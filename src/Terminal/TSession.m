#import "TSession.h"
#import "VTEscape.h"
#import <dispatch/dispatch.h>
#include <libproc.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <spawn.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>

static const NSUInteger kReadChunk = 1 << 16, kParseBudget = 1 << 16;
static const NSUInteger kOutputCap = 1 << 20, kPendingCap = 1 << 20;
static const NSTimeInterval kKillGrace = 1.0;
static NSString *const kRecordApplication = @"local.feather.terminal";

static NSString *PidsDir(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"FEATHERVIEW_TERMINAL_PIDS_DIR"];
    if (override.isAbsolutePath) return override;
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    NSString *folder = [bid isEqualToString:@"local.feather.editor"] ? @"Feather" : [@"Feather-" stringByAppendingString:bid ?: @""];
    return [[support stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"TerminalPids"];
}

// A pid alone is never an identity. Birth time comes from the kernel, not ps/argv or a shell name.
static NSDictionary *ProcessIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return nil;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof path) <= 0) return nil;
    pid_t sid = getsid(pid);
    if (sid < 0) return nil;
    return @{@"pid": @(pid), @"uid": @(info.pbi_uid), @"birthSeconds": @(info.pbi_start_tvsec),
             @"birthMicroseconds": @(info.pbi_start_tvusec), @"executable": @(path),
             @"session": @(sid), @"pgrp": @(info.pbi_pgid)};
}

static BOOL ValidNumber(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double n = [value doubleValue];
    return n >= minimum && n <= maximum && n == (double)[value unsignedLongLongValue];
}

static BOOL ValidIdentity(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    return ValidNumber(value[@"pid"], 2, INT_MAX) && ValidNumber(value[@"uid"], 0, UINT_MAX) &&
        [value[@"uid"] unsignedIntValue] == getuid() && ValidNumber(value[@"birthSeconds"], 1, UINT64_MAX) &&
        ValidNumber(value[@"birthMicroseconds"], 0, 999999) && ValidNumber(value[@"session"], 1, INT_MAX) &&
        ValidNumber(value[@"pgrp"], 1, INT_MAX) && [value[@"executable"] isKindOfClass:NSString.class] &&
        [value[@"executable"] isAbsolutePath];
}

typedef NS_ENUM(NSInteger, ProcessState) { ProcessGone, ProcessDifferent, ProcessAlive, ProcessUnknown };

static ProcessState IdentityState(NSDictionary *identity, BOOL checkExecutable) {
    pid_t pid = [identity[@"pid"] intValue];
    struct proc_bsdinfo info = {0};
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info)
        return (errno == ESRCH || errno == ENOENT) ? ProcessGone : ProcessUnknown;
    if (info.pbi_uid != [identity[@"uid"] unsignedIntValue] || info.pbi_ruid != getuid() ||
        info.pbi_start_tvsec != [identity[@"birthSeconds"] unsignedLongLongValue] ||
        info.pbi_start_tvusec != [identity[@"birthMicroseconds"] unsignedLongLongValue]) return ProcessDifferent;
    if (info.pbi_status == SZOMB) return ProcessGone;
    if (checkExecutable) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof path) <= 0) return ProcessUnknown;
        // The executable may legitimately change after launch (a script/helper can exec another
        // image). Birth time, uid, session and process group remain the stable identity checks.
        if (getsid(pid) != [identity[@"session"] intValue] || info.pbi_pgid != [identity[@"pgrp"] unsignedIntValue]) return ProcessDifferent;
    }
    return ProcessAlive;
}

static BOOL SameBirth(NSDictionary *a, NSDictionary *b) {
    return [a[@"pid"] isEqual:b[@"pid"]] && [a[@"uid"] isEqual:b[@"uid"]] &&
        [a[@"birthSeconds"] isEqual:b[@"birthSeconds"]] && [a[@"birthMicroseconds"] isEqual:b[@"birthMicroseconds"]];
}

// Snapshot session members AND descendants: job control deliberately puts foreground/background jobs
// in different process groups. Signal individual validated identities, never a potentially reused pgid.
static NSArray<NSDictionary *> *SessionMembers(NSDictionary *child, NSArray<NSDictionary *> *known) {
    if (!ValidIdentity(child) || ![child[@"pid"] isEqual:child[@"session"]] || ![child[@"pid"] isEqual:child[@"pgrp"]]) return known;
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return known;
    int capacity = count + 128;
    pid_t *pids = calloc((size_t)capacity, sizeof *pids);
    if (!pids) return known;
    count = proc_listallpids(pids, capacity * (int)sizeof *pids);
    NSMutableDictionary<NSNumber *, NSDictionary *> *identities = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *parents = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSDictionary *> *candidates = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *selected = [NSMutableSet set];
    for (NSDictionary *identity in known) {
        ProcessState state = IdentityState(identity, NO);
        if (state == ProcessAlive || state == ProcessUnknown) {
            identities[identity[@"pid"]] = identity;
            [selected addObject:identity[@"pid"]];
        }
    }
    ProcessState rootState = IdentityState(child, NO);
    BOOL sessionValid = rootState == ProcessAlive || rootState == ProcessGone;
    if (rootState == ProcessAlive) [selected addObject:child[@"pid"]];
    pid_t sid = [child[@"session"] intValue];
    uint64_t birthSec = [child[@"birthSeconds"] unsignedLongLongValue];
    uint64_t birthUsec = [child[@"birthMicroseconds"] unsignedLongLongValue];
    for (int i = 0; i < MIN(count, capacity); i++) {
        struct proc_bsdinfo info = {0};
        pid_t pid = pids[i];
        if (pid <= 1 || pid == getpid() || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info ||
            info.pbi_uid != getuid() || info.pbi_ruid != getuid() || info.pbi_status == SZOMB ||
            info.pbi_start_tvsec < birthSec || (info.pbi_start_tvsec == birthSec && info.pbi_start_tvusec < birthUsec)) continue;
        NSDictionary *identity = ProcessIdentity(pid);
        if (!identity || [identity[@"birthSeconds"] unsignedLongLongValue] != info.pbi_start_tvsec ||
            [identity[@"birthMicroseconds"] unsignedLongLongValue] != info.pbi_start_tvusec) continue;
        candidates[@(pid)] = identity;
        parents[@(pid)] = @(info.pbi_ppid);
        if (sessionValid && [identity[@"session"] intValue] == sid) [selected addObject:@(pid)];
    }
    BOOL added;
    do {
        added = NO;
        for (NSNumber *pid in parents) if (![selected containsObject:pid] && [selected containsObject:parents[pid]]) {
            [selected addObject:pid]; added = YES;
        }
    } while (added);
    for (NSNumber *pid in selected) {
        NSDictionary *identity = candidates[pid];
        if (identity && (!identities[pid] || SameBirth(identity, identities[pid]))) identities[pid] = identity;
    }
    [identities removeObjectForKey:child[@"pid"]];
    NSMutableArray *members = [identities.allValues mutableCopy];
    NSDictionary *root = candidates[child[@"pid"]];
    if (root && SameBirth(root, child)) [members addObject:root];
    free(pids);
    return members;
}

static BOOL MembersGone(NSArray<NSDictionary *> *members) {
    for (NSDictionary *identity in members) {
        ProcessState state = IdentityState(identity, NO);
        if (state == ProcessAlive || state == ProcessUnknown) return NO;
    }
    return YES;
}

static void SignalMembers(NSArray<NSDictionary *> *members, int signalNumber) {
    // Root last: give children a chance to exit while their parent can still reap them.
    for (NSDictionary *identity in members)
        if (IdentityState(identity, YES) == ProcessAlive) kill([identity[@"pid"] intValue], signalNumber);
}

static void WriteRecord(NSString *path, NSDictionary *record) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) NSLog(@"Terminal: could not save process identity at %@", path);
}

static NSDictionary *ReadRecord(NSString *path) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_size > (1 << 20)) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id record = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"application"] isEqual:kRecordApplication] ||
        !ValidNumber(record[@"version"], 1, 1) || !ValidNumber(record[@"uid"], getuid(), getuid()) ||
        !ValidIdentity(record[@"owner"]) || !ValidIdentity(record[@"child"]) ||
        ![record[@"members"] isKindOfClass:NSArray.class] || [record[@"members"] count] > 4096) return nil;
    if (![path.lastPathComponent isEqualToString:[record[@"child"][@"pid"] stringValue]] ||
        ![record[@"child"][@"pid"] isEqual:record[@"child"][@"session"]] ||
        ![record[@"child"][@"pid"] isEqual:record[@"child"][@"pgrp"]]) return nil;
    for (id identity in record[@"members"]) if (!ValidIdentity(identity)) return nil;
    return record;
}

static BOOL OwnerDead(NSDictionary *record) {
    ProcessState state = IdentityState(record[@"owner"], NO);
    return state == ProcessGone || state == ProcessDifferent;
}

static void RemoveRecord(NSString *path, NSDictionary *record) {
    // Another launch may have replaced a reused pid's record while cleanup was running.
    NSDictionary *current = ReadRecord(path);
    if (current && SameBirth(current[@"child"], record[@"child"]) && SameBirth(current[@"owner"], record[@"owner"]))
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

@interface TSession () {
    int _master;
    pid_t _pid;
    TScreen *_screen;
    VTEscape *_vt;
    dispatch_queue_t _queue;
    dispatch_source_t _reader, _writer, _poll;
    dispatch_group_t _ioCanceled;
    NSMutableData *_buffer, *_pending;
    BOOL _readPaused, _readEOF, _drainScheduled, _ioClosed; // protected by _buffer's lock
    BOOL _shellExited, _outputDone, _terminating, _exited;
    int _exitCode;
    double _killAt;
    NSString *_recordPath, *_lastTitle, *_lastCwd;
    NSDictionary *_childIdentity, *_ownerIdentity, *_lastRecord;
    NSArray<NSDictionary *> *_members;
}
- (void)readAvailable;
- (void)drain;
- (void)checkExit;
- (void)finishIfReady;
- (void)flushPending;
- (void)cancelIO;
- (void)saveMembers;
@end

@implementation TSession
@synthesize shellName = _shellName, pid = _pid;

static NSMutableDictionary<NSString *, TSession *> *gDragTokens;
static NSMutableSet<TSession *> *gLiveSessions;

+ (NSString *)registerDragSession:(TSession *)session {
    NSAssert(NSThread.isMainThread, @"Terminal ownership is main-thread-only");
    if (!gDragTokens) gDragTokens = [NSMutableDictionary dictionary];
    NSString *token = NSUUID.UUID.UUIDString;
    gDragTokens[token] = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [gDragTokens removeObjectForKey:token]; });
    return token;
}

+ (TSession *)sessionForDragToken:(NSString *)token { return gDragTokens[token]; }
+ (NSArray<TSession *> *)liveSessions {
    NSAssert(NSThread.isMainThread, @"Terminal ownership is main-thread-only");
    return gLiveSessions.allObjects ?: @[];
}
+ (NSString *)pidsDirectory { return PidsDir(); }

+ (NSString *)defaultShell {
    NSString *shell = NSProcessInfo.processInfo.environment[@"SHELL"];
    if (shell.length && [NSFileManager.defaultManager isExecutableFileAtPath:shell]) return shell;
    for (NSString *candidate in @[@"/bin/zsh", @"/bin/bash"]) if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    return @"/bin/sh";
}

- (instancetype)initWithDirectory:(NSString *)dir shell:(NSString *)shell error:(NSString **)error {
    NSAssert(NSThread.isMainThread, @"Terminal ownership is main-thread-only");
    if (!(self = [super init])) return nil;
    _master = -1; _exitCode = -1;
    if (error) *error = nil;
    _buffer = [NSMutableData data]; _pending = [NSMutableData data];
    _screen = [[TScreen alloc] initWithCols:80 rows:24 scrollback:5000];
    _vt = [[VTEscape alloc] initWithEndpoint:_screen];
    _lastTitle = [_screen.title copy]; _lastCwd = [_screen.cwd copy];
    _queue = dispatch_queue_create("local.feather.terminal", DISPATCH_QUEUE_SERIAL);
    shell = shell.length ? shell : TSession.defaultShell;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:shell]) shell = @"/bin/sh";
    _shellName = shell.lastPathComponent;
    BOOL isDirectory = NO;
    if (!dir.length || ![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDirectory] || !isDirectory) dir = NSHomeDirectory();
    _directory = [dir copy];
    _ownerIdentity = ProcessIdentity(getpid());
    NSString *recordDir = PidsDir();
    if (!_ownerIdentity || ![NSFileManager.defaultManager createDirectoryAtPath:recordDir withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil]) {
        if (error) *error = @"Could not create terminal process registry";
        return nil;
    }

    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (master < 0) { if (error) *error = @"posix_openpt failed"; return nil; }
    char slavePath[PATH_MAX];
    const char *slaveName;
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0 || grantpt(master) < 0 || unlockpt(master) < 0 ||
        !(slaveName = ptsname(master)) || strlcpy(slavePath, slaveName, sizeof slavePath) >= sizeof slavePath ||
        fcntl(master, F_SETFL, O_NONBLOCK) < 0) {
        close(master); if (error) *error = @"Could not prepare terminal PTY"; return nil;
    }
    int slave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC);
    struct winsize ws = {.ws_col = 80, .ws_row = 24};
    if (slave < 0 || ioctl(slave, TIOCSWINSZ, &ws) < 0) {
        if (slave >= 0) close(slave);
        close(master); if (error) *error = @"Could not size terminal PTY"; return nil;
    }

    // Darwin applies SETSID before file actions. Opening the slave then acquires the controlling
    // terminal. CLOEXEC_DEFAULT closes every inherited descriptor except these explicit stdio actions.
    // All Objective-C/argv/environment work is done here in the parent, never in a forked child.
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment addEntriesFromDictionary:@{@"TERM": @"xterm-256color", @"FEATHERVIEW_TERMINAL": @"1", @"COLORTERM": @"truecolor",
                                          @"TERM_PROGRAM": @"FeatherView", @"TERMINAL_EMULATOR": @"FeatherView"}];
    char **envp = calloc(environment.count + 1, sizeof *envp);
    NSUInteger envCount = 0;
    BOOL allocated = envp != NULL;
    for (NSString *key in environment) {
        if (!allocated) break;
        envp[envCount] = strdup([[NSString stringWithFormat:@"%@=%@", key, environment[key]] UTF8String]);
        if (!envp[envCount]) { allocated = NO; break; }
        envCount++;
    }
    char *argv[] = {(char *)_shellName.UTF8String, (char *)([shell.lastPathComponent isEqualToString:@"fish"] ? "--login" : "-l"), NULL};
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    int result = posix_spawnattr_init(&attributes);
    BOOL hasAttributes = result == 0, hasActions = NO;
    if (!result) { result = posix_spawn_file_actions_init(&actions); hasActions = result == 0; }
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    if (!result) result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    if (!result) result = posix_spawnattr_setsigmask(&attributes, &empty);
    if (!result) result = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (!result) result = posix_spawn_file_actions_addchdir_np(&actions, dir.fileSystemRepresentation);
    if (!result) result = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO);
    pid_t pid = 0;
    if (!result) result = allocated ? posix_spawn(&pid, shell.fileSystemRepresentation, &actions, &attributes, argv, envp) : ENOMEM;
    if (hasActions) posix_spawn_file_actions_destroy(&actions);
    if (hasAttributes) posix_spawnattr_destroy(&attributes);
    for (NSUInteger i = 0; i < envCount; i++) free(envp[i]);
    free(envp);
    close(slave);
    if (result) { close(master); if (error) *error = [NSString stringWithFormat:@"Could not spawn terminal: %s", strerror(result)]; return nil; }

    _master = master; _pid = pid;
    _childIdentity = ProcessIdentity(pid);
    if (!_childIdentity || [_childIdentity[@"session"] intValue] != pid || [_childIdentity[@"pgrp"] intValue] != pid) {
        NSLog(@"Terminal: invalid spawned identity pid=%d session=%@ pgrp=%@", pid, _childIdentity[@"session"], _childIdentity[@"pgrp"]);
        kill(pid, SIGKILL); // still our unreaped child: the pid cannot have been recycled
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(master); _master = -1;
        if (error) *error = @"Could not establish a dedicated terminal session";
        return nil;
    }
    _members = @[_childIdentity];
    _recordPath = [recordDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", pid]];
    [self saveMembers];
    if (!gLiveSessions) gLiveSessions = [NSMutableSet set];
    [gLiveSessions addObject:self];

    __weak TSession *weakSelf = self;
    _ioCanceled = dispatch_group_create();
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, master, 0, _queue);
    dispatch_group_enter(_ioCanceled);
    dispatch_group_t canceled = _ioCanceled;
    dispatch_source_set_cancel_handler(_reader, ^{ dispatch_group_leave(canceled); });
    dispatch_source_set_event_handler(_reader, ^{ [weakSelf readAvailable]; });
    dispatch_resume(_reader);
    _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_poll, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), 500 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_poll, ^{ [weakSelf checkExit]; });
    dispatch_resume(_poll);
    return self;
}

- (TScreen *)screen { return _screen; }
- (BOOL)shellExited { return _shellExited; }
- (BOOL)outputDone { return _outputDone; }
- (BOOL)terminating { return _terminating; }
- (BOOL)exited { return _exited; }
- (int)exitCode { return _exitCode; }
- (BOOL)running { return !_shellExited && !_terminating; }

- (void)dealloc {
    // Live sessions cannot deallocate. A finished session's fd was closed only after its queue's
    // cancellation barrier; failed initializers have no sources and close their local fd themselves.
    if (_poll) dispatch_source_cancel(_poll);
}

- (void)saveMembers {
    if (!_childIdentity) return;
    NSDictionary *record = @{@"application": kRecordApplication, @"version": @1, @"uid": @(getuid()),
                             @"owner": _ownerIdentity, @"child": _childIdentity, @"members": _members ?: @[]};
    if (![record isEqual:_lastRecord]) { WriteRecord(_recordPath, record); _lastRecord = record; }
}

// Serial I/O queue. One outstanding main-queue drain, at most 1 MiB queued output, at most 64 KiB
// per read turn. Suspending the source applies kernel PTY backpressure without dropping bytes.
- (void)readAvailable {
    uint8_t bytes[kReadChunk];
    @synchronized (_buffer) {
        if (_readEOF || _ioClosed) return;
        NSUInteger room = kOutputCap - _buffer.length;
        if (!room) {
            if (!_readPaused) { dispatch_suspend(_reader); _readPaused = YES; }
            return;
        }
        ssize_t count;
        do { count = read(_master, bytes, MIN(room, sizeof bytes)); } while (count < 0 && errno == EINTR);
        if (count > 0) [_buffer appendBytes:bytes length:(NSUInteger)count];
        else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
            _readEOF = YES;
            if (_readPaused) { dispatch_resume(_reader); _readPaused = NO; }
            dispatch_source_cancel(_reader);
        }
        if (!_drainScheduled && (_buffer.length || _readEOF)) {
            _drainScheduled = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ [self drain]; });
        }
    }
}

- (void)drain {
    NSAssert(NSThread.isMainThread, @"Parsing is main-thread-only");
    NSData *chunk;
    BOOL eof;
    @synchronized (_buffer) {
        NSUInteger count = MIN(kParseBudget, _buffer.length);
        chunk = [_buffer subdataWithRange:NSMakeRange(0, count)];
        [_buffer replaceBytesInRange:NSMakeRange(0, count) withBytes:NULL length:0];
        eof = _readEOF && !_buffer.length;
    }
    if (chunk.length) {
        [_vt feed:chunk.bytes length:chunk.length];
        if (self.onChange) self.onChange();
        if (!((_lastTitle == _screen.title) || [_lastTitle isEqualToString:_screen.title]) ||
            !((_lastCwd == _screen.cwd) || [_lastCwd isEqualToString:_screen.cwd])) {
            _lastTitle = [_screen.title copy]; _lastCwd = [_screen.cwd copy];
            if (self.onTitleChange) self.onTitleChange();
        }
    }
    if (eof) { _outputDone = YES; [self cancelIO]; }
    @synchronized (_buffer) {
        if (_buffer.length) dispatch_async(dispatch_get_main_queue(), ^{ [self drain]; });
        else _drainScheduled = NO;
    }
    dispatch_async(_queue, ^{
        @synchronized (self->_buffer) {
            if (self->_readPaused && !self->_readEOF && !self->_ioClosed) {
                dispatch_resume(self->_reader); self->_readPaused = NO;
            }
        }
    });
    [self finishIfReady];
}

#pragma mark Input

- (void)writeData:(NSData *)data {
    NSAssert(NSThread.isMainThread, @"Terminal input is main-thread-only");
    if (!data.length || !self.running || _outputDone) return;
    // Synchronize the bounded queue insertion as well as fd use. This prevents an unbounded pile of
    // captured NSData blocks when repeated paste/key events outrun a non-reading child.
    dispatch_sync(_queue, ^{
        @synchronized (self->_buffer) {
            if (self->_ioClosed || self->_readEOF || data.length > kPendingCap - self->_pending.length) return;
        }
        [self->_pending appendData:data];
        [self flushPending];
    });
}

- (void)writeString:(NSString *)string { [self writeData:[string dataUsingEncoding:NSUTF8StringEncoding]]; }

- (void)flushPending {
    if (!_pending.length) return;
    @synchronized (_buffer) { if (_ioClosed || _readEOF) { [_pending setLength:0]; return; } }
    ssize_t count;
    do { count = write(_master, _pending.bytes, MIN(_pending.length, kReadChunk)); } while (count < 0 && errno == EINTR);
    if (count > 0) [_pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)count) withBytes:NULL length:0];
    else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) [_pending setLength:0];
    if (_pending.length && !_writer) {
        __weak TSession *weakSelf = self;
        _writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, _master, 0, _queue);
        dispatch_group_t canceled = _ioCanceled;
        dispatch_group_enter(canceled);
        dispatch_source_set_cancel_handler(_writer, ^{ dispatch_group_leave(canceled); });
        dispatch_source_set_event_handler(_writer, ^{ [weakSelf flushPending]; });
        dispatch_resume(_writer);
    } else if (!_pending.length && _writer) {
        dispatch_source_cancel(_writer); _writer = nil;
    }
}

- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows {
    NSAssert(NSThread.isMainThread, @"Terminal screen is main-thread-only");
    [_screen resizeCols:cols rows:rows];
    struct winsize ws = {.ws_col = (unsigned short)MIN(cols, 0xFFFE), .ws_row = (unsigned short)MIN(rows, 0xFFFE)};
    dispatch_async(_queue, ^{ @synchronized (self->_buffer) { if (!self->_ioClosed) ioctl(self->_master, TIOCSWINSZ, &ws); } });
}

// Runs on the serial queue after all fd operations. The cancellation handlers for BOTH sources
// must run before close: a descriptor may otherwise be reused while a dispatch source still owns it.
- (void)cancelIO {
    dispatch_async(_queue, ^{
        @synchronized (self->_buffer) {
            if (self->_ioClosed) return;
            self->_ioClosed = YES;
            if (self->_readPaused) { dispatch_resume(self->_reader); self->_readPaused = NO; }
            if (self->_reader) dispatch_source_cancel(self->_reader);
            if (self->_writer) dispatch_source_cancel(self->_writer);
            self->_reader = nil; self->_writer = nil;
            [self->_pending setLength:0];
            dispatch_group_notify(self->_ioCanceled, self->_queue, ^{
                close(self->_master); self->_master = -1;
                dispatch_async(dispatch_get_main_queue(), ^{ [self finishIfReady]; });
            });
        }
    });
}

#pragma mark Lifecycle

- (void)checkExit {
    if (_exited) return;
    if (_childIdentity) {
        _members = SessionMembers(_childIdentity, _members);
        [self saveMembers]; // persist jobs BEFORE reaping the root or sending any signal
    }
    if (!_shellExited) {
        int status = 0;
        pid_t result;
        do { result = waitpid(_pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
        if (result == _pid || (result < 0 && errno == ECHILD)) {
            _shellExited = YES;
            if (result == _pid) _exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
            // Shell exit must not abandon jobs holding the slave or the buffered output tail.
            [self terminate];
            dispatch_async(_queue, ^{ [self readAvailable]; });
        }
    }
    if (_terminating && CFAbsoluteTimeGetCurrent() >= _killAt) {
        SignalMembers(_members, SIGKILL);
        // A failed identity read immediately after spawn still represents our unreaped child.
        if (!_childIdentity && !_shellExited) kill(_pid, SIGKILL);
    }
    [self finishIfReady];
}

- (void)finishIfReady {
    if (_exited || !_shellExited || !_outputDone || !MembersGone(_members)) return;
    __block BOOL closed;
    dispatch_sync(_queue, ^{ closed = self->_master < 0; });
    if (!closed) return;
    _exited = YES;
    if (_poll) { dispatch_source_cancel(_poll); _poll = nil; }
    if (_lastRecord) RemoveRecord(_recordPath, _lastRecord);
    [gLiveSessions removeObject:self];
    for (NSString *token in gDragTokens.allKeys) if (gDragTokens[token] == self) [gDragTokens removeObjectForKey:token];
    if (self.onChange) self.onChange();
    if (self.onExit) self.onExit();
}

- (void)terminate {
    NSAssert(NSThread.isMainThread, @"Terminal ownership is main-thread-only");
    if (_terminating || _exited) return;
    _terminating = YES;
    _killAt = CFAbsoluteTimeGetCurrent() + kKillGrace;
    if (_childIdentity) {
        _members = SessionMembers(_childIdentity, _members);
        [self saveMembers];
        SignalMembers(_members, SIGHUP);
    } else if (!_shellExited) kill(_pid, SIGHUP);
}

+ (BOOL)shutdownAllSessionsWithTimeout:(NSTimeInterval)timeout {
    NSAssert(NSThread.isMainThread, @"Terminal shutdown is main-thread-only");
    double start = CFAbsoluteTimeGetCurrent(), deadline = start + MAX(0, timeout);
    for (TSession *session in self.liveSessions) {
        [session terminate];
        session->_killAt = MIN(session->_killAt, start + MAX(0, timeout) * 0.5);
    }
    while (self.liveSessions.count) {
        for (TSession *session in self.liveSessions) [session checkExit];
        if (!self.liveSessions.count) return YES;
        double remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0) return NO;
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.02, remaining)]];
    }
    return YES;
}

+ (void)sweepOrphanedShells {
    NSString *directory = PidsDir(); // capture override before dispatching; never switch directories mid-sweep
    static dispatch_queue_t sweepQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sweepQueue = dispatch_queue_create("local.feather.terminal.recovery", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(sweepQueue, ^{
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil]) {
            @autoreleasepool {
                if (!name.intValue || ![name isEqualToString:[NSString stringWithFormat:@"%d", name.intValue]]) continue;
                NSString *path = [directory stringByAppendingPathComponent:name];
                NSDictionary *record = ReadRecord(path);
                if (!record) {
                    // Old shell-name-only records provide no safe pid identity. Retire, never kill.
                    NSLog(@"Terminal: discarded unverifiable process record %@", path);
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    continue;
                }
                if (!OwnerDead(record)) continue;
                NSDictionary *child = record[@"child"];
                ProcessState state = IdentityState(child, YES);
                if (state == ProcessDifferent) { RemoveRecord(path, record); continue; }
                if (state == ProcessUnknown) continue;
                NSArray *members = SessionMembers(child, record[@"members"]);
                NSMutableDictionary *updated = [record mutableCopy]; updated[@"members"] = members;
                WriteRecord(path, updated);
                if (OwnerDead(updated)) SignalMembers(members, SIGHUP);
                // Escalation is asynchronous: no sleeping worker, no process-wide shell scan.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKillGrace * NSEC_PER_SEC)), sweepQueue, ^{
                    NSDictionary *current = ReadRecord(path);
                    if (!current || !SameBirth(current[@"child"], child) || !OwnerDead(current)) return;
                    ProcessState root = IdentityState(child, YES);
                    if (root == ProcessDifferent || root == ProcessUnknown) return;
                    NSArray *survivors = SessionMembers(child, current[@"members"]);
                    NSMutableDictionary *next = [current mutableCopy]; next[@"members"] = survivors;
                    WriteRecord(path, next);
                    if (OwnerDead(next)) SignalMembers(survivors, SIGKILL);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), sweepQueue, ^{
                        if (OwnerDead(next) && MembersGone(survivors)) RemoveRecord(path, next);
                    });
                });
            }
        }
    });
}

@end

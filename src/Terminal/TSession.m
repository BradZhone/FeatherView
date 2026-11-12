#import "TSession.h"
#import <dispatch/dispatch.h>
#import "VTEscape.h"
#include <util.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>

// Output is read on a background queue into a buffer and parsed on the main thread in bounded
// chunks (kParseBudget), so a program dumping megabytes never blocks the UI for long. The screen is
// only touched on the main thread, which is also where the view draws.

static const NSUInteger kReadChunk = 1 << 16, kParseBudget = 1 << 18, kPendingCap = 1 << 20;

@interface TSession () {
    int _master;
    pid_t _pid;
    TScreen *_screen;
    VTEscape *_vt;
    dispatch_source_t _reader;
    dispatch_queue_t _queue;
    NSMutableData *_buffer;
    NSData *_pending;                  // input the PTY wouldn't take yet
    BOOL _exited, _draining, _notified, _killed;
    int _exitCode;
    dispatch_source_t _poll;           // exit watch when the output has gone quiet
    NSTimer *_sigkill;                 // terminate: SIGKILL if still there
}
- (void)drain;
- (void)checkExit;
@end
@implementation TSession
@synthesize shellName = _shellName, pid = _pid;

static NSMutableDictionary<NSString *, TSession *> *gDragTokens;

+ (NSString *)registerDragSession:(TSession *)session {
    if (!gDragTokens) gDragTokens = [NSMutableDictionary dictionary];
    NSString *token = [NSUUID UUID].UUIDString;
    gDragTokens[token] = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [gDragTokens removeObjectForKey:token]; });
    return token;
}

+ (TSession *)sessionForDragToken:(NSString *)token { return gDragTokens[token]; }

static NSString * const kMarker = @"FEATHERVIEW_TERMINAL=1";

+ (NSString *)pidsDirectory { return PidsDir(); }

static NSString *PidsDir(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    NSString *folder = [bid isEqualToString:@"local.feather.editor"] ? @"Feather" : [@"Feather-" stringByAppendingString:bid ?: @""];
    return [[support stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"TerminalPids"];
}

// Records the child's pid so a later launch can end shells this instance left behind (crash, force quit).
// The file is named by pid and holds the shell name, so the sweep can sanity-check the process.
+ (void)recordSpawnedPid:(pid_t)pid shell:(NSString *)shell {
    NSString *dir = PidsDir();
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [(shell ?: @"zsh") writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", pid]]
                        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (void)forgetPid:(pid_t)pid {
    [NSFileManager.defaultManager removeItemAtPath:[PidsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", pid]] error:nil];
}

+ (void)sweepOrphanedShells {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *dir = PidsDir();
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
            pid_t pid = f.intValue;
            if (pid <= 1) { [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil]; continue; }
            if (kill(pid, 0) != 0) {                     // already gone: drop the record
                [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
                continue;
            }
            NSString *shell = [[NSString alloc] initWithContentsOfFile:[dir stringByAppendingPathComponent:f] encoding:NSUTF8StringEncoding error:nil] ?: @"zsh";
            // sanity check: the pid must still be that shell (pids are recycled rarely, but be safe)
            NSTask *ps = [NSTask new];
            ps.launchPath = @"/bin/ps";
            ps.arguments = @[@"-axo", @"pid=,command="];
            NSPipe *out = [NSPipe pipe];
            ps.standardOutput = out;
            ps.standardError = [NSPipe pipe];
            [ps launch];
            NSString *text = [[NSString alloc] initWithData:[out.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
            BOOL isShell = NO;
            for (NSString *line in [text componentsSeparatedByString:@"\n"])
                if ([line intValue] == pid && [line containsString:shell]) isShell = YES;
            if (!isShell) { [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil]; continue; }
            kill(pid, SIGHUP);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (kill(pid, 0) == 0) kill(pid, SIGKILL);
                [NSFileManager.defaultManager removeItemAtPath:[PidsDir() stringByAppendingPathComponent:f] error:nil];
            });
        }
    });
}

+ (NSString *)defaultShell {
    const char *env = getenv("SHELL");
    NSString *s = env ? @(env) : nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (s.length && [fm isExecutableFileAtPath:s]) return s;
    for (NSString *c in @[@"/bin/zsh", @"/bin/bash"]) if ([fm isExecutableFileAtPath:c]) return c;
    return @"/bin/sh";
}

- (instancetype)initWithDirectory:(NSString *)dir shell:(NSString *)shell error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _master = -1;
    _shellName = @"shell";
    _exitCode = -1;
    _buffer = [NSMutableData data];
    _screen = [[TScreen alloc] initWithCols:80 rows:24 scrollback:5000];
    _vt = [[VTEscape alloc] initWithEndpoint:_screen];
    _queue = dispatch_queue_create("local.feather.terminal", DISPATCH_QUEUE_SERIAL);

    shell = shell.length ? shell : TSession.defaultShell;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:shell]) shell = @"/bin/sh";
    _shellName = shell.lastPathComponent;
    dir = dir.length ? dir : NSHomeDirectory();
    if (![NSFileManager.defaultManager fileExistsAtPath:dir]) dir = NSHomeDirectory();
    _directory = [dir copy];

    struct winsize ws = {.ws_col = 80, .ws_row = 24};
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) { if (error) *error = @"posix_openpt failed"; return nil; }
    grantpt(master);
    unlockpt(master);
    int slave = open(ptsname(master), O_RDWR);
    if (slave < 0) { close(master); if (error) *error = @"open(ptsname) failed"; return nil; }
    ioctl(slave, TIOCSWINSZ, &ws);

    pid_t pid = fork();
    if (pid < 0) { close(master); close(slave); if (error) *error = @"fork failed"; return nil; }
    if (pid == 0) {
        // only exec calls between fork and exec
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);
        close(master);
        setenv("TERM", "xterm-256color", 1);
        setenv("FEATHERVIEW_TERMINAL", "1", 1);            // marks our shells for the orphan sweep
        setenv("COLORTERM", "truecolor", 1);
        setenv("TERM_PROGRAM", "FeatherView", 1);
        setenv("TERMINAL_EMULATOR", "FeatherView", 1);
        chdir(dir.fileSystemRepresentation);
        BOOL fish = [shell hasSuffix:@"/fish"];
        char argv0[PATH_MAX];
        strlcpy(argv0, shell.fileSystemRepresentation, sizeof argv0);
        const char *base = strrchr(argv0, '/');
        execl(argv0, base ? base + 1 : argv0, fish ? "--login" : "-l", (char *)NULL);
        _exit(127);
    }
    close(slave);
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    _master = master;
    _pid = pid;
    [TSession recordSpawnedPid:pid shell:shell.lastPathComponent];

    __weak typeof(self) weakSelf = self;
    _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, master, 0, _queue);
    dispatch_source_set_event_handler(_reader, ^{
        typeof(self) me = weakSelf;
        if (!me || me->_exited) return;
        uint8_t buf[kReadChunk];
        ssize_t n;
        while ((n = read(me->_master, buf, sizeof buf)) > 0) {
            @synchronized (me->_buffer) { [me->_buffer appendBytes:buf length:(NSUInteger)n]; }
            if ((NSUInteger)n < sizeof buf) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [me drain]; });
    });
    dispatch_resume(_reader);
    return self;
}

- (TScreen *)screen { return _screen; }
- (BOOL)exited { return _exited; }
- (int)exitCode { return _exitCode; }
- (BOOL)running { return !_exited; }

// Output is parsed on the main thread; at most kParseBudget bytes per run, then the runloop gets a turn.
- (void)dealloc {
    // no forgetPid here: a dealloc without terminate means the app is going away and the sweep
    // at the next launch will clean the shell up; forgetting the record would strand it
    if (_reader) dispatch_source_cancel(_reader);
    if (_poll) dispatch_source_cancel(_poll);
    [_sigkill invalidate];
    if (_master >= 0) close(_master);
}

- (void)drain {
    if (_draining || _exited) return;
    NSUInteger total = 0;
    _draining = YES;
    while (!_exited) {
        NSData *chunk = nil;
        @synchronized (_buffer) {
            if (!_buffer.length) break;
            chunk = [_buffer subdataWithRange:NSMakeRange(0, MIN(kParseBudget, _buffer.length))];
            [_buffer replaceBytesInRange:NSMakeRange(0, chunk.length) withBytes:NULL length:0];
        }
        [_vt feed:chunk.bytes length:chunk.length];
        total += chunk.length;
        if (_pending.length) [self flushPending];
        if (total >= kParseBudget) {
            dispatch_async(dispatch_get_main_queue(), ^{ _draining = NO; [self drain]; });
            [self checkExit];
            [self notify];
            return;
        }
    }
    _draining = NO;
    if (_pending.length) [self flushPending];
    [self checkExit];
    [self notify];
}

- (void)notify {
    if (_notified || (!self.onChange && !self.onTitleChange)) return;
    _notified = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) me = self;
        me->_notified = NO;
        if (me.onChange) me.onChange();
        if (me.onTitleChange) me.onTitleChange();
    });
}

// The process may exit long after the last output; a slow poll catches that.
- (void)checkExit {
    if (_exited || !_pid) return;
    int status = 0;
    if (waitpid(_pid, &status, WNOHANG) == _pid) {
        _exited = YES;
        _exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WTERMSIG(status) ?: 0);
        [TSession forgetPid:_pid];
        [TSession forgetPid:_pid];
        dispatch_source_cancel(_reader);
        _reader = nil;
        dispatch_source_cancel(_poll);
        _poll = nil;
        [_sigkill invalidate];
        _sigkill = nil;
        if (self.onExit) dispatch_async(dispatch_get_main_queue(), self.onExit);
        [self notify];
        return;
    }
    if (!_poll) {
        __weak typeof(self) weakSelf = self;
        _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_poll, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)0.5 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(_poll, ^{ [weakSelf checkExit]; });
        dispatch_resume(_poll);
    }
}

#pragma mark Input

- (void)writeData:(NSData *)d {
    if (_exited || !d.length) return;
    const uint8_t *b = d.bytes;
    NSUInteger left = d.length;
    while (left) {
        ssize_t w = write(_master, b, left);
        if (w >= 0) { b += w; left -= (NSUInteger)w; continue; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN && left <= kPendingCap) {   // the PTY buffer is full: the reader drains it
            NSMutableData *q = [_pending mutableCopy] ?: [NSMutableData data];
            [q appendBytes:b length:left];
            _pending = q;
        }
        break;
    }
}

- (void)flushPending {
    NSData *d = _pending;
    _pending = nil;
    [self writeData:d];
}

- (void)writeString:(NSString *)s { [self writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; }

- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows {
    [_screen resizeCols:cols rows:rows];
    struct winsize ws = {.ws_col = (unsigned short)MIN(cols, 0xFFFE), .ws_row = (unsigned short)MIN(rows, 0xFFFE)};
    ioctl(_master, TIOCSWINSZ, &ws);        // the kernel delivers SIGWINCH to the shell
}

#pragma mark Ending it

- (void)terminate {
    if (_exited) return;
    [TSession forgetPid:_pid];
    _killed = YES;
    kill(_pid, SIGHUP);
    __weak typeof(self) weakSelf = self;
    [_sigkill invalidate];
    _sigkill = [NSTimer timerWithTimeInterval:2.0 repeats:NO block:^(NSTimer *t) {
        typeof(self) me = weakSelf;
        if (!me || me->_exited) return;
        kill(me->_pid, SIGKILL);
        [me checkExit];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_sigkill forMode:NSRunLoopCommonModes];
    [self checkExit];
}

@end

#import "WorkspaceSearch.h"
#import "FileWalker.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const NSUInteger kMaxFileBytes = 16u << 20;
static const NSUInteger kMaxHitsPerFile = 200;
static const NSUInteger kPreviewBytes = 160;

@implementation SearchHit @end

static NSString *decode(const uint8_t *p, NSUInteger n) {
    if (!n) return @"";
    return [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:p length:n encoding:NSISOLatin1StringEncoding];
}

static NSUInteger backToBoundary(const uint8_t *p, NSUInteger i, NSUInteger lo) {
    while (i > lo && (p[i] & 0xC0) == 0x80) i--;
    return i;
}

// Builds a hit from one line of text (no trailing newline) and a match at byte offset `m`.
static SearchHit *makeHit(NSString *path, NSUInteger lineNo, const uint8_t *line, NSUInteger len,
                          NSUInteger m, NSUInteger mlen) {
    SearchHit *h = [SearchHit new];
    h.path = path; h.line = lineNo; h.column = m + 1; h.matchBytes = mlen;
    while (len && (line[len - 1] == '\r' || line[len - 1] == '\n')) len--;
    NSUInteger s = 0;
    while (s < m && (line[s] == ' ' || line[s] == '\t')) s++;
    BOOL clipped = NO;
    if (m > s + 40) { s = backToBoundary(line, m - 30, s); clipped = YES; }
    NSUInteger e = MIN(len, s + kPreviewBytes);
    if (e < len) e = backToBoundary(line, e, s);
    if (m + mlen > e || m < s) {
        h.preview = decode(line + s, e - s);
        h.previewMatch = NSMakeRange(NSNotFound, 0);
        return h;
    }
    NSString *pre = decode(line + s, m - s), *mid = decode(line + m, mlen), *post = decode(line + m + mlen, e - m - mlen);
    NSString *lead = clipped ? @"…" : @"";
    h.preview = [NSString stringWithFormat:@"%@%@%@%@", lead, pre, mid, post];
    h.previewMatch = NSMakeRange(lead.length + pre.length, mid.length);
    return h;
}

@interface WorkspaceSearch ()
@property (atomic) NSUInteger generation;
@property (atomic, strong) NSTask *task;
@end

@implementation WorkspaceSearch

- (instancetype)init {
    if ((self = [super init])) _maxHits = 2000;
    return self;
}

+ (NSString *)ripgrepPath {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Apps launched from Finder get a minimal PATH, so check the usual install locations too.
        NSMutableArray *dirs = [@[@"/opt/homebrew/bin", @"/usr/local/bin", @"/opt/local/bin",
                                  [NSHomeDirectory() stringByAppendingPathComponent:@".cargo/bin"]] mutableCopy];
        [dirs addObjectsFromArray:[NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"]];
        for (NSString *d in dirs) {
            NSString *p = [d stringByAppendingPathComponent:@"rg"];
            if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) { path = p; break; }
        }
    });
    return path;
}

- (void)cancel {
    self.generation++;
    NSTask *t = self.task;
    self.task = nil;
    if (t.isRunning) [t terminate];
}

- (void)search:(NSString *)query root:(NSString *)root caseSensitive:(BOOL)cs includeHidden:(BOOL)hidden
       onBatch:(void (^)(NSArray<SearchHit *> *, NSUInteger))onBatch onDone:(void (^)(BOOL))onDone {
    [self cancel];
    NSUInteger gen = self.generation;
    if (!query.length) { onDone(NO); return; }
    void (^batch)(NSArray *, NSUInteger) = ^(NSArray *hits, NSUInteger files) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.generation == gen) onBatch(hits, files); });
    };
    void (^done)(BOOL) = ^(BOOL truncated) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.generation == gen) onDone(truncated); });
    };
    NSString *rg = self.disableRipgrep ? nil : [WorkspaceSearch ripgrepPath];
    _usedRipgrep = rg != nil;
    if (rg) [self runRipgrep:rg query:query root:root cs:cs hidden:hidden gen:gen batch:batch done:done];
    else [self runBuiltin:query root:root cs:cs hidden:hidden gen:gen batch:batch done:done];
}

// One rg output line: "<path>\0<line>:<col>:<text>"
static SearchHit *parseRgLine(const uint8_t *p, NSUInteger n, NSUInteger mlen, NSString **lastPath, NSData **lastRaw) {
    const uint8_t *z = memchr(p, 0, n);
    if (!z) return nil;
    NSUInteger plen = z - p;
    if (!*lastRaw || (*lastRaw).length != plen || memcmp((*lastRaw).bytes, p, plen)) {
        *lastRaw = [NSData dataWithBytes:p length:plen];
        *lastPath = [NSFileManager.defaultManager stringWithFileSystemRepresentation:(const char *)p length:plen];
    }
    const uint8_t *q = z + 1, *end = p + n;
    NSUInteger line = 0, col = 0;
    while (q < end && *q >= '0' && *q <= '9') line = line * 10 + (*q++ - '0');
    if (q >= end || *q++ != ':') return nil;
    while (q < end && *q >= '0' && *q <= '9') col = col * 10 + (*q++ - '0');
    if (q >= end || *q++ != ':' || !line || !col) return nil;
    NSUInteger tlen = end - q;
    return makeHit(*lastPath, line, q, tlen, MIN(col - 1, tlen), MIN(mlen, tlen > col - 1 ? tlen - (col - 1) : 0));
}

- (void)runRipgrep:(NSString *)rg query:(NSString *)query root:(NSString *)root cs:(BOOL)cs hidden:(BOOL)hidden
               gen:(NSUInteger)gen batch:(void (^)(NSArray *, NSUInteger))batch done:(void (^)(BOOL))done {
    NSMutableArray *args = [@[@"--null", @"--line-number", @"--column", @"--no-heading", @"--color", @"never",
                              @"--fixed-strings", @"--max-columns", @"600", @"--max-columns-preview",
                              @"--max-count", [NSString stringWithFormat:@"%lu", (unsigned long)kMaxHitsPerFile],
                              @"--max-filesize", @"16M", cs ? @"--case-sensitive" : @"--ignore-case"] mutableCopy];
    if (hidden) [args addObject:@"--hidden"];
    for (NSString *d in FWSkippedDirs()) [args addObjectsFromArray:@[@"--glob", [NSString stringWithFormat:@"!%@/", d]]];
    if ([root isEqualToString:NSHomeDirectory()]) [args addObjectsFromArray:@[@"--glob", @"!/Library/"]];
    [args addObjectsFromArray:@[@"--regexp", query, @"--", root]];

    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:rg];
    t.arguments = args;
    t.currentDirectoryURL = [NSURL fileURLWithPath:root];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) {
        _usedRipgrep = NO;
        [self runBuiltin:query root:root cs:cs hidden:hidden gen:gen batch:batch done:done];
        return;
    }
    self.task = t;
    NSUInteger mlen = [query lengthOfBytesUsingEncoding:NSUTF8StringEncoding], maxHits = self.maxHits;
    NSFileHandle *fh = out.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buf = [NSMutableData data];
        NSMutableArray *pending = [NSMutableArray array];
        NSUInteger total = 0;
        BOOL truncated = NO;
        NSString *lastPath = nil; NSData *lastRaw = nil;
        CFAbsoluteTime tick = CFAbsoluteTimeGetCurrent();
        while (self.generation == gen && !truncated) {
            NSData *chunk = fh.availableData;
            if (!chunk.length) break;
            [buf appendData:chunk];
            const uint8_t *b = buf.bytes;
            NSUInteger start = 0, n = buf.length;
            for (NSUInteger i = 0; i < n; i++) {
                if (b[i] != '\n') continue;
                SearchHit *h = parseRgLine(b + start, i - start, mlen, &lastPath, &lastRaw);
                start = i + 1;
                if (!h) continue;
                [pending addObject:h];
                if (++total >= maxHits) { truncated = YES; break; }
            }
            [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (pending.count && (now - tick > 0.1 || pending.count >= 200)) {
                batch([pending copy], 0); [pending removeAllObjects]; tick = now;
            }
        }
        if (t.isRunning) [t terminate];
        [t waitUntilExit];
        if (pending.count) batch([pending copy], 0);
        done(truncated);
    });
}

static const uint8_t *findBytes(const uint8_t *h, NSUInteger hn, const uint8_t *n, NSUInteger nn, BOOL cs) {
    if (nn > hn) return NULL;
    if (cs) return memmem(h, hn, n, nn);
    uint8_t first = n[0], firstU = (first >= 'a' && first <= 'z') ? first - 32 : first;
    for (NSUInteger i = 0; i + nn <= hn; i++) {
        uint8_t c = h[i];
        if (c != first && c != firstU) continue;
        NSUInteger k = 1;
        for (; k < nn; k++) {
            uint8_t a = h[i + k];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (a != n[k]) break;
        }
        if (k == nn) return h + i;
    }
    return NULL;
}

- (void)runBuiltin:(NSString *)query root:(NSString *)root cs:(BOOL)cs hidden:(BOOL)hidden
               gen:(NSUInteger)gen batch:(void (^)(NSArray *, NSUInteger))batch done:(void (^)(BOOL))done {
    NSMutableData *needle = [[query dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (!cs) { uint8_t *p = needle.mutableBytes; for (NSUInteger i = 0; i < needle.length; i++) if (p[i] >= 'A' && p[i] <= 'Z') p[i] += 32; }
    NSUInteger maxHits = self.maxHits;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSUInteger total = 0, files = 0;
        __block BOOL truncated = NO;
        __block CFAbsoluteTime tick = CFAbsoluteTimeGetCurrent();
        NSMutableArray *pending = [NSMutableArray array];
        const uint8_t *nb = needle.bytes;
        NSUInteger nn = needle.length;
        FWWalk(root, hidden, ^BOOL(NSString *rel, const char *abs) {
            if (self.generation != gen) return NO;
            files++;
            int fd = open(abs, O_RDONLY);
            if (fd < 0) return YES;
            struct stat st;
            if (fstat(fd, &st) != 0 || st.st_size == 0 || (NSUInteger)st.st_size > kMaxFileBytes) { close(fd); return YES; }
            NSUInteger len = (NSUInteger)st.st_size;
            const uint8_t *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
            close(fd);
            if (m == MAP_FAILED) return YES;
            if (!memchr(m, 0, MIN(len, (NSUInteger)8192))) {
                NSString *path = [root stringByAppendingPathComponent:rel];
                NSUInteger pos = 0, lineNo = 1, counted = 0, inFile = 0;
                const uint8_t *hit;
                while (pos < len && (hit = findBytes(m + pos, len - pos, nb, nn, cs))) {
                    NSUInteger off = hit - m;
                    for (NSUInteger i = counted; i < off; i++) if (m[i] == '\n') lineNo++;
                    counted = off;
                    NSUInteger ls = off;
                    while (ls > 0 && m[ls - 1] != '\n') ls--;
                    const uint8_t *nl = memchr(m + off, '\n', len - off);
                    NSUInteger le = nl ? (NSUInteger)(nl - m) : len;
                    [pending addObject:makeHit(path, lineNo, m + ls, le - ls, off - ls, nn)];
                    total++; inFile++;
                    pos = le + 1;                         // one hit per line, like rg
                    if (total >= maxHits) { truncated = YES; break; }
                    if (inFile >= kMaxHitsPerFile) break;
                }
            }
            munmap((void *)m, len);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - tick > 0.1 || pending.count >= 200) { batch([pending copy], files); [pending removeAllObjects]; tick = now; }
            return !truncated;
        });
        batch([pending copy], files);
        done(truncated);
    });
}

@end

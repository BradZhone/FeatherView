#import "WorkspaceSearch.h"
#import "Localization.h"
#import "FileWalker.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const NSUInteger kMaxFileBytes = 16u << 20;
static const NSUInteger kMaxHitsPerFile = 200;
static const NSUInteger kPreviewBytes = 160;
static const NSUInteger kMaxLineBytes = 4096;           // a preview shows at most this much of a line
static const NSUInteger kMaxScanLine = 1u << 20;         // the built-in regex scan looks this far into a line
static const NSTimeInterval kRegexBudget = 2;            // per line: a pathological regex gives up, not hangs

@implementation SearchHit @end

@implementation SearchOptions
- (instancetype)init { if ((self = [super init])) _respectGitignore = YES; return self; }
- (id)copyWithZone:(NSZone *)z {
    SearchOptions *o = [SearchOptions new];
    o.caseSensitive = _caseSensitive; o.wholeWord = _wholeWord; o.regex = _regex; o.includeHidden = _includeHidden; o.filter = _filter;
    o.respectGitignore = _respectGitignore;
    return o;
}
- (NSRegularExpression *)matcherFor:(NSString *)q error:(NSString **)error {
    if (!q.length) return nil;
    NSString *p = _regex ? q : [NSRegularExpression escapedPatternForString:q];
    if (_wholeWord) p = [NSString stringWithFormat:@"(?<![\\p{L}\\p{N}_])(?:%@)(?![\\p{L}\\p{N}_])", p];
    NSError *e = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p
        options:_caseSensitive ? 0 : NSRegularExpressionCaseInsensitive error:&e];
    if (!re && error) *error = FTL(@"Invalid regular expression");
    return re;
}
@end

// Matches with a time limit, checked while ICU is still matching (catastrophic backtracking).
static NSArray<NSValue *> *boundedMatches(NSRegularExpression *re, NSString *s, NSRange r, NSUInteger limit, BOOL (^cancelled)(void)) {
    if (!re || !s.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [re enumerateMatchesInString:s options:NSMatchingReportProgress range:r usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m && m.range.length) [out addObject:[NSValue valueWithRange:m.range]];
        if (out.count >= limit || CFAbsoluteTimeGetCurrent() - t0 > kRegexBudget || (cancelled && cancelled())) *stop = YES;
    }];
    return out;
}

NSArray<NSValue *> *WSMatches(NSRegularExpression *re, NSString *s, NSUInteger limit) {
    return boundedMatches(re, s, NSMakeRange(0, s.length), limit, nil);
}

static NSString *decode(const uint8_t *p, NSUInteger n) {
    if (!n) return @"";
    return [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:p length:n encoding:NSISOLatin1StringEncoding];
}

static NSUInteger backToBoundary(const uint8_t *p, NSUInteger i, NSUInteger lo) {
    while (i > lo && (p[i] & 0xC0) == 0x80) i--;
    return i;
}

// UTF-8 byte length of the first `chars` UTF-16 units of s.
static NSUInteger bytesOfPrefix(NSString *s, NSUInteger chars) {
    return [[s substringToIndex:MIN(chars, s.length)] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}

// Builds a hit from one line (no trailing newline) and a match at byte offset m of mlen bytes.
// For a long line, `line` may start part-way in: base is its byte offset in the real line.
static SearchHit *makeHitAt(NSString *path, NSUInteger lineNo, NSUInteger base, const uint8_t *line, NSUInteger len,
                            NSUInteger m, NSUInteger mlen, NSRegularExpression *re) {
    SearchHit *h = [SearchHit new];
    h.path = path; h.line = lineNo; h.column = base + m + 1; h.matchBytes = mlen;
    while (len && (line[len - 1] == '\r' || line[len - 1] == '\n')) len--;
    m = MIN(m, len); mlen = MIN(mlen, len - m);
    NSUInteger s = 0;
    while (s < m && (line[s] == ' ' || line[s] == '\t')) s++;
    BOOL clipped = NO;
    if (m > s + 40) { s = backToBoundary(line, m - 30, s); clipped = YES; }
    NSUInteger e = MIN(len, MAX(s + kPreviewBytes, m + mlen));
    if (e < len) e = backToBoundary(line, e, s);
    NSString *lead = clipped ? @"…" : @"";
    h.preview = [lead stringByAppendingString:decode(line + s, e - s)];
    NSArray *all = WSMatches(re, h.preview, 50);
    if (!all.count && m >= s && m + mlen <= e) {                       // the matcher disagrees (e.g. rg-only regex syntax)
        NSUInteger a = decode(line + s, m - s).length, b = decode(line + m, mlen).length;
        if (b) all = @[[NSValue valueWithRange:NSMakeRange(lead.length + a, b)]];
    }
    h.previewMatches = all;
    h.previewMatch = all.count ? [all[0] rangeValue] : NSMakeRange(NSNotFound, 0);
    return h;
}

// A hit on a line of any length: the preview comes from a window around the match.
static SearchHit *makeHit(NSString *path, NSUInteger lineNo, const uint8_t *line, NSUInteger len,
                          NSUInteger m, NSUInteger mlen, NSRegularExpression *re) {
    NSUInteger base = 0;
    if (len > kMaxLineBytes && m + mlen > kMaxLineBytes - 64) {
        base = backToBoundary(line, m > 64 ? m - 64 : 0, 0);
        NSUInteger end = MIN(len, base + kMaxLineBytes);
        if (end < len) end = backToBoundary(line, end, base);
        return makeHitAt(path, lineNo, base, line + base, end - base, m - base, MIN(mlen, end - m), re);
    }
    return makeHitAt(path, lineNo, 0, line, MIN(len, kMaxLineBytes), m, mlen, re);
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
    SearchOptions *o = [SearchOptions new];
    o.caseSensitive = cs; o.includeHidden = hidden;
    [self search:query root:root options:o onBatch:onBatch onDone:onDone];
}

- (void)search:(NSString *)query root:(NSString *)root options:(SearchOptions *)options
       onBatch:(void (^)(NSArray<SearchHit *> *, NSUInteger))onBatch onDone:(void (^)(BOOL))onDone {
    [self cancel];
    NSUInteger gen = self.generation;
    NSRegularExpression *re = [options matcherFor:query error:NULL];
    if (!query.length || !re) { onDone(NO); return; }
    void (^batch)(NSArray *, NSUInteger) = ^(NSArray *hits, NSUInteger files) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.generation == gen) onBatch(hits, files); });
    };
    void (^done)(BOOL) = ^(BOOL truncated) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.generation == gen) onDone(truncated); });
    };
    NSString *rg = self.disableRipgrep ? nil : [WorkspaceSearch ripgrepPath];
    _usedRipgrep = rg != nil;
    SearchOptions *o = [options copy];
    if (rg) [self runRipgrep:rg query:query root:root options:o matcher:re gen:gen batch:batch done:done];
    else [self runBuiltin:query root:root options:o matcher:re gen:gen batch:batch done:done];
}

#pragma mark ripgrep

// Byte length of the match that starts at byte `col0` of the line (rg reports where, not how long).
static NSUInteger matchLength(NSRegularExpression *re, const uint8_t *text, NSUInteger tlen, NSUInteger col0, NSUInteger fallback) {
    NSString *line = decode(text, tlen);
    NSUInteger at = decode(text, MIN(col0, tlen)).length;
    if (at > line.length) return fallback;
    NSArray<NSValue *> *ms = boundedMatches(re, line, NSMakeRange(at, line.length - at), 1, nil);
    if (!ms.count || ms[0].rangeValue.location != at) return fallback;
    return bytesOfPrefix(line, NSMaxRange(ms[0].rangeValue)) - bytesOfPrefix(line, at);
}

- (void)runRipgrep:(NSString *)rg query:(NSString *)query root:(NSString *)root options:(SearchOptions *)o
           matcher:(NSRegularExpression *)re gen:(NSUInteger)gen batch:(void (^)(NSArray *, NSUInteger))batch done:(void (^)(BOOL))done {
    // --no-config: a user's RIPGREP_CONFIG_PATH must not change the output format. No --max-columns: a
    // long line is replaced by "[Omitted long line]", which loses the match; makeHit windows it instead.
    NSMutableArray *args = [@[@"--no-config", @"--null", @"--line-number", @"--column", @"--no-heading", @"--color", @"never",
                              @"--max-count", [NSString stringWithFormat:@"%lu", (unsigned long)kMaxHitsPerFile],
                              @"--max-filesize", @"16M", o.caseSensitive ? @"--case-sensitive" : @"--ignore-case"] mutableCopy];
    if (!o.regex) [args addObject:@"--fixed-strings"];
    if (o.wholeWord) [args addObject:@"--word-regexp"];
    if (o.includeHidden) [args addObject:@"--hidden"];
    if (!o.respectGitignore) [args addObject:@"--no-ignore-vcs"];
    for (NSString *d in FWSkippedDirs()) [args addObjectsFromArray:@[@"--glob", [NSString stringWithFormat:@"!%@/", d]]];
    for (NSString *h in FWAlwaysHidden()) [args addObjectsFromArray:@[@"--iglob", [@"!" stringByAppendingString:h]]];
    if ([root isEqualToString:NSHomeDirectory()]) [args addObjectsFromArray:@[@"--glob", @"!/Library/"]];
    if (o.filter) [args addObjectsFromArray:o.filter.ripgrepArguments];
    [args addObjectsFromArray:@[@"--regexp", query, @"--", root]];

    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:rg];
    t.arguments = args;
    t.currentDirectoryURL = [NSURL fileURLWithPath:root];
    NSPipe *out = [NSPipe pipe], *errPipe = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = errPipe;
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) {
        _usedRipgrep = NO;
        [self runBuiltin:query root:root options:o matcher:re gen:gen batch:batch done:done];
        return;
    }
    self.task = t;
    NSUInteger qBytes = o.regex ? 0 : [query lengthOfBytesUsingEncoding:NSUTF8StringEncoding], maxHits = self.maxHits;
    NSUInteger rootLen = root.length + ([root hasSuffix:@"/"] ? 0 : 1);
    FWPathFilter *filter = o.filter;
    BOOL dropHidden = !o.includeHidden;              // an include type lets rg list dot files; drop them here
    NSFileHandle *fh = out.fileHandleForReading;
    __block NSData *stderrData = nil;
    dispatch_group_t errRead = dispatch_group_create();
    dispatch_group_async(errRead, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{   // so a full stderr pipe can't stall rg
        stderrData = [errPipe.fileHandleForReading readDataToEndOfFile];
    });
    _lastError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buf = [NSMutableData data];
        NSMutableArray *pending = [NSMutableArray array];
        NSUInteger total = 0;
        BOOL truncated = NO;
        NSData *lastRaw = nil; NSString *lastPath = nil; BOOL lastAllowed = YES;
        CFAbsoluteTime tick = CFAbsoluteTimeGetCurrent();
        while (self.generation == gen && !truncated) {
            NSData *chunk = fh.availableData;
            if (!chunk.length) break;
            [buf appendData:chunk];
            const uint8_t *b = buf.bytes;
            NSUInteger start = 0, n = buf.length;
            for (NSUInteger i = 0; i < n; i++) {
                if (b[i] != '\n') continue;
                const uint8_t *p = b + start, *end = b + i;
                start = i + 1;
                const uint8_t *z = memchr(p, 0, end - p);              // "<path>\0<line>:<col>:<text>"
                if (!z) continue;
                NSUInteger plen = z - p;
                if (!lastRaw || lastRaw.length != plen || memcmp(lastRaw.bytes, p, plen)) {
                    lastRaw = [NSData dataWithBytes:p length:plen];
                    lastPath = [NSFileManager.defaultManager stringWithFileSystemRepresentation:(const char *)p length:plen];
                    NSString *rel = [lastPath hasPrefix:root] ? [lastPath substringFromIndex:MIN(rootLen, lastPath.length)] : nil;
                    lastAllowed = rel && (!filter || [filter allowsFile:rel]) &&
                                  !(dropHidden && ([rel hasPrefix:@"."] || [rel containsString:@"/."]));
                }
                if (!lastAllowed) continue;
                const uint8_t *q = z + 1;
                NSUInteger line = 0, col = 0;
                while (q < end && *q >= '0' && *q <= '9') line = line * 10 + (*q++ - '0');
                if (q >= end || *q++ != ':') continue;
                while (q < end && *q >= '0' && *q <= '9') col = col * 10 + (*q++ - '0');
                if (q >= end || *q++ != ':' || !line || !col) continue;
                NSUInteger tlen = (NSUInteger)(end - q), c0 = MIN(col - 1, tlen);
                NSUInteger mlen = matchLength(re, q, tlen, c0, qBytes);
                [pending addObject:makeHit(lastPath, line, q, tlen, c0, mlen, re)];
                if (++total >= maxHits) { truncated = YES; break; }
            }
            [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (pending.count && (now - tick > 0.1 || pending.count >= 200)) {
                batch([pending copy], 0); [pending removeAllObjects]; tick = now;
            }
        }
        BOOL stopped = self.generation != gen || truncated;
        if (t.isRunning) [t terminate];
        [t waitUntilExit];
        dispatch_group_wait(errRead, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (pending.count) batch([pending copy], 0);
        // exit 2 with nothing found: rg itself failed (a regex it can't parse), not "no results".
        // Per-file errors (permissions) also exit 2 but start with a path.
        NSString *msg = [[NSString alloc] initWithData:stderrData ?: NSData.data encoding:NSUTF8StringEncoding] ?: @"";
        msg = [msg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!stopped && !total && t.terminationStatus == 2 && msg.length && ![msg hasPrefix:root] && ![msg hasPrefix:@"rg: /"]) {
            if (o.regex && [msg containsString:@"regex"]) {           // e.g. lookaround: the built-in scanner supports it
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.generation != gen) return;
                    self->_usedRipgrep = NO;
                    [self runBuiltin:query root:root options:o matcher:re gen:gen batch:batch done:done];
                });
                return;
            }
            NSString *first = [msg componentsSeparatedByString:@"\n"].lastObject;
            self->_lastError = [FTL(@"ripgrep: ") stringByAppendingString:[first substringToIndex:MIN(first.length, (NSUInteger)200)]];
        }
        done(truncated);
    });
}

#pragma mark Built-in scanner

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

- (void)runBuiltin:(NSString *)query root:(NSString *)root options:(SearchOptions *)o
           matcher:(NSRegularExpression *)re gen:(NSUInteger)gen batch:(void (^)(NSArray *, NSUInteger))batch done:(void (^)(BOOL))done {
    NSMutableData *needle = [[query dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    BOOL ascii = YES;
    for (NSUInteger i = 0; i < needle.length; i++) if (((uint8_t *)needle.mutableBytes)[i] >= 0x80) ascii = NO;
    if (!o.caseSensitive) { uint8_t *p = needle.mutableBytes; for (NSUInteger i = 0; i < needle.length; i++) if (p[i] >= 'A' && p[i] <= 'Z') p[i] += 32; }
    // plain text is found with a byte scan; regex, whole word and non-ASCII case folding go line by line
    BOOL fast = !o.regex && !o.wholeWord && (o.caseSensitive || ascii);
    BOOL prefilter = !o.regex && (o.caseSensitive || ascii);                // the text must appear somewhere in the file
    NSUInteger maxHits = self.maxHits;
    _lastError = nil;
    BOOL (^cancelled)(void) = ^BOOL { return self.generation != gen; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSUInteger total = 0, files = 0;
        __block BOOL truncated = NO;
        __block CFAbsoluteTime tick = CFAbsoluteTimeGetCurrent();
        NSMutableArray *pending = [NSMutableArray array];
        const uint8_t *nb = needle.bytes;
        NSUInteger nn = needle.length;
        FWWalkFiltered(root, o.includeHidden, o.filter, ^BOOL(NSString *rel, const char *abs) {
            if (self.generation != gen) return NO;
            if (o.filter && ![o.filter allowsFile:rel]) return YES;
            files++;
            int fd = open(abs, O_RDONLY);
            if (fd < 0) return YES;
            struct stat st;
            if (fstat(fd, &st) != 0 || st.st_size == 0 || (NSUInteger)st.st_size > kMaxFileBytes) { close(fd); return YES; }
            NSUInteger len = (NSUInteger)st.st_size;
            const uint8_t *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
            close(fd);
            if (m == MAP_FAILED) return YES;
            if (!memchr(m, 0, MIN(len, (NSUInteger)8192)) && (!prefilter || findBytes(m, len, nb, nn, o.caseSensitive))) {
                NSString *path = [root stringByAppendingPathComponent:rel];
                NSUInteger inFile = 0;
                if (fast) {
                    NSUInteger pos = 0, lineNo = 1, counted = 0;
                    const uint8_t *hit;
                    while (pos < len && (hit = findBytes(m + pos, len - pos, nb, nn, o.caseSensitive))) {
                        NSUInteger off = hit - m;
                        for (NSUInteger i = counted; i < off; i++) if (m[i] == '\n') lineNo++;
                        counted = off;
                        NSUInteger ls = off;
                        while (ls > 0 && m[ls - 1] != '\n') ls--;
                        const uint8_t *nl = memchr(m + off, '\n', len - off);
                        NSUInteger le = nl ? (NSUInteger)(nl - m) : len;
                        [pending addObject:makeHit(path, lineNo, m + ls, le - ls, off - ls, nn, re)];
                        total++; inFile++;
                        pos = le + 1;                                         // one hit per line, like rg
                        if (total >= maxHits) { truncated = YES; break; }
                        if (inFile >= kMaxHitsPerFile) break;
                    }
                } else {
                    NSUInteger ls = 0, lineNo = 1;
                    while (ls < len) {
                        const uint8_t *nl = memchr(m + ls, '\n', len - ls);
                        NSUInteger le = nl ? (NSUInteger)(nl - m) : len, ll = MIN(le - ls, kMaxScanLine);
                        if (ll < le - ls) ll = backToBoundary(m + ls, ll, 0);
                        NSString *s = decode(m + ls, ll);
                        NSArray<NSValue *> *r = boundedMatches(re, s, NSMakeRange(0, s.length), 1, cancelled);
                        if (cancelled()) break;
                        if (r.count) {
                            NSRange mr = r[0].rangeValue;
                            NSUInteger b0 = bytesOfPrefix(s, mr.location), b1 = bytesOfPrefix(s, NSMaxRange(mr));
                            [pending addObject:makeHit(path, lineNo, m + ls, ll, b0, b1 - b0, re)];
                            total++; inFile++;
                            if (total >= maxHits) { truncated = YES; break; }
                            if (inFile >= kMaxHitsPerFile) break;
                        }
                        ls = le + 1; lineNo++;
                    }
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

#import "FileWalker.h"
#include <fts.h>
#include <sys/stat.h>

const NSInteger FWNoMatch = NSIntegerMin;
static const NSUInteger kMaxFiles = 300000;

#include <fnmatch.h>

// Both lists are set from the settings window; walks run on background queues, so they swap under a lock.
static NSLock *gListLock;
static NSSet<NSString *> *gSkipped;
static NSArray<NSString *> *gHidden;

static void ensureLists(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gListLock = [NSLock new];
        gSkipped = [NSSet setWithArray:FWDefaultSearchSkipped()];
        gHidden = FWDefaultAlwaysHidden();
    });
}

NSArray<NSString *> *FWDefaultSearchSkipped(void) {
    return @[@"node_modules", @".build", @"build", @"DerivedData", @"Pods", @".venv", @"venv", @"__pycache__",
             @"target", @".gradle", @".idea", @".next", @"dist", @".cache"];
}
NSArray<NSString *> *FWDefaultAlwaysHidden(void) { return @[@".git", @".hg", @".svn", @".DS_Store", @".Trash"]; }

NSSet<NSString *> *FWSkippedDirs(void) {
    ensureLists();
    [gListLock lock];
    NSSet *s = gSkipped;
    [gListLock unlock];
    return s;
}
NSArray<NSString *> *FWAlwaysHidden(void) {
    ensureLists();
    [gListLock lock];
    NSArray *a = gHidden;
    [gListLock unlock];
    return a;
}
void FWSetSearchSkipped(NSArray<NSString *> *names) {
    ensureLists();
    [gListLock lock];
    gSkipped = [NSSet setWithArray:names ?: @[]];
    [gListLock unlock];
}
void FWSetAlwaysHidden(NSArray<NSString *> *patterns) {
    ensureLists();
    [gListLock lock];
    gHidden = [patterns copy] ?: @[];
    [gListLock unlock];
}

// Exact names, or globs such as *.pyc, against the base name (case-insensitive).
static BOOL hiddenBy(NSArray<NSString *> *patterns, const char *name) {
    for (NSString *p in patterns) if (fnmatch(p.fileSystemRepresentation, name, FNM_CASEFOLD) == 0) return YES;
    return NO;
}
BOOL FWIsAlwaysHidden(NSString *name) { return name.length && hiddenBy(FWAlwaysHidden(), name.fileSystemRepresentation); }

void FWWalk(NSString *root, BOOL includeHidden, BOOL (^visit)(NSString *rel, const char *abs)) {
    FWWalkFiltered(root, includeHidden, nil, visit);
}

void FWWalkFiltered(NSString *root, BOOL includeHidden, FWPathFilter *filter, BOOL (^visit)(NSString *rel, const char *abs)) {
    char *rootC = strdup(root.fileSystemRepresentation);
    size_t rootLen = strlen(rootC);
    while (rootLen > 1 && rootC[rootLen - 1] == '/') rootC[--rootLen] = 0;
    char *argv[] = {rootC, NULL};
    FTS *fts = fts_open(argv, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, NULL);      // a symlinked workspace folder is followed
    if (!fts) { free(rootC); return; }
    NSSet *skip = FWSkippedDirs();
    NSArray *never = FWAlwaysHidden();
    NSFileManager *fm = NSFileManager.defaultManager;
    FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_level == 0) continue;
        BOOL hidden = e->fts_name[0] == '.' || (e->fts_statp && (e->fts_statp->st_flags & UF_HIDDEN));
        if (hiddenBy(never, e->fts_name)) { if (e->fts_info == FTS_D) fts_set(fts, e, FTS_SKIP); continue; }
        if (e->fts_info == FTS_D) {
            NSString *name = [fm stringWithFileSystemRepresentation:e->fts_name length:e->fts_namelen];
            if ((hidden && !includeHidden) || [skip containsObject:name]) { fts_set(fts, e, FTS_SKIP); continue; }
            if (filter) {
                const char *relC = e->fts_path + rootLen + 1;
                if ([filter prunesDirectory:[fm stringWithFileSystemRepresentation:relC length:strlen(relC)]]) fts_set(fts, e, FTS_SKIP);
            }
            continue;
        }
        if (e->fts_info != FTS_F || (hidden && !includeHidden)) continue;
        const char *relC = e->fts_path + rootLen + 1;
        NSString *rel = [fm stringWithFileSystemRepresentation:relC length:strlen(relC)];
        if (!visit(rel, e->fts_path)) break;
    }
    fts_close(fts);
    free(rootC);
}

static inline unichar fold(unichar c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

// Scores a subsequence match of q (already folded) in s[from..n).
static NSInteger scoreRange(const unichar *q, NSUInteger qn, const unichar *s, NSUInteger from, NSUInteger n) {
    NSInteger score = 0;
    NSUInteger qi = 0, last = NSNotFound;
    for (NSUInteger i = from; i < n && qi < qn; i++) {
        if (fold(s[i]) != q[qi]) continue;
        NSInteger b = 1;
        if (last != NSNotFound && i == last + 1) b += 5;                     // consecutive
        unichar prev = i > from ? s[i - 1] : '/';
        if (i == from || prev == '/' || prev == '_' || prev == '-' || prev == '.' || prev == ' ') b += 8;
        else if (s[i] >= 'A' && s[i] <= 'Z' && !(prev >= 'A' && prev <= 'Z')) b += 6;   // camelCase hump
        score += b;
        last = i;
        qi++;
    }
    return qi == qn ? score : FWNoMatch;
}

NSInteger FWFuzzyScore(NSString *query, NSString *path) {
    NSString *qs = [query stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSUInteger qn = qs.length, n = path.length;
    if (!qn) return 0;
    if (qn > n) return FWNoMatch;
    unichar qb[128], sb[1024];
    if (qn > 128 || n > 1024) return FWNoMatch;
    [qs getCharacters:qb range:NSMakeRange(0, qn)];
    for (NSUInteger i = 0; i < qn; i++) qb[i] = fold(qb[i]);
    [path getCharacters:sb range:NSMakeRange(0, n)];

    NSUInteger nameStart = 0;
    for (NSUInteger i = n; i > 0; i--) if (sb[i - 1] == '/') { nameStart = i; break; }
    NSInteger s = scoreRange(qb, qn, sb, nameStart, n);
    if (s != FWNoMatch) {
        s += 100;
        if (n - nameStart == qn) s += 50;                                       // whole name
        else if (fold(sb[nameStart]) == qb[0]) s += 10;                         // name prefix
    } else {
        s = scoreRange(qb, qn, sb, 0, n);
        if (s == FWNoMatch) return FWNoMatch;
    }
    return s * 1000 - (NSInteger)n;                                             // shorter paths win ties
}

typedef struct { NSInteger score; NSUInteger idx, len; } Ranked;

static int cmpRanked(const void *a, const void *b) {
    const Ranked *x = a, *y = b;
    if (x->score != y->score) return x->score > y->score ? -1 : 1;
    if (x->len != y->len) return x->len < y->len ? -1 : 1;
    return x->idx < y->idx ? -1 : (x->idx > y->idx);
}

NSArray<NSNumber *> *FWRank(NSString *query, NSArray<NSString *> *paths, NSUInteger limit) {
    NSUInteger n = paths.count;
    Ranked *r = malloc(MAX(n, (NSUInteger)1) * sizeof(Ranked));
    NSUInteger m = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *p = paths[i];
        NSInteger s = FWFuzzyScore(query, p);
        if (s != FWNoMatch) r[m++] = (Ranked){s, i, p.length};
    }
    qsort(r, m, sizeof(Ranked), cmpRanked);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:MIN(m, limit)];
    for (NSUInteger i = 0; i < MIN(m, limit); i++) [out addObject:@(r[i].idx)];
    free(r);
    return out;
}

#pragma mark Path filter

// "*.ts" → ^[^/]*\.ts$ ; "**/x" matches at any depth ; {ts,tsx} alternatives. Case-insensitive.
static NSRegularExpression *globRegex(NSString *g) {
    NSMutableString *r = [NSMutableString stringWithString:@"^"];
    NSUInteger n = g.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [g characterAtIndex:i];
        if (c == '*' && i + 1 < n && [g characterAtIndex:i + 1] == '*') {
            if (i + 2 < n && [g characterAtIndex:i + 2] == '/') { [r appendString:@"(?:.*/)?"]; i += 2; }
            else { [r appendString:@".*"]; i += 1; }
        } else if (c == '*') [r appendString:@"[^/]*"];
        else if (c == '?') [r appendString:@"[^/]"];
        else if (c == '{') [r appendString:@"(?:"];
        else if (c == '}') [r appendString:@")"];
        else if (c == ',') [r appendString:@"|"];
        else [r appendString:[NSRegularExpression escapedPatternForString:[NSString stringWithCharacters:&c length:1]]];
    }
    [r appendString:@"$"];
    return [NSRegularExpression regularExpressionWithPattern:r options:NSRegularExpressionCaseInsensitive error:nil];
}

static BOOL matches(NSRegularExpression *re, NSString *s) {
    return re && [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

static BOOL hasGlob(NSString *s) { return [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?{"]].location != NSNotFound; }
BOOL FWQueryIsGlob(NSString *q) { return [q rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"*?"]].location != NSNotFound; }

typedef NS_ENUM(NSInteger, FTokKind) { FTokWord, FTokDotExt, FTokName, FTokPrefix, FTokCompGlob, FTokPathGlob };

@interface FWFilterToken : NSObject
@property (nonatomic) FTokKind kind;
@property (nonatomic) BOOL exclude;
@property (nonatomic, copy) NSString *text;                 // lower-cased
@property (nonatomic, strong) NSRegularExpression *re;
@end
@implementation FWFilterToken @end

// Splits on commas / whitespace, but not inside {a,b}.
static NSArray<NSString *> *splitTokens(NSString *s) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    NSInteger depth = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '{') depth++;
        if (c == '}' && depth > 0) depth--;
        if (depth == 0 && (c == ',' || c == ' ' || c == '\t' || c == '\n' || c == 0xFF0C)) {   // also the full-width comma
            if (cur.length) [out addObject:[cur copy]];
            [cur setString:@""];
            continue;
        }
        [cur appendFormat:@"%C", c];
    }
    if (cur.length) [out addObject:cur];
    return out;
}

@implementation FWPathFilter {
    NSArray<FWFilterToken *> *_tokens;
}

+ (instancetype)filterWithString:(NSString *)s {
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *raw in splitTokens(s ?: @"")) {
        NSString *t = raw;
        BOOL ex = [t hasPrefix:@"!"] || [t hasPrefix:@"-"];
        if (ex) t = [t substringFromIndex:1];
        while ([t hasPrefix:@"./"]) t = [t substringFromIndex:2];
        if ([t hasPrefix:@"/"]) t = [t substringFromIndex:1];
        while ([t hasSuffix:@"/"]) t = [t substringToIndex:t.length - 1];
        if (!t.length) continue;
        FWFilterToken *k = [FWFilterToken new];
        k.exclude = ex;
        k.text = t.lowercaseString;
        BOOL slash = [t rangeOfString:@"/"].location != NSNotFound;
        if (hasGlob(t)) { k.kind = slash ? FTokPathGlob : FTokCompGlob; k.re = globRegex(t); if (!k.re) continue; }
        else if (slash) k.kind = FTokPrefix;
        else if ([t hasPrefix:@"."] && t.length > 1 && [[t substringFromIndex:1] rangeOfString:@"."].location == NSNotFound) k.kind = FTokDotExt;
        else if ([t rangeOfString:@"."].location != NSNotFound) k.kind = FTokName;
        else k.kind = FTokWord;
        [tokens addObject:k];
    }
    if (!tokens.count) return nil;
    FWPathFilter *f = [FWPathFilter new];
    f->_tokens = tokens;
    for (FWFilterToken *k in tokens) if (!k.exclude) f->_hasIncludes = YES;
    return f;
}

static BOOL tokenMatches(FWFilterToken *k, NSString *rel, NSArray<NSString *> *comps, NSString *ext) {
    switch (k.kind) {
        case FTokWord:
            if ([ext isEqualToString:k.text]) return YES;
            for (NSString *c in comps) if ([c caseInsensitiveCompare:k.text] == NSOrderedSame) return YES;
            return NO;
        case FTokDotExt:
            return [ext isEqualToString:[k.text substringFromIndex:1]] || [comps.lastObject caseInsensitiveCompare:k.text] == NSOrderedSame;
        case FTokName:
            for (NSString *c in comps) if ([c caseInsensitiveCompare:k.text] == NSOrderedSame) return YES;
            return NO;
        case FTokPrefix: {
            NSString *l = rel.lowercaseString;
            return [l isEqualToString:k.text] || [l hasPrefix:[k.text stringByAppendingString:@"/"]];
        }
        case FTokCompGlob:
            for (NSString *c in comps) if (matches(k.re, c)) return YES;
            return NO;
        case FTokPathGlob:
            return matches(k.re, rel);
    }
    return NO;
}

- (BOOL)allowsFile:(NSString *)rel {
    NSArray *comps = [rel componentsSeparatedByString:@"/"];
    NSString *ext = [comps.lastObject pathExtension].lowercaseString;
    BOOL included = !_hasIncludes;
    for (FWFilterToken *k in _tokens) {
        if (k.exclude) { if (tokenMatches(k, rel, comps, ext)) return NO; }
        else if (!included && tokenMatches(k, rel, comps, ext)) included = YES;
    }
    return included;
}

- (BOOL)prunesDirectory:(NSString *)rel {
    NSString *name = rel.lastPathComponent;
    for (FWFilterToken *k in _tokens) {
        if (!k.exclude) continue;
        switch (k.kind) {
            case FTokWord: case FTokName:
                if ([name caseInsensitiveCompare:k.text] == NSOrderedSame) return YES;
                break;
            case FTokCompGlob:
                if (matches(k.re, name)) return YES;
                break;
            case FTokPrefix: {
                NSString *l = rel.lowercaseString;
                if ([l isEqualToString:k.text] || [l hasPrefix:[k.text stringByAppendingString:@"/"]]) return YES;
                break;
            }
            case FTokPathGlob:
                if ([k.text hasSuffix:@"/**"] && matches(globRegex([k.text substringToIndex:k.text.length - 3]), rel)) return YES;
                break;
            case FTokDotExt: break;
        }
    }
    return NO;
}

// What rg can apply itself without changing which files it may see. An include glob would override
// .gitignore and hidden-file rules, so includes are only passed when they are all extensions, as a file
// type (types respect ignore files); everything else is checked on rg's output.
static NSString *caseless(NSString *t) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) [out appendFormat:@"[%C%C]", (unichar)(c | 32), (unichar)(c & ~32)];
        else if ((c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == '+') [out appendFormat:@"%C", c];
        else return nil;
    }
    return out;
}

- (NSArray<NSString *> *)ripgrepArguments {
    NSMutableArray *args = [NSMutableArray array], *types = [NSMutableArray array];
    BOOL onlyExtensions = YES;
    for (FWFilterToken *k in _tokens) {
        if (!k.exclude) {
            NSString *g = k.kind == FTokDotExt ? caseless(k.text) : nil;
            if (g) [types addObjectsFromArray:@[@"--type-add", [@"fvinclude:*" stringByAppendingString:g]]];
            else onlyExtensions = NO;
            continue;
        }
        NSMutableArray *globs = [NSMutableArray array];
        switch (k.kind) {
            case FTokWord: case FTokName: case FTokCompGlob: [globs addObject:k.text]; break;
            case FTokDotExt: [globs addObject:[@"*" stringByAppendingString:k.text]]; break;
            case FTokPrefix: case FTokPathGlob: break;
        }
        for (NSString *g in globs) [args addObjectsFromArray:@[@"--iglob", [@"!" stringByAppendingString:g]]];
    }
    if (onlyExtensions && types.count) { [args addObjectsFromArray:types]; [args addObjectsFromArray:@[@"--type", @"fvinclude"]]; }
    return args;
}

@end

#pragma mark File-name search

@interface FWNameMatch () { @public NSUInteger _depth; }
@end
@implementation FWNameMatch @end

static inline BOOL boundaryBefore(NSString *s, NSUInteger i) {
    if (i == 0) return YES;
    unichar p = [s characterAtIndex:i - 1], c = [s characterAtIndex:i];
    return p == '.' || p == '-' || p == '_' || p == ' ' || (c >= 'A' && c <= 'Z' && !(p >= 'A' && p <= 'Z'));
}

// Score of one (lower-case) query word against a path; 0 = no match. *range = the match inside the name.
static NSInteger wordScore(NSString *w, NSRegularExpression *glob, NSString *rel, NSString *name, NSRange *range) {
    *range = NSMakeRange(NSNotFound, 0);
    if (glob) {
        if (!matches(glob, [w rangeOfString:@"/"].location != NSNotFound ? rel : name)) return 0;
        *range = NSMakeRange(0, name.length);
        return 500;
    }
    if ([rel rangeOfString:w options:NSCaseInsensitiveSearch].location == NSNotFound) return 0;   // fast reject
    if ([w rangeOfString:@"/"].location != NSNotFound) {                                           // "src/app.ts"
        if ([rel.lowercaseString hasSuffix:w]) { *range = NSMakeRange(0, name.length); return 900; }
        return 400;
    }
    NSRange r = [name rangeOfString:w options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return 200;                                                       // only a folder matches
    *range = r;
    if (r.length == name.length) return 1000;                                                       // exact name
    if (r.location == 0 && r.length == name.stringByDeletingPathExtension.length) return 950;       // name without extension
    if (r.location == 0) return 800;                                                                // prefix
    if ([w hasPrefix:@"."] && NSMaxRange(r) == name.length) return 750;                             // ".svg" = extension
    return boundaryBefore(name, r.location) ? 650 : 600;                                            // contains
}

NSArray<FWNameMatch *> *FWNameSearch(NSString *query, NSArray<NSString *> *paths, FWPathFilter *filter,
                                     NSUInteger limit, NSUInteger *total) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *w in [query.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (w.length) [words addObject:w];
    if (total) *total = 0;
    if (!words.count) return @[];
    NSMutableArray *globs = [NSMutableArray array];
    for (NSString *w in words) [globs addObject:(FWQueryIsGlob(w) ? globRegex(w) : nil) ?: (id)NSNull.null];
    NSMutableArray<FWNameMatch *> *out = [NSMutableArray array];
    for (NSString *rel in paths) {
        NSRange slash = [rel rangeOfString:@"/" options:NSBackwardsSearch];
        NSString *name = slash.location == NSNotFound ? rel : [rel substringFromIndex:slash.location + 1];
        NSInteger score = 0, best = 0;
        NSRange hl = NSMakeRange(NSNotFound, 0);
        for (NSUInteger i = 0; i < words.count; i++) {
            NSRange r;
            NSInteger s = wordScore(words[i], globs[i] == NSNull.null ? nil : globs[i], rel, name, &r);
            if (!s) { score = 0; break; }
            score += s;
            if (s > best && r.location != NSNotFound) { best = s; hl = r; }
        }
        if (!score || (filter && ![filter allowsFile:rel])) continue;
        FWNameMatch *m = [FWNameMatch new];
        m.rel = rel; m.score = score; m.nameRange = hl;
        for (NSUInteger k = 0; k < rel.length; k++) if ([rel characterAtIndex:k] == '/') m->_depth++;
        [out addObject:m];
    }
    if (total) *total = out.count;
    [out sortUsingComparator:^NSComparisonResult(FWNameMatch *a, FWNameMatch *b) {
        if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
        if (a->_depth != b->_depth) return a->_depth < b->_depth ? NSOrderedAscending : NSOrderedDescending;   // shallower first
        if (a.rel.length != b.rel.length) return a.rel.length < b.rel.length ? NSOrderedAscending : NSOrderedDescending;
        return [a.rel localizedStandardCompare:b.rel];
    }];
    return out.count > limit ? [out subarrayWithRange:NSMakeRange(0, limit)] : out;
}

@implementation FileList {
    NSMutableArray<NSString *> *_paths;
    NSLock *_lock;
    BOOL _hidden;
    volatile BOOL _cancelled;
}

- (instancetype)initWithRoot:(NSString *)root includeHidden:(BOOL)hidden {
    if (!(self = [super init])) return nil;
    _root = [root copy];
    _hidden = hidden;
    _paths = [NSMutableArray array];
    _lock = [NSLock new];
    return self;
}

- (void)cancel { _cancelled = YES; }

- (NSArray<NSString *> *)snapshot {
    [_lock lock];
    NSArray *a = [_paths copy];
    [_lock unlock];
    return a;
}

- (void)startWithProgress:(void (^)(BOOL))progress {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block CFAbsoluteTime lastTick = CFAbsoluteTimeGetCurrent();
        __block NSUInteger count = 0;
        FWWalk(self->_root, self->_hidden, ^BOOL(NSString *rel, const char *abs) {
            [self->_lock lock];
            [self->_paths addObject:rel];
            [self->_lock unlock];
            count++;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastTick > 0.15) {
                lastTick = now;
                dispatch_async(dispatch_get_main_queue(), ^{ progress(NO); });
            }
            return !self->_cancelled && count < kMaxFiles;
        });
        self->_done = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ progress(YES); });
    });
}

@end

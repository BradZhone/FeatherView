#import "FileWalker.h"
#include <fts.h>
#include <sys/stat.h>

const NSInteger FWNoMatch = NSIntegerMin;
static const NSUInteger kMaxFiles = 300000;

NSSet<NSString *> *FWSkippedDirs(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@".git", @".hg", @".svn", @"node_modules", @".build", @"build", @"DerivedData",
                                  @"Pods", @".venv", @"venv", @"__pycache__", @"target", @".gradle", @".idea",
                                  @".next", @"dist", @".cache", @".Trash"]];
    });
    return s;
}

void FWWalk(NSString *root, BOOL includeHidden, BOOL (^visit)(NSString *rel, const char *abs)) {
    char *rootC = strdup(root.fileSystemRepresentation);
    size_t rootLen = strlen(rootC);
    while (rootLen > 1 && rootC[rootLen - 1] == '/') rootC[--rootLen] = 0;
    char *argv[] = {rootC, NULL};
    FTS *fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!fts) { free(rootC); return; }
    NSSet *skip = FWSkippedDirs();
    NSFileManager *fm = NSFileManager.defaultManager;
    FTSENT *e;
    while ((e = fts_read(fts))) {
        if (e->fts_level == 0) continue;
        BOOL hidden = e->fts_name[0] == '.' || (e->fts_statp && (e->fts_statp->st_flags & UF_HIDDEN));
        if (e->fts_info == FTS_D) {
            NSString *name = [fm stringWithFileSystemRepresentation:e->fts_name length:e->fts_namelen];
            if ((hidden && !includeHidden) || [skip containsObject:name]) fts_set(fts, e, FTS_SKIP);
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

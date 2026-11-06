#import <Foundation/Foundation.h>

// Folder names not descended into by quick open / workspace search (configurable; the tree still shows them).
NSSet<NSString *> *FWSkippedDirs(void);
void FWSetSearchSkipped(NSArray<NSString *> *names);
NSArray<NSString *> *FWDefaultSearchSkipped(void);
// Names or globs (*.pyc) hidden everywhere — tree, quick open, search — even when hidden files are shown.
NSArray<NSString *> *FWAlwaysHidden(void);
void FWSetAlwaysHidden(NSArray<NSString *> *patterns);
NSArray<NSString *> *FWDefaultAlwaysHidden(void);
BOOL FWIsAlwaysHidden(NSString *name);

// Calls visit(relativePath, absolutePath) for each regular file under root.
// Return NO from visit to stop. Runs synchronously on the calling thread.
void FWWalk(NSString *root, BOOL includeHidden, BOOL (^visit)(NSString *rel, const char *abs));

// Fuzzy subsequence score of query against a relative path (higher is better).
// Returns FWNoMatch when query is not a subsequence. Matches in the file name rank higher.
extern const NSInteger FWNoMatch;
NSInteger FWFuzzyScore(NSString *query, NSString *path);

// Indices into paths of the best `limit` matches, best first.
NSArray<NSNumber *> *FWRank(NSString *query, NSArray<NSString *> *paths, NSUInteger limit);

// "Files to include / exclude" for workspace search, comma or space separated, "!" excludes:
//   "src, *.ts, !*.test.ts, !vendor"   ts / .ts = extension, src = any folder or file of that name,
//   src/app = path prefix, *.m / **/x = glob (on the name when there is no "/", else on the path).
@interface FWPathFilter : NSObject
+ (instancetype)filterWithString:(NSString *)s;          // nil for an empty string
@property (nonatomic, readonly) BOOL hasIncludes;
- (BOOL)allowsFile:(NSString *)rel;                      // relative path
- (BOOL)prunesDirectory:(NSString *)rel;                 // an excluded folder: skip everything inside
- (NSArray<NSString *> *)ripgrepArguments;               // --glob args rg can apply itself (a superset; results are re-checked)
@end

// Same walk as FWWalk, but folders the filter excludes are not descended into.
void FWWalkFiltered(NSString *root, BOOL includeHidden, FWPathFilter *filter, BOOL (^visit)(NSString *rel, const char *abs));

// File-name search (not fuzzy): exact name > name prefix > extension > name contains > path contains.
// Words separated by spaces must all match; * and ? make it a glob on the name (or the path with "/").
@interface FWNameMatch : NSObject
@property (nonatomic, copy) NSString *rel;
@property (nonatomic) NSInteger score;
@property (nonatomic) NSRange nameRange;                 // matched part of the last path component, for highlighting
@end
NSArray<FWNameMatch *> *FWNameSearch(NSString *query, NSArray<NSString *> *paths, FWPathFilter *filter,
                                     NSUInteger limit, NSUInteger *total);
BOOL FWQueryIsGlob(NSString *query);                     // "*.svg", "Makefile.*": a name pattern, not text to find in files

// Background file list for quick open; grows while scanning.
@interface FileList : NSObject
- (instancetype)initWithRoot:(NSString *)root includeHidden:(BOOL)hidden;
- (void)startWithProgress:(void (^)(BOOL done))progress;   // progress called on main queue
- (NSArray<NSString *> *)snapshot;
- (void)cancel;
@property (atomic, readonly) BOOL done;
@property (nonatomic, readonly) NSString *root;
@end

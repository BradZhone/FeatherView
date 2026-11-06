#import <Foundation/Foundation.h>

// Directory names never descended into by quick open / workspace search.
NSSet<NSString *> *FWSkippedDirs(void);

// Calls visit(relativePath, absolutePath) for each regular file under root.
// Return NO from visit to stop. Runs synchronously on the calling thread.
void FWWalk(NSString *root, BOOL includeHidden, BOOL (^visit)(NSString *rel, const char *abs));

// Fuzzy subsequence score of query against a relative path (higher is better).
// Returns FWNoMatch when query is not a subsequence. Matches in the file name rank higher.
extern const NSInteger FWNoMatch;
NSInteger FWFuzzyScore(NSString *query, NSString *path);

// Indices into paths of the best `limit` matches, best first.
NSArray<NSNumber *> *FWRank(NSString *query, NSArray<NSString *> *paths, NSUInteger limit);

// Background file list for quick open; grows while scanning.
@interface FileList : NSObject
- (instancetype)initWithRoot:(NSString *)root includeHidden:(BOOL)hidden;
- (void)startWithProgress:(void (^)(BOOL done))progress;   // progress called on main queue
- (NSArray<NSString *> *)snapshot;
- (void)cancel;
@property (atomic, readonly) BOOL done;
@property (nonatomic, readonly) NSString *root;
@end

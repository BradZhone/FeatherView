#import <Foundation/Foundation.h>
@class FWPathFilter;

@interface SearchHit : NSObject
@property (nonatomic, copy) NSString *path;      // absolute
@property (nonatomic) NSUInteger line;           // 1-based
@property (nonatomic) NSUInteger column;         // 1-based byte column
@property (nonatomic) NSUInteger matchBytes;     // match length in bytes (0 if unknown)
@property (nonatomic, copy) NSString *preview;   // trimmed line text
@property (nonatomic) NSRange previewMatch;      // first match within preview (UTF-16), may be NSNotFound
@property (nonatomic, copy) NSArray<NSValue *> *previewMatches;   // every match within preview
@end

@interface SearchOptions : NSObject <NSCopying>
@property (nonatomic) BOOL caseSensitive, wholeWord, regex, includeHidden;
@property (nonatomic) BOOL respectGitignore;                  // ripgrep skips files listed in .gitignore (default YES)
@property (nonatomic, strong) FWPathFilter *filter;           // nil = every file
// The matcher used for previews, match lengths and the built-in scanner; nil (and *error) for a bad regex.
- (NSRegularExpression *)matcherFor:(NSString *)query error:(NSString **)error;
@end

// Text search across a directory. Uses ripgrep when installed, otherwise a built-in scanner.
// All callbacks run on the main queue; a new search or -cancel silences the previous one.
@interface WorkspaceSearch : NSObject
@property (nonatomic) NSUInteger maxHits;        // default 2000
@property (nonatomic) BOOL disableRipgrep;       // for tests
@property (nonatomic, readonly) BOOL usedRipgrep;
@property (nonatomic, readonly, copy) NSString *lastError;   // set before onDone when the search itself failed

+ (NSString *)ripgrepPath;
- (void)search:(NSString *)query root:(NSString *)root options:(SearchOptions *)options
       onBatch:(void (^)(NSArray<SearchHit *> *hits, NSUInteger filesScanned))onBatch
        onDone:(void (^)(BOOL truncated))onDone;
- (void)search:(NSString *)query root:(NSString *)root caseSensitive:(BOOL)cs includeHidden:(BOOL)hidden
       onBatch:(void (^)(NSArray<SearchHit *> *hits, NSUInteger filesScanned))onBatch
        onDone:(void (^)(BOOL truncated))onDone;
- (void)cancel;
@end

// All matches of `re` in `s` (UTF-16 ranges), at most `limit`.
NSArray<NSValue *> *WSMatches(NSRegularExpression *re, NSString *s, NSUInteger limit);

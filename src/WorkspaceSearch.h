#import <Foundation/Foundation.h>

@interface SearchHit : NSObject
@property (nonatomic, copy) NSString *path;      // absolute
@property (nonatomic) NSUInteger line;           // 1-based
@property (nonatomic) NSUInteger column;         // 1-based byte column
@property (nonatomic) NSUInteger matchBytes;     // match length in bytes
@property (nonatomic, copy) NSString *preview;   // trimmed line text
@property (nonatomic) NSRange previewMatch;      // match within preview (UTF-16), may be NSNotFound
@end

// Fixed-string search across a directory. Uses ripgrep when installed, otherwise a built-in scanner.
// All callbacks run on the main queue; a new search or -cancel silences the previous one.
@interface WorkspaceSearch : NSObject
@property (nonatomic) NSUInteger maxHits;        // default 2000
@property (nonatomic) BOOL disableRipgrep;       // for tests
@property (nonatomic, readonly) BOOL usedRipgrep;

+ (NSString *)ripgrepPath;
- (void)search:(NSString *)query root:(NSString *)root caseSensitive:(BOOL)cs includeHidden:(BOOL)hidden
       onBatch:(void (^)(NSArray<SearchHit *> *hits, NSUInteger filesScanned))onBatch
        onDone:(void (^)(BOOL truncated))onDone;
- (void)cancel;
@end

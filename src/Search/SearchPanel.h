#import <Cocoa/Cocoa.h>
@class SearchHit;

typedef NS_ENUM(NSInteger, SearchScope) { SearchScopeAll = 0, SearchScopeNames, SearchScopeContents };

// Sidebar "搜索" tab: query, match options (Aa / 全词 / .*), scope (全部 / 文件名 / 内容), files to
// include / exclude, then results in two sections — matching file names, and content matches grouped by file.
@interface SearchPanel : NSObject <NSSearchFieldDelegate, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, copy) NSString *root;              // setting clears results
@property (nonatomic) BOOL includeHidden;                // re-runs the search
@property (nonatomic) BOOL respectGitignore;             // content search skips .gitignore'd files
// focusEditor: YES for clicks / Return, NO for keyboard navigation in the results list
@property (nonatomic, copy) void (^onOpen)(SearchHit *hit, BOOL focusEditor);
@property (nonatomic, copy) void (^onOpenFile)(NSString *path, BOOL focusEditor);   // a file-name result
@property (nonatomic, copy) void (^onReveal)(NSString *path);                         // "在文件树中显示"
- (void)focusWithQuery:(NSString *)q;
- (void)selectNextResult:(BOOL)backward;                 // F4 / ⇧F4
- (void)fileSystemChanged;                               // files were created / renamed / deleted
@property (nonatomic, readonly) BOOL hasResults;

// Mostly for tests: drive the panel without the typing debounce.
@property (nonatomic) SearchScope scope;
@property (nonatomic) BOOL caseSensitive, wholeWord, regex;
@property (nonatomic, copy) NSString *query, *filterText;
- (void)runNow;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly) NSUInteger nameCount, contentFileCount, hitCount;
@property (nonatomic, readonly) NSString *statusText;
@property (nonatomic, readonly) NSOutlineView *resultsView;
@end

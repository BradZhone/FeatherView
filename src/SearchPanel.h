#import <Cocoa/Cocoa.h>
@class SearchHit;

// Sidebar "搜索" tab: query field, options, grouped results.
@interface SearchPanel : NSObject <NSSearchFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, copy) NSString *root;              // setting clears results
@property (nonatomic) BOOL includeHidden;
// focusEditor: YES for clicks, NO for keyboard navigation in the results list
@property (nonatomic, copy) void (^onOpen)(SearchHit *hit, BOOL focusEditor);
- (void)focusWithQuery:(NSString *)q;
@end

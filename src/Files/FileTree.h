#import <Cocoa/Cocoa.h>

@interface FileNode : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) BOOL isDir;
@property (nonatomic, readonly, weak) FileNode *parent;
@property (nonatomic, readonly) NSString *path;
@end

// Lazily loaded directory tree backing an NSOutlineView.
@interface FileTree : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
- (instancetype)initWithOutlineView:(NSOutlineView *)ov;
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic) BOOL showHidden;
// User opened a file: pinned = double click (keep the tab), otherwise a preview tab.
@property (nonatomic, copy) void (^onOpen)(NSString *path, BOOL pinned);
@property (nonatomic, readonly) NSString *selectedPath;                  // first selected row
@property (nonatomic, readonly) NSArray<NSString *> *selectedPaths;      // ⇧ / ⌘ click selects several, in row order
@property (nonatomic, readonly) NSString *clickedPath;   // row under a right-click, or nil
// Right-click on a selected row = the whole selection (like Finder); on another row = just that row.
@property (nonatomic, readonly) NSArray<NSString *> *clickedPaths;
// Programmatic selection below never triggers onOpen.
- (void)reload;                       // keeps expansion state and the selection
- (void)refreshInBackground;          // same, reading folders off the main thread (file system events)
@property (nonatomic, copy) void (^onRefreshed)(void);   // a background refresh changed the tree
- (void)revealPath:(NSString *)path;  // expand ancestors and select
- (void)revealPaths:(NSArray<NSString *> *)paths;
- (void)reloadAndReveal:(NSString *)path;
@end

// Return renames (one item), ⌘⌫ moves the selection to Trash (sent as renameItem: / trashItem: up the responder chain).
@interface FileOutlineView : NSOutlineView
@end

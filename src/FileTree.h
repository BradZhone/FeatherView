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
@property (nonatomic, readonly) NSString *selectedPath;
@property (nonatomic, readonly) NSString *clickedPath;   // row under a right-click, or nil
// Programmatic selection below never triggers onOpen.
- (void)reload;                       // keeps expansion state
- (void)revealPath:(NSString *)path;  // expand ancestors and select
- (void)reloadAndReveal:(NSString *)path;
@end

// Return renames, ⌘⌫ moves to Trash (sent as renameItem: / trashItem: up the responder chain).
@interface FileOutlineView : NSOutlineView
@end

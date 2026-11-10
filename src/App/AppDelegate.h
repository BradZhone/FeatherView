#import <Cocoa/Cocoa.h>
#import "FileTree.h"
#import "ContentController.h"
#import "SearchPanel.h"
#import "QuickPicker.h"
#import "WelcomeView.h"
#import "FileWatcher.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, NSMenuDelegate, NSMenuItemValidation> {
@public
    NSWindow *_win;
    NSSplitView *_split;
    NSView *_sidebar;
    NSPopUpButton *_rootPopup;          // sidebar header: current workspace, click to switch
    NSSegmentedControl *_tabs;
    NSScrollView *_treeScroll;
    FileOutlineView *_outline;
    FileTree *_tree;
    SearchPanel *_search;
    ContentController *_content;
    WelcomeView *_welcome;
    QuickPicker *_picker;
    NSMenu *_recentMenu;
    BOOL _sessionSaved, _launched;
    NSMutableArray<NSString *> *_pendingFiles;          // opened from Finder before launch finished
    id _defaultAppsPanel;
    NSString *(^_trashHandler)(NSString *path);         // tests: instead of the real Trash; returns an error
    NSPasteboard *_pasteboard;                          // tests: instead of the general pasteboard
    FileWatcher *_watcher;                              // the workspace folder
    __weak NSWindow *_keyWindowOverride;                // tests: stands in for NSApp.keyWindow
}
- (void)openRoot:(NSString *)root;
- (BOOL)switchToRoot:(NSString *)root;     // asks about unsaved tabs first
- (void)openFile:(NSString *)path;         // pinned tab + reveal in tree
- (void)updateTitle;
- (void)refreshWorkspaceUI;                // header popup + welcome page
- (void)saveSession;
- (void)mainWindowWillReappear;
- (BOOL)openDroppedURLs:(NSArray<NSURL *> *)urls;       // files and folders dragged onto the window
- (void)fileSystemChanged;                 // the workspace watcher fired           // after the window was closed: its session comes back, ⌘Q asks again
- (void)showSidebarTab:(NSInteger)tab;     // 0 files, 1 search
@end

// The Selection menu: its shortcuts (⌥↑, ⌘D, ⌘[ …) only apply while a text editor has the focus, so a
// disabled item doesn't swallow them in other views (tables, text fields, the spreadsheet grid).
@interface FTEditorMenu : NSMenu
@property (class, nonatomic, weak) NSResponder *focusOverride;     // tests: stands in for the key window's first responder
@end

@interface AppDelegate (Menu)
- (void)buildMenu;
+ (void)applyAppearance:(NSInteger)mode;   // 0 system, 1 light, 2 dark
- (NSMenu *)treeContextMenu;
- (NSString *)targetPathFrom:(id)sender;               // first of targetPathsFrom:
- (NSArray<NSString *> *)targetPathsFrom:(id)sender;   // context-menu paths, else the tree selection, else the open file
- (void)copyItemPath:(id)sender;
- (void)rebuildRootPopupMenu:(NSMenu *)menu;
- (NSWindow *)windowForClose;                          // the key window when it isn't the main one
@end

@interface AppDelegate (Workspace)
- (NSArray<NSString *> *)recentRoots;
- (void)noteRecentRoot:(NSString *)root;
- (void)removeRecentRoot:(NSString *)root;    // one entry; its saved session stays
- (NSArray<NSString *> *)trashablePaths:(NSArray<NSString *> *)paths;
- (void)trashItem:(id)sender;              // every target; one sheet for all errors
@end

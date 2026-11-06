#import <Cocoa/Cocoa.h>
#import "FileTree.h"
#import "ContentController.h"
#import "SearchPanel.h"
#import "QuickPicker.h"
#import "WelcomeView.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, NSMenuDelegate> {
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
    BOOL _sessionSaved;
}
- (void)openRoot:(NSString *)root;
- (BOOL)switchToRoot:(NSString *)root;     // asks about unsaved tabs first
- (void)openFile:(NSString *)path;         // pinned tab + reveal in tree
- (void)updateTitle;
- (void)refreshWorkspaceUI;                // header popup + welcome page
- (void)saveSession;
- (void)showSidebarTab:(NSInteger)tab;     // 0 files, 1 search
@end

@interface AppDelegate (Menu)
- (void)buildMenu;
- (NSMenu *)treeContextMenu;
- (NSString *)targetPathFrom:(id)sender;
- (void)rebuildRootPopupMenu:(NSMenu *)menu;
@end

@interface AppDelegate (Workspace)
- (NSArray<NSString *> *)recentRoots;
- (void)noteRecentRoot:(NSString *)root;
@end

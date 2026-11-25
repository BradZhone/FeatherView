#import <Cocoa/Cocoa.h>
#import "FileTree.h"
#import "FileWatcher.h"

// A floating workspace: a small always-on-top panel with its own file tree, on its own folder,
// independent of the main window's workspace. Shown and hidden with one shortcut, for glancing at
// notes while working in another app.
//
// The panel is a utility window at NSFloatingWindowLevel. It never ends the app: closing it only
// hides it, and it is taken down before the main window's own close goes through, so the app is
// never left running with nothing but this panel.
@interface FloatPanel : NSObject <NSWindowDelegate, NSSplitViewDelegate, NSMenuDelegate>

// The name its position and size are kept under. One panel per name: AppKit writes the setting
// whenever a window carrying it moves, so two panels sharing one overwrite each other's frame.
- (instancetype)initWithFrameName:(NSString *)frameName;
@property (nonatomic, readonly) NSPanel *panel;
@property (nonatomic, readonly) FileTree *tree;
@property (nonatomic, readonly) BOOL visible;

// The folder shown. Persisted; the tree and its watcher follow it. Setting one that isn't in the
// list adds it.
@property (nonatomic, copy) NSString *folder;

// The folders the header's pop-up offers, most recently used first. Persisted.
@property (nonatomic, readonly) NSArray<NSString *> *folders;
- (void)addFolder:(NSString *)path;        // adds and switches to it
- (void)removeFolder:(NSString *)path;     // switches away if it was the current one
- (void)chooseFolder:(id)sender;           // "Add Folder…": an open panel on the panel itself

// Files the panel can't show itself (images, PDFs, binaries) go to the main window, as does a file
// the main window already has unsaved edits in — its copy is the current one, not the disk's.
@property (nonatomic, copy) void (^onOpenElsewhere)(NSString *path);
// Asked before showing a file: YES when the main window is holding unsaved edits for it.
@property (nonatomic, copy) BOOL (^hasUnsavedEditsElsewhere)(NSString *path);
// After the panel saves: the main window re-checks the file, so its own copy isn't left stale.
@property (nonatomic, copy) void (^onSaved)(NSString *path);

// The file in the active tab, nil when there is none.
@property (nonatomic, readonly) NSString *openPath;
- (void)openFile:(NSString *)path;         // in a tab; falls back to onOpenElsewhere
// Can the panel show this file itself (text, markup, an image or a PDF)? The main window asks before
// offering "Move to Floating Workspace", since anything else would only bounce back to it.
- (BOOL)canShow:(NSString *)path;
// Reopens the tabs that were open when the app last quit, skipping any file no longer there. Called
// once at launch; opens straight from disk and never hands a file to the main window.
- (void)restoreTabs;
@property (nonatomic, readonly) BOOL dirty;              // any tab has unsaved work
- (BOOL)save;                              // ⌘S on the active tab
- (BOOL)saveAll;                           // ⌥⌘S

// Tabs, one per open file, each with its own editor, undo history and link trail.
@property (nonatomic, readonly) NSUInteger tabCount;
@property (nonatomic, readonly) NSArray<NSString *> *openPaths;   // in strip order
- (void)selectTab:(NSInteger)index;
- (void)closeTab:(NSInteger)index;         // ⌘W; asks if that tab alone is unsaved
- (void)selectNextTab;                     // ⌃⇥ / ⇧⌘]
- (void)selectPreviousTab;

// Auto-save, following the same setting as the main window (off / after a pause / on focus change).
// A file changed on disk behind the panel's back is never overwritten silently.
- (void)flushAutoSave;                     // focus change: write out what is due
@property (nonatomic) NSTimeInterval autoSaveDelay;      // tests; default 1 s
// Save / discard / cancel for an unsaved file in the panel. NO means the reader cancelled and
// whatever was about to happen (quitting, closing the main window) must not.
- (BOOL)confirmUnsavedBeforeClosing;
@property (nonatomic, copy) NSModalResponse (^alertHandler)(NSAlert *alert);   // tests

// Source or rendered, never both: the panel is too small to be useful split. Persisted.
@property (nonatomic) BOOL showsPreview;
- (void)toggleFloatPreview:(id)sender;     // ⇧⌘V inside the panel

// Links in a rendered preview are followed in the panel, which is a trail to walk back along.
@property (nonatomic, readonly) BOOL canGoBack, canGoForward;
- (void)goBack;
- (void)goForward;

- (void)show;        // brings the panel up and gives it the keyboard
- (void)hide;
- (void)toggle;

// The sidebar can be collapsed to leave the content alone; persisted.
@property (nonatomic) BOOL sidebarVisible;
- (void)toggleFloatSidebar:(id)sender;   // never toggleSidebar:, which NSWindow and NSSplitView own

// The system-wide shortcut that shows and hides the panel, "⇧⌘E" style. It works while another app
// is in front, which a menu shortcut cannot. Persisted; empty leaves none registered.
@property (nonatomic, copy) NSString *shortcut;
@property (nonatomic, readonly) BOOL shortcutRegistered;   // NO when another app already holds it
@property (nonatomic, readonly) NSString *shortcutProblem; // why, for the settings window
+ (NSString *)defaultShortcut;
// Gives the combination back to the system and stops following the setting. For a panel being
// taken out of use: the setting itself is left alone, so another panel can still take it up.
- (void)relinquishShortcut;

// Hide as soon as the panel stops being the key window (off by default: this is a workspace to leave
// open, not a launcher). Persisted.
@property (nonatomic) BOOL hidesWhenInactive;

@end

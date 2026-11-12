#import <Cocoa/Cocoa.h>
#import "FileKind.h"
@class TextEditorView, PDFPreview, ImagePreviewView, TSession;

typedef NS_ENUM(NSInteger, AutoSaveMode) {
    AutoSaveOff = 0,
    AutoSaveAfterDelay,        // after a short pause in typing (and on focus change)
    AutoSaveOnFocusChange,     // when switching tabs, apps or windows
};

// Right-hand pane: tab strip + active viewer + find/replace bar + status bar.
// Text tabs keep their editor (and undo history) alive; image / Quick Look / hex
// viewers of background tabs are released and rebuilt when the tab is activated.
@interface ContentController : NSObject <NSSearchFieldDelegate, NSTextFieldDelegate>
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, strong) NSView *emptyView;              // shown when no tab is open
@property (nonatomic, readonly) NSString *currentPath;         // active tab's file (nil for an untitled document)
@property (nonatomic, readonly) TextEditorView *editor;        // active tab's editor, if text
@property (nonatomic, readonly) NSArray<NSString *> *openPaths;     // untitled tabs: their backup file
@property (nonatomic, readonly) NSUInteger tabCount, dirtyCount;
@property (nonatomic) BOOL previewEnabled;                     // VSCode-style preview tab (default YES)
@property (nonatomic) BOOL showsMinimap;                       // applies to every open editor (default YES)
- (void)redrawEditors;                                           // after a drawing setting changed
@property (nonatomic) BOOL wordWrap;                           // applies to every open editor (default NO)
@property (nonatomic, copy) void (^onStateChange)(void);       // title / dirty changed
@property (nonatomic, copy) void (^onActivate)(NSString *path);// active tab changed
// Tests set this to answer save/discard prompts without a modal alert.
@property (nonatomic, copy) NSModalResponse (^alertHandler)(NSAlert *alert);

// preview: reuse the single preview tab (single click). focus: move keyboard focus to the viewer.
- (void)openPath:(NSString *)path preview:(BOOL)preview focus:(BOOL)focus;
- (void)reopenActiveAs:(ViewerKind)mode;
- (void)pinActive;
- (BOOL)closeActive;
- (BOOL)closeOthers;
- (BOOL)closeAll;                       // asks once about unsaved tabs
- (BOOL)closePathsWithin:(NSString *)path;
- (void)closeAllWithoutAsking;
@property (nonatomic, readonly) NSUInteger viewerLoads;       // tests: viewers built so far
- (void)selectTabOffset:(NSInteger)delta;
- (void)selectTabAtIndex:(NSInteger)i;  // negative = last
- (BOOL)reopenClosed;
- (BOOL)confirmCloseAll;                // save/discard/cancel for all dirty files (not untitled tabs: they are kept); does not close

- (BOOL)save;
@property (nonatomic, readonly) BOOL activeIsDirty;            // the active tab has unsaved changes (text or cells)
- (BOOL)saveAll;
- (NSDictionary *)sessionState;
- (void)restoreSession:(NSDictionary *)state;
- (void)checkExternalChanges;

// Untitled documents (⌘N): "未命名-N" tabs whose text lives in a backup file until the user saves it somewhere.
// They stay with the workspace (switching away or quitting keeps them, nothing is asked); only closing such a
// tab asks where to save it. currentPath is nil for them.
// Terminals: a tab (like a document tab) or the bottom panel. The session survives placement
// switches; closing one ends its process without asking.
- (nullable TSession *)openTerminalAt:(nullable NSString *)directory asTab:(BOOL)asTab;
@property (nonatomic, readonly) NSArray<TSession *> *terminals;
@property (nonatomic, readonly) NSUInteger terminalCount;
- (BOOL)terminalPanelVisible;
- (void)setTerminalPanelVisible:(BOOL)visible focus:(BOOL)focus;
- (void)moveActiveTerminalToPanel;
- (void)moveActivePanelTerminalToTab;
- (nullable TSession *)activeTerminal;
- (void)closeTerminal:(TSession *)t;
- (void)shutdownTerminals;                        // at quit: end every live session, waiting briefly
@property (nonatomic) CGFloat terminalPanelHeight;
// Where a new terminal starts (default: home). The app sets this to the workspace root.
@property (nonatomic, copy, nullable) NSString *(^terminalDirectoryProvider)(void);
- (void)moveTerminalToTab:(nullable TSession *)t;                 // drag & drop targets
- (void)moveTerminalToPanel:(nullable TSession *)t;
- (void)newUntitledDocument;
@property (nonatomic, readonly) BOOL activeIsUntitled;
@property (nonatomic, readonly) NSString *currentTitle;        // "未命名-1" or the file name
@property (nonatomic, copy) NSString *untitledDirectory;       // backups; default ~/Library/Application Support/Feather/Untitled (name kept from before the rename)
- (void)backupUntitled;                                         // write every untitled tab's text to its backup now
// Tests: answer the save panel. Return nil to cancel.
@property (nonatomic, copy) NSString *(^savePathHandler)(NSString *suggestedName, NSString *directory);
@property (nonatomic, copy) void (^onSaveAs)(NSString *path);  // an untitled document became this file
+ (NSSet<NSString *> *)untitledBackupsInSessions:(NSDictionary *)sessions;
// Backups no session refers to (a crash before the session was written): non-empty ones open as untitled tabs.
- (void)adoptUntitledBackups:(NSArray<NSString *> *)paths;

- (void)showFindBar;
- (void)showReplaceBar;
- (void)findNext:(BOOL)backward;
- (void)openHit:(NSString *)path line:(NSUInteger)line column:(NSUInteger)col length:(NSUInteger)len;
- (void)pathMoved:(NSString *)from to:(NSString *)to;

// Markdown / HTML tabs
@property (nonatomic, copy) NSString *workspaceRoot;           // HTML preview may read files under it
@property (nonatomic, readonly) BOOL activeIsMarkup;
@property (nonatomic, readonly) MarkupKind activeMarkupKind;
@property (nonatomic) MarkupLayout activeMarkupLayout;          // setting it also becomes the default for that kind
- (void)openPath:(NSString *)path preview:(BOOL)preview focus:(BOOL)focus layout:(MarkupLayout)layout;
- (void)findInPreview;                                          // ⌘F in a rendered view: its own find / filter
@property (nonatomic, readonly) BOOL activeHasDataView;         // a table / tree / database / archive is showing

// Auto-save: silent, never overwrites a file changed on disk; problems go to the status bar.
@property (nonatomic) AutoSaveMode autoSaveMode;
@property (nonatomic) NSTimeInterval autoSaveDelay;            // AfterDelay, default 1 s
- (BOOL)flushAutoSave;                                          // NO if some file could not be saved
@property (nonatomic, readonly) NSString *statusText;

// Zoom follows what is shown: image / PDF zoom, Markdown / HTML preview scale, or the editor font size.
@property (nonatomic, readonly) BOOL canZoom;
- (void)zoomIn;
- (void)zoomOut;
- (void)zoomReset;                       // fit (image, PDF) or 100% / default font size
- (void)zoomActualSize;
@property (nonatomic, readonly) BOOL activeCanRotate;
- (void)rotate:(NSInteger)quarterTurns;
@property (nonatomic, readonly) PDFPreview *activePDF;
@property (nonatomic, readonly) ImagePreviewView *activeImage;
- (void)goToPage:(NSUInteger)index;      // 0-based
- (void)togglePDFThumbnails;
- (void)togglePDFTwoPages;
- (void)openInDefaultApp;
- (BOOL)findInActive:(NSString *)text backward:(BOOL)backward;
@end

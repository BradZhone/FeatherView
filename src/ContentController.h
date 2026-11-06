#import <Cocoa/Cocoa.h>
#import "FileKind.h"
@class TextEditorView, PDFPreview, ImagePreviewView;

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
@property (nonatomic, readonly) NSString *currentPath;         // active tab
@property (nonatomic, readonly) TextEditorView *editor;        // active tab's editor, if text
@property (nonatomic, readonly) NSArray<NSString *> *openPaths;
@property (nonatomic, readonly) NSUInteger tabCount, dirtyCount;
@property (nonatomic) BOOL previewEnabled;                     // VSCode-style preview tab (default YES)
@property (nonatomic) BOOL showsMinimap;                       // applies to every open editor (default YES)
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
- (void)selectTabOffset:(NSInteger)delta;
- (void)selectTabAtIndex:(NSInteger)i;  // negative = last
- (BOOL)reopenClosed;
- (BOOL)confirmCloseAll;                // save/discard/cancel for all dirty tabs; does not close

- (BOOL)save;
- (BOOL)saveAll;
- (NSDictionary *)sessionState;
- (void)restoreSession:(NSDictionary *)state;
- (void)checkExternalChanges;

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
- (void)findInPreview;

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

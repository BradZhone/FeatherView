#import <Cocoa/Cocoa.h>
#import "Zoomable.h"
@class XLWorkbook, SheetGrid;

// A viewer with its own unsaved changes (not a text editor): the tab shows them, ⌘S saves, closing asks.
@protocol FTSavable <NSObject>
@property (nonatomic, readonly) BOOL isDirty;
- (BOOL)saveReturningError:(NSString **)error;
@property (nonatomic, copy) void (^onChange)(void);        // dirty state or status text changed
@property (nonatomic, readonly) NSString *status;
- (BOOL)find:(NSString *)text backward:(BOOL)backward;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
@end

// .xlsx / .xlsm: cells with their formats and styles, sheet tabs, a formula bar, and editing. Saving writes
// only the edited cells back into the file (see XLWorkbook).
@interface SpreadsheetPreview : NSView <FTSavable, FTZoomable, NSTextFieldDelegate>
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path error:(NSString **)error;   // nil if unreadable
@property (nonatomic, readonly) XLWorkbook *workbook;
@property (nonatomic, readonly) SheetGrid *grid;
@property (nonatomic, readonly) NSUInteger sheetIndex;
- (void)showSheet:(NSUInteger)index;
- (BOOL)setText:(NSString *)text row:(NSUInteger)row col:(NSUInteger)col;   // as if typed; records undo
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) void (^onMessage)(NSString *message);
@end

// .docx / .doc: the system's Office renderer (the one Quick Look uses), shown as pages with zoom and find.
// Read-only; "Open in …" hands the file to Pages or Word.
@interface DocumentPreview : NSView <FTZoomable>
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path;
@property (nonatomic, readonly) BOOL loaded;              // rendered (or fell back to Quick Look)
@property (nonatomic, readonly) NSString *status;
@property (nonatomic, copy) void (^onChange)(void);
- (BOOL)find:(NSString *)text backward:(BOOL)backward;
- (void)evaluate:(NSString *)js done:(void (^)(id result))done;   // tests
+ (void)removeStaleRenderings;
@end

// "Open in Excel" / "Open in Pages": the default app for the file that isn't FeatherView; nil if there is none.
NSButton *FTOpenInAppButton(NSString *path, id target, SEL action);
NSURL *FTOtherAppFor(NSString *path);

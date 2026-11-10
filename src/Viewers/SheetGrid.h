#import "CanvasView.h"
#import "XLWorkbook.h"
#import "XLXML.h"

// The cells of one worksheet: virtualized drawing (only visible cells), frozen panes, merged cells, Excel
// styles, a selection and in-place editing. Sizes are the sheet's points × zoom.
@interface SheetGrid : CanvasView <NSTextFieldDelegate> {
@public
    XLSheet *_sheet;
    CGFloat *_ry, *_cx;                  // cumulative row tops / column lefts, in points × zoom
    NSUInteger _nRows, _nCols, _capRows, _capCols;
    NSUInteger _row, _col, _anchorRow, _anchorCol;
    NSTextField *_field;                 // in-cell editor
    BOOL _committing;
    NSMutableDictionary<NSString *, NSFont *> *_fonts;
    CGFloat _zoom;
}
@property (nonatomic, strong) XLSheet *sheet;            // resets selection and scrolling
@property (nonatomic) CGFloat zoom;                      // 1 = 100 %
@property (nonatomic, copy) void (^onSelect)(void);      // the active cell or range changed
@property (nonatomic, copy) BOOL (^onEdit)(NSUInteger row, NSUInteger col, NSString *text);
@property (nonatomic, copy) void (^onMessage)(NSString *message);
@property (nonatomic, copy) void (^onEditingText)(NSString *text);    // live text while editing in the cell
@property (nonatomic, strong) NSPasteboard *pasteboard;  // tests; default general
@property (nonatomic, readonly) NSUInteger row, col;
@property (nonatomic, readonly) XLRange selection;
@property (nonatomic, readonly) BOOL isEditing;
- (void)selectRow:(NSUInteger)row col:(NSUInteger)col extend:(BOOL)extend;
- (void)invalidate;                                      // cell contents changed

// geometry (SheetGrid.m)
- (CGFloat)headerWidth;
- (CGFloat)headerHeight;
- (void)ensureRows:(NSUInteger)n cols:(NSUInteger)m;
- (NSRect)rectForRow:(NSUInteger)r col:(NSUInteger)c;   // in view coordinates, merged cells expanded
- (BOOL)cellAtPoint:(NSPoint)p row:(NSUInteger *)r col:(NSUInteger *)c;   // NO in the headers
- (void)scrollToActive;
- (NSUInteger)frozenRows;
- (NSUInteger)frozenCols;
- (CGFloat)frozenW;
- (CGFloat)frozenH;
- (CGFloat)xOfCol:(NSUInteger)c;
- (CGFloat)yOfRow:(NSUInteger)r;
@end

@interface SheetGrid (Input)
- (BOOL)beginEditing:(NSString *)initial;
- (void)commitEditing;
- (void)cancelEditing;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
- (void)delete:(id)sender;
@end

@interface SheetGrid (Draw)
- (NSFont *)fontFor:(XLStyle *)style;
@end

#import "TextEditorView.h"
#import "PieceTable.h"
#import "Highlighter.h"
#import <CoreText/CoreText.h>

@interface EditOp : NSObject
@property BOOL isInsert;
@property NSUInteger offset;
@property NSData *bytes;
@end

typedef NS_ENUM(NSInteger, GroupKind) { GroupOther, GroupTyping, GroupBackspace };

@interface EditGroup : NSObject
@property NSMutableArray<EditOp *> *ops;
@property PieceTable *swapBuffer;        // set: the group replaces the whole buffer (Replace All); undo swaps back
@property NSUInteger caretBefore, caretAfter, serial;
@property GroupKind kind;
@end

@interface TextEditorView () {
@public
    PieceTable *_buf;
    NSUInteger _caret, _anchor;          // byte offsets; selection = [min, max)
    CGFloat _desiredX;                   // -1 = none
    CTFontRef _font, _italicFont, _boldFont;   // italic / bold only when their advances match the regular face
    CGFloat _lineHeight, _ascent, _charWidth, _widestLine;
    Highlighter *_hl;
    NSString *_indentUnit;
    NSString *_markedText;               // IME composition, not in buffer
    NSRange _markedSel;
    NSMutableArray<EditGroup *> *_undo, *_redo;
    NSUInteger _serial, _savedSerial, _editCount;
    BOOL _coalesceBroken;
    NSString *_path;
    NSStringEncoding _encoding;
    BOOL _showsMinimap, _mapDragging;
    CGFloat _mapGrab;                    // cursor offset inside the slider while dragging
    NSMutableDictionary<NSNumber *, NSData *> *_mapCache;   // line → packed colour runs
    NSUInteger _mapCacheEdit;
    CTParagraphStyleRef _paraStyle;      // 4-column tab stops
    // Soft wrap: _rowStart[L] = first visual row of line L (prefix sums, lineCount + 1 entries).
    BOOL _wordWrap, _wrapActive, _wrapValid, _wrapBusy;
    uint64_t *_rowStart;
    NSUInteger _rowCap, _wrapLines;
    CGFloat _wrapWidth;                  // text width the table was built for
    CGFloat _pendingTop;                 // logical line to keep at the top across a rebuild, -1 = none
    PTUnicodeIndex *_uindex;              // find with Unicode case folding; rebuilt when _uindexEdit != _editCount
    NSUInteger _uindexEdit;
    NSString *_killed;                   // ⌃K text, for ⌃Y
    NSTimer *_dragScroll;                // autoscroll while a selection drag is outside the view
    NSPoint _dragPoint;
    NSUInteger _axEdit;                  // last edit VoiceOver was told about
    NSRange _editLines;                  // lines touched by the edit in progress (beginEdit:)
    BOOL _bulkEdit;                      // many ops at once: rebuild instead of splicing
    NSMutableDictionary<id, NSNumber *> *_advances;   // cluster → advance, for non-ASCII
}
@end

// Rows of one logical line: UTF-16 start index of each row, plus the indent of continuation rows.
typedef struct { NSUInteger count; uint32_t *starts; CGFloat indent; } WrapRows;

@interface TextEditorView (Wrap)
- (BOOL)wrapOn;                                 // rebuilds the row table if needed
- (NSUInteger)rowCount;
- (NSUInteger)firstRowOfLine:(NSUInteger)L;
- (NSUInteger)lineOfRow:(NSUInteger)row;
- (CGFloat)yForLine:(CGFloat)line;              // content y of a (fractional) logical line
- (CGFloat)lineAtY:(CGFloat)y;                  // inverse of yForLine:
- (void)scrollToLine:(CGFloat)line;             // puts that line at the top
- (WrapRows)rowsOf:(NSString *)s;               // caller frees .starts
- (BOOL)wrapLimited;                            // wrap wanted but the file is too large
- (void)changeLayout:(void (^)(void))change;    // font / wrap / minimap changes; keeps the top line
- (void)beginEdit:(NSRange)r;                   // around every buffer mutation
- (void)endEdit;
- (CGFloat)beginBulkEdit;                       // many mutations: rebuild once instead of splicing each
- (void)endBulkEdit:(CGFloat)top;               // pass what beginBulkEdit returned
- (void)ensureWrap;
- (void)refreshRowsOfLine:(NSUInteger)L;        // e.g. while IME text is shown on the line
- (NSString *)displayString:(NSUInteger)L;      // the line as drawn (with IME text)
- (NSUInteger)rowOfOffset:(NSUInteger)off x:(CGFloat *)x;          // global row; x within the text area
- (NSUInteger)offsetInRow:(NSUInteger)row x:(CGFloat)x;
@end

@interface TextEditorView (Minimap)
- (CGFloat)minimapWidth;                 // 0 when hidden or the view is too narrow
- (CGFloat)rightInset;                   // minimap + scroll indicator
- (NSRect)minimapRect;
- (NSRect)minimapSliderRect;
- (void)drawMinimap;
- (BOOL)minimapPressAt:(NSPoint)p;       // NO if p is outside the minimap
- (void)minimapDragTo:(NSPoint)p;
@end

@interface TextEditorView (Layout)
- (CGFloat)gutterWidth;
- (CGFloat)textOriginX;                         // view x of column 0 (scroll applied)
- (NSData *)lineBytes:(NSUInteger)line;         // capped, UTF-8 boundary safe
- (NSString *)lineString:(NSUInteger)line;
- (NSUInteger)utf16Index:(NSUInteger)byteOff inLine:(NSUInteger)line;
- (NSUInteger)byteOffsetForUTF16:(NSUInteger)idx inLine:(NSUInteger)line;
- (CTLineRef)createLine:(NSString *)s CF_RETURNS_RETAINED;
- (CTLineRef)createLine:(NSString *)s range:(NSRange)r CF_RETURNS_RETAINED;   // one row; indices stay those of s
- (CGFloat)xForOffset:(NSUInteger)off;          // content x (no scroll, no gutter)
- (NSUInteger)offsetAtPoint:(NSPoint)p;
- (void)scrollCaretVisible;
- (NSUInteger)prevCharOffset:(NSUInteger)off;
- (NSUInteger)nextCharOffset:(NSUInteger)off;
- (NSUInteger)wordBoundary:(NSUInteger)off forward:(BOOL)fwd;
- (NSRange)wordRangeAt:(NSUInteger)off;
@end

@interface TextEditorView (Edit)
- (NSRange)selection;
- (void)moveCaretTo:(NSUInteger)off extend:(BOOL)extend;
- (void)replaceRange:(NSRange)r withString:(NSString *)s kind:(GroupKind)kind;
- (void)notifyChange;
- (void)applyGroup:(EditGroup *)g inverse:(BOOL)inverse;
- (void)pushUndo:(EditGroup *)g;
- (PTUnicodeIndex *)unicodeIndexFor:(NSString *)needle;   // nil: the byte search applies                // keeps at most 2000 groups   // undo (inverse) / redo of one group
- (void)undo:(id)sender;
- (void)redo:(id)sender;
@end

@interface TextEditorView (Input) <NSTextInputClient>
- (void)dragTo:(NSPoint)p;                      // selection drag, also from the autoscroll timer
@end

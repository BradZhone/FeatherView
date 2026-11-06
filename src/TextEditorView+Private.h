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
@property NSUInteger caretBefore, caretAfter, serial;
@property GroupKind kind;
@end

@interface TextEditorView () {
@public
    PieceTable *_buf;
    NSUInteger _caret, _anchor;          // byte offsets; selection = [min, max)
    CGFloat _desiredX;                   // -1 = none
    CTFontRef _font;
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
}
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
- (CGFloat)xForOffset:(NSUInteger)off;          // content x (no scroll, no gutter)
- (NSUInteger)offsetForX:(CGFloat)x line:(NSUInteger)line;
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
- (void)undo:(id)sender;
- (void)redo:(id)sender;
@end

@interface TextEditorView (Input) <NSTextInputClient>
@end

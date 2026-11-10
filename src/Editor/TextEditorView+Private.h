#import "TextEditorView.h"
#import "PieceTable.h"
#import "Highlighter.h"
#import <CoreText/CoreText.h>

// One cursor: selection [min, max) of two byte offsets, plus the column vertical moves aim for (-1 = none).
typedef struct { NSUInteger anchor, caret; CGFloat x; } Sel;
static inline NSUInteger SelStart(Sel s) { return MIN(s.anchor, s.caret); }
static inline NSUInteger SelEnd(Sel s) { return MAX(s.anchor, s.caret); }
static inline NSRange SelRange(Sel s) { return NSMakeRange(SelStart(s), SelEnd(s) - SelStart(s)); }
static inline Sel SelMake(NSUInteger anchor, NSUInteger caret) { return (Sel){anchor, caret, -1}; }

static const NSUInteger kMaxCursors = 10000;

typedef NS_ENUM(NSInteger, GroupKind) { GroupOther, GroupTyping, GroupBackspace };

// Replacements made at once, sorted, in the coordinates of the text before them; the bytes each one
// removed and inserted are concatenated in order.
typedef struct { NSUInteger location, removed, inserted; } BatchEdit;
@interface EditBatch : NSObject
@property NSMutableData *edits;          // BatchEdit[]
@property NSMutableData *removed, *inserted;
@end

@interface EditGroup : NSObject
@property EditBatch *batch;
@property PieceTable *swapBuffer;        // set: the group replaces the whole buffer (Replace All); undo swaps back
@property NSData *selsBefore, *selsAfter;   // Sel[]
@property NSUInteger primaryBefore, primaryAfter, serial;
@property GroupKind kind;
@end

// The replacements of one change, collected in order (current coordinates). A range that overlaps the
// previous one is merged into it (two cursors deleting the same word).
@interface EditList : NSObject
- (NSUInteger)replace:(NSRange)r with:(NSString *)s;          // returns the index of the item it ended up in
- (NSUInteger)replace:(NSRange)r withData:(NSData *)d;
@property (nonatomic, readonly) NSUInteger count;
- (NSRange)rangeAt:(NSUInteger)i;
- (NSData *)dataAt:(NSUInteger)i;
- (NSUInteger)newStartOf:(NSUInteger)i;                       // where item i's text starts afterwards
// Where an offset of the text before ends up. Inside a replaced range: its start; at an insertion point:
// before the inserted text, or after it with `right`.
- (NSUInteger)map:(NSUInteger)offset right:(BOOL)right;
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
    // Multiple cursors: the primary one is _anchor/_caret/_desiredX, the others are here (Sel[], sorted).
    NSMutableData *_extra;
    NSMutableArray<NSData *> *_cursorHistory;          // earlier cursor sets, for ⌘U (Sel[] + primary index)
    NSMutableIndexSet *_autoClosed;                    // closing brackets / quotes typed by auto-close
    NSPasteboard *_pasteboard;
    BOOL _columnDrag, _ignoreDrag;                     // ⇧⌥ drag: column selection; a ⌥ click removed a cursor
    NSPoint _columnFrom;                               // x in the text, y = row
    NSUInteger _bracketPair[2];                         // matching brackets at the caret (NSNotFound: none)
    NSUInteger _bracketEdit, _bracketCaret;
    BOOL _bracketValid;
    NSData *_occurrenceSels;                           // cursors right after the last ⌘D
    BOOL _occurrenceWhole;                             // that ⌘D series started from a caret: whole words
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
- (void)wrapApplyEdits:(const PTEdit *)e count:(NSUInteger)n;   // applies several edits, re-measuring their lines
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
- (NSRange)selection;                                    // the primary cursor's
- (void)moveCaretTo:(NSUInteger)off extend:(BOOL)extend; // one cursor
- (void)replaceRange:(NSRange)r withString:(NSString *)s kind:(GroupKind)kind;   // one cursor, after the text
// One undoable change. `after` (Sel[], new coordinates) NULL: the cursors are mapped through the edits
// (a selection grows over text inserted at its edges, a caret moves past it).
- (void)commit:(EditList *)edits selections:(const Sel *)after count:(NSUInteger)n primary:(NSUInteger)primary kind:(GroupKind)kind;
// Every cursor's edit: the range to replace (location NSNotFound: none), its text, and the new selection
// relative to the range's start (left alone: after the text).
typedef NSRange (^CursorEdit)(Sel s, NSString **text, NSInteger *anchor, NSInteger *caret);
- (void)editCursors:(CursorEdit)f kind:(GroupKind)kind;
- (void)notifyChange;
- (void)applyGroup:(EditGroup *)g inverse:(BOOL)inverse;   // undo (inverse) / redo of one group
- (void)pushUndo:(EditGroup *)g;                           // keeps at most 2000 groups
- (PTUnicodeIndex *)unicodeIndexFor:(NSString *)needle;   // nil: the byte search applies
- (NSString *)stringIn:(NSRange)r;                         // UTF-8 decoded, @"" if invalid
- (NSString *)newline;                                    // the file's line break
- (void)undo:(id)sender;
- (void)redo:(id)sender;
@end

@interface TextEditorView (Cursors)
- (NSUInteger)cursorCount;
- (NSMutableData *)cursors:(NSUInteger *)primary;           // Sel[], sorted by start
// Clamps, sorts and merges overlapping selections; the primary one goes to _anchor/_caret. No redraw.
- (void)setCursors:(const Sel *)s count:(NSUInteger)n primary:(NSUInteger)primary;
- (void)dropExtraCursors;
- (void)cursorsChanged;                                    // scroll to the primary one, redraw, notify
typedef NSUInteger (^CaretMove)(Sel *s);                   // new caret of one cursor; may set s->x
- (void)moveCursors:(CaretMove)f extend:(BOOL)extend keepColumn:(BOOL)keepColumn;
- (void)rememberCursors;                                   // for ⌘U
- (void)addCursorAt:(NSUInteger)off;                       // ⌥ click: adds, or removes the one there
- (NSRange)wordAroundCaret:(NSUInteger)off;                // the word the caret is in or right after; empty if none
- (void)copy:(id)sender;                                   // the selections, or the cursors' lines
- (void)cut:(id)sender;
- (void)paste:(id)sender;                                  // one piece per cursor when the counts match
- (void)beginColumnSelectionAt:(NSPoint)p;
- (void)columnSelectTo:(NSPoint)p;
@end

@interface TextEditorView (Lines)
- (NSUInteger)firstNonBlankOf:(NSUInteger)line;
- (NSString *)indentOf:(NSUInteger)line;
- (NSString *)lineCommentToken;                            // nil: the language has none
@end

@interface TextEditorView (Assist)
- (BOOL)autoPairInsert:(NSString *)s;                     // handled typing of a bracket or quote
- (BOOL)autoPairBackspace;
- (void)shiftAutoClosed:(EditList *)edits;
- (void)updateBracketPair;
- (NSString *)highlightedWord:(BOOL *)wholeWord;          // what other occurrences are marked for
@end

@interface TextEditorView (Input) <NSTextInputClient>
- (void)dragTo:(NSPoint)p;                      // selection drag, also from the autoscroll timer
@end

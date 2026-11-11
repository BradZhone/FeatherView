#import "CanvasView.h"
@class PieceTable;

// Editable text view over a PieceTable. Renders only visible lines with CoreText.
@interface TextEditorView : CanvasView

- (instancetype)initWithFrame:(NSRect)frame buffer:(PieceTable *)buffer
                         path:(NSString *)path encoding:(NSStringEncoding)encoding;

@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSStringEncoding encoding;
@property (nonatomic, readonly) BOOL isDirty;
@property (nonatomic, copy) void (^onChange)(void);      // caret / content / dirty changed

- (NSString *)statusText;
- (NSUInteger)caretLine;          // 1-based
@property (nonatomic) BOOL showsMinimap;
@property (nonatomic) BOOL wordWrap;                     // soft wrap at the view's width (off for very large files)
@property (nonatomic, readonly) BOOL wrapsLines;         // wrapping is actually in effect
@property (nonatomic) CGFloat fontSize;                  // keeps the top visible line when changed
@property (class, nonatomic) CGFloat defaultFontSize;     // for editors created later (default 13)
@property (class, nonatomic) BOOL autoCloseBrackets;      // typing ( [ { and quotes adds the closing one (default YES)
@property (class, nonatomic) BOOL showsIndentGuides;      // a line at each indentation level (default YES)
@property (class, nonatomic) BOOL showsWhitespace;        // dots for spaces, arrows for tabs (default NO)
@property (nonatomic, readonly) NSUInteger cursorCount;  // 1 unless there are multiple cursors
@property (nonatomic, strong) NSPasteboard *pasteboard;  // the general one unless set (tests)

@end

// Multiple cursors and line commands; menu items send these to the first responder.
@interface TextEditorView (Commands)
- (void)addCursorAbove:(id)sender;          // ⌥⌘↑
- (void)addCursorBelow:(id)sender;          // ⌥⌘↓
- (void)addNextOccurrence:(id)sender;       // ⌘D
- (void)skipToNextOccurrence:(id)sender;    // ⇧⌘D
- (void)selectAllOccurrences:(id)sender;    // ⇧⌘L
- (void)addCursorsToLineEnds:(id)sender;    // ⌥⌘I
- (void)undoCursor:(id)sender;              // ⌘U
- (void)moveLinesUp:(id)sender;             // ⌥↑
- (void)moveLinesDown:(id)sender;           // ⌥↓
- (void)copyLinesUp:(id)sender;             // ⇧⌥↑
- (void)copyLinesDown:(id)sender;           // ⇧⌥↓
- (void)deleteLines:(id)sender;             // ⇧⌘K
- (void)insertLineBelow:(id)sender;         // ⌘↩
- (void)insertLineAbove:(id)sender;         // ⇧⌘↩
- (void)indentLines:(id)sender;             // ⌘]
- (void)outdentLines:(id)sender;            // ⌘[
- (void)toggleLineComment:(id)sender;       // ⌘/
- (void)joinLines:(id)sender;               // ⌃J
- (void)sortLinesAscending:(id)sender;
- (void)sortLinesDescending:(id)sender;
- (void)trimTrailingWhitespace:(id)sender;
- (void)expandSelection:(id)sender;         // ⌃⇧⌘→
- (void)shrinkSelection:(id)sender;         // ⌃⇧⌘←
- (void)fold:(id)sender;                    // ⌥⌘[
- (void)unfold:(id)sender;                  // ⌥⌘]
- (void)foldAll:(id)sender;                 // ⇧⌥⌘[
- (void)unfoldAll:(id)sender;               // ⇧⌥⌘]
- (void)jumpToBracket:(id)sender;           // ⇧⌘ backslash
@end

@interface TextEditorView (Document)
- (BOOL)save:(NSString **)error;
- (BOOL)findString:(NSString *)s backward:(BOOL)backward;
- (void)gotoLine:(NSUInteger)line;
@end

@interface TextEditorView (Search)
- (NSString *)selectedText;                    // single-line selection, else nil
- (void)setDocumentPath:(NSString *)path;      // after a rename
- (void)selectLine:(NSUInteger)line column:(NSUInteger)col length:(NSUInteger)len;   // 1-based, byte column
- (BOOL)replaceSelectionIfMatches:(NSString *)find with:(NSString *)repl;           // then finds next
- (NSUInteger)replaceAll:(NSString *)find with:(NSString *)repl;                    // one undo step
@property (nonatomic, readonly) NSData *contentData;       // UTF-8 buffer contents
@property (nonatomic, readonly) NSUInteger contentLength;
@property (nonatomic, readonly) CGFloat topVisibleLine;    // 0-based, fractional
@property (nonatomic, readonly) NSUInteger editCount;      // bumps on every content change (incl. undo)
@property (nonatomic, readonly) BOOL isComposing;          // IME marked text pending
@end

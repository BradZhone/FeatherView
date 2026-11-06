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
@property (nonatomic) CGFloat fontSize;                  // keeps the top visible line when changed
@property (class, nonatomic) CGFloat defaultFontSize;     // for editors created later (default 13)

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

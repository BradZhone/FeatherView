#import <Foundation/Foundation.h>

// A terminal screen: a grid of cells plus a scrollback ring of pushed-off lines, and every screen
// operation an escape sequence can ask for. Pure Foundation; rendering and the PTY live elsewhere.
// All offsets are 0-based; "style" is what SGR currently selects and is applied to written cells.

#define TCDefault 0xFFFFFFFFu               // fg / bg: the theme's default

typedef struct {
    uint32_t ch;                             // Unicode code point; 0 = blank
    uint32_t fg, bg;                         // TCDefault, 0x00RRGGBB, or a palette index (TCPal)
    uint8_t attrs;
} TCell;

enum {
    TFBold = 1, TFItalic = 2, TFUnderline = 4, TFReverse = 8, TFWide = 16, TFCont = 32,
    TFStrike = 128
};

// fg / bg carry a palette index (0..255) when this bit is set; RGB otherwise uses bits 0..23.
#define TCPal 0x01000000u

typedef enum { TMouseOff = 0, TMousePress, TMouseDrag, TMouseAny } TMouseMode;

// Everything the escape parser produces; TScreen implements this.
@protocol TTEndpoint <NSObject>
- (void)putChar:(uint32_t)ch wide:(BOOL)wide;
- (void)bell;
- (void)backspace;
- (void)tab;
- (void)carriageReturn;
- (void)lineFeed;
- (void)reverseLineFeed;
- (void)cursorUp:(NSUInteger)n;
- (void)cursorDown:(NSUInteger)n;
- (void)cursorForward:(NSUInteger)n;
- (void)cursorBack:(NSUInteger)n;
- (void)cursorToRow:(NSUInteger)row col:(NSUInteger)col origin:(BOOL)origin;
- (void)cursorToColumn:(NSUInteger)col;
- (void)cursorToRow:(NSUInteger)row;
- (void)eraseInDisplay:(NSInteger)mode;      // 0 to cursor end, 1 to cursor start, 2 all, 3 all + scrollback
- (void)eraseInLine:(NSInteger)mode;         // 0 to cursor end, 1 to cursor start, 2 all
- (void)insertLines:(NSUInteger)n;
- (void)deleteLines:(NSUInteger)n;
- (void)insertChars:(NSUInteger)n;
- (void)deleteChars:(NSUInteger)n;
- (void)eraseChars:(NSUInteger)n;
- (void)repeatLastChar:(NSUInteger)n;
- (void)scrollUp:(NSUInteger)n;
- (void)scrollDown:(NSUInteger)n;
- (void)setScrollRegionTop:(NSUInteger)top bottom:(NSUInteger)bottom;
- (void)setAutoWrap:(BOOL)on;
- (void)setOriginMode:(BOOL)on;
- (void)setAppCursorKeys:(BOOL)on;
- (void)setCursorVisible:(BOOL)on;
- (void)enterAltScreen:(BOOL)clear;
- (void)leaveAltScreen;
- (void)setMouseMode:(TMouseMode)mode;
- (void)setSGRMouse:(BOOL)on;
- (void)setBracketedPaste:(BOOL)on;
- (void)setInverseScreen:(BOOL)on;           // DECSCNM: swap paper and ink
- (void)saveCursor;
- (void)restoreCursor;
- (void)sgr:(const NSInteger *)p count:(NSUInteger)n;   // select graphic rendition
- (void)setTitle:(NSString *)title;
- (void)setCwd:(NSString *)fileURL;
- (void)setTabStop;
- (void)clearTabStop:(NSInteger)mode;        // 0 here, 3 all
- (void)backwardTab;                         // CBT: to the previous tab stop
- (void)reset;                               // ESC c
@end

@interface TScreen : NSObject <TTEndpoint>

- (instancetype)initWithCols:(NSUInteger)cols rows:(NSUInteger)rows scrollback:(NSUInteger)maxLines;

@property (nonatomic, readonly) NSUInteger cols, rows;
@property (nonatomic, readonly) NSUInteger historyCount;     // lines pushed off the top
@property (nonatomic) BOOL cursorVisible;                    // the app's choice (DECTCEM)

// The cell grid, the scrollback, and what the parser has toggled. Reading from the same thread
// that feeds the parser keeps this consistent; the view draws on that thread.
- (TCell)cellAtRow:(NSUInteger)r col:(NSUInteger)c;
- (NSUInteger)historyLength:(NSUInteger)i;                   // cells in pushed-off line i (0 = oldest)
- (const TCell *)historyCells:(NSUInteger)i;
- (NSUInteger)tabStops;                                      // one bit per column

@property (nonatomic, readonly) BOOL autoWrap, originMode, appCursorKeys, altScreen, sgrMouse, bracketedPaste, inverse;
@property (nonatomic, readonly) TMouseMode mouseMode;
@property (nonatomic, readonly) NSUInteger cursorRow, cursorCol, scrollTop, scrollBottom;
@property (nonatomic, readonly) NSString *title, *cwd;       // OSC 0/2, OSC 7 (file URL)
- (const uint32_t *)palette;                                 // 256 colors; first 16 from setPalette16:
- (void)setPalette16:(const uint32_t *)colors;               // 0..15, follows the theme

// The theme's background / foreground for drawing blanks; set alongside the palette.
@property (nonatomic) uint32_t defaultBg, defaultFg;

- (NSString *)textOfRow:(NSUInteger)r;                       // visible text (one blank per cell)
- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows;   // keeps the content, no reflow
- (void)clearScrollback;
- (NSUInteger)bellCount;                                     // bumped on every bell (the view flashes)

@end

#import <Cocoa/Cocoa.h>
#import "CanvasView.h"
#import "TSession.h"

// A terminal view: draws its session's screen, sends keys and mouse events to the PTY. Reuse the
// attachment across placements to retain selection and the user's scrollback position. Recognized
// control/function key equivalents precede text bindings; Command shortcuts remain menu actions.
@interface TerminalView : CanvasView

- (instancetype)initWithSession:(TSession *)session;

@property (nonatomic, readonly) TSession *session;
@property (nonatomic) CGFloat fontSize;                 // keeps to the default unless changed
+ (CGFloat)defaultFontSize;
+ (void)setDefaultFontSize:(CGFloat)size;

- (BOOL)hasSelection;
- (NSString *)selectedText;

@end

@interface TerminalView (Commands)
- (void)copy:(id)sender;                    // the selection, or an interrupt (^C) without one
- (void)paste:(id)sender;                   // bracketed paste when the app asked for it
- (void)selectAll:(id)sender;
- (void)clear:(id)sender;                   // ⌘K: screen and scrollback
@end

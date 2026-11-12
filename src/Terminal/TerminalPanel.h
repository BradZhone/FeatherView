#import <Cocoa/Cocoa.h>

@class TSession;

// The terminal panel: a strip of session tabs over one terminal view, dragged taller from its top
// edge. The strip is custom-drawn (like the tab bar): click selects, the ✕ closes, a tab drags out
// to the document tab bar, and a terminal tab dropped here moves into the panel.
@interface TerminalPanel : NSView <NSDraggingSource>

- (void)refresh:(NSArray<TSession *> *)sessions active:(TSession *)active;
- (void)setContentView:(NSView *)view;      // the active session's terminal view
@property (nonatomic, readonly, nullable) NSView *currentView;   // the terminal view on top
- (void)closeTabAtIndex:(NSUInteger)i;      // what the ✕ does (tests call it too)

@property (nonatomic, copy) void (^onSelect)(TSession *session);
@property (nonatomic, copy) void (^onClose)(TSession *session);
@property (nonatomic, copy) void (^onNew)(void);
@property (nonatomic, copy) void (^onHide)(void);                   // the ⌄ at the right edge
@property (nonatomic, copy) void (^onDropTerminal)(NSString *dragToken);   // a tab dropped on the strip
@property (nonatomic, copy) void (^onHeightChange)(CGFloat height);
- (NSUInteger)tabCount;                                              // tests

@end

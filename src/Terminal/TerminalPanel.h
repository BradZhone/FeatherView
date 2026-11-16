#import <Cocoa/Cocoa.h>
#import "FTTabDrag.h"

@class TSession, TerminalView, TabBarView;

NS_ASSUME_NONNULL_BEGIN

// Up to three independent terminal columns, each with its own tabs and active terminal view.
@interface TerminalPanel : NSView

@property (nonatomic, readonly, copy) NSArray<TSession *> *sessions; // flattened in column/tab order
@property (nonatomic, readonly, nullable) TSession *activeSession;
@property (nonatomic, readonly) NSUInteger columnCount;
@property (nonatomic, readonly, nullable) NSView *currentView;
@property (nonatomic, readonly, copy) NSArray<NSView *> *columnViews;
@property (nonatomic, readonly, copy) NSArray<TabBarView *> *tabBars;
@property (nonatomic, getter=isMaximized) BOOL maximized;
@property (nonatomic, copy, nullable) TerminalView *(^viewProvider)(TSession *session); // one view per session across placements

- (void)addSession:(TSession *)t;             // adds a tab to the focused column
- (void)removeSession:(TSession *)t;          // detaches its view; does not terminate the session
// Into uses a pre-removal insertion index (negative means append); edges create/relocate a column.
// An incoming session can also be inserted directly, without a preceding addSession:.
- (BOOL)moveSession:(TSession *)t toColumn:(NSUInteger)column zone:(FTTabDropZone)zone index:(NSInteger)tabIndex;
- (BOOL)containsSession:(TSession *)t;
- (void)focusSession:(TSession *)t;
- (void)syncFocus;
- (void)refreshTitles;
- (NSUInteger)tabCount;
- (void)closeTabAtIndex:(NSUInteger)i;        // flattened compatibility index

@property (nonatomic, copy, nullable) void (^onClose)(TSession *session);
@property (nonatomic, copy, nullable) void (^onNew)(void);
@property (nonatomic, copy, nullable) void (^onHide)(void);
@property (nonatomic, copy, nullable) void (^onHeightChange)(CGFloat height);
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
// Only sessions outside this panel are forwarded to the controller.
@property (nonatomic, copy, nullable) BOOL (^onDropTerminal)(NSString *token, NSUInteger column, FTTabDropZone zone, NSInteger index);

@end

NS_ASSUME_NONNULL_END

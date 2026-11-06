#import <Cocoa/Cocoa.h>

// Flipped view that virtualizes scrolling: subclasses draw only what is visible,
// using scrollX/scrollY as the content offset. Draws its own thin scroll indicator.
@interface CanvasView : NSView

@property (nonatomic) CGFloat scrollX, scrollY;
@property (nonatomic, copy) void (^onScroll)(void);   // vertical scroll position changed

// Subclass hooks
- (CGFloat)contentHeight;
- (CGFloat)maxScrollX;
- (CGFloat)maxScrollY;
- (void)canvasMouseDown:(NSEvent *)e;
- (void)canvasMouseDragged:(NSEvent *)e;

- (void)scrollToY:(CGFloat)y;
- (void)clampScroll;
- (void)drawScrollIndicator;
- (BOOL)pointInIndicator:(NSPoint)p;

+ (CGFloat)indicatorWidth;
@end

// Turns on clipsToBounds (macOS 14+ no longer clips custom views by default).
void FTClipToBounds(NSView *v);

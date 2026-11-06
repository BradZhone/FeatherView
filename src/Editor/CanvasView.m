#import "CanvasView.h"

@implementation CanvasView {
    BOOL _draggingKnob;
    CGFloat _dragOffset;
}

+ (CGFloat)indicatorWidth { return 10; }

void FTClipToBounds(NSView *v) {
    // Since macOS 14 views don't clip by default and drawRect: may get a dirty rect that
    // reaches into neighbouring views (here: the tab bar above the editor).
    if (@available(macOS 14.0, *)) v.clipsToBounds = YES;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) FTClipToBounds(self);
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (CGFloat)contentHeight { return 0; }
- (CGFloat)maxScrollX { return 0; }
- (void)canvasMouseDown:(NSEvent *)e {}
- (void)canvasMouseDragged:(NSEvent *)e {}

- (CGFloat)maxScrollY { return MAX(0, self.contentHeight - self.bounds.size.height); }

- (void)clampScroll {
    _scrollY = MIN(MAX(0, _scrollY), self.maxScrollY);
    _scrollX = MIN(MAX(0, _scrollX), self.maxScrollX);
}

- (void)scrolled { if (self.onScroll) self.onScroll(); }

- (void)setScrollX:(CGFloat)x { _scrollX = x; [self clampScroll]; self.needsDisplay = YES; }
- (void)setScrollY:(CGFloat)y {
    CGFloat old = _scrollY;
    _scrollY = y;
    [self clampScroll];
    self.needsDisplay = YES;
    if (_scrollY != old) [self scrolled];
}
- (void)scrollToY:(CGFloat)y { self.scrollY = y; }

- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self clampScroll]; }

- (void)scrollWheel:(NSEvent *)e {
    CGFloat dx = e.scrollingDeltaX, dy = e.scrollingDeltaY, oldY = _scrollY;
    if (!e.hasPreciseScrollingDeltas) { dx *= 16; dy *= 16; }
    if (fabs(dx) > fabs(dy) * 1.5) { _scrollX -= dx; }
    else { _scrollY -= dy; }
    [self clampScroll];
    self.needsDisplay = YES;
    if (_scrollY != oldY) [self scrolled];
}

- (NSRect)knobRect {
    CGFloat h = self.bounds.size.height, ch = self.contentHeight;
    if (ch <= h || h <= 0) return NSZeroRect;
    CGFloat kh = MAX(24, h * h / ch);
    CGFloat ky = (h - kh) * (_scrollY / self.maxScrollY);
    CGFloat w = [CanvasView indicatorWidth];
    return NSMakeRect(self.bounds.size.width - w + 2, ky + 2, w - 4, kh - 4);
}

- (BOOL)pointInIndicator:(NSPoint)p {
    return self.contentHeight > self.bounds.size.height &&
           p.x >= self.bounds.size.width - [CanvasView indicatorWidth];
}

- (void)drawScrollIndicator {
    NSRect k = self.knobRect;
    if (NSIsEmptyRect(k)) return;
    [[NSColor.labelColor colorWithAlphaComponent:_draggingKnob ? 0.45 : 0.25] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:k xRadius:3 yRadius:3] fill];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self pointInIndicator:p]) {
        NSRect k = self.knobRect;
        if (NSPointInRect(p, NSInsetRect(k, -2, -2))) _dragOffset = p.y - k.origin.y;
        else _dragOffset = k.size.height / 2;           // jump knob under cursor
        _draggingKnob = YES;
        [self dragKnobTo:p.y];
        return;
    }
    [self canvasMouseDown:e];
}

- (void)dragKnobTo:(CGFloat)y {
    NSRect k = self.knobRect;
    CGFloat track = self.bounds.size.height - (k.size.height + 4);
    if (track <= 0) return;
    CGFloat frac = MIN(MAX(0, (y - _dragOffset) / track), 1);
    self.scrollY = frac * self.maxScrollY;
}

- (void)mouseDragged:(NSEvent *)e {
    if (_draggingKnob) { [self dragKnobTo:[self convertPoint:e.locationInWindow fromView:nil].y]; return; }
    [self canvasMouseDragged:e];
}

- (void)mouseUp:(NSEvent *)e {
    if (_draggingKnob) { _draggingKnob = NO; self.needsDisplay = YES; }
}

@end

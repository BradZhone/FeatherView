#import "FTSplitView.h"

static const CGFloat kGrabSlop = 4;        // how close to a divider the drag starts

@implementation FTSplitView {
    CGFloat _weights[3];                   // normalized to 1 over all items
    NSMapTable<NSView *, NSNumber *> *_weightsByItem;
    NSInteger _dragB;                      // divider being dragged (between items b and b+1)
    CGFloat _dragLeft, _dragRight;         // the fixed outer edges of the two dragged items
    BOOL _dragging, _maximized;
    id _focusMonitor;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _focused = 0;
        _maximized = NO;
        _minimumItemWidth = 180;
        _dragB = -1;
        _weightsByItem = [NSMapTable weakToStrongObjectsMapTable];
        if (@available(macOS 14.0, *)) self.clipsToBounds = YES;   // unclipped views repaint their neighbours
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)dealloc { if (_focusMonitor) [NSEvent removeMonitor:_focusMonitor]; }

- (void)viewDidMoveToWindow {
    if (_focusMonitor) { [NSEvent removeMonitor:_focusMonitor]; _focusMonitor = nil; }
    if (!self.window) return;
    __weak FTSplitView *weakSelf = self;
    _focusMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        FTSplitView *me = weakSelf;
        if (!me || event.window != me.window || me.isHiddenOrHasHiddenAncestor) return event;
        NSPoint point = [me convertPoint:event.locationInWindow fromView:nil];
        if (!NSPointInRect(point, me.bounds) || [me dividerAt:point.x] >= 0) return event;
        NSInteger index = [me itemAtPoint:point];
        if (index < 0 || index == me.focused) return event;
        NSView *item = me.items[index];
        // Let AppKit dispatch the click at its original geometry before changing column widths.
        dispatch_async(dispatch_get_main_queue(), ^{
            FTSplitView *split = weakSelf;
            if (!split) return;
            NSUInteger current = [split.items indexOfObjectIdenticalTo:item];
            if (current == NSNotFound || (NSInteger)current == split.focused) return;
            if (split.onFocusItem) split.onFocusItem((NSInteger)current);
            else split.focused = (NSInteger)current;
        });
        return event;
    }];
}

- (NSArray<NSNumber *> *)weights {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:_items.count];
    for (NSUInteger i = 0; i < _items.count; i++) [a addObject:@(_weights[i])];
    return a;
}

- (void)setItems:(NSArray<NSView *> *)items {
    NSArray<NSView *> *oldItems = _items ?: @[];
    for (NSUInteger i = 0; i < oldItems.count; i++)
        if (i < 3) [_weightsByItem setObject:@(_weights[i]) forKey:oldItems[i]];
    NSArray<NSView *> *nextItems = [items copy] ?: @[];
    if (nextItems.count > 3) return;
    for (NSView *v in oldItems) if (![nextItems containsObject:v]) [v removeFromSuperview];
    _items = nextItems;
    CGFloat sum = 0;
    NSUInteger n = MIN(_items.count, (NSUInteger)3);
    for (NSUInteger i = 0; i < n; i++) {
        NSNumber *saved = [_weightsByItem objectForKey:_items[i]];
        _weights[i] = saved.doubleValue > 0 ? saved.doubleValue : 1;
        sum += _weights[i];
    }
    for (NSUInteger i = 0; i < n; i++) {
        _weights[i] /= sum > 0 ? sum : 1;
        [_weightsByItem setObject:@(_weights[i]) forKey:_items[i]];
    }
    for (NSView *v in _items) {
        v.autoresizingMask = 0;
        if (v.superview != self) [self addSubview:v];
    }
    _focused = _items.count ? MIN(_focused, (NSInteger)_items.count - 1) : 0;
    if (_items.count < 2) _maximized = NO;
    [self applyLayout];
}

- (void)setFocused:(NSInteger)f {
    _focused = _items.count ? MIN(MAX(f, 0), (NSInteger)_items.count - 1) : 0;
    [self applyLayout];
}

- (BOOL)isMaximized { return _maximized && _items.count > 1; }

- (void)setMaximized:(BOOL)m {
    if (_maximized == m) return;
    _maximized = m;
    [self applyLayout];
    if (self.onMaximizeChange) self.onMaximizeChange(m);
}

#pragma mark Layout

// Only called at all when autoresizesSubviews is on (the default) — never turn it off here.
- (void)resizeSubviewsWithOldSize:(NSSize)old { [self applyLayout]; }

// Clamp every width to the minimum, taking what is needed from the widest column.
- (void)balancedWidths:(CGFloat *)w count:(NSUInteger)n total:(CGFloat)total {
    CGFloat minimum = MIN(_minimumItemWidth, total / n);
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat need = MAX(0, minimum - w[i]);
        for (NSUInteger j = 0; j < n && need > 0; j++) {
            if (j == i) continue;
            CGFloat take = MIN(need, MAX(0, w[j] - minimum));
            w[j] -= take; w[i] += take; need -= take;
        }
    }
}

- (void)applyLayout {
    NSUInteger n = _items.count;
    if (!n) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat w[3] = {0, 0, 0};
    if (_maximized && n > 1) {
        CGFloat minimum = MIN(_minimumItemWidth, W / n);
        for (NSUInteger i = 0; i < n; i++) w[i] = (NSInteger)i == _focused ? MAX(0, W - (n - 1) * minimum) : minimum;
    } else {
        CGFloat sum = 0;
        for (NSUInteger i = 0; i < n; i++) sum += _weights[i];
        if (sum <= 0) sum = 1;
        for (NSUInteger i = 0; i < n; i++) w[i] = _weights[i] / sum * W;
        [self balancedWidths:w count:n total:W];
    }
    CGFloat x = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSRect frame = NSMakeRect(round(x), 0, (i + 1 == n ? W - round(x) : round(x + w[i]) - round(x)), H);
        if (!NSEqualRects(_items[i].frame, frame)) _items[i].frame = frame;
        x += w[i];
    }
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.separatorColor setFill];
    CGFloat x = 0;
    for (NSUInteger i = 0; i + 1 < _items.count; i++) {
        x += _items[i].frame.size.width;
        NSRectFill(NSMakeRect(round(x) - 0.5, 0, 1, self.bounds.size.height));
    }
}

#pragma mark Dividers: drag, double-click, cursor

// x of the divider between items b and b+1.
- (CGFloat)boundary:(NSInteger)b {
    CGFloat x = 0;
    for (NSInteger i = 0; i <= b; i++) x += _items[i].frame.size.width;
    return x;
}

- (NSInteger)dividerAt:(CGFloat)x {
    for (NSInteger b = 0; (NSUInteger)b + 1 < _items.count; b++)
        if (fabs(x - [self boundary:b]) <= kGrabSlop + 4) return b;
    return -1;
}

// Child columns fill the whole width, so the normal hit-test would never return this view.
// Give the divider a generous interactive band and keep the rest of the hit testing to children.
- (NSView *)hitTest:(NSPoint)p {
    NSPoint local = [self convertPoint:p fromView:self.superview];
    if (!self.hidden && NSPointInRect(local, self.bounds) && [self dividerAt:local.x] >= 0) return self;
    return [super hitTest:p];
}

- (void)weightsFromFrames {
    CGFloat W = self.bounds.size.width;
    if (W <= 0) return;
    for (NSUInteger i = 0; i < _items.count; i++) _weights[i] = _items[i].frame.size.width / W;
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger b = [self dividerAt:p.x];
    if (b < 0) return;
    if (e.clickCount == 2) {                       // double-click maximizes the column left of it
        if (self.isMaximized && _focused == b) self.maximized = NO;
        else { self.focused = b; self.maximized = YES; }
        if (self.onFocusItem) self.onFocusItem(b);
        return;
    }
    if (self.isMaximized) {                        // a drag leaves maximize mode with the current widths
        [self weightsFromFrames];
        self.maximized = NO;
    }
    _dragging = YES;
    _dragB = b;
    [self weightsFromFrames];
    CGFloat minimum = MIN(_minimumItemWidth, self.bounds.size.width / MAX(1, _items.count));
    _dragLeft = [self boundary:b - 1] + minimum;
    _dragRight = [self boundary:b + 1] - minimum;
    if (_dragRight < _dragLeft) _dragRight = _dragLeft;
}

- (void)mouseDragged:(NSEvent *)e {
    if (!_dragging) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat W = self.bounds.size.width;
    if (W <= 0) return;
    CGFloat x = MIN(MAX(p.x, _dragLeft), _dragRight);
    CGFloat left = [self boundary:_dragB - 1], right = [self boundary:_dragB + 1];
    _weights[_dragB] = (x - left) / W;
    _weights[_dragB + 1] = (right - x) / W;
    [self applyLayout];
}

- (void)mouseUp:(NSEvent *)e { _dragging = NO; _dragB = -1; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingCursorUpdate owner:self userInfo:nil]];
}

- (void)cursorUpdate:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self dividerAt:p.x] >= 0) [NSCursor.resizeLeftRightCursor set];
    else [super cursorUpdate:event];
}

- (void)resetCursorRects {
    for (NSInteger b = 0; (NSUInteger)b + 1 < _items.count; b++) {
        CGFloat x = [self boundary:b];
        [self addCursorRect:NSMakeRect(x - kGrabSlop - 4, 0, (kGrabSlop + 4) * 2, self.bounds.size.height) cursor:NSCursor.resizeLeftRightCursor];
    }
}

- (NSInteger)itemAtPoint:(NSPoint)p {
    for (NSUInteger i = 0; i < _items.count; i++) if (NSPointInRect(p, _items[i].frame)) return (NSInteger)i;
    return -1;
}

- (FTSplitDropZone)dropZoneAtPoint:(NSPoint)p item:(NSInteger *)item {
    NSInteger i = [self itemAtPoint:p];
    if (item) *item = i;
    if (i < 0 || i >= (NSInteger)_items.count) return FTSplitDropInto;
    NSRect r = _items[i].frame;
    CGFloat edge = MIN(72, MAX(24, r.size.width * 0.24));
    if (p.x < NSMinX(r) + edge) return FTSplitDropBefore;
    if (p.x > NSMaxX(r) - edge) return FTSplitDropAfter;
    return FTSplitDropInto;
}

@end

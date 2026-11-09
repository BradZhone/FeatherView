#import "TabBarView.h"
#import "Localization.h"
#import "CanvasView.h"

@implementation TabItem @end

@interface TabAXElement : NSAccessibilityElement
@property (nonatomic, weak) TabBarView *bar;
@property (nonatomic) NSInteger index;
@end

@implementation TabAXElement
- (BOOL)accessibilityPerformPress {
    TabBarView *b = self.bar;
    if (b.onSelect) b.onSelect(self.index);
    return YES;
}
@end

@implementation TabBarView {
    NSMutableArray<NSValue *> *_rects;      // strip coordinates (before scrolling)
    CGFloat _scroll, _totalW;
    NSInteger _hover, _pressClose, _dragIndex;
    BOOL _hoverClose, _dragging;
    CGFloat _dragStartX;
    NSArray *_ax;
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _selectedIndex = _hover = _pressClose = _dragIndex = -1;
    _rects = [NSMutableArray array];
    FTClipToBounds(self);
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
          owner:self userInfo:nil]];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSAttributedString *)labelFor:(TabItem *)t selected:(BOOL)sel {
    NSFont *f = [NSFont systemFontOfSize:12];
    if (t.preview) f = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSItalicFontMask];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSColor *c = t.missing ? NSColor.tertiaryLabelColor : (sel ? NSColor.labelColor : NSColor.secondaryLabelColor);
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps} mutableCopy];
    if (t.missing) a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:t.title ?: @"" attributes:a];
    if (t.subtitle.length)
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:t.subtitle]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
                         NSParagraphStyleAttributeName: ps}]];
    return s;
}

- (NSRect)rectForTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_rects.count) return NSZeroRect;
    NSRect r = _rects[i].rectValue;
    r.origin.x -= _scroll;
    return r;
}

static NSRect closeRect(NSRect tab) { return NSMakeRect(NSMaxX(tab) - 24, NSMidY(tab) - 8, 16, 16); }

- (void)clampScroll { _scroll = MIN(MAX(0, _scroll), MAX(0, _totalW - self.bounds.size.width)); }

- (void)reload {
    [_rects removeAllObjects];
    CGFloat x = 0, h = self.bounds.size.height;
    for (TabItem *t in _items) {
        CGFloat w = MIN(MAX(ceil([self labelFor:t selected:NO].size.width) + 40, 90), 240);
        [_rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, h)]];
        x += w;
    }
    _totalW = x;
    [self clampScroll];
    if (_selectedIndex >= 0 && _selectedIndex < (NSInteger)_rects.count) {
        NSRect r = _rects[_selectedIndex].rectValue;
        if (NSMinX(r) < _scroll) _scroll = NSMinX(r);
        else if (NSMaxX(r) > _scroll + self.bounds.size.width) _scroll = NSMaxX(r) - self.bounds.size.width;
    }
    if (_hover >= (NSInteger)_items.count) _hover = -1;
    [self updateToolTips];
    _ax = nil;
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}

- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self reload]; }

- (void)updateToolTips {
    [self removeAllToolTips];
    for (NSInteger i = 0; i < (NSInteger)_rects.count; i++)
        [self addToolTipRect:[self rectForTab:i] owner:self userData:(void *)(intptr_t)i];
}

- (NSString *)view:(NSView *)v stringForToolTip:(NSToolTipTag)tag point:(NSPoint)p userData:(void *)data {
    NSInteger i = (intptr_t)data;
    return (i < (NSInteger)_items.count ? _items[i].toolTip : nil) ?: @"";
}

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    NSRect b = self.bounds;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, NSMaxY(b) - 1, b.size.width, 1));
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        NSRect r = [self rectForTab:i];
        if (!NSIntersectsRect(r, dirty)) continue;
        TabItem *t = _items[i];
        BOOL sel = i == _selectedIndex, hover = i == _hover;
        if (sel) {
            [NSColor.textBackgroundColor setFill];
            NSRectFill(r);
            [NSColor.controlAccentColor setFill];
            NSRectFill(NSMakeRect(r.origin.x, 0, r.size.width, 2));
        } else if (hover) {
            [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
            NSRectFill(NSMakeRect(r.origin.x, 0, r.size.width, r.size.height - 1));
        }
        [NSColor.separatorColor setFill];
        NSRectFill(NSMakeRect(NSMaxX(r) - 1, 6, 1, r.size.height - 12));

        NSAttributedString *label = [self labelFor:t selected:sel];
        CGFloat lh = label.size.height;
        [label drawWithRect:NSMakeRect(r.origin.x + 12, NSMidY(r) - lh / 2, r.size.width - 40, lh)
                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];

        // unsaved: dot (× while hovered). saved: × on the selected or hovered tab only.
        NSRect cr = closeRect(r);
        if (t.dirty && !hover) {
            [NSColor.secondaryLabelColor setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(cr, 4.5, 4.5)] fill];
        } else if (hover || sel) {
            if (hover && _hoverClose) {
                [[NSColor.labelColor colorWithAlphaComponent:0.12] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:cr xRadius:3 yRadius:3] fill];
            }
            NSBezierPath *x = [NSBezierPath bezierPath];
            NSRect in = NSInsetRect(cr, 4.5, 4.5);
            [x moveToPoint:in.origin]; [x lineToPoint:NSMakePoint(NSMaxX(in), NSMaxY(in))];
            [x moveToPoint:NSMakePoint(NSMinX(in), NSMaxY(in))]; [x lineToPoint:NSMakePoint(NSMaxX(in), NSMinY(in))];
            x.lineWidth = 1.3;
            x.lineCapStyle = NSLineCapStyleRound;
            [NSColor.secondaryLabelColor setStroke];
            [x stroke];
        }
    }
}

- (NSInteger)indexAt:(NSPoint)p {
    for (NSInteger i = 0; i < (NSInteger)_rects.count; i++) if (NSPointInRect(p, [self rectForTab:i])) return i;
    return -1;
}

- (NSPoint)local:(NSEvent *)e { return [self convertPoint:e.locationInWindow fromView:nil]; }

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self local:e];
    NSInteger h = [self indexAt:p];
    BOOL hc = h >= 0 && NSPointInRect(p, closeRect([self rectForTab:h]));
    if (h != _hover || hc != _hoverClose) { _hover = h; _hoverClose = hc; self.needsDisplay = YES; }
}
- (void)mouseExited:(NSEvent *)e { _hover = -1; _hoverClose = NO; self.needsDisplay = YES; }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self local:e];
    NSInteger i = [self indexAt:p];
    _dragIndex = -1; _dragging = NO; _pressClose = -1;
    if (i < 0) return;
    if (NSPointInRect(p, closeRect([self rectForTab:i]))) { _pressClose = i; return; }
    if (e.clickCount == 2) { if (self.onPin) self.onPin(i); return; }
    if (self.onSelect) self.onSelect(i);
    _dragIndex = i; _dragStartX = p.x;
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragIndex < 0) return;
    NSPoint p = [self local:e];
    if (!_dragging && fabs(p.x - _dragStartX) < 6) return;
    _dragging = YES;
    NSInteger to = [self indexAt:NSMakePoint(p.x, NSMidY(self.bounds))];
    if (to < 0) to = p.x < 0 ? 0 : (NSInteger)_items.count - 1;
    if (to != _dragIndex && self.onMove) { self.onMove(_dragIndex, to); _dragIndex = to; }
}

- (void)mouseUp:(NSEvent *)e {
    if (_pressClose >= 0) {
        NSInteger i = _pressClose;
        _pressClose = -1;
        if (NSPointInRect([self local:e], closeRect([self rectForTab:i])) && self.onClose) self.onClose(i);
    }
    _dragIndex = -1; _dragging = NO;
}

- (void)otherMouseUp:(NSEvent *)e {
    NSInteger i = [self indexAt:[self local:e]];
    if (e.buttonNumber == 2 && i >= 0 && self.onClose) self.onClose(i);
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSInteger i = [self indexAt:[self local:e]];
    return i >= 0 && self.menuForIndex ? self.menuForIndex(i) : nil;
}

- (void)scrollWheel:(NSEvent *)e {
    CGFloat d = fabs(e.scrollingDeltaX) > fabs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY;
    if (!e.hasPreciseScrollingDeltas) d *= 16;
    _scroll -= d;
    [self clampScroll];
    [self updateToolTips];
    self.needsDisplay = YES;
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTabGroupRole; }
- (NSString *)accessibilityLabel { return FTL(@"Open files"); }
- (NSArray *)accessibilityChildren {
    if (_ax) return _ax;
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        TabAXElement *el = [TabAXElement accessibilityElementWithRole:NSAccessibilityRadioButtonRole
            frame:[self.window convertRectToScreen:[self convertRect:[self rectForTab:i] toView:nil]]
            label:[_items[i].title stringByAppendingString:_items[i].dirty ? FTL(@", unsaved") : @""] parent:self];
        el.bar = self;
        el.index = i;
        el.accessibilityValue = @(i == _selectedIndex);
        [a addObject:el];
    }
    _ax = a;
    return a;
}
- (NSArray *)accessibilityTabs { return self.accessibilityChildren; }

@end

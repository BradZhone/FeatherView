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
    NSInteger _hover, _pressClose, _dragIndex, _dropIndex;
    BOOL _hoverClose, _dragging, _nativeDrag;
    NSPoint _dragStart;
    NSTimeInterval _lastClickTime;
    NSPoint _lastClickPoint;
    NSInteger _lastClickIndex;
    NSEvent *_downEvent;
    NSArray *_ax;
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _selectedIndex = _hover = _pressClose = _dragIndex = _dropIndex = -1;
    _tabDragType = FTTabDragType;
    _rects = [NSMutableArray array];
    FTClipToBounds(self);
    [self registerForDraggedTypes:@[FTTabDragType, FTTerminalDragType]];
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
    if (_dropIndex >= 0) {
        NSInteger index = MIN(_dropIndex, (NSInteger)_rects.count);
        CGFloat x = index < (NSInteger)_rects.count ? NSMinX([self rectForTab:index]) : _totalW - _scroll;
        x = MIN(MAX(NSMinX(b) + 1, x), NSMaxX(b) - 1);
        [NSColor.controlAccentColor setFill];
        NSRectFill(NSMakeRect(x - 1, NSMinY(b) + 3, 2, MAX(0, b.size.height - 6)));
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

- (void)clearDropHighlight {
    if (_dropIndex < 0) return;
    _dropIndex = -1;
    self.needsDisplay = YES;
}

- (void)clearDragState {
    _dragIndex = _pressClose = -1;
    _dragging = _nativeDrag = NO;
    _downEvent = nil;
}

- (void)finishTabDrag {
    [self clearDragState];
    [self clearDropHighlight];
    _lastClickTime = 0;
    _lastClickIndex = -1;
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self local:e];
    NSInteger i = [self indexAt:p];
    [self clearDragState];
    if (i < 0) return;
    if (NSPointInRect(p, closeRect([self rectForTab:i]))) { _pressClose = i; return; }
    NSTimeInterval now = e.timestamp > 0 ? e.timestamp : NSProcessInfo.processInfo.systemUptime;
    BOOL repeated = _lastClickIndex == i && now - _lastClickTime <= NSEvent.doubleClickInterval &&
                    hypot(p.x - _lastClickPoint.x, p.y - _lastClickPoint.y) <= 4;
    if ((e.clickCount >= 2 || repeated) && self.onDoubleClick) {
        _lastClickTime = 0;
        _lastClickIndex = -1;
        self.onDoubleClick(i);
        return;
    }
    _lastClickTime = now;
    _lastClickPoint = p;
    _lastClickIndex = i;
    if (self.onSelect) self.onSelect(i);
    _dragIndex = i; _dragStart = e.locationInWindow; _downEvent = e;
}

- (void)mouseDragged:(NSEvent *)e {
    if (_nativeDrag) { [FTTabDrag updateInteractiveDragWithEvent:e]; return; }
    if (_dragIndex < 0 || _dragIndex >= (NSInteger)_items.count) return;
    NSPoint p = [self local:e];
    if (!_dragging && hypot(e.locationInWindow.x - _dragStart.x, e.locationInWindow.y - _dragStart.y) < 6) return;
    BOOL configured = self.tabDragTokenForIndex != nil;
    NSString *token = configured ? self.tabDragTokenForIndex(_dragIndex) : nil;
    NSString *type = self.tabDragTypeForIndex ? self.tabDragTypeForIndex(_dragIndex) : nil;
    if (!type.length) type = self.tabDragType.length ? self.tabDragType : FTTabDragType;
    if (!configured && self.dragTokenForIndex) {
        token = self.dragTokenForIndex(_dragIndex);
        type = FTTerminalDragType;
    }
    if (token.length) {
        _dragging = _nativeDrag = YES;
        [FTTabDrag beginInteractiveDragWithToken:token terminal:[type isEqualToString:FTTerminalDragType] source:self event:e];
        return;
    }
    _dragging = YES;
    NSInteger to = [self indexAt:NSMakePoint(p.x, NSMidY(self.bounds))];
    if (to < 0) to = p.x < 0 ? 0 : (NSInteger)_items.count - 1;
    if (to != _dragIndex && self.onMove) { self.onMove(_dragIndex, to); _dragIndex = to; }
}

// NSDraggingSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextWithinApplication ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session { return YES; }

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    [FTTabDrag endDragging];
    [self clearDragState];
    [self clearDropHighlight];
}

#pragma mark Dropping tabs

- (NSInteger)insertionIndexAt:(NSPoint)point {
    for (NSInteger i = 0; i < (NSInteger)_rects.count; i++)
        if (point.x < NSMidX([self rectForTab:i])) return i;
    return _rects.count;
}

- (NSString *)tokenFromDrag:(id<NSDraggingInfo>)sender terminal:(BOOL *)terminal {
    NSPasteboard *pb = sender.draggingPasteboard;
    NSString *token = [pb stringForType:FTTabDragType];
    *terminal = NO;
    if (!token.length) { token = [pb stringForType:FTTerminalDragType]; *terminal = YES; }
    return token;
}

- (BOOL)canAcceptToken:(NSString *)token terminal:(BOOL)terminal {
    return token.length && (self.onDropTab || (terminal && self.dropTerminal)) &&
        (!self.canDropTab || self.canDropTab(token, terminal));
}

- (BOOL)updateToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point {
    if (!NSPointInRect(point, self.bounds) || ![self canAcceptToken:token terminal:terminal]) {
        [self clearDropHighlight];
        return NO;
    }
    NSInteger index = [self insertionIndexAt:point];
    if (_dropIndex != index) { _dropIndex = index; self.needsDisplay = YES; }
    return YES;
}

- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point {
    if (![self updateToken:token terminal:terminal atPoint:point]) return NO;
    NSInteger index = [self insertionIndexAt:point];
    [self clearDropHighlight];
    if (self.onDropTab) return self.onDropTab(token, terminal, index);
    if (terminal && self.dropTerminal) { self.dropTerminal(token); return YES; }
    return NO;
}

- (NSDragOperation)updateDrop:(id<NSDraggingInfo>)sender {
    BOOL terminal;
    NSString *token = [self tokenFromDrag:sender terminal:&terminal];
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    if (!NSPointInRect(point, self.bounds) || ![self canAcceptToken:token terminal:terminal]) {
        [self clearDropHighlight];
        return NSDragOperationNone;
    }
    NSInteger index = [self insertionIndexAt:point];
    if (_dropIndex != index) { _dropIndex = index; self.needsDisplay = YES; }
    return NSDragOperationMove;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self updateDrop:sender]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self updateDrop:sender]; }
- (void)draggingExited:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }
- (void)draggingEnded:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self updateDrop:sender] != NSDragOperationNone; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    BOOL terminal;
    NSString *token = [self tokenFromDrag:sender terminal:&terminal];
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    NSInteger index = [self insertionIndexAt:point];
    [self clearDropHighlight];
    if (!NSPointInRect(point, self.bounds) || ![self canAcceptToken:token terminal:terminal]) return NO;
    if (self.onDropTab) return self.onDropTab(token, terminal, index);
    self.dropTerminal(token);
    return YES;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }

- (void)mouseUp:(NSEvent *)e {
    if (_nativeDrag) { [FTTabDrag finishInteractiveDragWithEvent:e]; return; }
    if (_pressClose >= 0) {
        NSInteger i = _pressClose;
        _pressClose = -1;
        if (i < (NSInteger)_items.count && NSPointInRect([self local:e], closeRect([self rectForTab:i])) && self.onClose)
            self.onClose(i);
    }
    [self clearDragState];
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

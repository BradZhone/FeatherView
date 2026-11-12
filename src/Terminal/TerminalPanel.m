#import "TerminalPanel.h"
#import "TSession.h"
#import "CanvasView.h"
#import "Localization.h"

// Fixed height of the session-tab strip inside the panel.
static const CGFloat kStripH = 26;

static NSString * const kDragType = @"local.feather.terminal.session";

@interface TerminalPanel () {
    NSView *_holder;
    NSView *_content;
    NSArray<TSession *> *_sessions;
    TSession *_active;
    NSMutableArray<NSValue *> *_tabRects, *_closeRects;   // strip coordinates
    NSRect _plusRect, _hideRect, _activeCloseRect;
    NSInteger _pressTab, _pressClose;
    NSPoint _downPoint, _dragAnchor;
    CGFloat _startHeight;
    NSEvent *_downEvent;
    BOOL _draggingStrip, _draggingHeight;
}
@end
@implementation TerminalPanel

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        FTClipToBounds(self);                  // macOS 14+: an unclipped view repaints its neighbours
        _holder = [NSView new];
        [self addSubview:_holder];
        _tabRects = [NSMutableArray array];
        _closeRects = [NSMutableArray array];
        _pressTab = _pressClose = -1;
        [self registerForDraggedTypes:@[kDragType]];
        [self refresh:nil active:nil];
    }
    return self;
}

- (NSUInteger)tabCount { return _sessions.count; }
- (NSView *)currentView { return _content; }

- (void)refresh:(NSArray<TSession *> *)sessions active:(TSession *)active {
    _sessions = sessions ?: @[];
    _active = active;
    _pressTab = _pressClose = -1;
    [self layout];
    self.needsDisplay = YES;                   // the strip is drawn here, not by subviews
}

- (void)setContentView:(NSView *)view {
    [_content removeFromSuperview];
    _content = view;
    if (view) {
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        view.frame = _holder.bounds;
        [_holder addSubview:view];
    }
    [self layout];
}

- (void)layout {
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _holder.frame = NSMakeRect(0, kStripH + 4, w, MAX(0, h - kStripH - 4));
    [super layout];
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [self drawStrip];
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, kStripH, self.bounds.size.width, 1));
    NSRectFill(NSMakeRect(self.bounds.size.width / 2 - 24, 3, 48, 2));   // the drag handle on the top edge
}

#pragma mark Strip drawing and hit testing

- (void)drawStrip {
    CGFloat y = (kStripH - 16) / 2;
    NSDictionary *selAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
                               NSForegroundColorAttributeName: NSColor.controlAccentColor};
    NSDictionary *idleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11],
                                NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSDictionary *closeAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10],
                                 NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    [_tabRects removeAllObjects];
    [_closeRects removeAllObjects];
    CGFloat x = 6;
    for (NSUInteger i = 0; i < _sessions.count; i++) {
        TSession *t = _sessions[i];
        NSString *title = t.exited ? FTL(@"ended") : ((t.screen.cwd.length ? t.screen.cwd : t.directory).lastPathComponent ?: @"/");
        NSDictionary *attrs = t == _active ? selAttrs : idleAttrs;
        NSMutableParagraphStyle *tail = [NSMutableParagraphStyle new];
        tail.lineBreakMode = NSLineBreakByTruncatingTail;
        NSAttributedString *s = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: attrs[NSFontAttributeName], NSForegroundColorAttributeName: attrs[NSForegroundColorAttributeName],
            NSParagraphStyleAttributeName: tail}];
        // long titles (a shell that puts the whole path in the title) are capped
        CGFloat w = MIN(ceil([s size].width) + 10, 260);
        NSRect r = NSMakeRect(x, 3, w, kStripH - 6);
        if (t == _active) {
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
            NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);   // NSRectFill copies and drops the alpha
        }
        [s drawInRect:NSMakeRect(x + 5, y + 1, w - 12, kStripH - 2)];
        NSRect cr = NSMakeRect(x + w + 1, y, 14, 16);
        [@"✕" drawAtPoint:NSMakePoint(cr.origin.x + 1, y + 1) withAttributes:closeAttrs];
        [_tabRects addObject:[NSValue valueWithRect:r]];
        [_closeRects addObject:[NSValue valueWithRect:cr]];
        x = NSMaxX(cr) + 5;
    }
    _plusRect = NSMakeRect(x + 4, y - 1, 16, 18);
    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    NSAttributedString *plus = [[NSAttributedString alloc] initWithString:@"+" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: center}];
    [plus drawInRect:_plusRect];
    _activeCloseRect = _active ? NSMakeRect(self.bounds.size.width - 46, y, 16, 16) : NSZeroRect;
    if (_active) [@"✕" drawAtPoint:NSMakePoint(_activeCloseRect.origin.x + 1, y + 1) withAttributes:closeAttrs];
    _hideRect = NSMakeRect(self.bounds.size.width - 26, y - 2, 22, 20);
    NSImage *chevron = [NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:FTL(@"Hide Terminal Panel")];
    [chevron setSize:NSMakeSize(11, 11)];
    [chevron drawInRect:NSInsetRect(_hideRect, 4, 4) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (NSInteger)tabAt:(NSPoint)p {
    for (NSUInteger i = 0; i < _tabRects.count; i++) if (NSPointInRect(p, [_tabRects[i] rectValue])) return (NSInteger)i;
    return -1;
}

- (void)closeTabAtIndex:(NSUInteger)i {
    if (i >= _sessions.count || !self.onClose) return;
    self.onClose(_sessions[i]);
}

#pragma mark Mouse

- (BOOL)isInHandle:(NSPoint)p { return p.y < 6; }

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _downEvent = e;
    _downPoint = p;
    _pressTab = _pressClose = -1;
    if ([self isInHandle:p]) { _draggingHeight = YES; _dragAnchor = p; _startHeight = self.bounds.size.height; return; }
    for (NSUInteger i = 0; i < _closeRects.count; i++) if (NSPointInRect(p, [_closeRects[i] rectValue])) { _pressClose = (NSInteger)i; return; }
    if (NSPointInRect(p, _plusRect)) { if (self.onNew) self.onNew(); return; }
    if (NSPointInRect(p, _activeCloseRect)) { if (self.onClose && _active) self.onClose(_active); return; }
    if (NSPointInRect(p, _hideRect)) { if (self.onHide) self.onHide(); return; }
    NSInteger i = [self tabAt:p];
    if (i >= 0) {
        _pressTab = i;
        if (self.onSelect && _sessions[i] != _active) self.onSelect(_sessions[i]);
    }
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_draggingHeight) {
        CGFloat newH = MAX(120, MIN(_startHeight + (_dragAnchor.y - p.y), self.superview ? self.superview.bounds.size.height - 120 : 600));
        if (fabs(newH - self.bounds.size.height) >= 1 && self.onHeightChange) self.onHeightChange(newH);
        return;
    }
    // a strip tab dragged away becomes a drag & drop session for the tab bar
    if (_pressTab >= 0 && !_draggingStrip && (fabs(p.x - _downPoint.x) > 6 || fabs(p.y - _downPoint.y) > 6) && _downEvent) {
        _draggingStrip = YES;
        NSPasteboardItem *pb = [NSPasteboardItem new];
        [pb setString:[TSession registerDragSession:_sessions[_pressTab]] forType:kDragType];
        NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:pb];
        NSRect imgRect = [_tabRects[_pressTab] rectValue];
        NSImage *img = [[NSImage alloc] initWithSize:imgRect.size];
        [img lockFocus];
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.3] setFill];
        NSRectFill(NSMakeRect(0, 0, imgRect.size.width, imgRect.size.height));
        NSString *title = _sessions[_pressTab].screen.title.length ? _sessions[_pressTab].screen.title : _sessions[_pressTab].directory.lastPathComponent;
        [title drawAtPoint:NSMakePoint(5, 4) withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11]}];
        [img unlockFocus];
        [item setDraggingFrame:NSMakeRect(_downPoint.x - imgRect.size.width / 2, _downPoint.y - imgRect.size.height / 2, imgRect.size.width, imgRect.size.height) contents:img];
        [self beginDraggingSessionWithItems:@[item] event:_downEvent source:self];
        _pressTab = -1;
    }
}

- (void)mouseUp:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_draggingHeight) { _draggingHeight = NO; return; }
    if (_pressClose >= 0 && NSPointInRect(p, [_closeRects[_pressClose] rectValue])) [self closeTabAtIndex:(NSUInteger)_pressClose];
    _pressClose = -1;
    _pressTab = -1;
    _draggingStrip = NO;
}

// NSDraggingSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return context == NSDraggingContextOutsideApplication ? NSDragOperationMove : NSDragOperationNone;
}

#pragma mark Drop target (a terminal tab from the tab bar)

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [[sender draggingPasteboard].types containsObject:kDragType] ? NSDragOperationMove : NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSString *token = [[sender draggingPasteboard] stringForType:kDragType];
    if (token && self.onDropTerminal) self.onDropTerminal(token);
    return YES;
}

- (void)resetCursorRects {
    [self addCursorRect:NSMakeRect(0, self.bounds.size.height - 6, self.bounds.size.width, 6) cursor:NSCursor.resizeUpDownCursor];
}

@end

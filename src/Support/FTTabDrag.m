#import "FTTabDrag.h"
#import "TabBarView.h"
#import <dispatch/dispatch.h>

NSString *const FTTabDragType = @"local.feather.tab";
NSString *const FTTerminalDragType = @"local.feather.terminal.session";

static NSMutableDictionary<NSString *, id> *gTabDragTokens;
static BOOL gInteractiveDrag, gInteractiveTerminal, gInteractiveFinalizing;
static NSString *gInteractiveToken;
static TabBarView *gInteractiveSource;
static __weak NSWindow *gInteractiveWindow;
static __weak NSView *gInteractiveTarget;
static id gInteractiveMonitor, gResignObserver, gCloseObserver;

@interface FTTabDropOverlay : NSView
@end

// Resolve targets by visible geometry, not hitTest: (whose argument is in the parent's
// coordinates). WebKit's native children and the split divider must not steal local tab drags.
static NSView *dropTargetAtPoint(NSView *view, NSPoint windowPoint) {
    if (view.hiddenOrHasHiddenAncestor) return nil;
    NSPoint local = [view convertPoint:windowPoint fromView:nil];
    if (!NSPointInRect(local, view.visibleRect)) return nil;
    if ([view isKindOfClass:TabBarView.class]) return view;
    if ([view isKindOfClass:FTTabDropView.class] &&
        NSPointInRect(local, [(FTTabDropView *)view dropContentRect])) return view;
    for (NSView *child in view.subviews.reverseObjectEnumerator) {
        NSView *target = dropTargetAtPoint(child, windowPoint);
        if (target) return target;
    }
    return nil;
}

static NSView *targetForEvent(NSEvent *event) {
    NSWindow *window = gInteractiveWindow;
    if (!window || !window.visible || event.window != window) return nil;
    return dropTargetAtPoint(window.contentView, event.locationInWindow);
}

@implementation FTTabDrag

+ (NSString *)registerObject:(id)object {
    if (!object) return nil;
    NSString *token = NSUUID.UUID.UUIDString;
    @synchronized (FTTabDrag.class) {
        if (!gTabDragTokens) gTabDragTokens = [NSMutableDictionary dictionary];
        gTabDragTokens[token] = object;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (![gInteractiveToken isEqualToString:token]) [FTTabDrag forgetToken:token];
    });
    return token;
}

+ (id)objectForToken:(NSString *)token {
    if (!token.length) return nil;
    @synchronized (FTTabDrag.class) { return gTabDragTokens[token]; }
}

+ (void)forgetToken:(NSString *)token {
    if (!token.length) return;
    @synchronized (FTTabDrag.class) { [gTabDragTokens removeObjectForKey:token]; }
}

+ (BOOL)isDragging { return gInteractiveDrag; }

+ (void)clearTarget {
    if ([gInteractiveTarget isKindOfClass:TabBarView.class])
        [(TabBarView *)gInteractiveTarget clearDropHighlight];
    else if ([gInteractiveTarget isKindOfClass:FTTabDropView.class])
        [(FTTabDropView *)gInteractiveTarget clearDropHighlight];
    gInteractiveTarget = nil;
}

+ (void)updateInteractiveDragWithEvent:(NSEvent *)event {
    if (!gInteractiveDrag || gInteractiveFinalizing) return;
    NSView *target = targetForEvent(event);
    if (target != gInteractiveTarget) {
        [self clearTarget];
        gInteractiveTarget = target;
    }
    NSPoint point = [target convertPoint:event.locationInWindow fromView:nil];
    if ([target isKindOfClass:TabBarView.class])
        [(TabBarView *)target updateToken:gInteractiveToken terminal:gInteractiveTerminal atPoint:point];
    else if ([target isKindOfClass:FTTabDropView.class])
        [(FTTabDropView *)target updateToken:gInteractiveToken terminal:gInteractiveTerminal atPoint:point];
}

+ (void)finishInteractiveDragWithEvent:(NSEvent *)event {
    if (!gInteractiveDrag || gInteractiveFinalizing) return;
    // Mouse-up can arrive at a different location from the final drag update.
    if (event) [self updateInteractiveDragWithEvent:event];
    gInteractiveFinalizing = YES;
    NSView *target = gInteractiveTarget;
    TabBarView *source = gInteractiveSource;
    NSString *token = gInteractiveToken;
    BOOL terminal = gInteractiveTerminal;
    NSPoint point = event ? [target convertPoint:event.locationInWindow fromView:nil] : NSZeroPoint;
    if (gInteractiveMonitor) [NSEvent removeMonitor:gInteractiveMonitor];
    gInteractiveMonitor = nil;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (gResignObserver) [nc removeObserver:gResignObserver];
    if (gCloseObserver) [nc removeObserver:gCloseObserver];
    gResignObserver = gCloseObserver = nil;
    @try {
        if (event && [target isKindOfClass:TabBarView.class])
            [(TabBarView *)target acceptToken:token terminal:terminal atPoint:point];
        else if (event && [target isKindOfClass:FTTabDropView.class])
            [(FTTabDropView *)target acceptToken:token terminal:terminal atPoint:point];
    } @finally {
        [self clearTarget];
        [source finishTabDrag];
        if (!terminal) [self forgetToken:token];
        gInteractiveSource = nil;
        gInteractiveToken = nil;
        gInteractiveWindow = nil;
        gInteractiveDrag = gInteractiveTerminal = gInteractiveFinalizing = NO;
    }
}

+ (void)beginInteractiveDragWithToken:(NSString *)token
                           terminal:(BOOL)terminal
                             source:(NSView *)source
                              event:(NSEvent *)event {
    NSAssert(NSThread.isMainThread, @"Tab dragging is main-thread-only");
    [self endDragging];
    if (!token.length || !source.window || ![source isKindOfClass:TabBarView.class]) return;
    gInteractiveDrag = YES;
    gInteractiveTerminal = terminal;
    gInteractiveToken = [token copy];
    gInteractiveWindow = source.window;
    gInteractiveSource = (TabBarView *)source;
    gInteractiveMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
            if (!gInteractiveDrag) return e;
            if (e.type == NSEventTypeKeyDown) {
                if (e.keyCode == 53) { [FTTabDrag endDragging]; return nil; }
                return e;
            }
            if (e.type == NSEventTypeLeftMouseUp) [FTTabDrag finishInteractiveDragWithEvent:e];
            else [FTTabDrag updateInteractiveDragWithEvent:e];
            // The source owns the gesture. Do not let a terminal or HTML page handle it too,
            // or dispatch mouse-up against views that the drop has just removed.
            return nil;
        }];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    gResignObserver = [nc addObserverForName:NSApplicationWillResignActiveNotification object:NSApp
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [FTTabDrag endDragging]; }];
    gCloseObserver = [nc addObserverForName:NSWindowWillCloseNotification object:source.window
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { [FTTabDrag endDragging]; }];
    if (event) [self updateInteractiveDragWithEvent:event];
}

+ (void)endDragging { [self finishInteractiveDragWithEvent:nil]; }

@end

@implementation FTTabDropOverlay
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)isAccessibilityElement { return NO; }
- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 2, 2);
    if (NSIsEmptyRect(r)) return;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4];
    [[NSColor.controlAccentColor colorWithAlphaComponent:.12] setFill];
    [path fill];
    [NSColor.controlAccentColor setStroke];
    path.lineWidth = 2;
    [path stroke];
}
@end

@implementation FTTabDropView {
    FTTabDropOverlay *_dropOverlay;
    FTTabDropZone _dropZone;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) [self registerForDraggedTypes:@[FTTabDragType, FTTerminalDragType]];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) [self registerForDraggedTypes:@[FTTabDragType, FTTerminalDragType]];
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSRect)dropContentRect {
    NSRect r = self.bounds;
    CGFloat header = MIN(30, r.size.height);
    if (self.isFlipped) r.origin.y += header;
    r.size.height -= header;
    return r;
}

- (FTTabDropZone)dropZoneForPoint:(NSPoint)point {
    NSRect r = [self dropContentRect];
    if (!NSPointInRect(point, r)) return FTTabDropInto;
    CGFloat edge = MIN(120, r.size.width * .25);
    if (point.x < NSMinX(r) + edge) return FTTabDropBefore;
    if (point.x > NSMaxX(r) - edge) return FTTabDropAfter;
    return FTTabDropInto;
}

- (NSRect)dropPreviewRectForZone:(FTTabDropZone)zone {
    NSRect r = [self dropContentRect];
    if (zone == FTTabDropBefore) r.size.width = floor(r.size.width / 2);
    else if (zone == FTTabDropAfter) {
        CGFloat half = floor(r.size.width / 2);
        r.origin.x = NSMaxX(r) - half;
        r.size.width = half;
    }
    return r;
}

- (void)layoutDropHighlight {
    if (_dropOverlay) _dropOverlay.frame = [self dropPreviewRectForZone:_dropZone];
}

- (void)layout {
    [super layout];
    [self layoutDropHighlight];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self layoutDropHighlight];
}

- (BOOL)canAcceptToken:(NSString *)token terminal:(BOOL)terminal zone:(FTTabDropZone)zone {
    return token.length && zone >= FTTabDropInto && zone <= FTTabDropAfter && self.onDropTab &&
        (!self.canDropTab || self.canDropTab(token, terminal, zone));
}

- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal zone:(FTTabDropZone)zone index:(NSInteger)index {
    return [self canAcceptToken:token terminal:terminal zone:zone] && self.onDropTab(token, terminal, zone, index);
}

- (BOOL)updateToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point {
    FTTabDropZone zone = [self dropZoneForPoint:point];
    NSRect r = [self dropContentRect];
    // A small dead band prevents the preview flickering between a split and a merge.
    CGFloat edge = MIN(120, r.size.width * .25);
    if (_dropOverlay && NSPointInRect(point, r)) {
        if (_dropZone == FTTabDropBefore && point.x < NSMinX(r) + edge + 8) zone = FTTabDropBefore;
        else if (_dropZone == FTTabDropAfter && point.x > NSMaxX(r) - edge - 8) zone = FTTabDropAfter;
        else if (_dropZone == FTTabDropInto && point.x >= NSMinX(r) + edge - 8 &&
                 point.x <= NSMaxX(r) - edge + 8) zone = FTTabDropInto;
    }
    if (!NSPointInRect(point, r) || ![self canAcceptToken:token terminal:terminal zone:zone]) {
        [self clearDropHighlight];
        return NO;
    }
    _dropZone = zone;
    if (!_dropOverlay) {
        _dropOverlay = [[FTTabDropOverlay alloc] initWithFrame:NSZeroRect];
        [self addSubview:_dropOverlay positioned:NSWindowAbove relativeTo:nil];
    }
    [self layoutDropHighlight];
    _dropOverlay.needsDisplay = YES;
    return YES;
}

- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point {
    if (![self updateToken:token terminal:terminal atPoint:point]) return NO;
    FTTabDropZone zone = _dropZone;
    [self clearDropHighlight];
    return [self acceptToken:token terminal:terminal zone:zone index:-1];
}

- (void)clearDropHighlight {
    [_dropOverlay removeFromSuperview];
    _dropOverlay = nil;
}

- (NSString *)tokenFromDrag:(id<NSDraggingInfo>)sender terminal:(BOOL *)terminal {
    NSString *token = [sender.draggingPasteboard stringForType:FTTabDragType];
    *terminal = NO;
    if (!token.length) { token = [sender.draggingPasteboard stringForType:FTTerminalDragType]; *terminal = YES; }
    return token;
}

- (NSDragOperation)updateDrop:(id<NSDraggingInfo>)sender {
    BOOL terminal;
    NSString *token = [self tokenFromDrag:sender terminal:&terminal];
    NSPoint point = [self convertPoint:sender.draggingLocation fromView:nil];
    return [self updateToken:token terminal:terminal atPoint:point] ? NSDragOperationMove : NSDragOperationNone;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self updateDrop:sender]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self updateDrop:sender]; }
- (void)draggingExited:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }
- (void)draggingEnded:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return [self updateDrop:sender] != NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    BOOL terminal;
    NSString *token = [self tokenFromDrag:sender terminal:&terminal];
    return [self acceptToken:token terminal:terminal atPoint:[self convertPoint:sender.draggingLocation fromView:nil]];
}
- (void)concludeDragOperation:(id<NSDraggingInfo>)sender { [self clearDropHighlight]; }
@end

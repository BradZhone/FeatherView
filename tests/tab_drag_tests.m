// Local mouse-event dragging through the real application window, including HTML and live PTYs.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "TabBarView.h"
#import "FTTabDrag.h"
#import "FTSplitView.h"
#import "TerminalPanel.h"
#import "TerminalView.h"
#import "MarkupView.h"
#import "TextEditorView.h"

@interface AppDelegate (TabDragTests)
- (void)buildWindow;
@end

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)
static AppDelegate *app;
static NSWindow *window;
static ContentController *cc;
static NSTimeInterval stamp;
static NSArray *rootItems;
static NSRect windowFrame, sidebarFrame, contentFrame;

static void drain(double seconds) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static NSView *rootHit(NSPoint p) {
    NSView *root = window.contentView;
    while (root.superview) root = root.superview;
    return [root hitTest:[root convertPoint:p fromView:nil]];
}

static NSEvent *mouse(NSEventType type, NSPoint point) {
    stamp += .7; // Never mistake two separate drags for a tab double-click.
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:stamp
        windowNumber:window.windowNumber context:nil eventNumber:(NSInteger)(stamp * 10) clickCount:1
        pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

static void deliver(NSEvent *event) {
    [NSApp postEvent:event atStart:YES];
    NSEvent *queued = [NSApp nextEventMatchingMask:NSEventMaskAny
        untilDate:[NSDate dateWithTimeIntervalSinceNow:.03] inMode:NSDefaultRunLoopMode dequeue:YES];
    if (queued) [NSApp sendEvent:queued];
}

static NSArray<TabBarView *> *bars(void) { return [[cc valueForKey:@"_tabBars"] copy]; }
static NSArray<FTTabDropView *> *panes(void) { return [[cc valueForKey:@"_panes"] copy]; }
static TerminalPanel *panel(void) { return [cc valueForKey:@"_terminalPanel"]; }
static NSArray *docs(void) { return [[cc valueForKey:@"_docs"] copy]; }
static NSArray *paths(NSUInteger pane) {
    NSMutableArray *out = [NSMutableArray array];
    for (id doc in docs()) if ([[doc valueForKey:@"pane"] unsignedIntegerValue] == pane)
        [out addObject:[doc valueForKey:@"path"] ?: @""];
    return out;
}
static NSPoint bodyPoint(FTTabDropView *pane, FTTabDropZone zone) {
    NSRect r = pane.dropContentRect;
    return [pane convertPoint:NSMakePoint(zone == FTTabDropBefore ? NSMinX(r) + 4 :
        zone == FTTabDropAfter ? NSMaxX(r) - 4 : NSMidX(r), NSMidY(r)) toView:nil];
}
static NSPoint tabPoint(TabBarView *bar, NSInteger index, BOOL trailing) {
    NSRect r = [bar rectForTab:index];
    return [bar convertPoint:NSMakePoint(trailing ? MIN(NSMaxX(bar.bounds) - 3, NSMaxX(r) - 3) :
        MAX(NSMinX(bar.bounds) + 3, NSMinX(r) + 12), NSMidY(r)) toView:nil];
}

static void snapshot(NSString *name) {
    NSString *dir = NSProcessInfo.processInfo.environment[@"FEATHER_DRAG_SNAPSHOTS"];
    if (!dir.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSView *view = window.contentView;
    [view layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    CHECK([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES], "save drag preview snapshot");
}

static TabBarView *start(TabBarView *source, NSInteger index) {
    [source finishTabDrag];
    NSPoint point = tabPoint(source, index, NO);
    NSView *receiver = rootHit(point);
    CHECK(receiver == source, "source tab is reached through the main window root (%s)", receiver.className.UTF8String);
    if (receiver != source) return nil;
    rootItems = window.contentView.subviews.copy;
    windowFrame = window.frame; sidebarFrame = app->_sidebar.frame; contentFrame = cc.view.frame;
    [receiver mouseDown:mouse(NSEventTypeLeftMouseDown, point)];
    point.x += 9;
    [receiver mouseDragged:mouse(NSEventTypeLeftMouseDragged, point)];
    CHECK(FTTabDrag.isDragging, "actual mouse drag starts a local token gesture");
    CHECK([[source valueForKey:@"_nativeDrag"] boolValue], "source records an in-flight gesture");
    return source;
}

static void hover(NSPoint p) {
    deliver(mouse(NSEventTypeLeftMouseDragged, p));
    CHECK(FTTabDrag.isDragging, "hover retains the drag");
    CHECK([window.contentView.subviews isEqualToArray:rootItems] && NSEqualRects(window.frame, windowFrame) &&
        NSEqualRects(app->_sidebar.frame, sidebarFrame) && NSEqualRects(cc.view.frame, contentFrame),
        "hover never adds a root split child, resizes the window or blanks half the content");
}

static void done(TabBarView *source, NSPoint p) {
    deliver(mouse(NSEventTypeLeftMouseUp, p));
    CHECK(!FTTabDrag.isDragging, "queued mouse-up finishes the drag");
    CHECK([[source valueForKey:@"_dragIndex"] integerValue] == -1 &&
        ![[source valueForKey:@"_nativeDrag"] boolValue], "source state clears even when AppKit consumes mouse-up");
}

static void preview(FTTabDropView *pane, FTTabDropZone zone) {
    NSView *overlay = [pane valueForKey:@"_dropOverlay"];
    CHECK(overlay && overlay.superview == pane, "body target displays a mounted preview");
    CHECK(NSEqualRects(overlay.frame, [pane dropPreviewRectForZone:zone]), "blue preview matches its half-body geometry");
    CHECK(NSMinY(overlay.frame) >= NSMinY(pane.dropContentRect) &&
        NSMaxY(overlay.frame) <= NSMaxY(pane.dropContentRect), "preview excludes the entire tab header");
    if (zone != FTTabDropInto) CHECK(fabs(overlay.frame.size.width - pane.dropContentRect.size.width / 2) <= 1,
        "split preview uses half the target body, not a narrow activation strip");
    for (NSUInteger i = 0; i < 6; i++) hover(bodyPoint(pane, zone));
    CHECK([pane valueForKey:@"_dropOverlay"] == overlay, "repeated updates reuse one stable preview");
}

static void editorDrags(NSString *root) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in @[@"one.txt", @"two.txt", @"page.html"]) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSString *text = [name hasSuffix:@"html"] ? @"<html><body><h1>Drag preview</h1><p>HTML stays interactive.</p></body></html>" : @"original\n";
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [files addObject:path];
        [cc openPath:path preview:NO focus:YES];
    }
    CHECK(cc.activeMarkupLayout == MarkupPreview, "HTML fixture starts rendered");
    id htmlDoc = docs().lastObject;
    NSView *viewer = [htmlDoc valueForKey:@"viewer"];
    TabBarView *source = start(bars()[0], 0);
    NSPoint last = tabPoint(bars()[0], 2, YES);
    hover(last);
    CHECK([[bars()[0] valueForKey:@"_dropIndex"] integerValue] == 3 && ![panes()[0] valueForKey:@"_dropOverlay"],
        "tab header shows an insertion line, never a blue split box");
    snapshot(@"header-reorder.png");
    done(source, last);
    CHECK(([paths(0) isEqualToArray:@[files[1], files[2], files[0]]]), "editor tab reorders forwards");
    source = start(bars()[0], 2);
    NSPoint first = tabPoint(bars()[0], 0, NO);
    hover(first); done(source, first);
    CHECK([paths(0) isEqualToArray:files], "editor tab reorders backwards on the next drag");

    source = start(bars()[0], 2);
    FTTabDropView *target = panes()[0];
    NSPoint right = bodyPoint(target, FTTabDropAfter);
    hover(right); preview(target, FTTabDropAfter);
    snapshot(@"html-split-preview.png");
    done(source, right);
    CHECK(cc.paneCount == 2 && [paths(1) isEqualToArray:@[files[2]]], "HTML splits through mouse events");
    CHECK([htmlDoc valueForKey:@"viewer"] == viewer && [viewer isDescendantOf:panes()[1]], "HTML viewer identity survives the split");
    CHECK(![panes()[0] valueForKey:@"_dropOverlay"], "drop removes the old preview");
    source = start(bars()[1], 0);
    NSPoint center = bodyPoint(panes()[0], FTTabDropInto);
    hover(center); done(source, center);
    CHECK(cc.paneCount == 1 && cc.tabCount == 3, "merging the HTML pane removes only the empty source");

    source = start(bars()[0], 1);
    target = panes()[0];
    NSPoint left = bodyPoint(target, FTTabDropBefore);
    hover(left); preview(target, FTTabDropBefore); done(source, left);
    CHECK(cc.paneCount == 2 && [paths(0) isEqualToArray:@[files[1]]], "left split works with the sidebar's nonzero origin");
    source = start(bars()[0], 0);
    // No drag update at the release destination: finish must resolve mouse-up again.
    hover(bodyPoint(panes()[1], FTTabDropBefore));
    done(source, tabPoint(bars()[1], (NSInteger)bars()[1].items.count - 1, YES));
    CHECK(cc.paneCount == 1 && cc.tabCount == 3, "release over a tab strip overrides a stale body target");

    source = start(bars()[0], 0);
    hover(bodyPoint(panes()[0], FTTabDropAfter));
    NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:stamp + .1
        windowNumber:window.windowNumber context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
    deliver(escape);
    CHECK(!FTTabDrag.isDragging && cc.paneCount == 1 && ![panes()[0] valueForKey:@"_dropOverlay"], "Esc cancels without moving tabs");
    source = start(bars()[0], 0);
    hover(bodyPoint(panes()[0], FTTabDropBefore));
    done(source, NSMakePoint(-40, -40));
    CHECK(cc.paneCount == 1 && ![panes()[0] valueForKey:@"_dropOverlay"], "release outside the content cancels and clears highlight");
    source = start(bars()[0], 0);
    FTTabDropView *cancelTarget = panes()[0];
    NSPoint cancelLeft = bodyPoint(cancelTarget, FTTabDropBefore);
    hover(cancelLeft);
    NSView *cancelOverlay = [cancelTarget valueForKey:@"_dropOverlay"];
    NSRect body = cancelTarget.dropContentRect;
    CGFloat edge = MIN(120, body.size.width * .25);
    NSPoint jitter = [cancelTarget convertPoint:NSMakePoint(NSMinX(body) + edge + 3, NSMidY(body)) toView:nil];
    hover(jitter);
    CHECK([cancelTarget valueForKey:@"_dropOverlay"] == cancelOverlay &&
          NSEqualRects(cancelOverlay.frame, [cancelTarget dropPreviewRectForZone:FTTabDropBefore]),
          "small pointer jitter retains the visible split zone");
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillResignActiveNotification object:NSApp];
    CHECK(!FTTabDrag.isDragging && ![cancelTarget valueForKey:@"_dropOverlay"] && cc.paneCount == 1,
          "application deactivation cancels and removes preview");
    CHECK([[source valueForKey:@"_dragIndex"] integerValue] == -1, "focus-loss cancellation resets source");
    source = start(bars()[0], 0);
    hover(cancelLeft);
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:window];
    CHECK(!FTTabDrag.isDragging && ![cancelTarget valueForKey:@"_dropOverlay"], "window closing cancels local dragging");
    [cc showFindBar];
    body = cancelTarget.dropContentRect;
    CHECK(NSMinY(body) == 62, "editor drop body excludes the find bar as well as the tabs");
    source = start(bars()[0], 0);
    hover(bodyPoint(cancelTarget, FTTabDropAfter));
    preview(cancelTarget, FTTabDropAfter);
    [FTTabDrag endDragging];
}

static void terminalDrags(NSString *root) {
    NSMutableArray<TSession *> *sessions = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        TSession *session = [cc openTerminalAt:root asTab:NO];
        CHECK(session != nil, "create isolated live PTY");
        if (session) [sessions addObject:session];
    }
    if (sessions.count != 3) return;
    TerminalPanel *tp = panel();
    CHECK(tp.columnCount == 1 && tp.tabCount == 3, "terminal fixtures share a column");
    TSession *moving = sessions[0];
    TerminalView *view = [[cc valueForKey:@"_terminalViews"] objectForKey:moving];
    pid_t pid = moving.pid;
    TScreen *screen = moving.screen;
    TabBarView *source = start(tp.tabBars[0], 0);
    NSPoint last = tabPoint(tp.tabBars[0], 2, YES);
    hover(last); done(source, last);
    CHECK(tp.sessions.lastObject == moving, "terminal reorders forwards");
    source = start(tp.tabBars[0], 2);
    NSPoint first = tabPoint(tp.tabBars[0], 0, NO);
    hover(first); done(source, first);
    CHECK([tp.sessions isEqualToArray:sessions], "terminal reorders backwards on a second drag");

    source = start(tp.tabBars[0], 1);
    FTTabDropView *target = (id)tp.columnViews[0];
    NSPoint right = bodyPoint(target, FTTabDropAfter);
    hover(right); preview(target, FTTabDropAfter);
    snapshot(@"terminal-split-preview.png");
    done(source, right);
    CHECK(tp.columnCount == 2 && tp.tabBars[0].items.count == 2 && tp.tabBars[1].items.count == 1,
        "terminal splits into independent tab strips");
    source = start(tp.tabBars[1], 0);
    NSPoint center = bodyPoint((id)tp.columnViews[0], FTTabDropInto);
    hover(center); done(source, center);
    CHECK(tp.columnCount == 1 && tp.tabCount == 3, "terminal central merge preserves every session");

    [tp focusSession:moving];
    source = start(tp.tabBars[0], 0);
    center = bodyPoint(panes()[0], FTTabDropInto);
    hover(center); done(source, center);
    CHECK(![tp containsSession:moving] && cc.terminalCount == 3 && cc.activeTerminal == moving,
        "terminal moves from panel into an editor tab");
    CHECK([[cc valueForKey:@"_terminalViews"] objectForKey:moving] == view && moving.pid == pid && moving.screen == screen,
        "panel-to-editor move preserves TerminalView, PTY process and screen");
    TabBarView *bar = bars()[0];
    source = start(bar, bar.selectedIndex);
    center = bodyPoint((id)tp.columnViews[0], FTTabDropInto);
    hover(center); done(source, center);
    CHECK([tp containsSession:moving] && tp.tabCount == 3 && cc.terminalCount == 3,
        "editor terminal moves back into the panel");
    CHECK([[cc valueForKey:@"_terminalViews"] objectForKey:moving] == view && moving.pid == pid && moving.screen == screen &&
        view.window == window, "terminal view remains canonical after the round trip");

    NSString *marker = [root stringByAppendingPathComponent:@"pty-alive"];
    [moving writeString:[NSString stringWithFormat:@"printf alive > '%@'\n", marker]];
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:4];
    while (![[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"alive"] && until.timeIntervalSinceNow > 0) drain(.02);
    CHECK([[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"alive"],
        "original PTY executes commands after reordering, splitting, merging and migration");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        stamp = NSProcessInfo.processInfo.systemUptime;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        app = [AppDelegate new];
        @try {
            [app buildWindow];
            window = app->_win; cc = app->_content;
            cc.autoSaveMode = AutoSaveOff;
            cc.workspaceRoot = root;
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"htmlLayout"];
            [window makeKeyAndOrderFront:nil];
            drain(.1);
            CHECK(window.contentView == app->_split && app->_split.subviews.count == 2, "test uses the actual outer sidebar split");
            editorDrags(root);
            terminalDrags(root);
        } @catch (NSException *exception) {
            CHECK(NO, "uncaught %s: %s", exception.name.UTF8String, exception.reason.UTF8String);
        } @finally {
            [FTTabDrag endDragging];
            [cc shutdownTerminals];
            [cc closeAllWithoutAsking];
            [window orderOut:nil];
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
    }
    printf("%d tab drag checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}

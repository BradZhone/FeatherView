// File tree controls exercised through the window, with private defaults and temporary folders.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "TextEditorView.h"
#import "TerminalView.h"
#import "Localization.h"

@interface AppDelegate (FileTreeTests)
- (void)buildWindow;
- (void)buildMenu;
@end

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static BOOL spinUntil(BOOL (^ready)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!ready() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return ready();
}

static NSString *folder(NSString *root, NSString *name) {
    NSString *path = [root stringByAppendingPathComponent:name];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil], "create fixture folder");
    return path;
}

static NSString *file(NSString *root, NSString *name) {
    NSString *path = [root stringByAppendingPathComponent:name];
    CHECK([@"original\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil], "create fixture file");
    return path;
}

static NSInteger rowForPath(NSOutlineView *ov, NSString *path) {
    for (NSInteger r = 0; r < ov.numberOfRows; r++)
        if ([[(FileNode *)[ov itemAtRow:r] path] isEqualToString:path]) return r;
    return -1;
}

static FileNode *nodeForPath(NSOutlineView *ov, NSString *path) {
    NSInteger row = rowForPath(ov, path);
    return row >= 0 ? [ov itemAtRow:row] : nil;
}

static void setFolderExpanded(NSOutlineView *ov, FileNode *node, BOOL expanded) {
    CHECK(node != nil, "folder node is available for direct outline state change");
    if (!node) return;
    if (expanded) [ov expandItem:node]; else [ov collapseItem:node collapseChildren:YES];
}

static NSView *rootHit(NSWindow *window, NSPoint windowPoint) {
    NSView *root = window.contentView;
    while (root.superview) root = root.superview;
    return [root hitTest:[root convertPoint:windowPoint fromView:nil]];
}

// Queue the release before dispatching the press, so AppKit's native tracking loop can consume it.
static void click(NSWindow *window, NSView *view, NSPoint point, NSEventModifierFlags flags, NSInteger count) {
    NSPoint location = [view convertPoint:point toView:nil];
    NSView *hit = rootHit(window, location);
    CHECK(hit == view || [hit isDescendantOf:view], "window hit testing reaches %s, got %s", view.className.UTF8String, hit.className.UTF8String);
    static NSInteger number;
    NSInteger eventNumber = ++number;
    NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:location modifierFlags:flags
                                  timestamp:timestamp + 0.05 windowNumber:window.windowNumber context:nil
                                eventNumber:eventNumber clickCount:count pressure:0];
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:location modifierFlags:flags
                                    timestamp:timestamp windowNumber:window.windowNumber context:nil
                                  eventNumber:eventNumber clickCount:count pressure:1];
    [NSApp postEvent:up atStart:YES];
    [NSApp postEvent:down atStart:YES];
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseDown untilDate:[NSDate dateWithTimeIntervalSinceNow:1]
                                         inMode:NSDefaultRunLoopMode dequeue:YES];
    CHECK(event != nil, "queued press is delivered");
    if (event) [hit mouseDown:event];
    event = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [hit mouseUp:event];
    [window.contentView layoutSubtreeIfNeeded];
}

static void clickButton(NSButton *button) {
    CHECK(button.window && !button.hiddenOrHasHiddenAncestor, "button is mounted and visible");
    click(button.window, button, NSMakePoint(NSMidX(button.bounds), NSMidY(button.bounds)), 0, 1);
}

static void folderControls(AppDelegate *app, NSString *root) {
    FileTree *tree = app->_tree;
    NSOutlineView *ov = app->_outline;
    NSString *alpha = [root stringByAppendingPathComponent:@"alpha"];
    NSString *nested = [alpha stringByAppendingPathComponent:@"nested"];
    NSString *leaf = [nested stringByAppendingPathComponent:@"leaf.txt"];
    NSString *beta = [root stringByAppendingPathComponent:@"beta"];
    NSString *other = [beta stringByAppendingPathComponent:@"other.txt"];
    NSString *top = [root stringByAppendingPathComponent:@"top.txt"];
    __block NSUInteger opened = 0;
    void (^onOpen)(NSString *, BOOL) = tree.onOpen;
    tree.onOpen = ^(NSString *path, BOOL pinned) { opened++; if (onOpen) onOpen(path, pinned); };

    CHECK(tree.collapseButton.superview == app->_treeHeader && !app->_treeHeader.hidden, "Collapse All is mounted in the Files header");
    CHECK([tree.collapseButton.title isEqualToString:FTL(@"Collapse All")] && tree.collapseButton.accessibilityLabel.length,
          "collapse action has visible and accessible text");
    CHECK(NSMaxY(app->_treeHeader.frame) <= NSMinY(app->_treeScroll.frame), "tree header does not cover the first row");
    CHECK(!tree.collapseButton.enabled && ov.numberOfRows == 4, "new root starts collapsed with disabled action");

    setFolderExpanded(ov, nodeForPath(ov, alpha), YES);
    CHECK(spinUntil(^BOOL { return [ov isItemExpanded:nodeForPath(ov, alpha)]; }, 1), "folder state expands through outline API");
    CHECK(tree.collapseButton.enabled && opened == 0, "folder disclosure enables Collapse All and opens no document");
    setFolderExpanded(ov, nodeForPath(ov, alpha), NO);
    CHECK(spinUntil(^BOOL { return ![ov isItemExpanded:nodeForPath(ov, alpha)]; }, 1), "folder state collapses through outline API");
    CHECK(!tree.collapseButton.enabled, "collapsing the last expanded folder disables action");
    setFolderExpanded(ov, nodeForPath(ov, alpha), YES);
    CHECK(spinUntil(^BOOL { return [ov isItemExpanded:nodeForPath(ov, alpha)]; }, 1), "folder state expands exactly once");
    setFolderExpanded(ov, nodeForPath(ov, alpha), NO);
    CHECK(spinUntil(^BOOL { return ![ov isItemExpanded:nodeForPath(ov, alpha)]; }, 1), "folder state collapses exactly once");
    CHECK(opened == 0, "folder disclosure never opens a document");

    [app->_content openPath:top preview:NO focus:NO];
    [app->_content openPath:leaf preview:NO focus:YES];
    app->_content.autoSaveMode = AutoSaveOff;
    TextEditorView *editor = app->_content.editor;
    [(id<NSTextInputClient>)editor insertText:@"unsaved" replacementRange:NSMakeRange(NSNotFound, 0)];
    [editor selectLine:1 column:1 length:3];
    NSString *selection = editor.selectedText;
    NSArray *openPaths = app->_content.openPaths;
    NSUInteger tabs = app->_content.tabCount;
    [tree revealPaths:@[leaf, other]];
    FileNode *alphaNode = nodeForPath(ov, alpha), *nestedNode = nodeForPath(ov, nested), *betaNode = nodeForPath(ov, beta);
    CHECK([ov isItemExpanded:alphaNode] && [ov isItemExpanded:nestedNode] && [ov isItemExpanded:betaNode], "both branches and nested directories expanded");
    CHECK(opened == 0, "programmatic reveal does not open documents");
    clickButton(tree.collapseButton);
    CHECK(ov.numberOfRows == 4 && ![ov isItemExpanded:alphaNode] && ![ov isItemExpanded:nestedNode] && ![ov isItemExpanded:betaNode],
          "header mouse click collapses all branches, including nested expansion state");
    CHECK(!tree.collapseButton.enabled && opened == 0, "collapse updates button without opening a file");
    CHECK([app->_content.currentPath isEqualToString:leaf] && app->_content.editor == editor && app->_content.tabCount == tabs &&
          [app->_content.openPaths isEqualToArray:openPaths] && editor.isDirty && [editor.selectedText isEqualToString:selection],
          "collapse preserves the active editor, open documents, unsaved edits and text selection");
    for (NSString *path in tree.selectedPaths)
        CHECK(rowForPath(ov, path) >= 0, "outline selection only contains visible rows");
    [tree reload];
    CHECK(ov.numberOfRows == 4 && ![ov isItemExpanded:alphaNode] && !tree.collapseButton.enabled, "reload keeps folders collapsed");

    setFolderExpanded(ov, alphaNode, YES);
    CHECK([ov isItemExpanded:alphaNode] && ![ov isItemExpanded:nestedNode], "normal reopen leaves nested directories collapsed");
    setFolderExpanded(ov, nestedNode, YES);
    CHECK(spinUntil(^BOOL { return [ov isItemExpanded:nestedNode]; }, 1), "nested directory reopens normally");
    CHECK(opened == 0, "reopening directories opens no document");
    [tree collapseAll:nil];
    [tree revealPath:leaf];
    CHECK([tree.selectedPath isEqualToString:leaf] && tree.collapseButton.enabled && opened == 0,
          "explicit reveal after collapse reopens ancestors without opening a document");

    clickButton(tree.collapseButton);
    [tree revealPath:top];
    CHECK([tree.selectedPath isEqualToString:top] && !tree.collapseButton.enabled, "selecting a top-level file keeps all folders collapsed");
    [tree collapseAll:nil];
    CHECK([tree.selectedPath isEqualToString:top], "collapse preserves a visible file selection");
    [tree revealPath:leaf];
    __block BOOL refreshed = NO;
    tree.onRefreshed = ^{ refreshed = YES; };
    file(nested, @"new.txt");
    [tree refreshInBackground];
    clickButton(tree.collapseButton);
    CHECK(spinUntil(^BOOL { return refreshed; }, 3), "background filesystem refresh completes after collapse");
    CHECK(ov.numberOfRows == 4 && !tree.collapseButton.enabled && ![ov isItemExpanded:alphaNode], "an in-flight refresh does not reopen collapsed directories");
    tree.onRefreshed = nil;
    tree.onOpen = onOpen;
}

static double medianOf5(double *v) {
    double a[5];
    memcpy(a, v, sizeof(a));
    for (int i = 0; i < 5; i++) for (int j = i + 1; j < 5; j++) if (a[j] < a[i]) { double t = a[i]; a[i] = a[j]; a[j] = t; }
    return a[2];
}

// The compositor's own output, not cacheDisplayInRect:. A divider AppKit draws for a collapsed
// subview is missing from an offscreen cache render but present on screen, so only this catches it.
static NSBitmapImageRep *windowComposite(AppDelegate *app, NSString *name) {
    [app->_win.contentView layoutSubtreeIfNeeded];
    [app->_win display];
    for (int i = 0; i < 10; i++) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                               (CGWindowID)app->_win.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    if (!image) return nil;                       // no Screen Recording permission for this process
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
    CGImageRelease(image);
    NSString *dir = NSProcessInfo.processInfo.environment[@"FEATHERVIEW_FILE_TREE_SNAPSHOTS"];
    if (dir.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    }
    return rep;
}

// x of the darkest column that is darker than the page on both sides, or -1. The step between
// the sidebar and the editor is one-sided, so it never registers; a stray hairline does.
static NSInteger darkLineColumn(NSBitmapImageRep *rep, double *dropOut) {
    NSInteger W = rep.pixelsWide, H = rep.pixelsHigh, y0 = H * 0.12, y1 = H * 0.95;
    if (W < 16 || H < 16) return -1;
    double *lum = calloc(W, sizeof(double)), worst = 0;
    NSInteger worstX = -1;
    for (NSInteger x = 0; x < W; x++) {
        double sum = 0; NSInteger n = 0;
        for (NSInteger y = y0; y < y1; y += 3) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            sum += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent;
            n++;
        }
        lum[x] = n ? sum / n : 1;
    }
    for (NSInteger x = 6; x + 6 < W; x++) {
        double left[5], right[5];
        for (int i = 0; i < 5; i++) { left[i] = lum[x - 6 + i]; right[i] = lum[x + 2 + i]; }
        double drop = MIN(medianOf5(left), medianOf5(right)) - lum[x];
        if (drop > worst) { worst = drop; worstX = x; }
    }
    free(lum);
    if (dropOut) *dropOut = worst;
    return worst > 0.04 ? worstX : -1;
}

static void checkNoDarkLine(AppDelegate *app, NSString *name) {
    NSBitmapImageRep *rep = windowComposite(app, name);
    if (!rep) { printf("  (skipped %s: on-screen capture needs Screen Recording permission)\n", name.UTF8String); return; }
    double drop = 0;
    NSInteger x = darkLineColumn(rep, &drop);
    CHECK(x < 0, "%s has no stray dark hairline (column %ld, %.0f%% darker than both sides)",
          name.UTF8String, (long)x, drop * 100);
}

// Drags the outer divider to a new x. NSSplitView tracks the mouse in its own loop, so the
// release and the move have to be queued before the press is handed over.
static void dragSidebarDivider(AppDelegate *app, CGFloat toX) {
    NSSplitView *split = app->_split;
    CGFloat fromX = app->_sidebar.frame.size.width, h = split.bounds.size.height;
    NSPoint from = [split convertPoint:NSMakePoint(fromX, h / 2) toView:nil];
    NSPoint to = [split convertPoint:NSMakePoint(toX, h / 2) toView:nil];
    NSView *hit = rootHit(app->_win, from);
    CHECK(hit == split, "the divider band hit-tests to the split view, got %s", hit.className.UTF8String);
    static NSInteger number;
    NSInteger eventNumber = ++number;
    NSTimeInterval stamp = NSProcessInfo.processInfo.systemUptime;
    NSEvent *(^mouse)(NSEventType, NSPoint, NSTimeInterval) = ^NSEvent *(NSEventType type, NSPoint p, NSTimeInterval dt) {
        return [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:stamp + dt
                              windowNumber:app->_win.windowNumber context:nil eventNumber:eventNumber
                                 clickCount:1 pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
    };
    [NSApp postEvent:mouse(NSEventTypeLeftMouseUp, to, 0.3) atStart:YES];
    [NSApp postEvent:mouse(NSEventTypeLeftMouseDragged, to, 0.2) atStart:YES];
    [NSApp postEvent:mouse(NSEventTypeLeftMouseDragged, NSMakePoint((from.x + to.x) / 2, from.y), 0.1) atStart:YES];
    [split mouseDown:mouse(NSEventTypeLeftMouseDown, from, 0)];
    [app->_win.contentView layoutSubtreeIfNeeded];
}

static NSMenuItem *menuItemFor(SEL action) {
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *i in top.submenu.itemArray) if (i.action == action) return i;
    return nil;
}

// A menu item with a nil target is sent to the first object in the responder chain that answers
// its action: key window's first responder, up to the window, its delegate, then NSApp and its
// delegate. A test process cannot become key window, so the chain is walked explicitly here —
// otherwise dispatch jumps straight to the delegate and hides exactly this class of bug.
static id responderClaiming(AppDelegate *app, SEL action) {
    NSMutableArray *chain = [NSMutableArray array];
    for (NSResponder *r = app->_win.firstResponder; r; r = r.nextResponder) [chain addObject:r];
    if (app->_win.delegate) [chain addObject:app->_win.delegate];
    [chain addObject:NSApp];
    if (NSApp.delegate) [chain addObject:NSApp.delegate];
    for (id r in chain) if ([r respondsToSelector:action]) return r;
    return nil;
}

// ⌘B through the real main menu, including with a terminal focused: a focused terminal gets first
// refusal on key equivalents, so it must still decline Command shortcuts.
static void sidebarShortcut(AppDelegate *app) {
    NSMenuItem *toggle = menuItemFor(@selector(toggleFileSidebar:));
    CHECK(toggle != nil && [toggle.keyEquivalent isEqualToString:@"b"] &&
          toggle.keyEquivalentModifierMask == NSEventModifierFlagCommand, "Hide Sidebar carries ⌘B");
    if (!toggle) return;
    CHECK([app validateMenuItem:toggle] && [toggle.title isEqualToString:FTL(@"Hide Sidebar")],
          "the item is enabled and names the hide action while the sidebar shows");

    // The action must not be a selector AppKit already implements: NSWindow and NSSplitView both
    // have toggleSidebar:, and both precede the delegate in the chain, so ⌘B hit AppKit's no-op.
    CHECK(![NSWindow instancesRespondToSelector:toggle.action] &&
          ![NSSplitView instancesRespondToSelector:toggle.action] &&
          ![NSView instancesRespondToSelector:toggle.action],
          "the sidebar action is not a selector AppKit's own window or split view answers");
    [app->_win makeFirstResponder:app->_outline];
    CHECK(responderClaiming(app, toggle.action) == app,
          "the delegate is the first responder-chain object that answers the sidebar action, got %s",
          NSStringFromClass([responderClaiming(app, toggle.action) class]).UTF8String);

    NSEvent *commandB = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                    modifierFlags:NSEventModifierFlagCommand timestamp:0
                                     windowNumber:app->_win.windowNumber context:nil
                                       characters:@"b" charactersIgnoringModifiers:@"b" isARepeat:NO keyCode:11];
    [app->_win makeFirstResponder:app->_outline];
    CGFloat width = app->_sidebar.frame.size.width;
    CHECK([NSApp.mainMenu performKeyEquivalent:commandB], "the main menu claims ⌘B");
    [app->_win.contentView layoutSubtreeIfNeeded];
    CHECK(app->_sidebar.hidden && app->_content.view.frame.origin.x == 0,
          "⌘B collapses the file tree and hands its width to the editor (x %.0f)", app->_content.view.frame.origin.x);
    CHECK([app validateMenuItem:toggle] && [toggle.title isEqualToString:FTL(@"Show Sidebar")],
          "the collapsed state renames the item to the reopen action");
    [NSApp.mainMenu performKeyEquivalent:commandB];
    [app->_win.contentView layoutSubtreeIfNeeded];
    CHECK(!app->_sidebar.hidden && fabs(app->_sidebar.frame.size.width - width) < 1,
          "⌘B reopens the file tree at its previous width (%.0f -> %.0f)", width, app->_sidebar.frame.size.width);

    // With the text editor focused: ⌘B is "bold" in a stock NSTextView, and the editor must not
    // swallow it or insert anything.
    NSString *file = [app->_tree.rootPath stringByAppendingPathComponent:@"top.txt"];
    [app->_content openPath:file preview:NO focus:YES];
    [app->_win.contentView layoutSubtreeIfNeeded];
    TextEditorView *editor = app->_content.editor;
    if (editor) {
        [app->_win makeFirstResponder:editor];
        NSUInteger before = editor.contentLength;
        CHECK([NSApp.mainMenu performKeyEquivalent:commandB] && app->_sidebar.hidden,
              "⌘B collapses the file tree while the editor has the focus");
        CHECK(editor.contentLength == before && !editor.isDirty, "⌘B types nothing into the document");
        [NSApp.mainMenu performKeyEquivalent:commandB];
        CHECK(!app->_sidebar.hidden, "and reopens it");
    }

    // With a terminal focused the shortcut must still toggle instead of reaching the shell.
    TSession *session = [app->_content openTerminalAt:nil asTab:YES];
    [app->_win.contentView layoutSubtreeIfNeeded];
    TerminalView *tv = [[app->_content valueForKey:@"_terminalViews"] objectForKey:session];
    if (tv) {
        [app->_win makeFirstResponder:tv];
        CHECK(app->_win.firstResponder == tv, "the terminal holds the keyboard focus");
        CHECK(![tv performKeyEquivalent:commandB], "a focused terminal declines ⌘B instead of writing to the shell");
        CHECK([NSApp.mainMenu performKeyEquivalent:commandB] && app->_sidebar.hidden,
              "⌘B still collapses the file tree from a terminal");
        [NSApp.mainMenu performKeyEquivalent:commandB];
        CHECK(!app->_sidebar.hidden, "and reopens it");
    }
    if (session) [app->_content closeTerminal:session];
    [app->_content closeAllWithoutAsking];
}

// Every nil-target menu action the delegate implements must be unique to it. If AppKit also
// implements the selector, the window or a view answers first and the shortcut silently does
// nothing — which is exactly how ⌘B was broken by being named toggleSidebar:.
static void menuActionsAreOurs(AppDelegate *app) {
    NSArray *appKitOwns = @[@"terminate:", @"hide:", @"orderFrontStandardAboutPanel:", @"arrangeInFront:",
                            @"performMiniaturize:", @"performZoom:", @"performClose:", @"toggleFullScreen:",
                            @"undo:", @"redo:", @"cut:", @"copy:", @"paste:", @"selectAll:", @"delete:",
                            @"uppercaseWord:", @"lowercaseWord:", @"capitalizeWord:", @"startDictation:",
                            @"orderFrontCharacterPalette:", @"toggleAutomaticSpellingCorrection:"];
    NSArray *chainClasses = @[NSWindow.class, NSView.class, NSSplitView.class, NSScrollView.class,
                              NSOutlineView.class, NSTableView.class, NSTextView.class, NSClipView.class];
    NSUInteger checked = 0;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *mi in top.submenu.itemArray) {
            if (!mi.action || mi.target) continue;                       // explicit targets are unambiguous
            NSString *name = NSStringFromSelector(mi.action);
            if ([appKitOwns containsObject:name]) continue;              // deliberately AppKit's own
            if (![app respondsToSelector:mi.action]) continue;           // handled by the editor or a viewer
            checked++;
            for (Class k in chainClasses)
                CHECK(![k instancesRespondToSelector:mi.action],
                      "%s is the delegate's action but %s implements it too, so it would never run",
                      name.UTF8String, NSStringFromClass(k).UTF8String);
        }
    CHECK(checked > 20, "the menu audit actually covered the delegate's actions (%lu)", (unsigned long)checked);
}

// Two items cannot claim one shortcut: AppKit keeps the first and silently clears the second, so
// the duplicate's key equivalent comes back empty and its shortcut never fires.
// When two items ask for one shortcut, AppKit keeps the first and clears the second's key
// equivalent, so the loser's shortcut silently never fires (it happened to Full Screen Preview,
// which first asked for ⇧⌘Return — already taken by Insert Line Above). Comparing the built menu
// against itself cannot see this: the evidence is erased by then. Each shortcut that matters is
// asserted to still be there instead.
static void shortcutsSurvived(void) {
    struct { SEL action; NSString *key; NSEventModifierFlags mods; } want[] = {
        {@selector(toggleFileSidebar:), @"b", NSEventModifierFlagCommand},
        {@selector(togglePreviewFullScreen:), @"f", NSEventModifierFlagCommand | NSEventModifierFlagControl},
        {@selector(togglePreview:), @"v", NSEventModifierFlagCommand | NSEventModifierFlagShift},
        {@selector(splitPreview:), @"v", NSEventModifierFlagCommand | NSEventModifierFlagOption},
        {@selector(splitEditor:), @"\\", NSEventModifierFlagCommand},
        {@selector(showFind:), @"f", NSEventModifierFlagCommand},
        {@selector(searchWorkspace:), @"f", NSEventModifierFlagCommand | NSEventModifierFlagShift},
        {@selector(showFilesTab:), @"e", NSEventModifierFlagCommand | NSEventModifierFlagShift},
        {@selector(toggleMaximizeSplit:), @"m", NSEventModifierFlagCommand | NSEventModifierFlagControl},
        // ⌃⌘ arrows, not plain ⌘ ones: those move the caret in the source editor.
        {@selector(goBackAction:), [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
         NSEventModifierFlagCommand | NSEventModifierFlagControl},
        {@selector(goForwardAction:), [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
         NSEventModifierFlagCommand | NSEventModifierFlagControl},
    };
    for (size_t i = 0; i < sizeof want / sizeof want[0]; i++) {
        NSMenuItem *mi = menuItemFor(want[i].action);
        CHECK(mi != nil, "%s has a menu item", sel_getName(want[i].action));
        CHECK([mi.keyEquivalent isEqualToString:want[i].key] && mi.keyEquivalentModifierMask == want[i].mods,
              "%s kept its shortcut (key '%s', mods %lu)", sel_getName(want[i].action),
              mi.keyEquivalent.UTF8String, (unsigned long)mi.keyEquivalentModifierMask);
    }
}

static void sidebarControls(AppDelegate *app) {
    [app->_win.contentView layoutSubtreeIfNeeded];
    NSTitlebarAccessoryViewController *accessory = app->_win.titlebarAccessoryViewControllers.firstObject;
    CHECK(accessory.view != app->_sidebarButton && app->_sidebarButton.superview == accessory.view,
          "sidebar titlebar accessory keeps the button inside a stable container view");
    [app->_split setPosition:320 ofDividerAtIndex:0];
    checkNoDarkLine(app, @"sidebar-wide.png");
    CGFloat width = app->_sidebar.frame.size.width;
    [app->_win makeFirstResponder:app->_outline];
    clickButton(app->_sidebarButton);
    CHECK(app->_sidebar.hidden && app->_content.view.frame.origin.x == 0 &&
          fabs(app->_content.view.frame.size.width - app->_split.bounds.size.width) < 1,
          "titlebar click hides sidebar and gives its entire width to editor (x %.0f, width %.0f, split %.0f)",
          app->_content.view.frame.origin.x, app->_content.view.frame.size.width, app->_split.bounds.size.width);
    CHECK(![(NSView *)app->_win.firstResponder isDescendantOf:app->_sidebar], "hidden sidebar does not keep keyboard focus");
    CHECK([app->_sidebarButton.accessibilityLabel isEqualToString:FTL(@"Show Sidebar")], "titlebar control names the reopen action");
    clickButton(app->_sidebarButton);
    CHECK(!app->_sidebar.hidden && fabs(app->_sidebar.frame.size.width - width) < 1 &&
          fabs(app->_content.view.frame.origin.x - width - app->_split.dividerThickness) < 1,
          "titlebar click restores the manually resized sidebar (%.0f -> %.0f)", width, app->_sidebar.frame.size.width);
    CHECK([app->_sidebarButton.accessibilityLabel isEqualToString:FTL(@"Hide Sidebar")], "titlebar control names the hide action");

    NSSegmentedControl *tabs = app->_tabs;
    click(app->_win, tabs, NSMakePoint(tabs.bounds.size.width * 0.75, NSMidY(tabs.bounds)), 0, 1);
    CHECK(tabs.selectedSegment == 1 && app->_treeHeader.hidden && app->_treeScroll.hidden && !app->_search.view.hidden,
          "Search tab hides file tree and Collapse All header");
    click(app->_win, tabs, NSMakePoint(tabs.bounds.size.width * 0.25, NSMidY(tabs.bounds)), 0, 1);
    CHECK(tabs.selectedSegment == 0 && !app->_treeHeader.hidden && !app->_treeScroll.hidden && app->_search.view.hidden,
          "Files tab restores the tree and visible collapse control");
    [app setSidebarVisible:NO];
    [app showSidebarTab:1];
    CHECK(!app->_sidebar.hidden && !app->_search.view.hidden && app->_treeHeader.hidden, "showing Search reveals a hidden sidebar");
    [app setSidebarVisible:NO];
    CHECK(app->_sidebar.hidden && app->_split.subviews.count == 2 &&
          app->_split.dividerStyle == NSSplitViewDividerStyleThin,
          "sidebar collapse keeps the outer split divider controlled");
    // A collapsed subview keeps its width, so AppKit would otherwise draw its own divider over
    // the editor at the stale sidebar edge. The answer here must not depend on sidebar state:
    // AppKit caches it, so a hidden-when-asked divider reappears after the next resize.
    CHECK([app splitView:app->_split shouldHideDividerAtIndex:0], "the split view never draws its own divider");
    checkNoDarkLine(app, @"sidebar-collapsed.png");
    [app showSidebarTab:0];
    CHECK(!app->_sidebar.hidden && !app->_treeHeader.hidden && !app->_treeScroll.hidden, "showing Files reveals a hidden sidebar");

    // ⌃⌘F enters the immersive preview, and the item names the way out while it is on.
    NSMenuItem *fullScreen = menuItemFor(@selector(togglePreviewFullScreen:));
    CHECK(fullScreen != nil && [fullScreen.keyEquivalent isEqualToString:@"f"] &&
          fullScreen.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagControl),
          "Full Screen Preview carries ⌃⌘F");
    if (fullScreen) {
        CHECK(responderClaiming(app, fullScreen.action) == app,
              "the delegate is the first chain object answering the full-screen action");
        NSString *doc = [app->_tree.rootPath stringByAppendingPathComponent:@"note.md"];
        [@"# Heading\n\nbody\n" writeToFile:doc atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [app->_content openPath:doc preview:NO focus:YES layout:MarkupPreview];
        [app->_win.contentView layoutSubtreeIfNeeded];
        CHECK([app validateMenuItem:fullScreen] && [fullScreen.title isEqualToString:FTL(@"Full Screen Preview")],
              "a rendered document enables the item under its entering title");
        [app togglePreviewFullScreen:nil];
        [app->_win.contentView layoutSubtreeIfNeeded];
        CHECK(app->_content.previewFullScreen, "the menu action enters the immersive preview");
        CHECK([app validateMenuItem:fullScreen] && [fullScreen.title isEqualToString:FTL(@"Exit Full Screen Preview")],
              "while on, the item names the way out");

        // The sidebar is outside the content view, so the immersive preview has to hide it from
        // here, and put back exactly the state it found.
        CHECK(app->_sidebar.hidden, "the immersive preview hides the file tree too");
        [app togglePreviewFullScreen:nil];
        [app->_win.contentView layoutSubtreeIfNeeded];
        CHECK(!app->_content.previewFullScreen, "and the action leaves again");
        CHECK(!app->_sidebar.hidden, "leaving brings the file tree back");

        // A sidebar the user had already collapsed must stay collapsed afterwards.
        [app setSidebarVisible:NO];
        [app togglePreviewFullScreen:nil];
        [app->_win.contentView layoutSubtreeIfNeeded];
        CHECK(app->_content.previewFullScreen && app->_sidebar.hidden, "full screen from an already collapsed sidebar");
        [app togglePreviewFullScreen:nil];
        [app->_win.contentView layoutSubtreeIfNeeded];
        CHECK(app->_sidebar.hidden, "an already collapsed file tree is not reopened on the way out");
        [app setSidebarVisible:YES];

        [app->_content closeAllWithoutAsking];
        CHECK(![app validateMenuItem:fullScreen], "with no rendered document the item is disabled");
    }

    dragSidebarDivider(app, 300);
    CHECK(fabs(app->_sidebar.frame.size.width - 300) < 2 &&
          fabs(app->_content.view.frame.origin.x - app->_sidebar.frame.size.width - app->_split.dividerThickness) < 2,
          "a hidden divider still resizes the sidebar by mouse drag (width %.0f, editor x %.0f)",
          app->_sidebar.frame.size.width, app->_content.view.frame.origin.x);
    checkNoDarkLine(app, @"sidebar-dragged.png");
    [app setSidebarVisible:NO];
    checkNoDarkLine(app, @"sidebar-collapsed-after-drag.png");
    [app setSidebarVisible:YES];
    CHECK(fabs(app->_sidebar.frame.size.width - 300) < 2, "reopening restores the dragged width (%.0f)", app->_sidebar.frame.size.width);
    checkNoDarkLine(app, @"sidebar-restored-after-drag.png");
}

static void emptyRoots(AppDelegate *app, NSString *root) {
    [app->_content closeAllWithoutAsking];
    NSString *empty = folder(root, @"empty-workspace");
    [app openRoot:empty];
    CHECK([app->_tree.rootPath isEqualToString:empty] && app->_outline.numberOfRows == 0 && !app->_tree.collapseButton.enabled,
          "openRoot accepts an empty workspace and disables Collapse All");
    [app->_tree collapseAll:nil];
    [app->_tree reload];
    CHECK(app->_outline.numberOfRows == 0, "collapse and reload of an empty tree are safe");
    NSString *newDir = folder(empty, @"new-folder");
    NSString *newFile = file(newDir, @"new-file.txt");
    [app->_tree reloadAndReveal:newFile];
    CHECK([app->_tree.selectedPath isEqualToString:newFile] && app->_tree.collapseButton.enabled, "new items appear and reveal normally after an empty root");
    clickButton(app->_tree.collapseButton);
    CHECK(app->_outline.numberOfRows == 1 && !app->_tree.collapseButton.enabled, "new folder collapses from header normally");
    app->_tree.rootPath = nil;
    [app->_tree collapseAll:nil];
    CHECK(app->_outline.numberOfRows == 0 && !app->_tree.collapseButton.enabled, "clearing root leaves a safe empty tree");
}

int main(void) {
    @autoreleasepool {
        const char *home = getenv("CFFIXED_USER_HOME"), *pids = getenv("FEATHERVIEW_TERMINAL_PIDS_DIR");
        if (!home || !*home || !pids || !*pids) {
            fprintf(stderr, "file_tree_tests requires private CFFIXED_USER_HOME and FEATHERVIEW_TERMINAL_PIDS_DIR\n");
            return 2;
        }
        NSString *root = folder(@(home), [@"file-tree-" stringByAppendingString:NSUUID.UUID.UUIDString]);
        NSString *workspace = folder(root, @"workspace");
        file(folder(workspace, @"alpha/nested"), @"leaf.txt");
        file(folder(workspace, @"beta"), @"other.txt");
        folder(workspace, @"empty");
        file(workspace, @"top.txt");
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"AppleLanguages": @[@"en"], @"autoSaveMode": @(AutoSaveOff),
            @"sessions": @{}, @"recentRoots": @[], @"lastRoot": workspace} forName:NSArgumentDomain];
        [NSApplication sharedApplication];
        AppDelegate *app = [AppDelegate new];
        @try {
            // Build only: launching would sweep orphan shell records and open user session state.
            [app buildMenu];                     // ⌘B is dispatched through the real main menu
            [app buildWindow];
            app->_content.untitledDirectory = folder(root, @"untitled");
            app->_content.autoSaveMode = AutoSaveOff;
            [app openRoot:workspace];
            // main.m sets this; menu items with a nil target reach the delegate through it.
            NSApp.delegate = (id<NSApplicationDelegate>)app;
            [app->_win makeKeyAndOrderFront:nil];
            [app->_win.contentView layoutSubtreeIfNeeded];
            folderControls(app, workspace);
            sidebarControls(app);
            menuActionsAreOurs(app);
            shortcutsSurvived();
            sidebarShortcut(app);
            emptyRoots(app, root);
        } @finally {
            [app->_watcher stop];
            [NSNotificationCenter.defaultCenter removeObserver:app];
            app->_content.onActivate = nil;
            [app->_content closeAllWithoutAsking];
            NSApp.delegate = nil;
            app->_win.delegate = nil;
            [app->_win orderOut:nil];
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
    }
    if (failures) { fprintf(stderr, "%d file tree failure(s)\n", failures); return 1; }
    puts("all file tree tests passed");
    return 0;
}

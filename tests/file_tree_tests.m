// File tree controls exercised through the window, with private defaults and temporary folders.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "TextEditorView.h"
#import "Localization.h"

@interface AppDelegate (FileTreeTests)
- (void)buildWindow;
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

static void saveWindowSnapshot(AppDelegate *app, NSString *name) {
    NSString *dir = NSProcessInfo.processInfo.environment[@"FEATHERVIEW_FILE_TREE_SNAPSHOTS"];
    if (!dir.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSView *view = app->_win.contentView;
    [view layoutSubtreeIfNeeded];
    [app->_win displayIfNeeded];
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
}

static void sidebarControls(AppDelegate *app) {
    [app->_win.contentView layoutSubtreeIfNeeded];
    NSTitlebarAccessoryViewController *accessory = app->_win.titlebarAccessoryViewControllers.firstObject;
    CHECK(accessory.view != app->_sidebarButton && app->_sidebarButton.superview == accessory.view,
          "sidebar titlebar accessory keeps the button inside a stable container view");
    [app->_split setPosition:320 ofDividerAtIndex:0];
    saveWindowSnapshot(app, @"sidebar-wide.png");
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
    saveWindowSnapshot(app, @"sidebar-collapsed.png");
    CHECK(app->_sidebar.hidden && app->_split.subviews.count == 2 &&
          app->_split.dividerStyle == NSSplitViewDividerStyleThin,
          "sidebar collapse keeps the outer split divider controlled");
    [app showSidebarTab:0];
    CHECK(!app->_sidebar.hidden && !app->_treeHeader.hidden && !app->_treeScroll.hidden, "showing Files reveals a hidden sidebar");
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
            [app buildWindow];
            app->_content.untitledDirectory = folder(root, @"untitled");
            app->_content.autoSaveMode = AutoSaveOff;
            [app openRoot:workspace];
            [app->_win makeKeyAndOrderFront:nil];
            [app->_win.contentView layoutSubtreeIfNeeded];
            folderControls(app, workspace);
            sidebarControls(app);
            emptyRoots(app, root);
        } @finally {
            [app->_watcher stop];
            [NSNotificationCenter.defaultCenter removeObserver:app];
            app->_content.onActivate = nil;
            [app->_content closeAllWithoutAsking];
            app->_win.delegate = nil;
            [app->_win orderOut:nil];
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
    }
    if (failures) { fprintf(stderr, "%d file tree failure(s)\n", failures); return 1; }
    puts("all file tree tests passed");
    return 0;
}

#import "AppDelegate.h"
#import "TextEditorView.h"
#import "WorkspaceSearch.h"
#import "FileOps.h"
#import "MarkupView.h"

static const CGFloat kSidebarW = 260;

@interface SidebarView : NSView
@end
@implementation SidebarView
- (BOOL)isFlipped { return YES; }
@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)n {
    [self buildMenu];
    [self buildWindow];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSString *root = nil, *file = nil;
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--open"] && i + 1 < args.count) { file = args[++i]; continue; }
        if ([a hasPrefix:@"-psn_"]) continue;
        if ([a hasPrefix:@"-"]) { i++; continue; }     // -NSFoo YES style defaults
        root = a;
    }
    if (_tree.rootPath && !root) { [_win makeKeyAndOrderFront:nil]; return; }   // opened via Finder
    BOOL isDir = NO;
    if (!root) {
        root = [NSUserDefaults.standardUserDefaults stringForKey:@"lastRoot"];
        if (!root || ![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDir] || !isDir) root = NSHomeDirectory();
    }
    [self openRoot:root.stringByStandardizingPath];
    if (file) [self openFile:file.stringByStandardizingPath];
    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    NSString *p = urls.firstObject.path.stringByStandardizingPath;
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir]) return;
    if (dir) [self switchToRoot:p];
    else if (FOPathIsWithin(p, _tree.rootPath)) [self openFile:p];
    else if ([self switchToRoot:p.stringByDeletingLastPathComponent]) [self openFile:p];
    [_win makeKeyAndOrderFront:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)n {
    if (!_tree.rootPath) return;
    [_tree reload];
    [_content checkExternalChanges];
}
- (void)applicationWillResignActive:(NSNotification *)n {
    [_content flushAutoSave];          // switching to another app counts as a focus change
    [self saveSession];
    [self updateTitle];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    if (_sessionSaved) return NSTerminateNow;            // window close already asked
    if (![_content confirmCloseAll]) return NSTerminateCancel;
    [self saveSession];
    return NSTerminateNow;
}

- (BOOL)windowShouldClose:(NSWindow *)w {
    if (![_content confirmCloseAll]) return NO;
    [self saveSession];
    _sessionSaved = YES;
    [_content closeAllWithoutAsking];
    return YES;
}

- (void)saveSession {
    NSString *root = _tree.rootPath;
    if (!root || _sessionSaved) return;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *all = [[ud dictionaryForKey:@"sessions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    all[root] = _content.sessionState;
    NSArray *keep = self.recentRoots;
    for (NSString *k in all.allKeys) if (![keep containsObject:k] && ![k isEqualToString:root]) [all removeObjectForKey:k];
    [ud setObject:all forKey:@"sessions"];
}

- (void)openRoot:(NSString *)root {
    [self saveSession];
    [_content closeAllWithoutAsking];
    _tree.rootPath = root;
    _search.root = root;
    _content.workspaceRoot = root;
    [NSUserDefaults.standardUserDefaults setObject:root forKey:@"lastRoot"];
    [self noteRecentRoot:root];
    NSDictionary *s = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"sessions"][root];
    if (s) [_content restoreSession:s];
    [self refreshWorkspaceUI];
    [self updateTitle];
}

- (BOOL)switchToRoot:(NSString *)root {
    if ([root isEqualToString:_tree.rootPath]) return YES;
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&dir] || !dir) return NO;
    if (![_content confirmCloseAll]) return NO;
    [self openRoot:root];
    return YES;
}

- (void)openFile:(NSString *)path { [_content openPath:path preview:NO focus:YES]; }

- (void)updateTitle {
    NSString *cur = _content.currentPath;
    _win.title = cur ? cur.lastPathComponent : (_tree.rootPath.lastPathComponent ?: @"Feather");
    _win.subtitle = _tree.rootPath ? [_tree.rootPath stringByAbbreviatingWithTildeInPath] : @"";
    _win.representedURL = cur ? [NSURL fileURLWithPath:cur] : nil;
    _win.documentEdited = _content.dirtyCount > 0;
}

- (void)refreshWorkspaceUI {
    NSString *root = _tree.rootPath;
    NSMenuItem *title = _rootPopup.menu.itemArray.firstObject;
    title.title = root.lastPathComponent ?: @"未打开文件夹";
    _rootPopup.toolTip = root ? [NSString stringWithFormat:@"%@\n点击切换工作区", root.stringByAbbreviatingWithTildeInPath] : nil;
    [_welcome reloadWithRoot:root recent:self.recentRoots];
}

- (void)showSidebarTab:(NSInteger)tab {
    _tabs.selectedSegment = tab;
    _treeScroll.hidden = tab != 0;
    _search.view.hidden = tab != 1;
}

- (void)tabChanged:(NSSegmentedControl *)s { [self showSidebarTab:s.selectedSegment]; }

- (void)buildWindow {
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _win.minSize = NSMakeSize(560, 320);
    _win.delegate = self;
    _win.releasedWhenClosed = NO;
    [_win center];
    _win.frameAutosaveName = @"FeatherMain";
    NSRect cb = _win.contentView.bounds;
    CGFloat h = cb.size.height, headerH = 30, tabH = 28, top = headerH + tabH;

    _split = [[NSSplitView alloc] initWithFrame:cb];
    _split.vertical = YES;
    _split.dividerStyle = NSSplitViewDividerStyleThin;
    _split.delegate = self;
    _split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _sidebar = [[SidebarView alloc] initWithFrame:NSMakeRect(0, 0, kSidebarW, h)];
    _sidebar.autoresizesSubviews = YES;

    _rootPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(6, 4, kSidebarW - 12, 24) pullsDown:YES];
    _rootPopup.bordered = NO;
    _rootPopup.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _rootPopup.autoresizingMask = NSViewWidthSizable;
    [_rootPopup.cell setArrowPosition:NSPopUpArrowAtBottom];
    [_rootPopup.cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:@"未打开文件夹" action:NULL keyEquivalent:@""];
    titleItem.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
    [_rootPopup.menu addItem:titleItem];
    _rootPopup.menu.delegate = self;
    _rootPopup.accessibilityLabel = @"切换工作区";
    [_sidebar addSubview:_rootPopup];

    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[@"文件", @"搜索"] trackingMode:NSSegmentSwitchTrackingSelectOne
                                                    target:self action:@selector(tabChanged:)];
    _tabs.segmentDistribution = NSSegmentDistributionFillEqually;
    _tabs.controlSize = NSControlSizeSmall;
    _tabs.frame = NSMakeRect(8, headerH + 2, kSidebarW - 16, 22);
    _tabs.autoresizingMask = NSViewWidthSizable;
    [_sidebar addSubview:_tabs];

    _treeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, top, kSidebarW, h - top)];
    _treeScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _treeScroll.hasVerticalScroller = YES;
    _treeScroll.autohidesScrollers = YES;
    _outline = [[FileOutlineView alloc] initWithFrame:_treeScroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:col];
    _outline.outlineTableColumn = col;
    _outline.headerView = nil;
    _outline.style = NSTableViewStyleSourceList;
    _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _outline.rowHeight = 22;
    _outline.menu = [self treeContextMenu];
    _treeScroll.documentView = _outline;
    [col setWidth:_treeScroll.contentSize.width];
    [_sidebar addSubview:_treeScroll];

    _search = [SearchPanel new];
    _search.view.frame = NSMakeRect(0, top, kSidebarW, h - top);
    _search.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_sidebar addSubview:_search.view];

    _content = [ContentController new];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud registerDefaults:@{@"autoSaveMode": @(AutoSaveAfterDelay), @"autoSaveDelay": @1.0, @"showMinimap": @YES}];
    _content.previewEnabled = ![ud boolForKey:@"disablePreviewTabs"];
    _content.autoSaveMode = (AutoSaveMode)[ud integerForKey:@"autoSaveMode"];
    _content.autoSaveDelay = [ud doubleForKey:@"autoSaveDelay"];
    _content.showsMinimap = [ud boolForKey:@"showMinimap"];
    if ([ud doubleForKey:@"editorFontSize"] > 0) TextEditorView.defaultFontSize = [ud doubleForKey:@"editorFontSize"];
    if ([ud doubleForKey:@"markdownScale"] > 0) MarkdownPreview.defaultScale = [ud doubleForKey:@"markdownScale"];
    if ([ud doubleForKey:@"htmlZoom"] > 0) HTMLPreview.defaultZoom = [ud doubleForKey:@"htmlZoom"];
    _welcome = [[WelcomeView alloc] initWithFrame:NSZeroRect];
    _content.emptyView = _welcome;
    _tree = [[FileTree alloc] initWithOutlineView:_outline];

    __weak AppDelegate *weakSelf = self;
    _welcome.onOpenRoot = ^(NSString *r) { [weakSelf switchToRoot:r]; };
    _tree.onOpen = ^(NSString *p, BOOL pinned) {
        AppDelegate *me = weakSelf;
        BOOL viaKeyboard = NSApp.currentEvent.type == NSEventTypeKeyDown;
        [me->_content openPath:p preview:!pinned focus:pinned && !viaKeyboard];
    };
    _content.onStateChange = ^{ [weakSelf updateTitle]; };
    _content.onActivate = ^(NSString *p) {
        AppDelegate *me = weakSelf;
        if (p) [me->_tree revealPath:p];
        [me updateTitle];
    };
    _search.onOpen = ^(SearchHit *hit, BOOL focusEditor) {
        AppDelegate *me = weakSelf;
        if (!me) return;
        [me->_content openHit:hit.path line:hit.line column:hit.column length:hit.matchBytes];
        if (focusEditor && me->_content.editor) [me->_win makeFirstResponder:me->_content.editor];
    };
    [self showSidebarTab:0];

    // Give both panes their final widths before the split view sees them; otherwise the
    // right pane keeps its initial frame and leaves an empty strip until the first resize.
    _content.view.frame = NSMakeRect(kSidebarW + 1, 0, cb.size.width - kSidebarW - 1, h);
    _content.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_split addSubview:_sidebar];
    [_split addSubview:_content.view];
    _win.contentView = _split;
    [_split adjustSubviews];
    [_split setPosition:kSidebarW ofDividerAtIndex:0];
    [self refreshWorkspaceUI];
}

- (BOOL)splitView:(NSSplitView *)sv shouldAdjustSizeOfSubview:(NSView *)v { return v != sv.subviews.firstObject; }
- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i { return 180; }
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i { return sv.bounds.size.width - 280; }

@end

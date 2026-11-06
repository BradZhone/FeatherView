#import "AppDelegate.h"
#import "Localization.h"
#import "TextEditorView.h"
#import "WorkspaceSearch.h"
#import "FileOps.h"
#import "MarkupView.h"
#import "Settings.h"
#import "DataPreviews.h"

static const CGFloat kSidebarW = 260;

@interface SidebarView : NSView
@end
@implementation SidebarView
- (BOOL)isFlipped { return YES; }
@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)n {
    _pendingFiles = _pendingFiles ?: [NSMutableArray array];
    [FTSettings.shared apply];
    [AppDelegate applyAppearance:FTSettings.shared.appearance];          // before the window draws
    [self buildMenu];
    [self buildWindow];
    [self pruneUntitledBackups];
}

// Backups no saved session refers to (e.g. after a crash before the session was written) are kept a week.
- (void)pruneUntitledBackups {
    NSString *dir = _content.untitledDirectory;
    NSSet *keep = [ContentController untitledBackupsInSessions:[NSUserDefaults.standardUserDefaults dictionaryForKey:@"sessions"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if ([keep containsObject:p]) continue;
        NSDate *m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
        if (m && -m.timeIntervalSinceNow > 7 * 86400) [fm removeItemAtPath:p error:nil];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSString *root = nil;
    for (NSUInteger i = 1; i < args.count; i++) {      // FeatherView [folder] [--open file]...
        NSString *a = args[i];
        if ([a isEqualToString:@"--open"] && i + 1 < args.count) { [_pendingFiles addObject:[args[++i] stringByStandardizingPath]]; continue; }
        if ([a hasPrefix:@"-psn_"]) continue;
        if ([a hasPrefix:@"-"]) { i++; continue; }     // -NSFoo YES style defaults
        root = a;
    }
    _launched = YES;
    if (!_tree.rootPath) {                               // a folder dropped on the icon may already have set it
        BOOL isDir = NO;
        if (!root) root = [NSUserDefaults.standardUserDefaults stringForKey:@"lastRoot"];
        if (!root || ![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDir] || !isDir)
            root = _pendingFiles.count ? _pendingFiles.firstObject.stringByDeletingLastPathComponent : NSHomeDirectory();
        [self openRoot:root.stringByStandardizingPath];
    }
    [self openPendingFiles];
    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// Finder (double-click, "Open With", drag onto the icon). Files open as tabs in the current workspace,
// like an editor's default handler should; the workspace only changes when a folder is opened.
// Before launch finishes they are queued, so the last session is restored first.
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    if (!_pendingFiles) _pendingFiles = [NSMutableArray array];
    NSString *folder = nil;
    for (NSURL *u in urls) {
        NSString *p = u.path.stringByStandardizingPath;
        BOOL dir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir]) continue;
        if (dir) folder = folder ?: p;
        else [_pendingFiles addObject:p];
    }
    if (folder) [self switchToRoot:folder];
    if (_launched) { [self openPendingFiles]; [_win makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
}

- (void)openPendingFiles {
    NSArray *files = [_pendingFiles copy];
    [_pendingFiles removeAllObjects];
    for (NSString *p in files) [self openFile:p];
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
    [_content backupUntitled];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *all = [[ud dictionaryForKey:@"sessions"] mutableCopy] ?: [NSMutableDictionary dictionary];
    all[root] = _content.sessionState;
    NSArray *keep = self.recentRoots;
    for (NSString *k in all.allKeys) {
        if ([keep containsObject:k] || [k isEqualToString:root]) continue;
        // a workspace taken off the recent list keeps its session while it holds untitled documents
        if ([ContentController untitledBackupsInSessions:@{k: all[k]}].count) continue;
        [all removeObjectForKey:k];
    }
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
    _win.title = _content.currentTitle ?: (_tree.rootPath.lastPathComponent ?: @"FeatherView");
    _win.subtitle = _tree.rootPath ? [_tree.rootPath stringByAbbreviatingWithTildeInPath] : @"";
    _win.representedURL = cur ? [NSURL fileURLWithPath:cur] : nil;
    _win.documentEdited = _content.dirtyCount > 0;
}

// Settings window / menu toggles → every part that depends on them.
- (void)applySettings:(NSNotification *)n {
    FTSettings *st = FTSettings.shared;
    [AppDelegate applyAppearance:st.appearance];
    _content.autoSaveMode = (AutoSaveMode)st.autoSaveMode;
    _content.showsMinimap = st.showsMinimap;
    _content.wordWrap = st.wordWrap;
    _search.includeHidden = st.showHidden;
    _search.respectGitignore = st.respectGitignore;
    [_search fileSystemChanged];
    if (_tree.showHidden != st.showHidden) _tree.showHidden = st.showHidden;    // reloads
    else if (n) [_tree reload];                                                 // the always-hidden list may have changed
}

- (void)refreshWorkspaceUI {
    NSString *root = _tree.rootPath;
    NSMenuItem *title = _rootPopup.menu.itemArray.firstObject;
    title.title = root.lastPathComponent ?: FTL(@"No Folder Open");
    _rootPopup.toolTip = root ? [NSString stringWithFormat:FTL(@"%@\nClick to switch workspaces"), root.stringByAbbreviatingWithTildeInPath] : nil;
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
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:FTL(@"No Folder Open") action:NULL keyEquivalent:@""];
    titleItem.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
    [_rootPopup.menu addItem:titleItem];
    _rootPopup.menu.delegate = self;
    _rootPopup.accessibilityLabel = FTL(@"Switch Workspace");
    [_sidebar addSubview:_rootPopup];

    _tabs = [NSSegmentedControl segmentedControlWithLabels:@[FTL(@"Files"), FTL(@"Search")] trackingMode:NSSegmentSwitchTrackingSelectOne
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
    if ([ud doubleForKey:@"dataFontSize"] > 0) FTSetDataFontSize([ud doubleForKey:@"dataFontSize"]);
    _welcome = [[WelcomeView alloc] initWithFrame:NSZeroRect];
    _content.emptyView = _welcome;
    _tree = [[FileTree alloc] initWithOutlineView:_outline];
    [self applySettings:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applySettings:) name:FTSettingsDidChange object:nil];

    __weak AppDelegate *weakSelf = self;
    _welcome.onOpenRoot = ^(NSString *r) { [weakSelf switchToRoot:r]; };
    _welcome.onRemoveRecent = ^(NSString *r) { [weakSelf removeRecentRoot:r]; };
    _tree.onOpen = ^(NSString *p, BOOL pinned) {
        AppDelegate *me = weakSelf;
        BOOL viaKeyboard = NSApp.currentEvent.type == NSEventTypeKeyDown;
        [me->_content openPath:p preview:!pinned focus:pinned && !viaKeyboard];
    };
    _content.onStateChange = ^{ [weakSelf updateTitle]; };
    _content.onSaveAs = ^(NSString *p) {
        AppDelegate *me = weakSelf;
        if (!me) return;
        [me->_tree reloadAndReveal:p];
        [me->_search fileSystemChanged];
        [me updateTitle];
    };
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
    _search.onOpenFile = ^(NSString *p, BOOL focusEditor) {
        AppDelegate *me = weakSelf;
        if (!me) return;
        [me->_content openPath:p preview:!focusEditor focus:focusEditor];
    };
    _search.onReveal = ^(NSString *p) {
        AppDelegate *me = weakSelf;
        [me showSidebarTab:0];
        [me->_tree revealPath:p];
        [me->_win makeFirstResponder:me->_outline];
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

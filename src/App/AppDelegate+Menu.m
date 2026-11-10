#import "AppDelegate.h"
#import "Localization.h"
#import "TextEditorView.h"
#import "PDFViewer.h"
#import "ImageViewer.h"
#import "DefaultAppsPanel.h"
#import "Settings.h"
#import "SettingsWindow.h"

static const NSInteger kContextTag = 7001;

static NSMenuItem *item(NSString *title, SEL action, NSString *key, NSEventModifierFlags mods) {
    NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    if (key.length) m.keyEquivalentModifierMask = mods;
    return m;
}

@implementation AppDelegate (Menu)

- (void)buildMenu {
    const NSEventModifierFlags C = NSEventModifierFlagCommand, S = NSEventModifierFlagShift,
                               O = NSEventModifierFlagOption, K = NSEventModifierFlagControl;
    NSMenuItem *recent = item(FTL(@"Open Recent"), NULL, nil, 0);
    _recentMenu = [[NSMenu alloc] initWithTitle:FTL(@"Open Recent")];
    _recentMenu.delegate = self;
    recent.submenu = _recentMenu;

    NSArray *spec = @[
        @[@"FeatherView", @[item(FTL(@"About FeatherView"), @selector(orderFrontStandardAboutPanel:), nil, 0),
                        NSMenuItem.separatorItem,
                        item(FTL(@"Settings…"), @selector(showSettings:), @",", C),
                        item(FTL(@"Default Apps…"), @selector(showDefaultApps:), nil, 0),
                        NSMenuItem.separatorItem,
                        item(FTL(@"Hide FeatherView"), @selector(hide:), @"h", C),
                        item(FTL(@"Quit FeatherView"), @selector(terminate:), @"q", C)]],
        @[FTL(@"File"), @[item(FTL(@"New Document"), @selector(newUntitled:), @"n", C),
                    item(FTL(@"New File…"), @selector(newFile:), @"n", C | O),
                    item(FTL(@"New Folder…"), @selector(newFolder:), @"n", C | S),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Open Folder…"), @selector(openFolder:), @"o", C),
                    recent,
                    item(FTL(@"Switch Workspace…"), @selector(switchWorkspace:), @"r", K),
                    item(FTL(@"Quick Open…"), @selector(quickOpen:), @"p", C),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Save"), @selector(saveDocument:), @"s", C),
                    item(FTL(@"Save All"), @selector(saveAllDocuments:), @"s", C | O),
                    [self autoSaveMenuItem],
                    NSMenuItem.separatorItem,
                    item(FTL(@"Close Tab"), @selector(closeTab:), @"w", C),
                    item(FTL(@"Close Other Tabs"), @selector(closeOtherTabs:), nil, 0),
                    item(FTL(@"Close All Tabs"), @selector(closeAllTabs:), @"w", C | O),
                    item(FTL(@"Reopen Closed Tab"), @selector(reopenClosedTab:), @"t", C | S),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Rename…"), @selector(renameItem:), nil, 0),
                    item(FTL(@"Move to Trash"), @selector(trashItem:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Refresh File Tree"), @selector(reloadTree:), @"r", C),
                    item(FTL(@"Show in Finder"), @selector(revealInFinder:), @"r", C | S),
                    item(FTL(@"Open with Default App"), @selector(openInDefaultAppAction:), @"o", C | S),
                    item(FTL(@"Copy Path"), @selector(copyItemPath:), @"c", C | O),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Close Window"), @selector(performClose:), @"w", C | S)]],
        @[FTL(@"Edit"), @[item(FTL(@"Undo"), @selector(undo:), @"z", C),
                    item(FTL(@"Redo"), @selector(redo:), @"z", C | S),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Cut"), @selector(cut:), @"x", C),
                    item(FTL(@"Copy"), @selector(copy:), @"c", C),
                    item(FTL(@"Paste"), @selector(paste:), @"v", C),
                    item(FTL(@"Select All"), @selector(selectAll:), @"a", C),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Find…"), @selector(showFind:), @"f", C),
                    item(FTL(@"Find and Replace…"), @selector(showReplace:), @"f", C | O),
                    item(FTL(@"Find Next"), @selector(findNextMatch:), @"g", C),
                    item(FTL(@"Find Previous"), @selector(findPrevMatch:), @"g", C | S),
                    item(FTL(@"Search in Workspace…"), @selector(searchWorkspace:), @"f", C | S),
                    item(FTL(@"Next Search Result"), @selector(nextSearchResult:), [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey], 0),
                    item(FTL(@"Previous Search Result"), @selector(previousSearchResult:), [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey], S),
                    item(FTL(@"Go to Line…"), @selector(promptGoToLine:), @"l", C)]],
        @[FTL(@"View"), @[item(FTL(@"Zoom In"), @selector(zoomInAction:), @"=", C),
                    item(FTL(@"Zoom Out"), @selector(zoomOutAction:), @"-", C),
                    item(FTL(@"Fit to Window / Default Size"), @selector(zoomResetAction:), @"0", C),
                    item(FTL(@"Actual Size"), @selector(zoomActualAction:), nil, 0),
                    item(FTL(@"Rotate Left"), @selector(rotateLeftAction:), nil, 0),
                    item(FTL(@"Rotate Right"), @selector(rotateRightAction:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(FTL(@"PDF Thumbnails"), @selector(togglePDFThumbsAction:), @"t", C | O),
                    item(FTL(@"PDF Two Pages"), @selector(togglePDFTwoPagesAction:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Preview (Markdown, Tables, JSON…)"), @selector(togglePreview:), @"v", C | S),
                    item(FTL(@"Side-by-Side Preview"), @selector(splitPreview:), @"v", C | O),
                    item(FTL(@"Source Only"), @selector(sourceOnly:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Word Wrap"), @selector(toggleWordWrap:), @"z", C | O),     // not ⌥Z: that types Ω, or ż on Polish keyboards
                    item(FTL(@"Show Minimap"), @selector(toggleMinimap:), @"m", NSEventModifierFlagCommand | NSEventModifierFlagOption),
                    [self appearanceMenuItem],
                    NSMenuItem.separatorItem,
                    item(FTL(@"File Tree"), @selector(showFilesTab:), @"e", C | S),
                    item(FTL(@"Search"), @selector(searchWorkspace:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Automatic"), @selector(viewAuto:), @"0", C | O),
                    item(FTL(@"As Text"), @selector(viewText:), @"1", C | O),
                    item(FTL(@"As Hex"), @selector(viewHex:), @"2", C | O),
                    item(FTL(@"Quick Look"), @selector(viewQuickLook:), @"3", C | O),
                    NSMenuItem.separatorItem,
                    item(FTL(@"Show Hidden Files"), @selector(toggleHidden:), @".", C | S)]],
        @[FTL(@"Tabs"), [self tabMenuItems]],
        @[FTL(@"Window"), @[item(FTL(@"Minimize"), @selector(performMiniaturize:), @"m", C),
                      item(FTL(@"Zoom"), @selector(performZoom:), nil, 0),
                      NSMenuItem.separatorItem,
                      item(FTL(@"Bring All to Front"), @selector(arrangeInFront:), nil, 0)]],
    ];
    NSMenu *bar = [NSMenu new];
    for (NSArray *m in spec) {
        NSMenuItem *top = [NSMenuItem new];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:m[0]];
        for (NSMenuItem *i in m[1]) [sub addItem:i];
        if ([m[0] isEqualToString:FTL(@"View")]) {               // ⌘+ (shift-=) as well as ⌘=
            NSMenuItem *plus = item(FTL(@"Zoom In"), @selector(zoomInAction:), @"+", NSEventModifierFlagCommand);
            plus.hidden = YES;
            plus.allowsKeyEquivalentWhenHidden = YES;
            [sub addItem:plus];
        }
        top.submenu = sub;
        [bar addItem:top];
        if ([m[0] isEqualToString:FTL(@"Window")]) NSApp.windowsMenu = sub;     // AppKit lists the open windows here
    }
    NSApp.mainMenu = bar;
}

- (NSArray<NSMenuItem *> *)tabMenuItems {
    const NSEventModifierFlags C = NSEventModifierFlagCommand, O = NSEventModifierFlagOption;
    NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSMutableArray *a = [@[item(FTL(@"Next Tab"), @selector(nextTab:), right, C | O),
                           item(FTL(@"Previous Tab"), @selector(previousTab:), left, C | O),
                           NSMenuItem.separatorItem,
                           item(FTL(@"Keep Open (Pin Preview Tab)"), @selector(pinTab:), nil, 0),
                           item(FTL(@"Single Click Opens a Preview Tab"), @selector(togglePreviewTabs:), nil, 0),
                           NSMenuItem.separatorItem] mutableCopy];
    for (int i = 1; i <= 9; i++) {
        NSMenuItem *m = item(i == 9 ? FTL(@"Last Tab") : [NSString stringWithFormat:FTL(@"Tab %d"), i],
                             @selector(selectTabByNumber:), [NSString stringWithFormat:@"%d", i], C);
        m.tag = i;
        [a addObject:m];
    }
    return a;
}

- (NSMenu *)treeContextMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    for (NSMenuItem *i in @[item(FTL(@"New File…"), @selector(newFile:), nil, 0),
                            item(FTL(@"New Folder…"), @selector(newFolder:), nil, 0),
                            NSMenuItem.separatorItem,
                            item(FTL(@"Rename…"), @selector(renameItem:), nil, 0),
                            item(FTL(@"Move to Trash"), @selector(trashItem:), nil, 0),
                            NSMenuItem.separatorItem,
                            item(FTL(@"Show in Finder"), @selector(revealInFinder:), nil, 0),
                            item(FTL(@"Copy Path"), @selector(copyItemPath:), nil, 0)]) { i.tag = kContextTag; [m addItem:i]; }
    m.delegate = self;
    return m;
}

// Tree context menu: stamp every item with the clicked path (root when clicking empty space).
// Recent menu: rebuild from defaults.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == _recentMenu) {
        [menu removeAllItems];
        for (NSString *r in self.recentRoots) {
            NSMenuItem *i = item([r stringByAbbreviatingWithTildeInPath], @selector(openRecent:), nil, 0);
            i.representedObject = r;
            [menu addItem:i];
            [self addRemoveAlternateFor:r title:[FTL(@"Remove from List: ") stringByAppendingString:r.stringByAbbreviatingWithTildeInPath] to:menu];
        }
        if (!menu.numberOfItems) { NSMenuItem *e = item(FTL(@"None"), NULL, nil, 0); e.enabled = NO; [menu addItem:e]; }
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *hint = item(FTL(@"Hold ⌥ to remove one"), NULL, nil, 0);
        hint.enabled = NO;
        [menu addItem:hint];
        [menu addItem:item(FTL(@"Clear List"), @selector(clearRecent:), nil, 0)];
        return;
    }
    if (menu == _rootPopup.menu) { [self rebuildRootPopupMenu:menu]; return; }
    NSArray *targets = _tree.clickedPaths;
    if (!targets.count && _tree.rootPath) targets = @[_tree.rootPath];
    for (NSMenuItem *i in menu.itemArray) i.representedObject = targets;
}

// Item 0 is the pull-down's title; the rest is rebuilt each time it opens.
- (void)rebuildRootPopupMenu:(NSMenu *)menu {
    while (menu.numberOfItems > 1) [menu removeItemAtIndex:1];
    NSString *root = _tree.rootPath;
    NSArray *recent = self.recentRoots;
    if (recent.count) {
        NSMenuItem *h = item(FTL(@"Recent Workspaces"), NULL, nil, 0);
        h.enabled = NO;
        [menu addItem:h];
    }
    for (NSString *r in recent) {
        NSMenuItem *i = item(r.lastPathComponent, @selector(openRecent:), nil, 0);
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:r.lastPathComponent
            attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:0]}];
        [t appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@"   " stringByAppendingString:r.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath]
            attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:11], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
        i.attributedTitle = t;
        i.representedObject = r;
        i.state = [r isEqualToString:root] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:i];
        if (![r isEqualToString:root]) [self addRemoveAlternateFor:r title:[FTL(@"Remove from List: ") stringByAppendingString:r.lastPathComponent] to:menu];
    }
    if (recent.count > 1) {
        NSMenuItem *hint = item(FTL(@"Hold ⌥ to remove one"), NULL, nil, 0);
        hint.enabled = NO;
        [menu addItem:hint];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:item(FTL(@"Open Folder…"), @selector(openFolder:), nil, 0)];
    [menu addItem:item(FTL(@"Switch Workspace by Name…"), @selector(switchWorkspace:), nil, 0)];
    if (root) [menu addItem:item(FTL(@"Show Workspace in Finder"), @selector(revealRootInFinder:), nil, 0)];
    if (recent.count > 1) [menu addItem:item(FTL(@"Clear Recent List"), @selector(clearRecent:), nil, 0)];
}

// Shown in place of the item above it while ⌥ is held.
- (void)addRemoveAlternateFor:(NSString *)root title:(NSString *)title to:(NSMenu *)menu {
    NSMenuItem *alt = item(title, @selector(removeRecent:), nil, 0);
    alt.keyEquivalentModifierMask = NSEventModifierFlagOption;
    alt.alternate = YES;
    alt.representedObject = root;
    alt.image = [NSImage imageWithSystemSymbolName:@"minus.circle" accessibilityDescription:nil];
    [menu addItem:alt];
}

- (void)revealRootInFinder:(id)s {
    if (_tree.rootPath) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:_tree.rootPath]]];
}

- (BOOL)validateMenuItem:(NSMenuItem *)mi {
    SEL a = mi.action;
    NSString *target = [self targetPathFrom:mi];
    NSArray<NSString *> *targets = [self targetPathsFrom:mi];
    BOOL hasRoot = _tree.rootPath != nil;
    NSUInteger tabs = _content.tabCount;
    if (a == @selector(toggleHidden:)) { mi.state = _tree.showHidden ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (a == @selector(togglePreviewTabs:)) { mi.state = _content.previewEnabled ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (a == @selector(toggleWordWrap:)) { mi.state = _content.wordWrap ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (a == @selector(toggleMinimap:)) { mi.state = _content.showsMinimap ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    // A draft is always savable (⌘S asks where): its edits go to a backup file, so the editor reads as clean.
    if (a == @selector(saveDocument:)) return _content.tabCount > 0;     // a clean file: ⌘S does nothing, without a beep
    if (a == @selector(saveAllDocuments:)) return _content.dirtyCount > 0;
    if (a == @selector(closeTab:)) return YES;               // a tab, else the key window (an empty main window too)
    if (a == @selector(closeAllTabs:)) return tabs > 0;
    if (a == @selector(closeOtherTabs:) || a == @selector(nextTab:) || a == @selector(previousTab:)) return tabs > 1;
    if (a == @selector(selectTabByNumber:)) return mi.tag == 9 ? tabs > 0 : (NSUInteger)mi.tag <= tabs;
    if (a == @selector(pinTab:)) return tabs > 0;
    if (a == @selector(renameItem:))
        return targets.count == 1 && ![target isEqualToString:_tree.rootPath];
    if (a == @selector(trashItem:)) {
        NSUInteger n = [self trashablePaths:targets].count;
        mi.title = n > 1 ? [NSString stringWithFormat:FTL(@"Move %lu Items to Trash"), (unsigned long)n] : FTL(@"Move to Trash");
        return n > 0;
    }
    if (a == @selector(newFile:) || a == @selector(newFolder:) || a == @selector(quickOpen:) ||
        a == @selector(searchWorkspace:)) return hasRoot;
    if (a == @selector(nextSearchResult:) || a == @selector(previousSearchResult:)) return _search.hasResults;
    if (a == @selector(copyItemPath:)) {
        mi.title = targets.count > 1 ? [NSString stringWithFormat:FTL(@"Copy %lu Paths"), (unsigned long)targets.count] : FTL(@"Copy Path");
        return targets.count > 0;
    }
    if (a == @selector(revealInFinder:)) return targets.count > 0;
    if (a == @selector(setAutoSave:)) { mi.state = mi.tag == _content.autoSaveMode ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (a == @selector(setAppearanceMode:)) {
        mi.state = mi.tag == [NSUserDefaults.standardUserDefaults integerForKey:@"appearance"] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (a == @selector(togglePreview:) || a == @selector(splitPreview:) || a == @selector(sourceOnly:)) {
        MarkupLayout l = _content.activeMarkupLayout;
        MarkupLayout mine = a == @selector(togglePreview:) ? MarkupPreview : a == @selector(splitPreview:) ? MarkupSplit : MarkupSource;
        mi.state = _content.activeIsMarkup && l == mine ? NSControlStateValueOn : NSControlStateValueOff;
        return _content.activeIsMarkup;
    }
    BOOL pdf = _content.activePDF != nil;
    if (a == @selector(zoomInAction:) || a == @selector(zoomOutAction:) || a == @selector(zoomResetAction:) || a == @selector(zoomActualAction:)) {
        if (a == @selector(zoomResetAction:)) mi.title = (pdf || _content.activeImage) ? FTL(@"Fit to Window") : FTL(@"Default Size");
        return _content.canZoom;
    }
    if (a == @selector(rotateLeftAction:) || a == @selector(rotateRightAction:)) return _content.activeCanRotate;
    if (a == @selector(togglePDFThumbsAction:)) { mi.state = _content.activePDF.showsThumbnails; return pdf; }
    if (a == @selector(togglePDFTwoPagesAction:)) { mi.state = _content.activePDF.twoPages; return pdf; }
    if (a == @selector(openInDefaultAppAction:)) return _content.currentPath != nil;
    if (a == @selector(promptGoToLine:)) {
        mi.title = pdf ? FTL(@"Go to Page…") : FTL(@"Go to Line…");
        return pdf || (_content.editor != nil && !(_content.activeIsMarkup && _content.activeMarkupLayout == MarkupPreview));
    }
    BOOL dataView = _content.activeHasDataView;
    if (a == @selector(showFind:) && dataView) return YES;
    if (a == @selector(showFind:) || a == @selector(findNextMatch:) || a == @selector(findPrevMatch:)) {
        if (pdf) return YES;
        if (a == @selector(showFind:)) return _content.editor != nil && !(_content.activeMarkupKind == MarkupHTML && _content.activeMarkupLayout == MarkupPreview);
        return _content.editor != nil && !(_content.activeIsMarkup && _content.activeMarkupLayout == MarkupPreview);
    }
    if (a == @selector(showReplace:))
        return _content.editor != nil && !(_content.activeIsMarkup && _content.activeMarkupLayout == MarkupPreview);
    if (a == @selector(viewAuto:) || a == @selector(viewText:) || a == @selector(viewHex:) ||
        a == @selector(viewQuickLook:)) return _content.currentPath != nil;
    return YES;
}

// Context-menu item → its stamped paths; main menu / keyboard → tree selection, else the open file.
- (NSArray<NSString *> *)targetPathsFrom:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class] && [sender tag] == kContextTag) return [sender representedObject] ?: @[];
    NSArray *sel = _tree.selectedPaths;
    if (sel.count) return sel;
    return _content.currentPath ? @[_content.currentPath] : @[];
}

- (NSString *)targetPathFrom:(id)sender { return [self targetPathsFrom:sender].firstObject; }

- (void)saveDocument:(id)s {
    if (!_content.activeIsUntitled && !_content.activeIsDirty) return;    // nothing to write; don't touch the file
    [_content save];
    [self updateTitle];
}
- (void)reloadTree:(id)s { [_tree reload]; }
- (void)toggleHidden:(id)s { FTSettings.shared.showHidden = !FTSettings.shared.showHidden; }
- (void)showSettings:(id)s { [SettingsWindow.shared reloadFromSettings]; [SettingsWindow.shared showWindow:nil]; [SettingsWindow.shared.window makeKeyAndOrderFront:nil]; }
- (void)revealInFinder:(id)s {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in [self targetPathsFrom:s]) [urls addObject:[NSURL fileURLWithPath:p]];
    if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
}
- (void)copyItemPath:(id)s {
    NSArray *paths = [self targetPathsFrom:s];
    if (!paths.count) return;
    NSPasteboard *pb = _pasteboard ?: NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[paths componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}
- (void)showFind:(id)s {
    if (_content.activeHasDataView || (_content.activeIsMarkup && _content.activeMarkupLayout == MarkupPreview)) [_content findInPreview];
    else [_content showFindBar];
}

#pragma mark Appearance

// 0 跟随系统, 1 浅色, 2 深色 — the window, sheets, previews and the editor colours all follow NSApp.appearance.
+ (void)applyAppearance:(NSInteger)mode {
    NSApp.appearance = mode == 1 ? [NSAppearance appearanceNamed:NSAppearanceNameAqua]
                     : mode == 2 ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
}

- (NSMenuItem *)appearanceMenuItem {
    NSMenuItem *top = item(FTL(@"Appearance"), NULL, nil, 0);
    NSMenu *m = [[NSMenu alloc] initWithTitle:FTL(@"Appearance")];
    NSArray *titles = @[FTL(@"System"), FTL(@"Light"), FTL(@"Dark")];
    for (NSInteger i = 0; i < 3; i++) { NSMenuItem *x = item(titles[i], @selector(setAppearanceMode:), nil, 0); x.tag = i; [m addItem:x]; }
    top.submenu = m;
    return top;
}

- (void)setAppearanceMode:(NSMenuItem *)s { FTSettings.shared.appearance = s.tag; }

- (void)newUntitled:(id)s { [_content newUntitledDocument]; }

- (NSMenuItem *)autoSaveMenuItem {
    NSMenuItem *top = item(FTL(@"Auto Save"), NULL, nil, 0);
    NSMenu *m = [[NSMenu alloc] initWithTitle:FTL(@"Auto Save")];
    NSArray *titles = @[FTL(@"Off"), FTL(@"1 Second After Typing Stops"), FTL(@"On Switching Files or Windows")];
    for (NSInteger i = 0; i < 3; i++) { NSMenuItem *x = item(titles[i], @selector(setAutoSave:), nil, 0); x.tag = i; [m addItem:x]; }
    top.submenu = m;
    return top;
}

- (void)setAutoSave:(NSMenuItem *)s {
    FTSettings.shared.autoSaveMode = s.tag;
    [_content flushAutoSave];
    [self updateTitle];
}

- (void)togglePreview:(id)s {
    MarkupLayout l = _content.activeMarkupLayout;
    _content.activeMarkupLayout = l == MarkupPreview ? MarkupSource : MarkupPreview;
}
- (void)splitPreview:(id)s { _content.activeMarkupLayout = _content.activeMarkupLayout == MarkupSplit ? MarkupSource : MarkupSplit; }
- (void)sourceOnly:(id)s { _content.activeMarkupLayout = MarkupSource; }
- (void)toggleMinimap:(id)s { FTSettings.shared.showsMinimap = !_content.showsMinimap; }
- (void)toggleWordWrap:(id)s { FTSettings.shared.wordWrap = !_content.wordWrap; }
- (void)showReplace:(id)s { [_content showReplaceBar]; }
- (void)findNextMatch:(id)s { [_content findNext:NO]; }
- (void)findPrevMatch:(id)s { [_content findNext:YES]; }
- (void)showFilesTab:(id)s { [self showSidebarTab:0]; [_win makeFirstResponder:_outline]; }
- (void)nextSearchResult:(id)s { [_search selectNextResult:NO]; }
- (void)previousSearchResult:(id)s { [_search selectNextResult:YES]; }
- (void)searchWorkspace:(id)s {
    [self showSidebarTab:1];
    [_search focusWithQuery:_content.editor.selectedText];
}

- (void)saveAllDocuments:(id)s { [_content saveAll]; [self updateTitle]; }
// ⌘W belongs to the key window: in Settings or a panel it closes that window, not a tab behind it.
- (NSWindow *)windowForClose {
    NSWindow *k = _keyWindowOverride ?: NSApp.keyWindow;
    return k && k != _win && k.isVisible && (k.styleMask & NSWindowStyleMaskClosable) ? k : nil;
}
- (void)closeTab:(id)s {
    NSWindow *other = self.windowForClose;
    if (other) [other performClose:s];
    else if (_content.tabCount) [_content closeActive];
    else [_win performClose:s];
}
- (void)closeOtherTabs:(id)s { [_content closeOthers]; }
- (void)closeAllTabs:(id)s { [_content closeAll]; }
- (void)reopenClosedTab:(id)s { if (![_content reopenClosed]) NSBeep(); }
- (void)nextTab:(id)s { [_content selectTabOffset:1]; }
- (void)previousTab:(id)s { [_content selectTabOffset:-1]; }
- (void)selectTabByNumber:(NSMenuItem *)s { [_content selectTabAtIndex:s.tag == 9 ? -1 : s.tag - 1]; }
- (void)pinTab:(id)s { [_content pinActive]; }
- (void)togglePreviewTabs:(id)s {
    _content.previewEnabled = !_content.previewEnabled;
    [NSUserDefaults.standardUserDefaults setBool:!_content.previewEnabled forKey:@"disablePreviewTabs"];
    if (!_content.previewEnabled) [_content pinActive];
}

- (void)reshow:(ViewerKind)k { if (_content.currentPath) [_content reopenActiveAs:k]; }
- (void)viewAuto:(id)s { [self reshow:ViewerAuto]; }
- (void)viewText:(id)s { [self reshow:ViewerText]; }
- (void)viewHex:(id)s { [self reshow:ViewerHex]; }
- (void)viewQuickLook:(id)s { [self reshow:ViewerQuickLook]; }

- (void)promptGoToLine:(id)s {
    PDFPreview *pdf = _content.activePDF;
    NSAlert *a = [NSAlert new];
    a.messageText = pdf ? [NSString stringWithFormat:FTL(@"Go to Page (1–%lu)"), (unsigned long)pdf.pageCount] : FTL(@"Go to Line");
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    a.accessoryView = tf;
    [a addButtonWithTitle:FTL(@"Go")];
    [a addButtonWithTitle:FTL(@"Cancel")];
    a.window.initialFirstResponder = tf;
    if ([a runModal] != NSAlertFirstButtonReturn || tf.integerValue <= 0) return;
    if (pdf) [_content goToPage:(NSUInteger)tf.integerValue - 1];
    else [_content.editor gotoLine:(NSUInteger)tf.integerValue];
}

- (void)showDefaultApps:(id)s {
    DefaultAppsPanel *p = [DefaultAppsPanel new];
    _defaultAppsPanel = p;                                 // keep it alive while the sheet is up
    [p beginSheetForWindow:_win];
}

- (void)zoomInAction:(id)s { [_content zoomIn]; }
- (void)zoomOutAction:(id)s { [_content zoomOut]; }
- (void)zoomResetAction:(id)s { [_content zoomReset]; }
- (void)zoomActualAction:(id)s { [_content zoomActualSize]; }
- (void)rotateLeftAction:(id)s { [_content rotate:-1]; }
- (void)rotateRightAction:(id)s { [_content rotate:1]; }
- (void)togglePDFThumbsAction:(id)s { [_content togglePDFThumbnails]; }
- (void)togglePDFTwoPagesAction:(id)s { [_content togglePDFTwoPages]; }
- (void)openInDefaultAppAction:(id)s { [_content openInDefaultApp]; }

@end

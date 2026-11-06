#import "AppDelegate.h"
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
    NSMenuItem *recent = item(@"最近打开", NULL, nil, 0);
    _recentMenu = [[NSMenu alloc] initWithTitle:@"最近打开"];
    _recentMenu.delegate = self;
    recent.submenu = _recentMenu;

    NSArray *spec = @[
        @[@"FeatherView", @[item(@"关于 FeatherView", @selector(orderFrontStandardAboutPanel:), nil, 0),
                        NSMenuItem.separatorItem,
                        item(@"设置…", @selector(showSettings:), @",", C),
                        item(@"默认打开方式…", @selector(showDefaultApps:), nil, 0),
                        NSMenuItem.separatorItem,
                        item(@"隐藏 FeatherView", @selector(hide:), @"h", C),
                        item(@"退出 FeatherView", @selector(terminate:), @"q", C)]],
        @[@"文件", @[item(@"新建文档", @selector(newUntitled:), @"n", C),
                    item(@"新建文件…", @selector(newFile:), @"n", C | O),
                    item(@"新建文件夹…", @selector(newFolder:), @"n", C | S),
                    NSMenuItem.separatorItem,
                    item(@"打开文件夹…", @selector(openFolder:), @"o", C),
                    recent,
                    item(@"切换工作区…", @selector(switchWorkspace:), @"r", K),
                    item(@"快速打开文件…", @selector(quickOpen:), @"p", C),
                    NSMenuItem.separatorItem,
                    item(@"保存", @selector(saveDocument:), @"s", C),
                    item(@"全部保存", @selector(saveAllDocuments:), @"s", C | O),
                    [self autoSaveMenuItem],
                    NSMenuItem.separatorItem,
                    item(@"关闭标签页", @selector(closeTab:), @"w", C),
                    item(@"关闭其他标签页", @selector(closeOtherTabs:), nil, 0),
                    item(@"关闭所有标签页", @selector(closeAllTabs:), @"w", C | O),
                    item(@"重新打开关闭的标签页", @selector(reopenClosedTab:), @"t", C | S),
                    NSMenuItem.separatorItem,
                    item(@"重命名…", @selector(renameItem:), nil, 0),
                    item(@"移到废纸篓", @selector(trashItem:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(@"刷新文件树", @selector(reloadTree:), @"r", C),
                    item(@"在访达中显示", @selector(revealInFinder:), @"r", C | S),
                    item(@"用默认应用打开", @selector(openInDefaultAppAction:), @"o", C | S),
                    item(@"拷贝路径", @selector(copyItemPath:), @"c", C | O),
                    NSMenuItem.separatorItem,
                    item(@"关闭窗口", @selector(performClose:), @"w", C | S)]],
        @[@"编辑", @[item(@"撤销", @selector(undo:), @"z", C),
                    item(@"重做", @selector(redo:), @"z", C | S),
                    NSMenuItem.separatorItem,
                    item(@"剪切", @selector(cut:), @"x", C),
                    item(@"拷贝", @selector(copy:), @"c", C),
                    item(@"粘贴", @selector(paste:), @"v", C),
                    item(@"全选", @selector(selectAll:), @"a", C),
                    NSMenuItem.separatorItem,
                    item(@"查找…", @selector(showFind:), @"f", C),
                    item(@"查找和替换…", @selector(showReplace:), @"f", C | O),
                    item(@"查找下一个", @selector(findNextMatch:), @"g", C),
                    item(@"查找上一个", @selector(findPrevMatch:), @"g", C | S),
                    item(@"在工作区中搜索…", @selector(searchWorkspace:), @"f", C | S),
                    item(@"下一个搜索结果", @selector(nextSearchResult:), [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey], 0),
                    item(@"上一个搜索结果", @selector(previousSearchResult:), [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey], S),
                    item(@"跳到行…", @selector(promptGoToLine:), @"l", C)]],
        @[@"显示", @[item(@"放大", @selector(zoomInAction:), @"=", C),
                    item(@"缩小", @selector(zoomOutAction:), @"-", C),
                    item(@"适合窗口 / 恢复默认大小", @selector(zoomResetAction:), @"0", C),
                    item(@"实际大小", @selector(zoomActualAction:), nil, 0),
                    item(@"向左旋转", @selector(rotateLeftAction:), nil, 0),
                    item(@"向右旋转", @selector(rotateRightAction:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(@"PDF 缩略图", @selector(togglePDFThumbsAction:), @"t", C | O),
                    item(@"PDF 双页显示", @selector(togglePDFTwoPagesAction:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(@"预览（Markdown、表格、JSON…）", @selector(togglePreview:), @"v", C | S),
                    item(@"并排预览", @selector(splitPreview:), @"v", C | O),
                    item(@"仅源码", @selector(sourceOnly:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(@"自动换行", @selector(toggleWordWrap:), @"z", O),
                    item(@"显示小地图", @selector(toggleMinimap:), @"m", NSEventModifierFlagCommand | NSEventModifierFlagOption),
                    [self appearanceMenuItem],
                    NSMenuItem.separatorItem,
                    item(@"文件树", @selector(showFilesTab:), @"e", C | S),
                    item(@"搜索", @selector(searchWorkspace:), nil, 0),
                    NSMenuItem.separatorItem,
                    item(@"自动", @selector(viewAuto:), @"0", C | O),
                    item(@"作为文本", @selector(viewText:), @"1", C | O),
                    item(@"作为十六进制", @selector(viewHex:), @"2", C | O),
                    item(@"快速查看", @selector(viewQuickLook:), @"3", C | O),
                    NSMenuItem.separatorItem,
                    item(@"显示隐藏文件", @selector(toggleHidden:), @".", C | S)]],
        @[@"标签页", [self tabMenuItems]],
    ];
    NSMenu *bar = [NSMenu new];
    for (NSArray *m in spec) {
        NSMenuItem *top = [NSMenuItem new];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:m[0]];
        for (NSMenuItem *i in m[1]) [sub addItem:i];
        if ([m[0] isEqualToString:@"显示"]) {               // ⌘+ (shift-=) as well as ⌘=
            NSMenuItem *plus = item(@"放大", @selector(zoomInAction:), @"+", NSEventModifierFlagCommand);
            plus.hidden = YES;
            plus.allowsKeyEquivalentWhenHidden = YES;
            [sub addItem:plus];
        }
        top.submenu = sub;
        [bar addItem:top];
    }
    NSApp.mainMenu = bar;
}

- (NSArray<NSMenuItem *> *)tabMenuItems {
    const NSEventModifierFlags C = NSEventModifierFlagCommand, O = NSEventModifierFlagOption;
    NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSMutableArray *a = [@[item(@"下一个标签页", @selector(nextTab:), right, C | O),
                           item(@"上一个标签页", @selector(previousTab:), left, C | O),
                           NSMenuItem.separatorItem,
                           item(@"保持打开（固定预览标签页）", @selector(pinTab:), nil, 0),
                           item(@"单击文件时使用预览标签页", @selector(togglePreviewTabs:), nil, 0),
                           NSMenuItem.separatorItem] mutableCopy];
    for (int i = 1; i <= 9; i++) {
        NSMenuItem *m = item(i == 9 ? @"最后一个标签页" : [NSString stringWithFormat:@"第 %d 个标签页", i],
                             @selector(selectTabByNumber:), [NSString stringWithFormat:@"%d", i], C);
        m.tag = i;
        [a addObject:m];
    }
    return a;
}

- (NSMenu *)treeContextMenu {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    for (NSMenuItem *i in @[item(@"新建文件…", @selector(newFile:), nil, 0),
                            item(@"新建文件夹…", @selector(newFolder:), nil, 0),
                            NSMenuItem.separatorItem,
                            item(@"重命名…", @selector(renameItem:), nil, 0),
                            item(@"移到废纸篓", @selector(trashItem:), nil, 0),
                            NSMenuItem.separatorItem,
                            item(@"在访达中显示", @selector(revealInFinder:), nil, 0),
                            item(@"拷贝路径", @selector(copyItemPath:), nil, 0)]) { i.tag = kContextTag; [m addItem:i]; }
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
            [self addRemoveAlternateFor:r title:[@"从列表中移除 " stringByAppendingString:r.stringByAbbreviatingWithTildeInPath] to:menu];
        }
        if (!menu.numberOfItems) { NSMenuItem *e = item(@"无", NULL, nil, 0); e.enabled = NO; [menu addItem:e]; }
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *hint = item(@"按住 ⌥ 可单独移除", NULL, nil, 0);
        hint.enabled = NO;
        [menu addItem:hint];
        [menu addItem:item(@"清除列表", @selector(clearRecent:), nil, 0)];
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
        NSMenuItem *h = item(@"最近的工作区", NULL, nil, 0);
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
        if (![r isEqualToString:root]) [self addRemoveAlternateFor:r title:[@"从列表中移除 " stringByAppendingString:r.lastPathComponent] to:menu];
    }
    if (recent.count > 1) {
        NSMenuItem *hint = item(@"按住 ⌥ 可单独移除", NULL, nil, 0);
        hint.enabled = NO;
        [menu addItem:hint];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:item(@"打开文件夹…", @selector(openFolder:), nil, 0)];
    [menu addItem:item(@"按名称切换工作区…", @selector(switchWorkspace:), nil, 0)];
    if (root) [menu addItem:item(@"在访达中显示工作区", @selector(revealRootInFinder:), nil, 0)];
    if (recent.count > 1) [menu addItem:item(@"清除最近列表", @selector(clearRecent:), nil, 0)];
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
    if (a == @selector(saveDocument:)) return _content.editor.isDirty;
    if (a == @selector(saveAllDocuments:)) return _content.dirtyCount > 0;
    if (a == @selector(closeTab:) || a == @selector(closeAllTabs:)) return tabs > 0;
    if (a == @selector(closeOtherTabs:) || a == @selector(nextTab:) || a == @selector(previousTab:)) return tabs > 1;
    if (a == @selector(selectTabByNumber:)) return mi.tag == 9 ? tabs > 0 : (NSUInteger)mi.tag <= tabs;
    if (a == @selector(pinTab:)) return tabs > 0;
    if (a == @selector(renameItem:))
        return targets.count == 1 && ![target isEqualToString:_tree.rootPath];
    if (a == @selector(trashItem:)) {
        NSUInteger n = [self trashablePaths:targets].count;
        mi.title = n > 1 ? [NSString stringWithFormat:@"将 %lu 项移到废纸篓", (unsigned long)n] : @"移到废纸篓";
        return n > 0;
    }
    if (a == @selector(newFile:) || a == @selector(newFolder:) || a == @selector(quickOpen:) ||
        a == @selector(searchWorkspace:)) return hasRoot;
    if (a == @selector(nextSearchResult:) || a == @selector(previousSearchResult:)) return _search.hasResults;
    if (a == @selector(copyItemPath:)) {
        mi.title = targets.count > 1 ? [NSString stringWithFormat:@"拷贝 %lu 个路径", (unsigned long)targets.count] : @"拷贝路径";
        return targets.count > 0;
    }
    if (a == @selector(revealInFinder:)) return targets.count > 0;
    if (a == @selector(setAutoSave:)) { mi.state = mi.tag == _content.autoSaveMode ? NSControlStateValueOn : NSControlStateValueOff; return YES; }
    if (a == @selector(setAppearanceMode:)) {
        mi.state = mi.tag == [NSUserDefaults.standardUserDefaults integerForKey:@"appearance"] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (a == @selector(saveDocument:) && _content.activeIsUntitled) return YES;      // ⌘S asks where to save it
    if (a == @selector(togglePreview:) || a == @selector(splitPreview:) || a == @selector(sourceOnly:)) {
        MarkupLayout l = _content.activeMarkupLayout;
        MarkupLayout mine = a == @selector(togglePreview:) ? MarkupPreview : a == @selector(splitPreview:) ? MarkupSplit : MarkupSource;
        mi.state = _content.activeIsMarkup && l == mine ? NSControlStateValueOn : NSControlStateValueOff;
        return _content.activeIsMarkup;
    }
    BOOL pdf = _content.activePDF != nil;
    if (a == @selector(zoomInAction:) || a == @selector(zoomOutAction:) || a == @selector(zoomResetAction:) || a == @selector(zoomActualAction:)) {
        if (a == @selector(zoomResetAction:)) mi.title = (pdf || _content.activeImage) ? @"适合窗口" : @"恢复默认大小";
        return _content.canZoom;
    }
    if (a == @selector(rotateLeftAction:) || a == @selector(rotateRightAction:)) return _content.activeCanRotate;
    if (a == @selector(togglePDFThumbsAction:)) { mi.state = _content.activePDF.showsThumbnails; return pdf; }
    if (a == @selector(togglePDFTwoPagesAction:)) { mi.state = _content.activePDF.twoPages; return pdf; }
    if (a == @selector(openInDefaultAppAction:)) return _content.currentPath != nil;
    if (a == @selector(promptGoToLine:)) {
        mi.title = pdf ? @"跳到页…" : @"跳到行…";
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

- (void)saveDocument:(id)s { [_content save]; [self updateTitle]; }
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
    NSMenuItem *top = item(@"外观", NULL, nil, 0);
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"外观"];
    NSArray *titles = @[@"跟随系统", @"浅色", @"深色"];
    for (NSInteger i = 0; i < 3; i++) { NSMenuItem *x = item(titles[i], @selector(setAppearanceMode:), nil, 0); x.tag = i; [m addItem:x]; }
    top.submenu = m;
    return top;
}

- (void)setAppearanceMode:(NSMenuItem *)s { FTSettings.shared.appearance = s.tag; }

- (void)newUntitled:(id)s { [_content newUntitledDocument]; }

- (NSMenuItem *)autoSaveMenuItem {
    NSMenuItem *top = item(@"自动保存", NULL, nil, 0);
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"自动保存"];
    NSArray *titles = @[@"关闭", @"停止输入 1 秒后保存", @"切换文件或窗口时保存"];
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
- (void)closeTab:(id)s { if (_content.tabCount) [_content closeActive]; else [_win performClose:s]; }
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
    a.messageText = pdf ? [NSString stringWithFormat:@"跳到页（共 %lu 页）", (unsigned long)pdf.pageCount] : @"跳到行";
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    a.accessoryView = tf;
    [a addButtonWithTitle:@"跳转"];
    [a addButtonWithTitle:@"取消"];
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

#import "SettingsWindow.h"
#import "Settings.h"

@implementation SettingsWindow {
    NSButton *_showHiddenBox, *_gitignoreBox, *_minimapBox, *_wrapBox;
    NSTextField *_alwaysHiddenField, *_searchSkippedField;
    NSPopUpButton *_appearancePopup, *_autoSavePopup;
}

+ (instancetype)shared {
    static SettingsWindow *w;
    if (!w) w = [SettingsWindow new];
    return w;
}

static NSTextField *note(NSString *s) {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.font = [NSFont systemFontOfSize:11];
    t.textColor = NSColor.secondaryLabelColor;
    t.preferredMaxLayoutWidth = 360;
    return t;
}

static NSTextField *heading(NSString *s) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    return t;
}

static NSTextField *rowLabel(NSString *s) {
    NSTextField *t = [NSTextField labelWithString:s];
    t.alignment = NSTextAlignmentRight;
    return t;
}

static NSStackView *column(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 4;
    return s;
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 520)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:YES];
    w.title = @"设置";
    w.releasedWhenClosed = NO;
    if (!(self = [super initWithWindow:w])) return nil;

    _appearancePopup = [NSPopUpButton new];
    [_appearancePopup addItemsWithTitles:@[@"跟随系统", @"浅色", @"深色"]];
    _appearancePopup.target = self; _appearancePopup.action = @selector(appearanceChanged:);

    _showHiddenBox = [NSButton checkboxWithTitle:@"显示隐藏文件（以 . 开头的文件和访达中隐藏的文件）" target:self action:@selector(boxChanged:)];
    _alwaysHiddenField = [NSTextField textFieldWithString:@""];
    _alwaysHiddenField.placeholderString = @".git, .DS_Store, *.pyc";
    _alwaysHiddenField.delegate = self;
    [_alwaysHiddenField.widthAnchor constraintEqualToConstant:360].active = YES;
    _searchSkippedField = [NSTextField textFieldWithString:@""];
    _searchSkippedField.placeholderString = @"node_modules, build, dist";
    _searchSkippedField.delegate = self;
    [_searchSkippedField.widthAnchor constraintEqualToConstant:360].active = YES;
    _gitignoreBox = [NSButton checkboxWithTitle:@"搜索内容时跳过 .gitignore 里的文件" target:self action:@selector(boxChanged:)];

    _autoSavePopup = [NSPopUpButton new];
    [_autoSavePopup addItemsWithTitles:@[@"关闭", @"停止输入 1 秒后保存", @"切换文件或窗口时保存"]];
    _autoSavePopup.target = self; _autoSavePopup.action = @selector(autoSaveChanged:);
    _minimapBox = [NSButton checkboxWithTitle:@"显示小地图" target:self action:@selector(boxChanged:)];
    _wrapBox = [NSButton checkboxWithTitle:@"自动换行（随窗口宽度）" target:self action:@selector(boxChanged:)];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[heading(@"外观"), NSGridCell.emptyContentView],
        @[rowLabel(@"主题："), _appearancePopup],
        @[heading(@"文件"), NSGridCell.emptyContentView],
        @[NSGridCell.emptyContentView, column(@[_showHiddenBox, note(@"也可以用 ⇧⌘. 随时切换。")])],
        @[rowLabel(@"始终隐藏："), column(@[_alwaysHiddenField, note(@"文件树、快速打开和搜索都不显示这些名字。逗号分隔，可用通配符，如 *.pyc。")])],
        @[rowLabel(@"搜索时跳过："), column(@[_searchSkippedField, note(@"搜索和快速打开不进入这些文件夹（文件树里照常显示）。")])],
        @[NSGridCell.emptyContentView, _gitignoreBox],
        @[heading(@"编辑器"), NSGridCell.emptyContentView],
        @[rowLabel(@"自动保存："), _autoSavePopup],
        @[NSGridCell.emptyContentView, column(@[_wrapBox, note(@"也可以用 ⌥Z 切换。超过 100 万行或 32 MB 的文件不换行。")])],
        @[NSGridCell.emptyContentView, _minimapBox]]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    const NSInteger headings[] = {0, 2, 7};
    for (int k = 0; k < 3; k++) {
        NSInteger r = headings[k];
        NSGridRow *row = [grid rowAtIndex:r];
        [row mergeCellsInRange:NSMakeRange(0, 2)];
        [row cellAtIndex:0].xPlacement = NSGridCellPlacementLeading;
        row.topPadding = r ? 10 : 0;
    }
    for (NSInteger r = 0; r < grid.numberOfRows; r++) [grid rowAtIndex:r].rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSButton *reset = [NSButton buttonWithTitle:@"文件设置恢复默认" target:self action:@selector(resetFiles:)];
    NSStackView *all = [NSStackView stackViewWithViews:@[grid, reset]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeLeading;
    all.spacing = 18;
    all.detachesHiddenViews = YES;
    all.edgeInsets = NSEdgeInsetsMake(20, 24, 20, 24);
    w.contentView = all;
    [self reloadFromSettings];
    [reset.leadingAnchor constraintEqualToAnchor:_alwaysHiddenField.leadingAnchor].active = YES;
    [all layoutSubtreeIfNeeded];
    [w setContentSize:all.fittingSize];
    [w center];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadFromSettings) name:FTSettingsDidChange object:nil];
    return self;
}

- (NSButton *)showHiddenBox { return _showHiddenBox; }
- (NSButton *)gitignoreBox { return _gitignoreBox; }
- (NSButton *)minimapBox { return _minimapBox; }
- (NSButton *)wrapBox { return _wrapBox; }
- (NSTextField *)alwaysHiddenField { return _alwaysHiddenField; }
- (NSTextField *)searchSkippedField { return _searchSkippedField; }
- (NSPopUpButton *)appearancePopup { return _appearancePopup; }
- (NSPopUpButton *)autoSavePopup { return _autoSavePopup; }

- (void)reloadFromSettings {
    FTSettings *s = FTSettings.shared;
    [_appearancePopup selectItemAtIndex:s.appearance];
    _showHiddenBox.state = s.showHidden;
    _gitignoreBox.state = s.respectGitignore;
    _minimapBox.state = s.showsMinimap;
    _wrapBox.state = s.wordWrap;
    [_autoSavePopup selectItemAtIndex:MIN(2, MAX(0, s.autoSaveMode))];
    if (self.window.firstResponder != _alwaysHiddenField.currentEditor) _alwaysHiddenField.stringValue = [s.alwaysHidden componentsJoinedByString:@", "];
    if (self.window.firstResponder != _searchSkippedField.currentEditor) _searchSkippedField.stringValue = [s.searchSkipped componentsJoinedByString:@", "];
}

- (void)appearanceChanged:(NSPopUpButton *)p { FTSettings.shared.appearance = p.indexOfSelectedItem; }
- (void)autoSaveChanged:(NSPopUpButton *)p { FTSettings.shared.autoSaveMode = p.indexOfSelectedItem; }
- (void)boxChanged:(NSButton *)b {
    FTSettings *s = FTSettings.shared;
    if (b == _showHiddenBox) s.showHidden = b.state == NSControlStateValueOn;
    else if (b == _gitignoreBox) s.respectGitignore = b.state == NSControlStateValueOn;
    else if (b == _minimapBox) s.showsMinimap = b.state == NSControlStateValueOn;
    else if (b == _wrapBox) s.wordWrap = b.state == NSControlStateValueOn;
}

- (void)commitFields {
    FTSettings *s = FTSettings.shared;
    NSArray *hidden = [FTSettings listFromString:_alwaysHiddenField.stringValue];
    NSArray *skipped = [FTSettings listFromString:_searchSkippedField.stringValue];
    if (![hidden isEqualToArray:s.alwaysHidden]) s.alwaysHidden = hidden;
    if (![skipped isEqualToArray:s.searchSkipped]) s.searchSkipped = skipped;
}
- (void)controlTextDidEndEditing:(NSNotification *)n { [self commitFields]; }

- (void)resetFiles:(id)sender { [FTSettings.shared resetFileLists]; [self.window makeFirstResponder:nil]; [self reloadFromSettings]; }

@end

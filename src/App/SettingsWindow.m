#import "SettingsWindow.h"
#import "Localization.h"
#import "Settings.h"
#import "ShortcutField.h"
#import "HotKey.h"

@implementation SettingsWindow {
    NSButton *_showHiddenBox, *_gitignoreBox, *_minimapBox, *_wrapBox, *_remoteBox, *_closeBox, *_guidesBox, *_spaceBox;
    NSTextField *_alwaysHiddenField, *_searchSkippedField;
    NSPopUpButton *_appearancePopup, *_autoSavePopup;
    // The floating workspace
    NSButton *_floatHideBox, *_floatAddButton, *_floatRemoveButton;
    NSTableView *_floatFolderTable;
    FTShortcutField *_floatShortcutField;
    NSTextField *_floatShortcutNote;
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
    w.title = FTL(@"Settings");
    w.releasedWhenClosed = NO;
    if (!(self = [super initWithWindow:w])) return nil;
    w.delegate = self;

    _appearancePopup = [NSPopUpButton new];
    [_appearancePopup addItemsWithTitles:@[FTL(@"System"), FTL(@"Light"), FTL(@"Dark")]];
    _appearancePopup.target = self; _appearancePopup.action = @selector(appearanceChanged:);

    _showHiddenBox = [NSButton checkboxWithTitle:FTL(@"Show hidden files (dot files and files hidden in Finder)") target:self action:@selector(boxChanged:)];
    _alwaysHiddenField = [NSTextField textFieldWithString:@""];
    _alwaysHiddenField.placeholderString = @".git, .DS_Store, *.pyc";
    _alwaysHiddenField.delegate = self;
    [_alwaysHiddenField.widthAnchor constraintEqualToConstant:360].active = YES;
    _searchSkippedField = [NSTextField textFieldWithString:@""];
    _searchSkippedField.placeholderString = @"node_modules, build, dist";
    _searchSkippedField.delegate = self;
    [_searchSkippedField.widthAnchor constraintEqualToConstant:360].active = YES;
    _gitignoreBox = [NSButton checkboxWithTitle:FTL(@"Skip files listed in .gitignore when searching contents") target:self action:@selector(boxChanged:)];

    _autoSavePopup = [NSPopUpButton new];
    [_autoSavePopup addItemsWithTitles:@[FTL(@"Off"), FTL(@"1 Second After Typing Stops"), FTL(@"On Switching Files or Windows")]];
    _autoSavePopup.target = self; _autoSavePopup.action = @selector(autoSaveChanged:);
    _minimapBox = [NSButton checkboxWithTitle:FTL(@"Show minimap") target:self action:@selector(boxChanged:)];
    _wrapBox = [NSButton checkboxWithTitle:FTL(@"Wrap lines to the window width") target:self action:@selector(boxChanged:)];
    _remoteBox = [NSButton checkboxWithTitle:FTL(@"Load images from the web in Markdown previews") target:self action:@selector(boxChanged:)];
    _closeBox = [NSButton checkboxWithTitle:FTL(@"Auto-close brackets and quotes") target:self action:@selector(boxChanged:)];
    _guidesBox = [NSButton checkboxWithTitle:FTL(@"Show indent guides") target:self action:@selector(boxChanged:)];
    _spaceBox = [NSButton checkboxWithTitle:FTL(@"Show whitespace") target:self action:@selector(boxChanged:)];

    // The floating workspace: its folders, its system-wide shortcut, and whether it stays open.
    _floatShortcutField = [FTShortcutField new];
    __weak typeof(self) weakSelf = self;
    _floatShortcutField.validate = ^BOOL(NSString *s, NSString **problem) {
        return [weakSelf validateFloatShortcut:s problem:problem];
    };
    _floatShortcutField.onChange = ^(NSString *s) { [weakSelf floatShortcutPicked:s]; };
    _floatShortcutNote = note(@"");

    _floatFolderTable = [NSTableView new];
    NSTableColumn *fc = [[NSTableColumn alloc] initWithIdentifier:@"folder"];
    fc.width = 320;
    [_floatFolderTable addTableColumn:fc];
    _floatFolderTable.headerView = nil;
    _floatFolderTable.rowHeight = 18;
    _floatFolderTable.dataSource = self;
    _floatFolderTable.delegate = self;
    _floatFolderTable.allowsMultipleSelection = NO;
    _floatFolderTable.doubleAction = @selector(revealFloatFolder:);
    _floatFolderTable.target = self;
    NSScrollView *folderScroll = [NSScrollView new];
    folderScroll.documentView = _floatFolderTable;
    folderScroll.hasVerticalScroller = YES;
    folderScroll.borderType = NSBezelBorder;
    [folderScroll.widthAnchor constraintEqualToConstant:360].active = YES;
    [folderScroll.heightAnchor constraintEqualToConstant:84].active = YES;

    _floatAddButton = [NSButton buttonWithTitle:FTL(@"Add…") target:self action:@selector(addFloatFolder:)];
    _floatRemoveButton = [NSButton buttonWithTitle:FTL(@"Remove") target:self action:@selector(removeFloatFolder:)];
    _floatAddButton.controlSize = _floatRemoveButton.controlSize = NSControlSizeSmall;
    NSStackView *folderButtons = [NSStackView stackViewWithViews:@[_floatAddButton, _floatRemoveButton]];
    folderButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    folderButtons.spacing = 6;

    _floatHideBox = [NSButton checkboxWithTitle:FTL(@"Hide it as soon as it loses the keyboard") target:self action:@selector(boxChanged:)];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[heading(FTL(@"Appearance")), NSGridCell.emptyContentView],
        @[rowLabel(FTL(@"Theme:")), _appearancePopup],
        @[heading(FTL(@"Files")), NSGridCell.emptyContentView],
        @[NSGridCell.emptyContentView, column(@[_showHiddenBox, note(FTL(@"You can also toggle this at any time with ⇧⌘."))])],
        @[rowLabel(FTL(@"Always hide:")), column(@[_alwaysHiddenField, note(FTL(@"Never shown in the file tree, Quick Open or search. Separate with commas; wildcards such as *.pyc are allowed."))])],
        @[rowLabel(FTL(@"Skip when searching:")), column(@[_searchSkippedField, note(FTL(@"Search and Quick Open don’t look inside these folders (they still appear in the file tree)."))])],
        @[NSGridCell.emptyContentView, _gitignoreBox],
        @[heading(FTL(@"Editor")), NSGridCell.emptyContentView],
        @[rowLabel(FTL(@"Auto save:")), _autoSavePopup],
        @[NSGridCell.emptyContentView, column(@[_wrapBox, note(FTL(@"Toggle with ⌥⌘Z. Files over 1 million lines or 32 MB are not wrapped."))])],
        @[NSGridCell.emptyContentView, column(@[_minimapBox, _guidesBox, _spaceBox])],
        @[NSGridCell.emptyContentView, column(@[_closeBox, note(FTL(@"Quotes are not closed in plain text and Markdown."))])],
        @[heading(FTL(@"Floating Workspace")), NSGridCell.emptyContentView],
        @[rowLabel(FTL(@"Shortcut:")), column(@[_floatShortcutField,
            note(FTL(@"Works in any app, so it is taken from every other one. Click and press a combination; ⌫ clears it.")),
            _floatShortcutNote])],
        @[rowLabel(FTL(@"Folders:")), column(@[folderScroll, folderButtons,
            note(FTL(@"The panel’s header switches between these. Double-click one to show it in Finder."))])],
        @[NSGridCell.emptyContentView, column(@[_floatHideBox,
            note(FTL(@"Off: it stays up until you press the shortcut again or Esc."))])],
        @[heading(FTL(@"Previews")), NSGridCell.emptyContentView],
        @[NSGridCell.emptyContentView, column(@[_remoteBox, note(FTL(@"Off: images such as README badges show their description instead, and nothing is downloaded."))])]]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    const NSInteger headings[] = {0, 2, 7, 12, 16};
    for (int k = 0; k < 5; k++) {
        NSInteger r = headings[k];
        NSGridRow *row = [grid rowAtIndex:r];
        [row mergeCellsInRange:NSMakeRange(0, 2)];
        [row cellAtIndex:0].xPlacement = NSGridCellPlacementLeading;
        row.topPadding = r ? 10 : 0;
    }
    for (NSInteger r = 0; r < grid.numberOfRows; r++) [grid rowAtIndex:r].rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSButton *reset = [NSButton buttonWithTitle:FTL(@"Restore Default File Settings") target:self action:@selector(resetFiles:)];
    NSStackView *all = [NSStackView stackViewWithViews:@[grid, reset]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeLeading;
    all.spacing = 18;
    all.detachesHiddenViews = YES;
    NSView *content = [NSView new];
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:24],
        [all.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-24],
        [all.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [all.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-20]]];
    w.contentView = content;
    [self reloadFromSettings];
    [reset.leadingAnchor constraintEqualToAnchor:_alwaysHiddenField.leadingAnchor].active = YES;
    [content layoutSubtreeIfNeeded];
    [w setContentSize:content.fittingSize];
    [w center];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadFromSettings) name:FTSettingsDidChange object:nil];
    return self;
}

- (NSButton *)showHiddenBox { return _showHiddenBox; }
- (NSButton *)gitignoreBox { return _gitignoreBox; }
- (NSButton *)minimapBox { return _minimapBox; }
- (NSButton *)wrapBox { return _wrapBox; }
- (NSButton *)remoteImagesBox { return _remoteBox; }
- (NSButton *)autoCloseBox { return _closeBox; }
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
    _remoteBox.state = s.remoteImages;
    _closeBox.state = s.autoCloseBrackets;
    _guidesBox.state = s.showIndentGuides;
    _spaceBox.state = s.showWhitespace;
    [_autoSavePopup selectItemAtIndex:MIN(2, MAX(0, s.autoSaveMode))];
    if (self.window.firstResponder != _alwaysHiddenField.currentEditor) _alwaysHiddenField.stringValue = [s.alwaysHidden componentsJoinedByString:@", "];
    if (self.window.firstResponder != _searchSkippedField.currentEditor) _searchSkippedField.stringValue = [s.searchSkipped componentsJoinedByString:@", "];

    _floatHideBox.state = s.floatHidesWhenInactive;
    if (!_floatShortcutField.recording) _floatShortcutField.shortcut = s.floatShortcut;
    [_floatFolderTable reloadData];
    _floatRemoveButton.enabled = _floatFolderTable.selectedRow >= 0;
    // Whether macOS actually gave us the combination is only known once the panel has tried, and
    // it is worth saying plainly: a refused shortcut is a key that silently does nothing.
    NSString *problem = self.floatShortcutStatus ? self.floatShortcutStatus() : nil;
    _floatShortcutNote.stringValue = problem ?: @"";
    _floatShortcutNote.textColor = NSColor.systemRedColor;
    _floatShortcutNote.hidden = problem.length == 0;
}

- (void)appearanceChanged:(NSPopUpButton *)p { FTSettings.shared.appearance = p.indexOfSelectedItem; }
- (void)autoSaveChanged:(NSPopUpButton *)p { FTSettings.shared.autoSaveMode = p.indexOfSelectedItem; }
- (void)boxChanged:(NSButton *)b {
    FTSettings *s = FTSettings.shared;
    if (b == _showHiddenBox) s.showHidden = b.state == NSControlStateValueOn;
    else if (b == _gitignoreBox) s.respectGitignore = b.state == NSControlStateValueOn;
    else if (b == _minimapBox) s.showsMinimap = b.state == NSControlStateValueOn;
    else if (b == _wrapBox) s.wordWrap = b.state == NSControlStateValueOn;
    else if (b == _remoteBox) s.remoteImages = b.state == NSControlStateValueOn;
    else if (b == _closeBox) s.autoCloseBrackets = b.state == NSControlStateValueOn;
    else if (b == _guidesBox) s.showIndentGuides = b.state == NSControlStateValueOn;
    else if (b == _spaceBox) s.showWhitespace = b.state == NSControlStateValueOn;
    else if (b == _floatHideBox) s.floatHidesWhenInactive = b.state == NSControlStateValueOn;
}

- (void)commitFields {
    FTSettings *s = FTSettings.shared;
    NSArray *hidden = [FTSettings listFromString:_alwaysHiddenField.stringValue];
    NSArray *skipped = [FTSettings listFromString:_searchSkippedField.stringValue];
    if (![hidden isEqualToArray:s.alwaysHidden]) s.alwaysHidden = hidden;
    if (![skipped isEqualToArray:s.searchSkipped]) s.searchSkipped = skipped;
}
- (void)controlTextDidEndEditing:(NSNotification *)n { [self commitFields]; }
// A list typed without pressing Return still counts when the window is closed or left.
- (void)windowWillClose:(NSNotification *)n { [self.window makeFirstResponder:nil]; [self commitFields]; }
- (void)windowDidResignKey:(NSNotification *)n { [self commitFields]; }

- (void)resetFiles:(id)sender { [FTSettings.shared resetFileLists]; [self.window makeFirstResponder:nil]; [self reloadFromSettings]; }

#pragma mark The floating workspace

- (NSButton *)floatHidesBox { return _floatHideBox; }
- (NSButton *)floatAddButton { return _floatAddButton; }
- (NSButton *)floatRemoveButton { return _floatRemoveButton; }
- (NSTableView *)floatFolderTable { return _floatFolderTable; }
- (FTShortcutField *)floatShortcutField { return _floatShortcutField; }
- (NSTextField *)floatShortcutNote { return _floatShortcutNote; }

// A global shortcut is taken from every other app, so macOS refuses one without ⌘, ⌃ or ⌥. Whether
// another app already holds it only shows once it has been tried, which is what the note reports.
- (BOOL)validateFloatShortcut:(NSString *)s problem:(NSString **)problem {
    if (![FTHotKey isUsableShortcut:s]) {
        if (problem) *problem = FTL(@"Hold ⌘, ⌃ or ⌥ as well.");
        return NO;
    }
    return YES;
}

- (void)floatShortcutPicked:(NSString *)s {
    FTSettings.shared.floatShortcut = s ?: @"";
    [self reloadFromSettings];      // the panel has tried to register it by now
}

- (void)addFloatFolder:(id)sender {
    if (_folderChooser) {
        NSString *p = _folderChooser();
        if (p.length) [self adoptFolder:p];
        return;
    }
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.prompt = FTL(@"Choose");
    p.message = FTL(@"A folder the floating workspace can show");
    __weak typeof(self) weakSelf = self;
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) [weakSelf adoptFolder:p.URL.path];
    }];
}

- (void)adoptFolder:(NSString *)path {
    NSString *p = path.stringByStandardizingPath;
    if (!p.length) return;
    NSMutableArray *list = [FTSettings.shared.floatFolders mutableCopy];
    [list removeObject:p];
    [list insertObject:p atIndex:0];        // most recently chosen first, as the panel orders them
    while (list.count > 10) [list removeLastObject];
    FTSettings.shared.floatFolders = list;
    [self reloadFromSettings];
    NSUInteger row = [FTSettings.shared.floatFolders indexOfObject:p];
    if (row != NSNotFound) [_floatFolderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)removeFloatFolder:(id)sender {
    NSInteger row = _floatFolderTable.selectedRow;
    NSArray *folders = FTSettings.shared.floatFolders;
    if (row < 0 || row >= (NSInteger)folders.count) return;
    NSMutableArray *list = [folders mutableCopy];
    [list removeObjectAtIndex:(NSUInteger)row];
    FTSettings.shared.floatFolders = list;
    [self reloadFromSettings];
}

- (void)revealFloatFolder:(id)sender {
    NSInteger row = _floatFolderTable.clickedRow;
    NSArray *folders = FTSettings.shared.floatFolders;
    if (row < 0 || row >= (NSInteger)folders.count) return;
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:folders[(NSUInteger)row]]]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)FTSettings.shared.floatFolders.count; }

// A folder that has gone is still listed, greyed and marked, so it can be removed.
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSArray *folders = FTSettings.shared.floatFolders;
    if (row < 0 || row >= (NSInteger)folders.count) return nil;
    NSString *path = folders[(NSUInteger)row];
    NSTextField *label = [t makeViewWithIdentifier:@"folder" owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = @"folder";
        label.font = [NSFont systemFontOfSize:11];
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    BOOL there = [NSFileManager.defaultManager fileExistsAtPath:path];
    label.stringValue = there ? path.stringByAbbreviatingWithTildeInPath
                              : [NSString stringWithFormat:FTL(@"%@ (missing)"), path.stringByAbbreviatingWithTildeInPath];
    label.textColor = there ? NSColor.labelColor : NSColor.secondaryLabelColor;
    label.toolTip = path;
    return label;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    _floatRemoveButton.enabled = _floatFolderTable.selectedRow >= 0;
}

@end


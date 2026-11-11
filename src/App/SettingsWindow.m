#import "SettingsWindow.h"
#import "Localization.h"
#import "Settings.h"

@implementation SettingsWindow {
    NSButton *_showHiddenBox, *_gitignoreBox, *_minimapBox, *_wrapBox, *_remoteBox, *_closeBox, *_guidesBox, *_spaceBox;
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
        @[heading(FTL(@"Previews")), NSGridCell.emptyContentView],
        @[NSGridCell.emptyContentView, column(@[_remoteBox, note(FTL(@"Off: images such as README badges show their description instead, and nothing is downloaded."))])]]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    const NSInteger headings[] = {0, 2, 7, 12};
    for (int k = 0; k < 4; k++) {
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

@end

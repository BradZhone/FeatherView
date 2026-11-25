#import "FloatPanel.h"
#import "Localization.h"
#import "FileIcons.h"
#import "FileKind.h"
#import "Settings.h"
#import "HotKey.h"
#import "TextEditorView.h"
#import "PieceTable.h"
#import "MarkupView.h"
#import "ImageViewer.h"
#import "PDFViewer.h"
#import "TabBarView.h"
#import "ContentController.h"      // AutoSaveMode, shared with the main window

static const CGFloat kTreeW = 200;        // the sidebar's width inside the panel
static const CGFloat kHeaderH = 28;
static const CGFloat kTabH = 26;      // the panel's strip, a little tighter than the window's
static NSString *const kDefaultFrameName = @"FeatherFloat";

// Esc and ⌘B have to work while the tree has the keyboard, so the panel takes them before the
// responder chain: an NSOutlineView swallows Esc, and nothing in the panel is in a menu yet.
@interface FloatPanelWindow : NSPanel
@property (nonatomic, copy) void (^onEscape)(void);
@property (nonatomic, copy) void (^onToggleSidebar)(void);
@property (nonatomic, copy) void (^onSave)(void);
@property (nonatomic, copy) void (^onTogglePreview)(void);
@property (nonatomic, copy) void (^onBack)(void);
@property (nonatomic, copy) void (^onForward)(void);
@property (nonatomic, copy) void (^onCloseTab)(void);
@property (nonatomic, copy) void (^onSaveAll)(void);
@property (nonatomic, copy) void (^onNextTab)(void);
@property (nonatomic, copy) void (^onPreviousTab)(void);
@end

@implementation FloatPanelWindow
- (BOOL)canBecomeKeyWindow { return YES; }      // a utility panel would otherwise refuse the keyboard

- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 53) { if (_onEscape) _onEscape(); return; }         // 53 = Esc
    [super keyDown:e];
}

// The panel's own shortcuts. They are handled here rather than through the main menu because the
// menu's items act on the main window, and an outline view or text view would otherwise swallow
// some of these before the window saw them.
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    NSEventModifierFlags f = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *k = e.charactersIgnoringModifiers.lowercaseString;
    if (f == NSEventModifierFlagCommand) {
        if ([k isEqualToString:@"b"]) { if (_onToggleSidebar) _onToggleSidebar(); return YES; }
        if ([k isEqualToString:@"s"]) { if (_onSave) _onSave(); return YES; }
        if ([k isEqualToString:@"w"]) { if (_onCloseTab) _onCloseTab(); return YES; }
        if ([k isEqualToString:@"["]) { if (_onBack) _onBack(); return YES; }
        if ([k isEqualToString:@"]"]) { if (_onForward) _onForward(); return YES; }
    }
    if (f == (NSEventModifierFlagCommand | NSEventModifierFlagOption) && [k isEqualToString:@"s"]) {
        if (_onSaveAll) _onSaveAll();
        return YES;
    }
    if (f == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
        if ([k isEqualToString:@"v"]) { if (_onTogglePreview) _onTogglePreview(); return YES; }
        if ([k isEqualToString:@"]"]) { if (_onNextTab) _onNextTab(); return YES; }
        if ([k isEqualToString:@"["]) { if (_onPreviousTab) _onPreviousTab(); return YES; }
    }
    // ⌃⇥ between tabs, as the main window has.
    if (f == NSEventModifierFlagControl && e.keyCode == 48) { if (_onNextTab) _onNextTab(); return YES; }
    if (f == (NSEventModifierFlagControl | NSEventModifierFlagShift) && e.keyCode == 48) {
        if (_onPreviousTab) _onPreviousTab();
        return YES;
    }
    return [super performKeyEquivalent:e];
}
@end

// Flipped so subviews are laid out from the top, like the main window's sidebar.
@interface FloatBackdrop : NSView
@end
@implementation FloatBackdrop
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSIntersectionRect(dirty, self.bounds));
}
@end

// Draws the divider itself so it disappears with the sidebar. Deliberately paired with *not*
// implementing splitView:shouldHideDividerAtIndex: against live sidebar state: AppKit caches that
// answer and re-queries it inside its own drag loop, which left a black line at the stale edge.
@interface FloatSplitView : NSSplitView
@end
@implementation FloatSplitView
- (void)drawDividerInRect:(NSRect)rect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(rect);
    if (self.subviews.firstObject.hidden) return;
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(NSMidX(rect), NSMinY(rect), 1, rect.size.height));
}
@end

// One open file in the panel: its editor, the container rendering it, and the trail of links
// followed from it. Each tab keeps its own, so switching tabs doesn't reload or lose a position.
@interface FloatDoc : NSObject
@property (nonatomic, strong) TextEditorView *editor;
@property (nonatomic, strong) MarkupContainer *markup;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSMutableArray<NSString *> *back, *forward;
@property (nonatomic) NSTimeInterval lastEditAt;        // for the auto-save delay
@property (nonatomic) NSUInteger savedEditCount;        // what was last written out
@property (nonatomic, strong) NSDate *diskStamp;        // the file's time when last read or written
@property (nonatomic) NSUInteger lastSeenEditCount;    // to tell a text change from a caret move
@property (nonatomic) BOOL renderStale;                // edited since the rendered view last drew
// An image or PDF has no editor: it shows a read-only view instead of editor + container.
@property (nonatomic, strong) NSView *mediaView;
@property (nonatomic, copy) NSString *mediaInfo;       // what the media view puts in the status bar
@end

@implementation FloatDoc
- (instancetype)init {
    if ((self = [super init])) { _back = [NSMutableArray array]; _forward = [NSMutableArray array]; }
    return self;
}
@end

@implementation FloatPanel {
    FloatPanelWindow *_panel;
    // Backing store is NSUserDefaults for these, so both accessors are written by hand.
    FloatSplitView *_split;
    NSView *_sidebar, *_content;
    NSTextField *_placeholder;
    NSScrollView *_treeScroll;
    FileOutlineView *_outline;
    NSButton *_sidebarButton;
    NSPopUpButton *_folderPopup;
    NSButton *_chooseButton;
    FileTree *_tree;
    FileWatcher *_watcher;
    CGFloat _treeWidth;
    NSRunningApplication *_cameFrom;         // whoever was in front when the panel was shown
    FTHotKey *_hotKey;
    NSTextField *_status;
    NSSegmentedControl *_modeSwitch, *_historyControl;
    // The open files and which one is on show.
    NSMutableArray<FloatDoc *> *_docs;
    FloatDoc *_active;
    TabBarView *_tabBar;
    NSTimer *_autoSaveTimer;
    BOOL _shortcutRelinquished;
    NSString *_frameName;
    BOOL _restoring;      // reopening last session's tabs: open from disk, never bounce elsewhere
}

@synthesize autoSaveDelay = _autoSaveDelay;
@dynamic sidebarVisible, hidesWhenInactive;    // read from and written to NSUserDefaults / the views

- (NSPanel *)panel { return _panel; }
- (FileTree *)tree { return _tree; }
- (BOOL)visible { return _panel.isVisible; }

static NSUserDefaults *ud(void) { return NSUserDefaults.standardUserDefaults; }

- (instancetype)init { return [self initWithFrameName:kDefaultFrameName]; }

- (instancetype)initWithFrameName:(NSString *)frameName {
    if (!(self = [super init])) return nil;
    _frameName = [frameName.length ? frameName : kDefaultFrameName copy];
    _treeWidth = [ud() doubleForKey:@"floatTreeWidth"] > 0 ? [ud() doubleForKey:@"floatTreeWidth"] : kTreeW;
    [self build];
    _folder = [[ud() stringForKey:@"floatFolder"] copy];
    if (!_folder.length) _folder = [self.folders.firstObject copy];     // first run after adding one
    [self applyFolder];
    self.sidebarVisible = [ud() objectForKey:@"floatSidebarVisible"] ? [ud() boolForKey:@"floatSidebarVisible"] : YES;
    [self applyShortcut];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:)
                                               name:FTSettingsDidChange object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_watcher stop];
}

- (void)build {
    NSRect initial = NSMakeRect(0, 0, 520, 560);
    _panel = [[FloatPanelWindow alloc] initWithContentRect:initial
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
          backing:NSBackingStoreBuffered defer:NO];
    _panel.title = FTL(@"Floating Workspace");
    _panel.level = NSFloatingWindowLevel;
    _panel.minSize = NSMakeSize(260, 200);
    _panel.releasedWhenClosed = NO;             // hidden and shown again, never rebuilt
    _panel.hidesOnDeactivate = NO;              // stays up over other apps; see hidesWhenInactive
    // Gone the instant the shortcut is pressed. A utility panel's own behaviour fades it out, which
    // is a wait when the whole point is a glance.
    _panel.animationBehavior = NSWindowAnimationBehaviorNone;
    _panel.delegate = self;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    __weak FloatPanel *weakSelf = self;
    _panel.onEscape = ^{ [weakSelf hide]; };
    _panel.onToggleSidebar = ^{ [weakSelf toggleFloatSidebar:nil]; };
    _panel.onSave = ^{ [weakSelf save]; };
    _panel.onTogglePreview = ^{ [weakSelf toggleFloatPreview:nil]; };
    _panel.onBack = ^{ [weakSelf goBack]; };
    _panel.onForward = ^{ [weakSelf goForward]; };
    _panel.onCloseTab = ^{ FloatPanel *me = weakSelf; [me closeTab:me->_tabBar.selectedIndex]; };
    _panel.onSaveAll = ^{ [weakSelf saveAll]; };
    _panel.onNextTab = ^{ [weakSelf selectNextTab]; };
    _panel.onPreviousTab = ^{ [weakSelf selectPreviousTab]; };
    // Its own frame across launches, which is all the position and size persistence needed.
    if (![_panel setFrameUsingName:_frameName]) [_panel center];
    _panel.frameAutosaveName = _frameName;

    FloatBackdrop *root = [[FloatBackdrop alloc] initWithFrame:_panel.contentView.bounds];
    root.autoresizesSubviews = YES;
    _panel.contentView = root;
    NSRect b = root.bounds;

    _split = [[FloatSplitView alloc] initWithFrame:b];
    _split.vertical = YES;
    _split.dividerStyle = NSSplitViewDividerStyleThin;
    _split.delegate = self;
    _split.wantsLayer = YES;
    _split.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    _split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_split];

    _sidebar = [[FloatBackdrop alloc] initWithFrame:NSMakeRect(0, 0, _treeWidth, b.size.height)];
    _sidebar.autoresizesSubviews = YES;

    // A pull-down, like the main window's workspace header: the current folder is the title, and
    // opening it offers the others, plus adding one.
    _folderPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(4, 3, _treeWidth - 8, 22) pullsDown:YES];
    _folderPopup.bordered = NO;
    _folderPopup.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _folderPopup.autoresizingMask = NSViewWidthSizable;
    [_folderPopup.cell setArrowPosition:NSPopUpArrowAtBottom];
    [_folderPopup.cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
    _folderPopup.menu.delegate = self;
    _folderPopup.accessibilityLabel = FTL(@"Floating Workspace Folder");
    [_sidebar addSubview:_folderPopup];

    _treeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, kHeaderH, _treeWidth, b.size.height - kHeaderH)];
    _treeScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _treeScroll.hasVerticalScroller = YES;
    _treeScroll.autohidesScrollers = YES;
    _treeScroll.drawsBackground = NO;
    _outline = [[FileOutlineView alloc] initWithFrame:_treeScroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outline addTableColumn:col];
    _outline.outlineTableColumn = col;
    _outline.headerView = nil;
    _outline.style = NSTableViewStyleSourceList;
    _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _outline.rowHeight = 20;
    _treeScroll.documentView = _outline;
    [col setWidth:_treeScroll.contentSize.width];
    [_sidebar addSubview:_treeScroll];

    _content = [[FloatBackdrop alloc] initWithFrame:NSMakeRect(_treeWidth + 1, 0, b.size.width - _treeWidth - 1, b.size.height)];
    _content.autoresizesSubviews = YES;
    _placeholder = [NSTextField labelWithString:@""];
    _placeholder.textColor = NSColor.tertiaryLabelColor;
    _placeholder.alignment = NSTextAlignmentCenter;
    _placeholder.frame = NSMakeRect(0, 0, _content.bounds.size.width, _content.bounds.size.height);
    _placeholder.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_content addSubview:_placeholder];
    // With no folder yet there is nothing to click in the tree, so the way to choose one is here
    // as well as in the header's pull-down.
    _chooseButton = [NSButton buttonWithTitle:FTL(@"Choose a Folder…") target:self action:@selector(chooseFolder:)];
    [_chooseButton sizeToFit];
    _chooseButton.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [_content addSubview:_chooseButton];

    _docs = [NSMutableArray array];
    _tabBar = [[TabBarView alloc] initWithFrame:NSMakeRect(0, 0, _content.bounds.size.width, kTabH)];
    _tabBar.autoresizingMask = NSViewWidthSizable;
    __weak FloatPanel *weakTabs = self;
    _tabBar.onSelect = ^(NSInteger i) { [weakTabs selectTab:i]; };
    _tabBar.onClose = ^(NSInteger i) { [weakTabs closeTab:i]; };
    _tabBar.onMove = ^(NSInteger from, NSInteger to) { [weakTabs moveTabFrom:from to:to]; };
    _tabBar.hidden = YES;
    [_content addSubview:_tabBar];

    // One line along the bottom: the file's name, whether it is unsaved, and the caret position —
    // the same facts the main window's status bar carries, in the room a panel has.
    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:10];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_content addSubview:_status];

    [_split addSubview:_sidebar];
    [_split addSubview:_content];
    [_split adjustSubviews];

    _sidebarButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:FTL(@"Hide Sidebar")]
                                        target:self action:@selector(toggleFloatSidebar:)];
    _sidebarButton.bordered = NO;
    _sidebarButton.imagePosition = NSImageOnly;
    _sidebarButton.focusRingType = NSFocusRingTypeNone;
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 30, 24)];
    accessory.autoresizesSubviews = YES;
    _sidebarButton.frame = accessory.bounds;
    _sidebarButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [accessory addSubview:_sidebarButton];
    NSTitlebarAccessoryViewController *ac = [NSTitlebarAccessoryViewController new];
    ac.view = accessory;
    ac.layoutAttribute = NSLayoutAttributeLeft;
    [_panel addTitlebarAccessoryViewController:ac];

    // Source / rendered and the trail through followed links live in a strip at the top of the
    // content area, not in the title bar: a utility window's is 19 points tall, which no segmented
    // control fits inside — they were drawn clipped against its edges.
    _modeSwitch = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:@"doc.plaintext" accessibilityDescription:FTL(@"Source")],
        [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:FTL(@"Preview")]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeSwitchChanged:)];
    _modeSwitch.controlSize = NSControlSizeSmall;
    [_modeSwitch setToolTip:FTL(@"Source") forSegment:0];
    [_modeSwitch setToolTip:FTL(@"Preview (⇧⌘V)") forSegment:1];
    [_modeSwitch sizeToFit];
    _modeSwitch.hidden = YES;
    [_content addSubview:_modeSwitch];

    _historyControl = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:FTL(@"Back")],
        [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:FTL(@"Forward")]]
        trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(historyClicked:)];
    _historyControl.controlSize = NSControlSizeSmall;
    [_historyControl setToolTip:FTL(@"Back") forSegment:0];
    [_historyControl setToolTip:FTL(@"Forward") forSegment:1];
    [_historyControl sizeToFit];
    _historyControl.hidden = YES;
    [_content addSubview:_historyControl];

    _tree = [[FileTree alloc] initWithOutlineView:_outline];
    _tree.showHidden = FTSettings.shared.showHidden;
    __weak FloatPanel *weak = self;
    // Shown in the panel. A double click is the same thing here: there are no tabs to pin, and
    // sending it to the main window on a double click would undo the point of the panel.
    _tree.onOpen = ^(NSString *path, BOOL pinned) { [weak openFile:path]; };
    [self layoutContent];
}

- (void)settingsChanged:(NSNotification *)n {
    _tree.showHidden = FTSettings.shared.showHidden;
    [_tree reload];
    // The shortcut and the folder list can be changed in the settings window; the panel follows.
    if (![_hotKey.shortcut isEqualToString:self.shortcut]) [self applyShortcut];
    if (_folder.length && ![self.folders containsObject:_folder] && self.folders.count)
        self.folder = self.folders.firstObject;      // the current folder was removed there
    [self updateFolderTitle];
}

#pragma mark Folders

- (NSArray<NSString *> *)folders { return FTSettings.shared.floatFolders; }
- (void)setFolders:(NSArray<NSString *> *)folders { FTSettings.shared.floatFolders = folders; }

- (void)addFolder:(NSString *)path {
    NSString *p = path.stringByStandardizingPath;
    if (!p.length) return;
    NSMutableArray *list = [self.folders mutableCopy];
    [list removeObject:p];
    [list insertObject:p atIndex:0];            // most recently chosen first
    while (list.count > 10) [list removeLastObject];
    [self setFolders:list];
    self.folder = p;
}

- (void)removeFolder:(NSString *)path {
    NSString *p = path.stringByStandardizingPath;
    NSMutableArray *list = [self.folders mutableCopy];
    [list removeObject:p];
    [self setFolders:list];
    if ([p isEqualToString:_folder]) self.folder = list.firstObject;
    [self updateFolderTitle];
}

// An open panel on the panel itself, so it appears over the floating window rather than behind it.
- (void)chooseFolder:(id)sender {
    if (_folderChooser) {
        NSString *p = _folderChooser();
        if (p.length) [self addFolder:p];
        return;
    }
    // "Add Folder…" comes from the header pull-down, whose action fires while AppKit is still
    // tearing the menu's tracking down. A sheet begun inside that unwind never appears — the reader
    // sees nothing happen. Letting the menu finish first (next main-loop turn) is what shows it.
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.prompt = FTL(@"Choose");
    p.message = FTL(@"The folder the floating workspace shows");
    p.directoryURL = [NSURL fileURLWithPath:_folder ?: NSHomeDirectory()];
    __weak FloatPanel *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FloatPanel *me = weak;
        if (!me) return;
        // The panel must be in front for a sheet to attach to it; a hotkey-shown panel over
        // another app can lose that by the time this runs.
        [NSApp activateIgnoringOtherApps:YES];
        [me->_panel makeKeyAndOrderFront:nil];
        [p beginSheetModalForWindow:me->_panel completionHandler:^(NSModalResponse r) {
            if (r == NSModalResponseOK) [me addFolder:p.URL.path];
        }];
    });
}

- (void)folderPicked:(NSMenuItem *)item {
    NSString *p = item.representedObject;
    if (p.length) self.folder = p;
}

- (void)folderRemoved:(NSMenuItem *)item {
    NSString *p = item.representedObject;
    if (p.length) [self removeFolder:p];
}

// Item 0 is the pull-down's title; everything below is rebuilt each time it opens.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _folderPopup.menu) return;
    while (menu.numberOfItems > 0) [menu removeItemAtIndex:0];
    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:self.folderTitle action:NULL keyEquivalent:@""];
    title.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
    [menu addItem:title];
    for (NSString *f in self.folders) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:f.lastPathComponent action:@selector(folderPicked:) keyEquivalent:@""];
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:f.lastPathComponent
            attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:0]}];
        [t appendAttributedString:[[NSAttributedString alloc]
            initWithString:[@"   " stringByAppendingString:f.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath]
            attributes:@{NSFontAttributeName: [NSFont menuFontOfSize:11], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
        i.attributedTitle = t;
        i.target = self;
        i.representedObject = f;
        i.state = [f isEqualToString:_folder] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:i];
        // ⌥ on a folder that isn't the current one removes it from the list, as in the main window.
        if (![f isEqualToString:_folder]) {
            NSMenuItem *alt = [[NSMenuItem alloc] initWithTitle:[FTL(@"Remove from List: ") stringByAppendingString:f.lastPathComponent]
                                                         action:@selector(folderRemoved:) keyEquivalent:@""];
            alt.target = self;
            alt.representedObject = f;
            alt.alternate = YES;
            alt.keyEquivalentModifierMask = NSEventModifierFlagOption;
            [menu addItem:alt];
        }
    }
    if (self.folders.count) [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:FTL(@"Add Folder…") action:@selector(chooseFolder:) keyEquivalent:@""];
    add.target = self;
    [menu addItem:add];
    if (_folder.length) {
        NSMenuItem *reveal = [[NSMenuItem alloc] initWithTitle:FTL(@"Show in Finder") action:@selector(revealFolder:) keyEquivalent:@""];
        reveal.target = self;
        [menu addItem:reveal];
    }
}

- (void)revealFolder:(id)sender {
    if (_folder.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:_folder]]];
}

#pragma mark Showing a file in the panel

- (NSString *)openPath { return _active.path; }
- (BOOL)dirty { for (FloatDoc *d in _docs) if (d.editor.isDirty) return YES; return NO; }
- (NSUInteger)tabCount { return _docs.count; }
- (NSArray<NSString *> *)openPaths {
    NSMutableArray *out = [NSMutableArray array];
    for (FloatDoc *d in _docs) if (d.path) [out addObject:d.path];
    return out;
}

- (FloatDoc *)docForPath:(NSString *)path {
    NSString *p = path.stringByStandardizingPath;
    for (FloatDoc *d in _docs) if ([d.path.stringByStandardizingPath isEqualToString:p]) return d;
    return nil;
}

// Text, the markup kinds, and read-only images and PDFs are shown here. Anything else — a video, a
// spreadsheet, an archive — needs a viewer the panel doesn't carry and goes to the main window.
- (BOOL)canShowInPanel:(NSString *)path {
    if (FKMarkupKind(path) != MarkupNone) return YES;
    ViewerKind k = FKGuessKind(path);
    return k == ViewerText || k == ViewerImage || k == ViewerPDF;
}

- (BOOL)canShow:(NSString *)path { return path.length && [self canShowInPanel:path]; }

// A file the panel can't show goes to the main window — unless this is the launch-time restore,
// which opens only what the panel shows itself and quietly skips the rest.
- (void)bounceElsewhere:(NSString *)path {
    if (_restoring) return;
    if (self.onOpenElsewhere) self.onOpenElsewhere(path);
}

- (void)openFile:(NSString *)path {
    if (!path.length) return;
    // The main window's unsaved copy is the current one; showing the file from disk here would
    // present older text as if it were the file, and saving over it would lose their edits. On the
    // launch-time restore there is nothing open in the main window yet, so this is skipped.
    if (!_restoring && self.hasUnsavedEditsElsewhere && self.hasUnsavedEditsElsewhere(path)) {
        [self flash:FTL(@"Open with unsaved changes in the main window; opened there instead")];
        [self bounceElsewhere:path];
        return;
    }
    if (![self canShowInPanel:path]) {
        [self bounceElsewhere:path];
        return;
    }
    // Already open: show that tab rather than a second copy of the same file.
    FloatDoc *existing = [self docForPath:path];
    if (existing) { [self activateDoc:existing]; return; }
    FloatDoc *d = [self buildDocFor:path];
    if (!d) {
        // It passed canShowInPanel: but couldn't be built — an image or PDF that won't decode, or a
        // locked PDF. The text path already handed those to the main window; this covers the media
        // ones, so the click isn't silently dropped.
        if (FKGuessKind(path) == ViewerImage || FKGuessKind(path) == ViewerPDF)
            [self bounceElsewhere:path];
        return;
    }
    [_docs addObject:d];
    [self activateDoc:d];
    [self reloadTabs];
}

// A new tab's editor and rendered view. nil when the file turns out not to be text after all.
- (FloatDoc *)buildDocFor:(NSString *)path {
    // Images and PDFs are read-only, so they skip the editor and get a plain viewer.
    ViewerKind k = FKMarkupKind(path) == MarkupNone ? FKGuessKind(path) : ViewerText;
    if (k == ViewerImage || k == ViewerPDF) return [self buildMediaDocFor:path kind:k];

    NSStringEncoding enc = NSUTF8StringEncoding;
    NSString *err = nil;
    NSData *data = FKLoadTextAllowingNUL(path, &enc, NO, &err);
    if (!data) {
        [self bounceElsewhere:path];
        return nil;
    }
    FloatDoc *d = [FloatDoc new];
    d.path = path;
    d.editor = [[TextEditorView alloc] initWithFrame:_content.bounds
                                              buffer:[[PieceTable alloc] initWithData:data]
                                                path:path encoding:enc];
    d.editor.wordWrap = FTSettings.shared.wordWrap;
    d.editor.showsMinimap = NO;                 // no room for one in a panel this size
    d.savedEditCount = d.editor.editCount;
    d.lastSeenEditCount = d.editor.editCount;
    d.diskStamp = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    __weak FloatPanel *weak = self;
    __weak FloatDoc *weakDoc = d;
    d.editor.onChange = ^{ [weak docChanged:weakDoc]; };
    d.markup = [[MarkupContainer alloc] initWithEditor:d.editor kind:FKMarkupKind(path) path:path root:_folder];
    d.markup.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    d.markup.onOpenFile = ^(NSString *p, NSString *anchor) { [weak followLink:p anchor:anchor]; };
    d.markup.onMessage = ^(NSString *m) { [weak flash:m]; };
    return d;
}

// A read-only media tab: an image or PDF viewer, the same ones the main window uses, with no
// editor and no preview switch. nil if the file can't be decoded, so the main window still gets it.
- (FloatDoc *)buildMediaDocFor:(NSString *)path kind:(ViewerKind)kind {
    NSView *view = nil;
    NSString *info = nil;
    if (kind == ViewerImage) {
        ImagePreviewView *iv = [[ImagePreviewView alloc] initWithFrame:_content.bounds path:path];
        __block BOOL failed = NO;
        iv.onFailure = ^{ failed = YES; };
        iv.onChange = ^{};
        // onFailure fires synchronously from init when the bytes aren't a decodable image.
        if (failed) return nil;
        view = iv;
        info = iv.info;
    } else {
        PDFPreview *pv = [[PDFPreview alloc] initWithFrame:_content.bounds path:path];
        if (!pv || pv.isLocked) return nil;    // unreadable, or password-protected: the main window has the prompt
        view = pv;
        info = pv.info;
    }
    FloatDoc *d = [FloatDoc new];
    d.path = path;
    d.mediaView = view;
    d.mediaView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    d.mediaInfo = info;
    d.diskStamp = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    __weak FloatPanel *weak = self;
    __weak FloatDoc *weakDoc = d;
    if ([view isKindOfClass:ImagePreviewView.class]) {
        __weak ImagePreviewView *weakIv = (ImagePreviewView *)view;
        ((ImagePreviewView *)view).onChange = ^{
            FloatPanel *me = weak;
            if (!me) return;
            weakDoc.mediaInfo = weakIv.info;
            if (weakDoc == me->_active) [me docChanged:weakDoc];
        };
    }
    return d;
}

- (void)activateDoc:(FloatDoc *)d {
    if (!d) return;
    // Leaving a tab is a focus change, which both auto-save modes write out on.
    if (_active != d && _active.editor.isDirty && self.autoSaveMode != AutoSaveOff) [self autoSaveDoc:_active];
    if (_active != d) {
        [_active.markup removeFromSuperview];
        [_active.mediaView removeFromSuperview];
        // A tab that is no longer on show gives up its rendered view, as the main window's do; its
        // editor and undo history stay, so switching back is where it left off.
        [_active.markup releasePreview];
    }
    _active = d;
    NSView *view = d.mediaView ?: d.markup;
    if (view.superview != _content) [_content addSubview:view];
    [d.markup ensurePreview];
    [self applyMode];
    [self layoutContent];
    [self docChanged:d];
    [self syncHistory];
    [self reloadTabs];
    if (_tree.rootPath && d.path) [_tree revealPath:d.path];
    if (_panel.isVisible) [_panel makeFirstResponder:d.mediaView ?: d.markup.focusView];
}

// Switching a tab's file in place, for a followed link: the same views are reused, so nothing
// flashes. NO when the file isn't text, or the kind differs and the container can't take it.
- (BOOL)swapDoc:(FloatDoc *)d toPath:(NSString *)path {
    if (!d.editor || FKMarkupKind(path) != d.markup.kind) return NO;   // media has no editor to reuse
    NSStringEncoding enc = NSUTF8StringEncoding;
    NSString *err = nil;
    NSData *data = FKLoadTextAllowingNUL(path, &enc, NO, &err);
    if (!data) return NO;
    if (![d.editor loadData:data path:path encoding:enc]) return NO;      // refuses while dirty
    d.path = path;
    d.savedEditCount = d.editor.editCount;
    d.lastSeenEditCount = d.editor.editCount;
    d.renderStale = NO;
    d.diskStamp = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
    d.markup.path = path;
    [d.markup refreshNow];
    [self applyMode];
    [self docChanged:d];
    [self reloadTabs];
    if (_tree.rootPath) [_tree revealPath:path];
    return YES;
}

#pragma mark Tabs

- (void)reloadTabs {
    NSMutableArray<TabItem *> *items = [NSMutableArray array];
    for (FloatDoc *d in _docs) {
        TabItem *t = [TabItem new];
        t.title = d.path.lastPathComponent ?: @"";
        t.dirty = d.editor.isDirty;
        t.toolTip = d.path.stringByAbbreviatingWithTildeInPath;
        t.missing = d.path.length && ![NSFileManager.defaultManager fileExistsAtPath:d.path];
        [items addObject:t];
    }
    _tabBar.items = items;
    _tabBar.selectedIndex = _active ? (NSInteger)[_docs indexOfObject:_active] : -1;
    [_tabBar reload];
    _tabBar.hidden = _docs.count == 0;
    [self layoutContent];
    [self persistTabs];
}

// The open files and which one is on show, kept so closing the panel (or quitting) and coming back
// restores them rather than leaving the reader to pick each one out of the tree again. Not written
// while reopening them, so a half-restored list never overwrites the saved one.
- (void)persistTabs {
    if (_restoring) return;
    [ud() setObject:self.openPaths forKey:@"floatOpenTabs"];
    [ud() setInteger:_active ? (NSInteger)[_docs indexOfObject:_active] : -1 forKey:@"floatActiveTab"];
}

- (void)restoreTabs {
    NSArray<NSString *> *paths = [ud() stringArrayForKey:@"floatOpenTabs"];
    if (!paths.count) return;
    NSInteger active = [ud() objectForKey:@"floatActiveTab"] ? [ud() integerForKey:@"floatActiveTab"] : -1;
    NSString *activePath = (active >= 0 && active < (NSInteger)paths.count) ? paths[(NSUInteger)active] : nil;
    _restoring = YES;
    for (NSString *p in paths)
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) [self openFile:p];
    _restoring = NO;
    // Land on the tab that was active last, if it is still among those that opened.
    FloatDoc *d = activePath ? [self docForPath:activePath] : nil;
    if (d) [self activateDoc:d];      // reloadTabs within writes the pruned list back out
    else [self persistTabs];          // some files were gone: save what actually opened
}

- (void)selectTab:(NSInteger)i {
    if (i >= 0 && i < (NSInteger)_docs.count) [self activateDoc:_docs[(NSUInteger)i]];
}

// Closing asks only about this tab's own unsaved work, and only when auto-save is off: with it on
// the file is already written out.
- (void)closeTab:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)_docs.count) return;
    FloatDoc *d = _docs[(NSUInteger)i];
    if (d.editor.isDirty && ![self confirmUnsavedDoc:d]) return;
    [d.markup removeFromSuperview];
    [d.mediaView removeFromSuperview];
    [_docs removeObjectAtIndex:(NSUInteger)i];
    if (_active == d) {
        _active = nil;
        FloatDoc *next = _docs.count ? _docs[MIN((NSUInteger)i, _docs.count - 1)] : nil;
        if (next) [self activateDoc:next];
        else { [self applyMode]; [self docChanged:nil]; [self syncHistory]; }
    }
    [self reloadTabs];
}

- (void)selectNextTab {
    if (_docs.count < 2) return;
    NSUInteger i = [_docs indexOfObject:_active];
    [self activateDoc:_docs[(i + 1) % _docs.count]];
}

- (void)selectPreviousTab {
    if (_docs.count < 2) return;
    NSUInteger i = [_docs indexOfObject:_active];
    [self activateDoc:_docs[(i + _docs.count - 1) % _docs.count]];
}

- (void)moveTabFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || from >= (NSInteger)_docs.count) return;
    FloatDoc *d = _docs[(NSUInteger)from];
    [_docs removeObjectAtIndex:(NSUInteger)from];
    [_docs insertObject:d atIndex:MIN((NSUInteger)to, _docs.count)];
    [self reloadTabs];
}

// Source or rendered. A kind with no source worth editing (a table, a notebook) still gets both,
// as in the main window; what the panel never does is show them side by side.
- (void)applyMode {
    _modeSwitch.selectedSegment = self.showsPreview ? 1 : 0;
    // No source/preview switch for an image or PDF, or for a kind with nothing to render.
    _modeSwitch.hidden = _active == nil || _active.mediaView != nil || _active.markup.kind == MarkupNone;
    if (!_active.markup) return;
    BOOL preview = self.showsPreview && _active.markup.kind != MarkupNone;
    _active.markup.markupLayout = preview ? MarkupPreview : MarkupSource;
    // A preview that already exists is not re-rendered by the layout switch — only a freshly built
    // one is. Edits made in the source view would otherwise appear only after leaving the file and
    // coming back, which is when the container is rebuilt.
    if (preview && _active.renderStale) {
        [_active.markup refreshNow];
        _active.renderStale = NO;
    }
    [self layoutContent];
}

- (BOOL)showsPreview {
    NSNumber *v = [ud() objectForKey:@"floatShowsPreview"];
    return v ? v.boolValue : YES;              // reading is what the panel is for
}

- (void)setShowsPreview:(BOOL)on {
    [ud() setBool:on forKey:@"floatShowsPreview"];
    [self applyMode];
}

- (void)toggleFloatPreview:(id)sender { self.showsPreview = !self.showsPreview; }
- (void)modeSwitchChanged:(NSSegmentedControl *)c { self.showsPreview = c.selectedSegment == 1; }

- (void)docChanged:(FloatDoc *)d {
    if (d && d == _active && d.mediaView) {
        _status.stringValue = [NSString stringWithFormat:@"%@   %@", d.path.lastPathComponent ?: @"", d.mediaInfo ?: @""];
    } else if (d && d == _active) {
        _status.stringValue = [NSString stringWithFormat:@"%@%@   %@", d.editor.isDirty ? @"● " : @"",
                               d.path.lastPathComponent ?: @"", d.editor.statusText];
    } else if (!_active) {
        _status.stringValue = @"";
    }
    _panel.documentEdited = self.dirty;
    _placeholder.hidden = _active != nil;
    if (d && d.editor && d.editor.editCount != d.lastSeenEditCount) {
        d.lastSeenEditCount = d.editor.editCount;
        d.lastEditAt = NSProcessInfo.processInfo.systemUptime;        // the text changed, not the caret
        d.renderStale = YES;
        // Without this the rendered view never hears about an edit, so turning the preview on
        // showed the text as it was when the file was opened.
        [d.markup textChanged];
        [self scheduleAutoSave];
    }
    if (d && d.editor && d.editor.editCount != d.savedEditCount) [self scheduleAutoSave];
    // A tab's dirty dot lives in the strip, so the strip is redrawn on every change.
    if (d && d.editor) {
        NSUInteger i = [_docs indexOfObject:d];
        if (i != NSNotFound && i < _tabBar.items.count && _tabBar.items[i].dirty != d.editor.isDirty) [self reloadTabs];
    }
    [self updateFolderTitle];
}

// A temporary line; the file's own status comes back on the next change.
- (void)flash:(NSString *)message {
    if (!message.length) return;
    _status.stringValue = [@"⚠️ " stringByAppendingString:message];
    NSString *shown = _status.stringValue;
    __weak FloatPanel *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FloatPanel *me = weak;
        if (me && [me->_status.stringValue isEqualToString:shown]) [me docChanged:me->_active];
    });
}

// Hiding the panel leaves its unsaved file alone — it is still there on the next ⇧⌘E, exactly as
// the main window keeps a dirty tab. Quitting is where the reader has to decide, which is what
// this answers for.
- (BOOL)confirmUnsavedBeforeClosing {
    for (FloatDoc *d in _docs.copy) if (d.editor.isDirty && ![self confirmUnsavedDoc:d]) return NO;
    return YES;
}

- (BOOL)confirmUnsavedDoc:(FloatDoc *)doc {
    if (!doc.editor.isDirty) return YES;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:FTL(@"Save “%@” in the floating workspace?"),
                     doc.path.lastPathComponent ?: @""];
    a.informativeText = FTL(@"Its changes are lost if you don’t save them.");
    [a addButtonWithTitle:FTL(@"Save")];
    [a addButtonWithTitle:FTL(@"Discard")];
    [a addButtonWithTitle:FTL(@"Cancel")];
    NSModalResponse r = _alertHandler ? _alertHandler(a) : [a runModal];
    if (r == NSAlertFirstButtonReturn) return [self saveDoc:doc announce:YES];
    return r == NSAlertSecondButtonReturn;        // discard: let it go; cancel: stop
}

- (BOOL)save { return [self saveDoc:_active announce:YES]; }

- (BOOL)saveDoc:(FloatDoc *)d announce:(BOOL)announce {
    if (!d.editor.isDirty) return YES;
    NSString *err = nil;
    if (![d.editor save:&err]) {
        if (announce) [self flash:[NSString stringWithFormat:FTL(@"Couldn’t save: %@"), err ?: FTL(@"Unknown error")]];
        return NO;
    }
    d.savedEditCount = d.editor.editCount;
    d.diskStamp = [NSFileManager.defaultManager attributesOfItemAtPath:d.path error:nil][NSFileModificationDate];
    [self docChanged:d];
    [self reloadTabs];
    // The main window keeps the file's modification time to refuse overwriting a file changed
    // behind its back. Saving here is exactly that, so it is told to look again.
    if (self.onSaved) self.onSaved(d.path);
    return YES;
}

- (BOOL)saveAll {
    BOOL ok = YES;
    for (FloatDoc *d in _docs.copy) if (![self saveDoc:d announce:YES]) ok = NO;
    return ok;
}

#pragma mark Auto-save

// The same three modes as the main window, and the same setting: off, a pause in typing, or on
// losing focus. A file the panel never wrote to is left alone, as is one changed on disk behind
// the panel's back — overwriting that silently is what nobody wants.
- (AutoSaveMode)autoSaveMode { return (AutoSaveMode)FTSettings.shared.autoSaveMode; }

- (void)scheduleAutoSave {
    if (self.autoSaveMode != AutoSaveAfterDelay) return;
    [_autoSaveTimer invalidate];
    NSTimeInterval delay = MAX(0.2, _autoSaveDelay > 0 ? _autoSaveDelay : 1.0);
    __weak FloatPanel *weak = self;
    _autoSaveTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        [weak autoSaveIdleDocs];
    }];
}

- (void)autoSaveIdleDocs {
    if (self.autoSaveMode != AutoSaveAfterDelay) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSTimeInterval delay = MAX(0.2, _autoSaveDelay > 0 ? _autoSaveDelay : 1.0);
    BOOL more = NO;
    for (FloatDoc *d in _docs.copy) {
        if (!d.editor.isDirty) continue;
        if (now - d.lastEditAt < delay - 0.01) { more = YES; continue; }   // still typing
        [self autoSaveDoc:d];
    }
    if (more) [self scheduleAutoSave];
}

// Silent: a problem goes to the status line and the file stays unsaved, as in the main window.
// Never prompts, so nothing blocks while the reader is typing in another app.
- (void)autoSaveDoc:(FloatDoc *)d {
    if (!d.editor.isDirty || !d.path.length) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:d.path]) {
        [self flash:FTL(@"The file was deleted; not auto-saved (⌘S recreates it)")];
        return;
    }
    if ([self diskChangedFor:d]) {
        [self flash:FTL(@"The file changed on disk; not auto-saved (⌘S to decide whether to overwrite)")];
        return;
    }
    [self saveDoc:d announce:NO];
}

// The file on disk is no longer what this tab last read or wrote.
- (BOOL)diskChangedFor:(FloatDoc *)d {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:d.path error:nil];
    if (!attrs) return NO;
    NSDate *mt = attrs[NSFileModificationDate];
    if (!d.diskStamp) { d.diskStamp = mt; return NO; }
    return mt && [mt compare:d.diskStamp] == NSOrderedDescending;
}

// Switching tabs, windows or apps is a focus change: both auto-save modes write out then.
- (void)flushAutoSave {
    if (self.autoSaveMode == AutoSaveOff) return;
    [_autoSaveTimer invalidate];
    _autoSaveTimer = nil;
    for (FloatDoc *d in _docs.copy) [self autoSaveDoc:d];
}

#pragma mark Links and the trail through them

// A link is followed inside the tab it was clicked in, so a chain of links leaves one tab behind
// rather than one per hop. A tab holding unsaved work keeps it: the link gets its own tab, since
// loading over a dirty editor is refused.
- (void)followLink:(NSString *)path anchor:(NSString *)anchor {
    if (!path.length) return;
    if (![self canShowInPanel:path]) {
        [self bounceElsewhere:path];
        return;
    }
    if ([self docForPath:path]) { [self openFile:path]; return; }      // already open: go there
    FloatDoc *d = _active;
    NSString *from = d.path;
    if (!d || d.editor.isDirty || ![self swapDoc:d toPath:path]) {
        [self openFile:path];
        return;
    }
    if (from.length) {
        [d.back addObject:from];
        if (d.back.count > 50) [d.back removeObjectAtIndex:0];
    }
    [d.forward removeAllObjects];
    if (anchor.length) [d.markup.markdownView scrollToAnchor:anchor];
    [self syncHistory];
}

- (BOOL)canGoBack { return _active.back.count > 0; }
- (BOOL)canGoForward { return _active.forward.count > 0; }

- (void)goBack {
    FloatDoc *d = _active;
    if (!d.back.count) return;
    NSString *to = d.back.lastObject, *from = d.path;
    [d.back removeLastObject];
    if (![self swapDoc:d toPath:to]) { [d.back addObject:to]; return; }
    if (from.length) [d.forward addObject:from];
    [self syncHistory];
}

- (void)goForward {
    FloatDoc *d = _active;
    if (!d.forward.count) return;
    NSString *to = d.forward.lastObject, *from = d.path;
    [d.forward removeLastObject];
    if (![self swapDoc:d toPath:to]) { [d.forward addObject:to]; return; }
    if (from.length) [d.back addObject:from];
    [self syncHistory];
}

- (void)historyClicked:(NSSegmentedControl *)c {
    if (c.selectedSegment == 0) [self goBack]; else [self goForward];
}

- (void)syncHistory {
    BOOL any = self.canGoBack || self.canGoForward;
    _historyControl.hidden = !any;
    [_historyControl setEnabled:self.canGoBack forSegment:0];
    [_historyControl setEnabled:self.canGoForward forSegment:1];
    [self layoutContent];
}

- (NSString *)folderTitle {
    if (!_folder.length) return FTL(@"Choose a Folder");
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:_folder isDirectory:&dir] || !dir)
        return [NSString stringWithFormat:FTL(@"%@ (missing)"), _folder.lastPathComponent];
    return _folder.lastPathComponent;
}

- (void)updateFolderTitle {
    NSMenu *m = _folderPopup.menu;
    if (!m.numberOfItems) [self menuNeedsUpdate:m];
    else m.itemArray.firstObject.title = self.folderTitle;
    _folderPopup.toolTip = _folder.stringByAbbreviatingWithTildeInPath;
    [_folderPopup setNeedsDisplay:YES];

    // What the right-hand side says depends on whether there is a folder at all.
    BOOL haveFolder = _tree.rootPath != nil;
    _chooseButton.hidden = haveFolder;
    _placeholder.stringValue = haveFolder ? FTL(@"Choose a file in the list")
                             : _folder.length ? FTL(@"That folder is no longer there") : @"";
    if (!haveFolder) {
        NSRect c = _content.bounds;
        _chooseButton.frame = NSMakeRect(floor((c.size.width - _chooseButton.frame.size.width) / 2),
                                         floor(c.size.height / 2) - 14,
                                         _chooseButton.frame.size.width, _chooseButton.frame.size.height);
    }
}

- (void)setFolder:(NSString *)folder {
    NSString *p = folder.length ? folder.stringByStandardizingPath : nil;
    if ((!p && !_folder) || (p && [p isEqualToString:_folder])) return;
    _folder = [p copy];
    if (p) [ud() setObject:p forKey:@"floatFolder"]; else [ud() removeObjectForKey:@"floatFolder"];
    [self applyFolder];
}

- (void)applyFolder {
    [_watcher stop];
    _watcher = nil;
    BOOL dir = NO;
    BOOL ok = _folder.length && [NSFileManager.defaultManager fileExistsAtPath:_folder isDirectory:&dir] && dir;
    _tree.rootPath = ok ? _folder : nil;
    [self updateFolderTitle];
    if (!ok) return;
    // Its own watcher on its own root: the main window's covers a different folder, and the two
    // never see each other's changes.
    __weak FloatPanel *weak = self;
    _watcher = [[FileWatcher alloc] initWithRoot:_folder onChange:^{
        FloatPanel *me = weak;
        [me->_tree refreshInBackground];
    }];
}

#pragma mark Showing

- (void)show {
    // Who to give the keyboard back to. Taken before activating: from then on the frontmost app is
    // this one, and hiding the panel would otherwise leave the reader in FeatherView, not in the
    // app they came from.
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && ![front isEqual:NSRunningApplication.currentApplication]) _cameFrom = front;

    [_panel setFrameUsingName:_frameName];
    // The panel can only take real key presses while this app is the active one, so showing it
    // activates. Ordering it in regardless puts it over the frontmost app's windows.
    [NSApp activateIgnoringOtherApps:YES];
    [_panel makeKeyAndOrderFront:nil];
    [_panel orderFrontRegardless];
    if (_tree.rootPath) [_tree refreshInBackground];
    if (self.sidebarVisible) [_panel makeFirstResponder:_outline];
}

- (void)hide {
    [self flushAutoSave];               // going away counts as a focus change
    [_panel saveFrameUsingName:_frameName];
    [_panel orderOut:nil];
    // Back to the app the reader came from. Without this, hiding the panel leaves FeatherView
    // active and its main window in front — they asked for a glance, not a switch.
    NSRunningApplication *back = _cameFrom;
    _cameFrom = nil;
    if (back && !back.terminated) [back activateWithOptions:0];
}

- (void)toggle { if (_panel.isVisible) [self hide]; else [self show]; }

// Closing is hiding: the panel is kept so its tree, folder and expansion survive.
- (BOOL)windowShouldClose:(NSWindow *)w {
    [self hide];
    return NO;
}

- (void)windowDidResignKey:(NSNotification *)n {
    [self flushAutoSave];               // switching away from the panel, as in the main window
    if (self.hidesWhenInactive && _panel.isVisible) [self hide];
}

- (void)windowDidResize:(NSNotification *)n {
    if (!_sidebar.hidden) _treeWidth = _sidebar.frame.size.width;
    [self layoutContent];
}

// Top to bottom on the right: the tab strip with the mode and history controls at its right end,
// the file's view, and one status line. The controls sit here rather than in the title bar, which
// is 19 points tall in a utility window and clipped them.
- (void)layoutContent {
    NSRect c = _content.bounds;
    CGFloat statusH = 16;
    CGFloat tabH = _tabBar.hidden ? 0 : kTabH;

    CGFloat right = c.size.width - 6;
    if (!_modeSwitch.hidden) {
        NSSize s = _modeSwitch.frame.size;
        _modeSwitch.frame = NSMakeRect(right - s.width, floor((tabH - s.height) / 2), s.width, s.height);
        right = NSMinX(_modeSwitch.frame) - 6;
    }
    if (!_historyControl.hidden) {
        NSSize s = _historyControl.frame.size;
        _historyControl.frame = NSMakeRect(right - s.width, floor((tabH - s.height) / 2), s.width, s.height);
        right = NSMinX(_historyControl.frame) - 6;
    }
    // The strip gets what the controls leave; a very narrow panel gives the controls up rather
    // than squeezing the tabs to nothing.
    CGFloat stripW = MAX(0, right);
    if (stripW < 80 && !_modeSwitch.hidden) { _modeSwitch.hidden = YES; _historyControl.hidden = YES; stripW = c.size.width; }
    _tabBar.frame = NSMakeRect(0, 0, stripW, tabH);

    _status.frame = NSMakeRect(8, c.size.height - statusH, MAX(0, c.size.width - 16), statusH - 2);
    _status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    NSRect body = NSMakeRect(0, tabH, c.size.width, MAX(0, c.size.height - tabH - statusH));
    _active.markup.frame = body;
    _active.mediaView.frame = body;
    _placeholder.frame = body;
    if (!_chooseButton.hidden)
        _chooseButton.frame = NSMakeRect(floor((c.size.width - _chooseButton.frame.size.width) / 2),
                                         floor(NSMidY(body)) - 14,
                                         _chooseButton.frame.size.width, _chooseButton.frame.size.height);
}

#pragma mark Sidebar

- (void)setSidebarVisible:(BOOL)visible {
    if (visible && _sidebar.hidden) {
        _sidebar.hidden = NO;
        [_split setPosition:_treeWidth ofDividerAtIndex:0];
    } else if (!visible && !_sidebar.hidden) {
        _treeWidth = MAX(120, _sidebar.frame.size.width);
        // Collapsing, not just hiding: this sets hidden and isSubviewCollapsed: and gives the
        // content the whole width. The sidebar's own frame keeps its old width, which is how AppKit
        // represents a collapsed subview — nothing is drawn from it.
        [_split setPosition:0 ofDividerAtIndex:0];
    }
    [_split adjustSubviews];
    [_split setNeedsDisplay:YES];
    _sidebarButton.image = [NSImage imageWithSystemSymbolName:@"sidebar.left"
                                     accessibilityDescription:visible ? FTL(@"Hide Sidebar") : FTL(@"Show Sidebar")];
    [ud() setBool:visible forKey:@"floatSidebarVisible"];
    if (!visible && _panel.firstResponder == _outline) [_panel makeFirstResponder:_panel.contentView];
}

- (BOOL)sidebarVisible { return !_sidebar.hidden; }

- (void)toggleFloatSidebar:(id)sender { self.sidebarVisible = _sidebar.hidden; }

#pragma mark Hiding when inactive

- (BOOL)hidesWhenInactive { return FTSettings.shared.floatHidesWhenInactive; }
- (void)setHidesWhenInactive:(BOOL)v { FTSettings.shared.floatHidesWhenInactive = v; }

#pragma mark The global shortcut

// ⇧⌘E. Not ⌘-only: those are the app's own menu shortcuts, and a global one is taken from every
// other app as well, so it needs to be something nothing common uses.
+ (NSString *)defaultShortcut { return @"⇧⌘E"; }

- (NSString *)shortcut { return FTSettings.shared.floatShortcut; }

- (void)setShortcut:(NSString *)shortcut {
    FTSettings.shared.floatShortcut = shortcut;
    [self applyShortcut];
}

- (void)relinquishShortcut {
    _shortcutRelinquished = YES;
    _hotKey.shortcut = @"";
    _hotKey = nil;
}

- (void)applyShortcut {
    if (_shortcutRelinquished) return;
    if (!_hotKey) {
        __weak FloatPanel *weak = self;
        _hotKey = [[FTHotKey alloc] initWithHandler:^{ [weak toggle]; }];
    }
    _hotKey.shortcut = self.shortcut;
}

- (BOOL)shortcutRegistered { return _hotKey.registered; }
- (NSString *)shortcutProblem { return _hotKey.problem; }

#pragma mark Split view

- (BOOL)splitView:(NSSplitView *)sv canCollapseSubview:(NSView *)v { return v == _sidebar; }
// Resizing the panel widens the content, not the tree, as in the main window.
- (BOOL)splitView:(NSSplitView *)sv shouldAdjustSizeOfSubview:(NSView *)v { return v != sv.subviews.firstObject; }
- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i { return 120; }
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i {
    return MAX(120, sv.bounds.size.width - 140);
}

- (void)splitViewDidResizeSubviews:(NSNotification *)n {
    if (_sidebar.hidden) return;
    CGFloat w = _sidebar.frame.size.width;
    if (w > 0) { _treeWidth = w; [ud() setDouble:w forKey:@"floatTreeWidth"]; }
}

@end

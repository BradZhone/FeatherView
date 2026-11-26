// The floating workspace: its own folder and file tree, shown and hidden by one shortcut, with its
// position, size, folder and collapsed sidebar kept across launches.
#import <Cocoa/Cocoa.h>
#import "FloatPanel.h"
#import "AppDelegate.h"
#import "Settings.h"
#import "HotKey.h"
#import "MarkupView.h"
#import "TextEditorView.h"
#import "TabBarView.h"
#import "ImageViewer.h"
#import "PDFViewer.h"
#import <Quartz/Quartz.h>
#import "ContentController.h"
#import "SettingsWindow.h"
#import "ShortcutField.h"

// The tree's own action methods are internal to the panel; the test drives them directly.
@interface FloatPanel (TreeOpsTesting)
- (void)floatNewFile:(id)sender;
- (void)floatNewFolder:(id)sender;
- (void)renameItem:(id)sender;
- (void)trashItem:(id)sender;
@end

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static void spin(double seconds) {
    CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + seconds;
    while (CFAbsoluteTimeGetCurrent() < until)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static NSString *makeFolder(NSString *name, NSArray<NSString *> *files) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@-%@", name, NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *f in files)
        [[NSString stringWithFormat:@"# %@\n", f] writeToFile:[dir stringByAppendingPathComponent:f]
                                                   atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return dir;
}

// A global shortcut is held by whoever registered it first, and these tests build many panels where
// the app builds one. Each is kept so its claim can be given up before the shortcut is tested.
static NSMutableArray<FloatPanel *> *gPanels;

static NSUInteger gPanelSeq;

static FloatPanel *newPanel(void) {
    // Its own frame name: AppKit writes that setting whenever a window carrying it moves, and these
    // tests keep several panels alive where the app has one, so a shared name has them overwriting
    // each other's saved frame (one gets cascaded off screen and that is what the next reads).
    FloatPanel *fp = [[FloatPanel alloc] initWithFrameName:
                      [NSString stringWithFormat:@"FeatherFloatTest%lu", (unsigned long)++gPanelSeq]];
    if (!gPanels) gPanels = [NSMutableArray array];
    [gPanels addObject:fp];
    return fp;
}

// The two panels of the persistence test share one name on purpose: they stand for two launches.
static FloatPanel *panelSharingFrameName(NSString *name) {
    FloatPanel *fp = [[FloatPanel alloc] initWithFrameName:name];
    if (!gPanels) gPanels = [NSMutableArray array];
    [gPanels addObject:fp];
    return fp;
}

// Every panel follows the shared shortcut setting and re-registers when it changes, so several
// live ones race for the combination. The app has exactly one panel; these tests have built many,
// and the only way to take a panel out of the running for good is to let it go. Its FTHotKey
// unregisters in -dealloc and its settings observer goes with it.
static void releaseEarlierShortcuts(void) {
    for (FloatPanel *fp in gPanels) { [fp hide]; [fp relinquishShortcut]; fp.panel.frameAutosaveName = @""; }
    [gPanels removeAllObjects];
}

static NSOutlineView *outlineOf(FloatPanel *fp) {
    NSMutableArray<NSView *> *stack = [@[fp.panel.contentView] mutableCopy];
    while (stack.count) {
        NSView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:NSOutlineView.class]) return (NSOutlineView *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static id findView(FloatPanel *fp, Class cls) {
    NSMutableArray<NSView *> *stack = [@[fp.panel.contentView] mutableCopy];
    while (stack.count) {
        NSView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:cls]) return v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

// NSMenu's -update does not call menuNeedsUpdate: — only a real open, or the delegate directly.
static void openMenu(NSMenu *menu) {
    if ([menu.delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [menu.delegate menuNeedsUpdate:menu];
}

static NSPopUpButton *folderPopupOf(FloatPanel *fp) { return findView(fp, NSPopUpButton.class); }

static NSButton *chooseButtonOf(FloatPanel *fp) {
    NSMutableArray<NSView *> *stack = [@[fp.panel.contentView] mutableCopy];
    while (stack.count) {
        NSView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:NSButton.class] && ((NSButton *)v).action == @selector(chooseFolder:)) return (NSButton *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static NSSplitView *splitOf(FloatPanel *fp) {
    for (NSView *v in ((NSView *)fp.panel.contentView).subviews)
        if ([v isKindOfClass:NSSplitView.class]) return (NSSplitView *)v;
    return nil;
}

// Is a vertical line drawn at x? Decided within one snapshot: the column at x against the column a
// few points to its right. An absolute colour would not do — windowBackgroundColor and
// separatorColor are dynamic and resolve in the appearance of whoever asks, not the one drawn here.
static BOOL columnDiffersFromNeighbour(NSView *v, CGFloat x) {
    NSRect r = NSMakeRect(MAX(0, x - 1), 0, 8, 40);
    NSBitmapImageRep *shot = [v bitmapImageRepForCachingDisplayInRect:r];
    [v cacheDisplayInRect:r toBitmapImageRep:shot];
    if (shot.pixelsWide < 8) return NO;
    CGFloat scale = shot.pixelsWide / r.size.width;
    NSInteger y = shot.pixelsHigh / 2;
    NSColor *far = [[shot colorAtX:shot.pixelsWide - 1 y:y] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
    for (NSInteger px = 0; px < (NSInteger)(3 * scale); px++) {
        NSColor *c = [[shot colorAtX:px y:y] colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
        if (!c || !far) continue;
        CGFloat d = fabs(c.redComponent - far.redComponent) + fabs(c.greenComponent - far.greenComponent)
                  + fabs(c.blueComponent - far.blueComponent) + fabs(c.alphaComponent - far.alphaComponent);
        if (d > 0.05) return YES;
    }
    return NO;
}

// A panel that is up over other apps, hidden and brought back, with its tree intact.
static void showAndHide(NSString *folder) {
    FloatPanel *fp = newPanel();
    fp.folder = folder;
    CHECK(!fp.visible, "a new panel starts hidden");

    [fp show];
    spin(0.3);
    CHECK(fp.visible && fp.panel.isVisible, "show puts it on screen");
    CHECK(fp.panel.level == NSFloatingWindowLevel, "it floats above ordinary windows (level %ld)", (long)fp.panel.level);
    CHECK(!fp.panel.hidesOnDeactivate, "it stays up when another app comes forward");
    CHECK((fp.panel.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces) != 0, "it follows across spaces");
    CHECK(fp.panel.canBecomeKeyWindow, "it can take the keyboard (a utility panel refuses by default)");
    // Shown and hidden by a shortcut, so it has to be instant: a utility panel's own behaviour
    // fades it out over a couple of hundred milliseconds.
    CHECK(fp.panel.animationBehavior == NSWindowAnimationBehaviorNone,
          "it appears and disappears with no fade (behaviour %ld)", (long)fp.panel.animationBehavior);

    NSOutlineView *ov = outlineOf(fp);
    CHECK(ov != nil, "the panel has a file tree");
    CHECK(ov.numberOfRows == 3, "the tree lists the folder's files (%ld rows)", (long)ov.numberOfRows);
    CHECK([fp.tree.rootPath isEqualToString:folder], "on its own folder");

    [fp hide];
    spin(0.2);
    CHECK(!fp.visible, "hide takes it off screen");
    [fp toggle];
    spin(0.2);
    CHECK(fp.visible, "toggle brings it back");
    CHECK(outlineOf(fp) == ov && ov.numberOfRows == 3, "the same tree comes back, not a rebuilt one");
    [fp toggle];
    spin(0.2);
    CHECK(!fp.visible, "and toggle hides it again");

    // Closing is hiding: the tree, folder and expansion are kept, and the app is not left without
    // a window because of it.
    [fp show];
    spin(0.2);
    BOOL allowed = [fp windowShouldClose:fp.panel];
    spin(0.2);
    CHECK(!allowed && !fp.visible, "the close button hides the panel instead of destroying it");
    CHECK([fp.tree.rootPath isEqualToString:folder], "its folder survives being closed");
}

// Esc hides, ⌘B collapses the sidebar: both have to work while the tree has the keyboard, where an
// outline view would otherwise swallow them.
static void keysInThePanel(NSString *folder) {
    FloatPanel *fp = newPanel();
    fp.folder = folder;
    [fp show];
    spin(0.3);
    NSOutlineView *ov = outlineOf(fp);
    [fp.panel makeFirstResponder:ov];
    CHECK(fp.panel.firstResponder == ov, "the tree has the keyboard");

    NSEvent *esc = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:fp.panel.windowNumber
                                     context:nil characters:@"\033" charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
    [fp.panel sendEvent:esc];
    spin(0.2);
    CHECK(!fp.visible, "Esc hides the panel even from inside the tree");

    [fp show];
    spin(0.2);
    [fp.panel makeFirstResponder:outlineOf(fp)];
    CHECK(fp.sidebarVisible, "the sidebar starts visible");
    NSEvent *cmdB = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand
                                    timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:fp.panel.windowNumber
                                      context:nil characters:@"b" charactersIgnoringModifiers:@"b" isARepeat:NO keyCode:11];
    CHECK([fp.panel performKeyEquivalent:cmdB], "⌘B is claimed by the panel");
    spin(0.2);
    CHECK(!fp.sidebarVisible, "⌘B collapses the sidebar");
    [fp.panel performKeyEquivalent:cmdB];
    spin(0.2);
    CHECK(fp.sidebarVisible, "and brings it back");
    [fp hide];
}

// Collapsing the sidebar leaves no divider behind. A pixel check belongs on an on-screen composite
// (cacheDisplayInRect: skips AppKit's own divider drawing, and a collapsed divider has no width to
// scan) — what is checkable here is the arrangement that produced the black line last time: the
// delegate must not answer shouldHideDividerAtIndex: out of live sidebar state, because AppKit
// caches that answer and re-queries it inside its own drag loop.
static void dividerGoesWithTheSidebar(NSString *folder) {
    FloatPanel *fp = newPanel();
    fp.folder = folder;
    [fp show];
    spin(0.3);
    NSSplitView *sv = splitOf(fp);
    CHECK(sv != nil && sv.subviews.count == 2, "the panel is a two-part split view");
    CHECK(![fp respondsToSelector:@selector(splitView:shouldHideDividerAtIndex:)],
          "the delegate does not answer shouldHideDividerAtIndex: from live sidebar state");
    CHECK([sv isKindOfClass:NSClassFromString(@"FloatSplitView")],
          "the split view draws its own divider, so it can leave it out with the sidebar");

    NSView *sidebar = sv.subviews.firstObject, *content = sv.subviews.lastObject;
    CGFloat sidebarW = sidebar.frame.size.width;

    // With the sidebar showing there is a separator at its edge: the divider column differs from
    // the content beside it. Comparing columns within one snapshot, because a dynamic colour such
    // as windowBackgroundColor resolves in the current appearance and not in the one drawn here.
    CHECK(columnDiffersFromNeighbour(sv, sidebarW),
          "a separator is drawn at the sidebar's edge while it is showing");

    fp.sidebarVisible = NO;
    spin(0.2);
    CHECK(sidebar.hidden && [sv isSubviewCollapsed:sidebar], "collapsing hides and collapses the sidebar");
    // A collapsed subview keeps its own frame width — that is AppKit's bookkeeping, not something
    // on screen. What the reader sees is the content starting at the divider's single point.
    CHECK(content.frame.origin.x <= sv.dividerThickness && content.frame.size.width >= sv.bounds.size.width - sv.dividerThickness,
          "the content takes the width (x=%.1f w=%.1f of %.1f)", content.frame.origin.x,
          content.frame.size.width, sv.bounds.size.width);
    // And nothing is drawn in that strip: it matches the content next to it.
    CHECK(!columnDiffersFromNeighbour(sv, 0),
          "no line is left where the collapsed sidebar's edge was");

    fp.sidebarVisible = YES;
    spin(0.2);
    CHECK(!sidebar.hidden && ![sv isSubviewCollapsed:sidebar] && sidebar.frame.size.width > 100,
          "and the sidebar comes back at its width (%.1f)", sidebar.frame.size.width);
    CHECK(columnDiffersFromNeighbour(sv, sidebar.frame.size.width), "with its separator back");
    [fp hide];
}

// Folder, collapsed sidebar, sidebar width and the window frame all come back on the next launch.
static void persistence(NSString *a, NSString *b) {
    // Every panel carries the same frameAutosaveName, and AppKit writes that setting by itself
    // whenever a window carrying one moves. The app has a single panel; this test has several, so
    // the earlier ones give up the name here — otherwise AppKit cascades one of them off screen
    // and the frame checked below is that one's, not the one this test saved.
    for (FloatPanel *fp in gPanels) { [fp hide]; fp.panel.frameAutosaveName = @""; }

    NSString *shared = @"FeatherFloatPersistence";
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[@"NSWindow Frame " stringByAppendingString:shared]];
    FloatPanel *first = panelSharingFrameName(shared);
    first.folder = a;
    [first show];
    spin(0.3);
    [first.panel setFrame:NSMakeRect(420, 260, 600, 480) display:YES];
    first.sidebarVisible = NO;
    first.hidesWhenInactive = YES;
    [first hide];
    spin(0.2);
    first.panel.frameAutosaveName = @"";   // only the panel under test may still carry the name

    // What persistence actually keeps is the saved frame string in defaults. The live window frame
    // is not checked here: AppKit repositions an on-screen window to fit the screen and cascades it
    // against other open windows, which is the window server's business, not persistence.
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:[@"NSWindow Frame " stringByAppendingString:shared]];
    CHECK(saved.length && [saved hasPrefix:@"420 260 600 480"],
          "the position and size are saved (\"%s\")", saved.UTF8String);

    FloatPanel *second = panelSharingFrameName(shared);    // stands in for the next launch
    CHECK([second.folder isEqualToString:a], "the folder is remembered (%s)", second.folder.lastPathComponent.UTF8String);
    CHECK(!second.sidebarVisible, "the collapsed sidebar is remembered");
    CHECK(second.hidesWhenInactive, "hiding when inactive is remembered");
    // The fresh panel reads that saved frame before it is ever shown.
    CHECK(fabs(second.panel.frame.size.width - 600) < 2 && fabs(second.panel.frame.size.height - 480) < 2,
          "and a new panel comes up at the saved size (%s)", NSStringFromRect(second.panel.frame).UTF8String);

    // Switching folders moves the tree and its watcher, and is remembered in turn.
    FloatPanel *third = panelSharingFrameName(shared);
    third.folder = b;
    [third show];
    spin(0.3);
    CHECK([third.tree.rootPath isEqualToString:b], "switching folders moves the tree");
    CHECK(outlineOf(third).numberOfRows == 2, "and shows the new folder's files (%ld)", (long)outlineOf(third).numberOfRows);
    [third hide];
    FloatPanel *fourth = panelSharingFrameName(shared);
    CHECK([fourth.folder isEqualToString:b], "the switch is remembered too");

    // A folder that has gone away must not leave a tree pointing at it.
    FloatPanel *fifth = panelSharingFrameName(shared);
    fifth.folder = @"/no/such/folder";
    [fifth show];
    spin(0.2);
    CHECK(fifth.tree.rootPath == nil, "a missing folder leaves the tree empty rather than failing");
    [fifth hide];
}

// Hiding when the panel stops being key: off by default, and only acts when switched on.
static void hidesWhenInactive(NSString *folder) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"floatHidesWhenInactive"];
    FloatPanel *fp = newPanel();
    fp.folder = folder;
    CHECK(!fp.hidesWhenInactive, "staying open is the default");
    [fp show];
    spin(0.2);
    [fp windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:fp.panel]];
    spin(0.2);
    CHECK(fp.visible, "losing the keyboard leaves it up by default");

    fp.hidesWhenInactive = YES;
    [fp windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:fp.panel]];
    spin(0.2);
    CHECK(!fp.visible, "switched on, losing the keyboard hides it");
    fp.hidesWhenInactive = NO;
}

// A click in the tree opens the file in the panel. Single or double makes no difference: there are
// no tabs here to pin, and sending a double click to the main window would undo the point of it.
static void openingAFile(NSString *folder) {
    FloatPanel *fp = newPanel();
    fp.folder = folder;
    __block NSUInteger elsewhere = 0;
    fp.onOpenElsewhere = ^(NSString *p) { elsewhere++; };
    [fp show];
    spin(0.3);
    CHECK(outlineOf(fp).numberOfRows > 0, "the tree has rows to click");
    CHECK(fp.tree.onOpen != nil, "the panel listens to its tree");
    NSString *file = [folder stringByAppendingPathComponent:@"one.md"];
    fp.tree.onOpen(file, NO);
    spin(0.3);
    CHECK([fp.openPath isEqualToString:file] && elsewhere == 0,
          "a single click opens it in the panel (%s)", fp.openPath.lastPathComponent.UTF8String);
    fp.tree.onOpen(file, YES);
    spin(0.2);
    CHECK([fp.openPath isEqualToString:file] && elsewhere == 0, "a double click does the same");
    [fp hide];
}

// Clicking a file shows it in the panel, not in the main window. Source and rendered, editable,
// saved with ⌘S, with links followed in the panel and a trail back along them.
static void showsFilesInPanel(NSString *dir) {
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    __block NSUInteger sentElsewhere = 0;
    __block NSString *elsewhere = nil;
    fp.onOpenElsewhere = ^(NSString *p) { sentElsewhere++; elsewhere = p; };
    [fp show];
    spin(0.3);

    NSString *note = [dir stringByAppendingPathComponent:@"one.md"];
    [fp openFile:note];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:note], "the file opens in the panel (%s)", fp.openPath.lastPathComponent.UTF8String);
    CHECK(sentElsewhere == 0, "and is not handed to the main window");
    MarkupContainer *mc = findView(fp, MarkupContainer.class);
    CHECK(mc != nil, "the panel holds a markup container");
    CHECK(mc.markupLayout == MarkupPreview, "rendered by default, which is what reading wants");
    CHECK(mc.markdownView != nil && [mc.markdownView.textView.string containsString:@"one.md"],
          "and it is showing the file's rendered text");

    // Source and rendered, never both.
    fp.showsPreview = NO;
    spin(0.2);
    CHECK(mc.markupLayout == MarkupSource, "the switch gives the source");
    fp.showsPreview = YES;
    spin(0.2);
    CHECK(mc.markupLayout == MarkupPreview, "and back to rendered");
    CHECK(mc.markupLayout != MarkupSplit, "never side by side: there is no room for it");
    FloatPanel *next = newPanel();
    CHECK(next.showsPreview, "the mode is remembered across launches");

    // Editable, and saved to disk.
    fp.showsPreview = NO;
    spin(0.2);
    TextEditorView *ed = findView(fp, TextEditorView.class);
    CHECK(ed != nil && [ed.path isEqualToString:note], "the source view is an editor on that file");
    [(id<NSTextInputClient>)ed insertText:@"edited in the panel\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(fp.dirty && ed.isDirty, "typing makes it unsaved");
    CHECK(fp.panel.documentEdited, "which the panel's title bar shows");
    __block NSUInteger saveTold = 0;
    fp.onSaved = ^(NSString *p) { saveTold++; };
    CHECK([fp save], "⌘S saves it");
    spin(0.2);
    CHECK(!fp.dirty && !fp.panel.documentEdited, "and it is no longer unsaved");
    NSString *onDisk = [NSString stringWithContentsOfFile:note encoding:NSUTF8StringEncoding error:nil];
    CHECK([onDisk containsString:@"edited in the panel"], "the text reached the file");
    CHECK(saveTold == 1, "the main window is told to re-check the file (%lu)", (unsigned long)saveTold);

    // A video the panel has no viewer for goes to the main window instead.
    NSString *mov = [dir stringByAppendingPathComponent:@"clip.mov"];
    const uint8_t movBytes[] = {0,0,0,0x14,'f','t','y','p','q','t',' ',' '};
    [[NSData dataWithBytes:movBytes length:sizeof movBytes] writeToFile:mov atomically:YES];
    [fp openFile:mov];
    spin(0.2);
    CHECK(sentElsewhere == 1 && [elsewhere isEqualToString:mov], "a video is handed to the main window");
    CHECK([fp.openPath isEqualToString:note], "and the panel keeps the file it had");

    // A file the main window is editing is not shown from disk behind its back.
    fp.hasUnsavedEditsElsewhere = ^BOOL(NSString *p) { return [p.lastPathComponent isEqualToString:@"two.md"]; };
    [fp openFile:[dir stringByAppendingPathComponent:@"two.md"]];
    spin(0.2);
    CHECK(sentElsewhere == 2, "a file with unsaved edits in the main window opens there instead");
    CHECK([fp.openPath isEqualToString:note], "the panel does not show the stale copy from disk");
    fp.hasUnsavedEditsElsewhere = nil;
    [fp hide];
}

// Links in the rendered view are followed inside the panel, and ⌘[ / ⌘] walk the trail.
static void followsLinksInPanel(NSString *dir) {
    NSString *hub = [dir stringByAppendingPathComponent:@"hub.md"];
    NSString *leaf = [dir stringByAppendingPathComponent:@"leaf.md"];
    [@"# Hub\n\n[leaf](leaf.md)\n" writeToFile:hub atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"# Leaf\n\nnothing here\n" writeToFile:leaf atomically:YES encoding:NSUTF8StringEncoding error:nil];

    FloatPanel *fp = newPanel();
    fp.folder = dir;
    __block NSUInteger elsewhere = 0;
    fp.onOpenElsewhere = ^(NSString *p) { elsewhere++; };
    [fp show];
    spin(0.2);
    fp.showsPreview = YES;
    [fp openFile:hub];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:hub] && !fp.canGoBack, "the hub is open with no trail behind it");

    MarkupContainer *mc = findView(fp, MarkupContainer.class);
    [mc followHref:@"leaf.md"];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:leaf], "a link is followed in the panel (%s)", fp.openPath.lastPathComponent.UTF8String);
    CHECK(elsewhere == 0, "not in the main window");
    CHECK(fp.canGoBack && !fp.canGoForward, "which leaves a trail back");
    CHECK(findView(fp, MarkupContainer.class) == mc, "the same container is reused, so nothing flashes");

    [fp goBack];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:hub] && fp.canGoForward, "back returns to the hub");
    [fp goForward];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:leaf] && fp.canGoBack && !fp.canGoForward, "forward goes out again");

    // Choosing a file in the tree starts over rather than extending the trail.
    [fp openFile:hub];
    spin(0.2);
    CHECK(!fp.canGoBack && !fp.canGoForward, "a file chosen in the tree starts a fresh trail");
    [fp hide];
}

// Unsaved work in the panel is never dropped without asking, and never replaced by another file.
static void unsavedInPanel(NSString *dir) {
    // Auto-save off: this is about what happens to work that has *not* been written out.
    NSInteger was = FTSettings.shared.autoSaveMode;
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    [fp show];
    spin(0.2);
    fp.showsPreview = NO;
    NSString *a = [dir stringByAppendingPathComponent:@"one.md"];
    [fp openFile:a];
    spin(0.3);
    TextEditorView *ed = findView(fp, TextEditorView.class);
    [(id<NSTextInputClient>)ed insertText:@"unsaved" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(fp.dirty, "the panel has unsaved work");

    NSString *b = [dir stringByAppendingPathComponent:@"two.md"];
    [fp openFile:b];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:b] && fp.tabCount == 2,
          "another file opens in its own tab, leaving the unsaved one alone (%lu tabs)", (unsigned long)fp.tabCount);
    CHECK(fp.dirty, "the unsaved work is still there");
    [fp selectTab:0];
    spin(0.2);
    CHECK([fp.openPath isEqualToString:a], "and switching back finds it");

    // Hiding keeps it: the file is still there, still unsaved, on the next ⇧⌘E.
    [fp hide];
    spin(0.2);
    [fp show];
    spin(0.2);
    CHECK([fp.openPath isEqualToString:a] && fp.dirty, "hiding and showing keeps the unsaved file");
    CHECK(fp.tabCount == 2, "and both tabs (%lu)", (unsigned long)fp.tabCount);

    // Quitting asks. Cancel stops it; discard lets it go.
    __block NSUInteger asked = 0;
    fp.alertHandler = ^NSModalResponse(NSAlert *al) { asked++; return NSAlertThirdButtonReturn; };
    CHECK(![fp confirmUnsavedBeforeClosing] && asked == 1, "cancel stops the app from quitting");
    fp.alertHandler = ^NSModalResponse(NSAlert *al) { asked++; return NSAlertSecondButtonReturn; };
    CHECK([fp confirmUnsavedBeforeClosing] && asked == 2, "discard lets it quit");
    fp.alertHandler = ^NSModalResponse(NSAlert *al) { asked++; return NSAlertFirstButtonReturn; };
    CHECK([fp confirmUnsavedBeforeClosing] && asked == 3 && !fp.dirty, "save writes it out and lets it quit");
    fp.alertHandler = nil;
    [fp hide];
    FTSettings.shared.autoSaveMode = was;
}

// Images and PDFs the panel can now show itself, read-only, rather than handing them to the main
// window. A type it still can't show (a video) does go there.
static void mediaInPanel(NSString *dir) {
    NSString *png = [dir stringByAppendingPathComponent:@"pic.png"];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:40 pixelsHigh:20
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png atomically:YES];

    FloatPanel *fp = newPanel();
    fp.folder = dir;
    __block NSUInteger elsewhere = 0;
    __block NSString *sent = nil;
    fp.onOpenElsewhere = ^(NSString *p) { elsewhere++; sent = p; };
    [fp show];
    spin(0.3);

    [fp openFile:png];
    spin(0.4);
    CHECK([fp.openPath isEqualToString:png] && elsewhere == 0, "an image opens in the panel, not the main window");
    CHECK(findView(fp, ImagePreviewView.class) != nil, "with an image view");
    CHECK(findView(fp, TextEditorView.class) == nil, "and no editor");
    CHECK(!fp.dirty, "a read-only image is never unsaved");

    // A PDF too. A one-page PDF built by hand with PDFKit.
    NSString *pdfPath = [dir stringByAppendingPathComponent:@"doc.pdf"];
    NSImage *blank = [[NSImage alloc] initWithSize:NSMakeSize(200, 200)];
    [blank lockFocus];
    [NSColor.whiteColor setFill];
    NSRectFill(NSMakeRect(0, 0, 200, 200));
    [blank unlockFocus];
    PDFDocument *pdf = [[PDFDocument alloc] init];
    [pdf insertPage:[[PDFPage alloc] initWithImage:blank] atIndex:0];
    [pdf writeToFile:pdfPath];
    [fp openFile:pdfPath];
    spin(0.4);
    CHECK([fp.openPath isEqualToString:pdfPath] && elsewhere == 0, "a PDF opens in the panel too");
    CHECK(findView(fp, PDFPreview.class) != nil, "with a PDF view");

    // The source/preview switch is only for text; an image has nothing to switch.
    [fp selectTab:0];       // back to the image
    spin(0.3);
    NSSegmentedControl *mode = nil;
    NSMutableArray<NSView *> *stack = [@[fp.panel.contentView] mutableCopy];
    while (stack.count) {
        NSView *v = stack.firstObject; [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:NSSegmentedControl.class] && ((NSSegmentedControl *)v).segmentCount == 2 && [((NSSegmentedControl *)v) imageForSegment:0]) mode = (NSSegmentedControl *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    CHECK(mode == nil || mode.hidden, "no source/preview switch for an image");

    // A type the panel cannot show still goes to the main window.
    NSString *mov = [dir stringByAppendingPathComponent:@"clip.mov"];
    const uint8_t movBytes[] = {0,0,0,0x14,'f','t','y','p','q','t',' ',' '};
    [[NSData dataWithBytes:movBytes length:sizeof movBytes] writeToFile:mov atomically:YES];
    [fp openFile:mov];
    spin(0.2);
    CHECK(elsewhere == 1 && [sent isEqualToString:mov], "a video the panel can't show goes to the main window");
    CHECK(![fp.openPath isEqualToString:mov], "and does not become a panel tab");
    [fp hide];
}

// Editing in the source view and turning the preview on shows the edit. It used to show the file
// as it was when opened, until the tab was left and come back to, because nothing told the
// container the text had changed and an existing preview is not re-rendered by a layout switch.
static void editThenPreview(NSString *dir) {
    NSInteger was = FTSettings.shared.autoSaveMode;
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    NSString *f = [dir stringByAppendingPathComponent:@"live.md"];
    [@"# before\n" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];

    FloatPanel *fp = newPanel();
    fp.folder = dir;
    [fp show];
    spin(0.2);
    fp.showsPreview = YES;
    [fp openFile:f];
    spin(0.4);
    MarkupContainer *mc = findView(fp, MarkupContainer.class);
    CHECK([mc.markdownView.textView.string containsString:@"before"], "the preview shows the file");

    // Edit in the source view, then turn the preview back on.
    fp.showsPreview = NO;
    spin(0.2);
    TextEditorView *ed = findView(fp, TextEditorView.class);
    [(id<NSTextInputClient>)ed insertText:@"# after the edit\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    fp.showsPreview = YES;
    // No waiting: the container's own re-render is debounced by about half a second, and the
    // complaint was that the preview showed stale text until the tab was left and returned to.
    mc = findView(fp, MarkupContainer.class);
    CHECK([mc.markdownView.textView.string containsString:@"after the edit"],
          "turning the preview on shows the edit straight away, with no wait");

    // And an edit made while the preview is showing reaches it too, after its own short delay.
    fp.showsPreview = NO;
    spin(0.2);
    [(id<NSTextInputClient>)findView(fp, TextEditorView.class) insertText:@"# second edit\n"
                                                        replacementRange:NSMakeRange(NSNotFound, 0)];
    fp.showsPreview = YES;
    MarkupContainer *again = findView(fp, MarkupContainer.class);
    CHECK([again.markdownView.textView.string containsString:@"second edit"],
          "and so does the next one, also at once");
    [fp hide];
    FTSettings.shared.autoSaveMode = was;
}

// With the panel in front, a command only the main window can carry out is off rather than being
// done out of sight. ⌥⌘T opened a terminal in the main window; ⌘\\ split its editor.
static void mainWindowCommandsAreOff(NSString *dir) {
    AppDelegate *app = [AppDelegate new];
    [app applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [app buildMenu];
    app->_content.alertHandler = ^NSModalResponse(NSAlert *al) { return NSAlertSecondButtonReturn; };
    [app openRoot:dir];
    FloatPanel *fp = app.floatPanel;
    fp.folder = dir;

    SEL mainOnly[] = {@selector(newTerminal:), @selector(toggleTerminalPanel:), @selector(splitEditor:),
                      @selector(closeAllTabs:), @selector(openFolder:), @selector(quickOpen:),
                      @selector(searchWorkspace:), @selector(viewHex:), @selector(saveAllDocuments:)};
    // With the main window in front they are available as usual.
    [app->_win makeKeyAndOrderFront:nil];
    spin(0.3);
    NSUInteger onWithMain = 0;
    for (size_t i = 0; i < sizeof mainOnly / sizeof mainOnly[0]; i++) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"x" action:mainOnly[i] keyEquivalent:@""];
        if ([app validateMenuItem:mi]) onWithMain++;
    }
    CHECK(onWithMain > 0, "with the main window in front these commands are available (%lu of %zu)",
          (unsigned long)onWithMain, sizeof mainOnly / sizeof mainOnly[0]);

    // Every one of them is classed as main-window-only (the frontmost gate is checked separately
    // below, because a panel can't be made the key window in this test session).
    NSUInteger notClassed = 0;
    NSMutableString *names = [NSMutableString string];
    for (size_t i = 0; i < sizeof mainOnly / sizeof mainOnly[0]; i++) {
        if (![app commandIsMainWindowOnly:mainOnly[i]]) { notClassed++; [names appendFormat:@"%s ", sel_getName(mainOnly[i])]; }
    }
    CHECK(notClassed == 0, "all are classed as main-window-only (%s)", names.UTF8String);

    // What the panel carries out itself, and the app-wide commands, are not in that class.
    CHECK(![app commandIsMainWindowOnly:@selector(saveDocument:)], "saving the panel's own file is not blocked");
    CHECK(![app commandIsMainWindowOnly:@selector(showSettings:)], "nor are the app-wide commands");
    CHECK(![app commandIsMainWindowOnly:@selector(toggleFloatPanel:)], "nor hiding the panel itself");

    // The gate: with the panel hidden, nothing is blocked whatever its class.
    [fp hide];
    spin(0.3);
    CHECK(![app floatPanelHasNoAnswerFor:@selector(newTerminal:)],
          "with the panel away a main-window command is available");
    // And with the panel shown but the main window key, likewise — the gate is "panel in front".
    [fp show];
    [app->_win makeKeyAndOrderFront:nil];
    spin(0.3);
    CHECK(![app floatPanelHasNoAnswerFor:@selector(newTerminal:)],
          "and with the main window in front, even while the panel is open");
    [fp relinquishShortcut];
    [fp hide];
}

// A tab per open file, each with its own editor and link trail.
static void tabs(NSString *dir) {
    NSInteger was = FTSettings.shared.autoSaveMode;
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    [fp show];
    spin(0.3);
    CHECK(fp.tabCount == 0, "a fresh panel has no tabs");

    NSString *a = [dir stringByAppendingPathComponent:@"one.md"];
    NSString *b = [dir stringByAppendingPathComponent:@"two.md"];
    NSString *c = [dir stringByAppendingPathComponent:@"three.md"];
    [fp openFile:a];
    spin(0.3);
    [fp openFile:b];
    spin(0.3);
    CHECK(fp.tabCount == 2 && [fp.openPath isEqualToString:b], "a second file opens in its own tab");
    TabBarView *strip = findView(fp, TabBarView.class);
    CHECK(strip != nil && !strip.hidden && strip.items.count == 2, "the strip shows both");
    CHECK(strip.selectedIndex == 1, "with the new one selected (%ld)", (long)strip.selectedIndex);

    // Opening a file that is already open goes to its tab rather than making a second copy.
    [fp openFile:a];
    spin(0.2);
    CHECK(fp.tabCount == 2 && [fp.openPath isEqualToString:a], "an already open file activates its tab");

    // Each tab keeps its own editor, so switching does not reload or lose anything.
    fp.showsPreview = NO;
    spin(0.2);
    TextEditorView *edA = findView(fp, TextEditorView.class);
    [fp openFile:c];
    spin(0.3);
    CHECK(fp.tabCount == 3, "a third tab (%lu)", (unsigned long)fp.tabCount);
    [fp selectTab:0];
    spin(0.3);
    CHECK([fp.openPath isEqualToString:a], "back to the first tab");
    CHECK(findView(fp, TextEditorView.class) == edA, "with the same editor it had, not a reloaded one");

    // Moving and closing.
    CHECK([fp.openPaths[0] isEqualToString:a] && [fp.openPaths[2] isEqualToString:c], "the strip order");
    strip.onMove(0, 2);
    spin(0.2);
    CHECK([fp.openPaths.lastObject isEqualToString:a], "a tab can be moved along the strip");
    [fp closeTab:0];
    spin(0.2);
    CHECK(fp.tabCount == 2 && ![fp.openPaths containsObject:b], "closing removes that tab");

    [fp selectNextTab];
    spin(0.2);
    NSString *afterNext = fp.openPath;
    [fp selectPreviousTab];
    spin(0.2);
    CHECK(![fp.openPath isEqualToString:afterNext], "the tab shortcuts move between tabs");

    // Closing the last tab leaves the panel empty rather than broken.
    while (fp.tabCount) { [fp closeTab:0]; spin(0.1); }
    CHECK(fp.tabCount == 0 && fp.openPath == nil, "closing every tab empties the panel");
    CHECK(((TabBarView *)findView(fp, TabBarView.class)).hidden, "and the strip goes away");
    [fp hide];
    FTSettings.shared.autoSaveMode = was;
}

// The open tabs survive the app quitting: a fresh panel reopens them, on the tab that was active,
// and leaves behind any file that is no longer there.
static void tabsRestore(NSString *dir) {
    NSInteger was = FTSettings.shared.autoSaveMode;
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud removeObjectForKey:@"floatOpenTabs"];
    [ud removeObjectForKey:@"floatActiveTab"];

    NSString *a = [dir stringByAppendingPathComponent:@"one.md"];
    NSString *b = [dir stringByAppendingPathComponent:@"two.md"];
    NSString *gone = [dir stringByAppendingPathComponent:@"vanishing.md"];
    [@"# vanishing\n" writeToFile:gone atomically:YES encoding:NSUTF8StringEncoding error:nil];

    FloatPanel *first = newPanel();
    first.folder = dir;
    [first show];
    spin(0.2);
    [first openFile:a];  spin(0.2);
    [first openFile:gone];  spin(0.2);
    [first openFile:b];  spin(0.2);
    [first selectTab:0];  spin(0.2);      // leave the first tab active
    CHECK([first.openPath isEqualToString:a], "the active tab is the one we chose");
    [first hide];

    // The file that was open is removed before the "next launch" reads the list back.
    [NSFileManager.defaultManager removeItemAtPath:gone error:nil];

    FloatPanel *second = newPanel();      // stands in for the next launch
    second.folder = dir;
    [second restoreTabs];
    spin(0.3);
    CHECK(second.tabCount == 2, "the open tabs come back, minus the missing file (%lu)", (unsigned long)second.tabCount);
    CHECK([second.openPaths containsObject:a] && [second.openPaths containsObject:b], "both surviving files reopened");
    CHECK(![second.openPaths containsObject:gone], "the deleted file is not reopened");
    CHECK([second.openPath isEqualToString:a], "on the tab that was active last (%s)", second.openPath.lastPathComponent.UTF8String);

    // An empty session restores to nothing rather than reopening a stale list.
    while (second.tabCount) { [second closeTab:0]; spin(0.1); }
    FloatPanel *third = newPanel();
    [third restoreTabs];
    spin(0.2);
    CHECK(third.tabCount == 0, "with no tabs saved, a launch opens none");

    [ud removeObjectForKey:@"floatOpenTabs"];
    [ud removeObjectForKey:@"floatActiveTab"];
    FTSettings.shared.autoSaveMode = was;
}

// With hide-on-blur on, the panel must not take itself down when its own sheet or alert takes the
// key window — that is what made the folder picker flash and vanish. The save prompt stands in for
// the picker (a real NSOpenPanel can't run headless); both go through the same modal guard.
static void staysUpForItsOwnDialogs(NSString *dir) {
    NSInteger wasAuto = FTSettings.shared.autoSaveMode;
    BOOL wasHide = FTSettings.shared.floatHidesWhenInactive;
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    FTSettings.shared.floatHidesWhenInactive = YES;

    FloatPanel *fp = newPanel();
    fp.folder = dir;
    [fp show];
    spin(0.2);
    fp.showsPreview = NO;
    NSString *note = [dir stringByAppendingPathComponent:@"one.md"];
    [fp openFile:note];
    spin(0.3);
    TextEditorView *ed = findView(fp, TextEditorView.class);
    [(id<NSTextInputClient>)ed insertText:@"x" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(fp.dirty, "the tab has unsaved work for the prompt to ask about");

    // The alert fires from closeTab. While it is up, the panel loses key — mimic that — and must
    // stay visible rather than hide itself and pull the alert's host away.
    __block BOOL visibleWhileAsked = NO;
    __weak FloatPanel *weakFp = fp;
    fp.alertHandler = ^NSModalResponse(NSAlert *a) {
        FloatPanel *me = weakFp;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:me.panel];
        visibleWhileAsked = me.visible;
        return NSAlertSecondButtonReturn;        // discard, so nothing else blocks
    };
    [fp closeTab:0];
    spin(0.2);
    CHECK(visibleWhileAsked, "the panel stays up while its own alert is answered");

    FTSettings.shared.autoSaveMode = wasAuto;
    FTSettings.shared.floatHidesWhenInactive = wasHide;
    [fp hide];
}

// Auto-save, on the same setting as the main window. A file changed on disk behind the panel's
// back is never overwritten silently.
static void autoSave(NSString *dir) {
    NSInteger was = FTSettings.shared.autoSaveMode;
    NSString *f = [dir stringByAppendingPathComponent:@"auto.md"];
    [@"# start\n" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];

    FTSettings.shared.autoSaveMode = AutoSaveAfterDelay;
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    fp.autoSaveDelay = 0.25;
    [fp show];
    spin(0.2);
    fp.showsPreview = NO;
    [fp openFile:f];
    spin(0.3);
    TextEditorView *ed = findView(fp, TextEditorView.class);
    CHECK(ed != nil, "the file is open in the source view");
    [(id<NSTextInputClient>)ed insertText:@"typed\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(fp.dirty, "typing leaves it unsaved for a moment");
    spin(1.0);
    CHECK(!fp.dirty, "and a pause writes it out without being asked");
    CHECK([[NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] containsString:@"typed"],
          "the text reached the file");

    // On focus change: hiding the panel is one.
    FTSettings.shared.autoSaveMode = AutoSaveOnFocusChange;
    [(id<NSTextInputClient>)findView(fp, TextEditorView.class) insertText:@"more\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(fp.dirty, "unsaved again");
    spin(0.8);
    CHECK(fp.dirty, "a pause alone does not save in this mode");
    [fp hide];
    spin(0.3);
    CHECK(!fp.dirty, "hiding the panel does");
    CHECK([[NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] containsString:@"more"],
          "and the text is in the file");

    // Off: nothing is written until ⌘S.
    FTSettings.shared.autoSaveMode = AutoSaveOff;
    [fp show];
    spin(0.2);
    [(id<NSTextInputClient>)findView(fp, TextEditorView.class) insertText:@"manual\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    spin(0.8);
    CHECK(fp.dirty, "with auto-save off a pause saves nothing");
    [fp flushAutoSave];
    CHECK(fp.dirty, "and neither does a focus change");
    CHECK([fp save] && !fp.dirty, "but ⌘S does");

    // A file changed on disk is not overwritten by auto-save.
    FTSettings.shared.autoSaveMode = AutoSaveAfterDelay;
    fp.autoSaveDelay = 0.25;
    [(id<NSTextInputClient>)findView(fp, TextEditorView.class) insertText:@"mine\n" replacementRange:NSMakeRange(NSNotFound, 0)];
    spin(0.1);
    [@"# someone else wrote this\n" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
    spin(1.2);
    CHECK(fp.dirty, "a file changed on disk is left alone, and the panel's work kept");
    CHECK([[NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil] containsString:@"someone else"],
          "the other change stands");

    [fp hide];
    FTSettings.shared.autoSaveMode = was;
}

// The mode and history controls fit the space they are given. In a utility window's 19-point title
// bar they were clipped, which is why they live in the content area now.
static void controlsFitTheirStrip(NSString *dir) {
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    [fp show];
    spin(0.2);
    [fp openFile:[dir stringByAppendingPathComponent:@"one.md"]];
    spin(0.3);

    NSSegmentedControl *mode = nil;
    NSMutableArray<NSView *> *stack = [@[fp.panel.contentView] mutableCopy];
    while (stack.count) {
        NSView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([v isKindOfClass:NSSegmentedControl.class] && ((NSSegmentedControl *)v).segmentCount == 2 &&
            !v.hidden) mode = (NSSegmentedControl *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    CHECK(mode != nil, "a segmented control is on screen in the content area");
    NSView *host = mode.superview;
    CHECK(host != nil, "inside a container view, not the title bar");
    // It must sit inside its container, top and bottom: clipping is what was wrong.
    CHECK(NSMinY(mode.frame) >= -0.5 && NSMaxY(mode.frame) <= host.bounds.size.height + 0.5,
          "and fits inside it vertically (%.1f..%.1f of %.1f)", NSMinY(mode.frame), NSMaxY(mode.frame),
          host.bounds.size.height);
    CHECK(NSMaxX(mode.frame) <= host.bounds.size.width + 0.5,
          "and horizontally (%.1f of %.1f)", NSMaxX(mode.frame), host.bounds.size.width);
    CHECK(fp.panel.titlebarAccessoryViewControllers.count == 1,
          "only the sidebar button is left in the title bar (%lu accessories)",
          (unsigned long)fp.panel.titlebarAccessoryViewControllers.count);

    TabBarView *strip = findView(fp, TabBarView.class);
    CHECK(!NSIntersectsRect(strip.frame, mode.frame), "the tab strip does not run under the controls");

    // Narrow: the controls give way rather than squeezing the tabs to nothing.
    [fp.panel setFrame:NSMakeRect(fp.panel.frame.origin.x, fp.panel.frame.origin.y, 300, 400) display:YES];
    spin(0.3);
    strip = findView(fp, TabBarView.class);
    CHECK(strip.frame.size.width > 60, "a narrow panel still has a usable strip (%.1f)", strip.frame.size.width);
    [fp hide];
}

// Several folders, switched from the panel's own header. Without this the folder could only be set
// by writing to NSUserDefaults, which a running app does not even read back.
static void folderList(NSString *unusedA, NSString *unusedB) {
    // Its own folders: the counts below are exact, and other tests add files to theirs.
    NSString *a = makeFolder(@"list-a", @[@"a1.md", @"a2.md", @"a3.md"]);
    NSString *b = makeFolder(@"list-b", @[@"b1.md", @"b2.md"]);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"floatFolders"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"floatFolder"];
    FloatPanel *fp = newPanel();
    [fp show];
    spin(0.3);
    CHECK(fp.folders.count == 0 && fp.folder == nil, "a panel with nothing configured has no folder");
    NSPopUpButton *popup = folderPopupOf(fp);
    CHECK(popup != nil, "the header has a folder pull-down");
    openMenu(popup.menu);
    CHECK([popup.menu.itemArray.firstObject.title isEqualToString:@"Choose a Folder"],
          "which says so (\"%s\")", popup.menu.itemArray.firstObject.title.UTF8String);
    // And a button in the empty content area, since the tree has nothing to click.
    NSButton *choose = chooseButtonOf(fp);
    CHECK(choose != nil && !choose.hidden, "with a button to choose one");
    CHECK(choose.action == @selector(chooseFolder:), "that opens the folder picker");

    [fp addFolder:a];
    spin(0.3);
    CHECK([fp.folder isEqualToString:a] && fp.folders.count == 1, "adding a folder switches to it");
    CHECK([fp.tree.rootPath isEqualToString:a] && outlineOf(fp).numberOfRows == 3,
          "and the tree shows it (%ld rows)", (long)outlineOf(fp).numberOfRows);
    CHECK(chooseButtonOf(fp).hidden, "the choose button goes away once there is a folder");
    openMenu(popup.menu);
    CHECK([popup.menu.itemArray.firstObject.title isEqualToString:a.lastPathComponent],
          "the pull-down's title is the folder (\"%s\")", popup.menu.itemArray.firstObject.title.UTF8String);

    [fp addFolder:b];
    spin(0.3);
    CHECK([fp.folder isEqualToString:b] && fp.folders.count == 2, "a second folder is added and switched to");
    CHECK(outlineOf(fp).numberOfRows == 2, "the tree follows (%ld rows)", (long)outlineOf(fp).numberOfRows);
    CHECK([fp.folders.firstObject isEqualToString:b], "most recently chosen comes first");

    // Switching back through the menu, the way a click does.
    openMenu(popup.menu);
    NSMenuItem *first = nil;
    for (NSMenuItem *i in popup.menu.itemArray) if ([i.representedObject isEqualToString:a]) { first = i; break; }
    CHECK(first != nil && first.target == fp && first.action != NULL,
          "the other folder is in the menu, aimed at the panel");
    // Sending the item's own action is what a click on it does.
    if (first) [NSApp sendAction:first.action to:first.target from:first];
    spin(0.3);
    CHECK([fp.folder isEqualToString:a] && outlineOf(fp).numberOfRows == 3, "picking it switches the tree back");

    // A tick marks the current one, and the current one offers no ⌥ remove item.
    openMenu(popup.menu);
    NSUInteger ticks = 0, altsForCurrent = 0;
    for (NSMenuItem *i in popup.menu.itemArray) {
        if (i.state == NSControlStateValueOn) ticks++;
        if (i.isAlternate && [i.representedObject isEqualToString:a]) altsForCurrent++;
    }
    CHECK(ticks == 1, "exactly one folder is ticked (%lu)", (unsigned long)ticks);
    CHECK(altsForCurrent == 0, "the current folder cannot be removed from the list");

    [fp removeFolder:b];
    CHECK(fp.folders.count == 1 && [fp.folder isEqualToString:a], "removing another folder leaves the current one");
    [fp removeFolder:a];
    spin(0.2);
    CHECK(fp.folders.count == 0 && fp.folder == nil, "removing the last one leaves no folder");
    CHECK(fp.tree.rootPath == nil && !chooseButtonOf(fp).hidden, "and the panel offers to choose one again");

    // Remembered across launches, including which was last used.
    [fp addFolder:a];
    [fp addFolder:b];
    FloatPanel *next = newPanel();
    CHECK(next.folders.count == 2 && [next.folder isEqualToString:b],
          "the list and the last folder come back (%lu folders, %s)", (unsigned long)next.folders.count,
          next.folder.lastPathComponent.UTF8String);

    // A folder that has gone away stays in the list, so it can be removed, but shows as missing.
    NSString *gone = [NSTemporaryDirectory() stringByAppendingPathComponent:@"float-gone"];
    [NSFileManager.defaultManager createDirectoryAtPath:gone withIntermediateDirectories:YES attributes:nil error:nil];
    [next addFolder:gone];
    [NSFileManager.defaultManager removeItemAtPath:gone error:nil];
    [next setFolder:nil];
    [next setFolder:gone];
    spin(0.2);
    CHECK(next.tree.rootPath == nil, "a folder that has gone leaves the tree empty");
    openMenu(folderPopupOf(next).menu);
    CHECK([folderPopupOf(next).menu.itemArray.firstObject.title containsString:@"missing"],
          "and the header says so (\"%s\")", folderPopupOf(next).menu.itemArray.firstObject.title.UTF8String);
    [next removeFolder:gone];

    // "Add Folder…" in the header pull-down reaches the picker. It used to open a sheet while the
    // menu was still unwinding, so nothing appeared; the seam stands in for the open panel here.
    FloatPanel *add = newPanel();
    __block NSUInteger asked = 0;
    add.folderChooser = ^NSString * { asked++; return a; };
    [add show];
    spin(0.2);
    NSMenu *menu = folderPopupOf(add).menu;
    openMenu(menu);
    NSMenuItem *addItem = nil;
    for (NSMenuItem *i in menu.itemArray) if (i.action == @selector(chooseFolder:)) { addItem = i; break; }
    CHECK(addItem != nil && addItem.target == add, "the pull-down offers Add Folder…, aimed at the panel");
    if (addItem) [NSApp sendAction:addItem.action to:addItem.target from:addItem];
    spin(0.2);
    CHECK(asked == 1, "choosing it opens the picker (%lu)", (unsigned long)asked);
    CHECK([add.folder isEqualToString:a] && [add.folders containsObject:a], "and the chosen folder is adopted");
    [add hide];

    [fp hide];
    [next hide];
    for (NSString *d in @[a, b]) [NSFileManager.defaultManager removeItemAtPath:d error:nil];
}

// The system-wide shortcut: registered by default, changeable, and refusals reported rather than
// swallowed. A menu shortcut can't reach the panel while another app is in front, which is what
// this exists for.
static void globalShortcut(NSString *folder) {
    // Every panel built earlier in this process still holds the combination it registered; the real
    // app only ever has one. Theirs are given up first — and that writes the empty shortcut to the
    // shared setting, so the setting is cleared afterwards to get the default back.
    releaseEarlierShortcuts();
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"floatShortcut"];

    FloatPanel *fp = [FloatPanel new];
    fp.folder = folder;
    CHECK([fp.shortcut isEqualToString:@"⇧⌘E"], "⇧⌘E is the default (%s)", fp.shortcut.UTF8String);
    CHECK(fp.shortcutRegistered, "it is registered with the system: %s",
          fp.shortcutProblem.UTF8String ?: "no problem reported");
    CHECK(fp.shortcutProblem == nil, "and reports no problem");

    fp.shortcut = @"⌥⌘J";
    CHECK([fp.shortcut isEqualToString:@"⌥⌘J"] && fp.shortcutRegistered,
          "it can be changed (%s, registered=%d)", fp.shortcut.UTF8String, fp.shortcutRegistered);
    FloatPanel *next = [FloatPanel new];
    CHECK([next.shortcut isEqualToString:@"⌥⌘J"], "and is remembered across launches");

    // Two holders of one combination: the second must be refused, not silently dead. This is what
    // the reader meets when another app already has the shortcut.
    CHECK(!next.shortcutRegistered && next.shortcutProblem.length,
          "a combination another app holds is refused with a reason (%s)", next.shortcutProblem.UTF8String);
    next.shortcut = @"";              // and gives it up again

    // Combinations macOS will not take as a global shortcut.
    fp.shortcut = @"E";
    CHECK(!fp.shortcutRegistered && fp.shortcutProblem.length, "a bare key is refused: %s", fp.shortcutProblem.UTF8String);
    fp.shortcut = @"⇧E";
    CHECK(!fp.shortcutRegistered, "⇧ alone is not enough either");
    fp.shortcut = @"";
    CHECK(!fp.shortcutRegistered && fp.shortcutProblem == nil, "an empty shortcut turns it off without complaint");

    CHECK([FTHotKey isUsableShortcut:@"⇧⌘E"] && [FTHotKey isUsableShortcut:@"⌃⌥Space"] &&
          ![FTHotKey isUsableShortcut:@"E"] && ![FTHotKey isUsableShortcut:@"⇧A"] && ![FTHotKey isUsableShortcut:@""],
          "what counts as a usable combination");

    // Writing one down from a key press, the way the settings window will.
    NSEvent *press = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                 modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagShift
                                     timestamp:0 windowNumber:0 context:nil characters:@"E"
                    charactersIgnoringModifiers:@"e" isARepeat:NO keyCode:14];
    CHECK([[FTHotKey shortcutForEvent:press] isEqualToString:@"⇧⌘E"], "a key press becomes ⇧⌘E (%s)",
          [FTHotKey shortcutForEvent:press].UTF8String);
    NSEvent *plain = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                     timestamp:0 windowNumber:0 context:nil characters:@"e"
                   charactersIgnoringModifiers:@"e" isARepeat:NO keyCode:14];
    CHECK([FTHotKey shortcutForEvent:plain] == nil, "a press with no modifier is not offered as one");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"floatShortcut"];
}

// The menu item must not carry the same combination as the global hot key: both would fire and the
// panel would toggle twice. It shows the shortcut in its title instead.
static void menuItemDoesNotClaimTheShortcut(void) {
    AppDelegate *app = [AppDelegate new];
    [app buildMenu];
    (void)app.floatPanel;        // the app builds it at launch, which is when the hot key registers
    NSMenuItem *floatItem = nil, *fileTree = nil;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *i in top.submenu.itemArray) {
            if (i.action == @selector(toggleFloatPanel:)) floatItem = i;
            if (i.action == @selector(showFilesTab:)) fileTree = i;
        }
    CHECK(floatItem != nil, "the View menu has a Floating Workspace item");
    CHECK(floatItem.keyEquivalent.length == 0,
          "it carries no key equivalent, so the global hot key is the only thing that fires (\"%s\")",
          floatItem.keyEquivalent.UTF8String);
    CHECK(fileTree != nil && [fileTree.keyEquivalent isEqualToString:@"1"] &&
          fileTree.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagControl),
          "File Tree moved to ⌃⌘1, leaving ⇧⌘E free for the panel");
    // Nothing else may hold ⇧⌘E, or AppKit would clear one of them silently.
    NSUInteger holders = 0;
    for (NSMenuItem *top in NSApp.mainMenu.itemArray)
        for (NSMenuItem *i in top.submenu.itemArray)
            if ([i.keyEquivalent isEqualToString:@"e"] &&
                i.keyEquivalentModifierMask == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) holders++;
    CHECK(holders == 0, "no menu item holds ⇧⌘E any more (%lu do)", (unsigned long)holders);

    [app validateMenuItem:floatItem];
    CHECK([floatItem.title containsString:@"⇧⌘E"] || [floatItem.title containsString:@"⌥⌘J"],
          "the item's title names the shortcut so it can be found: \"%s\"", floatItem.title.UTF8String);
}

// The settings window's floating-workspace section: the folder list, the shortcut recorder and the
// hide-when-inactive box. Without these three the panel could only be configured by writing to
// NSUserDefaults, which a running app does not read back.
static void settingsSection(NSString *a, NSString *b) {
    NSArray *keep = FTSettings.shared.floatFolders;
    NSString *keepShortcut = FTSettings.shared.floatShortcut;
    FTSettings.shared.floatFolders = @[];

    SettingsWindow *w = [SettingsWindow new];
    CHECK(w.floatFolderTable != nil && w.floatShortcutField != nil && w.floatHidesBox != nil,
          "the window has a folder list, a shortcut recorder and a hide box");
    [w reloadFromSettings];
    CHECK(w.floatFolderTable.numberOfRows == 0, "the list starts empty");
    CHECK(!w.floatRemoveButton.enabled, "with nothing to remove");

    // Adding, through the picker the window would put up.
    __block NSUInteger asked = 0;
    w.folderChooser = ^NSString * { asked++; return a; };
    [w.floatAddButton performClick:nil];
    CHECK(asked == 1 && w.floatFolderTable.numberOfRows == 1, "Add… asks for a folder and lists it");
    CHECK([FTSettings.shared.floatFolders.firstObject isEqualToString:a], "and remembers it");
    w.folderChooser = ^NSString * { return b; };
    [w.floatAddButton performClick:nil];
    CHECK(w.floatFolderTable.numberOfRows == 2, "a second folder (%ld rows)", (long)w.floatFolderTable.numberOfRows);
    CHECK([FTSettings.shared.floatFolders.firstObject isEqualToString:b], "most recently added first");

    // The same folder twice is one entry, moved to the front.
    w.folderChooser = ^NSString * { return a; };
    [w.floatAddButton performClick:nil];
    CHECK(w.floatFolderTable.numberOfRows == 2 && [FTSettings.shared.floatFolders.firstObject isEqualToString:a],
          "adding one already listed moves it rather than duplicating it");

    // What a row shows, including a folder that has gone.
    NSTextField *row0 = (NSTextField *)[w tableView:w.floatFolderTable viewForTableColumn:w.floatFolderTable.tableColumns.firstObject row:0];
    CHECK([row0.stringValue containsString:a.lastPathComponent], "a row names its folder (\"%s\")", row0.stringValue.UTF8String);
    NSString *gone = [NSTemporaryDirectory() stringByAppendingPathComponent:@"settings-gone"];
    [NSFileManager.defaultManager createDirectoryAtPath:gone withIntermediateDirectories:YES attributes:nil error:nil];
    w.folderChooser = ^NSString * { return gone; };
    [w.floatAddButton performClick:nil];
    [NSFileManager.defaultManager removeItemAtPath:gone error:nil];
    [w reloadFromSettings];
    NSTextField *goneRow = (NSTextField *)[w tableView:w.floatFolderTable viewForTableColumn:w.floatFolderTable.tableColumns.firstObject row:0];
    CHECK([goneRow.stringValue containsString:@"missing"],
          "a folder that has gone is marked rather than dropped (\"%s\")", goneRow.stringValue.UTF8String);

    // Removing takes the selected one.
    [w.floatFolderTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [w tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:w.floatFolderTable]];
    CHECK(w.floatRemoveButton.enabled, "Remove becomes available with a row selected");
    NSUInteger before = FTSettings.shared.floatFolders.count;
    [w.floatRemoveButton performClick:nil];
    CHECK(FTSettings.shared.floatFolders.count == before - 1 && ![FTSettings.shared.floatFolders containsObject:gone],
          "and removes it from the list");

    // The shortcut recorder.
    FTShortcutField *f = w.floatShortcutField;
    CHECK([f.shortcut isEqualToString:FTSettings.shared.floatShortcut], "the recorder shows the current shortcut");
    [f startRecording];
    CHECK(f.recording, "clicking it starts recording");
    NSEvent *optCmdJ = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                   modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagOption
                                       timestamp:0 windowNumber:0 context:nil characters:@"j"
                      charactersIgnoringModifiers:@"j" isARepeat:NO keyCode:38];
    CHECK([f recordEvent:optCmdJ], "a combination is taken");
    CHECK(!f.recording && [f.shortcut isEqualToString:@"⌥⌘J"], "and recorded (%s)", f.shortcut.UTF8String);
    CHECK([FTSettings.shared.floatShortcut isEqualToString:@"⌥⌘J"], "and saved");

    // A combination macOS won't take as a global shortcut is refused with a reason.
    [f startRecording];
    NSEvent *bare = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                    timestamp:0 windowNumber:0 context:nil characters:@"k"
                   charactersIgnoringModifiers:@"k" isARepeat:NO keyCode:40];
    [f recordEvent:bare];
    CHECK(f.recording && f.problem.length, "a bare key is refused and says why (\"%s\")", f.problem.UTF8String);
    CHECK([f.shortcut isEqualToString:@"⌥⌘J"], "leaving the old one in place");
    NSEvent *shiftOnly = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                     modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0
                                           context:nil characters:@"K" charactersIgnoringModifiers:@"k"
                                         isARepeat:NO keyCode:40];
    [f recordEvent:shiftOnly];
    CHECK(f.recording && f.problem.length, "⇧ alone is refused too");

    // Esc leaves it alone, ⌫ clears it.
    NSEvent *esc = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                   timestamp:0 windowNumber:0 context:nil characters:@"\033"
                  charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
    [f recordEvent:esc];
    CHECK(!f.recording && [f.shortcut isEqualToString:@"⌥⌘J"], "Esc stops recording and changes nothing");
    [f startRecording];
    NSEvent *del = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                   timestamp:0 windowNumber:0 context:nil characters:@"\b"
                  charactersIgnoringModifiers:@"\b" isARepeat:NO keyCode:51];
    [f recordEvent:del];
    CHECK(!f.recording && f.shortcut.length == 0 && FTSettings.shared.floatShortcut.length == 0,
          "⌫ clears it, which turns the shortcut off (shortcut=\"%s\")", f.shortcut.UTF8String ?: "nil");

    // A refused registration is said out loud rather than leaving a dead key.
    w.floatShortcutStatus = ^NSString * { return @"Another app is already using that shortcut."; };
    [w reloadFromSettings];
    CHECK(!w.floatShortcutNote.hidden && w.floatShortcutNote.stringValue.length,
          "a shortcut macOS refused is reported in the window (\"%s\")", w.floatShortcutNote.stringValue.UTF8String);
    w.floatShortcutStatus = ^NSString * { return nil; };
    [w reloadFromSettings];
    CHECK(w.floatShortcutNote.hidden, "and nothing is said when it is in effect");

    // The hide box, and the panel following it.
    FTSettings.shared.floatHidesWhenInactive = NO;
    [w reloadFromSettings];
    CHECK(w.floatHidesBox.state == NSControlStateValueOff, "staying open is the default");
    [w.floatHidesBox performClick:nil];
    CHECK(FTSettings.shared.floatHidesWhenInactive, "ticking it is saved");
    FloatPanel *fp = newPanel();
    CHECK(fp.hidesWhenInactive, "and the panel reads the same setting");
    FTSettings.shared.floatHidesWhenInactive = NO;

    // The panel and the window agree about the folder list, both ways.
    NSArray *both = @[a, b];
    FTSettings.shared.floatFolders = both;
    CHECK([fp.folders isEqualToArray:both], "the panel sees the window's list");
    [fp addFolder:b];
    [w reloadFromSettings];
    CHECK(w.floatFolderTable.numberOfRows == 2 && [FTSettings.shared.floatFolders.firstObject isEqualToString:b],
          "and the window sees the panel's choice");

    FTSettings.shared.floatFolders = keep;
    FTSettings.shared.floatShortcut = keepShortcut;
    fp.shortcut = @"";              // this panel outlives the test; it gives the combination back
    FTSettings.shared.floatShortcut = keepShortcut;
    [w.window close];
}

// Right-click in the main window → "Move to Floating Workspace". The panel answers whether it can
// show a file (so the item is offered only when it can), and opening one brings the panel up.
static void moveIntoPanel(NSString *dir) {
    FloatPanel *fp = newPanel();
    fp.folder = dir;

    NSString *md = [dir stringByAppendingPathComponent:@"one.md"];
    NSString *mov = [dir stringByAppendingPathComponent:@"clip.mov"];
    const uint8_t movBytes[] = {0,0,0,0x14,'f','t','y','p','q','t',' ',' '};
    [[NSData dataWithBytes:movBytes length:sizeof movBytes] writeToFile:mov atomically:YES];

    CHECK([fp canShow:md], "the panel can show a markdown file");
    CHECK(![fp canShow:mov], "but not a video it has no viewer for");
    CHECK(![fp canShow:nil], "and nil is never showable");

    // The content controller's wiring: it only offers the move when canShow says yes, and opening
    // brings the panel up — the two blocks the app connects to the panel.
    __block NSString *opened = nil;
    BOOL (^canOpen)(NSString *) = ^BOOL(NSString *p) { return [fp canShow:p]; };
    void (^openIt)(NSString *) = ^(NSString *p) { opened = p; [fp openFile:p]; [fp show]; };
    CHECK(canOpen(md) && !canOpen(mov), "the window would offer the move for the note, not the video");
    openIt(md);
    spin(0.3);
    CHECK([opened isEqualToString:md] && [fp.openPath isEqualToString:md], "the note opens in the panel");
    CHECK(fp.visible, "and the panel is shown so the move is visible");
    [fp hide];
}

// The panel's tree is not a read-only list: new file / folder, rename (with the open tab following),
// and move to trash (closing the tab). The name prompt and the trash are stubbed so nothing pops a
// sheet or touches the real Trash.
static void treeFileOps(NSString *unused) {
    NSString *dir = makeFolder(@"treeops", @[@"keep.md"]);
    FloatPanel *fp = newPanel();
    fp.folder = dir;
    __block NSString *nextName = nil;
    fp.namePrompt = ^NSString *(NSString *t, NSString *init) { return nextName; };
    fp.trashHandler = ^NSString *(NSString *p) { [NSFileManager.defaultManager removeItemAtPath:p error:nil]; return nil; };
    [fp show];
    spin(0.3);
    NSFileManager *fm = NSFileManager.defaultManager;

    // New file, into the root, opened for editing.
    nextName = @"made.md";
    [fp floatNewFile:nil];
    spin(0.3);
    NSString *made = [dir stringByAppendingPathComponent:@"made.md"];
    CHECK([fm fileExistsAtPath:made], "new file is created on disk");
    CHECK([fp.openPath isEqualToString:made], "and opens in the panel (%s)", fp.openPath.lastPathComponent.UTF8String);

    // New folder.
    nextName = @"sub";
    [fp floatNewFolder:nil];
    spin(0.3);
    BOOL isDir = NO;
    CHECK([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"sub"] isDirectory:&isDir] && isDir, "new folder is created");

    // Rename the open file; its tab follows to the new path rather than dangling.
    [fp.tree revealPath:made];
    spin(0.1);
    nextName = @"renamed.md";
    [fp renameItem:nil];
    spin(0.3);
    NSString *renamed = [dir stringByAppendingPathComponent:@"renamed.md"];
    CHECK([fm fileExistsAtPath:renamed] && ![fm fileExistsAtPath:made], "rename moves the file");
    CHECK([fp.openPath isEqualToString:renamed], "the open tab follows the rename (%s)", fp.openPath.lastPathComponent.UTF8String);

    // Trash it; the file goes and its tab closes.
    [fp.tree revealPath:renamed];
    spin(0.1);
    [fp trashItem:nil];
    spin(0.3);
    CHECK(![fm fileExistsAtPath:renamed], "trash removes the file");
    CHECK(![fp.openPaths containsObject:renamed], "and closes its tab");

    // The root cannot be renamed or trashed.
    [fp.tree revealPath:dir];        // selecting the root selects nothing within it
    NSMenuItem *rename = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(renameItem:) keyEquivalent:@""];
    rename.tag = 0x5107; rename.representedObject = @[dir];
    CHECK(![(id<NSMenuItemValidation>)fp validateMenuItem:rename], "the workspace root is not renameable");

    [fp hide];
    [fm removeItemAtPath:dir error:nil];
}

static void builtLazily(void) {
    AppDelegate *app = [AppDelegate new];
    CHECK(app->_float == nil, "no panel exists until something asks for one");
    NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:@"x" action:@selector(toggleFloatPanel:) keyEquivalent:@""];
    [app validateMenuItem:mi];
    CHECK(app->_float == nil, "validating the menu item does not build it");
    CHECK(mi.state == NSControlStateValueOff, "and reports it as not showing");

    // A session that never opened the panel must still be able to close its window. Asking a nil
    // panel whether it holds unsaved work answers NO, which read as "cancel" and refused the close.
    [app applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    app->_content.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertSecondButtonReturn; };
    CHECK(app->_float == nil, "still no panel");
    CHECK([app windowShouldClose:app->_win], "the window closes with no panel in existence");

    FloatPanel *fp = app.floatPanel;
    CHECK(fp != nil && app->_float == fp, "asking for it builds it once");
    CHECK(app.floatPanel == fp, "and keeps the same one");
    CHECK([app windowShouldClose:app->_win], "and still closes with a panel holding nothing unsaved");
    fp.shortcut = @"";        // give the hot key back, this panel outlives the test
}

// The panel's state lives in NSUserDefaults, and CFFIXED_USER_HOME does not isolate a binary with
// no bundle identifier: without this, one run's collapsed sidebar and saved frame are read by the
// next and the assertions about starting state fail. Every key this test can write is cleared
// before and after.
static NSString *const kOurKeys[] = {@"floatFolder", @"floatFolders", @"floatSidebarVisible",
                                     @"floatTreeWidth", @"floatHidesWhenInactive", @"floatShortcut", @"floatShowsPreview",
                                     @"floatOpenTabs", @"floatActiveTab",
                                     @"NSWindow Frame FeatherFloat",
                                     @"NSWindow Frame FeatherFloatPersistence"};

static void clearOurDefaults(void) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    for (size_t i = 0; i < sizeof kOurKeys / sizeof *kOurKeys; i++) [ud removeObjectForKey:kOurKeys[i]];
    [ud synchronize];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [FTSettings shared];
        clearOurDefaults();
        NSString *a = makeFolder(@"notes", @[@"one.md", @"two.md", @"three.md"]);
        NSString *b = makeFolder(@"other", @[@"x.md", @"y.md"]);
        @try {
            showAndHide(a);
            keysInThePanel(a);
            dividerGoesWithTheSidebar(a);
            persistence(a, b);
            hidesWhenInactive(a);
            openingAFile(a);
            showsFilesInPanel(a);
            followsLinksInPanel(a);
            unsavedInPanel(a);
            mediaInPanel(a);
            editThenPreview(a);
            mainWindowCommandsAreOff(a);
            tabs(a);
            tabsRestore(a);
            moveIntoPanel(a);
            staysUpForItsOwnDialogs(a);
            autoSave(a);
            controlsFitTheirStrip(a);
            folderList(a, b);
            globalShortcut(a);
            menuItemDoesNotClaimTheShortcut();
            settingsSection(a, b);
            treeFileOps(a);
            builtLazily();
        } @catch (NSException *e) {
            CHECK(NO, "uncaught %s: %s", e.name.UTF8String, e.reason.UTF8String);
        } @finally {
            for (NSString *d in @[a, b]) [NSFileManager.defaultManager removeItemAtPath:d error:nil];
            clearOurDefaults();      // nothing is left for the next run, or for the real app
        }
    }
    if (failures) { printf("%d float panel failure(s)\n", failures); return 1; }
    printf("all float panel tests passed\n");
    return 0;
}

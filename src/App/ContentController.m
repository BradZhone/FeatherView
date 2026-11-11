#import "ContentController.h"
#import "Localization.h"
#import "TextEditorView.h"
#import "PieceTable.h"
#import "Viewers.h"
#import "FileOps.h"
#import "TabBarView.h"
#import "MarkupView.h"
#import "PDFViewer.h"
#import "TablePreview.h"
#import "TreePreview.h"
#import "BinaryPreviews.h"
#import "JSONTree.h"
#import "DataPreviews.h"
#import "OfficeViews.h"
#include <sys/stat.h>

static const CGFloat kStatusH = 22, kFindH = 32, kTabH = 30;
static const NSUInteger kAutoSaveMaxBytes = 32u << 20;     // bigger files only save on focus change

@interface Doc : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) ViewerKind mode;
@property (nonatomic) BOOL preview, missing, changedOnDisk, wasDirty;
@property (nonatomic, strong) NSView *viewer;       // nil until first activation
@property (nonatomic, strong) TextEditorView *editor;   // text docs: kept while the tab is open
@property (nonatomic, strong) MarkupContainer *markup;  // .md / .html: editor + preview
@property (nonatomic, strong) NSView<FTSavable> *savable;  // a spreadsheet: its own edits, saved with ⌘S
@property (nonatomic) BOOL viewerIsQL, hasLayout;
@property (nonatomic) MarkupLayout layout;          // remembered across viewer reloads
@property (nonatomic, copy) NSString *status, *saveError;
@property (nonatomic) struct timespec mtime;
@property (nonatomic) off_t size;
@property (nonatomic) NSUInteger restoreLine, lastEdit;
@property (nonatomic, strong) NSTimer *saveTimer;
@property (nonatomic) BOOL untitled;                  // path is a backup file, title is "未命名-N"
@property (nonatomic) BOOL discarded;                 // the user chose "不保存"
@property (nonatomic, copy) NSString *title;
@end
@implementation Doc @end

static NSString *docName(Doc *d) { return d.untitled ? d.title : d.path.lastPathComponent; }

// An untitled tab counts as unsaved whenever it has text, even though its backup is up to date.
static BOOL untitledHasText(Doc *d) {
    if (d.editor) return d.editor.contentLength > 0;
    struct stat st;
    return stat(d.path.fileSystemRepresentation, &st) == 0 && st.st_size > 0;
}

static BOOL statPath(NSString *p, struct timespec *mt, off_t *sz) {
    struct stat st;
    if (stat(p.fileSystemRepresentation, &st) != 0) return NO;
    *mt = st.st_mtimespec; *sz = st.st_size;
    return YES;
}

static NSString *sizeString(off_t n) {
    return [NSByteCountFormatter stringFromByteCount:n countStyle:NSByteCountFormatterCountStyleFile];
}

@interface PaneView : NSView
@property (nonatomic) NSView *tabBar, *content, *findBar, *statusBar, *empty, *layoutSwitch;
@property (nonatomic) BOOL hasTabs, showsLayoutSwitch;
@end

@implementation PaneView
- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)old { [self layoutPane]; }
- (void)drawRect:(NSRect)r {
    if (!_showsLayoutSwitch || !_hasTabs) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSMakeRect(NSMaxX(_tabBar.frame), 0, self.bounds.size.width - NSMaxX(_tabBar.frame), kTabH));
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(NSMaxX(_tabBar.frame), kTabH - 1, self.bounds.size.width - NSMaxX(_tabBar.frame), 1));
}
- (void)layoutPane {
    NSRect b = self.bounds;
    _tabBar.hidden = _statusBar.hidden = _content.hidden = !_hasTabs;
    _empty.hidden = _hasTabs;
    _layoutSwitch.hidden = !(_hasTabs && _showsLayoutSwitch);
    if (!_hasTabs) { _findBar.hidden = YES; _empty.frame = b; return; }
    CGFloat y = kTabH, sw = _layoutSwitch.hidden ? 0 : _layoutSwitch.frame.size.width + 16;
    _tabBar.frame = NSMakeRect(0, 0, b.size.width - sw, kTabH);
    if (sw) _layoutSwitch.frame = (NSRect){{b.size.width - sw + 8, floor((kTabH - _layoutSwitch.frame.size.height) / 2)}, _layoutSwitch.frame.size};
    self.needsDisplay = YES;
    if (!_findBar.hidden) { _findBar.frame = NSMakeRect(0, y, b.size.width, kFindH); y += kFindH; }
    _statusBar.frame = NSMakeRect(0, b.size.height - kStatusH, b.size.width, kStatusH);
    _content.frame = NSMakeRect(0, y, b.size.width, MAX(0, b.size.height - y - kStatusH));
}
@end

// [查找____] [替换____] [替换] [全部替换] info
@interface FindBarView : NSView
@property (nonatomic) NSSearchField *find;
@property (nonatomic) NSTextField *replace, *info;
@property (nonatomic) NSButton *one, *all;
@property (nonatomic) BOOL findOnly;                 // PDF: no replace
@end

// Status text on the left, the active viewer's tool strip (zoom, pages…) on the right.
@interface StatusBarView : NSView
@property (nonatomic) NSTextField *label;
@property (nonatomic) NSView *tools;
@end

@implementation StatusBarView
- (BOOL)isFlipped { return YES; }
- (void)setTools:(NSView *)t {
    if (t == _tools) return;
    [_tools removeFromSuperview];
    _tools = t;
    if (t) { t.translatesAutoresizingMaskIntoConstraints = YES; [self addSubview:t]; }
    [self resizeSubviewsWithOldSize:self.bounds.size];
}
- (void)resizeSubviewsWithOldSize:(NSSize)old {
    NSRect b = self.bounds;
    CGFloat tw = _tools ? _tools.fittingSize.width : 0;
    if (tw > b.size.width - 160) tw = 0;               // too narrow: keep the status text, drop the tools
    _tools.hidden = tw == 0;
    if (tw) _tools.frame = NSMakeRect(b.size.width - tw - 4, 1, tw, b.size.height - 2);
    _label.frame = NSMakeRect(10, 3, MAX(0, b.size.width - 20 - (tw ? tw + 8 : 0)), 16);
}
@end

@implementation FindBarView
- (BOOL)isFlipped { return YES; }
- (void)setFindOnly:(BOOL)v {
    _findOnly = v;
    _replace.hidden = _one.hidden = _all.hidden = v;
    [self resizeSubviewsWithOldSize:self.bounds.size];
}
- (void)resizeSubviewsWithOldSize:(NSSize)old {
    if (_findOnly) {
        CGFloat w = self.bounds.size.width;
        _find.frame = NSMakeRect(8, 5, MIN(320, w - 120), 22);
        _info.frame = NSMakeRect(NSMaxX(_find.frame) + 8, 8, MAX(0, w - NSMaxX(_find.frame) - 16), 16);
        return;
    }
    CGFloat w = self.bounds.size.width, pad = 8;
    CGFloat btns = _one.frame.size.width + _all.frame.size.width + pad, infoW = 90;
    CGFloat fieldW = MAX(80, MIN(280, (w - btns - infoW - pad * 5) / 2));
    _find.frame = NSMakeRect(pad, 5, fieldW, 22);
    _replace.frame = NSMakeRect(NSMaxX(_find.frame) + pad, 5, fieldW, 22);
    CGFloat x = NSMaxX(_replace.frame) + pad;
    _one.frame = (NSRect){{x, 3}, _one.frame.size};
    _all.frame = (NSRect){{NSMaxX(_one.frame) + 4, 3}, _all.frame.size};
    _info.frame = NSMakeRect(NSMaxX(_all.frame) + pad, 8, MAX(0, w - NSMaxX(_all.frame) - 2 * pad), 16);
}
@end

@implementation ContentController {
    PaneView *_pane;
    TabBarView *_tabBar;
    FindBarView *_findBar;
    NSSearchField *_search;
    NSTextField *_replace;
    NSTextField *_status;
    StatusBarView *_statusBar;
    NSMutableArray<Doc *> *_docs;
    Doc *_active;
    NSMutableArray<NSString *> *_closed;
    BOOL _closingAll;
    NSUInteger _viewerLoads;                     // tests: how many viewers were built
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _docs = [NSMutableArray array];
    _closed = [NSMutableArray array];
    _previewEnabled = YES;
    _pane = [[PaneView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _pane.autoresizesSubviews = YES;
    FTClipToBounds(_pane);

    _tabBar = [[TabBarView alloc] initWithFrame:NSMakeRect(0, 0, 800, kTabH)];
    [self wireTabBar];

    FindBarView *find = [[FindBarView alloc] initWithFrame:NSMakeRect(0, 0, 800, kFindH)];
    _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _search.placeholderString = FTL(@"Find");
    _search.delegate = self;
    _search.sendsWholeSearchString = YES;
    _replace = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _replace.placeholderString = FTL(@"Replace with");
    _replace.delegate = self;
    NSButton *one = [NSButton buttonWithTitle:FTL(@"Replace") target:self action:@selector(replaceOne:)];
    NSButton *all = [NSButton buttonWithTitle:FTL(@"Replace All") target:self action:@selector(replaceAllAction:)];
    one.controlSize = all.controlSize = NSControlSizeSmall;
    one.font = all.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [one sizeToFit]; [all sizeToFit];
    NSTextField *info = [NSTextField labelWithString:@""];
    info.font = [NSFont systemFontOfSize:11];
    info.textColor = NSColor.secondaryLabelColor;
    find.find = _search; find.replace = _replace; find.one = one; find.all = all; find.info = info;
    for (NSView *v in @[_search, _replace, one, all, info]) [find addSubview:v];
    [find resizeSubviewsWithOldSize:find.bounds.size];
    find.hidden = YES;
    _findBar = find;

    StatusBarView *bar = [[StatusBarView alloc] initWithFrame:NSMakeRect(0, 0, 800, kStatusH)];
    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:11];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.frame = NSMakeRect(10, 3, 780, 16);
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [bar addSubview:_status];
    bar.label = _status;
    _statusBar = bar;

    NSArray *icons = @[@"doc.plaintext", @"rectangle.split.2x1", @"eye"];
    NSArray *tips = @[FTL(@"Source"), FTL(@"Side by Side (⌥⌘V)"), FTL(@"Preview (⇧⌘V)")];
    NSSegmentedControl *sw = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:icons[0] accessibilityDescription:tips[0]],
        [NSImage imageWithSystemSymbolName:icons[1] accessibilityDescription:tips[1]],
        [NSImage imageWithSystemSymbolName:icons[2] accessibilityDescription:tips[2]]]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(layoutSwitchChanged:)];
    sw.controlSize = NSControlSizeSmall;
    sw.segmentStyle = NSSegmentStyleTexturedRounded;
    for (NSInteger i = 0; i < 3; i++) [sw setToolTip:tips[i] forSegment:i];
    [sw sizeToFit];
    sw.hidden = YES;

    _autoSaveDelay = 1.0;
    _showsMinimap = YES;
    _pane.tabBar = _tabBar; _pane.findBar = find; _pane.statusBar = bar; _pane.layoutSwitch = sw;
    for (NSView *v in @[_tabBar, find, bar, sw]) [_pane addSubview:v];
    self.emptyView = [[NSView alloc] initWithFrame:NSZeroRect];
    return self;
}

- (void)setEmptyView:(NSView *)v {
    [_emptyView removeFromSuperview];
    _emptyView = v;
    _pane.empty = v;
    [_pane addSubview:v];
    [_pane layoutPane];
}

- (NSView *)view { return _pane; }
- (NSString *)currentPath { return _active.untitled ? nil : _active.path; }
- (NSString *)currentTitle { return _active ? docName(_active) : nil; }
- (BOOL)activeIsUntitled { return _active.untitled; }
- (TextEditorView *)editor { return _active.editor; }
- (NSArray<NSString *> *)openPaths { return [_docs valueForKey:@"path"]; }
- (NSUInteger)tabCount { return _docs.count; }
- (NSString *)statusText { return _status.stringValue; }
- (void)stateChanged { if (self.onStateChange) self.onStateChange(); }

static BOOL docDirty(Doc *d) { return d.untitled ? untitledHasText(d) : d.savable ? d.savable.isDirty : d.editor.isDirty; }

#pragma mark Markup layout

- (MarkupLayout)activeMarkupLayout { return _active.markup ? _active.markup.markupLayout : MarkupSource; }
- (BOOL)activeIsMarkup { return _active.markup != nil; }
- (MarkupKind)activeMarkupKind { return _active.markup.kind; }
- (BOOL)activeHasDataView {
    MarkupContainer *m = _active.markup;
    if (m && m.markupLayout != MarkupSource && (m.kind == MarkupTable || m.kind == MarkupJSON || m.kind == MarkupPlist)) return YES;
    return [_active.viewer isKindOfClass:TreePreview.class] || [_active.viewer isKindOfClass:SQLitePreview.class] || [_active.viewer isKindOfClass:ArchivePreview.class];
}

+ (NSString *)layoutKey:(MarkupKind)k {
    switch (k) {
        case MarkupHTML: return @"htmlLayout";
        case MarkupTable: return @"tableLayout";
        case MarkupJSON: return @"jsonLayout";
        case MarkupPlist: return @"plistLayout";
        case MarkupNotebook: return @"notebookLayout";
        default: return @"markdownLayout";
    }
}

// JSON and plists are usually edited, so they open as source; the rest open rendered.
+ (MarkupLayout)defaultLayout:(MarkupKind)k {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:[self layoutKey:k]];
    if (v) return (MarkupLayout)[v integerValue];
    return k == MarkupJSON || k == MarkupPlist ? MarkupSource : MarkupPreview;
}

- (void)setActiveMarkupLayout:(MarkupLayout)l {
    Doc *d = _active;
    if (!d.markup) return;
    d.markup.markupLayout = l;
    d.layout = l; d.hasLayout = YES;
    [NSUserDefaults.standardUserDefaults setInteger:l forKey:[ContentController layoutKey:d.markup.kind]];
    [self syncLayoutSwitch];
    [_pane.window makeFirstResponder:d.markup.focusView];
}

- (void)layoutSwitchChanged:(NSSegmentedControl *)s { [self setActiveMarkupLayout:(MarkupLayout)s.selectedSegment]; }

- (void)syncLayoutSwitch {
    NSSegmentedControl *sw = (NSSegmentedControl *)_pane.layoutSwitch;
    _pane.showsLayoutSwitch = _active.markup != nil;
    if (_active.markup) sw.selectedSegment = _active.markup.markupLayout;
    [_pane layoutPane];
}

- (void)setShowsMinimap:(BOOL)s {
    _showsMinimap = s;
    for (Doc *d in _docs) d.editor.showsMinimap = s;
}

- (void)redrawEditors { for (Doc *d in _docs) d.editor.needsDisplay = YES; }

- (void)setWordWrap:(BOOL)w {
    _wordWrap = w;
    for (Doc *d in _docs) d.editor.wordWrap = w;
}

- (void)setWorkspaceRoot:(NSString *)root {
    if (![root isEqualToString:_workspaceRoot]) [_closed removeAllObjects];    // Reopen Closed Tab stays in its workspace
    _workspaceRoot = [root copy];
    for (Doc *d in _docs) d.markup.root = root;
}

- (NSUInteger)dirtyCount {
    NSUInteger n = 0;
    for (Doc *d in _docs) if (docDirty(d)) n++;
    return n;
}

- (Doc *)docForPath:(NSString *)p {
    if (!p) return nil;
    for (Doc *d in _docs) if ([d.path isEqualToString:p]) return d;
    return nil;
}

#pragma mark Viewers

- (NSView *)placeholder:(NSString *)msg {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    NSTextField *l = [NSTextField labelWithString:msg];
    l.textColor = NSColor.tertiaryLabelColor;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:l];
    [NSLayoutConstraint activateConstraints:@[[l.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
                                              [l.centerYAnchor constraintEqualToAnchor:v.centerYAnchor]]];
    return v;
}

- (NSUInteger)viewerLoads { return _viewerLoads; }

- (void)loadViewer:(Doc *)d {
    _viewerLoads++;
    struct timespec mt = {0}; off_t sz = 0;
    d.missing = !statPath(d.path, &mt, &sz);
    if (d.missing) { d.viewer = [self placeholder:FTL(@"The file no longer exists")]; d.status = FTL(@"Deleted"); return; }
    d.mtime = mt; d.size = sz; d.changedOnDisk = NO;
    ViewerKind k = d.mode == ViewerAuto ? FKGuessKind(d.path) : d.mode;
    switch (k) {
        case ViewerTree:      [self loadPlistTree:d]; break;
        case ViewerSQLite:    [self loadSQLite:d]; break;
        case ViewerArchive:   [self loadArchive:d]; break;
        case ViewerSpreadsheet: [self loadSpreadsheet:d]; break;
        case ViewerDocument:  [self loadDocument:d]; break;
        case ViewerImage:     [self loadImage:d]; break;
        case ViewerQuickLook: [self loadQuickLook:d]; break;
        case ViewerPDF:       [self loadPDF:d]; break;
        case ViewerHex:       [self loadHex:d]; break;
        default:              [self loadText:d]; break;
    }
}

- (void)loadText:(Doc *)d {
    NSStringEncoding enc = NSUTF8StringEncoding;
    NSString *err = nil;
    NSData *data = FKLoadTextAllowingNUL(d.path, &enc, d.untitled || d.mode == ViewerText, &err);
    if (!data) { [self loadHex:d]; return; }
    TextEditorView *ed = [[TextEditorView alloc] initWithFrame:NSZeroRect buffer:[[PieceTable alloc] initWithData:data]
                                                          path:d.path encoding:enc];
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    __weak TextEditorView *weakEd = ed;
    d.lastEdit = ed.editCount;
    ed.showsMinimap = _showsMinimap;
    ed.wordWrap = _wordWrap;
    ed.onChange = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc; TextEditorView *e = weakEd;
        if (!me || !doc || !e) return;
        BOOL dirty = e.isDirty;
        NSString *warn = doc.saveError ? [@"   ⚠️ " stringByAppendingString:doc.saveError]
                       : doc.changedOnDisk ? FTL(@"   ⚠️ Changed on disk") : @"";
        doc.status = doc.untitled ? [NSString stringWithFormat:FTL(@"%@   New document · ⌘S to choose where to save%@"), e.statusText, warn]
                                  : [NSString stringWithFormat:@"%@   %@%@", e.statusText, sizeString(doc.size), warn];
        if (doc == me->_active) me->_status.stringValue = doc.status;
        if (e.editCount != doc.lastEdit) {             // content changed (not just the caret)
            doc.lastEdit = e.editCount;
            [doc.markup textChanged];
            [me scheduleAutoSave:doc];
        }
        if (dirty != doc.wasDirty || (dirty && doc.preview)) {
            doc.wasDirty = dirty;
            if (dirty) doc.preview = NO;               // editing keeps the tab
            [me reloadTabs];
            [me stateChanged];
        }
    };
    d.editor = ed;
    d.viewer = ed;
    MarkupKind mk = d.mode == ViewerAuto ? FKMarkupKind(d.path) : MarkupNone;
    if (mk != MarkupNone) {
        MarkupContainer *mc = [[MarkupContainer alloc] initWithEditor:ed kind:mk path:d.path root:_workspaceRoot];
        mc.onOpenFile = ^(NSString *p, NSString *anchor) { [weakSelf openLinkedFile:p anchor:anchor]; };
        mc.onMessage = ^(NSString *msg) { [weakSelf flashStatus:msg]; };
        mc.onLayoutChange = ^(MarkupLayout l) {
            ContentController *me = weakSelf; Doc *doc = weakDoc;
            if (!me || !doc) return;
            doc.layout = l; doc.hasLayout = YES;
            [me syncLayoutSwitch];
        };
        ed.onScroll = ^{ [weakDoc.markup editorScrolled]; };
        d.markup = mc;
        d.viewer = mc;
        mc.markupLayout = d.hasLayout ? d.layout : (data.length ? [ContentController defaultLayout:mk] : MarkupSource);
    }
    ed.onChange();
}

// A link always opens its own tab; the tab it was clicked in is kept (a preview tab gets pinned).
- (void)openLinkedFile:(NSString *)p anchor:(NSString *)anchor {
    if (_active.preview) { _active.preview = NO; [self reloadTabs]; }
    Doc *d = [self openPath:p mode:ViewerAuto preview:NO focus:YES];
    if (anchor.length) [d.markup.markdownView scrollToAnchor:anchor];
}

// Temporary message in the status bar; the normal status comes back on the next change.
- (void)flashStatus:(NSString *)msg {
    _status.stringValue = [@"⚠️ " stringByAppendingString:msg];
    NSString *shown = _status.stringValue;
    __weak ContentController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ContentController *me = weakSelf;
        if (me && [me->_status.stringValue isEqualToString:shown]) me->_status.stringValue = me->_active.status ?: @"";
    });
}

- (void)loadHex:(Doc *)d {
    NSString *err = nil;
    NSData *data = FKLoadRaw(d.path, &err);
    if (!data) { d.viewer = [self placeholder:err ?: FTL(@"Couldn’t read the file")]; d.status = @""; return; }
    d.viewer = [[HexView alloc] initWithFrame:NSZeroRect data:data];
    d.status = [NSString stringWithFormat:FTL(@"Hex (read-only)   %@"), sizeString(d.size)];
}

- (void)loadImage:(Doc *)d {
    ImagePreviewView *iv = [[ImagePreviewView alloc] initWithFrame:NSZeroRect path:d.path];
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    __weak ImagePreviewView *weakIv = iv;
    iv.onChange = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc;
        if (!me || !doc) return;
        doc.status = [NSString stringWithFormat:@"%@   %@", weakIv.info, sizeString(doc.size)];
        if (doc == me->_active) me->_status.stringValue = doc.status;
    };
    iv.onFailure = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc;
        if (!me || !doc || doc.viewer != weakIv) return;
        doc.mode = weakIv.isVector ? ViewerText : ViewerQuickLook;     // broken SVG: show its source
        [me reloadViewerOf:doc];
    };
    d.viewer = iv;
    iv.onChange();
}

- (void)loadPDF:(Doc *)d {
    PDFPreview *pv = [[PDFPreview alloc] initWithFrame:NSZeroRect path:d.path];
    if (!pv) { [self loadQuickLook:d]; return; }
    while (pv.isLocked) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:FTL(@"“%@” is encrypted"), d.path.lastPathComponent];
        a.informativeText = FTL(@"Enter the password to open it.");
        NSSecureTextField *f = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
        a.accessoryView = f;
        a.window.initialFirstResponder = f;
        [a addButtonWithTitle:FTL(@"Open")];
        [a addButtonWithTitle:FTL(@"Cancel")];
        if ([self runAlert:a] != NSAlertFirstButtonReturn) { d.viewer = [self placeholder:FTL(@"Encrypted PDF, no password entered")]; d.status = @""; return; }
        if (![pv unlock:f.stringValue]) NSBeep();
    }
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    __weak PDFPreview *weakPv = pv;
    pv.onChange = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc;
        if (!me || !doc) return;
        doc.status = [NSString stringWithFormat:@"%@   %@", weakPv.info, sizeString(doc.size)];
        if (doc == me->_active) me->_status.stringValue = doc.status;
    };
    pv.onOpenFile = ^(NSString *p) { [weakSelf openLinkedFile:p anchor:nil]; };
    pv.showsThumbnails = [NSUserDefaults.standardUserDefaults boolForKey:@"pdfThumbnails"];
    d.viewer = pv;
    pv.onChange();
}

// Binary property list: no text to edit, only the tree.
- (void)loadPlistTree:(Doc *)d {
    NSData *data = [NSData dataWithContentsOfFile:d.path options:NSDataReadingMappedIfSafe error:nil];
    id obj = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if (!obj) { [self loadHex:d]; return; }
    TreePreview *t = [[TreePreview alloc] initWithFrame:NSZeroRect];
    [t setRoot:JSONFromPropertyList(obj)];
    d.viewer = t;
    d.status = [NSString stringWithFormat:FTL(@"Binary property list (read-only)   %@"), sizeString(d.size)];
}

- (void)loadSQLite:(Doc *)d {
    SQLitePreview *v = [[SQLitePreview alloc] initWithFrame:NSZeroRect path:d.path];
    if (!v) { [self loadHex:d]; return; }
    d.viewer = v;
    d.status = v.status;
}

- (void)loadArchive:(Doc *)d {
    ArchivePreview *v = [[ArchivePreview alloc] initWithFrame:NSZeroRect path:d.path];
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    __weak ArchivePreview *weakV = v;
    v.onOpenFile = ^(NSString *p) { [weakSelf openPath:p preview:NO focus:YES]; };
    v.onMessage = ^(NSString *m) { [weakSelf flashStatus:m]; };
    v.onChange = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc;
        if (!me || !doc) return;
        doc.status = weakV.status;
        if (doc == me->_active) me->_status.stringValue = doc.status;
    };
    d.viewer = v;
    d.status = v.status;
}

- (void)loadSpreadsheet:(Doc *)d {
    NSString *err = nil;
    SpreadsheetPreview *v = [[SpreadsheetPreview alloc] initWithFrame:NSZeroRect path:d.path error:&err];
    if (!v) { [self loadQuickLook:d]; if (err) d.status = [NSString stringWithFormat:@"%@   ⚠️ %@", d.status, err]; return; }
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    v.onMessage = ^(NSString *m) { [weakSelf flashStatus:m]; };
    v.onChange = ^{ [weakSelf savableChanged:weakDoc]; };
    d.viewer = v;
    d.savable = v;
    d.status = v.status;
}

- (void)loadDocument:(Doc *)d {
    DocumentPreview *v = [[DocumentPreview alloc] initWithFrame:NSZeroRect path:d.path];
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    __weak DocumentPreview *weakV = v;
    v.onChange = ^{
        ContentController *me = weakSelf; Doc *doc = weakDoc;
        if (!me || !doc) return;
        doc.status = [NSString stringWithFormat:@"%@   %@", weakV.status, sizeString(doc.size)];
        if (doc == me->_active) me->_status.stringValue = doc.status;
    };
    d.viewer = v;
    d.status = [NSString stringWithFormat:@"%@   %@", v.status, sizeString(d.size)];
}

- (void)savableChanged:(Doc *)d {
    if (!d) return;
    BOOL dirty = d.savable.isDirty;
    NSString *warn = d.saveError ? [@"   ⚠️ " stringByAppendingString:d.saveError] : d.changedOnDisk ? FTL(@"   ⚠️ Changed on disk") : @"";
    d.status = [NSString stringWithFormat:@"%@   %@%@", d.savable.status, sizeString(d.size), warn];
    if (d == _active) _status.stringValue = d.status;
    if (dirty != d.wasDirty) {
        d.wasDirty = dirty;
        if (dirty) d.preview = NO;
        [self reloadTabs];
        [self stateChanged];
    }
}

- (BOOL)activeIsDirty { return _active && docDirty(_active); }

- (void)loadQuickLook:(Doc *)d {
    NSView *ql = FKCreateQuickLookView(NSZeroRect, d.path);
    if (!ql) { [self loadText:d]; return; }
    d.viewer = ql;
    d.viewerIsQL = YES;
    d.status = [NSString stringWithFormat:FTL(@"Quick Look   %@"), sizeString(d.size)];
}

- (void)releaseViewer:(Doc *)d {
    if (d.viewerIsQL) FKCloseQuickLookView(d.viewer);
    if (d.markup) { d.layout = d.markup.markupLayout; d.hasLayout = YES; [d.markup releasePreview]; }
    [d.saveTimer invalidate];
    d.saveTimer = nil;
    [d.viewer removeFromSuperview];
    d.viewer = nil;
    d.editor = nil;
    d.markup = nil;
    d.savable = nil;
    d.viewerIsQL = NO;
}

- (void)reloadViewerOf:(Doc *)d {
    TextEditorView *old = d.editor;
    NSUInteger line = old ? old.caretLine : 0;
    [self releaseViewer:d];
    d.restoreLine = line;
    if (d == _active) [self installActive:NO];
    [self reloadTabs];
}

// Puts the active doc's viewer into the pane, creating it if needed.
- (void)installActive:(BOOL)focus {
    Doc *d = _active;
    if (d && !d.viewer) [self loadViewer:d];
    NSView *v = d.viewer;
    if (_pane.content != v) {
        if (_pane.content && _pane.content != v) [_pane.content removeFromSuperview];
        _pane.content = v;
        if (v) [_pane addSubview:v positioned:NSWindowBelow relativeTo:_findBar];
    }
    _pane.hasTabs = _docs.count > 0;
    [self syncLayoutSwitch];
    [d.markup ensurePreview];
    _status.stringValue = d.status ?: @"";
    _statusBar.tools = [v conformsToProtocol:@protocol(FTZoomable)] ? [(id<FTZoomable>)v toolsView] : nil;
    _findBar.findOnly = !d.editor;                         // PDF, workbook, document: find without replace
    TextEditorView *ed = self.editor;
    if (ed && d.restoreLine) { [ed gotoLine:d.restoreLine]; d.restoreLine = 0; [d.markup editorScrolled]; }
    NSView *fv = d.markup ? d.markup.focusView : [v conformsToProtocol:@protocol(FTZoomable)] ? [(id<FTZoomable>)v focusView] : v;
    if (focus && fv) [_pane.window makeFirstResponder:fv];
}

#pragma mark Zoom / pages

- (PDFPreview *)activePDF { return [_active.viewer isKindOfClass:PDFPreview.class] ? (PDFPreview *)_active.viewer : nil; }
- (ImagePreviewView *)activeImage { return [_active.viewer isKindOfClass:ImagePreviewView.class] ? (ImagePreviewView *)_active.viewer : nil; }
- (BOOL)activeCanRotate { return self.activePDF || self.activeImage; }
- (NSUInteger)activePageCount { return self.activePDF.pageCount; }

// Which kind of zoom applies right now: the image / PDF itself, the rendered preview, or the editor font.
- (NSInteger)zoomTarget {
    if ([_active.viewer conformsToProtocol:@protocol(FTZoomable)]) return 1;
    if ([_active.viewer isKindOfClass:TreePreview.class] || [_active.viewer isKindOfClass:SQLitePreview.class] ||
        [_active.viewer isKindOfClass:ArchivePreview.class]) return 5;
    MarkupContainer *m = _active.markup;
    if (m && m.markupLayout != MarkupSource) {
        NSResponder *fr = _pane.window.firstResponder;
        BOOL inEditor = m.markupLayout == MarkupSplit && [fr isKindOfClass:NSView.class] && [(NSView *)fr isDescendantOf:m.editor];
        if (!inEditor) {
            if (m.kind == MarkupHTML) return 3;
            if (m.kind == MarkupTable || m.kind == MarkupJSON || m.kind == MarkupPlist) return 5;
            return 2;
        }
    }
    return _active.editor ? 4 : 0;
}
- (BOOL)canZoom { return self.zoomTarget != 0; }

- (void)zoomBy:(NSInteger)dir {
    id<FTZoomable> z = (id<FTZoomable>)_active.viewer;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    switch (self.zoomTarget) {
        case 1: dir > 0 ? [z ftZoomIn] : dir < 0 ? [z ftZoomOut] : [z ftZoomToFit]; break;
        case 2: {
            CGFloat s = dir ? MarkdownPreview.defaultScale + dir * 0.1 : 1;
            MarkdownPreview.defaultScale = s;
            [ud setDouble:MarkdownPreview.defaultScale forKey:@"markdownScale"];
            for (Doc *d in _docs) d.markup.markdownView.scale = MarkdownPreview.defaultScale;
            [self flashStatus:[NSString stringWithFormat:FTL(@"Preview zoom %.0f%%"), MarkdownPreview.defaultScale * 100]];
            break;
        }
        case 3: {
            CGFloat s = dir ? HTMLPreview.defaultZoom * (dir > 0 ? 1.1 : 1 / 1.1) : 1;
            HTMLPreview.defaultZoom = s;
            [ud setDouble:HTMLPreview.defaultZoom forKey:@"htmlZoom"];
            for (Doc *d in _docs) d.markup.htmlView.zoom = HTMLPreview.defaultZoom;
            [self flashStatus:[NSString stringWithFormat:FTL(@"Page zoom %.0f%%"), HTMLPreview.defaultZoom * 100]];
            break;
        }
        case 5: {
            FTSetDataFontSize(dir ? FTDataFontSize() + dir : 12);
            [ud setDouble:FTDataFontSize() forKey:@"dataFontSize"];
            [self flashStatus:[NSString stringWithFormat:FTL(@"Table font size %.0f"), FTDataFontSize()]];
            break;
        }
        case 4: {
            CGFloat s = dir ? TextEditorView.defaultFontSize + dir : 13;
            TextEditorView.defaultFontSize = s;
            [ud setDouble:TextEditorView.defaultFontSize forKey:@"editorFontSize"];
            for (Doc *d in _docs) d.editor.fontSize = TextEditorView.defaultFontSize;
            [self flashStatus:[NSString stringWithFormat:FTL(@"Editor font size %.0f"), TextEditorView.defaultFontSize]];
            break;
        }
    }
}

- (void)zoomIn { [self zoomBy:1]; }
- (void)zoomOut { [self zoomBy:-1]; }
- (void)zoomReset { [self zoomBy:0]; }
- (void)zoomActualSize { if (self.zoomTarget == 1) [(id<FTZoomable>)_active.viewer ftZoomActualSize]; else [self zoomReset]; }
- (void)rotate:(NSInteger)q { if (self.activeCanRotate) [(id<FTZoomable>)_active.viewer ftRotate:q]; }
- (void)goToPage:(NSUInteger)i { [self.activePDF goToPage:i]; }

- (void)togglePDFThumbnails {
    PDFPreview *p = self.activePDF;
    if (!p) return;
    p.showsThumbnails = !p.showsThumbnails;
    [NSUserDefaults.standardUserDefaults setBool:p.showsThumbnails forKey:@"pdfThumbnails"];
}
- (void)togglePDFTwoPages { self.activePDF.twoPages = !self.activePDF.twoPages; }
- (void)openInDefaultApp { if (self.currentPath) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.currentPath]]; }

#pragma mark Tabs

- (void)reloadTabs {
    NSCountedSet *names = [NSCountedSet set];
    for (Doc *d in _docs) [names addObject:docName(d)];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:_docs.count];
    for (Doc *d in _docs) {
        TabItem *t = [TabItem new];
        t.title = docName(d);
        if (!d.untitled && [names countForObject:t.title] > 1) t.subtitle = d.path.stringByDeletingLastPathComponent.lastPathComponent;
        t.dirty = docDirty(d);
        t.preview = d.preview;
        t.missing = d.missing;
        t.toolTip = d.untitled ? FTL(@"New document (⌘S to choose where to save)") : [d.path stringByAbbreviatingWithTildeInPath];
        [items addObject:t];
    }
    _tabBar.items = items;
    _tabBar.selectedIndex = _active ? (NSInteger)[_docs indexOfObject:_active] : -1;
    [_tabBar reload];
}

- (void)activate:(Doc *)d focus:(BOOL)focus {
    Doc *prev = _active;
    if (prev != d && prev && [_docs containsObject:prev]) {
        if (_autoSaveMode != AutoSaveOff || prev.untitled) [self autoSave:prev];   // leaving a file saves it
        if (prev.markup) [prev.markup releasePreview];                 // keep the editor, drop the preview
        else if (!prev.editor && !(prev.savable && prev.savable.isDirty)) [self releaseViewer:prev];   // keep unsaved cells
    }
    _active = d;
    [self installActive:focus];
    [self reloadTabs];
    [self stateChanged];
    if (self.onActivate) self.onActivate(d.untitled ? nil : d.path);
}

- (void)openPath:(NSString *)path preview:(BOOL)preview focus:(BOOL)focus {
    [self openPath:path mode:ViewerAuto preview:preview focus:focus];
}

// Opens with an explicit layout for this tab only (e.g. a new .md file starts in the editor).
- (void)openPath:(NSString *)path preview:(BOOL)preview focus:(BOOL)focus layout:(MarkupLayout)layout {
    Doc *d = [self openPath:path mode:ViewerAuto preview:preview focus:NO];
    if (d.markup) { d.markup.markupLayout = layout; d.layout = layout; d.hasLayout = YES; [self syncLayoutSwitch]; }
    if (focus) [_pane.window makeFirstResponder:d.markup ? d.markup.focusView : d.viewer];
}

- (void)findInPreview {
    if ([_active.markup focusPreviewFilter]) return;
    if ([_active.viewer respondsToSelector:@selector(focusFilter)]) { [(id)_active.viewer focusFilter]; return; }
    if ([_active.viewer isKindOfClass:SQLitePreview.class]) { [[(SQLitePreview *)_active.viewer grid] focusFilter]; return; }
    if ([_active.viewer isKindOfClass:ArchivePreview.class]) { [[(ArchivePreview *)_active.viewer grid] focusFilter]; return; }
    MarkdownPreview *m = _active.markup.markdownView;
    if (!m) { NSBeep(); return; }
    NSMenuItem *it = [NSMenuItem new];
    it.tag = NSTextFinderActionShowFindInterface;
    [_pane.window makeFirstResponder:m.textView];
    [m.textView performTextFinderAction:it];
}

- (Doc *)openPath:(NSString *)path mode:(ViewerKind)mode preview:(BOOL)preview focus:(BOOL)focus {
    if (!path.length) return nil;
    if (!path.isAbsolutePath)
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    path = path.stringByStandardizingPath;
    BOOL isDir = NO;
    if (!path || ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir] && isDir)) return nil;
    if (!_previewEnabled) preview = NO;
    Doc *d = [self docForPath:path];
    if (d) {
        if (!preview) d.preview = NO;
        if (mode != ViewerAuto && mode != d.mode && !docDirty(d)) { d.mode = mode; [self releaseViewer:d]; }
        [self activate:d focus:focus];
        return d;
    }
    Doc *reuse = nil;
    if (preview) for (Doc *x in _docs) if (x.preview && !x.untitled && !docDirty(x)) { reuse = x; break; }
    if (reuse) {
        [self releaseViewer:reuse];
        reuse.path = path; reuse.mode = mode; reuse.missing = NO; reuse.status = nil;
        reuse.hasLayout = NO; reuse.saveError = nil; reuse.restoreLine = 0;
        d = reuse;
    } else {
        d = [Doc new];
        d.path = path; d.mode = mode; d.preview = preview;
        NSUInteger at = _active ? [_docs indexOfObject:_active] + 1 : _docs.count;
        [_docs insertObject:d atIndex:MIN(at, _docs.count)];
    }
    [self activate:d focus:focus];
    return d;
}

- (void)reopenActiveAs:(ViewerKind)mode {
    Doc *d = _active;
    if (!d || ![self askSave:d]) return;
    d.mode = mode;
    [self releaseViewer:d];
    [self installActive:YES];
    [self reloadTabs];
}

- (void)pinActive { if (_active.preview) { _active.preview = NO; [self reloadTabs]; } }

- (NSModalResponse)runAlert:(NSAlert *)a { return self.alertHandler ? self.alertHandler(a) : [a runModal]; }

// YES = go ahead (saved or discarded). Activates the tab so the user sees what they're asked about.
- (BOOL)askSave:(Doc *)d {
    if (!docDirty(d)) return YES;
    if (!d.untitled && _autoSaveMode != AutoSaveOff && [self autoSave:d]) return YES;   // only ask when auto-save could not save
    if (d != _active) [self activate:d focus:NO];
    NSAlert *a = [NSAlert new];
    a.messageText = d.untitled ? [NSString stringWithFormat:FTL(@"Save “%@”?"), d.title]
                               : [NSString stringWithFormat:FTL(@"“%@” has unsaved changes"), d.path.lastPathComponent];
    a.informativeText = d.untitled ? FTL(@"This document has never been saved. Its contents will be lost if you don’t save it.") : FTL(@"Your changes will be lost if you don’t save them.");
    [a addButtonWithTitle:d.untitled ? FTL(@"Save…") : FTL(@"Save")];
    [a addButtonWithTitle:FTL(@"Cancel")];
    [a addButtonWithTitle:FTL(@"Don’t Save")];
    NSModalResponse r = [self runAlert:a];
    if (r == NSAlertFirstButtonReturn) return [self saveDoc:d];
    if (r == NSAlertThirdButtonReturn) { d.discarded = YES; return YES; }
    return NO;
}

// ask: the user is closing this tab (an untitled one's backup goes too). NO: internal close — switching
// workspace, restoring a session, closing the window — untitled backups are kept for next time.
- (BOOL)closeDoc:(Doc *)d ask:(BOOL)ask {
    if (ask && ![self askSave:d]) return NO;
    NSUInteger i = [_docs indexOfObject:d];
    if (i == NSNotFound) return YES;
    BOOL hadFocus = [_pane.window.firstResponder isKindOfClass:NSView.class] &&
                    [(NSView *)_pane.window.firstResponder isDescendantOf:_pane];
    if (d.untitled && !ask && !d.discarded) [self autoSave:d];          // keep the latest text
    if (!d.untitled) {
        [_closed addObject:d.path];
        if (_closed.count > 30) [_closed removeObjectAtIndex:0];
    }
    [_docs removeObjectAtIndex:i];
    if (_pane.content && _pane.content == d.viewer) _pane.content = nil;
    [self releaseViewer:d];
    if (d.untitled && (ask || d.discarded)) [NSFileManager.defaultManager removeItemAtPath:d.path error:nil];
    if (d == _active) {
        _active = nil;
        if (_closingAll) return YES;                   // the next tab isn't loaded just to be closed too
        if (_docs.count) { [self activate:_docs[MIN(i, _docs.count - 1)] focus:hadFocus]; return YES; }
        [self installActive:NO];
        if (self.onActivate) self.onActivate(nil);
    }
    [self reloadTabs];
    [self stateChanged];
    return YES;
}

- (BOOL)closeActive { return _active ? [self closeDoc:_active ask:YES] : NO; }

- (BOOL)closeOthers {
    Doc *keep = _active;
    for (Doc *d in _docs.copy) if (d != keep && ![self closeDoc:d ask:YES]) return NO;
    if (keep) [self activate:keep focus:NO];
    return YES;
}

- (BOOL)closeRightOf:(Doc *)keep {
    NSUInteger i = [_docs indexOfObject:keep];
    if (i == NSNotFound) return YES;
    for (Doc *d in [_docs subarrayWithRange:NSMakeRange(i + 1, _docs.count - i - 1)]) if (![self closeDoc:d ask:YES]) return NO;
    return YES;
}

- (void)finishClosingAll {
    _closingAll = NO;
    if (_docs.count) { [self activate:_docs.firstObject focus:NO]; return; }
    [self installActive:NO];
    if (self.onActivate) self.onActivate(nil);
    [self reloadTabs];
    [self stateChanged];
}

- (BOOL)closeAll {
    if (![self confirmClose:YES]) return NO;
    _closingAll = YES;
    for (Doc *d in _docs.copy) {
        if (d.untitled && !docDirty(d)) d.discarded = YES;              // empty untitled tabs just go
        [self closeDoc:d ask:NO];
    }
    [self finishClosingAll];
    return YES;
}

- (void)closeAllWithoutAsking {
    _closingAll = YES;
    for (Doc *d in _docs.copy) [self closeDoc:d ask:NO];
    [self finishClosingAll];
}

- (BOOL)closePathsWithin:(NSString *)path {
    for (Doc *d in _docs.copy) if (!d.untitled && FOPathIsWithin(d.path, path) && ![self closeDoc:d ask:YES]) return NO;
    return YES;
}

- (BOOL)confirmCloseAll { return [self confirmClose:NO]; }

// One question for every unsaved tab. untitled: include untitled documents (closing the tabs) or not
// (switching workspace / quitting, where they are kept). "不保存" marks untitled ones for deletion.
- (BOOL)confirmClose:(BOOL)untitled {
    [self flushAutoSave];
    [self backupUntitled];
    NSMutableArray<Doc *> *dirty = [NSMutableArray array];
    for (Doc *d in _docs) if (docDirty(d) && (untitled || !d.untitled)) [dirty addObject:d];
    if (!dirty.count) return YES;
    if (dirty.count == 1) return [self askSave:dirty[0]];
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:FTL(@"%lu files have unsaved changes"), (unsigned long)dirty.count];
    NSMutableArray *names = [NSMutableArray array];
    for (Doc *d in dirty) [names addObject:docName(d)];
    a.informativeText = [names componentsJoinedByString:FTL(@", ")];
    [a addButtonWithTitle:FTL(@"Save All")];
    [a addButtonWithTitle:FTL(@"Cancel")];
    [a addButtonWithTitle:FTL(@"Don’t Save")];
    NSModalResponse r = [self runAlert:a];
    if (r == NSAlertFirstButtonReturn) { for (Doc *d in dirty) if (![self saveDoc:d]) return NO; return YES; }
    if (r == NSAlertThirdButtonReturn) { for (Doc *d in dirty) d.discarded = YES; return YES; }
    return NO;
}

- (void)selectTabOffset:(NSInteger)delta {
    if (_docs.count < 2 || !_active) return;
    NSInteger i = ((NSInteger)[_docs indexOfObject:_active] + delta) % (NSInteger)_docs.count;
    if (i < 0) i += _docs.count;
    [self activate:_docs[i] focus:YES];
}

- (void)selectTabAtIndex:(NSInteger)i {
    if (!_docs.count) return;
    if (i < 0 || i >= (NSInteger)_docs.count) i = _docs.count - 1;
    [self activate:_docs[i] focus:YES];
}

- (BOOL)reopenClosed {
    while (_closed.count) {
        NSString *p = _closed.lastObject;
        [_closed removeLastObject];
        if ([NSFileManager.defaultManager fileExistsAtPath:p] && ![self docForPath:p]) {
            [self openPath:p preview:NO focus:YES];
            return YES;
        }
    }
    return NO;
}

#pragma mark Session / disk

- (NSDictionary *)sessionState {
    NSMutableArray *tabs = [NSMutableArray array];
    for (Doc *d in _docs) {
        NSUInteger line = d.editor ? d.editor.caretLine : d.restoreLine;
        if (d.untitled) [tabs addObject:@{@"path": d.path, @"untitled": d.title, @"line": @(line)}];
        else [tabs addObject:@{@"path": d.path, @"preview": @(d.preview), @"line": @(line)}];
    }
    NSUInteger ai = _active ? [_docs indexOfObject:_active] : 0;
    return @{@"tabs": tabs, @"active": @(ai)};
}

- (void)restoreSession:(NSDictionary *)state {
    [self closeAllWithoutAsking];
    [_closed removeAllObjects];
    NSArray *tabs = [state[@"tabs"] isKindOfClass:NSArray.class] ? state[@"tabs"] : @[];
    NSUInteger want = [state[@"active"] unsignedIntegerValue], idx = 0;
    Doc *activeDoc = nil;
    for (NSDictionary *t in tabs) {
        NSString *p = [t isKindOfClass:NSDictionary.class] ? t[@"path"] : nil;
        BOOL isDir = NO;
        BOOL exists = [p isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&isDir];
        if (exists && !isDir && ![self docForPath:p]) {
            Doc *d = [Doc new];
            d.path = p;
            NSString *title = [t[@"untitled"] isKindOfClass:NSString.class] ? t[@"untitled"] : nil;
            if (title) { d.untitled = YES; d.title = title; d.mode = ViewerText; }
            d.preview = !title && [t[@"preview"] boolValue] && _previewEnabled;
            d.restoreLine = [t[@"line"] unsignedIntegerValue];
            [_docs addObject:d];
            if (idx == want || !activeDoc) activeDoc = d;
        }
        idx++;
    }
    if (activeDoc) [self activate:activeDoc focus:NO];        // only the active tab is loaded
    else { [self installActive:NO]; [self reloadTabs]; }
}

- (void)checkExternalChanges {
    BOOL changed = NO;
    for (Doc *d in _docs.copy) {
        if (!d.viewer || d.untitled) continue;                 // not loaded: read fresh on activation; backups are ours
        struct timespec mt; off_t sz;
        BOOL exists = statPath(d.path, &mt, &sz);
        if (!exists) { if (!d.missing) { d.missing = YES; changed = YES; } continue; }
        if (d.missing) { d.missing = NO; changed = YES; }
        if (mt.tv_sec == d.mtime.tv_sec && mt.tv_nsec == d.mtime.tv_nsec && sz == d.size) continue;
        if (docDirty(d)) {
            if (!d.changedOnDisk) { d.changedOnDisk = YES; if (d.editor) d.editor.onChange(); else [self savableChanged:d]; }
            continue;
        }
        [self reloadViewerOf:d];
        changed = YES;
    }
    if (changed) [self reloadTabs];
}

- (BOOL)diskChanged:(Doc *)d {
    struct timespec mt; off_t sz;
    return !d.missing && statPath(d.path, &mt, &sz) && (mt.tv_sec != d.mtime.tv_sec || mt.tv_nsec != d.mtime.tv_nsec || sz != d.size);
}

- (void)didSave:(Doc *)d {
    struct timespec mt; off_t sz;
    if (statPath(d.path, &mt, &sz)) { d.mtime = mt; d.size = sz; }
    d.missing = NO; d.changedOnDisk = NO; d.saveError = nil;
    [d.saveTimer invalidate];
    d.saveTimer = nil;
    if (d.editor) d.editor.onChange();
    if (d.savable) [self savableChanged:d];
    [d.markup didSave];
    [self reloadTabs];
    [self stateChanged];
}

#pragma mark Auto-save

- (void)scheduleAutoSave:(Doc *)d {
    [d.saveTimer invalidate];
    d.saveTimer = nil;
    BOOL wanted = d.untitled ? d.editor.isDirty : (_autoSaveMode == AutoSaveAfterDelay && docDirty(d));   // untitled: always back up
    if (!wanted || d.editor.contentLength > kAutoSaveMaxBytes) return;
    __weak ContentController *weakSelf = self;
    __weak Doc *weakDoc = d;
    NSTimeInterval delay = d.untitled && _autoSaveMode != AutoSaveAfterDelay ? 1.0 : _autoSaveDelay;
    d.saveTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.05, delay) repeats:NO block:^(NSTimer *t) {
        Doc *doc = weakDoc;
        if (doc) [weakSelf autoSave:doc];
    }];
}

// Silent save. Never prompts: problems are shown in the status bar and the file stays unsaved.
- (BOOL)autoSave:(Doc *)d {
    [d.saveTimer invalidate];
    d.saveTimer = nil;
    if (d.savable) return !d.savable.isDirty;                              // a workbook is only written by ⌘S
    TextEditorView *ed = d.editor;
    if (!ed.isDirty) return YES;
    if (ed.isComposing) { [self scheduleAutoSave:d]; return NO; }          // wait for the IME
    if (d.untitled) {                                                       // the backup, not a user file
        NSString *err = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:d.path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![NSFileManager.defaultManager fileExistsAtPath:d.path]) [NSData.data writeToFile:d.path atomically:NO];
        if (![ed save:&err]) { d.saveError = [NSString stringWithFormat:FTL(@"Couldn’t keep a backup: %@"), err ?: FTL(@"Unknown error")]; ed.onChange(); return NO; }
        [self didSave:d];
        return YES;
    }
    NSString *problem = nil;
    if (d.missing || ![NSFileManager.defaultManager fileExistsAtPath:d.path]) problem = FTL(@"The file was deleted; not auto-saved (⌘S recreates it)");
    else if ([self diskChanged:d]) problem = FTL(@"The file changed on disk; not auto-saved (⌘S to decide whether to overwrite)");
    NSString *err = nil;
    if (!problem && ![ed save:&err]) problem = [NSString stringWithFormat:FTL(@"Auto-save failed: %@"), err ?: FTL(@"Unknown error")];
    if (problem) {
        d.saveError = problem;
        ed.onChange();
        return NO;
    }
    [self didSave:d];
    return YES;
}

- (BOOL)flushAutoSave {
    [self backupUntitled];
    if (_autoSaveMode == AutoSaveOff) return NO;
    BOOL ok = YES;
    for (Doc *d in _docs.copy) if (!d.untitled && docDirty(d) && ![self autoSave:d]) ok = NO;
    return ok;
}

- (void)backupUntitled {
    for (Doc *d in _docs.copy) if (d.untitled && d.editor.isDirty) [self autoSave:d];
}

- (BOOL)saveDoc:(Doc *)d {
    if (d.untitled) return [self saveUntitled:d];
    if (d.savable) return [self saveSavable:d];
    TextEditorView *ed = d.editor;
    if (!ed) return YES;
    if ([self diskChanged:d]) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:FTL(@"“%@” has changed on disk"), d.path.lastPathComponent];
        a.informativeText = FTL(@"Saving will overwrite the newer version on disk.");
        [a addButtonWithTitle:FTL(@"Overwrite")];
        [a addButtonWithTitle:FTL(@"Cancel")];
        if ([self runAlert:a] != NSAlertFirstButtonReturn) return NO;
    }
    NSString *err = nil;
    if (![ed save:&err]) {
        NSAlert *a = [NSAlert new];
        a.messageText = FTL(@"Couldn’t Save");
        a.informativeText = err ?: FTL(@"Unknown error");
        [self runAlert:a];
        return NO;
    }
    [self didSave:d];
    return YES;
}

- (BOOL)saveSavable:(Doc *)d {
    if (!d.savable.isDirty) return YES;
    if ([self diskChanged:d]) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:FTL(@"“%@” has changed on disk"), d.path.lastPathComponent];
        a.informativeText = FTL(@"Saving will overwrite the newer version on disk.");
        [a addButtonWithTitle:FTL(@"Overwrite")];
        [a addButtonWithTitle:FTL(@"Cancel")];
        if ([self runAlert:a] != NSAlertFirstButtonReturn) return NO;
    }
    NSString *err = nil;
    if (![d.savable saveReturningError:&err]) {
        NSAlert *a = [NSAlert new];
        a.messageText = FTL(@"Couldn’t Save");
        a.informativeText = err ?: FTL(@"Unknown error");
        [self runAlert:a];
        d.saveError = err;
        [self savableChanged:d];
        return NO;
    }
    [self didSave:d];
    return YES;
}

- (BOOL)save { return _active ? [self saveDoc:_active] : YES; }

#pragma mark Untitled documents

- (NSString *)untitledDirectory {
    if (_untitledDirectory) return _untitledDirectory;
    // per app identity, so a test binary (its own defaults domain) never sees or prunes the real backups
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    NSString *folder = [bid isEqualToString:@"local.feather.editor"] ? @"Feather" : [@"Feather-" stringByAppendingString:bid ?: NSProcessInfo.processInfo.processName];
    return [[support stringByAppendingPathComponent:folder] stringByAppendingPathComponent:@"Untitled"];
}

- (NSString *)nextUntitledTitle {
    NSMutableSet *used = [NSMutableSet set];
    for (Doc *d in _docs) if (d.untitled) [used addObject:d.title];
    NSUInteger n = 1;
    while ([used containsObject:[NSString stringWithFormat:FTL(@"Untitled-%lu"), (unsigned long)n]]) n++;
    return [NSString stringWithFormat:FTL(@"Untitled-%lu"), (unsigned long)n];
}

- (void)newUntitledDocument {
    NSString *dir = self.untitledDirectory;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", NSUUID.UUID.UUIDString]];
    if (![NSData.data writeToFile:path atomically:NO]) { NSBeep(); return; }
    Doc *d = [Doc new];
    d.path = path; d.mode = ViewerText; d.untitled = YES;
    d.title = self.nextUntitledTitle;
    NSUInteger at = _active ? [_docs indexOfObject:_active] + 1 : _docs.count;
    [_docs insertObject:d atIndex:MIN(at, _docs.count)];
    [self activate:d focus:YES];
}

// First line of text, cleaned up for a file name.
static NSString *suggestedName(TextEditorView *ed, NSString *fallback) {
    NSData *data = ed.contentData;
    NSString *text = [[NSString alloc] initWithBytes:data.bytes length:MIN(data.length, (NSUInteger)400) encoding:NSUTF8StringEncoding] ?: @"";
    NSString *first = @"";
    for (NSString *l in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t#>*-/"]];
        if (t.length) { first = t; break; }
    }
    for (NSString *bad in @[@"/", @":", @"\\", @"\0"]) first = [first stringByReplacingOccurrencesOfString:bad withString:@" "];
    if (first.length > 40) first = [first substringToIndex:[first rangeOfComposedCharacterSequenceAtIndex:40].location];
    first = [first stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [(first.length ? first : fallback) stringByAppendingPathExtension:@"txt"];
}

- (NSString *)askSavePath:(NSString *)name {
    NSString *dir = _workspaceRoot ?: NSHomeDirectory();
    if (self.savePathHandler) return self.savePathHandler(name, dir);
    NSSavePanel *p = [NSSavePanel savePanel];
    p.directoryURL = [NSURL fileURLWithPath:dir];
    p.nameFieldStringValue = name;
    p.canCreateDirectories = YES;
    p.allowsOtherFileTypes = YES;
    p.extensionHidden = NO;
    p.message = FTL(@"Choose where to save. The extension sets the syntax highlighting, for example .md, .py or .json.");
    return [p runModal] == NSModalResponseOK ? p.URL.path : nil;
}

// Save As: writes the text to a real file, then the tab becomes that file.
- (BOOL)saveUntitled:(Doc *)d {
    if (!d.editor) [self loadViewer:d];
    TextEditorView *ed = d.editor;
    if (!ed) return NO;
    NSString *dest = [self askSavePath:suggestedName(ed, d.title)].stringByStandardizingPath;
    if (!dest.length) return NO;
    Doc *other = [self docForPath:dest];                 // that file is open in another tab
    if (other && docDirty(other)) {
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:FTL(@"“%@” is open with unsaved changes"), dest.lastPathComponent];
        a.informativeText = FTL(@"Saving here replaces the file and closes that tab. Its changes will be lost.");
        [a addButtonWithTitle:FTL(@"Replace")];
        [a addButtonWithTitle:FTL(@"Cancel")];
        if ([self runAlert:a] != NSAlertFirstButtonReturn) return NO;
    }
    NSString *backup = d.path;
    BOOL existed = [NSFileManager.defaultManager fileExistsAtPath:dest];
    if (!existed) [NSFileManager.defaultManager createFileAtPath:dest contents:nil attributes:@{NSFilePosixPermissions: @0644}];
    [ed setDocumentPath:dest];
    NSString *err = nil;
    if (![ed save:&err]) {
        [ed setDocumentPath:backup];
        if (!existed) [NSFileManager.defaultManager removeItemAtPath:dest error:nil];
        NSAlert *a = [NSAlert new];
        a.messageText = FTL(@"Couldn’t Save");
        a.informativeText = err ?: FTL(@"Unknown error");
        [self runAlert:a];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
    if (other) { other.discarded = YES; [self closeDoc:other ask:NO]; [_closed removeObject:dest]; }
    d.path = dest; d.untitled = NO; d.title = nil; d.saveError = nil;
    if (FKMarkupKind(dest) != MarkupNone) { d.mode = ViewerAuto; [self reloadViewerOf:d]; }   // gets its preview
    [self didSave:d];
    if (self.onSaveAs) self.onSaveAs(dest);
    if (d == _active && self.onActivate) self.onActivate(dest);
    return YES;
}

+ (NSSet<NSString *> *)untitledBackupsInSessions:(NSDictionary *)sessions {
    NSMutableSet *out = [NSMutableSet set];
    for (NSDictionary *s in sessions.allValues) {
        if (![s isKindOfClass:NSDictionary.class]) continue;
        for (NSDictionary *t in s[@"tabs"]) if ([t isKindOfClass:NSDictionary.class] && t[@"untitled"] && t[@"path"]) [out addObject:t[@"path"]];
    }
    return out;
}

- (void)adoptUntitledBackups:(NSArray<NSString *> *)paths {
    Doc *first = nil;
    for (NSString *p in paths) {
        struct stat st;
        if ([self docForPath:p] || lstat(p.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (st.st_size == 0) { [NSFileManager.defaultManager removeItemAtPath:p error:nil]; continue; }
        Doc *d = [Doc new];
        d.path = p; d.mode = ViewerText; d.untitled = YES;
        d.title = self.nextUntitledTitle;
        [_docs addObject:d];
        first = first ?: d;
    }
    if (!first) return;
    if (_active) [self reloadTabs];
    else [self activate:first focus:NO];
    [self stateChanged];
}

// A cancelled save panel (an untitled tab) or a failed save doesn't stop the others.
- (BOOL)saveAll {
    BOOL ok = YES;
    for (Doc *d in _docs.copy) if (docDirty(d) && ![self saveDoc:d]) ok = NO;
    return ok;
}

#pragma mark Find / replace / navigation

- (void)showFindBar {
    if (!_docs.count) return;
    _findBar.hidden = NO;
    [_pane layoutPane];
    [_findBar resizeSubviewsWithOldSize:_findBar.bounds.size];
    NSString *sel = self.editor.selectedText;
    if (sel.length) _search.stringValue = sel;
    [_pane.window makeFirstResponder:_search];
    [_search selectText:nil];
}

- (void)showReplaceBar {
    [self showFindBar];
    if (_search.stringValue.length) [_pane.window makeFirstResponder:_replace];
}

- (void)hideFindBar {
    _findBar.hidden = YES;
    [_pane layoutPane];
    NSView *fv = _active.markup ? _active.markup.focusView
               : [_active.viewer conformsToProtocol:@protocol(FTZoomable)] ? [(id<FTZoomable>)_active.viewer focusView] : _active.viewer;
    if (fv) [_pane.window makeFirstResponder:fv];
}

// Find in whatever is shown: the PDF text, or the editor buffer.
- (BOOL)findInActive:(NSString *)s backward:(BOOL)back {
    if (self.activePDF) return [self.activePDF find:s backward:back];
    if (_active.savable) return [_active.savable find:s backward:back];
    if ([_active.viewer isKindOfClass:DocumentPreview.class]) return [(DocumentPreview *)_active.viewer find:s backward:back];
    return [self.editor findString:s backward:back];
}

- (void)findNext:(BOOL)backward {
    if (!_search.stringValue.length) { [self showFindBar]; return; }
    _findBar.info.stringValue = [self findInActive:_search.stringValue backward:backward] ? @"" : FTL(@"No results");
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:)) {
        if (c == _replace) { [self replaceOne:nil]; return YES; }
        BOOL back = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
        _findBar.info.stringValue = [self findInActive:_search.stringValue backward:back] ? @"" : FTL(@"No results");
        return YES;
    }
    if (sel == @selector(cancelOperation:)) { [self hideFindBar]; return YES; }
    return NO;
}

- (void)replaceOne:(id)sender {
    if (!_search.stringValue.length) return;
    [self.editor replaceSelectionIfMatches:_search.stringValue with:_replace.stringValue];
    _findBar.info.stringValue = @"";
}

- (void)replaceAllAction:(id)sender {
    if (!_search.stringValue.length) return;
    NSUInteger n = [self.editor replaceAll:_search.stringValue with:_replace.stringValue];
    _findBar.info.stringValue = n ? [NSString stringWithFormat:FTLP(n, @"Replaced %lu occurrence", @"Replaced %lu occurrences"), (unsigned long)n] : FTL(@"No results");
}

- (void)openHit:(NSString *)path line:(NSUInteger)line column:(NSUInteger)col length:(NSUInteger)len {
    Doc *d = [self docForPath:path];
    if (d) [self activate:d focus:NO];
    else {
        ViewerKind k = FKMarkupKind(path) != MarkupNone ? ViewerAuto : ViewerText;   // keep the .md preview chrome
        d = [self openPath:path mode:k preview:YES focus:NO];
    }
    if (d.markup.markupLayout == MarkupPreview) [self setActiveMarkupLayout:MarkupSplit];   // the match must be visible
    [d.editor selectLine:line column:col length:len];
}

- (void)pathMoved:(NSString *)from to:(NSString *)to {
    BOOL any = NO;
    for (Doc *d in _docs) {
        if (!FOPathIsWithin(d.path, from)) continue;
        d.path = [to stringByAppendingString:[d.path substringFromIndex:from.length]];
        if (d.editor) { [d.editor setDocumentPath:d.path]; d.markup.path = d.path; }
        else if ([d.savable isKindOfClass:SpreadsheetPreview.class]) [(SpreadsheetPreview *)d.savable setPath:d.path];   // keeps unsaved cells
        else if (d.viewer) [self reloadViewerOf:d];
        any = YES;
    }
    if (any) { [self reloadTabs]; [self stateChanged]; }
}

#pragma mark Tab bar wiring

- (void)wireTabBar {
    __weak ContentController *weakSelf = self;
    _tabBar.onSelect = ^(NSInteger i) { ContentController *me = weakSelf; if (me && i < (NSInteger)me->_docs.count) [me activate:me->_docs[i] focus:YES]; };
    _tabBar.onClose = ^(NSInteger i) { ContentController *me = weakSelf; if (me && i < (NSInteger)me->_docs.count) [me closeDoc:me->_docs[i] ask:YES]; };
    _tabBar.onPin = ^(NSInteger i) {
        ContentController *me = weakSelf;
        if (!me || i >= (NSInteger)me->_docs.count) return;
        me->_docs[i].preview = NO;
        [me activate:me->_docs[i] focus:YES];
    };
    _tabBar.onMove = ^(NSInteger from, NSInteger to) {
        ContentController *me = weakSelf;
        if (!me || from == to || from >= (NSInteger)me->_docs.count || to >= (NSInteger)me->_docs.count) return;
        Doc *d = me->_docs[from];
        [me->_docs removeObjectAtIndex:from];
        [me->_docs insertObject:d atIndex:to];
        [me reloadTabs];
    };
    _tabBar.menuForIndex = ^NSMenu *(NSInteger i) { return [weakSelf menuForTab:i]; };
}

- (NSMenu *)menuForTab:(NSInteger)i {
    if (i >= (NSInteger)_docs.count) return nil;
    Doc *d = _docs[i];
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    void (^add)(NSString *, SEL) = ^(NSString *t, SEL s) {
        NSMenuItem *it = [m addItemWithTitle:t action:s keyEquivalent:@""];
        it.target = self;
        it.representedObject = d;
    };
    add(FTL(@"Close"), @selector(menuClose:));
    add(FTL(@"Close Others"), @selector(menuCloseOthers:));
    add(FTL(@"Close to the Right"), @selector(menuCloseRight:));
    add(FTL(@"Close All"), @selector(menuCloseAll:));
    [m addItem:NSMenuItem.separatorItem];
    if (d.preview) add(FTL(@"Keep Open"), @selector(menuPin:));
    if (d.untitled) { add(FTL(@"Save…"), @selector(menuSave:)); return m; }
    add(FTL(@"Show in Finder"), @selector(menuReveal:));
    add(FTL(@"Copy Path"), @selector(menuCopyPath:));
    return m;
}

- (void)menuClose:(NSMenuItem *)s { [self closeDoc:s.representedObject ask:YES]; }
- (void)menuCloseOthers:(NSMenuItem *)s { [self activate:s.representedObject focus:NO]; [self closeOthers]; }
- (void)menuCloseRight:(NSMenuItem *)s { [self closeRightOf:s.representedObject]; }
- (void)menuCloseAll:(NSMenuItem *)s { [self closeAll]; }
- (void)menuSave:(NSMenuItem *)s { [self saveDoc:s.representedObject]; }
- (void)menuPin:(NSMenuItem *)s { [(Doc *)s.representedObject setPreview:NO]; [self reloadTabs]; }
- (void)menuReveal:(NSMenuItem *)s {
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:[s.representedObject path]]]];
}
- (void)menuCopyPath:(NSMenuItem *)s {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[s.representedObject path] forType:NSPasteboardTypeString];
}

@end

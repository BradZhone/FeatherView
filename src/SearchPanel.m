#import "SearchPanel.h"
#import "WorkspaceSearch.h"

@interface SearchGroup : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic) NSMutableArray<SearchHit *> *hits;
@end
@implementation SearchGroup @end

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@implementation SearchPanel {
    FlippedView *_view;
    NSSearchField *_field;
    NSButton *_caseBox;
    NSTextField *_status;
    NSOutlineView *_ov;
    WorkspaceSearch *_engine;
    NSMutableArray<SearchGroup *> *_groups;
    NSMutableDictionary<NSString *, SearchGroup *> *_byPath;
    NSMutableSet<NSString *> *_collapsed;
    NSUInteger _hitCount;
    NSString *_lastQuery;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _engine = [WorkspaceSearch new];
    _groups = [NSMutableArray array];
    _byPath = [NSMutableDictionary dictionary];
    _collapsed = [NSMutableSet set];
    CGFloat w = 260;
    _view = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, w, 600)];
    _view.autoresizesSubviews = YES;

    _field = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 6, w - 16, 24)];
    _field.placeholderString = @"在工作区中搜索";
    _field.delegate = self;
    _field.sendsSearchStringImmediately = NO;
    _field.autoresizingMask = NSViewWidthSizable;
    _field.target = self;
    _field.action = @selector(run:);
    [_view addSubview:_field];

    _caseBox = [NSButton checkboxWithTitle:@"区分大小写" target:self action:@selector(run:)];
    _caseBox.controlSize = NSControlSizeSmall;
    _caseBox.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [_caseBox sizeToFit];
    _caseBox.frame = (NSRect){{10, 34}, _caseBox.frame.size};
    [_view addSubview:_caseBox];

    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont systemFontOfSize:11];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.frame = NSMakeRect(10, 54, w - 20, 16);
    _status.autoresizingMask = NSViewWidthSizable;
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [_view addSubview:_status];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 74, w, 600 - 74)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.drawsBackground = NO;
    _ov = [[NSOutlineView alloc] initWithFrame:sv.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"r"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_ov addTableColumn:col];
    _ov.outlineTableColumn = col;
    _ov.headerView = nil;
    _ov.style = NSTableViewStyleSourceList;
    _ov.rowHeight = 20;
    _ov.indentationPerLevel = 10;
    _ov.backgroundColor = NSColor.clearColor;
    _ov.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _ov.dataSource = self;
    _ov.delegate = self;
    _ov.target = self;
    _ov.action = @selector(clicked:);
    sv.documentView = _ov;
    [col setWidth:sv.contentSize.width];
    [_view addSubview:sv];
    return self;
}

- (NSView *)view { return _view; }

- (void)setRoot:(NSString *)root {
    _root = [root copy];
    [_engine cancel];
    [self clearResults];
    _status.stringValue = @"";
    _lastQuery = nil;
}

- (void)clearResults {
    [_groups removeAllObjects];
    [_byPath removeAllObjects];
    [_collapsed removeAllObjects];
    _hitCount = 0;
    [_ov reloadData];
}

- (void)focusWithQuery:(NSString *)q {
    [_view.window makeFirstResponder:_field];
    if (q.length && ![q isEqualToString:_field.stringValue]) { _field.stringValue = q; [self run:nil]; }
    else [_field selectText:nil];
}

- (void)run:(id)sender {
    NSString *q = _field.stringValue;
    [self clearResults];
    _lastQuery = q;
    if (!q.length || !_root) { [_engine cancel]; _status.stringValue = @""; return; }
    _status.stringValue = @"搜索中…";
    __weak SearchPanel *weakSelf = self;
    [_engine search:q root:_root caseSensitive:_caseBox.state == NSControlStateValueOn includeHidden:_includeHidden
        onBatch:^(NSArray<SearchHit *> *hits, NSUInteger files) { [weakSelf append:hits files:files]; }
         onDone:^(BOOL truncated) { [weakSelf finished:truncated]; }];
}

- (void)append:(NSArray<SearchHit *> *)hits files:(NSUInteger)files {
    for (SearchHit *h in hits) {
        SearchGroup *g = _byPath[h.path];
        if (!g) {
            g = [SearchGroup new];
            g.path = h.path;
            g.hits = [NSMutableArray array];
            _byPath[h.path] = g;
            [_groups addObject:g];
        }
        [g.hits addObject:h];
    }
    _hitCount += hits.count;
    [_ov reloadData];
    for (SearchGroup *g in _groups) if (![_collapsed containsObject:g.path]) [_ov expandItem:g];
    _status.stringValue = files ? [NSString stringWithFormat:@"搜索中… 已扫描 %lu 个文件，%lu 处匹配", (unsigned long)files, (unsigned long)_hitCount]
                                : [NSString stringWithFormat:@"搜索中… %lu 处匹配", (unsigned long)_hitCount];
}

- (void)finished:(BOOL)truncated {
    NSString *engine = _engine.usedRipgrep ? @"ripgrep" : @"内置";
    if (!_hitCount) _status.stringValue = [NSString stringWithFormat:@"无结果（%@）", engine];
    else _status.stringValue = [NSString stringWithFormat:@"%lu 个文件中 %lu 处%@（%@）", (unsigned long)_groups.count,
                                (unsigned long)_hitCount, truncated ? @"，结果过多已截断" : @"", engine];
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (!_field.stringValue.length && _lastQuery.length) [self run:nil];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:) && _ov.numberOfRows) {
        [_view.window makeFirstResponder:_ov];
        [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        return YES;
    }
    return NO;
}

#pragma mark Results

- (SearchHit *)hitForItem:(id)item {
    return [item isKindOfClass:SearchGroup.class] ? [(SearchGroup *)item hits].firstObject : item;
}

- (void)clicked:(id)sender {
    id item = [_ov itemAtRow:_ov.clickedRow];
    if (item && self.onOpen) self.onOpen([self hitForItem:item], YES);
}

- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    if (NSApp.currentEvent.type != NSEventTypeKeyDown) return;      // clicks handled in clicked:
    id item = [_ov itemAtRow:_ov.selectedRow];
    if (item && self.onOpen) {
        self.onOpen([self hitForItem:item], NO);
        [_view.window makeFirstResponder:_ov];
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification *)n { [_collapsed addObject:[n.userInfo[@"NSObject"] path]]; }
- (void)outlineViewItemDidExpand:(NSNotification *)n { [_collapsed removeObject:[n.userInfo[@"NSObject"] path]]; }

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    return item ? [(SearchGroup *)item hits].count : _groups.count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item {
    return item ? [(SearchGroup *)item hits][i] : _groups[i];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return [item isKindOfClass:SearchGroup.class]; }

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NSTextField *tf = [ov makeViewWithIdentifier:@"res" owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = @"res";
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSFont *small = [NSFont systemFontOfSize:11];
    if ([item isKindOfClass:SearchGroup.class]) {
        SearchGroup *g = item;
        NSString *dir = g.path.stringByDeletingLastPathComponent;
        if ([dir hasPrefix:_root]) dir = [dir substringFromIndex:MIN(dir.length, _root.length + 1)];
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:g.path.lastPathComponent
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}];
        [s appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"  %@  %lu", dir, (unsigned long)g.hits.count]
            attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
        tf.attributedStringValue = s;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    } else {
        SearchHit *h = item;
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%lu  ", (unsigned long)h.line]
            attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}];
        NSUInteger base = s.length;
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:h.preview
            attributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.labelColor}]];
        if (h.previewMatch.location != NSNotFound && NSMaxRange(h.previewMatch) <= h.preview.length)
            [s addAttributes:@{NSBackgroundColorAttributeName: [NSColor.systemYellowColor colorWithAlphaComponent:0.35],
                               NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]}
                       range:NSMakeRange(base + h.previewMatch.location, h.previewMatch.length)];
        tf.attributedStringValue = s;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    return tf;
}

@end

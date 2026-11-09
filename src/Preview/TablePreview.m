#import "TablePreview+Private.h"
#import "Localization.h"
#import "CanvasView.h"

static const NSUInteger kMaxRows = 500000, kSyncBytes = 4u << 20;

@implementation TablePreview
@synthesize onJumpToLine = _onJumpToLine;
@dynamic filterText;                                 // TablePreview+Order.m

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    FTClipToBounds(self);
    _sortColumn = -1;
    _sortAscending = YES;
    _headerChoice = -1;
    _numeric = [NSMutableDictionary dictionary];

    _filter = [NSSearchField new];
    _filter.placeholderString = FTL(@"Filter rows (column:text)");
    _filter.delegate = self;
    _filter.controlSize = NSControlSizeSmall;
    _filter.font = [NSFont systemFontOfSize:11.5];
    _filter.translatesAutoresizingMaskIntoConstraints = NO;
    _headerBox = [NSButton checkboxWithTitle:FTL(@"First row is header") target:self action:@selector(headerToggled:)];
    _headerBox.controlSize = NSControlSizeSmall;
    _headerBox.font = [NSFont systemFontOfSize:11.5];
    _headerBox.translatesAutoresizingMaskIntoConstraints = NO;
    _delimPopup = [NSPopUpButton new];
    _delimPopup.controlSize = NSControlSizeSmall;
    _delimPopup.font = [NSFont systemFontOfSize:11.5];
    NSArray *titles = @[FTL(@"Detect delimiter"), FTL(@"Comma ,"), FTL(@"Tab"), FTL(@"Semicolon ;"), FTL(@"Pipe |")];
    unichar tags[] = {0, ',', '\t', ';', '|'};
    for (NSUInteger i = 0; i < titles.count; i++) { [_delimPopup addItemWithTitle:titles[i]]; _delimPopup.lastItem.tag = tags[i]; }
    _delimPopup.target = self; _delimPopup.action = @selector(delimiterChosen:);
    _delimPopup.translatesAutoresizingMaskIntoConstraints = NO;
    _info = [NSTextField labelWithString:@""];
    _info.font = [NSFont systemFontOfSize:11];
    _info.textColor = NSColor.secondaryLabelColor;
    _info.lineBreakMode = NSLineBreakByTruncatingTail;
    _info.translatesAutoresizingMaskIntoConstraints = NO;
    [_info setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    _table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
    _table.gridColor = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
        return [NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.08 : 0.07];
    }];
    _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
    _table.allowsMultipleSelection = YES;
    _table.allowsColumnReordering = NO;
    _table.style = NSTableViewStylePlain;
    _table.intercellSpacing = NSMakeSize(8, 0);
    _table.rowHeight = FTDataRowHeight();
    _table.target = self;
    _table.doubleAction = @selector(doubleClicked:);
    _table.menu = [NSMenu new];
    _table.menu.delegate = self;
    _scroll = [NSScrollView new];
    _scroll.documentView = _table;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.borderType = NSNoBorder;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *v in @[_filter, _headerBox, _delimPopup, _info, line, _scroll]) [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [_filter.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [_filter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_filter.widthAnchor constraintEqualToConstant:220],
        [_headerBox.leadingAnchor constraintEqualToAnchor:_filter.trailingAnchor constant:12],
        [_headerBox.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [_delimPopup.leadingAnchor constraintEqualToAnchor:_headerBox.trailingAnchor constant:8],
        [_delimPopup.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [_info.leadingAnchor constraintEqualToAnchor:_delimPopup.trailingAnchor constant:12],
        [_info.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-8],
        [_info.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [line.topAnchor constraintEqualToAnchor:_filter.bottomAnchor constant:6],
        [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:FTDataFontSizeDidChange object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r { [NSColor.textBackgroundColor setFill]; NSRectFill(NSIntersectionRect(r, self.bounds)); }

- (void)setExtraInfo:(NSString *)e { _extraInfo = [e copy]; [self updateInfo]; }
- (NSView *)focusView { return _table; }
- (void)focusFilter { [self.window makeFirstResponder:_filter]; }
- (NSTableView *)tableView { return _table; }
- (id<TableModel>)model { return _model; }
- (NSString *)infoText { return _info.stringValue; }

#pragma mark Data

- (BOOL)isJSONLines { return [@[@"jsonl", @"ndjson", @"jsonlines"] containsObject:_path.pathExtension.lowercaseString]; }

- (unichar)extensionDelimiter {
    NSString *e = _path.pathExtension.lowercaseString;
    if ([@[@"tsv", @"tab"] containsObject:e]) return '\t';
    if ([e isEqualToString:@"psv"]) return '|';
    return 0;
}

static id<TableModel> parse(NSData *d, BOOL jsonl, unichar delim, NSInteger header) {
    if (jsonl) return [JSONLinesTable tableWithData:d maxRows:kMaxRows];
    return [CSVTable tableWithData:d delimiter:delim hasHeader:header maxRows:kMaxRows];
}

- (void)setSourceData:(NSData *)utf8 path:(NSString *)path {
    _path = [path copy];
    _source = utf8;
    BOOL jsonl = self.isJSONLines;
    _headerBox.hidden = _delimPopup.hidden = jsonl;
    unichar delim = _delimChoice ?: [CSVTable sniffDelimiter:utf8 hint:self.extensionDelimiter];
    NSInteger header = _headerChoice;
    NSUInteger gen = ++_parseGen;
    if (utf8.length <= kSyncBytes) { [self install:parse(utf8, jsonl, delim, header)]; return; }
    _info.stringValue = FTL(@"Reading table…");
    __weak TablePreview *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id<TableModel> m = parse(utf8, jsonl, delim, header);
        dispatch_async(dispatch_get_main_queue(), ^{
            TablePreview *me = weakSelf;
            if (me && me->_parseGen == gen) [me install:m];
        });
    });
}

- (void)setModel:(id<TableModel>)model {
    _headerBox.hidden = _delimPopup.hidden = YES;
    _source = nil;
    _parseGen++;
    [self install:model];
}

- (NSUInteger)shownColumns { return MIN(_model.columnCount, kMaxShownColumns); }

- (void)install:(id<TableModel>)m {
    BOOL sameShape = _model && m.columnCount == _model.columnCount;
    for (NSUInteger c = 0; sameShape && c < MIN(m.columnCount, kMaxShownColumns); c++)
        if (![[m headerForColumn:c] isEqualToString:[_model headerForColumn:c]]) sameShape = NO;
    _keepScroll = _model != nil && sameShape;
    _model = m;
    [_numeric removeAllObjects];
    if ([m isKindOfClass:CSVTable.class]) {
        CSVTable *t = (CSVTable *)m;
        _headerBox.state = t.hasHeader;
        [_delimPopup selectItemWithTag:_delimChoice];
        _delimPopup.itemArray.firstObject.title = [NSString stringWithFormat:FTL(@"Auto (%@)"), t.delimiter == '\t' ? @"Tab" : [NSString stringWithFormat:@"%C", t.delimiter]];
    }
    if (_sortColumn >= (NSInteger)m.columnCount) _sortColumn = -1;
    if (!sameShape) [self rebuildColumns]; else [_table reloadData];
    [self applyOrder];
}

- (void)headerToggled:(NSButton *)b { _headerChoice = b.state == NSControlStateValueOn ? 1 : 0; [self reparse]; }
- (void)delimiterChosen:(NSPopUpButton *)p { _delimChoice = (unichar)p.selectedTag; [self reparse]; }
- (void)reparse { if (_source) [self setSourceData:_source path:_path]; }

- (void)fontChanged:(NSNotification *)n { _table.rowHeight = FTDataRowHeight(); [self rebuildColumns]; }

- (BOOL)columnIsNumeric:(NSUInteger)c {
    NSNumber *cached = _numeric[@(c)];
    if (cached) return cached.boolValue;
    NSUInteger seen = 0, nums = 0;
    for (NSUInteger r = 0; r < _model.rowCount && seen < 200; r++) {
        NSString *v = [_model cellAtRow:r column:c];
        if (!v.length) continue;
        seen++;
        NSScanner *s = [NSScanner scannerWithString:[[v stringByReplacingOccurrencesOfString:@"," withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" %$¥€"]]];
        double d;
        if ([s scanDouble:&d] && s.isAtEnd) nums++;
    }
    BOOL numeric = seen && nums * 10 >= seen * 9;
    _numeric[@(c)] = @(numeric);
    return numeric;
}

- (void)rebuildColumns {
    while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];
    NSFont *f = FTDataFont(), *bold = [NSFont systemFontOfSize:f.pointSize weight:NSFontWeightSemibold];
    NSTableColumn *g = [[NSTableColumn alloc] initWithIdentifier:@"#"];
    g.title = @"";
    NSString *maxNum = FTGrouped(MAX((NSUInteger)9, _model.rowCount));
    g.width = MAX(36, ceil([maxNum sizeWithAttributes:@{NSFontAttributeName: FTDataDigitsFont()}].width) + 14);
    g.resizingMask = NSTableColumnNoResizing;
    [_table addTableColumn:g];
    NSUInteger sample = MIN(_model.rowCount, (NSUInteger)120);
    for (NSUInteger c = 0; c < self.shownColumns; c++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu", (unsigned long)c]];
        col.title = [_model headerForColumn:c];
        col.headerToolTip = col.title;
        CGFloat w = [col.title sizeWithAttributes:@{NSFontAttributeName: bold}].width + 26;
        for (NSUInteger r = 0; r < sample && c < 100; r++) {
            NSString *v = [_model cellAtRow:r column:c];
            if (v.length > 80) v = [v substringToIndex:80];
            w = MAX(w, [v sizeWithAttributes:@{NSFontAttributeName: f}].width + 14);
        }
        col.width = MIN(MAX(w, 48), 360);
        col.minWidth = 30;
        col.maxWidth = 4000;
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:col.identifier ascending:YES];
        if ([self columnIsNumeric:c]) [col.headerCell setAlignment:NSTextAlignmentRight];
        [_table addTableColumn:col];
    }
    [_table reloadData];
}

#pragma mark Table data source

- (NSUInteger)modelRow:(NSInteger)row {
    if (row < 0) return NSNotFound;
    if (!_order) return (NSUInteger)row;
    return (NSUInteger)row < _order.length / 4 ? ((const uint32_t *)_order.bytes)[row] : NSNotFound;
}

- (NSUInteger)visibleRowCount { return _order ? _order.length / 4 : _model.rowCount; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)self.visibleRowCount; }

- (NSString *)displayedCellAtRow:(NSUInteger)row column:(NSUInteger)column {
    NSUInteger r = [self modelRow:(NSInteger)row];
    return r == NSNotFound ? @"" : [_model cellAtRow:r column:column];
}

- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSUInteger r = [self modelRow:row];
    if (r == NSNotFound) return @"";
    if ([col.identifier isEqualToString:@"#"]) return FTGrouped(r + 1);
    NSString *v = [_model cellAtRow:r column:(NSUInteger)col.identifier.integerValue];
    if ([v rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        v = [[v componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" ⏎ "];
    return v;
}

- (void)tableView:(NSTableView *)t willDisplayCell:(NSTextFieldCell *)cell forTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    BOOL gutter = [col.identifier isEqualToString:@"#"];
    BOOL numeric = !gutter && [self columnIsNumeric:(NSUInteger)col.identifier.integerValue];
    cell.font = gutter || numeric ? FTDataDigitsFont() : FTDataFont();
    cell.alignment = gutter || numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textColor = gutter ? NSColor.tertiaryLabelColor : NSColor.labelColor;
}

- (BOOL)tableView:(NSTableView *)t shouldEditTableColumn:(NSTableColumn *)c row:(NSInteger)r { return NO; }

@end

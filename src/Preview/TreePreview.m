#import "TreePreview+Private.h"
#import "CanvasView.h"
#import "Highlighter.h"

static const NSUInteger kSyncBytes = 2u << 20, kMaxTreeBytes = 64u << 20;

@implementation TreePreview
@synthesize onJumpToLine = _onJumpToLine;
@dynamic filterText;

static NSButton *tool(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] target:target action:action];
    b.bordered = NO;
    b.toolTip = tip;
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    FTClipToBounds(self);
    _filter = [NSSearchField new];
    _filter.placeholderString = @"筛选键或值";
    _filter.delegate = self;
    _filter.controlSize = NSControlSizeSmall;
    _filter.font = [NSFont systemFontOfSize:11.5];
    _filter.translatesAutoresizingMaskIntoConstraints = NO;
    _expandAll = tool(@"plus.square.on.square", @"全部展开", self, @selector(expandAllAction:));
    _collapseAll = tool(@"minus.square", @"全部折叠", self, @selector(collapseAllAction:));
    _info = [NSTextField labelWithString:@""];
    _info.font = [NSFont systemFontOfSize:11];
    _info.textColor = NSColor.secondaryLabelColor;
    _info.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _info.translatesAutoresizingMaskIntoConstraints = NO;
    [_info setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _error = [NSTextField wrappingLabelWithString:@""];
    _error.font = [NSFont systemFontOfSize:11.5];
    _error.textColor = NSColor.systemRedColor;
    _error.hidden = YES;
    _error.translatesAutoresizingMaskIntoConstraints = NO;
    _errorHeight = [_error.heightAnchor constraintEqualToConstant:0];
    _errorHeight.active = YES;                               // collapsed while there is no error

    _ov = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSTableColumn *k = [[NSTableColumn alloc] initWithIdentifier:@"key"], *v = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    k.title = @"名称"; v.title = @"值";
    k.width = 260; v.width = 420;
    k.resizingMask = v.resizingMask = NSTableColumnUserResizingMask;
    [_ov addTableColumn:k];
    [_ov addTableColumn:v];
    _ov.outlineTableColumn = k;
    _ov.dataSource = self;
    _ov.delegate = self;
    _ov.usesAlternatingRowBackgroundColors = YES;
    _ov.style = NSTableViewStylePlain;
    _ov.indentationPerLevel = 14;
    _ov.rowHeight = FTDataRowHeight();
    _ov.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _ov.autoresizesOutlineColumn = NO;
    _ov.target = self;
    _ov.doubleAction = @selector(doubleClicked:);
    _ov.menu = [NSMenu new];
    _ov.menu.delegate = self;
    NSScrollView *sv = [NSScrollView new];
    sv.documentView = _ov;
    sv.hasVerticalScroller = sv.hasHorizontalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *x in @[_filter, _expandAll, _collapseAll, _info, _error, line, sv]) [self addSubview:x];
    [NSLayoutConstraint activateConstraints:@[
        [_filter.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [_filter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [_filter.widthAnchor constraintEqualToConstant:220],
        [_expandAll.leadingAnchor constraintEqualToAnchor:_filter.trailingAnchor constant:10],
        [_expandAll.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [_collapseAll.leadingAnchor constraintEqualToAnchor:_expandAll.trailingAnchor constant:6],
        [_collapseAll.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [_info.leadingAnchor constraintEqualToAnchor:_collapseAll.trailingAnchor constant:12],
        [_info.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-8],
        [_info.centerYAnchor constraintEqualToAnchor:_filter.centerYAnchor],
        [_error.topAnchor constraintEqualToAnchor:_filter.bottomAnchor constant:0],
        [_error.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
        [_error.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
        [line.topAnchor constraintEqualToAnchor:_error.bottomAnchor constant:6],
        [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sv.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fontChanged:) name:FTDataFontSizeDidChange object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r { [NSColor.textBackgroundColor setFill]; NSRectFill(NSIntersectionRect(r, self.bounds)); }
- (NSView *)focusView { return _ov; }
- (void)focusFilter { [self.window makeFirstResponder:_filter]; }
- (NSOutlineView *)outlineView { return _ov; }
- (JSONNode *)root { return _root; }
- (NSString *)errorText { return _error.hidden ? nil : _error.stringValue; }
- (NSString *)infoText { return _info.stringValue; }
- (void)fontChanged:(NSNotification *)n { _ov.rowHeight = FTDataRowHeight(); [_ov reloadData]; }

#pragma mark Data

static JSONNode *parseSource(NSData *d, BOOL plist, NSString **err) {
    if (!plist) return JSONParse(d, err);
    NSError *e = nil;
    id obj = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:NULL error:&e];
    if (!obj) { *err = [NSString stringWithFormat:@"无法解析属性列表：%@", e.localizedDescription ?: @"格式错误"]; return nil; }
    return JSONFromPropertyList(obj);
}

- (void)setSourceData:(NSData *)utf8 path:(NSString *)path {
    _path = [path copy];
    BOOL plist = [@[@"plist", @"strings", @"stringsdict", @"entitlements", @"xcprivacy", @"mobileconfig", @"webloc"] containsObject:path.pathExtension.lowercaseString];
    if (utf8.length > kMaxTreeBytes) { [self showError:@"文件超过 64 MB，树形视图已关闭。请使用源码视图。" keepTree:NO]; return; }
    NSUInteger gen = ++_parseGen;
    void (^done)(JSONNode *, NSString *) = ^(JSONNode *r, NSString *err) {
        if (gen != self->_parseGen) return;
        if (!r) { [self showError:err keepTree:YES]; return; }
        self->_error.hidden = YES;
        self->_errorHeight.active = YES;
        [self installRoot:r keepExpansion:self->_root != nil];
    };
    if (utf8.length <= kSyncBytes) { NSString *err = nil; JSONNode *r = parseSource(utf8, plist, &err); done(r, err); return; }
    _info.stringValue = @"正在解析…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        JSONNode *r = parseSource(utf8, plist, &err);
        dispatch_async(dispatch_get_main_queue(), ^{ done(r, err); });
    });
}

- (void)showError:(NSString *)err keepTree:(BOOL)keep {
    _error.stringValue = keep && _root ? [NSString stringWithFormat:@"⚠️ %@（下面是上一次能解析时的内容）", err] : [@"⚠️ " stringByAppendingString:err ?: @""];
    _error.hidden = NO;
    _errorHeight.active = NO;
    if (!keep || !_root) { _root = nil; _nodeCount = 0; [_ov reloadData]; [self updateInfo]; }
}

- (void)setRoot:(JSONNode *)root { _error.hidden = YES; _errorHeight.active = YES; [self installRoot:root keepExpansion:NO]; }

- (void)installRoot:(JSONNode *)root keepExpansion:(BOOL)keep {
    NSMutableSet *open = [NSMutableSet set];                 // expansion survives edits: remembered by path
    if (keep) for (NSInteger r = 0; r < _ov.numberOfRows; r++) {
        JSONNode *n = [_ov itemAtRow:r];
        if ([_ov isItemExpanded:n]) [open addObject:n.path];
    }
    _root = root;
    _nodeCount = JSONNodeCount(root, 10000000);
    _visible = nil;
    [_ov reloadData];
    if (keep && open.count) {
        NSMutableArray *stack = [[self childrenOf:nil] mutableCopy];
        while (stack.count) {
            JSONNode *n = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (n.children.count && [open containsObject:n.path]) { [_ov expandItem:n]; [stack addObjectsFromArray:n.children]; }
        }
    } else [self expandToDepth:_nodeCount <= 300 ? 3 : _nodeCount <= 5000 ? 2 : 1];
    if (_filter.stringValue.length) [self applyFilter]; else [self updateInfo];
}

- (void)expandToDepth:(NSUInteger)depth {
    NSMutableArray *level = [[self childrenOf:nil] mutableCopy];
    NSUInteger budget = 3000;
    for (NSUInteger d = 1; d < depth && level.count && budget; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (JSONNode *n in level) {
            if (!n.children.count || !budget) continue;
            [_ov expandItem:n];
            budget--;
            [next addObjectsFromArray:[self childrenOf:n]];
        }
        level = next;
    }
}

- (void)expandAllAction:(id)s { [self expandToDepth:_nodeCount > 50000 ? 4 : 64]; }
- (void)collapseAllAction:(id)s { for (JSONNode *n in [self childrenOf:nil]) [_ov collapseItem:n collapseChildren:YES]; }

#pragma mark Outline

// The root's members are the top level (a scalar root is shown as one row).
- (NSArray<JSONNode *> *)childrenOf:(JSONNode *)n {
    if (!n) {
        if (!_root) return @[];
        n = _root;
        if (!n.children && n.kind != JSONObject && n.kind != JSONArray) return @[n];
    }
    NSArray *kids = n.children ?: @[];
    if (!_visible) return kids;
    NSMutableArray *out = [NSMutableArray array];
    for (JSONNode *c in kids) if ([_visible containsObject:c]) [out addObject:c];
    return out;
}

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item { return (NSInteger)[self childrenOf:item].count; }
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item { return [self childrenOf:item][(NSUInteger)i]; }
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(JSONNode *)item { return item.children.count > 0; }

static NSColor *kindColor(JSONKind k) {
    switch (k) {
        case JSONString: return HLColor(TokString);
        case JSONNumber: return HLColor(TokNumber);
        case JSONBool: case JSONNull: return HLColor(TokConstant);
        case JSONData: case JSONDate: return HLColor(TokType);
        default: return NSColor.secondaryLabelColor;
    }
}

static NSString *summary(JSONNode *n) {
    NSMutableString *s = [NSMutableString stringWithString:n.kind == JSONObject ? @"{ " : @"[ "];
    for (JSONNode *c in n.children) {
        if (s.length > 80) { [s appendString:@"…  "]; break; }
        if (n.kind == JSONObject) [s appendFormat:@"%@: ", c.key];
        if (c.kind == JSONObject) [s appendString:@"{…}"];
        else if (c.kind == JSONArray) [s appendFormat:@"[%lu]", (unsigned long)c.children.count];
        else if (c.kind == JSONString) [s appendFormat:@"\"%@\"", c.text.length > 24 ? [[c.text substringToIndex:24] stringByAppendingString:@"…"] : c.text];
        else [s appendString:c.text ?: @""];
        [s appendString:@", "];
    }
    if ([s hasSuffix:@", "]) [s deleteCharactersInRange:NSMakeRange(s.length - 2, 2)];
    [s appendString:n.kind == JSONObject ? @" }" : @" ]"];
    return s;
}

- (id)outlineView:(NSOutlineView *)ov objectValueForTableColumn:(NSTableColumn *)col byItem:(JSONNode *)n {
    NSFont *f = FTDataFont();
    BOOL container = n.kind == JSONObject || n.kind == JSONArray;
    if ([col.identifier isEqualToString:@"key"]) {
        BOOL index = !n.key && n.parent;
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:n.displayKey attributes:@{
            NSFontAttributeName: index ? FTDataDigitsFont() : [NSFont systemFontOfSize:f.pointSize weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: index ? NSColor.secondaryLabelColor : HLColor(TokProperty)}];
        if (container) [s appendAttributedString:[[NSAttributedString alloc] initWithString:
            [NSString stringWithFormat:n.kind == JSONObject ? @"  {%lu}" : @"  [%lu]", (unsigned long)n.children.count]
            attributes:@{NSFontAttributeName: FTDataDigitsFont(), NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}]];
        return s;
    }
    NSString *text = container ? summary(n) : n.kind == JSONString ? [NSString stringWithFormat:@"\"%@\"", n.text] : n.text ?: @"";
    if (text.length > 300) text = [[text substringToIndex:300] stringByAppendingString:@"…"];
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" ⏎ "];
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: container || n.kind == JSONString ? f : FTDataDigitsFont(),
        NSForegroundColorAttributeName: container ? NSColor.tertiaryLabelColor : kindColor(n.kind)}];
}

- (void)outlineView:(NSOutlineView *)ov willDisplayCell:(NSTextFieldCell *)cell forTableColumn:(NSTableColumn *)col item:(id)item {
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
}
- (BOOL)outlineView:(NSOutlineView *)ov shouldEditTableColumn:(NSTableColumn *)c item:(id)item { return NO; }
- (void)outlineViewSelectionDidChange:(NSNotification *)n { [self updateInfo]; }

@end

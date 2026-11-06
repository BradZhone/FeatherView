#import "TreePreview+Private.h"
#import "Localization.h"

static const NSUInteger kSyncNodes = 30000;

@implementation TreePreview (Filter)

// Nodes whose key or value contains q, plus their ancestors (to reach them) and descendants (what matched).
static NSHashTable *visibleFor(JSONNode *root, NSString *q, NSUInteger *matches) {
    NSHashTable *keep = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger hits = 0;
    NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    while (stack.count) {
        JSONNode *n = stack.lastObject;
        [stack removeLastObject];
        BOOL hit = (n.key && [n.key rangeOfString:q options:o].location != NSNotFound) || (n.text && [n.text rangeOfString:q options:o].location != NSNotFound);
        if (hit) {
            hits++;
            for (JSONNode *a = n; a && ![keep containsObject:a]; a = a.parent) [keep addObject:a];
            NSMutableArray *sub = [NSMutableArray arrayWithArray:n.children ?: @[]];
            while (sub.count) { JSONNode *c = sub.lastObject; [sub removeLastObject]; [keep addObject:c]; if (c.children) [sub addObjectsFromArray:c.children]; }
            continue;                                          // its subtree is already in
        }
        if (n.children) [stack addObjectsFromArray:n.children];
    }
    *matches = hits;
    return keep;
}

- (NSString *)filterText { return _filter.stringValue; }
- (void)setFilterText:(NSString *)f { _filter.stringValue = f ?: @""; [self applyFilter]; }

- (void)controlTextDidChange:(NSNotification *)n {
    [_filterTimer invalidate];
    _filterTimer = [NSTimer scheduledTimerWithTimeInterval:_nodeCount > kSyncNodes ? 0.3 : 0.12 repeats:NO block:^(NSTimer *t) { [self applyFilter]; }];
}

- (void)applyFilter {
    NSString *q = [_filter.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSUInteger gen = ++_filterGen;
    if (!q.length || !_root) { _visible = nil; [_ov reloadData]; [self expandToDepth:2]; [self updateInfo]; return; }
    JSONNode *root = _root;
    void (^show)(NSHashTable *, NSUInteger) = ^(NSHashTable *keep, NSUInteger hits) {
        if (gen != self->_filterGen || root != self->_root) return;
        self->_visible = keep;
        [self->_ov reloadData];
        NSMutableArray *stack = [[self childrenOf:nil] mutableCopy];
        NSUInteger budget = 4000;                              // open the way to the matches
        while (stack.count && budget) {
            JSONNode *n = stack.lastObject;
            [stack removeLastObject];
            if (!n.children.count) continue;
            BOOL childHit = NO;
            for (JSONNode *c in n.children) if ([keep containsObject:c]) { childHit = YES; break; }
            if (!childHit) continue;
            [self->_ov expandItem:n];
            budget--;
            [stack addObjectsFromArray:[self childrenOf:n]];
        }
        [self updateInfoWithMatches:hits];
    };
    if (_nodeCount <= kSyncNodes) { NSUInteger h; NSHashTable *k = visibleFor(root, q, &h); show(k, h); return; }
    _info.stringValue = FTL(@"Filtering…");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger h;
        NSHashTable *k = visibleFor(root, q, &h);
        dispatch_async(dispatch_get_main_queue(), ^{ show(k, h); });
    });
}

- (void)updateInfo { [self updateInfoWithMatches:NSNotFound]; }

- (void)updateInfoWithMatches:(NSUInteger)hits {
    if (!_root) { _info.stringValue = @""; return; }
    NSMutableString *s = [NSMutableString stringWithFormat:FTLP(_nodeCount, @"%@ node", @"%@ nodes"), FTGrouped(_nodeCount)];
    if (hits != NSNotFound) [s appendFormat:FTLP(hits, @" · %@ match", @" · %@ matches"), FTGrouped(hits)];
    JSONNode *sel = _ov.selectedRow >= 0 ? [_ov itemAtRow:_ov.selectedRow] : nil;
    if (sel) [s appendFormat:@" · %@", sel.path];
    _info.stringValue = s;
}

#pragma mark Copy, menu, double click

static NSString *valueText(JSONNode *n) {
    if (n.kind == JSONObject || n.kind == JSONArray) return [n JSONStringPretty:YES];
    return n.text ?: @"";
}

- (void)copy:(id)sender {
    JSONNode *n = _ov.selectedRow >= 0 ? [_ov itemAtRow:_ov.selectedRow] : nil;
    if (n) FTCopyString(valueText(n));
}
- (BOOL)validateMenuItem:(NSMenuItem *)m { return m.action != @selector(copy:) || _ov.selectedRow >= 0; }

- (void)doubleClicked:(id)sender {
    JSONNode *n = _ov.clickedRow >= 0 ? [_ov itemAtRow:_ov.clickedRow] : nil;
    if (!n) return;
    if (n.children.count) { if ([_ov isItemExpanded:n]) [_ov collapseItem:n]; else [_ov expandItem:n]; return; }
    if (n.line && self.onJumpToLine) self.onJumpToLine(n.line);
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = _ov.clickedRow;
    JSONNode *n = row >= 0 ? [_ov itemAtRow:row] : nil;
    if (!n) return;
    [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    void (^add)(NSString *, void (^)(void)) = ^(NSString *t, void (^act)(void)) {
        NSMenuItem *i = [menu addItemWithTitle:t action:@selector(runMenuBlock:) keyEquivalent:@""];
        i.target = self;
        i.representedObject = act;
    };
    BOOL container = n.kind == JSONObject || n.kind == JSONArray;
    add(container ? FTL(@"Copy as JSON") : FTL(@"Copy Value"), ^{ FTCopyString(valueText(n)); });
    if (n.key) add(FTL(@"Copy Name"), ^{ FTCopyString(n.key); });
    add([NSString stringWithFormat:FTL(@"Copy Path  %@"), n.path.length > 40 ? [[n.path substringToIndex:40] stringByAppendingString:@"…"] : n.path], ^{ FTCopyString(n.path); });
    if (container && n.children.count) {
        [menu addItem:NSMenuItem.separatorItem];
        add(FTL(@"Expand All Children"), ^{ [self->_ov expandItem:n expandChildren:YES]; });
        add(FTL(@"Collapse"), ^{ [self->_ov collapseItem:n collapseChildren:YES]; });
    }
    if (n.line && self.onJumpToLine) {
        [menu addItem:NSMenuItem.separatorItem];
        add([NSString stringWithFormat:FTL(@"Show in Source (Line %lu)"), (unsigned long)n.line], ^{ self.onJumpToLine(n.line); });
    }
}

- (void)runMenuBlock:(NSMenuItem *)i { void (^b)(void) = i.representedObject; if (b) b(); }

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:) && _ov.numberOfRows) {
        [self.window makeFirstResponder:_ov];
        [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        return YES;
    }
    return NO;
}

@end

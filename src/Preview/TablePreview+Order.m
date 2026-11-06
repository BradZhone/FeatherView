#import "TablePreview+Private.h"
#import "Localization.h"

static const NSUInteger kSyncRows = 20000;

typedef struct { double num; __unsafe_unretained NSString *text; } SortKey;

@implementation TablePreview (Order)

static double numberOf(NSString *v, BOOL *ok) {
    NSString *t = [[v stringByReplacingOccurrencesOfString:@"," withString:@""]
                   stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" %$¥€"]];
    NSScanner *s = [NSScanner scannerWithString:t];
    double d = 0;
    *ok = t.length && [s scanDouble:&d] && s.isAtEnd;
    return d;
}

// Sorted and / or filtered row order, computed from an immutable model (safe off the main thread).
static NSMutableData *computeOrder(id<TableModel> m, NSInteger sortCol, BOOL asc, BOOL numeric, NSString *filter, NSInteger filterCol) {
    NSUInteger n = m.rowCount, cols = m.columnCount;
    NSMutableData *out = [NSMutableData dataWithCapacity:n * 4];
    for (NSUInteger r = 0; r < n; r++) {
        if (filter.length) {
            BOOL hit = NO;
            for (NSUInteger c = filterCol >= 0 ? (NSUInteger)filterCol : 0; c < (filterCol >= 0 ? (NSUInteger)filterCol + 1 : cols); c++)
                if ([[m cellAtRow:r column:c] rangeOfString:filter options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) { hit = YES; break; }
            if (!hit) continue;
        }
        uint32_t v = (uint32_t)r;
        [out appendBytes:&v length:4];
    }
    if (sortCol < 0) return out;
    NSUInteger k = out.length / 4;
    uint32_t *rows = out.mutableBytes;
    NSMutableArray *texts = [NSMutableArray arrayWithCapacity:k];         // keeps the strings alive for the keys
    SortKey *keys = calloc(MAX(n, (NSUInteger)1), sizeof(SortKey));
    for (NSUInteger i = 0; i < k; i++) {
        NSString *v = [m cellAtRow:rows[i] column:(NSUInteger)sortCol];
        [texts addObject:v];
        BOOL ok = NO;
        keys[rows[i]].num = numeric ? numberOf(v, &ok) : 0;
        if (numeric && !ok) keys[rows[i]].num = asc ? INFINITY : -INFINITY;   // blanks last either way
        keys[rows[i]].text = v;
    }
    NSMutableArray *boxed = [NSMutableArray arrayWithCapacity:k];
    for (NSUInteger i = 0; i < k; i++) [boxed addObject:@(rows[i])];
    [boxed sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        SortKey x = keys[a.unsignedIntValue], y = keys[b.unsignedIntValue];
        NSComparisonResult r = numeric ? (x.num < y.num ? NSOrderedAscending : x.num > y.num ? NSOrderedDescending : NSOrderedSame)
                                       : [x.text localizedStandardCompare:y.text];
        if (!x.text.length != !y.text.length) return x.text.length ? NSOrderedAscending : NSOrderedDescending;   // blanks last
        return asc ? r : -r;
    }];
    for (NSUInteger i = 0; i < k; i++) rows[i] = [boxed[i] unsignedIntValue];
    free(keys);
    (void)texts;
    return out;
}

// "列名:文字" filters one column; otherwise every column.
- (NSString *)filterForColumn:(NSInteger *)col {
    NSString *f = [_filter.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    *col = -1;
    NSRange colon = [f rangeOfString:@":"];
    if (colon.location == NSNotFound) colon = [f rangeOfString:@"："];
    if (colon.location != NSNotFound && colon.location > 0) {
        NSString *name = [[f substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSUInteger c = 0; c < _model.columnCount; c++)
            if ([[_model headerForColumn:c] caseInsensitiveCompare:name] == NSOrderedSame) {
                *col = (NSInteger)c;
                return [[f substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
    }
    return f;
}

- (void)applyOrder {
    NSInteger fcol;
    NSString *filter = [self filterForColumn:&fcol];
    NSUInteger gen = ++_orderGen;
    NSPoint scroll = _scroll.contentView.bounds.origin;
    BOOL keep = _keepScroll;
    _keepScroll = NO;
    if (_sortColumn < 0 && !filter.length) { _order = nil; [self finishOrder:scroll keep:keep]; return; }
    id<TableModel> m = _model;
    NSInteger sc = _sortColumn;
    BOOL asc = _sortAscending, numeric = sc >= 0 && [self columnIsNumeric:(NSUInteger)sc];
    if (m.rowCount <= kSyncRows) { _order = computeOrder(m, sc, asc, numeric, filter, fcol); [self finishOrder:scroll keep:keep]; return; }
    _working = YES;
    [self updateInfo];
    __weak TablePreview *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *o = computeOrder(m, sc, asc, numeric, filter, fcol);
        dispatch_async(dispatch_get_main_queue(), ^{
            TablePreview *me = weakSelf;
            if (!me || me->_orderGen != gen || me->_model != m) return;
            me->_working = NO;
            me->_order = o;
            [me finishOrder:scroll keep:keep];
        });
    });
}

- (void)finishOrder:(NSPoint)scroll keep:(BOOL)keep {
    [_table reloadData];
    if (keep) [_scroll.contentView scrollToPoint:scroll]; else [_table scrollRowToVisible:0];
    [_scroll reflectScrolledClipView:_scroll.contentView];
    [self updateInfo];
}

- (void)updateInfo {
    if (!_model) { _info.stringValue = @""; return; }
    if (!_model.rowCount && !_model.columnCount) {
        _info.stringValue = self.extraInfo.length ? [FTL(@"Empty table · ") stringByAppendingString:self.extraInfo] : FTL(@"Empty table");
        return;
    }
    NSMutableString *s = [NSMutableString string];
    NSUInteger shown = self.visibleRowCount, total = _model.rowCount;
    if (_order && shown != total) [s appendFormat:FTL(@"%@ of %@ rows"), FTGrouped(shown), FTGrouped(total)];
    else [s appendFormat:FTLP(total, @"%@ row", @"%@ rows"), FTGrouped(total)];
    [s appendFormat:FTLP(_model.columnCount, @" × %@ column", @" × %@ columns"), FTGrouped(_model.columnCount)];
    if ([_model respondsToSelector:@selector(truncated)] && _model.truncated) [s appendString:FTL(@" (file too large, only the beginning was read)")];
    if ([_model isKindOfClass:JSONLinesTable.class] && [(JSONLinesTable *)_model badLines])
        [s appendFormat:FTLP([(JSONLinesTable *)_model badLines], @" · %lu line is not a JSON object", @" · %lu lines are not JSON objects"), (unsigned long)[(JSONLinesTable *)_model badLines]];
    if (self.extraInfo.length) [s appendFormat:@" · %@", self.extraInfo];
    if (_working) [s appendString:FTL(@" · Working…")];
    _info.stringValue = s;
}

- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)old {
    NSSortDescriptor *d = t.sortDescriptors.firstObject;
    NSInteger col = d ? d.key.integerValue : -1;
    if (col == _sortColumn && d.ascending == _sortAscending) return;
    _sortColumn = col;
    _sortAscending = d ? d.ascending : YES;
    [self applyOrder];
}

#pragma mark Filter

- (NSString *)filterText { return _filter.stringValue; }
- (void)setFilterText:(NSString *)f { _filter.stringValue = f ?: @""; [self applyOrder]; }

- (void)controlTextDidChange:(NSNotification *)n {
    [_filterTimer invalidate];
    _filterTimer = [NSTimer scheduledTimerWithTimeInterval:_model.rowCount > kSyncRows ? 0.3 : 0.12 repeats:NO block:^(NSTimer *t) { [self applyOrder]; }];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:) && self.visibleRowCount) {
        [self.window makeFirstResponder:_table];
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        return YES;
    }
    return NO;
}

#pragma mark Copy, menu, double click

- (NSString *)rowsAsTSV:(NSIndexSet *)rows {
    NSMutableString *s = [NSMutableString string];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        NSUInteger r = [self modelRow:(NSInteger)row];
        if (r == NSNotFound) return;
        NSMutableArray *cells = [NSMutableArray array];
        for (NSUInteger c = 0; c < self->_model.columnCount; c++) [cells addObject:[[self->_model cellAtRow:r column:c] stringByReplacingOccurrencesOfString:@"\t" withString:@" "]];
        [s appendFormat:@"%@\n", [cells componentsJoinedByString:@"\t"]];
    }];
    return s;
}

- (void)copy:(id)sender {
    if (_table.selectedRowIndexes.count) FTCopyString([self rowsAsTSV:_table.selectedRowIndexes]);
}
- (BOOL)validateMenuItem:(NSMenuItem *)m { return m.action != @selector(copy:) || _table.selectedRowIndexes.count > 0; }

- (void)doubleClicked:(id)sender {
    NSUInteger r = [self modelRow:_table.clickedRow];
    if (r == NSNotFound) return;
    NSUInteger line = [_model respondsToSelector:@selector(sourceLineOfRow:)] ? [_model sourceLineOfRow:r] : 0;
    if (line && self.onJumpToLine) self.onJumpToLine(line);
    else if (self.onActivateRow) self.onActivateRow(r);
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = _table.clickedRow, colIndex = _table.clickedColumn;
    if (row < 0) return;
    if (![_table.selectedRowIndexes containsIndex:(NSUInteger)row]) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    NSTableColumn *col = colIndex >= 0 ? _table.tableColumns[colIndex] : nil;
    NSUInteger r = [self modelRow:row];
    NSMenuItem *(^add)(NSString *, void (^)(void)) = ^NSMenuItem *(NSString *t, void (^act)(void)) {
        NSMenuItem *i = [menu addItemWithTitle:t action:@selector(runMenuBlock:) keyEquivalent:@""];
        i.target = self;
        i.representedObject = act;
        return i;
    };
    if (col && ![col.identifier isEqualToString:@"#"]) {
        NSString *v = [_model cellAtRow:r column:(NSUInteger)col.identifier.integerValue];
        add(FTL(@"Copy Cell"), ^{ FTCopyString(v); });
        NSString *name = [_model headerForColumn:(NSUInteger)col.identifier.integerValue];
        add([NSString stringWithFormat:FTL(@"Show Only Rows with This “%@”"), name.length > 16 ? [[name substringToIndex:16] stringByAppendingString:@"…"] : name], ^{
            self.filterText = [NSString stringWithFormat:@"%@:%@", name, v];
        });
    }
    NSIndexSet *sel = _table.selectedRowIndexes;
    add(sel.count > 1 ? [NSString stringWithFormat:FTL(@"Copy %lu Rows (TSV)"), (unsigned long)sel.count] : FTL(@"Copy Row (TSV)"), ^{ FTCopyString([self rowsAsTSV:sel]); });
    NSUInteger line = [_model respondsToSelector:@selector(sourceLineOfRow:)] ? [_model sourceLineOfRow:r] : 0;
    if (line && self.onJumpToLine) {
        [menu addItem:NSMenuItem.separatorItem];
        add([NSString stringWithFormat:FTL(@"Show in Source (Line %lu)"), (unsigned long)line], ^{ self.onJumpToLine(line); });
    }
    if (_sortColumn >= 0) add(FTL(@"Restore File Order"), ^{ [self sortByColumn:-1 ascending:YES]; });
}

- (void)runMenuBlock:(NSMenuItem *)i { void (^b)(void) = i.representedObject; if (b) b(); }

@end

@implementation TablePreview (Sorting)

- (void)sortByColumn:(NSInteger)column ascending:(BOOL)ascending {
    _sortColumn = column;
    _sortAscending = ascending;
    _table.sortDescriptors = column < 0 ? @[] : @[[NSSortDescriptor sortDescriptorWithKey:[NSString stringWithFormat:@"%ld", (long)column] ascending:ascending]];
    [self applyOrder];
}

@end

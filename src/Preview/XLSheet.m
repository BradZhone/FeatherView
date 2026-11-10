#import "XLWorkbook+Private.h"
#import "Localization.h"
#include <stdlib.h>

static int cmpCell(const void *a, const void *b) {
    uint64_t x = ((const XLCell *)a)->key, y = ((const XLCell *)b)->key;
    return x < y ? -1 : x > y;
}

static int cmpRow(const void *a, const void *b) {
    uint32_t x = ((const XLRow *)a)->row, y = ((const XLRow *)b)->row;
    return x < y ? -1 : x > y;
}

static BOOL parseRange(NSString *s, XLRange *r) {
    NSArray *p = [s componentsSeparatedByString:@":"];
    if (!p.count || !XLParseRefString(p[0], &r->row, &r->col)) return NO;
    if (p.count < 2 || !XLParseRefString(p[1], &r->lastRow, &r->lastCol)) { r->lastRow = r->row; r->lastCol = r->col; }
    if (r->lastRow < r->row) { NSUInteger t = r->row; r->row = r->lastRow; r->lastRow = t; }
    if (r->lastCol < r->col) { NSUInteger t = r->col; r->col = r->lastCol; r->lastCol = t; }
    return YES;
}

@implementation XLSheet

- (instancetype)initWithName:(NSString *)name path:(NSString *)path book:(XLWorkbook *)book hidden:(BOOL)hidden chart:(BOOL)chart {
    if (!(self = [super init])) return nil;
    _name = [name copy]; _path = [path copy]; _book = book; _hidden = hidden; _isChart = chart;
    _strings = [NSMutableArray array];
    _formulas = [NSMutableDictionary dictionary]; _sharedMaster = [NSMutableDictionary dictionary]; _sharedOf = [NSMutableDictionary dictionary];
    _mastersWithChildren = [NSMutableIndexSet indexSet];
    _arrays = [NSMutableArray array]; _tableHeads = [NSMutableArray array]; _mergeList = [NSMutableArray array];
    _mergeAt = [NSMutableDictionary dictionary];
    _colWidth = [NSMutableDictionary dictionary]; _rowHeight = [NSMutableDictionary dictionary]; _colStyle = [NSMutableDictionary dictionary];
    _hiddenCols = [NSMutableIndexSet indexSet]; _hiddenRows = [NSMutableIndexSet indexSet];
    _edits = [NSMutableDictionary dictionary];
    _display = [NSCache new]; _display.countLimit = 20000;
    _showGridLines = YES; _defaultRowHeight = 15; _defaultColWidth = 8.43; _prefix = @"";
    _usedRows = _usedCols = 1;
    return self;
}

- (void)dealloc { free(_cells); free(_rows); }

- (void)ensureLoaded {
    if (_loaded) return;
    _loaded = YES;
    if (_isChart) return;
    XLWorkbook *b = _book;
    NSData *xml = [b->_zip dataForEntry:_path];
    if (!xml) { _truncated = YES; return; }
    [self parse:xml];
    NSDictionary *rels = XLRels(b->_zip, _path);
    for (NSArray *r in rels.allValues) if ([r[0] isEqual:@"table"]) [self addTable:[b->_zip dataForEntry:r[1]]];
}

- (void)parse:(NSData *)data {
    const uint8_t *x = data.bytes;
    NSUInteger n = data.length, i = 0, cap = 0, rowCap = 0;
    XLTag t;
    NSUInteger curRow = 0, nextCol = 0, rowsSeen = 0;
    BOOL inRow = NO;
    XLRow row = {0};
    NSMutableDictionary<NSString *, NSNumber *> *seen = [NSMutableDictionary dictionary];   // one copy of repeated text
    NSUInteger (^intern)(NSString *) = ^NSUInteger(NSString *v) {
        NSNumber *k = seen[v];
        if (k) return k.unsignedIntegerValue;
        [self->_strings addObject:v];
        if (seen.count < 200000) seen[v] = @(self->_strings.count - 1);
        return self->_strings.count - 1;
    };
    while (XLNextTag(x, n, i, &t)) @autoreleasepool {                                  // a large sheet makes millions of small strings
        i = t.end;
        if (XLTagIs(x, &t, "sheetProtection") && !t.closing) { NSString *v = XLAttr(x, &t, "sheet"); _protected = [v isEqual:@"1"] || [v isEqual:@"true"]; }
        else if (XLTagIs(x, &t, "dimension") && !t.closing) {
            NSRange r; if (XLAttrRange(x, &t, "ref", &r)) { _dimOff = r.location; _dimLen = r.length; }
        } else if (XLTagIs(x, &t, "sheetView") && !t.closing) { NSString *g = XLAttr(x, &t, "showGridLines"); if ([g isEqual:@"0"] || [g isEqual:@"false"]) _showGridLines = NO; }
        else if (XLTagIs(x, &t, "pane") && !t.closing) {
            NSString *st = XLAttr(x, &t, "state");
            if ([st isEqual:@"frozen"] || [st isEqual:@"frozenSplit"]) { _frozenColumns = (NSUInteger)XLAttr(x, &t, "xSplit").integerValue; _frozenRows = (NSUInteger)XLAttr(x, &t, "ySplit").integerValue; }
        } else if (XLTagIs(x, &t, "sheetFormatPr") && !t.closing) {
            double h = XLAttr(x, &t, "defaultRowHeight").doubleValue, w = XLAttr(x, &t, "defaultColWidth").doubleValue, bw = XLAttr(x, &t, "baseColWidth").doubleValue;
            if (h > 0) _defaultRowHeight = h;
            if (w > 0) _defaultColWidth = w; else if (bw > 0) _defaultColWidth = bw + 0.71;
        } else if (XLTagIs(x, &t, "col") && !t.closing) {
            NSUInteger a = (NSUInteger)MAX(1, XLAttr(x, &t, "min").integerValue), z = (NSUInteger)MIN(16384, MAX((NSInteger)a, XLAttr(x, &t, "max").integerValue));
            double w = XLAttr(x, &t, "width").doubleValue;
            NSString *h = XLAttr(x, &t, "hidden"), *st = XLAttr(x, &t, "style");
            BOOL hide = [h isEqual:@"1"] || [h isEqual:@"true"];
            for (NSUInteger c = a; c <= z && c - a < 1024; c++) {                 // a <col> over all 16384 columns only matters for the first ones
                if (w > 0) _colWidth[@(c - 1)] = @(w);
                if (st) _colStyle[@(c - 1)] = @(st.integerValue);
                if (hide) [_hiddenCols addIndex:c - 1];
            }
        } else if (XLTagIs(x, &t, "sheetData")) {
            if (t.selfClosing) { _sheetDataSelfClosing = YES; _sheetDataOff = t.start; _sheetDataLen = t.end - t.start; _sheetDataClose = t.start; _prefix = XLPrefix(x, &t); }
            else if (t.closing) _sheetDataClose = t.start;
            else { _sheetDataOff = t.start; _sheetDataLen = t.end - t.start; _prefix = XLPrefix(x, &t); }
        } else if (XLTagIs(x, &t, "row")) {
            if (t.closing) { if (inRow) { row.closeOff = (uint32_t)t.start; inRow = NO; [self pushRow:row cap:&rowCap]; } continue; }
            NSString *r = XLAttr(x, &t, "r");
            curRow = r ? (NSUInteger)MAX(1, r.integerValue) - 1 : (rowsSeen ? curRow + 1 : 0);
            rowsSeen++;
            nextCol = 0;
            memset(&row, 0, sizeof row);
            row.row = (uint32_t)curRow; row.openOff = (uint32_t)t.start; row.openLen = (uint32_t)(t.end - t.start);
            NSString *ht = XLAttr(x, &t, "ht"), *hid = XLAttr(x, &t, "hidden"), *cf = XLAttr(x, &t, "customFormat"), *rs = XLAttr(x, &t, "s");
            if (ht.doubleValue > 0) _rowHeight[@(curRow)] = @(ht.doubleValue);
            if ([hid isEqual:@"1"] || [hid isEqual:@"true"]) [_hiddenRows addIndex:curRow];
            row.customFormat = [cf isEqual:@"1"] || [cf isEqual:@"true"];
            row.style = (uint32_t)rs.integerValue;
            if (t.selfClosing) { row.selfClosing = YES; row.closeOff = (uint32_t)t.end; [self pushRow:row cap:&rowCap]; }
            else inRow = YES;
        } else if (XLTagIs(x, &t, "c") && !t.closing) {
            if (_cellCount >= kXLMaxCells) { _truncated = YES; break; }
            XLCell c = {0};
            c.str = UINT32_MAX;
            NSUInteger rr = curRow, cc = nextCol;
            NSRange ref;
            if (XLAttrRange(x, &t, "r", &ref)) XLParseRef(x + ref.location, ref.length, &rr, &cc);
            nextCol = cc + 1;
            c.key = XLKey(rr, cc);
            c.style = (uint32_t)XLAttr(x, &t, "s").integerValue;
            NSString *type = XLAttr(x, &t, "t") ?: @"n";
            NSUInteger elemEnd = t.end;
            NSString *v = nil, *f = nil, *inl = nil;
            NSMutableString *is = nil;
            if (!t.selfClosing) {
                XLTag u; NSUInteger j = t.end;
                while (XLNextTag(x, n, j, &u)) {
                    j = u.end;
                    if (XLTagIs(x, &u, "c") && u.closing) { elemEnd = u.end; break; }
                    if (u.closing) continue;
                    if (XLTagIs(x, &u, "v") && !u.selfClosing) { XLTag e; if (XLNextTag(x, n, u.end, &e)) { v = XLDecode(x + u.end, e.start - u.end); j = e.end; } }
                    else if (XLTagIs(x, &u, "f")) {
                        NSString *ft = XLAttr(x, &u, "t"), *si = XLAttr(x, &u, "si"), *fref = XLAttr(x, &u, "ref");
                        if (!u.selfClosing) { XLTag e; if (XLNextTag(x, n, u.end, &e)) { f = XLDecode(x + u.end, e.start - u.end); j = e.end; } }
                        c.flags |= XLFFormula;
                        if ([ft isEqual:@"shared"] && si) {
                            if (f.length) { c.flags |= XLFMaster; _sharedMaster[@(si.integerValue)] = @(c.key); }
                            else { c.flags |= XLFChild; _sharedOf[@(c.key)] = @(si.integerValue); [_mastersWithChildren addIndex:(NSUInteger)si.integerValue]; }
                        } else if ([ft isEqual:@"array"] && fref) {
                            XLRange ar; if (parseRange(fref, &ar)) [_arrays addObject:[NSValue valueWithBytes:&ar objCType:@encode(XLRange)]];
                        }
                    } else if (XLTagIs(x, &u, "is")) is = [NSMutableString string];
                    else if (is && XLTagIs(x, &u, "r")) c.flags |= XLFRich;
                    else if (is && XLTagIs(x, &u, "t") && !u.selfClosing) { XLTag e; if (XLNextTag(x, n, u.end, &e)) { [is appendString:XLDecode(x + u.end, e.start - u.end)]; j = e.end; } }
                }
                i = j;
                inl = is;
            }
            c.xmlOff = (uint32_t)t.start; c.xmlLen = (uint32_t)(elemEnd - t.start);
            if (f) _formulas[@(c.key)] = f;
            if ([type isEqual:@"s"]) {
                NSInteger k = v.integerValue;
                c.type = v && k >= 0 && (NSUInteger)k < _book->_shared.count ? XLString : XLEmpty;
                c.num = k; c.flags |= XLFShared;
                if ([_book->_sharedRich containsIndex:(NSUInteger)k]) c.flags |= XLFRich;
            } else if ([type isEqual:@"inlineStr"] || [type isEqual:@"str"]) {
                NSString *text = inl ?: v;
                if (text) { c.type = XLString; c.str = (uint32_t)intern(XLDecodeOOXML(text)); }
            } else if ([type isEqual:@"b"]) { if (v) { c.type = XLBool; c.num = v.integerValue != 0; } }
            else if ([type isEqual:@"e"]) { if (v) { c.type = XLError; c.str = (uint32_t)intern(v); } }
            else if ([type isEqual:@"d"]) {
                NSInteger y = 0, mo = 0, d = 0, h = 0, mi = 0; double sec = 0;
                if (v && sscanf(v.UTF8String, "%ld-%ld-%ldT%ld:%ld:%lf", &y, &mo, &d, &h, &mi, &sec) >= 3) {
                    c.type = XLNumber; c.num = XLDateToSerial(y, mo, d, (h * 3600 + mi * 60 + sec) / 86400.0, _book.date1904);
                }
            } else if (v.length) { c.type = XLNumber; c.num = strtod(v.UTF8String, NULL); }
            if (_cellCount == cap) { cap = MAX(1024, cap * 2); _cells = realloc(_cells, cap * sizeof(XLCell)); }
            _cells[_cellCount++] = c;
            if (c.type != XLEmpty || f) { _usedRows = MAX(_usedRows, rr + 1); _usedCols = MAX(_usedCols, cc + 1); }
        } else if (XLTagIs(x, &t, "mergeCell") && !t.closing) {
            XLRange r; if (parseRange(XLAttr(x, &t, "ref"), &r)) [self addMerge:r];
        }
    }
    qsort(_cells, _cellCount, sizeof(XLCell), cmpCell);
    qsort(_rows, _rowCount2, sizeof(XLRow), cmpRow);
    for (NSNumber *k in _sharedOf.copy) {                                  // a child's formula, shifted from its master
        NSNumber *m = _sharedMaster[_sharedOf[k]];
        NSString *mf = m ? _formulas[m] : nil;
        if (mf) _formulas[k] = XLShiftFormula(mf, (NSInteger)XLKeyRow(k.unsignedLongLongValue) - (NSInteger)XLKeyRow(m.unsignedLongLongValue),
                                                   (NSInteger)XLKeyCol(k.unsignedLongLongValue) - (NSInteger)XLKeyCol(m.unsignedLongLongValue));
    }
}

- (void)pushRow:(XLRow)row cap:(NSUInteger *)cap {
    if (_rowCount2 == *cap) { *cap = MAX(256, *cap * 2); _rows = realloc(_rows, *cap * sizeof(XLRow)); }
    _rows[_rowCount2++] = row;
}

- (const XLRow *)rowRecord:(NSUInteger)r {
    NSUInteger lo = 0, hi = _rowCount2;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (_rows[mid].row < r) lo = mid + 1; else hi = mid; }
    return lo < _rowCount2 && _rows[lo].row == r ? &_rows[lo] : NULL;
}

- (NSUInteger)rowIndexAfter:(NSUInteger)r {                     // first row record with a greater row number
    NSUInteger lo = 0, hi = _rowCount2;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (_rows[mid].row <= r) lo = mid + 1; else hi = mid; }
    return lo;
}

- (void)addMerge:(XLRange)r {
    [_mergeList addObject:[NSValue valueWithBytes:&r objCType:@encode(XLRange)]];
    _usedRows = MAX(_usedRows, r.lastRow + 1); _usedCols = MAX(_usedCols, r.lastCol + 1);
    NSValue *v = _mergeList.lastObject;
    if ((r.lastRow - r.row + 1) * (r.lastCol - r.col + 1) > 20000) { _mergeAt[@(XLKey(r.row, r.col))] = v; return; }
    for (NSUInteger a = r.row; a <= r.lastRow; a++) for (NSUInteger b = r.col; b <= r.lastCol; b++) _mergeAt[@(XLKey(a, b))] = v;
}

- (void)addTable:(NSData *)d {
    const uint8_t *x = d.bytes; NSUInteger n = d.length; XLTag t;
    if (!d || !XLNextTag(x, n, 0, &t)) return;
    while (!XLTagIs(x, &t, "table") && XLNextTag(x, n, t.end, &t)) {}
    if (!XLTagIs(x, &t, "table")) return;
    XLRange r;
    if (!parseRange(XLAttr(x, &t, "ref"), &r)) return;
    NSString *hc = XLAttr(x, &t, "headerRowCount"), *tc = XLAttr(x, &t, "totalsRowCount");
    if (!hc || hc.integerValue > 0) { XLRange h = {r.row, r.col, r.row, r.lastCol}; [_tableHeads addObject:[NSValue valueWithBytes:&h objCType:@encode(XLRange)]]; }
    if (tc.integerValue > 0) { XLRange h = {r.lastRow, r.col, r.lastRow, r.lastCol}; [_tableHeads addObject:[NSValue valueWithBytes:&h objCType:@encode(XLRange)]]; }
}

- (const XLCell *)cellAt:(NSUInteger)row col:(NSUInteger)col {
    [self ensureLoaded];
    uint64_t k = XLKey(row, col);
    NSUInteger lo = 0, hi = _cellCount;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if (_cells[mid].key < k) lo = mid + 1; else hi = mid;
    }
    return lo < _cellCount && _cells[lo].key == k ? &_cells[lo] : NULL;
}

- (NSUInteger)rowCount { [self ensureLoaded]; return _usedRows; }
- (NSUInteger)columnCount { [self ensureLoaded]; return _usedCols; }
- (NSUInteger)frozenRows { [self ensureLoaded]; return _frozenRows; }
- (NSUInteger)frozenColumns { [self ensureLoaded]; return _frozenColumns; }
- (BOOL)showGridLines { [self ensureLoaded]; return _showGridLines; }
- (double)defaultRowHeight { [self ensureLoaded]; return _defaultRowHeight; }
- (BOOL)truncated { [self ensureLoaded]; return _truncated; }
- (NSArray<NSValue *> *)merges { [self ensureLoaded]; return _mergeList; }

// Column widths are in characters of the default font's digit width (7 px for Calibri 11), plus padding.
- (double)widthOfColumn:(NSUInteger)c {
    [self ensureLoaded];
    if ([_hiddenCols containsIndex:c]) return 0;
    NSNumber *w = _colWidth[@(c)];
    double chars = w ? w.doubleValue : _defaultColWidth;
    double px = chars <= 0 ? 0 : floor(chars * 7 + 5);
    return px * 0.75;
}

- (double)heightOfRow:(NSUInteger)r {
    [self ensureLoaded];
    if ([_hiddenRows containsIndex:r]) return 0;
    NSNumber *h = _rowHeight[@(r)];
    return h ? h.doubleValue : _defaultRowHeight;
}

- (BOOL)mergeAt:(NSUInteger)row col:(NSUInteger)col range:(XLRange *)range {
    [self ensureLoaded];
    NSValue *v = _mergeAt[@(XLKey(row, col))];
    if (!v) for (NSValue *m in _mergeList) {                                        // huge merges are only indexed by their anchor
        XLRange r; [m getValue:&r];
        if (row >= r.row && row <= r.lastRow && col >= r.col && col <= r.lastCol && (r.lastRow - r.row + 1) * (r.lastCol - r.col + 1) > 20000) { v = m; break; }
    }
    if (!v) return NO;
    if (range) [v getValue:range];
    return YES;
}

- (NSString *)readOnlyReason {
    [self ensureLoaded];
    if (_isChart) return FTL(@"This is a chart sheet");
    if (_truncated) return FTL(@"This sheet is too large to edit here (only its first 2 million cells are shown)");
    if (_protected) return FTL(@"This sheet is protected");
    return nil;
}

@end

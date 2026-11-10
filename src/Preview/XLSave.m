#import "XLWorkbook+Private.h"
#import "Localization.h"

@interface XLPatch : NSObject
@property (nonatomic) NSUInteger off, len, order;
@property (nonatomic, copy) NSString *text;
@end
@implementation XLPatch @end

@implementation XLSheet (Save)

- (NSString *)cellXML:(XLEdit *)e row:(NSUInteger)row col:(NSUInteger)col style:(uint32_t)style {
    NSString *p = _prefix, *r = XLCellName(row, col);
    NSString *s = style ? [NSString stringWithFormat:@" s=\"%u\"", style] : @"";
    switch (e.kind) {
        case 0: return style ? [NSString stringWithFormat:@"<%@c r=\"%@\"%@/>", p, r, s] : @"";
        case 1: return [NSString stringWithFormat:@"<%@c r=\"%@\"%@><%@v>%@</%@v></%@c>", p, r, s, p, XLNumberString(e.number), p, p];
        case 3: return [NSString stringWithFormat:@"<%@c r=\"%@\"%@ t=\"b\"><%@v>%d</%@v></%@c>", p, r, s, p, e.number != 0, p, p];
        case 4: return [NSString stringWithFormat:@"<%@c r=\"%@\"%@><%@f>%@</%@f></%@c>", p, r, s, p, XLEscape(e.text), p, p];
        default: {
            NSString *t = e.text ?: @"";
            BOOL keep = t.length && ([t hasPrefix:@" "] || [t hasSuffix:@" "] || [t containsString:@"\n"] || [t containsString:@"  "]);
            return [NSString stringWithFormat:@"<%@c r=\"%@\"%@ t=\"inlineStr\"><%@is><%@t%@>%@</%@t></%@is></%@c>", p, r, s, p, p,
                    keep ? @" xml:space=\"preserve\"" : @"", XLEscape(t), p, p, p];
        }
    }
}

- (uint32_t)styleForNewCellAt:(NSUInteger)row col:(NSUInteger)col {
    const XLRow *r = [self rowRecord:row];
    if (r && r->customFormat) return r->style;
    NSNumber *cs = _colStyle[@(col)];
    return cs ? cs.unsignedIntValue : 0;
}

- (NSData *)patchedXML:(NSData *)xml error:(NSString **)error {
    if (!_edits.count) return xml;
    if (_truncated || !_loaded) { if (error) *error = FTL(@"This sheet can’t be saved here"); return nil; }
    NSMutableArray<XLPatch *> *patches = [NSMutableArray array];
    void (^patch)(NSUInteger, NSUInteger, NSString *) = ^(NSUInteger off, NSUInteger len, NSString *t) {
        XLPatch *p = [XLPatch new]; p.off = off; p.len = len; p.text = t; p.order = patches.count;
        [patches addObject:p];
    };
    // edits by row, each row's by column
    NSArray<NSNumber *> *keys = [_edits.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSString *> *newRows = [NSMutableArray array];                     // rows that don't exist yet, in order
    NSMutableDictionary<NSNumber *, NSMutableString *> *rowInsert = [NSMutableDictionary dictionary];   // new rows by insertion offset
    NSUInteger minR = NSUIntegerMax, minC = NSUIntegerMax, maxR = 0, maxC = 0;
    NSUInteger k = 0;
    while (k < keys.count) {
        NSUInteger row = XLKeyRow(keys[k].unsignedLongLongValue);
        NSUInteger end = k;
        while (end < keys.count && XLKeyRow(keys[end].unsignedLongLongValue) == row) end++;
        const XLRow *rr = [self rowRecord:row];
        NSMutableString *appendToRow = [NSMutableString string];        // new cells after the row's last cell
        for (NSUInteger q = k; q < end; q++) {
            uint64_t key = keys[q].unsignedLongLongValue;
            NSUInteger col = XLKeyCol(key);
            XLEdit *e = _edits[keys[q]];
            const XLCell *c = [self cellAt:row col:col];
            if (e.kind) { minR = MIN(minR, row); maxR = MAX(maxR, row); minC = MIN(minC, col); maxC = MAX(maxC, col); }
            if (c) { patch(c->xmlOff, c->xmlLen, [self cellXML:e row:row col:col style:c->style]); continue; }
            NSString *cx = [self cellXML:e row:row col:col style:[self styleForNewCellAt:row col:col]];
            if (!cx.length) continue;
            if (!rr) { [appendToRow appendString:cx]; continue; }
            // before the first existing cell of this row with a greater column
            const XLCell *next = NULL;
            NSUInteger lo = 0, hi = _cellCount; uint64_t want = XLKey(row, col + 1);
            while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (_cells[mid].key < want) lo = mid + 1; else hi = mid; }
            if (lo < _cellCount && XLKeyRow(_cells[lo].key) == row) next = &_cells[lo];
            if (next) patch(next->xmlOff, 0, cx);
            else [appendToRow appendString:cx];
        }
        if (appendToRow.length) {
            if (rr && !rr->selfClosing) patch(rr->closeOff, 0, appendToRow);
            else if (rr) {                                                               // <row …/> becomes <row …>cells</row>
                NSString *open = [[NSString alloc] initWithBytes:(const uint8_t *)xml.bytes + rr->openOff length:rr->openLen encoding:NSUTF8StringEncoding];
                NSRange sl = [open rangeOfString:@"/>" options:NSBackwardsSearch];
                if (sl.location == NSNotFound) { if (error) *error = FTL(@"Couldn’t update the sheet"); return nil; }
                patch(rr->openOff, rr->openLen, [NSString stringWithFormat:@"%@>%@</%@row>", [open substringToIndex:sl.location], appendToRow, _prefix]);
            } else {
                NSString *rowXML = [NSString stringWithFormat:@"<%@row r=\"%lu\">%@</%@row>", _prefix, (unsigned long)row + 1, appendToRow, _prefix];
                NSUInteger after = [self rowIndexAfter:row];
                NSUInteger off = after < _rowCount2 ? _rows[after].openOff : _sheetDataClose;
                if (_sheetDataSelfClosing) [newRows addObject:rowXML];
                else {
                    NSMutableString *m = rowInsert[@(off)];
                    if (!m) rowInsert[@(off)] = m = [NSMutableString string];
                    [m appendString:rowXML];
                }
            }
        }
        k = end;
    }
    for (NSNumber *off in rowInsert) patch(off.unsignedIntegerValue, 0, rowInsert[off]);
    if (_sheetDataSelfClosing && newRows.count)
        patch(_sheetDataOff, _sheetDataLen, [NSString stringWithFormat:@"<%@sheetData>%@</%@sheetData>", _prefix, [newRows componentsJoinedByString:@""], _prefix]);
    if (_dimLen && minR != NSUIntegerMax) {                                          // <dimension ref> covers the new cells
        NSString *cur = [[NSString alloc] initWithBytes:(const uint8_t *)xml.bytes + _dimOff length:_dimLen encoding:NSUTF8StringEncoding];
        NSArray *p = [cur componentsSeparatedByString:@":"];
        NSUInteger r0, c0, r1, c1;
        if (p.count && XLParseRefString(p[0], &r0, &c0)) {
            if (!(p.count > 1 && XLParseRefString(p[1], &r1, &c1))) { r1 = r0; c1 = c0; }
            BOOL empty = _cellCount == 0;
            NSUInteger a = empty ? minR : MIN(r0, minR), b = empty ? minC : MIN(c0, minC), c = empty ? maxR : MAX(r1, maxR), d = empty ? maxC : MAX(c1, maxC);
            NSString *ref = a == c && b == d ? XLCellName(a, b) : [NSString stringWithFormat:@"%@:%@", XLCellName(a, b), XLCellName(c, d)];
            if (![ref isEqualToString:cur]) patch(_dimOff, _dimLen, ref);
        }
    }
    [patches sortUsingComparator:^NSComparisonResult(XLPatch *a, XLPatch *b) {
        if (a.off != b.off) return a.off < b.off ? NSOrderedAscending : NSOrderedDescending;
        if (a.len != b.len) return a.len < b.len ? NSOrderedAscending : NSOrderedDescending;   // insertions before a replacement there
        return a.order < b.order ? NSOrderedAscending : a.order > b.order;
    }];
    NSMutableData *out = [NSMutableData dataWithCapacity:xml.length + 4096];
    const uint8_t *x = xml.bytes;
    NSUInteger pos = 0;
    for (XLPatch *p in patches) {
        if (p.off < pos || p.off + p.len > xml.length) { if (error) *error = FTL(@"Couldn’t update the sheet"); return nil; }
        [out appendBytes:x + pos length:p.off - pos];
        [out appendData:[p.text dataUsingEncoding:NSUTF8StringEncoding]];
        pos = p.off + p.len;
    }
    [out appendBytes:x + pos length:xml.length - pos];
    return out;
}

@end

@implementation XLWorkbook (Save)

static NSData *replacing(NSData *d, NSUInteger off, NSUInteger len, NSString *with) {
    NSMutableData *m = [d mutableCopy];
    NSData *w = [with dataUsingEncoding:NSUTF8StringEncoding];
    [m replaceBytesInRange:NSMakeRange(off, len) withBytes:w.bytes length:w.length];
    return m;
}

// <calcPr fullCalcOnLoad="1"/>: Excel and Numbers recompute every formula when the file is opened.
- (NSData *)workbookAskingToRecalculate:(NSData *)wb {
    const uint8_t *x = wb.bytes; NSUInteger n = wb.length, i = 0;
    XLTag t, calc = {0}, before = {0}, root = {0};
    BOOL haveCalc = NO, haveBefore = NO, haveRoot = NO;
    NSString *prefix = @"";
    while (XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (XLTagIs(x, &t, "workbook") && t.closing) { root = t; haveRoot = YES; }
        else if (XLTagIs(x, &t, "workbook")) prefix = XLPrefix(x, &t);
        else if (XLTagIs(x, &t, "calcPr") && !t.closing) { calc = t; haveCalc = YES; }
        else if (!haveBefore && !t.closing && (XLTagIs(x, &t, "oleSize") || XLTagIs(x, &t, "customWorkbookViews") || XLTagIs(x, &t, "pivotCaches") ||
                 XLTagIs(x, &t, "smartTagPr") || XLTagIs(x, &t, "smartTagTypes") || XLTagIs(x, &t, "webPublishing") || XLTagIs(x, &t, "fileRecoveryPr") ||
                 XLTagIs(x, &t, "webPublishObjects") || XLTagIs(x, &t, "extLst"))) { before = t; haveBefore = YES; }
    }
    if (haveCalc) {
        NSRange v;
        if (XLAttrRange(x, &calc, "fullCalcOnLoad", &v)) return replacing(wb, v.location, v.length, @"1");
        return replacing(wb, calc.attrStart, 0, @" fullCalcOnLoad=\"1\"");
    }
    NSString *tag = [NSString stringWithFormat:@"<%@calcPr fullCalcOnLoad=\"1\"/>", prefix];
    if (haveBefore) return replacing(wb, before.start, 0, tag);
    if (haveRoot) return replacing(wb, root.start, 0, tag);
    return wb;
}

static NSData *withoutElements(NSData *d, const char *local, NSString *(^attr)(const uint8_t *, const XLTag *), NSString *value) {
    const uint8_t *x = d.bytes; NSUInteger n = d.length, i = 0;
    XLTag t;
    while (d && XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (!t.closing && XLTagIs(x, &t, local) && [attr(x, &t) isEqualToString:value]) {
            NSUInteger end = t.end;
            if (!t.selfClosing) { XLTag e; NSUInteger j = t.end; while (XLNextTag(x, n, j, &e)) { j = e.end; if (e.closing && XLTagIs(x, &e, local)) { end = e.end; break; } } }
            return replacing(d, t.start, end - t.start, @"");
        }
    }
    return d;
}

- (NSData *)savedData:(NSString **)error {
    NSMutableDictionary<NSString *, NSData *> *repl = [NSMutableDictionary dictionary];
    NSMutableSet *removed = [NSMutableSet set];
    for (XLSheet *s in self.sheets) {
        if (!s->_edits.count) continue;
        NSData *xml = [_zip dataForEntry:s->_path];
        NSData *patched = xml ? [s patchedXML:xml error:error] : nil;
        if (!patched) { if (error && !*error) *error = FTL(@"Couldn’t read the sheet"); return nil; }
        repl[s->_path] = patched;
    }
    if (!repl.count) return nil;
    NSData *wb = [_zip dataForEntry:_workbookPath];
    if (wb) repl[_workbookPath] = [self workbookAskingToRecalculate:wb];
    // the calculation chain lists formula cells; it is optional and Excel rebuilds it, a stale one is reported as damage
    NSString *rels = [[_workbookPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"_rels"] stringByAppendingPathComponent:[_workbookPath.lastPathComponent stringByAppendingString:@".rels"]];
    NSDictionary *r = XLRels(_zip, _workbookPath);
    for (NSString *rid in r) {
        if (![r[rid][0] isEqual:@"calcChain"]) continue;
        NSString *part = r[rid][1];
        [removed addObject:part];
        repl[rels] = withoutElements([_zip dataForEntry:rels], "Relationship", ^NSString *(const uint8_t *x, const XLTag *t) { return XLAttr(x, t, "Id"); }, rid);
        NSData *ct = [_zip dataForEntry:@"[Content_Types].xml"];
        if (ct) repl[@"[Content_Types].xml"] = withoutElements(ct, "Override", ^NSString *(const uint8_t *x, const XLTag *t) { return XLAttr(x, t, "PartName"); }, [@"/" stringByAppendingString:part]);
    }
    NSString *zerr = nil;
    NSData *out = [_zip dataReplacing:repl removing:removed error:&zerr];
    if (!out && error) *error = zerr ?: FTL(@"Couldn’t write the workbook");
    return out;
}

@end

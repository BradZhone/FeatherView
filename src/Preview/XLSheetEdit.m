#import "XLWorkbook+Private.h"
#import "Localization.h"
#include <xlocale.h>
#include <math.h>

NSString *XLNumberString(double v) {
    char b[40];
    snprintf_l(b, sizeof b, NULL, "%.15g", v);
    if (strtod_l(b, NULL, NULL) != v) snprintf_l(b, sizeof b, NULL, "%.17g", v);
    return @(b);
}

// A1 references in a formula moved by (dRow, dCol), except $-anchored parts; text in quotes is left alone.
NSString *XLShiftFormula(NSString *f, NSInteger dr, NSInteger dc) {
    if (!dr && !dc) return f;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(?<![A-Za-z0-9_.$])(\\$?)([A-Za-z]{1,3})(\\$?)([0-9]{1,7})(?![A-Za-z0-9_(])" options:0 error:nil];
    });
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = f.length;
    while (i < n) {
        unichar q = [f characterAtIndex:i];
        if (q == '"' || q == '\'') {                                            // "text" or 'Sheet name'
            NSUInteger j = i + 1;
            while (j < n && [f characterAtIndex:j] != q) j++;
            [out appendString:[f substringWithRange:NSMakeRange(i, MIN(j + 1, n) - i)]];
            i = j + 1; continue;
        }
        NSUInteger j = i;
        while (j < n && [f characterAtIndex:j] != '"' && [f characterAtIndex:j] != '\'') j++;
        NSString *seg = [f substringWithRange:NSMakeRange(i, j - i)];
        NSMutableString *res = [NSMutableString string];
        __block NSUInteger last = 0;
        [re enumerateMatchesInString:seg options:0 range:NSMakeRange(0, seg.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags fl, BOOL *stop) {
            [res appendString:[seg substringWithRange:NSMakeRange(last, m.range.location - last)]];
            last = NSMaxRange(m.range);
            NSString *colS = [seg substringWithRange:[m rangeAtIndex:2]].uppercaseString;
            NSInteger col = 0;
            for (NSUInteger k = 0; k < colS.length; k++) col = col * 26 + ([colS characterAtIndex:k] - 'A' + 1);
            NSInteger row = [seg substringWithRange:[m rangeAtIndex:4]].integerValue;
            BOOL absC = [m rangeAtIndex:1].length > 0, absR = [m rangeAtIndex:3].length > 0;
            if (col > 16384 || row < 1 || row > 1048576) { [res appendString:[seg substringWithRange:m.range]]; return; }
            if (!absC) col += dc;
            if (!absR) row += dr;
            if (col < 1 || row < 1) { [res appendString:@"#REF!"]; return; }
            [res appendFormat:@"%@%@%@%ld", absC ? @"$" : @"", XLColumnName((NSUInteger)col - 1), absR ? @"$" : @"", (long)row];
        }];
        [res appendString:[seg substringFromIndex:last]];
        [out appendString:res];
        i = j;
    }
    return out;
}

static BOOL looksSpecial(NSString *s) {                  // text that would read back as something else
    if (!s.length) return NO;
    unichar c = [s characterAtIndex:0];
    if (c == '=' || c == '\'' ) return YES;
    if ([s caseInsensitiveCompare:@"TRUE"] == NSOrderedSame || [s caseInsensitiveCompare:@"FALSE"] == NSOrderedSame) return YES;
    char *end = NULL;
    const char *u = [s stringByReplacingOccurrencesOfString:@"," withString:@""].UTF8String;
    strtod_l(u, &end, NULL);
    return end && end != u && (*end == 0 || (*end == '%' && end[1] == 0));
}

@implementation XLSheet (Edit)

- (XLStyle *)styleAt:(NSUInteger)row col:(NSUInteger)col {
    const XLCell *c = [self cellAt:row col:col];
    XLWorkbook *b = _book;
    if (c) return [b style:c->style];
    const XLRow *r = [self rowRecord:row];
    if (r && r->customFormat) return [b style:r->style];
    NSNumber *cs = _colStyle[@(col)];
    return [b style:cs ? cs.unsignedIntegerValue : 0];
}

- (XLType)typeAt:(NSUInteger)row col:(NSUInteger)col {
    XLEdit *e = _edits[@(XLKey(row, col))];
    if (e) return e.kind == 1 ? XLNumber : e.kind == 2 ? XLString : e.kind == 3 ? XLBool : e.kind == 4 ? XLString : XLEmpty;
    const XLCell *c = [self cellAt:row col:col];
    return c ? c->type : XLEmpty;
}

- (BOOL)isEditedAt:(NSUInteger)row col:(NSUInteger)col { return _edits[@(XLKey(row, col))] != nil; }

- (BOOL)isUncomputedFormulaAt:(NSUInteger)row col:(NSUInteger)col {
    XLEdit *e = _edits[@(XLKey(row, col))];
    if (e) return e.kind == 4;
    const XLCell *c = [self cellAt:row col:col];
    return c && (c->flags & XLFFormula) && c->type == XLEmpty && _formulas[@(c->key)];
}

- (NSString *)stringOf:(const XLCell *)c {
    XLWorkbook *b = _book;
    if (c->flags & XLFShared) { NSUInteger k = (NSUInteger)c->num; return k < b->_shared.count ? b->_shared[k] : @""; }
    return c->str < _strings.count ? _strings[c->str] : @"";
}

- (NSString *)displayAt:(NSUInteger)row col:(NSUInteger)col colour:(uint32_t *)colour {
    NSNumber *key = @(XLKey(row, col));
    NSArray *hit = [_display objectForKey:key];
    if (hit) { if (colour) *colour = [hit[1] unsignedIntValue]; return hit[0]; }
    XLStyle *st = [self styleAt:row col:col];
    XLWorkbook *b = _book;
    uint32_t col32 = 0;
    NSString *s = @"";
    XLEdit *e = _edits[key];
    const XLCell *c = e ? NULL : [self cellAt:row col:col];
    if (e) {
        if (e.kind == 1) s = XLFormatNumber(e.number, st.numberFormat, b.date1904, &col32);
        else if (e.kind == 2) s = XLFormatText(e.text, st.numberFormat);
        else if (e.kind == 3) s = e.number ? @"TRUE" : @"FALSE";
        else if (e.kind == 4) s = [@"=" stringByAppendingString:e.text];           // not computed here
    } else if (c) {
        switch (c->type) {
            case XLNumber: s = XLFormatNumber(c->num, st.numberFormat, b.date1904, &col32); break;
            case XLString: s = XLFormatText([self stringOf:c], st.numberFormat); break;
            case XLBool: s = c->num ? @"TRUE" : @"FALSE"; break;
            case XLError: s = [self stringOf:c]; break;
            case XLEmpty: { NSString *f = _formulas[@(c->key)]; if (f) s = [@"=" stringByAppendingString:f]; break; }   // saved without values
        }
    }
    [_display setObject:@[s, @(col32)] forKey:key];
    if (colour) *colour = col32;
    return s;
}

- (NSString *)textForNumber:(double)v style:(XLStyle *)st {
    if (st.isDate) {
        NSDateComponents *d = [NSDateComponents new];
        if (XLSerialToDate(v, _book.date1904, d)) {
            BOOL time = fabs(v - floor(v)) > 1e-9, date = v >= 1;
            NSString *ds = [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)d.year, (long)d.month, (long)d.day];
            NSString *ts = d.second ? [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)d.hour, (long)d.minute, (long)d.second]
                                    : [NSString stringWithFormat:@"%02ld:%02ld", (long)d.hour, (long)d.minute];
            return date && time ? [NSString stringWithFormat:@"%@ %@", ds, ts] : date ? ds : ts;
        }
    }
    if ([st.numberFormat containsString:@"%"] && !st.isDate) return [XLNumberString(v * 100) stringByAppendingString:@"%"];
    return XLNumberString(v);
}

- (NSString *)originalTextAt:(NSUInteger)row col:(NSUInteger)col {
    const XLCell *c = [self cellAt:row col:col];
    if (!c) return @"";
    NSString *f = _formulas[@(c->key)];
    if (f) return [@"=" stringByAppendingString:f];
    switch (c->type) {
        case XLNumber: return [self textForNumber:c->num style:[self styleAt:row col:col]];
        case XLString: { NSString *s = [self stringOf:c]; return looksSpecial(s) ? [@"'" stringByAppendingString:s] : s; }
        case XLBool: return c->num ? @"TRUE" : @"FALSE";
        case XLError: return [self stringOf:c];
        case XLEmpty: return @"";
    }
    return @"";
}

- (NSString *)editTextAt:(NSUInteger)row col:(NSUInteger)col {
    XLEdit *e = _edits[@(XLKey(row, col))];
    if (!e) return [self originalTextAt:row col:col];
    switch (e.kind) {
        case 1: return [self textForNumber:e.number style:[self styleAt:row col:col]];
        case 2: return looksSpecial(e.text) ? [@"'" stringByAppendingString:e.text] : e.text;
        case 3: return e.number ? @"TRUE" : @"FALSE";
        case 4: return [@"=" stringByAppendingString:e.text];
    }
    return @"";
}

- (NSString *)whyReadOnlyAt:(NSUInteger)row col:(NSUInteger)col {
    NSString *s = self.readOnlyReason;
    if (s) return s;
    XLRange m;
    if ([self mergeAt:row col:col range:&m] && (m.row != row || m.col != col))
        return [NSString stringWithFormat:FTL(@"Part of a merged cell: edit %@ instead"), XLCellName(m.row, m.col)];
    for (NSValue *v in _arrays) { XLRange r; [v getValue:&r]; if (row >= r.row && row <= r.lastRow && col >= r.col && col <= r.lastCol) return FTL(@"Part of an array formula: edit it in Excel or Numbers"); }
    const XLCell *c = [self cellAt:row col:col];
    if (c && (c->flags & XLFMaster)) {
        for (NSNumber *si in _sharedMaster) if ([_sharedMaster[si] unsignedLongLongValue] == c->key && [_mastersWithChildren containsIndex:si.unsignedIntegerValue])
            return FTL(@"Other cells share this formula: edit it in Excel or Numbers");
    }
    for (NSValue *v in _tableHeads) { XLRange r; [v getValue:&r]; if (row >= r.row && row <= r.lastRow && col >= r.col && col <= r.lastCol) return FTL(@"A table's header or total row: edit it in Excel or Numbers"); }
    return nil;
}

- (XLEdit *)editFromText:(NSString *)text style:(XLStyle *)st {
    XLEdit *e = [XLEdit new];
    if (!text.length) { e.kind = 0; return e; }
    if ([text hasPrefix:@"'"]) { e.kind = 2; e.text = [text substringFromIndex:1]; return e; }
    if ([text hasPrefix:@"="] && text.length > 1) { e.kind = 4; e.text = [text substringFromIndex:1]; return e; }
    if ([text caseInsensitiveCompare:@"TRUE"] == NSOrderedSame) { e.kind = 3; e.number = 1; return e; }
    if ([text caseInsensitiveCompare:@"FALSE"] == NSOrderedSame) { e.kind = 3; e.number = 0; return e; }
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL pct = [t hasSuffix:@"%"];
    NSString *num = [(pct ? [t substringToIndex:t.length - 1] : t) stringByReplacingOccurrencesOfString:@"," withString:@""];
    if ([num hasPrefix:@"$"] || [num hasPrefix:@"¥"] || [num hasPrefix:@"€"] || [num hasPrefix:@"£"]) num = [num substringFromIndex:1];
    char *end = NULL;
    const char *u = num.UTF8String;
    double v = u ? strtod_l(u, &end, NULL) : 0;
    if (u && *u && end && *end == 0 && isfinite(v) && !strpbrk(u, "xXnN")) { e.kind = 1; e.number = pct ? v / 100 : v; return e; }
    if (st.isDate) {                                                                 // 2026-01-05, 2026/1/5, 2026-01-05 18:30, 18:30
        NSInteger y = 0, mo = 0, d = 0, h = 0, mi = 0; double sec = 0; int got;
        NSString *norm = [t stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        if ((got = sscanf(norm.UTF8String, "%ld-%ld-%ld %ld:%ld:%lf", &y, &mo, &d, &h, &mi, &sec)) >= 3 && y >= 1900 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
            e.kind = 1; e.number = XLDateToSerial(y, mo, d, got >= 5 ? (h * 3600 + mi * 60 + sec) / 86400.0 : 0, _book.date1904); return e;
        }
        if (sscanf(t.UTF8String, "%ld:%ld:%lf", &h, &mi, &sec) >= 2 && ![t containsString:@"-"]) { e.kind = 1; e.number = (h * 3600 + mi * 60 + sec) / 86400.0; return e; }
    }
    e.kind = 2; e.text = text;
    return e;
}

- (BOOL)edit:(XLEdit *)e matchesCellAt:(NSUInteger)row col:(NSUInteger)col {
    const XLCell *c = [self cellAt:row col:col];
    if (!c) return e.kind == 0;
    NSString *f = _formulas[@(c->key)];
    if (f || e.kind == 4) return f && e.kind == 4 && [e.text isEqualToString:f];
    switch (e.kind) {
        case 0: return c->type == XLEmpty;
        case 1: return c->type == XLNumber && c->num == e.number;
        case 2: return c->type == XLString && !(c->flags & XLFRich) && [[self stringOf:c] isEqualToString:e.text];
        case 3: return c->type == XLBool && (c->num != 0) == (e.number != 0);
    }
    return NO;
}

- (BOOL)setText:(NSString *)text atRow:(NSUInteger)row col:(NSUInteger)col error:(NSString **)error {
    NSString *why = [self whyReadOnlyAt:row col:col];
    if (why) { if (error) *error = why; return NO; }
    if (row >= 1048576 || col >= 16384) { if (error) *error = FTL(@"Outside the sheet"); return NO; }
    NSNumber *key = @(XLKey(row, col));
    [_display removeObjectForKey:key];
    XLEdit *e = [self editFromText:text style:[self styleAt:row col:col]];
    if ([text isEqualToString:[self originalTextAt:row col:col]] || [self edit:e matchesCellAt:row col:col]) { [_edits removeObjectForKey:key]; return YES; }   // what the file has
    _edits[key] = e;
    if (text.length) { _usedRows = MAX(_usedRows, row + 1); _usedCols = MAX(_usedCols, col + 1); }
    return YES;
}

@end

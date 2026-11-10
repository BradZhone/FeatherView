#import "XLXML.h"

static inline BOOL isNameChar(uint8_t c) { return c > ' ' && c != '>' && c != '/' && c != '='; }

BOOL XLNextTag(const uint8_t *x, NSUInteger n, NSUInteger from, XLTag *t) {
    NSUInteger i = from;
    while (i < n) {
        const uint8_t *lt = memchr(x + i, '<', n - i);
        if (!lt) return NO;
        i = (NSUInteger)(lt - x);
        if (i + 1 >= n) return NO;
        uint8_t c = x[i + 1];
        if (c == '!' || c == '?') {                                    // comment, CDATA, DOCTYPE, PI
            const char *end = (i + 3 < n && x[i + 2] == '-' && x[i + 3] == '-') ? "-->" :
                              (i + 8 < n && !memcmp(x + i + 2, "[CDATA[", 7)) ? "]]>" : c == '?' ? "?>" : ">";
            size_t el = strlen(end);
            NSUInteger j = i + 2;
            while (j + el <= n && memcmp(x + j, end, el)) j++;
            i = j + el;
            continue;
        }
        memset(t, 0, sizeof *t);
        t->start = i;
        NSUInteger j = i + 1;
        if (x[j] == '/') { t->closing = YES; j++; }
        t->nameStart = j;
        while (j < n && isNameChar(x[j])) j++;
        t->nameLen = j - t->nameStart;
        t->localStart = t->nameStart;
        for (NSUInteger k = t->nameStart; k < j; k++) if (x[k] == ':') t->localStart = k + 1;
        t->attrStart = j;
        uint8_t q = 0;
        while (j < n) {
            uint8_t ch = x[j];
            if (q) { if (ch == q) q = 0; }
            else if (ch == '"' || ch == '\'') q = ch;
            else if (ch == '>') break;
            j++;
        }
        if (j >= n) return NO;
        t->selfClosing = j > t->attrStart && x[j - 1] == '/';
        t->attrEnd = t->selfClosing ? j - 1 : j;
        t->end = j + 1;
        return YES;
    }
    return NO;
}

BOOL XLTagIs(const uint8_t *x, const XLTag *t, const char *local) {
    size_t l = strlen(local);
    return t->nameStart + t->nameLen - t->localStart == l && !memcmp(x + t->localStart, local, l);
}

BOOL XLAttrRange(const uint8_t *x, const XLTag *t, const char *name, NSRange *value) {
    size_t l = strlen(name);
    NSUInteger i = t->attrStart;
    while (i < t->attrEnd) {
        while (i < t->attrEnd && x[i] <= ' ') i++;
        NSUInteger ns = i;
        while (i < t->attrEnd && x[i] != '=' && x[i] > ' ') i++;
        NSUInteger nl = i - ns;
        while (i < t->attrEnd && x[i] != '"' && x[i] != '\'') i++;
        if (i >= t->attrEnd) return NO;
        uint8_t q = x[i++];
        NSUInteger vs = i;
        while (i < t->attrEnd && x[i] != q) i++;
        if (nl == l && !memcmp(x + ns, name, l)) { *value = NSMakeRange(vs, i - vs); return YES; }
        i++;
    }
    return NO;
}

NSString *XLAttr(const uint8_t *x, const XLTag *t, const char *name) {
    NSRange r;
    return XLAttrRange(x, t, name, &r) ? XLDecode(x + r.location, r.length) : nil;
}

NSString *XLAttrLocal(const uint8_t *x, const XLTag *t, const char *local) {
    size_t l = strlen(local);
    NSUInteger i = t->attrStart;
    while (i < t->attrEnd) {
        while (i < t->attrEnd && x[i] <= ' ') i++;
        NSUInteger ns = i;
        while (i < t->attrEnd && x[i] != '=' && x[i] > ' ') i++;
        NSUInteger ne = i, ls = ns;
        for (NSUInteger k = ns; k < ne; k++) if (x[k] == ':') ls = k + 1;
        while (i < t->attrEnd && x[i] != '"' && x[i] != '\'') i++;
        if (i >= t->attrEnd) return nil;
        uint8_t q = x[i++];
        NSUInteger vs = i;
        while (i < t->attrEnd && x[i] != q) i++;
        if (ls > ns && ne - ls == l && !memcmp(x + ls, local, l)) return XLDecode(x + vs, i - vs);
        i++;
    }
    return nil;
}

NSString *XLPrefix(const uint8_t *x, const XLTag *t) {
    return t->localStart > t->nameStart ? [[NSString alloc] initWithBytes:x + t->nameStart length:t->localStart - t->nameStart encoding:NSUTF8StringEncoding] : @"";
}

NSString *XLDecode(const uint8_t *p, NSUInteger n) {
    if (!memchr(p, '&', n)) return [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableData *o = [NSMutableData dataWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        if (p[i] != '&') { [o appendBytes:p + i length:1]; continue; }
        const uint8_t *semi = memchr(p + i, ';', MIN(n - i, (NSUInteger)12));
        if (!semi) { [o appendBytes:p + i length:1]; continue; }
        NSUInteger len = (NSUInteger)(semi - (p + i)) - 1;
        const char *e = (const char *)p + i + 1;
        uint32_t cp = 0;
        if (len >= 2 && e[0] == '#') cp = (uint32_t)strtoul(e + (e[1] == 'x' ? 2 : 1), NULL, e[1] == 'x' ? 16 : 10);
        else if (len == 2 && !memcmp(e, "lt", 2)) cp = '<';
        else if (len == 2 && !memcmp(e, "gt", 2)) cp = '>';
        else if (len == 3 && !memcmp(e, "amp", 3)) cp = '&';
        else if (len == 4 && !memcmp(e, "quot", 4)) cp = '"';
        else if (len == 4 && !memcmp(e, "apos", 4)) cp = '\'';
        if (!cp || cp > 0x10FFFF) { [o appendBytes:p + i length:1]; continue; }
        NSString *ch = [[NSString alloc] initWithBytes:&cp length:4 encoding:NSUTF32LittleEndianStringEncoding];
        [o appendData:[ch dataUsingEncoding:NSUTF8StringEncoding]];
        i += len + 1;
    }
    return [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *XLDecodeOOXML(NSString *s) {
    if ([s rangeOfString:@"_x"].location == NSNotFound) return s;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"_x([0-9A-Fa-f]{4})_" options:0 error:nil]; });
    NSMutableString *o = [NSMutableString string];
    __block NSUInteger last = 0;
    [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        [o appendString:[s substringWithRange:NSMakeRange(last, m.range.location - last)]];
        unichar c = (unichar)strtoul([s substringWithRange:[m rangeAtIndex:1]].UTF8String, NULL, 16);
        [o appendFormat:@"%C", c];
        last = NSMaxRange(m.range);
    }];
    [o appendString:[s substringFromIndex:last]];
    return o;
}

NSString *XLEscape(NSString *s) {
    NSMutableString *o = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '&') [o appendString:@"&amp;"];
        else if (c == '<') [o appendString:@"&lt;"];
        else if (c == '>') [o appendString:@"&gt;"];
        else if (c == '"') [o appendString:@"&quot;"];
        else if (c == '_' && i + 6 < s.length && [s characterAtIndex:i + 1] == 'x' && [s characterAtIndex:i + 6] == '_') [o appendString:@"_x005F_"];
        else if (c < 0x20 && c != '\t' && c != '\n' && c != '\r') [o appendFormat:@"_x%04X_", c];
        else [o appendFormat:@"%C", c];
    }
    return o;
}

BOOL XLParseRef(const uint8_t *p, NSUInteger n, NSUInteger *row, NSUInteger *col) {
    NSUInteger i = 0, c = 0, r = 0;
    if (i < n && p[i] == '$') i++;
    NSUInteger cs = i;
    while (i < n && ((p[i] | 32) >= 'a' && (p[i] | 32) <= 'z')) { c = c * 26 + ((p[i] | 32) - 'a' + 1); i++; }
    if (i == cs || i - cs > 3) return NO;
    if (i < n && p[i] == '$') i++;
    NSUInteger rs = i;
    while (i < n && p[i] >= '0' && p[i] <= '9') { r = r * 10 + (p[i] - '0'); i++; }
    if (i == rs || i != n || !r || r > 1048576 || c > 16384) return NO;
    *row = r - 1; *col = c - 1;
    return YES;
}

BOOL XLParseRefString(NSString *s, NSUInteger *row, NSUInteger *col) {
    const char *u = s.UTF8String;
    return u && XLParseRef((const uint8_t *)u, strlen(u), row, col);
}

NSString *XLColumnName(NSUInteger c) {
    char b[8]; int i = 7; b[i] = 0;
    c += 1;
    while (c && i > 0) { b[--i] = (char)('A' + (c - 1) % 26); c = (c - 1) / 26; }
    return @(b + i);
}

NSString *XLCellName(NSUInteger row, NSUInteger col) { return [NSString stringWithFormat:@"%@%lu", XLColumnName(col), (unsigned long)row + 1]; }

#import "XLNumberFormat.h"
#include <math.h>

#pragma mark Built-in codes

static BOOL eastAsian(void) {
    NSString *l = NSLocale.preferredLanguages.firstObject ?: @"en";
    return [l hasPrefix:@"zh"] || [l hasPrefix:@"ja"] || [l hasPrefix:@"ko"];
}

NSString *XLBuiltinFormat(NSUInteger i) {
    switch (i) {
        case 0: return @"General";
        case 1: return @"0"; case 2: return @"0.00"; case 3: return @"#,##0"; case 4: return @"#,##0.00";
        case 9: return @"0%"; case 10: return @"0.00%"; case 11: return @"0.00E+00";
        case 12: return @"# ?/?"; case 13: return @"# ?\?/?\?";
        case 14: return eastAsian() ? @"yyyy/m/d" : @"m/d/yyyy";       // "short date" follows the system
        case 15: return @"d-mmm-yy"; case 16: return @"d-mmm"; case 17: return @"mmm-yy";
        case 18: return @"h:mm AM/PM"; case 19: return @"h:mm:ss AM/PM"; case 20: return @"h:mm"; case 21: return @"h:mm:ss";
        case 22: return eastAsian() ? @"yyyy/m/d h:mm" : @"m/d/yyyy h:mm";
        case 37: return @"#,##0 ;(#,##0)"; case 38: return @"#,##0 ;[Red](#,##0)";
        case 39: return @"#,##0.00;(#,##0.00)"; case 40: return @"#,##0.00;[Red](#,##0.00)";
        case 45: return @"mm:ss"; case 46: return @"[h]:mm:ss"; case 47: return @"mmss.0"; case 48: return @"##0.0E+0"; case 49: return @"@";
        // East Asian built-ins (Excel's zh-CN meanings)
        case 27: case 36: case 50: case 52: case 57: return @"yyyy\"年\"m\"月\"";   // l10n: data
        case 28: case 29: case 51: case 53: case 54: case 58: return @"m\"月\"d\"日\"";   // l10n: data
        case 30: return @"m-d-yy"; case 31: return @"yyyy\"年\"m\"月\"d\"日\"";   // l10n: data
        case 32: return @"h\"时\"mm\"分\""; case 33: return @"h\"时\"mm\"分\"ss\"秒\"";   // l10n: data
        case 34: case 55: return @"上午/下午h\"时\"mm\"分\""; case 35: case 56: return @"上午/下午h\"时\"mm\"分\"ss\"秒\"";   // l10n: data
    }
    return nil;
}

#pragma mark Dates

static void civilFromDays(int64_t z, NSInteger *y, NSInteger *m, NSInteger *d) {   // days since 1970-01-01
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097, yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t yy = yoe + era * 400, doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153;
    *d = (NSInteger)(doy - (153 * mp + 2) / 5 + 1);
    *m = (NSInteger)(mp < 10 ? mp + 3 : mp - 9);
    *y = (NSInteger)(yy + (*m <= 2));
}

static int64_t daysFromCivil(int64_t y, int64_t m, int64_t d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400;
    int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1, doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static const int64_t kEpoch1900 = -25569;           // 1899-12-30 in days since 1970
static const int64_t kEpoch1904 = -24107;           // 1904-01-01

BOOL XLSerialToDate(double serial, BOOL date1904, NSDateComponents *out) {
    if (!isfinite(serial) || serial < 0 || serial > 2958466) return NO;            // Excel's range ends at 9999-12-31
    int64_t day = (int64_t)floor(serial);
    int64_t ms = llround((serial - (double)day) * 86400000.0);
    if (ms >= 86400000) { day++; ms -= 86400000; }
    NSInteger y, m, d;
    if (!date1904 && day == 60) { y = 1900; m = 2; d = 29; }                        // Lotus's leap-year bug, kept by Excel
    else {
        int64_t base = date1904 ? kEpoch1904 : (day < 60 ? kEpoch1900 + 1 : kEpoch1900);
        civilFromDays(base + day, &y, &m, &d);
    }
    out.year = y; out.month = m; out.day = d;
    out.hour = (NSInteger)(ms / 3600000); out.minute = (NSInteger)(ms / 60000 % 60); out.second = (NSInteger)(ms / 1000 % 60);
    out.nanosecond = (NSInteger)(ms % 1000) * 1000000;
    int64_t days = date1904 ? kEpoch1904 + day : (day < 60 ? kEpoch1900 + 1 + day : kEpoch1900 + day);
    out.weekday = (NSInteger)(((days % 7) + 7 + 4) % 7) + 1;                         // 1970-01-01 was a Thursday; 1 = Sunday
    return YES;
}

double XLDateToSerial(NSInteger y, NSInteger m, NSInteger d, double frac, BOOL date1904) {
    int64_t days = daysFromCivil(y, m, d);
    double serial = (double)(days - (date1904 ? kEpoch1904 : kEpoch1900));
    if (!date1904 && serial < 61) serial -= 1;
    return serial + frac;
}

#pragma mark Sections

typedef struct { int kind; NSString *text; } Tok;      // kind: 0 literal, 1 placeholder 0, 2 #, 3 ?, 4 '.', 5 ',', 6 '%', 7 E+, 8 E-, 9 '@', 10 date token
enum { TLit, T0, THash, TQ, TDot, TComma, TPct, TEPlus, TEMinus, TAt, TDate };

static NSArray<NSString *> *sections(NSString *code) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    BOOL q = NO; NSInteger br = 0;
    for (NSUInteger i = 0; i < code.length; i++) {
        unichar c = [code characterAtIndex:i];
        if (c == '\\' && i + 1 < code.length && !q) { [cur appendFormat:@"%C%C", c, [code characterAtIndex:++i]]; continue; }
        if (c == '"') q = !q;
        else if (!q && c == '[') br++;
        else if (!q && c == ']' && br) br--;
        else if (!q && !br && c == ';') { [out addObject:[cur copy]]; [cur setString:@""]; continue; }
        [cur appendFormat:@"%C", c];
    }
    [out addObject:cur];
    return out;
}

static uint32_t namedColour(NSString *n) {
    NSDictionary *m = @{@"black": @0xFF000000, @"white": @0xFFFFFFFF, @"red": @0xFFFF0000, @"green": @0xFF00FF00,
                        @"blue": @0xFF0000FF, @"yellow": @0xFFFFFF00, @"magenta": @0xFFFF00FF, @"cyan": @0xFF00FFFF};
    return [m[n.lowercaseString] unsignedIntValue];
}

typedef struct { BOOL has; unichar op[2]; double v; } Cond;

// Removes [Red], [$€-407], [>100] …; keeps [h] [mm] [ss] for elapsed time. Collects colour and condition.
static NSString *stripBrackets(NSString *s, uint32_t *colour, Cond *cond) {
    NSMutableString *o = [NSMutableString string];
    BOOL q = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\' && !q && i + 1 < s.length) { [o appendFormat:@"%C%C", c, [s characterAtIndex:++i]]; continue; }
        if (c == '"') { q = !q; [o appendFormat:@"%C", c]; continue; }
        if (q || c != '[') { [o appendFormat:@"%C", c]; continue; }
        NSRange end = [s rangeOfString:@"]" options:0 range:NSMakeRange(i, s.length - i)];
        if (end.location == NSNotFound) { [o appendString:[s substringFromIndex:i]]; break; }
        NSString *in = [s substringWithRange:NSMakeRange(i + 1, end.location - i - 1)];
        NSString *lower = in.lowercaseString;
        if ([@[@"h", @"hh", @"m", @"mm", @"s", @"ss"] containsObject:lower]) [o appendFormat:@"[%@]", lower];
        else if ([lower hasPrefix:@"$"]) {                                               // [$€-407] currency, [$-409] locale only
            NSRange dash = [in rangeOfString:@"-"];
            NSString *sym = [in substringWithRange:NSMakeRange(1, (dash.location == NSNotFound ? in.length : dash.location) - 1)];
            if (sym.length) [o appendFormat:@"\"%@\"", [sym stringByReplacingOccurrencesOfString:@"\"" withString:@""]];
        } else if (in.length && strchr("<>=", [in characterAtIndex:0])) {
            if (cond) {
                NSUInteger k = 0;
                cond->has = YES; cond->op[0] = cond->op[1] = 0;
                while (k < in.length && k < 2 && strchr("<>=", [in characterAtIndex:k])) { cond->op[k] = [in characterAtIndex:k]; k++; }
                cond->v = [[in substringFromIndex:k] doubleValue];
            }
        } else if ([lower hasPrefix:@"color"] && colour) {                               // [Color3]: the legacy palette
            static const uint32_t pal[] = {0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF};
            NSInteger k = [lower substringFromIndex:5].integerValue;
            if (k >= 1 && k <= 8) *colour = pal[k - 1];
        } else if (colour && namedColour(in)) *colour = namedColour(in);
        i = end.location;
    }
    return o;
}

static BOOL condMatches(Cond c, double v) {
    if (!c.has) return NO;
    unichar a = c.op[0], b = c.op[1];
    if (a == '<' && b == '=') return v <= c.v;
    if (a == '>' && b == '=') return v >= c.v;
    if (a == '<' && b == '>') return v != c.v;
    if (a == '<') return v < c.v;
    if (a == '>') return v > c.v;
    return v == c.v;
}

static BOOL isDateSection(NSString *s) {
    BOOL q = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\' && !q) { i++; continue; }
        if (c == '"') { q = !q; continue; }
        if (q) continue;
        if (c == '[') {                                                           // [h] [mm] [ss]
            if (i + 1 < s.length && strchr("hHmMsS", [s characterAtIndex:i + 1])) return YES;
            while (i < s.length && [s characterAtIndex:i] != ']') i++;
            continue;
        }
        if (c == '_' || c == '*') { i++; continue; }
        if (strchr("yYmMdDhHsS", c) || c == 0x5E74 /* 年 */ || c == 0x4E0A /* 上 (上午) */) return YES;   // l10n: data
        if ((c == 'e' || c == 'E') && i + 1 < s.length && [s characterAtIndex:i + 1] != '+' && [s characterAtIndex:i + 1] != '-') return YES;
    }
    return NO;
}

BOOL XLFormatIsDate(NSString *code) {
    if (!code.length || [code caseInsensitiveCompare:@"General"] == NSOrderedSame) return NO;
    return isDateSection(stripBrackets(sections(code).firstObject, NULL, NULL));
}

#pragma mark Dates: formatting

static NSString *monthName(NSInteger m, NSInteger len) {
    static NSArray *full, *shortN;
    if (!full) {
        full = @[@"January", @"February", @"March", @"April", @"May", @"June", @"July", @"August", @"September", @"October", @"November", @"December"];
        shortN = @[@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"];
    }
    if (m < 1 || m > 12) return @"";
    if (len == 3) return shortN[m - 1];
    if (len == 5) return [full[m - 1] substringToIndex:1];
    return full[m - 1];
}

static NSString *dayName(NSInteger wd, BOOL full) {
    NSArray *f = @[@"Sunday", @"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday"];
    NSString *n = f[(NSUInteger)MAX(0, MIN(6, wd - 1))];
    return full ? n : [n substringToIndex:3];
}

static NSString *formatDate(double v, NSString *s, BOOL d1904) {
    NSDateComponents *c = [NSDateComponents new];
    if (!XLSerialToDate(v, d1904, c)) return nil;
    // tokens: letters runs (y m d h s), literals, AM/PM, elapsed, fractional seconds
    NSMutableArray<NSArray *> *toks = [NSMutableArray array];   // @[type, text]
    BOOL ampm = NO;
    for (NSUInteger i = 0; i < s.length; ) {
        unichar ch = [s characterAtIndex:i];
        if (ch == '"') {
            NSRange e = [s rangeOfString:@"\"" options:0 range:NSMakeRange(i + 1, s.length - i - 1)];
            NSUInteger end = e.location == NSNotFound ? s.length : e.location;
            [toks addObject:@[@"lit", [s substringWithRange:NSMakeRange(i + 1, end - i - 1)]]];
            i = end + 1; continue;
        }
        if (ch == '\\' && i + 1 < s.length) { [toks addObject:@[@"lit", [s substringWithRange:NSMakeRange(i + 1, 1)]]]; i += 2; continue; }
        if (ch == '_' && i + 1 < s.length) { [toks addObject:@[@"lit", @" "]]; i += 2; continue; }
        if (ch == '*' && i + 1 < s.length) { i += 2; continue; }
        if (ch == '[') {
            NSRange e = [s rangeOfString:@"]" options:0 range:NSMakeRange(i, s.length - i)];
            NSUInteger end = e.location == NSNotFound ? s.length - 1 : e.location;
            [toks addObject:@[@"elapsed", [s substringWithRange:NSMakeRange(i + 1, end - i - 1)].lowercaseString]];
            i = end + 1; continue;
        }
        NSString *rest = [s substringFromIndex:i];
        if ([rest.uppercaseString hasPrefix:@"AM/PM"]) { [toks addObject:@[@"ampm", @"AM/PM"]]; ampm = YES; i += 5; continue; }
        if ([rest.uppercaseString hasPrefix:@"A/P"]) { [toks addObject:@[@"ampm", @"A/P"]]; ampm = YES; i += 3; continue; }
        if ([rest hasPrefix:@"上午/下午"]) { [toks addObject:@[@"ampm", @"zh"]]; ampm = YES; i += 5; continue; }   // l10n: data
        unichar lc = (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch;
        if (strchr("ymdhsae", lc) && lc) {
            NSUInteger j = i;
            while (j < s.length) { unichar x = [s characterAtIndex:j]; if (((x >= 'A' && x <= 'Z') ? x + 32 : x) != lc) break; j++; }
            [toks addObject:@[[NSString stringWithFormat:@"%C", lc], @(j - i)]];
            i = j; continue;
        }
        if (ch == '.' && toks.count && [toks.lastObject[0] isEqual:@"s"]) {                 // fractional seconds
            NSUInteger j = i + 1;
            while (j < s.length && [s characterAtIndex:j] == '0') j++;
            [toks addObject:@[@"frac", @(j - i - 1)]];
            i = j; continue;
        }
        [toks addObject:@[@"lit", [NSString stringWithFormat:@"%C", ch]]];
        i++;
    }
    // m after h, or before s, is minutes
    for (NSUInteger k = 0; k < toks.count; k++) {
        if (![toks[k][0] isEqual:@"m"] || [toks[k][1] integerValue] > 2) continue;
        BOOL minute = NO;
        for (NSInteger p = (NSInteger)k - 1; p >= 0; p--) { NSString *t = toks[p][0]; if ([t isEqual:@"lit"]) continue; minute = [t isEqual:@"h"] || ([t isEqual:@"elapsed"] && [toks[p][1] hasPrefix:@"h"]); break; }
        for (NSUInteger p = k + 1; !minute && p < toks.count; p++) { NSString *t = toks[p][0]; if ([t isEqual:@"lit"]) continue; minute = [t isEqual:@"s"] || ([t isEqual:@"elapsed"] && [toks[p][1] hasPrefix:@"s"]); break; }
        if (minute) toks[k] = @[@"min", toks[k][1]];
    }
    NSMutableString *o = [NSMutableString string];
    NSInteger hour = c.hour;
    double secsTotal = round(v * 86400.0);
    for (NSArray *t in toks) {
        NSString *k = t[0];
        NSInteger n = [t[1] isKindOfClass:NSNumber.class] ? [t[1] integerValue] : 0;
        if ([k isEqual:@"lit"]) [o appendString:t[1]];
        else if ([k isEqual:@"y"] || [k isEqual:@"e"]) [o appendFormat:n <= 2 && [k isEqual:@"y"] ? @"%02ld" : @"%ld", (long)(n <= 2 && [k isEqual:@"y"] ? c.year % 100 : c.year)];
        else if ([k isEqual:@"m"]) [o appendString:n == 1 ? [NSString stringWithFormat:@"%ld", (long)c.month] : n == 2 ? [NSString stringWithFormat:@"%02ld", (long)c.month] : monthName(c.month, n >= 5 ? 5 : n)];
        else if ([k isEqual:@"d"]) [o appendString:n == 1 ? [NSString stringWithFormat:@"%ld", (long)c.day] : n == 2 ? [NSString stringWithFormat:@"%02ld", (long)c.day] : dayName(c.weekday, n >= 4)];
        else if ([k isEqual:@"a"]) [o appendString:@[@"日", @"一", @"二", @"三", @"四", @"五", @"六"][(NSUInteger)MAX(0, MIN(6, c.weekday - 1))]];   // l10n: data
        else if ([k isEqual:@"h"]) { NSInteger h = ampm ? (hour % 12 ?: 12) : hour; [o appendFormat:n >= 2 ? @"%02ld" : @"%ld", (long)h]; }
        else if ([k isEqual:@"min"]) [o appendFormat:n >= 2 ? @"%02ld" : @"%ld", (long)c.minute];
        else if ([k isEqual:@"s"]) [o appendFormat:n >= 2 ? @"%02ld" : @"%ld", (long)c.second];
        else if ([k isEqual:@"frac"]) { if (n) [o appendFormat:@".%0*ld", (int)n, (long)(c.nanosecond / (NSInteger)pow(10, 9 - n))]; }
        else if ([k isEqual:@"ampm"]) {
            BOOL pm = hour >= 12;
            if ([t[1] isEqual:@"zh"]) [o appendString:pm ? @"下午" : @"上午"];   // l10n: data
            else if ([t[1] isEqual:@"A/P"]) [o appendString:pm ? @"P" : @"A"];
            else [o appendString:pm ? @"PM" : @"AM"];
        } else if ([k isEqual:@"elapsed"]) {
            NSString *w = t[1];
            double val = [w hasPrefix:@"h"] ? floor(secsTotal / 3600) : [w hasPrefix:@"m"] ? floor(secsTotal / 60) : secsTotal;
            [o appendFormat:@"%0*.0f", (int)w.length, val];
        }
    }
    return o;
}

#pragma mark Numbers

NSString *XLGeneral(double v) {
    if (!isfinite(v)) return @"#NUM!";
    if (v == 0) return @"0";
    double a = fabs(v);
    if (a == floor(a) && a < 1e11) return [NSString stringWithFormat:@"%.0f", v];
    if (a >= 1e11 || a < 1e-9) {
        NSString *s = [NSString stringWithFormat:@"%.5E", v];                    // 1.23457E+11
        NSRange e = [s rangeOfString:@"E"];
        NSString *m = [s substringToIndex:e.location], *x = [s substringFromIndex:e.location];
        while ([m containsString:@"."] && ([m hasSuffix:@"0"] || [m hasSuffix:@"."])) m = [m substringToIndex:m.length - 1];
        return [m stringByAppendingString:x];
    }
    NSInteger intDigits = a >= 1 ? (NSInteger)floor(log10(a)) + 1 : 1;
    NSString *s = [NSString stringWithFormat:@"%.*f", (int)MAX(0, 10 - intDigits), v];  // about 11 characters, like Excel
    if ([s containsString:@"."]) while ([s hasSuffix:@"0"]) s = [s substringToIndex:s.length - 1];
    if ([s hasSuffix:@"."]) s = [s substringToIndex:s.length - 1];
    return [s isEqualToString:@"-0"] ? @"0" : s;
}

static NSArray<NSValue *> *tokenizeNumber(NSString *s, NSMutableArray<NSString *> *lits) {
    // returns Tok as (kind, literal index) pairs packed in NSValue of NSRange{kind, litIndex}
    NSMutableArray *out = [NSMutableArray array];
    void (^lit)(NSString *) = ^(NSString *t) { [lits addObject:t]; [out addObject:[NSValue valueWithRange:NSMakeRange(TLit, lits.count - 1)]]; };
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"': {
                NSRange e = [s rangeOfString:@"\"" options:0 range:NSMakeRange(i + 1, s.length - i - 1)];
                NSUInteger end = e.location == NSNotFound ? s.length : e.location;
                lit([s substringWithRange:NSMakeRange(i + 1, end - i - 1)]);
                i = end; break;
            }
            case '\\': if (i + 1 < s.length) lit([s substringWithRange:NSMakeRange(++i, 1)]); break;
            case '_': if (i + 1 < s.length) { i++; lit(@" "); } break;
            case '*': if (i + 1 < s.length) i++; break;
            case '0': [out addObject:[NSValue valueWithRange:NSMakeRange(T0, 0)]]; break;
            case '#': [out addObject:[NSValue valueWithRange:NSMakeRange(THash, 0)]]; break;
            case '?': [out addObject:[NSValue valueWithRange:NSMakeRange(TQ, 0)]]; break;
            case '.': [out addObject:[NSValue valueWithRange:NSMakeRange(TDot, 0)]]; break;
            case ',': [out addObject:[NSValue valueWithRange:NSMakeRange(TComma, 0)]]; break;
            case '%': [out addObject:[NSValue valueWithRange:NSMakeRange(TPct, 0)]]; break;
            case '@': [out addObject:[NSValue valueWithRange:NSMakeRange(TAt, 0)]]; break;
            case 'E': case 'e':
                if (i + 1 < s.length && ([s characterAtIndex:i + 1] == '+' || [s characterAtIndex:i + 1] == '-')) {
                    [out addObject:[NSValue valueWithRange:NSMakeRange([s characterAtIndex:i + 1] == '+' ? TEPlus : TEMinus, 0)]]; i++;
                } else lit([NSString stringWithFormat:@"%C", c]);
                break;
            default: lit([NSString stringWithFormat:@"%C", c]);
        }
    }
    return out;
}

static BOOL isPH(NSUInteger k) { return k == T0 || k == THash || k == TQ; }

// One pass over the tokens: digits go onto placeholders, literals stay where they are written.
static NSString *formatPlain(double v, NSString *s) {
    NSMutableArray<NSString *> *lits = [NSMutableArray array];
    NSArray<NSValue *> *toks = tokenizeNumber(s, lits);
    NSUInteger n = toks.count;
    NSUInteger (^kind)(NSUInteger) = ^NSUInteger(NSUInteger i) { return toks[i].rangeValue.location; };
    NSInteger dot = -1, exp = -1;
    NSUInteger pct = 0, phCount = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger k = kind(i);
        if (isPH(k)) phCount++;
        if (k == TPct) pct++;
        if (k == TDot && dot < 0 && exp < 0) dot = (NSInteger)i;
        if ((k == TEPlus || k == TEMinus) && exp < 0) exp = (NSInteger)i;
    }
    NSMutableString *o = [NSMutableString string];
    if (!phCount) {                                                                  // only text, such as "-"
        for (NSUInteger i = 0; i < n; i++) { NSUInteger k = kind(i); if (k == TLit) [o appendString:lits[toks[i].rangeValue.length]]; else if (k == TPct) [o appendString:@"%"]; }
        return o;
    }
    NSUInteger intEnd = dot >= 0 ? (NSUInteger)dot : exp >= 0 ? (NSUInteger)exp : n;
    NSUInteger fracEnd = exp >= 0 ? (NSUInteger)exp : n;
    // commas in the integer part: between placeholders they group, after the last one each divides by 1000
    NSInteger firstIntPH = -1, lastIntPH = -1;
    for (NSUInteger i = 0; i < intEnd; i++) if (isPH(kind(i))) { if (firstIntPH < 0) firstIntPH = (NSInteger)i; lastIntPH = (NSInteger)i; }
    BOOL group = NO;
    NSUInteger scale = 0;
    for (NSUInteger i = 0; i < intEnd; i++) {
        if (kind(i) != TComma) continue;
        if (firstIntPH >= 0 && (NSInteger)i > firstIntPH && (NSInteger)i < lastIntPH) group = YES;
        else if (lastIntPH >= 0 && (NSInteger)i > lastIntPH) scale++;
    }
    NSInteger lastPH = -1;                                                           // "0.0,," : commas after the last digit scale too
    for (NSUInteger i = 0; i < fracEnd; i++) if (isPH(kind(i))) lastPH = (NSInteger)i;
    for (NSUInteger i = intEnd; i < fracEnd; i++) if (kind(i) == TComma && (NSInteger)i > lastPH) scale++;
    for (NSUInteger p = 0; p < pct; p++) v *= 100;
    for (NSUInteger k = 0; k < scale; k++) v /= 1000;
    NSMutableArray<NSNumber *> *intPH = [NSMutableArray array], *fracPH = [NSMutableArray array], *expPH = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        if (!isPH(kind(i))) continue;
        if (i < intEnd) [intPH addObject:@(i)];
        else if (dot >= 0 && i > (NSUInteger)dot && i < fracEnd) [fracPH addObject:@(i)];
        else if (exp >= 0 && i > (NSUInteger)exp) [expPH addObject:@(i)];
    }
    NSInteger e10 = 0;
    if (exp >= 0 && v != 0) {
        NSUInteger ip = MAX(intPH.count, (NSUInteger)1);
        e10 = (NSInteger)floor(log10(v));
        if (ip > 1) e10 = (NSInteger)(floor((double)e10 / ip) * ip);
        v /= pow(10, (double)e10);
        if (round(v * pow(10, fracPH.count)) / pow(10, fracPH.count) >= pow(10, ip)) { v /= 10; e10++; }
    }
    NSString *num = [NSString stringWithFormat:@"%.*f", (int)fracPH.count, v];
    NSRange pt = [num rangeOfString:@"."];
    NSString *intDigits = pt.location == NSNotFound ? num : [num substringToIndex:pt.location];
    NSString *fracDigits = pt.location == NSNotFound ? @"" : [num substringFromIndex:pt.location + 1];
    if ([intDigits isEqualToString:@"0"]) intDigits = @"";
    // fraction: trailing zeros go unless a 0 placeholder needs them
    NSUInteger keepFrac = fracDigits.length;
    while (keepFrac > 0 && [fracDigits characterAtIndex:keepFrac - 1] == '0' && kind([fracPH[keepFrac - 1] unsignedIntegerValue]) != T0) keepFrac--;
    // what each integer placeholder shows: right to left one digit each, the leftmost takes the rest
    NSMutableDictionary<NSNumber *, NSString *> *intText = [NSMutableDictionary dictionary];
    NSInteger d = (NSInteger)intDigits.length - 1;
    if (group) {                                                                     // grouped: one block at the first placeholder
        NSUInteger zeros = 0;
        for (NSNumber *x in intPH) if (kind(x.unsignedIntegerValue) == T0) zeros++;
        NSMutableString *digs = [intDigits mutableCopy];
        while (digs.length < zeros) [digs insertString:@"0" atIndex:0];
        NSMutableString *g = [NSMutableString string];
        for (NSUInteger q = 0; q < digs.length; q++) { if (q && (digs.length - q) % 3 == 0) [g appendString:@","]; [g appendFormat:@"%C", [digs characterAtIndex:q]]; }
        if (intPH.count) intText[intPH.firstObject] = g;
    } else {
        for (NSInteger slot = (NSInteger)intPH.count - 1; slot >= 0; slot--) {
            NSUInteger k = kind(intPH[(NSUInteger)slot].unsignedIntegerValue);
            NSString *t;
            if (slot == 0 && d >= 0) { t = [intDigits substringToIndex:(NSUInteger)d + 1]; d = -1; }
            else if (d >= 0) { t = [intDigits substringWithRange:NSMakeRange((NSUInteger)d, 1)]; d--; }
            else t = k == T0 ? @"0" : k == TQ ? @" " : @"";
            intText[intPH[(NSUInteger)slot]] = t;
        }
    }
    NSString *expDigits = [NSString stringWithFormat:@"%ld", labs(e10)];
    NSUInteger fi = 0, ei = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger k = kind(i);
        if (k == TLit) { [o appendString:lits[toks[i].rangeValue.length]]; continue; }
        if (k == TPct) { [o appendString:@"%"]; continue; }
        if (k == TComma) continue;
        if (k == TDot) { if ((NSInteger)i == dot) [o appendString:@"."]; continue; }      // Excel keeps it: 12 in "#.##" is "12." 
        if (k == TEPlus || k == TEMinus) { [o appendFormat:@"E%@", e10 < 0 ? @"-" : k == TEPlus ? @"+" : @""]; continue; }
        if (i < intEnd) {
            [o appendString:intText[@(i)] ?: @""];
        } else if (exp >= 0 && i > (NSUInteger)exp) {
            NSUInteger slot = ei++, fromRight = expPH.count - 1 - slot;
            if (slot == 0 && expDigits.length > expPH.count) [o appendString:[expDigits substringToIndex:expDigits.length - expPH.count + 1]];
            else if (fromRight < expDigits.length) [o appendFormat:@"%C", [expDigits characterAtIndex:expDigits.length - 1 - fromRight]];
            else if (k == T0) [o appendString:@"0"];
        } else {
            if (fi < keepFrac) [o appendFormat:@"%C", [fracDigits characterAtIndex:fi]];
            else if (k == T0) [o appendString:@"0"];
            else if (k == TQ) [o appendString:@" "];
            fi++;
        }
    }
    return o;
}

NSString *XLFormatNumber(double v, NSString *code, BOOL d1904, uint32_t *colour) {
    if (!isfinite(v)) return @"#NUM!";
    if (!code.length || [code caseInsensitiveCompare:@"General"] == NSOrderedSame) return XLGeneral(v);
    NSArray<NSString *> *secs = sections(code);
    Cond conds[4] = {{0}};
    NSMutableArray *clean = [NSMutableArray array];
    uint32_t cols[4] = {0};
    for (NSUInteger i = 0; i < MIN(secs.count, (NSUInteger)4); i++) [clean addObject:stripBrackets(secs[i], &cols[i], &conds[i])];
    NSUInteger pick = 0;
    BOOL neg = v < 0, autoMinus = NO;
    if (conds[0].has || (clean.count > 1 && conds[1].has)) {                          // [>100]0;[<0]…: conditions decide
        if (condMatches(conds[0], v)) pick = 0;
        else if (clean.count > 1 && (conds[1].has ? condMatches(conds[1], v) : YES)) pick = 1;
        else pick = MIN((NSUInteger)2, clean.count - 1);
        autoMinus = neg && !(pick == 1 && clean.count > 1);
    } else if (clean.count == 1) { pick = 0; autoMinus = neg; }
    else if (neg) pick = 1;
    else if (v == 0 && clean.count >= 3) pick = 2;
    NSString *sec = clean[pick];
    if (colour && cols[pick]) *colour = cols[pick];
    if ([sec caseInsensitiveCompare:@"General"] == NSOrderedSame || !sec.length) {
        NSString *g = XLGeneral(pick == 1 ? fabs(v) : v);
        return sec.length ? g : @"";
    }
    if ([[sec stringByReplacingOccurrencesOfString:@"General" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, sec.length)] length] != sec.length) {
        NSString *g = XLGeneral(fabs(v));
        return [[sec stringByReplacingOccurrencesOfString:@"General" withString:g options:NSCaseInsensitiveSearch range:NSMakeRange(0, sec.length)]
                stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    }
    if (isDateSection(sec)) return formatDate(v, sec, d1904) ?: @"#######";
    NSString *body = formatPlain(fabs(v), sec);
    BOOL zero = YES;
    for (NSUInteger i = 0; i < body.length && zero; i++) { unichar c = [body characterAtIndex:i]; if (c >= '1' && c <= '9') zero = NO; }
    return autoMinus && !zero ? [@"-" stringByAppendingString:body] : body;
}

NSString *XLFormatText(NSString *text, NSString *code) {
    if (!code.length) return text;
    NSArray *secs = sections(code);
    NSString *sec = secs.count >= 4 ? secs[3] : nil;
    if (!sec) for (NSString *x in secs) if ([x containsString:@"@"]) { sec = x; break; }
    if (!sec) return text;
    sec = stripBrackets(sec, NULL, NULL);
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < sec.length; i++) {
        unichar c = [sec characterAtIndex:i];
        if (c == '"') {
            NSRange e = [sec rangeOfString:@"\"" options:0 range:NSMakeRange(i + 1, sec.length - i - 1)];
            NSUInteger end = e.location == NSNotFound ? sec.length : e.location;
            [o appendString:[sec substringWithRange:NSMakeRange(i + 1, end - i - 1)]];
            i = end;
        } else if (c == '\\' && i + 1 < sec.length) [o appendFormat:@"%C", [sec characterAtIndex:++i]];
        else if (c == '_' && i + 1 < sec.length) { i++; [o appendString:@" "]; }
        else if (c == '*' && i + 1 < sec.length) i++;
        else if (c == '@') [o appendString:text];
        else [o appendFormat:@"%C", c];
    }
    return o;
}

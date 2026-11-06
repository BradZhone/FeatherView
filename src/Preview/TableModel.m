#import "TableModel.h"
#import "JSONTree.h"

static const NSUInteger kMaxCells = 6000000;          // ~48 MB of ranges; bigger files show the first rows

static NSString *decode(const uint8_t *b, NSUInteger n) {
    if (!n) return @"";
    return [[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:b length:n encoding:NSISOLatin1StringEncoding] ?: @"";
}

static NSString *letters(NSUInteger c) {                  // 0 → A, 25 → Z, 26 → AA
    NSMutableString *s = [NSMutableString string];
    c++;
    while (c) { c--; [s insertString:[NSString stringWithFormat:@"%c", (char)('A' + c % 26)] atIndex:0]; c /= 26; }
    return s;
}

#pragma mark CSV

@implementation CSVTable {
    NSData *_data;
    uint32_t *_off, *_len;                                // len's top bit = the field was quoted
    uint32_t *_rowStart, *_rowLine;                       // first cell index / 1-based source line of each record
    NSUInteger _cells, _rows, _cols, _capCells, _capRows;
    BOOL _truncated;
}

- (void)dealloc { free(_off); free(_len); free(_rowStart); free(_rowLine); }

static NSUInteger countFields(const uint8_t *s, NSUInteger n, NSUInteger *pos, uint8_t d) {
    NSUInteger i = *pos, fields = 1;
    BOOL q = NO;
    for (; i < n; i++) {
        uint8_t c = s[i];
        if (q) { if (c == '"') { if (i + 1 < n && s[i + 1] == '"') i++; else q = NO; } continue; }
        if (c == '"') q = YES;
        else if (c == d) fields++;
        else if (c == '\n' || c == '\r') { if (c == '\r' && i + 1 < n && s[i + 1] == '\n') i++; i++; break; }
    }
    *pos = i;
    return fields;
}

// The delimiter that gives the most rows with the same (> 1) number of fields in the first 40 records.
+ (unichar)sniffDelimiter:(NSData *)utf8 hint:(unichar)hint {
    const uint8_t *s = utf8.bytes;
    NSUInteger n = MIN(utf8.length, (NSUInteger)65536);
    uint8_t cands[] = {',', '\t', ';', '|'};
    double best = 0; unichar pick = hint ?: ',';
    for (int k = 0; k < 4; k++) {
        NSCountedSet *counts = [NSCountedSet set];
        NSUInteger pos = (n >= 3 && s[0] == 0xEF && s[1] == 0xBB) ? 3 : 0, records = 0;
        while (pos < n && records < 40) { [counts addObject:@(countFields(s, n, &pos, cands[k]))]; records++; }
        NSNumber *mode = nil; NSUInteger freq = 0;
        for (NSNumber *c in counts) if ([counts countForObject:c] > freq || ([counts countForObject:c] == freq && c.unsignedIntegerValue > mode.unsignedIntegerValue)) { freq = [counts countForObject:c]; mode = c; }
        if (mode.unsignedIntegerValue < 2 || !records) continue;
        double score = (double)freq / records * 10 + MIN(mode.unsignedIntegerValue, (NSUInteger)20) * 0.1;
        if (cands[k] == hint) score += 1.5;                   // the extension says so: prefer it on a tie
        if (score > best) { best = score; pick = cands[k]; }
    }
    return pick;
}

static BOOL looksNumeric(NSString *s) {
    if (!s.length) return NO;
    NSScanner *sc = [NSScanner scannerWithString:s];
    double d;
    return [sc scanDouble:&d] && sc.isAtEnd;
}

+ (instancetype)tableWithData:(NSData *)utf8 delimiter:(unichar)delimiter hasHeader:(NSInteger)hasHeader maxRows:(NSUInteger)maxRows {
    CSVTable *t = [CSVTable new];
    t->_data = utf8;
    t->_delimiter = delimiter ?: [self sniffDelimiter:utf8 hint:0];
    [t parse:maxRows ?: NSUIntegerMax];
    if (hasHeader < 0) {                                       // a first row of only numbers is data
        BOOL allNumbers = t->_rows > 0;
        for (NSUInteger c = 0; c < [t fieldsInRecord:0]; c++) if (!looksNumeric([t raw:0 column:c])) { allNumbers = NO; break; }
        t->_hasHeader = t->_rows > 1 && !allNumbers;
    } else t->_hasHeader = hasHeader == 1 && t->_rows > 0;
    return t;
}

- (NSUInteger)fieldsInRecord:(NSUInteger)r {
    if (r >= _rows) return 0;
    NSUInteger end = r + 1 < _rows ? _rowStart[r + 1] : _cells;
    return end - _rowStart[r];
}

- (void)grow {
    if (_cells == _capCells) {
        _capCells = MAX(1024, _capCells * 2);
        _off = realloc(_off, _capCells * sizeof(uint32_t));
        _len = realloc(_len, _capCells * sizeof(uint32_t));
    }
}

- (void)parse:(NSUInteger)maxRows {
    const uint8_t *s = _data.bytes;
    NSUInteger n = MIN(_data.length, (NSUInteger)UINT32_MAX - 1), i = 0, line = 1;
    if (n >= 3 && s[0] == 0xEF && s[1] == 0xBB && s[2] == 0xBF) i = 3;
    uint8_t d = (uint8_t)_delimiter;
    while (i < n) {
        if (_rows >= maxRows || _cells >= kMaxCells) { _truncated = YES; break; }
        if (_rows == _capRows) {
            _capRows = MAX(256, _capRows * 2);
            _rowStart = realloc(_rowStart, _capRows * sizeof(uint32_t));
            _rowLine = realloc(_rowLine, _capRows * sizeof(uint32_t));
        }
        NSUInteger firstCell = _cells, recordLine = line;
        for (;;) {                                               // fields of one record
            BOOL quoted = i < n && s[i] == '"';
            NSUInteger a, b;
            if (quoted) {
                i++; a = i;
                for (;;) {
                    if (i >= n) { b = i; break; }
                    if (s[i] == '"') {
                        if (i + 1 < n && s[i + 1] == '"') { i += 2; continue; }
                        b = i; i++; break;
                    }
                    if (s[i] == '\n') line++;
                    i++;
                }
                while (i < n && s[i] != d && s[i] != '\n' && s[i] != '\r') i++;   // junk after the closing quote
            } else {
                a = i;
                while (i < n && s[i] != d && s[i] != '\n' && s[i] != '\r') i++;
                b = i;
            }
            [self grow];
            _off[_cells] = (uint32_t)a;
            _len[_cells] = (uint32_t)(b - a) | (quoted ? 0x80000000u : 0);
            _cells++;
            if (i < n && s[i] == d) { i++; continue; }
            break;
        }
        if (i < n && s[i] == '\r') i++;
        if (i < n && s[i] == '\n') i++;
        line++;
        if (_cells == firstCell + 1 && (_len[firstCell] & 0x7FFFFFFF) == 0 && !(_len[firstCell] & 0x80000000u)) {
            _cells = firstCell;                                  // blank line
            continue;
        }
        _rowStart[_rows] = (uint32_t)firstCell;
        _rowLine[_rows] = (uint32_t)recordLine;
        _rows++;
        _cols = MAX(_cols, _cells - firstCell);
    }
}

- (NSString *)raw:(NSUInteger)r column:(NSUInteger)c {
    if (r >= _rows) return @"";
    NSUInteger start = _rowStart[r], end = r + 1 < _rows ? _rowStart[r + 1] : _cells;
    if (start + c >= end) return @"";
    uint32_t len = _len[start + c];
    NSString *v = decode((const uint8_t *)_data.bytes + _off[start + c], len & 0x7FFFFFFF);
    return (len & 0x80000000u) ? [v stringByReplacingOccurrencesOfString:@"\"\"" withString:@"\""] : v;
}

- (NSUInteger)rowCount { return _hasHeader ? _rows - 1 : _rows; }
- (NSUInteger)columnCount { return _cols; }
- (BOOL)truncated { return _truncated; }
- (NSString *)cellAtRow:(NSUInteger)r column:(NSUInteger)c { return [self raw:_hasHeader ? r + 1 : r column:c]; }
- (NSString *)headerForColumn:(NSUInteger)c {
    NSString *h = _hasHeader ? [self raw:0 column:c] : @"";
    return h.length ? h : letters(c);
}
- (NSUInteger)sourceLineOfRow:(NSUInteger)r { NSUInteger k = _hasHeader ? r + 1 : r; return k < _rows ? _rowLine[k] : 0; }

@end

#pragma mark JSON Lines

@implementation JSONLinesTable {
    NSMutableArray<NSString *> *_headers;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *_rows;
    NSMutableArray<NSNumber *> *_lines;
    BOOL _truncated;
}

static NSString *cellText(JSONNode *v) {
    switch (v.kind) {
        case JSONObject: case JSONArray: return [v JSONStringPretty:NO];
        case JSONNull: return @"";
        default: return v.text ?: @"";
    }
}

+ (instancetype)tableWithData:(NSData *)utf8 maxRows:(NSUInteger)maxRows {
    JSONLinesTable *t = [JSONLinesTable new];
    t->_headers = [NSMutableArray array];
    t->_rows = [NSMutableArray array];
    t->_lines = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    const uint8_t *s = utf8.bytes;
    NSUInteger n = utf8.length, i = 0, line = 0;
    while (i < n) {
        NSUInteger a = i;
        while (i < n && s[i] != '\n') i++;
        NSUInteger b = i;
        i++; line++;
        while (b > a && (s[b - 1] == '\r' || s[b - 1] == ' ' || s[b - 1] == '\t')) b--;
        while (a < b && (s[a] == ' ' || s[a] == '\t')) a++;
        if (a == b) continue;
        if (t->_rows.count >= (maxRows ?: NSUIntegerMax)) { t->_truncated = YES; break; }
        JSONNode *v = JSONParse([NSData dataWithBytesNoCopy:(void *)(s + a) length:b - a freeWhenDone:NO], NULL);
        if (!v || (v.kind != JSONObject && v.kind != JSONArray)) { t->_badLines++; continue; }
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (JSONNode *c in v.children) {
            NSString *k = v.kind == JSONObject ? c.key : [NSString stringWithFormat:@"%lu", (unsigned long)c.index];
            if (!seen[k] && t->_headers.count < 500) { seen[k] = @YES; [t->_headers addObject:k]; }
            row[k] = cellText(c);
        }
        [t->_rows addObject:row];
        [t->_lines addObject:@(line)];
    }
    return t;
}

- (NSUInteger)rowCount { return _rows.count; }
- (NSUInteger)columnCount { return _headers.count; }
- (BOOL)truncated { return _truncated; }
- (NSString *)headerForColumn:(NSUInteger)c { return c < _headers.count ? _headers[c] : @""; }
- (NSString *)cellAtRow:(NSUInteger)r column:(NSUInteger)c {
    if (r >= _rows.count || c >= _headers.count) return @"";
    return _rows[r][_headers[c]] ?: @"";
}
- (NSUInteger)sourceLineOfRow:(NSUInteger)r { return r < _lines.count ? _lines[r].unsignedIntegerValue : 0; }

@end

#pragma mark In memory

@implementation ArrayTable {
    NSArray<NSString *> *_headers;
    NSArray<NSArray<NSString *> *> *_rows;
    BOOL _truncated;
}
+ (instancetype)tableWithHeaders:(NSArray<NSString *> *)headers rows:(NSArray<NSArray<NSString *> *> *)rows truncated:(BOOL)truncated {
    ArrayTable *t = [ArrayTable new];
    t->_headers = [headers copy]; t->_rows = [rows copy]; t->_truncated = truncated;
    return t;
}
- (NSUInteger)rowCount { return _rows.count; }
- (NSUInteger)columnCount { return _headers.count; }
- (BOOL)truncated { return _truncated; }
- (NSString *)headerForColumn:(NSUInteger)c { return c < _headers.count ? _headers[c] : @""; }
- (NSString *)cellAtRow:(NSUInteger)r column:(NSUInteger)c {
    if (r >= _rows.count) return @"";
    NSArray *row = _rows[r];
    return c < row.count ? row[c] : @"";
}
@end

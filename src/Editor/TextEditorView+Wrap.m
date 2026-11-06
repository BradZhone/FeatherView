#import "TextEditorView+Private.h"

// Soft wrap. Each logical line occupies one or more visual rows of _lineHeight; _rowStart holds
// prefix sums so row ↔ line lookups are O(log n) and an edit only re-measures the lines it touched.
// Breaks come from one function (rowsOf:) used by the table, drawing and hit testing alike.

static const NSUInteger kWrapMaxBytes = 32u << 20, kWrapMaxLines = 1000000;
static const CGFloat kMinWrapWidth = 120;

static inline BOOL isWideChar(unichar c) {
    return c >= 0x1100 && (c <= 0x115F || (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
                           (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60) ||
                           (c >= 0xFFE0 && c <= 0xFFE6));
}
static inline BOOL isSpace(unichar c) { return c == ' ' || c == '\t' || c == 0x3000; }
// A row may end after these (paths, URLs, lists, minified code).
static inline BOOL breaksAfter(unichar c) {
    return c == '-' || c == '/' || c == '\\' || c == ',' || c == ';' || c == '&' || c == '|' || c == '?' ||
           c == 0x3001 || c == 0x3002 || c == 0xFF0C || c == 0xFF1B || c == 0xFF1A || c == 0xFF01 || c == 0xFF1F;
}
// Closing CJK punctuation must not start a row.
static inline BOOL noBreakBefore(unichar c) {
    return c == 0x3001 || c == 0x3002 || c == 0xFF0C || c == 0xFF0E || c == 0xFF1A || c == 0xFF1B || c == 0xFF01 ||
           c == 0xFF1F || c == 0xFF09 || c == 0x300B || c == 0x300D || c == 0x300F || c == 0x3011 || c == 0x201D || c == 0x2019;
}

// Index of the last row whose first row is <= row (rowStart has n + 1 entries).
static NSUInteger findLine(const uint64_t *rowStart, NSUInteger n, uint64_t row) {
    NSUInteger lo = 0, hi = n - 1;
    while (lo < hi) {
        NSUInteger mid = (lo + hi + 1) / 2;
        if (rowStart[mid] <= row) lo = mid; else hi = mid - 1;
    }
    return lo;
}

@implementation TextEditorView (Wrap)

#pragma mark Measuring

- (CGFloat)tabWidth { return 4 * _charWidth; }

- (CGFloat)wrapWidthNow {
    return self.bounds.size.width - self.gutterWidth - 8 - self.rightInset - _charWidth - 6;
}

// Advance of the cluster at [r] in s. ASCII is the font's fixed advance; everything else is measured once.
- (CGFloat)advanceOf:(NSString *)s range:(NSRange)r {
    if (!_advances) _advances = [NSMutableDictionary dictionary];
    id key = r.length == 1 ? (id)@([s characterAtIndex:r.location]) : [s substringWithRange:r];
    NSNumber *w = _advances[key];
    if (w) return w.doubleValue;
    // CJK punctuation is narrower at the end of a string than mid-line: measure it followed by
    // another character too and keep the wider, so rows never come out wider than measured
    NSString *c = [s substringWithRange:r];
    CGFloat adv = 0;
    for (NSString *t in @[c, [c stringByAppendingString:@"x"]]) {
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:t attributes:@{(id)kCTFontAttributeName: (__bridge id)_font}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        adv = MAX(adv, CTLineGetTypographicBounds(line, NULL, NULL, NULL) - (t.length > c.length ? _charWidth : 0));
        CFRelease(line);
    }
    if (_advances.count > 20000) [_advances removeAllObjects];
    _advances[key] = @(adv);
    return adv;
}

// Row starts of s laid out in `width`. A row ends after a space or break-after punctuation, or
// between CJK characters; a word longer than a row is split at a cluster boundary. Spaces may hang
// past the edge. Continuation rows are indented like the line itself while that leaves half the width.
- (WrapRows)rowsOf:(NSString *)s width:(CGFloat)width {
    WrapRows out = {1, NULL, 0};
    NSUInteger n = s.length;
    if (!n || width <= 0) return out;
    const CGFloat cw = _charWidth, tab = self.tabWidth, eps = 0.01;
    unichar stack[512];
    unichar *u = n <= 512 ? stack : malloc(n * sizeof(unichar));
    [s getCharacters:u range:NSMakeRange(0, n)];

    BOOL ascii = YES;
    for (NSUInteger i = 0; i < n && ascii; i++) ascii = u[i] >= 0x20 && u[i] < 0x7F;
    if (ascii && n * cw <= width + eps) { if (u != stack) free(u); return out; }

    NSUInteger lead = 0;
    CGFloat leadW = 0;
    while (lead < n && (u[lead] == ' ' || u[lead] == '\t')) {
        leadW = u[lead] == '\t' ? (floor(leadW / tab + eps) + 1) * tab : leadW + cw;
        lead++;
    }
    CGFloat indent = leadW <= width / 2 ? leadW : 0;

    NSUInteger cap = 0, rowStart = 0, brk = NSNotFound, i = 0;
    CGFloat origin = 0, x = 0;            // x: advance since the row's first character
    unichar prev = 0;
    BOOL havePrev = NO;
    while (i < n) {
        unichar c = u[i];
        NSUInteger len = 1;
        CGFloat w;
        BOOL cont = NO;                   // inside a cluster that started earlier
        if (c == '\t') w = (floor(x / tab + eps) + 1) * tab - x;
        else if (c >= 0x20 && c < 0x7F) w = cw;
        else {
            NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:i];
            if (r.location < i) { cont = YES; w = 0; len = NSMaxRange(r) - i; }
            else { len = r.length; w = [self advanceOf:s range:r]; }
        }
        if (!cont && havePrev && i > rowStart && (out.count > 1 || i > lead) && !isSpace(c) &&
            (isSpace(prev) || breaksAfter(prev) || ((isWideChar(prev) || isWideChar(c)) && !noBreakBefore(c))))
            brk = i;
        if (!cont && !isSpace(c) && i > rowStart && origin + x + w > width + eps) {
            NSUInteger at = brk != NSNotFound && brk > rowStart ? brk : i;
            if (out.count >= cap) {
                cap = MAX((NSUInteger)8, cap * 2);
                out.starts = realloc(out.starts, cap * sizeof(uint32_t));
                out.starts[0] = 0;
            }
            out.starts[out.count++] = (uint32_t)at;
            rowStart = i = at;
            origin = indent; x = 0; brk = NSNotFound; havePrev = NO;
            continue;                     // re-measure from the break
        }
        x += w;
        if (!cont) { prev = c; havePrev = YES; }
        i += len;
    }
    if (u != stack) free(u);
    out.indent = out.count > 1 ? indent : 0;
    return out;
}

- (WrapRows)rowsOf:(NSString *)s {
    if (!_wrapActive) return (WrapRows){1, NULL, 0};
    return [self rowsOf:s width:_wrapWidth];
}

// Rows of line L as stored in the buffer (IME text is added by refreshRowsOfLine:).
- (NSUInteger)rowCountOfLine:(NSUInteger)L {
    NSUInteger s = [_buf lineStart:L], e = [_buf lineEnd:L], len = e - s;
    CGFloat width = _wrapWidth;
    if (len * 4 * _charWidth <= width) return 1;        // a tab or a wide glyph is at most 4 columns per byte
    if (len <= 1024) {
        uint8_t b[1024];
        [_buf read:NSMakeRange(s, len) into:b];
        BOOL ascii = YES;
        for (NSUInteger i = 0; i < len && ascii; i++) ascii = b[i] >= 0x20 && b[i] < 0x7F;
        if (ascii && len * _charWidth <= width + 0.01) return 1;
    }
    WrapRows r = [self rowsOf:[self lineString:L] width:width];
    free(r.starts);
    return r.count;
}

- (NSString *)displayString:(NSUInteger)L {
    NSString *s = [self lineString:L];
    if (!_markedText.length || L != [_buf lineForOffset:_caret]) return s;
    NSUInteger at = MIN([self utf16Index:_caret inLine:L], s.length);
    return [NSString stringWithFormat:@"%@%@%@", [s substringToIndex:at], _markedText, [s substringFromIndex:at]];
}

#pragma mark Row table

- (void)ensureRowCap:(NSUInteger)need {
    if (need <= _rowCap) return;
    _rowCap = MAX(need, _rowCap * 3 / 2 + 64);
    _rowStart = realloc(_rowStart, _rowCap * sizeof(uint64_t));
}

- (void)setRows:(NSUInteger)rows forLine:(NSUInteger)L {
    if (!_wrapActive || !_wrapValid || L >= _wrapLines) return;
    int64_t d = (int64_t)rows - (int64_t)(_rowStart[L + 1] - _rowStart[L]);
    if (!d) return;
    for (NSUInteger k = L + 1; k <= _wrapLines; k++) _rowStart[k] += d;
}

- (void)refreshRowsOfLine:(NSUInteger)L {
    if (!_wrapActive || !_wrapValid) return;
    WrapRows r = [self rowsOf:[self displayString:L]];
    free(r.starts);
    [self setRows:r.count forLine:L];
}

- (void)rebuildWrapTable {
    NSUInteger n = _buf.lineCount;
    [self ensureRowCap:n + 1];
    uint64_t acc = 0;
    for (NSUInteger L = 0; L < n; L++) { _rowStart[L] = acc; acc += [self rowCountOfLine:L]; }
    _rowStart[n] = acc;
    _wrapLines = n;
    _wrapValid = YES;
    if (_markedText) [self refreshRowsOfLine:[_buf lineForOffset:_caret]];
}

- (BOOL)wrapLimited {
    return _wordWrap && (_buf.length > kWrapMaxBytes || _buf.lineCount > kWrapMaxLines);
}

// Builds, rebuilds or drops the row table so it matches the current settings and width,
// keeping the logical line at the top of the view where it was.
- (void)ensureWrap {
    if (_wrapBusy) return;
    CGFloat width = floor(self.wrapWidthNow);
    BOOL want = _wordWrap && !self.wrapLimited && width >= kMinWrapWidth;
    BOOL stale = want && (!_wrapActive || !_wrapValid || _wrapLines != _buf.lineCount || fabs(width - _wrapWidth) >= 0.5);
    BOOL drop = !want && _wrapActive;
    if (!stale && !drop && _pendingTop < 0) return;
    _wrapBusy = YES;
    CGFloat top = _pendingTop;
    if (top < 0 && (!_wrapActive || (_wrapValid && _wrapLines == _buf.lineCount))) top = MAX(0, [self lineAtY:self.scrollY]);
    _pendingTop = -1;
    if (stale) {
        _wrapWidth = width;
        _wrapActive = YES;
        [self rebuildWrapTable];
    } else if (drop) {
        _wrapActive = _wrapValid = NO;
        free(_rowStart); _rowStart = NULL; _rowCap = 0; _wrapLines = 0;
    }
    if (top >= 0) [self scrollToLine:top];
    _wrapBusy = NO;
    if (stale || drop) self.needsDisplay = YES;
}

- (void)changeLayout:(void (^)(void))change {
    [self ensureWrap];
    CGFloat top = MAX(0, [self lineAtY:self.scrollY]);
    change();
    _wrapValid = NO;
    _pendingTop = top;
    [self ensureWrap];
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

#pragma mark Edits

- (void)beginEdit:(NSRange)r {
    _editLines = NSMakeRange(NSNotFound, 0);
    if (!_wrapActive || _bulkEdit) return;
    if (!_wrapValid || _wrapLines != _buf.lineCount) { _wrapValid = NO; return; }
    NSUInteger a = [_buf lineForOffset:r.location], b = [_buf lineForOffset:NSMaxRange(r)];
    _editLines = NSMakeRange(a, b - a + 1);
}

// Re-measures the lines the edit produced and shifts the rows after them.
- (void)endEdit {
    if (_editLines.location == NSNotFound) return;
    NSUInteger a = _editLines.location, oldEnd = NSMaxRange(_editLines), n = _buf.lineCount;
    _editLines = NSMakeRange(NSNotFound, 0);
    NSUInteger newEnd = oldEnd + n - _wrapLines;             // wraps correctly when lines were removed
    if (newEnd <= a || newEnd > n) { _wrapValid = NO; return; }
    NSUInteger cnt = newEnd - a;
    uint64_t *rows = malloc(cnt * sizeof(uint64_t)), acc = 0;
    for (NSUInteger k = 0; k < cnt; k++) { rows[k] = acc; acc += [self rowCountOfLine:a + k]; }
    uint64_t base = _rowStart[a];
    int64_t d = (int64_t)(base + acc) - (int64_t)_rowStart[oldEnd];
    [self ensureRowCap:n + 1];
    memmove(&_rowStart[newEnd], &_rowStart[oldEnd], (_wrapLines + 1 - oldEnd) * sizeof(uint64_t));
    for (NSUInteger k = newEnd; k <= n; k++) _rowStart[k] += d;
    for (NSUInteger k = 0; k < cnt; k++) _rowStart[a + k] = base + rows[k];
    free(rows);
    _wrapLines = n;
    if (_markedText) [self refreshRowsOfLine:[_buf lineForOffset:_caret]];
}

- (CGFloat)beginBulkEdit {
    [self ensureWrap];
    _bulkEdit = YES;
    return MAX(0, [self lineAtY:self.scrollY]);
}

- (void)endBulkEdit:(CGFloat)top {
    _bulkEdit = NO;
    if (!_wrapActive) return;
    _wrapValid = NO;
    _pendingTop = top;
    [self ensureWrap];
}

#pragma mark Geometry

- (BOOL)wrapOn { [self ensureWrap]; return _wrapActive && _wrapValid; }

- (NSUInteger)rowCount { return self.wrapOn ? (NSUInteger)_rowStart[_wrapLines] : _buf.lineCount; }

- (NSUInteger)firstRowOfLine:(NSUInteger)L {
    if (!self.wrapOn) return L;
    return (NSUInteger)_rowStart[MIN(L, _wrapLines)];
}

- (NSUInteger)lineOfRow:(NSUInteger)row {
    if (!self.wrapOn) return MIN(row, _buf.lineCount - 1);
    return findLine(_rowStart, _wrapLines, MIN((uint64_t)row, _rowStart[_wrapLines] - 1));
}

- (CGFloat)yForLine:(CGFloat)line {
    if (!self.wrapOn || line <= 0) return 4 + line * _lineHeight;
    NSUInteger L = (NSUInteger)floor(line);
    if (L >= _wrapLines) return 4 + (_rowStart[_wrapLines] + (line - _wrapLines)) * _lineHeight;
    CGFloat f = line - L;
    return 4 + (_rowStart[L] + f * (_rowStart[L + 1] - _rowStart[L])) * _lineHeight;
}

- (CGFloat)lineAtY:(CGFloat)y {
    CGFloat row = (y - 4) / _lineHeight;
    if (!self.wrapOn || row <= 0) return row;
    uint64_t total = _rowStart[_wrapLines];
    if (row >= total) return _wrapLines + (row - total);
    NSUInteger L = findLine(_rowStart, _wrapLines, (uint64_t)floor(row));
    return L + (row - _rowStart[L]) / (CGFloat)(_rowStart[L + 1] - _rowStart[L]);
}

- (void)scrollToLine:(CGFloat)line {
    self.scrollY = line <= 0 ? 0 : [self yForLine:line];
}

// Row (global) holding `off`, and its x inside the text area. An offset at a row boundary
// belongs to the row it starts.
- (NSUInteger)rowOfOffset:(NSUInteger)off x:(CGFloat *)x {
    NSUInteger L = [_buf lineForOffset:off];
    NSString *s = [self lineString:L];
    NSUInteger u = MIN([self utf16Index:off inLine:L], s.length);
    WrapRows r = [self rowsOf:s];
    NSUInteger k = 0;
    while (k + 1 < r.count && r.starts[k + 1] <= u) k++;
    NSUInteger a = k ? r.starts[k] : 0, b = k + 1 < r.count ? r.starts[k + 1] : s.length;
    if (x) {
        CTLineRef line = [self createLine:s range:NSMakeRange(a, b - a)];
        *x = (k ? r.indent : 0) + CTLineGetOffsetForStringIndex(line, u, NULL);
        CFRelease(line);
    }
    free(r.starts);
    NSUInteger first = [self firstRowOfLine:L];
    if (self.wrapOn) k = MIN(k, (NSUInteger)(_rowStart[L + 1] - _rowStart[L]) - 1);
    return first + k;
}

- (NSUInteger)offsetInRow:(NSUInteger)row x:(CGFloat)x {
    NSUInteger L = [self lineOfRow:row];
    NSUInteger k = row - [self firstRowOfLine:L];
    NSString *s = [self lineString:L];
    WrapRows r = [self rowsOf:s];
    k = MIN(k, r.count - 1);
    NSUInteger a = k ? r.starts[k] : 0, b = k + 1 < r.count ? r.starts[k + 1] : s.length;
    CGFloat indent = k ? r.indent : 0;
    free(r.starts);
    CTLineRef line = [self createLine:s range:NSMakeRange(a, b - a)];
    CFIndex idx = CTLineGetStringIndexForPosition(line, CGPointMake(MAX(0, x - indent), 0));
    CFRelease(line);
    NSUInteger i = idx == kCFNotFound ? a : MIN(MAX((NSUInteger)idx, a), b);
    if (i == b && b < s.length) i = [s rangeOfComposedCharacterSequenceAtIndex:b - 1].location;   // stay on this row
    else if (i < s.length) i = [s rangeOfComposedCharacterSequenceAtIndex:i].location;
    return [self byteOffsetForUTF16:i inLine:L];
}

@end

#import "SheetGrid.h"
#import "Localization.h"

static const NSUInteger kSpareRows = 60, kSpareCols = 12;     // room beyond the data to type into

@implementation SheetGrid
@synthesize zoom = _zoom;

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _zoom = 1;
    _fonts = [NSMutableDictionary dictionary];
    _capRows = _capCols = 1;
    _ry = calloc(1, sizeof(CGFloat)); _cx = calloc(1, sizeof(CGFloat));
    return self;
}

- (void)dealloc { free(_ry); free(_cx); }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isEditing { return _field != nil; }
- (NSUInteger)row { return _row; }
- (NSUInteger)col { return _col; }

- (XLRange)selection {
    XLRange r = {MIN(_row, _anchorRow), MIN(_col, _anchorCol), MAX(_row, _anchorRow), MAX(_col, _anchorCol)};
    return r;
}

- (void)setSheet:(XLSheet *)s {
    [self cancelEditing];
    _sheet = s;
    _nRows = _nCols = 0;
    _row = _col = _anchorRow = _anchorCol = 0;
    self.scrollX = 0; self.scrollY = 0;
    [self ensureRows:s.rowCount + kSpareRows cols:s.columnCount + kSpareCols];
    self.needsDisplay = YES;
    if (self.onSelect) self.onSelect();
}

- (void)setZoom:(CGFloat)z {
    _zoom = MIN(MAX(z, 0.25), 4);
    [_fonts removeAllObjects];
    NSUInteger r = _nRows, c = _nCols;
    _nRows = _nCols = 0;
    [self ensureRows:r cols:c];
    [self cancelEditing];
    [self clampScroll];
    self.needsDisplay = YES;
}

- (void)invalidate {
    [self ensureRows:_sheet.rowCount + kSpareRows cols:_sheet.columnCount + kSpareCols];
    self.needsDisplay = YES;
}

#pragma mark Geometry

- (void)ensureRows:(NSUInteger)n cols:(NSUInteger)m {
    n = MIN(n, (NSUInteger)1048576); m = MIN(m, (NSUInteger)16384);
    if (n > _nRows) {
        if (n + 1 > _capRows) { _capRows = MAX(n + 1, _capRows * 2); _ry = realloc(_ry, _capRows * sizeof(CGFloat)); }
        if (!_nRows) _ry[0] = 0;
        for (NSUInteger r = _nRows; r < n; r++) _ry[r + 1] = _ry[r] + round([_sheet heightOfRow:r] * 4 / 3 * _zoom);   // points → pixels, like Excel
        _nRows = n;
    }
    if (m > _nCols) {
        if (m + 1 > _capCols) { _capCols = MAX(m + 1, _capCols * 2); _cx = realloc(_cx, _capCols * sizeof(CGFloat)); }
        if (!_nCols) _cx[0] = 0;
        for (NSUInteger c = _nCols; c < m; c++) _cx[c + 1] = _cx[c] + round([_sheet widthOfColumn:c] * 4 / 3 * _zoom);
        _nCols = m;
    }
}

- (CGFloat)headerHeight { return round(20 * MIN(_zoom, 1.5)); }
- (CGFloat)headerWidth {
    NSUInteger digits = 1;
    for (NSUInteger n = _nRows; n >= 10; n /= 10) digits++;
    return round(MAX(3, digits) * 7.5 * MIN(_zoom, 1.5) + 12);
}
- (NSUInteger)frozenRows { return MIN(_sheet.frozenRows, _nRows); }
- (NSUInteger)frozenCols { return MIN(_sheet.frozenColumns, _nCols); }
- (CGFloat)frozenH { return _ry[self.frozenRows]; }
- (CGFloat)frozenW { return _cx[self.frozenCols]; }

- (CGFloat)contentHeight { return self.headerHeight + _ry[_nRows]; }
- (CGFloat)maxScrollX { return MAX(0, self.headerWidth + _cx[_nCols] - self.bounds.size.width + 20); }

// Grows the grid as it is scrolled towards its end, like a spreadsheet.
- (void)clampScroll {
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    if (_nRows && self.scrollY + h * 2 > _ry[_nRows]) [self ensureRows:_nRows + 200 cols:_nCols];
    if (_nCols && self.scrollX + w * 2 > _cx[_nCols]) [self ensureRows:_nRows cols:_nCols + 20];
    [super clampScroll];
}

- (CGFloat)yOfRow:(NSUInteger)r {
    CGFloat y = _ry[MIN(r, _nRows)];
    return self.headerHeight + (r < self.frozenRows ? y : y - self.scrollY);
}
- (CGFloat)xOfCol:(NSUInteger)c {
    CGFloat x = _cx[MIN(c, _nCols)];
    return self.headerWidth + (c < self.frozenCols ? x : x - self.scrollX);
}

- (NSRect)rectForRow:(NSUInteger)r col:(NSUInteger)c {
    XLRange m = {r, c, r, c};
    [_sheet mergeAt:r col:c range:&m];
    [self ensureRows:m.lastRow + 1 cols:m.lastCol + 1];
    CGFloat x = [self xOfCol:m.col], y = [self yOfRow:m.row];
    return NSMakeRect(x, y, _cx[m.lastCol + 1] - _cx[m.col], _ry[m.lastRow + 1] - _ry[m.row]);
}

static NSUInteger indexAt(const CGFloat *edges, NSUInteger n, CGFloat v) {   // last i with edges[i] <= v
    NSUInteger lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi + 1) / 2; if (edges[mid] <= v) lo = mid; else hi = mid - 1; }
    return MIN(lo, n ? n - 1 : 0);
}

- (BOOL)cellAtPoint:(NSPoint)p row:(NSUInteger *)r col:(NSUInteger *)c {
    CGFloat gx = p.x - self.headerWidth, gy = p.y - self.headerHeight;
    if (gx < 0 || gy < 0) return NO;
    if (gx >= self.frozenW) gx += self.scrollX;
    if (gy >= self.frozenH) gy += self.scrollY;
    [self ensureRows:indexAt(_ry, _nRows, gy) + 2 cols:indexAt(_cx, _nCols, gx) + 2];
    *r = indexAt(_ry, _nRows, gy); *c = indexAt(_cx, _nCols, gx);
    return YES;
}

- (void)scrollToActive {
    NSRect cell = [self rectForRow:_row col:_col], b = self.bounds;
    CGFloat top = self.headerHeight + self.frozenH, left = self.headerWidth + self.frozenW;
    if (_row >= self.frozenRows) {
        if (NSMinY(cell) < top) self.scrollY -= top - NSMinY(cell);
        else if (NSMaxY(cell) > NSMaxY(b)) self.scrollY += NSMaxY(cell) - NSMaxY(b);
    }
    if (_col >= self.frozenCols) {
        if (NSMinX(cell) < left) self.scrollX -= left - NSMinX(cell);
        else if (NSMaxX(cell) > NSMaxX(b) - 12) self.scrollX += NSMaxX(cell) - NSMaxX(b) + 12;
    }
    if (_field) _field.frame = NSInsetRect([self rectForRow:_row col:_col], 1, 1);
}

- (void)selectRow:(NSUInteger)row col:(NSUInteger)col extend:(BOOL)extend {
    row = MIN(row, (NSUInteger)1048575); col = MIN(col, (NSUInteger)16383);
    XLRange m;
    if (!extend && [_sheet mergeAt:row col:col range:&m]) { row = m.row; col = m.col; }
    _row = row; _col = col;
    if (!extend) { _anchorRow = row; _anchorCol = col; }
    [self ensureRows:row + kSpareRows cols:col + kSpareCols];
    [self scrollToActive];
    self.needsDisplay = YES;
    if (self.onSelect) self.onSelect();
}

@end

#import "TScreen.h"

// The grid, the scroll region, deferred autowrap, the alternate screen and the scrollback.
// Region boundaries are inclusive line indices; everything is clamped so stray sequences can't
// crash the terminal (a hostile or buggy program writes here).

static void clearCells(TCell *cells, NSUInteger count) {
    TCell blank = {0, TCDefault, TCDefault, 0};
    for (NSUInteger i = 0; i < count; i++) cells[i] = blank;
}

@interface TScreen () {
@public
    TCell *_grid, *_altGrid;
    BOOL _alt, _fullRegion, _primaryFullRegion;
    NSUInteger _cols, _rows, _curR, _curC, _top, _bot;
    // Retain clipped columns and bottom rows until they are exposed again or overwritten.
    NSUInteger _stride, _gridRows, _altRows, _regionTop, _regionBottom, _primaryTop, _primaryBottom;
    BOOL _wrapPending, _autoWrap, _origin, _appCursor, _sgrMouse, _bracketed, _inverse, _savedInverse;
    TMouseMode _mouse;
    uint32_t _fg, _bg;
    uint8_t _attrs;
    NSUInteger _savedR, _savedC;
    uint32_t _savedFg, _savedBg;
    uint8_t _savedAttrs;
    NSMutableArray<NSData *> *_history;
    NSUInteger _historyMax, _historyStart;
    uint32_t _palette[256];
    NSMutableData *_stops;                 // uint8_t per column
    NSString *_title, *_cwd;
    NSUInteger _bells;
    uint32_t _lastChar;
}
- (void)blankRow:(NSUInteger)r from:(NSUInteger)c count:(NSUInteger)n;
@end
@implementation TScreen

- (instancetype)initWithCols:(NSUInteger)cols rows:(NSUInteger)rows scrollback:(NSUInteger)maxLines {
    if (!(self = [super init])) return nil;
    _cols = MAX(cols, (NSUInteger)2);
    _rows = MAX(rows, (NSUInteger)1);
    _historyMax = MAX(maxLines, (NSUInteger)100);
    _stride = _cols;
    _gridRows = _altRows = _rows;
    _grid = calloc(_stride * _gridRows, sizeof(TCell));
    _altGrid = calloc(_stride * _altRows, sizeof(TCell));
    _history = [NSMutableArray array];
    _stops = [NSMutableData dataWithLength:_cols];
    // A usable ANSI palette also exists before any view has drawn this screen.
    const uint32_t ansi[16] = {0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                               0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF};
    [self setPalette16:ansi];
    // 16-255 are the standard xterm cube and greys.
    for (NSUInteger i = 16; i < 256; i++) {
        NSUInteger k = i - 16;
        NSUInteger r = k / 36, g = (k / 6) % 6, b = k % 6;
        if (i >= 232) { NSUInteger grey = 8 + (NSUInteger)(i - 232) * 10; _palette[i] = grey << 16 | grey << 8 | grey; }
        else _palette[i] = (r ? (55 + r * 40) : 0) << 16 | (g ? (55 + g * 40) : 0) << 8 | (b ? (55 + b * 40) : 0);
    }
    _fg = _bg = TCDefault;
    _savedFg = _savedBg = TCDefault;
    _defaultFg = TCDefault;
    _defaultBg = TCDefault;
    _cursorVisible = YES;
    _top = 0;
    _bot = _rows - 1;
    [self reset];
    return self;
}

- (void)dealloc { free(_grid); free(_altGrid); }

// ESC c: everything back to power-up values.
- (void)reset {
    if (_alt) [self leaveAltScreen];
    clearCells(_grid, _stride * _gridRows);
    clearCells(_altGrid, _stride * _altRows);
    [self clearScrollback];
    _curR = _curC = _savedR = _savedC = 0;
    _top = _regionTop = _primaryTop = 0;
    _bot = _regionBottom = _primaryBottom = _rows - 1;
    _fullRegion = _primaryFullRegion = YES;
    _wrapPending = NO;
    _autoWrap = YES;
    _origin = NO;
    _appCursor = NO;
    _alt = NO;
    _sgrMouse = NO;
    _bracketed = NO;
    _inverse = NO;
    _mouse = TMouseOff;
    _fg = _bg = TCDefault;
    _attrs = 0;
    _cursorVisible = YES;
    for (NSUInteger i = 0; i < _cols; i += 8) if (i) ((uint8_t *)_stops.mutableBytes)[i] = 1;
    _lastChar = 0;
}

#pragma mark Accessors

- (NSUInteger)cols { return _cols; }
- (NSUInteger)rows { return _rows; }
- (NSUInteger)historyCount { return _history.count; }
- (NSUInteger)historyStart { return _historyStart; }
- (NSUInteger)tabStops { NSUInteger n = 0; const uint8_t *s = _stops.bytes; for (NSUInteger i = 0; i < _cols && i < 64; i++) if (s[i]) n |= 1UL << i; return n; }
- (BOOL)autoWrap { return _autoWrap; }
- (BOOL)originMode { return _origin; }
- (BOOL)appCursorKeys { return _appCursor; }
- (BOOL)altScreen { return _alt; }
- (BOOL)sgrMouse { return _sgrMouse; }
- (BOOL)bracketedPaste { return _bracketed; }
- (BOOL)inverse { return _inverse; }
- (TMouseMode)mouseMode { return _mouse; }
- (NSUInteger)cursorRow { return _curR; }
- (NSUInteger)cursorCol { return _curC; }
- (NSUInteger)scrollTop { return _top; }
- (NSUInteger)scrollBottom { return _bot; }
- (NSString *)title { return _title; }
- (NSString *)cwd { return _cwd; }
- (const uint32_t *)palette { return _palette; }
- (void)setPalette16:(const uint32_t *)colors { for (int i = 0; i < 16; i++) _palette[i] = colors[i]; }
- (NSUInteger)bellCount { return _bells; }

- (TCell)cellAtRow:(NSUInteger)r col:(NSUInteger)c {
    if (r >= _rows || c >= _cols) return (TCell){0, TCDefault, TCDefault, 0};
    return _grid[r * _stride + c];
}

- (NSUInteger)historyLength:(NSUInteger)i {
    if (i >= _history.count) return 0;
    return ((const NSData *)_history[i]).length / sizeof(TCell);
}

- (const TCell *)historyCells:(NSUInteger)i {
    if (i >= _history.count) return NULL;
    return ((const NSData *)_history[i]).bytes;
}

#pragma mark Cells

- (void)appendHistory:(NSData *)line {
    [_history addObject:line];
    if (_history.count > _historyMax) {
        NSUInteger removed = _history.count - _historyMax;
        _historyStart += removed;
        [_history removeObjectsInRange:NSMakeRange(0, removed)];
    }
}

- (void)pushHistoryRow:(NSUInteger)r {
    if (r < _rows) [self appendHistory:[self cellsOfRow:r]];
}

- (void)bell { _bells++; }

- (void)blankRow:(NSUInteger)r from:(NSUInteger)c count:(NSUInteger)n {
    if (r >= _rows) return;
    n = MIN(n, _cols - MIN(c, _cols));
    TCell blank = {0, TCDefault, TCDefault, 0};
    blank.fg = _inverse ? _fg : TCDefault;
    blank.bg = _inverse ? TCDefault : _bg;
    // A complete line erase also invalidates columns retained from a wider layout.
    if (c == 0 && n == _cols) clearCells(_grid + r * _stride, _stride);
    for (NSUInteger i = 0; i < n; i++) _grid[r * _stride + c + i] = blank;
}

- (void)putChar:(uint32_t)ch wide:(BOOL)wide {
    if (!_cols || !_rows) return;
    if (_curC >= _cols) { _curC = _cols - 1; _wrapPending = _autoWrap; }
    if (_wrapPending && _autoWrap) {
        _wrapPending = NO;
        _curC = 0;
        if (_curR == _bot) [self scrollUp:1];
        else if (_curR + 1 < _rows) _curR++;
    }
    // a wide character at the last column starts on the next row
    if (wide && _curC + 1 >= _cols) { _grid[_curR * _stride + _curC] = (TCell){0, TCDefault, TCDefault, 0}; _curC = 0;
        if (_curR == _bot) [self scrollUp:1]; else if (_curR + 1 < _rows) _curR++; }
    if (_curR >= _rows || _curC >= _cols) return;
    TCell *cell = &_grid[_curR * _stride + _curC];
    uint32_t fg = _fg, bg = _bg;
    uint8_t attrs = _attrs | (wide ? TFWide : 0);
    if (_inverse) { uint32_t t = fg; fg = bg; bg = t; attrs |= TFReverse; }
    *cell = (TCell){ch, fg, bg, attrs};
    _lastChar = ch;
    _curC++;
    if (wide) {
        if (_curC < _cols) _grid[_curR * _stride + _curC] = (TCell){ch, fg, bg, attrs | TFCont};
        _curC++;
    }
    if (_curC >= _cols) { _curC = _cols - 1; _wrapPending = _autoWrap; } else _wrapPending = NO;
}

- (void)carriageReturn { _curC = 0; _wrapPending = NO; }
- (void)backspace { if (_curC) _curC--; _wrapPending = NO; }

- (void)tab {
    if (!_stops.length) return;
    uint8_t *s = _stops.mutableBytes;
    do { if (_curC + 1 < _cols) _curC++; } while (_curC + 1 < _cols && !s[_curC]);
    _wrapPending = NO;
}

- (void)setTabStop { if (!_stops.length) return; ((uint8_t *)_stops.mutableBytes)[_curC] = 1; }

- (void)backwardTab {
    if (!_stops.length) return;
    const uint8_t *s = _stops.bytes;
    NSUInteger c = _curC;
    do { if (c) c--; } while (c && !s[c]);
    _curC = c;
    _wrapPending = NO;
}
- (void)clearTabStop:(NSInteger)mode {
    if (!_stops.length) return;
    uint8_t *s = _stops.mutableBytes;
    if (mode == 0) s[_curC] = 0;
    else if (mode == 3) memset(s, 0, _cols);
}

- (void)cursorUp:(NSUInteger)n { NSUInteger t = _origin ? _top : 0; _curR = n && _curR >= t + n ? MAX(t, _curR - n) : t; _wrapPending = NO; }
- (void)cursorDown:(NSUInteger)n { NSUInteger b = _origin ? _bot : _rows - 1; _curR = MIN(b, _curR + n); _wrapPending = NO; }
- (void)cursorForward:(NSUInteger)n { _curC = MIN(_cols - 1, _curC + n); _wrapPending = NO; }
- (void)cursorBack:(NSUInteger)n { _curC = _curC > n ? _curC - n : 0; _wrapPending = NO; }
- (void)cursorToColumn:(NSUInteger)col { _curC = MIN(col, _cols - 1); _wrapPending = NO; }
- (void)cursorToRow:(NSUInteger)row { _curR = MIN(_origin ? _top + row : row, _rows - 1); _wrapPending = NO; }
- (void)cursorToRow:(NSUInteger)row col:(NSUInteger)col origin:(BOOL)origin {
    if (origin && _origin) [self cursorToRow:row];
    else _curR = MIN(row, _rows - 1);
    _curC = MIN(col, _cols - 1);
    _wrapPending = NO;
}

- (void)reverseLineFeed {
    if (_curR == _top) [self scrollDown:1];
    else if (_curR) _curR--;
}

- (void)lineFeed {
    if (_curR == _bot) [self scrollUp:1];
    else if (_curR + 1 < _rows) _curR++;
    _wrapPending = NO;
}

#pragma mark Scrolling

- (NSData *)cellsOfRow:(NSUInteger)r {
    return [NSData dataWithBytes:&_grid[r * _stride] length:_stride * sizeof(TCell)];
}

- (void)setRow:(NSUInteger)r from:(NSData *)d {
    if (r >= _rows) return;
    clearCells(&_grid[r * _stride], _stride);
    memcpy(&_grid[r * _stride], d.bytes, MIN(d.length, _stride * sizeof(TCell)));
}

// Lines leaving the top of a full-screen region go to the scrollback (the alternate screen never does).
- (void)scrollUp:(NSUInteger)n {
    n = MIN(n, _bot - _top + 1);
    for (NSUInteger k = 0; k < n; k++) {
        if (!_alt && _fullRegion) [self pushHistoryRow:0];
        for (NSUInteger r = _top; r < _bot; r++) memcpy(&_grid[r * _stride], &_grid[(r + 1) * _stride], _stride * sizeof(TCell));
        [self blankRow:_bot from:0 count:_cols];
    }
}

- (void)scrollDown:(NSUInteger)n {
    n = MIN(n, _bot - _top + 1);
    for (NSUInteger k = 0; k < n; k++) {
        for (NSUInteger r = _bot; r > _top; r--) memcpy(&_grid[r * _stride], &_grid[(r - 1) * _stride], _stride * sizeof(TCell));
        [self blankRow:_top from:0 count:_cols];
    }
}

- (void)setScrollRegionTop:(NSUInteger)top bottom:(NSUInteger)bottom {
    bottom = MIN(bottom, _rows - 1);
    if (top >= bottom + 1) return;                          // a degenerate region is ignored, like xterm
    _top = _regionTop = top;
    _bot = _regionBottom = bottom;
    _fullRegion = top == 0 && bottom == _rows - 1;
    _curR = _origin ? _top : 0;
    _wrapPending = NO;
}

#pragma mark Erasing

- (void)eraseInDisplay:(NSInteger)mode {
    NSUInteger r = _curR, c = _curC;
    if (mode == 0) {
        [self blankRow:r from:c count:_cols - c];
        for (NSUInteger k = r + 1; k < _rows; k++) [self blankRow:k from:0 count:_cols];
    } else if (mode == 1) {
        [self blankRow:r from:0 count:c + 1];
        for (NSUInteger k = 0; k < r; k++) [self blankRow:k from:0 count:_cols];
    } else if (mode == 2 || mode == 3) {
        for (NSUInteger k = 0; k < _rows; k++) [self blankRow:k from:0 count:_cols];
        clearCells(_grid + _rows * _stride, (_gridRows - _rows) * _stride);
        if (mode == 3) [self clearScrollback];
    }
}

- (void)eraseInLine:(NSInteger)mode {
    if (_curR >= _rows) return;
    if (mode == 0) [self blankRow:_curR from:_curC count:_cols - _curC];
    else if (mode == 1) [self blankRow:_curR from:0 count:MIN(_curC + 1, _cols)];
    else if (mode == 2) [self blankRow:_curR from:0 count:_cols];
}

- (void)insertLines:(NSUInteger)n {
    if (_curR < _top || _curR > _bot) return;
    n = MIN(n, _bot - _curR + 1);
    for (NSUInteger k = 0; k < n; k++) {
        NSData *last = [self cellsOfRow:_bot];
        for (NSUInteger r = _bot; r > _curR; r--) [self setRow:r from:[self cellsOfRow:r - 1]];
        [self setRow:_curR from:last];
        [self blankRow:_curR from:0 count:_cols];
    }
    _curC = 0;
    _wrapPending = NO;
}

- (void)deleteLines:(NSUInteger)n {
    if (_curR < _top || _curR > _bot) return;
    n = MIN(n, _bot - _curR + 1);
    for (NSUInteger k = 0; k < n; k++) {
        NSData *first = [self cellsOfRow:_curR];
        for (NSUInteger r = _curR; r < _bot; r++) [self setRow:r from:[self cellsOfRow:r + 1]];
        [self setRow:_bot from:first];
        [self blankRow:_bot from:0 count:_cols];
    }
    _curC = 0;
    _wrapPending = NO;
}

- (void)insertChars:(NSUInteger)n {
    if (_curR >= _rows) return;
    n = MIN(n, _cols - _curC);
    memmove(&_grid[_curR * _stride + _curC + n], &_grid[_curR * _stride + _curC], (_cols - _curC - n) * sizeof(TCell));
    [self blankRow:_curR from:_curC count:n];
}

- (void)deleteChars:(NSUInteger)n {
    if (_curR >= _rows) return;
    n = MIN(n, _cols - _curC);
    memmove(&_grid[_curR * _stride + _curC], &_grid[_curR * _stride + _curC + n], (_cols - _curC - n) * sizeof(TCell));
    [self blankRow:_curR from:_cols - n count:n];
}

- (void)eraseChars:(NSUInteger)n { if (_curR < _rows) [self blankRow:_curR from:_curC count:MIN(n, _cols - _curC)]; }

- (void)repeatLastChar:(NSUInteger)n {
    if (!_lastChar) return;
    for (NSUInteger i = 0; i < n; i++) [self putChar:_lastChar wide:NO];
}

#pragma mark Modes

- (void)setAutoWrap:(BOOL)on { _autoWrap = on; if (!on) _wrapPending = NO; }
- (void)setOriginMode:(BOOL)on { _origin = on; if (on) _curR = _top; _curC = 0; _wrapPending = NO; }
- (void)setAppCursorKeys:(BOOL)on { _appCursor = on; }
- (void)setCursorVisible:(BOOL)on { _cursorVisible = on; }
- (void)setMouseMode:(TMouseMode)mode { _mouse = mode; }
- (void)setSGRMouse:(BOOL)on { _sgrMouse = on; }
- (void)setBracketedPaste:(BOOL)on { _bracketed = on; }
- (void)setInverseScreen:(BOOL)on {
    if (on == _inverse) return;
    _inverse = on;
    for (NSUInteger i = 0; i < _rows * _stride; i++) {           // swap what is on screen now
        TCell *c = &_grid[i];
        uint32_t t = c->fg; c->fg = c->bg; c->bg = t;
    }
}

- (void)saveCursor { _savedR = _curR; _savedC = _curC; _savedFg = _fg; _savedBg = _bg; _savedAttrs = _attrs; _savedInverse = _inverse; }

- (void)restoreCursor {
    _curR = MIN(_savedR, _rows - 1);
    _curC = MIN(_savedC, _cols - 1);
    _fg = _savedFg; _bg = _savedBg; _attrs = _savedAttrs;
    _inverse = _savedInverse;
    _wrapPending = NO;
}

#pragma mark Alternate screen (DECSET 47 / 1047 / 1049)

- (void)enterAltScreen:(BOOL)clear {
    if (_alt) return;
    [self saveCursor];
    _primaryTop = _regionTop;
    _primaryBottom = _regionBottom;
    _primaryFullRegion = _fullRegion;
    _alt = YES;
    // Keep both backing stores equally large when the primary has clipped bottom rows.
    NSUInteger capacity = MAX(_gridRows, _altRows);
    TCell *next = calloc(capacity * _stride, sizeof(TCell));
    clearCells(next, capacity * _stride);
    if (!clear) memcpy(next, _grid, _gridRows * _stride * sizeof(TCell));
    free(_altGrid);
    _altGrid = _grid;
    _altRows = _gridRows;
    _grid = next;
    _gridRows = capacity;
    _top = _regionTop = 0;
    _bot = _regionBottom = _rows - 1;
    _fullRegion = YES;
    _curR = _curC = 0;
    _wrapPending = NO;
}

- (void)leaveAltScreen {
    if (!_alt) return;
    _alt = NO;
    TCell *t = _grid;
    _grid = _altGrid;
    _altGrid = t;
    NSUInteger capacity = _gridRows;
    _gridRows = _altRows;
    _altRows = capacity;
    _regionTop = _primaryTop;
    _regionBottom = _primaryBottom;
    _fullRegion = _primaryFullRegion;
    _top = _fullRegion ? 0 : MIN(_regionTop, _rows - 1);
    _bot = _fullRegion ? _rows - 1 : MAX(_top, MIN(_regionBottom, _rows - 1));
    [self restoreCursor];
}

#pragma mark SGR

- (void)sgr:(const NSInteger *)p count:(NSUInteger)n {
    static const NSInteger zero = 0;
    if (!n) { n = 1; p = &zero; }                                // SGR without parameters resets
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger v = p[i];
        if (v == 0) { _attrs = 0; _fg = _bg = TCDefault; }
        else if (v == 1) _attrs |= TFBold;
        else if (v == 3) _attrs |= TFItalic;
        else if (v == 4) _attrs |= TFUnderline;
        else if (v == 7) _attrs |= TFReverse;
        else if (v == 9) _attrs |= TFStrike;
        else if (v == 22) _attrs &= ~TFBold;
        else if (v == 23) _attrs &= ~TFItalic;
        else if (v == 24) _attrs &= ~TFUnderline;
        else if (v == 27) _attrs &= ~TFReverse;
        else if (v == 29) _attrs &= ~TFStrike;
        else if (v == 30) _fg = 0 | TCPal;
        else if (v >= 31 && v <= 37) _fg = (uint32_t)(v - 30) | TCPal;
        else if (v == 38 || v == 48) {
            uint32_t *slot = v == 38 ? &_fg : &_bg;
            if (i + 1 < n && p[i + 1] == 5 && i + 2 < n) { *slot = (uint32_t)MAX(0, MIN(p[i + 2], 255)) | TCPal; i += 2; }
            else if (i + 1 < n && p[i + 1] == 2 && i + 4 < n) {
                *slot = (uint32_t)(MAX(0, MIN(p[i + 2], 255)) << 16 | MAX(0, MIN(p[i + 3], 255)) << 8 | MAX(0, MIN(p[i + 4], 255)));
                i += 4;
            }
        }
        else if (v == 39) _fg = TCDefault;
        else if (v == 40) _bg = 0 | TCPal;
        else if (v >= 41 && v <= 47) _bg = (uint32_t)(v - 40) | TCPal;
        else if (v == 49) _bg = TCDefault;
        else if (v >= 90 && v <= 97) _fg = (uint32_t)(v - 90 + 8) | TCPal;
        else if (v >= 100 && v <= 107) _bg = (uint32_t)(v - 100 + 8) | TCPal;
    }
}

- (void)setTitle:(NSString *)title { _title = [title copy]; }
- (void)setCwd:(NSString *)fileURL {
    NSURL *u = [NSURL URLWithString:fileURL];
    if (![u.scheme.lowercaseString isEqualToString:@"file"]) return;
    NSString *p = u.path;
    if (p.length) _cwd = p;
}

#pragma mark Resize and scrollback

- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows {
    if (!cols || !rows) return;             // an unmounted view has no usable terminal geometry
    cols = MAX(cols, (NSUInteger)2);
    if (cols == _cols && rows == _rows) return;
    NSUInteger stride = MAX(cols, _stride);
    TCell *grids[2] = {_grid, _altGrid};
    NSUInteger capacities[2] = {_gridRows, _altRows};
    for (NSUInteger screen = 0; screen < 2; screen++) {
        BOOL primary = screen == (_alt ? 1 : 0);
        BOOL full = primary && (_alt ? _primaryFullRegion : _fullRegion);
        NSUInteger cursor = primary && _alt ? _savedR : _curR;
        // Remove unused bottom space first. Only lines above the cursor have to become history.
        NSUInteger shift = full && rows < _rows && cursor >= rows ? MIN(_rows - rows, cursor - rows + 1) : 0;
        NSUInteger retainedRows = MAX(_rows, capacities[screen]);
        NSUInteger pull = full && rows > retainedRows ? MIN(rows - retainedRows, _history.count) : 0;
        NSUInteger capacity = MAX(rows, capacities[screen] - shift + pull);
        TCell *next = calloc(stride * capacity, sizeof(TCell));
        clearCells(next, stride * capacity);
        if (primary) {
            for (NSUInteger r = 0; r < shift; r++)
                [self appendHistory:[NSData dataWithBytes:grids[screen] + r * _stride length:_stride * sizeof(TCell)]];
            for (NSUInteger r = 0; r < pull; r++) {
                NSData *line = _history[_history.count - pull + r];
                memcpy(next + r * stride, line.bytes, MIN(line.length, stride * sizeof(TCell)));
            }
            if (pull) [_history removeObjectsInRange:NSMakeRange(_history.count - pull, pull)];
        }
        for (NSUInteger r = shift; r < capacities[screen]; r++)
            memcpy(next + (r - shift + pull) * stride, grids[screen] + r * _stride, _stride * sizeof(TCell));
        free(grids[screen]);
        grids[screen] = next;
        // Unused bottom rows do not block pulling real history on the next grow.
        while (capacity > rows) {
            BOOL blank = YES;
            for (NSUInteger col = 0; col < stride; col++) {
                TCell cell = next[(capacity - 1) * stride + col];
                if (cell.ch || cell.attrs || cell.bg != TCDefault) { blank = NO; break; }
            }
            if (!blank) break;
            capacity--;
        }
        capacities[screen] = capacity;
        if (primary) {
            if (_alt) _savedR = cursor - shift + pull;
            else {
                _curR = cursor - shift + pull;
                _savedR = _savedR >= shift ? _savedR - shift + pull : pull;
            }
        }
    }
    _grid = grids[0]; _altGrid = grids[1];
    _gridRows = capacities[0]; _altRows = capacities[1];
    _stride = stride;
    _cols = cols;
    _rows = rows;
    _curR = MIN(_curR, rows - 1);
    _curC = MIN(_curC, cols - 1);
    _top = _fullRegion ? 0 : MIN(_regionTop, rows - 1);
    _bot = _fullRegion ? rows - 1 : MAX(_top, MIN(_regionBottom, rows - 1));
    _wrapPending = NO;
    NSMutableData *stops = [NSMutableData dataWithLength:cols];
    if (_stops.length) memcpy(stops.mutableBytes, _stops.bytes, MIN(_stops.length, cols));
    for (NSUInteger i = ((_stops.length + 7) / 8) * 8; i < cols; i += 8)
        if (i) ((uint8_t *)stops.mutableBytes)[i] = 1;
    _stops = stops;
}

- (void)clearScrollback { _historyStart += _history.count; [_history removeAllObjects]; }

- (NSString *)textOfRow:(NSUInteger)r {
    if (r >= _rows) return @"";
    TCell *row = &_grid[r * _stride];
    NSMutableString *s = [NSMutableString string];
    char buf[5];
    for (NSUInteger c = 0; c < _cols; c++) {
        uint32_t ch = row[c].ch;
        if (!ch) { [s appendString:@" "]; continue; }
        if (row[c].attrs & TFCont) continue;
        NSInteger n = ch < 0x80 ? 1 : ch < 0x800 ? 2 : ch < 0x10000 ? 3 : 4;
        if (ch < 0x80) buf[0] = (char)ch;
        else if (ch < 0x800) { buf[0] = 0xC0 | (ch >> 6); buf[1] = 0x80 | (ch & 0x3F); }
        else if (ch < 0x10000) { buf[0] = 0xE0 | (ch >> 12); buf[1] = 0x80 | ((ch >> 6) & 0x3F); buf[2] = 0x80 | (ch & 0x3F); }
        else { buf[0] = 0xF0 | (ch >> 18); buf[1] = 0x80 | ((ch >> 12) & 0x3F); buf[2] = 0x80 | ((ch >> 6) & 0x3F); buf[3] = 0x80 | (ch & 0x3F); }
        NSString *part = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
        [s appendString:part ?: @"?"];
    }
    return s;
}

@end

#import "PieceTable.h"

typedef struct { uint8_t src; NSUInteger start, len; } Piece;   // src 0 = original, 1 = add

@implementation PieceTable {
    NSData *_orig;
    NSMutableData *_add;
    Piece *_pieces;
    NSUInteger _count, _cap;
    uint32_t *_lines;
    NSUInteger _lineCount, _lineCap;
    NSUInteger _cacheIdx, _cacheStart;   // last piece lookup
}

- (instancetype)initWithData:(NSData *)data {
    if (!(self = [super init])) return nil;
    _orig = data ?: [NSData data];
    _add = [NSMutableData data];
    _cap = 16;
    _pieces = calloc(_cap, sizeof(Piece));
    _length = _orig.length;
    if (_length) _pieces[_count++] = (Piece){0, 0, _length};

    const uint8_t *b = _orig.bytes;
    _lineCap = 1024;
    _lines = malloc(_lineCap * sizeof(uint32_t));
    _lines[_lineCount++] = 0;
    const uint8_t *p = b, *end = b ? b + _length : b;            // empty data may have no bytes pointer
    while (p < end && (p = memchr(p, '\n', end - p))) {
        if (p > b && p[-1] == '\r') _usesCRLF = YES;
        p++;
        [self pushLine:(uint32_t)(p - b)];
    }
    return self;
}

- (void)dealloc { free(_pieces); free(_lines); }

- (void)pushLine:(uint32_t)off {
    if (_lineCount == _lineCap) { _lineCap *= 2; _lines = realloc(_lines, _lineCap * sizeof(uint32_t)); }
    _lines[_lineCount++] = off;
}

- (NSUInteger)lineCount { return _lineCount; }
- (NSUInteger)lineStart:(NSUInteger)line { return line < _lineCount ? _lines[line] : _length; }

- (NSUInteger)lineEnd:(NSUInteger)line {
    if (line + 1 >= _lineCount) return _length;
    NSUInteger e = _lines[line + 1] - 1;               // position of '\n'
    if (e > _lines[line] && [self byteAt:e - 1] == '\r') e--;
    return e;
}

- (NSUInteger)lineForOffset:(NSUInteger)off {
    NSUInteger lo = 0, hi = _lineCount - 1;
    while (lo < hi) {
        NSUInteger mid = (lo + hi + 1) / 2;
        if (_lines[mid] <= off) lo = mid; else hi = mid - 1;
    }
    return lo;
}

// Index of the piece containing `off` (or _count if off == length); *start receives its offset.
- (NSUInteger)pieceAt:(NSUInteger)off start:(NSUInteger *)start {
    NSUInteger i = 0, s = 0;
    if (_cacheIdx < _count && _cacheStart <= off) { i = _cacheIdx; s = _cacheStart; }
    while (i < _count && s + _pieces[i].len <= off) { s += _pieces[i].len; i++; }
    if (i < _count) { _cacheIdx = i; _cacheStart = s; }
    *start = s;
    return i;
}

- (const uint8_t *)bytesOf:(Piece)p {
    const uint8_t *base = p.src ? _add.bytes : _orig.bytes;
    return base ? base + p.start : (const uint8_t *)"";        // empty data has no bytes pointer
}

- (uint8_t)byteAt:(NSUInteger)off {
    if (off >= _length) return 0;
    NSUInteger s, i = [self pieceAt:off start:&s];
    return [self bytesOf:_pieces[i]][off - s];
}

- (NSUInteger)read:(NSRange)r into:(uint8_t *)out {
    if (r.location >= _length) return 0;
    NSUInteger want = MIN(r.length, _length - r.location), got = 0, s;
    NSUInteger i = [self pieceAt:r.location start:&s];
    NSUInteger inPiece = r.location - s;
    while (got < want && i < _count) {
        Piece p = _pieces[i];
        NSUInteger n = MIN(p.len - inPiece, want - got);
        memcpy(out + got, [self bytesOf:p] + inPiece, n);
        got += n; inPiece = 0; i++;
    }
    return got;
}

- (NSData *)dataInRange:(NSRange)r {
    if (r.location >= _length) return [NSData data];
    r.length = MIN(r.length, _length - r.location);
    NSMutableData *d = [NSMutableData dataWithLength:r.length];
    [self read:r into:d.mutableBytes];
    return d;
}

- (void)ensurePieceCap:(NSUInteger)extra {
    if (_count + extra <= _cap) return;
    while (_count + extra > _cap) _cap *= 2;
    _pieces = realloc(_pieces, _cap * sizeof(Piece));
}

- (void)insertBytes:(const uint8_t *)bytes length:(NSUInteger)n at:(NSUInteger)off {
    if (!n) return;
    off = MIN(off, _length);
    NSUInteger addStart = _add.length;
    [_add appendBytes:bytes length:n];
    Piece np = {1, addStart, n};

    [self ensurePieceCap:2];
    NSUInteger s, i = [self pieceAt:off start:&s];
    if (i < _count && s == off) {
        // boundary before piece i; try to extend the previous piece
        if (i > 0 && _pieces[i-1].src == 1 && _pieces[i-1].start + _pieces[i-1].len == addStart) {
            _pieces[i-1].len += n;
        } else {
            memmove(&_pieces[i+1], &_pieces[i], (_count - i) * sizeof(Piece));
            _pieces[i] = np; _count++;
        }
    } else if (i == _count) {
        if (_count && _pieces[_count-1].src == 1 && _pieces[_count-1].start + _pieces[_count-1].len == addStart)
            _pieces[_count-1].len += n;
        else
            _pieces[_count++] = np;
    } else {
        Piece p = _pieces[i];
        NSUInteger left = off - s;
        Piece L = {p.src, p.start, left}, R = {p.src, p.start + left, p.len - left};
        memmove(&_pieces[i+3], &_pieces[i+1], (_count - i - 1) * sizeof(Piece));
        _pieces[i] = L; _pieces[i+1] = np; _pieces[i+2] = R; _count += 2;
    }

    // line index
    NSUInteger first = [self lineForOffset:off] + 1;   // first line start strictly after off
    for (NSUInteger k = first; k < _lineCount; k++) _lines[k] += (uint32_t)n;
    const uint8_t *ins = (const uint8_t *)_add.bytes + addStart;
    NSUInteger nl = 0;
    for (NSUInteger k = 0; k < n; k++) if (ins[k] == '\n') nl++;
    if (nl) {
        if (_lineCount + nl > _lineCap) {
            while (_lineCount + nl > _lineCap) _lineCap *= 2;
            _lines = realloc(_lines, _lineCap * sizeof(uint32_t));
        }
        memmove(&_lines[first + nl], &_lines[first], (_lineCount - first) * sizeof(uint32_t));
        NSUInteger w = first;
        for (NSUInteger k = 0; k < n; k++) if (ins[k] == '\n') _lines[w++] = (uint32_t)(off + k + 1);
        _lineCount += nl;
    }
    _length += n;
    _cacheIdx = _cacheStart = 0;
}

- (void)deleteRange:(NSRange)r {
    if (r.location >= _length || !r.length) return;
    r.length = MIN(r.length, _length - r.location);
    NSUInteger a = r.location, b = NSMaxRange(r);

    Piece *out = malloc((_count + 1) * sizeof(Piece));
    NSUInteger oc = 0, s = 0;
    for (NSUInteger i = 0; i < _count; i++) {
        Piece p = _pieces[i];
        NSUInteger ps = s, pe = s + p.len;
        s = pe;
        if (pe <= a || ps >= b) { out[oc++] = p; continue; }
        if (ps < a) out[oc++] = (Piece){p.src, p.start, a - ps};
        if (pe > b) out[oc++] = (Piece){p.src, p.start + (b - ps), pe - b};
    }
    free(_pieces);
    _pieces = out; _count = oc; _cap = MAX(oc + 1, (NSUInteger)16);
    _pieces = realloc(_pieces, _cap * sizeof(Piece));

    // drop line starts in (a, b], shift the rest
    NSUInteger first = [self lineForOffset:a] + 1, last = first;
    while (last < _lineCount && _lines[last] <= b) last++;
    NSUInteger removed = last - first;
    for (NSUInteger k = last; k < _lineCount; k++) _lines[k] -= (uint32_t)r.length;
    memmove(&_lines[first], &_lines[last], (_lineCount - last) * sizeof(uint32_t));
    _lineCount -= removed;
    _length -= r.length;
    _cacheIdx = _cacheStart = 0;
}

@end

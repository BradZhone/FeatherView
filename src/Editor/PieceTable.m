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
    NSUInteger *_starts;                 // offset of each piece, rebuilt lazily (_startsValid)
    NSUInteger _startsCap;
    BOOL _startsValid;
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

- (void)dealloc { free(_pieces); free(_lines); free(_starts); }

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
// Sequential reads walk on from the last lookup; anything else is a binary search, since many cursors
// leave many pieces.
- (NSUInteger)pieceAt:(NSUInteger)off start:(NSUInteger *)start {
    if (_cacheIdx < _count && _cacheStart <= off) {
        NSUInteger i = _cacheIdx, s = _cacheStart;
        for (int k = 0; k < 4 && i < _count; k++) {
            if (off < s + _pieces[i].len) { _cacheIdx = i; _cacheStart = s; *start = s; return i; }
            s += _pieces[i].len; i++;
        }
        if (i == _count) { *start = s; return i; }
    }
    if (off >= _length) { *start = _length; return _count; }
    if (!_startsValid) {
        if (_startsCap < _count) { _startsCap = MAX(_count, _startsCap * 2); _starts = realloc(_starts, _startsCap * sizeof(NSUInteger)); }
        NSUInteger acc = 0;
        for (NSUInteger i = 0; i < _count; i++) { _starts[i] = acc; acc += _pieces[i].len; }
        _startsValid = YES;
    }
    NSUInteger lo = 0, hi = _count - 1;
    while (lo < hi) {
        NSUInteger mid = (lo + hi + 1) / 2;
        if (_starts[mid] <= off) lo = mid; else hi = mid - 1;
    }
    _cacheIdx = lo; _cacheStart = _starts[lo];
    *start = _starts[lo];
    return lo;
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
    _startsValid = NO;
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
    _startsValid = NO;
}

static inline void putPiece(Piece *out, NSUInteger *n, Piece p) {
    if (!p.len) return;
    Piece *last = *n ? &out[*n - 1] : NULL;
    if (last && last->src == p.src && last->start + last->len == p.start) last->len += p.len;
    else out[(*n)++] = p;
}

- (void)applyEdits:(const PTEdit *)edits count:(NSUInteger)count {
    if (!count) return;
    if (count == 1) {
        PTEdit e = edits[0];
        if (e.removed) [self deleteRange:NSMakeRange(e.location, e.removed)];
        if (e.inserted) [self insertBytes:e.bytes length:e.inserted at:e.location];
        return;
    }
    // pieces: copy the kept stretches, drop the removed ones, add one piece per insertion
    NSUInteger addBase = _add.length, nlIns = 0;
    for (NSUInteger k = 0; k < count; k++) {
        for (NSUInteger j = 0; j < edits[k].inserted; j++) if (edits[k].bytes[j] == '\n') nlIns++;
    }
    for (NSUInteger k = 0; k < count; k++) if (edits[k].inserted) [_add appendBytes:edits[k].bytes length:edits[k].inserted];
    Piece *out = malloc((_count + 2 * count + 1) * sizeof(Piece));
    NSUInteger oc = 0, pi = 0, ps = 0, pos = 0, addAt = addBase;
    for (NSUInteger k = 0; k <= count; k++) {
        NSUInteger to = k < count ? MIN(edits[k].location, _length) : _length;
        while (pos < to && pi < _count) {
            Piece p = _pieces[pi];
            NSUInteger pe = ps + p.len;
            if (pe <= pos) { ps = pe; pi++; continue; }
            NSUInteger a = MAX(pos, ps), b = MIN(to, pe);
            putPiece(out, &oc, (Piece){p.src, p.start + (a - ps), b - a});
            pos = b;
            if (b == pe) { ps = pe; pi++; }
        }
        if (k == count) break;
        if (edits[k].inserted) { putPiece(out, &oc, (Piece){1, addAt, edits[k].inserted}); addAt += edits[k].inserted; }
        pos = MIN(MAX(pos, edits[k].location + edits[k].removed), _length);
    }
    free(_pieces);
    _pieces = out; _count = oc; _cap = _count + 2 * count + 1;

    // line starts: kept ones shift by the edits before them, removed ones drop, inserted ones are added
    NSUInteger cap = _lineCount + nlIns;
    uint32_t *lines = malloc(MAX(cap, (NSUInteger)1024) * sizeof(uint32_t));
    NSUInteger w = 0, li = 0;
    NSInteger delta = 0;
    lines[w++] = 0;
    li = 1;
    for (NSUInteger k = 0; k <= count; k++) {
        NSUInteger loc = k < count ? edits[k].location : NSUIntegerMax;
        while (li < _lineCount && _lines[li] <= loc) lines[w++] = (uint32_t)((NSInteger)_lines[li++] + delta);
        if (k == count) break;
        NSUInteger end = loc + edits[k].removed;
        while (li < _lineCount && _lines[li] <= end) li++;
        NSUInteger at = (NSUInteger)((NSInteger)loc + delta);
        for (NSUInteger j = 0; j < edits[k].inserted; j++) if (edits[k].bytes[j] == '\n') lines[w++] = (uint32_t)(at + j + 1);
        delta += (NSInteger)edits[k].inserted - (NSInteger)edits[k].removed;
    }
    free(_lines);
    _lines = lines; _lineCount = w; _lineCap = MAX(cap, (NSUInteger)1024);
    _length = (NSUInteger)((NSInteger)_length + delta);
    _cacheIdx = _cacheStart = 0;
    _startsValid = NO;
}

@end

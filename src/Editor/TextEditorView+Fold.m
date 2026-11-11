#import "TextEditorView+Private.h"

// Code folding. Regions come from indentation (a line followed by more-indented lines), or from headings in
// Markdown. A folded region's lines get no rows in the row table, so everything that maps rows to lines
// (drawing, hit testing, moving up and down) skips them. Folds follow edits made elsewhere and are dropped
// by edits that reach into the hidden lines; a caret that ends up in hidden lines unfolds them.

typedef struct { NSUInteger headerEnd, hiddenEnd; } FoldOffsets;

@implementation TextEditorView (Fold)

#pragma mark Lookup

- (NSRange)hiddenRangeAt:(NSUInteger)L {
    const NSRange *h = _hidden.bytes;
    NSUInteger n = _hidden.length / sizeof(NSRange), lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (NSMaxRange(h[mid]) <= L) lo = mid + 1; else hi = mid; }
    return lo < n && h[lo].location <= L ? h[lo] : NSMakeRange(NSNotFound, 0);
}

- (BOOL)lineHidden:(NSUInteger)L { return _hidden.length && [self hiddenRangeAt:L].location != NSNotFound; }

- (NSUInteger)foldIndexOf:(NSUInteger)header {
    const Fold *f = _folds.bytes;
    NSUInteger n = _folds.length / sizeof(Fold), lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (f[mid].header < header) lo = mid + 1; else hi = mid; }
    return lo < n && f[lo].header == header ? lo : NSNotFound;
}

- (BOOL)lineFolded:(NSUInteger)L { return _folds.length && [self foldIndexOf:L] != NSNotFound; }

- (void)rebuildHidden {
    if (!_folds.length) { _folds = nil; _hidden = nil; return; }
    NSMutableData *h = [NSMutableData data];
    const Fold *f = _folds.bytes;
    for (NSUInteger i = 0; i < _folds.length / sizeof(Fold); i++) {
        NSRange r = NSMakeRange(f[i].header + 1, f[i].last - f[i].header);
        NSRange *last = h.length ? (NSRange *)h.mutableBytes + h.length / sizeof(NSRange) - 1 : NULL;
        if (last && r.location <= NSMaxRange(*last)) { NSUInteger e = MAX(NSMaxRange(*last), NSMaxRange(r)); last->length = e - last->location; }
        else [h appendBytes:&r length:sizeof r];
    }
    _hidden = h;
}

#pragma mark Regions

- (NSUInteger)indentColumns:(NSUInteger)L blank:(BOOL *)blank {
    NSUInteger i = [_buf lineStart:L], e = [_buf lineEnd:L], col = 0;
    for (; i < e; i++) {
        uint8_t b = [_buf byteAt:i];
        if (b == ' ') col++;
        else if (b == '\t') col = (col / 4 + 1) * 4;
        else break;
    }
    if (blank) *blank = i == e;
    return col;
}

- (BOOL)markdownFolds { return [_hl.modeName isEqualToString:@"markdown"]; }

- (NSUInteger)headingLevel:(NSUInteger)L {
    NSUInteger s = [_buf lineStart:L], e = [_buf lineEnd:L], n = 0;
    while (s + n < e && n < 7 && [_buf byteAt:s + n] == '#') n++;
    if (n == 0 || n > 6) return 0;
    if (s + n < e && [_buf byteAt:s + n] != ' ' && [_buf byteAt:s + n] != '\t') return 0;
    return n;
}

- (BOOL)isFence:(NSUInteger)L {
    NSUInteger i = [self firstNonBlankOf:L], e = [_buf lineEnd:L];
    if (i + 3 > e) return NO;
    uint8_t c = [_buf byteAt:i];
    return (c == '`' || c == '~') && [_buf byteAt:i + 1] == c && [_buf byteAt:i + 2] == c;
}

- (NSUInteger)lastNonBlankFrom:(NSUInteger)L down:(NSUInteger)stop {
    while (L > stop && [self firstNonBlankOf:L] == [_buf lineEnd:L]) L--;
    return L;
}

- (NSUInteger)foldEndOf:(NSUInteger)L {
    NSUInteger n = _buf.lineCount;
    if (L >= n) return NSNotFound;
    NSUInteger end = L;
    if (self.markdownFolds) {
        NSUInteger h = [self headingLevel:L];
        if (!h) return NSNotFound;
        BOOL fence = NO;
        NSUInteger j = L + 1;
        for (; j < n; j++) {
            if ([self isFence:j]) { fence = !fence; continue; }
            NSUInteger k = fence ? 0 : [self headingLevel:j];
            if (k && k <= h) break;
        }
        end = [self lastNonBlankFrom:j - 1 down:L];
    } else {
        BOOL blank;
        NSUInteger ind = [self indentColumns:L blank:&blank];
        if (blank) return NSNotFound;
        for (NSUInteger j = L + 1; j < n; j++) {
            NSUInteger i = [self indentColumns:j blank:&blank];
            if (blank) continue;
            if (i <= ind) break;
            end = j;
        }
    }
    return end > L ? end : NSNotFound;
}

// The gutter asks this for every visible line, so it only looks at the next non-blank line.
- (BOOL)startsRegion:(NSUInteger)L {
    NSUInteger n = _buf.lineCount;
    if (self.markdownFolds) {
        NSUInteger h = [self headingLevel:L];
        if (!h) return NO;
        for (NSUInteger j = L + 1; j < n && j < L + 200; j++) {
            if ([self firstNonBlankOf:j] == [_buf lineEnd:j]) continue;
            NSUInteger k = [self headingLevel:j];
            return !k || k > h;
        }
        return NO;
    }
    BOOL blank;
    NSUInteger ind = [self indentColumns:L blank:&blank];
    if (blank) return NO;
    for (NSUInteger j = L + 1; j < n && j < L + 200; j++) {
        NSUInteger i = [self indentColumns:j blank:&blank];
        if (!blank) return i > ind;
    }
    return NO;
}

// Every region of the file, in one pass.
- (NSMutableData *)allRegions {
    NSMutableData *out = [NSMutableData data], *stack = [NSMutableData data];      // stack: {line, key}
    NSUInteger n = _buf.lineCount, lastNonBlank = 0;
    BOOL md = self.markdownFolds, fence = NO;
    void (^close)(NSUInteger, NSUInteger) = ^(NSUInteger key, NSUInteger upto) {
        while (stack.length) {
            NSUInteger *top = (NSUInteger *)stack.mutableBytes + stack.length / sizeof(NSUInteger) - 2;
            if (top[1] < key) break;
            if (upto > top[0]) { Fold f = {top[0], upto}; [out appendBytes:&f length:sizeof f]; }
            stack.length -= 2 * sizeof(NSUInteger);
        }
    };
    for (NSUInteger L = 0; L < n; L++) {
        BOOL blank;
        NSUInteger ind = [self indentColumns:L blank:&blank];
        if (blank) continue;
        if (md) {
            if ([self isFence:L]) { fence = !fence; lastNonBlank = L; continue; }
            NSUInteger h = fence ? 0 : [self headingLevel:L];
            if (h) {
                close(h, lastNonBlank);
                NSUInteger e[2] = {L, h};
                [stack appendBytes:e length:sizeof e];
            }
        } else {
            close(ind, lastNonBlank);
            NSUInteger e[2] = {L, ind};
            [stack appendBytes:e length:sizeof e];
        }
        lastNonBlank = L;
    }
    close(0, lastNonBlank);
    return out;
}

#pragma mark Changing folds

static int byHeader(const void *a, const void *b) {
    NSUInteger x = ((const Fold *)a)->header, y = ((const Fold *)b)->header;
    return x < y ? -1 : x > y;
}

// Carets in lines that are now hidden go to the end of the fold's first line.
- (void)moveCursorsOutOfFolds {
    if (!_hidden.length) return;
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    Sel *c = cur.mutableBytes;
    BOOL moved = NO;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        NSUInteger L = [_buf lineForOffset:c[i].caret];
        NSRange h = [self hiddenRangeAt:L];
        if (h.location == NSNotFound) continue;
        NSUInteger at = [_buf lineEnd:h.location - 1];
        c[i] = SelMake(at, at);
        moved = YES;
    }
    if (moved) [self setCursors:c count:cur.length / sizeof(Sel) primary:primary];
}

- (void)setFolds:(NSMutableData *)folds {
    if (folds.length) qsort(folds.mutableBytes, folds.length / sizeof(Fold), sizeof(Fold), byHeader);
    [self changeLayout:^{
        self->_folds = folds.length ? folds : nil;
        [self rebuildHidden];
        [self moveCursorsOutOfFolds];
    }];
    _coalesceBroken = YES;
    [self notifyChange];
}

- (void)addFold:(Fold)f to:(NSMutableData *)folds {
    const Fold *x = folds.bytes;
    for (NSUInteger i = 0; i < folds.length / sizeof(Fold); i++) if (x[i].header == f.header) return;
    [folds appendBytes:&f length:sizeof f];
}

- (NSUInteger)enclosingRegionOf:(NSUInteger)L {
    if ([self startsRegion:L] && ![self lineFolded:L] && [self foldEndOf:L] != NSNotFound) return L;
    BOOL blank;
    NSUInteger ind = [self indentColumns:L blank:&blank];
    if (self.markdownFolds) {
        for (NSUInteger j = L; j-- > 0;) {
            NSUInteger h = [self headingLevel:j];
            if (!h || [self lineFolded:j]) continue;
            NSUInteger e = [self foldEndOf:j];
            if (e != NSNotFound && e >= L) return j;
        }
        return NSNotFound;
    }
    if (blank) for (NSUInteger j = L + 1; j < _buf.lineCount; j++) { NSUInteger i = [self indentColumns:j blank:&blank]; if (!blank) { ind = i; break; } }
    for (NSUInteger j = L; j-- > 0;) {
        NSUInteger i = [self indentColumns:j blank:&blank];
        if (blank || i >= ind) continue;
        if (![self lineFolded:j]) { NSUInteger e = [self foldEndOf:j]; if (e != NSNotFound && e >= L) return j; }
        ind = i;
        if (!i) break;
    }
    return NSNotFound;
}

- (NSIndexSet *)caretLines {
    NSUInteger p = 0;
    NSData *cur = [self cursors:&p];
    const Sel *c = cur.bytes;
    NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) [lines addIndex:[_buf lineForOffset:c[i].caret]];
    return lines;
}

- (void)fold:(id)sender {
    NSMutableData *folds = [_folds mutableCopy] ?: [NSMutableData data];
    __block BOOL any = NO;
    [self.caretLines enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        NSUInteger h = [self enclosingRegionOf:L];
        if (h == NSNotFound) return;
        [self addFold:(Fold){h, [self foldEndOf:h]} to:folds];
        any = YES;
    }];
    if (!any) { NSBeep(); return; }
    [self setFolds:folds];
}

- (void)unfold:(id)sender {
    NSMutableData *folds = [_folds mutableCopy];
    __block BOOL any = NO;
    [self.caretLines enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        NSUInteger i = [self foldIndexOf:L];
        if (!folds.length || i == NSNotFound) return;
        [folds replaceBytesInRange:NSMakeRange(i * sizeof(Fold), sizeof(Fold)) withBytes:NULL length:0];
        self->_folds = folds;                               // foldIndexOf: looks at the current list
        any = YES;
    }];
    if (!any) { NSBeep(); return; }
    [self setFolds:folds];
}

- (void)foldAll:(id)sender {
    NSMutableData *r = [self allRegions];
    if (!r.length) { NSBeep(); return; }
    [self setFolds:r];
}

- (void)unfoldAll:(id)sender {
    if (!_folds.length) return;
    [self setFolds:nil];
}

- (void)toggleFoldAtLine:(NSUInteger)L {
    NSMutableData *folds = [_folds mutableCopy] ?: [NSMutableData data];
    NSUInteger i = [self foldIndexOf:L];
    if (_folds.length && i != NSNotFound) {
        [folds replaceBytesInRange:NSMakeRange(i * sizeof(Fold), sizeof(Fold)) withBytes:NULL length:0];
    } else {
        NSUInteger e = [self foldEndOf:L];
        if (e == NSNotFound) return;
        [self addFold:(Fold){L, e} to:folds];
    }
    [self setFolds:folds];
}

- (void)clearFolds { _folds = nil; _hidden = nil; _pendingFolds = nil; }

- (void)revealCursors {
    if (!_hidden.length) return;
    NSIndexSet *lines = self.caretLines;
    NSMutableData *folds = [_folds mutableCopy];
    const Fold *f = folds.bytes;
    NSUInteger n = folds.length / sizeof(Fold), w = 0;
    Fold *out = folds.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        Fold x = f[i];
        if ([lines countOfIndexesInRange:NSMakeRange(x.header + 1, x.last - x.header)]) continue;
        out[w++] = x;
    }
    if (w == n) return;
    folds.length = w * sizeof(Fold);
    [self changeLayout:^{ self->_folds = folds.length ? folds : nil; [self rebuildHidden]; }];
}

#pragma mark Edits

// Before the buffer changes: each fold as the offsets of its first line's end and of its last line's end,
// moved by the edits before them. Anything up to the first line's end may change (that line is wherever
// its end goes); an edit reaching into the hidden lines, or a line break added right at that end, drops it.
- (void)prepareFoldsForEdits:(const PTEdit *)e count:(NSUInteger)n {
    _pendingFolds = nil;
    _foldsDropped = NO;
    if (!_folds.length) return;
    NSMutableData *out = [NSMutableData data];
    const Fold *f = _folds.bytes;
    NSUInteger lines = _buf.lineCount;
    for (NSUInteger i = 0; i < _folds.length / sizeof(Fold); i++) {
        NSUInteger he = [_buf lineEnd:f[i].header], be = [_buf lineEnd:f[i].last];
        NSUInteger after = f[i].last + 1 < lines ? [_buf lineStart:f[i].last + 1] : NSNotFound;
        NSInteger shift = 0;
        BOOL keep = YES;
        for (NSUInteger k = 0; k < n && keep; k++) {
            NSUInteger a = e[k].location, b = a + e[k].removed;
            BOOL nl = e[k].inserted && memchr(e[k].bytes, '\n', e[k].inserted);
            if (b < he || (b == he && (a < he || !nl))) shift += (NSInteger)e[k].inserted - (NSInteger)e[k].removed;
            else if (after != NSNotFound && a >= after) break;
            else keep = NO;
        }
        if (!keep) { _foldsDropped = YES; continue; }
        FoldOffsets o = {(NSUInteger)((NSInteger)he + shift), (NSUInteger)((NSInteger)be + shift)};
        [out appendBytes:&o length:sizeof o];
    }
    _pendingFolds = out;
}

- (void)applyPendingFolds {
    if (!_pendingFolds) return;
    NSMutableData *folds = [NSMutableData data];
    const FoldOffsets *o = _pendingFolds.bytes;
    for (NSUInteger i = 0; i < _pendingFolds.length / sizeof(FoldOffsets); i++) {
        NSUInteger h = [_buf lineForOffset:o[i].headerEnd], l = [_buf lineForOffset:o[i].hiddenEnd];
        if (l > h) { Fold f = {h, l}; [folds appendBytes:&f length:sizeof f]; }
        else _foldsDropped = YES;
    }
    _pendingFolds = nil;
    _folds = folds.length ? folds : nil;
    [self rebuildHidden];
}

#pragma mark Geometry

- (NSRect)foldBoxOfLine:(NSUInteger)L {
    CGFloat x = 0;
    NSUInteger row = [self rowOfOffset:[_buf lineEnd:L] x:&x];
    return NSMakeRect(self.textOriginX + x + 6, 4 + row * _lineHeight - self.scrollY + 2, ceil(2.6 * _charWidth), _lineHeight - 4);
}

@end

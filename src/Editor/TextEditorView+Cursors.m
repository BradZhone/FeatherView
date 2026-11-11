#import "TextEditorView+Private.h"
#import "Localization.h"

// Multiple cursors. The primary cursor is _anchor/_caret/_desiredX, so everything that only knows one
// cursor (input methods, VoiceOver, find, the status bar) keeps working; the others live in _extra.

static NSPasteboardType const kPiecesType = @"local.feather.editor.pieces";   // {pieces: [..], lines: bool}

static inline BOOL wordByte(uint8_t c) {
    return c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'z');
}

typedef struct { Sel s; NSUInteger order; } Keyed;
static int byStart(const void *x, const void *y) {
    const Keyed *a = x, *b = y;
    NSUInteger sa = SelStart(a->s), sb = SelStart(b->s);
    if (sa != sb) return sa < sb ? -1 : 1;
    NSUInteger ea = SelEnd(a->s), eb = SelEnd(b->s);
    if (ea != eb) return ea < eb ? -1 : 1;
    return a->order < b->order ? -1 : a->order > b->order;
}

@implementation TextEditorView (Cursors)

- (NSUInteger)cursorCount { return 1 + _extra.length / sizeof(Sel); }

- (NSMutableData *)cursors:(NSUInteger *)primary {
    NSUInteger n = _extra.length / sizeof(Sel);
    NSMutableData *out = [NSMutableData dataWithLength:(n + 1) * sizeof(Sel)];
    Sel *o = out.mutableBytes;
    const Sel *x = _extra.bytes;
    Sel p = {_anchor, _caret, _desiredX};
    NSUInteger at = 0;                       // the primary goes before the first cursor that starts after it
    while (at < n && (SelStart(x[at]) < SelStart(p) || (SelStart(x[at]) == SelStart(p) && SelEnd(x[at]) <= SelEnd(p)))) at++;
    if (at) memcpy(o, x, at * sizeof(Sel));
    o[at] = p;
    if (n > at) memcpy(o + at + 1, x + at, (n - at) * sizeof(Sel));
    if (primary) *primary = at;
    return out;
}

- (NSUInteger)charStart:(NSUInteger)off {
    off = MIN(off, _buf.length);
    while (off > 0 && off < _buf.length && ([_buf byteAt:off] & 0xC0) == 0x80) off--;
    return off;
}

- (void)setCursors:(const Sel *)in count:(NSUInteger)n primary:(NSUInteger)primary {
    if (!n) { Sel z = SelMake(0, 0); [self setCursors:&z count:1 primary:0]; return; }
    Keyed *k = malloc(n * sizeof(Keyed));
    for (NSUInteger i = 0; i < n; i++) {
        Sel s = in[i];
        s.anchor = [self charStart:s.anchor];
        s.caret = [self charStart:s.caret];
        k[i] = (Keyed){s, i};
    }
    qsort(k, n, sizeof(Keyed), byStart);
    // merge overlapping selections; an empty one touching another joins it
    NSUInteger w = 0, newPrimary = 0;
    for (NSUInteger i = 0; i < n; i++) {
        BOOL isPrimary = k[i].order == primary;
        if (w) {
            Sel *last = &k[w - 1].s;
            NSUInteger ls = SelStart(*last), le = SelEnd(*last), s = SelStart(k[i].s), e = SelEnd(k[i].s);
            BOOL touch = s == le && (ls == le || s == e);
            if (s < le || touch) {
                BOOL lastPrimary = k[w - 1].order == primary;
                Sel dir = isPrimary ? k[i].s : *last;            // the primary's direction wins
                NSUInteger a = ls, b = MAX(le, e);
                BOOL back = (isPrimary || lastPrimary) && dir.caret < dir.anchor;
                if (b == a) *last = (Sel){a, a, isPrimary ? k[i].s.x : last->x};
                else *last = back ? (Sel){b, a, -1} : (Sel){a, b, -1};
                if (isPrimary) { newPrimary = w - 1; k[w - 1].order = primary; }
                continue;
            }
        }
        if (isPrimary) newPrimary = w;
        k[w++] = k[i];
    }
    if (w > kMaxCursors) {                    // keep the primary, drop from the end
        Keyed p = k[newPrimary];
        w = kMaxCursors;
        if (newPrimary >= w) { k[w - 1] = p; newPrimary = w - 1; }
    }
    Sel p = k[newPrimary].s;
    _anchor = p.anchor; _caret = p.caret; _desiredX = p.x;
    if (w == 1) { _extra = nil; free(k); return; }
    if (!_extra) _extra = [NSMutableData data];
    _extra.length = (w - 1) * sizeof(Sel);
    Sel *x = _extra.mutableBytes;
    for (NSUInteger i = 0, j = 0; i < w; i++) if (i != newPrimary) x[j++] = k[i].s;
    free(k);
}

- (void)dropExtraCursors { _extra = nil; }

- (void)cursorsChanged {
    [self scrollCaretVisible];
    [self notifyChange];
}

- (void)moveCursors:(CaretMove)f extend:(BOOL)extend keepColumn:(BOOL)keepColumn {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    Sel *c = cur.mutableBytes;
    NSUInteger n = cur.length / sizeof(Sel);
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger to = MIN(f(&c[i]), _buf.length);
        c[i].caret = to;
        if (!extend) c[i].anchor = to;
        if (!keepColumn) c[i].x = -1;
    }
    [self setCursors:c count:n primary:primary];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self cursorsChanged];
}

#pragma mark Cursor history (⌘U)

- (NSData *)cursorSnapshot {
    NSUInteger p = 0;
    NSData *c = [self cursors:&p];
    NSMutableData *d = [NSMutableData dataWithBytes:&p length:sizeof p];
    [d appendData:c];
    return d;
}

- (void)restoreCursorSnapshot:(NSData *)d {
    NSUInteger p;
    memcpy(&p, d.bytes, sizeof p);
    [self setCursors:(const Sel *)((const uint8_t *)d.bytes + sizeof p) count:(d.length - sizeof p) / sizeof(Sel) primary:p];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self cursorsChanged];
}

- (void)rememberCursors {
    if (!_cursorHistory) _cursorHistory = [NSMutableArray array];
    [_cursorHistory addObject:self.cursorSnapshot];
    if (_cursorHistory.count > 50) [_cursorHistory removeObjectAtIndex:0];
}

- (void)undoCursor:(id)sender {
    NSData *d = _cursorHistory.lastObject;
    if (!d) { NSBeep(); return; }
    [_cursorHistory removeLastObject];
    [self restoreCursorSnapshot:d];
}

#pragma mark Adding cursors

// Index of a cursor whose selection overlaps r (or is a caret inside or at its edges), else NSNotFound.
static NSUInteger cursorOverlapping(const Sel *c, NSUInteger n, NSRange r) {
    NSUInteger lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (SelEnd(c[mid]) < r.location) lo = mid + 1; else hi = mid; }
    for (NSUInteger i = lo; i < n && SelStart(c[i]) <= NSMaxRange(r); i++) {
        NSUInteger s = SelStart(c[i]), e = SelEnd(c[i]);
        if (s < NSMaxRange(r) && e > r.location) return i;
        if (s == e && s >= r.location && s <= NSMaxRange(r)) return i;
        if (!r.length && r.location >= s && r.location <= e) return i;
    }
    return NSNotFound;
}

- (void)addCursorAt:(NSUInteger)off {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSUInteger n = cur.length / sizeof(Sel);
    Sel *c = cur.mutableBytes;
    NSUInteger hit = cursorOverlapping(c, n, NSMakeRange(off, 0));
    [self rememberCursors];
    if (hit != NSNotFound && n > 1) {                      // ⌥ click on a cursor removes it
        memmove(&c[hit], &c[hit + 1], (n - hit - 1) * sizeof(Sel));
        n--;
        if (primary == hit) primary = n - 1; else if (primary > hit) primary--;
        _ignoreDrag = YES;
    } else if (hit == NSNotFound) {
        [cur appendBytes:&(Sel){off, off, -1} length:sizeof(Sel)];
        c = cur.mutableBytes;
        primary = n++;
    }
    [self setCursors:c count:n primary:primary];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self cursorsChanged];
}

- (void)addCursorVertically:(NSInteger)dir {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSUInteger n = cur.length / sizeof(Sel);
    NSMutableData *out = [cur mutableCopy];
    const Sel *c = cur.bytes;
    NSUInteger newPrimary = primary, rows = self.rowCount;
    for (NSUInteger i = 0; i < n && out.length / sizeof(Sel) < kMaxCursors; i++) {
        CGFloat x = 0;
        NSUInteger row = [self rowOfOffset:c[i].caret x:&x];
        if (c[i].x >= 0) x = c[i].x;
        if ((dir < 0 && row == 0) || (dir > 0 && row + 1 >= rows)) continue;
        NSUInteger off = [self offsetInRow:dir < 0 ? row - 1 : row + 1 x:x];
        Sel s = {off, off, x};
        if (i == primary) newPrimary = out.length / sizeof(Sel);
        [out appendBytes:&s length:sizeof s];
    }
    if (out.length == cur.length) { NSBeep(); return; }
    [self rememberCursors];
    [self setCursors:out.bytes count:out.length / sizeof(Sel) primary:newPrimary];
    _coalesceBroken = YES;
    [self cursorsChanged];
}

- (void)addCursorAbove:(id)sender { [self addCursorVertically:-1]; }
- (void)addCursorBelow:(id)sender { [self addCursorVertically:1]; }

- (void)addCursorsToLineEnds:(id)sender {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    const Sel *c = cur.bytes;
    NSUInteger n = cur.length / sizeof(Sel);
    NSMutableData *out = [NSMutableData data];
    NSUInteger newPrimary = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger s = SelStart(c[i]), e = SelEnd(c[i]);
        if (s == e) { if (i == primary) newPrimary = out.length / sizeof(Sel); [out appendBytes:&c[i] length:sizeof(Sel)]; continue; }
        NSUInteger L0 = [_buf lineForOffset:s], L1 = [_buf lineForOffset:e];
        for (NSUInteger L = L0; L <= L1 && out.length / sizeof(Sel) < kMaxCursors; L++) {
            if (L == L1 && L > L0 && e == [_buf lineStart:L]) break;      // ends at the start of a line
            NSUInteger at = L == L1 ? e : [_buf lineEnd:L];
            if (i == primary) newPrimary = out.length / sizeof(Sel);
            [out appendBytes:&(Sel){at, at, -1} length:sizeof(Sel)];
        }
    }
    [self rememberCursors];
    [self setCursors:out.bytes count:out.length / sizeof(Sel) primary:newPrimary];
    _coalesceBroken = YES;
    [self cursorsChanged];
}

#pragma mark Occurrences (⌘D, ⇧⌘D, ⇧⌘L)

- (BOOL)isWholeWord:(NSRange)r {
    if (r.location > 0 && wordByte([_buf byteAt:r.location - 1])) return NO;
    if (NSMaxRange(r) < _buf.length && wordByte([_buf byteAt:NSMaxRange(r)])) return NO;
    return YES;
}

- (NSRange)wordAroundCaret:(NSUInteger)off {
    BOOL after = off < _buf.length && wordByte([_buf byteAt:off]), before = off > 0 && wordByte([_buf byteAt:off - 1]);
    if (!after && !before) return NSMakeRange(off, 0);
    NSRange w = [self wordRangeAt:after ? off : off - 1];
    return w.length && wordByte([_buf byteAt:w.location]) ? w : NSMakeRange(off, 0);
}

// Every empty cursor becomes the word around it (the first ⌘D).
- (BOOL)selectWordsAtCarets {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    Sel *c = cur.mutableBytes;
    NSUInteger n = cur.length / sizeof(Sel);
    BOOL any = NO;
    for (NSUInteger i = 0; i < n; i++) {
        if (c[i].anchor != c[i].caret) continue;
        NSRange w = [self wordAroundCaret:c[i].caret];
        if (!w.length) continue;
        c[i] = SelMake(w.location, NSMaxRange(w));
        any = YES;
    }
    if (!any) return NO;
    [self rememberCursors];
    [self setCursors:c count:n primary:primary];
    return YES;
}

- (NSData *)occurrenceNeedle {
    NSRange r = self.selection;
    if (!r.length || r.length > (1u << 20)) return nil;
    return [_buf dataInRange:r];
}

// A ⌘D series stays in whole-word mode while the cursors are what it left them as.
- (BOOL)occurrenceSeriesContinues {
    NSUInteger p = 0;
    return _occurrenceSels && [_occurrenceSels isEqualToData:[self cursors:&p]];
}

- (void)endOccurrenceStep {
    NSUInteger p = 0;
    _occurrenceSels = [self cursors:&p];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self cursorsChanged];
}

// Next match at or after `from` that no cursor holds yet, wrapping around once; NSNotFound if none.
- (NSUInteger)nextOccurrence:(NSData *)needle after:(NSUInteger)from whole:(BOOL)whole cursors:(const Sel *)c count:(NSUInteger)n {
    NSUInteger at = MIN(from, _buf.length);
    BOOL wrapped = NO;
    for (NSUInteger tries = 0; tries < 100000; tries++) {
        NSUInteger hit = [_buf findExact:needle from:at];
        if (hit == NSNotFound) return NSNotFound;
        if (hit < at) { if (wrapped) return NSNotFound; wrapped = YES; }
        if (wrapped && hit >= from) return NSNotFound;
        NSRange r = NSMakeRange(hit, needle.length);
        if (cursorOverlapping(c, n, r) == NSNotFound && (!whole || [self isWholeWord:r])) return hit;
        at = hit + 1;
    }
    return NSNotFound;
}

- (void)addNextOccurrence:(id)sender {
    if (!self.selection.length) {
        _occurrenceWhole = YES;
        if ([self selectWordsAtCarets]) [self endOccurrenceStep]; else NSBeep();
        return;
    }
    if (![self occurrenceSeriesContinues]) _occurrenceWhole = NO;
    NSData *needle = [self occurrenceNeedle];
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSUInteger n = cur.length / sizeof(Sel);
    if (n >= kMaxCursors) { NSBeep(); return; }
    NSUInteger hit = [self nextOccurrence:needle after:SelEnd(((Sel *)cur.mutableBytes)[primary]) whole:_occurrenceWhole cursors:cur.bytes count:n];
    if (hit == NSNotFound) { NSBeep(); return; }
    [self rememberCursors];
    [cur appendBytes:&(Sel){hit, hit + needle.length, -1} length:sizeof(Sel)];
    [self setCursors:cur.bytes count:n + 1 primary:n];
    [self endOccurrenceStep];
}

- (void)skipToNextOccurrence:(id)sender {
    if (!self.selection.length) { [self addNextOccurrence:sender]; return; }
    if (![self occurrenceSeriesContinues]) _occurrenceWhole = NO;
    NSData *needle = [self occurrenceNeedle];
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSUInteger n = cur.length / sizeof(Sel);
    Sel *c = cur.mutableBytes;
    NSUInteger hit = [self nextOccurrence:needle after:SelEnd(c[primary]) whole:_occurrenceWhole cursors:c count:n];
    if (hit == NSNotFound) { NSBeep(); return; }
    [self rememberCursors];
    c[primary] = SelMake(hit, hit + needle.length);
    [self setCursors:c count:n primary:primary];
    [self endOccurrenceStep];
}

- (void)selectAllOccurrences:(id)sender {
    BOOL whole = NO;
    if (!self.selection.length) {
        NSRange w = [self wordAroundCaret:_caret];
        if (!w.length) { NSBeep(); return; }
        [self dropExtraCursors];
        _anchor = w.location; _caret = NSMaxRange(w);
        whole = YES;
    } else if ([self occurrenceSeriesContinues]) whole = _occurrenceWhole;
    NSData *needle = [self occurrenceNeedle];
    NSUInteger keep = self.selection.location;
    NSData *starts = [_buf allExact:needle limit:NSUIntegerMax];
    const NSUInteger *h = starts.bytes;
    NSMutableData *out = [NSMutableData data];
    NSUInteger primary = 0;
    for (NSUInteger i = 0; i < starts.length / sizeof(NSUInteger) && out.length / sizeof(Sel) < kMaxCursors; i++) {
        NSRange r = NSMakeRange(h[i], needle.length);
        if (whole && ![self isWholeWord:r]) continue;
        if (h[i] == keep) primary = out.length / sizeof(Sel);
        [out appendBytes:&(Sel){r.location, NSMaxRange(r), -1} length:sizeof(Sel)];
    }
    if (!out.length) { NSBeep(); return; }
    [self rememberCursors];
    _occurrenceWhole = whole;
    [self setCursors:out.bytes count:out.length / sizeof(Sel) primary:primary];
    [self endOccurrenceStep];
}

#pragma mark Expand / shrink (⌃⇧⌘→ / ⌃⇧⌘←)

- (void)expandSelection:(id)sender {
    NSData *now = self.cursorSnapshot;
    if (!_expandLast || ![_expandLast isEqualToData:now]) _expandStack = [NSMutableArray array];
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    Sel *c = cur.mutableBytes;
    BOOL grew = NO;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        NSRange r = [self expandedRangeOf:SelRange(c[i])];
        if (r.length == SelRange(c[i]).length) continue;
        c[i] = SelMake(r.location, NSMaxRange(r));
        grew = YES;
    }
    if (!grew) { NSBeep(); return; }
    [_expandStack addObject:now];
    [self setCursors:c count:cur.length / sizeof(Sel) primary:primary];
    _coalesceBroken = YES;
    [self cursorsChanged];
    _expandLast = self.cursorSnapshot;
}

- (void)shrinkSelection:(id)sender {
    if (!_expandStack.count || ![_expandLast isEqualToData:self.cursorSnapshot]) { NSBeep(); return; }
    NSData *d = _expandStack.lastObject;
    [_expandStack removeLastObject];
    [self restoreCursorSnapshot:d];
    _expandLast = self.cursorSnapshot;
}

#pragma mark Column selection (⇧⌥ drag)

- (NSPoint)textPointFor:(NSPoint)p {
    CGFloat y = p.y + self.scrollY - 4;
    NSUInteger rows = self.rowCount;
    NSUInteger row = y < 0 ? 0 : MIN((NSUInteger)(y / _lineHeight), rows ? rows - 1 : 0);
    return NSMakePoint(MAX(0, p.x - self.textOriginX), row);
}

- (void)beginColumnSelectionAt:(NSPoint)p {
    _columnDrag = YES;
    _columnFrom = [self textPointFor:p];
    [self columnSelectTo:p];
}

// One selection per row between the two points, from x0 to x1; rows too short to reach are skipped.
- (void)columnSelectTo:(NSPoint)p {
    NSPoint to = [self textPointFor:p];
    NSUInteger r0 = (NSUInteger)_columnFrom.y, r1 = (NSUInteger)to.y;
    CGFloat x0 = _columnFrom.x, x1 = to.x;
    NSUInteger lo = MIN(r0, r1), hi = MAX(r0, r1);
    NSMutableData *out = [NSMutableData data];
    for (NSUInteger row = lo; row <= hi && out.length / sizeof(Sel) < kMaxCursors; row++) {
        NSUInteger a = [self offsetInRow:row x:x0], b = [self offsetInRow:row x:x1];
        if (x0 != x1 && a == b && hi > lo) {                     // the row ends before both columns
            CGFloat endX = 0;
            [self rowOfOffset:a x:&endX];
            if (endX + 0.5 < MIN(x0, x1)) continue;
        }
        [out appendBytes:&(Sel){a, b, x1} length:sizeof(Sel)];
    }
    if (!out.length) {
        NSUInteger a = [self offsetInRow:r1 x:x1];
        [out appendBytes:&(Sel){a, a, x1} length:sizeof(Sel)];
    }
    NSUInteger n = out.length / sizeof(Sel);
    [self setCursors:out.bytes count:n primary:r1 >= r0 ? n - 1 : 0];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self cursorsChanged];
}

#pragma mark Clipboard

- (NSPasteboard *)pasteboard { return _pasteboard ?: NSPasteboard.generalPasteboard; }
- (void)setPasteboard:(NSPasteboard *)p { _pasteboard = p; }

// What ⌘C / ⌘X take: the selections, or the cursors' whole lines when nothing is selected.
- (NSArray<NSString *> *)clipboardPieces:(BOOL *)lines ranges:(NSMutableArray<NSValue *> *)ranges {
    NSUInteger primary = 0;
    NSData *cur = [self cursors:&primary];
    const Sel *c = cur.bytes;
    NSUInteger n = cur.length / sizeof(Sel);
    BOOL whole = YES;
    for (NSUInteger i = 0; i < n && whole; i++) whole = c[i].anchor == c[i].caret;
    *lines = whole;
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger lastLine = NSNotFound;
    for (NSUInteger i = 0; i < n; i++) {
        NSRange r;
        if (whole) {
            NSUInteger L = [_buf lineForOffset:c[i].caret];
            if (L == lastLine) continue;
            lastLine = L;
            NSUInteger a = [_buf lineStart:L], b = L + 1 < _buf.lineCount ? [_buf lineStart:L + 1] : _buf.length;
            r = NSMakeRange(a, b - a);
            NSString *s = [self stringIn:r];
            if (L + 1 >= _buf.lineCount) s = [s stringByAppendingString:@"\n"];      // the last line has no break
            [out addObject:[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]];
        } else {
            if (c[i].anchor == c[i].caret) continue;
            r = SelRange(c[i]);
            [out addObject:[[self stringIn:r] stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]];
        }
        [ranges addObject:[NSValue valueWithRange:r]];
    }
    return out;
}

- (void)writePieces:(NSArray<NSString *> *)pieces lines:(BOOL)lines {
    NSPasteboard *pb = self.pasteboard;
    [pb clearContents];
    NSString *joined = lines ? [pieces componentsJoinedByString:@""] : [pieces componentsJoinedByString:@"\n"];
    [pb setString:joined forType:NSPasteboardTypeString];
    if (pieces.count > 1 || lines) {
        NSData *d = [NSPropertyListSerialization dataWithPropertyList:@{@"pieces": pieces, @"lines": @(lines)}
                                                               format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        if (d) [pb setData:d forType:kPiecesType];
    }
}

- (void)copy:(id)sender {
    BOOL lines = NO;
    NSArray *pieces = [self clipboardPieces:&lines ranges:[NSMutableArray array]];
    if (pieces.count) [self writePieces:pieces lines:lines];
}

- (void)cut:(id)sender {
    BOOL lines = NO;
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSArray *pieces = [self clipboardPieces:&lines ranges:ranges];
    if (!pieces.count) return;
    [self writePieces:pieces lines:lines];
    if (!lines) {
        [self editCursors:^NSRange(Sel s, NSString **t, NSInteger *a, NSInteger *c) { return SelRange(s); } kind:GroupOther];
        return;
    }
    __block NSUInteger lastLine = NSNotFound;
    [self editCursors:^NSRange(Sel s, NSString **t, NSInteger *a, NSInteger *c) {
        NSUInteger L = [self->_buf lineForOffset:s.caret];
        if (L == lastLine) return NSMakeRange(NSNotFound, 0);
        lastLine = L;
        NSUInteger x = [self->_buf lineStart:L], y;
        if (L + 1 < self->_buf.lineCount) y = [self->_buf lineStart:L + 1];
        else { y = self->_buf.length; if (L > 0) x = [self->_buf lineEnd:L - 1]; }     // the last line takes the break before it
        return NSMakeRange(x, y - x);
    } kind:GroupOther];
}

- (void)paste:(id)sender {
    NSPasteboard *pb = self.pasteboard;
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    NSArray<NSString *> *pieces = nil;
    BOOL lines = NO;
    NSData *d = [pb dataForType:kPiecesType];
    NSDictionary *info = d ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:nil] : nil;
    if ([info isKindOfClass:NSDictionary.class] && [info[@"pieces"] isKindOfClass:NSArray.class]) {
        NSArray *p = info[@"pieces"];
        NSString *joined = [info[@"lines"] boolValue] ? [p componentsJoinedByString:@""] : [p componentsJoinedByString:@"\n"];
        if ([joined isEqualToString:s]) { pieces = p; lines = [info[@"lines"] boolValue]; }   // still ours
    }
    NSUInteger n = self.cursorCount;
    if (pieces.count != n) { pieces = nil; lines = lines && n == 1; }
    if (!pieces && n > 1) {                                  // one line per cursor
        NSArray *split = [([s hasSuffix:@"\n"] ? [s substringToIndex:s.length - 1] : s) componentsSeparatedByString:@"\n"];
        if (split.count == n) pieces = split;
    }
    BOOL crlf = _buf.usesCRLF;
    NSString *(^fix)(NSString *) = ^NSString *(NSString *t) { return crlf ? [t stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"] : t; };
    __block NSUInteger i = 0;
    BOOL lineMode = lines;
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) {
        NSString *piece = pieces ? pieces[i] : s;
        i++;
        if (lineMode && sel.anchor == sel.caret) {               // whole lines go above the cursor's line
            NSUInteger ls = [self->_buf lineStart:[self->_buf lineForOffset:sel.caret]];
            *t = fix(piece);
            NSInteger keep = (NSInteger)(sel.caret - ls) + (NSInteger)[*t lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            *a = keep; *c = keep;
            return NSMakeRange(ls, 0);
        }
        *t = fix(piece);
        return SelRange(sel);
    } kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)selectAll:(id)sender {
    [self dropExtraCursors];
    _anchor = 0; _caret = _buf.length;
    _coalesceBroken = YES;
    [self notifyChange];
}

// Esc: back to one cursor, then drop the selection.
- (void)cancelOperation:(id)s {
    if (_extra.length) { [self rememberCursors]; [self dropExtraCursors]; _coalesceBroken = YES; [self notifyChange]; return; }
    if (self.selection.length) [self moveCaretTo:_caret extend:NO];
}

@end

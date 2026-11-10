#import "TextEditorView+Private.h"

// Line commands. Each works on every cursor; cursors on the same or touching lines act as one block.

typedef struct { NSUInteger first, last; } Block;

@implementation TextEditorView (Lines)

- (NSUInteger)firstNonBlankOf:(NSUInteger)L {
    NSUInteger i = [_buf lineStart:L], e = [_buf lineEnd:L];
    while (i < e && ([_buf byteAt:i] == ' ' || [_buf byteAt:i] == '\t')) i++;
    return i;
}

- (NSString *)indentOf:(NSUInteger)L {
    NSUInteger a = [_buf lineStart:L];
    return [self stringIn:NSMakeRange(a, [self firstNonBlankOf:L] - a)];
}

- (NSString *)lineCommentToken { return _hl.lineComment; }

- (BOOL)lineIsBlank:(NSUInteger)L { return [self firstNonBlankOf:L] == [_buf lineEnd:L]; }

// Lines a selection covers: one that ends at the start of a line doesn't include it.
- (Block)linesOf:(Sel)s {
    NSUInteger a = SelStart(s), b = SelEnd(s);
    NSUInteger L0 = [_buf lineForOffset:a], L1 = [_buf lineForOffset:b];
    if (L1 > L0 && b == [_buf lineStart:L1]) L1--;
    return (Block){L0, L1};
}

// The cursors' line blocks, in order; `touching` joins blocks with no line between them too.
// map[i] = the block of cursor i.
- (NSMutableData *)blocks:(BOOL)touching cursors:(NSData *)cur map:(NSMutableData *)map {
    const Sel *c = cur.bytes;
    NSUInteger n = cur.length / sizeof(Sel);
    NSMutableData *out = [NSMutableData data];
    if (map) map.length = n * sizeof(NSUInteger);
    NSUInteger *m = map.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        Block b = [self linesOf:c[i]];
        Block *last = out.length ? (Block *)out.mutableBytes + out.length / sizeof(Block) - 1 : NULL;
        if (last && (b.first <= last->last || (touching && b.first == last->last + 1))) last->last = MAX(last->last, b.last);
        else [out appendBytes:&b length:sizeof b];
        if (m) m[i] = out.length / sizeof(Block) - 1;
    }
    return out;
}

- (NSUInteger)lineEndWithBreak:(NSUInteger)L {          // start of the next line, or the end of the text
    return L + 1 < _buf.lineCount ? [_buf lineStart:L + 1] : _buf.length;
}

#pragma mark Move / copy / delete

- (void)moveLines:(NSInteger)dir {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSMutableData *map = [NSMutableData data];
    NSData *blocks = [self blocks:YES cursors:cur map:map];
    const Block *bl = blocks.bytes;
    NSUInteger nb = blocks.length / sizeof(Block), lines = _buf.lineCount;
    EditList *e = [EditList new];
    NSMutableData *shift = [NSMutableData dataWithLength:nb * sizeof(NSInteger)];
    NSInteger *sh = shift.mutableBytes;
    BOOL moved = NO;
    for (NSUInteger k = 0; k < nb; k++) {
        Block b = bl[k];
        if (dir < 0 && b.first == 0) continue;
        if (dir > 0 && b.last + 1 >= lines) continue;
        NSUInteger bs = [_buf lineStart:b.first], be = [_buf lineEnd:b.last];
        NSString *block = [self stringIn:NSMakeRange(bs, be - bs)];
        if (dir < 0) {
            NSUInteger ps = [_buf lineStart:b.first - 1], pe = [_buf lineEnd:b.first - 1];
            NSString *prev = [self stringIn:NSMakeRange(ps, pe - ps)], *sep = [self stringIn:NSMakeRange(pe, bs - pe)];
            [e replace:NSMakeRange(ps, be - ps) with:[NSString stringWithFormat:@"%@%@%@", block, sep, prev]];
            sh[k] = -(NSInteger)(bs - ps);
        } else {
            NSUInteger ns = [_buf lineStart:b.last + 1], ne = [_buf lineEnd:b.last + 1];
            NSString *next = [self stringIn:NSMakeRange(ns, ne - ns)], *sep = [self stringIn:NSMakeRange(be, ns - be)];
            [e replace:NSMakeRange(bs, ne - bs) with:[NSString stringWithFormat:@"%@%@%@", next, sep, block]];
            sh[k] = (NSInteger)(ne - be);
        }
        moved = YES;
    }
    if (!moved) { NSBeep(); return; }
    // cursors move with their lines (a full-line selection's end at the next line's start too)
    Sel *c = cur.mutableBytes;
    const NSUInteger *m = map.bytes;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        NSInteger d = sh[m[i]];
        if (!d) continue;
        c[i].anchor = (NSUInteger)((NSInteger)c[i].anchor + d);
        c[i].caret = (NSUInteger)((NSInteger)c[i].caret + d);
        c[i].x = -1;
    }
    [self commit:e selections:c count:cur.length / sizeof(Sel) primary:primary kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)moveLinesUp:(id)sender { [self moveLines:-1]; }
- (void)moveLinesDown:(id)sender { [self moveLines:1]; }

- (void)copyLines:(BOOL)down {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSMutableData *map = [NSMutableData data];
    NSData *blocks = [self blocks:NO cursors:cur map:map];
    const Block *bl = blocks.bytes;
    NSUInteger nb = blocks.length / sizeof(Block);
    EditList *e = [EditList new];
    NSString *nl = self.newline;
    NSMutableData *shift = [NSMutableData dataWithLength:nb * sizeof(NSInteger)];
    NSInteger *sh = shift.mutableBytes, acc = 0;
    for (NSUInteger k = 0; k < nb; k++) {
        NSUInteger bs = [_buf lineStart:bl[k].first], be = [_buf lineEnd:bl[k].last];
        NSString *block = [self stringIn:NSMakeRange(bs, be - bs)];
        NSInteger len = (NSInteger)(be - bs + [nl lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        if (down) { [e replace:NSMakeRange(be, 0) with:[nl stringByAppendingString:block]]; sh[k] = acc + len; }
        else { [e replace:NSMakeRange(bs, 0) with:[block stringByAppendingString:nl]]; sh[k] = acc; }
        acc += len;
    }
    Sel *c = cur.mutableBytes;
    const NSUInteger *m = map.bytes;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        NSInteger d = sh[m[i]];
        c[i].anchor = (NSUInteger)((NSInteger)c[i].anchor + d);
        c[i].caret = (NSUInteger)((NSInteger)c[i].caret + d);
        c[i].x = -1;
    }
    [self commit:e selections:c count:cur.length / sizeof(Sel) primary:primary kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)copyLinesUp:(id)sender { [self copyLines:NO]; }
- (void)copyLinesDown:(id)sender { [self copyLines:YES]; }

- (void)deleteLines:(id)sender {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSMutableData *map = [NSMutableData data];
    NSData *blocks = [self blocks:YES cursors:cur map:map];
    const Block *bl = blocks.bytes;
    NSUInteger nb = blocks.length / sizeof(Block), lines = _buf.lineCount;
    const Sel *c = cur.bytes;
    const NSUInteger *m = map.bytes;
    EditList *e = [EditList new];
    NSMutableData *after = [NSMutableData dataWithLength:nb * sizeof(Sel)];
    Sel *out = after.mutableBytes;
    NSUInteger newPrimary = m[primary];
    NSInteger removed = 0;
    for (NSUInteger k = 0; k < nb; k++) {
        Block b = bl[k];
        NSUInteger col = 0;                                   // the column of the block's first cursor
        for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) if (m[i] == k) { col = c[i].caret - [_buf lineStart:[_buf lineForOffset:c[i].caret]]; break; }
        NSUInteger x, y, target;                              // removed [x, y); the caret's line afterwards (old numbers)
        if (b.last + 1 < lines) { x = [_buf lineStart:b.first]; y = [_buf lineStart:b.last + 1]; target = b.last + 1; }
        else if (b.first > 0) { x = [_buf lineEnd:b.first - 1]; y = _buf.length; target = b.first - 1; }
        else { x = 0; y = _buf.length; target = NSNotFound; }
        [e replace:NSMakeRange(x, y - x) with:@""];
        NSUInteger caret;
        if (target == NSNotFound) caret = 0;
        else {
            NSUInteger ts = [_buf lineStart:target], te = [_buf lineEnd:target];
            NSUInteger at = ts + MIN(col, te - ts);
            // in the text afterwards: earlier removals, and this one if the line comes after it
            caret = (NSUInteger)((NSInteger)at - removed - (target > b.last ? (NSInteger)(y - x) : 0));
        }
        out[k] = SelMake(caret, caret);
        removed += (NSInteger)(y - x);
    }
    [self commit:e selections:out count:nb primary:newPrimary kind:GroupOther];
    _coalesceBroken = YES;
}

#pragma mark New lines

// Indentation for a new line after line L: the same, one more after an opening bracket or a Python colon.
- (NSString *)indentAfterLine:(NSUInteger)L {
    NSString *indent = [self indentOf:L];
    NSUInteger ls = [_buf lineStart:L], e = [_buf lineEnd:L];
    while (e > ls && ([_buf byteAt:e - 1] == ' ' || [_buf byteAt:e - 1] == '\t')) e--;
    uint8_t last = e > ls ? [_buf byteAt:e - 1] : 0;
    BOOL colon = last == ':' && [@[@"py", @"pyi", @"pyw"] containsObject:_path.pathExtension.lowercaseString];
    return last == '{' || last == '[' || last == '(' || colon ? [indent stringByAppendingString:_indentUnit] : indent;
}

- (void)insertLine:(BOOL)below {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    const Sel *c = cur.bytes;
    NSUInteger n = cur.length / sizeof(Sel);
    EditList *e = [EditList new];
    NSMutableData *after = [NSMutableData data];
    NSString *nl = self.newline;
    NSUInteger nlLen = [nl lengthOfBytesUsingEncoding:NSUTF8StringEncoding], lastLine = NSNotFound, newPrimary = 0;
    NSInteger acc = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger L = [_buf lineForOffset:c[i].caret];
        if (L != lastLine) {
            lastLine = L;
            NSString *indent = below ? [self indentAfterLine:L] : [self indentOf:L];
            NSUInteger iLen = [indent lengthOfBytesUsingEncoding:NSUTF8StringEncoding], caret;
            if (below) {
                NSUInteger at = [_buf lineEnd:L];
                [e replace:NSMakeRange(at, 0) with:[nl stringByAppendingString:indent]];
                caret = (NSUInteger)((NSInteger)at + acc) + nlLen + iLen;
            } else {
                NSUInteger at = [_buf lineStart:L];
                [e replace:NSMakeRange(at, 0) with:[indent stringByAppendingString:nl]];
                caret = (NSUInteger)((NSInteger)at + acc) + iLen;
            }
            acc += (NSInteger)(nlLen + iLen);
            [after appendBytes:&(Sel){caret, caret, -1} length:sizeof(Sel)];
        }
        if (i == primary) newPrimary = after.length / sizeof(Sel) - 1;
    }
    [self commit:e selections:after.bytes count:after.length / sizeof(Sel) primary:newPrimary kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)insertLineBelow:(id)sender { [self insertLine:YES]; }
- (void)insertLineAbove:(id)sender { [self insertLine:NO]; }

#pragma mark Indentation and comments

// The distinct lines under the cursors; blank lines of multi-line selections are left out.
- (NSIndexSet *)cursorLines:(BOOL)skipBlank {
    NSUInteger p = 0;
    NSData *cur = [self cursors:&p];
    const Sel *c = cur.bytes;
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        Block b = [self linesOf:c[i]];
        for (NSUInteger L = b.first; L <= b.last; L++)
            if (!(skipBlank && b.last > b.first && [self lineIsBlank:L])) [out addIndex:L];
    }
    return out;
}

- (void)indentLines:(id)sender {
    EditList *e = [EditList new];
    NSString *unit = _indentUnit;
    [[self cursorLines:YES] enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) { [e replace:NSMakeRange([self->_buf lineStart:L], 0) with:unit]; }];
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)outdentLines:(id)sender {
    EditList *e = [EditList new];
    NSUInteger width = [_indentUnit isEqualToString:@"\t"] ? 4 : _indentUnit.length;
    [[self cursorLines:NO] enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        NSUInteger ls = [self->_buf lineStart:L], le = [self->_buf lineEnd:L], n = 0;
        if (ls < le && [self->_buf byteAt:ls] == '\t') n = 1;
        else while (n < width && ls + n < le && [self->_buf byteAt:ls + n] == ' ') n++;
        if (n) [e replace:NSMakeRange(ls, n) with:@""];
    }];
    if (!e.count) return;
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

- (BOOL)line:(NSUInteger)L hasPrefix:(NSString *)token at:(NSUInteger *)at {
    NSUInteger f = [self firstNonBlankOf:L], n = [token lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (f + n > [_buf lineEnd:L]) return NO;
    if (at) *at = f;
    return [[self stringIn:NSMakeRange(f, n)] isEqualToString:token];
}

- (void)toggleLineComment:(id)sender {
    NSString *token = _hl.lineComment;
    NSArray<NSString *> *block = token ? nil : _hl.blockComment;
    if (!token && !block) { NSBeep(); return; }
    NSString *open = token ?: block[0], *close = block[1];
    NSIndexSet *all = [self cursorLines:NO];
    NSMutableIndexSet *lines = [NSMutableIndexSet indexSet];
    [all enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) { if (![self lineIsBlank:L]) [lines addIndex:L]; }];
    if (!lines.count) [lines addIndexes:all];
    __block BOOL commented = YES;
    __block NSUInteger minIndent = NSUIntegerMax;
    [lines enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        if (![self line:L hasPrefix:open at:NULL]) commented = NO;
        if (close) {
            NSUInteger e = [self->_buf lineEnd:L], cl = [close lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            while (e > [self->_buf lineStart:L] && ([self->_buf byteAt:e - 1] == ' ' || [self->_buf byteAt:e - 1] == '\t')) e--;
            if (e < cl || ![[self stringIn:NSMakeRange(e - cl, cl)] isEqualToString:close]) commented = NO;
        }
        minIndent = MIN(minIndent, [self firstNonBlankOf:L] - [self->_buf lineStart:L]);
    }];
    EditList *e = [EditList new];
    NSUInteger ol = [open lengthOfBytesUsingEncoding:NSUTF8StringEncoding], cl = [close lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [lines enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        PieceTable *b = self->_buf;
        if (commented) {
            NSUInteger at = 0;
            [self line:L hasPrefix:open at:&at];
            NSUInteger n = ol + (at + ol < [b lineEnd:L] && [b byteAt:at + ol] == ' ' ? 1 : 0);
            [e replace:NSMakeRange(at, n) with:@""];
            if (close) {
                NSUInteger end = [b lineEnd:L];
                while (end > at + n && ([b byteAt:end - 1] == ' ' || [b byteAt:end - 1] == '\t')) end--;
                NSUInteger cs = end - cl;
                if (cs > at + n && [b byteAt:cs - 1] == ' ') cs--;
                if (cs >= at + n) [e replace:NSMakeRange(cs, end - cs) with:@""];
            }
        } else {
            NSUInteger at = [b lineStart:L] + MIN(minIndent, [self firstNonBlankOf:L] - [b lineStart:L]);
            [e replace:NSMakeRange(at, 0) with:[open stringByAppendingString:@" "]];
            if (close) {
                NSUInteger end = [b lineEnd:L];
                while (end > at && ([b byteAt:end - 1] == ' ' || [b byteAt:end - 1] == '\t')) end--;
                [e replace:NSMakeRange(end, 0) with:[@" " stringByAppendingString:close]];
            }
        }
    }];
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

#pragma mark Join, sort, trim, case

- (void)joinLines:(id)sender {
    NSUInteger p = 0;
    NSData *cur = [self cursors:&p];
    const Sel *c = cur.bytes;
    NSMutableIndexSet *joins = [NSMutableIndexSet indexSet];        // line L joins with L + 1
    NSUInteger lines = _buf.lineCount;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        Block b = [self linesOf:c[i]];
        if (b.last == b.first) { if (b.first + 1 < lines) [joins addIndex:b.first]; }
        else [joins addIndexesInRange:NSMakeRange(b.first, b.last - b.first)];
    }
    if (!joins.count) { NSBeep(); return; }
    EditList *e = [EditList new];
    [joins enumerateIndexesUsingBlock:^(NSUInteger L, BOOL *stop) {
        PieceTable *b = self->_buf;
        NSUInteger x = [b lineEnd:L], ls = [b lineStart:L];
        while (x > ls && ([b byteAt:x - 1] == ' ' || [b byteAt:x - 1] == '\t')) x--;
        NSUInteger y = [self firstNonBlankOf:L + 1];
        BOOL space = x > ls && y < [b lineEnd:L + 1];
        [e replace:NSMakeRange(x, y - x) with:space ? @" " : @""];
    }];
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)sortLines:(BOOL)ascending {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSData *blocks;
    if (cur.length == sizeof(Sel) && _anchor == _caret) {
        Block all = {0, _buf.lineCount - 1};
        blocks = [NSData dataWithBytes:&all length:sizeof all];
    } else blocks = [self blocks:NO cursors:cur map:nil];
    const Block *bl = blocks.bytes;
    EditList *e = [EditList new];
    for (NSUInteger k = 0; k < blocks.length / sizeof(Block); k++) {
        Block b = bl[k];
        if (b.last > b.first && b.last + 1 == _buf.lineCount && [_buf lineStart:b.last] == _buf.length) b.last--;   // the final empty line
        if (b.last <= b.first) continue;
        NSMutableArray<NSString *> *lines = [NSMutableArray array], *seps = [NSMutableArray array];
        for (NSUInteger L = b.first; L <= b.last; L++) {
            [lines addObject:[self stringIn:NSMakeRange([_buf lineStart:L], [_buf lineEnd:L] - [_buf lineStart:L])]];
            if (L < b.last) [seps addObject:[self stringIn:NSMakeRange([_buf lineEnd:L], [_buf lineStart:L + 1] - [_buf lineEnd:L])]];
        }
        NSArray *sorted = [lines sortedArrayUsingComparator:^NSComparisonResult(NSString *x, NSString *y) {
            NSComparisonResult r = [x localizedStandardCompare:y];
            return ascending ? r : -r;
        }];
        NSMutableString *out = [NSMutableString string];
        for (NSUInteger i = 0; i < sorted.count; i++) { [out appendString:sorted[i]]; if (i < seps.count) [out appendString:seps[i]]; }
        NSUInteger a = [_buf lineStart:b.first];
        [e replace:NSMakeRange(a, [_buf lineEnd:b.last] - a) with:out];
    }
    if (!e.count) { NSBeep(); return; }
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)sortLinesAscending:(id)sender { [self sortLines:YES]; }
- (void)sortLinesDescending:(id)sender { [self sortLines:NO]; }

- (void)trimTrailingWhitespace:(id)sender {
    EditList *e = [EditList new];
    for (NSUInteger L = 0; L < _buf.lineCount; L++) {
        NSUInteger ls = [_buf lineStart:L], le = [_buf lineEnd:L], x = le;
        while (x > ls && ([_buf byteAt:x - 1] == ' ' || [_buf byteAt:x - 1] == '\t')) x--;
        if (x < le) [e replace:NSMakeRange(x, le - x) with:@""];
    }
    if (!e.count) return;
    [self commit:e selections:NULL count:0 primary:0 kind:GroupOther];
    _coalesceBroken = YES;
}

// Selected text, or the word at each caret; the selection is kept.
- (void)transformCase:(NSString *(^)(NSString *))f {
    [self editCursors:^NSRange(Sel s, NSString **t, NSInteger *a, NSInteger *c) {
        NSRange r = s.anchor == s.caret ? [self wordAroundCaret:s.caret] : SelRange(s);
        if (!r.length) return NSMakeRange(NSNotFound, 0);
        *t = f([self stringIn:r]);
        NSInteger len = (NSInteger)[*t lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (s.anchor == s.caret) { NSInteger at = MIN((NSInteger)(s.caret - r.location), len); *a = at; *c = at; }
        else if (s.caret > s.anchor) { *a = 0; *c = len; }
        else { *a = len; *c = 0; }
        return r;
    } kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)uppercaseWord:(id)sender { [self transformCase:^NSString *(NSString *s) { return s.uppercaseString; }]; }
- (void)lowercaseWord:(id)sender { [self transformCase:^NSString *(NSString *s) { return s.lowercaseString; }]; }
- (void)capitalizeWord:(id)sender { [self transformCase:^NSString *(NSString *s) { return s.capitalizedString; }]; }

@end

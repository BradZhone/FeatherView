#import "TextEditorView+Private.h"

// Typing aids: auto-closed brackets and quotes, the matching bracket, other occurrences of a word.

extern BOOL FTEditorAutoClose;
static const NSUInteger kBracketScanLines = 3000;

static inline BOOL wordByte(uint8_t c) {
    return c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'z');
}
static unichar closerOf(unichar c) {
    switch (c) { case '(': return ')'; case '[': return ']'; case '{': return '}'; case '"': return '"'; case '\'': return '\''; case '`': return '`'; }
    return 0;
}
static BOOL isCloser(uint8_t c) { return c == ')' || c == ']' || c == '}' || c == '"' || c == '\'' || c == '`'; }
static BOOL isQuote(unichar c) { return c == '"' || c == '\'' || c == '`'; }

@implementation TextEditorView (Assist)

// Plain text and Markdown prose would get in the way more often than not: brackets yes, quotes no.
- (BOOL)pairsQuote:(unichar)q {
    NSString *mode = _hl.modeName;
    if (!mode || [mode isEqualToString:@"markdown"]) return NO;
    if (q == '`') return [mode isEqualToString:@"code"];
    if (q == '\'') return ![mode isEqualToString:@"markup"] && ![mode isEqualToString:@"ini"] && ![mode isEqualToString:@"ignore"];
    return YES;
}

- (BOOL)autoPairInsert:(NSString *)s {
    if (!FTEditorAutoClose || s.length != 1 || !_hl) return NO;
    unichar ch = [s characterAtIndex:0];
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    Sel *c = cur.mutableBytes;
    NSUInteger n = cur.length / sizeof(Sel), len = _buf.length;

    // a closer typed over the one auto-close put there just moves past it
    if (isCloser(ch)) {
        BOOL all = YES;
        for (NSUInteger i = 0; i < n && all; i++)
            all = c[i].anchor == c[i].caret && [_autoClosed containsIndex:c[i].caret] && c[i].caret < len && [_buf byteAt:c[i].caret] == ch;
        if (all) {
            for (NSUInteger i = 0; i < n; i++) { [_autoClosed removeIndex:c[i].caret]; c[i].caret = c[i].anchor = c[i].caret + 1; c[i].x = -1; }
            [self setCursors:c count:n primary:primary];
            [self cursorsChanged];
            return YES;
        }
    }
    unichar close = closerOf(ch);
    if (!close || (isQuote(ch) && ![self pairsQuote:ch])) return NO;

    BOOL allSelected = YES;
    for (NSUInteger i = 0; i < n && allSelected; i++) allSelected = c[i].anchor != c[i].caret;
    NSString *closeStr = [NSString stringWithCharacters:&close length:1];
    if (allSelected) {                                     // wrap the selections, which stay selected
        [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *b) {
            NSString *inner = [self stringIn:SelRange(sel)];
            *t = [NSString stringWithFormat:@"%@%@%@", s, inner, closeStr];
            NSInteger il = (NSInteger)[inner lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            BOOL fwd = sel.caret > sel.anchor;
            *a = fwd ? 1 : 1 + il; *b = fwd ? 1 + il : 1;
            return SelRange(sel);
        } kind:GroupOther];
        _coalesceBroken = YES;
        return YES;
    }
    // pair at carets followed by nothing, a space or a closer (and, for quotes, not inside a word)
    BOOL any = NO;
    for (NSUInteger i = 0; i < n && !any; i++) any = [self pairsAt:c[i] opener:ch];
    if (!any) return NO;
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *b) {
        BOOL pair = [self pairsAt:sel opener:ch];
        *t = pair ? [s stringByAppendingString:closeStr] : s;
        *a = 1; *b = 1;
        return SelRange(sel);
    } kind:GroupTyping];
    NSMutableIndexSet *ac = _autoClosed ? [_autoClosed mutableCopy] : [NSMutableIndexSet indexSet];   // shifted by the edit
    NSData *now = [self cursors:&primary];
    const Sel *after = now.bytes;
    for (NSUInteger i = 0; i < now.length / sizeof(Sel); i++) {
        NSUInteger at = after[i].caret;
        if (at < _buf.length && at > 0 && [_buf byteAt:at] == close && [_buf byteAt:at - 1] == ch) [ac addIndex:at];
    }
    _autoClosed = ac;
    return YES;
}

- (BOOL)pairsAt:(Sel)s opener:(unichar)ch {
    if (s.anchor != s.caret) return NO;
    NSUInteger at = s.caret, len = _buf.length;
    uint8_t next = at < len ? [_buf byteAt:at] : 0;
    if (!(next == 0 || next == ' ' || next == '\t' || next == '\n' || next == '\r' || next == ')' || next == ']' || next == '}' ||
          next == ',' || next == ';' || next == ':' || (isQuote(ch) ? NO : isQuote(next)))) return NO;
    if (isQuote(ch) && at > 0) {
        uint8_t prev = [_buf byteAt:at - 1];
        if (wordByte(prev) || prev == ch || prev == '\\') return NO;
    }
    return YES;
}

// Backspace between a pair that auto-close made removes both.
- (BOOL)autoPairBackspace {
    if (!_autoClosed.count) return NO;
    NSUInteger primary = 0;
    NSData *cur = [self cursors:&primary];
    const Sel *c = cur.bytes;
    for (NSUInteger i = 0; i < cur.length / sizeof(Sel); i++) {
        NSUInteger at = c[i].caret;
        if (c[i].anchor != at || at == 0 || ![_autoClosed containsIndex:at] || at >= _buf.length) return NO;
        if (closerOf([_buf byteAt:at - 1]) != [_buf byteAt:at]) return NO;
    }
    [self editCursors:^NSRange(Sel s, NSString **t, NSInteger *a, NSInteger *b) { return NSMakeRange(s.caret - 1, 2); } kind:GroupOther];
    return YES;
}

// Auto-closed characters follow the text around them; one that was replaced is forgotten.
- (void)shiftAutoClosed:(EditList *)edits {
    if (!_autoClosed.count) return;
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [_autoClosed enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        NSUInteger j = [edits map:i right:YES];
        if (j < self->_buf.length && isCloser([self->_buf byteAt:j])) [out addIndex:j];
    }];
    _autoClosed = out;
}

#pragma mark Matching brackets

// Bytes of line L where brackets count: not inside strings or comments.
- (NSData *)codeMaskOf:(NSUInteger)L bytes:(NSData **)bytes {
    NSData *d = [self lineBytes:L];
    if (bytes) *bytes = d;
    NSMutableData *mask = [NSMutableData dataWithLength:d.length];
    memset(mask.mutableBytes, 1, d.length);
    if (!_hl || !d.length) return mask;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) return mask;
    // UTF-16 index → byte index
    const uint8_t *b = d.bytes;
    NSMutableData *u2b = [NSMutableData dataWithLength:(s.length + 1) * sizeof(NSUInteger)];
    NSUInteger *m = u2b.mutableBytes, u = 0;
    for (NSUInteger i = 0; i < d.length; i++) {
        if ((b[i] & 0xC0) == 0x80) continue;
        if (u <= s.length) m[u] = i;
        u += b[i] >= 0xF0 ? 2 : 1;
        if (b[i] >= 0xF0 && u - 1 <= s.length) m[u - 1] = i;
    }
    if (u <= s.length) m[u] = d.length;
    uint8_t *mk = mask.mutableBytes;
    [_hl tokenize:s emit:^(NSRange r, TokenKind k) {
        if (k != TokString && k != TokComment) return;
        NSUInteger a = m[MIN(r.location, s.length)], e = m[MIN(NSMaxRange(r), s.length)];
        if (e > a) memset(mk + a, 0, e - a);
    }];
    return mask;
}

static uint8_t partnerOf(uint8_t c) {
    switch (c) { case '(': return ')'; case ')': return '('; case '[': return ']'; case ']': return '['; case '{': return '}'; case '}': return '{'; }
    return 0;
}
static BOOL opens(uint8_t c) { return c == '(' || c == '[' || c == '{'; }

// The bracket matching the one at `at`, scanning a bounded number of lines; NSNotFound if none.
- (NSUInteger)matchOfBracketAt:(NSUInteger)at {
    uint8_t ch = [_buf byteAt:at], want = partnerOf(ch);
    if (!want) return NSNotFound;
    BOOL fwd = opens(ch);
    NSUInteger L = [_buf lineForOffset:at], ls = [_buf lineStart:L];
    NSInteger depth = 0;
    for (NSUInteger step = 0; step < kBracketScanLines; step++) {
        NSData *bytes = nil;
        NSData *mask = [self codeMaskOf:L bytes:&bytes];
        const uint8_t *b = bytes.bytes, *mk = mask.bytes;
        NSUInteger n = bytes.length;
        NSUInteger base = [_buf lineStart:L];
        if (step == 0 && (at - ls >= n || !mk[at - ls])) return NSNotFound;          // the bracket itself is in a string
        if (fwd) {
            for (NSUInteger i = step ? 0 : at - base; i < n; i++) {
                if (!mk[i]) continue;
                if (b[i] == ch) depth++;
                else if (b[i] == want && --depth == 0) return base + i;
            }
            if (++L >= _buf.lineCount) return NSNotFound;
        } else {
            for (NSUInteger i = step ? n : at - base + 1; i-- > 0;) {
                if (!mk[i]) continue;
                if (b[i] == ch) depth++;
                else if (b[i] == want && --depth == 0) return base + i;
            }
            if (L == 0) return NSNotFound;
            L--;
        }
    }
    return NSNotFound;
}

// A bracket right before the caret wins over one right after it.
- (NSUInteger)bracketAtCaret {
    if (_caret > 0 && partnerOf([_buf byteAt:_caret - 1])) return _caret - 1;
    if (_caret < _buf.length && partnerOf([_buf byteAt:_caret])) return _caret;
    return NSNotFound;
}

- (void)updateBracketPair {
    if (_bracketValid && _bracketEdit == _editCount && _bracketCaret == _caret) return;
    _bracketValid = YES; _bracketEdit = _editCount; _bracketCaret = _caret;
    _bracketPair[0] = _bracketPair[1] = NSNotFound;
    if (_anchor != _caret) return;
    NSUInteger at = [self bracketAtCaret];
    if (at == NSNotFound) return;
    NSUInteger m = [self matchOfBracketAt:at];
    if (m == NSNotFound) return;
    _bracketPair[0] = MIN(at, m); _bracketPair[1] = MAX(at, m);
}

// ⇧⌘\: to the matching bracket, or to the opening one of the brackets around the caret.
- (void)jumpToBracket:(id)sender {
    NSUInteger at = [self bracketAtCaret], m = at == NSNotFound ? NSNotFound : [self matchOfBracketAt:at];
    if (m == NSNotFound) {
        // the nearest unclosed opener before the caret
        NSInteger depth[3] = {0, 0, 0};
        NSUInteger L = [_buf lineForOffset:_caret];
        for (NSUInteger step = 0; step < kBracketScanLines && m == NSNotFound; step++) {
            NSData *bytes = nil;
            NSData *mask = [self codeMaskOf:L bytes:&bytes];
            const uint8_t *b = bytes.bytes, *mk = mask.bytes;
            NSUInteger base = [_buf lineStart:L], from = step ? bytes.length : MIN(_caret - base, bytes.length);
            for (NSUInteger i = from; i-- > 0 && m == NSNotFound;) {
                if (!mk[i]) continue;
                int k = b[i] == '(' || b[i] == ')' ? 0 : b[i] == '[' || b[i] == ']' ? 1 : b[i] == '{' || b[i] == '}' ? 2 : -1;
                if (k < 0) continue;
                if (opens(b[i])) { if (depth[k] == 0) m = base + i; else depth[k]--; }
                else depth[k]++;
            }
            if (L == 0) break;
            L--;
        }
        if (m == NSNotFound) { NSBeep(); return; }
    }
    [self moveCaretTo:m extend:NO];
}

#pragma mark Expanding the selection

// The opening bracket of the innermost pair that contains [a, b), and its match; NO if none.
- (BOOL)bracketsAround:(NSRange)r open:(NSUInteger *)o close:(NSUInteger *)c {
    NSInteger depth[3] = {0, 0, 0};
    NSUInteger L = [_buf lineForOffset:r.location];
    for (NSUInteger step = 0; step < kBracketScanLines; step++) {
        NSData *bytes = nil;
        NSData *mask = [self codeMaskOf:L bytes:&bytes];
        const uint8_t *b = bytes.bytes, *mk = mask.bytes;
        NSUInteger base = [_buf lineStart:L], from = step ? bytes.length : MIN(r.location - base, bytes.length);
        for (NSUInteger i = from; i-- > 0;) {
            if (!mk[i]) continue;
            int k = b[i] == '(' || b[i] == ')' ? 0 : b[i] == '[' || b[i] == ']' ? 1 : b[i] == '{' || b[i] == '}' ? 2 : -1;
            if (k < 0) continue;
            if (!opens(b[i])) { depth[k]++; continue; }
            if (depth[k]) { depth[k]--; continue; }
            NSUInteger m = [self matchOfBracketAt:base + i];
            if (m != NSNotFound && m >= NSMaxRange(r)) { *o = base + i; *c = m; return YES; }
        }
        if (L == 0) break;
        L--;
    }
    return NO;
}

- (NSRange)expandedRangeOf:(NSRange)r {
    NSMutableArray<NSValue *> *cand = [NSMutableArray array];
    void (^add)(NSUInteger, NSUInteger) = ^(NSUInteger a, NSUInteger b) { if (b >= a) [cand addObject:[NSValue valueWithRange:NSMakeRange(a, b - a)]]; };
    NSRange w = [self wordAroundCaret:r.location];
    if (w.length) add(w.location, NSMaxRange(w));
    // a string token on the line: its text, then with the quotes
    NSUInteger L = [_buf lineForOffset:r.location], ls = [_buf lineStart:L];
    if (_hl && NSMaxRange(r) <= [_buf lineEnd:L]) {
        NSString *s = [self lineString:L];
        __block NSRange str = NSMakeRange(NSNotFound, 0);
        NSUInteger ua = [self utf16Index:r.location inLine:L], ub = [self utf16Index:NSMaxRange(r) inLine:L];
        [_hl tokenize:s emit:^(NSRange t, TokenKind k) { if (k == TokString && t.location <= ua && NSMaxRange(t) >= ub && t.length >= 2) str = t; }];
        if (str.location != NSNotFound) {
            NSUInteger a = [self byteOffsetForUTF16:str.location inLine:L], b = [self byteOffsetForUTF16:NSMaxRange(str) inLine:L];
            add(a + 1, b - 1);
            add(a, b);
        }
    }
    // brackets, inner then outer, outwards
    NSRange at = r;
    for (int depth = 0; depth < 64; depth++) {
        NSUInteger o, c;
        if (![self bracketsAround:at open:&o close:&c]) break;
        add(o + 1, c);
        add(o, c + 1);
        at = NSMakeRange(o, c + 1 - o);
    }
    NSUInteger L1 = [_buf lineForOffset:NSMaxRange(r)];
    add([self firstNonBlankOf:L], [_buf lineEnd:L1]);
    add(ls, [_buf lineEnd:L1]);
    add(ls, L1 + 1 < _buf.lineCount ? [_buf lineStart:L1 + 1] : _buf.length);
    add(0, _buf.length);
    NSRange best = NSMakeRange(0, _buf.length);
    for (NSValue *v in cand) {
        NSRange x = v.rangeValue;
        BOOL contains = x.location <= r.location && NSMaxRange(x) >= NSMaxRange(r) && x.length > r.length;
        if (contains && x.length < best.length) best = x;
    }
    return best;
}

#pragma mark Other occurrences

// The selected text (one line, not too long), or the word at the caret; nil when nothing qualifies.
- (NSString *)highlightedWord:(BOOL *)whole {
    NSRange r = self.selection;
    if (r.length) {
        if (r.length > 200 || [_buf lineForOffset:r.location] != [_buf lineForOffset:NSMaxRange(r)]) return nil;
        NSString *s = [self stringIn:r];
        if (![s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) return nil;
        *whole = NO;
        return s;
    }
    NSRange w = [self wordAroundCaret:_caret];
    if (!w.length || w.length > 200) return nil;
    *whole = YES;
    return [self stringIn:w];
}

@end

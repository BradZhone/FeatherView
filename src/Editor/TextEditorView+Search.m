#import "TextEditorView+Private.h"

static inline uint8_t lcb(uint8_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

@implementation TextEditorView (Search)

- (NSData *)contentData { return [_buf dataInRange:NSMakeRange(0, _buf.length)]; }
- (NSUInteger)contentLength { return _buf.length; }
- (CGFloat)topVisibleLine { return MAX(0, [self lineAtY:self.scrollY]); }
- (NSUInteger)editCount { return _editCount; }
- (BOOL)isComposing { return _markedText != nil; }

- (NSString *)selectedText {
    NSRange r = self.selection;
    if (!r.length || r.length > 500) return nil;
    NSString *s = [[NSString alloc] initWithData:[_buf dataInRange:r] encoding:NSUTF8StringEncoding];
    return [s rangeOfString:@"\n"].location == NSNotFound ? s : nil;
}

- (void)setDocumentPath:(NSString *)path {
    _path = [path copy];
    _hl = [Highlighter highlighterForPath:path];
    [self notifyChange];
}

- (NSUInteger)charBoundary:(NSUInteger)off lo:(NSUInteger)lo {
    while (off > lo && ([_buf byteAt:off] & 0xC0) == 0x80) off--;
    return off;
}

- (void)selectLine:(NSUInteger)line column:(NSUInteger)col length:(NSUInteger)len {
    NSUInteger L = MIN(MAX(line, 1), _buf.lineCount) - 1;
    NSUInteger ls = [_buf lineStart:L], le = [_buf lineEnd:L];
    NSUInteger a = [self charBoundary:MIN(ls + (col ? col - 1 : 0), le) lo:ls];
    NSUInteger b = MIN(a + len, le);
    if (b < le) { NSUInteger nb = b; while (nb < le && ([_buf byteAt:nb] & 0xC0) == 0x80) nb++; b = nb; }
    _anchor = a; _caret = b;
    _coalesceBroken = YES;
    _desiredX = -1;
    self.scrollY = MAX(0, [self yForLine:L] - self.bounds.size.height / 3);
    [self scrollCaretVisible];
    [self notifyChange];
}

- (BOOL)selectionEquals:(NSData *)d {
    NSRange r = self.selection;
    if (r.length != d.length || !r.length) return NO;
    NSData *sel = [_buf dataInRange:r];
    const uint8_t *a = sel.bytes, *b = d.bytes;
    for (NSUInteger i = 0; i < r.length; i++) if (lcb(a[i]) != lcb(b[i])) return NO;
    return YES;
}

- (BOOL)replaceSelectionIfMatches:(NSString *)find with:(NSString *)repl {
    NSData *f = [find dataUsingEncoding:NSUTF8StringEncoding];
    if (!f.length) return NO;
    BOOL replaced = NO;
    PTUnicodeIndex *ui = [self unicodeIndexFor:find];
    if (ui ? [ui range:self.selection matches:find] : [self selectionEquals:f]) {
        [self replaceRange:self.selection withString:repl kind:GroupOther];
        _coalesceBroken = YES;
        replaced = YES;
    }
    [self findString:find backward:NO];
    return replaced;
}

// One pass over the text, then the buffer is swapped: per-match edits made this quadratic.
- (NSUInteger)replaceAll:(NSString *)find with:(NSString *)repl {
    NSData *f = [find dataUsingEncoding:NSUTF8StringEncoding];
    NSData *r = [repl dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    if (!f.length) return 0;
    NSUInteger count = 0, caret = _caret;
    PTUnicodeIndex *ui = [self unicodeIndexFor:find];
    NSArray *hits = ui ? [ui allMatches:find] : nil;
    if (ui) count = hits.count;
    NSData *out = ui ? (count ? [_buf dataReplacingRanges:hits with:r offset:&caret] : nil)
                     : [_buf dataReplacingAll:f with:r count:&count offset:&caret];
    if (!count) return 0;
    EditGroup *g = [EditGroup new];
    g.ops = [NSMutableArray array];
    g.caretBefore = _caret;
    g.kind = GroupOther;
    g.swapBuffer = [[PieceTable alloc] initWithData:out];
    [self applyGroup:g inverse:NO];                    // g.swapBuffer now holds the text before
    g.serial = ++_serial;
    _caret = _anchor = MIN(caret, _buf.length);
    g.caretAfter = _caret;
    [self pushUndo:g];
    [_redo removeAllObjects];
    _coalesceBroken = YES;
    [self scrollCaretVisible];
    [self notifyChange];
    return count;
}

@end

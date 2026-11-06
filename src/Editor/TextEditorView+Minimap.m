#import "TextEditorView+Private.h"

// Each source line is a 2 pt strip; each character a 1 pt block coloured by token kind.
static const CGFloat kMapLine = 2, kMapChar = 1, kMapWidth = 96, kMinEditorWidth = 360;
static const NSUInteger kMapCols = 120, kMapReadBytes = 512, kMapCacheMax = 4000;

typedef struct { uint16_t col, len; uint8_t kind; } MapRun;

static BOOL isWide(unichar c) {
    return c >= 0x1100 && (c <= 0x115F || (c >= 0x2E80 && c <= 0xA4CF) || (c >= 0xAC00 && c <= 0xD7A3) ||
                           (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE30 && c <= 0xFE4F) || (c >= 0xFF00 && c <= 0xFF60) ||
                           (c >= 0xFFE0 && c <= 0xFFE6));
}

@implementation TextEditorView (Minimap)

- (CGFloat)minimapWidth {
    if (!_showsMinimap || self.bounds.size.width - self.gutterWidth < kMinEditorWidth) return 0;
    return kMapWidth;
}

- (CGFloat)rightInset { return [CanvasView indicatorWidth] + self.minimapWidth; }

- (NSRect)minimapRect {
    CGFloat w = self.minimapWidth;
    return NSMakeRect(self.bounds.size.width - [CanvasView indicatorWidth] - w, 0, w, self.bounds.size.height);
}

#pragma mark Geometry

// The map has one strip per logical line, also when the editor wraps; positions go through
// lineAtY: / yForLine: so wrapped rows don't skew the slider.
- (CGFloat)mapContentHeight { return _buf.lineCount * kMapLine; }
- (CGFloat)topLine { return MAX(0, [self lineAtY:self.scrollY]); }
- (CGFloat)maxTopLine { return MAX(0, [self lineAtY:self.maxScrollY]); }
- (CGFloat)sliderHeight {
    CGFloat lines = [self lineAtY:self.scrollY + self.bounds.size.height] - [self lineAtY:self.scrollY];
    return MIN(self.bounds.size.height, MAX(kMapLine, lines * kMapLine));
}
- (BOOL)mapScrolls { return self.mapContentHeight > self.bounds.size.height; }
- (CGFloat)scrollRatio { CGFloat m = self.maxTopLine; return m > 0 ? MIN(1, self.topLine / m) : 0; }

// Offset of map line 0 above the top of the view.
- (CGFloat)mapTop { return self.mapScrolls ? self.scrollRatio * (self.mapContentHeight - self.bounds.size.height) : 0; }

- (NSRect)minimapSliderRect {
    NSRect m = self.minimapRect;
    CGFloat sh = self.sliderHeight, y;
    if (self.mapScrolls) y = self.scrollRatio * (m.size.height - sh);
    else y = self.topLine * kMapLine;
    y = MIN(MAX(0, y), MAX(0, m.size.height - sh));
    return NSMakeRect(m.origin.x, y, m.size.width, sh);
}

// Scrolls the editor so the slider's top lands at y.
- (void)scrollSliderTo:(CGFloat)y {
    CGFloat h = self.bounds.size.height, sh = self.sliderHeight;
    if (self.mapScrolls) {
        CGFloat ratio = h - sh > 0 ? MIN(MAX(0, y / (h - sh)), 1) : 0;
        if (ratio >= 1) self.scrollY = self.maxScrollY;
        else [self scrollToLine:ratio * self.maxTopLine];
    } else [self scrollToLine:MAX(0, y) / kMapLine];
}

#pragma mark Mouse

- (BOOL)minimapPressAt:(NSPoint)p {
    if (!NSPointInRect(p, self.minimapRect)) return NO;
    NSRect s = self.minimapSliderRect;
    if (!NSPointInRect(p, s)) {
        // jump: centre the clicked line, then keep dragging from the slider's middle
        CGFloat line = (p.y + self.mapTop) / kMapLine;
        self.scrollY = [self yForLine:line] - self.bounds.size.height / 2;
        s = self.minimapSliderRect;
    }
    _mapGrab = MIN(MAX(0, p.y - s.origin.y), s.size.height);
    _mapDragging = YES;
    self.needsDisplay = YES;
    return YES;
}

- (void)minimapDragTo:(NSPoint)p {
    [self scrollSliderTo:p.y - _mapGrab];
}

#pragma mark Drawing

// Packed colour runs for one line, cached until the next edit.
- (NSData *)runsForLine:(NSUInteger)L {
    NSNumber *key = @(L);
    NSData *cached = _mapCache[key];
    if (cached) return cached;
    NSUInteger s = [_buf lineStart:L], e = [_buf lineEnd:L], n = MIN(e - s, kMapReadBytes);
    NSData *raw = [_buf dataInRange:NSMakeRange(s, n)];
    const uint8_t *b = raw.bytes;
    while (n > 0 && n < e - s && (b[n] & 0xC0) == 0x80) n--;
    NSString *str = [[NSString alloc] initWithBytes:b length:n encoding:NSUTF8StringEncoding] ?: @"";
    NSUInteger len = str.length;
    uint8_t *kinds = calloc(MAX(len, (NSUInteger)1), 1);
    if (_hl) [_hl tokenize:str emit:^(NSRange r, TokenKind k) { memset(kinds + r.location, k, MIN(r.length, len - r.location)); }];
    NSMutableData *out = [NSMutableData data];
    MapRun cur = {0, 0, 0};
    NSUInteger col = 0;
    for (NSUInteger i = 0; i < len && col < kMapCols; i++) {
        unichar c = [str characterAtIndex:i];
        if (CFStringIsSurrogateLowCharacter(c)) continue;
        NSUInteger w = c == '\t' ? 4 - col % 4 : (isWide(c) || CFStringIsSurrogateHighCharacter(c)) ? 2 : 1;
        BOOL blank = c == ' ' || c == '\t';
        if (blank || kinds[i] != cur.kind || col != cur.col + cur.len) {
            if (cur.len) [out appendBytes:&cur length:sizeof cur];
            cur = (MapRun){(uint16_t)col, 0, kinds[i]};
        }
        if (!blank) cur.len += w;
        col += w;
    }
    if (cur.len) [out appendBytes:&cur length:sizeof cur];
    free(kinds);
    if (_mapCache.count > kMapCacheMax) [_mapCache removeAllObjects];
    _mapCache[key] = out;
    return out;
}

static NSColor *runColor(TokenKind k) { return k == TokPlain ? NSColor.secondaryLabelColor : HLColor(k); }

// Fills one colour's batch of rects in a single call.
static void flushBucket(CGContextRef cg, NSUInteger k, CGRect *rects, NSUInteger *count) {
    if (!*count) return;
    CGContextSetFillColorWithColor(cg, [runColor((TokenKind)k) colorWithAlphaComponent:0.75].CGColor);
    CGContextFillRects(cg, rects, *count);
    *count = 0;
}

- (void)drawMinimap {
    NSRect m = self.minimapRect;
    if (NSIsEmptyRect(m)) return;
    if (!_mapCache) _mapCache = [NSMutableDictionary dictionary];
    if (_mapCacheEdit != _editCount) { [_mapCache removeAllObjects]; _mapCacheEdit = _editCount; }
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(m);
    [NSColor.separatorColor setFill];
    NSRectFillUsingOperation(NSMakeRect(m.origin.x, 0, 1, m.size.height), NSCompositingOperationSourceOver);

    CGFloat top = self.mapTop, x0 = m.origin.x + 6;
    NSUInteger first = (NSUInteger)MAX(0, floor(top / kMapLine));
    NSUInteger last = MIN(_buf.lineCount, (NSUInteger)ceil((top + m.size.height) / kMapLine) + 1);

    NSRange sel = self.selection;
    if (sel.length) {
        NSUInteger a = [_buf lineForOffset:sel.location], b = [_buf lineForOffset:NSMaxRange(sel)];
        [[NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.8] setFill];
        NSRectFillUsingOperation(NSIntersectionRect(m, NSMakeRect(m.origin.x, a * kMapLine - top, m.size.width, (b - a + 1) * kMapLine)),
                                 NSCompositingOperationSourceOver);
    }

    const NSUInteger kinds = TokKindCount, cap = 2048;
    CGRect *buckets[TokKindCount] = {0};                    // allocated on first use: most files use a few kinds
    NSUInteger counts[TokKindCount] = {0};
    for (NSUInteger L = first; L < last; L++) {
        NSData *d = [self runsForLine:L];
        const MapRun *r = d.bytes;
        CGFloat y = L * kMapLine - top;
        for (NSUInteger i = 0; i < d.length / sizeof(MapRun); i++) {
            NSUInteger k = MIN(r[i].kind, (uint8_t)(TokKindCount - 1));
            CGFloat w = MIN(r[i].len * kMapChar, NSMaxX(m) - 4 - (x0 + r[i].col * kMapChar));
            if (w <= 0) continue;
            if (!buckets[k]) buckets[k] = malloc(cap * sizeof(CGRect));
            buckets[k][counts[k]++] = CGRectMake(x0 + r[i].col * kMapChar, y, w, kMapLine * 0.75);
            if (counts[k] == cap) flushBucket(cg, k, buckets[k], &counts[k]);
        }
    }
    for (NSUInteger k = 0; k < kinds; k++) if (buckets[k]) { flushBucket(cg, k, buckets[k], &counts[k]); free(buckets[k]); }

    NSUInteger caretLine = [_buf lineForOffset:_caret];
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.7] setFill];
    NSRectFillUsingOperation(NSIntersectionRect(m, NSMakeRect(m.origin.x + 1, caretLine * kMapLine - top, m.size.width - 1, kMapLine)),
                             NSCompositingOperationSourceOver);

    NSRect s = self.minimapSliderRect;
    [[NSColor.labelColor colorWithAlphaComponent:_mapDragging ? 0.16 : 0.08] setFill];
    NSRectFillUsingOperation(NSMakeRect(s.origin.x + 1, s.origin.y, s.size.width - 1, s.size.height), NSCompositingOperationSourceOver);
}

@end

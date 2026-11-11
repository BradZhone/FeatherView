#import "TextEditorView+Private.h"
#import "FileKind.h"
#import "Localization.h"

@implementation TextEditorView
@synthesize path = _path, encoding = _encoding;
@dynamic cursorCount, pasteboard;

static CGFloat gDefaultFontSize = 13;
+ (CGFloat)defaultFontSize { return gDefaultFontSize; }
+ (void)setDefaultFontSize:(CGFloat)s { gDefaultFontSize = MIN(MAX(s, 8), 40); }
BOOL FTEditorAutoClose = YES;
+ (BOOL)autoCloseBrackets { return FTEditorAutoClose; }
+ (void)setAutoCloseBrackets:(BOOL)on { FTEditorAutoClose = on; }
static BOOL gIndentGuides = YES, gShowWhitespace = NO;
+ (BOOL)showsIndentGuides { return gIndentGuides; }
+ (void)setShowsIndentGuides:(BOOL)on { gIndentGuides = on; }
+ (BOOL)showsWhitespace { return gShowWhitespace; }
+ (void)setShowsWhitespace:(BOOL)on { gShowWhitespace = on; }

- (instancetype)initWithFrame:(NSRect)frame buffer:(PieceTable *)buffer
                         path:(NSString *)path encoding:(NSStringEncoding)encoding {
    if (!(self = [super initWithFrame:frame])) return nil;
    _buf = buffer;
    _path = [path copy];
    _encoding = encoding;
    _desiredX = -1;
    _pendingTop = -1;
    [self applyFontSize:gDefaultFontSize];
    _hl = [Highlighter highlighterForPath:path];
    _undo = [NSMutableArray array];
    _redo = [NSMutableArray array];

    uint8_t probe[65536];
    NSUInteger n = [_buf read:NSMakeRange(0, sizeof probe) into:probe];
    _indentWidth = detectIndentWidth(probe, n);
    _indentUnit = memchr(probe, '\t', n) ? @"\t" : [@"        " substringToIndex:_indentWidth];
    return self;
}

// Spaces per indentation level: the most common step between the indentation of consecutive lines.
static NSUInteger detectIndentWidth(const uint8_t *b, NSUInteger n) {
    NSUInteger votes[9] = {0}, prev = 0;
    for (NSUInteger i = 0; i < n;) {
        NSUInteger sp = 0;
        while (i + sp < n && b[i + sp] == ' ') sp++;
        NSUInteger j = i + sp;
        BOOL blank = j >= n || b[j] == '\n' || b[j] == '\r';
        BOOL tab = j < n && b[j] == '\t';
        if (!blank && !tab) {
            NSUInteger d = sp > prev ? sp - prev : 0;
            if (d == 2 || d == 4 || d == 8) votes[d]++;
            prev = sp;
        }
        const uint8_t *nl = memchr(b + j, '\n', n - MIN(j, n));
        if (!nl) break;
        i = (NSUInteger)(nl - b) + 1;
    }
    if (votes[2] > votes[4] && votes[2] >= votes[8]) return 2;
    if (votes[8] > votes[4] && votes[8] > votes[2]) return 8;
    return 4;
}

- (void)dealloc {
    if (_font) CFRelease(_font);
    if (_italicFont) CFRelease(_italicFont);
    if (_boldFont) CFRelease(_boldFont);
    if (_paraStyle) CFRelease(_paraStyle);
    free(_rowStart);
}

// Same face with a trait, or NULL if it would change the column grid.
static CTFontRef variant(CTFontRef base, CTFontSymbolicTraits trait, CGFloat charWidth) {
    CTFontRef f = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, trait, trait);
    if (!f) return NULL;
    UniChar ch[] = {'M', 'i', 'W', '.'};
    CGGlyph g[4]; CGSize adv[4];
    CTFontGetGlyphsForCharacters(f, ch, g, 4);
    CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, g, adv, 4);
    for (int k = 0; k < 4; k++) if (fabs(adv[k].width - charWidth) > 0.01) { CFRelease(f); return NULL; }
    return f;
}

- (void)applyFontSize:(CGFloat)size {
    if (_font) CFRelease(_font);
    NSFont *mono = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    _font = mono ? (CTFontRef)CFBridgingRetain(mono) : CTFontCreateWithName(CFSTR("Menlo"), size, NULL);
    _ascent = ceil(CTFontGetAscent(_font));
    _lineHeight = ceil(_ascent + CTFontGetDescent(_font) + CTFontGetLeading(_font)) + 3;
    UniChar ch = 'M'; CGGlyph g; CGSize adv;
    CTFontGetGlyphsForCharacters(_font, &ch, &g, 1);
    CTFontGetAdvancesForGlyphs(_font, kCTFontOrientationHorizontal, &g, &adv, 1);
    _charWidth = adv.width;
    _widestLine = 0;
    if (_italicFont) CFRelease(_italicFont);
    if (_boldFont) CFRelease(_boldFont);
    _italicFont = variant(_font, kCTFontItalicTrait, _charWidth);
    _boldFont = variant(_font, kCTFontBoldTrait, _charWidth);

    // tabs every 4 columns (CoreText's default interval isn't a multiple of the advance)
    if (_paraStyle) CFRelease(_paraStyle);
    CGFloat interval = 4 * _charWidth;
    CFArrayRef noStops = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CTParagraphStyleSetting set[] = {
        {kCTParagraphStyleSpecifierTabStops, sizeof(CFArrayRef), &noStops},
        {kCTParagraphStyleSpecifierDefaultTabInterval, sizeof(CGFloat), &interval}};
    _paraStyle = CTParagraphStyleCreate(set, 2);
    CFRelease(noStops);
    [_advances removeAllObjects];
}

- (CGFloat)fontSize { return CTFontGetSize(_font); }

- (void)setFontSize:(CGFloat)size {
    size = MIN(MAX(size, 8), 40);
    if (fabs(size - self.fontSize) < 0.01) return;
    [self changeLayout:^{ [self applyFontSize:size]; }];          // keeps the same line at the top
}

- (BOOL)wordWrap { return _wordWrap; }
- (void)setWordWrap:(BOOL)w {
    if (w == _wordWrap) return;
    [self changeLayout:^{ self->_wordWrap = w; self->_widestLine = 0; }];
    [self notifyChange];
}

- (BOOL)wrapsLines { return self.wrapsText; }

// Every scroll / resize path ends here: rebuild the row table for the new width first.
- (void)clampScroll {
    [self ensureWrap];
    [super clampScroll];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }

- (CGFloat)contentHeight { return (self.rowCount + 3) * _lineHeight + 8; }
- (CGFloat)maxScrollX {
    if (self.wrapsText) return 0;
    CGFloat avail = self.bounds.size.width - self.gutterWidth - self.rightInset - 16;
    return MAX(0, _widestLine - avail);
}

- (BOOL)showsMinimap { return _showsMinimap; }
- (void)setShowsMinimap:(BOOL)s {
    if (s == _showsMinimap) return;
    [self changeLayout:^{ self->_showsMinimap = s; }];            // the text width changes
}

- (BOOL)isDirty {
    NSUInteger top = _undo.count ? _undo.lastObject.serial : 0;
    return top != _savedSerial;
}

- (void)resetCursorRects {
    NSRect r = self.bounds;
    r.size.width -= self.rightInset;
    [self addCursorRect:r cursor:NSCursor.IBeamCursor];
    if (self.minimapWidth) [self addCursorRect:self.minimapRect cursor:NSCursor.arrowCursor];
}

static CGColorRef tokenColor(TokenKind k) { return HLColor(k).CGColor; }

// What one cursor contributes to a line, as UTF-16 indices into the drawn string.
typedef struct { NSUInteger su, eu; BOOL nl; NSUInteger caret; } Span;

static inline BOOL wordUnit(unichar c) { return c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'z'); }

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(dirty);

    CGFloat gutter = self.gutterWidth, x0 = self.textOriginX;
    BOOL table = self.wrapOn, wrap = table && _wrapText;
    NSUInteger rows = self.rowCount;
    NSUInteger firstRow = (NSUInteger)MAX(0, floor((self.scrollY + NSMinY(dirty) - 4) / _lineHeight));
    NSUInteger lastRow = MIN(rows, (NSUInteger)ceil((self.scrollY + NSMaxY(dirty) - 4) / _lineHeight) + 1);
    NSUInteger first = firstRow < rows ? [self lineOfRow:firstRow] : _buf.lineCount;
    NSUInteger last = lastRow > firstRow ? [self lineOfRow:lastRow - 1] + 1 : first;
    NSUInteger caretLine = [_buf lineForOffset:_caret];
    BOOL focused = self.window.firstResponder == self && self.window.isKeyWindow;
    BOOL healed = NO;
    CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));

    NSUInteger primary = 0;
    NSData *curData = _extra.length ? [self cursors:&primary] : nil;
    Sel one = {_anchor, _caret, _desiredX};
    const Sel *cur = curData ? curData.bytes : &one;
    NSUInteger ncur = curData ? curData.length / sizeof(Sel) : 1;
    [self updateBracketPair];
    BOOL wholeWord = NO;
    NSString *word = focused || ncur > 1 ? [self highlightedWord:&wholeWord] : nil;
    NSColor *selColor = focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor;
    NSColor *lineColor = [NSColor.labelColor colorWithAlphaComponent:0.045];
    NSColor *wordColor = [NSColor.systemGrayColor colorWithAlphaComponent:0.22];
    NSColor *bracketColor = [NSColor.systemGrayColor colorWithAlphaComponent:0.35];
    CGFloat fullWidth = self.bounds.size.width;
    NSMutableData *spanData = [NSMutableData data];
    NSColor *guideColor = [NSColor.labelColor colorWithAlphaComponent:0.12];
    NSColor *spaceColor = NSColor.tertiaryLabelColor;
    NSUInteger unit = MAX(_indentWidth, (NSUInteger)1), lines = _buf.lineCount;
    CGFloat leftX = gutter, rightX = fullWidth - self.minimapWidth;

    CGContextSaveGState(cg);
    CGContextClipToRect(cg, NSMakeRect(gutter, NSMinY(dirty), self.bounds.size.width - gutter - self.minimapWidth, NSHeight(dirty)));
    for (NSUInteger L = first; L < last; L++) {
        if (_hidden.length) {                            // skip folded lines
            NSRange h = [self hiddenRangeAt:L];
            if (h.location != NSNotFound) { L = NSMaxRange(h) - 1; continue; }
        }
        BOOL folded = _folds.length && [self lineFolded:L];
        NSUInteger row0 = [self firstRowOfLine:L];
        NSString *s = [self lineString:L];
        NSUInteger markAt = NSNotFound;
        if (_markedText.length && L == caretLine) {
            markAt = MIN([self utf16Index:_caret inLine:L], s.length);
            s = [NSString stringWithFormat:@"%@%@%@", [s substringToIndex:markAt], _markedText, [s substringFromIndex:markAt]];
        }
        NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:s attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font,
            (id)kCTParagraphStyleAttributeName: (__bridge id)_paraStyle,
            (id)kCTForegroundColorAttributeName: (__bridge id)tokenColor(TokPlain)}];
        CTFontRef italic = _italicFont, bold = _boldFont, regular = _font;
        if (_hl) [_hl tokenize:s emit:^(NSRange r, TokenKind k) {
            [as addAttribute:(id)kCTForegroundColorAttributeName value:(__bridge id)tokenColor(k) range:r];
            CTFontRef f = HLIsItalic(k) ? italic : HLIsBold(k) ? bold : regular;
            if (f) [as addAttribute:(id)kCTFontAttributeName value:(__bridge id)f range:r];
        }];
        if (markAt != NSNotFound)
            [as addAttribute:(id)kCTUnderlineStyleAttributeName value:@(kCTUnderlineStyleSingle)
                       range:NSMakeRange(markAt, _markedText.length)];

        WrapRows wr = [self rowsOf:s];
        // indent guides: one at the start of each level inside the indentation; a blank line takes the deeper
        // of its neighbours, so guides run through the gaps in a block
        NSUInteger guides = 0;
        if (gIndentGuides) {
            BOOL blank;
            NSUInteger ind = [self indentColumns:L blank:&blank];
            if (blank) {
                NSUInteger up = 0, down = 0;
                for (NSUInteger j = L; j-- > 0 && j + 100 > L;) { NSUInteger i = [self indentColumns:j blank:&blank]; if (!blank) { up = i; break; } }
                for (NSUInteger j = L + 1; j < lines && j < L + 100; j++) { NSUInteger i = [self indentColumns:j blank:&blank]; if (!blank) { down = i; break; } }
                ind = MAX(up, down);
            }
            guides = (ind + unit - 1) / unit;
        }
        if (wrap && !folded && wr.count != [self firstRowOfLine:L + 1] - row0) {
            // the table's estimate was off (unusual glyphs): fix it and draw again
            [self refreshRowsOfLine:L];
            healed = YES;
        }
        CTTypesetterRef ts = wr.count > 1 ? CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)as) : NULL;
        NSUInteger ls = [_buf lineStart:L], le = [_buf lineEnd:L];
        NSUInteger (^u16)(NSUInteger) = ^NSUInteger(NSUInteger off) {
            NSUInteger u = [self utf16Index:off inLine:L];
            return markAt != NSNotFound && u > markAt ? u + self->_markedText.length : u;
        };

        // the cursors on this line (sorted, so a binary search finds the first)
        spanData.length = 0;
        BOOL caretHere = NO;
        NSUInteger lo = 0, hi = ncur;
        while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (SelEnd(cur[mid]) < ls) lo = mid + 1; else hi = mid; }
        for (NSUInteger i = lo; i < ncur && SelStart(cur[i]) <= le; i++) {
            Sel c = cur[i];
            Span sp = {NSNotFound, 0, NO, NSNotFound};
            NSUInteger a = SelStart(c), b = SelEnd(c);
            if (a < b && a <= le && b > ls) {
                sp.su = u16(MAX(a, ls)); sp.eu = u16(MIN(b, le)); sp.nl = b > le;
            }
            if (focused && c.caret >= ls && c.caret <= le) {
                BOOL isPrimary = curData ? i == primary : YES;
                sp.caret = isPrimary && markAt != NSNotFound ? markAt + _markedSel.location : u16(c.caret);
                if (a == b) caretHere = YES;
            }
            if (sp.su != NSNotFound || sp.caret != NSNotFound) [spanData appendBytes:&sp length:sizeof sp];
        }
        const Span *spans = spanData.bytes;
        NSUInteger nspan = spanData.length / sizeof(Span);
        NSUInteger brk[2] = {NSNotFound, NSNotFound};
        for (int k = 0; k < 2; k++)
            if (_bracketPair[k] != NSNotFound && _bracketPair[k] >= ls && _bracketPair[k] < le) brk[k] = u16(_bracketPair[k]);
        NSMutableData *hits = nil;                      // other occurrences of the word, UTF-16 ranges
        if (word.length && s.length >= word.length) {
            hits = [NSMutableData data];
            NSRange in = NSMakeRange(0, s.length);
            while (in.length) {
                NSRange r = [s rangeOfString:word options:NSLiteralSearch range:in];
                if (r.location == NSNotFound) break;
                BOOL ok = !wholeWord || ((r.location == 0 || !wordUnit([s characterAtIndex:r.location - 1])) &&
                                         (NSMaxRange(r) >= s.length || !wordUnit([s characterAtIndex:NSMaxRange(r)])));
                if (ok) [hits appendBytes:&r length:sizeof r];
                in = NSMakeRange(NSMaxRange(r), s.length - NSMaxRange(r));
            }
        }

        for (NSUInteger k = 0; k < wr.count; k++) {
            NSUInteger a = k ? wr.starts[k] : 0, b = k + 1 < wr.count ? wr.starts[k + 1] : s.length;
            CGFloat top = 4 + (row0 + k) * _lineHeight - self.scrollY;
            if (top + _lineHeight < NSMinY(dirty) || top > NSMaxY(dirty)) continue;
            CGFloat rx = x0 + (k ? wr.indent : 0);
            CTLineRef line = ts ? CTTypesetterCreateLine(ts, CFRangeMake(a, b - a))
                                : CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
            BOOL lastRowOfLine = k + 1 == wr.count;
            if (caretHere) {
                [lineColor setFill];
                NSRectFillUsingOperation(NSMakeRect(gutter, top, fullWidth - gutter, _lineHeight), NSCompositingOperationSourceOver);
            }
            const NSRange *hr = hits.bytes;
            for (NSUInteger h = 0; h < hits.length / sizeof(NSRange); h++) {
                NSUInteger p = MAX(hr[h].location, a), q = MIN(NSMaxRange(hr[h]), b);
                if (p >= q) continue;
                CGFloat xa = CTLineGetOffsetForStringIndex(line, p, NULL), xb = CTLineGetOffsetForStringIndex(line, q, NULL);
                [wordColor setFill];
                NSRectFillUsingOperation(NSMakeRect(rx + xa, top + 1, xb - xa, _lineHeight - 2), NSCompositingOperationSourceOver);
            }
            for (NSUInteger j = 0; j < nspan; j++) {
                if (spans[j].su == NSNotFound) continue;
                NSUInteger p = MAX(spans[j].su, a), q = MIN(spans[j].eu, b);
                BOOL nl = spans[j].nl;
                if (p < q || (p == q && lastRowOfLine && nl && p >= a)) {
                    CGFloat xa = CTLineGetOffsetForStringIndex(line, p, NULL);
                    CGFloat xb = CTLineGetOffsetForStringIndex(line, q, NULL);
                    if (lastRowOfLine && nl) xb += _charWidth * 0.6;          // newline is selected
                    [selColor setFill];
                    NSRectFill(NSMakeRect(rx + xa, top, MAX(1, xb - xa), _lineHeight));
                }
            }
            if (guides) {
                [guideColor setFill];
                for (NSUInteger g = 0; g < guides; g++) {
                    CGFloat gx = floor(x0 + g * unit * _charWidth) + 0.5;
                    if (gx >= leftX) NSRectFillUsingOperation(NSMakeRect(gx, top, 1, _lineHeight), NSCompositingOperationSourceOver);
                }
            }
            if (gShowWhitespace) {
                // only the characters in view: a long line has many
                CFIndex from = CTLineGetStringIndexForPosition(line, CGPointMake(leftX - rx, 0));
                CFIndex to = CTLineGetStringIndexForPosition(line, CGPointMake(rightX - rx, 0));
                NSUInteger p0 = from == kCFNotFound ? a : MAX(a, (NSUInteger)MAX(0, from - 1));
                NSUInteger p1 = to == kCFNotFound ? b : MIN(b, (NSUInteger)to + 1);
                [spaceColor setFill];
                for (NSUInteger i = p0; i < p1; i++) {
                    unichar ch = [s characterAtIndex:i];
                    if (ch != ' ' && ch != '\t') continue;
                    CGFloat xa = CTLineGetOffsetForStringIndex(line, i, NULL), xb = CTLineGetOffsetForStringIndex(line, i + 1, NULL);
                    CGFloat cy = top + _lineHeight / 2;
                    if (ch == ' ') {
                        CGFloat d = MAX(1.5, _charWidth * 0.18);
                        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(rx + (xa + xb) / 2 - d / 2, cy - d / 2, d, d)] fill];
                    } else {
                        CGFloat ax = rx + xa + 2, bx = rx + MAX(xa + _charWidth, xb) - 2, h = MIN(3.0, _lineHeight / 5);
                        NSBezierPath *arrow = [NSBezierPath bezierPath];
                        [arrow moveToPoint:NSMakePoint(ax, cy)]; [arrow lineToPoint:NSMakePoint(bx, cy)];
                        [arrow moveToPoint:NSMakePoint(bx - h, cy - h)]; [arrow lineToPoint:NSMakePoint(bx, cy)]; [arrow lineToPoint:NSMakePoint(bx - h, cy + h)];
                        arrow.lineWidth = 1;
                        [spaceColor setStroke];
                        [arrow stroke];
                    }
                }
            }
            CGContextSetTextPosition(cg, rx, top + _ascent + 1);
            CTLineDraw(line, cg);
            if (folded && lastRowOfLine) {                // ⋯ after a folded line
                CGFloat ex = rx + CTLineGetTypographicBounds(line, NULL, NULL, NULL) + 6;
                NSRect box = NSMakeRect(ex, top + 2, ceil(2.6 * _charWidth), _lineHeight - 4);
                [[NSColor.systemGrayColor colorWithAlphaComponent:0.25] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
                NSAttributedString *dots = [[NSAttributedString alloc] initWithString:@"⋯" attributes:@{
                    (id)kCTFontAttributeName: (__bridge id)_font, (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.secondaryLabelColor.CGColor}];
                CTLineRef dl = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)dots);
                CGFloat dw = CTLineGetTypographicBounds(dl, NULL, NULL, NULL);
                CGContextSetTextPosition(cg, NSMidX(box) - dw / 2, top + _ascent + 1);
                CTLineDraw(dl, cg);
                CFRelease(dl);
            }
            if (!wrap) _widestLine = MAX(_widestLine, CTLineGetTypographicBounds(line, NULL, NULL, NULL));
            for (int m = 0; m < 2; m++) {
                if (brk[m] == NSNotFound || brk[m] < a || brk[m] >= b) continue;
                CGFloat xa = CTLineGetOffsetForStringIndex(line, brk[m], NULL), xb = CTLineGetOffsetForStringIndex(line, brk[m] + 1, NULL);
                [bracketColor setFill];
                NSFrameRectWithWidthUsingOperation(NSMakeRect(rx + xa, top + 1, MAX(1, xb - xa), _lineHeight - 2), 1, NSCompositingOperationSourceOver);
            }
            for (NSUInteger j = 0; j < nspan; j++) {
                NSUInteger cu = spans[j].caret;
                if (cu == NSNotFound || cu < a || !(cu < b || lastRowOfLine)) continue;
                CGFloat cx = CTLineGetOffsetForStringIndex(line, cu, NULL);
                [NSColor.controlAccentColor setFill];
                NSRectFill(NSMakeRect(floor(rx + cx), top, 2, _lineHeight));
            }
            CFRelease(line);
        }
        if (ts) CFRelease(ts);
        free(wr.starts);
    }
    CGContextRestoreGState(cg);
    [self drawGutterFrom:first to:last caretLine:caretLine dirty:dirty];
    [self drawMinimap];
    [self drawScrollIndicator];
    if (healed) dispatch_async(dispatch_get_main_queue(), ^{ [self clampScroll]; self.needsDisplay = YES; });
}

- (void)drawGutterFrom:(NSUInteger)first to:(NSUInteger)last caretLine:(NSUInteger)caretLine dirty:(NSRect)dirty {
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGFloat g = self.gutterWidth;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSMakeRect(0, NSMinY(dirty), g, NSHeight(dirty)));
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(g - 1, NSMinY(dirty), 1, NSHeight(dirty)));
    BOOL hover = _gutterHover;
    CGFloat cs = MIN(9.0, _lineHeight * 0.45);
    for (NSUInteger L = first; L < last; L++) {          // number on the first row of each line only
        if (_hidden.length) {
            NSRange h = [self hiddenRangeAt:L];
            if (h.location != NSNotFound) { L = NSMaxRange(h) - 1; continue; }
        }
        CGFloat top = 4 + [self firstRowOfLine:L] * _lineHeight - self.scrollY;
        BOOL folded = _folds.length && [self lineFolded:L];
        if (folded || (hover && [self startsRegion:L])) {     // fold control
            CGFloat cx = g - 9, cy = top + _lineHeight / 2;
            NSBezierPath *p = [NSBezierPath bezierPath];
            if (folded) { [p moveToPoint:NSMakePoint(cx - cs / 4, cy - cs / 2)]; [p lineToPoint:NSMakePoint(cx + cs / 4, cy)]; [p lineToPoint:NSMakePoint(cx - cs / 4, cy + cs / 2)]; }
            else { [p moveToPoint:NSMakePoint(cx - cs / 2, cy - cs / 4)]; [p lineToPoint:NSMakePoint(cx, cy + cs / 4)]; [p lineToPoint:NSMakePoint(cx + cs / 2, cy - cs / 4)]; }
            p.lineWidth = 1.5; p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
            [(folded ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor) setStroke];
            [p stroke];
        }
        NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)L + 1];
        CGColorRef c = (L == caretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor).CGColor;
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:num attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font, (id)kCTForegroundColorAttributeName: (__bridge id)c}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CGContextSetTextPosition(cg, g - 18 - w, top + _ascent + 1);
        CTLineDraw(line, cg);
        CFRelease(line);
    }
}

// Accessibility: expose as a text area with the current line as its value.
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (NSString *)accessibilityLabel { return _path.lastPathComponent; }
// VoiceOver sees the caret's line as the text (a whole large file would be too much to hand over).
- (id)accessibilityValue { return [self lineString:[_buf lineForOffset:_caret]]; }
- (NSInteger)accessibilityNumberOfCharacters { return (NSInteger)[self.accessibilityValue length]; }
- (NSInteger)accessibilityInsertionPointLineNumber { return (NSInteger)[_buf lineForOffset:_caret]; }
- (NSString *)accessibilitySelectedText { return self.selection.length <= 65536 ? self.selectedText : nil; }
- (NSRange)accessibilitySelectedTextRange {
    NSUInteger L = [_buf lineForOffset:_caret];
    NSRange sel = self.selection;
    NSUInteger a = [self utf16Index:MAX(sel.location, [_buf lineStart:L]) inLine:L], b = [self utf16Index:MIN(NSMaxRange(sel), [_buf lineEnd:L]) inLine:L];
    return NSMakeRange(a, b >= a ? b - a : 0);
}
- (NSString *)accessibilityRoleDescription { return FTL(@"text editor"); }

- (NSUInteger)caretLine { return [_buf lineForOffset:_caret] + 1; }

- (NSString *)statusText {
    NSUInteger L = [_buf lineForOffset:_caret];
    NSUInteger col = [self utf16Index:_caret inLine:L] + 1;
    NSString *enc = FKEncodingName(_encoding);
    NSMutableString *s = [NSMutableString stringWithFormat:FTL(@"Ln %lu, Col %lu   %@   %@"),
                          (unsigned long)L + 1, (unsigned long)col, enc, _buf.usesCRLF ? @"CRLF" : @"LF"];
    NSRange sel = self.selection;
    NSUInteger n = self.cursorCount;
    if (n > 1) [s appendFormat:FTLP(n, @"   %lu selection", @"   %lu selections"), (unsigned long)n];
    else if (sel.length) [s appendFormat:FTLP(sel.length, @"   %lu byte selected", @"   %lu bytes selected"), (unsigned long)sel.length];
    if (self.wrapLimited) [s appendString:FTL(@"   Large file, not wrapped")];
    return s;
}

@end

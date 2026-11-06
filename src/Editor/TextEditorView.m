#import "TextEditorView+Private.h"

@implementation EditOp @end
@implementation EditGroup @end

@implementation TextEditorView
@synthesize path = _path, encoding = _encoding;

static CGFloat gDefaultFontSize = 13;
+ (CGFloat)defaultFontSize { return gDefaultFontSize; }
+ (void)setDefaultFontSize:(CGFloat)s { gDefaultFontSize = MIN(MAX(s, 8), 40); }

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
    _indentUnit = memchr(probe, '\t', n) ? @"\t" : @"    ";
    return self;
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

- (BOOL)wrapsLines { return self.wrapOn; }

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
    if (self.wrapOn) return 0;
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

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(dirty);

    CGFloat gutter = self.gutterWidth, x0 = self.textOriginX;
    BOOL wrap = self.wrapOn;
    NSUInteger rows = self.rowCount;
    NSUInteger firstRow = (NSUInteger)MAX(0, floor((self.scrollY + NSMinY(dirty) - 4) / _lineHeight));
    NSUInteger lastRow = MIN(rows, (NSUInteger)ceil((self.scrollY + NSMaxY(dirty) - 4) / _lineHeight) + 1);
    NSUInteger first = firstRow < rows ? [self lineOfRow:firstRow] : _buf.lineCount;
    NSUInteger last = lastRow > firstRow ? [self lineOfRow:lastRow - 1] + 1 : first;
    NSRange sel = self.selection;
    NSUInteger caretLine = [_buf lineForOffset:_caret];
    BOOL focused = self.window.firstResponder == self && self.window.isKeyWindow;
    BOOL healed = NO;
    CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));

    CGContextSaveGState(cg);
    CGContextClipToRect(cg, NSMakeRect(gutter, NSMinY(dirty), self.bounds.size.width - gutter - self.minimapWidth, NSHeight(dirty)));
    for (NSUInteger L = first; L < last; L++) {
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
        if (wrap && wr.count != [self firstRowOfLine:L + 1] - row0) {
            // the table's estimate was off (unusual glyphs): fix it and draw again
            [self refreshRowsOfLine:L];
            healed = YES;
        }
        CTTypesetterRef ts = wr.count > 1 ? CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)as) : NULL;
        NSUInteger ls = [_buf lineStart:L], le = [_buf lineEnd:L];
        // selection as UTF-16 indices into s
        NSUInteger su = NSNotFound, eu = 0;
        BOOL nl = NO;
        if (sel.length && sel.location <= le && NSMaxRange(sel) > ls) {
            su = [self utf16Index:MAX(sel.location, ls) inLine:L];
            eu = [self utf16Index:MIN(NSMaxRange(sel), le) inLine:L];
            nl = NSMaxRange(sel) > le;
            if (markAt != NSNotFound) {
                if (su > markAt) su += _markedText.length;
                if (eu > markAt) eu += _markedText.length;
            }
        }
        NSUInteger caretU = NSNotFound;
        if (L == caretLine && focused)
            caretU = [self utf16Index:_caret inLine:L] + (markAt != NSNotFound ? _markedSel.location : 0);

        for (NSUInteger k = 0; k < wr.count; k++) {
            NSUInteger a = k ? wr.starts[k] : 0, b = k + 1 < wr.count ? wr.starts[k + 1] : s.length;
            CGFloat top = 4 + (row0 + k) * _lineHeight - self.scrollY;
            if (top + _lineHeight < NSMinY(dirty) || top > NSMaxY(dirty)) continue;
            CGFloat rx = x0 + (k ? wr.indent : 0);
            CTLineRef line = ts ? CTTypesetterCreateLine(ts, CFRangeMake(a, b - a))
                                : CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
            BOOL lastRowOfLine = k + 1 == wr.count;
            if (su != NSNotFound) {
                NSUInteger p = MAX(su, a), q = MIN(eu, b);
                if (p < q || (p == q && lastRowOfLine && nl && p >= a)) {
                    CGFloat xa = CTLineGetOffsetForStringIndex(line, p, NULL);
                    CGFloat xb = CTLineGetOffsetForStringIndex(line, q, NULL);
                    if (lastRowOfLine && nl) xb += _charWidth * 0.6;          // newline is selected
                    [(focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor) setFill];
                    NSRectFill(NSMakeRect(rx + xa, top, MAX(1, xb - xa), _lineHeight));
                }
            }
            CGContextSetTextPosition(cg, rx, top + _ascent + 1);
            CTLineDraw(line, cg);
            if (!wrap) _widestLine = MAX(_widestLine, CTLineGetTypographicBounds(line, NULL, NULL, NULL));
            if (caretU != NSNotFound && caretU >= a && (caretU < b || lastRowOfLine)) {
                CGFloat cx = CTLineGetOffsetForStringIndex(line, caretU, NULL);
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
    for (NSUInteger L = first; L < last; L++) {          // number on the first row of each line only
        NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)L + 1];
        CGColorRef c = (L == caretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor).CGColor;
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:num attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font, (id)kCTForegroundColorAttributeName: (__bridge id)c}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CGContextSetTextPosition(cg, g - 8 - w, 4 + [self firstRowOfLine:L] * _lineHeight - self.scrollY + _ascent + 1);
        CTLineDraw(line, cg);
        CFRelease(line);
    }
}

// Accessibility: expose as a text area with the current line as its value.
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityTextAreaRole; }
- (NSString *)accessibilityLabel { return _path.lastPathComponent; }
- (id)accessibilityValue { return [self lineString:[_buf lineForOffset:_caret]]; }

- (NSUInteger)caretLine { return [_buf lineForOffset:_caret] + 1; }

- (NSString *)statusText {
    NSUInteger L = [_buf lineForOffset:_caret];
    NSUInteger col = [self utf16Index:_caret inLine:L] + 1;
    NSString *enc = _encoding == NSUTF8StringEncoding ? @"UTF-8" :
                    _encoding == NSUTF16StringEncoding ? @"UTF-16" : @"GB18030";
    NSMutableString *s = [NSMutableString stringWithFormat:@"行 %lu，列 %lu   %@   %@",
                          (unsigned long)L + 1, (unsigned long)col, enc, _buf.usesCRLF ? @"CRLF" : @"LF"];
    NSRange sel = self.selection;
    if (sel.length) [s appendFormat:@"   已选 %lu 字节", (unsigned long)sel.length];
    if (self.wrapLimited) [s appendString:@"   文件较大，未自动换行"];
    return s;
}

@end

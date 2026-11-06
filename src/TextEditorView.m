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
    [self applyFontSize:gDefaultFontSize];
    _hl = [Highlighter highlighterForPath:path];
    _undo = [NSMutableArray array];
    _redo = [NSMutableArray array];

    uint8_t probe[65536];
    NSUInteger n = [_buf read:NSMakeRange(0, sizeof probe) into:probe];
    _indentUnit = memchr(probe, '\t', n) ? @"\t" : @"    ";
    return self;
}

- (void)dealloc { if (_font) CFRelease(_font); }

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
}

- (CGFloat)fontSize { return CTFontGetSize(_font); }

- (void)setFontSize:(CGFloat)size {
    size = MIN(MAX(size, 8), 40);
    if (fabs(size - self.fontSize) < 0.01) return;
    CGFloat topLine = (self.scrollY - 4) / _lineHeight;          // keep the same line at the top
    [self applyFontSize:size];
    self.scrollY = MAX(0, 4 + topLine * _lineHeight);
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }

- (CGFloat)contentHeight { return (_buf.lineCount + 3) * _lineHeight + 8; }
- (CGFloat)maxScrollX {
    CGFloat avail = self.bounds.size.width - self.gutterWidth - self.rightInset - 16;
    return MAX(0, _widestLine - avail);
}

- (BOOL)showsMinimap { return _showsMinimap; }
- (void)setShowsMinimap:(BOOL)s {
    if (s == _showsMinimap) return;
    _showsMinimap = s;
    [self clampScroll];
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
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

static CGColorRef tokenColor(TokenKind k) {
    switch (k) {
        case TokKeyword: return NSColor.systemPinkColor.CGColor;
        case TokString:  return NSColor.systemRedColor.CGColor;
        case TokComment: return NSColor.secondaryLabelColor.CGColor;
        case TokNumber:  return NSColor.systemOrangeColor.CGColor;
        case TokType:    return NSColor.systemTealColor.CGColor;
        default:         return NSColor.textColor.CGColor;
    }
}

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(dirty);

    CGFloat gutter = self.gutterWidth, x0 = self.textOriginX;
    NSUInteger first = (NSUInteger)MAX(0, floor((self.scrollY + NSMinY(dirty) - 4) / _lineHeight));
    NSUInteger last = MIN(_buf.lineCount, (NSUInteger)ceil((self.scrollY + NSMaxY(dirty) - 4) / _lineHeight) + 1);
    NSRange sel = self.selection;
    NSUInteger caretLine = [_buf lineForOffset:_caret];
    BOOL focused = self.window.firstResponder == self && self.window.isKeyWindow;
    CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));

    CGContextSaveGState(cg);
    CGContextClipToRect(cg, NSMakeRect(gutter, NSMinY(dirty), self.bounds.size.width - gutter - self.minimapWidth, NSHeight(dirty)));
    for (NSUInteger L = first; L < last; L++) {
        CGFloat top = 4 + L * _lineHeight - self.scrollY;
        NSString *s = [self lineString:L];
        NSUInteger markAt = NSNotFound;
        if (_markedText.length && L == caretLine) {
            markAt = [self utf16Index:_caret inLine:L];
            s = [NSString stringWithFormat:@"%@%@%@", [s substringToIndex:markAt], _markedText, [s substringFromIndex:markAt]];
        }
        NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:s attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font,
            (id)kCTForegroundColorAttributeName: (__bridge id)tokenColor(TokPlain)}];
        if (_hl) [_hl tokenize:s emit:^(NSRange r, TokenKind k) {
            [as addAttribute:(id)kCTForegroundColorAttributeName value:(__bridge id)tokenColor(k) range:r];
        }];
        if (markAt != NSNotFound)
            [as addAttribute:(id)kCTUnderlineStyleAttributeName value:@(kCTUnderlineStyleSingle)
                       range:NSMakeRange(markAt, _markedText.length)];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);

        NSUInteger ls = [_buf lineStart:L], le = [_buf lineEnd:L];
        if (sel.length && sel.location <= le && NSMaxRange(sel) > ls) {
            NSUInteger a = MAX(sel.location, ls), b = MIN(NSMaxRange(sel), le);
            CGFloat xa = CTLineGetOffsetForStringIndex(line, [self utf16Index:a inLine:L], NULL);
            CGFloat xb = CTLineGetOffsetForStringIndex(line, [self utf16Index:b inLine:L], NULL);
            if (NSMaxRange(sel) > le) xb += _charWidth * 0.6;          // newline is selected
            [(focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor) setFill];
            NSRectFill(NSMakeRect(x0 + xa, top, MAX(1, xb - xa), _lineHeight));
        }
        CGContextSetTextPosition(cg, x0, top + _ascent + 1);
        CTLineDraw(line, cg);
        _widestLine = MAX(_widestLine, CTLineGetTypographicBounds(line, NULL, NULL, NULL));
        if (L == caretLine && focused) {
            NSUInteger ci = [self utf16Index:_caret inLine:L] + (markAt != NSNotFound ? _markedSel.location : 0);
            CGFloat cx = CTLineGetOffsetForStringIndex(line, ci, NULL);
            [NSColor.controlAccentColor setFill];
            NSRectFill(NSMakeRect(floor(x0 + cx), top, 2, _lineHeight));
        }
        CFRelease(line);
    }
    CGContextRestoreGState(cg);
    [self drawGutterFrom:first to:last caretLine:caretLine dirty:dirty];
    [self drawMinimap];
    [self drawScrollIndicator];
}

- (void)drawGutterFrom:(NSUInteger)first to:(NSUInteger)last caretLine:(NSUInteger)caretLine dirty:(NSRect)dirty {
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGFloat g = self.gutterWidth;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(NSMakeRect(0, NSMinY(dirty), g, NSHeight(dirty)));
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(g - 1, NSMinY(dirty), 1, NSHeight(dirty)));
    for (NSUInteger L = first; L < last; L++) {
        NSString *num = [NSString stringWithFormat:@"%lu", (unsigned long)L + 1];
        CGColorRef c = (L == caretLine ? NSColor.labelColor : NSColor.tertiaryLabelColor).CGColor;
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:num attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font, (id)kCTForegroundColorAttributeName: (__bridge id)c}];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        CGContextSetTextPosition(cg, g - 8 - w, 4 + L * _lineHeight - self.scrollY + _ascent + 1);
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
    return s;
}

@end

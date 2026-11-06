#import "TextEditorView+Private.h"

static const NSUInteger kMaxLineBytes = 32 * 1024;   // pathological minified lines get truncated

@implementation TextEditorView (Layout)

- (CGFloat)gutterWidth {
    NSUInteger digits = 1;
    for (NSUInteger n = _buf.lineCount; n >= 10; n /= 10) digits++;
    return ceil(MAX(3, digits) * _charWidth + 20);
}

- (CGFloat)textOriginX { return self.gutterWidth + 8 - self.scrollX; }

- (NSData *)lineBytes:(NSUInteger)line {
    NSUInteger s = [_buf lineStart:line], e = [_buf lineEnd:line];
    NSUInteger n = MIN(e - s, kMaxLineBytes);
    NSData *d = [_buf dataInRange:NSMakeRange(s, n)];
    if (n < e - s) {                                 // back off to a UTF-8 boundary
        const uint8_t *b = d.bytes;
        while (n > 0 && (b[n] & 0xC0) == 0x80) n--;
        d = [d subdataWithRange:NSMakeRange(0, n)];
    }
    return d;
}

- (NSString *)lineString:(NSUInteger)line {
    NSData *d = [self lineBytes:line];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
}

- (NSUInteger)utf16Index:(NSUInteger)off inLine:(NSUInteger)line {
    NSUInteger s = [_buf lineStart:line];
    if (off <= s) return 0;
    NSData *d = [_buf dataInRange:NSMakeRange(s, MIN(off - s, kMaxLineBytes))];
    const uint8_t *b = d.bytes;
    NSUInteger u = 0;
    for (NSUInteger i = 0; i < d.length; i++) {
        uint8_t c = b[i];
        if ((c & 0xC0) == 0x80) continue;
        u += (c >= 0xF0) ? 2 : 1;
    }
    return u;
}

- (NSUInteger)byteOffsetForUTF16:(NSUInteger)idx inLine:(NSUInteger)line {
    NSData *d = [self lineBytes:line];
    const uint8_t *b = d.bytes;
    NSUInteger i = 0, u = 0;
    while (i < d.length && u < idx) {
        uint8_t c = b[i];
        NSUInteger len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        u += len == 4 ? 2 : 1;
        i += len;
    }
    return [_buf lineStart:line] + MIN(i, d.length);
}

- (CTLineRef)createLine:(NSString *)s {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s
        attributes:@{(id)kCTFontAttributeName: (__bridge id)_font}];
    return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
}

- (CGFloat)xForOffset:(NSUInteger)off {
    NSUInteger L = [_buf lineForOffset:off];
    CTLineRef line = [self createLine:[self lineString:L]];
    CGFloat x = CTLineGetOffsetForStringIndex(line, [self utf16Index:off inLine:L], NULL);
    CFRelease(line);
    return x;
}

- (NSUInteger)offsetForX:(CGFloat)x line:(NSUInteger)L {
    NSString *s = [self lineString:L];
    CTLineRef line = [self createLine:s];
    CFIndex idx = CTLineGetStringIndexForPosition(line, CGPointMake(MAX(0, x), 0));
    CFRelease(line);
    if (idx == kCFNotFound) idx = 0;
    idx = MIN((NSUInteger)idx, s.length);
    if ((NSUInteger)idx < s.length) idx = [s rangeOfComposedCharacterSequenceAtIndex:idx].location;
    return [self byteOffsetForUTF16:idx inLine:L];
}

- (NSUInteger)offsetAtPoint:(NSPoint)p {
    CGFloat y = p.y + self.scrollY - 4;
    if (y < 0) return 0;
    NSUInteger L = (NSUInteger)(y / _lineHeight);
    if (L >= _buf.lineCount) return _buf.length;
    return [self offsetForX:p.x - self.textOriginX line:L];
}

- (void)scrollCaretVisible {
    NSUInteger L = [_buf lineForOffset:_caret];
    CGFloat top = 4 + L * _lineHeight, h = self.bounds.size.height;
    if (top < self.scrollY) self.scrollY = top - _lineHeight;
    else if (top + _lineHeight > self.scrollY + h) self.scrollY = top + 2 * _lineHeight - h;

    CGFloat x = [self xForOffset:_caret];
    _widestLine = MAX(_widestLine, x + _charWidth);
    CGFloat avail = self.bounds.size.width - self.gutterWidth - self.rightInset - 16;
    if (x < self.scrollX) self.scrollX = MAX(0, x - 4 * _charWidth);
    else if (x > self.scrollX + avail) self.scrollX = x - avail + 4 * _charWidth;
}

- (NSUInteger)prevCharOffset:(NSUInteger)off {
    if (off == 0) return 0;
    NSUInteger L = [_buf lineForOffset:off], ls = [_buf lineStart:L];
    if (off == ls) return [_buf lineEnd:L - 1];            // across "\n" or "\r\n"
    NSString *s = [self lineString:L];
    NSUInteger u = [self utf16Index:off inLine:L];
    if (u == 0 || u > s.length) return MAX(ls, off - 1);
    NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:u - 1];
    return [self byteOffsetForUTF16:r.location inLine:L];
}

- (NSUInteger)nextCharOffset:(NSUInteger)off {
    if (off >= _buf.length) return _buf.length;
    NSUInteger L = [_buf lineForOffset:off];
    if (off >= [_buf lineEnd:L]) return L + 1 < _buf.lineCount ? [_buf lineStart:L + 1] : _buf.length;
    NSString *s = [self lineString:L];
    NSUInteger u = [self utf16Index:off inLine:L];
    if (u >= s.length) return [_buf lineEnd:L];
    return [self byteOffsetForUTF16:NSMaxRange([s rangeOfComposedCharacterSequenceAtIndex:u]) inLine:L];
}

static int charClass(uint8_t c) {
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') return 0;
    if (c >= 0x80 || c == '_' || (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'z')) return 1;
    return 2;
}

- (NSUInteger)wordBoundary:(NSUInteger)off forward:(BOOL)fwd {
    NSUInteger n = _buf.length;
    if (fwd) {
        while (off < n && charClass([_buf byteAt:off]) == 0) off++;
        if (off >= n) return n;
        int k = charClass([_buf byteAt:off]);
        while (off < n && charClass([_buf byteAt:off]) == k) off++;
    } else {
        while (off > 0 && charClass([_buf byteAt:off - 1]) == 0) off--;
        if (off == 0) return 0;
        int k = charClass([_buf byteAt:off - 1]);
        while (off > 0 && charClass([_buf byteAt:off - 1]) == k) off--;
    }
    return off;
}

- (NSRange)wordRangeAt:(NSUInteger)off {
    NSUInteger L = [_buf lineForOffset:off], ls = [_buf lineStart:L], le = [_buf lineEnd:L];
    if (ls == le) return NSMakeRange(ls, 0);
    NSUInteger p = MIN(off, le - 1);
    int k = charClass([_buf byteAt:p]);
    NSUInteger a = p, b = p + 1;
    while (a > ls && charClass([_buf byteAt:a - 1]) == k) a--;
    while (b < le && charClass([_buf byteAt:b]) == k) b++;
    return NSMakeRange(a, b - a);
}

@end

#import "Viewers.h"
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <objc/message.h>

#pragma mark Hex

@implementation HexView {
    NSData *_data;
    CTFontRef _font;
    CGFloat _lineHeight, _ascent;
}

- (instancetype)initWithFrame:(NSRect)frame data:(NSData *)data {
    if (!(self = [super initWithFrame:frame])) return nil;
    _data = data;
    _font = (CTFontRef)CFBridgingRetain([NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]);
    _ascent = ceil(CTFontGetAscent(_font));
    _lineHeight = ceil(_ascent + CTFontGetDescent(_font)) + 4;
    return self;
}
- (void)dealloc { if (_font) CFRelease(_font); }

- (NSUInteger)rows { return (_data.length + 15) / 16; }
- (CGFloat)contentHeight { return self.rows * _lineHeight + 16; }

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(dirty);
    CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));
    const uint8_t *b = _data.bytes;
    NSUInteger n = _data.length;
    NSUInteger first = (NSUInteger)MAX(0, floor((self.scrollY + NSMinY(dirty) - 8) / _lineHeight));
    NSUInteger last = MIN(self.rows, (NSUInteger)ceil((self.scrollY + NSMaxY(dirty)) / _lineHeight) + 1);
    NSDictionary *addrAttr = @{(id)kCTFontAttributeName: (__bridge id)_font,
                               (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.tertiaryLabelColor.CGColor};
    NSDictionary *attr = @{(id)kCTFontAttributeName: (__bridge id)_font,
                           (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.textColor.CGColor};
    char line[96];
    for (NSUInteger r = first; r < last; r++) {
        NSUInteger off = r * 16, cnt = MIN((NSUInteger)16, n - off);
        char *p = line;
        for (NSUInteger i = 0; i < 16; i++) {
            if (i < cnt) p += snprintf(p, 4, "%02x ", b[off + i]); else { memcpy(p, "   ", 3); p += 3; }
            if (i == 7) *p++ = ' ';
        }
        *p++ = ' ';
        for (NSUInteger i = 0; i < cnt; i++) { uint8_t c = b[off + i]; *p++ = (c >= 32 && c < 127) ? c : '.'; }
        *p = 0;
        NSMutableAttributedString *as = [[NSMutableAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%08lx  ", (unsigned long)off] attributes:addrAttr];
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:@(line) attributes:attr]];
        CTLineRef ct = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGContextSetTextPosition(cg, 12, 8 + r * _lineHeight - self.scrollY + _ascent);
        CTLineDraw(ct, cg);
        CFRelease(ct);
    }
    [self drawScrollIndicator];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:@"十六进制视图，%lu 字节", (unsigned long)_data.length]; }

@end

#pragma mark Quick Look

NSView *FKCreateQuickLookView(NSRect frame, NSString *path) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/Quartz.framework/Quartz", RTLD_LAZY);
        cls = NSClassFromString(@"QLPreviewView");
    });
    if (!cls) return nil;
    NSView *v = ((id (*)(id, SEL, NSRect, NSInteger))objc_msgSend)([cls alloc], NSSelectorFromString(@"initWithFrame:style:"), frame, 0);
    ((void (*)(id, SEL, id))objc_msgSend)(v, NSSelectorFromString(@"setPreviewItem:"), [NSURL fileURLWithPath:path]);
    return v;
}

void FKCloseQuickLookView(NSView *v) {
    SEL close = NSSelectorFromString(@"close");
    if ([v respondsToSelector:close]) ((void (*)(id, SEL))objc_msgSend)(v, close);
}

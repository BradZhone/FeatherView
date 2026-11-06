#import "SVGImage.h"

@interface SVGText : NSObject
@property (nonatomic) CGFloat x, y, size, opacity;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *anchor, *family;
@property (nonatomic) BOOL bold;
@property (nonatomic, strong) NSMutableString *text;
@end
@implementation SVGText @end

// Inherited presentation state for one element level.
@interface SVGFrame : NSObject
@property (nonatomic) CGFloat dx, dy, sx, sy, size, opacity;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic, copy) NSString *anchor, *family;
@property (nonatomic) BOOL bold;
@end
@implementation SVGFrame
- (SVGFrame *)copyFrame {
    SVGFrame *f = [SVGFrame new];
    f.dx = _dx; f.dy = _dy; f.sx = _sx; f.sy = _sy; f.size = _size; f.opacity = _opacity;
    f.color = _color; f.anchor = _anchor; f.family = _family; f.bold = _bold;
    return f;
}
@end

static NSColor *parseColor(NSString *s) {
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if ([s hasPrefix:@"#"]) {
        NSString *h = [s substringFromIndex:1];
        if (h.length == 3) h = [NSString stringWithFormat:@"%C%C%C%C%C%C", [h characterAtIndex:0], [h characterAtIndex:0],
                                [h characterAtIndex:1], [h characterAtIndex:1], [h characterAtIndex:2], [h characterAtIndex:2]];
        if (h.length != 6) return nil;
        unsigned v = 0;
        [[NSScanner scannerWithString:h] scanHexInt:&v];
        return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
    }
    NSDictionary *named = @{@"white": NSColor.whiteColor, @"black": NSColor.blackColor, @"red": NSColor.redColor,
                            @"green": [NSColor colorWithSRGBRed:0 green:0.5 blue:0 alpha:1], @"blue": NSColor.blueColor,
                            @"gray": NSColor.grayColor, @"grey": NSColor.grayColor};
    return named[s];
}

// Inside <text>, every start or end of a <tspan> closes the current run; a new run starts at the
// position the (inner) element specifies, or where the text element started.
@interface SVGTextCollector : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<SVGText *> *texts;
@property (nonatomic, strong) NSMutableArray<SVGFrame *> *stack;
@property (nonatomic, strong) SVGText *current;
@property (nonatomic) NSInteger textDepth;      // > 0 while inside <text>
@property (nonatomic) CGFloat textX, textY;     // origin of the enclosing <text>
@end

@implementation SVGTextCollector

- (instancetype)init {
    if ((self = [super init])) {
        _texts = [NSMutableArray array];
        SVGFrame *root = [SVGFrame new];
        root.sx = root.sy = 1; root.size = 16; root.opacity = 1; root.color = NSColor.blackColor; root.anchor = @"start";
        _stack = [NSMutableArray arrayWithObject:root];
    }
    return self;
}

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    SVGFrame *f = [_stack.lastObject copyFrame];
    NSString *tr = a[@"transform"];
    if (tr.length) {
        NSScanner *sc = [NSScanner scannerWithString:tr];
        sc.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,()"];
        NSString *fn;
        while ([sc scanUpToString:@"(" intoString:&fn]) {
            fn = [fn stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            double v1 = 0, v2 = NAN;
            [sc scanDouble:&v1];
            if (![sc scanDouble:&v2]) v2 = NAN;
            if ([fn isEqualToString:@"translate"]) { f.dx += v1 * f.sx; f.dy += (isnan(v2) ? 0 : v2) * f.sy; }
            else if ([fn isEqualToString:@"scale"]) { f.sx *= v1; f.sy *= isnan(v2) ? v1 : v2; }
            [sc scanUpToCharactersFromSet:[NSCharacterSet letterCharacterSet] intoString:NULL];
        }
    }
    NSMutableDictionary *attrs = [a mutableCopy];
    for (NSString *decl in [a[@"style"] componentsSeparatedByString:@";"]) {
        NSArray *kv = [decl componentsSeparatedByString:@":"];
        if (kv.count == 2) attrs[[kv[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] =
                               [kv[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    if (attrs[@"font-size"]) f.size = [attrs[@"font-size"] doubleValue] ?: f.size;
    if (attrs[@"font-family"]) f.family = attrs[@"font-family"];
    if (attrs[@"font-weight"]) f.bold = [attrs[@"font-weight"] isEqualToString:@"bold"] || [attrs[@"font-weight"] integerValue] >= 600;
    if (attrs[@"text-anchor"]) f.anchor = attrs[@"text-anchor"];
    if (attrs[@"fill"]) { NSColor *c = parseColor(attrs[@"fill"]); if (c) f.color = c; }
    if (attrs[@"fill-opacity"]) f.opacity *= [attrs[@"fill-opacity"] doubleValue];
    if (attrs[@"opacity"]) f.opacity *= [attrs[@"opacity"] doubleValue];
    BOOL isText = [el isEqualToString:@"text"], isSpan = [el isEqualToString:@"tspan"] && _textDepth > 0;
    if (isText) {
        _textDepth++;
        _textX = f.dx + [attrs[@"x"] doubleValue] * f.sx;
        _textY = f.dy + [attrs[@"y"] doubleValue] * f.sy;
    }
    if (isText || isSpan) {
        [self endRun];
        CGFloat x = attrs[@"x"] ? f.dx + [attrs[@"x"] doubleValue] * f.sx : _textX;
        CGFloat y = attrs[@"y"] ? f.dy + [attrs[@"y"] doubleValue] * f.sy : _textY;
        [self startRunAt:x y:y frame:f];
    }
    [_stack addObject:f];
}

- (void)startRunAt:(CGFloat)x y:(CGFloat)y frame:(SVGFrame *)f {
    SVGText *t = [SVGText new];
    t.x = x; t.y = y;
    t.size = f.size * f.sy; t.color = f.color; t.opacity = f.opacity; t.anchor = f.anchor; t.family = f.family; t.bold = f.bold;
    t.text = [NSMutableString string];
    _current = t;
}

- (void)endRun {
    NSString *s = [_current.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length) { [_current.text setString:s]; [_texts addObject:_current]; }
    _current = nil;
}

- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { if (_current) [_current.text appendString:s]; }

- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    if (_stack.count > 1) [_stack removeLastObject];
    if ([el isEqualToString:@"text"] && _textDepth > 0) { [self endRun]; _textDepth--; return; }
    if ([el isEqualToString:@"tspan"] && _textDepth > 0) {
        [self endRun];
        [self startRunAt:_textX y:_textY frame:_stack.lastObject];      // trailing text of the parent <text>
    }
}

@end

BOOL FTLooksLikeSVG(NSData *data) {
    NSUInteger n = MIN(data.length, (NSUInteger)1024);
    NSString *head = [[NSString alloc] initWithBytes:data.bytes length:n encoding:NSUTF8StringEncoding]
                   ?: [[NSString alloc] initWithBytes:data.bytes length:n encoding:NSISOLatin1StringEncoding];
    return [head rangeOfString:@"<svg" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

NSImage *FTSVGImageWithCurrentColor(NSData *data, NSString *hex) {
    if (!data.length || !hex.length) return FTSVGImage(data);
    NSString *src = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!src || [src rangeOfString:@"currentColor" options:NSCaseInsensitiveSearch].location == NSNotFound) return FTSVGImage(data);
    src = [src stringByReplacingOccurrencesOfString:@"currentColor" withString:hex options:NSCaseInsensitiveSearch range:NSMakeRange(0, src.length)];
    return FTSVGImage([src dataUsingEncoding:NSUTF8StringEncoding]);
}

NSImage *FTSVGImage(NSData *data) {
    if (!data.length) return nil;
    NSString *src = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!src || [src rangeOfString:@"<text" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        NSImage *img = [[NSImage alloc] initWithData:data];
        return img.size.width > 0 ? img : nil;
    }
    SVGTextCollector *col = [SVGTextCollector new];
    NSXMLParser *xp = [[NSXMLParser alloc] initWithData:data];
    xp.delegate = col;
    [xp parse];
    // shapes only: drop the text so a future system renderer that does draw it won't double it
    NSString *shapes = [src stringByReplacingOccurrencesOfString:@"<text\\b[\\s\\S]*?</text>" withString:@""
                                                         options:NSRegularExpressionSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, src.length)];
    NSImage *base = [[NSImage alloc] initWithData:[shapes dataUsingEncoding:NSUTF8StringEncoding]];
    if (base.size.width <= 0) return nil;
    NSArray<SVGText *> *texts = [col.texts copy];
    return [NSImage imageWithSize:base.size flipped:YES drawingHandler:^BOOL(NSRect r) {
        [base drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        for (SVGText *t in texts) {
            NSString *fam = [[[t.family componentsSeparatedByString:@","].firstObject stringByReplacingOccurrencesOfString:@"'" withString:@""]
                             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSFont *f = fam.length ? [NSFont fontWithName:fam size:t.size] : nil;
            if (!f) f = [NSFont systemFontOfSize:t.size weight:t.bold ? NSFontWeightBold : NSFontWeightRegular];
            NSDictionary *at = @{NSFontAttributeName: f,
                                 NSForegroundColorAttributeName: [t.color colorWithAlphaComponent:t.color.alphaComponent * t.opacity]};
            CGFloat w = [t.text sizeWithAttributes:at].width, x = t.x;
            if ([t.anchor isEqualToString:@"middle"]) x -= w / 2;
            else if ([t.anchor isEqualToString:@"end"]) x -= w;
            [t.text drawAtPoint:NSMakePoint(x, t.y - f.ascender) withAttributes:at];
        }
        return YES;
    }];
}
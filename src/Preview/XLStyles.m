#import "XLWorkbook+Private.h"
#include <math.h>

@implementation XLStyle
- (instancetype)init {
    if ((self = [super init])) { _fontName = @"Calibri"; _fontSize = 11; _numberFormat = @"General"; }
    return self;
}
@end

// The legacy 64-colour palette (indexed="n").
static const uint32_t kIndexed[64] = {
    0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF,
    0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF,
    0xFF800000, 0xFF008000, 0xFF000080, 0xFF808000, 0xFF800080, 0xFF008080, 0xFFC0C0C0, 0xFF808080,
    0xFF9999FF, 0xFF993366, 0xFFFFFFCC, 0xFFCCFFFF, 0xFF660066, 0xFFFF8080, 0xFF0066CC, 0xFFCCCCFF,
    0xFF000080, 0xFFFF00FF, 0xFFFFFF00, 0xFF00FFFF, 0xFF800080, 0xFF800000, 0xFF008080, 0xFF0000FF,
    0xFF00CCFF, 0xFFCCFFFF, 0xFFCCFFCC, 0xFFFFFF99, 0xFF99CCFF, 0xFFFF99CC, 0xFFCC99FF, 0xFFFFCC99,
    0xFF3366FF, 0xFF33CCCC, 0xFF99CC00, 0xFFFFCC00, 0xFFFF9900, 0xFFFF6600, 0xFF666699, 0xFF969696,
    0xFF003366, 0xFF339966, 0xFF003300, 0xFF333300, 0xFF993300, 0xFF993366, 0xFF333399, 0xFF333333,
};

static uint32_t tinted(uint32_t argb, double tint) {
    if (tint == 0) return argb;
    double r = ((argb >> 16) & 255) / 255.0, g = ((argb >> 8) & 255) / 255.0, b = (argb & 255) / 255.0;
    double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b)), l = (mx + mn) / 2, h = 0, s = 0;
    if (mx != mn) {
        double d = mx - mn;
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4;
        h /= 6;
    }
    l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;
    double (^hue)(double, double, double) = ^double(double p, double q, double t) {
        if (t < 0) t += 1; if (t > 1) t -= 1;
        if (t < 1.0 / 6) return p + (q - p) * 6 * t;
        if (t < 0.5) return q;
        if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
        return p;
    };
    if (s == 0) r = g = b = l;
    else {
        double q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
        r = hue(p, q, h + 1.0 / 3); g = hue(p, q, h); b = hue(p, q, h - 1.0 / 3);
    }
    return (argb & 0xFF000000) | (uint32_t)lround(r * 255) << 16 | (uint32_t)lround(g * 255) << 8 | (uint32_t)lround(b * 255);
}

static XLLine lineStyle(NSString *s) {
    if (!s.length || [s isEqual:@"none"]) return XLLineNone;
    if ([s isEqual:@"medium"] || [s hasPrefix:@"mediumDash"] || [s isEqual:@"slantDashDot"]) return XLLineMedium;
    if ([s isEqual:@"thick"]) return XLLineThick;
    if ([s isEqual:@"double"]) return XLLineDouble;
    if ([s isEqual:@"dashed"] || [s hasPrefix:@"dashDot"]) return XLLineDashed;
    if ([s isEqual:@"dotted"]) return XLLineDotted;
    if ([s isEqual:@"hair"]) return XLLineHair;
    return XLLineThin;
}

static BOOL flagOn(const uint8_t *x, const XLTag *t) {                 // <b/>, <b val="1"/>, <b val="false"/>
    NSString *v = XLAttr(x, t, "val");
    return !v || !([v isEqual:@"0"] || [v isEqual:@"false"]);
}

typedef struct { XLLine style; uint32_t color; } Side;

@implementation XLWorkbook (Styles)

- (uint32_t)colorFrom:(const uint8_t *)x tag:(const XLTag *)t {
    NSString *rgb = XLAttr(x, t, "rgb"), *theme = XLAttr(x, t, "theme"), *idx = XLAttr(x, t, "indexed"), *tint = XLAttr(x, t, "tint");
    uint32_t c = 0;
    if (rgb.length >= 6) {
        unsigned v = (unsigned)strtoul(rgb.UTF8String, NULL, 16);
        c = rgb.length >= 8 ? v : (0xFF000000 | v);
        if ((c >> 24) == 0) c |= 0xFF000000;                         // some writers store alpha 00 meaning opaque
    } else if (theme) {
        NSUInteger k = (NSUInteger)theme.integerValue;
        c = k < _themeColors.count ? _themeColors[k].unsignedIntValue : 0;
    } else if (idx) {
        NSInteger k = idx.integerValue;
        c = k >= 0 && k < 64 ? kIndexed[k] : 0;                       // 64 / 65: system colours, left to the view
    }
    return c && tint ? tinted(c, tint.doubleValue) : c;
}

- (void)loadTheme:(NSData *)xml {
    // clrScheme order is dk1 lt1 dk2 lt2 accent1-6 hlink folHlink; theme indices swap the first two pairs
    NSMutableArray *raw = [NSMutableArray array];
    const uint8_t *x = xml.bytes; NSUInteger n = xml.length, i = 0;
    XLTag t; BOOL inScheme = NO;
    while (XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (XLTagIs(x, &t, "clrScheme")) { if (t.closing) break; inScheme = YES; continue; }
        if (!inScheme || t.closing) continue;
        if (XLTagIs(x, &t, "srgbClr")) { NSString *v = XLAttr(x, &t, "val"); [raw addObject:@(0xFF000000 | (uint32_t)strtoul(v.UTF8String ?: "0", NULL, 16))]; }
        else if (XLTagIs(x, &t, "sysClr")) { NSString *v = XLAttr(x, &t, "lastClr") ?: ([XLAttr(x, &t, "val") isEqual:@"window"] ? @"FFFFFF" : @"000000");
                                             [raw addObject:@(0xFF000000 | (uint32_t)strtoul(v.UTF8String, NULL, 16))]; }
    }
    if (raw.count >= 4) [raw exchangeObjectAtIndex:0 withObjectAtIndex:1], [raw exchangeObjectAtIndex:2 withObjectAtIndex:3];
    _themeColors = raw;
}

- (void)loadStyles:(NSData *)xml {
    const uint8_t *x = xml.bytes; NSUInteger n = xml.length, i = 0;
    NSMutableDictionary<NSNumber *, NSString *> *fmts = [NSMutableDictionary dictionary];
    NSMutableArray<XLStyle *> *fonts = [NSMutableArray array], *xfs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *fills = [NSMutableArray array];
    NSMutableArray<NSData *> *borders = [NSMutableArray array];
    NSString *section = nil;                                         // numFmts fonts fills borders cellXfs
    XLStyle *font = nil; uint32_t fill = 0; BOOL fillSolid = NO, inFill = NO;
    Side sides[4]; NSInteger side = -1; BOOL inBorder = NO;
    XLStyle *xf = nil;
    XLTag t;
    while (XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (XLTagIs(x, &t, "numFmts") || XLTagIs(x, &t, "fonts") || XLTagIs(x, &t, "fills") || XLTagIs(x, &t, "borders") ||
            XLTagIs(x, &t, "cellXfs") || XLTagIs(x, &t, "cellStyleXfs") || XLTagIs(x, &t, "dxfs") || XLTagIs(x, &t, "cellStyles")) {
            section = t.closing || t.selfClosing ? nil : [[NSString alloc] initWithBytes:x + t.localStart length:t.nameStart + t.nameLen - t.localStart encoding:NSUTF8StringEncoding];
            continue;
        }
        if ([section isEqual:@"numFmts"] && XLTagIs(x, &t, "numFmt") && !t.closing) {
            fmts[@(XLAttr(x, &t, "numFmtId").integerValue)] = XLAttr(x, &t, "formatCode") ?: @"General";
        } else if ([section isEqual:@"fonts"]) {
            if (XLTagIs(x, &t, "font")) { if (t.closing || t.selfClosing) { if (font || t.selfClosing) [fonts addObject:font ?: [XLStyle new]]; font = nil; } else font = [XLStyle new]; continue; }
            if (!font || t.closing) continue;
            if (XLTagIs(x, &t, "b")) font.bold = flagOn(x, &t);
            else if (XLTagIs(x, &t, "i")) font.italic = flagOn(x, &t);
            else if (XLTagIs(x, &t, "strike")) font.strike = flagOn(x, &t);
            else if (XLTagIs(x, &t, "u")) { NSString *v = XLAttr(x, &t, "val"); font.underline = ![v isEqual:@"none"]; }
            else if (XLTagIs(x, &t, "sz")) font.fontSize = MAX(1, XLAttr(x, &t, "val").doubleValue);
            else if (XLTagIs(x, &t, "name") || XLTagIs(x, &t, "rFont")) font.fontName = XLAttr(x, &t, "val") ?: font.fontName;
            else if (XLTagIs(x, &t, "color")) font.fontColor = [self colorFrom:x tag:&t];
        } else if ([section isEqual:@"fills"]) {
            if (XLTagIs(x, &t, "fill")) {
                if (t.closing || t.selfClosing) { [fills addObject:@(fillSolid ? fill : 0)]; inFill = NO; }
                else { inFill = YES; fill = 0; fillSolid = NO; }
                continue;
            }
            if (!inFill || t.closing) continue;
            if (XLTagIs(x, &t, "patternFill")) { NSString *p = XLAttr(x, &t, "patternType"); fillSolid = p && ![p isEqual:@"none"] && ![p isEqual:@"gray125"] && ![p isEqual:@"gray0625"]; }
            else if (XLTagIs(x, &t, "gradientFill")) fillSolid = YES;
            else if ((XLTagIs(x, &t, "fgColor") || (XLTagIs(x, &t, "bgColor") && !fill) || XLTagIs(x, &t, "color")) && !fill) fill = [self colorFrom:x tag:&t];
        } else if ([section isEqual:@"borders"]) {
            if (XLTagIs(x, &t, "border")) {
                if (t.closing || t.selfClosing) { if (!inBorder) memset(sides, 0, sizeof sides); [borders addObject:[NSData dataWithBytes:sides length:sizeof sides]]; inBorder = NO; }
                else { inBorder = YES; memset(sides, 0, sizeof sides); }
                continue;
            }
            if (!inBorder) continue;
            NSInteger which = XLTagIs(x, &t, "left") || XLTagIs(x, &t, "start") ? 0 : XLTagIs(x, &t, "right") || XLTagIs(x, &t, "end") ? 1 :
                              XLTagIs(x, &t, "top") ? 2 : XLTagIs(x, &t, "bottom") ? 3 : -1;
            if (which >= 0) {
                if (t.closing) { side = -1; continue; }
                sides[which].style = lineStyle(XLAttr(x, &t, "style"));
                side = t.selfClosing ? -1 : which;
            } else if (XLTagIs(x, &t, "color") && side >= 0 && !t.closing) sides[side].color = [self colorFrom:x tag:&t];
        } else if ([section isEqual:@"cellXfs"]) {
            if (XLTagIs(x, &t, "xf")) {
                if (t.closing) { if (xf) [xfs addObject:xf]; xf = nil; continue; }
                xf = [XLStyle new];
                NSUInteger fi = (NSUInteger)XLAttr(x, &t, "fontId").integerValue, li = (NSUInteger)XLAttr(x, &t, "fillId").integerValue,
                           bi = (NSUInteger)XLAttr(x, &t, "borderId").integerValue, ni = (NSUInteger)XLAttr(x, &t, "numFmtId").integerValue;
                XLStyle *f = fi < fonts.count ? fonts[fi] : nil;
                if (f) { xf.fontName = f.fontName; xf.fontSize = f.fontSize; xf.bold = f.bold; xf.italic = f.italic; xf.underline = f.underline; xf.strike = f.strike; xf.fontColor = f.fontColor; }
                xf.fillColor = li < fills.count ? fills[li].unsignedIntValue : 0;
                if (bi < borders.count) {
                    const Side *sd = borders[bi].bytes;
                    xf.left = sd[0].style; xf.leftColor = sd[0].color; xf.right = sd[1].style; xf.rightColor = sd[1].color;
                    xf.top = sd[2].style; xf.topColor = sd[2].color; xf.bottom = sd[3].style; xf.bottomColor = sd[3].color;
                }
                xf.numFmtId = ni;
                xf.numberFormat = fmts[@(ni)] ?: XLBuiltinFormat(ni) ?: @"General";
                xf.isDate = XLFormatIsDate(xf.numberFormat);
                if (t.selfClosing) { [xfs addObject:xf]; xf = nil; }
            } else if (XLTagIs(x, &t, "alignment") && xf && !t.closing) {
                NSString *h = XLAttr(x, &t, "horizontal"), *v = XLAttr(x, &t, "vertical");
                xf.hAlign = [h isEqual:@"left"] ? XLAlignLeft : [h hasPrefix:@"center"] ? XLAlignCenter : [h isEqual:@"right"] ? XLAlignRight :
                            [h isEqual:@"fill"] ? XLAlignFill : [h isEqual:@"justify"] || [h isEqual:@"distributed"] ? XLAlignJustify : XLAlignGeneral;
                xf.vAlign = [v isEqual:@"top"] ? XLAlignTop : [v isEqual:@"center"] || [v isEqual:@"justify"] || [v isEqual:@"distributed"] ? XLAlignVCenter : XLAlignBottom;
                NSString *w = XLAttr(x, &t, "wrapText");
                xf.wrap = w && ![w isEqual:@"0"] && ![w isEqual:@"false"];
                xf.indent = XLAttr(x, &t, "indent").integerValue;
            }
        }
    }
    _styles = xfs;
}

- (XLStyle *)style:(NSUInteger)i {
    static XLStyle *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ plain = [XLStyle new]; });
    if (i < _styles.count) return _styles[i];
    return _styles.count ? _styles[0] : plain;
}

@end

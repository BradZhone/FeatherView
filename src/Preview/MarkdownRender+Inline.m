#import "MarkdownRender+Private.h"
#import "Localization.h"
#import <ImageIO/ImageIO.h>
#import "SVGImage.h"

static const NSUInteger kMaxRemoteImages = 40;
static const NSUInteger kMaxImageBytes = 8u << 20;

NSDictionary<NSString *, NSString *> *MDHTMLAttrs(NSString *tag) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))" options:0 error:nil];
    });
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *m in [re matchesInString:tag options:0 range:NSMakeRange(0, tag.length)]) {
        NSString *v = @"";
        for (NSUInteger g = 2; g <= 4; g++) if ([m rangeAtIndex:g].location != NSNotFound) v = [tag substringWithRange:[m rangeAtIndex:g]];
        d[[tag substringWithRange:[m rangeAtIndex:1]].lowercaseString] = v;
    }
    return d;
}

static NSString *tagName(NSString *raw, BOOL *closing) {
    NSUInteger i = 1;
    *closing = raw.length > 1 && [raw characterAtIndex:1] == '/';
    if (*closing) i = 2;
    NSUInteger s = i;
    while (i < raw.length && [NSCharacterSet.alphanumericCharacterSet characterIsMember:[raw characterAtIndex:i]]) i++;
    return [raw substringWithRange:NSMakeRange(s, i - s)].lowercaseString;
}

@implementation MarkdownRenderer (Inline)

// Local file that a relative / file: link points to, or nil for web links and #anchors.
- (NSString *)localTarget:(NSString *)href {
    if (!href.length || [href hasPrefix:@"#"]) return nil;
    NSURL *u = [NSURL URLWithString:href];
    NSString *scheme = u.scheme.lowercaseString;
    if (scheme.length && ![scheme isEqualToString:@"file"]) return nil;
    NSString *p = href;
    NSRange cut = [p rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"#?"]];
    if (cut.location != NSNotFound) p = [p substringToIndex:cut.location];
    p = [scheme isEqualToString:@"file"] ? u.path : (p.stringByRemovingPercentEncoding ?: p);
    if (!p.length) return nil;
    if (![p hasPrefix:@"/"]) p = [self.baseDir stringByAppendingPathComponent:p];
    return p.stringByStandardizingPath;
}

// Links are coloured here rather than through linkTextAttributes so a dead local link can look different.
- (void)styleLink:(NSString *)href title:(NSString *)title into:(NSMutableDictionary *)d {
    d[NSLinkAttributeName] = href ?: @"";
    NSString *target = [self localTarget:href];
    BOOL missing = target && ![NSFileManager.defaultManager fileExistsAtPath:target];
    d[NSForegroundColorAttributeName] = missing ? NSColor.tertiaryLabelColor : NSColor.linkColor;
    if (missing) d[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    d[NSToolTipAttributeName] = missing ? [NSString stringWithFormat:FTL(@"File not found: %@"), target.lastPathComponent]
                              : title.length ? title : (href ?: @"");
}

- (void)inlines:(NSArray<MDInline *> *)a attrs:(NSDictionary *)base into:(NSMutableAttributedString *)o {
    NSMutableArray<NSDictionary *> *stack = [NSMutableArray array];   // raw inline HTML: <b>…</b> etc.
    NSDictionary *cur = base;
    for (MDInline *x in a) {
        NSFont *f = cur[NSFontAttributeName];
        NSMutableDictionary *d = [cur mutableCopy];
        switch (x.type) {
            case MDText: [o appendAttributedString:[[NSAttributedString alloc] initWithString:x.text attributes:cur]]; break;
            case MDSoftBreak: [o appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:cur]]; break;
            case MDHardBreak: [o appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u2028" attributes:cur]]; break;
            case MDCodeSpan:
                d[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:f.pointSize * 0.9 weight:NSFontWeightRegular];
                d[NSBackgroundColorAttributeName] = MDCodeBackground();
                [o appendAttributedString:[[NSAttributedString alloc] initWithString:x.text attributes:d]];
                break;
            case MDEmph: d[NSFontAttributeName] = MDTrait(f, NSFontDescriptorTraitItalic); [self inlines:x.children attrs:d into:o]; break;
            case MDStrong: d[NSFontAttributeName] = MDTrait(f, NSFontDescriptorTraitBold); [self inlines:x.children attrs:d into:o]; break;
            case MDStrike: d[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle); [self inlines:x.children attrs:d into:o]; break;
            case MDLink:
                [self styleLink:x.url title:x.title into:d];
                [self inlines:x.children attrs:d into:o];
                break;
            case MDImage: [o appendAttributedString:[self imageFor:x.url alt:x.text width:nil height:nil attrs:cur]]; break;
            case MDRawHTML: {
                BOOL closing;
                NSString *t = tagName(x.text, &closing);
                if ([t isEqualToString:@"br"]) { [o appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u2028" attributes:cur]]; break; }
                if ([t isEqualToString:@"img"]) {
                    NSDictionary *at = MDHTMLAttrs(x.text);
                    [o appendAttributedString:[self imageFor:at[@"src"] alt:at[@"alt"] width:at[@"width"] height:at[@"height"] attrs:cur]];
                    break;
                }
                if (closing) { if (stack.count) { cur = stack.lastObject; [stack removeLastObject]; } break; }
                if ([x.text hasSuffix:@"/>"] || ![@[@"b", @"strong", @"i", @"em", @"code", @"kbd", @"tt", @"s", @"del", @"strike", @"u", @"ins", @"a", @"sup", @"sub", @"mark", @"small", @"span", @"font"] containsObject:t]) break;
                [stack addObject:cur];
                if ([@[@"b", @"strong"] containsObject:t]) d[NSFontAttributeName] = MDTrait(f, NSFontDescriptorTraitBold);
                else if ([@[@"i", @"em"] containsObject:t]) d[NSFontAttributeName] = MDTrait(f, NSFontDescriptorTraitItalic);
                else if ([@[@"code", @"kbd", @"tt"] containsObject:t]) {
                    d[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:f.pointSize * 0.9 weight:NSFontWeightRegular];
                    d[NSBackgroundColorAttributeName] = MDCodeBackground();
                } else if ([@[@"s", @"del", @"strike"] containsObject:t]) d[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
                else if ([@[@"u", @"ins"] containsObject:t]) d[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
                else if ([t isEqualToString:@"a"]) { NSString *h = MDHTMLAttrs(x.text)[@"href"]; if (h.length) [self styleLink:h title:nil into:d]; }
                else if ([t isEqualToString:@"sup"] || [t isEqualToString:@"sub"]) {
                    d[NSFontAttributeName] = [NSFont fontWithDescriptor:f.fontDescriptor size:f.pointSize * 0.75];
                    d[NSBaselineOffsetAttributeName] = @([t isEqualToString:@"sup"] ? f.pointSize * 0.35 : -f.pointSize * 0.15);
                } else if ([t isEqualToString:@"mark"]) d[NSBackgroundColorAttributeName] = [NSColor.systemYellowColor colorWithAlphaComponent:0.35];
                else if ([t isEqualToString:@"small"]) d[NSFontAttributeName] = [NSFont fontWithDescriptor:f.fontDescriptor size:f.pointSize * 0.85];
                cur = d;
                break;
            }
        }
    }
}

static NSImage *decode(CGImageSourceRef src, CGFloat maxPx) {
    if (!src) return nil;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CGFloat w = [props[(id)kCGImagePropertyPixelWidth] doubleValue], h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    if ([props[(id)kCGImagePropertyOrientation] intValue] >= 5) { CGFloat t = w; w = h; h = t; }
    NSDictionary *opt = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                          (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                          (id)kCGImageSourceShouldCacheImmediately: @YES,
                          (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1, MIN(maxPx, MAX(w, h))))};
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    if (!cg) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(w ?: CGImageGetWidth(cg), h ?: CGImageGetHeight(cg))];
    CGImageRelease(cg);
    return img;
}

- (CGFloat)decodeLimit { return self.maxImageWidth * 2; }       // Retina

- (NSImage *)localImage:(NSString *)path {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    NSImage *img = decode(src, self.decodeLimit);
    if (src) CFRelease(src);
    if (!img) {                                                     // SVG and friends
        img = FTSVGImage([NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil]);
    }
    return img;
}

- (void)fetch:(NSString *)src {
    if ([_inflight containsObject:src] || _remoteCount >= kMaxRemoteImages) return;
    _remoteCount++;
    [_inflight addObject:src];
    NSString *u = [src stringByReplacingOccurrencesOfString:@"://img.shields.io/" withString:@"://raster.shields.io/"];
    NSURL *url = [NSURL URLWithString:u];
    if (!_session) {
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.timeoutIntervalForRequest = 10;
        cfg.timeoutIntervalForResource = 20;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    CGFloat limit = self.decodeLimit;
    __weak MarkdownRenderer *weakSelf = self;
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSImage *img = nil;
        if (data.length && data.length <= kMaxImageBytes) {
            CGImageSourceRef s = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            img = decode(s, limit);
            if (s) CFRelease(s);
            if (!img) img = FTSVGImage(data);                       // SVG badges
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            MarkdownRenderer *me = weakSelf;
            if (!me) return;
            me->_images[src] = img ?: (id)NSNull.null;
            [me->_inflight removeObject:src];
            if (img && me.onImageLoaded) me.onImageLoaded();
        });
    }] resume];
}

- (NSAttributedString *)imageFor:(NSString *)src alt:(NSString *)alt width:(NSString *)w height:(NSString *)h attrs:(NSDictionary *)attrs {
    src = [src stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    id cached = src.length ? _images[src] : nil;
    NSImage *img = [cached isKindOfClass:NSImage.class] ? cached : nil;
    if (!cached && src.length) {
        NSURL *u = [NSURL URLWithString:src];
        NSString *scheme = u.scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"]) [self fetch:src];
        else if (!scheme.length || [scheme isEqualToString:@"file"]) {
            NSString *p = [scheme isEqualToString:@"file"] ? u.path : (src.stringByRemovingPercentEncoding ?: src);
            if (![p hasPrefix:@"/"]) p = [self.baseDir stringByAppendingPathComponent:p];
            img = [self localImage:p.stringByStandardizingPath];
            _images[src] = img ?: (id)NSNull.null;
        }
    }
    if (!img) {
        NSMutableDictionary *d = [attrs mutableCopy];
        d[NSForegroundColorAttributeName] = NSColor.secondaryLabelColor;
        NSString *label = alt.length ? alt : src.lastPathComponent ?: FTL(@"image");
        return [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[%@]", label] attributes:d];
    }
    CGFloat iw = img.size.width, ih = img.size.height, dw = iw, dh = ih;
    if (w.doubleValue > 0) {
        dw = [w hasSuffix:@"%"] ? self.maxImageWidth * w.doubleValue / 100 : w.doubleValue;
        dh = h.doubleValue > 0 ? h.doubleValue : (iw > 0 ? ih * dw / iw : ih);
    } else if (h.doubleValue > 0) { dh = h.doubleValue; dw = ih > 0 ? iw * dh / ih : iw; }
    if (dw > self.maxImageWidth) { dh = dh * self.maxImageWidth / dw; dw = self.maxImageWidth; }
    NSTextAttachment *att = [NSTextAttachment new];
    att.image = img;
    NSFont *f = attrs[NSFontAttributeName];
    CGFloat dy = dh < f.pointSize * 2 ? round(f.descender) : 0;            // badges sit on the baseline
    att.bounds = NSMakeRect(0, dy, round(dw), round(dh));
    NSMutableAttributedString *s = [[NSAttributedString attributedStringWithAttachment:att] mutableCopy];
    [s addAttributes:attrs range:NSMakeRange(0, s.length)];
    if (alt.length && !attrs[NSToolTipAttributeName]) [s addAttribute:NSToolTipAttributeName value:alt range:NSMakeRange(0, s.length)];
    return s;
}

- (NSAttributedString *)checkbox:(BOOL)done {
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:
            @[done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor]]];
    NSImage *img = [[NSImage imageWithSystemSymbolName:done ? @"checkmark.square.fill" : @"square"
                                accessibilityDescription:done ? FTL(@"done") : FTL(@"not done")] imageWithSymbolConfiguration:cfg];
    NSTextAttachment *att = [NSTextAttachment new];
    att.image = img;
    att.bounds = NSMakeRect(0, -2, img.size.width, img.size.height);
    return [NSAttributedString attributedStringWithAttachment:att];
}

@end

@implementation MarkdownRenderer (Blocks)

- (void)table:(MDBlock *)b ctx:(RCtx *)c {
    NSUInteger cols = b.rows.firstObject.count;
    if (!cols) return;
    NSTextTable *t = [NSTextTable new];
    t.numberOfColumns = cols;
    t.collapsesBorders = YES;
    [t setWidth:c.indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
    [t setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
    NSFont *body = [NSFont systemFontOfSize:13], *head = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    for (NSUInteger r = 0; r < b.rows.count; r++) {
        for (NSUInteger col = 0; col < cols; col++) {
            NSTextTableBlock *cell = [[NSTextTableBlock alloc] initWithTable:t startingRow:r rowSpan:1 startingColumn:col columnSpan:1];
            [cell setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder];
            [cell setBorderColor:NSColor.separatorColor];
            [cell setWidth:6 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
            [cell setWidth:10 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinXEdge];
            [cell setWidth:10 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMaxXEdge];
            if (r == 0) cell.backgroundColor = MDCodeBackground();
            else if (r % 2 == 0) cell.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.025];
            MDAlign al = col < b.align.count ? [b.align[col] integerValue] : MDAlignNone;
            RCtx *cc = [c with:^(RCtx *x) {
                x.indent = 0;
                x.align = al == MDAlignCenter ? NSTextAlignmentCenter : al == MDAlignRight ? NSTextAlignmentRight : NSTextAlignmentNatural;
            }];
            NSString *src = [b.rows[r][col] stringByReplacingOccurrencesOfString:@"\\|" withString:@"|"];
            NSMutableAttributedString *s = [self inlineText:src ctx:cc font:r ? body : head];
            if (!s.length) [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"\u200B" attributes:[self base:cc font:body]]];
            [self para:s ctx:cc after:0 before:0 block:cell marker:nil markerAt:0 font:body];
        }
    }
}

static void trimEdges(NSMutableAttributedString *s) {
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (s.length && ([ws characterIsMember:[s.string characterAtIndex:0]] || [s.string characterAtIndex:0] == 0x2028))
        [s deleteCharactersInRange:NSMakeRange(0, 1)];
    while (s.length && ([ws characterIsMember:[s.string characterAtIndex:s.length - 1]] || [s.string characterAtIndex:s.length - 1] == 0x2028))
        [s deleteCharactersInRange:NSMakeRange(s.length - 1, 1)];
}

// README-style HTML: <p align="center">, <h1>, <img>, <a>, <br>, <details>. Unknown tags are dropped, text is kept.
- (void)html:(MDBlock *)b ctx:(RCtx *)c {
    NSString *tag = b.info;
    if ([@[@"!--", @"script", @"style"] containsObject:tag]) return;
    if ([tag isEqualToString:@"pre"]) {
        NSString *t = [b.text stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, b.text.length)];
        [self code:t info:@"" ctx:c];
        return;
    }
    NSArray<MDInline *> *nodes = [_doc inlines:b.text];
    NSMutableArray *seg = [NSMutableArray array];
    NSString *segTag = nil;
    NSSet *breakers = [NSSet setWithArray:@[@"p", @"div", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"li", @"summary", @"tr", @"center"]];
    for (NSUInteger i = 0; i <= nodes.count; i++) {
        MDInline *x = i < nodes.count ? nodes[i] : nil;
        BOOL closing = NO;
        NSString *name = x.type == MDRawHTML ? tagName(x.text, &closing) : nil;
        if (x && !(name && [breakers containsObject:name])) { [seg addObject:x]; continue; }
        if (seg.count) {
            NSString *h = segTag ?: @"";
            NSInteger lv = h.length == 2 && [h hasPrefix:@"h"] ? [[h substringFromIndex:1] integerValue] : 0;
            static const CGFloat sizes[] = {14, 28, 22, 18, 16, 14, 13};
            NSFont *f = lv ? [NSFont systemFontOfSize:sizes[MIN(lv, 6)] weight:NSFontWeightSemibold] : [NSFont systemFontOfSize:14];
            BOOL center = [b.text rangeOfString:@"center" options:NSCaseInsensitiveSearch].location != NSNotFound;
            RCtx *hc = [c with:^(RCtx *z) { if (center) z.align = NSTextAlignmentCenter; }];
            NSMutableAttributedString *s = [NSMutableAttributedString new];
            [self inlines:seg attrs:[self base:hc font:f] into:s];
            trimEdges(s);
            if (s.length) [self para:s ctx:hc after:lv ? 10 : 8 before:lv ? 8 : 0 block:nil marker:nil markerAt:0 font:f];
            [seg removeAllObjects];
        }
        if (name && !closing) segTag = name;
        else if (name && closing) segTag = nil;
    }
}

@end

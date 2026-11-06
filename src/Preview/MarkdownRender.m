#import "MarkdownRender+Private.h"
#import "Highlighter.h"

static const CGFloat kBody = 14, kListStep = 22;

@implementation RCtx
- (RCtx *)with:(void (^)(RCtx *))change {
    RCtx *c = [RCtx new];
    c.indent = _indent; c.tb = _tb; c.depth = _depth; c.tight = _tight; c.color = _color; c.align = _align;
    c.lineHeight = _lineHeight;
    change(c);
    return c;
}
@end

NSFont *MDTrait(NSFont *f, NSFontDescriptorSymbolicTraits t) {
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithSymbolicTraits:f.fontDescriptor.symbolicTraits | t];
    return [NSFont fontWithDescriptor:d size:f.pointSize] ?: f;
}

NSColor *MDCodeBackground(void) { return [NSColor.labelColor colorWithAlphaComponent:0.06]; }

// A plain NSTextBlock shrinks to its narrowest content (one glyph per line); pin it to the container width.
NSTextBlock *MDFullWidthBlock(void) {
    NSTextBlock *b = [NSTextBlock new];
    [b setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
    return b;
}

@implementation MarkdownRenderer

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _images = [NSMutableDictionary dictionary];
    _inflight = [NSMutableSet set];
    _maxImageWidth = 760;
    return self;
}

- (NSArray<NSNumber *> *)mapLines { return _lines; }
- (NSArray<NSNumber *> *)mapLocs { return _locs; }
- (NSDictionary *)anchors { return _anchorMap; }

- (void)mark:(NSUInteger)line {
    NSUInteger loc = _out.length;
    if (_lines.count && _lines.lastObject.unsignedIntegerValue >= line) return;   // keep monotonic
    [_lines addObject:@(line)];
    [_locs addObject:@(loc)];
}

- (NSDictionary *)base:(RCtx *)c font:(NSFont *)f {
    return @{NSFontAttributeName: f, NSForegroundColorAttributeName: c.color ?: NSColor.labelColor};
}

- (NSMutableAttributedString *)inlineText:(NSString *)s ctx:(RCtx *)c font:(NSFont *)f {
    NSMutableAttributedString *o = [NSMutableAttributedString new];
    [self inlines:[_doc inlines:s] attrs:[self base:c font:f] into:o];
    return o;
}

// Appends one paragraph. `marker` (bullet / number / checkbox) hangs at markerAt, text starts at c.indent.
- (void)para:(NSAttributedString *)content ctx:(RCtx *)c after:(CGFloat)after before:(CGFloat)before
       block:(NSTextBlock *)block marker:(NSAttributedString *)marker markerAt:(CGFloat)markerAt font:(NSFont *)f {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.headIndent = c.indent;
    ps.firstLineHeadIndent = marker ? markerAt : c.indent;
    ps.paragraphSpacing = after;
    ps.paragraphSpacingBefore = before;
    ps.lineHeightMultiple = c.lineHeight ?: 1.18;
    ps.alignment = c.align;
    ps.tabStops = marker ? @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:c.indent options:@{}]] : @[];
    NSMutableArray *blocks = [c.tb mutableCopy] ?: [NSMutableArray array];
    if (block) [blocks addObject:block];
    ps.textBlocks = blocks;
    NSMutableAttributedString *p = [NSMutableAttributedString new];
    if (marker) {
        [p appendAttributedString:marker];
        [p appendAttributedString:[[NSAttributedString alloc] initWithString:@"\t" attributes:[self base:c font:f]]];
    }
    [p appendAttributedString:content];
    [p appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:[self base:c font:f]]];
    [p addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, p.length)];
    [_out appendAttributedString:p];
}

- (NSAttributedString *)render:(MDDocument *)doc {
    _doc = doc;
    _out = [NSMutableAttributedString new];
    _lines = [NSMutableArray array];
    _locs = [NSMutableArray array];
    _anchorMap = [NSMutableDictionary dictionary];
    _slugs = [NSCountedSet set];
    RCtx *c = [RCtx new];
    c.color = NSColor.labelColor;
    c.align = NSTextAlignmentNatural;
    [self blocks:doc.blocks ctx:c];
    while (_out.length && [_out.string characterAtIndex:_out.length - 1] == '\n') [_out deleteCharactersInRange:NSMakeRange(_out.length - 1, 1)];
    _doc = nil;
    return _out;
}

- (void)blocks:(NSArray<MDBlock *> *)bs ctx:(RCtx *)c {
    NSFont *body = [NSFont systemFontOfSize:kBody];
    for (MDBlock *b in bs) {
        [self mark:b.line];
        switch (b.type) {
            case MDParagraph:
                [self para:[self inlineText:b.text ctx:c font:body] ctx:c after:c.tight ? 2 : 10 before:0
                     block:nil marker:nil markerAt:0 font:body];
                break;
            case MDHeading: [self heading:b ctx:c]; break;
            case MDCode: [self code:b.text info:b.info ctx:c]; break;
            case MDQuote: [self quote:b ctx:c]; break;
            case MDList: [self list:b ctx:c]; break;
            case MDItem: [self blocks:b.children ctx:c]; break;
            case MDRule: [self rule:c]; break;
            case MDTable: [self table:b ctx:c]; break;
            case MDHTMLBlock: [self html:b ctx:c]; break;
        }
    }
}

- (void)heading:(MDBlock *)b ctx:(RCtx *)c {
    static const CGFloat sizes[] = {0, 28, 22, 18, 16, 14, 13};
    NSInteger lv = MIN(MAX(b.level, 1), 6);
    NSFont *f = [NSFont systemFontOfSize:sizes[lv] weight:lv <= 2 ? NSFontWeightSemibold : NSFontWeightBold];
    NSMutableAttributedString *t = [self inlineText:b.text ctx:c font:f];
    if (lv == 6) [t addAttribute:NSForegroundColorAttributeName value:NSColor.secondaryLabelColor range:NSMakeRange(0, t.length)];
    NSString *slug = MDSlug(MDPlainText([_doc inlines:b.text]));
    NSUInteger dup = [_slugs countForObject:slug];
    [_slugs addObject:slug];
    _anchorMap[dup ? [NSString stringWithFormat:@"%@-%lu", slug, (unsigned long)dup] : slug] = @(_out.length);
    NSTextBlock *rule = nil;
    if (lv <= 2) {
        rule = MDFullWidthBlock();
        [rule setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMaxYEdge];
        [rule setBorderColor:NSColor.separatorColor forEdge:NSMaxYEdge];
        [rule setWidth:6 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMaxYEdge];
        [rule setWidth:c.indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
        [rule setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
        [rule setWidth:lv == 1 ? 18 : 14 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
    }
    RCtx *hc = rule ? [c with:^(RCtx *x) { x.indent = 0; }] : c;
    [self para:t ctx:hc after:rule ? 0 : 8 before:rule ? 0 : 14 block:rule marker:nil markerAt:0 font:f];
}

static NSString *extForLang(NSString *lang) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"javascript": @"js", @"typescript": @"ts", @"python": @"py", @"ruby": @"rb", @"shell": @"sh", @"bash": @"sh",
              @"zsh": @"sh", @"console": @"sh", @"golang": @"go", @"rust": @"rs", @"objective-c": @"m", @"objc": @"m",
              @"objectivec": @"m", @"c++": @"cpp", @"csharp": @"cs", @"kotlin": @"kt", @"yml": @"yaml", @"dockerfile": @"dockerfile",
              @"makefile": @"makefile", @"jsonc": @"json", @"tsx": @"tsx", @"jsx": @"jsx", @"html": @"html", @"xml": @"xml",
              @"vue": @"vue", @"markdown": @"md", @"diff": @"diff", @"patch": @"diff", @"toml": @"toml", @"ini": @"ini",
              @"scss": @"scss", @"css": @"css", @"docker": @"dockerfile", @"sh": @"sh", @"text": @"", @"plaintext": @"", @"txt": @""};
    });
    NSString *l = lang.lowercaseString;
    return m[l] ?: l;
}


- (void)code:(NSString *)text info:(NSString *)info ctx:(RCtx *)c {
    NSFont *mono = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    NSTextBlock *blk = MDFullWidthBlock();
    blk.backgroundColor = MDCodeBackground();
    [blk setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
    [blk setWidth:c.indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
    [blk setWidth:4 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
    [blk setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
    Highlighter *hl = info.length ? [Highlighter highlighterForPath:[@"x." stringByAppendingString:extForLang(info)]] : nil;
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: NSColor.labelColor}];
    if (hl) {
        __block NSUInteger off = 0;
        for (NSString *line in [t.string componentsSeparatedByString:@"\n"]) {
            NSUInteger base = off;
            [hl tokenize:line emit:^(NSRange r, TokenKind k) {
                NSRange at = NSMakeRange(base + r.location, r.length);
                [t addAttribute:NSForegroundColorAttributeName value:HLColor(k) range:at];
                if (HLIsItalic(k) || HLIsBold(k))
                    [t addAttribute:NSFontAttributeName value:[NSFontManager.sharedFontManager convertFont:mono
                        toHaveTrait:HLIsItalic(k) ? NSItalicFontMask : NSBoldFontMask] range:at];
            }];
            off += line.length + 1;
        }
    }
    // Consecutive paragraphs sharing one NSTextBlock instance are drawn as a single box.
    RCtx *cc = [c with:^(RCtx *x) { x.indent = 0; x.align = NSTextAlignmentLeft; x.lineHeight = 1.05; }];
    NSUInteger off = 0;
    for (NSString *line in [t.string componentsSeparatedByString:@"\n"]) {
        NSAttributedString *l = [t attributedSubstringFromRange:NSMakeRange(off, line.length)];
        [self para:l ctx:cc after:0 before:0 block:blk marker:nil markerAt:0 font:mono];
        off += line.length + 1;
    }
}

- (void)quote:(MDBlock *)b ctx:(RCtx *)c {
    NSTextBlock *q = MDFullWidthBlock();
    [q setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMinXEdge];
    [q setBorderColor:NSColor.tertiaryLabelColor forEdge:NSMinXEdge];
    [q setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinXEdge];
    [q setWidth:c.indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
    [q setWidth:10 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
    RCtx *qc = [c with:^(RCtx *x) {
        x.tb = [(c.tb ?: @[]) arrayByAddingObject:q];
        x.indent = 0;
        x.color = NSColor.secondaryLabelColor;
    }];
    [self blocks:b.children ctx:qc];
}

- (void)list:(MDBlock *)b ctx:(RCtx *)c {
    static NSString *const bullets[] = {@"•", @"◦", @"▪"};
    NSFont *body = [NSFont systemFontOfSize:kBody];
    NSInteger num = b.start;
    CGFloat markerAt = c.indent, textAt = c.indent + (b.ordered ? 28 : kListStep);
    for (MDBlock *item in b.children) {
        [self mark:item.line];
        NSAttributedString *marker;
        if (item.task >= 0) marker = [self checkbox:item.task == 1];
        else {
            NSString *m = b.ordered ? [NSString stringWithFormat:@"%ld.", (long)num] : bullets[MIN(c.depth, 2)];
            marker = [[NSAttributedString alloc] initWithString:m attributes:@{
                NSFontAttributeName: b.ordered ? [NSFont monospacedDigitSystemFontOfSize:kBody weight:NSFontWeightRegular] : body,
                NSForegroundColorAttributeName: b.ordered ? (c.color ?: NSColor.labelColor) : NSColor.secondaryLabelColor}];
        }
        num++;
        RCtx *ic = [c with:^(RCtx *x) { x.indent = textAt; x.depth = c.depth + 1; x.tight = b.tight; }];
        NSArray<MDBlock *> *kids = item.children;
        NSUInteger k = 0;
        NSAttributedString *first = [NSAttributedString new];
        if (kids.count && kids[0].type == MDParagraph) { first = [self inlineText:kids[0].text ctx:ic font:body]; k = 1; }
        [self para:first ctx:ic after:b.tight ? 2 : 8 before:0 block:nil marker:marker markerAt:markerAt font:body];
        if (k < kids.count) [self blocks:[kids subarrayWithRange:NSMakeRange(k, kids.count - k)] ctx:ic];
    }
    if (c.depth == 0 && _out.length) [self spaceAfterLast:10];
}

- (void)spaceAfterLast:(CGFloat)space {
    NSRange last = [_out.string paragraphRangeForRange:NSMakeRange(_out.length - 1, 0)];
    NSMutableParagraphStyle *ps = [[_out attribute:NSParagraphStyleAttributeName atIndex:last.location effectiveRange:NULL] mutableCopy];
    if (!ps || ps.paragraphSpacing >= space) return;
    ps.paragraphSpacing = space;
    [_out addAttribute:NSParagraphStyleAttributeName value:ps range:last];
}

- (void)rule:(RCtx *)c {
    NSTextBlock *r = MDFullWidthBlock();
    [r setWidth:1 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMaxYEdge];
    [r setBorderColor:NSColor.separatorColor forEdge:NSMaxYEdge];
    [r setWidth:c.indent type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinXEdge];
    [r setWidth:10 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
    [r setWidth:18 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
    NSFont *tiny = [NSFont systemFontOfSize:2];
    RCtx *rc = [c with:^(RCtx *x) { x.indent = 0; x.lineHeight = 0.5; }];
    [self para:[[NSAttributedString alloc] initWithString:@"\u200B" attributes:[self base:rc font:tiny]]
           ctx:rc after:0 before:0 block:r marker:nil markerAt:0 font:tiny];
}

@end

#import "MarkupView.h"
#import "Localization.h"
#import "MarkdownRender.h"
#import "TextEditorView.h"
#import "CanvasView.h"

static CGFloat gMarkdownScale = 1;
static NSAttributedString *scaled(NSAttributedString *src, CGFloat k);

// Handles link clicks itself: works on the first click into an inactive window, and the link is
// followed only after the click has finished (following it may switch tabs and free this view).
@implementation MarkdownTextView {
    NSUInteger _pressedLink;
}

- (instancetype)initWithFrame:(NSRect)f textContainer:(NSTextContainer *)c {
    if ((self = [super initWithFrame:f textContainer:c])) _pressedLink = NSNotFound;
    return self;
}

- (NSUInteger)linkIndexAtPoint:(NSPoint)p {
    NSLayoutManager *lm = self.layoutManager;
    NSPoint c = NSMakePoint(p.x - self.textContainerOrigin.x, p.y - self.textContainerOrigin.y);
    CGFloat frac = 0;
    NSUInteger g = [lm glyphIndexForPoint:c inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:&frac];
    if (g >= lm.numberOfGlyphs || !NSPointInRect(c, [lm boundingRectForGlyphRange:NSMakeRange(g, 1) inTextContainer:self.textContainer]))
        return NSNotFound;
    NSUInteger i = [lm characterIndexForGlyphAtIndex:g];
    return [self.textStorage attribute:NSLinkAttributeName atIndex:i effectiveRange:NULL] ? i : NSNotFound;
}

- (id)linkAtIndex:(NSUInteger)i {
    return i < self.textStorage.length ? [self.textStorage attribute:NSLinkAttributeName atIndex:i effectiveRange:NULL] : nil;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return [self linkIndexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]] != NSNotFound || [super acceptsFirstMouse:e];
}

- (void)mouseDown:(NSEvent *)e {
    NSUInteger i = [self linkIndexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i == NSNotFound || e.clickCount > 1 || (e.modifierFlags & NSEventModifierFlagShift)) { _pressedLink = NSNotFound; [super mouseDown:e]; return; }
    _pressedLink = i;
}

- (void)mouseUp:(NSEvent *)e {
    NSUInteger pressed = _pressedLink;
    _pressedLink = NSNotFound;
    if (pressed == NSNotFound) { [super mouseUp:e]; return; }
    NSUInteger i = [self linkIndexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    id link = [self linkAtIndex:pressed];
    if (i != NSNotFound && [[self linkAtIndex:i] isEqual:link]) [self activateLinkAtIndex:pressed];
}

- (void)activateLinkAtIndex:(NSUInteger)i {
    id link = [self linkAtIndex:i];
    if (!link) return;
    __weak MarkdownTextView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        MarkdownTextView *me = weakSelf;
        id<NSTextViewDelegate> d = me.delegate;
        if (me && [d respondsToSelector:@selector(textView:clickedOnLink:atIndex:)]) [d textView:me clickedOnLink:link atIndex:i];
    });
}

@end

@implementation MarkdownPreview {
    NSTextStorage *_storage;                 // the text view does not own its storage
    NSScrollView *_scroll;
    MarkdownRenderer *_renderer;
    NSString *_source, *_dir;
    CGFloat _renderedWidth;
    BOOL _rerenderQueued;
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scroll.hasVerticalScroller = YES;
    _scroll.drawsBackground = YES;
    _scroll.backgroundColor = NSColor.textBackgroundColor;
    // TextKit 1 (explicit stack): NSTextBlock / NSTextTable (code boxes, quotes, tables) need it.
    NSTextStorage *storage = [NSTextStorage new];
    NSLayoutManager *lm = [NSLayoutManager new];
    [storage addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(f.size.width, CGFLOAT_MAX)];
    [lm addTextContainer:tc];
    _textView = [[MarkdownTextView alloc] initWithFrame:NSMakeRect(0, 0, f.size.width, f.size.height) textContainer:tc];
    _storage = storage;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.richText = YES;
    _textView.drawsBackground = YES;
    _textView.backgroundColor = NSColor.textBackgroundColor;
    _textView.verticallyResizable = YES;
    _textView.horizontallyResizable = NO;
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.minSize = NSMakeSize(0, 0);
    _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _textView.textContainer.containerSize = NSMakeSize(f.size.width, CGFLOAT_MAX);
    _textView.textContainer.widthTracksTextView = YES;
    _textView.usesFindBar = YES;
    _textView.incrementalSearchingEnabled = YES;
    _textView.layoutManager.allowsNonContiguousLayout = YES;
    _textView.linkTextAttributes = @{NSCursorAttributeName: NSCursor.pointingHandCursor};   // colour set per link by the renderer
    _textView.delegate = self;
    _textView.textContainerInset = NSMakeSize(32, 24);
    _textView.accessibilityLabel = FTL(@"Markdown preview");
    _scroll.documentView = _textView;
    [self addSubview:_scroll];
    _scale = gMarkdownScale;
    _renderer = [MarkdownRenderer new];
    __weak MarkdownPreview *weakSelf = self;
    _renderer.onImageLoaded = ^{ [weakSelf scheduleRerender]; };
    return self;
}

- (MarkdownRenderer *)renderer { return _renderer; }

- (void)dealloc { _textView.delegate = nil; }      // NSTextView's delegate is not zeroing-weak

- (CGFloat)contentWidth { return MAX(200, self.bounds.size.width - 2 * _textView.textContainerInset.width - 20); }

- (void)updateInsets {
    CGFloat w = self.bounds.size.width, side = MAX(24, (w - 880) / 2);
    if (fabs(_textView.textContainerInset.width - side) > 0.5) _textView.textContainerInset = NSMakeSize(side, 24);
}

- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    [self updateInsets];
    if (_source && fabs(self.contentWidth - _renderedWidth) > 40) [self scheduleRerender];
}

- (void)setMarkdown:(NSString *)source baseDir:(NSString *)dir {
    _source = [source copy];
    _dir = [dir copy];
    [self render];
}

- (void)render {
    _rerenderQueued = NO;
    if (!_source) return;
    [self updateInsets];
    _renderedWidth = self.contentWidth;
    _renderer.baseDir = _dir;
    _renderer.maxImageWidth = MIN(_renderedWidth, 840);
    NSAttributedString *a = [_renderer render:MDParse(_source)];
    if (fabs(_scale - 1) > 0.01) a = scaled(a, _scale);
    NSPoint keep = _scroll.contentView.bounds.origin;
    [_textView.textStorage setAttributedString:a];
    [_textView scrollPoint:keep];
}

// Text zoom: scales fonts, indents and spacing so the text re-flows; images keep their size.
static NSAttributedString *scaled(NSAttributedString *src, CGFloat k) {
    NSMutableAttributedString *m = [src mutableCopy];
    NSRange all = NSMakeRange(0, m.length);
    [src enumerateAttribute:NSFontAttributeName inRange:all options:0 usingBlock:^(NSFont *f, NSRange r, BOOL *stop) {
        if (f) [m addAttribute:NSFontAttributeName value:[NSFont fontWithDescriptor:f.fontDescriptor size:f.pointSize * k] ?: f range:r];
    }];
    [src enumerateAttribute:NSParagraphStyleAttributeName inRange:all options:0 usingBlock:^(NSParagraphStyle *p, NSRange r, BOOL *stop) {
        if (!p) return;
        NSMutableParagraphStyle *q = [p mutableCopy];
        q.headIndent *= k; q.firstLineHeadIndent *= k;
        q.paragraphSpacing *= k; q.paragraphSpacingBefore *= k;
        NSMutableArray *tabs = [NSMutableArray array];
        for (NSTextTab *t in p.tabStops) [tabs addObject:[[NSTextTab alloc] initWithTextAlignment:t.alignment location:t.location * k options:t.options]];
        q.tabStops = tabs;
        [m addAttribute:NSParagraphStyleAttributeName value:q range:r];
    }];
    return m;
}

+ (CGFloat)defaultScale { return gMarkdownScale; }
+ (void)setDefaultScale:(CGFloat)s { gMarkdownScale = MIN(MAX(round(s * 10) / 10, 0.5), 3); }

- (void)setScale:(CGFloat)s {
    s = MIN(MAX(s, 0.5), 3);
    if (fabs(s - _scale) < 0.001) return;
    _scale = s;
    [self render];
}

- (void)scheduleRerender {
    if (_rerenderQueued) return;
    _rerenderQueued = YES;
    __weak MarkdownPreview *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf render]; });
}

// Lays out up to `loc` and grows the text view so scrolling there is possible.
- (CGFloat)yForLocation:(NSUInteger)loc {
    NSLayoutManager *lm = _textView.layoutManager;
    NSUInteger len = _textView.textStorage.length;
    if (!len) return 0;
    [lm ensureLayoutForCharacterRange:NSMakeRange(0, MIN(len, loc + 1))];
    [_textView sizeToFit];
    NSUInteger g = [lm glyphIndexForCharacterAtIndex:MIN(loc, len - 1)];
    NSRect r = [lm lineFragmentRectForGlyphAtIndex:g effectiveRange:NULL];
    return r.origin.y + _textView.textContainerOrigin.y;
}

- (void)scrollToSourceLine:(CGFloat)line {
    NSArray<NSNumber *> *L = _renderer.mapLines, *C = _renderer.mapLocs;
    if (!L.count) return;
    NSInteger lo = 0, hi = (NSInteger)L.count - 1;
    while (lo < hi) { NSInteger mid = (lo + hi + 1) / 2; if (L[mid].doubleValue <= line) lo = mid; else hi = mid - 1; }
    CGFloat y;
    if (line < L[0].doubleValue) y = 0;
    else {
        CGFloat y0 = [self yForLocation:C[lo].unsignedIntegerValue];
        CGFloat y1 = lo + 1 < (NSInteger)L.count ? [self yForLocation:C[lo + 1].unsignedIntegerValue] : NSMaxY(_textView.bounds);
        CGFloat l0 = L[lo].doubleValue, l1 = lo + 1 < (NSInteger)L.count ? L[lo + 1].doubleValue : l0 + 1;
        y = y0 + (y1 - y0) * MIN(1, MAX(0, (line - l0) / MAX(1, l1 - l0)));
    }
    [_textView scrollPoint:NSMakePoint(0, MAX(0, y - 8))];
}

- (BOOL)scrollToAnchor:(NSString *)slug {
    NSString *s = (slug.stringByRemovingPercentEncoding ?: slug).lowercaseString;
    NSNumber *loc = _renderer.anchors[s] ?: _renderer.anchors[MDSlug(s)];
    if (!loc) return NO;
    [_textView scrollPoint:NSMakePoint(0, MAX(0, [self yForLocation:loc.unsignedIntegerValue] - 12))];
    return YES;
}

- (BOOL)textView:(NSTextView *)tv clickedOnLink:(id)link atIndex:(NSUInteger)i {
    NSString *href = [link isKindOfClass:NSURL.class] ? [link absoluteString] : [link description];
    if ([href hasPrefix:@"#"]) { if (![self scrollToAnchor:[href substringFromIndex:1]]) NSBeep(); return YES; }
    if (self.onLink) self.onLink(href);
    return YES;
}

- (BOOL)isAccessibilityElement { return NO; }

@end

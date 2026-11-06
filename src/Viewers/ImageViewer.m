#import "ImageViewer.h"
#import "Localization.h"
#import "CanvasView.h"
#import "SVGImage.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat kMaxDecodePixels = 24e6;       // ~96 MB decoded; bigger images stay slightly soft at 1:1
static const CGFloat kMinZoom = 0.02, kMaxZoom = 32;
static const NSUInteger kMaxAnimatedPixels = 4e6;

@interface ImagePreviewView () <NSPasteboardItemDataProvider>
@end

@implementation ImagePreviewView {
    NSString *_path;
    CGImageRef _img;
    CGSize _origPixels;                  // after EXIF orientation, before our rotation
    CGFloat _decodedLong;                // long side of _img in pixels
    BOOL _decoding, _decodeAgain, _hasAlpha;
    BOOL _vector;                        // SVG: rasterized at whatever size the zoom needs
    BOOL _fit;
    CGFloat _scale;                      // points per original pixel when !_fit
    NSPoint _center;                     // image point (rotated pixel space) shown at the view centre
    NSInteger _rot;
    NSUInteger _frames;
    BOOL _animStop, _animating;
    NSPoint _dragStart;
    NSStackView *_tools;
    NSTextField *_percent;
}

- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path {
    if (!(self = [super initWithFrame:frame])) return nil;
    _path = [path copy];
    _vector = [[UTType typeWithFilenameExtension:path.pathExtension] conformsToType:UTTypeSVG];
    _fit = YES;
    _scale = 1;
    FTClipToBounds(self);
    return self;
}

- (void)dealloc { _animStop = YES; if (_img) CGImageRelease(_img); }
- (BOOL)isOpaque { return YES; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

#pragma mark Geometry (rotated pixel space)

- (CGSize)pixelSize { return _rot % 2 ? CGSizeMake(_origPixels.height, _origPixels.width) : _origPixels; }
- (NSRect)viewport { return _fit ? NSInsetRect(self.bounds, 16, 16) : self.bounds; }

static const CGFloat kVectorFitLong = 512;          // a 16-pt SVG icon is shown this big, sharp

// Raster images never grow past 1:1 when fitted; vectors grow to fill the box (long side ≤ kVectorFitLong).
static CGFloat fitFor(CGSize p, NSSize box, BOOL vector) {
    if (p.width <= 0 || p.height <= 0 || box.width <= 0 || box.height <= 0) return 1;
    CGFloat fill = MIN(box.width / p.width, box.height / p.height);
    if (!vector) return MIN(1, fill);
    return MIN(fill, MAX(1, kVectorFitLong / MAX(p.width, p.height)));
}

- (CGFloat)fitScale { return fitFor(self.pixelSize, NSInsetRect(self.bounds, 16, 16).size, _vector); }

- (CGFloat)scale { return _fit ? self.fitScale : _scale; }
- (BOOL)fitsWindow { return _fit; }
- (NSInteger)rotation { return _rot; }
- (NSUInteger)frameCount { return _frames; }
- (BOOL)isVector { return _vector; }
- (CGFloat)zoomPercent { return round(self.scale * 100); }
- (NSView *)focusView { return self; }

// Keeps at least a quarter of the viewport covered by the image.
- (void)clampCenter {
    CGSize p = self.pixelSize;
    NSRect v = self.viewport;
    CGFloat k = self.scale, hx = v.size.width / 2 / k, hy = v.size.height / 2 / k;
    CGFloat mx = MIN(hx, p.width / 2) * 0.5, my = MIN(hy, p.height / 2) * 0.5;
    _center.x = p.width * k <= v.size.width ? p.width / 2 : MIN(MAX(_center.x, hx - mx), p.width - hx + mx);
    _center.y = p.height * k <= v.size.height ? p.height / 2 : MIN(MAX(_center.y, hy - my), p.height - hy + my);
}

- (NSRect)imageRect {
    CGSize p = self.pixelSize;
    NSRect v = self.viewport;
    CGFloat k = self.scale;
    if (_fit) { _center = NSMakePoint(p.width / 2, p.height / 2); }
    return NSMakeRect(NSMidX(v) - _center.x * k, NSMidY(v) - _center.y * k, p.width * k, p.height * k);
}

- (void)setZoom:(CGFloat)z around:(NSPoint)vp {
    NSRect r = self.imageRect;
    CGFloat old = self.scale;
    NSPoint ip = NSMakePoint((vp.x - r.origin.x) / old, (vp.y - r.origin.y) / old);   // image point under the cursor
    z = MIN(MAX(z, MIN(kMinZoom, self.fitScale)), kMaxZoom);
    _fit = NO;
    _scale = z;
    NSRect v = self.viewport;
    _center = NSMakePoint(ip.x - (vp.x - NSMidX(v)) / z, ip.y - (vp.y - NSMidY(v)) / z);
    [self clampCenter];
    [self changed];
}

static const CGFloat kSteps[] = {0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32};

- (CGFloat)nextStep:(BOOL)up {
    CGFloat s = self.scale;
    NSUInteger n = sizeof kSteps / sizeof *kSteps;
    if (up) { for (NSUInteger i = 0; i < n; i++) if (kSteps[i] > s * 1.01) return kSteps[i]; return kMaxZoom; }
    for (NSUInteger i = n; i-- > 0;) if (kSteps[i] < s * 0.99) return kSteps[i];
    return kMinZoom;
}

- (NSPoint)viewCenter { return NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)); }
- (void)ftZoomIn { [self setZoom:[self nextStep:YES] around:self.viewCenter]; }
- (void)ftZoomOut {
    CGFloat z = [self nextStep:NO];
    CGFloat fit = self.fitScale;
    if (!_fit && z <= fit * 1.001 && self.scale > fit * 1.001) { [self ftZoomToFit]; return; }   // stepping out lands on "fit"
    [self setZoom:z around:self.viewCenter];
}
- (void)ftZoomToFit { _fit = YES; [self changed]; }
- (void)ftZoomActualSize { [self setZoom:1 around:self.viewCenter]; }

- (void)panBy:(NSSize)d {
    if (_fit) return;
    _center.x -= d.width / _scale;
    _center.y -= d.height / _scale;
    [self clampCenter];
    [self changed];
}

- (void)ftRotate:(NSInteger)q {
    CGSize before = self.pixelSize;
    NSPoint c = _center;
    _rot = ((_rot + q) % 4 + 4) % 4;
    q = ((q % 4) + 4) % 4;
    for (NSInteger i = 0; i < q; i++) { c = NSMakePoint(before.height - c.y, c.x); before = CGSizeMake(before.height, before.width); }
    _center = c;
    [self clampCenter];
    [self changed];
}

#pragma mark Drawing

// Light checks in light mode, dark checks in dark mode, so currentColor icons (black / white) stay readable.
static NSColor *checkerboard(BOOL dark) {
    static NSColor *c[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int d = 0; d < 2; d++) {
            CGFloat a = d ? 0.17 : 0.80, b = d ? 0.23 : 0.92;
            NSImage *tile = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect r) {
                [[NSColor colorWithWhite:a alpha:1] setFill]; NSRectFill(r);
                [[NSColor colorWithWhite:b alpha:1] setFill];
                NSRectFill(NSMakeRect(0, 0, 8, 8)); NSRectFill(NSMakeRect(8, 8, 8, 8));
                return YES;
            }];
            c[d] = [NSColor colorWithPatternImage:tile];
        }
    });
    return c[dark ? 1 : 0];
}

- (BOOL)isDark {
    return [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}

- (void)drawRect:(NSRect)dirty {
    dirty = NSIntersectionRect(dirty, self.bounds);
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    if (!_img) return;
    NSRect r = self.imageRect;
    if (!_fit || r.size.width >= 1) r = NSMakeRect(round(r.origin.x), round(r.origin.y), round(r.size.width), round(r.size.height));
    if (_hasAlpha) { [checkerboard(self.isDark) setFill]; NSRectFill(NSIntersectionRect(r, dirty)); }
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGFloat s = self.window.backingScaleFactor ?: 2;
    CGFloat devPerPixel = r.size.width * s / MAX(1, (_rot % 2 ? CGImageGetHeight(_img) : CGImageGetWidth(_img)));
    CGContextSetInterpolationQuality(cg, devPerPixel > 2.5 ? kCGInterpolationNone : kCGInterpolationHigh);   // crisp pixels when zoomed in
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, NSMidX(r), NSMidY(r));
    CGContextRotateCTM(cg, _rot * M_PI_2);                  // flipped view: positive angle turns clockwise on screen
    CGFloat w = _rot % 2 ? r.size.height : r.size.width, h = _rot % 2 ? r.size.width : r.size.height;
    CGContextScaleCTM(cg, 1, -1);                           // CGImage draws bottom-up
    CGContextDrawImage(cg, CGRectMake(-w / 2, -h / 2, w, h), _img);
    CGContextRestoreGState(cg);
}

#pragma mark Decoding

// Text colour of the current appearance, for SVG icons drawn with currentColor.
- (NSString *)inkHex {
    __block NSString *hex = @"#000000";
    [(self.window.effectiveAppearance ?: self.effectiveAppearance) performAsCurrentDrawingAppearance:^{
        NSColor *c = [NSColor.labelColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (c) hex = [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(c.redComponent * 255), (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255)];
    }];
    return hex;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (_vector && _img) { _decodedLong = 0; [self decodeNow]; }       // currentColor follows light / dark
}

- (CGSize)decodedSize { return _img ? CGSizeMake(CGImageGetWidth(_img), CGImageGetHeight(_img)) : CGSizeZero; }

// Long side in pixels needed for the current zoom, never above the original or the cap.
- (CGFloat)wantedLong {
    CGFloat s = self.window.backingScaleFactor ?: 2;
    CGFloat origLong = MAX(_origPixels.width, _origPixels.height);
    if (origLong <= 0) return MAX(self.bounds.size.width, self.bounds.size.height) * s;
    CGFloat want = origLong * self.scale * s;
    CGFloat cap = sqrt(kMaxDecodePixels * origLong / MAX(1, MIN(_origPixels.width, _origPixels.height)));
    return ceil(MAX(64, MIN(_vector ? want : MIN(want, origLong), cap)));
}

// Draws the SVG into a bitmap whose long side is `longSide` pixels.
static CGImageRef rasterizeSVG(NSImage *svg, CGFloat longSide) {
    NSSize n = svg.size;
    if (n.width <= 0 || n.height <= 0 || longSide <= 0) return NULL;
    CGFloat k = longSide / MAX(n.width, n.height);
    size_t w = MAX(1, (size_t)llround(n.width * k)), h = MAX(1, (size_t)llround(n.height * k));
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!cg) return NULL;
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    [svg drawInRect:NSMakeRect(0, 0, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);
    return img;
}

- (void)viewDidMoveToWindow {
    if (!self.window) { _animStop = YES; _animating = NO; return; }
    _animStop = NO;
    [self decodeIfNeeded];
}
- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    if (self.window && !self.inLiveResize) [self decodeIfNeeded];
}
- (void)viewDidEndLiveResize { [super viewDidEndLiveResize]; [self decodeIfNeeded]; }

- (void)decodeIfNeeded {
    if (!self.window || _animating) return;
    CGFloat want = self.wantedLong;
    CGFloat aspect = _origPixels.width > 0 ? MIN(_origPixels.width, _origPixels.height) / MAX(_origPixels.width, _origPixels.height) : 1;
    BOOL worthShrinking = want < _decodedLong * 0.7 && (_decodedLong * _decodedLong - want * want) * aspect * 4 > 4e6;
    if (_img && want <= _decodedLong * 1.2 && !worthShrinking) return;                  // close enough
    if (_img && want < _decodedLong) {                                                  // zoomed out: free memory a bit later
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(decodeNow) object:nil];
        [self performSelector:@selector(decodeNow) withObject:nil afterDelay:0.6];
        return;
    }
    [self decodeNow];
}

- (void)decodeNow {
    if (_decoding) { _decodeAgain = YES; return; }
    _decoding = YES;
    CGFloat want = self.wantedLong;
    NSURL *url = [NSURL fileURLWithPath:_path];
    BOOL first = _img == NULL;
    NSSize box = NSInsetRect(self.bounds, 16, 16).size;
    CGFloat backing = self.window.backingScaleFactor ?: 2, cap = kMaxDecodePixels;
    BOOL vector = _vector;
    NSString *ink = vector ? [self inkHex] : nil;
    __weak ImagePreviewView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CGImageRef img = NULL; CGSize px = CGSizeZero; BOOL alpha = NO; size_t frames = 0;
        if (vector) {
            NSImage *svg = FTSVGImageWithCurrentColor([NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil], ink);
            px = svg.size;                                         // points = pixels at 100%
            CGFloat w = want;
            if (first && px.width > 0 && px.height > 0) {          // size unknown on the main thread: fit
                CGFloat longSide = MAX(px.width, px.height);
                w = ceil(MAX(64, MIN(longSide * fitFor(px, box, YES) * backing, sqrt(cap * longSide / MIN(px.width, px.height)))));
            }
            img = rasterizeSVG(svg, w);
            alpha = YES; frames = 1;
        }
        CGImageSourceRef src = vector ? NULL : CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (src) {
            NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
            px = CGSizeMake([props[(id)kCGImagePropertyPixelWidth] doubleValue], [props[(id)kCGImagePropertyPixelHeight] doubleValue]);
            if ([props[(id)kCGImagePropertyOrientation] intValue] >= 5) px = CGSizeMake(px.height, px.width);
            alpha = [props[(id)kCGImagePropertyHasAlpha] boolValue];
            frames = CGImageSourceGetCount(src);
            CGFloat w = want;
            if (first && px.width > 0 && px.height > 0) {          // sizes not known yet on the main thread: fit
                CGFloat fit = MIN(1, MIN(box.width / px.width, box.height / px.height));
                CGFloat longSide = MAX(px.width, px.height);
                w = ceil(MAX(64, MIN(MIN(longSide * fit * backing, longSide), sqrt(cap * longSide / MIN(px.width, px.height)))));
            }
            NSDictionary *opt = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                  (id)kCGImageSourceShouldCacheImmediately: @YES,
                                  (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1, w))};
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
            CFRelease(src);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ImagePreviewView *me = weakSelf;
            if (!me) { if (img) CGImageRelease(img); return; }
            me->_decoding = NO;
            if (!img) { if (!me->_img && me.onFailure) me.onFailure(); return; }
            if (me->_img) CGImageRelease(me->_img);
            me->_img = img;
            me->_origPixels = px;
            me->_hasAlpha = alpha;
            me->_frames = frames;
            me->_decodedLong = MAX(CGImageGetWidth(img), CGImageGetHeight(img));
            me.needsDisplay = YES;
            [me notify];
            if (first && frames > 1 && px.width * px.height <= kMaxAnimatedPixels) [me startAnimation];
            if (me->_decodeAgain) { me->_decodeAgain = NO; [me decodeIfNeeded]; }

        });
    });
}

// Animated GIF / APNG / HEICS: frames come from ImageIO at full size, so only small animations play.
- (void)startAnimation {
    _animating = YES;
    __weak ImagePreviewView *weakSelf = self;
    CGAnimateImageAtURLWithBlock((__bridge CFURLRef)[NSURL fileURLWithPath:_path], NULL, ^(size_t i, CGImageRef frame, bool *stop) {
        ImagePreviewView *me = weakSelf;
        if (!me || me->_animStop) { *stop = true; if (me) me->_animating = NO; return; }
        CGImageRetain(frame);
        if (me->_img) CGImageRelease(me->_img);
        me->_img = frame;
        me->_decodedLong = MAX(CGImageGetWidth(frame), CGImageGetHeight(frame));
        me.needsDisplay = YES;
    });
}

#pragma mark State changes

- (void)changed {
    self.needsDisplay = YES;
    [self decodeIfNeeded];
    [self notify];
}

- (void)notify {
    _percent.stringValue = [NSString stringWithFormat:@"%.0f%%", self.zoomPercent];
    if (self.onChange) self.onChange();
}

- (NSString *)info {
    if (!_img) return FTL(@"Decoding…");
    NSMutableString *s = [NSMutableString stringWithFormat:@"%.0f × %.0f   %@", _origPixels.width, _origPixels.height,
                          _path.pathExtension.uppercaseString];
    if (_frames > 1) [s appendFormat:FTL(@"   %lu frames%@"), (unsigned long)_frames, _animating ? @"" : FTL(@" (too large, first frame only)")];
    [s appendFormat:@"   %@%.0f%%", _fit ? FTL(@"Fit ") : @"", self.zoomPercent];
    if (_rot) [s appendFormat:FTL(@"   Rotated %ld°"), (long)_rot * 90];
    return s;
}

#pragma mark Input

- (void)magnifyWithEvent:(NSEvent *)e {
    [self setZoom:self.scale * (1 + e.magnification) around:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)smartMagnifyWithEvent:(NSEvent *)e { [self toggleZoomAt:[self convertPoint:e.locationInWindow fromView:nil]]; }

- (void)toggleZoomAt:(NSPoint)p {
    if (_fit && self.fitScale < 1) [self setZoom:1 around:p];
    else [self ftZoomToFit];
}

- (void)scrollWheel:(NSEvent *)e {
    CGFloat dy = e.scrollingDeltaY, dx = e.scrollingDeltaX;
    if (!e.hasPreciseScrollingDeltas) { dx *= 10; dy *= 10; }
    if (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
        [self setZoom:self.scale * pow(1.01, dy) around:[self convertPoint:e.locationInWindow fromView:nil]];
        return;
    }
    [self panBy:NSMakeSize(dx, dy)];
}

- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (e.clickCount == 2) { [self toggleZoomAt:p]; return; }
    _dragStart = p;
    if (!_fit) [NSCursor.closedHandCursor push];
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    [self panBy:NSMakeSize(p.x - _dragStart.x, p.y - _dragStart.y)];
    _dragStart = p;
}

- (void)mouseUp:(NSEvent *)e { if (!_fit) [NSCursor pop]; }

- (void)resetCursorRects { if (!_fit) [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }

- (void)keyDown:(NSEvent *)e { [self interpretKeyEvents:@[e]]; }
- (void)moveLeft:(id)s  { [self panBy:NSMakeSize(60, 0)]; }
- (void)moveRight:(id)s { [self panBy:NSMakeSize(-60, 0)]; }
- (void)moveUp:(id)s    { [self panBy:NSMakeSize(0, 60)]; }
- (void)moveDown:(id)s  { [self panBy:NSMakeSize(0, -60)]; }
- (void)doCommandBySelector:(SEL)sel { if ([self respondsToSelector:sel]) [super doCommandBySelector:sel]; }

#pragma mark Copy

// Puts the file itself on the pasteboard (as a file and as image data of its own type), plus PNG for
// apps that only take common formats. PNG is produced only if someone actually pastes it.
- (void)copy:(id)sender { [self writeToPasteboard:NSPasteboard.generalPasteboard]; }

- (void)writeToPasteboard:(NSPasteboard *)pb {
    [pb clearContents];
    NSPasteboardItem *item = [NSPasteboardItem new];
    NSURL *url = [NSURL fileURLWithPath:_path];
    [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    NSString *uti = nil;
    [url getResourceValue:&uti forKey:NSURLTypeIdentifierKey error:nil];
    NSData *raw = [NSData dataWithContentsOfFile:_path options:NSDataReadingMappedIfSafe error:nil];
    if (uti && raw) [item setData:raw forType:uti];
    if (![uti isEqualToString:NSPasteboardTypePNG]) [item setDataProvider:self forTypes:@[NSPasteboardTypePNG]];
    [pb writeObjects:@[item]];
}

- (void)pasteboard:(NSPasteboard *)pb item:(NSPasteboardItem *)item provideDataForType:(NSPasteboardType)type {
    CGImageRef img = NULL;
    if (_vector) {                                         // @2x so it stays sharp on Retina
        NSImage *svg = FTSVGImageWithCurrentColor([NSData dataWithContentsOfFile:_path options:NSDataReadingMappedIfSafe error:nil], @"#000000");
        img = rasterizeSVG(svg, MIN(MAX(svg.size.width, svg.size.height) * 2, 8192));
    } else {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:_path], NULL);
        if (!src) return;
        NSDictionary *opt = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES, (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(_origPixels.width, _origPixels.height) ?: 4096)};
        img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
        CFRelease(src);
    }
    if (!img) return;
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:img] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CGImageRelease(img);
    [item setData:png forType:type];
}

- (BOOL)validateMenuItem:(NSMenuItem *)m { return m.action != @selector(copy:) || _img != NULL; }

#pragma mark Tools / accessibility

- (NSView *)toolsView {
    if (_tools) return _tools;
    _percent = FTToolLabel(44);
    _percent.stringValue = [NSString stringWithFormat:@"%.0f%%", self.zoomPercent];
    _tools = FTToolStrip(@[FTToolButton(@"minus.magnifyingglass", FTL(@"Zoom Out (⌘-)"), self, @selector(ftZoomOut)),
                           _percent,
                           FTToolButton(@"plus.magnifyingglass", FTL(@"Zoom In (⌘+)"), self, @selector(ftZoomIn)),
                           FTToolButton(@"arrow.down.right.and.arrow.up.left", FTL(@"Fit to Window (⌘0)"), self, @selector(ftZoomToFit)),
                           FTToolButton(@"1.magnifyingglass", FTL(@"Actual Size"), self, @selector(ftZoomActualSize)),
                           FTToolButton(@"rotate.left", FTL(@"Rotate Left"), self, @selector(rotateLeft:)),
                           FTToolButton(@"rotate.right", FTL(@"Rotate Right"), self, @selector(rotateRight:))]);
    return _tools;
}

- (void)rotateLeft:(id)s { [self ftRotate:-1]; }
- (void)rotateRight:(id)s { [self ftRotate:1]; }

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityImageRole; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:FTL(@"Image %@, %@"), _path.lastPathComponent, self.info]; }

@end

NSButton *FTToolButton(NSString *symbol, NSString *label, id target, SEL action) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label]
                ?: [NSImage imageWithSystemSymbolName:@"circle" accessibilityDescription:label];
    NSButton *b = [NSButton buttonWithImage:img target:target action:action];
    b.bordered = NO;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.toolTip = label;
    b.contentTintColor = NSColor.secondaryLabelColor;
    [b.widthAnchor constraintEqualToConstant:20].active = YES;
    [b.heightAnchor constraintEqualToConstant:18].active = YES;
    return b;
}

NSTextField *FTToolLabel(CGFloat width) {
    NSTextField *l = [NSTextField labelWithString:@""];
    l.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    l.textColor = NSColor.secondaryLabelColor;
    l.alignment = NSTextAlignmentCenter;
    [l.widthAnchor constraintEqualToConstant:width].active = YES;
    return l;
}

NSStackView *FTToolStrip(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 2;
    s.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 4);
    return s;
}

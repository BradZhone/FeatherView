// Renders the FeatherView app icon into an .iconset directory: make_icon <out.iconset> [preview.png]
// A glowing quill on a deep-space squircle: the vane fades violet → cyan, its lower half turns into
// circuit traces and it breaks into pixels at the edge; an orbit ring passes behind and in front of it.
// Below 64 px the fine detail is dropped so the silhouette stays crisp.
#import <Cocoa/Cocoa.h>

static CGColorRef C(uint32_t rgb, CGFloat a) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:a].CGColor;
}

static CGGradientRef gradient(const uint32_t *rgb, const CGFloat *alpha, const CGFloat *loc, size_t n) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat comps[40];
    for (size_t i = 0; i < n; i++) {
        comps[i * 4] = ((rgb[i] >> 16) & 255) / 255.0;
        comps[i * 4 + 1] = ((rgb[i] >> 8) & 255) / 255.0;
        comps[i * 4 + 2] = (rgb[i] & 255) / 255.0;
        comps[i * 4 + 3] = alpha[i];
    }
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, loc, n);
    CGColorSpaceRelease(cs);
    return g;
}

// Deterministic, so every build draws the same icon.
static uint32_t gSeed = 12345;
static CGFloat rnd(void) { gSeed = gSeed * 1664525u + 1013904223u; return (gSeed >> 8) / 16777216.0; }

// Feather frame: rachis along +y from the quill (y = -345) to the tip (y = 336); +x is the wide side.
static CGPathRef vanePath(void) {
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, 2, 336);
    CGPathAddCurveToPoint(p, NULL, 120, 250, 180, 60, 150, -90);
    CGPathAddCurveToPoint(p, NULL, 135, -160, 70, -205, 8, -215);
    CGPathAddLineToPoint(p, NULL, -8, -215);
    CGPathAddCurveToPoint(p, NULL, -70, -195, -120, -140, -128, -60);
    CGPathAddCurveToPoint(p, NULL, -140, 80, -95, 240, 2, 336);
    CGPathCloseSubpath(p);
    return p;
}

// Rachis x at height y: a gentle S so the feather looks alive.
static CGFloat spineX(CGFloat y) { return 6 * sin((y + 330) / 660 * M_PI) - 4 * (y / 330); }

static void drawBackground(CGContextRef c, BOOL detail) {
    // deep navy → near-black, lit from the upper left
    uint32_t bg[] = {0x1E2F78, 0x0E1640, 0x060A1E};
    CGFloat ba[] = {1, 1, 1}, bl[] = {0, 0.55, 1};
    CGGradientRef g = gradient(bg, ba, bl, 3);
    CGContextDrawRadialGradient(c, g, CGPointMake(360, 780), 0, CGPointMake(512, 512), 780, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);

    CGFloat gloc[] = {0, 1};
    uint32_t blue[] = {0x3D7BFF, 0x3D7BFF};                                        // glow behind the feather
    CGFloat ba2[] = {0.40, 0};
    g = gradient(blue, ba2, gloc, 2);
    CGContextDrawRadialGradient(c, g, CGPointMake(540, 530), 0, CGPointMake(540, 530), 440, 0);
    CGGradientRelease(g);
    uint32_t violet[] = {0xA855F7, 0xA855F7};                                      // and a violet one at the quill
    CGFloat va[] = {0.26, 0};
    g = gradient(violet, va, gloc, 2);
    CGContextDrawRadialGradient(c, g, CGPointMake(320, 290), 0, CGPointMake(320, 290), 340, 0);
    CGGradientRelease(g);

    if (!detail) return;
    // engineering grid, fading out towards the edges
    const CGFloat step = 824.0 / 16;
    CGContextSetLineWidth(c, 1.4);
    for (int k = 0; k <= 16; k++) {
        CGFloat v = 100 + k * step;
        for (int seg = 0; seg < 16; seg++) {
            CGFloat a0 = 100 + seg * step, a1 = a0 + step, mid = (a0 + a1) / 2;
            for (int axis = 0; axis < 2; axis++) {
                CGFloat x = axis ? v : mid, y = axis ? mid : v;
                CGFloat fade = MAX(0, 1 - hypot(x - 520, y - 520) / 470);
                if (fade <= 0) continue;
                CGContextSetStrokeColorWithColor(c, C(0x7FA8FF, 0.11 * fade));
                if (axis) { CGContextMoveToPoint(c, v, a0); CGContextAddLineToPoint(c, v, a1); }
                else { CGContextMoveToPoint(c, a0, v); CGContextAddLineToPoint(c, a1, v); }
                CGContextStrokePath(c);
            }
        }
    }
    for (int x = 0; x <= 16; x++) for (int y = 0; y <= 16; y++) {                 // intersections
        CGFloat px = 100 + x * step, py = 100 + y * step;
        CGFloat fade = MAX(0, 1 - hypot(px - 520, py - 520) / 430);
        if (fade <= 0.05) continue;
        CGContextSetFillColorWithColor(c, C(0xA9C6FF, 0.30 * fade));
        CGContextFillEllipseInRect(c, CGRectMake(px - 2.4, py - 2.4, 4.8, 4.8));
    }
    // fine grain so the gradients don't look flat
    gSeed = 99;
    for (int k = 0; k < 2600; k++) {
        CGFloat x = 100 + rnd() * 824, y = 100 + rnd() * 824, a = rnd() * 0.05;
        CGContextSetFillColorWithColor(c, C(rnd() > 0.5 ? 0xFFFFFF : 0x000000, a));
        CGContextFillRect(c, CGRectMake(x, y, 2, 2));
    }
}

// Orbit: a tilted ellipse. The back half is drawn before the feather, the front half after it.
static CGAffineTransform orbitTransform(void) {
    CGAffineTransform t = CGAffineTransformMakeTranslation(512, 500);
    t = CGAffineTransformRotate(t, 0.42);
    return CGAffineTransformScale(t, 1, 0.30);
}

static void drawOrbit(CGContextRef c, BOOL front, CGFloat px) {
    if (px < 32) return;
    BOOL detail = px > 64;
    CGAffineTransform t = orbitTransform();
    CGFloat r = 360;
    CGMutablePathRef arc = CGPathCreateMutable();
    if (front) CGPathAddArc(arc, &t, 0, 0, r, M_PI, 2 * M_PI, NO);                 // lower half faces us
    else CGPathAddArc(arc, &t, 0, 0, r, 0, M_PI, NO);
    CGContextSaveGState(c);
    CGContextAddPath(c, arc);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineWidth(c, detail ? 5 : 10);
    CGContextReplacePathWithStrokedPath(c);
    CGContextClip(c);
    uint32_t oc[] = {0x67E8F9, 0x818CF8, 0xC084FC};
    CGFloat oa[] = {front ? 0.95 : 0.40, front ? 0.70 : 0.25, front ? 0.12 : 0.05}, ol[] = {0, 0.5, 1};
    CGGradientRef g = gradient(oc, oa, ol, 3);
    CGContextDrawLinearGradient(c, g, CGPointMake(160, 330), CGPointMake(880, 680), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
    if (front && detail) {                                                         // a node riding the ring
        CGPoint p = CGPointApplyAffineTransform(CGPointMake(cos(-0.45) * r, sin(-0.45) * r), t);
        CGContextSaveGState(c);
        CGContextSetShadowWithColor(c, CGSizeZero, 18 * px / 1024, C(0x67E8F9, 1));
        CGContextSetFillColorWithColor(c, C(0xE0FCFF, 1));
        CGContextFillEllipseInRect(c, CGRectMake(p.x - 11, p.y - 11, 22, 22));
        CGContextRestoreGState(c);
    }
    CGPathRelease(arc);
}

// Vane in its own transparency layer so the whole vane gets one glow.
static void drawVane(CGContextRef c, CGPathRef vane, CGFloat px, BOOL detail) {
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeZero, 60 * px / 1024, C(0x4F8BFF, 0.85));
    CGContextBeginTransparencyLayer(c, NULL);

    CGContextSaveGState(c);
    CGContextAddPath(c, vane);
    CGContextClip(c);
    uint32_t vc[] = {0x6D28D9, 0x4F46E5, 0x3B82F6, 0x22D3EE, 0xE0FCFF};            // violet quill → cyan → white tip
    CGFloat va[] = {1, 1, 1, 1, 1}, vl[] = {0, 0.25, 0.52, 0.80, 1};
    CGGradientRef g = gradient(vc, va, vl, 5);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, -220), CGPointMake(0, 340), 0);
    CGGradientRelease(g);
    uint32_t fc[] = {0xFFFFFF, 0xFFFFFF, 0x0B1030, 0x0B1030};                       // fold: left half lit, right half shaded
    CGFloat fa[] = {0.24, 0, 0, 0.32}, fl[] = {0, 0.48, 0.52, 1};
    g = gradient(fc, fa, fl, 4);
    CGContextDrawLinearGradient(c, g, CGPointMake(-140, 0), CGPointMake(170, 0), 0);
    CGGradientRelease(g);

    if (detail) {
        CGContextSetLineCap(c, kCGLineCapRound);                                   // barbs: grooves sweeping up and out
        for (CGFloat y = -200; y < 320; y += 15) {
            for (int side = -1; side <= 1; side += 2) {
                if (side > 0 && y > -195 && y < -10) continue;                    // leave room for the circuit
                CGFloat x0 = spineX(y), len = 230, rise = 105 + (y + 200) * 0.08;
                for (int pass = 0; pass < 2; pass++) {
                    CGFloat dy = pass ? 3 : 0;
                    CGContextMoveToPoint(c, x0, y + dy);
                    CGContextAddQuadCurveToPoint(c, x0 + side * len * 0.55, y + dy + rise * 0.35, x0 + side * len, y + dy + rise);
                    CGContextSetStrokeColorWithColor(c, pass ? C(0xFFFFFF, 0.14) : C(0x0A1240, 0.32));
                    CGContextSetLineWidth(c, pass ? 1.4 : 2.6);
                    CGContextStrokePath(c);
                }
            }
        }
        CGPoint traces[][4] = {                                                     // circuit in the lower right
            {{8, -178}, {46, -178}, {74, -150}, {110, -150}},
            {{8, -134}, {40, -134}, {66, -108}, {126, -108}},
            {{8, -90},  {58, -90},  {86, -62},  {136, -62}},
            {{8, -46},  {36, -46},  {58, -24},  {104, -24}},
        };
        CGContextSetShadowWithColor(c, CGSizeZero, 10 * px / 1024, C(0x67E8F9, 0.9));
        CGContextSetStrokeColorWithColor(c, C(0xA5F3FC, 0.95));
        CGContextSetLineJoin(c, kCGLineJoinRound);
        for (int k = 0; k < 4; k++) {
            CGContextSetLineWidth(c, 5);
            CGContextMoveToPoint(c, traces[k][0].x, traces[k][0].y);
            for (int m = 1; m < 4; m++) CGContextAddLineToPoint(c, traces[k][m].x, traces[k][m].y);
            CGContextStrokePath(c);
            CGRect pad = CGRectMake(traces[k][3].x - 9, traces[k][3].y - 9, 18, 18);
            CGContextSetFillColorWithColor(c, C(0x0B1030, 1));
            CGContextFillEllipseInRect(c, pad);
            CGContextSetLineWidth(c, 4);
            CGContextStrokeEllipseInRect(c, pad);
        }
        CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
    }
    CGContextRestoreGState(c);

    CGContextAddPath(c, vane);                                                     // crisp rim
    CGContextSetStrokeColorWithColor(c, C(0xFFFFFF, detail ? 0.38 : 0.5));
    CGContextSetLineWidth(c, detail ? 2.5 : 6);
    CGContextStrokePath(c);

    CGContextEndTransparencyLayer(c);
    CGContextRestoreGState(c);
}

static void drawFeather(CGContextRef c, CGFloat px, BOOL detail) {
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, 500, 505);
    CGContextRotateCTM(c, -0.70);
    CGPathRef vane = vanePath();
    drawVane(c, vane, px, detail);

    if (detail) {                                                                  // pixels breaking away from the wide edge
        gSeed = 7;
        for (int k = 0; k < 26; k++) {
            CGFloat t = rnd(), y = 40 + t * 250, edge = 150 - (y - 40) * 0.46 + 6;
            CGFloat x = edge + 14 + rnd() * 90 * (1 - t * 0.5);
            CGFloat sz = 7 + rnd() * 13 * (1 - (x - edge) / 130), a = 0.95 * (1 - (x - edge) / 125);
            if (a <= 0.08 || sz < 4) continue;
            CGContextSaveGState(c);
            CGContextSetShadowWithColor(c, CGSizeZero, 10 * px / 1024, C(0x67E8F9, a));
            CGContextSetFillColorWithColor(c, C(t > 0.5 ? 0xCFFAFE : 0x7DD3FC, a));
            CGContextFillRect(c, CGRectMake(round(x / 6) * 6, round(y / 6) * 6, sz, sz));
            CGContextRestoreGState(c);
        }
    }

    CGMutablePathRef shaft = CGPathCreateMutable();                                // rachis: a glowing shaft
    CGPathMoveToPoint(shaft, NULL, spineX(330), 330);
    for (CGFloat y = 320; y >= -215; y -= 10) CGPathAddLineToPoint(shaft, NULL, spineX(y), y);
    CGContextSaveGState(c);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetShadowWithColor(c, CGSizeZero, 22 * px / 1024, C(0x67E8F9, 1));
    CGContextAddPath(c, shaft);
    CGContextSetStrokeColorWithColor(c, C(0xBAF6FF, 1));
    CGContextSetLineWidth(c, detail ? 9 : 16);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGPathRelease(shaft);

    CGMutablePathRef quill = CGPathCreateMutable();                                // calamus: bare, tapered quill
    CGFloat w = detail ? 10 : 16;
    CGPathMoveToPoint(quill, NULL, spineX(-215) - w, -215);
    CGPathAddCurveToPoint(quill, NULL, -w, -270, -w * 0.4, -320, spineX(-345), -345);
    CGPathAddCurveToPoint(quill, NULL, w * 0.4, -320, w, -270, spineX(-215) + w, -215);
    CGPathCloseSubpath(quill);
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeZero, 26 * px / 1024, C(0x67E8F9, 1));
    CGContextAddPath(c, quill);
    CGContextSetFillColorWithColor(c, C(0xF0FDFF, 1));
    CGContextFillPath(c);
    CGContextRestoreGState(c);
    CGPathRelease(quill);

    CGPoint nib = CGPointMake(spineX(-345), -350);                                 // the spark where it writes
    uint32_t sc[] = {0xFFFFFF, 0x67E8F9, 0x67E8F9};
    CGFloat sa[] = {1, 0.55, 0}, sl[] = {0, 0.3, 1};
    CGGradientRef g = gradient(sc, sa, sl, 3);
    CGContextDrawRadialGradient(c, g, nib, 0, nib, detail ? 70 : 95, 0);
    CGGradientRelease(g);
    if (detail) {
        for (int k = 0; k < 4; k++) {                                              // four tapered rays
            CGFloat ang = k * M_PI_2 + M_PI_4, len = k % 2 ? 34 : 52;
            CGPoint tip = CGPointMake(nib.x + cos(ang) * len, nib.y + sin(ang) * len);
            CGPoint side = CGPointMake(-sin(ang) * 3.2, cos(ang) * 3.2);
            CGContextMoveToPoint(c, nib.x + side.x, nib.y + side.y);
            CGContextAddLineToPoint(c, tip.x, tip.y);
            CGContextAddLineToPoint(c, nib.x - side.x, nib.y - side.y);
            CGContextClosePath(c);
        }
        CGContextSetFillColorWithColor(c, C(0xFFFFFF, 0.92));
        CGContextFillPath(c);
    }
    CGPathRelease(vane);
    CGContextRestoreGState(c);
}

static void drawIcon(CGContextRef c, CGFloat px) {
    BOOL detail = px > 64;
    CGContextScaleCTM(c, px / 1024.0, px / 1024.0);
    CGRect body = CGRectMake(100, 100, 824, 824);                                  // macOS icon grid
    CGPathRef sq = CGPathCreateWithRoundedRect(body, 185, 185, NULL);

    CGContextSaveGState(c);                                                        // drop shadow
    CGContextSetShadowWithColor(c, CGSizeMake(0, -12 * px / 1024), 28 * px / 1024, C(0x000000, 0.45));
    CGContextAddPath(c, sq);
    CGContextSetFillColorWithColor(c, C(0x060A1E, 1));
    CGContextFillPath(c);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CGContextAddPath(c, sq);
    CGContextClip(c);
    drawBackground(c, detail);
    drawOrbit(c, NO, px);
    drawFeather(c, px, detail);
    drawOrbit(c, YES, px);

    CGMutablePathRef sheen = CGPathCreateMutable();                                // glass sheen across the top
    CGPathMoveToPoint(sheen, NULL, 100, 924);
    CGPathAddLineToPoint(sheen, NULL, 924, 924);
    CGPathAddLineToPoint(sheen, NULL, 924, 700);
    CGPathAddCurveToPoint(sheen, NULL, 700, 640, 360, 660, 100, 760);
    CGPathCloseSubpath(sheen);
    CGContextSaveGState(c);
    CGContextAddPath(c, sheen);
    CGContextClip(c);
    uint32_t gc[] = {0xFFFFFF, 0xFFFFFF};
    CGFloat ga[] = {0.13, 0}, gl[] = {0, 1};                                       // fades out before the curve: no hard edge
    CGGradientRef g = gradient(gc, ga, gl, 2);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, 924), CGPointMake(0, 765), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
    CGPathRelease(sheen);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);                                                        // rim light, bright at the top
    CGPathRef inner = CGPathCreateWithRoundedRect(CGRectInset(body, 2, 2), 183, 183, NULL);
    CGContextAddPath(c, inner);
    CGContextSetLineWidth(c, detail ? 4 : 10);
    CGContextReplacePathWithStrokedPath(c);
    CGContextClip(c);
    uint32_t rc[] = {0xFFFFFF, 0x9DB8FF, 0x9DB8FF};
    CGFloat ra[] = {0.55, 0.12, 0}, rl[] = {0, 0.45, 1};
    g = gradient(rc, ra, rl, 3);
    CGContextDrawLinearGradient(c, g, CGPointMake(0, 924), CGPointMake(0, 100), 0);
    CGGradientRelease(g);
    CGContextRestoreGState(c);
    CGPathRelease(inner);
    CGPathRelease(sq);
}

static NSData *render(NSInteger px) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    drawIcon(c, px);
    CGImageRef img = CGBitmapContextCreateImage(c);
    NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:img] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    CGImageRelease(img);
    CGContextRelease(c);
    return png;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: make_icon out.iconset [preview.png]\n"); return 1; }
        NSString *dir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            for (int scale = 1; scale <= 2; scale++) {
                NSString *name = scale == 1 ? [NSString stringWithFormat:@"icon_%@x%@.png", n, n]
                                            : [NSString stringWithFormat:@"icon_%@x%@@2x.png", n, n];
                [render(n.integerValue * scale) writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
            }
        }
        if (argc > 2) [render(1024) writeToFile:@(argv[2]) atomically:YES];
    }
    return 0;
}

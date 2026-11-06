// Renders the Feather app icon into an .iconset directory: make_icon <out.iconset>
#import <Cocoa/Cocoa.h>

static void drawIcon(CGContextRef c, CGFloat s) {
    CGContextScaleCTM(c, s / 1024.0, s / 1024.0);
    // macOS icon grid: 824pt body centred in 1024 canvas
    CGRect body = CGRectMake(100, 100, 824, 824);
    CGPathRef sq = CGPathCreateWithRoundedRect(body, 185, 185, NULL);

    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -10), 24, [NSColor colorWithWhite:0 alpha:0.35].CGColor);
    CGContextAddPath(c, sq);
    CGContextSetFillColorWithColor(c, NSColor.blackColor.CGColor);
    CGContextFillPath(c);
    CGContextRestoreGState(c);

    CGContextSaveGState(c);
    CGContextAddPath(c, sq);
    CGContextClip(c);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {0.36, 0.62, 0.98, 1,   0.16, 0.33, 0.80, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextDrawLinearGradient(c, g, CGPointMake(512, 924), CGPointMake(512, 100), 0);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);

    // feather vane, tilted ~40°
    CGContextTranslateCTM(c, 512, 512);
    CGContextRotateCTM(c, -0.70);
    CGMutablePathRef vane = CGPathCreateMutable();
    CGPathMoveToPoint(vane, NULL, 0, 330);
    CGPathAddCurveToPoint(vane, NULL, 150, 220, 165, -40, 30, -250);
    CGPathAddLineToPoint(vane, NULL, -10, -250);
    CGPathAddCurveToPoint(vane, NULL, -170, -60, -140, 220, 0, 330);
    CGPathCloseSubpath(vane);
    CGContextAddPath(c, vane);
    CGContextSetFillColorWithColor(c, [NSColor colorWithWhite:1 alpha:0.96].CGColor);
    CGContextFillPath(c);

    // notches in the vane
    CGContextSaveGState(c);
    CGContextAddPath(c, vane);
    CGContextClip(c);
    CGContextSetStrokeColorWithColor(c, [NSColor colorWithRed:0.27 green:0.50 blue:0.92 alpha:1].CGColor);
    CGContextSetLineWidth(c, 14);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextMoveToPoint(c, 0, 120);  CGContextAddLineToPoint(c, 170, 210);
    CGContextMoveToPoint(c, 0, -60);  CGContextAddLineToPoint(c, -170, 40);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);

    // shaft
    CGContextSetStrokeColorWithColor(c, [NSColor colorWithRed:0.20 green:0.38 blue:0.85 alpha:1].CGColor);
    CGContextSetLineWidth(c, 16);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextMoveToPoint(c, 0, 300);
    CGContextAddCurveToPoint(c, 6, 100, 8, -120, -6, -330);
    CGContextStrokePath(c);
    CGContextRestoreGState(c);
    CGPathRelease(vane);
    CGPathRelease(sq);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: make_icon out.iconset\n"); return 1; }
        NSString *dir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            for (int scale = 1; scale <= 2; scale++) {
                NSInteger px = n.integerValue * scale;
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kCGImageAlphaPremultipliedLast);
                CGColorSpaceRelease(cs);
                CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
                drawIcon(c, px);
                CGImageRef img = CGBitmapContextCreateImage(c);
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
                NSString *name = scale == 1 ? [NSString stringWithFormat:@"icon_%@x%@.png", n, n]
                                            : [NSString stringWithFormat:@"icon_%@x%@@2x.png", n, n];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
                CGImageRelease(img);
                CGContextRelease(c);
            }
        }
    }
    return 0;
}

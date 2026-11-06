#import <Cocoa/Cocoa.h>
#import "Zoomable.h"

// Image viewer: decoded with ImageIO at the size it is shown (re-decoded when zooming in, capped at
// ~24 MP), fit / 1:1 / zoom with ⌘+ ⌘- pinch ⌘-scroll, drag to pan, rotate, animated GIF/PNG, copy.
@interface ImagePreviewView : NSView <FTZoomable>
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path;
@property (nonatomic, readonly) NSString *info;          // "6016 × 6016   HEIC   37%"
@property (nonatomic, readonly) CGSize decodedSize;      // pixels actually held in memory
@property (nonatomic, readonly) CGSize pixelSize;        // original, after EXIF orientation
@property (nonatomic, readonly) BOOL fitsWindow;
@property (nonatomic, readonly) NSInteger rotation;      // quarter turns clockwise, 0…3
@property (nonatomic, readonly) NSUInteger frameCount;   // > 1 for animations
@property (nonatomic, readonly) BOOL isVector;           // SVG: re-rendered sharp at any zoom
@property (nonatomic, readonly) NSRect imageRect;        // where the image is drawn, view coordinates
- (void)setZoom:(CGFloat)pointsPerPixel around:(NSPoint)viewPoint;
- (void)panBy:(NSSize)delta;
- (void)writeToPasteboard:(NSPasteboard *)pb;            // what ⌘C does (file + image data, PNG on demand)
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, copy) void (^onFailure)(void);     // decode failed -> caller falls back
@end

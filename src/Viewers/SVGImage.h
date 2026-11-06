#import <Cocoa/Cocoa.h>

// The system SVG renderer behind NSImage draws shapes but drops <text> (e.g. GitHub / shields.io badges).
// Draws the shapes with NSImage and the text elements ourselves.
NSImage *FTSVGImage(NSData *data);
// Same, with `currentColor` resolved to hex ("#RRGGBB"); the system renderer would draw it black.
NSImage *FTSVGImageWithCurrentColor(NSData *data, NSString *hex);
BOOL FTLooksLikeSVG(NSData *data);

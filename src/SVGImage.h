#import <Cocoa/Cocoa.h>

// The system SVG renderer behind NSImage draws shapes but drops <text> (e.g. GitHub / shields.io badges).
// Draws the shapes with NSImage and the text elements ourselves.
NSImage *FTSVGImage(NSData *data);
BOOL FTLooksLikeSVG(NSData *data);

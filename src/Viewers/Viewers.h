#import "CanvasView.h"

// Read-only hex dump; only visible rows are formatted.
@interface HexView : CanvasView
- (instancetype)initWithFrame:(NSRect)frame data:(NSData *)data;
@end

#import "ImageViewer.h"

// Quick Look preview; Quartz.framework is loaded on first use only.
NSView *FKCreateQuickLookView(NSRect frame, NSString *path);
void FKCloseQuickLookView(NSView *v);

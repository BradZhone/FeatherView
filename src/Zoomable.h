#import <Cocoa/Cocoa.h>

// Viewers with their own zoom (images, PDF). The status bar shows `toolsView` on the right.
@protocol FTZoomable <NSObject>
- (void)ftZoomIn;
- (void)ftZoomOut;
- (void)ftZoomToFit;
- (void)ftZoomActualSize;
- (void)ftRotate:(NSInteger)quarterTurns;     // +1 clockwise, -1 counter-clockwise; view only, the file is untouched
@property (nonatomic, readonly) CGFloat zoomPercent;
@property (nonatomic, readonly) NSView *toolsView;
@property (nonatomic, readonly) NSView *focusView;
@end

// Small borderless SF Symbol button for status-bar tool strips.
NSButton *FTToolButton(NSString *symbol, NSString *label, id target, SEL action);
NSTextField *FTToolLabel(CGFloat width);
NSStackView *FTToolStrip(NSArray<NSView *> *views);

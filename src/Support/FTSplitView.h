#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, FTSplitDropZone) {
    FTSplitDropInto = 0,
    FTSplitDropBefore,
    FTSplitDropAfter,
};

// Horizontal split container for 1–3 columns. Divider hit testing is handled here even though
// column views fill the container, so a real mouse drag reaches the divider rather than its child.
@interface FTSplitView : NSView
@property (nonatomic, copy) NSArray<NSView *> *items;      // 1..3 views, laid out left to right
@property (nonatomic, copy) void (^onFocusItem)(NSInteger index);
@property (nonatomic) NSInteger focused;                    // the column that follows keyboard focus
@property (nonatomic, getter=isMaximized) BOOL maximized;   // default NO; when enabled, expansion follows focus
@property (nonatomic) CGFloat minimumItemWidth;             // drag limit (default 180)
@property (nonatomic, readonly) NSArray<NSNumber *> *weights;   // normalized widths (tests)
@property (nonatomic, copy) void (^onMaximizeChange)(BOOL maximized);
- (void)applyLayout;                                        // re-apply the weights / maximize
- (NSInteger)itemAtPoint:(NSPoint)p;                        // view coordinates, -1 between items
- (FTSplitDropZone)dropZoneAtPoint:(NSPoint)p item:(NSInteger *)item;
@end

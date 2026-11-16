#import <Cocoa/Cocoa.h>

FOUNDATION_EXPORT NSString *const FTTabDragType;
FOUNDATION_EXPORT NSString *const FTTerminalDragType;

typedef NS_ENUM(NSInteger, FTTabDropZone) {
    FTTabDropInto = 0,
    FTTabDropBefore,
    FTTabDropAfter,
};

// Opaque, process-local tokens retain their objects for up to 30 seconds.
@interface FTTabDrag : NSObject
+ (NSString *)registerObject:(id)object;
+ (id)objectForToken:(NSString *)token;
+ (void)forgetToken:(NSString *)token;
+ (void)beginInteractiveDragWithToken:(NSString *)token
                           terminal:(BOOL)terminal
                             source:(NSView *)source
                              event:(NSEvent *)event;
+ (void)updateInteractiveDragWithEvent:(NSEvent *)event;
+ (void)finishInteractiveDragWithEvent:(NSEvent *)event;     // nil cancels
+ (void)endDragging;
+ (BOOL)isDragging;
@end

// A column container. Only its body accepts content drops; headers belong to tab strips.
@interface FTTabDropView : NSView
@property (nonatomic, copy) BOOL (^canDropTab)(NSString *token, BOOL terminal, FTTabDropZone zone);
@property (nonatomic, copy) BOOL (^onDropTab)(NSString *token, BOOL terminal, FTTabDropZone zone, NSInteger index);
- (NSRect)dropContentRect;                                  // subclasses exclude their header/find bar
- (NSRect)dropPreviewRectForZone:(FTTabDropZone)zone;         // half the body for a split, the whole body for a merge
- (FTTabDropZone)dropZoneForPoint:(NSPoint)point;
- (BOOL)updateToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point;
- (void)clearDropHighlight;
- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal zone:(FTTabDropZone)zone index:(NSInteger)index;
- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point;
- (BOOL)canAcceptToken:(NSString *)token terminal:(BOOL)terminal zone:(FTTabDropZone)zone;
@end

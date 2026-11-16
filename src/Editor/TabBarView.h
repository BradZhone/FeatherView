#import <Cocoa/Cocoa.h>
#import "FTTabDrag.h"

@interface TabItem : NSObject
@property (nonatomic, copy) NSString *title, *subtitle, *toolTip;
@property (nonatomic) BOOL dirty, preview, missing;
@end

// Horizontal, custom-drawn tab strip. Mutate items/selectedIndex, then call -reload.
@interface TabBarView : NSView <NSDraggingSource>
@property (nonatomic, copy) NSArray<TabItem *> *items;
@property (nonatomic) NSInteger selectedIndex;           // -1 = none
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic, copy) void (^onClose)(NSInteger index);
@property (nonatomic, copy) void (^onDoubleClick)(NSInteger index);
@property (nonatomic, copy) void (^onMove)(NSInteger from, NSInteger to);
@property (nonatomic, copy) NSMenu *(^menuForIndex)(NSInteger index);
// Configured bars share local tab dragging for reordering and moving between columns.
@property (nonatomic, copy) NSString *(^tabDragTokenForIndex)(NSInteger index);
@property (nonatomic, copy) NSString *(^tabDragTypeForIndex)(NSInteger index); // overrides tabDragType when nonempty
@property (nonatomic, copy) NSString *tabDragType;                     // defaults to FTTabDragType
@property (nonatomic, copy) BOOL (^onDropTab)(NSString *token, BOOL terminal, NSInteger index); // insertion index, 0..count
@property (nonatomic, copy) BOOL (^canDropTab)(NSString *token, BOOL terminal);
// Legacy terminal tokens and unconfigured bars' onMove reordering remain supported.
@property (nonatomic, copy) NSString *(^dragTokenForIndex)(NSInteger index);
@property (nonatomic, copy) void (^dropTerminal)(NSString *dragToken);
- (void)reload;
- (NSRect)rectForTab:(NSInteger)index;                   // view coordinates
- (BOOL)updateToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point;
- (void)clearDropHighlight;
- (void)finishTabDrag;
- (BOOL)acceptToken:(NSString *)token terminal:(BOOL)terminal atPoint:(NSPoint)point;
@end

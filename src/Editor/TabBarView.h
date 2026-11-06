#import <Cocoa/Cocoa.h>

@interface TabItem : NSObject
@property (nonatomic, copy) NSString *title, *subtitle, *toolTip;
@property (nonatomic) BOOL dirty, preview, missing;
@end

// Horizontal, custom-drawn tab strip. Mutate items/selectedIndex, then call -reload.
@interface TabBarView : NSView
@property (nonatomic, copy) NSArray<TabItem *> *items;
@property (nonatomic) NSInteger selectedIndex;           // -1 = none
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
@property (nonatomic, copy) void (^onClose)(NSInteger index);
@property (nonatomic, copy) void (^onPin)(NSInteger index);          // double-click
@property (nonatomic, copy) void (^onMove)(NSInteger from, NSInteger to);
@property (nonatomic, copy) NSMenu *(^menuForIndex)(NSInteger index);
- (void)reload;
- (NSRect)rectForTab:(NSInteger)index;                   // view coordinates
@end

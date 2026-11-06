#import <Cocoa/Cocoa.h>

@interface PickerItem : NSObject
@property (nonatomic, copy) NSString *title, *subtitle;
@property (nonatomic, strong) id payload;
+ (instancetype)title:(NSString *)t subtitle:(NSString *)s payload:(id)p;
@end

// Floating search-and-pick panel attached to a window.
// onQuery fires on every keystroke; the owner answers with -setItems: (any thread → main).
@interface QuickPicker : NSObject <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy) void (^onQuery)(NSString *query);
@property (nonatomic, copy) void (^onPick)(PickerItem *item);
@property (nonatomic, copy) void (^onDismiss)(void);
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, readonly) NSString *query;
- (void)showInWindow:(NSWindow *)parent;
- (void)setItems:(NSArray<PickerItem *> *)items;
- (void)setStatus:(NSString *)status;
- (void)dismiss;
@end

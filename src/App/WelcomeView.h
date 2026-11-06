#import <Cocoa/Cocoa.h>

// Shown when no file is open: quick actions + clickable recent workspaces.
// Action buttons send nil-targeted actions (openFolder:, quickOpen:, …) up the responder chain.
@interface WelcomeView : NSView
@property (nonatomic, copy) void (^onOpenRoot)(NSString *root);
@property (nonatomic, copy) void (^onRemoveRecent)(NSString *root);
- (void)reloadWithRoot:(NSString *)root recent:(NSArray<NSString *> *)recent;
@end

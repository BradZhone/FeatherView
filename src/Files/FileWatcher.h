#import <Foundation/Foundation.h>

// FSEvents on one folder tree. onChange runs on the main queue, coalesced (about half a second), and not for
// changes only inside skipped folders (.git, node_modules …) or FeatherView's own temporary save files.
@interface FileWatcher : NSObject
- (instancetype)initWithRoot:(NSString *)root onChange:(void (^)(void))onChange;
- (void)stop;
@property (nonatomic, readonly) NSString *root;
+ (BOOL)pathIsInteresting:(NSString *)path root:(NSString *)root;   // tests
@end

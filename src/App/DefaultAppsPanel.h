#import <Cocoa/Cocoa.h>
#import "DefaultApps.h"

// Sheet: choose which file types open with Feather from Finder.
@interface DefaultAppsPanel : NSObject
@property (nonatomic, strong) DefaultApps *apps;
- (void)beginSheetForWindow:(NSWindow *)w;
// For tests: the checkboxes (one per DefaultApps.groups entry) and applying without the UI.
@property (nonatomic, readonly) NSArray<NSButton *> *checkboxes;
- (void)buildSheet;
- (void)applyThen:(void (^)(NSString *error))finished;
@end

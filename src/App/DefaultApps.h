#import <Cocoa/Cocoa.h>

// A group of file extensions that can be handed to Feather (or back) in one go.
@interface FileTypeGroup : NSObject
@property (nonatomic, copy) NSString *key, *title;
@property (nonatomic, copy) NSArray<NSString *> *extensions;
@property (nonatomic, readonly) NSArray<NSString *> *contentTypes;   // UTIs, de-duplicated; dynamic ones for unknown extensions
@property (nonatomic, copy) NSString *unsupportedReason;              // macOS doesn't let an editor take these (shown, not offered)
@end

// Default "open with" app per content type. Never changes anything unless asked.
// The app that was default before Feather is remembered per type so it can be restored.
@interface DefaultApps : NSObject
+ (NSArray<FileTypeGroup *> *)groups;
@property (nonatomic, copy) NSString *featherBundleID;        // default: this app
@property (nonatomic, copy) NSURL *featherURL;                // the copy to register; default: installed copy, else this bundle
- (NSURL *)defaultAppForType:(NSString *)uti;
- (BOOL)featherIsDefaultFor:(FileTypeGroup *)g;              // for every type in the group
- (NSString *)currentDefaultName:(FileTypeGroup *)g;          // "Visual Studio Code", "TextEdit 等 2 个", "无"
// Makes Feather the default (on) or restores the remembered previous app (off). done: nil or an error message.
- (void)setGroup:(FileTypeGroup *)g toFeather:(BOOL)on done:(void (^)(NSString *error))done;

// Hooks for tests (default: NSWorkspace + NSUserDefaults).
@property (nonatomic, copy) NSURL *(^lookup)(NSString *uti);
@property (nonatomic, copy) void (^setHandler)(NSURL *app, NSString *uti, void (^completion)(NSError *e));
@property (nonatomic, strong) NSUserDefaults *store;
@end

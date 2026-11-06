#import "DefaultApps.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kPreviousKey = @"previousDefaultApps";     // uti → path of the app that was default before

@implementation FileTypeGroup
- (NSArray<NSString *> *)contentTypes {
    NSMutableOrderedSet *s = [NSMutableOrderedSet orderedSet];
    for (NSString *e in _extensions) {
        UTType *t = [UTType typeWithFilenameExtension:e];
        if (t) [s addObject:t.identifier];
    }
    return s.array;
}
@end

static FileTypeGroup *group(NSString *key, NSString *title, NSString *exts) {
    FileTypeGroup *g = [FileTypeGroup new];
    g.key = key; g.title = title; g.extensions = [exts componentsSeparatedByString:@" "];
    return g;
}

// macOS treats the .html handler as part of the default web browser: the change is refused ("The file
// couldn't be opened") for an app that isn't a browser. Listed so the user knows why, never applied.
static FileTypeGroup *html(void) {
    FileTypeGroup *g = group(@"html", @"HTML", @"html htm");
    g.unsupportedReason = @"macOS 把 .html 交给默认浏览器管理，编辑器设置不了。可以在 FeatherView 里直接打开 HTML 文件。";
    return g;
}

// NSWorkspace wraps the Launch Services status in a generic "file couldn't be opened" error.
static NSString *describe(NSError *e) {
    NSError *u = e.userInfo[NSUnderlyingErrorKey];
    NSInteger code = u ? u.code : e.code;
    if (code == -128 || code == NSUserCancelledError) return @"已取消";
    if (code == -54 || code == -5000) return @"没有权限更改（macOS 拒绝了）";
    if ([e.domain isEqualToString:NSCocoaErrorDomain] && e.code == NSFileReadUnknownError) return @"macOS 拒绝了这个更改";
    return e.localizedDescription ?: @"未知错误";
}

@implementation DefaultApps

+ (NSArray<FileTypeGroup *> *)groups {
    // .ts / .mts are separate: macOS also uses them for MPEG-2 video (FeatherView hands real video to Quick Look).
    return @[group(@"markdown", @"Markdown", @"md markdown mdown mkd"),
             group(@"text", @"纯文本、日志", @"txt text log"),
             group(@"code", @"源代码", @"c h m mm cc cpp hpp swift py rb go rs js mjs cjs jsx tsx java kt kts scala cs php lua pl sh bash zsh fish sql css scss less"),
             group(@"typescript", @"TypeScript（.ts 同时是视频格式）", @"ts mts cts"),
             group(@"config", @"配置与数据", @"json jsonc yaml yml toml ini conf cfg xml plist csv tsv"),
             html(),
             group(@"image", @"图片", @"png jpg jpeg gif heic webp tiff tif bmp svg"),
             group(@"pdf", @"PDF", @"pdf")];
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _featherBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"local.feather.editor";
    _store = NSUserDefaults.standardUserDefaults;
    _lookup = ^NSURL *(NSString *uti) {
        UTType *t = [UTType typeWithIdentifier:uti];
        return t ? [NSWorkspace.sharedWorkspace URLForApplicationToOpenContentType:t] : nil;
    };
    _setHandler = ^(NSURL *app, NSString *uti, void (^completion)(NSError *)) {
        UTType *t = [UTType typeWithIdentifier:uti];
        if (!t) { completion([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil]); return; }
        [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:app toOpenContentType:t completionHandler:completion];
    };
    return self;
}

// Register the installed copy, not a build folder that happens to be running.
- (NSURL *)featherURL {
    if (_featherURL) return _featherURL;
    for (NSString *dir in @[[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"], @"/Applications"])
        for (NSString *name in @[@"FeatherView.app", @"Feather.app"]) {          // Feather.app: before the rename
            NSString *p = [dir stringByAppendingPathComponent:name];
            if ([[NSBundle bundleWithPath:p].bundleIdentifier isEqualToString:_featherBundleID]) return [NSURL fileURLWithPath:p];
        }
    return NSBundle.mainBundle.bundleURL;
}

- (NSURL *)defaultAppForType:(NSString *)uti { return self.lookup(uti); }

- (BOOL)isFeather:(NSURL *)app { return app && [[NSBundle bundleWithURL:app].bundleIdentifier isEqualToString:_featherBundleID]; }

- (BOOL)featherIsDefaultFor:(FileTypeGroup *)g {
    NSArray *types = g.contentTypes;
    if (!types.count) return NO;
    for (NSString *t in types) if (![self isFeather:self.lookup(t)]) return NO;
    return YES;
}

- (NSString *)currentDefaultName:(FileTypeGroup *)g {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (NSString *t in g.contentTypes) {
        NSURL *u = self.lookup(t);
        [names addObject:u ? [NSFileManager.defaultManager displayNameAtPath:u.path].stringByDeletingPathExtension : @"无"];
    }
    if (!names.count) return @"无";
    if (names.count == 1) return names.firstObject;
    return [NSString stringWithFormat:@"%@ 等 %lu 个", names.firstObject, (unsigned long)names.count];
}

- (void)setGroup:(FileTypeGroup *)g toFeather:(BOOL)on done:(void (^)(NSString *))done {
    if (g.unsupportedReason) { done(g.unsupportedReason); return; }
    NSMutableDictionary *prev = [[self.store dictionaryForKey:kPreviousKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    dispatch_group_t wait = dispatch_group_create();
    NSMutableArray *errors = [NSMutableArray array];
    NSLock *lock = [NSLock new];
    NSURL *feather = self.featherURL;
    for (NSString *t in g.contentTypes) {
        NSURL *current = self.lookup(t), *target;
        if (on) {
            if ([self isFeather:current]) continue;
            target = feather;
        } else {
            if (![self isFeather:current]) continue;
            NSString *back = prev[t];
            if (!back || ![NSFileManager.defaultManager fileExistsAtPath:back]) {
                NSString *ext = [UTType typeWithIdentifier:t].preferredFilenameExtension ?: t;
                [errors addObject:[NSString stringWithFormat:@".%@ 原来的打开方式已不存在，请在访达“显示简介”里另选", ext]];
                continue;
            }
            target = [NSURL fileURLWithPath:back];
        }
        dispatch_group_enter(wait);
        self.setHandler(target, t, ^(NSError *e) {
            [lock lock];
            if (e) [errors addObject:describe(e)];
            else if (on && current && !prev[t]) prev[t] = current.path;   // remember what to give it back to, only once it changed
            else if (!on) [prev removeObjectForKey:t];
            [lock unlock];
            dispatch_group_leave(wait);
        });
    }
    dispatch_group_notify(wait, dispatch_get_main_queue(), ^{
        [self.store setObject:prev forKey:kPreviousKey];
        done(errors.count ? [[NSOrderedSet orderedSetWithArray:errors].array componentsJoinedByString:@"；"] : nil);
    });
}

@end

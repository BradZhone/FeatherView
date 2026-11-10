#import "Settings.h"
#import "FileWalker.h"

NSNotificationName const FTSettingsDidChange = @"FTSettingsDidChange";

@implementation FTSettings

+ (instancetype)shared {
    static FTSettings *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [FTSettings new];
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            @"showHidden": @YES, @"respectGitignore": @YES, @"autoSaveMode": @1, @"showMinimap": @YES, @"wordWrap": @YES, @"remoteImages": @YES, @"autoCloseBrackets": @YES,
            @"alwaysHidden": FWDefaultAlwaysHidden(), @"searchSkipped": FWDefaultSearchSkipped()}];
    });
    return s;
}

static NSUserDefaults *ud(void) { return NSUserDefaults.standardUserDefaults; }
- (void)changed { [self apply]; [NSNotificationCenter.defaultCenter postNotificationName:FTSettingsDidChange object:self]; }

- (NSInteger)appearance { return [ud() integerForKey:@"appearance"]; }
- (void)setAppearance:(NSInteger)v { [ud() setInteger:MIN(2, MAX(0, v)) forKey:@"appearance"]; [self changed]; }
- (BOOL)showHidden { return [ud() boolForKey:@"showHidden"]; }
- (void)setShowHidden:(BOOL)v { [ud() setBool:v forKey:@"showHidden"]; [self changed]; }
- (BOOL)respectGitignore { return [ud() boolForKey:@"respectGitignore"]; }
- (void)setRespectGitignore:(BOOL)v { [ud() setBool:v forKey:@"respectGitignore"]; [self changed]; }
- (NSInteger)autoSaveMode { return [ud() integerForKey:@"autoSaveMode"]; }
- (void)setAutoSaveMode:(NSInteger)v { [ud() setInteger:v forKey:@"autoSaveMode"]; [self changed]; }
- (BOOL)showsMinimap { return [ud() boolForKey:@"showMinimap"]; }
- (void)setShowsMinimap:(BOOL)v { [ud() setBool:v forKey:@"showMinimap"]; [self changed]; }
- (BOOL)wordWrap { return [ud() boolForKey:@"wordWrap"]; }
- (void)setWordWrap:(BOOL)v { [ud() setBool:v forKey:@"wordWrap"]; [self changed]; }
- (BOOL)autoCloseBrackets { return [ud() boolForKey:@"autoCloseBrackets"]; }
- (void)setAutoCloseBrackets:(BOOL)v { [ud() setBool:v forKey:@"autoCloseBrackets"]; [self changed]; }
- (BOOL)remoteImages { return [ud() boolForKey:@"remoteImages"]; }
- (void)setRemoteImages:(BOOL)v { [ud() setBool:v forKey:@"remoteImages"]; [self changed]; }

static NSArray *strings(id v) {
    NSMutableArray *out = [NSMutableArray array];
    if ([v isKindOfClass:NSArray.class]) for (id x in v) if ([x isKindOfClass:NSString.class] && [x length]) [out addObject:x];
    return out;
}
- (NSArray<NSString *> *)alwaysHidden { return strings([ud() objectForKey:@"alwaysHidden"]); }
- (void)setAlwaysHidden:(NSArray<NSString *> *)a { [ud() setObject:strings(a) forKey:@"alwaysHidden"]; [self changed]; }
- (NSArray<NSString *> *)searchSkipped { return strings([ud() objectForKey:@"searchSkipped"]); }
- (void)setSearchSkipped:(NSArray<NSString *> *)a { [ud() setObject:strings(a) forKey:@"searchSkipped"]; [self changed]; }

- (void)resetFileLists {
    [ud() removeObjectForKey:@"alwaysHidden"];
    [ud() removeObjectForKey:@"searchSkipped"];
    [ud() removeObjectForKey:@"showHidden"];
    [ud() removeObjectForKey:@"respectGitignore"];
    [self changed];
}

- (void)apply {
    FWSetAlwaysHidden(self.alwaysHidden);
    FWSetSearchSkipped(self.searchSkipped);
}

+ (NSArray<NSString *> *)listFromString:(NSString *)s {
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@", \t\n，、"];
    for (NSString *p in [s componentsSeparatedByCharactersInSet:sep]) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if (t.length) [out addObject:t];
    }
    return out.array;
}

@end

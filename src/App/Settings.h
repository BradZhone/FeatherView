#import <Cocoa/Cocoa.h>

extern NSNotificationName const FTSettingsDidChange;

// Everything the settings window (⌘,) controls, stored in NSUserDefaults. Setters post FTSettingsDidChange.
@interface FTSettings : NSObject
+ (instancetype)shared;
@property (nonatomic) NSInteger appearance;                       // 0 跟随系统, 1 浅色, 2 深色
@property (nonatomic) BOOL showHidden;                            // dot files and Finder-hidden files (default YES)
@property (nonatomic, copy) NSArray<NSString *> *alwaysHidden;    // never shown: .git .DS_Store …
@property (nonatomic, copy) NSArray<NSString *> *searchSkipped;   // folders search / quick open skip: node_modules …
@property (nonatomic) BOOL respectGitignore;                      // content search skips .gitignore'd files (default YES)
@property (nonatomic) NSInteger autoSaveMode;                     // AutoSaveMode
@property (nonatomic) BOOL showsMinimap;
@property (nonatomic) BOOL wordWrap;                              // soft wrap in the editor (default YES)
- (void)resetFileLists;
- (void)apply;                    // pushes the lists to the file walker; call once at launch
+ (NSArray<NSString *> *)listFromString:(NSString *)s;            // "a, b  c" → [a, b, c]
@end

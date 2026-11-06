#import <Cocoa/Cocoa.h>

// Previews that show a file's text as structured data (table, tree). MarkupContainer feeds them the editor's
// bytes after each edit; they keep sort / filter / expansion across updates.
@protocol FTDataPreview <NSObject>
- (void)setSourceData:(NSData *)utf8 path:(NSString *)path;
- (NSView *)focusView;
- (void)focusFilter;                                                  // ⌘F
@property (nonatomic, copy) void (^onJumpToLine)(NSUInteger line);    // double click / "在源码中显示"; 1-based
@end

// One text size for tables and trees (⌘+ / ⌘- while one is shown).
extern NSNotificationName const FTDataFontSizeDidChange;
CGFloat FTDataFontSize(void);
void FTSetDataFontSize(CGFloat size);
NSFont *FTDataFont(void);
NSFont *FTDataDigitsFont(void);                                       // monospaced digits, for numbers
CGFloat FTDataRowHeight(void);
NSString *FTGrouped(NSUInteger n);                                    // 12,345
void FTCopyString(NSString *s);

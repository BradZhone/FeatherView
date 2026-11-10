#import <Cocoa/Cocoa.h>

// ⌘, — appearance, hidden files, what search skips, editor options. Changes apply immediately.
@interface SettingsWindow : NSWindowController <NSTextFieldDelegate, NSWindowDelegate>
+ (instancetype)shared;
- (void)reloadFromSettings;
// tests
@property (nonatomic, readonly) NSButton *showHiddenBox, *gitignoreBox, *minimapBox, *wrapBox;
@property (nonatomic, readonly) NSButton *remoteImagesBox;
@property (nonatomic, readonly) NSButton *autoCloseBox;
@property (nonatomic, readonly) NSTextField *alwaysHiddenField, *searchSkippedField;
@property (nonatomic, readonly) NSPopUpButton *appearancePopup, *autoSavePopup;
- (void)commitFields;
@end

#import <Cocoa/Cocoa.h>

@class FTShortcutField;

// ⌘, — appearance, hidden files, what search skips, editor options, the floating workspace.
// Changes apply immediately.
@interface SettingsWindow : NSWindowController <NSTextFieldDelegate, NSWindowDelegate,
                                                NSTableViewDataSource, NSTableViewDelegate>
+ (instancetype)shared;
- (void)reloadFromSettings;
// tests
@property (nonatomic, readonly) NSButton *showHiddenBox, *gitignoreBox, *minimapBox, *wrapBox;
@property (nonatomic, readonly) NSButton *remoteImagesBox;
@property (nonatomic, readonly) NSButton *autoCloseBox;
@property (nonatomic, readonly) NSTextField *alwaysHiddenField, *searchSkippedField;
@property (nonatomic, readonly) NSPopUpButton *appearancePopup, *autoSavePopup;
@property (nonatomic, readonly) NSButton *floatHidesBox, *floatAddButton, *floatRemoveButton;
@property (nonatomic, readonly) NSTableView *floatFolderTable;
@property (nonatomic, readonly) FTShortcutField *floatShortcutField;
@property (nonatomic, readonly) NSTextField *floatShortcutNote;
- (void)commitFields;
// Answers the folder picker without a sheet; nil uses the real NSOpenPanel.
@property (nonatomic, copy) NSString *(^folderChooser)(void);
// Why the floating workspace's shortcut isn't in effect, or nil. Set by whoever owns the panel,
// since only it knows whether macOS accepted the combination.
@property (nonatomic, copy) NSString *(^floatShortcutStatus)(void);
@end

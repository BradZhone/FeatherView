#import <Cocoa/Cocoa.h>

// One system-wide keyboard shortcut, through Carbon's RegisterEventHotKey. It arrives whatever app
// is in front and needs no accessibility permission, so nothing is ever asked of the user.
//
// A global shortcut is taken from every other app while it is registered, so there is only ever one
// of these and the combination is the reader's to choose.
@interface FTHotKey : NSObject

// nil combination, or one that macOS refuses (another app has it), leaves nothing registered and
// returns NO from -registered. The handler runs on the main queue.
- (instancetype)initWithHandler:(void (^)(void))handler;

// "⇧⌘E" style text, as shown in a menu. nil or empty unregisters.
@property (nonatomic, copy) NSString *shortcut;
@property (nonatomic, readonly) BOOL registered;      // NO when the combination was refused
@property (nonatomic, readonly) NSString *problem;    // why it was refused, for the settings window

// Text ↔ key code. A combination needs at least one of ⌘ / ⌃ / ⌥ (macOS refuses plain keys), and
// the key itself is taken from the physical layout, so it is the same key on any keyboard.
+ (NSString *)shortcutForEvent:(NSEvent *)event;      // nil when the event is not usable as one
+ (BOOL)isUsableShortcut:(NSString *)s;

@end

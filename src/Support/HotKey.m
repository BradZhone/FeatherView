#import "HotKey.h"
#import "Localization.h"
#import <Carbon/Carbon.h>

// The glyphs a menu shows, in the order macOS writes them.
static NSString *const kCtrl = @"⌃", *const kOpt = @"⌥", *const kShift = @"⇧", *const kCmd = @"⌘";

// Keys that have no character to print, by virtual key code. Everything else is written as the
// character the key produces with no modifiers, upper-cased.
static NSDictionary<NSNumber *, NSString *> *namedKeys(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{@(kVK_Space): @"Space", @(kVK_Return): @"↩", @(kVK_Tab): @"⇥", @(kVK_Escape): @"⎋",
              @(kVK_Delete): @"⌫", @(kVK_ForwardDelete): @"⌦", @(kVK_Home): @"↖", @(kVK_End): @"↘",
              @(kVK_PageUp): @"⇞", @(kVK_PageDown): @"⇟", @(kVK_LeftArrow): @"←", @(kVK_RightArrow): @"→",
              @(kVK_UpArrow): @"↑", @(kVK_DownArrow): @"↓",
              @(kVK_F1): @"F1", @(kVK_F2): @"F2", @(kVK_F3): @"F3", @(kVK_F4): @"F4", @(kVK_F5): @"F5",
              @(kVK_F6): @"F6", @(kVK_F7): @"F7", @(kVK_F8): @"F8", @(kVK_F9): @"F9", @(kVK_F10): @"F10",
              @(kVK_F11): @"F11", @(kVK_F12): @"F12",
              @(kVK_ANSI_A): @"A", @(kVK_ANSI_B): @"B", @(kVK_ANSI_C): @"C", @(kVK_ANSI_D): @"D",
              @(kVK_ANSI_E): @"E", @(kVK_ANSI_F): @"F", @(kVK_ANSI_G): @"G", @(kVK_ANSI_H): @"H",
              @(kVK_ANSI_I): @"I", @(kVK_ANSI_J): @"J", @(kVK_ANSI_K): @"K", @(kVK_ANSI_L): @"L",
              @(kVK_ANSI_M): @"M", @(kVK_ANSI_N): @"N", @(kVK_ANSI_O): @"O", @(kVK_ANSI_P): @"P",
              @(kVK_ANSI_Q): @"Q", @(kVK_ANSI_R): @"R", @(kVK_ANSI_S): @"S", @(kVK_ANSI_T): @"T",
              @(kVK_ANSI_U): @"U", @(kVK_ANSI_V): @"V", @(kVK_ANSI_W): @"W", @(kVK_ANSI_X): @"X",
              @(kVK_ANSI_Y): @"Y", @(kVK_ANSI_Z): @"Z",
              @(kVK_ANSI_0): @"0", @(kVK_ANSI_1): @"1", @(kVK_ANSI_2): @"2", @(kVK_ANSI_3): @"3",
              @(kVK_ANSI_4): @"4", @(kVK_ANSI_5): @"5", @(kVK_ANSI_6): @"6", @(kVK_ANSI_7): @"7",
              @(kVK_ANSI_8): @"8", @(kVK_ANSI_9): @"9",
              @(kVK_ANSI_Minus): @"-", @(kVK_ANSI_Equal): @"=", @(kVK_ANSI_LeftBracket): @"[",
              @(kVK_ANSI_RightBracket): @"]", @(kVK_ANSI_Backslash): @"\\", @(kVK_ANSI_Semicolon): @";",
              @(kVK_ANSI_Quote): @"'", @(kVK_ANSI_Comma): @",", @(kVK_ANSI_Period): @".",
              @(kVK_ANSI_Slash): @"/", @(kVK_ANSI_Grave): @"`"};
    });
    return d;
}

static NSString *nameForCode(uint32_t code) { return namedKeys()[@(code)]; }

static BOOL codeForName(NSString *name, uint32_t *out) {
    for (NSNumber *k in namedKeys())
        if ([namedKeys()[k] caseInsensitiveCompare:name] == NSOrderedSame) { *out = k.unsignedIntValue; return YES; }
    return NO;
}

// "⇧⌘E" → modifier glyphs split from the key name.
static BOOL parse(NSString *s, uint32_t *code, uint32_t *carbonMods, NSEventModifierFlags *cocoaMods) {
    if (!s.length) return NO;
    uint32_t cm = 0;
    NSEventModifierFlags fm = 0;
    NSUInteger i = 0;
    NSArray<NSString *> *glyphs = @[kCtrl, kOpt, kShift, kCmd];
    BOOL more = YES;
    while (more && i < s.length) {
        more = NO;
        for (NSString *g in glyphs) {
            if (i + g.length <= s.length && [[s substringWithRange:NSMakeRange(i, g.length)] isEqualToString:g]) {
                if (g == kCtrl) { cm |= controlKey; fm |= NSEventModifierFlagControl; }
                else if (g == kOpt) { cm |= optionKey; fm |= NSEventModifierFlagOption; }
                else if (g == kShift) { cm |= shiftKey; fm |= NSEventModifierFlagShift; }
                else { cm |= cmdKey; fm |= NSEventModifierFlagCommand; }
                i += g.length;
                more = YES;
                break;
            }
        }
    }
    NSString *key = [s substringFromIndex:i];
    if (!key.length || !codeForName(key, code)) return NO;
    // macOS refuses a global shortcut without ⌘, ⌃ or ⌥: it would swallow ordinary typing.
    if (!(cm & (cmdKey | controlKey | optionKey))) return NO;
    *carbonMods = cm;
    if (cocoaMods) *cocoaMods = fm;
    return YES;
}

@implementation FTHotKey {
    void (^_handler)(void);
    EventHotKeyRef _ref;
    EventHandlerRef _eventHandler;
    uint32_t _id;
}

static uint32_t gNextID = 1;
static NSMapTable<NSNumber *, FTHotKey *> *registry(void) {
    static NSMapTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSMapTable strongToWeakObjectsMapTable]; });
    return t;
}

static OSStatus hotKeyPressed(EventHandlerCallRef call, EventRef event, void *ctx) {
    EventHotKeyID hkid;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hkid, NULL, &hkid) != noErr)
        return eventNotHandledErr;
    FTHotKey *hk = [registry() objectForKey:@(hkid.id)];
    if (!hk) return eventNotHandledErr;
    dispatch_async(dispatch_get_main_queue(), ^{ if (hk->_handler) hk->_handler(); });
    return noErr;
}

- (instancetype)initWithHandler:(void (^)(void))handler {
    if (!(self = [super init])) return nil;
    _handler = [handler copy];
    _id = gNextID++;
    [registry() setObject:self forKey:@(_id)];
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&hotKeyPressed, 1, &spec, NULL, &_eventHandler);
    return self;
}

- (void)dealloc {
    [self unregister];
    if (_eventHandler) RemoveEventHandler(_eventHandler);
    [registry() removeObjectForKey:@(_id)];
}

- (void)unregister {
    if (!_ref) return;
    UnregisterEventHotKey(_ref);
    _ref = NULL;
}

- (BOOL)registered { return _ref != NULL; }

- (void)setShortcut:(NSString *)shortcut {
    _shortcut = [shortcut copy];
    _problem = nil;
    [self unregister];
    if (!shortcut.length) return;
    uint32_t code = 0, mods = 0;
    if (!parse(shortcut, &code, &mods, NULL)) {
        _problem = FTL(@"That combination can’t be used; include ⌘, ⌃ or ⌥.");
        return;
    }
    EventHotKeyID hkid = {.signature = 'ftvw', .id = _id};
    OSStatus s = RegisterEventHotKey(code, mods, hkid, GetApplicationEventTarget(), 0, &_ref);
    if (s != noErr) {
        _ref = NULL;
        // -9878 is eventHotKeyExistsErr: another app holds it, and macOS gives it to whoever asked first.
        _problem = FTL(@"Another app is already using that shortcut.");
    }
}

+ (NSString *)shortcutForEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return nil;
    NSString *key = nameForCode((uint32_t)event.keyCode);
    if (!key) return nil;
    NSEventModifierFlags f = event.modifierFlags;
    NSMutableString *out = [NSMutableString string];
    if (f & NSEventModifierFlagControl) [out appendString:kCtrl];
    if (f & NSEventModifierFlagOption) [out appendString:kOpt];
    if (f & NSEventModifierFlagShift) [out appendString:kShift];
    if (f & NSEventModifierFlagCommand) [out appendString:kCmd];
    if (!(f & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption))) return nil;
    [out appendString:key];
    return out;
}

+ (BOOL)isUsableShortcut:(NSString *)s {
    uint32_t code = 0, mods = 0;
    return parse(s, &code, &mods, NULL);
}

@end

#import <Cocoa/Cocoa.h>

// Records one keyboard shortcut: click it, press the combination, and that is what it shows. Esc
// leaves it alone, ⌫ clears it. Written as a menu writes it ("⇧⌘E").
//
// While it is recording it takes every key press, so the combination being recorded can't also
// trigger whatever it is already assigned to.
@interface FTShortcutField : NSView

@property (nonatomic, copy) NSString *shortcut;
// Asked before accepting one. NO leaves the field as it was; use it to refuse a combination macOS
// or the app won't take, with `problem` saying why.
@property (nonatomic, copy) BOOL (^validate)(NSString *shortcut, NSString **problem);
@property (nonatomic, copy) void (^onChange)(NSString *shortcut);
@property (nonatomic, readonly) BOOL recording;

// Shown under the field: why the last combination was refused, or nothing.
@property (nonatomic, copy) NSString *problem;

- (void)startRecording;
- (void)stopRecording;
// Tests: as if this key had been pressed while recording.
- (BOOL)recordEvent:(NSEvent *)event;

@end

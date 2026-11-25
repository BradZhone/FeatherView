#import "ShortcutField.h"
#import "HotKey.h"
#import "Localization.h"

@implementation FTShortcutField {
    NSButton *_button;
    BOOL _recording;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _button = [NSButton buttonWithTitle:@"" target:self action:@selector(clicked:)];
    _button.bezelStyle = NSBezelStyleRounded;
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_button];
    [NSLayoutConstraint activateConstraints:@[
        [_button.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_button.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_button.widthAnchor constraintGreaterThanOrEqualToConstant:120]]];
    [self updateTitle];
    return self;
}

- (BOOL)recording { return _recording; }

- (void)setShortcut:(NSString *)shortcut {
    _shortcut = [shortcut copy];
    [self updateTitle];
}

- (void)setProblem:(NSString *)problem {
    _problem = [problem copy];
    [self updateTitle];
}

- (void)updateTitle {
    if (_recording) {
        _button.title = FTL(@"Press a combination…");
    } else if (_shortcut.length) {
        _button.title = _shortcut;
    } else {
        _button.title = FTL(@"None");
    }
    _button.contentTintColor = _problem.length && !_recording ? NSColor.systemRedColor : nil;
}

- (void)clicked:(id)sender {
    if (_recording) [self stopRecording]; else [self startRecording];
}

- (void)startRecording {
    if (_recording) return;
    _recording = YES;
    self.problem = nil;
    [self updateTitle];
    [self.window makeFirstResponder:self];
}

- (void)stopRecording {
    if (!_recording) return;
    _recording = NO;
    [self updateTitle];
    if (self.window.firstResponder == self) [self.window makeFirstResponder:nil];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { [self setKeyboardFocusRingNeedsDisplayInRect:self.bounds]; return YES; }
- (BOOL)resignFirstResponder { [self stopRecording]; return YES; }

// Every key press goes here while recording, so the combination being recorded can't also fire
// whatever already has it.
- (void)keyDown:(NSEvent *)e {
    if (_recording && [self recordEvent:e]) return;
    [super keyDown:e];
}

- (BOOL)performKeyEquivalent:(NSEvent *)e {
    return _recording ? [self recordEvent:e] : [super performKeyEquivalent:e];
}

- (BOOL)recordEvent:(NSEvent *)e {
    if (!_recording || e.type != NSEventTypeKeyDown) return NO;
    if (e.keyCode == 53) { [self stopRecording]; return YES; }        // Esc: leave it alone
    if (e.keyCode == 51) {                                            // ⌫: no shortcut at all
        [self stopRecording];
        _shortcut = nil;
        self.problem = nil;
        if (self.onChange) self.onChange(nil);
        return YES;
    }
    NSString *s = [FTHotKey shortcutForEvent:e];
    if (!s) {
        // A bare key, or one with ⇧ alone: macOS won't give a global shortcut for it.
        self.problem = FTL(@"Hold ⌘, ⌃ or ⌥ as well.");
        return YES;
    }
    NSString *why = nil;
    if (self.validate && !self.validate(s, &why)) {
        self.problem = why.length ? why : FTL(@"That combination can’t be used.");
        return YES;
    }
    [self stopRecording];
    _shortcut = [s copy];
    self.problem = nil;
    if (self.onChange) self.onChange(s);
    return YES;
}

@end

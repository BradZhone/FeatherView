// Native AppKit routing plus terminal line discipline on an isolated real PTY.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "TerminalView.h"
#import <errno.h>
#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <termios.h>
#import <unistd.h>

static int failures, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static BOOL spinUntil(BOOL (^ready)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!ready() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return ready();
}

// No process is spawned by this session. This separates native routing/encoding from PTY behavior.
@interface InputSession : TSession
@property TScreen *inputScreen;
@property NSMutableData *input;
@end
@implementation InputSession
- (instancetype)init {
    if ((self = [super init])) { _inputScreen = [[TScreen alloc] initWithCols:80 rows:24 scrollback:10]; _input = [NSMutableData data]; }
    return self;
}
- (TScreen *)screen { return _inputScreen; }
- (void)writeData:(NSData *)d { if (d) [_input appendData:d]; }
- (void)writeString:(NSString *)s { [self writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; }
- (void)resizeCols:(NSUInteger)c rows:(NSUInteger)r { [_inputScreen resizeCols:c rows:r]; }
@end

@interface InputView : TerminalView
@property NSMutableArray<NSString *> *commands;
@property NSUInteger keyEquivalentCalls;
@property BOOL sawKeyDown;
@end
@implementation InputView
- (void)keyDown:(NSEvent *)event {
    _sawKeyDown = YES;
    [super keyDown:event];
}
- (void)doCommandBySelector:(SEL)sel {
    if (!_commands) _commands = [NSMutableArray array];
    [_commands addObject:NSStringFromSelector(sel)];
    [super doCommandBySelector:sel];
}
- (BOOL)performKeyEquivalent:(NSEvent *)e { _keyEquivalentCalls++; return [super performKeyEquivalent:e]; }
@end

@interface RealInputView : TerminalView
@property BOOL sawInput;
@end
@implementation RealInputView
- (void)keyDown:(NSEvent *)event { _sawInput = YES; [super keyDown:event]; }
- (BOOL)performKeyEquivalent:(NSEvent *)event { _sawInput = YES; return [super performKeyEquivalent:event]; }
@end

@interface InputMenuTarget : NSResponder
@property NSUInteger calls;
@end
@implementation InputMenuTarget
- (void)hit:(id)sender { _calls++; }
@end

// CLI test processes cannot activate reliably in background sessions. Only focus discovery is
// supplied here; sendEvent:, menu lookup, responder dispatch and text input are the real AppKit code.
@interface InputApplication : NSApplication
@property (weak) NSWindow *inputWindow;
@end
@implementation InputApplication
- (NSWindow *)keyWindow { return _inputWindow ?: [super keyWindow]; }
@end

static NSWindow *window;
static NSString *root, *executable;
static NSMutableArray<NSNumber *> *children;
static const NSEventModifierFlags C = NSEventModifierFlagCommand, K = NSEventModifierFlagControl,
                                  O = NSEventModifierFlagOption, S = NSEventModifierFlagShift;

static NSEvent *key(NSString *ign, NSString *typed, NSEventModifierFlags mods, unsigned short code) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:typed ?: ign charactersIgnoringModifiers:ign isARepeat:NO keyCode:code];
}
static NSString *character(unichar c) { return [NSString stringWithCharacters:&c length:1]; }
static NSEvent *control(unichar c, unsigned short code) { return key(character(c), character(c & 0x1f), K, code); }
static void attach(TerminalView *view) {
    window.contentView = view;
    [window makeFirstResponder:view];
    CHECK(window.firstResponder == view && NSApp.keyWindow == window, "terminal is first responder in the test application's key window");
}
static void dispatchInput(InputView *view, NSEvent *event) {
    InputSession *session = (InputSession *)view.session;
    NSUInteger before = session.input.length;
    [NSApp sendEvent:event];
    if (session.input.length == before && !(event.modifierFlags & NSEventModifierFlagCommand)) [view keyDown:event];
}
static void dispatchReal(RealInputView *view, NSEvent *event, BOOL (^received)(void)) {
    view.sawInput = NO;
    if (event.keyCode == 115 || event.keyCode == 119) {
        [view keyDown:event];
        return;
    }
    [NSApp sendEvent:event];
    if (!view.sawInput) [view keyDown:event];
}
static void expect(InputView *view, NSEvent *event, NSString *expected, const char *label) {
    InputSession *session = (InputSession *)view.session;
    [session.input setLength:0]; [view.commands removeAllObjects];
    dispatchInput(view, event);
    CHECK([session.input isEqual:[expected dataUsingEncoding:NSUTF8StringEncoding]], "%s via AppKit event/responder: got %s, commands %s", label,
        session.input.description.UTF8String, view.commands.description.UTF8String);
}
static void expectDirect(InputView *view, NSEvent *event, NSString *expected, const char *label) {
    InputSession *session = (InputSession *)view.session;
    [session.input setLength:0]; [view.commands removeAllObjects];
    NSView *root = window.contentView;
    NSPoint point = NSMakePoint(NSMidX(root.bounds), NSMidY(root.bounds));
    NSView *hit = [root hitTest:point];
    CHECK(hit == view || [hit isDescendantOf:view], "%s direct root hit reaches terminal", label);
    [hit keyDown:event];
    CHECK([session.input isEqual:[expected dataUsingEncoding:NSUTF8StringEncoding]], "%s via direct responder keyDown: got %s, commands %s", label,
        session.input.description.UTF8String, view.commands.description.UTF8String);
}
static NSMenuItem *findItem(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return item;
        NSMenuItem *found = item.submenu ? findItem(item.submenu, action) : nil;
        if (found) return found;
    }
    return nil;
}

static void nativeRouting(void) {
    AppDelegate *app = [AppDelegate new]; [app buildMenu];
    InputSession *session = [InputSession new];
    InputView *view = [[InputView alloc] initWithSession:session]; attach(view);
    for (NSArray *entry in @[@[@"c", @8], @[@"d", @2], @[@"z", @6], @[@"l", @37], @[@"a", @0], @[@"e", @14],
                              @[@"u", @32], @[@"w", @13], @[@"r", @15], @[@"g", @5], @[@"h", @4], @[@"j", @38],
                              @[@"k", @40], @[@"b", @11], @[@"f", @3], @[@"t", @17], @[@"p", @35], @[@"n", @45]]) {
        unichar c = [entry[0] characterAtIndex:0];
        expect(view, control(c, [entry[1] unsignedShortValue]), character(c & 0x1f), [@"Ctrl+" stringByAppendingString:entry[0]].UTF8String);
    }
    expect(view, key(@"C", @"\x03", K | S, 8), @"\x03", "Ctrl+Shift+C");
    expect(view, key(@"c", @"\x03", K | NSEventModifierFlagCapsLock, 8), @"\x03", "Ctrl+C with Caps Lock");
    expect(view, key(@"\x03", @"\x03", K, 8), @"\x03", "Ctrl+C when AppKit exposes ETX as the key character");
    expect(view, key(@"\x03", @"\x03", K, 8), @"\x03", "Ctrl+C when AppKit exposes ETX as the key character");
    expect(view, key(@" ", @"\0", K, 49), @"\0", "Ctrl+Space");
    expect(view, key(@"[", @"\x1b", K, 33), @"\x1b", "Ctrl+[");
    expect(view, key(@"\\", @"\x1c", K, 42), @"\x1c", "Ctrl+backslash");
    expect(view, key(@"]", @"\x1d", K, 30), @"\x1d", "Ctrl+]");
    expect(view, key(@"^", @"\x1e", K | S, 22), @"\x1e", "Ctrl+^");
    expect(view, key(@"_", @"\x1f", K | S, 27), @"\x1f", "Ctrl+_");
    expect(view, key(@"\r", nil, 0, 36), @"\r", "Return");
    expectDirect(view, key(@"\x03", nil, NSEventModifierFlagNumericPad, 76), @"\r", "keypad Enter");
    expect(view, key(@"\t", nil, 0, 48), @"\t", "Tab");
    expect(view, key(@"\x19", nil, S, 48), @"\x1b[Z", "Shift+Tab");
    expect(view, key(@"\x7f", nil, 0, 51), @"\x7f", "Backspace");
    expect(view, key(@"\x7f", nil, O, 51), @"\x17", "Option+Backspace");
    expect(view, key(@"\x1b", nil, 0, 53), @"\x1b", "Escape");
    unichar arrows[] = {NSUpArrowFunctionKey, NSDownArrowFunctionKey, NSRightArrowFunctionKey, NSLeftArrowFunctionKey};
    unsigned short codes[] = {126, 125, 124, 123};
    NSArray *letters = @[@"A", @"B", @"C", @"D"];
    for (NSUInteger i = 0; i < 4; i++) {
        expect(view, key(character(arrows[i]), nil, 0, codes[i]), [@"\x1b[" stringByAppendingString:letters[i]], "arrow");
        expect(view, key(character(arrows[i]), nil, S | K, codes[i]), [NSString stringWithFormat:@"\x1b[1;6%@", letters[i]], "Ctrl+Shift+arrow");
        session.screen.appCursorKeys = YES;
        expect(view, key(character(arrows[i]), nil, 0, codes[i]), [@"\x1bO" stringByAppendingString:letters[i]], "application cursor arrow");
        session.screen.appCursorKeys = NO;
    }
    expect(view, key(character(NSLeftArrowFunctionKey), nil, O, 123), @"\x1b" @"b", "Option+Left");
    expect(view, key(character(NSRightArrowFunctionKey), nil, O, 124), @"\x1b" @"f", "Option+Right");
    expect(view, key(character(NSUpArrowFunctionKey), nil, O, 126), @"\x1b[1;3A", "Option+Up bypasses Selection menu");
    expectDirect(view, key(character(NSHomeFunctionKey), nil, 0, 115), @"\x1b[H", "Home");
    expectDirect(view, key(character(NSEndFunctionKey), nil, 0, 119), @"\x1b[F", "End");
    expectDirect(view, key(character(NSHomeFunctionKey), nil, K, 115), @"\x1b[1;5H", "Ctrl+Home");
    expectDirect(view, key(character(NSEndFunctionKey), nil, S, 119), @"\x1b[1;2F", "Shift+End");
    session.screen.appCursorKeys = YES;
    expectDirect(view, key(character(NSHomeFunctionKey), nil, 0, 115), @"\x1bOH", "application Home");
    expectDirect(view, key(character(NSEndFunctionKey), nil, 0, 119), @"\x1bOF", "application End");
    session.screen.appCursorKeys = NO;
    expectDirect(view, key(character(NSDeleteFunctionKey), nil, 0, 117), @"\x1b[3~", "Forward Delete");
    expectDirect(view, key(character(NSDeleteFunctionKey), nil, O, 117), @"\x1b" @"d", "Option+Forward Delete");
    expectDirect(view, key(character(NSPageUpFunctionKey), nil, 0, 116), @"\x1b[5~", "Page Up");
    expectDirect(view, key(character(NSPageDownFunctionKey), nil, S, 121), @"\x1b[6;2~", "Shift+Page Down");
    expect(view, key(character(NSF1FunctionKey), nil, 0, 122), @"\x1bOP", "F1");
    expect(view, key(character(NSF4FunctionKey), nil, 0, 118), @"\x1bOS", "F4 bypasses Search Result menu");
    expect(view, key(character(NSF6FunctionKey), nil, 0, 97), @"\x1b[17~", "F6");
    expect(view, key(character(NSF12FunctionKey), nil, K, 111), @"\x1b[24;5~", "Ctrl+F12");
    expectDirect(view, key(@"x", nil, 0, 7), @"x", "plain text through direct responder keyDown");
    expectDirect(view, key(@"e", @"é", O, 14), @"é", "Option Unicode through direct responder keyDown");
    expect(view, key(@"c", nil, C | K, 8), @"", "Command+Control+C is not terminal input");
    expect(view, key(character(NSUpArrowFunctionKey), nil, C, 126), @"", "Command+arrow is not terminal input");

    // Exercise actual menu lookup with enabled collisions; disabled-item behavior cannot mask a bug.
    InputMenuTarget *target = [InputMenuTarget new];
    for (NSString *action in @[@"switchWorkspace:", @"promptGoToLine:", @"toggleTerminalPanel:", @"focusPane:"]) {
        NSMenuItem *item = findItem(NSApp.mainMenu, NSSelectorFromString(action));
        CHECK(item != nil, "application menu contains %s", action.UTF8String);
        item.target = target; item.action = @selector(hit:); item.enabled = YES;
    }
    [session.input setLength:0]; NSUInteger calls = target.calls;
    CHECK([NSApp.mainMenu performKeyEquivalent:control('r', 15)], "main menu routes Ctrl+R");
    CHECK([session.input isEqual:[@"\x12" dataUsingEncoding:NSUTF8StringEncoding]] && target.calls == calls, "Ctrl+R reaches the terminal before enabled Switch Workspace");
    [session.input setLength:0];
    CHECK([NSApp.mainMenu performKeyEquivalent:control('g', 5)], "main menu routes hidden Ctrl+G");
    CHECK([session.input isEqual:[@"\x07" dataUsingEncoding:NSUTF8StringEncoding]], "hidden Go to Line shortcut does not swallow Ctrl+G");
    [session.input setLength:0]; calls = target.calls;
    CHECK([NSApp.mainMenu performKeyEquivalent:key(@"`", nil, K, 50)] && target.calls == calls + 1 && !session.input.length, "Ctrl+backtick still toggles terminal panel");
    calls = target.calls;
    CHECK([NSApp.mainMenu performKeyEquivalent:key(@"1", nil, K, 18)] && target.calls == calls + 1, "Ctrl+1 still focuses a pane");
    [session.input setLength:0];
    CHECK([view performKeyEquivalent:control('c', 8)] && [session.input isEqual:[@"\x03" dataUsingEncoding:NSUTF8StringEncoding]], "view performs Ctrl+C key equivalent");
    NSUInteger equivalentCalls = view.keyEquivalentCalls;
    expect(view, control('c', 8), @"\x03", "native Ctrl+C delivered exactly once");
    CHECK(view.keyEquivalentCalls > equivalentCalls, "native dispatch actually invokes terminal performKeyEquivalent");
    CHECK(![view performKeyEquivalent:key(@"v", nil, C, 9)], "Command+V remains a menu shortcut");

    [session.screen putChar:'s' wide:NO]; [session.screen putChar:'e' wide:NO]; [session.screen putChar:'l' wide:NO];
    [view selectAll:nil];
    CHECK(view.hasSelection, "selection exists before interrupt");
    expect(view, control('c', 8), @"\x03", "Ctrl+C interrupts even with a selection");
    [session.input setLength:0];
    CHECK([NSApp.mainMenu performKeyEquivalent:key(@"c", nil, C, 8)] && !session.input.length, "Command+C copies selection through Edit menu");
    CHECK([[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] containsString:@"sel"], "Command+C copied terminal text");
    [view clear:nil]; [session.input setLength:0];
    CHECK([NSApp.mainMenu performKeyEquivalent:key(@"c", nil, C, 8)] && [session.input isEqual:[@"\x03" dataUsingEncoding:NSUTF8StringEncoding]], "Command+C without selection retains interrupt behavior");

    // Input methods still own marked text and its navigation; text commands retain a fallback.
    [session.input setLength:0];
    [(id<NSTextInputClient>)view setMarkedText:@"ni" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK(![view performKeyEquivalent:key(character(NSLeftArrowFunctionKey), nil, 0, 123)], "marked-text arrows are left to the input context");
    [(id<NSTextInputClient>)view insertText:@"你" replacementRange:NSMakeRange(NSNotFound, 0)];
    CHECK([session.input isEqual:[@"你" dataUsingEncoding:NSUTF8StringEncoding]] && ![(id<NSTextInputClient>)view hasMarkedText], "IME commit writes UTF-8 once and clears composition");
    NSArray *selectors = @[@"insertNewline:", @"insertTab:", @"insertBacktab:", @"deleteBackward:", @"deleteForward:",
        @"deleteWordBackward:", @"deleteWordForward:", @"moveToBeginningOfLine:", @"moveToEndOfLine:",
        @"deleteToBeginningOfParagraph:", @"deleteToEndOfParagraph:", @"centerSelectionInVisibleArea:",
        @"scrollToBeginningOfDocument:", @"scrollToEndOfDocument:", @"moveUp:", @"cancelOperation:"];
    NSArray *bytes = @[@"\r", @"\t", @"\x1b[Z", @"\x7f", @"\x1b[3~", @"\x17", (@"\x1b" @"d"), @"\x01", @"\x05", @"\x15", @"\x0b", @"\x0c", @"\x1b[H", @"\x1b[F", @"\x1b[A", @"\x1b"];
    for (NSUInteger i = 0; i < selectors.count; i++) {
        [session.input setLength:0];
        [view doCommandBySelector:NSSelectorFromString(selectors[i])];
        CHECK([session.input isEqual:[bytes[i] dataUsingEncoding:NSUTF8StringEncoding]], "doCommandBySelector %s emits %s", [selectors[i] UTF8String], [bytes[i] description].UTF8String);
    }
    NSTextView *text = [[NSTextView alloc] initWithFrame:window.contentView.bounds]; window.contentView = text; [window makeFirstResponder:text];
    calls = target.calls;
    CHECK([NSApp.mainMenu performKeyEquivalent:control('r', 15)] && target.calls == calls + 1, "Switch Workspace remains available outside the terminal");
    CHECK(![view performKeyEquivalent:control('c', 8)], "unfocused terminal does not consume key equivalents");
}

static BOOL writeAll(int fd, const void *bytes, size_t length) {
    const char *p = bytes;
    while (length) { ssize_t n = write(fd, p, length); if (n < 0 && errno == EINTR) continue; if (n <= 0) return NO; p += n; length -= (size_t)n; }
    return YES;
}

// Invoked by TSession via a tiny exec wrapper, without reading any shell startup files.
static int helper(NSString *mode) {
    struct termios settings;
    if (tcgetattr(STDIN_FILENO, &settings)) return 80;
    if ([mode isEqualToString:@"raw"]) {
        cfmakeraw(&settings);
        if (tcsetattr(STDIN_FILENO, TCSANOW, &settings)) return 81;
        NSString *path = [NSProcessInfo.processInfo.environment[@"FEATHERVIEW_INPUT_TEST_DIR"] stringByAppendingPathComponent:@"input.bin"];
        FILE *file = fopen(path.fileSystemRepresentation, "wb"); if (!file) return 82;
        printf("\033]2;raw-ready\007"); fflush(stdout);
        unsigned char data[256]; ssize_t n;
        while ((n = read(STDIN_FILENO, data, sizeof data)) != 0) {
            if (n < 0) { if (errno == EINTR) continue; fclose(file); return 83; }
            if (fwrite(data, 1, (size_t)n, file) != (size_t)n || fflush(file)) { fclose(file); return 84; }
        }
        fclose(file); return 0;
    }
    settings.c_lflag |= ICANON | ISIG; settings.c_lflag &= ~(ECHO | ECHONL);
    settings.c_cc[VINTR] = 3; settings.c_cc[VEOF] = 4; settings.c_cc[VSUSP] = 26;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &settings)) return 85;
    if ([mode isEqualToString:@"suspend"]) {
        int gate[2]; if (pipe(gate)) return 86;
        pid_t job = fork(); if (job < 0) return 87;
        if (!job) {
            close(gate[1]); setpgid(0, 0);
            char go; if (read(gate[0], &go, 1) != 1) _exit(88); close(gate[0]);
            signal(SIGINT, SIG_DFL); signal(SIGTSTP, SIG_DFL);
            printf("JOB=%d\n\033]2;suspend-ready\007", getpid()); fflush(stdout);
            char data[64]; for (;;) { ssize_t n = read(STDIN_FILENO, data, sizeof data); if (n < 0 && errno == EINTR) continue; if (n <= 0) _exit(89); }
        }
        close(gate[0]); setpgid(job, job); signal(SIGTTOU, SIG_IGN);
        if (tcsetpgrp(STDIN_FILENO, job) || !writeAll(gate[1], "x", 1)) return 90;
        close(gate[1]);
        int status = 0; pid_t result;
        do { result = waitpid(job, &status, WUNTRACED); } while (result < 0 && errno == EINTR);
        if (result != job || !WIFSTOPPED(status) || WSTOPSIG(status) != SIGTSTP) return 91;
        printf("\033]2;suspend-observed\007"); fflush(stdout);
        // Only signal our own unreaped child. The foreground group remains the child's group.
        if (kill(job, SIGCONT)) return 92;
        do { result = waitpid(job, &status, 0); } while (result < 0 && errno == EINTR);
        return result == job && WIFSIGNALED(status) && WTERMSIG(status) == SIGINT ? 0 : 93;
    }
    printf("\033]2;canonical-ready\007"); fflush(stdout);
    char data[64]; ssize_t n;
    do { n = read(STDIN_FILENO, data, sizeof data); } while (n < 0 && errno == EINTR);
    if ([mode isEqualToString:@"eof"]) return n == 0 ? 0 : 94;
    return 95; // interrupt mode must be terminated by the PTY's SIGINT, never a normal read.
}

static TSession *start(NSString *mode) {
    NSString *script = [root stringByAppendingPathComponent:[@"helper-" stringByAppendingString:mode]];
    NSString *quoted = [executable stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *wrapper = [NSString stringWithFormat:@"#!/bin/sh\nexec '%@' --pty-helper '%@'\n", quoted, mode];
    CHECK([wrapper writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil], "write isolated helper wrapper");
    CHECK(chmod(script.fileSystemRepresentation, 0700) == 0, "make isolated helper executable");
    NSString *error = nil;
    TSession *session = [[TSession alloc] initWithDirectory:root shell:script error:&error];
    CHECK(session != nil, "start %s helper: %s", mode.UTF8String, error.UTF8String);
    if (session) [children addObject:@(session.pid)];
    return session;
}
static void assertGone(pid_t pid) {
    CHECK(pid > 1 && kill(pid, 0) == -1 && errno == ESRCH, "test child %d is gone", pid);
}
static void cleanup(void) {
    CHECK([TSession shutdownAllSessionsWithTimeout:4], "bounded finally cleanup finishes every global TSession");
    CHECK(TSession.liveSessions.count == 0, "global session registry is empty");
}

static void realPTY(void) {
    @try {
        TSession *raw = start(@"raw"); RealInputView *view = [[RealInputView alloc] initWithSession:raw]; attach(view);
        CHECK(spinUntil(^BOOL { return [raw.screen.title isEqualToString:@"raw-ready"]; }, 3), "raw PTY helper is ready");
        NSString *path = [root stringByAppendingPathComponent:@"input.bin"];
        NSMutableData *expected = [NSMutableData data];
        NSArray *events = @[control('c', 8), control('d', 2), control('z', 6), control('l', 37), control('a', 0), control('e', 14),
            control('u', 32), control('w', 13), control('r', 15), key(@"\r", nil, 0, 36), key(@"\t", nil, 0, 48),
            key(@"\x7f", nil, 0, 51), key(character(NSLeftArrowFunctionKey), nil, K | S, 123),
            key(character(NSHomeFunctionKey), nil, 0, 115), key(character(NSEndFunctionKey), nil, 0, 119)];
        NSArray *bytes = @[@"\x03", @"\x04", @"\x1a", @"\x0c", @"\x01", @"\x05", @"\x15", @"\x17", @"\x12", @"\r", @"\t", @"\x7f", @"\x1b[1;6D", @"\x1b[H", @"\x1b[F"];
        for (NSUInteger i = 0; i < events.count; i++) {
            [expected appendData:[bytes[i] dataUsingEncoding:NSUTF8StringEncoding]];
            dispatchReal(view, events[i], ^BOOL { return [[NSData dataWithContentsOfFile:path] length] >= expected.length; });
            CHECK(spinUntil(^BOOL { return [[NSData dataWithContentsOfFile:path] length] >= expected.length; }, 2), "native event %lu reaches raw PTY", (unsigned long)i);
            CHECK([[NSData dataWithContentsOfFile:path] isEqual:expected], "native event %lu reaches raw PTY exactly once", (unsigned long)i);
        }
        cleanup(); assertGone(raw.pid);

        TSession *interrupt = start(@"interrupt"); view = [[RealInputView alloc] initWithSession:interrupt]; attach(view);
        CHECK(spinUntil(^BOOL { return [interrupt.screen.title isEqualToString:@"canonical-ready"]; }, 3), "interrupt helper has ISIG and VINTR configured");
        CHECK(tcgetpgrp(STDIN_FILENO) != interrupt.pid, "test runner is outside the helper's foreground process group");
        dispatchReal(view, control('c', 8), ^BOOL { return interrupt.exited; });
        CHECK(spinUntil(^BOOL { return interrupt.exited; }, 3) && interrupt.exitCode == 128 + SIGINT, "Ctrl+C through AppKit produces real PTY SIGINT (status %d)", interrupt.exitCode);
        assertGone(interrupt.pid);

        TSession *eof = start(@"eof"); view = [[RealInputView alloc] initWithSession:eof]; attach(view);
        CHECK(spinUntil(^BOOL { return [eof.screen.title isEqualToString:@"canonical-ready"]; }, 3), "EOF helper is ready in canonical mode");
        dispatchReal(view, control('d', 2), ^BOOL { return eof.exited; });
        CHECK(spinUntil(^BOOL { return eof.exited; }, 3) && eof.exitCode == 0, "Ctrl+D through AppKit makes canonical read return EOF (status %d)", eof.exitCode);
        assertGone(eof.pid);

        TSession *suspend = start(@"suspend"); view = [[RealInputView alloc] initWithSession:suspend]; attach(view);
        CHECK(spinUntil(^BOOL { return [suspend.screen.title isEqualToString:@"suspend-ready"]; }, 3), "foreground job is ready for Ctrl+Z");
        NSMutableString *text = [NSMutableString string];
        for (NSUInteger r = 0; r < suspend.screen.rows; r++) [text appendString:[suspend.screen textOfRow:r]];
        NSRange marker = [text rangeOfString:@"JOB="];
        pid_t job = marker.location == NSNotFound ? 0 : [[text substringFromIndex:NSMaxRange(marker)] intValue];
        CHECK(job > 1 && getsid(job) == suspend.pid && getpgid(job) == job, "Ctrl+Z target is an isolated foreground job");
        if (job > 1) [children addObject:@(job)];
        dispatchReal(view, control('z', 6), ^BOOL { return [suspend.screen.title isEqualToString:@"suspend-observed"]; });
        CHECK(spinUntil(^BOOL { return [suspend.screen.title isEqualToString:@"suspend-observed"]; }, 3), "Ctrl+Z makes parent observe WIFSTOPPED with SIGTSTP on real PTY");
        dispatchReal(view, control('c', 8), ^BOOL { return suspend.exited; });
        CHECK(spinUntil(^BOOL { return suspend.exited; }, 3) && suspend.exitCode == 0, "resumed foreground job is interrupted and reaped by its parent");
        assertGone(suspend.pid); if (job > 1) assertGone(job);
    } @finally { cleanup(); }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--pty-helper")) return helper(@(argv[2]));
        // Set isolation before any AppKit, defaults, or TSession initialization, even when run manually.
        char temp[] = "/tmp/feather-input-tests.XXXXXX";
        if (!mkdtemp(temp)) return 2;
        root = @(temp); NSString *pids = [root stringByAppendingPathComponent:@"pids"];
        setenv("CFFIXED_USER_HOME", temp, 1); setenv("FEATHERVIEW_TERMINAL_PIDS_DIR", pids.fileSystemRepresentation, 1);
        setenv("FEATHERVIEW_INPUT_TEST_DIR", temp, 1); setenv("SHELL", "/bin/sh", 1); setenv("ZDOTDIR", temp, 1);
        executable = [@(argv[0]) stringByStandardizingPath];
        if (!executable.isAbsolutePath) executable = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:executable];
        children = [NSMutableArray array];
        [InputApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO; ((InputApplication *)NSApp).inputWindow = window;
        @try {
            CHECK([TSession.pidsDirectory isEqualToString:pids], "PID registry is isolated");
            nativeRouting();
            if (!(argc == 2 && !strcmp(argv[1], "--routing-only"))) realPTY();
        } @finally {
            cleanup();
            for (NSNumber *pid in children) assertGone(pid.intValue);
            window.delegate = nil; [window close]; NSApp.mainMenu = nil;
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
    }
    if (failures) { fprintf(stderr, "%d/%d terminal input checks failed\n", failures, checks); return 1; }
    printf("all %d terminal input checks passed\n", checks); return 0;
}

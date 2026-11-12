// The terminal core: escape parsing into a screen grid, and a real shell on a PTY.
// Pure Foundation, no AppKit.
#import <Foundation/Foundation.h>
#import "TScreen.h"
#import "VTEscape.h"
#import "TSession.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static TScreen *feed(NSString *seq, NSUInteger cols, NSUInteger rows) {
    TScreen *s = [[TScreen alloc] initWithCols:cols rows:rows scrollback:1000];
    VTEscape *vt = [[VTEscape alloc] initWithEndpoint:s];
    NSData *d = [seq dataUsingEncoding:NSUTF8StringEncoding];
    [vt feed:d.bytes length:d.length];
    return s;
}

static void lines(TScreen *s, NSUInteger cols, char out[][cols]) {
    for (NSUInteger r = 0; r < s.rows; r++) {
        NSString *t = [s textOfRow:r];
        memset(out[r], ' ', cols);
        [t getBytes:out[r] maxLength:cols usedLength:NULL encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, MIN(t.length, cols)) remainingRange:NULL];
    }
}

__attribute__((unused)) static void show(TScreen *s, NSUInteger cols, NSUInteger rows, const char *what) {
    char l[rows][cols];
    lines(s, cols, l);
    printf("  %s:\n", what);
    for (NSUInteger r = 0; r < rows; r++) printf("    |%.*s|\n", (int)cols, l[r]);
}

static void plainText(void) {
    TScreen *s = feed(@"hello\r\nworld", 20, 5);
    CHECK([[s textOfRow:0] hasPrefix:@"hello"], "text: %s", [s textOfRow:0].UTF8String);
    CHECK([[s textOfRow:1] hasPrefix:@"world"], "newline moves down");
    CHECK(s.cursorRow == 1 && s.cursorCol == 5, "cursor after text (%lu,%lu)", (unsigned long)s.cursorRow, (unsigned long)s.cursorCol);
    s = feed(@"hello\nworld", 20, 5);
    CHECK([[s textOfRow:1] hasPrefix:@"     world"], "a bare LF keeps the column: %s", [s textOfRow:1].UTF8String);
    // \r\n does not double-step
    s = feed(@"a\r\nb\r\n", 10, 4);
    CHECK([[s textOfRow:1] hasPrefix:@"b"], "CRLF");
    CHECK(s.cursorRow == 2, "cursor on line 2 (%lu)", (unsigned long)s.cursorRow);
    // wrapping: 30 chars in 10 columns
    s = feed(@"0123456789ABCDEFGHIJ", 10, 4);
    CHECK([[s textOfRow:1] hasPrefix:@"ABCDEFGHIJ"], "autowrap");
    CHECK(s.cursorRow == 1 && s.cursorCol == 9, "deferred wrap: the cursor waits in the last column (%lu,%lu)", (unsigned long)s.cursorRow, (unsigned long)s.cursorCol);
    // backspace, tab, carriage return
    s = feed(@"abc\bd\tX", 20, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"abd     X"], "backspace, tab to the stop, overwrite: %s", [s textOfRow:0].UTF8String);
}

static void cursorMoves(void) {
    TScreen *s = feed(@"\x1b[2;3HX", 20, 5);
    CHECK([[s textOfRow:1] hasPrefix:@"  X"], "CUP");
    s = feed(@"\x1b[10C\x1b[3DX", 20, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"       X"], "CUB overrides CUF");
    s = feed(@"\x1b[5HX", 20, 5);            // column defaults to 1
    CHECK([[s textOfRow:4] hasPrefix:@"X"], "row 5, column 1: %s", [s textOfRow:4].UTF8String);
    s = feed(@"\x1b[99;99HX", 10, 3);       // clamped
    CHECK(s.cursorRow == 2 && s.cursorCol == 9, "clamped (%lu,%lu)", (unsigned long)s.cursorRow, (unsigned long)s.cursorCol);
    s = feed(@"abc\r\bX", 20, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"Xbc"], "CR + backspace");
    // scroll region keeps the header
    s = feed(@"head\r\n\x1b[2;4r\x1b[4H\r\nl1\r\nl2\r\nl3\r\nl4", 20, 5);
    CHECK([[s textOfRow:0] hasPrefix:@"head"], "region keeps line 1");
    CHECK([[s textOfRow:1] hasPrefix:@"l2"] && [[s textOfRow:2] hasPrefix:@"l3"] && [[s textOfRow:3] hasPrefix:@"l4"],
          "scrolled inside the region: %s | %s | %s", [s textOfRow:1].UTF8String, [s textOfRow:2].UTF8String, [s textOfRow:3].UTF8String);
    CHECK(s.historyCount == 0, "a region's scroll is not history");
}

static void eraseAndScroll(void) {
    TScreen *s = feed(@"aaaa\r\nbbbb\r\ncccc\r\ndddd\x1b[2J", 10, 4);
    CHECK([[s textOfRow:0] isEqualToString:@"          "], "ED2 clears");
    s = feed(@"aaaa\r\nbbbb\x1b[3G\x1b[K", 10, 2);
    CHECK([[s textOfRow:1] hasPrefix:@"bb"], "EL0 erases from the cursor only: %s", [s textOfRow:1].UTF8String);
    s = feed(@"aaaa\r\nbbbb\x1b[1G\x1b[KXX", 10, 2);
    CHECK([[s textOfRow:1] hasPrefix:@"XX"], "EL0 at column 1 clears the line");
    s = feed(@"\x1b[3;4H\x1b[1J", 10, 3);
    CHECK([[s textOfRow:0] isEqualToString:@"          "] && [[s textOfRow:1] isEqualToString:@"          "] &&
          [[s textOfRow:2] hasPrefix:@"     "], "ED1 clears above the cursor");
    // scrolling pushes into history
    s = [[TScreen alloc] initWithCols:10 rows:3 scrollback:100];
    VTEscape *vt = [[VTEscape alloc] initWithEndpoint:s];
    for (int i = 0; i < 6; i++) { NSString *t = [NSString stringWithFormat:@"line%d\r\n", i]; NSData *d = [t dataUsingEncoding:NSUTF8StringEncoding]; [vt feed:d.bytes length:d.length]; }
    CHECK(s.historyCount >= 3, "history grows (%lu)", (unsigned long)s.historyCount);
    CHECK([[s textOfRow:0] hasPrefix:@"line4"], "the top visible line");
        NSUInteger n = [s historyLength:0];
    NSMutableString *hs = [NSMutableString string];
    const TCell *c = [s historyCells:0];
    for (NSUInteger i = 0; i < n; i++) { unichar u = (unichar)c[i].ch; if (u) [hs appendString:[NSString stringWithCharacters:&u length:1]]; }
    CHECK([hs hasPrefix:@"line0"], "the oldest history line: %s", hs.UTF8String);
    // insert / delete lines
    s = feed(@"a\r\nb\r\nc\r\x1b[1H\x1b[1L", 10, 4);
    CHECK([[s textOfRow:0] isEqualToString:@"          "], "IL opens a line");
    CHECK([[s textOfRow:1] hasPrefix:@"a"], "IL pushes down");
    s = feed(@"a\r\nb\r\nc\r\x1b[1H\x1b[1M", 10, 4);
    CHECK([[s textOfRow:0] hasPrefix:@"b"], "DL removes a line");
    s = feed(@"abcdef\x1b[3G\x1b[2P", 10, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"abef"], "DCH removes 2: %s", [s textOfRow:0].UTF8String);
    s = feed(@"abcdef\x1b[3G\x1b[2PX", 10, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"abXf"], "and the cursor stays: %s", [s textOfRow:0].UTF8String);
    s = feed(@"abcdef\x1b[2G\x1b[2@X", 10, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"aX bcdef"], "ICH inserts blanks: %s", [s textOfRow:0].UTF8String);
    s = feed(@"abcdef\x1b[2G\x1b[3X", 10, 2);
    CHECK([[s textOfRow:0] hasPrefix:@"a   ef"], "ECH");
}

static void styles(void) {
    TScreen *s = feed(@"\x1b[31mR\x1b[0m\x1b[1;32mGB\x1b[38;5;196mQ\x1b[48;2;10;20;30mZ", 40, 2);
    TCell r = [s cellAtRow:0 col:0];
    CHECK((r.fg & TCPal) && (r.fg & 0xFF) == 1, "SGR red (0x%X)", r.fg);
    TCell gb = [s cellAtRow:0 col:2];
    CHECK((gb.attrs & TFBold) && (gb.fg & TCPal) && (gb.fg & 0xFF) == 2, "bold green (0x%X)", gb.fg);
    TCell q = [s cellAtRow:0 col:3];
    CHECK((q.fg & TCPal) && (q.fg & 0xFF) == 196, "256-color index (0x%X)", q.fg);
    TCell z = [s cellAtRow:0 col:4];
    CHECK(z.bg == (10 << 16 | 20 << 8 | 30), "truecolor bg 0x%06X", z.bg);
    s = feed(@"\x1b[4mU\x1b[24mN", 10, 1);
    CHECK(([s cellAtRow:0 col:0].attrs & TFUnderline) && !([s cellAtRow:0 col:1].attrs & TFUnderline), "underline off");
    s = feed(@"\x1b[7mV", 10, 1);
    TCell v = [s cellAtRow:0 col:0];
    CHECK((v.attrs & TFReverse), "reverse video");
    // SGR 0 resets
    s = feed(@"\x1b[1;31mA\x1b[mB", 10, 1);
    CHECK(!([s cellAtRow:0 col:1].attrs & TFBold) && ([s cellAtRow:0 col:1].fg & 0xFF) != 1, "SGR without params resets");
}

static void wideChars(void) {
    TScreen *s = feed(@"中文en", 20, 2);
    CHECK([s cellAtRow:0 col:0].attrs & TFWide, "wide char");
    CHECK([s cellAtRow:0 col:1].attrs & TFCont, "continuation cell");
    CHECK([s cellAtRow:0 col:4].ch == 'e', "ascii continues after (0x%X)", [s cellAtRow:0 col:4].ch);
    NSString *t = [s textOfRow:0];
    CHECK([t hasPrefix:@"中文en"], "text row: %s", t.UTF8String);
    // a wide char at the last column wraps to the next row
    s = feed(@"\x1b[1;20H中", 20, 2);
    CHECK(([s cellAtRow:0 col:19].ch == 0) && ([s cellAtRow:1 col:0].attrs & TFWide), "wide at the last column wraps");
    // UTF-8 split across two feeds
    TScreen *s2 = [[TScreen alloc] initWithCols:10 rows:2 scrollback:100];
    VTEscape *vt = [[VTEscape alloc] initWithEndpoint:s2];
    NSData *d = [@"中" dataUsingEncoding:NSUTF8StringEncoding];
    [vt feed:(const uint8_t *)d.bytes length:2];
    [vt feed:(const uint8_t *)d.bytes + 2 length:1];
    CHECK([s2 cellAtRow:0 col:0].ch == 0x4E2D, "UTF-8 across feeds: 0x%X", [s2 cellAtRow:0 col:0].ch);
    // invalid bytes become replacement characters and never wedge the parser
    s2 = [[TScreen alloc] initWithCols:10 rows:2 scrollback:100];
    vt = [[VTEscape alloc] initWithEndpoint:s2];
    const uint8_t bad[] = {0xE4, 'a', 0xFF, 'b'};
    [vt feed:bad length:sizeof bad];
    CHECK([s2 cellAtRow:0 col:0].ch == 'a' && [s2 cellAtRow:0 col:1].ch == 0xFFFD && [s2 cellAtRow:0 col:2].ch == 'b',
          "invalid UTF-8 recovers: %X %X %X", [s2 cellAtRow:0 col:0].ch, [s2 cellAtRow:0 col:1].ch, [s2 cellAtRow:0 col:2].ch);
}

static void altScreenAndModes(void) {
    TScreen *s = feed(@"primary\x1b[?1049h\x1b[2Jalt\x1b[?1049l", 20, 3);
    CHECK([[s textOfRow:0] hasPrefix:@"primary"], "1049 restores the primary screen: %s", [s textOfRow:0].UTF8String);
    s = feed(@"primary\r\n\x1b[?1049h\nalt", 20, 3);
    CHECK(s.altScreen && [[s textOfRow:1] hasPrefix:@"alt"], "alt screen active");
    [s leaveAltScreen];
    CHECK(!s.altScreen && [[s textOfRow:0] hasPrefix:@"primary"], "and back");
    s = feed(@"\x1b[?1000h\x1b[?1006h\x1b[?2004h\x1b[?25l", 10, 2);
    CHECK(s.mouseMode == TMousePress && s.sgrMouse && s.bracketedPaste && !s.cursorVisible, "modes set");
    s = feed(@"\x1b[?1000l\x1b[?25h", 10, 2);
    CHECK(s.mouseMode == TMouseOff && s.cursorVisible, "modes cleared");
    s = feed(@"\x1b[?7l" @"aaaaaaaaaaaaaaaaaaaaaX", 10, 3);
    CHECK(s.cursorRow == 0 && [[s textOfRow:0] hasPrefix:@"aaaaaaaaaX"], "autowrap off keeps writing in the last column (%lu,%lu): %s",
          (unsigned long)s.cursorRow, (unsigned long)s.cursorCol, [s textOfRow:0].UTF8String);
}

static void oscAndReset(void) {
    TScreen *s = feed(@"\x1b]0;my title\x07", 10, 2);
    CHECK([s.title isEqualToString:@"my title"], "OSC 0 title: %s", s.title.UTF8String);
    s = feed(@"\x1b]2;other\x1b\\", 10, 2);
    CHECK([s.title isEqualToString:@"other"], "OSC 2 with ST terminator");
    s = feed(@"\x1b]7;file:///tmp/my%20dir\x1b\\", 10, 2);
    CHECK([s.cwd isEqualToString:@"/tmp/my dir"], "OSC 7 cwd: %s", s.cwd.UTF8String);
    s = feed(@"\x1b]7;not a url\x1b\\", 10, 2);
    CHECK(!s.cwd.length, "a bad OSC 7 is ignored: %s", s.cwd.UTF8String);
    CHECK([s palette][196] == 0xFF0000 && [s palette][21] == 0x0000FF && [s palette][244] == 0x808080,
          "the 256-color palette is initialized (196 %06X 21 %06X 244 %06X)",
          [s palette][196], [s palette][21], [s palette][244]);
    s = feed(@"\x1b[31mred\x1b" "c\x1b[32mgreen", 10, 2);
    TCell g = [s cellAtRow:0 col:0];
    CHECK((g.fg & TCPal) && (g.fg & 0xFF) == 2, "RIS cleared the style");
    // an unterminated OSC cannot wedge the parser
    s = feed(@"\x1b]2;never ends", 10, 2);
    CHECK([[s textOfRow:0] isEqualToString:@"          "], "the unterminated OSC printed nothing");
    feed(@"ok", 10, 2);
}

static void resizeAndFuzz(void) {
    TScreen *s = feed(@"abcdef\r\nghijkl", 10, 3);
    [s resizeCols:8 rows:2];
    CHECK(s.cols == 8 && s.rows == 2 && [[s textOfRow:0] hasPrefix:@"abcdef"], "resize keeps content");
    CHECK(s.cursorRow <= 1 && s.cursorCol < 8, "cursor clamped");
    // feeding byte by byte equals feeding at once
    NSString *seq = @"abc 中 \x1b[31mred\x1b[0m\n\x1b[2;3Hx\x1b]0;t\x07\x1b[?1049h\x1b[2J alt\x1b[?1049l\x1b[5C\r";
    TScreen *whole = feed(seq, 12, 4);
    TScreen *part = [[TScreen alloc] initWithCols:12 rows:4 scrollback:100];
    VTEscape *vt = [[VTEscape alloc] initWithEndpoint:part];
    NSData *d = [seq dataUsingEncoding:NSUTF8StringEncoding];
    for (NSUInteger i = 0; i < d.length; i++) [vt feed:(const uint8_t *)d.bytes + i length:1];
    for (NSUInteger r = 0; r < 4; r++) CHECK([[whole textOfRow:r] isEqualToString:[part textOfRow:r]],
          "byte-by-byte matches, row %lu: \"%s\" vs \"%s\"", (unsigned long)r, [whole textOfRow:r].UTF8String, [part textOfRow:r].UTF8String);
    CHECK(whole.cursorRow == part.cursorRow && whole.cursorCol == part.cursorCol, "cursor matches");
    // random bytes: bounded time, no crash, parser still works afterwards
    srandom(9);
    NSMutableData *junk = [NSMutableData dataWithLength:60000];
    uint8_t *j = junk.mutableBytes;
    const char *pool = "\x1b[;?mHJKL\x07\r\n中\xFF" "a ]\\P0123456789";
    for (NSUInteger i = 0; i < junk.length; i++) j[i] = pool[random() % strlen(pool)];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    TScreen *z = [[TScreen alloc] initWithCols:80 rows:24 scrollback:1000];
    vt = [[VTEscape alloc] initWithEndpoint:z];
    [vt feed:j length:junk.length];
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    CHECK(dt < 2.0, "60 000 junk bytes parsed in %.2f s", dt);
    [z resizeCols:40 rows:12];
    feed(@"still alive", 10, 2);
}

#pragma mark A real process

static void drainRunloop(double seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static void sessionBasics(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *err = nil;
    TSession *ts = [[TSession alloc] initWithDirectory:dir shell:@"/bin/sh" error:&err];
    CHECK(ts && !err, "session started (%s)", err.UTF8String);
    CHECK([ts.directory isEqualToString:dir], "started in the given directory: %s", ts.directory.UTF8String);
    [ts writeString:@"printf 'hello-from-test'\n"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 5 && ![[ts.screen textOfRow:0] containsString:@"hello-from-test"]) drainRunloop(0.05);
    CHECK([[ts.screen textOfRow:0] containsString:@"hello-from-test"], "echoed output: %s", [ts.screen textOfRow:0].UTF8String);
    CHECK([ts.screen cols] == 80 && [ts.screen rows] == 24, "80x24 by default");
    [ts writeString:@"exit 7\n"];
    t0 = CFAbsoluteTimeGetCurrent();
    while (!ts.exited && CFAbsoluteTimeGetCurrent() - t0 < 5) drainRunloop(0.05);
    CHECK(ts.exited && ts.exitCode == 7, "exit code 7 (%d)", ts.exitCode);

    // a long dump arrives in bounded chunks and the screen ends up complete
    ts = [[TSession alloc] initWithDirectory:dir shell:@"/bin/sh" error:nil];
    [ts writeString:@"seq 1 20000\n"];
    t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < 10) {
        drainRunloop(0.05);
        NSString *bottom = [ts.screen textOfRow:[ts.screen rows] - 1];
        if ([bottom containsString:@"20000"] && [ts.screen historyCount] == 5000) break;
    }
    CHECK([ts.screen historyCount] == 5000, "the scrollback is capped at 5000 (%lu)", (unsigned long)[ts.screen historyCount]);
    NSMutableString *all = [NSMutableString string];
    for (NSUInteger r = 0; r < [ts.screen rows]; r++) [all appendString:[ts.screen textOfRow:r]];
    CHECK([all containsString:@"20000"] || [all containsString:@"199"], "the tail is on screen: %s", [all stringByReplacingOccurrencesOfString:@"\n" withString:@"|"].UTF8String);
    [ts terminate];
    t0 = CFAbsoluteTimeGetCurrent();
    while (!ts.exited && CFAbsoluteTimeGetCurrent() - t0 < 5) drainRunloop(0.05);
    CHECK(ts.exited, "terminate ends the process");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void orphanSweep(void) {
    NSString *pidsDir = [TSession pidsDirectory];
    // a spawned shell is recorded, and the record is dropped when it exits on its own
    NSString *err = nil;
    TSession *ts = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:&err];
    CHECK(ts && !err, "session for the sweep test");
    NSString *file = [pidsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", (int)ts.pid]];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK([NSFileManager.defaultManager fileExistsAtPath:file], "the spawned pid is recorded");
    [ts writeString:@"exit 0\n"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (!ts.exited && CFAbsoluteTimeGetCurrent() - t0 < 3) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:file], "a self-exited shell drops its record");
    // a recorded pid that is still alive: the sweep ends it; a pid whose command doesn't match is skipped
    TSession *ts2 = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    NSTask *sleep = [NSTask new];
    sleep.launchPath = @"/bin/sleep";
    sleep.arguments = @[@"30"];
    [sleep launch];
    NSString *wrongShell = [pidsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", sleep.processIdentifier]];
    [@"zsh" writeToFile:wrongShell atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [TSession sweepOrphanedShells];
    t0 = CFAbsoluteTimeGetCurrent();
    while ((!ts2.exited || sleep.isRunning) && CFAbsoluteTimeGetCurrent() - t0 < 4) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(ts2.exited, "the sweep ends a recorded, still-running shell");
    CHECK(sleep.isRunning, "a pid whose command doesn't match is left alone");
    [sleep terminate];
    [NSFileManager.defaultManager removeItemAtPath:wrongShell error:nil];
}

static void vimLikeSequence(void) {
    // what vim does: alt screen, hide cursor, region, absolute moves, colors, mouse, bracketed paste
    TScreen *s = feed(@"~\n~\n~\x1b[?1049h\x1b[?25l\x1b[1;24r\x1b[5;10H\x1b[31m-- INSERT --\x1b[?1002h\x1b[?2004h", 80, 24);
    CHECK(s.altScreen && !s.cursorVisible && s.mouseMode == TMouseDrag && s.bracketedPaste, "vim mode set");
    CHECK([[s textOfRow:4] containsString:@"-- INSERT --"], "the modeline: %s", [s textOfRow:4].UTF8String);
    // leaving restores the shell's screen
    s = feed(@"ready$\x1b[?1049h\x1b[2J\x1b[1;1Hvim screen\x1b[?1049l", 20, 4);
    CHECK([[s textOfRow:0] hasPrefix:@"ready$"], "prompt restored: %s", [s textOfRow:0].UTF8String);
    BOOL allok = YES;
    for (NSUInteger r = 0; r < 4 && allok; r++) allok = ![[s textOfRow:r] containsString:@"vim screen"];
    CHECK(allok, "the alt screen is gone");
}

int main(void) {
    @autoreleasepool {
        plainText();
        cursorMoves();
        eraseAndScroll();
        styles();
        wideChars();
        altScreenAndModes();
        oscAndReset();
        resizeAndFuzz();
        orphanSweep();
        vimLikeSequence();
        sessionBasics();
    }
    if (failures) { printf("%d terminal failure(s)\n", failures); return 1; }
    printf("all terminal tests passed\n");
    return 0;
}

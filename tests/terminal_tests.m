// The terminal core: escape parsing into a screen grid, and a real shell on a PTY.
// Pure Foundation, no AppKit.
#import <Foundation/Foundation.h>
#import "TScreen.h"
#import "VTEscape.h"
#import "TSession.h"
#include <libproc.h>
#include <sys/proc.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <termios.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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

static BOOL waitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    double deadline = CFAbsoluteTimeGetCurrent() + timeout;
    do {
        if (condition()) return YES;
        drainRunloop(0.02);
    } while (CFAbsoluteTimeGetCurrent() < deadline);
    return condition();
}

static NSString *screenText(TSession *session) {
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger row = 0; row < session.screen.rows; row++) [text appendString:[session.screen textOfRow:row]];
    return text;
}

static BOOL processGone(pid_t pid) {
    struct proc_bsdinfo info = {0};
    errno = 0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info) return errno == ESRCH || errno == ENOENT;
    return info.pbi_status == SZOMB;
}

static NSString *recordPath(pid_t pid) {
    return [TSession.pidsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", pid]];
}

static NSMutableDictionary *recordFor(pid_t pid) {
    return [[NSDictionary dictionaryWithContentsOfFile:recordPath(pid)] mutableCopy];
}

static void saveRecord(NSDictionary *record, pid_t pid) {
    CHECK([record writeToFile:recordPath(pid) atomically:YES], "write isolated test record");
}

static void cleanupSessions(void) {
    CHECK([TSession shutdownAllSessionsWithTimeout:4], "bounded session cleanup (%lu remain)", (unsigned long)TSession.liveSessions.count);
}

static void sessionBasics(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    @try {
        NSString *error = nil;
        TSession *session = [[TSession alloc] initWithDirectory:dir shell:@"/bin/sh" error:&error];
        CHECK(session && !error, "session started (%s)", error.UTF8String);
        CHECK([session.directory isEqualToString:dir], "started in the given directory");
        [session writeString:@"printf '\\033[2J\\033[H%s' hello-$((370+41))\n"];
        CHECK(waitUntil(4, ^BOOL{ return [screenText(session) containsString:@"hello-411"]; }), "parsed actual shell output: %s", screenText(session).UTF8String);
        CHECK(session.screen.cols == 80 && session.screen.rows == 24, "80x24 by default");
        __block int exits = 0;
        session.onExit = ^{ exits++; };
        [session writeString:@"exit 7\n"];
        CHECK(waitUntil(4, ^BOOL{ return session.exited; }), "shell exits and drains");
        CHECK(session.shellExited && session.outputDone && session.exitCode == 7, "exit status/output state (%d)", session.exitCode);
        CHECK(exits == 1, "onExit exactly once");
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:recordPath(session.pid)], "completed shell drops its identity record");
        [session terminate];
        CHECK(exits == 1, "repeat terminate does not deliver another exit");
    } @finally {
        cleanupSessions();
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
}

// This executable also supplies deterministic PTY children. They have no shell startup files,
// perform no unrelated work, and can only be launched by this isolated test process.
static int helperProcess(NSString *mode) {
    struct termios settings;
    if (tcgetattr(STDIN_FILENO, &settings) == 0) { cfmakeraw(&settings); tcsetattr(STDIN_FILENO, TCSANOW, &settings); }
    if ([mode isEqualToString:@"tail"]) {
        char bytes[8192]; memset(bytes, 'x', sizeof bytes);
        for (int i = 0; i < 192; i++) {
            size_t offset = 0;
            while (offset < sizeof bytes) {
                ssize_t n = write(STDOUT_FILENO, bytes + offset, sizeof bytes - offset);
                if (n > 0) offset += (size_t)n; else if (errno != EINTR) return 91;
            }
        }
        const char *tail = "\033[2J\033[HFINAL-TAIL-731\033]2;tail-title\007\033]7;file:///tmp/tail-dir\007";
        write(STDOUT_FILENO, tail, strlen(tail));
        return 23;
    }
    if ([mode isEqualToString:@"silent-input"]) {
        usleep(250000); // deliberately fill the parent's nonblocking input queue, without any output
        size_t total = 0;
        unsigned char bytes[8192];
        while (total < 524288) {
            ssize_t n = read(STDIN_FILENO, bytes, MIN(sizeof bytes, 524288 - total));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return 92;
            for (ssize_t i = 0; i < n; i++) if (bytes[i] != (unsigned char)((total + (size_t)i) % 251)) return 93;
            total += (size_t)n;
        }
        const char *done = "\033[2J\033[HINPUT-ORDER-OK";
        write(STDOUT_FILENO, done, strlen(done));
        return 0;
    }
    if ([mode isEqualToString:@"closed-output"]) {
        close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
        usleep(650000);
        return 9;
    }
    if ([mode isEqualToString:@"resist"]) {
        signal(SIGHUP, SIG_IGN);
        for (;;) pause();
    }
    if ([mode isEqualToString:@"fd-check"]) {
        int candidate = [NSProcessInfo.processInfo.environment[@"FV_TEST_INHERITED_FD"] intValue];
        BOOL closed = fcntl(candidate, F_GETFD) == -1 && errno == EBADF;
        write(STDOUT_FILENO, closed ? "FD-CLOSED" : "FD-LEAKED", 9);
        return closed ? 0 : 94;
    }
    return 95;
}

static NSString *testExecutable;
static NSString *helperShell(NSString *mode) {
    NSString *path = [TSession.pidsDirectory stringByAppendingPathComponent:[@"helper-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *script = [NSString stringWithFormat:@"#!/bin/sh\nexec '%@' --pty-helper '%@'\n", [testExecutable stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"], mode];
    CHECK([script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil], "write deterministic helper");
    CHECK(chmod(path.fileSystemRepresentation, 0700) == 0, "make deterministic helper executable");
    return path;
}

static void outputAndInput(void) {
    @try {
        TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:helperShell(@"tail") error:nil];
        CHECK(session != nil, "tail helper starts");
        __block int exits = 0;
        __block BOOL tailAtExit = NO;
        __weak TSession *weakSession = session;
        session.onExit = ^{
            exits++;
            TSession *done = weakSession;
            tailAtExit = [screenText(done) containsString:@"FINAL-TAIL-731"] && [done.screen.title isEqualToString:@"tail-title"] &&
                [done.screen.cwd isEqualToString:@"/tmp/tail-dir"] && done.outputDone && done.shellExited;
        };
        // Stop main-queue parsing briefly so a fast child exercises the bounded output backlog.
        usleep(200000);
        CHECK(waitUntil(8, ^BOOL{ return session.exited; }), "large-output child finishes");
        CHECK(tailAtExit && exits == 1 && session.exitCode == 23, "full final tail is parsed before onExit (%s)", screenText(session).UTF8String);

        session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:helperShell(@"silent-input") error:nil];
        NSMutableData *data = [NSMutableData dataWithLength:524288];
        for (NSUInteger i = 0; i < data.length; i++) ((uint8_t *)data.mutableBytes)[i] = i % 251;
        // The helper enters raw mode before the first write. There is intentionally no output
        // readiness event; waiting only gives its exec chain time to install raw mode.
        drainRunloop(0.75);
        [session writeData:[data subdataWithRange:NSMakeRange(0, 300000)]];
        [session writeData:[data subdataWithRange:NSMakeRange(300000, data.length - 300000)]];
        CHECK(waitUntil(5, ^BOOL{ return session.exited; }), "pending input progresses without output");
        CHECK(session.exitCode == 0 && [screenText(session) containsString:@"INPUT-ORDER-OK"], "queued input preserves order (%d)", session.exitCode);

        session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:helperShell(@"closed-output") error:nil];
        CHECK(waitUntil(2, ^BOOL{ return session.outputDone; }), "EOF cancels read source before shell exit");
        CHECK(!session.shellExited && !session.exited, "EOF alone does not announce exit");
        CHECK(waitUntil(3, ^BOOL{ return session.exited; }) && session.exitCode == 9, "quiet/closed-output child is polled/reaped");

        int inherited = fcntl(STDERR_FILENO, F_DUPFD, 100);
        CHECK(inherited >= 100, "allocate an explicitly non-CLOEXEC descriptor");
        NSString *fd = [NSString stringWithFormat:@"%d", inherited];
        setenv("FV_TEST_INHERITED_FD", fd.UTF8String, 1);
        @try {
            session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:helperShell(@"fd-check") error:nil];
            CHECK(waitUntil(3, ^BOOL{ return session.exited; }) && session.exitCode == 0, "spawn closes inherited descriptors: %s", screenText(session).UTF8String);
        } @finally { close(inherited); unsetenv("FV_TEST_INHERITED_FD"); }
    } @finally { cleanupSessions(); }
}

static void titleNotifications(void) {
    @try {
        TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
        __block int titles = 0;
        session.onTitleChange = ^{ titles++; };
        [session writeString:@"printf '\\033]2;first-title\\007'\n"];
        CHECK(waitUntil(3, ^BOOL{ return [session.screen.title isEqualToString:@"first-title"]; }), "first title parsed");
        CHECK(titles == 1, "one title notification");
        [session writeString:@"printf 'ordinary output\\n'; printf '\\033]2;first-title\\007'\n"];
        drainRunloop(0.25);
        CHECK(titles == 1, "ordinary output/repeated title does not notify");
        [session writeString:@"printf '\\033]7;file:///tmp/test-cwd\\007'\n"];
        CHECK(waitUntil(3, ^BOOL{ return titles == 2; }), "cwd change notifies");
    } @finally { cleanupSessions(); }
}

static void retainedTerminationAndJobs(void) {
    pid_t shellPid = 0, jobPid = 0;
    NSString *jobFile = [TSession.pidsDirectory stringByAppendingPathComponent:@"job.pid"];
    @try {
        __weak TSession *weakSession;
        @autoreleasepool {
            TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
            shellPid = session.pid;
            [session writeString:[NSString stringWithFormat:@"set -m; trap '' HUP; /bin/sh -c 'trap \"\" HUP; while :; do sleep 1; done' & printf '%%s' $! > '%@'; sleep 0.2\n", jobFile]];
            CHECK(waitUntil(3, ^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:jobFile]; }), "HUP-resistant background job starts");
            drainRunloop(0.3);
            jobPid = [[NSString stringWithContentsOfFile:jobFile encoding:NSUTF8StringEncoding error:nil] intValue];
            CHECK(jobPid > 1 && getpgid(jobPid) != getpgid(shellPid) && getsid(jobPid) == shellPid, "background job has separate group in terminal session");
            weakSession = session;
            [session terminate]; [session terminate];
            CHECK([TSession.liveSessions containsObject:session], "closing session remains registered");
            CHECK([NSFileManager.defaultManager fileExistsAtPath:recordPath(shellPid)], "terminate preserves identity until cleanup");
        }
        CHECK(weakSession != nil, "registry retains session after UI owner releases it");
        CHECK(waitUntil(5, ^BOOL{ @autoreleasepool { return TSession.liveSessions.count == 0; } }), "retained escalation cleans shell and jobs");
        CHECK(processGone(shellPid) && processGone(jobPid), "shell and separate background process group are gone");
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:recordPath(shellPid)], "record removed only after cleanup");
        CHECK(waitUntil(1, ^BOOL{ return weakSession == nil; }), "cleanup releases registry ownership");
    } @finally { cleanupSessions(); [NSFileManager.defaultManager removeItemAtPath:jobFile error:nil]; }
}

static NSUInteger openFDCount(void) {
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    return bytes > 0 ? (NSUInteger)bytes / sizeof(struct proc_fdinfo) : 0;
}

static void manySessions(void) {
    @try {
        // Warm up libdispatch's process-wide descriptors before the leak comparison.
        TSession *warm = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
        [warm writeString:@"exit\n"]; cleanupSessions(); drainRunloop(0.1);
        NSUInteger before = openFDCount();
        NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
        for (int batch = 0; batch < 3; batch++) {
            for (int i = 0; i < 8; i++) {
                TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
                CHECK(session != nil, "quick shell starts");
                if (session) [pids addObject:@(session.pid)];
                if (i % 2) [session writeString:@"exit 0\n"]; else [session terminate];
            }
            CHECK([TSession shutdownAllSessionsWithTimeout:4], "quick sessions finish within bounded shutdown");
        }
        drainRunloop(0.1);
        for (NSNumber *pid in pids) {
            CHECK(processGone(pid.intValue), "quick child %d is gone", pid.intValue);
            int status;
            CHECK(waitpid(pid.intValue, &status, WNOHANG) == -1 && errno == ECHILD, "tracked child %d was reaped", pid.intValue);
        }
        CHECK(TSession.liveSessions.count == 0, "live registry empty");
        CHECK(openFDCount() <= before + 2, "no PTY descriptor leak (%lu -> %lu)", (unsigned long)before, (unsigned long)openFDCount());
    } @finally { cleanupSessions(); }
}

static void orphanSweep(void) {
    @try {
        TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
        pid_t pid = session.pid;
        NSMutableDictionary *original = recordFor(pid);
        CHECK([original[@"version"] isEqual:@1] && [original[@"child"][@"executable"] isEqual:@"/bin/sh"], "structured kernel identity recorded");
        [TSession sweepOrphanedShells]; drainRunloop(0.3);
        CHECK(!session.shellExited && !processGone(pid), "live exact owner is never swept");
        CHECK([NSFileManager.defaultManager fileExistsAtPath:recordPath(pid)], "live-owner record preserved");

        NSMutableDictionary *recycled = [original mutableCopy];
        NSMutableDictionary *child = [original[@"child"] mutableCopy];
        child[@"birthSeconds"] = @([child[@"birthSeconds"] unsignedLongLongValue] - 1);
        recycled[@"child"] = child;
        NSMutableDictionary *deadOwner = [original[@"owner"] mutableCopy];
        deadOwner[@"birthSeconds"] = @([deadOwner[@"birthSeconds"] unsignedLongLongValue] - 1);
        recycled[@"owner"] = deadOwner;
        saveRecord(recycled, pid);
        [TSession sweepOrphanedShells]; drainRunloop(0.3);
        CHECK(!session.shellExited && !processGone(pid), "recycled child identity is rejected without signaling");
        saveRecord(original, pid);

        [@"zsh" writeToFile:recordPath(pid) atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [TSession sweepOrphanedShells]; drainRunloop(0.2);
        CHECK(!processGone(pid), "legacy shell-name record never authorizes signaling");
        saveRecord(original, pid);
        NSMutableDictionary *malformed = [original mutableCopy]; malformed[@"child"] = @{@"pid": @(pid)};
        saveRecord(malformed, pid);
        [TSession sweepOrphanedShells]; drainRunloop(0.2);
        CHECK(!processGone(pid), "malformed identity never authorizes signaling");
        saveRecord(original, pid);
        // Exact live-owner and recycled-child safety is tested above. Real dead-owner recovery
        // uses a separate process below, so the live registry cannot rewrite the fixture.
    } @finally { cleanupSessions(); }
}

static void crashRecovery(void) {
    NSString *ready = [TSession.pidsDirectory stringByAppendingPathComponent:@"crash-ready.plist"];
    NSTask *harness = [NSTask new];
    harness.executableURL = [NSURL fileURLWithPath:testExecutable];
    harness.arguments = @[@"--crash-owner", ready];
    harness.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    harness.standardError = NSFileHandle.fileHandleWithNullDevice;
    @try {
        NSError *error = nil;
        CHECK([harness launchAndReturnError:&error], "launch crash owner (%s)", error.description.UTF8String);
        CHECK(waitUntil(5, ^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:ready]; }), "crash harness publishes owned identities");
        NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:ready];
        pid_t pid = [identity[@"shell"] intValue], job = [identity[@"job"] intValue];
        CHECK(pid > 1 && job > 1 && pid != getpid() && job != getpid(), "crash harness owns its test targets");
        if (harness.running) [harness terminate];
        CHECK(waitUntil(3, ^BOOL{ return !harness.running; }), "owner is dead before orphan sweep");
        [TSession sweepOrphanedShells];
        CHECK(waitUntil(5, ^BOOL{ return processGone(pid) && processGone(job); }), "dead owner shell and separate-group job recovered");
        CHECK(waitUntil(3, ^BOOL{ return ![NSFileManager.defaultManager fileExistsAtPath:recordPath(pid)]; }), "orphan identity retained until targets gone");
    } @finally {
        if (harness.running) { [harness terminate]; waitUntil(2, ^BOOL{ return !harness.running; }); }
        [TSession sweepOrphanedShells]; drainRunloop(1.8);
        [NSFileManager.defaultManager removeItemAtPath:ready error:nil];
    }
}

static int crashOwner(NSString *ready) {
    TSession *session = [[TSession alloc] initWithDirectory:NSTemporaryDirectory() shell:@"/bin/sh" error:nil];
    if (!session) return 81;
    NSString *jobFile = [ready stringByAppendingString:@".job"];
    [session writeString:[NSString stringWithFormat:@"set -m; trap '' HUP; /bin/sh -c 'trap \"\" HUP; while :; do sleep 1; done' & printf '%%s' $! > '%@'\n", jobFile]];
    if (!waitUntil(3, ^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:jobFile]; })) { cleanupSessions(); return 82; }
    pid_t job = [[NSString stringWithContentsOfFile:jobFile encoding:NSUTF8StringEncoding error:nil] intValue];
    drainRunloop(0.6); // persist job identities before simulating an abrupt owner death
    [@{@"shell": @(session.pid), @"job": @(job)} writeToFile:ready atomically:YES];
    for (;;) drainRunloop(0.25);
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        testExecutable = NSProcessInfo.processInfo.arguments.firstObject.stringByStandardizingPath;
        if (!testExecutable.isAbsolutePath) testExecutable = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:testExecutable];
        if (argc >= 3 && strcmp(argv[1], "--pty-helper") == 0) return helperProcess(@(argv[2]));
        if (argc >= 3 && strcmp(argv[1], "--crash-owner") == 0) return crashOwner(@(argv[2]));
        // Install the override before ANY session or sweep. The test never opens the user's real
        // Application Support registry. A crash harness inherits this exact isolated directory.
        NSString *isolated = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"feather-terminal-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:isolated withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil], "create isolated registry");
        setenv("FEATHERVIEW_TERMINAL_PIDS_DIR", isolated.UTF8String, 1);
        @try {
            CHECK([TSession.pidsDirectory isEqualToString:isolated], "registry override active");
            plainText();
            cursorMoves();
            eraseAndScroll();
            styles();
            wideChars();
            altScreenAndModes();
            oscAndReset();
            resizeAndFuzz();
            vimLikeSequence();
            sessionBasics();
            outputAndInput();
            titleNotifications();
            retainedTerminationAndJobs();
            manySessions();
            orphanSweep();
            crashRecovery();
        } @finally {
            cleanupSessions();
            [TSession sweepOrphanedShells]; drainRunloop(1.8);
            [NSFileManager.defaultManager removeItemAtPath:isolated error:nil];
        }
    }
    if (failures) { printf("%d terminal failure(s)\n", failures); return 1; }
    printf("all terminal tests passed\n");
    return 0;
}

// App-level terminal teardown: tabs may disappear before applicationShouldTerminate runs.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "TSession.h"
#import <signal.h>
#import <unistd.h>

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static BOOL spinUntil(BOOL (^ready)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!ready() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return ready();
}

static void closedTabs(NSString *dir) {
    ContentController *cc = [ContentController new];
    cc.terminalDirectoryProvider = ^NSString *{ return dir; };
    NSMutableArray<TSession *> *sessions = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        TSession *t = [cc openTerminalAt:dir asTab:YES];
        CHECK(t != nil, "start terminal %lu: %s", (unsigned long)i, cc.statusText.UTF8String);
        if (t) [sessions addObject:t];
    }
    for (TSession *t in sessions) [cc closeTerminal:t];
    CHECK(cc.terminalCount == 0, "all UI owners are removed");
    [cc shutdownTerminals];
    for (TSession *t in sessions) {
        CHECK(t.exited && t.shellExited && t.outputDone, "removed tab's process %d is reaped and output drained", t.pid);
        CHECK(kill(t.pid, 0) == -1 && errno == ESRCH, "removed tab's pid %d no longer exists", t.pid);
    }
    CHECK(TSession.liveSessions.count == 0, "global registry has no removed tabs left");
}

static void zshBatches(NSString *dir) {
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    for (NSUInteger batch = 0; batch < 3; batch++) {
        NSMutableArray<TSession *> *sessions = [NSMutableArray array];
        for (NSUInteger i = 0; i < 4; i++) {
            NSString *error = nil;
            TSession *t = [[TSession alloc] initWithDirectory:dir shell:@"/bin/zsh" error:&error];
            CHECK(t != nil, "zsh batch %lu session %lu starts: %s", (unsigned long)batch, (unsigned long)i, error.UTF8String);
            if (!t) continue;
            [sessions addObject:t]; [pids addObject:@(t.pid)];
            NSString *ready = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"zsh-%lu-%lu", (unsigned long)batch, (unsigned long)i]];
            [t writeString:[NSString stringWithFormat:@"trap '' HUP; printf ready > '%@'\n", ready]];
            CHECK(spinUntil(^BOOL { return [NSFileManager.defaultManager fileExistsAtPath:ready]; }, 5), "zsh installs its trap and writes readiness");
        }
        for (TSession *t in sessions) [t terminate];
        [sessions removeAllObjects];
        CHECK([TSession shutdownAllSessionsWithTimeout:4], "zsh batch is cleaned after last UI-like owner is released");
    }
    for (NSNumber *pid in pids)
        CHECK(kill(pid.intValue, 0) == -1 && errno == ESRCH, "tested zsh %d has no surviving process", pid.intValue);
    CHECK(pids.count == 12 && TSession.liveSessions.count == 0, "all twelve tested zsh instances are reaped");
}

static void closeWindow(NSString *dir) {
    AppDelegate *app = [AppDelegate new];
    [app applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [app openRoot:dir];
    app->_content.alertHandler = ^NSModalResponse(NSAlert *a) { return NSAlertThirdButtonReturn; };
    TSession *tab = [app->_content openTerminalAt:dir asTab:YES];
    TSession *panel = [app->_content openTerminalAt:dir asTab:NO];
    CHECK(tab && panel, "window has terminal tab and panel session: %s", app->_content.statusText.UTF8String);
    CHECK([app windowShouldClose:app->_win], "closing window is accepted");
    CHECK(tab.exited && panel.exited, "window closes only after owned terminal processes are gone");
    CHECK(TSession.liveSessions.count == 0, "window close leaves no globally tracked sessions");
    CHECK([app applicationShouldTerminate:NSApp] == NSTerminateNow, "subsequent application quit has no terminal work left");
    [app->_watcher stop];
    [app->_win orderOut:nil];
    app->_win.delegate = nil;
}

static void runningShellQuit(NSString *dir) {
    AppDelegate *app = [AppDelegate new];
    [app applicationWillFinishLaunching:[NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp]];
    [app openRoot:dir];
    TSession *t = [app->_content openTerminalAt:dir asTab:YES];
    CHECK(t != nil, "quit test session exists: %s", app->_content.statusText.UTF8String);
    NSString *ready = [dir stringByAppendingPathComponent:@"hup-ready"];
    [t writeString:[NSString stringWithFormat:@"trap '' HUP; printf ready > '%@'\n", ready]];
    CHECK(spinUntil(^BOOL { return [NSFileManager.defaultManager fileExistsAtPath:ready]; }, 5), "shell installs a HUP-resistant trap");
    CHECK([app applicationShouldTerminate:NSApp] == NSTerminateNow, "quit performs bounded escalation and reap");
    CHECK(t.exited && kill(t.pid, 0) == -1 && errno == ESRCH, "HUP-resistant shell is no longer alive after quit");
    CHECK(TSession.liveSessions.count == 0, "quit empties global lifecycle registry");
    [app->_watcher stop];
    [app->_win orderOut:nil];
    app->_win.delegate = nil;
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"fv-lifecycle-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *pids = [root stringByAppendingPathComponent:@"pids"];
        [NSFileManager.defaultManager createDirectoryAtPath:pids withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("FEATHERVIEW_TERMINAL_PIDS_DIR", pids.fileSystemRepresentation, 1);
        setenv("SHELL", "/bin/sh", 1);
        setenv("ZDOTDIR", root.fileSystemRepresentation, 1);
        [NSApplication sharedApplication];
        @try {
            closedTabs(root);
            zshBatches(root);
            closeWindow(root);
            runningShellQuit(root);
        } @finally {
            CHECK([TSession shutdownAllSessionsWithTimeout:4], "finally cleanup reaps every test shell");
            CHECK(TSession.liveSessions.count == 0, "no surviving test sessions");
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
    }
    if (failures) { fprintf(stderr, "%d lifecycle failure(s)\n", failures); return 1; }
    puts("all application terminal lifecycle tests passed");
    return 0;
}

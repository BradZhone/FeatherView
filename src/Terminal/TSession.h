#import <Foundation/Foundation.h>
#import "TScreen.h"

NS_ASSUME_NONNULL_BEGIN

// Main-thread-owned shell, PTY and parser. Reads/writes run on a serial queue; parsing and every
// callback run on the main thread. The live registry owns sessions independently of their views.
@interface TSession : NSObject

// dir: working directory (nil: home). shell: nil → $SHELL or /bin/zsh, run as a login shell.
- (nullable instancetype)initWithDirectory:(nullable NSString *)dir shell:(nullable NSString *)shell error:(NSString *_Nullable *_Nullable)error;

@property (nonatomic, readonly) TScreen *screen;
@property (nonatomic, readonly) NSString *directory;
@property (nonatomic, readonly) NSString *shellName;
@property (nonatomic, readonly) int pid;
@property (nonatomic, readonly) BOOL shellExited; // the actual child has been reaped; exitCode is available
@property (nonatomic, readonly) BOOL outputDone;  // PTY EOF and all buffered output has been parsed
@property (nonatomic, readonly) BOOL terminating;
@property (nonatomic, readonly) BOOL exited;      // reaped, outputDone, descriptors closed, jobs cleaned up
@property (nonatomic, readonly) int exitCode;     // shell status (128 + signal), -1 before exit/if unavailable
@property (nonatomic, readonly) BOOL running;     // shell has not exited or been asked to terminate

@property (nonatomic, copy, nullable) void (^onChange)(void);
@property (nonatomic, copy, nullable) void (^onTitleChange)(void); // only when the parsed title/cwd changes
@property (nonatomic, copy, nullable) void (^onExit)(void);        // once, after final output/cleanup

- (void)writeString:(NSString *)s;
- (void)writeData:(NSData *)d;
- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows;
- (void)terminate; // idempotent: validated shell/jobs get HUP, then KILL after a bounded grace period

+ (NSString *)defaultShell;
+ (NSArray<TSession *> *)liveSessions; // main thread; includes closing sessions no longer owned by a view
// Main thread, pumps the runloop and reaps children. YES means all sessions finished. On timeout,
// returns NO and leaves unfinished sessions/records owned for continued cleanup and crash recovery.
+ (BOOL)shutdownAllSessionsWithTimeout:(NSTimeInterval)timeout;

// Asynchronous, identity-checked recovery of this application's records with a provably dead owner.
// Never signals a live owner's sessions, recycled pids, or unverifiable legacy shell-name records.
+ (void)sweepOrphanedShells;
// Tests MUST set FEATHERVIEW_TERMINAL_PIDS_DIR to an isolated absolute directory before spawning or
// sweeping. Each session captures its directory at creation; production defaults to Application Support.
@property (class, nonatomic, readonly) NSString *pidsDirectory;

+ (NSString *)registerDragSession:(TSession *)session;
+ (nullable TSession *)sessionForDragToken:(NSString *)token;

@end

NS_ASSUME_NONNULL_END

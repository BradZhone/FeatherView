#import <Foundation/Foundation.h>
#import "TScreen.h"

NS_ASSUME_NONNULL_BEGIN

// A shell session: a PTY, a login shell running on it, a screen the output is parsed into. All
// screen access and parsing happen on the main thread (output arrives in bounded chunks, so the UI
// keeps responding), the raw reads happen on a background queue.
@interface TSession : NSObject

// dir: working directory (nil: home). shell: nil → $SHELL or /bin/zsh, run as a login shell.
- (nullable instancetype)initWithDirectory:(nullable NSString *)dir shell:(nullable NSString *)shell error:(NSString *_Nullable *_Nullable)error;

@property (nonatomic, readonly) TScreen *screen;
@property (nonatomic, readonly) NSString *directory;        // where it was started
@property (nonatomic, readonly) NSString *shellName;        // "zsh", "bash" …
@property (nonatomic, readonly) int pid;                    // the shell's process id
@property (nonatomic, readonly) BOOL exited;
@property (nonatomic, readonly) int exitCode;               // the shell's exit status, -1 before exit
@property (nonatomic, readonly) BOOL running;               // not exited (the shell itself may be busy)

@property (nonatomic, copy, nullable) void (^onChange)(void);       // output arrived (main thread)
@property (nonatomic, copy, nullable) void (^onTitleChange)(void);  // title or cwd changed (main thread)
@property (nonatomic, copy, nullable) void (^onExit)(void);         // main thread

- (void)writeString:(NSString *)s;
- (void)writeData:(NSData *)d;
- (void)resizeCols:(NSUInteger)cols rows:(NSUInteger)rows;
- (void)terminate;                                          // hang up, then SIGKILL after a moment

+ (NSString *)defaultShell;

// Kills terminal shells left behind by an instance that exited without closing them. Every spawned
// shell's pid is recorded under Application Support; at launch the recorded pids that are still
// alive (and still that shell) get SIGHUP, then SIGKILL if they survive. Nothing to clean: no-op.
+ (void)sweepOrphanedShells;
@property (class, nonatomic, readonly) NSString *pidsDirectory;   // where the pid records live (tests)

// Drag & drop between the tab bar and the terminal panel: a pasteboard carries an opaque token
// that maps back to the session (the registry lives here so both views can reach it without ARC
// pointer types on the pasteboard).
+ (NSString *)registerDragSession:(TSession *)session;
+ (nullable TSession *)sessionForDragToken:(NSString *)token;

@end

NS_ASSUME_NONNULL_END

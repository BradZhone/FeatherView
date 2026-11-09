#import "FileWatcher.h"
#import "FileWalker.h"
#import <CoreServices/CoreServices.h>

@implementation FileWatcher {
    FSEventStreamRef _stream;
    void (^_onChange)(void);
}

+ (BOOL)pathIsInteresting:(NSString *)path root:(NSString *)root {
    if (![path hasPrefix:root]) return YES;
    NSString *rel = [path substringFromIndex:MIN(root.length, path.length)];
    NSSet *skip = FWSkippedDirs();
    for (NSString *c in rel.pathComponents) {
        if ([c hasPrefix:@".feather-"]) return NO;              // a save in progress
        if ([skip containsObject:c] || [c isEqualToString:@".git"]) return NO;
    }
    return YES;
}

static void callback(ConstFSEventStreamRef s, void *info, size_t n, void *paths, const FSEventStreamEventFlags *flags, const FSEventStreamEventId *ids) {
    FileWatcher *w = (__bridge FileWatcher *)info;
    NSArray<NSString *> *ps = (__bridge NSArray *)paths;
    for (size_t i = 0; i < n; i++) {
        if ((flags[i] & kFSEventStreamEventFlagMustScanSubDirs) || [FileWatcher pathIsInteresting:ps[i] root:w->_root]) {
            if (w->_onChange) w->_onChange();
            return;
        }
    }
}

- (instancetype)initWithRoot:(NSString *)root onChange:(void (^)(void))onChange {
    if (!root.length || !(self = [super init])) return nil;
    _root = [root.stringByResolvingSymlinksInPath copy];       // FSEvents reports real paths
    _onChange = [onChange copy];
    FSEventStreamContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    _stream = FSEventStreamCreate(NULL, callback, &ctx, (__bridge CFArrayRef)@[_root], kFSEventStreamEventIdSinceNow, 0.5,
                                  kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
    if (!_stream) return nil;
    FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
    if (!FSEventStreamStart(_stream)) { [self stop]; return nil; }
    return self;
}

- (void)stop {
    if (!_stream) return;
    FSEventStreamStop(_stream);
    FSEventStreamInvalidate(_stream);
    FSEventStreamRelease(_stream);
    _stream = NULL;
    _onChange = nil;
}

- (void)dealloc { [self stop]; }

@end

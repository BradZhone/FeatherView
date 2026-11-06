#import "BinaryPreviews.h"
#import "Localization.h"
#import "TablePreview.h"
#import "TableModel.h"
#import "CanvasView.h"
#import "DataPreviews.h"

static const NSUInteger kMaxEntries = 200000;

@implementation ArchivePreview {
    NSString *_path;
    TablePreview *_grid;
    NSArray<NSArray<NSString *> *> *_rows;        // name, size, modified, kind
    unsigned long long _total;
    NSString *_error;
}

static NSData *runTar(NSArray *args, int *status) {
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/bsdtar"];
    t.arguments = args;
    t.environment = @{@"LC_ALL": @"C", @"PATH": @"/usr/bin:/bin"};
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) { *status = -1; return nil; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    *status = t.terminationStatus;
    return d;
}

// "-rw-r--r--  0 user group  1234 Mar  4 12:30 dir/name" — owner names may hold spaces, so the size is the
// number right before the date. Names come from the plain listing, matched line by line.
static NSArray *parseListing(NSString *verbose, NSArray<NSString *> *names, unsigned long long *total) {
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"^(\\S{10})\\s.*?\\s(\\d+)\\s+([A-Z][a-z]{2})\\s+(\\d{1,2})\\s+(\\d{1,2}:\\d{2}|\\d{4})\\s" options:0 error:nil];
    NSArray *months = @[@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun", @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"];
    NSInteger year = [NSCalendar.currentCalendar component:NSCalendarUnitYear fromDate:NSDate.date];
    NSArray *lines = [verbose componentsSeparatedByString:@"\n"];
    NSMutableArray *rows = [NSMutableArray array];
    *total = 0;
    for (NSUInteger i = 0; i < names.count && i < kMaxEntries; i++) {
        NSString *name = names[i], *size = @"", *when = @"";
        BOOL dir = [name hasSuffix:@"/"];
        NSString *l = i < lines.count ? lines[i] : @"";
        NSTextCheckingResult *m = [re firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        if (m) {
            dir = dir || [[l substringWithRange:[m rangeAtIndex:1]] hasPrefix:@"d"];
            unsigned long long bytes = [[l substringWithRange:[m rangeAtIndex:2]] longLongValue];
            if (!dir) { size = FTGrouped((NSUInteger)bytes); *total += bytes; }
            NSUInteger mon = [months indexOfObject:[l substringWithRange:[m rangeAtIndex:3]]] + 1;
            NSString *t = [l substringWithRange:[m rangeAtIndex:5]];
            BOOL hasTime = [t containsString:@":"];
            when = [NSString stringWithFormat:@"%ld-%02lu-%02ld%@", (long)(hasTime ? year : t.integerValue), (unsigned long)mon,
                    (long)[l substringWithRange:[m rangeAtIndex:4]].integerValue, hasTime ? [@" " stringByAppendingString:t] : @""];
        }
        [rows addObject:@[name, size, when, dir ? FTL(@"folder") : (name.pathExtension.length ? name.pathExtension.lowercaseString : FTL(@"file"))]];
    }
    return rows;
}

- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path {
    if (!(self = [super initWithFrame:frame])) return nil;
    FTClipToBounds(self);
    _path = [path copy];
    _grid = [[TablePreview alloc] initWithFrame:self.bounds];
    _grid.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _grid.extraInfo = FTL(@"Reading…");
    [self addSubview:_grid];
    __weak ArchivePreview *weakSelf = self;
    _grid.onActivateRow = ^(NSUInteger row) { [weakSelf extract:row]; };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int s1 = 0, s2 = 0;
        NSData *plain = runTar(@[@"-tf", path], &s1), *verbose = runTar(@[@"-tvf", path], &s2);
        NSString *p = [[NSString alloc] initWithData:plain ?: NSData.data encoding:NSUTF8StringEncoding] ?: @"";
        NSMutableArray *names = [[p componentsSeparatedByString:@"\n"] mutableCopy];
        [names removeObject:@""];
        unsigned long long total = 0;
        NSArray *rows = s1 == 0 ? parseListing([[NSString alloc] initWithData:verbose ?: NSData.data encoding:NSUTF8StringEncoding] ?: @"", names, &total) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            ArchivePreview *me = weakSelf;
            if (!me) return;
            me->_rows = rows ?: @[];
            me->_total = total;
            me->_loaded = YES;
            if (!rows) me->_error = FTL(@"Couldn’t read this archive (it may be damaged or encrypted)");
            [me->_grid setModel:[ArrayTable tableWithHeaders:@[FTL(@"Name"), FTL(@"Size (bytes)"), FTL(@"Modified"), FTL(@"Kind")] rows:me->_rows truncated:names.count > kMaxEntries]];
            me->_grid.extraInfo = me->_error ?: [NSString stringWithFormat:FTL(@"%@ uncompressed · double-click a file to open it"),
                [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile]];
            if (me.onChange) me.onChange();
        });
    });
    return self;
}

- (BOOL)isFlipped { return YES; }
- (TablePreview *)grid { return _grid; }
- (NSUInteger)entryCount { return _rows.count; }
- (NSString *)status {
    if (!_loaded) return FTL(@"Archive   Reading…");
    if (_error) return [FTL(@"Archive   ") stringByAppendingString:_error];
    return [NSString stringWithFormat:FTLP(_rows.count, @"Archive (read-only)   %@ item", @"Archive (read-only)   %@ items"), FTGrouped(_rows.count)];
}

- (void)extract:(NSUInteger)row {
    if (row >= _rows.count || [_rows[row][3] isEqual:FTL(@"folder")]) { NSBeep(); return; }
    NSString *name = _rows[row][0], *archive = _path;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"feather-archive-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    __weak ArchivePreview *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = 0;
        runTar(@[@"-xf", archive, @"-C", dir, @"--", name], &status);
        NSString *out = [dir stringByAppendingPathComponent:name];
        BOOL ok = status == 0 && [NSFileManager.defaultManager fileExistsAtPath:out];
        dispatch_async(dispatch_get_main_queue(), ^{
            ArchivePreview *me = weakSelf;
            if (!ok) { NSBeep(); return; }
            if (me.onOpenFile) me.onOpenFile(out);
        });
    });
}

@end

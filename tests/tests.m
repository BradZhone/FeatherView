#import <Foundation/Foundation.h>
#import "PieceTable.h"
#import "FileKind.h"
#import "FileWalker.h"
#import "FileOps.h"
#import "WorkspaceSearch.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static void verify(PieceTable *pt, NSData *ref, int step) {
    CHECK(pt.length == ref.length, "step %d length %lu vs %lu", step, pt.length, ref.length);
    NSData *all = [pt dataInRange:NSMakeRange(0, pt.length)];
    CHECK([all isEqualToData:ref], "step %d content mismatch", step);
    const uint8_t *b = ref.bytes;
    NSUInteger lines = 1;
    for (NSUInteger i = 0; i < ref.length; i++) if (b[i] == '\n') {
        CHECK([pt lineStart:lines] == i + 1, "step %d lineStart(%lu)", step, lines);
        lines++;
    }
    CHECK(pt.lineCount == lines, "step %d lineCount %lu vs %lu", step, pt.lineCount, lines);
    for (NSUInteger k = 0; k < ref.length; k += 7) {
        NSUInteger L = [pt lineForOffset:k];
        CHECK([pt lineStart:L] <= k && (L + 1 >= pt.lineCount || [pt lineStart:L + 1] > k), "step %d lineForOffset", step);
    }
}

static void fuzz(void) {
    srandom(42);
    NSMutableData *ref = [[@"hello\nworld\n中文\nlast" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    PieceTable *pt = [[PieceTable alloc] initWithData:[ref copy]];
    const char *alphabet = "ab\n\nxyz \t";
    for (int step = 0; step < 4000; step++) {
        if (random() % 3 || ref.length == 0) {
            NSUInteger at = ref.length ? random() % (ref.length + 1) : 0;
            NSUInteger n = 1 + random() % 6;
            uint8_t buf[8];
            for (NSUInteger i = 0; i < n; i++) buf[i] = alphabet[random() % strlen(alphabet)];
            [pt insertBytes:buf length:n at:at];
            [ref replaceBytesInRange:NSMakeRange(at, 0) withBytes:buf length:n];
        } else {
            NSUInteger at = random() % ref.length, n = 1 + random() % MIN((NSUInteger)10, ref.length - at);
            [pt deleteRange:NSMakeRange(at, n)];
            [ref replaceBytesInRange:NSMakeRange(at, n) withBytes:NULL length:0];
        }
        if (step % 50 == 0) verify(pt, ref, step);
    }
    verify(pt, ref, -1);
}

static void search(void) {
    NSData *d = [@"one Two three two\nTWO" dataUsingEncoding:NSUTF8StringEncoding];
    PieceTable *pt = [[PieceTable alloc] initWithData:d];
    NSData *n = [@"two" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK([pt find:n from:0 backward:NO] == 4, "find first");
    CHECK([pt find:n from:5 backward:NO] == 14, "find second");
    CHECK([pt find:n from:15 backward:NO] == 18, "find third");
    CHECK([pt find:n from:19 backward:NO] == 4, "wrap forward");
    CHECK([pt find:n from:14 backward:YES] == 4, "find backward");
    CHECK([pt find:n from:3 backward:YES] == 18, "wrap backward");
    CHECK([pt find:[@"zzz" dataUsingEncoding:NSUTF8StringEncoding] from:0 backward:NO] == NSNotFound, "absent");
}

static void crlf(void) {
    PieceTable *pt = [[PieceTable alloc] initWithData:[@"ab\r\ncd\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    CHECK(pt.usesCRLF, "crlf detect");
    CHECK([pt lineEnd:0] == 2 && [pt lineStart:1] == 4 && [pt lineEnd:1] == 6, "crlf line end");
    CHECK(pt.lineCount == 3, "crlf lines");
}

static void utf8(void) {
    const char *ok = "abc 中文 😀";
    CHECK(FKIsValidUTF8((const uint8_t *)ok, strlen(ok)), "valid utf8");
    uint8_t bad1[] = {0xE4, 0xB8};          // truncated
    uint8_t bad2[] = {0xC0, 0x80};          // overlong
    uint8_t gbk[] = {0xD6, 0xD0, 0xCE, 0xC4}; // "中文" in GBK
    CHECK(!FKIsValidUTF8(bad1, 2), "truncated");
    CHECK(!FKIsValidUTF8(bad2, 2), "overlong");
    CHECK(!FKIsValidUTF8(gbk, 4), "gbk not utf8");
    CHECK(FKGuessKind(@"a.png") == ViewerImage && FKGuessKind(@"a.pdf") == ViewerPDF && FKGuessKind(@"a.mov") == ViewerQuickLook &&
          FKGuessKind(@"a.svg") == ViewerText && FKGuessKind(@"Makefile") == ViewerText, "guess kind");
}

static NSString *makeTree(void) {
    NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
                      stringByResolvingSymlinksInPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *files = @{@"src/main.m": @"int value = 1;\nreturn Value;\n",
                            @"src/TextEditorView.m": @"// editor\n",
                            @"docs/中文.md": @"中文 value 结束\n",
                            @"node_modules/x/index.js": @"value\n",
                            @".hidden/secret.txt": @"value\n",
                            @"bin.dat": @"value\0\0\0"};
    for (NSString *rel in files) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *s = files[rel];
        [[s dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:NO];
    }
    return root;
}

static NSSet *walked(NSString *root, BOOL hidden) {
    NSMutableSet *s = [NSMutableSet set];
    FWWalk(root, hidden, ^BOOL(NSString *rel, const char *abs) { [s addObject:rel]; return YES; });
    return s;
}

static void walker(NSString *root) {
    NSSet *s = walked(root, NO);
    CHECK([s containsObject:@"src/main.m"] && [s containsObject:@"docs/中文.md"], "walk finds files: %s", s.description.UTF8String);
    CHECK(![s containsObject:@"node_modules/x/index.js"], "walk skips node_modules");
    CHECK(![s containsObject:@".hidden/secret.txt"], "walk skips hidden");
    CHECK([walked(root, YES) containsObject:@".hidden/secret.txt"], "walk includes hidden on request");
}

static void fuzzy(void) {
    CHECK(FWFuzzyScore(@"main", @"src/main.m") > FWFuzzyScore(@"main", @"domain/stuff/a.m"), "file name beats dir");
    CHECK(FWFuzzyScore(@"xyz", @"src/main.m") == FWNoMatch, "no match");
    CHECK(FWFuzzyScore(@"tev", @"src/TextEditorView.m") != FWNoMatch, "camel subsequence");
    CHECK(FWFuzzyScore(@"src main", @"src/main.m") != FWNoMatch, "spaces ignored");
    NSArray *paths = @[@"tests/editor_tests.m", @"src/TextEditorView.m", @"src/TextEditorView+Edit.m", @"README"];
    NSArray *r = FWRank(@"texteditorview", paths, 10);
    CHECK(r.count == 2 && [r[0] intValue] == 1, "rank exact name first: %s", r.description.UTF8String);
}

static void fileOps(NSString *root) {
    CHECK(FOValidateName(@"a/b") && FOValidateName(@"") && FOValidateName(@"..") && !FOValidateName(@"ok.txt"), "validate");
    NSString *f = [root stringByAppendingPathComponent:@"new.txt"];
    CHECK(!FOCreate(f, NO), "create file");
    CHECK(FOCreate(f, NO) != nil, "create refuses existing");
    CHECK(!FOCreate([root stringByAppendingPathComponent:@"dir"], YES), "create dir");
    NSString *g = [root stringByAppendingPathComponent:@"New.txt"];
    CHECK(!FORename(f, g), "case-only rename");
    CHECK(FORename(g, [root stringByAppendingPathComponent:@"src/main.m"]) != nil, "rename never overwrites");
    CHECK(FORename(g, [root stringByAppendingPathComponent:@"src"]) != nil, "rename onto dir refused");
    CHECK(FOPathIsWithin(@"/a/b/c", @"/a/b") && !FOPathIsWithin(@"/a/bc", @"/a/b") && FOPathIsWithin(@"/a", @"/a"), "within");
}

static NSArray<SearchHit *> *runSearch(NSString *q, NSString *root, BOOL cs, BOOL rg, NSUInteger max, BOOL *trunc) {
    WorkspaceSearch *ws = [WorkspaceSearch new];
    ws.disableRipgrep = !rg;
    if (max) ws.maxHits = max;
    NSMutableArray *hits = [NSMutableArray array];
    __block BOOL finished = NO;
    [ws search:q root:root caseSensitive:cs includeHidden:NO
       onBatch:^(NSArray *h, NSUInteger f) { [hits addObjectsFromArray:h]; }
        onDone:^(BOOL t) { finished = YES; if (trunc) *trunc = t; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    CHECK(finished, "search finished (rg=%d)", rg);
    return hits;
}

static void workspaceSearch(NSString *root, BOOL rg) {
    NSArray *hits = runSearch(@"value", root, NO, rg, 0, NULL);
    NSMutableSet *rels = [NSMutableSet set];
    for (SearchHit *h in hits) [rels addObject:[h.path substringFromIndex:root.length + 1]];
    CHECK([rels containsObject:@"src/main.m"] && [rels containsObject:@"docs/中文.md"], "rg=%d finds: %s", rg, rels.description.UTF8String);
    CHECK(![rels containsObject:@"node_modules/x/index.js"] && ![rels containsObject:@".hidden/secret.txt"] &&
          ![rels containsObject:@"bin.dat"], "rg=%d skips: %s", rg, rels.description.UTF8String);
    for (SearchHit *h in hits) {
        if ([h.path hasSuffix:@"main.m"] && h.line == 1)
            CHECK(h.column == 5 && [[h.preview substringWithRange:h.previewMatch] isEqualToString:@"value"], "rg=%d col/preview", rg);
        if ([h.path hasSuffix:@"中文.md"])
            CHECK(h.column == 8 && [[h.preview substringWithRange:h.previewMatch] isEqualToString:@"value"], "rg=%d utf8 col %lu", rg, h.column);
    }
    NSUInteger mainHits = 0;
    for (SearchHit *h in hits) if ([h.path hasSuffix:@"main.m"]) mainHits++;
    CHECK(mainHits == 2, "rg=%d case-insensitive hits %lu", rg, mainHits);
    mainHits = 0;
    for (SearchHit *h in runSearch(@"Value", root, YES, rg, 0, NULL)) if ([h.path hasSuffix:@"main.m"]) mainHits++;
    CHECK(mainHits == 1, "rg=%d case-sensitive", rg);
    BOOL trunc = NO;
    CHECK(runSearch(@"value", root, NO, rg, 1, &trunc).count == 1 && trunc, "rg=%d truncation", rg);
}

int main(void) {
    @autoreleasepool {
        fuzz(); search(); crlf(); utf8(); fuzzy();
        NSString *root = makeTree();
        walker(root);
        workspaceSearch(root, NO);
        if ([WorkspaceSearch ripgrepPath]) workspaceSearch(root, YES);
        else printf("(ripgrep not installed; rg path not tested)\n");
        fileOps(root);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all tests passed\n");
    return 0;
}

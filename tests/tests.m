#import <Foundation/Foundation.h>
#import "PieceTable.h"
#import "FileKind.h"
#import "FileWalker.h"
#import "FileOps.h"
#import "WorkspaceSearch.h"
#import "TableModel.h"
#import "JSONTree.h"
#import "Notebook.h"
#import "XLWorkbook.h"
#import "XLNumberFormat.h"
#import "XLXML.h"
#include "xlsx_fixture.h"

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
          FKGuessKind(@"a.svg") == ViewerImage && FKGuessKind(@"Makefile") == ViewerText, "guess kind");
}

// .ts is MPEG-2 video and .key is Keynote as far as macOS knows; the bytes decide.
static void guessKindByContent(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *(^put)(NSString *, NSData *) = ^NSString *(NSString *name, NSData *data) {
        NSString *p = [d stringByAppendingPathComponent:name];
        [data writeToFile:p atomically:YES];
        return p;
    };
    NSData *(^text)(NSString *) = ^NSData *(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; };
    NSMutableData *video = [NSMutableData dataWithLength:188 * 8];             // MPEG-TS packets: 0x47 sync + PIDs with zeros
    for (NSUInteger i = 0; i < 8; i++) ((uint8_t *)video.mutableBytes)[i * 188] = 0x47;
    CHECK(FKGuessKind(put(@"app.ts", text(@"export const x: number = 1;\n"))) == ViewerText, ".ts with TypeScript → editor");
    CHECK(FKGuessKind(put(@"中文.mts", text(@"// 注释\nexport {}\n"))) == ViewerText, ".mts with UTF-8 text → editor");
    CHECK(FKGuessKind(put(@"empty.ts", [NSData data])) == ViewerText, "empty .ts → editor");
    CHECK(FKGuessKind(put(@"clip.ts", video)) == ViewerQuickLook, "real MPEG-TS video → Quick Look");
    CHECK(FKGuessKind(put(@"server.key", text(@"-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n"))) == ViewerText,
          "PEM .key → editor, not Keynote");
    CHECK(FKGuessKind([d stringByAppendingPathComponent:@"missing.ts"]) == ViewerQuickLook, "unreadable .ts keeps the old guess");
    CHECK(FKGuessKind(put(@"notes.rtf", text(@"{\\rtf1 hi}"))) == ViewerQuickLook, "RTF still rendered by Quick Look");
    [NSFileManager.defaultManager removeItemAtPath:d error:nil];
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

static void pathFilter(void) {
    FWPathFilter *f = [FWPathFilter filterWithString:@"src, *.ts, !*.test.ts, !vendor"];
    CHECK([f allowsFile:@"src/app.m"] && [f allowsFile:@"lib/x.ts"] && ![f allowsFile:@"lib/x.test.ts"] &&
          ![f allowsFile:@"src/vendor/y.m"] && ![f allowsFile:@"docs/a.md"], "include / exclude words and globs");
    CHECK([f prunesDirectory:@"src/vendor"] && ![f prunesDirectory:@"src"], "excluded folders are pruned");
    FWPathFilter *ext = [FWPathFilter filterWithString:@"svg .md"];
    CHECK([ext allowsFile:@"a/b/logo.SVG"] && [ext allowsFile:@"README.md"] && ![ext allowsFile:@"svgs/a.png"] &&
          [ext allowsFile:@"svg/a.png"], "bare word = extension or folder");
    CHECK([[FWPathFilter filterWithString:@"src/app"] allowsFile:@"src/app/x.m"] && ![[FWPathFilter filterWithString:@"src/app"] allowsFile:@"lib/src/app/x.m"],
          "a path is a prefix from the root");
    CHECK([[FWPathFilter filterWithString:@"*.{ts,tsx}"] allowsFile:@"a/b.tsx"] && ![[FWPathFilter filterWithString:@"*.{ts,tsx}"] allowsFile:@"a/b.js"],
          "{a,b} alternatives");
    CHECK([[FWPathFilter filterWithString:@"!**/gen/**"] prunesDirectory:@"x/gen"], "!dir/** prunes");
    CHECK([FWPathFilter filterWithString:@"  , "] == nil, "empty filter = nil");
    NSArray *rg = [[FWPathFilter filterWithString:@"*.ts, src/app, !node"] ripgrepArguments];
    CHECK([rg containsObject:@"!node"] && ![rg containsObject:@"*.ts"], "rg gets no includes when one can't be expressed: %s",
          [rg componentsJoinedByString:@" "].UTF8String);
}

static void nameSearch(void) {
    NSArray *paths = @[@"src/ImageViewer.m", @"src/ImageViewer.h", @"docs/viewer-notes.md", @"assets/logo.svg", @"assets/icons/svg-sprite.png",
                       @"tests/viewer/a.txt", @"Makefile", @"src/main.m", @"res/LOGO.SVG", @"deep/a/b/c/logo.svg"];
    NSUInteger total = 0;
    NSArray<FWNameMatch *> *r = FWNameSearch(@"logo.svg", paths, nil, 10, &total);
    CHECK(total == 3 && [r[0].rel isEqual:@"res/LOGO.SVG"] && [r[2].rel isEqual:@"deep/a/b/c/logo.svg"], "exact name, case-insensitive, shallow first: %s",
          [[r valueForKey:@"rel"] componentsJoinedByString:@","].UTF8String);
    r = FWNameSearch(@".svg", paths, nil, 10, &total);
    CHECK(total == 3 && NSEqualRanges(r[0].nameRange, NSMakeRange(4, 4)), "extension search: %lu, range %s", (unsigned long)total, NSStringFromRange(r[0].nameRange).UTF8String);
    r = FWNameSearch(@"*.svg", paths, nil, 10, &total);
    CHECK(total == 3, "glob search (%lu)", (unsigned long)total);
    r = FWNameSearch(@"viewer", paths, nil, 10, &total);
    CHECK(total == 4 && [r[0].rel hasPrefix:@"src/ImageViewer"] == NO && [r.lastObject.rel isEqual:@"tests/viewer/a.txt"],
          "name matches before folder-only matches: %s", [[r valueForKey:@"rel"] componentsJoinedByString:@","].UTF8String);
    r = FWNameSearch(@"imageviewer", paths, nil, 10, &total);
    CHECK(total == 2 && r[0].score == r[1].score, "name without extension (%lu)", (unsigned long)total);
    r = FWNameSearch(@"src .m", paths, nil, 10, &total);
    CHECK(total == 2, "every word must match (%lu)", (unsigned long)total);
    r = FWNameSearch(@"makefile", paths, nil, 10, &total);
    CHECK(total == 1 && r[0].score == 1000, "exact name scores highest");
    r = FWNameSearch(@"svg", paths, [FWPathFilter filterWithString:@"!deep"], 10, &total);
    CHECK(total == 3, "filter applies to name search (%lu)", (unsigned long)total);
    CHECK(FWQueryIsGlob(@"*.svg") && !FWQueryIsGlob(@".svg"), "glob detection");
}

static NSArray<SearchHit *> *runSearchWith(NSString *q, NSString *root, SearchOptions *o, BOOL rg) {
    WorkspaceSearch *ws = [WorkspaceSearch new];
    ws.disableRipgrep = !rg;
    NSMutableArray *hits = [NSMutableArray array];
    __block BOOL finished = NO;
    [ws search:q root:root options:o onBatch:^(NSArray *h, NSUInteger f) { [hits addObjectsFromArray:h]; } onDone:^(BOOL t) { finished = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    CHECK(finished, "search finished (rg=%d)", rg);
    return hits;
}

static void searchOptions(BOOL rg) {
    NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByResolvingSymlinksInPath];
    NSDictionary *files = @{@"a.ts": @"const id = 1;\nconst idx = 2;\nuser_id = 3;\n",
                            @"b.test.ts": @"const id = 4;\n",
                            @"lib/c.m": @"int id2 = getId(5);\n",
                            @"中文.md": @"名字：用户ID = 7 (id)\n"};
    for (NSString *rel in files) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [[files[rel] dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:NO];
    }
    SearchOptions *o = [SearchOptions new];
    o.wholeWord = YES;
    NSArray *hits = runSearchWith(@"id", root, o, rg);
    NSMutableSet *where = [NSMutableSet set];
    for (SearchHit *h in hits) [where addObject:[NSString stringWithFormat:@"%@:%lu", h.path.lastPathComponent, (unsigned long)h.line]];
    NSSet *wordHits = [NSSet setWithArray:@[@"a.ts:1", @"b.test.ts:1", @"中文.md:1"]];
    CHECK([where isEqualToSet:wordHits], "rg=%d whole word: %s", rg, where.description.UTF8String);

    o = [SearchOptions new];
    o.regex = YES;
    hits = runSearchWith(@"id\\d+|getId\\(", root, o, rg);
    SearchHit *c = hits.firstObject;
    CHECK(hits.count == 1 && c.column == 5 && c.matchBytes == 3 && c.previewMatches.count == 2, "rg=%d regex: col %lu len %lu, %lu highlights", rg,
          (unsigned long)c.column, (unsigned long)c.matchBytes, (unsigned long)c.previewMatches.count);

    o = [SearchOptions new];
    o.filter = [FWPathFilter filterWithString:@"*.ts, !*.test.ts"];
    hits = runSearchWith(@"const", root, o, rg);
    NSMutableSet *names = [NSMutableSet set];
    for (SearchHit *h in hits) [names addObject:h.path.lastPathComponent];
    CHECK([names isEqualToSet:[NSSet setWithObject:@"a.ts"]] && hits.count == 2, "rg=%d include / exclude filter: %s", rg, names.description.UTF8String);

    o = [SearchOptions new];
    hits = runSearchWith(@"用户id", root, o, rg);
    SearchHit *u = hits.firstObject;
    CHECK(hits.count == 1 && u.column == 10 && u.matchBytes == 8, "rg=%d non-ASCII ignore case: col %lu len %lu", rg, (unsigned long)u.column, (unsigned long)u.matchBytes);
    NSString *err = nil;
    o.regex = YES;
    CHECK(![o matcherFor:@"(unclosed" error:&err] && err.length, "bad regex reported");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}


static NSString *writeTree(NSDictionary<NSString *, NSString *> *files) {
    NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByResolvingSymlinksInPath];
    for (NSString *rel in files) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [[files[rel] dataUsingEncoding:NSUTF8StringEncoding] writeToFile:p atomically:NO];
    }
    return root;
}

static NSSet<NSString *> *relPaths(NSArray<SearchHit *> *hits, NSString *root) {
    NSMutableSet *out = [NSMutableSet set];
    for (SearchHit *h in hits) [out addObject:[h.path substringFromIndex:MIN(root.length + 1, h.path.length)]];
    return out;
}

static void searchSafety(BOOL rg) {
    NSString *pad = [@"" stringByPaddingToLength:5000 withString:@"x" startingAtIndex:0];
    NSString *root = writeTree(@{@".gitignore": @"gen/\nsecret.ts\n", @"src/a.ts": @"needle\n", @".hidden.ts": @"needle\n",
                                 @".cache/b.ts": @"needle\n", @"gen/c.ts": @"needle\n", @"src/secret.ts": @"needle\n",
                                 @"long.txt": [NSString stringWithFormat:@"%@needle tail\n", pad],
                                 @"evil.txt": [[@"" stringByPaddingToLength:28 withString:@"a" startingAtIndex:0] stringByAppendingString:@"!\n"]});
    NSTask *git = [NSTask new];
    git.executableURL = [NSURL fileURLWithPath:@"/usr/bin/git"];
    git.arguments = @[@"init", @"-q", root];
    [git launchAndReturnError:nil];
    [git waitUntilExit];

    // An include filter must not bring back hidden or ignored files.
    for (NSString *f in @[@".ts", @"*.ts", @"src"]) {
        SearchOptions *o = [SearchOptions new];
        o.filter = [FWPathFilter filterWithString:f];
        NSSet *got = relPaths(runSearchWith(@"needle", root, o, rg), root);
        NSSet *want = rg ? [NSSet setWithObject:@"src/a.ts"] : [NSSet setWithObjects:@"src/a.ts", @"src/secret.ts", @"gen/c.ts", nil];
        if ([f isEqualToString:@"src"]) want = rg ? [NSSet setWithObject:@"src/a.ts"] : [NSSet setWithObjects:@"src/a.ts", @"src/secret.ts", nil];
        CHECK([got isEqualToSet:want], "rg=%d filter %s skips hidden and ignored files: %s", rg, f.UTF8String, got.description.UTF8String);
    }

    // A match far into a long line: right column, and the preview shows it.
    for (NSNumber *regex in @[@NO, @YES]) {
        SearchOptions *o = [SearchOptions new];
        o.regex = regex.boolValue;
        NSArray<SearchHit *> *hits = runSearchWith(regex.boolValue ? @"nee+dle" : @"needle", root, o, rg);
        SearchHit *h = nil;
        for (SearchHit *x in hits) if ([x.path hasSuffix:@"long.txt"]) h = x;
        CHECK(h && h.column == 5001 && h.matchBytes == 6 && [h.preview containsString:@"needle"] && h.previewMatch.location != NSNotFound,
              "rg=%d regex=%d long line: col %lu, preview “%s”", rg, regex.boolValue, (unsigned long)h.column,
              [h.preview substringFromIndex:h.preview.length > 30 ? h.preview.length - 30 : 0].UTF8String);
    }

    // Lookbehind: rg's engine rejects it, so the built-in scanner runs instead of showing "no results".
    SearchOptions *o = [SearchOptions new];
    o.regex = YES;
    NSSet *got = relPaths(runSearchWith(@"(?<=x)needle", root, o, rg), root);
    CHECK([got isEqualToSet:[NSSet setWithObject:@"long.txt"]], "rg=%d lookbehind regex: %s", rg, got.description.UTF8String);

    // Catastrophic backtracking gives up on the line instead of hanging the search.
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    runSearchWith(@"(a+)+$", root, o, NO);
    CHECK(CFAbsoluteTimeGetCurrent() - t0 < 6, "a pathological regex finishes (%.1f s)", CFAbsoluteTimeGetCurrent() - t0);

    // A workspace opened through a symlink is searched.
    NSString *link = [root stringByAppendingString:@"-link"];
    symlink(root.fileSystemRepresentation, link.fileSystemRepresentation);
    NSUInteger n = 0;
    for (SearchHit *h in runSearchWith(@"needle", link, [SearchOptions new], rg)) if ([h.path hasSuffix:@"src/a.ts"]) n++;
    CHECK(n == 1, "rg=%d search through a symlinked workspace folder", rg);
    unlink(link.fileSystemRepresentation);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static NSData *U(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }

static void csvTables(void) {
    CSVTable *t = [CSVTable tableWithData:U(@"\xEF\xBB\xBFname,qty,note\r\nApple,3,\"red, sweet\"\r\n\"Big \"\"B\"\"\",12,\"two\nlines\"\r\n\r\nPear,,\n")
                                delimiter:0 hasHeader:-1 maxRows:0];
    CHECK(t.delimiter == ',' && t.hasHeader && t.rowCount == 3 && t.columnCount == 3, "csv shape: %c header %d rows %lu cols %lu",
          t.delimiter, t.hasHeader, (unsigned long)t.rowCount, (unsigned long)t.columnCount);
    CHECK([[t headerForColumn:0] isEqual:@"name"] && [[t cellAtRow:0 column:2] isEqual:@"red, sweet"], "quoted comma");
    CHECK([[t cellAtRow:1 column:0] isEqual:@"Big \"B\""] && [[t cellAtRow:1 column:2] isEqual:@"two\nlines"], "escaped quotes, line break in a field");
    CHECK([[t cellAtRow:2 column:1] isEqual:@""] && [[t cellAtRow:2 column:2] isEqual:@""], "empty and missing cells");
    CHECK([t sourceLineOfRow:0] == 2 && [t sourceLineOfRow:2] == 6, "source lines (%lu, %lu)", (unsigned long)[t sourceLineOfRow:0], (unsigned long)[t sourceLineOfRow:2]);

    CSVTable *semi = [CSVTable tableWithData:U(@"a;b;c\n1,5;2;3\n4;5,5;6\n") delimiter:0 hasHeader:-1 maxRows:0];
    CHECK(semi.delimiter == ';' && semi.columnCount == 3 && [[semi cellAtRow:0 column:0] isEqual:@"1,5"], "semicolon CSV (European decimals) detected");
    CSVTable *tsv = [CSVTable tableWithData:U(@"x\ty\n1\t2\n") delimiter:'\t' hasHeader:-1 maxRows:0];
    CHECK(tsv.columnCount == 2 && [[tsv cellAtRow:0 column:1] isEqual:@"2"], "TSV");
    CSVTable *nums = [CSVTable tableWithData:U(@"1,2\n3,4\n") delimiter:0 hasHeader:-1 maxRows:0];
    CHECK(!nums.hasHeader && nums.rowCount == 2 && [[nums headerForColumn:1] isEqual:@"B"], "a numeric first row is data; columns get letters");
    CSVTable *capped = [CSVTable tableWithData:U(@"h\n1\n2\n3\n4\n") delimiter:0 hasHeader:1 maxRows:3];
    CHECK(capped.truncated && capped.rowCount == 2, "row cap (%lu rows)", (unsigned long)capped.rowCount);
    CSVTable *ragged = [CSVTable tableWithData:U(@"a,b\n1\n1,2,3\n") delimiter:',' hasHeader:1 maxRows:0];
    CHECK(ragged.columnCount == 3 && [[ragged headerForColumn:2] isEqual:@"C"], "ragged rows widen the table");

    JSONLinesTable *jl = [JSONLinesTable tableWithData:U(@"{\"id\":1,\"name\":\"a\"}\n\nnot json\n{\"name\":\"b\",\"tags\":[1,2],\"id\":2}\n") maxRows:0];
    CHECK(jl.rowCount == 2 && jl.columnCount == 3 && jl.badLines == 1 && [[jl headerForColumn:2] isEqual:@"tags"] &&
          [[jl cellAtRow:1 column:2] isEqual:@"[1,2]"] && [jl sourceLineOfRow:1] == 4, "JSON Lines: key union in order, nested values as JSON");
}

static void jsonTrees(void) {
    NSString *err = nil;
    JSONNode *r = JSONParse(U(@"{\n  // comment\n  \"z\": 1,\n  \"a\": {\"emoji\": \"\\ud83d\\ude00\", \"list\": [true, null, -2.5e3,],},\n  unquoted: 'single',\n}"), &err);
    CHECK(r && !err && r.children.count == 3 && [r.children[0].key isEqual:@"z"] && [r.children[1].key isEqual:@"a"],
          "keys keep file order, comments / trailing commas / JSON5 keys accepted: %s", err.UTF8String);
    JSONNode *a = r.children[1];
    CHECK([a.children[0].text isEqual:@"😀"] && a.children[1].kind == JSONArray && a.children[1].children.count == 3, "surrogate pair escape");
    JSONNode *num = a.children[1].children[2];
    CHECK(num.kind == JSONNumber && [num.text isEqual:@"-2.5e3"] && [num.path isEqual:@"$.a.list[2]"] && a.line == 4, "number, path %s, line %lu",
          num.path.UTF8String, (unsigned long)a.line);
    CHECK([r.children[2].text isEqual:@"single"] && [[r.children[0] JSONStringPretty:NO] isEqual:@"1"], "single-quoted string");
    JSONNode *odd = JSONParse(U(@"{\"@types/node\": [\"x\\\"y\"]}"), NULL);
    CHECK([odd.children[0].children[0].path isEqual:@"$[\"@types/node\"][0]"] && [[odd JSONStringPretty:NO] isEqual:@"{\"@types/node\":[\"x\\\"y\"]}"],
          "quoted path segment and re-serialised JSON: %s", [odd JSONStringPretty:NO].UTF8String);
    CHECK(!JSONParse(U(@"{\n  \"a\": 1\n  \"b\": 2\n}"), &err) && [err hasPrefix:@"Line 3, column 3"], "error position: %s", err.UTF8String);
    CHECK(!JSONParse(U(@"[1, 2"), &err) && [err containsString:@"]"], "unterminated array: %s", err.UTF8String);
    CHECK(!JSONParse(U(@""), &err) && [err containsString:@"empty"], "empty file");
    NSMutableString *deep = [NSMutableString string];
    for (int i = 0; i < 600; i++) [deep appendString:@"["];
    CHECK(!JSONParse(U(deep), &err) && [err containsString:@"Nested"], "deep nesting refused, not a stack overflow");
    JSONNode *pl = JSONFromPropertyList(@{@"b": @YES, @"a": @[@1, [NSData dataWithBytes:"\x01\x02" length:2]], @"when": [NSDate dateWithTimeIntervalSince1970:0]});
    CHECK(pl.children.count == 3 && [pl.children[0].key isEqual:@"a"] && pl.children[1].kind == JSONBool && [pl.children[0].children[1].text hasPrefix:@"2 bytes  0102"] &&
          pl.children[2].kind == JSONDate, "property list: sorted keys, bool, data, date");
    CHECK(JSONNodeCount(r, 100) == 9, "node count (%lu)", (unsigned long)JSONNodeCount(r, 100));

    // A 200-byte binary plist whose arrays all refer to the previous one: 2^40 leaves if expanded.
    NSMutableData *bomb = [[@"bplist00" dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    NSMutableArray<NSNumber *> *offs = [NSMutableArray array];
    [offs addObject:@(bomb.length)]; [bomb appendBytes:"\x54leaf" length:5];
    for (uint8_t k = 1; k <= 40; k++) { [offs addObject:@(bomb.length)]; uint8_t a[3] = {0xA2, (uint8_t)(k - 1), (uint8_t)(k - 1)}; [bomb appendBytes:a length:3]; }
    uint64_t table = bomb.length;
    for (NSNumber *o in offs) { uint8_t b = o.unsignedCharValue; [bomb appendBytes:&b length:1]; }
    uint8_t trailer[32] = {0};
    trailer[6] = 1; trailer[7] = 1;
    uint64_t be[3] = {CFSwapInt64HostToBig(offs.count), CFSwapInt64HostToBig(offs.count - 1), CFSwapInt64HostToBig(table)};
    memcpy(trailer + 8, be, 24);
    [bomb appendBytes:trailer length:32];
    id bombObj = [NSPropertyListSerialization propertyListWithData:bomb options:NSPropertyListImmutable format:NULL error:nil];
    CFAbsoluteTime b0 = CFAbsoluteTimeGetCurrent();
    JSONNode *br = JSONFromPropertyList(bombObj);
    NSUInteger bn = JSONNodeCount(br, 10000000);
    CHECK(bombObj && bn <= 2000001 && CFAbsoluteTimeGetCurrent() - b0 < 3, "a plist that expands exponentially is cut off (%lu nodes, %.1f s)",
          (unsigned long)bn, CFAbsoluteTimeGetCurrent() - b0);
}

static void notebooks(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSDictionary *nb = @{@"metadata": @{@"kernelspec": @{@"display_name": @"Python 3", @"language": @"python"}},
        @"cells": @[@{@"cell_type": @"markdown", @"source": @[@"# Title\n", @"Some **text**"]},
                    @{@"cell_type": @"code", @"execution_count": @3, @"source": @"print(1)\nx = '```'",
                      @"outputs": @[@{@"output_type": @"stream", @"text": @[@"1\n"]},
                                    @{@"output_type": @"display_data", @"data": @{@"image/png": @"iVBORw0KGgo=", @"text/plain": @"<Figure>"}},
                                    @{@"output_type": @"error", @"ename": @"E", @"evalue": @"v", @"traceback": @[@"\x1b[31mTraceback\x1b[0m"]}]}]};
    NSUInteger cells = 0;
    NSString *md = NotebookToMarkdown([NSJSONSerialization dataWithJSONObject:nb options:0 error:nil], dir, &cells);
    CHECK(cells == 2 && [md containsString:@"# Title\nSome **text**"] && [md containsString:@"In [3]"], "markdown cell as is, prompt shown");
    CHECK([md containsString:@"````python\nprint(1)\nx = '```'\n````"], "code fence longer than the backticks inside: %s", md.UTF8String);
    CHECK([md containsString:@"```text\n1\n```"] && [md containsString:@"```text\nTraceback\n```"], "stream text and ANSI-free traceback");
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    CHECK(files.count == 1 && [md containsString:@"![]("] && ![md containsString:@"<Figure>"], "image output written and linked instead of its text");
    CHECK([NotebookToMarkdown(U(@"{\"x\":1}"), dir, NULL) containsString:@"Couldn’t read"], "not a notebook → explanation");
    // Wrong types anywhere (hand-edited or other tools) must not throw.
    NSString *odd = NotebookToMarkdown(U(@"{\"metadata\": {\"language_info\": \"python\", \"kernelspec\": [1]},"
        "\"cells\": [{\"cell_type\": 3, \"source\": \"x\"}, {\"cell_type\": \"markdown\", \"source\": \"y\", \"attachments\": {\"a.png\": \"zz\", \"b.png\": {\"7\": 1}}},"
        "{\"cell_type\": \"code\", \"source\": \"z\", \"outputs\": [{\"output_type\": \"error\", \"ename\": 5}, {\"output_type\": [], \"data\": []}]}]}"), dir, NULL);
    CHECK([odd containsString:@"```python\nz\n```"], "a notebook with odd metadata types still renders: %s", odd.UTF8String);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}


static void numberFormats(void) {
    struct { double v; const char *code, *want; } cases[] = {
        {1234.5, "General", "1234.5"}, {0.1 + 0.2, "General", "0.3"}, {123456789012, "General", "1.23457E+11"}, {1.0 / 3, "General", "0.333333333"},
        {1234.567, "0", "1235"}, {1234.567, "0.00", "1234.57"}, {1234.567, "#,##0", "1,235"}, {1234567.891, "#,##0.00", "1,234,567.89"},
        {0.5, "#.##", ".5"}, {12, "#.##", "12."}, {5, "000", "005"}, {-1234.5, "#,##0.00", "-1,234.50"},
        {0.1234, "0%", "12%"}, {0.1234, "0.0%", "12.3%"}, {12345.678, "0.00E+00", "1.23E+04"}, {0.000123, "0.00E+00", "1.23E-04"},
        {-1234.5, "\"$\"#,##0.00", "-$1,234.50"}, {-1234.5, "#,##0.00;[Red](#,##0.00)", "(1,234.50)"}, {0, "#,##0;-#,##0;\"-\"", "-"},
        {1500000, "#,##0,\"K\"", "1,500K"}, {1500000, "0.0,,\"M\"", "1.5M"}, {1234.5, "[$€-407]#,##0.00", "€1,234.50"},
        {1234.5, "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)", " 1,234.50 "},
        {46027, "yyyy-mm-dd", "2026-01-05"}, {46027, "d-mmm-yy", "5-Jan-26"}, {46027, "mmmm d, yyyy", "January 5, 2026"}, {46027, "dddd", "Monday"},
        {46027.75, "yyyy-mm-dd hh:mm", "2026-01-05 18:00"}, {0.75, "h:mm AM/PM", "6:00 PM"}, {1.5, "[h]:mm:ss", "36:00:00"},
        {46027, "yyyy\"年\"m\"月\"d\"日\"", "2026年1月5日"}, {60, "yyyy-mm-dd", "1900-02-29"}, {61, "yyyy-mm-dd", "1900-03-01"},
        {42, "[>100]\"big\";[<=100]\"small\"", "small"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        NSString *got = XLFormatNumber(cases[i].v, @(cases[i].code), NO, NULL);
        CHECK([got isEqualToString:@(cases[i].want)], "format %g with %s: want %s, got %s", cases[i].v, cases[i].code, cases[i].want, got.UTF8String);
    }
    CHECK(XLFormatIsDate(@"yyyy-mm-dd") && !XLFormatIsDate(@"0.00") && !XLFormatIsDate(@"\"day\"0") && XLFormatIsDate(@"[h]:mm"), "date formats recognised");
    CHECK(XLDateToSerial(2026, 1, 5, 0, NO) == 46027 && XLDateToSerial(2026, 1, 5, 0, YES) == 46027 - 1462, "date serials, both systems");
    uint32_t colour = 0; XLFormatNumber(-1, @"0;[Red]-0", NO, &colour);
    CHECK(colour == 0xFFFF0000, "[Red] section colour");
}

static void workbooks(void) {
    NSData *src = XLFixture();
    NSString *err = nil;
    XLWorkbook *wb = [[XLWorkbook alloc] initWithData:src error:&err];
    CHECK(wb && wb.sheets.count == 2, "fixture opens: %s", err.UTF8String);
    XLSheet *s = wb.sheets.firstObject;
    CHECK([s.name isEqual:@"Data 数据"] && s.frozenRows == 1 && s.frozenColumns == 0, "sheet name and frozen row");
    CHECK([[s displayAt:0 col:0 colour:NULL] isEqual:@"Name"] && [[s displayAt:1 col:0 colour:NULL] isEqual:@"Bold part"] &&
          [[s displayAt:2 col:0 colour:NULL] isEqual:@" a & b "], "shared strings, rich text joined, phonetic hint dropped, entities: %s", [s displayAt:1 col:0 colour:NULL].UTF8String);
    CHECK([[s displayAt:1 col:1 colour:NULL] isEqual:@"1,234.50"] && [[s displayAt:2 col:1 colour:NULL] isEqual:@"12.50%"] &&
          [[s displayAt:1 col:2 colour:NULL] isEqual:@"2026-01-05"] && [[s displayAt:3 col:0 colour:NULL] isEqual:@"TRUE"] &&
          [[s displayAt:3 col:1 colour:NULL] isEqual:@"#DIV/0!"], "number formats, booleans and errors as Excel shows them");
    XLStyle *head = [s styleAt:0 col:0];
    CHECK(head.bold && head.fillColor == 0xFF4472C4 && head.fontColor == 0xFFFFFFFF && head.hAlign == XLAlignCenter && head.left == XLLineThin &&
          head.bottom == XLLineMedium && head.leftColor == 0xFF999999, "fonts, fills, borders and alignment");
    CHECK([s widthOfColumn:0] > [s widthOfColumn:1] && [s widthOfColumn:3] == 0, "column widths, hidden column");
    CHECK([[s editTextAt:2 col:3] isEqual:@"=B3*2"] && [[s editTextAt:1 col:3] isEqual:@"=B2*2"], "a shared formula's child shows its shifted formula: %s", [s editTextAt:2 col:3].UTF8String);
    CHECK([s whyReadOnlyAt:1 col:3] && ![s whyReadOnlyAt:2 col:3] && [s whyReadOnlyAt:4 col:2] && [s whyReadOnlyAt:9 col:5] &&
          [s whyReadOnlyAt:6 col:1] && ![s whyReadOnlyAt:6 col:0] && ![s whyReadOnlyAt:10 col:5],
          "shared-formula master, array formula, table header and merged cells are read-only; their neighbours aren't");
    CHECK([XLShiftFormula(@"SUM($A$1:A2)+'My Sheet'!B3+\"A1\"+LOG10(C4)", 2, 1) isEqual:@"SUM($A$1:B4)+'My Sheet'!C5+\"A1\"+LOG10(D6)"], "formula references shift, anchored and quoted parts don't");

    CHECK([s setText:@"1,234.50" atRow:1 col:1 error:NULL] && !wb.hasEdits, "typing the same value again is no edit");
    NSString *e = nil;
    BOOL ok = [s setText:@"Renamed" atRow:0 col:0 error:&e] && [s setText:@"2026-03-01" atRow:1 col:2 error:&e] && [s setText:@"=SUM(B2:B3)" atRow:5 col:1 error:&e]
           && [s setText:@"'007" atRow:4 col:0 error:&e] && [s setText:@"new" atRow:3 col:3 error:&e] && [s setText:@"between" atRow:7 col:0 error:&e]
           && [s setText:@"" atRow:3 col:1 error:&e] && [wb.sheets[1] setText:@"into the prefixed sheet" atRow:2 col:1 error:&e];
    CHECK(ok && wb.hasEdits && wb.hasFormulaEdits, "edits accepted: %s", e.UTF8String);
    CHECK(![s setText:@"x" atRow:1 col:3 error:&e] && e.length, "a shared formula's master is refused: %s", e.UTF8String);
    NSData *out = [wb savedData:&e];
    CHECK(out != nil, "saved: %s", e.UTF8String);
    XLWorkbook *back = [[XLWorkbook alloc] initWithData:out error:&err];
    XLSheet *b = back.sheets.firstObject;
    CHECK([[b displayAt:0 col:0 colour:NULL] isEqual:@"Renamed"] && [b styleAt:0 col:0].bold, "replaced cell keeps its style");
    CHECK([[b displayAt:1 col:2 colour:NULL] isEqual:@"2026-03-01"] && [b typeAt:1 col:2] == XLNumber, "a date typed into a date cell is a date");
    CHECK([[b editTextAt:5 col:1] isEqual:@"=SUM(B2:B3)"] && [[b editTextAt:4 col:0] isEqual:@"'007"] && [b typeAt:4 col:0] == XLString, "formula and literal text");
    CHECK([[b displayAt:3 col:3 colour:NULL] isEqual:@"new"] && [[b displayAt:7 col:0 colour:NULL] isEqual:@"between"] && [b typeAt:3 col:1] == XLEmpty,
          "new cell inside a row, a new row, a cleared cell");
    CHECK([[back.sheets[1] displayAt:2 col:1 colour:NULL] isEqual:@"into the prefixed sheet"], "a self-closing <x:sheetData/> gains its first row");
    CHECK([[b editTextAt:2 col:3] isEqual:@"=B3*2"] && [[b displayAt:1 col:0 colour:NULL] isEqual:@"Bold part"], "untouched cells read back the same");
    ZipArchive *z0 = [[ZipArchive alloc] initWithData:src error:NULL], *z1 = [[ZipArchive alloc] initWithData:out error:NULL];
    NSMutableArray *changed = [NSMutableArray array];
    for (NSString *n in z0.entryNames) if (![[z0 dataForEntry:n] isEqual:[z1 dataForEntry:n]]) [changed addObject:n];
    NSArray *want = @[@"[Content_Types].xml", @"xl/_rels/workbook.xml.rels", @"xl/workbook.xml", @"xl/worksheets/sheet1.xml", @"xl/worksheets/sheet2.xml", @"xl/calcChain.xml"];
    CHECK([[NSSet setWithArray:changed] isEqualToSet:[NSSet setWithArray:want]], "only the edited sheets, the workbook and the calc chain parts change: %s",
          [changed componentsJoinedByString:@", "].UTF8String);
    CHECK(![z1 hasEntry:@"xl/calcChain.xml"] && ![[[NSString alloc] initWithData:[z1 dataForEntry:@"[Content_Types].xml"] encoding:NSUTF8StringEncoding] containsString:@"calcChain"] &&
          [[[NSString alloc] initWithData:[z1 dataForEntry:@"xl/workbook.xml"] encoding:NSUTF8StringEncoding] containsString:@"<calcPr fullCalcOnLoad=\"1\"/></workbook>"],
          "the calc chain is removed and the workbook asks to be recalculated");
    NSString *s1 = [[NSString alloc] initWithData:[z1 dataForEntry:@"xl/worksheets/sheet1.xml"] encoding:NSUTF8StringEncoding];
    CHECK([s1 containsString:@"<dimension ref=\"A1:D8\"/>"] && [s1 rangeOfString:@"r=\"D4\""].location > [s1 rangeOfString:@"r=\"C4\""].location &&
          [s1 rangeOfString:@"<row r=\"8\">"].location > [s1 rangeOfString:@"<row r=\"6\""].location, "dimension grows; new cells and rows go in order");
    CHECK([[[NSString alloc] initWithData:[z1 dataForEntry:@"xl/worksheets/sheet2.xml"] encoding:NSUTF8StringEncoding] containsString:@"<x:sheetData><x:row r=\"3\"><x:c r=\"B3\" t=\"inlineStr\">"],
          "new elements use the sheet's namespace prefix");
    CHECK([[[NSString alloc] initWithData:[z1 dataForEntry:@"docProps/untouched.bin"] encoding:NSUTF8StringEncoding] isEqual:@"keep these bytes exactly"], "other parts are kept");

    for (NSData *junk in @[[NSData data], [@"PK not a zip" dataUsingEncoding:NSUTF8StringEncoding], [src subdataWithRange:NSMakeRange(0, src.length / 2)]])
        CHECK(![[XLWorkbook alloc] initWithData:junk error:&err] && err.length, "a damaged file is refused, not a crash");
}

static void hiddenLists(void) {
    NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByResolvingSymlinksInPath];
    for (NSString *rel in @[@".git/config", @".env", @"a/.DS_Store", @"a/x.pyc", @"a/x.py", @"node_modules/m/i.js", @"vendor/v.js"]) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [@"x" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
    NSArray *oldHidden = FWAlwaysHidden(), *oldSkip = FWSkippedDirs().allObjects;
    NSSet *withHidden = walked(root, YES);
    CHECK([withHidden containsObject:@".env"] && ![withHidden containsObject:@".git/config"] && ![withHidden containsObject:@"a/.DS_Store"] &&
          ![withHidden containsObject:@"node_modules/m/i.js"], "defaults: dot files shown, .git / .DS_Store never, node_modules skipped");
    FWSetAlwaysHidden(@[@"*.pyc", @".env"]);
    FWSetSearchSkipped(@[@"vendor"]);
    NSSet *custom = walked(root, YES);
    CHECK(![custom containsObject:@"a/x.pyc"] && ![custom containsObject:@".env"] && [custom containsObject:@"a/x.py"] &&
          [custom containsObject:@".git/config"] && [custom containsObject:@"node_modules/m/i.js"] && ![custom containsObject:@"vendor/v.js"],
          "configured lists apply (globs too): %s", custom.description.UTF8String);
    CHECK(FWIsAlwaysHidden(@"X.PYC") && !FWIsAlwaysHidden(@"x.py"), "case-insensitive glob");
    FWSetAlwaysHidden(oldHidden);
    FWSetSearchSkipped(oldSkip);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

// Installing FeatherView must not change which app opens anything: with rank Alternate macOS started
// preferring it over VS Code (which declares no rank). Only an explicit user choice may do that.
static void docTypesNeverTakeOver(void) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:@"Info.plist"];
    NSArray *types = info[@"CFBundleDocumentTypes"];
    CHECK(types.count >= 3, "Info.plist declares document types");
    for (NSDictionary *t in types)
        CHECK([t[@"LSHandlerRank"] isEqual:@"None"], "%s: LSHandlerRank is %s, must be None", [t[@"CFBundleTypeName"] UTF8String],
              [t[@"LSHandlerRank"] ?: @"(missing)" UTF8String]);
}

int main(void) {
    @autoreleasepool {
        docTypesNeverTakeOver();
        fuzz(); search(); crlf(); utf8(); guessKindByContent(); fuzzy();
        NSString *root = makeTree();
        walker(root);
        workspaceSearch(root, NO);
        pathFilter();
        nameSearch();
        searchOptions(NO);
        csvTables();
        jsonTrees();
        notebooks();
        numberFormats();
        workbooks();
        hiddenLists();
        searchSafety(NO);
        if ([WorkspaceSearch ripgrepPath]) searchOptions(YES);
        if ([WorkspaceSearch ripgrepPath]) searchSafety(YES);
        if ([WorkspaceSearch ripgrepPath]) workspaceSearch(root, YES);
        else printf("(ripgrep not installed; rg path not tested)\n");
        fileOps(root);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("all tests passed\n");
    return 0;
}

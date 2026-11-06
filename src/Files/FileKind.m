#import "FileKind.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const NSUInteger kCopyThreshold = 1 << 20;     // below this, read() instead of mmap
static const NSUInteger kMaxTextSize = 1u << 30;      // line index uses uint32 offsets

static BOOL conformsAny(UTType *t, NSArray<NSString *> *ids) {
    for (NSString *i in ids) {
        UTType *o = [UTType typeWithIdentifier:i];
        if (o && [t conformsToType:o]) return YES;
    }
    return NO;
}

// Media containers and office files always have NUL bytes near the start; text never does.
static BOOL headLooksLikeText(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    uint8_t buf[4096];
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    if (n < 0) return NO;
    if (n >= 2 && ((buf[0] == 0xFF && buf[1] == 0xFE) || (buf[0] == 0xFE && buf[1] == 0xFF))) return YES;   // UTF-16
    return memchr(buf, 0, (size_t)n) == NULL;
}

static BOOL headerIs(NSString *path, const char *magic) {
    size_t n = strlen(magic);
    char buf[32] = {0};
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    ssize_t got = read(fd, buf, MIN(n, sizeof buf));
    close(fd);
    return got == (ssize_t)n && memcmp(buf, magic, n) == 0;
}

static NSSet *archiveExts(void) {
    static NSSet *s;
    if (!s) s = [NSSet setWithArray:@[@"zip", @"jar", @"war", @"ear", @"aar", @"apk", @"ipa", @"xpi", @"crx", @"vsix", @"whl", @"nupkg",
                                      @"tar", @"tgz", @"tbz", @"tbz2", @"txz", @"tzst", @"7z", @"rar", @"cpio", @"xar", @"pkg", @"deb", @"rpm", @"iso", @"lha", @"cab"]];
    return s;
}

ViewerKind FKGuessKind(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *name = path.lastPathComponent.lowercaseString;
    if ([name hasSuffix:@".tar.gz"] || [name hasSuffix:@".tar.bz2"] || [name hasSuffix:@".tar.xz"] || [name hasSuffix:@".tar.zst"] || [archiveExts() containsObject:ext])
        return ViewerArchive;
    if ([@[@"sqlite", @"sqlite3", @"db", @"db3", @"sqlitedb"] containsObject:ext] && headerIs(path, "SQLite format 3")) return ViewerSQLite;
    if ([@[@"plist", @"strings", @"stringsdict", @"entitlements", @"xcprivacy", @"mobileconfig", @"webloc", @"savedstate", @"nib"] containsObject:ext] &&
        headerIs(path, "bplist00")) return ViewerTree;
    if (!ext.length) return headerIs(path, "SQLite format 3") ? ViewerSQLite : ViewerText;
    UTType *t = [UTType typeWithFilenameExtension:ext];
    if (!t) return ViewerText;
    if ([t conformsToType:UTTypeImage]) return ViewerImage;          // SVG included: the image view renders it
    if ([t conformsToType:UTTypePDF]) return ViewerPDF;
    // macOS maps .ts (TypeScript) to MPEG-2 video and .key (private key) to Keynote: look at the bytes
    if (conformsAny(t, @[@"public.audiovisual-content", @"public.presentation"]) && headLooksLikeText(path))
        return ViewerText;
    if (conformsAny(t, @[@"com.adobe.pdf", @"public.audiovisual-content", @"public.presentation",
                         @"public.spreadsheet", @"public.rtf", @"com.apple.rtfd", @"public.font",
                         @"org.idpf.epub-container", @"public.3d-content",
                         @"org.openxmlformats.wordprocessingml.document", @"com.microsoft.word.doc",
                         @"com.apple.iwork.pages.sffpages", @"com.apple.iwork.numbers.sffnumbers",
                         @"com.apple.iwork.keynote.sffkey"]))
        return ViewerQuickLook;
    return ViewerText;
}

MarkupKind FKMarkupKind(NSString *path) {
    NSString *e = path.pathExtension.lowercaseString;
    if ([@[@"md", @"markdown", @"mdown", @"mkd", @"mkdn", @"mdx"] containsObject:e]) return MarkupMarkdown;
    if ([@[@"html", @"htm", @"xhtml"] containsObject:e]) return MarkupHTML;
    if ([@[@"csv", @"tsv", @"tab", @"psv", @"jsonl", @"ndjson", @"jsonlines"] containsObject:e]) return MarkupTable;
    if ([e isEqualToString:@"ipynb"]) return MarkupNotebook;
    if ([@[@"json", @"jsonc", @"json5", @"geojson", @"topojson", @"har", @"webmanifest", @"babelrc", @"eslintrc", @"code-workspace", @"avsc"] containsObject:e])
        return MarkupJSON;
    if ([@[@"plist", @"entitlements", @"xcprivacy", @"mobileconfig", @"stringsdict"] containsObject:e]) return MarkupPlist;
    return MarkupNone;
}

BOOL FKIsValidUTF8(const uint8_t *p, NSUInteger n) {
    NSUInteger i = 0;
    while (i < n) {
        // fast path for ASCII runs
        while (i + 8 <= n) {
            uint64_t v; memcpy(&v, p + i, 8);
            if (v & 0x8080808080808080ULL) break;
            i += 8;
        }
        if (i >= n) break;
        uint8_t c = p[i];
        if (c < 0x80) { i++; continue; }
        NSUInteger need; uint32_t cp;
        if ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
        else return NO;
        if (i + need >= n) return NO;
        for (NSUInteger k = 1; k <= need; k++) {
            if ((p[i+k] & 0xC0) != 0x80) return NO;
            cp = (cp << 6) | (p[i+k] & 0x3F);
        }
        if ((need == 1 && cp < 0x80) || (need == 2 && cp < 0x800) || (need == 3 && cp < 0x10000) ||
            cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return NO;
        i += need + 1;
    }
    return YES;
}

static NSData *readFile(NSString *path, NSString **error, BOOL forceMap) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) { if (error) *error = @"无法读取文件"; return nil; }
    NSDataReadingOptions opt = (forceMap || (NSUInteger)st.st_size >= kCopyThreshold) ? NSDataReadingMappedAlways : 0;
    NSError *e = nil;
    NSData *d = st.st_size == 0 ? [NSData data] : [NSData dataWithContentsOfFile:path options:opt error:&e];
    if (!d && error) *error = e.localizedDescription ?: @"无法读取文件";
    return d;
}

NSData *FKLoadRaw(NSString *path, NSString **error) { return readFile(path, error, YES); }

NSData *FKLoadText(NSString *path, NSStringEncoding *enc, NSString **error) {
    NSData *d = readFile(path, error, NO);
    if (!d) return nil;
    if (d.length > kMaxTextSize) { if (error) *error = @"文件过大，改用十六进制查看"; return nil; }
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length;

    if (n >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF16StringEncoding];
        if (s) { *enc = NSUTF16StringEncoding; return [s dataUsingEncoding:NSUTF8StringEncoding]; }
    }
    if (memchr(b, 0, MIN(n, (NSUInteger)8192))) { if (error) *error = @"二进制文件"; return nil; }
    if (FKIsValidUTF8(b, n)) { *enc = NSUTF8StringEncoding; return d; }
    if (n < (64u << 20)) {
        NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        NSString *s = [[NSString alloc] initWithData:d encoding:gb];
        if (s) { *enc = gb; return [s dataUsingEncoding:NSUTF8StringEncoding]; }
    }
    if (error) *error = @"无法识别的编码";
    return nil;
}

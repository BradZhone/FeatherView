#import "FileIcons.h"
#import "Localization.h"

typedef NS_ENUM(NSInteger, FTFileFamily) { FamDir, FamImage, FamPDF, FamMedia, FamArchive, FamDoc, FamData, FamWeb, FamShell, FamCode, FamTable, FamDB, FamNotebook, FamOther };

static FTFileFamily family(NSString *name, BOOL isDir) {
    if (isDir) return FamDir;
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^put)(NSString *, FTFileFamily) = ^(NSString *exts, FTFileFamily f) { for (NSString *e in [exts componentsSeparatedByString:@" "]) m[e] = @(f); };
        put(@"png jpg jpeg gif heic heif webp tiff tif bmp svg svgz ico icns avif psd", FamImage);
        put(@"pdf", FamPDF);
        put(@"mp4 mov m4v avi mkv webm mp3 m4a wav aiff flac ogg", FamMedia);
        put(@"zip gz tgz tar 7z rar dmg xz bz2 jar war apk ipa whl deb rpm iso xar cpio", FamArchive);
        put(@"csv tsv tab psv jsonl ndjson xlsx xls numbers", FamTable);
        put(@"sqlite sqlite3 db db3", FamDB);
        put(@"ipynb", FamNotebook);
        put(@"md markdown mdx txt rtf doc docx pages log rst adoc tex", FamDoc);
        put(@"json jsonc json5 geojson har yaml yml toml ini conf cfg env xml plist lock properties sql", FamData);
        put(@"html htm xhtml css scss sass less vue svelte astro", FamWeb);
        put(@"sh bash zsh fish command ps1 bat", FamShell);
        put(@"c h m mm cc cpp hpp swift py rb go rs js mjs cjs jsx ts mts cts tsx java kt kts scala cs php lua pl dart zig proto r jl ex exs hs", FamCode);
        map = m;
    });
    NSNumber *f = map[name.pathExtension.lowercaseString];
    if (f) return f.integerValue;
    NSString *l = name.lowercaseString;
    if ([l isEqualToString:@"makefile"] || [l hasPrefix:@"dockerfile"]) return FamShell;
    if ([l hasPrefix:@".git"] || [l hasPrefix:@".env"] || [l hasSuffix:@"rc"]) return FamData;
    return FamOther;
}

NSString *FTFileSymbol(NSString *name, BOOL isDir) {
    switch (family(name, isDir)) {
        case FamDir:     return @"folder";
        case FamImage:   return @"photo";
        case FamPDF:     return @"doc.richtext";
        case FamMedia:   return @"play.rectangle";
        case FamArchive: return @"archivebox";
        case FamDoc:     return @"doc.text";
        case FamData:    return @"curlybraces";
        case FamWeb:     return @"globe";
        case FamShell:   return @"terminal";
        case FamCode:    return @"chevron.left.forwardslash.chevron.right";
        case FamTable:   return @"tablecells";
        case FamDB:      return @"cylinder.split.1x2";
        case FamNotebook: return @"book.pages";
        case FamOther:   return @"doc";
    }
    return @"doc";
}

NSColor *FTFileTint(NSString *name, BOOL isDir) {
    switch (family(name, isDir)) {
        case FamDir:     return NSColor.controlAccentColor;
        case FamImage:   return NSColor.systemPurpleColor;
        case FamPDF:     return NSColor.systemOrangeColor;
        case FamMedia:   return NSColor.systemIndigoColor;
        case FamArchive: return NSColor.systemBrownColor;
        case FamDoc:     return NSColor.systemBlueColor;
        case FamData:    return NSColor.systemYellowColor;
        case FamWeb:     return NSColor.systemTealColor;
        case FamShell:   return NSColor.systemGreenColor;
        case FamCode:    return NSColor.systemCyanColor;
        case FamTable:   return NSColor.systemGreenColor;
        case FamDB:      return NSColor.systemOrangeColor;
        case FamNotebook: return NSColor.systemOrangeColor;
        case FamOther:   return NSColor.secondaryLabelColor;
    }
    return NSColor.secondaryLabelColor;
}

NSImage *FTFileIcon(NSString *name, BOOL isDir) {
    return [NSImage imageWithSystemSymbolName:FTFileSymbol(name, isDir) accessibilityDescription:isDir ? FTL(@"Folder") : FTL(@"File")];
}

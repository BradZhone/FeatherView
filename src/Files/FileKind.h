#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ViewerKind) {
    ViewerAuto = 0,
    ViewerText,
    ViewerHex,
    ViewerImage,
    ViewerQuickLook,
    ViewerPDF,
    ViewerTree,          // binary property list
    ViewerSQLite,
    ViewerArchive,
    ViewerSpreadsheet,   // .xlsx: own grid, editable
    ViewerTerminal,      // an interactive shell (never guessed, created by the user)
    ViewerDocument,      // .docx: rendered pages, read-only
};

// Guess from extension / UTType; reads the first 4 KB only when the extension is ambiguous
// (.ts is also MPEG-2 video, .key also Keynote). Returns ViewerText when unsure.
ViewerKind FKGuessKind(NSString *path);

// Reads the file for text editing. Small files are copied into memory, large ones mmap'd.
// Returns nil if it looks binary or can't be decoded. On success *encoding is
// NSUTF8StringEncoding or the original encoding (GB18030 / UTF-16), in which case
// the returned data has already been converted to UTF-8.
NSData *FKLoadText(NSString *path, NSStringEncoding *encoding, NSString **error);
// allowNUL: the user asked for text (View as Text, a draft), so NUL bytes in UTF-8 are kept instead of meaning "binary".
NSData *FKLoadTextAllowingNUL(NSString *path, NSStringEncoding *encoding, BOOL allowNUL, NSString **error);
NSString *FKEncodingName(NSStringEncoding encoding);         // short label for the status bar: UTF-8, Shift_JIS, …
BOOL FKIsMappedSize(unsigned long long size);                // files this big are mmap'd rather than read

// Raw bytes (mmap'd) for the hex viewer.
NSData *FKLoadRaw(NSString *path, NSString **error);

BOOL FKIsValidUTF8(const uint8_t *p, NSUInteger n);

// Text files with a rendered view next to the source. Table: CSV / TSV / JSON Lines. JSON, Plist: tree. Notebook: .ipynb.
typedef NS_ENUM(NSInteger, MarkupKind) { MarkupNone = 0, MarkupMarkdown, MarkupHTML, MarkupTable, MarkupJSON, MarkupPlist, MarkupNotebook };
typedef NS_ENUM(NSInteger, MarkupLayout) { MarkupSource = 0, MarkupSplit, MarkupPreview };
MarkupKind FKMarkupKind(NSString *path);

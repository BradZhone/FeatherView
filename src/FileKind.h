#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ViewerKind) {
    ViewerAuto = 0,
    ViewerText,
    ViewerHex,
    ViewerImage,
    ViewerQuickLook,
    ViewerPDF,
};

// Guess from extension / UTType only (no file IO). Returns ViewerText when unsure.
ViewerKind FKGuessKind(NSString *path);

// Reads the file for text editing. Small files are copied into memory, large ones mmap'd.
// Returns nil if it looks binary or can't be decoded. On success *encoding is
// NSUTF8StringEncoding or the original encoding (GB18030 / UTF-16), in which case
// the returned data has already been converted to UTF-8.
NSData *FKLoadText(NSString *path, NSStringEncoding *encoding, NSString **error);

// Raw bytes (mmap'd) for the hex viewer.
NSData *FKLoadRaw(NSString *path, NSString **error);

BOOL FKIsValidUTF8(const uint8_t *p, NSUInteger n);

typedef NS_ENUM(NSInteger, MarkupKind) { MarkupNone = 0, MarkupMarkdown, MarkupHTML };
typedef NS_ENUM(NSInteger, MarkupLayout) { MarkupSource = 0, MarkupSplit, MarkupPreview };
MarkupKind FKMarkupKind(NSString *path);

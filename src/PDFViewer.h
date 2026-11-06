#import <Cocoa/Cocoa.h>
#import "Zoomable.h"
@class PDFView;

// PDF viewer (PDFKit): zoom, fit width / whole page, page navigation, find, thumbnails, two-page,
// per-page rotation (view only), text selection and copy, password-protected files.
@interface PDFPreview : NSView <FTZoomable>
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path;   // nil if the file is not a readable PDF
@property (nonatomic, readonly) BOOL isLocked;
- (BOOL)unlock:(NSString *)password;
@property (nonatomic, readonly) NSUInteger pageCount;
@property (nonatomic, readonly) NSUInteger currentPage;              // 0-based
- (void)goToPage:(NSUInteger)index;
- (void)nextPage;
- (void)previousPage;
- (void)ftZoomToFitPage;
- (BOOL)find:(NSString *)text backward:(BOOL)backward;             // wraps; selects and scrolls to the match
@property (nonatomic) BOOL showsThumbnails, twoPages;
@property (nonatomic, readonly) NSString *info;                      // "第 3 / 12 页   125%"
@property (nonatomic, readonly) PDFView *pdfView;
@property (nonatomic, copy) void (^onChange)(void);
@end

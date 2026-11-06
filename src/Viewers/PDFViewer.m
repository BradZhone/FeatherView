#import "PDFViewer.h"
#import "Localization.h"
#import "CanvasView.h"
#import <PDFKit/PDFKit.h>

static const CGFloat kThumbW = 132;

@implementation PDFPreview {
    PDFView *_pdf;
    PDFThumbnailView *_thumbs;
    NSStackView *_tools;
    NSTextField *_pageLabel, *_percent;
    NSString *_path;
}

- (instancetype)initWithFrame:(NSRect)f path:(NSString *)path {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
    if (!doc) return nil;
    if (!(self = [super initWithFrame:f])) return nil;
    _path = [path copy];
    FTClipToBounds(self);
    _pdf = [[PDFView alloc] initWithFrame:self.bounds];
    _pdf.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pdf.displayMode = kPDFDisplaySinglePageContinuous;
    _pdf.displaysPageBreaks = YES;
    _pdf.autoScales = YES;
    _pdf.backgroundColor = NSColor.windowBackgroundColor;
    _pdf.document = doc;
    [self addSubview:_pdf];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(pdfChanged:) name:PDFViewPageChangedNotification object:_pdf];
    [nc addObserver:self selector:@selector(pdfChanged:) name:PDFViewScaleChangedNotification object:_pdf];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    _thumbs.PDFView = nil;
    _pdf.document = nil;                 // drops PDFKit's page caches
}

- (PDFView *)pdfView { return _pdf; }
- (NSView *)focusView { return _pdf; }
- (BOOL)isLocked { return _pdf.document.isLocked; }

- (BOOL)unlock:(NSString *)password {
    BOOL ok = [_pdf.document unlockWithPassword:password ?: @""];
    if (ok) { PDFDocument *d = _pdf.document; _pdf.document = nil; _pdf.document = d; [self notify]; }   // re-layout pages
    return ok;
}

- (NSUInteger)pageCount { return _pdf.document.pageCount; }
- (NSUInteger)currentPage {
    PDFPage *p = _pdf.currentPage;
    return p ? [_pdf.document indexForPage:p] : 0;
}

- (void)goToPage:(NSUInteger)i {
    if (!self.pageCount) return;
    PDFPage *p = [_pdf.document pageAtIndex:MIN(i, self.pageCount - 1)];
    if (p) [_pdf goToPage:p];
    [self notify];
}
- (void)nextPage { if (_pdf.canGoToNextPage) [_pdf goToNextPage:nil]; }
- (void)previousPage { if (_pdf.canGoToPreviousPage) [_pdf goToPreviousPage:nil]; }

#pragma mark Zoom

- (CGFloat)zoomPercent { return round(_pdf.scaleFactor * 100); }
- (void)ftZoomIn { _pdf.autoScales = NO; [_pdf zoomIn:nil]; }
- (void)ftZoomOut { _pdf.autoScales = NO; [_pdf zoomOut:nil]; }
- (void)ftZoomToFit { _pdf.autoScales = YES; [self notify]; }               // fit width
- (void)ftZoomActualSize { _pdf.autoScales = NO; _pdf.scaleFactor = 1; }
- (void)ftZoomToFitPage {
    PDFPage *p = _pdf.currentPage ?: [_pdf.document pageAtIndex:0];
    if (!p) return;
    NSRect pb = [p boundsForBox:_pdf.displayBox];
    if (p.rotation % 180) pb.size = NSMakeSize(pb.size.height, pb.size.width);
    NSSize v = _pdf.bounds.size;
    CGFloat pages = _pdf.displayMode == kPDFDisplayTwoUp || _pdf.displayMode == kPDFDisplayTwoUpContinuous ? 2 : 1;
    CGFloat k = MIN((v.width - 24) / (pb.size.width * pages), (v.height - 24) / pb.size.height);
    _pdf.autoScales = NO;
    _pdf.scaleFactor = MAX(0.05, k);
    [_pdf goToPage:p];
}

- (void)ftRotate:(NSInteger)q {
    PDFPage *p = _pdf.currentPage;
    if (!p) return;
    p.rotation = ((p.rotation + (int)q * 90) % 360 + 360) % 360;   // in memory only; the file is not saved
    [_pdf layoutDocumentView];
    [self notify];
}

#pragma mark Find

- (BOOL)find:(NSString *)text backward:(BOOL)back {
    if (!text.length) return NO;
    NSStringCompareOptions o = NSCaseInsensitiveSearch | (back ? NSBackwardsSearch : 0);
    PDFSelection *s = [_pdf.document findString:text fromSelection:_pdf.currentSelection withOptions:o];
    if (!s) s = [_pdf.document findString:text fromSelection:nil withOptions:o];      // wrap around
    if (!s) { NSBeep(); return NO; }
    [_pdf setCurrentSelection:s animate:NO];
    [_pdf scrollSelectionToVisible:nil];
    [self notify];
    return YES;
}

#pragma mark Layout options

- (void)setShowsThumbnails:(BOOL)v {
    _showsThumbnails = v;
    if (v && !_thumbs) {
        _thumbs = [[PDFThumbnailView alloc] initWithFrame:NSMakeRect(0, 0, kThumbW, self.bounds.size.height)];
        _thumbs.thumbnailSize = NSMakeSize(kThumbW - 32, kThumbW * 1.3);
        _thumbs.backgroundColor = NSColor.windowBackgroundColor;
        _thumbs.PDFView = _pdf;
        [self addSubview:_thumbs];
    } else if (!v && _thumbs) {
        _thumbs.PDFView = nil;
        [_thumbs removeFromSuperview];
        _thumbs = nil;                  // thumbnails are rendered images; don't keep them around
    }
    [self resizeSubviewsWithOldSize:self.bounds.size];
}

- (void)setTwoPages:(BOOL)v {
    _twoPages = v;
    _pdf.displayMode = v ? kPDFDisplayTwoUpContinuous : kPDFDisplaySinglePageContinuous;
    _pdf.displaysAsBook = v;
    [self notify];
}

- (void)resizeSubviewsWithOldSize:(NSSize)old {
    NSRect b = self.bounds;
    CGFloat tw = _thumbs ? kThumbW : 0;
    _thumbs.frame = NSMakeRect(0, 0, tw, b.size.height);
    _pdf.frame = NSMakeRect(tw, 0, b.size.width - tw, b.size.height);
}

#pragma mark Status

- (void)pdfChanged:(NSNotification *)n { [self notify]; }

- (NSString *)info {
    NSString *mode = _pdf.autoScales ? FTL(@"Fit width ") : @"";
    return [NSString stringWithFormat:FTL(@"Page %lu of %lu   %@%.0f%%%@"), (unsigned long)self.currentPage + 1, (unsigned long)self.pageCount,
            mode, self.zoomPercent, _pdf.document.isEncrypted ? FTL(@"   Encrypted") : @""];
}

- (void)notify {
    _pageLabel.stringValue = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)self.currentPage + 1, (unsigned long)self.pageCount];
    _percent.stringValue = [NSString stringWithFormat:@"%.0f%%", self.zoomPercent];
    if (self.onChange) self.onChange();
}

- (NSView *)toolsView {
    if (_tools) return _tools;
    _pageLabel = FTToolLabel(58);
    _percent = FTToolLabel(44);
    _tools = FTToolStrip(@[FTToolButton(@"chevron.up", FTL(@"Previous Page"), self, @selector(previousPage)),
                           _pageLabel,
                           FTToolButton(@"chevron.down", FTL(@"Next Page"), self, @selector(nextPage)),
                           FTToolButton(@"minus.magnifyingglass", FTL(@"Zoom Out (⌘-)"), self, @selector(ftZoomOut)),
                           _percent,
                           FTToolButton(@"plus.magnifyingglass", FTL(@"Zoom In (⌘+)"), self, @selector(ftZoomIn)),
                           FTToolButton(@"arrow.left.and.right", FTL(@"Fit Width (⌘0)"), self, @selector(ftZoomToFit)),
                           FTToolButton(@"arrow.up.and.down.and.arrow.left.and.right", FTL(@"Fit Page"), self, @selector(ftZoomToFitPage)),
                           FTToolButton(@"rotate.right", FTL(@"Rotate Page"), self, @selector(rotatePage:)),
                           FTToolButton(@"sidebar.left", FTL(@"Thumbnails (⌥⌘T)"), self, @selector(toggleThumbs:))]);
    [self notify];
    return _tools;
}

- (void)rotatePage:(id)s { [self ftRotate:1]; }
- (void)toggleThumbs:(id)s { self.showsThumbnails = !self.showsThumbnails; }

@end

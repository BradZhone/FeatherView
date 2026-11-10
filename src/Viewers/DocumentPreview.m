#import "OfficeViews.h"
#import "Viewers.h"
#import "Localization.h"
#import "CanvasView.h"
#import <WebKit/WebKit.h>

static NSString *const kRenderPrefix = @"feather-office-";
static const CGFloat kBarH = 30;

// Pages on grey, like a word processor. The converter's own CSS sizes the page box; this only frames it.
static NSString *const kPageCSS =
    @"<style>html{background:#e8e8ea!important;}body{margin:0!important;padding:24px 0 40px!important;background:transparent!important;}"
     "body>div{background:#fff!important;color:#000;margin:0 auto 24px!important;box-shadow:0 1px 4px rgba(0,0,0,.25);}"
     "@media (prefers-color-scheme:dark){html{background:#2b2b2d!important;}body>div{box-shadow:0 1px 6px rgba(0,0,0,.6);}}"
     "a{cursor:pointer;}</style>";

@interface DocumentPreview () <WKNavigationDelegate>
@end

@implementation DocumentPreview {
    NSString *_path, *_dir, *_error;
    WKWebView *_web;
    NSView *_bar, *_fallback, *_spinnerHost;
    NSTextField *_label;
    NSButton *_openIn;
    NSProgressIndicator *_spinner;
}

+ (void)removeStaleRenderings {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = NSTemporaryDirectory();
    for (NSString *n in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
        if (![n hasPrefix:kRenderPrefix] && ![n hasPrefix:@"feather-sqlite-"]) continue;
        NSString *p = [tmp stringByAppendingPathComponent:n];
        NSDate *m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
        if (m && -m.timeIntervalSinceNow > 3600) [fm removeItemAtPath:p error:nil];
    }
}

- (instancetype)initWithFrame:(NSRect)f path:(NSString *)path {
    if (!(self = [super initWithFrame:f])) return nil;
    FTClipToBounds(self);
    _path = [path copy];
    _bar = [[NSView alloc] initWithFrame:NSZeroRect];
    _label = [NSTextField labelWithString:FTL(@"Read-only preview")];
    _label.font = [NSFont systemFontOfSize:11.5];
    _label.textColor = NSColor.secondaryLabelColor;
    [_bar addSubview:_label];
    _openIn = FTOpenInAppButton(path, self, @selector(openInApp:));
    if (_openIn) [_bar addSubview:_openIn];
    [self addSubview:_bar];
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    [self addSubview:_spinner];
    [_spinner startAnimation:nil];
    [self render];
    [self layoutParts];
    return self;
}

- (void)dealloc { if (_dir) [NSFileManager.defaultManager removeItemAtPath:_dir error:nil]; if (_fallback) FKCloseQuickLookView(_fallback); }

- (BOOL)isFlipped { return YES; }
- (void)resizeSubviewsWithOldSize:(NSSize)o { [self layoutParts]; }

- (void)layoutParts {
    NSRect b = self.bounds;
    _bar.frame = NSMakeRect(0, 0, b.size.width, kBarH);
    CGFloat ow = _openIn ? ceil(_openIn.fittingSize.width) + 4 : 0;
    if (_openIn) _openIn.frame = NSMakeRect(b.size.width - 8 - ow, 4, ow, 22);
    [_label sizeToFit];
    _label.frame = NSMakeRect(10, (kBarH - _label.frame.size.height) / 2, MAX(0, b.size.width - 30 - ow), _label.frame.size.height);
    NSRect body = NSMakeRect(0, kBarH, b.size.width, MAX(0, b.size.height - kBarH));
    _web.frame = body; _fallback.frame = body;
    _spinner.frame = NSMakeRect(NSMidX(body) - 8, NSMidY(body) - 8, 16, 16);
}

- (void)drawRect:(NSRect)r {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(r);
    [NSColor.separatorColor setFill]; NSRectFill(NSMakeRect(0, kBarH - 1, self.bounds.size.width, 1));
}

// qlmanage runs the same generator Quick Look uses, writing HTML and images we can show in our own view.
- (void)render {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[kRenderPrefix stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    _dir = dir;
    NSString *path = _path;
    __weak DocumentPreview *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/qlmanage"];
        t.arguments = @[@"-p", @"-o", dir, path];
        t.standardOutput = t.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSString *html = nil;
        if ([t launchAndReturnError:nil]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ if (t.isRunning) [t terminate]; });
            [t waitUntilExit];
            for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
                if ([n hasSuffix:@".qlpreview"]) {
                    NSString *p = [[dir stringByAppendingPathComponent:n] stringByAppendingPathComponent:@"Preview.html"];
                    if ([NSFileManager.defaultManager fileExistsAtPath:p]) html = p;
                }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf show:html]; });
    });
}

- (void)show:(NSString *)htmlPath {
    NSString *src = htmlPath ? [NSString stringWithContentsOfFile:htmlPath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!src.length) {                                                             // fall back to Quick Look's own view
        _fallback = FKCreateQuickLookView(NSZeroRect, _path);
        if (_fallback) [self addSubview:_fallback]; else _error = FTL(@"Couldn’t render this document");
        [_spinner stopAnimation:nil]; _spinner.hidden = YES;
        _loaded = YES;
        [self layoutParts];
        if (self.onChange) self.onChange();
        return;
    }
    NSRange head = [src rangeOfString:@"</head>" options:NSCaseInsensitiveSearch];
    src = head.location != NSNotFound ? [src stringByReplacingCharactersInRange:NSMakeRange(head.location, 0) withString:kPageCSS] : [kPageCSS stringByAppendingString:src];
    NSString *page = [htmlPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Page.html"];
    [src writeToFile:page atomically:YES encoding:NSUTF8StringEncoding error:nil];
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    cfg.defaultWebpagePreferences.allowsContentJavaScript = NO;                     // a document has no business running scripts
    _web = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:cfg];
    _web.navigationDelegate = self;
    _web.pageZoom = [NSUserDefaults.standardUserDefaults doubleForKey:@"documentZoom"] ?: 1;
    _web.accessibilityLabel = FTL(@"Document preview");
    [self addSubview:_web positioned:NSWindowBelow relativeTo:_spinner];
    [self layoutParts];
    [_web loadFileURL:[NSURL fileURLWithPath:page] allowingReadAccessToURL:[NSURL fileURLWithPath:htmlPath.stringByDeletingLastPathComponent isDirectory:YES]];
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    [_spinner stopAnimation:nil]; _spinner.hidden = YES;
    _loaded = YES;
    if (self.onChange) self.onChange();
}

- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h {
    NSURL *u = a.request.URL;
    if (a.navigationType != WKNavigationTypeLinkActivated && (u.isFileURL || [u.scheme isEqual:@"about"])) { h(WKNavigationActionPolicyAllow); return; }
    if (a.navigationType == WKNavigationTypeLinkActivated && [@[@"http", @"https", @"mailto"] containsObject:u.scheme.lowercaseString ?: @""])
        [NSWorkspace.sharedWorkspace openURL:u];                                    // scripts are off: this was a click
    h(WKNavigationActionPolicyCancel);
}

- (void)openInApp:(id)sender {
    NSURL *app = FTOtherAppFor(_path);
    if (app) [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:_path]] withApplicationAtURL:app configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (NSString *)status {
    if (_error) return _error;
    NSString *z = _web && fabs(_web.pageZoom - 1) > 0.01 ? [NSString stringWithFormat:@"   %.0f%%", _web.pageZoom * 100] : @"";
    return [NSString stringWithFormat:FTL(@"Word document (read-only)%@"), z];
}

- (void)evaluate:(NSString *)js done:(void (^)(id))done {
    if (!_web) { if (done) done(nil); return; }
    [_web evaluateJavaScript:js completionHandler:^(id r, NSError *e) { if (done) done(e ? nil : r); }];
}

- (BOOL)find:(NSString *)text backward:(BOOL)back {
    if (!_web || !text.length) return NO;
    NSData *j = [NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil];
    NSString *arg = [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding];
    [_web evaluateJavaScript:[NSString stringWithFormat:@"window.find(%@[0], false, %@, true)", arg, back ? @"true" : @"false"] completionHandler:^(id r, NSError *e) {
        if (![r boolValue]) NSBeep();
    }];
    return YES;
}

- (NSView *)focusView { return _web ?: _fallback ?: self; }
- (NSView *)toolsView { return nil; }
- (void)setPageZoom:(CGFloat)z {
    _web.pageZoom = MIN(MAX(z, 0.3), 3);
    [NSUserDefaults.standardUserDefaults setDouble:_web.pageZoom forKey:@"documentZoom"];
    if (self.onChange) self.onChange();
}
- (void)ftZoomIn { [self setPageZoom:_web.pageZoom * 1.1]; }
- (void)ftZoomOut { [self setPageZoom:_web.pageZoom / 1.1]; }
- (void)ftZoomToFit { [self setPageZoom:1]; }
- (void)ftZoomActualSize { [self setPageZoom:1]; }
- (void)ftRotate:(NSInteger)q {}
- (CGFloat)zoomPercent { return (_web ? _web.pageZoom : 1) * 100; }

@end

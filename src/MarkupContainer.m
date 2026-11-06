#import "MarkupView.h"
#import "TextEditorView.h"
#import "FileOps.h"
#import "CanvasView.h"
#import <WebKit/WebKit.h>

static CGFloat gHTMLZoom = 1;
static const NSUInteger kMaxMarkdownBytes = 2u << 20;

@interface HTMLPreview () <WKNavigationDelegate, WKUIDelegate>
@end

@implementation HTMLPreview {
    WKWebView *_web;
    NSString *_root;
    double _restoreY;
}

static NSString *absolute(NSString *p) {
    if (!p.length || p.isAbsolutePath) return p.stringByStandardizingPath;
    return [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:p].stringByStandardizingPath;
}

- (void)setPath:(NSString *)p { _path = absolute(p); }

- (instancetype)initWithFrame:(NSRect)f path:(NSString *)path root:(NSString *)root {
    if (!(self = [super initWithFrame:f])) return nil;
    _path = absolute(path);
    _root = [root copy];
    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;    // nothing written to ~/Library
    _web = [[WKWebView alloc] initWithFrame:self.bounds configuration:cfg];
    _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _web.navigationDelegate = self;
    _web.UIDelegate = self;
    _web.accessibilityLabel = @"HTML 预览";
    self.zoom = gHTMLZoom;
    [self addSubview:_web];
    [self load];
    return self;
}

- (NSView *)webView { return _web; }

+ (CGFloat)defaultZoom { return gHTMLZoom; }
+ (void)setDefaultZoom:(CGFloat)z { gHTMLZoom = MIN(MAX(z, 0.3), 3); }
- (CGFloat)zoom { return _web.pageZoom; }
- (void)setZoom:(CGFloat)z { _web.pageZoom = MIN(MAX(z, 0.3), 3); }

// Read access: the workspace when the file is inside it (relative CSS/JS/images), never the whole home folder.
- (NSURL *)accessURL {
    NSString *dir = _path.stringByDeletingLastPathComponent;
    BOOL useRoot = _root && FOPathIsWithin(_path, _root) && ![_root isEqualToString:NSHomeDirectory()] && ![_root isEqualToString:@"/"];
    return [NSURL fileURLWithPath:useRoot ? _root : dir isDirectory:YES];
}

- (void)load { [_web loadFileURL:[NSURL fileURLWithPath:_path] allowingReadAccessToURL:self.accessURL]; }

- (void)reload {
    __weak HTMLPreview *weakSelf = self;
    [_web evaluateJavaScript:@"window.scrollY" completionHandler:^(id y, NSError *e) {
        HTMLPreview *me = weakSelf;
        if (!me) return;
        me->_restoreY = [y isKindOfClass:NSNumber.class] ? [y doubleValue] : 0;
        [me load];
    }];
}

- (void)evaluate:(NSString *)js done:(void (^)(id))done {
    [_web evaluateJavaScript:js completionHandler:^(id r, NSError *e) { if (done) done(e ? nil : r); }];
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)nav {
    if (_restoreY > 0) { [wv evaluateJavaScript:[NSString stringWithFormat:@"window.scrollTo(0,%f)", _restoreY] completionHandler:nil]; _restoreY = 0; }
    if (self.onLoad) self.onLoad();
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)wv { [self load]; }

- (BOOL)isOwnFile:(NSURL *)u {
    return u.isFileURL && [u.path.stringByStandardizingPath isEqualToString:_path.stringByStandardizingPath];
}

- (void)follow:(NSURL *)u {
    NSString *scheme = u.scheme.lowercaseString;
    if (u.isFileURL) {
        BOOL dir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:u.path isDirectory:&dir] && !dir && self.onOpenFile) self.onOpenFile(u.path);
        else NSBeep();
    } else if ([@[@"http", @"https", @"mailto"] containsObject:scheme ?: @""]) [NSWorkspace.sharedWorkspace openURL:u];
}

// The page itself and its iframes load normally; clicked links open in a tab (local files) or the browser.
- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))h {
    NSURL *u = a.request.URL;
    if (!a.targetFrame.isMainFrame && a.targetFrame) { h(WKNavigationActionPolicyAllow); return; }
    if ([self isOwnFile:u] || [u.scheme isEqualToString:@"about"]) { h(WKNavigationActionPolicyAllow); return; }   // incl. #fragments
    if (a.navigationType == WKNavigationTypeLinkActivated) [self follow:u];
    h(WKNavigationActionPolicyCancel);
}

- (WKWebView *)webView:(WKWebView *)wv createWebViewWithConfiguration:(WKWebViewConfiguration *)c
   forNavigationAction:(WKNavigationAction *)a windowFeatures:(WKWindowFeatures *)f {
    if (a.navigationType == WKNavigationTypeLinkActivated) [self follow:a.request.URL];
    return nil;
}

@end

@implementation MarkupContainer {
    NSSplitView *_split;
    NSView *_preview;
    NSUInteger _renderGen;
    BOOL _built;
}

- (instancetype)initWithEditor:(TextEditorView *)editor kind:(MarkupKind)kind path:(NSString *)path root:(NSString *)root {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) return nil;
    _editor = editor;
    _kind = kind;
    _path = [path copy];
    _root = [root copy];
    _layout = MarkupSource;
    self.autoresizesSubviews = YES;
    FTClipToBounds(self);
    [self applyLayout];
    return self;
}

- (MarkdownPreview *)markdownView { return [_preview isKindOfClass:MarkdownPreview.class] ? (MarkdownPreview *)_preview : nil; }
- (HTMLPreview *)htmlView { return [_preview isKindOfClass:HTMLPreview.class] ? (HTMLPreview *)_preview : nil; }

- (void)setLayout:(MarkupLayout)l {
    if (l == _layout && _built) return;
    _layout = l;
    [self applyLayout];
}

- (NSView *)makePreview {
    __weak MarkupContainer *weakSelf = self;
    if (_kind == MarkupMarkdown) {
        MarkdownPreview *m = [[MarkdownPreview alloc] initWithFrame:self.bounds];
        m.onLink = ^(NSString *href) { [weakSelf followHref:href]; };
        return m;
    }
    HTMLPreview *h = [[HTMLPreview alloc] initWithFrame:self.bounds path:_path root:_root];
    h.onOpenFile = ^(NSString *p) { MarkupContainer *me = weakSelf; if (me.onOpenFile) me.onOpenFile(p, nil); };
    return h;
}

- (void)ensurePreview {
    if (_layout == MarkupSource || _preview) { if (!_built) [self applyLayout]; return; }
    [self applyLayout];
}

- (void)releasePreview {
    if (!_preview) return;
    [_preview removeFromSuperview];
    _preview = nil;
    [_split removeFromSuperview];
    _split = nil;
    _built = NO;
}

- (void)applyLayout {
    NSWindow *w = self.window;
    BOOL editorFocused = [w.firstResponder isKindOfClass:NSView.class] && [(NSView *)w.firstResponder isDescendantOf:_editor];
    for (NSView *v in self.subviews.copy) [v removeFromSuperview];
    [_split removeFromSuperview];
    _split = nil;
    if (_layout != MarkupSource && !_preview) {
        _preview = [self makePreview];
        if (_kind == MarkupMarkdown) [self refreshNow];          // HTML loads itself from disk
    }
    NSRect b = self.bounds;
    if (_layout == MarkupSource) {
        _editor.frame = b; _editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_editor];
    } else if (_layout == MarkupPreview) {
        _preview.frame = b; _preview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_preview];
    } else {
        _split = [[NSSplitView alloc] initWithFrame:b];
        _split.vertical = YES;
        _split.dividerStyle = NSSplitViewDividerStyleThin;
        _split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _split.delegate = self;
        CGFloat half = floor((b.size.width - 1) / 2);
        _editor.frame = NSMakeRect(0, 0, half, b.size.height);
        _preview.frame = NSMakeRect(half + 1, 0, b.size.width - half - 1, b.size.height);
        [_split addSubview:_editor];
        [_split addSubview:_preview];
        [self addSubview:_split];
        [_split adjustSubviews];
        [self editorScrolled];
    }
    _built = YES;
    if (w && (editorFocused || _layout == MarkupPreview)) [w makeFirstResponder:self.focusView];
}

- (CGFloat)splitView:(NSSplitView *)sv constrainMinCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i { return 160; }
- (CGFloat)splitView:(NSSplitView *)sv constrainMaxCoordinate:(CGFloat)p ofSubviewAt:(NSInteger)i { return sv.bounds.size.width - 160; }

- (NSView *)focusView {
    if (_layout != MarkupPreview) return _editor;
    return self.markdownView ? self.markdownView.textView : self.htmlView ? self.htmlView.webView : _editor;
}

- (void)refreshNow {
    if (self.markdownView) {
        NSString *dir = _path.stringByDeletingLastPathComponent;
        if (_editor.contentLength > kMaxMarkdownBytes) {
            [self.markdownView setMarkdown:@"> 文件超过 2 MB，预览已关闭。请使用源码视图。" baseDir:dir];
            return;
        }
        NSString *s = [[NSString alloc] initWithData:_editor.contentData encoding:NSUTF8StringEncoding] ?: @"";
        [self.markdownView setMarkdown:s baseDir:dir];
        if (_layout == MarkupSplit) [self editorScrolled];
    } else if (self.htmlView) [self.htmlView reload];
}

- (void)textChanged {
    if (_kind != MarkupMarkdown || !self.markdownView) return;
    NSUInteger gen = ++_renderGen;
    double delay = MIN(0.6, 0.12 + _editor.contentLength / 400000.0);
    __weak MarkupContainer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MarkupContainer *me = weakSelf;
        if (me && me->_renderGen == gen) [me refreshNow];
    });
}

- (void)didSave { if (self.htmlView) [self.htmlView reload]; }

- (void)editorScrolled {
    if (_layout == MarkupSplit) [self.markdownView scrollToSourceLine:_editor.topVisibleLine];
}

- (void)setPath:(NSString *)p {
    _path = [p copy];
    if (self.htmlView) { self.htmlView.path = p; [self.htmlView reload]; }
}

- (void)followHref:(NSString *)href {
    NSURL *u = [NSURL URLWithString:href];
    NSString *scheme = u.scheme.lowercaseString;
    if ([@[@"http", @"https", @"mailto"] containsObject:scheme ?: @""]) { [NSWorkspace.sharedWorkspace openURL:u]; return; }
    if (scheme.length && ![scheme isEqualToString:@"file"]) { NSBeep(); return; }
    NSString *pathPart = href, *anchor = nil;
    NSRange hash = [href rangeOfString:@"#"];
    if (hash.location != NSNotFound) { pathPart = [href substringToIndex:hash.location]; anchor = [href substringFromIndex:hash.location + 1]; }
    NSRange q = [pathPart rangeOfString:@"?"];
    if (q.location != NSNotFound) pathPart = [pathPart substringToIndex:q.location];
    NSString *p = [scheme isEqualToString:@"file"] ? u.path : (pathPart.stringByRemovingPercentEncoding ?: pathPart);
    if (![p hasPrefix:@"/"]) p = [_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:p];
    p = p.stringByStandardizingPath;
    BOOL dir = NO;
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir];
    if (!exists || dir) {
        NSBeep();
        NSString *shown = FOPathIsWithin(p, _path.stringByDeletingLastPathComponent)
            ? [p substringFromIndex:MIN(p.length, _path.stringByDeletingLastPathComponent.length + 1)] : p.stringByAbbreviatingWithTildeInPath;
        if (self.onMessage) self.onMessage(dir ? [NSString stringWithFormat:@"“%@”是文件夹，无法在标签页中打开", shown]
                                               : [NSString stringWithFormat:@"链接的文件不存在：%@", shown]);
        return;
    }
    if ([p isEqualToString:_path.stringByStandardizingPath]) { if (anchor) [self.markdownView scrollToAnchor:anchor]; return; }
    if (self.onOpenFile) self.onOpenFile(p, anchor);
}

@end

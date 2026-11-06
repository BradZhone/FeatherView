#import <Cocoa/Cocoa.h>
#import "FileKind.h"
@class TextEditorView, MarkdownRenderer;

@interface MarkdownTextView : NSTextView
- (NSUInteger)linkIndexAtPoint:(NSPoint)p;        // NSNotFound if no link under p
- (void)activateLinkAtIndex:(NSUInteger)i;        // follows on the next run-loop turn
@end

// Native Markdown preview: read-only TextKit 1 text view, no web engine.
@interface MarkdownPreview : NSView <NSTextViewDelegate>
@property (nonatomic, readonly) MarkdownTextView *textView;
@property (nonatomic, readonly) MarkdownRenderer *renderer;
@property (nonatomic, copy) void (^onLink)(NSString *href);
@property (nonatomic) CGFloat scale;                       // text size, 1 = normal; re-flows, images unchanged
@property (class, nonatomic) CGFloat defaultScale;
- (void)setMarkdown:(NSString *)source baseDir:(NSString *)dir;
- (void)scrollToSourceLine:(CGFloat)line;      // 0-based, fractional
- (BOOL)scrollToAnchor:(NSString *)slug;
@end

// HTML preview in WKWebView. Reloads from disk (after save), keeping the scroll position.
@interface HTMLPreview : NSView
- (instancetype)initWithFrame:(NSRect)f path:(NSString *)path root:(NSString *)root;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, readonly) NSView *webView;
@property (nonatomic, copy) void (^onOpenFile)(NSString *path);
@property (nonatomic, copy) void (^onLoad)(void);
@property (nonatomic) CGFloat zoom;                        // page zoom, 1 = 100%
@property (class, nonatomic) CGFloat defaultZoom;
- (void)reload;
- (void)evaluate:(NSString *)js done:(void (^)(id result))done;   // tests
@end

// Source editor + preview for .md / .html, in one of three layouts.
@interface MarkupContainer : NSView <NSSplitViewDelegate>
- (instancetype)initWithEditor:(TextEditorView *)editor kind:(MarkupKind)kind path:(NSString *)path root:(NSString *)root;
@property (nonatomic, readonly) TextEditorView *editor;
@property (nonatomic, readonly) MarkupKind kind;
@property (nonatomic) MarkupLayout layout;
@property (nonatomic, copy) NSString *path, *root;
@property (nonatomic, readonly) MarkdownPreview *markdownView;   // nil unless kind is Markdown and preview exists
@property (nonatomic, readonly) HTMLPreview *htmlView;
@property (nonatomic, copy) void (^onOpenFile)(NSString *path, NSString *anchor);
@property (nonatomic, copy) void (^onMessage)(NSString *message);   // e.g. link target missing
- (NSView *)focusView;
- (void)textChanged;        // debounced live re-render (Markdown)
- (void)didSave;            // HTML reloads from disk
- (void)editorScrolled;     // split view: keep preview at the same place
- (void)releasePreview;     // background tab: free the preview, keep the editor
- (void)ensurePreview;      // foreground again
- (void)refreshNow;
- (void)followHref:(NSString *)href;
@end

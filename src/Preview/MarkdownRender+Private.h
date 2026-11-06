#import "MarkdownRender.h"

// Rendering context, copied when descending into containers.
@interface RCtx : NSObject
@property (nonatomic) CGFloat indent;              // head indent of text, inside the innermost block
@property (nonatomic, copy) NSArray *tb;           // enclosing NSTextBlocks (quotes)
@property (nonatomic) NSInteger depth;             // list nesting
@property (nonatomic) BOOL tight;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) NSTextAlignment align;
@property (nonatomic) CGFloat lineHeight;          // 0 = default
- (RCtx *)with:(void (^)(RCtx *c))change;
@end

@interface MarkdownRenderer () {
@public
    MDDocument *_doc;
    NSMutableAttributedString *_out;
    NSMutableArray<NSNumber *> *_lines, *_locs;
    NSMutableDictionary<NSString *, NSNumber *> *_anchorMap;
    NSCountedSet *_slugs;
    NSMutableDictionary<NSString *, id> *_images;      // src → NSImage, or NSNull when it failed
    NSMutableSet<NSString *> *_inflight;
    NSUInteger _remoteCount;
    NSURLSession *_session;
}
- (NSDictionary *)base:(RCtx *)c font:(NSFont *)f;
- (NSMutableAttributedString *)inlineText:(NSString *)s ctx:(RCtx *)c font:(NSFont *)f;
- (void)para:(NSAttributedString *)content ctx:(RCtx *)c after:(CGFloat)after before:(CGFloat)before
       block:(NSTextBlock *)block marker:(NSAttributedString *)marker markerAt:(CGFloat)markerAt font:(NSFont *)f;
- (void)code:(NSString *)text info:(NSString *)info ctx:(RCtx *)c;
@end

@interface MarkdownRenderer (Inline)
- (void)inlines:(NSArray<MDInline *> *)a attrs:(NSDictionary *)base into:(NSMutableAttributedString *)o;
- (NSAttributedString *)imageFor:(NSString *)src alt:(NSString *)alt width:(NSString *)w height:(NSString *)h attrs:(NSDictionary *)attrs;
- (NSAttributedString *)checkbox:(BOOL)done;
@end

@interface MarkdownRenderer (Blocks)
- (void)table:(MDBlock *)b ctx:(RCtx *)c;
- (void)html:(MDBlock *)b ctx:(RCtx *)c;
@end

NSFont *MDTrait(NSFont *f, NSFontDescriptorSymbolicTraits t);
NSColor *MDCodeBackground(void);
NSDictionary<NSString *, NSString *> *MDHTMLAttrs(NSString *tag);

#import <Foundation/Foundation.h>

// CommonMark-flavoured Markdown (+ GFM tables, task lists, strikethrough, bare URLs) → AST.
// Not a full spec implementation; covers what READMEs and notes use in practice.

typedef NS_ENUM(NSInteger, MDBlockType) {
    MDParagraph, MDHeading, MDCode, MDQuote, MDList, MDItem, MDRule, MDTable, MDHTMLBlock,
};

typedef NS_ENUM(NSInteger, MDAlign) { MDAlignNone, MDAlignLeft, MDAlignCenter, MDAlignRight };

@interface MDBlock : NSObject
@property (nonatomic) MDBlockType type;
@property (nonatomic) NSUInteger line;                 // 0-based source line where the block starts
@property (nonatomic) NSInteger level;                 // heading 1–6
@property (nonatomic, copy) NSString *text;            // paragraph/heading inline source, code body, raw HTML
@property (nonatomic, copy) NSString *info;            // code fence language
@property (nonatomic, strong) NSMutableArray<MDBlock *> *children;   // quote, list → items, item → blocks
@property (nonatomic) BOOL ordered, tight;
@property (nonatomic) NSInteger start;                 // first number of an ordered list
@property (nonatomic) NSInteger task;                  // item: -1 none, 0 open, 1 done
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *rows;    // table, row 0 = header
@property (nonatomic, copy) NSArray<NSNumber *> *align;              // MDAlign per column
@end

typedef NS_ENUM(NSInteger, MDInlineType) {
    MDText, MDCodeSpan, MDEmph, MDStrong, MDStrike, MDLink, MDImage, MDHardBreak, MDSoftBreak, MDRawHTML,
};

@interface MDInline : NSObject
@property (nonatomic) MDInlineType type;
@property (nonatomic, copy) NSString *text;            // text, code, raw html; image alt
@property (nonatomic, copy) NSString *url, *title;     // link / image
@property (nonatomic, strong) NSArray<MDInline *> *children;
+ (instancetype)text:(NSString *)s;
@end

@interface MDDocument : NSObject
@property (nonatomic, strong) NSArray<MDBlock *> *blocks;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<NSString *> *> *refs;   // label → @[url, title]
- (NSArray<MDInline *> *)inlines:(NSString *)s;
@end

MDDocument *MDParse(NSString *source);
NSArray<MDInline *> *MDParseInline(NSString *s, NSDictionary *refs);
NSString *MDPlainText(NSArray<MDInline *> *inlines);
NSString *MDSlug(NSString *heading);                   // GitHub-style anchor, without de-duplication
NSString *MDRenderHTML(MDDocument *doc);               // compact HTML, used by tests

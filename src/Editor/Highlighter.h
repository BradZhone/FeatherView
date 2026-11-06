#import <Cocoa/Cocoa.h>

typedef NS_ENUM(uint8_t, TokenKind) {
    TokPlain, TokKeyword, TokString, TokComment, TokNumber, TokType,
    TokFunction,    // calls / definitions, Markdown link text
    TokProperty,    // JSON / YAML / TOML keys, CSS properties, HTML attributes, member access
    TokTag,         // HTML / XML tag names, CSS selectors, TOML sections
    TokConstant,    // true / null / ALL_CAPS / Markdown list markers
    TokMeta,        // punctuation-ish: #include, @decorator, ``` fences, YAML ---
    TokHeading,     // Markdown heading (bold)
    TokEmphasis,    // Markdown *italic* (italic)
    TokStrong,      // Markdown **bold** (bold)
    TokInserted,    // diff +
    TokDeleted,     // diff -  (the only red)
    TokKindCount
};

// Colour for each kind, light / dark aware. Red is reserved for TokDeleted.
NSColor *HLColor(TokenKind k);
BOOL HLIsItalic(TokenKind k);   // comments, emphasis
BOOL HLIsBold(TokenKind k);     // headings, strong

// Single-line, stateless tokenizer with one mode per file family (code, JSON, YAML, TOML/INI, CSS,
// HTML/XML, Markdown, diff). Multi-line constructs (block comments, fenced code) use per-line heuristics.
@interface Highlighter : NSObject
+ (instancetype)highlighterForPath:(NSString *)path;   // nil = no highlighting
@property (nonatomic, readonly) NSString *modeName;    // "code", "json", "markdown", … (tests)
- (void)tokenize:(NSString *)line emit:(void (^)(NSRange r, TokenKind k))emit;
@end

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(uint8_t, TokenKind) { TokPlain, TokKeyword, TokString, TokComment, TokNumber, TokType };

// Single-line, stateless tokenizer. Block comments are only recognized when they
// start and end on the same line (plus a heuristic for " * " continuation lines).
@interface Highlighter : NSObject
+ (instancetype)highlighterForPath:(NSString *)path;   // nil = no highlighting
- (void)tokenize:(NSString *)line emit:(void (^)(NSRange r, TokenKind k))emit;
@end

#import "Highlighter.h"

@implementation Highlighter {
    NSString *_lineComment;   // "//", "#", "--" or nil
    BOOL _blockComments;      // /* */
    NSSet<NSString *> *_keywords;
}

static NSSet *words(NSString *s) { return [NSSet setWithArray:[s componentsSeparatedByString:@" "]]; }

+ (instancetype)highlighterForPath:(NSString *)path {
    static NSDictionary<NSString *, NSArray *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSSet *cfam = words(@"if else for while do switch case default break continue return goto struct union enum typedef "
            "static const extern inline void int char short long float double unsigned signed bool true false NULL nil YES NO "
            "self super class public private protected virtual override template typename namespace using new delete this "
            "try catch throw finally import package interface extends implements final abstract var let func fn mut impl "
            "trait pub mod use crate match loop where async await yield function export from as in of typeof instanceof "
            "null undefined type go defer chan select range map struct guard protocol extension init deinit some any "
            "val fun object when is sizeof auto constexpr nullptr noexcept static_cast dynamic_cast");
        NSSet *script = words(@"if elif else for while in def class return import from as with try except finally raise "
            "pass break continue lambda yield global nonlocal assert del not and or is None True False async await "
            "then fi do done case esac function local export echo end begin rescue ensure module require unless until "
            "nil self puts");
        NSSet *sql = words(@"select from where insert into update delete create table drop alter join left right inner "
            "outer on group by order having limit as and or not null values set index primary key function local end "
            "then if else elseif return nil true false for in do while repeat until");
        NSArray *c = @[@"//", @YES, cfam], *h = @[@"#", @NO, script], *d = @[@"--", @NO, sql];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *e in [@"c h m mm cc cpp cxx hpp hh java js mjs cjs jsx ts tsx go rs swift kt kts scala cs dart php zig css scss less json jsonc proto groovy gradle" componentsSeparatedByString:@" "]) m[e] = c;
        for (NSString *e in [@"py rb sh bash zsh fish yml yaml toml ini conf cfg mk cmake r pl tf dockerfile makefile" componentsSeparatedByString:@" "]) m[e] = h;
        for (NSString *e in [@"sql lua hs" componentsSeparatedByString:@" "]) m[e] = d;
        table = m;
    });
    NSString *ext = path.pathExtension.lowercaseString;
    if (!ext.length) ext = path.lastPathComponent.lowercaseString;
    NSArray *cfg = table[ext];
    if (!cfg) return nil;
    Highlighter *hl = [Highlighter new];
    hl->_lineComment = cfg[0];
    hl->_blockComments = [cfg[1] boolValue];
    hl->_keywords = cfg[2];
    return hl;
}

static inline BOOL isIdentStart(unichar c) { return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static inline BOOL isIdent(unichar c) { return isIdentStart(c) || (c >= '0' && c <= '9'); }

- (void)tokenize:(NSString *)line emit:(void (^)(NSRange, TokenKind))emit {
    NSUInteger n = line.length;
    if (!n) return;
    unichar stackBuf[512];
    unichar *s = n <= 512 ? stackBuf : malloc(n * sizeof(unichar));
    [line getCharacters:s range:NSMakeRange(0, n)];
    NSUInteger lcLen = _lineComment.length;
    unichar lc0 = lcLen ? [_lineComment characterAtIndex:0] : 0;

    NSUInteger i = 0;
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    if (_blockComments && i < n && s[i] == '*' && (i + 1 == n || s[i+1] == ' ' || s[i+1] == '/')) {
        emit(NSMakeRange(0, n), TokComment);
        goto done;
    }
    while (i < n) {
        unichar c = s[i];
        if (lcLen && c == lc0 && i + lcLen <= n &&
            (lcLen == 1 || s[i+1] == [_lineComment characterAtIndex:1])) {
            emit(NSMakeRange(i, n - i), TokComment); break;
        }
        if (_blockComments && c == '/' && i + 1 < n && s[i+1] == '*') {
            NSUInteger j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j+1] == '/')) j++;
            j = MIN(n, j + 2);
            emit(NSMakeRange(i, j - i), TokComment); i = j; continue;
        }
        if (c == '"' || c == '\'' || c == '`') {
            NSUInteger j = i + 1;
            while (j < n && s[j] != c) { if (s[j] == '\\') j++; j++; }
            j = MIN(n, j + 1);
            emit(NSMakeRange(i, j - i), TokString); i = j; continue;
        }
        if (c >= '0' && c <= '9' && (i == 0 || !isIdent(s[i-1]))) {
            NSUInteger j = i + 1;
            while (j < n && (isIdent(s[j]) || s[j] == '.')) j++;
            emit(NSMakeRange(i, j - i), TokNumber); i = j; continue;
        }
        if (isIdentStart(c)) {
            NSUInteger j = i + 1;
            while (j < n && isIdent(s[j])) j++;
            NSString *w = [[NSString alloc] initWithCharactersNoCopy:s + i length:j - i freeWhenDone:NO];
            if ([_keywords containsObject:w] || (lc0 == '-' && [_keywords containsObject:w.lowercaseString])) emit(NSMakeRange(i, j - i), TokKeyword);
            else if (c >= 'A' && c <= 'Z' && j - i > 1) emit(NSMakeRange(i, j - i), TokType);
            i = j; continue;
        }
        i++;
    }
done:
    if (s != stackBuf) free(s);
}

@end

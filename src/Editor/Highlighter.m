#import "Highlighter.h"

#pragma mark Palette

static NSColor *rgb(uint32_t v) {
    return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}
static NSColor *pair(uint32_t light, uint32_t dark) {
    NSColor *l = rgb(light), *d = rgb(dark);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        return [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua ? d : l;
    }];
}

// Hues spread around the wheel so neighbouring kinds never look alike; red only for deletions.
NSColor *HLColor(TokenKind k) {
    static NSColor *table[TokKindCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table[TokPlain]    = NSColor.textColor;
        table[TokKeyword]  = pair(0x8839EF, 0xC678DD);   // violet
        table[TokString]   = pair(0x2F7D32, 0x98C379);   // green
        table[TokComment]  = pair(0x8C8FA1, 0x7F848E);   // grey, italic
        table[TokNumber]   = pair(0xB85C00, 0xD19A66);   // orange
        table[TokType]     = pair(0x8E6A00, 0xE5C07B);   // amber
        table[TokFunction] = pair(0x1E66F5, 0x61AFEF);   // blue
        table[TokProperty] = pair(0x0B7285, 0x56B6C2);   // teal
        table[TokTag]      = pair(0x5C5FD6, 0x8FA8FF);   // indigo
        table[TokConstant] = pair(0xB4469C, 0xE59FDC);   // orchid
        table[TokMeta]     = pair(0x6C7A96, 0x8B98B4);   // slate
        table[TokHeading]  = pair(0x1E66F5, 0x61AFEF);
        table[TokEmphasis] = NSColor.textColor;
        table[TokStrong]   = NSColor.textColor;
        table[TokInserted] = pair(0x2F7D32, 0x98C379);
        table[TokDeleted]  = pair(0xC4314B, 0xE88388);
    });
    return k < TokKindCount ? table[k] : table[TokPlain];
}
BOOL HLIsItalic(TokenKind k) { return k == TokComment || k == TokEmphasis; }
BOOL HLIsBold(TokenKind k) { return k == TokHeading || k == TokStrong; }

#pragma mark Languages

typedef NS_ENUM(NSInteger, HLMode) { ModeCode, ModeJSON, ModeYAML, ModeINI, ModeCSS, ModeMarkup, ModeMarkdown, ModeDiff, ModeHashOnly };

@interface HLLang : NSObject {
@public
    HLMode mode;
    NSString *name;
    const char *line;        // line comment: "//", "#", "--", ";" or NULL
    BOOL block;              // /* */
    BOOL hashDirective;      // C preprocessor
    BOOL dollarVars;         // $x (shell, PHP, Perl)
    BOOL decorators;         // @x
    BOOL lifetimes;          // Rust 'a
    BOOL caseless;           // SQL keywords in any case
    BOOL targets;            // Makefile "target:" at column 0
    BOOL toml;               // typed values in ModeINI
    NSSet<NSString *> *keywords, *constants, *types, *builtins;
}
@end
@implementation HLLang @end

static NSSet *W(NSString *s) { return [NSSet setWithArray:[s componentsSeparatedByString:@" "]]; }

static HLLang *lang(HLMode m, NSString *name, const char *lineComment, BOOL block, NSString *kw, NSString *consts, NSString *types) {
    HLLang *l = [HLLang new];
    l->mode = m; l->name = name; l->line = lineComment; l->block = block;
    l->keywords = kw ? W(kw) : [NSSet set];
    l->constants = consts ? W(consts) : [NSSet set];
    l->types = types ? W(types) : [NSSet set];
    l->builtins = [NSSet set];
    return l;
}

static NSDictionary<NSString *, HLLang *> *languages(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^map)(NSString *, HLLang *) = ^(NSString *exts, HLLang *l) { for (NSString *e in [exts componentsSeparatedByString:@" "]) m[e] = l; };

        HLLang *c = lang(ModeCode, @"code", "//", YES,
            @"if else for while do switch case default break continue return goto struct union enum typedef static const "
            "extern inline volatile register sizeof class public private protected virtual override template typename "
            "namespace using new delete this operator friend try catch throw noexcept constexpr auto explicit mutable "
            "static_cast dynamic_cast reinterpret_cast const_cast decltype @interface @implementation @end @property "
            "@protocol @selector @class @synthesize @autoreleasepool @try @catch @finally @import self super in",
            @"true false NULL nullptr nil Nil YES NO",
            @"void int char short long float double unsigned signed bool BOOL id instancetype SEL IMP size_t ssize_t "
            "uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t CGFloat NSInteger NSUInteger");
        c->hashDirective = YES;
        map(@"c h m mm cc cpp cxx hpp hh hxx ino metal cu", c);

        HLLang *js = lang(ModeCode, @"code", "//", YES,
            @"if else for while do switch case default break continue return function class extends new delete typeof "
            "instanceof in of var let const try catch finally throw async await yield import export from as default "
            "this super static get set type interface enum implements declare namespace module abstract readonly "
            "private public protected keyof infer is satisfies with void",
            @"true false null undefined NaN Infinity",
            @"string number boolean any unknown never object symbol bigint");
        js->decorators = YES; js->dollarVars = NO;
        map(@"js mjs cjs jsx ts mts cts tsx es6 qml", js);

        HLLang *jvm = lang(ModeCode, @"code", "//", YES,
            @"if else for while do switch case default break continue return class interface enum extends implements "
            "new this super static final abstract public private protected try catch finally throw throws import "
            "package synchronized volatile transient native instanceof var val fun object when is in out by init "
            "companion data sealed open override internal lateinit suspend inline def trait yield match lazy "
            "implicit using namespace foreach readonly ref struct async await get set partial where lock",
            @"true false null",
            @"void int long short byte char float double boolean String Int Long Float Double Boolean Unit Any Nothing "
            "object string bool decimal");
        jvm->decorators = YES;
        map(@"java kt kts scala sc groovy gradle cs fs dart", jvm);

        HLLang *php = lang(ModeCode, @"code", "//", YES, [jvm->keywords.allObjects componentsJoinedByString:@" "],
                           @"true false null TRUE FALSE NULL", nil);
        php->dollarVars = YES;
        map(@"php", php);

        HLLang *swift = lang(ModeCode, @"code", "//", YES,
            @"if else guard for while repeat switch case default break continue fallthrough return func class struct "
            "enum protocol extension import let var init deinit subscript self Self super static final public private "
            "fileprivate internal open override mutating nonmutating throws rethrows throw try catch do defer in as is "
            "where some any associatedtype typealias inout lazy weak unowned async await actor convenience required",
            @"true false nil", @"Int Double Float String Bool Character Void Any AnyObject");
        swift->decorators = YES;
        map(@"swift", swift);

        HLLang *go = lang(ModeCode, @"code", "//", YES,
            @"break case chan const continue default defer else fallthrough for func go goto if import interface map "
            "package range return select struct switch type var",
            @"true false nil iota",
            @"bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 "
            "uint16 uint32 uint64 uintptr any");
        map(@"go", go);

        HLLang *rust = lang(ModeCode, @"code", "//", YES,
            @"as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move "
            "mut pub ref return self Self static struct super trait type unsafe use where while macro_rules",
            @"true false None Some Ok Err",
            @"i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box");
        rust->lifetimes = YES;
        map(@"rs", rust);

        HLLang *zig = lang(ModeCode, @"code", "//", NO,
            @"const var fn pub return if else while for switch break continue defer errdefer try catch orelse struct "
            "enum union error comptime inline export extern test and or unreachable",
            @"true false null undefined", @"u8 u16 u32 u64 usize i8 i16 i32 i64 isize f32 f64 bool void type anytype");
        map(@"zig", zig);

        HLLang *proto = lang(ModeCode, @"code", "//", YES,
            @"syntax package import option message enum service rpc returns repeated optional required oneof map reserved extend",
            @"true false", @"double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 bool string bytes");
        map(@"proto", proto);

        HLLang *py = lang(ModeCode, @"code", "#", NO,
            @"if elif else for while in def class return import from as with try except finally raise pass break "
            "continue lambda yield global nonlocal assert del not and or is async await match case",
            @"None True False", @"int float str bool list dict set tuple bytes object");
        py->decorators = YES;
        map(@"py pyi pyw pyx", py);

        HLLang *rb = lang(ModeCode, @"code", "#", NO,
            @"if elsif else unless case when while until for in do end def class module return yield begin rescue "
            "ensure raise then and or not self super require require_relative include extend attr_accessor attr_reader",
            @"nil true false", nil);
        rb->decorators = NO;
        map(@"rb rake gemspec ru", rb);
        m[@"gemfile"] = rb; m[@"rakefile"] = rb;

        HLLang *sh = lang(ModeCode, @"code", "#", NO,
            @"if then else elif fi for while until do done case esac in function return local export readonly declare "
            "unset shift source alias set trap exit break continue select time",
            @"true false",
            nil);
        sh->dollarVars = YES;
        sh->builtins = W(@"echo printf cd ls cp mv rm mkdir rmdir cat grep sed awk find xargs test read eval exec "
                         "sudo git npm npx pnpm yarn brew make curl wget tar chmod chown ln kill ps open which");
        map(@"sh bash zsh ksh fish command bashrc zshrc profile envrc", sh);
        for (NSString *n in @[@".bashrc", @".zshrc", @".bash_profile", @".zprofile", @".profile", @".envrc"]) m[n] = sh;

        HLLang *hash = lang(ModeCode, @"code", "#", NO,
            @"if else elif elsif unless for foreach while do end in return function sub my our local use require "
            "package module import export def let then resource variable output locals provider data terraform "
            "query mutation subscription fragment on schema type input enum interface union scalar extend",
            @"true false null nil TRUE FALSE NULL NA", nil);
        hash->dollarVars = YES;
        map(@"pl pm r tcl tf tfvars hcl nix cmake graphql gql nim cr jl ex exs", hash);
        m[@"cmakelists.txt"] = hash;

        HLLang *sql = lang(ModeCode, @"code", "--", YES,
            @"select from where insert into update delete create table drop alter join left right inner outer full "
            "cross on group by order having limit offset as and or not in is like between exists values set index "
            "primary key foreign references unique default distinct union all case when then else end begin commit "
            "rollback transaction view trigger procedure function returns return declare with recursive asc desc "
            "if elseif local for do while repeat until function end then nil and or not in "
            "let where data type class instance module import deriving case of",
            @"null true false NULL TRUE FALSE nil", @"int integer bigint smallint text varchar char boolean date "
            "timestamp numeric decimal real float serial json jsonb uuid");
        sql->caseless = YES;
        map(@"sql psql mysql pgsql lua hs elm", sql);

        HLLang *dockerfile = lang(ModeCode, @"code", "#", NO,
            @"FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS",
            nil, nil);
        dockerfile->dollarVars = YES;
        map(@"dockerfile containerfile", dockerfile);

        HLLang *make = lang(ModeCode, @"code", "#", NO,
            @"ifeq ifneq ifdef ifndef else endif include define endef export override .PHONY",
            nil, nil);
        make->dollarVars = YES; make->targets = YES;
        map(@"mk mak makefile gnumakefile", make);

        map(@"css scss sass less styl", lang(ModeCSS, @"css", NULL, YES, nil, nil, nil));
        map(@"json jsonc json5 jsonl ndjson geojson webmanifest har ipynb babelrc eslintrc prettierrc code-workspace",
            lang(ModeJSON, @"json", "//", YES, nil, @"true false null", nil));
        for (NSString *n in @[@".babelrc", @".eslintrc", @".prettierrc", @"tsconfig.json", @"package.json"]) m[n] = m[@"json"];
        map(@"yaml yml clang-format", lang(ModeYAML, @"yaml", "#", NO, nil, @"true false null yes no on off True False Null ~", nil));
        for (NSString *n in @[@".clang-format", @".clang-tidy"]) m[n] = m[@"yaml"];
        HLLang *toml = lang(ModeINI, @"toml", "#", NO, nil, @"true false", nil);
        toml->toml = YES;
        map(@"toml lock", toml);
        map(@"ini conf cfg cnf properties env editorconfig gitconfig npmrc desktop service reg inf",
            lang(ModeINI, @"ini", "#", NO, nil, @"true false yes no on off", nil));
        for (NSString *n in @[@".env", @".editorconfig", @".gitconfig", @".npmrc", @".gitmodules"]) m[n] = m[@"ini"];
        map(@"gitignore dockerignore gitattributes npmignore prettierignore eslintignore",
            lang(ModeHashOnly, @"ignore", "#", NO, nil, nil, nil));
        for (NSString *n in @[@".gitignore", @".dockerignore", @".gitattributes", @".npmignore", @".prettierignore"]) m[n] = m[@"gitignore"];
        map(@"html htm xhtml xml svg plist xsd xsl xslt rss atom vue svelte astro jsp erb ejs hbs handlebars "
            "storyboard xib csproj vcxproj fsproj props targets resx config xaml kml gpx wsdl",
            lang(ModeMarkup, @"markup", NULL, NO, nil, nil, nil));
        map(@"md markdown mdown mkd mkdn mdx mdwn rmd", lang(ModeMarkdown, @"markdown", NULL, NO, nil, nil, nil));
        map(@"diff patch rej", lang(ModeDiff, @"diff", NULL, NO, nil, nil, nil));
        table = m;
    });
    return table;
}

@implementation Highlighter {
    HLLang *_l;
}

+ (instancetype)highlighterForPath:(NSString *)path {
    NSDictionary *t = languages();
    NSString *name = path.lastPathComponent.lowercaseString;
    HLLang *l = t[name];
    if (!l && [name hasPrefix:@"dockerfile"]) l = t[@"dockerfile"];
    if (!l && ([name hasPrefix:@".env."] || [name hasPrefix:@"env."])) l = t[@"env"];
    if (!l) { NSString *ext = name.pathExtension; l = t[ext.length ? ext : name]; }
    if (!l) return nil;
    Highlighter *h = [Highlighter new];
    h->_l = l;
    return h;
}

- (NSString *)modeName { return _l->name; }
- (NSString *)lineComment { return _l->line ? @(_l->line) : nil; }
- (NSArray<NSString *> *)blockComment {
    if (_l->mode == ModeMarkup || _l->mode == ModeMarkdown) return @[@"<!--", @"-->"];
    return _l->block ? @[@"/*", @"*/"] : nil;
}

typedef void (^Emit)(NSRange, TokenKind);
static const NSUInteger kMaxHighlight = 20000;          // longer lines (minified files) are highlighted up to here

static inline BOOL identStart(unichar c) { return c == '_' || c == '$' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c > 0x7F; }
static inline BOOL identChar(unichar c) { return identStart(c) || (c >= '0' && c <= '9'); }
static inline BOOL isDigit(unichar c) { return c >= '0' && c <= '9'; }
static inline BOOL isSpace(unichar c) { return c == ' ' || c == '\t'; }
static inline NSUInteger skipSpace(const unichar *s, NSUInteger i, NSUInteger n) { while (i < n && isSpace(s[i])) i++; return i; }
static inline void put(Emit e, NSUInteger a, NSUInteger b, TokenKind k) { if (b > a) e(NSMakeRange(a, b - a), k); }

// End of a quoted string starting at i (index after the closing quote, or n).
static NSUInteger stringEnd(const unichar *s, NSUInteger i, NSUInteger n) {
    unichar q = s[i];
    NSUInteger j = i + 1;
    while (j < n && s[j] != q) { if (s[j] == '\\') j++; j++; }
    return MIN(n, j + 1);
}

// 42, 3.14, 1e-9, 0xFF, 1_000, 10px, 2.5em, 100%
static NSUInteger numberEnd(const unichar *s, NSUInteger i, NSUInteger n) {
    NSUInteger j = i + 1;
    while (j < n) {
        unichar c = s[j];
        if (identChar(c) && c != '$') { j++; continue; }
        if (c == '.' && j + 1 < n && isDigit(s[j + 1])) { j++; continue; }
        if ((c == '-' || c == '+') && (s[j - 1] == 'e' || s[j - 1] == 'E') && !(s[i] == '0' && j > i + 1 && (s[i + 1] == 'x' || s[i + 1] == 'X'))) { j++; continue; }
        if (c == '%') { j++; break; }
        break;
    }
    return j;
}

static NSString *word(const unichar *s, NSUInteger a, NSUInteger b) {
    return [[NSString alloc] initWithCharacters:s + a length:b - a];
}

static BOOL allCaps(NSString *w) {
    if (w.length < 2) return NO;
    BOOL letter = NO;
    for (NSUInteger i = 0; i < w.length; i++) {
        unichar c = [w characterAtIndex:i];
        if (c >= 'a' && c <= 'z') return NO;
        if (c >= 'A' && c <= 'Z') letter = YES;
    }
    return letter;
}

#pragma mark Code

- (TokenKind)kindOfWord:(NSString *)w at:(NSUInteger)a end:(NSUInteger)b in:(const unichar *)s length:(NSUInteger)n {
    HLLang *l = _l;
    NSString *key = l->caseless ? w.lowercaseString : w;
    if ([l->keywords containsObject:key] || (l->caseless && [l->keywords containsObject:w])) return TokKeyword;
    if ([l->constants containsObject:w] || (l->caseless && [l->constants containsObject:key])) return TokConstant;
    if ([l->types containsObject:w] || (l->caseless && [l->types containsObject:key])) return TokType;
    NSUInteger k = skipSpace(s, b, n);
    BOOL call = k < n && s[k] == '(';
    if (k < n && s[k] == '!' && l->lifetimes) return TokFunction;                 // Rust macro!
    BOOL member = a > 0 && s[a - 1] == '.' && !(a > 1 && s[a - 2] == '.');
    unichar c0 = s[a];
    if (allCaps(w)) return call ? TokFunction : TokConstant;
    if (c0 >= 'A' && c0 <= 'Z') return TokType;
    if (call) return TokFunction;
    if ([l->builtins containsObject:w]) return TokFunction;
    if (member) return TokProperty;
    return TokPlain;
}

// Is "*/" at the start of this line likely the end of a comment that began on an earlier line?
static BOOL looksLikeCommentTail(const unichar *s, NSUInteger from, NSUInteger close) {
    for (NSUInteger k = from; k < close; k++) if (s[k] == ';' || s[k] == '{' || s[k] == '}' || s[k] == '(' || s[k] == '=') return NO;
    return YES;
}

- (void)code:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    HLLang *l = _l;
    NSUInteger lcLen = l->line ? strlen(l->line) : 0;
    NSUInteger i = skipSpace(s, 0, n);
    if (l->block && i < n) {
        if (s[i] == '*' && (i + 1 == n || s[i + 1] == ' ' || s[i + 1] == '/' || s[i + 1] == '*')) {   // " * text" inside /** */
            NSUInteger j = i;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
            j = j + 1 < n ? j + 2 : n;
            put(emit, 0, j, TokComment);
            i = j;
        } else {
            NSUInteger j = i;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/') && !(s[j] == '/' && (s[j + 1] == '*' || s[j + 1] == '/'))) j++;
            if (j + 1 < n && s[j] == '*' && s[j + 1] == '/' && looksLikeCommentTail(s, i, j)) { put(emit, 0, j + 2, TokComment); i = j + 2; }
        }
    }
    if (l->targets && n && identChar(s[0])) {                                                    // build: deps
        NSUInteger j = 0;
        while (j < n && (identChar(s[j]) || s[j] == '-' || s[j] == '.' || s[j] == '/' || s[j] == '%' || s[j] == ' ')) j++;
        if (j < n && s[j] == ':' && (j + 1 == n || s[j + 1] != '=')) {
            NSUInteger e = j;
            while (e > 0 && isSpace(s[e - 1])) e--;
            put(emit, 0, e, s[0] == '.' ? TokKeyword : TokFunction);
            i = j + 1;
        }
    }
    if (l->hashDirective && i < n && s[i] == '#') {                    // #include <x.h>, #define NAME
        NSUInteger j = skipSpace(s, i + 1, n);
        while (j < n && identChar(s[j])) j++;
        put(emit, i, j, TokMeta);
        NSUInteger k = skipSpace(s, j, n);
        if (k < n && s[k] == '<') {
            NSUInteger e = k;
            while (e < n && s[e] != '>') e++;
            put(emit, k, MIN(n, e + 1), TokString);
            i = MIN(n, e + 1);
        } else i = j;
    }
    while (i < n) {
        unichar c = s[i];
        if (lcLen && c == (unichar)l->line[0] && i + lcLen <= n && (lcLen == 1 || s[i + 1] == (unichar)l->line[1])) {
            BOOL hashOK = c != '#' || !l->dollarVars || i == 0 || isSpace(s[i - 1]);   // shell: $# and ${#x} are not comments
            if (hashOK) { put(emit, i, n, TokComment); return; }
        }
        if (l->block && c == '/' && i + 1 < n && s[i + 1] == '*') {
            NSUInteger j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
            j = MIN(n, j + 2);
            put(emit, i, j, TokComment); i = j; continue;
        }
        if (c == '"' || c == '`' || c == '\'') {
            if (c == '\'' && l->lifetimes && i + 1 < n && identStart(s[i + 1])) {      // Rust 'a lifetime, not a char
                NSUInteger j = i + 1;
                while (j < n && identChar(s[j])) j++;
                if (j >= n || s[j] != '\'') { put(emit, i, j, TokType); i = j; continue; }
            }
            NSUInteger j = stringEnd(s, i, n);
            if (j - i == 2 && j < n && s[j] == c && c != '`') {                         // """docstring"""
                NSUInteger e = j + 1;
                while (e + 2 < n && !(s[e] == c && s[e + 1] == c && s[e + 2] == c)) e++;
                j = MIN(n, e + 3);
            }
            put(emit, i, j, TokString); i = j; continue;
        }
        if (isDigit(c) && (i == 0 || !identChar(s[i - 1]))) {
            NSUInteger j = numberEnd(s, i, n);
            put(emit, i, j, TokNumber); i = j; continue;
        }
        if (c == '@' && i + 1 < n && identStart(s[i + 1])) {
            NSUInteger j = i + 1;
            while (j < n && identChar(s[j])) j++;
            NSString *w = word(s, i, j);
            if ([l->keywords containsObject:w]) put(emit, i, j, TokKeyword);         // @interface
            else if (l->decorators) put(emit, i, j, TokMeta);                     // @Override, @property
            i = j; continue;
        }
        if (c == '$' && l->dollarVars && i + 1 < n) {
            NSUInteger j = i + 1;
            if (s[j] == '{' || s[j] == '(') { unichar e = s[j] == '{' ? '}' : ')'; while (j < n && s[j] != e) j++; j = MIN(n, j + 1); }
            else if (identStart(s[j])) { while (j < n && identChar(s[j]) && s[j] != '$') j++; }
            else if (isDigit(s[j]) || (s[j] < 128 && s[j] && strchr("@#?*!$-", (char)s[j]))) j++;
            if (j > i + 1) { put(emit, i, j, TokProperty); i = j; continue; }
        }
        if (identStart(c) && !(c == '$' && l->dollarVars)) {                         // $el is a JS name, $x a shell variable
            NSUInteger j = i + 1;
            while (j < n && identChar(s[j]) && !(s[j] == '$' && l->dollarVars)) j++;
            BOOL prefix = (j - i <= 2) && j < n && (s[j] == '"' || s[j] == '\'');      // f"…", r'…', b"…", L"…", @"…"
            if (prefix) { NSUInteger e = stringEnd(s, j, n); put(emit, i, e, TokString); i = e; continue; }
            put(emit, i, j, [self kindOfWord:word(s, i, j) at:i end:j in:s length:n]);
            i = j; continue;
        }
        i++;
    }
}

#pragma mark JSON

- (void)json:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = 0;
    while (i < n) {
        unichar c = s[i];
        if (c == '/' && i + 1 < n && s[i + 1] == '/') { put(emit, i, n, TokComment); return; }       // JSONC
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            NSUInteger j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
            j = MIN(n, j + 2);
            put(emit, i, j, TokComment); i = j; continue;
        }
        if (c == '"' || c == '\'') {
            NSUInteger j = stringEnd(s, i, n), k = skipSpace(s, j, n);
            put(emit, i, j, k < n && s[k] == ':' ? TokProperty : TokString);                       // "key": vs "value"
            i = j; continue;
        }
        if (isDigit(c) || (c == '-' && i + 1 < n && isDigit(s[i + 1]))) {
            NSUInteger j = numberEnd(s, i, n);
            put(emit, i, j, TokNumber); i = j; continue;
        }
        if (identStart(c)) {
            NSUInteger j = i + 1;
            while (j < n && identChar(s[j])) j++;
            NSUInteger k = skipSpace(s, j, n);
            NSString *w = word(s, i, j);
            put(emit, i, j, [_l->constants containsObject:w] ? TokConstant : k < n && s[k] == ':' ? TokProperty : TokPlain);
            i = j; continue;
        }
        i++;
    }
}

#pragma mark YAML / TOML / INI

// A value after "key:" / "key =" / "- ": strings, numbers, booleans, anchors, trailing comments.
- (void)scalar:(const unichar *)s from:(NSUInteger)i length:(NSUInteger)n emit:(Emit)emit {
    BOOL ini = _l->mode == ModeINI && !_l->toml;
    while (i < n) {
        i = skipSpace(s, i, n);
        if (i >= n) return;
        unichar c = s[i];
        if (c == '#' || (c == ';' && ini)) { put(emit, i, n, TokComment); return; }
        if (c == '"' || c == '\'') {
            NSUInteger j = stringEnd(s, i, n);
            if (_l->toml && j - i == 2 && j < n && s[j] == c) {                                    // """multi-line"""
                NSUInteger e = j + 1;
                while (e + 2 < n && !(s[e] == c && s[e + 1] == c && s[e + 2] == c)) e++;
                j = MIN(n, e + 3);
            }
            put(emit, i, j, TokString); i = j; continue;
        }
        if (_l->mode == ModeYAML && (c == '&' || c == '*') && i + 1 < n && identChar(s[i + 1])) {   // &anchor *alias
            NSUInteger j = i + 1;
            while (j < n && !isSpace(s[j]) && s[j] != ',') j++;
            put(emit, i, j, TokConstant); i = j; continue;
        }
        if (_l->mode == ModeYAML && c == '!' ) {                                                   // !!str, !Ref
            NSUInteger j = i + 1;
            while (j < n && !isSpace(s[j])) j++;
            put(emit, i, j, TokType); i = j; continue;
        }
        if (_l->mode == ModeYAML && (c == '|' || c == '>')) {                                       // block scalar: | |- >+ |2
            NSUInteger j = i + 1;
            while (j < n && (s[j] == '-' || s[j] == '+' || isDigit(s[j]))) j++;
            NSUInteger k = skipSpace(s, j, n);
            if (k >= n || s[k] == '#') { put(emit, i, j, TokMeta); i = j; continue; }
        }
        if (c == '[' || c == ']' || c == '{' || c == '}' || c == ',') { i++; continue; }
        // a bare token up to whitespace / delimiter
        NSUInteger j = i;
        while (j < n && !isSpace(s[j]) && !(s[j] == ',' || s[j] == ']' || s[j] == '}') && !(s[j] == '#' && j > i && isSpace(s[j - 1]))) j++;
        if (j == i) { i++; continue; }
        BOOL inFlow = NO;                                                                          // { a = 1 } / {a: 1}
        for (NSUInteger k = 0; k < i; k++) if (s[k] == '{' || s[k] == '[') inFlow = YES;
        NSUInteger keyEnd = i;
        while (keyEnd < n && (identChar(s[keyEnd]) || s[keyEnd] == '-' || s[keyEnd] == '.')) keyEnd++;
        NSUInteger after = skipSpace(s, keyEnd, n);
        if (inFlow && keyEnd > i && after < n && (s[after] == '=' || (s[after] == ':' && _l->mode == ModeYAML))) {
            put(emit, i, keyEnd, TokProperty); i = after + 1; continue;
        }
        if (_l->mode == ModeYAML && s[j - 1] == ':' && j - 1 > i) j--;                             // "{a: 1}" -> key handled above
        NSString *w = word(s, i, j);
        BOOL number = isDigit(c) || ((c == '-' || c == '+' || c == '.') && j > i + 1 && isDigit(s[i + 1]));
        if ([_l->constants containsObject:w] || [_l->constants containsObject:w.lowercaseString]) put(emit, i, j, TokConstant);
        else if (number) put(emit, i, j, TokNumber);
        else if (_l->toml) put(emit, i, j, TokPlain);
        else if (ini) {                                                                            // INI: unquoted text runs to the comment
            NSUInteger e = j;
            while (e < n && !(s[e] == '#' && isSpace(s[e - 1])) && !(s[e] == ';' && isSpace(s[e - 1]))) e++;
            while (e > j && isSpace(s[e - 1])) e--;
            put(emit, i, e, TokString);
            j = e;
        } else {
            // YAML plain scalar: the rest of the line (up to a comment) is one string
            NSUInteger e = j;
            BOOL flow = NO;
            for (NSUInteger k = 0; k < i; k++) if (s[k] == '[' || s[k] == '{') flow = YES;
            if (!flow) { while (e < n && !(s[e] == '#' && isSpace(s[e - 1]))) e++; while (e > j && isSpace(s[e - 1])) e--; }
            put(emit, i, e, TokString);
            j = e;
        }
        i = j;
    }
}

- (void)yaml:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = skipSpace(s, 0, n);
    if (i >= n) return;
    if (s[i] == '#') { put(emit, i, n, TokComment); return; }
    if (i == 0 && n >= 3 && ((s[0] == '-' && s[1] == '-' && s[2] == '-') || (s[0] == '.' && s[1] == '.' && s[2] == '.'))) {
        put(emit, 0, 3, TokMeta); [self scalar:s from:3 length:n emit:emit]; return;
    }
    if (s[i] == '%') { put(emit, i, n, TokMeta); return; }                                         // %YAML 1.2
    while (i < n && s[i] == '-' && (i + 1 == n || isSpace(s[i + 1]))) {                           // list item(s)
        put(emit, i, i + 1, TokConstant);
        i = skipSpace(s, i + 1, n);
    }
    if (i >= n) return;
    // key: find ": " (or ":" at the end) outside quotes
    NSUInteger k = i;
    if (s[k] == '"' || s[k] == '\'') k = stringEnd(s, k, n);
    else while (k < n && !(s[k] == ':' && (k + 1 == n || isSpace(s[k + 1]))) && !(s[k] == '#' && k > 0 && isSpace(s[k - 1]))) k++;
    if (k < n && s[k] == ':' && (k + 1 == n || isSpace(s[k + 1])) && s[i] != '[' && s[i] != '{') {
        put(emit, i, k, TokProperty);
        [self scalar:s from:k + 1 length:n emit:emit];
        return;
    }
    [self scalar:s from:i length:n emit:emit];
}

- (void)ini:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = skipSpace(s, 0, n);
    if (i >= n) return;
    if (s[i] == '#' || s[i] == ';' || (s[i] == '!' && !_l->toml)) { put(emit, i, n, TokComment); return; }
    if (s[i] == '[') {                                                                             // [section] / [[array]]
        NSUInteger j = i;
        while (j < n && s[j] != ']') j++;
        while (j < n && s[j] == ']') j++;
        put(emit, i, j, TokTag);
        [self scalar:s from:j length:n emit:emit];
        return;
    }
    if (n - i > 7 && [word(s, i, i + 7) isEqualToString:@"export "]) { put(emit, i, i + 6, TokKeyword); i = skipSpace(s, i + 7, n); }   // .env
    NSUInteger k = i;
    while (k < n && s[k] != '=' && !(s[k] == ':' && !_l->toml)) {
        if (s[k] == '"' || s[k] == '\'') { k = stringEnd(s, k, n); continue; }
        k++;
    }
    if (k >= n) { [self scalar:s from:i length:n emit:emit]; return; }
    NSUInteger e = k;
    while (e > i && isSpace(s[e - 1])) e--;
    put(emit, i, e, TokProperty);
    [self scalar:s from:k + 1 length:n emit:emit];
}

#pragma mark CSS

// "prop: value" in [a, b).
- (void)cssDecl:(const unichar *)s from:(NSUInteger)a to:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = skipSpace(s, a, n);
    if (i >= n) return;
    NSUInteger colon = i;
    while (colon < n && s[colon] != ':') colon++;
    NSUInteger pe = colon;
    while (pe > i && isSpace(s[pe - 1])) pe--;
    BOOL var = s[i] == '$' || (s[i] == '-' && i + 1 < n && s[i + 1] == '-');
    put(emit, i, pe, var ? TokConstant : TokProperty);
    i = colon + 1;
    while (i < n) {
        unichar c = s[i];
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            NSUInteger j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
            j = MIN(n, j + 2);
            put(emit, i, j, TokComment); i = j; continue;
        }
        if (c == '/' && i + 1 < n && s[i + 1] == '/' && s[i - 1] != ':') { put(emit, i, n, TokComment); return; }
        if (c == '"' || c == '\'') { NSUInteger j = stringEnd(s, i, n); put(emit, i, j, TokString); i = j; continue; }
        if (c == '#' && i + 1 < n && identChar(s[i + 1])) {                                      // #1e66f5
            NSUInteger j = i + 1;
            while (j < n && identChar(s[j])) j++;
            put(emit, i, j, TokNumber); i = j; continue;
        }
        BOOL neg = c == '-' && i + 1 < n && isDigit(s[i + 1]) && !identChar(s[i - 1]);
        if (isDigit(c) || neg || (c == '.' && i + 1 < n && isDigit(s[i + 1]))) {
            NSUInteger j = numberEnd(s, i, n);
            put(emit, i, j, TokNumber); i = j; continue;
        }
        if (c == '!') { NSUInteger j = i + 1; while (j < n && identChar(s[j])) j++; put(emit, i, j, TokKeyword); i = j; continue; }
        if (c == '$' || c == '@' || (c == '-' && i + 1 < n && s[i + 1] == '-')) {                  // $var @var var(--x)
            NSUInteger j = i + 1;
            while (j < n && (identChar(s[j]) || s[j] == '-')) j++;
            put(emit, i, j, TokConstant); i = j; continue;
        }
        if (identStart(c)) {
            NSUInteger j = i + 1;
            while (j < n && (identChar(s[j]) || s[j] == '-')) j++;
            if (j < n && s[j] == '(') put(emit, i, j, TokFunction);                             // rgb( var( calc(
            i = j; continue;
        }
        i++;
    }
}

- (void)css:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = skipSpace(s, 0, n);
    if (i < n && s[i] == '*' && (i + 1 == n || s[i + 1] == ' ' || s[i + 1] == '/')) {           // inside /* */
        NSUInteger j = i;
        while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
        j = j + 1 < n ? j + 2 : n;
        put(emit, 0, j, TokComment); i = skipSpace(s, j, n);
    }
    if (i >= n) return;
    if (s[i] == '/' && i + 1 < n && s[i + 1] == '/') { put(emit, i, n, TokComment); return; }    // SCSS
    // A declaration: "prop: value" with no "{" — "a:hover {" and "li::before," are selectors.
    NSUInteger colon = NSNotFound;
    BOOL brace = NO;
    for (NSUInteger k = i; k < n; k++) {
        if (s[k] == '{') { brace = YES; break; }
        if (s[k] == ':' && colon == NSNotFound) colon = k;
    }
    BOOL looksDecl = colon != NSNotFound && !brace && (identStart(s[i]) || s[i] == '-' || s[i] == '$') &&
                     (colon + 1 >= n || isSpace(s[colon + 1]) || s[n - 1] == ';' || s[colon - 1] == ' ');
    if (looksDecl && s[n - 1] == ',' ) looksDecl = NO;
    if (looksDecl && s[i] != '@') {                                                              // "a: 1; b: 2"
        for (NSUInteger a = i, b = i; b <= n; b++)
            if (b == n || (s[b] == ';' && !(b + 1 < n && s[b + 1] == ';'))) { if (b > a) [self cssDecl:s from:a to:b emit:emit]; a = b + 1; }
        return;
    }
    while (i < n) {
        unichar c = s[i];
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            NSUInteger j = i + 2;
            while (j + 1 < n && !(s[j] == '*' && s[j + 1] == '/')) j++;
            j = MIN(n, j + 2);
            put(emit, i, j, TokComment); i = j; continue;
        }
        if (c == '"' || c == '\'') { NSUInteger j = stringEnd(s, i, n); put(emit, i, j, TokString); i = j; continue; }
        if (c == '@' && i + 1 < n && identStart(s[i + 1])) {                                     // @media @import
            NSUInteger j = i + 1;
            while (j < n && (identChar(s[j]) || s[j] == '-')) j++;
            put(emit, i, j, TokKeyword); i = j; continue;
        }
        if (c == '{') {                                                                           // "a { color: red; }"
            NSUInteger close = i + 1;
            while (close < n && s[close] != '}') close++;
            for (NSUInteger a = i + 1, b = i + 1; b <= close; b++)
                if (b == close || s[b] == ';') { if (b > a) [self cssDecl:s from:a to:b emit:emit]; a = b + 1; }
            i = close + 1; continue;
        }
        if (c == '}' || c == ',' || c == '>' || c == '+' || c == '~' || c == '(' || c == ')' || isSpace(c)) { i++; continue; }
        NSUInteger j = i + 1;
        if (c == '[') { while (j < n && s[j] != ']') j++; j = MIN(n, j + 1); put(emit, i, j, TokProperty); i = j; continue; }
        if (c == ':') { while (j < n && (s[j] == ':' || identChar(s[j]) || s[j] == '-')) j++; put(emit, i, j, TokKeyword); i = j; continue; }
        if (c == '&' || c == '*') { put(emit, i, j, TokKeyword); i = j; continue; }
        if (isDigit(c)) { j = numberEnd(s, i, n); put(emit, i, j, TokNumber); i = j; continue; }   // 50% in @keyframes
        while (j < n && (identChar(s[j]) || s[j] == '-')) j++;
        NSUInteger k = skipSpace(s, j, n);
        if (k < n && s[k] == ':' && c != '.' && c != '#') {                                      // @media (max-width: 600px)
            put(emit, i, j, TokProperty);
            NSUInteger e = k + 1;
            while (e < n && s[e] != ')' && s[e] != '{') e++;
            [self cssDecl:s from:i to:e emit:emit];
            i = e; continue;
        }
        put(emit, i, j, c == '.' || c == '#' ? TokType : TokTag);
        i = j;
    }
}

#pragma mark HTML / XML

- (void)markup:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = 0;
    NSUInteger close = NSNotFound, open = NSNotFound;                                            // a comment from earlier lines
    for (NSUInteger k = 0; k + 2 < n; k++) {
        if (open == NSNotFound && s[k] == '<' && k + 3 < n && s[k + 1] == '!' && s[k + 2] == '-' && s[k + 3] == '-') open = k;
        if (s[k] == '-' && s[k + 1] == '-' && s[k + 2] == '>') { close = k; break; }
    }
    if (close != NSNotFound && (open == NSNotFound || open > close)) { put(emit, 0, close + 3, TokComment); i = close + 3; }
    while (i < n) {
        unichar c = s[i];
        if (c == '<' && i + 3 < n && s[i + 1] == '!' && s[i + 2] == '-' && s[i + 3] == '-') {
            NSUInteger j = i + 4;
            while (j + 2 < n && !(s[j] == '-' && s[j + 1] == '-' && s[j + 2] == '>')) j++;
            j = j + 2 < n ? j + 3 : n;
            put(emit, i, j, TokComment); i = j; continue;
        }
        if (c == '<' && i + 1 < n && (s[i + 1] == '!' || s[i + 1] == '?')) {                    // <!DOCTYPE> <?xml ?>
            NSUInteger j = i + 2;
            while (j < n && s[j] != '>') j++;
            j = MIN(n, j + 1);
            put(emit, i, j, TokMeta); i = j; continue;
        }
        if (c == '<' && i + 1 < n && (identStart(s[i + 1]) || s[i + 1] == '/')) {
            NSUInteger nameStart = i + 1 + (s[i + 1] == '/'), j = nameStart;
            while (j < n && (identChar(s[j]) || s[j] == '-' || s[j] == ':' || s[j] == '.')) j++;
            put(emit, i, nameStart, TokMeta);
            put(emit, nameStart, j, TokTag);
            i = j;
            while (i < n && s[i] != '>') {                                                       // attributes
                if (s[i] == '"' || s[i] == '\'') { NSUInteger e = stringEnd(s, i, n); put(emit, i, e, TokString); i = e; continue; }
                if (s[i] == '/' && i + 1 < n && s[i + 1] == '>') break;
                if (identStart(s[i]) || s[i] == '@' || s[i] == ':' || s[i] == '#' || s[i] == '*' || s[i] == '[' || s[i] == '(') {
                    NSUInteger e = i + 1;                                                        // also Vue @click :prop, Angular [x] (y)
                    while (e < n && !isSpace(s[e]) && s[e] != '=' && s[e] != '>' && !(s[e] == '/' && e + 1 < n && s[e + 1] == '>')) e++;
                    put(emit, i, e, TokProperty); i = e; continue;
                }
                i++;
            }
            if (i < n) { NSUInteger e = MIN(n, s[i] == '/' ? i + 2 : i + 1); put(emit, i, e, TokMeta); i = e; }
            continue;
        }
        if (c == '&') {                                                                           // &amp; &#160;
            NSUInteger j = i + 1;
            while (j < n && j < i + 10 && (identChar(s[j]) || s[j] == '#')) j++;
            if (j < n && s[j] == ';' && j > i + 1) { put(emit, i, j + 1, TokConstant); i = j + 1; continue; }
        }
        if (identStart(c) && (i == 0 || isSpace(s[i - 1]))) {                                    // attribute lines of a multi-line tag
            NSUInteger e = i + 1;
            while (e < n && (identChar(s[e]) || s[e] == '-' || s[e] == ':' || s[e] == '.')) e++;
            if (e + 1 < n && s[e] == '=' && (s[e + 1] == '"' || s[e + 1] == '\'')) {
                put(emit, i, e, TokProperty);
                NSUInteger q = stringEnd(s, e + 1, n);
                put(emit, e + 1, q, TokString);
                i = q; continue;
            }
            i = e; continue;
        }
        i++;
    }
}

#pragma mark Markdown

// Closing run of `len` copies of d after i, not preceded by a space; NSNotFound if none.
static NSUInteger closing(const unichar *s, NSUInteger i, NSUInteger n, unichar d, NSUInteger len) {
    for (NSUInteger k = i; k + len <= n; k++) {
        BOOL hit = YES;
        for (NSUInteger m = 0; m < len; m++) if (s[k + m] != d) { hit = NO; break; }
        if (hit && k > i && !isSpace(s[k - 1]) && (k + len == n || s[k + len] != d)) return k;
    }
    return NSNotFound;
}

// Inline spans in [i, n). Later emits override earlier ones, so callers may colour a range first.
- (void)mdInline:(const unichar *)s from:(NSUInteger)i length:(NSUInteger)n emit:(Emit)emit {
    while (i < n) {
        unichar c = s[i];
        if (c == '\\' && i + 1 < n) { i += 2; continue; }
        if (c == '`') {                                                                           // `code`
            NSUInteger ticks = 1;
            while (i + ticks < n && s[i + ticks] == '`') ticks++;
            NSUInteger k = i + ticks;
            for (; k + ticks <= n; k++) {
                BOOL hit = YES;
                for (NSUInteger m = 0; m < ticks; m++) if (s[k + m] != '`') { hit = NO; break; }
                if (hit) break;
            }
            NSUInteger e = k + ticks <= n ? k + ticks : n;
            put(emit, i, e, TokString); i = e; continue;
        }
        if ((c == '*' || c == '_') && i + 1 < n && !(i > 0 && c == '_' && identChar(s[i - 1]))) {  // **strong** *em*, not snake_case
            NSUInteger len = s[i + 1] == c ? 2 : 1;
            if (i + len < n && !isSpace(s[i + len]) && s[i + len] != c) {
                NSUInteger k = closing(s, i + len, n, c, len);
                if (k != NSNotFound && !(c == '_' && k + len < n && identChar(s[k + len]))) {
                    put(emit, i, i + len, TokMeta);
                    put(emit, i + len, k, len == 2 ? TokStrong : TokEmphasis);
                    [self mdInline:s from:i + len length:k emit:^(NSRange r, TokenKind kk) { if (kk == TokString) emit(r, kk); }];
                    put(emit, k, k + len, TokMeta);
                    i = k + len; continue;
                }
            }
        }
        if (c == '~' && i + 1 < n && s[i + 1] == '~') {                                          // ~~struck~~
            NSUInteger k = closing(s, i + 2, n, '~', 2);
            if (k != NSNotFound) { put(emit, i, k + 2, TokComment); i = k + 2; continue; }
        }
        if (c == '[' || (c == '!' && i + 1 < n && s[i + 1] == '[')) {                            // [text](url) ![alt](src) [text][ref]
            NSUInteger open = c == '!' ? i + 1 : i, depth = 0, k = open;
            for (; k < n; k++) { if (s[k] == '[') depth++; else if (s[k] == ']' && --depth == 0) break; }
            if (k + 1 < n && (s[k + 1] == '(' || s[k + 1] == '[')) {
                unichar o = s[k + 1], endc = o == '(' ? ')' : ']';
                NSUInteger e = k + 2, d2 = 1;
                for (; e < n; e++) { if (s[e] == o) d2++; else if (s[e] == endc && --d2 == 0) break; }
                put(emit, i, open + 1, TokMeta);
                put(emit, open + 1, k, TokFunction);
                [self mdInline:s from:open + 1 length:k emit:emit];                              // badges: [![img](a)](b)
                put(emit, k, k + 2, TokMeta);
                put(emit, k + 2, MIN(e, n), TokComment);                                          // the URL stays quiet
                put(emit, e, MIN(n, e + 1), TokMeta);
                i = MIN(n, e + 1); continue;
            }
            if (k + 1 < n && s[k + 1] == ':' && i == skipSpace(s, 0, n)) {                       // [ref]: https://…
                put(emit, i, k + 2, TokFunction);
                put(emit, k + 2, n, TokComment);
                return;
            }
        }
        if (c == '<' && i + 1 < n && (identStart(s[i + 1]) || s[i + 1] == '/' || s[i + 1] == '!')) {   // <https://…> or raw HTML
            NSUInteger e = i + 1;
            while (e < n && s[e] != '>') e++;
            if (e < n) {
                BOOL url = NO;
                for (NSUInteger q = i + 1; q + 2 < e; q++) if (s[q] == ':' && s[q + 1] == '/' && s[q + 2] == '/') url = YES;
                if (url) put(emit, i, e + 1, TokComment);
                else [self markup:s + i length:e + 1 - i emit:^(NSRange r, TokenKind k) { emit(NSMakeRange(r.location + i, r.length), k); }];
                i = e + 1; continue;
            }
        }
        i++;
    }
}

- (void)markdown:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    NSUInteger i = skipSpace(s, 0, n);
    if (i >= n) return;
    unichar c = s[i];
    if ((c == '`' || c == '~') && i + 2 < n && s[i + 1] == c && s[i + 2] == c) {               // ```lang
        NSUInteger j = i;
        while (j < n && s[j] == c) j++;
        put(emit, i, j, TokMeta);
        put(emit, skipSpace(s, j, n), n, TokType);
        return;
    }
    if (c == '#') {                                                                               // # Heading
        NSUInteger j = i;
        while (j < n && s[j] == '#') j++;
        if (j - i <= 6 && (j == n || isSpace(s[j]))) {
            put(emit, i, j, TokMeta);
            put(emit, j, n, TokHeading);
            [self mdInline:s from:j length:n emit:^(NSRange r, TokenKind k) { if (k == TokString || k == TokComment) emit(r, k); }];
            return;
        }
    }
    if (c == '-' || c == '*' || c == '_' || c == '=') {                                          // --- *** ___ and === underline
        NSUInteger count = 0;
        BOOL rule = YES;
        for (NSUInteger k = i; k < n; k++) { if (s[k] == c) count++; else if (!isSpace(s[k])) { rule = NO; break; } }
        if (rule && count >= 3) { put(emit, i, n, TokMeta); return; }
    }
    if (c == '>') {                                                                               // > quote
        NSUInteger j = i;
        while (j < n && (s[j] == '>' || isSpace(s[j]))) j++;
        put(emit, i, j, TokMeta);
        put(emit, j, n, TokEmphasis);
        [self mdInline:s from:j length:n emit:emit];
        return;
    }
    NSUInteger after = i;
    if ((c == '-' || c == '*' || c == '+') && i + 1 < n && isSpace(s[i + 1])) after = i + 1;      // - item
    else if (isDigit(c)) {                                                                        // 1. item
        NSUInteger j = i;
        while (j < n && isDigit(s[j])) j++;
        if (j < n && (s[j] == '.' || s[j] == ')') && (j + 1 == n || isSpace(s[j + 1]))) after = j + 1;
    }
    if (after > i) {
        put(emit, i, after, TokConstant);
        NSUInteger t = skipSpace(s, after, n);
        if (t + 2 < n && s[t] == '[' && s[t + 2] == ']' && (s[t + 1] == ' ' || s[t + 1] == 'x' || s[t + 1] == 'X')) {
            put(emit, t, t + 3, TokKeyword);                                                      // - [ ] task
            t += 3;
        }
        [self mdInline:s from:t length:n emit:emit];
        return;
    }
    if (c == '|') {                                                                               // table
        BOOL separator = YES;
        for (NSUInteger k = i; k < n; k++) if (!(s[k] == '|' || s[k] == '-' || s[k] == ':' || isSpace(s[k]))) { separator = NO; break; }
        if (separator) { put(emit, i, n, TokMeta); return; }
        for (NSUInteger k = i; k < n; k++) if (s[k] == '|' && (k == 0 || s[k - 1] != '\\')) put(emit, k, k + 1, TokMeta);
    }
    [self mdInline:s from:i length:n emit:emit];
}

#pragma mark Diff

- (void)diff:(const unichar *)s length:(NSUInteger)n emit:(Emit)emit {
    unichar c = s[0];
    BOOL header = n >= 3 && ((c == '+' && s[1] == '+' && s[2] == '+') || (c == '-' && s[1] == '-' && s[2] == '-'));
    if (header || (n >= 5 && [word(s, 0, 5) isEqualToString:@"diff "]) || (n >= 6 && [word(s, 0, 6) isEqualToString:@"index "])) {
        put(emit, 0, n, TokMeta); return;
    }
    if (c == '@' && n > 1 && s[1] == '@') {                                                       // @@ -1,3 +1,4 @@ func
        NSUInteger j = 2;
        while (j + 1 < n && !(s[j] == '@' && s[j + 1] == '@')) j++;
        j = MIN(n, j + 2);
        put(emit, 0, j, TokFunction);
        put(emit, j, n, TokComment);
        return;
    }
    if (c == '+') put(emit, 0, n, TokInserted);
    else if (c == '-') put(emit, 0, n, TokDeleted);
    else if (c == '\\') put(emit, 0, n, TokComment);                                            // \ No newline at end of file
}

- (void)tokenize:(NSString *)line emit:(void (^)(NSRange, TokenKind))emit {
    NSUInteger n = MIN(line.length, kMaxHighlight);
    if (!n) return;
    unichar stackBuf[512];
    unichar *s = n <= 512 ? stackBuf : malloc(n * sizeof(unichar));
    [line getCharacters:s range:NSMakeRange(0, n)];
    switch (_l->mode) {
        case ModeCode:     [self code:s length:n emit:emit]; break;
        case ModeJSON:     [self json:s length:n emit:emit]; break;
        case ModeYAML:     [self yaml:s length:n emit:emit]; break;
        case ModeINI:      [self ini:s length:n emit:emit]; break;
        case ModeCSS:      [self css:s length:n emit:emit]; break;
        case ModeMarkup:   [self markup:s length:n emit:emit]; break;
        case ModeMarkdown: [self markdown:s length:n emit:emit]; break;
        case ModeDiff:     [self diff:s length:n emit:emit]; break;
        case ModeHashOnly: { NSUInteger i = skipSpace(s, 0, n); if (i < n && s[i] == '#') put(emit, i, n, TokComment); else if (i < n && s[i] == '!') put(emit, i, i + 1, TokKeyword); break; }
    }
    if (s != stackBuf) free(s);
}

@end

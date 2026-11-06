#import "Markdown.h"

NSString *MDNormLabel(NSString *s);

@implementation MDInline
+ (instancetype)text:(NSString *)s { MDInline *n = [MDInline new]; n.type = MDText; n.text = s; return n; }
@end

static BOOL isPunct(unichar c) {
    return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~') ||
           (c > 127 && [NSCharacterSet.punctuationCharacterSet characterIsMember:c]);
}
static BOOL isSpace(unichar c) { return c == 0 || c == ' ' || c == '\n' || c == '\t' || (c > 127 && [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]); }

@interface MDDelim : NSObject
@property (nonatomic, strong) MDInline *node;
@property (nonatomic) unichar ch;
@property (nonatomic) NSUInteger len, origLen;
@property (nonatomic) BOOL canOpen, canClose;
@end
@implementation MDDelim @end

@interface MDBracket : NSObject
@property (nonatomic, strong) MDInline *node;
@property (nonatomic) BOOL image, active;
@property (nonatomic) NSUInteger delimDepth, textStart;    // textStart: index after '[' in the source
@end
@implementation MDBracket @end

@interface MDInlineParser : NSObject {
@public
    unichar *s; NSUInteger n, i;
    NSDictionary *refs;
    NSMutableArray<MDInline *> *nodes;
    NSMutableArray<MDDelim *> *delims;
    NSMutableArray<MDBracket *> *brackets;
    NSMutableString *buf;
}
@end

@implementation MDInlineParser

- (void)flush {
    if (!buf.length) return;
    [nodes addObject:[MDInline text:[buf copy]]];
    [buf setString:@""];
}

- (void)add:(MDInline *)x { [self flush]; [nodes addObject:x]; }

- (NSString *)sub:(NSUInteger)a to:(NSUInteger)b { return [NSString stringWithCharacters:s + a length:b - a]; }

static NSString *unescape(NSString *t) {
    if ([t rangeOfString:@"\\"].location == NSNotFound) return t;
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger k = 0; k < t.length; k++) {
        unichar c = [t characterAtIndex:k];
        if (c == '\\' && k + 1 < t.length && isPunct([t characterAtIndex:k + 1])) c = [t characterAtIndex:++k];
        [o appendFormat:@"%C", c];
    }
    return o;
}

static NSString *entity(NSString *name) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"", @"apos": @"'", @"nbsp": @"\u00a0", @"copy": @"©",
              @"reg": @"®", @"trade": @"™", @"mdash": @"—", @"ndash": @"–", @"hellip": @"…", @"larr": @"←",
              @"rarr": @"→", @"uarr": @"↑", @"darr": @"↓", @"times": @"×", @"middot": @"·", @"bull": @"•",
              @"laquo": @"«", @"raquo": @"»", @"ldquo": @"“", @"rdquo": @"”", @"lsquo": @"‘", @"rsquo": @"’", @"emsp": @"\u2003"};
    });
    if ([name hasPrefix:@"#"]) {
        BOOL hex = name.length > 1 && ([name characterAtIndex:1] == 'x' || [name characterAtIndex:1] == 'X');
        unsigned long long v = strtoull([name substringFromIndex:hex ? 2 : 1].UTF8String, NULL, hex ? 16 : 10);
        if (!v || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) return @"\uFFFD";
        UTF32Char c = (UTF32Char)v;
        return [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
    }
    return m[name];
}

// Parses "(dest "title")" at i (pointing at '('). On success advances i past ')'.
- (BOOL)inlineDest:(NSString **)url title:(NSString **)title {
    NSUInteger k = i + 1;
    while (k < n && isSpace(s[k])) k++;
    NSUInteger ds = k;
    NSString *dest;
    if (k < n && s[k] == '<') {
        k++; ds = k;
        while (k < n && s[k] != '>' && s[k] != '\n') { if (s[k] == '\\') k++; k++; }
        if (k >= n || s[k] != '>') return NO;
        dest = [self sub:ds to:k]; k++;
    } else {
        NSInteger depth = 0;
        while (k < n && !isSpace(s[k])) {
            if (s[k] == '\\' && k + 1 < n) { k += 2; continue; }
            if (s[k] == '(') depth++;
            if (s[k] == ')') { if (depth == 0) break; depth--; }
            k++;
        }
        dest = [self sub:ds to:k];
    }
    while (k < n && isSpace(s[k])) k++;
    NSString *t = @"";
    if (k < n && (s[k] == '"' || s[k] == '\'' || s[k] == '(')) {
        unichar close = s[k] == '(' ? ')' : s[k];
        NSUInteger ts = ++k;
        while (k < n && s[k] != close) { if (s[k] == '\\') k++; k++; }
        if (k >= n) return NO;
        t = [self sub:ts to:k]; k++;
        while (k < n && isSpace(s[k])) k++;
    }
    if (k >= n || s[k] != ')') return NO;
    *url = unescape(dest); *title = unescape(t);
    i = k + 1;
    return YES;
}

static inline BOOL asciiAlnum(unichar c) { return (c >= '0' && c <= '9') || ((c | 32) >= 'a' && (c | 32) <= 'z'); }
static inline BOOL special(unichar c) {
    return c == '\\' || c == '`' || c == '*' || c == '_' || c == '~' || c == '!' || c == '[' || c == ']' ||
           c == '<' || c == '&' || c == '\n' || (c | 32) == 'h' || (c | 32) == 'w';
}

static NSArray<MDInline *> *mergeText(NSArray<MDInline *> *a) {
    NSMutableArray *o = [NSMutableArray arrayWithCapacity:a.count];
    for (MDInline *x in a) {
        if (x.type == MDText && !x.text.length) continue;
        MDInline *last = o.lastObject;
        if (x.type == MDText && last && last.type == MDText) { o[o.count - 1] = [MDInline text:[last.text stringByAppendingString:x.text]]; continue; }
        [o addObject:x];
    }
    return o;
}

static MDInline *node(MDInlineType t) { MDInline *x = [MDInline new]; x.type = t; return x; }

static void processEmphasis(NSMutableArray<MDInline *> *nodes, NSMutableArray<MDDelim *> *delims) {
    NSUInteger ci = 0;
    while (ci < delims.count) {
        MDDelim *closer = delims[ci];
        if (!closer.canClose || !closer.len) { ci++; continue; }
        NSInteger oi = (NSInteger)ci - 1;
        MDDelim *opener = nil;
        for (; oi >= 0; oi--) {
            MDDelim *o = delims[oi];
            if (o.ch != closer.ch || !o.canOpen || !o.len) continue;
            if (closer.ch == '~' && o.len != closer.len) continue;
            if (closer.ch != '~' && (o.canClose || closer.canOpen) && (o.origLen + closer.origLen) % 3 == 0 &&
                !(o.origLen % 3 == 0 && closer.origLen % 3 == 0)) continue;
            opener = o;
            break;
        }
        if (!opener) { ci++; continue; }
        NSUInteger a = [nodes indexOfObjectIdenticalTo:opener.node], b = [nodes indexOfObjectIdenticalTo:closer.node];
        if (a == NSNotFound || b == NSNotFound || b <= a) { ci++; continue; }
        NSUInteger use = closer.ch == '~' ? closer.len : (opener.len >= 2 && closer.len >= 2 ? 2 : 1);
        MDInline *wrap = node(closer.ch == '~' ? MDStrike : (use == 2 ? MDStrong : MDEmph));
        wrap.children = mergeText([nodes subarrayWithRange:NSMakeRange(a + 1, b - a - 1)]);
        [nodes replaceObjectsInRange:NSMakeRange(a + 1, b - a - 1) withObjectsFromArray:@[wrap]];
        opener.len -= use; closer.len -= use;
        opener.node.text = [opener.node.text substringToIndex:opener.len];
        closer.node.text = [closer.node.text substringToIndex:closer.len];
        [delims removeObjectsInRange:NSMakeRange(oi + 1, ci - oi - 1)];
        ci = oi + 1;
        if (!opener.len) { [nodes removeObjectIdenticalTo:opener.node]; [delims removeObjectAtIndex:oi]; ci--; }
        if (!closer.len) { [nodes removeObjectIdenticalTo:closer.node]; [delims removeObjectAtIndex:ci]; }
    }
}

- (void)codeSpan {
    NSUInteger k = i;
    while (k < n && s[k] == '`') k++;
    NSUInteger run = k - i, j = k;
    while (j < n) {
        if (s[j] != '`') { j++; continue; }
        NSUInteger e = j;
        while (e < n && s[e] == '`') e++;
        if (e - j == run) {
            NSString *code = [[self sub:k to:j] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            if (code.length >= 2 && [code hasPrefix:@" "] && [code hasSuffix:@" "] &&
                [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length)
                code = [code substringWithRange:NSMakeRange(1, code.length - 2)];
            MDInline *x = node(MDCodeSpan); x.text = code;
            [self add:x];
            i = e;
            return;
        }
        j = e;
    }
    [buf appendString:[self sub:i to:k]];
    i = k;
}

- (void)delimRun {
    unichar c = s[i];
    NSUInteger k = i;
    while (k < n && s[k] == c) k++;
    NSUInteger len = k - i;
    if (c == '~' && len > 2) { [buf appendString:[self sub:i to:k]]; i = k; return; }
    unichar before = i > 0 ? s[i - 1] : 0, after = k < n ? s[k] : 0;
    BOOL lf = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before));
    BOOL rf = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after));
    BOOL canOpen = lf, canClose = rf;
    if (c == '_') { canOpen = lf && (!rf || isPunct(before)); canClose = rf && (!lf || isPunct(after)); }
    MDInline *t = [MDInline text:[self sub:i to:k]];
    [self add:t];
    if (canOpen || canClose) {
        MDDelim *d = [MDDelim new];
        d.node = t; d.ch = c; d.len = d.origLen = len; d.canOpen = canOpen; d.canClose = canClose;
        [delims addObject:d];
    }
    i = k;
}

- (void)openBracket:(BOOL)image {
    NSUInteger len = image ? 2 : 1;
    MDInline *t = [MDInline text:image ? @"![" : @"["];
    [self add:t];
    MDBracket *b = [MDBracket new];
    b.node = t; b.image = image; b.active = YES; b.delimDepth = delims.count; b.textStart = i + len;
    [brackets addObject:b];
    i += len;
}

- (void)closeBracket {
    MDBracket *op = brackets.lastObject;
    NSUInteger labelEnd = i;
    i++;
    NSUInteger after = i;
    if (!op || !op.active) { if (op) [brackets removeLastObject]; [buf appendString:@"]"]; return; }
    NSString *url = nil, *title = @"";
    BOOL ok = i < n && s[i] == '(' && [self inlineDest:&url title:&title];
    if (!ok) {
        i = after;
        NSString *own = [self sub:op.textStart to:labelEnd], *label = own;
        NSUInteger resume = after;
        if (i < n && s[i] == '[') {
            NSUInteger k = i + 1;
            while (k < n && s[k] != ']' && s[k] != '[') { if (s[k] == '\\') k++; k++; }
            if (k < n && s[k] == ']') {
                NSString *l = [self sub:i + 1 to:k];
                if (l.length) label = l;
                resume = k + 1;
            }
        }
        NSArray *ref = refs[MDNormLabel(label)];
        if (!ref && ![label isEqualToString:own]) { ref = refs[MDNormLabel(own)]; resume = after; }
        if (ref) { url = ref[0]; title = ref[1]; ok = YES; i = resume; }
    }
    if (!ok) { [brackets removeLastObject]; [buf appendString:@"]"]; i = after; return; }
    [self flush];
    NSUInteger at = [nodes indexOfObjectIdenticalTo:op.node];
    NSMutableArray *inner = [[nodes subarrayWithRange:NSMakeRange(at + 1, nodes.count - at - 1)] mutableCopy];
    NSRange dr = NSMakeRange(op.delimDepth, delims.count - op.delimDepth);
    NSMutableArray *innerDelims = [[delims subarrayWithRange:dr] mutableCopy];
    processEmphasis(inner, innerDelims);
    [delims removeObjectsInRange:dr];
    MDInline *ln = node(op.image ? MDImage : MDLink);
    ln.url = url; ln.title = title; ln.children = mergeText(inner);
    if (op.image) ln.text = MDPlainText(ln.children);
    [nodes removeObjectsInRange:NSMakeRange(at, nodes.count - at)];
    [nodes addObject:ln];
    [brackets removeLastObject];
    if (!op.image) for (MDBracket *b in brackets) if (!b.image) b.active = NO;
}

- (BOOL)angle {
    NSUInteger k = i + 1, e = k;
    while (e < n && s[e] != '>' && s[e] != '<' && !isSpace(s[e])) e++;
    if (e < n && s[e] == '>' && e > k) {
        NSString *t = [self sub:k to:e];
        NSRange colon = [t rangeOfString:@":"];
        BOOL scheme = colon.location != NSNotFound && colon.location >= 2 && colon.location <= 32 && asciiAlnum([t characterAtIndex:0]);
        for (NSUInteger q = 0; scheme && q < colon.location; q++) {
            unichar c = [t characterAtIndex:q];
            if (!asciiAlnum(c) && c != '+' && c != '.' && c != '-') scheme = NO;
        }
        NSUInteger at = [t rangeOfString:@"@"].location;
        BOOL email = !scheme && at != NSNotFound && at > 0 && [t rangeOfString:@"." options:0 range:NSMakeRange(at, t.length - at)].location != NSNotFound;
        if (scheme || email) {
            MDInline *ln = node(MDLink);
            ln.url = email ? [@"mailto:" stringByAppendingString:t] : t;
            ln.children = @[[MDInline text:t]];
            [self add:ln];
            i = e + 1;
            return YES;
        }
    }
    if (k + 2 < n && s[k] == '!' && s[k + 1] == '-' && s[k + 2] == '-') {
        for (NSUInteger q = k + 3; q + 2 < n; q++) {
            if (s[q] == '-' && s[q + 1] == '-' && s[q + 2] == '>') {
                MDInline *r = node(MDRawHTML); r.text = [self sub:i to:q + 3];
                [self add:r];
                i = q + 3;
                return YES;
            }
        }
        return NO;
    }
    NSUInteger t = k;
    if (t < n && s[t] == '/') t++;
    if (t >= n || !((s[t] | 32) >= 'a' && (s[t] | 32) <= 'z')) return NO;
    while (t < n && (asciiAlnum(s[t]) || s[t] == '-')) t++;
    unichar q = 0;
    for (; t < n; t++) {
        if (q) { if (s[t] == q) q = 0; continue; }
        if (s[t] == '"' || s[t] == '\'') q = s[t];
        else if (s[t] == '>') break;
        else if (s[t] == '<') return NO;
    }
    if (t >= n) return NO;
    MDInline *r = node(MDRawHTML); r.text = [self sub:i to:t + 1];
    [self add:r];
    i = t + 1;
    return YES;
}

- (BOOL)entityRef {
    NSUInteger k = i + 1;
    while (k < n && k - i < 32 && (asciiAlnum(s[k]) || s[k] == '#')) k++;
    if (k >= n || s[k] != ';' || k == i + 1) return NO;
    NSString *v = entity([self sub:i + 1 to:k]);
    if (!v) return NO;
    [buf appendString:v];
    i = k + 1;
    return YES;
}

- (void)newline {
    NSUInteger sp = 0;
    while (sp < buf.length && [buf characterAtIndex:buf.length - 1 - sp] == ' ') sp++;
    if (sp) [buf deleteCharactersInRange:NSMakeRange(buf.length - sp, sp)];
    [self add:node(sp >= 2 ? MDHardBreak : MDSoftBreak)];
    i++;
    while (i < n && s[i] == ' ') i++;
}

- (BOOL)bareURL {
    if (i > 0 && (asciiAlnum(s[i - 1]) || s[i - 1] > 127)) return NO;
    NSString *head = [self sub:i to:MIN(n, i + 8)].lowercaseString;
    NSUInteger pre = [head hasPrefix:@"https://"] ? 8 : [head hasPrefix:@"http://"] ? 7 : [head hasPrefix:@"www."] ? 4 : 0;
    if (!pre) return NO;
    NSUInteger k = i + pre;
    while (k < n && !isSpace(s[k]) && s[k] != '<' && s[k] != '[' && s[k] != ']' && s[k] != '`') k++;
    while (k > i + pre) {
        unichar e = s[k - 1];
        if (strchr(".,:;!?\"'*_~", e) && e < 128) { k--; continue; }
        if (e == ')') {
            NSInteger bal = 0;
            for (NSUInteger q = i; q < k; q++) bal += s[q] == '(' ? 1 : s[q] == ')' ? -1 : 0;
            if (bal < 0) { k--; continue; }
        }
        break;
    }
    if (k <= i + pre) return NO;
    NSString *t = [self sub:i to:k];
    MDInline *ln = node(MDLink);
    ln.url = pre == 4 ? [@"http://" stringByAppendingString:t] : t;
    ln.children = @[[MDInline text:t]];
    [self add:ln];
    i = k;
    return YES;
}

- (void)scan {
    while (i < n) {
        unichar c = s[i];
        switch (c) {
            case '\\':
                if (i + 1 < n && s[i + 1] == '\n') {
                    [self add:node(MDHardBreak)];
                    i += 2;
                    while (i < n && s[i] == ' ') i++;
                } else if (i + 1 < n && isPunct(s[i + 1])) { [buf appendFormat:@"%C", s[i + 1]]; i += 2; }
                else { [buf appendString:@"\\"]; i++; }
                continue;
            case '`': [self codeSpan]; continue;
            case '*': case '_': case '~': [self delimRun]; continue;
            case '!':
                if (i + 1 < n && s[i + 1] == '[') [self openBracket:YES];
                else { [buf appendString:@"!"]; i++; }
                continue;
            case '[': [self openBracket:NO]; continue;
            case ']': [self closeBracket]; continue;
            case '<': if (![self angle]) { [buf appendString:@"<"]; i++; } continue;
            case '&': if (![self entityRef]) { [buf appendString:@"&"]; i++; } continue;
            case '\n': [self newline]; continue;
            default:
                if (((c | 32) == 'h' || (c | 32) == 'w') && [self bareURL]) continue;
                NSUInteger k = i + 1;
                while (k < n && !special(s[k])) k++;
                [buf appendString:[self sub:i to:k]];
                i = k;
        }
    }
    [self flush];
}

@end

NSArray<MDInline *> *MDParseInline(NSString *str, NSDictionary *refs) {
    MDInlineParser *p = [MDInlineParser new];
    p->n = str.length;
    p->s = malloc(MAX((NSUInteger)1, p->n) * sizeof(unichar));
    [str getCharacters:p->s range:NSMakeRange(0, p->n)];
    p->refs = refs ?: @{};
    p->nodes = [NSMutableArray array];
    p->delims = [NSMutableArray array];
    p->brackets = [NSMutableArray array];
    p->buf = [NSMutableString string];
    [p scan];
    processEmphasis(p->nodes, p->delims);
    NSArray *r = mergeText(p->nodes);
    free(p->s);
    return r;
}

NSString *MDPlainText(NSArray<MDInline *> *a) {
    NSMutableString *o = [NSMutableString string];
    for (MDInline *x in a) {
        switch (x.type) {
            case MDText: case MDCodeSpan: [o appendString:x.text ?: @""]; break;
            case MDImage: [o appendString:x.text ?: @""]; break;
            case MDSoftBreak: case MDHardBreak: [o appendString:@" "]; break;
            case MDRawHTML: break;
            default: [o appendString:MDPlainText(x.children)];
        }
    }
    return o;
}

NSString *MDSlug(NSString *heading) {
    NSMutableString *o = [NSMutableString string];
    NSString *l = heading.lowercaseString;
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    [l enumerateSubstringsInRange:NSMakeRange(0, l.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        unichar c = [ch characterAtIndex:0];
        if (c == ' ') [o appendString:@"-"];
        else if (c == '-' || c == '_' || (ch.length == 1 && [keep characterIsMember:c])) [o appendString:ch];
    }];
    return o;
}

static NSString *esc(NSString *s) {
    return [[[[s ?: @"" stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
              stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
             stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

static void htmlInlines(NSMutableString *o, NSArray<MDInline *> *a) {
    for (MDInline *x in a) {
        switch (x.type) {
            case MDText: [o appendString:esc(x.text)]; break;
            case MDCodeSpan: [o appendFormat:@"<code>%@</code>", esc(x.text)]; break;
            case MDEmph: [o appendString:@"<em>"]; htmlInlines(o, x.children); [o appendString:@"</em>"]; break;
            case MDStrong: [o appendString:@"<strong>"]; htmlInlines(o, x.children); [o appendString:@"</strong>"]; break;
            case MDStrike: [o appendString:@"<del>"]; htmlInlines(o, x.children); [o appendString:@"</del>"]; break;
            case MDLink: [o appendFormat:@"<a href=\"%@\">", esc(x.url)]; htmlInlines(o, x.children); [o appendString:@"</a>"]; break;
            case MDImage: [o appendFormat:@"<img src=\"%@\" alt=\"%@\">", esc(x.url), esc(x.text)]; break;
            case MDHardBreak: [o appendString:@"<br>"]; break;
            case MDSoftBreak: [o appendString:@"\n"]; break;
            case MDRawHTML: [o appendString:x.text]; break;
        }
    }
}

static void htmlBlocks(NSMutableString *o, NSArray<MDBlock *> *bs, MDDocument *d, BOOL tight) {
    for (MDBlock *b in bs) {
        switch (b.type) {
            case MDParagraph:
                if (!tight) [o appendString:@"<p>"];
                htmlInlines(o, [d inlines:b.text]);
                if (!tight) [o appendString:@"</p>"];
                break;
            case MDHeading: [o appendFormat:@"<h%ld>", (long)b.level]; htmlInlines(o, [d inlines:b.text]); [o appendFormat:@"</h%ld>", (long)b.level]; break;
            case MDCode:
                [o appendString:b.info.length ? [NSString stringWithFormat:@"<pre lang=\"%@\">", esc(b.info)] : @"<pre>"];
                [o appendFormat:@"%@</pre>", esc(b.text)];
                break;
            case MDQuote: [o appendString:@"<blockquote>"]; htmlBlocks(o, b.children, d, NO); [o appendString:@"</blockquote>"]; break;
            case MDList:
                [o appendString:b.ordered ? (b.start != 1 ? [NSString stringWithFormat:@"<ol start=\"%ld\">", (long)b.start] : @"<ol>") : @"<ul>"];
                for (MDBlock *it in b.children) {
                    [o appendString:@"<li>"];
                    if (it.task >= 0) [o appendString:it.task ? @"[x] " : @"[ ] "];
                    htmlBlocks(o, it.children, d, b.tight);
                    [o appendString:@"</li>"];
                }
                [o appendString:b.ordered ? @"</ol>" : @"</ul>"];
                break;
            case MDItem: htmlBlocks(o, b.children, d, tight); break;
            case MDRule: [o appendString:@"<hr>"]; break;
            case MDTable:
                [o appendString:@"<table>"];
                for (NSUInteger r = 0; r < b.rows.count; r++) {
                    [o appendString:@"<tr>"];
                    for (NSUInteger c = 0; c < b.rows[r].count; c++) {
                        NSString *tag = r ? @"td" : @"th";
                        MDAlign al = [b.align[c] integerValue];
                        NSString *a = al == MDAlignCenter ? @" align=\"center\"" : al == MDAlignRight ? @" align=\"right\"" : al == MDAlignLeft ? @" align=\"left\"" : @"";
                        [o appendFormat:@"<%@%@>", tag, a];
                        htmlInlines(o, [d inlines:[b.rows[r][c] stringByReplacingOccurrencesOfString:@"\\|" withString:@"|"]]);
                        [o appendFormat:@"</%@>", tag];
                    }
                    [o appendString:@"</tr>"];
                }
                [o appendString:@"</table>"];
                break;
            case MDHTMLBlock: [o appendString:b.text]; break;
        }
    }
}

NSString *MDRenderHTML(MDDocument *d) {
    NSMutableString *o = [NSMutableString string];
    htmlBlocks(o, d.blocks, d, NO);
    return o;
}

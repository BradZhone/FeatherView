#import "Markdown.h"

NSString *MDNormLabel(NSString *s);

static const NSUInteger kMaxInlineDepth = 32;          // deeper emphasis / links stay literal text
static const NSUInteger kMaxLabel = 999;                // CommonMark's limit for a link label

@interface MDInline ()
@property (nonatomic) NSUInteger depth;                 // nesting below this node
@end

@implementation MDInline
+ (instancetype)text:(NSString *)s { MDInline *n = [MDInline new]; n.type = MDText; n.text = s; return n; }
@end

static NSUInteger depthOf(NSArray<MDInline *> *children) {
    NSUInteger d = 0;
    for (MDInline *x in children) d = MAX(d, x.depth + 1);
    return d;
}

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
    NSUInteger linkFloor;                                // brackets below this index are inside a link: inactive
    NSMutableString *buf;
    // Positions from which a scan is known to fail, so repeated unclosed constructs stay linear.
    NSMutableDictionary<NSNumber *, NSNumber *> *noCodeRun;   // backtick run length → no closing run at or after
    NSUInteger noDestFrom, noCommentFrom, noQuoteFrom[3];
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
        if (k >= noDestFrom) return NO;
        NSInteger depth = 0;
        BOOL closer = NO;
        while (k < n && !isSpace(s[k])) {
            if (s[k] == '\\' && k + 1 < n) { k += 2; continue; }
            if (s[k] == '(') depth++;
            if (s[k] == ')') { closer = YES; if (depth == 0) break; depth--; }
            k++;
        }
        if (k >= n && !closer) noDestFrom = MIN(noDestFrom, ds);     // no space and no ")" to the end
        dest = [self sub:ds to:k];
    }
    while (k < n && isSpace(s[k])) k++;
    NSString *t = @"";
    if (k < n && (s[k] == '"' || s[k] == '\'' || s[k] == '(')) {
        unichar close = s[k] == '(' ? ')' : s[k];
        int qi = close == '"' ? 0 : close == '\'' ? 1 : 2;
        NSUInteger ts = ++k;
        if (ts >= noQuoteFrom[qi]) return NO;
        while (k < n && s[k] != close) { if (s[k] == '\\') k++; k++; }
        if (k >= n) { noQuoteFrom[qi] = MIN(noQuoteFrom[qi], ts); return NO; }
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
    NSMutableString *run = nil;
    for (MDInline *x in a) {
        if (x.type == MDText) { if (x.text.length) { if (!run) run = [NSMutableString string]; [run appendString:x.text]; } continue; }
        if (run) { [o addObject:[MDInline text:run]]; run = nil; }
        [o addObject:x];
    }
    if (run) [o addObject:[MDInline text:run]];
    return o;
}

static MDInline *node(MDInlineType t) { MDInline *x = [MDInline new]; x.type = t; return x; }

static BOOL canPair(MDDelim *o, MDDelim *c) {
    if (o.ch != c.ch || !o.canOpen || !o.len) return NO;
    if (c.ch == '~') return o.len == c.len;
    return !((o.canClose || c.canOpen) && (o.origLen + c.origLen) % 3 == 0 && !(o.origLen % 3 == 0 && c.origLen % 3 == 0));
}

// CommonMark's "process emphasis", as in cmark: nodes and delimiters are linked lists, and for each kind of
// closer the position below which no opener can match is remembered, so the work stays linear.
static void processEmphasis(NSMutableArray<MDInline *> *nodes, NSMutableArray<MDDelim *> *delims) {
    NSUInteger nd = delims.count;
    if (!nd) return;
    NSMutableArray<MDInline *> *cells = [nodes mutableCopy];          // cell id → node; wraps are appended
    NSUInteger cap = nodes.count + 1;
    for (MDDelim *d in delims) cap += d.len;
    NSInteger *np = malloc(cap * sizeof(NSInteger)), *nx = malloc(cap * sizeof(NSInteger));
    NSInteger *dp = malloc(nd * sizeof(NSInteger)), *dx = malloc(nd * sizeof(NSInteger)), *dc = malloc(nd * sizeof(NSInteger));
    __block NSInteger head = nodes.count ? 0 : -1;
    for (NSUInteger k = 0; k < nodes.count; k++) { np[k] = (NSInteger)k - 1; nx[k] = k + 1 < nodes.count ? (NSInteger)k + 1 : -1; }
    NSMapTable *cellOf = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    for (NSUInteger k = 0; k < nodes.count; k++) [cellOf setObject:@(k) forKey:nodes[k]];
    __block NSInteger first = -1;
    NSInteger last = -1;
    for (NSUInteger k = 0; k < nd; k++) {
        NSNumber *c = [cellOf objectForKey:delims[k].node];
        dc[k] = c ? c.integerValue : -1;
        if (dc[k] < 0) continue;
        dp[k] = last; dx[k] = -1;
        if (last >= 0) dx[last] = (NSInteger)k; else first = (NSInteger)k;
        last = (NSInteger)k;
    }
    void (^unlinkCell)(NSInteger) = ^(NSInteger c) {
        if (np[c] >= 0) nx[np[c]] = nx[c]; else head = nx[c];
        if (nx[c] >= 0) np[nx[c]] = np[c];
    };
    void (^unlinkDelim)(NSInteger) = ^(NSInteger d) {
        if (dp[d] >= 0) dx[dp[d]] = dx[d]; else first = dx[d];
        if (dx[d] >= 0) dp[dx[d]] = dp[d];
    };
    NSInteger bottom[3][2][3];
    for (int a = 0; a < 3; a++) for (int b = 0; b < 2; b++) for (int c = 0; c < 3; c++) bottom[a][b][c] = -1;
    NSInteger ci = first;
    while (ci >= 0) {
        MDDelim *c = delims[ci];
        if (!c.canClose) { ci = dx[ci]; continue; }
        NSInteger *bot = &bottom[c.ch == '*' ? 0 : c.ch == '_' ? 1 : 2][c.canOpen][c.origLen % 3];
        NSInteger oi = dp[ci];
        while (oi >= 0 && oi > *bot && !canPair(delims[oi], c)) oi = dp[oi];
        MDDelim *o = oi >= 0 && oi > *bot ? delims[oi] : nil;
        NSMutableArray *children = nil;
        if (o) {
            children = [NSMutableArray array];
            for (NSInteger k = nx[dc[oi]]; k >= 0 && k != dc[ci]; k = nx[k]) [children addObject:cells[k]];
            if (depthOf(children) >= kMaxInlineDepth) o = nil;      // too deep: these stay literal
        }
        if (!o) {
            *bot = dp[ci];
            NSInteger next = dx[ci];
            if (!c.canOpen) unlinkDelim(ci);
            ci = next;
            continue;
        }
        NSUInteger use = c.ch == '~' ? c.len : (o.len >= 2 && c.len >= 2 ? 2 : 1);
        MDInline *wrap = node(c.ch == '~' ? MDStrike : (use == 2 ? MDStrong : MDEmph));
        wrap.children = mergeText(children);
        wrap.depth = depthOf(wrap.children);
        NSInteger w = (NSInteger)cells.count;
        [cells addObject:wrap];
        np[w] = dc[oi]; nx[w] = dc[ci];
        nx[dc[oi]] = w; np[dc[ci]] = w;
        dx[oi] = ci; dp[ci] = oi;                                     // delimiters in between are done
        o.len -= use; c.len -= use;
        o.node.text = [o.node.text substringToIndex:o.len];
        c.node.text = [c.node.text substringToIndex:c.len];
        if (!o.len) { unlinkCell(dc[oi]); unlinkDelim(oi); }
        if (!c.len) { NSInteger next = dx[ci]; unlinkCell(dc[ci]); unlinkDelim(ci); ci = next; }
    }
    [nodes removeAllObjects];
    for (NSInteger k = head; k >= 0; k = nx[k]) [nodes addObject:cells[k]];
    free(np); free(nx); free(dp); free(dx); free(dc);
}

- (void)codeSpan {
    NSUInteger k = i;
    while (k < n && s[k] == '`') k++;
    NSUInteger run = k - i, j = k;
    NSNumber *none = noCodeRun[@(run)];
    if (none && k >= none.unsignedIntegerValue) j = n;              // known: no closing run of this length
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
    if (!none || k < none.unsignedIntegerValue) noCodeRun[@(run)] = @(k);
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
    BOOL active = op.active && (op.image || brackets.count - 1 >= linkFloor);     // no links inside links
    if (!op || !active) { if (op) [self popBracket]; [buf appendString:@"]"]; return; }
    NSString *url = nil, *title = @"";
    BOOL ok = i < n && s[i] == '(' && [self inlineDest:&url title:&title];
    if (!ok) {
        i = after;
        NSUInteger resume = after;
        BOOL lookup = refs.count && labelEnd - op.textStart <= kMaxLabel;
        NSString *own = lookup ? [self sub:op.textStart to:labelEnd] : @"", *label = own;
        if (lookup && i < n && s[i] == '[') {
            NSUInteger k = i + 1;
            while (k < n && k - i <= kMaxLabel && s[k] != ']' && s[k] != '[') { if (s[k] == '\\') k++; k++; }
            if (k < n && s[k] == ']') {
                NSString *l = [self sub:i + 1 to:k];
                if (l.length) label = l;
                resume = k + 1;
            }
        }
        NSArray *ref = lookup ? refs[MDNormLabel(label)] : nil;
        if (lookup && !ref && ![label isEqualToString:own]) { ref = refs[MDNormLabel(own)]; resume = after; }
        if (ref) { url = ref[0]; title = ref[1]; ok = YES; i = resume; }
    }
    if (!ok) { [self popBracket]; [buf appendString:@"]"]; i = after; return; }
    [self flush];
    NSUInteger at = nodes.count;                                    // from the end: the label is what follows it
    while (at > 0 && nodes[at - 1] != op.node) at--;
    if (!at) { [self popBracket]; [buf appendString:@"]"]; i = after; return; }
    at--;
    NSMutableArray *inner = [[nodes subarrayWithRange:NSMakeRange(at + 1, nodes.count - at - 1)] mutableCopy];
    NSRange dr = NSMakeRange(op.delimDepth, delims.count - op.delimDepth);
    NSMutableArray *innerDelims = [[delims subarrayWithRange:dr] mutableCopy];
    processEmphasis(inner, innerDelims);
    [delims removeObjectsInRange:dr];
    MDInline *ln = node(op.image ? MDImage : MDLink);
    ln.url = url; ln.title = title; ln.children = mergeText(inner);
    ln.depth = depthOf(ln.children);
    if (ln.depth >= kMaxInlineDepth) ln.children = @[[MDInline text:MDPlainText(ln.children)]];
    if (op.image) ln.text = MDPlainText(ln.children);
    [nodes removeObjectsInRange:NSMakeRange(at, nodes.count - at)];
    [nodes addObject:ln];
    [self popBracket];
    if (!op.image) linkFloor = brackets.count;
}

- (void)popBracket {
    [brackets removeLastObject];
    linkFloor = MIN(linkFloor, brackets.count);
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
        if (k + 3 >= noCommentFrom) return NO;
        for (NSUInteger q = k + 3; q + 2 < n; q++) {
            if (s[q] == '-' && s[q + 1] == '-' && s[q + 2] == '>') {
                MDInline *r = node(MDRawHTML); r.text = [self sub:i to:q + 3];
                [self add:r];
                i = q + 3;
                return YES;
            }
        }
        noCommentFrom = k + 3;
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
    NSInteger bal = 0;
    for (NSUInteger q = i; q < k; q++) bal += s[q] == '(' ? 1 : s[q] == ')' ? -1 : 0;
    while (k > i + pre) {
        unichar e = s[k - 1];
        if (e && e < 128 && strchr(".,:;!?\"'*_~", e)) { k--; continue; }
        if (e == ')' && bal < 0) { k--; bal++; continue; }
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
    p->noCodeRun = [NSMutableDictionary dictionary];
    p->noDestFrom = p->noCommentFrom = NSUIntegerMax;
    for (int q = 0; q < 3; q++) p->noQuoteFrom[q] = NSUIntegerMax;
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

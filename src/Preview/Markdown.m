#import "Markdown.h"

@implementation MDBlock
- (instancetype)init {
    if ((self = [super init])) { _children = [NSMutableArray array]; _task = -1; _start = 1; _tight = YES; }
    return self;
}
@end

@implementation MDDocument
- (NSArray<MDInline *> *)inlines:(NSString *)s { return MDParseInline(s ?: @"", _refs); }
@end

#pragma mark Line helpers (tabs are expanded before parsing)

static NSUInteger indentOf(NSString *s) {
    NSUInteger i = 0, n = s.length;
    while (i < n && [s characterAtIndex:i] == ' ') i++;
    return i;
}
static BOOL isBlank(NSString *s) { return indentOf(s) == s.length; }
static NSString *trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; }
static NSString *stripIndent(NSString *s, NSUInteger n) { return [s substringFromIndex:MIN(n, indentOf(s))]; }

static NSString *expandTabs(NSString *line) {
    if ([line rangeOfString:@"\t"].location == NSNotFound) return line;
    NSMutableString *out = [NSMutableString string];
    NSUInteger col = 0;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar c = [line characterAtIndex:i];
        if (c == '\t') { NSUInteger k = 4 - col % 4; for (NSUInteger j = 0; j < k; j++) [out appendString:@" "]; col += k; }
        else { [out appendFormat:@"%C", c]; col++; }
    }
    return out;
}

static BOOL allChars(NSString *t, unichar c) {
    if (!t.length) return NO;
    for (NSUInteger i = 0; i < t.length; i++) if ([t characterAtIndex:i] != c) return NO;
    return YES;
}

static BOOL isRule(NSString *l) {
    if (indentOf(l) > 3) return NO;
    unichar ch = 0; NSUInteger n = 0;
    for (NSUInteger i = 0; i < l.length; i++) {
        unichar c = [l characterAtIndex:i];
        if (c == ' ') continue;
        if (!ch && (c == '-' || c == '*' || c == '_')) ch = c;
        if (c != ch) return NO;
        n++;
    }
    return n >= 3;
}

static NSInteger atxLevel(NSString *l, NSString **content) {
    NSUInteger i = indentOf(l), n = l.length, h = 0;
    if (i > 3) return 0;
    while (i + h < n && [l characterAtIndex:i + h] == '#') h++;
    if (!h || h > 6 || (i + h < n && [l characterAtIndex:i + h] != ' ')) return 0;
    NSString *c = trim([l substringFromIndex:i + h]);
    NSUInteger e = c.length;
    while (e > 0 && [c characterAtIndex:e - 1] == '#') e--;
    if (e == 0) c = @"";
    else if (e < c.length && [c characterAtIndex:e - 1] == ' ') c = trim([c substringToIndex:e]);
    *content = c;
    return h;
}

static BOOL fenceOpen(NSString *l, unichar *fc, NSUInteger *flen, NSUInteger *find, NSString **info) {
    NSUInteger i = indentOf(l), n = l.length, k = 0;
    if (i > 3 || i >= n) return NO;
    unichar c = [l characterAtIndex:i];
    if (c != '`' && c != '~') return NO;
    while (i + k < n && [l characterAtIndex:i + k] == c) k++;
    if (k < 3) return NO;
    NSString *rest = trim([l substringFromIndex:i + k]);
    if (c == '`' && [rest rangeOfString:@"`"].location != NSNotFound) return NO;
    *fc = c; *flen = k; *find = i;
    *info = [rest componentsSeparatedByString:@" "].firstObject ?: @"";
    return YES;
}

static BOOL fenceClose(NSString *l, unichar fc, NSUInteger flen) {
    NSUInteger i = indentOf(l), n = l.length, k = 0;
    if (i > 3) return NO;
    while (i + k < n && [l characterAtIndex:i + k] == fc) k++;
    return k >= flen && isBlank([l substringFromIndex:i + k]);
}

static BOOL quotePrefix(NSString *l) {
    NSUInteger i = indentOf(l);
    return i <= 3 && i < l.length && [l characterAtIndex:i] == '>';
}
static NSString *stripQuote(NSString *l) {
    NSUInteger i = indentOf(l) + 1;
    if (i < l.length && [l characterAtIndex:i] == ' ') i++;
    return [l substringFromIndex:MIN(i, l.length)];
}

typedef struct { BOOL ordered; unichar bullet; NSInteger num; NSUInteger contentCol; BOOL empty; } MDMarker;

static BOOL listMarker(NSString *l, MDMarker *m) {
    NSUInteger i = indentOf(l), n = l.length, j;
    if (i > 3 || i >= n) return NO;
    unichar c = [l characterAtIndex:i];
    if (c == '-' || c == '*' || c == '+') { m->ordered = NO; m->bullet = c; m->num = 1; j = i + 1; }
    else if (c >= '0' && c <= '9') {
        NSInteger v = 0; j = i;
        while (j < n && j - i < 9 && [l characterAtIndex:j] >= '0' && [l characterAtIndex:j] <= '9') v = v * 10 + ([l characterAtIndex:j++] - '0');
        if (j >= n || ([l characterAtIndex:j] != '.' && [l characterAtIndex:j] != ')')) return NO;
        m->ordered = YES; m->bullet = [l characterAtIndex:j]; m->num = v; j++;
    } else return NO;
    if (j < n && [l characterAtIndex:j] != ' ') return NO;
    NSUInteger sp = 0;
    while (j + sp < n && [l characterAtIndex:j + sp] == ' ') sp++;
    m->empty = j + sp >= n;
    m->contentCol = (m->empty || sp > 4) ? j + 1 : j + sp;
    return YES;
}

static NSSet *blockTags(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:[@"address article aside blockquote body center details dialog dd div dl dt fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr html iframe legend li main menu nav ol p picture pre section summary table tbody td tfoot th thead tr ul video audio script style textarea" componentsSeparatedByString:@" "]];
    });
    return s;
}

// Returns the tag name (lowercase) when the line starts an HTML block, "!--" for comments, else nil.
static NSString *htmlBlockStart(NSString *l) {
    NSUInteger i = indentOf(l);
    if (i > 3) return nil;
    NSString *t = [l substringFromIndex:i];
    if (![t hasPrefix:@"<"]) return nil;
    if ([t hasPrefix:@"<!--"]) return @"!--";
    NSUInteger k = 1, n = t.length;
    if (k < n && [t characterAtIndex:k] == '/') k++;
    NSUInteger s = k;
    while (k < n && [NSCharacterSet.alphanumericCharacterSet characterIsMember:[t characterAtIndex:k]]) k++;
    if (k == s) return nil;
    if (k < n) { unichar c = [t characterAtIndex:k]; if (c != ' ' && c != '>' && c != '/') return nil; }
    NSString *name = [t substringWithRange:NSMakeRange(s, k - s)].lowercaseString;
    return [blockTags() containsObject:name] ? name : nil;
}

static NSArray<NSString *> *splitRow(NSString *l) {
    NSString *t = trim(l);
    if ([t hasPrefix:@"|"]) t = [t substringFromIndex:1];
    if ([t hasSuffix:@"|"] && ![t hasSuffix:@"\\|"]) t = [t substringToIndex:t.length - 1];
    NSMutableArray *cells = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == '\\' && i + 1 < t.length && [t characterAtIndex:i + 1] == '|') { [cur appendString:@"\\|"]; i++; continue; }
        if (c == '|') { [cells addObject:trim(cur)]; cur = [NSMutableString string]; continue; }
        [cur appendFormat:@"%C", c];
    }
    [cells addObject:trim(cur)];
    return cells;
}

static NSArray<NSNumber *> *delimRow(NSString *l, NSUInteger cols) {
    if (!cols || [l rangeOfString:@"-"].location == NSNotFound) return nil;
    NSArray *cells = splitRow(l);
    if (cells.count != cols) return nil;
    NSMutableArray *al = [NSMutableArray array];
    for (NSString *c in cells) {
        if (!c.length) return nil;
        BOOL left = [c hasPrefix:@":"], right = [c hasSuffix:@":"];
        NSString *mid = [c substringWithRange:NSMakeRange(left, c.length - left - (right && c.length > 1))];
        if (!allChars(mid, '-')) return nil;
        [al addObject:@(left && right ? MDAlignCenter : right ? MDAlignRight : left ? MDAlignLeft : MDAlignNone)];
    }
    return al;
}

#pragma mark Block parser

static MDBlock *blk(MDBlockType t, NSUInteger line) { MDBlock *b = [MDBlock new]; b.type = t; b.line = line; return b; }

// Lines that may interrupt a paragraph.
static BOOL startsBlock(NSString *l) {
    unichar fc; NSUInteger fl, fi; NSString *info, *hc; MDMarker m;
    if (fenceOpen(l, &fc, &fl, &fi, &info) || atxLevel(l, &hc) || quotePrefix(l) || isRule(l) || htmlBlockStart(l)) return YES;
    return listMarker(l, &m) && !m.empty && (!m.ordered || m.num == 1);
}

NSString *MDNormLabel(NSString *s) {
    NSArray *parts = [s.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static BOOL parseRefDef(NSString *line, NSMutableDictionary *refs) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^ {0,3}\\[([^\\]]+)\\]:[ \\t]*<?([^ \\t>]+)>?(?:[ \\t]+(?:\"([^\"]*)\"|'([^']*)'|\\(([^)]*)\\)))?[ \\t]*$" options:0 error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!m) return NO;
    NSString *label = MDNormLabel([line substringWithRange:[m rangeAtIndex:1]]);
    NSString *title = @"";
    for (NSUInteger g = 3; g <= 5; g++) if ([m rangeAtIndex:g].location != NSNotFound) title = [line substringWithRange:[m rangeAtIndex:g]];
    if (label.length && !refs[label]) refs[label] = @[[line substringWithRange:[m rangeAtIndex:2]], title];
    return YES;
}

static NSString *joinPara(NSArray<NSString *> *para) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:para.count];
    for (NSString *l in para) [a addObject:[l substringFromIndex:indentOf(l)]];
    return [[a componentsJoinedByString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSMutableArray<MDBlock *> *parseBlocks(NSArray<NSString *> *L, NSUInteger base, NSMutableDictionary *refs);

static NSUInteger parseList(NSArray<NSString *> *L, NSUInteger i, NSUInteger base, NSMutableDictionary *refs, NSMutableArray *out) {
    MDMarker first;
    listMarker(L[i], &first);
    MDBlock *list = blk(MDList, base + i);
    list.ordered = first.ordered;
    list.start = first.num;
    NSUInteger n = L.count;
    BOOL loose = NO;
    while (i < n) {
        MDMarker m;
        if (isRule(L[i]) || !listMarker(L[i], &m) || m.ordered != first.ordered || m.bullet != first.bullet) break;
        NSUInteger col = m.contentCol, s = i;
        NSMutableArray<NSString *> *content = [NSMutableArray arrayWithObject:L[i].length > col ? [L[i] substringFromIndex:col] : @""];
        BOOL prevBlank = NO;
        for (i++; i < n; i++) {
            NSString *x = L[i];
            if (isBlank(x)) { [content addObject:@""]; prevBlank = YES; continue; }
            if (indentOf(x) >= col) { [content addObject:[x substringFromIndex:col]]; prevBlank = NO; continue; }
            MDMarker sib;
            BOOL marker = listMarker(x, &sib);              // any marker ends the item, even "4." that can't interrupt a paragraph
            if (!prevBlank && !marker && !startsBlock(x) && !(m.empty && content.count == 1)) { [content addObject:x]; continue; }   // lazy line
            break;
        }
        NSUInteger trailing = 0;
        while (content.count > 1 && !content.lastObject.length) { [content removeLastObject]; trailing++; }

        MDBlock *item = blk(MDItem, base + s);
        NSString *f = content[0], *fl = f.lowercaseString;
        if ([f hasPrefix:@"[ ] "] || [f isEqualToString:@"[ ]"]) { item.task = 0; content[0] = [f substringFromIndex:MIN((NSUInteger)4, f.length)]; }
        else if ([fl hasPrefix:@"[x] "] || [fl isEqualToString:@"[x]"]) { item.task = 1; content[0] = [f substringFromIndex:MIN((NSUInteger)4, f.length)]; }
        item.children = parseBlocks(content, base + s, refs);
        for (NSUInteger k = 1; k < item.children.count; k++) {
            NSUInteger r = item.children[k].line - (base + s);
            if (r > 0 && r - 1 < content.count && isBlank(content[r - 1])) loose = YES;
        }
        [list.children addObject:item];
        MDMarker next;
        if (trailing && i < n && listMarker(L[i], &next) && next.ordered == first.ordered && next.bullet == first.bullet) loose = YES;
    }
    list.tight = !loose;
    [out addObject:list];
    return i;
}

static NSMutableArray<MDBlock *> *parseBlocks(NSArray<NSString *> *L, NSUInteger base, NSMutableDictionary *refs) {
    NSMutableArray<MDBlock *> *out = [NSMutableArray array];
    NSMutableArray<NSString *> *para = [NSMutableArray array];
    __block NSUInteger paraLine = 0;
    void (^flush)(void) = ^{
        while (para.count && parseRefDef(para[0], refs)) { [para removeObjectAtIndex:0]; paraLine++; }
        if (para.count) { MDBlock *p = blk(MDParagraph, base + paraLine); p.text = joinPara(para); [out addObject:p]; }
        [para removeAllObjects];
    };
    NSUInteger i = 0, n = L.count;
    while (i < n) {
        NSString *l = L[i];
        if (isBlank(l)) { flush(); i++; continue; }
        if (!para.count && indentOf(l) >= 4) {                           // indented code
            NSMutableArray *code = [NSMutableArray array];
            NSUInteger s = i;
            while (i < n && (isBlank(L[i]) || indentOf(L[i]) >= 4)) { [code addObject:isBlank(L[i]) ? @"" : stripIndent(L[i], 4)]; i++; }
            while (code.count && ![code.lastObject length]) [code removeLastObject];
            MDBlock *b = blk(MDCode, base + s); b.text = [code componentsJoinedByString:@"\n"]; b.info = @"";
            [out addObject:b];
            continue;
        }
        unichar fc; NSUInteger flen, find; NSString *info, *hc;
        if (fenceOpen(l, &fc, &flen, &find, &info)) {
            flush();
            NSUInteger s = i++;
            NSMutableArray *code = [NSMutableArray array];
            while (i < n && !fenceClose(L[i], fc, flen)) [code addObject:stripIndent(L[i++], find)];
            if (i < n) i++;
            MDBlock *b = blk(MDCode, base + s); b.text = [code componentsJoinedByString:@"\n"]; b.info = info;
            [out addObject:b];
            continue;
        }
        NSInteger h = atxLevel(l, &hc);
        if (h) { flush(); MDBlock *b = blk(MDHeading, base + i); b.level = h; b.text = hc; [out addObject:b]; i++; continue; }
        if (para.count && indentOf(l) <= 3 && (allChars(trim(l), '=') || allChars(trim(l), '-'))) {   // setext
            MDBlock *b = blk(MDHeading, base + paraLine);
            b.level = [trim(l) hasPrefix:@"="] ? 1 : 2;
            b.text = joinPara(para);
            [para removeAllObjects];
            [out addObject:b];
            i++; continue;
        }
        if (isRule(l)) { flush(); [out addObject:blk(MDRule, base + i)]; i++; continue; }
        if (quotePrefix(l)) {
            flush();
            NSUInteger s = i;
            NSMutableArray *inner = [NSMutableArray array];
            BOOL lastPara = NO;
            while (i < n) {
                if (quotePrefix(L[i])) {
                    NSString *x = stripQuote(L[i]);
                    [inner addObject:x];
                    lastPara = !isBlank(x) && !startsBlock(x) && indentOf(x) < 4;
                    i++;
                } else if (lastPara && !isBlank(L[i]) && !startsBlock(L[i])) { [inner addObject:L[i++]]; }
                else break;
            }
            MDBlock *q = blk(MDQuote, base + s);
            q.children = parseBlocks(inner, base + s, refs);
            [out addObject:q];
            continue;
        }
        MDMarker m;
        if (listMarker(l, &m) && (!para.count || (!m.empty && (!m.ordered || m.num == 1)))) {
            flush();
            i = parseList(L, i, base, refs, out);
            continue;
        }
        if (para.count && [para.lastObject rangeOfString:@"|"].location != NSNotFound) {   // GFM table
            NSArray *header = splitRow(para.lastObject);
            NSArray *al = delimRow(l, header.count);
            if (al) {
                [para removeLastObject];
                NSUInteger headAt = paraLine + para.count;
                flush();
                MDBlock *t = blk(MDTable, base + headAt);
                NSMutableArray *rows = [NSMutableArray arrayWithObject:header];
                for (i++; i < n && !isBlank(L[i]) && !startsBlock(L[i]); i++) {
                    NSMutableArray *r = [splitRow(L[i]) mutableCopy];
                    while (r.count < header.count) [r addObject:@""];
                    [rows addObject:[r subarrayWithRange:NSMakeRange(0, header.count)]];
                }
                t.rows = rows; t.align = al;
                [out addObject:t];
                continue;
            }
        }
        NSString *tag = htmlBlockStart(l);
        if (tag) {
            flush();
            NSUInteger s = i;
            NSMutableArray *raw = [NSMutableArray array];
            NSString *end = [tag isEqualToString:@"!--"] ? @"-->" :
                            [@[@"pre", @"script", @"style", @"textarea"] containsObject:tag] ? [NSString stringWithFormat:@"</%@>", tag] : nil;
            while (i < n) {
                if (!end && isBlank(L[i])) break;
                [raw addObject:L[i]];
                BOOL done = end && [L[i].lowercaseString rangeOfString:end].location != NSNotFound;
                i++;
                if (done) break;
            }
            MDBlock *b = blk(MDHTMLBlock, base + s); b.text = [raw componentsJoinedByString:@"\n"]; b.info = tag;
            [out addObject:b];
            continue;
        }
        if (!para.count) paraLine = i;
        [para addObject:l];
        i++;
    }
    flush();
    return out;
}

MDDocument *MDParse(NSString *source) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *l in [source componentsSeparatedByString:@"\n"])
        [lines addObject:expandTabs([l hasSuffix:@"\r"] ? [l substringToIndex:l.length - 1] : l)];
    NSMutableDictionary *refs = [NSMutableDictionary dictionary];
    MDDocument *d = [MDDocument new];
    d.blocks = parseBlocks(lines, 0, refs);
    d.refs = refs;
    return d;
}

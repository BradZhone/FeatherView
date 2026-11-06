#import "JSONTree.h"

static const NSUInteger kMaxDepth = 512, kMaxNodes = 2000000;

@implementation JSONNode

- (NSString *)displayKey {
    if (_key) return _key;
    if (_parent) return [NSString stringWithFormat:@"[%lu]", (unsigned long)_index];
    return @"根";
}

static BOOL identifierSafe(NSString *k) {
    if (!k.length) return NO;
    for (NSUInteger i = 0; i < k.length; i++) {
        unichar c = [k characterAtIndex:i];
        BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
        if (!(letter || (i && c >= '0' && c <= '9'))) return NO;
    }
    return YES;
}

static void escapeInto(NSMutableString *o, NSString *s) {
    [o appendString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"': [o appendString:@"\\\""]; break;
            case '\\': [o appendString:@"\\\\"]; break;
            case '\n': [o appendString:@"\\n"]; break;
            case '\r': [o appendString:@"\\r"]; break;
            case '\t': [o appendString:@"\\t"]; break;
            default:
                if (c < 0x20) [o appendFormat:@"\\u%04x", c];
                else [o appendFormat:@"%C", c];
        }
    }
    [o appendString:@"\""];
}

- (NSString *)path {
    NSMutableArray *parts = [NSMutableArray array];
    for (JSONNode *n = self; n.parent; n = n.parent) {
        if (n.parent.kind == JSONArray || !n.key) [parts insertObject:[NSString stringWithFormat:@"[%lu]", (unsigned long)n.index] atIndex:0];
        else if (identifierSafe(n.key)) [parts insertObject:[@"." stringByAppendingString:n.key] atIndex:0];
        else { NSMutableString *q = [NSMutableString stringWithString:@"["]; escapeInto(q, n.key); [q appendString:@"]"]; [parts insertObject:q atIndex:0]; }
    }
    return [@"$" stringByAppendingString:[parts componentsJoinedByString:@""]];
}

static void writeNode(JSONNode *n, NSMutableString *o, NSUInteger depth, BOOL pretty) {
    NSString *pad = pretty ? [@"" stringByPaddingToLength:(depth + 1) * 2 withString:@" " startingAtIndex:0] : @"";
    NSString *end = pretty ? [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0] : @"";
    switch (n.kind) {
        case JSONObject: case JSONArray: {
            BOOL obj = n.kind == JSONObject;
            if (!n.children.count) { [o appendString:obj ? @"{}" : @"[]"]; return; }
            [o appendString:obj ? @"{" : @"["];
            for (NSUInteger i = 0; i < n.children.count; i++) {
                JSONNode *c = n.children[i];
                if (pretty) { [o appendString:@"\n"]; [o appendString:pad]; }
                if (obj) { escapeInto(o, c.key ?: @""); [o appendString:pretty ? @": " : @":"]; }
                writeNode(c, o, depth + 1, pretty);
                if (i + 1 < n.children.count) [o appendString:@","];
            }
            if (pretty) { [o appendString:@"\n"]; [o appendString:end]; }
            [o appendString:obj ? @"}" : @"]"];
            return;
        }
        case JSONString: case JSONData: case JSONDate: escapeInto(o, n.text ?: @""); return;
        default: [o appendString:n.text ?: @"null"]; return;
    }
}

- (NSString *)JSONStringPretty:(BOOL)pretty {
    NSMutableString *o = [NSMutableString string];
    writeNode(self, o, 0, pretty);
    return o;
}

@end

#pragma mark Parser

typedef struct {
    const uint8_t *s;
    NSUInteger n, i, depth, nodes;
    NSUInteger lineAt, line;           // cached: line number at byte lineAt (parsing only moves forward)
    const char *err;                   // UTF-8 message; "%s" is replaced by word
    char word[64];
    NSUInteger errAt;
} P;

static NSUInteger lineOf(P *p, NSUInteger pos) {
    for (; p->lineAt < pos && p->lineAt < p->n; p->lineAt++) if (p->s[p->lineAt] == '\n') p->line++;
    return p->line;
}

static void failw(P *p, const char *msg, const char *word) {
    if (p->err) return;
    p->err = msg; p->errAt = p->i;
    strlcpy(p->word, word ?: "", sizeof p->word);
}
static void fail(P *p, const char *msg) { failw(p, msg, NULL); }

static void ws(P *p) {
    const uint8_t *s = p->s;
    for (;;) {
        while (p->i < p->n && (s[p->i] == ' ' || s[p->i] == '\t' || s[p->i] == '\n' || s[p->i] == '\r')) p->i++;
        if (p->i + 1 < p->n && s[p->i] == '/' && s[p->i + 1] == '/') { while (p->i < p->n && s[p->i] != '\n') p->i++; continue; }
        if (p->i + 1 < p->n && s[p->i] == '/' && s[p->i + 1] == '*') {
            p->i += 2;
            while (p->i + 1 < p->n && !(s[p->i] == '*' && s[p->i + 1] == '/')) p->i++;
            p->i = MIN(p->n, p->i + 2);
            continue;
        }
        return;
    }
}

static void appendUTF8(NSMutableData *d, uint32_t cp) {
    uint8_t b[4]; NSUInteger k;
    if (cp < 0x80) { b[0] = cp; k = 1; }
    else if (cp < 0x800) { b[0] = 0xC0 | (cp >> 6); b[1] = 0x80 | (cp & 0x3F); k = 2; }
    else if (cp < 0x10000) { b[0] = 0xE0 | (cp >> 12); b[1] = 0x80 | ((cp >> 6) & 0x3F); b[2] = 0x80 | (cp & 0x3F); k = 3; }
    else { b[0] = 0xF0 | (cp >> 18); b[1] = 0x80 | ((cp >> 12) & 0x3F); b[2] = 0x80 | ((cp >> 6) & 0x3F); b[3] = 0x80 | (cp & 0x3F); k = 4; }
    [d appendBytes:b length:k];
}

static int hexv(uint8_t c) { return c >= '0' && c <= '9' ? c - '0' : (c | 0x20) >= 'a' && (c | 0x20) <= 'f' ? (c | 0x20) - 'a' + 10 : -1; }

static NSString *decodeBytes(const uint8_t *b, NSUInteger len) {
    return [[NSString alloc] initWithBytes:b length:len encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithBytes:b length:len encoding:NSISOLatin1StringEncoding] ?: @"";
}

static NSString *parseString(P *p) {
    const uint8_t *s = p->s;
    uint8_t q = s[p->i++];
    NSUInteger start = p->i;
    NSMutableData *buf = nil;
    while (p->i < p->n && s[p->i] != q) {
        uint8_t c = s[p->i];
        if (c == '\n') { fail(p, "字符串没有结束"); return nil; }
        if (c != '\\') { if (buf) [buf appendBytes:&s[p->i] length:1]; p->i++; continue; }
        if (!buf) buf = [NSMutableData dataWithBytes:s + start length:p->i - start];
        if (p->i + 1 >= p->n) break;
        uint8_t e = s[p->i + 1];
        p->i += 2;
        switch (e) {
            case 'n': [buf appendBytes:"\n" length:1]; break;
            case 't': [buf appendBytes:"\t" length:1]; break;
            case 'r': [buf appendBytes:"\r" length:1]; break;
            case 'b': [buf appendBytes:"\b" length:1]; break;
            case 'f': [buf appendBytes:"\f" length:1]; break;
            case 'u': {
                uint32_t cp = 0;
                for (int k = 0; k < 4; k++) { int h = p->i < p->n ? hexv(s[p->i]) : -1; if (h < 0) { fail(p, "\\u 后面需要 4 位十六进制数"); return nil; } cp = cp * 16 + h; p->i++; }
                if (cp >= 0xD800 && cp < 0xDC00 && p->i + 5 < p->n && s[p->i] == '\\' && s[p->i + 1] == 'u') {
                    uint32_t lo = 0; BOOL ok = YES;
                    for (int k = 0; k < 4; k++) { int h = hexv(s[p->i + 2 + k]); if (h < 0) { ok = NO; break; } lo = lo * 16 + h; }
                    if (ok && lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); p->i += 6; }
                }
                appendUTF8(buf, cp);
                break;
            }
            default: [buf appendBytes:&e length:1];              // \" \\ \/ \' and anything else literally
        }
    }
    if (p->i >= p->n) { fail(p, "字符串没有结束"); return nil; }
    NSString *out = buf ? decodeBytes(buf.bytes, buf.length) : decodeBytes(s + start, p->i - start);
    p->i++;
    return out;
}

static BOOL identChar(uint8_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$' || c >= 0x80; }

static NSString *parseIdent(P *p) {
    NSUInteger a = p->i;
    while (p->i < p->n && identChar(p->s[p->i])) p->i++;
    return decodeBytes(p->s + a, p->i - a);
}

static JSONNode *parseValue(P *p);

static JSONNode *parseContainer(P *p, JSONNode *node, BOOL object) {
    if (++p->depth > kMaxDepth) { fail(p, "嵌套太深"); return nil; }
    uint8_t close = object ? '}' : ']';
    p->i++;
    NSMutableArray *kids = [NSMutableArray array];
    ws(p);
    if (p->i < p->n && p->s[p->i] == close) { p->i++; node.children = kids; p->depth--; return node; }
    for (;;) {
        ws(p);
        NSString *key = nil;
        if (object) {
            if (p->i >= p->n) { fail(p, "缺少 }"); return nil; }
            uint8_t c = p->s[p->i];
            if (c == '"' || c == '\'') key = parseString(p);
            else if (identChar(c)) key = parseIdent(p);
            else { fail(p, "这里需要属性名"); return nil; }
            if (!key) return nil;
            ws(p);
            if (p->i >= p->n || p->s[p->i] != ':') { fail(p, "属性名后面缺少 :"); return nil; }
            p->i++;
        }
        JSONNode *v = parseValue(p);
        if (!v) return nil;
        v.key = key;
        v.index = kids.count;
        v.parent = node;
        [kids addObject:v];
        ws(p);
        if (p->i < p->n && p->s[p->i] == ',') {
            p->i++;
            ws(p);
            if (p->i < p->n && p->s[p->i] == close) { p->i++; break; }       // trailing comma
            continue;
        }
        if (p->i < p->n && p->s[p->i] == close) { p->i++; break; }
        fail(p, object ? "缺少 , 或 }" : "缺少 , 或 ]");
        return nil;
    }
    node.children = kids;
    p->depth--;
    return node;
}

static JSONNode *parseValue(P *p) {
    ws(p);
    if (p->i >= p->n) { fail(p, "内容意外结束"); return nil; }
    if (++p->nodes > kMaxNodes) { fail(p, "节点太多（超过 200 万）"); return nil; }
    JSONNode *node = [JSONNode new];
    node.line = lineOf(p, p->i);
    uint8_t c = p->s[p->i];
    if (c == '{') { node.kind = JSONObject; return parseContainer(p, node, YES); }
    if (c == '[') { node.kind = JSONArray; return parseContainer(p, node, NO); }
    if (c == '"' || c == '\'') {
        node.kind = JSONString;
        node.text = parseString(p);
        return node.text ? node : nil;
    }
    if (c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9')) {
        NSUInteger a = p->i;
        if (c == '-' || c == '+') p->i++;
        if (p->i + 1 < p->n && p->s[p->i] == '0' && (p->s[p->i + 1] | 0x20) == 'x') {
            p->i += 2;
            while (p->i < p->n && hexv(p->s[p->i]) >= 0) p->i++;
        } else {
            BOOL digits = NO;
            while (p->i < p->n && ((p->s[p->i] >= '0' && p->s[p->i] <= '9') || p->s[p->i] == '.')) { digits |= p->s[p->i] != '.'; p->i++; }
            if (p->i < p->n && (p->s[p->i] | 0x20) == 'e') {
                p->i++;
                if (p->i < p->n && (p->s[p->i] == '+' || p->s[p->i] == '-')) p->i++;
                while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
            }
            if (!digits) {
                if (p->i < p->n && identChar(p->s[p->i])) {               // -Infinity
                    NSString *w = parseIdent(p);
                    if ([w isEqualToString:@"Infinity"]) { node.kind = JSONNumber; node.text = decodeBytes(p->s + a, p->i - a); return node; }
                }
                p->i = a; fail(p, "数字格式不对"); return nil;
            }
        }
        node.kind = JSONNumber;
        node.text = decodeBytes(p->s + a, p->i - a);
        return node;
    }
    if (identChar(c)) {
        NSUInteger a = p->i;
        NSString *w = parseIdent(p);
        if ([w isEqualToString:@"true"] || [w isEqualToString:@"false"]) { node.kind = JSONBool; node.text = w; return node; }
        if ([w isEqualToString:@"null"]) { node.kind = JSONNull; node.text = w; return node; }
        if ([w isEqualToString:@"Infinity"] || [w isEqualToString:@"NaN"]) { node.kind = JSONNumber; node.text = w; return node; }
        p->i = a;
        failw(p, "无法识别的值“%s”", (w.length > 20 ? [[w substringToIndex:20] stringByAppendingString:@"…"] : w).UTF8String);
        return nil;
    }
    char ch[2] = {(char)c, 0};
    failw(p, "意外的字符“%s”", c >= 0x20 && c < 0x7F ? ch : "?");
    return nil;
}

JSONNode *JSONParse(NSData *utf8, NSString **error) {
    P p = {0};
    p.s = utf8.bytes; p.n = utf8.length; p.line = 1;
    if (p.n >= 3 && p.s[0] == 0xEF && p.s[1] == 0xBB && p.s[2] == 0xBF) p.i = 3;
    ws(&p);
    if (p.i >= p.n) { if (error) *error = @"文件是空的"; return nil; }
    JSONNode *root = parseValue(&p);
    if (root) {
        ws(&p);
        if (p.i < p.n) { fail(&p, "值的后面还有多余的内容"); root = nil; }
    }
    if (!root) {
        if (error) {
            NSUInteger line = 1, col = 1;
            for (NSUInteger k = 0; k < MIN(p.errAt, p.n); k++) {
                if (p.s[k] == '\n') { line++; col = 1; }
                else if ((p.s[k] & 0xC0) != 0x80) col++;
            }
            NSString *msg = p.err ? [[NSString stringWithUTF8String:p.err] stringByReplacingOccurrencesOfString:@"%s" withString:@(p.word)] : @"格式错误";
            *error = [NSString stringWithFormat:@"第 %lu 行第 %lu 列：%@", (unsigned long)line, (unsigned long)col, msg];
        }
        return nil;
    }
    return root;
}

#pragma mark Property lists

static JSONNode *plistNode(id v, NSUInteger depth) {
    JSONNode *n = [JSONNode new];
    if ([v isKindOfClass:NSDictionary.class] && depth < kMaxDepth) {
        n.kind = JSONObject;
        NSMutableArray *kids = [NSMutableArray array];
        for (id k in [[v allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
                 return [[a description] localizedStandardCompare:[b description]]; }]) {
            JSONNode *c = plistNode(v[k], depth + 1);
            c.key = [k description];
            c.index = kids.count;
            c.parent = n;
            [kids addObject:c];
        }
        n.children = kids;
    } else if ([v isKindOfClass:NSArray.class] && depth < kMaxDepth) {
        n.kind = JSONArray;
        NSMutableArray *kids = [NSMutableArray array];
        for (id x in v) {
            JSONNode *c = plistNode(x, depth + 1);
            c.index = kids.count;
            c.parent = n;
            [kids addObject:c];
        }
        n.children = kids;
    } else if ([v isKindOfClass:NSString.class]) {
        n.kind = JSONString; n.text = v;
    } else if ([v isKindOfClass:NSNumber.class]) {
        BOOL isBool = CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID();
        n.kind = isBool ? JSONBool : JSONNumber;
        n.text = isBool ? ([v boolValue] ? @"true" : @"false") : [v stringValue];
    } else if ([v isKindOfClass:NSData.class]) {
        NSData *d = v;
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *b = d.bytes;
        for (NSUInteger i = 0; i < MIN(d.length, (NSUInteger)24); i++) [hex appendFormat:@"%02x", b[i]];
        n.kind = JSONData;
        n.text = [NSString stringWithFormat:@"%lu 字节  %@%@", (unsigned long)d.length, hex, d.length > 24 ? @"…" : @""];
    } else if ([v isKindOfClass:NSDate.class]) {
        n.kind = JSONDate;
        NSISO8601DateFormatter *f = [NSISO8601DateFormatter new];
        f.timeZone = NSTimeZone.localTimeZone;
        n.text = [f stringFromDate:v];
    } else {
        n.kind = JSONString; n.text = [v description];
    }
    return n;
}

JSONNode *JSONFromPropertyList(id plist) { return plist ? plistNode(plist, 0) : nil; }

NSUInteger JSONNodeCount(JSONNode *root, NSUInteger limit) {
    if (!root) return 0;
    NSUInteger count = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count && count < limit) {
        JSONNode *n = stack.lastObject;
        [stack removeLastObject];
        count++;
        if (n.children.count) [stack addObjectsFromArray:n.children];
    }
    return count;
}

#import "PieceTable.h"
#include <unistd.h>
#include <errno.h>

static inline uint8_t lc(uint8_t c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static BOOL matchAt(const uint8_t *h, const uint8_t *n, NSUInteger len) {
    for (NSUInteger i = 0; i < len; i++) if (lc(h[i]) != lc(n[i])) return NO;
    return YES;
}

@implementation PieceTable (Search)

// Scan match starts in [lo, hi). Forward returns the first, backward the last.
- (NSUInteger)scan:(NSData *)needle lo:(NSUInteger)lo hi:(NSUInteger)hi backward:(BOOL)back exact:(BOOL)exact {
    NSUInteger nl = needle.length, total = self.length;
    if (!nl || lo >= hi || nl > total) return NSNotFound;
    const NSUInteger chunk = 1 << 16;
    uint8_t *buf = malloc(chunk + nl);
    const uint8_t *nb = needle.bytes;
    NSUInteger found = NSNotFound;
    if (!back) {
        for (NSUInteger w = lo; w < hi && found == NSNotFound; w += chunk) {
            NSUInteger starts = MIN(chunk, hi - w);
            NSUInteger got = [self read:NSMakeRange(w, starts + nl - 1) into:buf];
            for (NSUInteger i = 0; i < starts && i + nl <= got; i++)
                if (exact ? !memcmp(buf + i, nb, nl) : matchAt(buf + i, nb, nl)) { found = w + i; break; }
        }
    } else {
        NSUInteger w = hi;
        while (w > lo && found == NSNotFound) {
            NSUInteger ws = (w - lo > chunk) ? w - chunk : lo, starts = w - ws;
            NSUInteger got = [self read:NSMakeRange(ws, starts + nl - 1) into:buf];
            for (NSUInteger i = starts; i-- > 0;)
                if (i + nl <= got && (exact ? !memcmp(buf + i, nb, nl) : matchAt(buf + i, nb, nl))) { found = ws + i; break; }
            w = ws;
        }
    }
    free(buf);
    return found;
}

- (NSUInteger)find:(NSData *)needle from:(NSUInteger)off backward:(BOOL)back {
    NSUInteger len = self.length;
    off = MIN(off, len);
    NSUInteger r = back ? [self scan:needle lo:0 hi:off backward:YES exact:NO]
                        : [self scan:needle lo:off hi:len backward:NO exact:NO];
    if (r != NSNotFound) return r;
    return back ? [self scan:needle lo:off hi:len backward:YES exact:NO]
                : [self scan:needle lo:0 hi:off backward:NO exact:NO];
}

- (NSUInteger)findExact:(NSData *)needle from:(NSUInteger)off {
    off = MIN(off, self.length);
    NSUInteger r = [self scan:needle lo:off hi:self.length backward:NO exact:YES];
    return r != NSNotFound ? r : [self scan:needle lo:0 hi:off backward:NO exact:YES];
}

- (NSData *)allExact:(NSData *)needle limit:(NSUInteger)limit {
    NSMutableData *out = [NSMutableData data];
    NSUInteger nl = needle.length, len = self.length;
    if (!nl || nl > len) return out;
    const NSUInteger chunk = 1 << 18;
    uint8_t *buf = malloc(chunk + nl);
    const uint8_t *nb = needle.bytes;
    NSUInteger next = 0, found = 0;                       // matches must start at next or later
    for (NSUInteger w = 0; w < len && found < limit; w += chunk) {
        NSUInteger got = [self read:NSMakeRange(w, chunk + nl - 1) into:buf], end = MIN(chunk, got);
        for (NSUInteger i = next > w ? next - w : 0; i < end && i + nl <= got; i++) {
            const uint8_t *p = memchr(buf + i, nb[0], end - i);
            if (!p) break;
            i = (NSUInteger)(p - buf);
            if (i + nl > got) break;
            if (memcmp(p, nb, nl)) continue;
            NSUInteger at = w + i;
            [out appendBytes:&at length:sizeof at];
            if (++found >= limit) break;
            next = at + nl; i += nl - 1;
        }
    }
    free(buf);
    return out;
}

- (NSData *)dataReplacingAll:(NSData *)needle with:(NSData *)repl count:(NSUInteger *)count offset:(NSUInteger *)offset {
    NSUInteger nl = needle.length, len = self.length, rl = repl.length, at = offset ? *offset : 0, moved = at, n = 0;
    *count = 0;
    if (!nl || nl > len) return nil;
    const NSUInteger chunk = 1 << 18;
    uint8_t *buf = malloc(chunk + nl);
    const uint8_t *nb = needle.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    NSUInteger pos = 0;                                   // everything before pos is in out
    for (NSUInteger w = 0; w < len; w += chunk) {
        NSUInteger got = [self read:NSMakeRange(w, chunk + nl - 1) into:buf], end = MIN(chunk, got);
        for (NSUInteger i = pos - w; i < end && i + nl <= got; ) {
            if (!matchAt(buf + i, nb, nl)) { i++; continue; }
            NSUInteger hit = w + i;
            [out appendBytes:buf + (pos - w) length:hit - pos];
            [out appendData:repl];
            if (at >= hit + nl) moved = moved - nl + rl;
            else if (at > hit) moved = moved - (at - hit) + rl;
            pos = hit + nl; i += nl; n++;
        }
        if (pos < w + end) { [out appendBytes:buf + (pos - w) length:w + end - pos]; pos = w + end; }
    }
    free(buf);
    *count = n;
    if (offset) *offset = moved;
    return n ? out : nil;
}

- (NSData *)dataReplacingRanges:(NSArray<NSValue *> *)ranges with:(NSData *)repl offset:(NSUInteger *)offset {
    NSUInteger pos = 0, at = offset ? *offset : 0, moved = at, len = self.length;
    NSMutableData *out = [NSMutableData dataWithCapacity:len];
    for (NSValue *v in ranges) {
        NSRange r = v.rangeValue;
        if (r.location < pos || NSMaxRange(r) > len) continue;
        [out appendData:[self dataInRange:NSMakeRange(pos, r.location - pos)]];
        [out appendData:repl];
        if (at >= NSMaxRange(r)) moved = moved - r.length + repl.length;
        else if (at > r.location) moved = moved - (at - r.location) + repl.length;
        pos = NSMaxRange(r);
    }
    [out appendData:[self dataInRange:NSMakeRange(pos, len - pos)]];
    if (offset) *offset = moved;
    return out;
}

- (BOOL)writeToFD:(int)fd {
    const NSUInteger chunk = 1 << 18;
    uint8_t *buf = malloc(chunk);
    BOOL ok = YES;
    for (NSUInteger off = 0; off < self.length && ok; off += chunk) {
        NSUInteger n = [self read:NSMakeRange(off, chunk) into:buf], done = 0;
        while (done < n) {
            ssize_t w = write(fd, buf + done, n - done);
            if (w < 0) { if (errno == EINTR) continue; ok = NO; break; }
            done += (NSUInteger)w;
        }
    }
    free(buf);
    return ok;
}

@end

static const NSUInteger kUnicodeMaxBytes = 64u << 20, kStep = 4096;

@implementation PTUnicodeIndex {
    NSString *_text;
    NSData *_bytes;
    NSMutableData *_marks;                  // UTF-16 index at every kStep-th byte (on a character start)
}

+ (BOOL)needsUnicode:(NSString *)n {
    for (NSUInteger i = 0; i < n.length; i++) if ([n characterAtIndex:i] >= 0x80) return ![n.lowercaseString isEqualToString:n.uppercaseString];
    return NO;
}

- (instancetype)initWithTable:(PieceTable *)t {
    if (t.length > kUnicodeMaxBytes || !(self = [super init])) return nil;
    _bytes = [t dataInRange:NSMakeRange(0, t.length)];
    _text = [[NSString alloc] initWithData:_bytes encoding:NSUTF8StringEncoding];
    if (!_text) return nil;
    const uint8_t *b = _bytes.bytes;
    _marks = [NSMutableData dataWithLength:(_bytes.length / kStep + 1) * sizeof(NSUInteger)];
    NSUInteger *m = _marks.mutableBytes, u = 0;
    for (NSUInteger i = 0; i < _bytes.length; i++) {
        if (i % kStep == 0) m[i / kStep] = u;
        uint8_t c = b[i];
        if ((c & 0xC0) != 0x80) u += c >= 0xF0 ? 2 : 1;
    }
    return self;
}

// kStep-aligned positions may fall inside a character; continuation bytes add no UTF-16 units, so the count holds.
- (NSUInteger)utf16For:(NSUInteger)byte {
    byte = MIN(byte, _bytes.length);
    const uint8_t *b = _bytes.bytes;
    NSUInteger k = byte / kStep, u = ((NSUInteger *)_marks.bytes)[k];
    for (NSUInteger i = k * kStep; i < byte; i++) if ((b[i] & 0xC0) != 0x80) u += b[i] >= 0xF0 ? 2 : 1;
    return u;
}

- (NSUInteger)byteFor:(NSUInteger)u16 {
    const NSUInteger *m = _marks.bytes;
    NSUInteger lo = 0, hi = _marks.length / sizeof(NSUInteger) - 1;
    while (lo < hi) { NSUInteger mid = (lo + hi + 1) / 2; if (m[mid] <= u16) lo = mid; else hi = mid - 1; }
    const uint8_t *b = _bytes.bytes;
    NSUInteger i = lo * kStep, u = m[lo];
    while (i < _bytes.length && (u < u16 || (b[i] & 0xC0) == 0x80)) { if ((b[i] & 0xC0) != 0x80) u += b[i] >= 0xF0 ? 2 : 1; i++; }
    return i;
}

- (NSRange)bytesOf:(NSRange)r { NSUInteger a = [self byteFor:r.location]; return NSMakeRange(a, [self byteFor:NSMaxRange(r)] - a); }

- (NSRange)find:(NSString *)n from:(NSUInteger)off backward:(BOOL)back {
    NSUInteger u = [self utf16For:off], len = _text.length;
    NSStringCompareOptions o = NSCaseInsensitiveSearch | (back ? NSBackwardsSearch : 0);
    NSRange r = back ? [_text rangeOfString:n options:o range:NSMakeRange(0, u)] : [_text rangeOfString:n options:o range:NSMakeRange(u, len - u)];
    if (r.location == NSNotFound) r = back ? [_text rangeOfString:n options:o range:NSMakeRange(u, len - u)] : [_text rangeOfString:n options:o range:NSMakeRange(0, u)];
    return r.location == NSNotFound ? r : [self bytesOf:r];
}

- (NSArray<NSValue *> *)allMatches:(NSString *)n {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger u = 0, len = _text.length;
    while (u < len) {
        NSRange r = [_text rangeOfString:n options:NSCaseInsensitiveSearch range:NSMakeRange(u, len - u)];
        if (r.location == NSNotFound || !r.length) break;
        [out addObject:[NSValue valueWithRange:[self bytesOf:r]]];
        u = NSMaxRange(r);
    }
    return out;
}

- (BOOL)range:(NSRange)bytes matches:(NSString *)n {
    if (NSMaxRange(bytes) > _bytes.length || !bytes.length) return NO;
    NSUInteger a = [self utf16For:bytes.location], b = [self utf16For:NSMaxRange(bytes)];
    return [[_text substringWithRange:NSMakeRange(a, b - a)] compare:n options:NSCaseInsensitiveSearch] == NSOrderedSame;
}

@end

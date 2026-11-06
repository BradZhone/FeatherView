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
- (NSUInteger)scan:(NSData *)needle lo:(NSUInteger)lo hi:(NSUInteger)hi backward:(BOOL)back {
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
                if (matchAt(buf + i, nb, nl)) { found = w + i; break; }
        }
    } else {
        NSUInteger w = hi;
        while (w > lo && found == NSNotFound) {
            NSUInteger ws = (w - lo > chunk) ? w - chunk : lo, starts = w - ws;
            NSUInteger got = [self read:NSMakeRange(ws, starts + nl - 1) into:buf];
            for (NSUInteger i = starts; i-- > 0;)
                if (i + nl <= got && matchAt(buf + i, nb, nl)) { found = ws + i; break; }
            w = ws;
        }
    }
    free(buf);
    return found;
}

- (NSUInteger)find:(NSData *)needle from:(NSUInteger)off backward:(BOOL)back {
    NSUInteger len = self.length;
    off = MIN(off, len);
    NSUInteger r = back ? [self scan:needle lo:0 hi:off backward:YES]
                        : [self scan:needle lo:off hi:len backward:NO];
    if (r != NSNotFound) return r;
    return back ? [self scan:needle lo:off hi:len backward:YES]
                : [self scan:needle lo:0 hi:off backward:NO];
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

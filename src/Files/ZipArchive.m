#import "ZipArchive.h"
#include <zlib.h>

static const NSUInteger kMaxEntryBytes = 512u << 20;

typedef struct {
    uint32_t headerOff;          // central directory record
    uint32_t localOff, compSize, size, crc;
    uint16_t method, flags, nameLen;
} ZipEntry;

static inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static inline uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static inline void wr16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static inline void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

@implementation ZipArchive {
    NSData *_data;
    NSMutableArray<NSString *> *_names;
    NSMutableDictionary<NSString *, NSValue *> *_entries;
    NSData *_comment;
}

- (instancetype)initWithData:(NSData *)data error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _data = data;
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0 && i >= (NSInteger)n - 22 - 65535; i--)
        if (rd32(b + i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { if (error) *error = @"Not a zip file"; return nil; }
    uint16_t count = rd16(b + eocd + 10);
    uint32_t cdSize = rd32(b + eocd + 12), cdOff = rd32(b + eocd + 16);
    uint16_t commentLen = rd16(b + eocd + 20);
    if (count == 0xFFFF || cdOff == 0xFFFFFFFF || (NSUInteger)cdOff + cdSize > (NSUInteger)eocd) { if (error) *error = @"Unsupported zip file (zip64)"; return nil; }
    _comment = [data subdataWithRange:NSMakeRange((NSUInteger)eocd + 22, MIN((NSUInteger)commentLen, n - (NSUInteger)eocd - 22))];
    _names = [NSMutableArray array];
    _entries = [NSMutableDictionary dictionary];
    NSUInteger p = cdOff;
    for (uint16_t k = 0; k < count; k++) {
        if (p + 46 > n || rd32(b + p) != 0x02014b50) { if (error) *error = @"Damaged zip directory"; return nil; }
        ZipEntry e = {0};
        e.headerOff = (uint32_t)p;
        e.flags = rd16(b + p + 8); e.method = rd16(b + p + 10); e.crc = rd32(b + p + 16);
        e.compSize = rd32(b + p + 20); e.size = rd32(b + p + 24);
        e.nameLen = rd16(b + p + 28);
        uint16_t extra = rd16(b + p + 30), cmt = rd16(b + p + 32);
        e.localOff = rd32(b + p + 42);
        if (p + 46 + e.nameLen + extra + cmt > n || (NSUInteger)e.localOff + 30 > n) { if (error) *error = @"Damaged zip directory"; return nil; }
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:e.nameLen encoding:NSUTF8StringEncoding]
                      ?: [[NSString alloc] initWithBytes:b + p + 46 length:e.nameLen encoding:NSISOLatin1StringEncoding];
        if (!_entries[name]) [_names addObject:name];
        _entries[name] = [NSValue valueWithBytes:&e objCType:@encode(ZipEntry)];
        p += 46 + e.nameLen + extra + cmt;
    }
    return self;
}

- (NSArray<NSString *> *)entryNames { return _names; }
- (BOOL)hasEntry:(NSString *)name { return _entries[name] != nil; }

- (ZipEntry)entry:(NSString *)name ok:(BOOL *)ok {
    ZipEntry e = {0};
    NSValue *v = _entries[name];
    *ok = v != nil;
    if (v) [v getValue:&e];
    return e;
}

// Start of the entry's data, after its local header.
- (NSUInteger)dataStart:(ZipEntry)e {
    const uint8_t *b = _data.bytes;
    if ((NSUInteger)e.localOff + 30 > _data.length || rd32(b + e.localOff) != 0x04034b50) return NSNotFound;
    return (NSUInteger)e.localOff + 30 + rd16(b + e.localOff + 26) + rd16(b + e.localOff + 28);
}

- (NSData *)dataForEntry:(NSString *)name {
    BOOL ok;
    ZipEntry e = [self entry:name ok:&ok];
    if (!ok || e.size > kMaxEntryBytes || (e.flags & 1)) return nil;               // encrypted
    NSUInteger at = [self dataStart:e];
    if (at == NSNotFound || at + e.compSize > _data.length) return nil;
    const uint8_t *src = (const uint8_t *)_data.bytes + at;
    if (e.method == 0) return e.compSize == e.size ? [NSData dataWithBytes:src length:e.size] : nil;
    if (e.method != 8) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:e.size];
    z_stream z = {0};
    if (inflateInit2(&z, -MAX_WBITS) != Z_OK) return nil;
    z.next_in = (Bytef *)src; z.avail_in = e.compSize;
    z.next_out = out.mutableBytes; z.avail_out = e.size;
    int rc = inflate(&z, Z_FINISH);
    inflateEnd(&z);
    if (rc != Z_STREAM_END || z.total_out != e.size) return nil;
    if ((uint32_t)crc32(0, out.bytes, (uInt)out.length) != e.crc) return nil;
    return out;
}

static NSData *deflateRaw(NSData *d) {
    z_stream z = {0};
    if (deflateInit2(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:deflateBound(&z, (uLong)d.length)];
    z.next_in = (Bytef *)d.bytes; z.avail_in = (uInt)d.length;
    z.next_out = out.mutableBytes; z.avail_out = (uInt)out.length;
    int rc = deflate(&z, Z_FINISH);
    out.length = z.total_out;
    deflateEnd(&z);
    return rc == Z_STREAM_END ? out : nil;
}

- (NSData *)dataReplacing:(NSDictionary<NSString *, NSData *> *)repl removing:(NSSet<NSString *> *)removed error:(NSString **)error {
    const uint8_t *b = _data.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:_data.length + 4096];
    NSMutableData *cd = [NSMutableData data];
    NSUInteger count = 0;
    NSMutableArray *order = [_names mutableCopy];
    for (NSString *k in [repl.allKeys sortedArrayUsingSelector:@selector(compare:)]) if (!_entries[k]) [order addObject:k];
    for (NSString *name in order) {
        if ([removed containsObject:name]) continue;
        if (out.length > 0xFFFFFFF0u) { if (error) *error = @"The file is too large to save (over 4 GB)"; return nil; }
        uint32_t localOff = (uint32_t)out.length;
        NSData *newData = repl[name];
        BOOL ok;
        ZipEntry e = [self entry:name ok:&ok];
        if (!newData) {
            // unchanged: local header with sizes filled in (no data descriptor), then the original bytes
            NSUInteger at = [self dataStart:e];
            if (at == NSNotFound || at + e.compSize > _data.length) { if (error) *error = [NSString stringWithFormat:@"Damaged zip entry %@", name]; return nil; }
            NSUInteger lh = e.localOff, lhLen = at - lh;
            NSMutableData *hdr = [NSMutableData dataWithBytes:b + lh length:lhLen];
            uint8_t *h = hdr.mutableBytes;
            wr16(h + 6, e.flags & ~8); wr32(h + 14, e.crc); wr32(h + 18, e.compSize); wr32(h + 22, e.size);
            [out appendData:hdr];
            [out appendBytes:b + at length:e.compSize];
            uint16_t extra = rd16(b + e.headerOff + 30), cmt = rd16(b + e.headerOff + 32);
            NSMutableData *rec = [NSMutableData dataWithBytes:b + e.headerOff length:46 + e.nameLen + extra + cmt];
            uint8_t *r = rec.mutableBytes;
            wr16(r + 8, e.flags & ~8); wr32(r + 42, localOff);
            [cd appendData:rec];
        } else {
            NSData *comp = deflateRaw(newData);
            if (!comp) { if (error) *error = @"Couldn't compress the file"; return nil; }
            NSData *nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
            uint32_t crc = (uint32_t)crc32(0, newData.bytes, (uInt)newData.length);
            uint8_t h[30] = {0};
            wr32(h, 0x04034b50); wr16(h + 4, 20); wr16(h + 6, 0x0800); wr16(h + 8, 8);
            if (ok) { wr16(h + 10, rd16(b + e.headerOff + 12)); wr16(h + 12, rd16(b + e.headerOff + 14)); }   // keep the time stamp
            wr32(h + 14, crc); wr32(h + 18, (uint32_t)comp.length); wr32(h + 22, (uint32_t)newData.length);
            wr16(h + 26, (uint16_t)nameBytes.length);
            [out appendBytes:h length:30];
            [out appendData:nameBytes];
            [out appendData:comp];
            uint8_t c[46] = {0};
            wr32(c, 0x02014b50);
            wr16(c + 4, ok ? rd16(b + e.headerOff + 4) : 20); wr16(c + 6, 20); wr16(c + 8, 0x0800); wr16(c + 10, 8);
            memcpy(c + 12, h + 10, 4);
            wr32(c + 16, crc); wr32(c + 20, (uint32_t)comp.length); wr32(c + 24, (uint32_t)newData.length);
            wr16(c + 28, (uint16_t)nameBytes.length);
            if (ok) wr32(c + 38, rd32(b + e.headerOff + 38));                               // external attributes
            wr32(c + 42, localOff);
            [cd appendBytes:c length:46];
            [cd appendData:nameBytes];
        }
        count++;
    }
    if (count > 0xFFFE) { if (error) *error = @"Too many entries"; return nil; }
    uint32_t cdOff = (uint32_t)out.length;
    [out appendData:cd];
    uint8_t eo[22] = {0};
    wr32(eo, 0x06054b50); wr16(eo + 8, (uint16_t)count); wr16(eo + 10, (uint16_t)count);
    wr32(eo + 12, (uint32_t)cd.length); wr32(eo + 16, cdOff); wr16(eo + 20, (uint16_t)_comment.length);
    [out appendBytes:eo length:22];
    [out appendData:_comment];
    return out;
}

@end

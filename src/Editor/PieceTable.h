#import <Foundation/Foundation.h>

// Text buffer: immutable original bytes (usually mmap'd) + append-only add buffer,
// stitched together by a piece list. Line starts are kept as uint32 offsets,
// so a buffer must stay below 4 GB.
@interface PieceTable : NSObject

- (instancetype)initWithData:(NSData *)data;

@property (nonatomic, readonly) NSUInteger length;
@property (nonatomic, readonly) NSUInteger lineCount;
@property (nonatomic, readonly) BOOL usesCRLF;

- (NSUInteger)lineStart:(NSUInteger)line;
// End of line content, excluding "\n" / "\r\n".
- (NSUInteger)lineEnd:(NSUInteger)line;
- (NSUInteger)lineForOffset:(NSUInteger)offset;

- (uint8_t)byteAt:(NSUInteger)offset;
- (NSUInteger)read:(NSRange)range into:(uint8_t *)out;
- (NSData *)dataInRange:(NSRange)range;

- (void)insertBytes:(const uint8_t *)bytes length:(NSUInteger)n at:(NSUInteger)offset;
- (void)deleteRange:(NSRange)range;

@end

@interface PieceTable (Search)
// ASCII case-insensitive search. Wraps around. Returns NSNotFound if absent.
- (NSUInteger)find:(NSData *)needle from:(NSUInteger)offset backward:(BOOL)backward;
- (BOOL)writeToFD:(int)fd;
// Every non-overlapping match (same matching as find:) replaced, in one pass; nil when there is none.
// *offset is moved along with the text around it (into the replacement if it was inside a match).
- (NSData *)dataReplacingAll:(NSData *)needle with:(NSData *)replacement count:(NSUInteger *)count offset:(NSUInteger *)offset;
// Byte ranges (sorted, not overlapping) replaced; *offset follows the text as above.
- (NSData *)dataReplacingRanges:(NSArray<NSValue *> *)ranges with:(NSData *)replacement offset:(NSUInteger *)offset;
@end

// Case-insensitive search for text whose case folding isn't ASCII ("Ä" finds "ä"), on a decoded copy.
// Build one per buffer state; nil when the text is too large or not valid UTF-8.
@interface PTUnicodeIndex : NSObject
+ (BOOL)needsUnicode:(NSString *)needle;
- (instancetype)initWithTable:(PieceTable *)table;
- (NSRange)find:(NSString *)needle from:(NSUInteger)offset backward:(BOOL)backward;     // bytes; wraps around
- (NSArray<NSValue *> *)allMatches:(NSString *)needle;                               // bytes
- (BOOL)range:(NSRange)bytes matches:(NSString *)needle;
@end

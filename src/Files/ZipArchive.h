#import <Foundation/Foundation.h>

// Reads a zip file (stored or deflated entries, no zip64) and writes a copy in which chosen entries are
// replaced, added or removed. Every other entry is copied byte for byte, compressed data included, so
// rewriting an Office file touches only the parts that changed.
@interface ZipArchive : NSObject
- (instancetype)initWithData:(NSData *)data error:(NSString **)error;
@property (nonatomic, readonly) NSArray<NSString *> *entryNames;      // in archive order
- (NSData *)dataForEntry:(NSString *)name;                           // nil if missing or unreadable
- (BOOL)hasEntry:(NSString *)name;
// replacements: name → new contents (deflated); a name not yet present is added at the end.
- (NSData *)dataReplacing:(NSDictionary<NSString *, NSData *> *)replacements removing:(NSSet<NSString *> *)removed error:(NSString **)error;
@end

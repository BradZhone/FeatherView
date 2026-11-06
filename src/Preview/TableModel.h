#import <Foundation/Foundation.h>

// Rows × columns of text, for the table view. Row and column indices are 0-based and exclude the header.
@protocol TableModel <NSObject>
@property (nonatomic, readonly) NSUInteger rowCount, columnCount;
- (NSString *)headerForColumn:(NSUInteger)c;
- (NSString *)cellAtRow:(NSUInteger)r column:(NSUInteger)c;     // never nil
@optional
- (NSUInteger)sourceLineOfRow:(NSUInteger)r;                     // 1-based line in the file
@property (nonatomic, readonly) BOOL truncated;                  // too big: only the first rows were read
@end

// RFC 4180 CSV / TSV: quoted fields, "" escapes, line breaks inside quotes, CRLF, BOM.
// Cells are kept as byte ranges into the data, so a large file costs ~8 bytes per cell.
@interface CSVTable : NSObject <TableModel>
// delimiter 0 = detect (, ; tab |). hasHeader: -1 detect, 0 no, 1 yes.
+ (instancetype)tableWithData:(NSData *)utf8 delimiter:(unichar)delimiter hasHeader:(NSInteger)hasHeader maxRows:(NSUInteger)maxRows;
+ (unichar)sniffDelimiter:(NSData *)utf8 hint:(unichar)hint;     // hint: the extension's delimiter, or 0
@property (nonatomic, readonly) unichar delimiter;
@property (nonatomic, readonly) BOOL hasHeader;
@end

// JSON Lines (.jsonl / .ndjson): one object per line; columns are the keys in first-seen order.
@interface JSONLinesTable : NSObject <TableModel>
+ (instancetype)tableWithData:(NSData *)utf8 maxRows:(NSUInteger)maxRows;
@property (nonatomic, readonly) NSUInteger badLines;             // lines that weren't a JSON object
@end

// Rows held in memory (SQLite results).
@interface ArrayTable : NSObject <TableModel>
+ (instancetype)tableWithHeaders:(NSArray<NSString *> *)headers rows:(NSArray<NSArray<NSString *> *> *)rows truncated:(BOOL)truncated;
@end

#import <Cocoa/Cocoa.h>
#import "DataPreviews.h"
@protocol TableModel;

// Spreadsheet-like view of CSV / TSV / JSON Lines (or any TableModel): row numbers, click a header to sort
// (numbers sort as numbers), a filter box ("列名:文字" limits it to one column), ⌘C copies rows as TSV.
@interface TablePreview : NSView <FTDataPreview, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate>
- (void)setModel:(id<TableModel>)model;                    // SQLite / archives: no header / delimiter options
@property (nonatomic, readonly) id<TableModel> model;
@property (nonatomic, readonly) NSTableView *tableView;
@property (nonatomic, readonly) NSUInteger visibleRowCount;
@property (nonatomic, copy) NSString *filterText;          // small tables apply it at once (tests)
- (NSString *)displayedCellAtRow:(NSUInteger)row column:(NSUInteger)column;
@property (nonatomic, readonly) NSString *infoText;
@property (nonatomic, copy) NSString *extraInfo;           // after the row count (archives: total size)
@property (nonatomic, copy) void (^onActivateRow)(NSUInteger modelRow);   // double click when rows have no source line
@property (nonatomic) NSInteger headerChoice;              // CSV: -1 detect, 0 no header, 1 first row is the header
@end

@interface TablePreview (Sorting)
- (void)sortByColumn:(NSInteger)column ascending:(BOOL)ascending;   // -1 = file order
@end

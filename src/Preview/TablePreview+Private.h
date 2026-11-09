#import "TablePreview.h"
#import "TableModel.h"

static const NSUInteger kMaxShownColumns = 1000;     // a table view with more columns stops responding

@interface TablePreview () {
@public
    NSSearchField *_filter;
    NSButton *_headerBox;
    NSPopUpButton *_delimPopup;
    NSTextField *_info;
    NSTableView *_table;
    NSScrollView *_scroll;
    id<TableModel> _model;
    NSMutableData *_order;                 // uint32: display row → model row; nil = every row in file order
    NSUInteger _parseGen, _orderGen;
    NSInteger _sortColumn;                 // -1 none
    BOOL _sortAscending, _working, _keepScroll;
    NSMutableDictionary<NSNumber *, NSNumber *> *_numeric;   // column → looks numeric
    NSString *_path, *_status;
    NSData *_source;                       // the CSV text, for re-parsing with another header / delimiter choice
    unichar _delimChoice;                  // 0 detect
    NSTimer *_filterTimer;
}
- (void)rebuildColumns;
- (NSUInteger)shownColumns;              // at most kMaxShownColumns of the model's
- (NSUInteger)modelRow:(NSInteger)displayRow;
- (BOOL)columnIsNumeric:(NSUInteger)c;
@end

@interface TablePreview (Order)          // sorting, filtering, copy and the context menu
- (void)applyOrder;
- (void)updateInfo;
- (void)doubleClicked:(id)sender;
@end

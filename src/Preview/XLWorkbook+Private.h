#import "XLWorkbook.h"
#import "XLXML.h"
#import "XLNumberFormat.h"
#import "ZipArchive.h"

static const NSUInteger kXLMaxCells = 2000000;           // beyond this a sheet is shown truncated and read-only

static inline uint64_t XLKey(NSUInteger row, NSUInteger col) { return ((uint64_t)row << 16) | col; }
static inline NSUInteger XLKeyRow(uint64_t k) { return (NSUInteger)(k >> 16); }
static inline NSUInteger XLKeyCol(uint64_t k) { return (NSUInteger)(k & 0xFFFF); }

typedef struct {
    uint64_t key;
    double num;              // number / bool / shared-string index
    uint32_t str;            // index into the sheet's strings (inline strings, errors, formula strings), or UINT32_MAX
    uint32_t style;          // cellXfs index
    uint32_t xmlOff, xmlLen; // the <c …>…</c> element in the worksheet part
    XLType type;
    uint8_t flags;           // bit 0 formula, 1 shared-string, 2 rich text, 3 shared-formula master, 4 shared-formula child
} XLCell;

enum { XLFFormula = 1, XLFShared = 2, XLFRich = 4, XLFMaster = 8, XLFChild = 16 };

typedef struct { uint32_t row; uint32_t openOff, openLen, closeOff; uint32_t style; BOOL selfClosing, customFormat; } XLRow;

// A pending edit. kind: 0 clear, 1 number, 2 string, 3 bool, 4 formula.
@interface XLEdit : NSObject
@property (nonatomic) uint8_t kind;
@property (nonatomic) double number;
@property (nonatomic, copy) NSString *text;                  // string, or formula without "="
@end

@interface XLStyle ()
@property (nonatomic) NSUInteger numFmtId;
@end

@interface XLWorkbook () {
@public
    ZipArchive *_zip;
    NSArray<NSString *> *_shared;                // shared strings (plain text)
    NSMutableIndexSet *_sharedRich;
    NSArray<XLStyle *> *_styles;                 // cellXfs
    NSArray<NSNumber *> *_themeColors;           // 12 ARGB
    NSString *_workbookPath;
}
@end

@interface XLWorkbook (Styles)
- (uint32_t)colorFrom:(const uint8_t *)x tag:(const XLTag *)t;          // rgb / theme+tint / indexed
- (XLStyle *)style:(NSUInteger)i;
- (void)loadStyles:(NSData *)xml;
- (void)loadTheme:(NSData *)xml;
@end

@interface XLSheet () {
@public
    __weak XLWorkbook *_book;
    NSString *_path;                              // worksheet part, e.g. xl/worksheets/sheet1.xml
    XLCell *_cells; NSUInteger _cellCount;
    XLRow *_rows; NSUInteger _rowCount2;
    NSMutableArray<NSString *> *_strings;
    NSMutableDictionary<NSNumber *, NSString *> *_formulas;     // key → formula text (no "=")
    NSMutableDictionary<NSNumber *, NSNumber *> *_sharedMaster; // shared index → master key
    NSMutableDictionary<NSNumber *, NSNumber *> *_sharedOf;     // child key → shared index
    NSMutableIndexSet *_mastersWithChildren;                     // shared indices that have children
    BOOL _loaded, _sheetDataSelfClosing;
    NSUInteger _sheetDataOff, _sheetDataLen;
    NSMutableArray<NSValue *> *_arrays, *_tableHeads, *_mergeList;
    NSMutableDictionary<NSNumber *, NSValue *> *_mergeAt;      // every covered cell → its merge
    NSMutableDictionary<NSNumber *, NSNumber *> *_colWidth, *_rowHeight, *_colStyle;
    NSMutableIndexSet *_hiddenCols, *_hiddenRows;
    NSMutableDictionary<NSNumber *, XLEdit *> *_edits;
    NSCache *_display;
    NSUInteger _usedRows, _usedCols, _sheetDataClose, _dimOff, _dimLen;
    NSString *_prefix;                            // namespace prefix of the cell elements ("" or "x:")
    BOOL _protected, _truncated, _showGridLines;
    double _defaultColWidth, _defaultRowHeight;
    NSUInteger _frozenRows, _frozenColumns;
}
- (instancetype)initWithName:(NSString *)name path:(NSString *)path book:(XLWorkbook *)book hidden:(BOOL)hidden chart:(BOOL)chart;
- (void)parse:(NSData *)xml;
- (void)ensureLoaded;
- (void)addTable:(NSData *)xml;
- (const XLCell *)cellAt:(NSUInteger)row col:(NSUInteger)col;
- (const XLRow *)rowRecord:(NSUInteger)r;
- (NSUInteger)rowIndexAfter:(NSUInteger)r;
@end

@interface XLSheet (Save)
- (NSData *)patchedXML:(NSData *)xml error:(NSString **)error;
@end

NSString *XLNumberString(double v);                                             // shortest text that reads back as v
NSDictionary<NSString *, NSArray<NSString *> *> *XLRels(ZipArchive *zip, NSString *part);

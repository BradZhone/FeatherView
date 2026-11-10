#import <Foundation/Foundation.h>

// An .xlsx workbook: values, number formats, fonts, fills, borders, merges, sizes and frozen panes, read
// from the package; edits are kept aside and written back by splicing only the edited cells into their
// worksheet XML, so every other part of the file stays byte-identical. Formulas are stored, not computed:
// a saved workbook asks Excel / Numbers to recalculate when opened.

typedef NS_ENUM(uint8_t, XLType) { XLEmpty = 0, XLNumber, XLString, XLBool, XLError };
typedef NS_ENUM(uint8_t, XLHAlign) { XLAlignGeneral = 0, XLAlignLeft, XLAlignCenter, XLAlignRight, XLAlignFill, XLAlignJustify };
typedef NS_ENUM(uint8_t, XLVAlign) { XLAlignBottom = 0, XLAlignVCenter, XLAlignTop };
typedef NS_ENUM(uint8_t, XLLine) { XLLineNone = 0, XLLineThin, XLLineMedium, XLLineThick, XLLineDashed, XLLineDotted, XLLineDouble, XLLineHair };

// Colours are 0xAARRGGBB; 0 means "not set".
@interface XLStyle : NSObject
@property (nonatomic, copy) NSString *fontName;
@property (nonatomic) double fontSize;                       // points
@property (nonatomic) BOOL bold, italic, underline, strike;
@property (nonatomic) uint32_t fontColor, fillColor;
@property (nonatomic) XLHAlign hAlign;
@property (nonatomic) XLVAlign vAlign;
@property (nonatomic) BOOL wrap;
@property (nonatomic) NSInteger indent;
@property (nonatomic) XLLine left, right, top, bottom;
@property (nonatomic) uint32_t leftColor, rightColor, topColor, bottomColor;
@property (nonatomic, copy) NSString *numberFormat;          // the code; "General" when unset
@property (nonatomic) BOOL isDate;
@end

typedef struct { NSUInteger row, col, lastRow, lastCol; } XLRange;   // inclusive

@interface XLSheet : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) BOOL hidden, isChart;
@property (nonatomic, readonly) BOOL truncated;              // more cells than are loaded: read-only
@property (nonatomic, readonly) NSString *readOnlyReason;    // nil when the sheet can be edited
@property (nonatomic, readonly) NSUInteger rowCount, columnCount;   // used area (at least 1 × 1)
@property (nonatomic, readonly) NSUInteger frozenRows, frozenColumns;
@property (nonatomic, readonly) BOOL showGridLines;
@property (nonatomic, readonly) double defaultRowHeight;     // points
- (double)widthOfColumn:(NSUInteger)c;                       // points; 0 if hidden
- (double)heightOfRow:(NSUInteger)r;                         // points; 0 if hidden
@property (nonatomic, readonly) NSArray<NSValue *> *merges;  // XLRange in NSValue (valueWithBytes:)
- (BOOL)mergeAt:(NSUInteger)row col:(NSUInteger)col range:(XLRange *)range;
@end

@interface XLSheet (Edit)
- (XLType)typeAt:(NSUInteger)row col:(NSUInteger)col;
- (NSString *)displayAt:(NSUInteger)row col:(NSUInteger)col colour:(uint32_t *)colour;   // as Excel shows it
- (NSString *)editTextAt:(NSUInteger)row col:(NSUInteger)col;      // what the formula bar shows (formula with "=")
- (XLStyle *)styleAt:(NSUInteger)row col:(NSUInteger)col;
- (BOOL)isEditedAt:(NSUInteger)row col:(NSUInteger)col;
- (BOOL)isUncomputedFormulaAt:(NSUInteger)row col:(NSUInteger)col;   // shows its formula: no value is stored
- (NSString *)whyReadOnlyAt:(NSUInteger)row col:(NSUInteger)col;   // nil = editable
// Sets a cell from what the user typed: "=SUM(A1:A3)", "12.5", "15%", "TRUE", "2026-01-05" (date cells), text,
// "'0123" for literal text, "" to clear. Returns NO with *error for read-only cells.
- (BOOL)setText:(NSString *)text atRow:(NSUInteger)row col:(NSUInteger)col error:(NSString **)error;
@end

@interface XLWorkbook : NSObject
- (instancetype)initWithData:(NSData *)data error:(NSString **)error;
@property (nonatomic, readonly) NSArray<XLSheet *> *sheets;
@property (nonatomic, readonly) NSUInteger activeSheet;      // as saved in the file
@property (nonatomic, readonly) BOOL date1904;
@property (nonatomic, readonly) BOOL hasEdits, hasFormulaEdits;
@end

@interface XLWorkbook (Save)
- (NSData *)savedData:(NSString **)error;                      // the package with the edits spliced in
@end

NSString *XLShiftFormula(NSString *formula, NSInteger dRow, NSInteger dCol);   // A1 references moved, $-anchored and quoted parts kept

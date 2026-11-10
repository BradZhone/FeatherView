#import <Foundation/Foundation.h>

// Excel number format codes ("#,##0.00", "0.0%", "yyyy-mm-dd", "[Red]-0;0", "@" …) applied to a value.
// Covers sections, colours, literals, thousands separators and scaling, percent, scientific, fractions
// are shown as decimals, dates and times (including elapsed [h]:mm). Not locale-aware: decimal point "."
// and separator ",", as the file stores them.

NSString *XLBuiltinFormat(NSUInteger numFmtId);                  // nil for an id without a fixed code
BOOL XLFormatIsDate(NSString *code);
// colour: set to an ARGB colour when the section names one ([Red] …), else left alone.
NSString *XLFormatNumber(double v, NSString *code, BOOL date1904, uint32_t *colour);
NSString *XLFormatText(NSString *text, NSString *code);          // the "@" section, if any
NSString *XLGeneral(double v);                                    // the General format
// Excel serial date ↔ components (date1904: the Mac 1904 date system)
BOOL XLSerialToDate(double serial, BOOL date1904, NSDateComponents *out);
double XLDateToSerial(NSInteger y, NSInteger m, NSInteger d, double dayFraction, BOOL date1904);

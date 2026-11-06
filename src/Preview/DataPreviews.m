#import "DataPreviews.h"

NSNotificationName const FTDataFontSizeDidChange = @"FTDataFontSizeDidChange";
static CGFloat gSize = 12;

CGFloat FTDataFontSize(void) { return gSize; }
void FTSetDataFontSize(CGFloat s) {
    gSize = MIN(MAX(s, 9), 28);
    [NSNotificationCenter.defaultCenter postNotificationName:FTDataFontSizeDidChange object:nil];
}
NSFont *FTDataFont(void) { return [NSFont systemFontOfSize:gSize]; }
NSFont *FTDataDigitsFont(void) { return [NSFont monospacedDigitSystemFontOfSize:gSize weight:NSFontWeightRegular]; }
CGFloat FTDataRowHeight(void) { NSFont *f = FTDataFont(); return ceil(f.ascender - f.descender + f.leading) + 6; }

NSString *FTGrouped(NSUInteger n) {
    static NSNumberFormatter *f;
    if (!f) { f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"]; }
    return [f stringFromNumber:@(n)];
}

void FTCopyString(NSString *s) {
    if (!s) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

#import "Localization.h"

static NSDictionary<NSString *, NSString *> *gTable;      // set by tests only

void FTSetLocalizationFolder(NSString *lprojPath) {
    gTable = lprojPath ? [NSDictionary dictionaryWithContentsOfFile:[lprojPath stringByAppendingPathComponent:@"Localizable.strings"]] : nil;
}

NSString *FTLocalized(NSString *key) {
    if (gTable) return gTable[key] ?: key;
    return [NSBundle.mainBundle localizedStringForKey:key value:key table:nil];
}

NSString *FTLocalizedPlural(NSUInteger n, NSString *one, NSString *other) {
    return FTLocalized(n == 1 ? one : other);
}

#import <Foundation/Foundation.h>

// UI text. The key is the English text (the development language); other languages live in
// Resources/<lang>.lproj/Localizable.strings and are picked by macOS from the user's language order.
// tests/editor_tests.m checks that every FTL / FTLP key has a translation with the same format specifiers.
NSString *FTLocalized(NSString *key) NS_FORMAT_ARGUMENT(1);
#define FTL(key) FTLocalized(key)

// Count-dependent text: the singular form for exactly 1 in English, the plural form otherwise.
// Languages without plural forms translate both keys the same way.
NSString *FTLocalizedPlural(NSUInteger n, NSString *one, NSString *other) NS_FORMAT_ARGUMENT(2) NS_FORMAT_ARGUMENT(3);
#define FTLP(n, one, other) FTLocalizedPlural((n), one, other)

// Tests: look strings up in this .lproj folder instead of the main bundle (nil = main bundle).
void FTSetLocalizationFolder(NSString *lprojPath);

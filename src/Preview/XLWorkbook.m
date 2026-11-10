#import "XLWorkbook+Private.h"
#import "Localization.h"

@implementation XLEdit @end

// "worksheets/sheet1.xml" relative to "xl/workbook.xml" → "xl/worksheets/sheet1.xml"
NSString *XLResolvePart(NSString *base, NSString *target) {
    if ([target hasPrefix:@"/"]) return [target substringFromIndex:1];
    NSMutableArray *parts = [[base.stringByDeletingLastPathComponent componentsSeparatedByString:@"/"] mutableCopy];
    [parts removeObject:@""];
    for (NSString *p in [target componentsSeparatedByString:@"/"]) {
        if ([p isEqual:@".."]) { if (parts.count) [parts removeLastObject]; }
        else if (p.length && ![p isEqual:@"."]) [parts addObject:p];
    }
    return [parts componentsJoinedByString:@"/"];
}

NSString *XLRelsPath(NSString *part) {
    return [[part.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"_rels"] stringByAppendingPathComponent:[part.lastPathComponent stringByAppendingString:@".rels"]];
}

// Id → @[type (last path component), resolved target]
NSDictionary<NSString *, NSArray<NSString *> *> *XLRels(ZipArchive *zip, NSString *part) {
    NSData *d = [zip dataForEntry:XLRelsPath(part)];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    const uint8_t *x = d.bytes; NSUInteger n = d.length, i = 0;
    XLTag t;
    while (d && XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (t.closing || !XLTagIs(x, &t, "Relationship")) continue;
        NSString *rid = XLAttr(x, &t, "Id"), *target = XLAttr(x, &t, "Target"), *type = XLAttr(x, &t, "Type").lastPathComponent ?: @"";
        if (!rid || !target || [XLAttr(x, &t, "TargetMode") isEqual:@"External"]) continue;
        out[rid] = @[type, XLResolvePart(part, target)];
    }
    return out;
}

@implementation XLWorkbook {
    NSMutableArray<XLSheet *> *_sheetList;
}

- (instancetype)initWithData:(NSData *)data error:(NSString **)error {
    if (!(self = [super init])) return nil;
    NSString *zerr = nil;
    _zip = [[ZipArchive alloc] initWithData:data error:&zerr];
    if (!_zip) { if (error) *error = FTL(@"This isn’t a valid Excel workbook (it can’t be read as a package)"); return nil; }
    _workbookPath = @"xl/workbook.xml";
    for (NSArray *r in XLRels(_zip, @"").allValues) if ([r[0] isEqual:@"officeDocument"]) _workbookPath = r[1];
    NSData *wb = [_zip dataForEntry:_workbookPath];
    if (!wb) { if (error) *error = FTL(@"This isn’t a valid Excel workbook (it has no workbook part)"); return nil; }
    if ([_zip hasEntry:@"EncryptedPackage"] || [_zip hasEntry:@"EncryptionInfo"]) { if (error) *error = FTL(@"This workbook is password-protected"); return nil; }
    NSDictionary *rels = XLRels(_zip, _workbookPath);
    NSString *stylesPath = nil, *sharedPath = nil, *themePath = nil;
    for (NSArray *r in rels.allValues) {
        if ([r[0] isEqual:@"styles"]) stylesPath = r[1];
        else if ([r[0] isEqual:@"sharedStrings"]) sharedPath = r[1];
        else if ([r[0] isEqual:@"theme"]) themePath = r[1];
    }
    NSData *theme = themePath ? [_zip dataForEntry:themePath] : nil;
    if (theme) [self loadTheme:theme];
    if (_themeColors.count < 12)
        _themeColors = @[@0xFFFFFFFF, @0xFF000000, @0xFFE7E6E6, @0xFF44546A, @0xFF4472C4, @0xFFED7D31, @0xFFA5A5A5, @0xFFFFC000, @0xFF5B9BD5, @0xFF70AD47, @0xFF0563C1, @0xFF954F72];
    NSData *styles = stylesPath ? [_zip dataForEntry:stylesPath] : nil;
    if (styles) [self loadStyles:styles];
    [self loadShared:sharedPath ? [_zip dataForEntry:sharedPath] : nil];

    _sheetList = [NSMutableArray array];
    const uint8_t *x = wb.bytes; NSUInteger n = wb.length, i = 0;
    XLTag t;
    while (XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (t.closing) continue;
        if (XLTagIs(x, &t, "workbookPr")) { NSString *v = XLAttr(x, &t, "date1904"); _date1904 = [v isEqual:@"1"] || [v isEqual:@"true"]; }
        else if (XLTagIs(x, &t, "workbookView")) _activeSheet = (NSUInteger)XLAttr(x, &t, "activeTab").integerValue;
        else if (XLTagIs(x, &t, "sheet")) {
            NSString *rid = XLAttrLocal(x, &t, "id");
            NSArray *rel = rid ? rels[rid] : nil;
            if (!rel) continue;
            NSString *state = XLAttr(x, &t, "state");
            XLSheet *s = [[XLSheet alloc] initWithName:XLAttr(x, &t, "name") ?: @"Sheet" path:rel[1] book:self
                                                hidden:[state isEqual:@"hidden"] || [state isEqual:@"veryHidden"] chart:![rel[0] isEqual:@"worksheet"]];
            [_sheetList addObject:s];
        }
    }
    if (!_sheetList.count) { if (error) *error = FTL(@"This workbook has no sheets"); return nil; }
    _activeSheet = MIN(_activeSheet, _sheetList.count - 1);
    return self;
}

- (NSArray<XLSheet *> *)sheets { return _sheetList; }

- (void)loadShared:(NSData *)d {
    NSMutableArray *out = [NSMutableArray array];
    _sharedRich = [NSMutableIndexSet indexSet];
    const uint8_t *x = d.bytes; NSUInteger n = d.length, i = 0;
    XLTag t;
    NSMutableString *cur = nil;
    BOOL phonetic = NO, rich = NO;
    while (d && XLNextTag(x, n, i, &t)) {
        i = t.end;
        if (XLTagIs(x, &t, "si")) {
            if (t.selfClosing) { [out addObject:@""]; continue; }
            if (!t.closing) { cur = [NSMutableString string]; rich = NO; continue; }
            if (rich) [_sharedRich addIndex:out.count];
            [out addObject:XLDecodeOOXML(cur ?: @"")]; cur = nil; continue;
        }
        if (XLTagIs(x, &t, "rPh")) { phonetic = !t.closing && !t.selfClosing; continue; }
        if (XLTagIs(x, &t, "r") && !t.closing) rich = YES;
        if (cur && !phonetic && XLTagIs(x, &t, "t") && !t.closing && !t.selfClosing) {
            XLTag e;
            if (XLNextTag(x, n, t.end, &e)) { [cur appendString:XLDecode(x + t.end, e.start - t.end)]; i = e.end; }
        }
    }
    _shared = out;
}

- (BOOL)hasEdits { for (XLSheet *s in _sheetList) if (s->_edits.count) return YES; return NO; }
- (BOOL)hasFormulaEdits {
    for (XLSheet *s in _sheetList) for (NSNumber *k in s->_edits) if (s->_edits[k].kind == 4 || s->_formulas[k]) return YES;
    return NO;
}

@end

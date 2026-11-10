#import "OfficeViews.h"
#import "SheetGrid.h"
#import "XLWorkbook.h"
#import "XLXML.h"
#import "FileOps.h"
#import "Localization.h"
#import "CanvasView.h"

static const CGFloat kBarH = 30, kTabsH = 28;

@interface SheetUndo : NSObject
@property (nonatomic) NSUInteger sheet, row, col;
@property (nonatomic, copy) NSString *before, *after;
@end
@implementation SheetUndo @end

NSURL *FTOtherAppFor(NSString *path) {
    NSURL *u = [NSURL fileURLWithPath:path];
    NSString *me = NSBundle.mainBundle.bundleIdentifier;
    NSURL *def = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:u];
    if (def && ![[NSBundle bundleWithURL:def].bundleIdentifier isEqualToString:me]) return def;
    if (@available(macOS 12.0, *)) {
        for (NSURL *a in [NSWorkspace.sharedWorkspace URLsForApplicationsToOpenURL:u])
            if (![[NSBundle bundleWithURL:a].bundleIdentifier isEqualToString:me]) return a;
    }
    return nil;
}

NSButton *FTOpenInAppButton(NSString *path, id target, SEL action) {
    NSURL *app = FTOtherAppFor(path);
    if (!app) return nil;
    NSString *name = [NSFileManager.defaultManager displayNameAtPath:app.path].stringByDeletingPathExtension;
    NSButton *b = [NSButton buttonWithTitle:[NSString stringWithFormat:FTL(@"Open in %@"), name] target:target action:action];
    b.bezelStyle = NSBezelStyleRecessed;
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11.5];
    b.toolTip = FTL(@"Edit this file in its own app");
    return b;
}

@implementation SpreadsheetPreview {
    XLWorkbook *_book;
    NSView *_bar, *_tabs;
    NSTextField *_cellName, *_formula;
    NSButton *_openIn;
    NSScrollView *_tabScroll;
    NSStackView *_tabStack;
    NSMutableArray<SheetUndo *> *_undo, *_redo;
    NSUInteger _sheetIndex;
    NSString *_note;
}
@synthesize onChange = _onChange;

- (instancetype)initWithFrame:(NSRect)f path:(NSString *)path error:(NSString **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:nil];     // read, not mapped: saving may write in place
    XLWorkbook *b = data ? [[XLWorkbook alloc] initWithData:data error:error] : nil;
    if (!b) { if (error && !*error) *error = FTL(@"Couldn’t read the file"); return nil; }
    if (!(self = [super initWithFrame:f])) return nil;
    FTClipToBounds(self);
    _book = b; _path = [path copy];
    _undo = [NSMutableArray array]; _redo = [NSMutableArray array];
    [self buildViews];
    NSUInteger first = b.activeSheet;
    if (first < b.sheets.count && b.sheets[first].hidden) for (NSUInteger i = 0; i < b.sheets.count; i++) if (!b.sheets[i].hidden) { first = i; break; }
    [self showSheet:first];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (XLWorkbook *)workbook { return _book; }
- (NSUInteger)sheetIndex { return _sheetIndex; }
- (BOOL)isDirty { return _book.hasEdits; }
- (NSView *)focusView { return _grid; }
- (NSView *)toolsView { return nil; }

static NSTextField *barField(NSString *placeholder, CGFloat w) {
    NSTextField *t = [NSTextField textFieldWithString:@""];
    t.placeholderString = placeholder;
    t.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    t.controlSize = NSControlSizeSmall;
    t.bezelStyle = NSTextFieldRoundedBezel;
    t.frame = NSMakeRect(0, 0, w, 22);
    return t;
}

- (void)buildViews {
    _bar = [[NSView alloc] initWithFrame:NSZeroRect];
    _cellName = barField(@"A1", 80);
    _cellName.alignment = NSTextAlignmentCenter;
    _cellName.delegate = self;
    _cellName.toolTip = FTL(@"Type a cell such as B12 and press Return to go there");
    _formula = barField(FTL(@"Value or =formula"), 300);
    _formula.delegate = self;
    _openIn = FTOpenInAppButton(_path, self, @selector(openInApp:));
    for (NSView *v in @[_cellName, _formula]) [_bar addSubview:v];
    if (_openIn) [_bar addSubview:_openIn];
    _grid = [[SheetGrid alloc] initWithFrame:NSZeroRect];
    __weak SpreadsheetPreview *weakSelf = self;
    _grid.onSelect = ^{ [weakSelf syncBar]; };
    _grid.onEditingText = ^(NSString *t) { SpreadsheetPreview *me = weakSelf; if (me) me->_formula.stringValue = t; };
    _grid.onEdit = ^BOOL(NSUInteger r, NSUInteger c, NSString *t) { return [weakSelf setText:t row:r col:c]; };
    _grid.onMessage = ^(NSString *m) { [weakSelf message:m]; };
    _grid.zoom = [NSUserDefaults.standardUserDefaults doubleForKey:@"sheetZoom"] ?: 1;
    _tabs = [[NSView alloc] initWithFrame:NSZeroRect];
    _tabStack = [NSStackView stackViewWithViews:@[]];
    _tabStack.spacing = 2;
    _tabStack.edgeInsets = NSEdgeInsetsMake(0, 6, 0, 6);
    _tabScroll = [NSScrollView new];
    _tabScroll.documentView = _tabStack;
    _tabScroll.hasHorizontalScroller = NO;
    _tabScroll.drawsBackground = NO;
    [_tabs addSubview:_tabScroll];
    [self rebuildTabs];
    for (NSView *v in @[_bar, _grid, _tabs]) [self addSubview:v];
    [self layoutParts];
}

- (void)rebuildTabs {
    for (NSView *v in _tabStack.arrangedSubviews.copy) [v removeFromSuperview];
    for (NSUInteger i = 0; i < _book.sheets.count; i++) {
        XLSheet *s = _book.sheets[i];
        NSString *title = s.hidden ? [NSString stringWithFormat:FTL(@"%@ (hidden)"), s.name] : s.name;
        NSButton *b = [NSButton buttonWithTitle:title target:self action:@selector(tabClicked:)];
        b.bezelStyle = NSBezelStyleRecessed;
        [b setButtonType:NSButtonTypePushOnPushOff];
        b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:12];
        b.tag = (NSInteger)i;
        b.state = i == _sheetIndex ? NSControlStateValueOn : NSControlStateValueOff;
        if (s.isChart) b.toolTip = FTL(@"Chart sheet: open the file in Excel or Numbers to see it");
        [_tabStack addArrangedSubview:b];
    }
    [_tabStack layoutSubtreeIfNeeded];
    _tabStack.frame = NSMakeRect(0, 0, MAX(_tabStack.fittingSize.width, 10), kTabsH);
}

- (void)resizeSubviewsWithOldSize:(NSSize)old { [self layoutParts]; }

- (void)layoutParts {
    NSRect b = self.bounds;
    CGFloat w = b.size.width;
    _bar.frame = NSMakeRect(0, 0, w, kBarH);
    _cellName.frame = NSMakeRect(8, 4, 84, 22);
    CGFloat openW = _openIn ? ceil(_openIn.fittingSize.width) + 4 : 0;
    _formula.frame = NSMakeRect(98, 4, MAX(80, w - 98 - 8 - (openW ? openW + 8 : 0)), 22);
    if (_openIn) _openIn.frame = NSMakeRect(w - 8 - openW, 4, openW, 22);
    _tabs.frame = NSMakeRect(0, b.size.height - kTabsH, w, kTabsH);
    _tabScroll.frame = NSMakeRect(0, 2, w, kTabsH - 4);
    _grid.frame = NSMakeRect(0, kBarH, w, MAX(0, b.size.height - kBarH - kTabsH));
}

- (void)drawRect:(NSRect)r {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(r);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, kBarH - 1, self.bounds.size.width, 1));
    NSRectFill(NSMakeRect(0, self.bounds.size.height - kTabsH, self.bounds.size.width, 1));
}

- (void)tabClicked:(NSButton *)b { [self showSheet:(NSUInteger)b.tag]; [self.window makeFirstResponder:_grid]; }

- (void)showSheet:(NSUInteger)i {
    if (i >= _book.sheets.count) return;
    [_grid commitEditing];
    _sheetIndex = i;
    _grid.sheet = _book.sheets[i];
    for (NSButton *b in _tabStack.arrangedSubviews) b.state = (NSUInteger)b.tag == i ? NSControlStateValueOn : NSControlStateValueOff;
    [self syncBar];
    [self changed];
}

- (void)syncBar {
    XLSheet *s = _grid.sheet;
    XLRange r = _grid.selection;
    _cellName.stringValue = r.row == r.lastRow && r.col == r.lastCol ? XLCellName(_grid.row, _grid.col)
                          : [NSString stringWithFormat:@"%@:%@", XLCellName(r.row, r.col), XLCellName(r.lastRow, r.lastCol)];
    if (!_grid.isEditing) _formula.stringValue = [s editTextAt:_grid.row col:_grid.col] ?: @"";
    NSString *why = [s whyReadOnlyAt:_grid.row col:_grid.col];
    _formula.editable = why == nil;
    _formula.toolTip = why;
    [self changed];
}

- (void)message:(NSString *)m { if (self.onMessage) self.onMessage(m); }

- (BOOL)setText:(NSString *)text row:(NSUInteger)row col:(NSUInteger)col {
    XLSheet *s = _book.sheets[_sheetIndex];
    NSString *before = [s editTextAt:row col:col] ?: @"";
    if ([before isEqualToString:text]) return YES;
    NSString *err = nil;
    if (![s setText:text atRow:row col:col error:&err]) { NSBeep(); [self message:err]; return NO; }
    SheetUndo *u = [SheetUndo new];
    u.sheet = _sheetIndex; u.row = row; u.col = col; u.before = before; u.after = text;
    [_undo addObject:u];
    if (_undo.count > 2000) [_undo removeObjectAtIndex:0];
    [_redo removeAllObjects];
    [_grid invalidate];
    [self syncBar];
    return YES;
}

- (void)apply:(SheetUndo *)u text:(NSString *)t {
    if (u.sheet != _sheetIndex) [self showSheet:u.sheet];
    NSString *err = nil;
    if (![_book.sheets[u.sheet] setText:t atRow:u.row col:u.col error:&err]) { NSBeep(); [self message:err]; return; }
    [_grid selectRow:u.row col:u.col extend:NO];
    [_grid invalidate];
    [self syncBar];
}

- (void)undo:(id)sender {
    SheetUndo *u = _undo.lastObject;
    if (!u) { NSBeep(); return; }
    [_undo removeLastObject];
    [self apply:u text:u.before];
    [_redo addObject:u];
}

- (void)redo:(id)sender {
    SheetUndo *u = _redo.lastObject;
    if (!u) { NSBeep(); return; }
    [_redo removeLastObject];
    [self apply:u text:u.after];
    [_undo addObject:u];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(undo:)) return _undo.count > 0;
    if (item.action == @selector(redo:)) return _redo.count > 0;
    return [self respondsToSelector:item.action];
}

// The formula bar and the cell box
- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (c == _cellName && sel == @selector(insertNewline:)) {
        NSUInteger r, col;
        NSString *t = [_cellName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (XLParseRefString([t componentsSeparatedByString:@":"].firstObject, &r, &col)) { [_grid selectRow:r col:col extend:NO]; [self.window makeFirstResponder:_grid]; }
        else NSBeep();
        return YES;
    }
    if (c == _formula && (sel == @selector(insertNewline:) || sel == @selector(insertTab:))) {
        if ([self setText:_formula.stringValue row:_grid.row col:_grid.col]) {
            [self.window makeFirstResponder:_grid];
            [_grid selectRow:sel == @selector(insertTab:) ? _grid.row : _grid.row + 1 col:sel == @selector(insertTab:) ? _grid.col + 1 : _grid.col extend:NO];
        }
        return YES;
    }
    if (sel == @selector(cancelOperation:)) { [self syncBar]; [self.window makeFirstResponder:_grid]; return YES; }
    return NO;
}

- (void)openInApp:(id)sender {
    NSURL *app = FTOtherAppFor(_path);
    if (!app) { NSBeep(); return; }
    if (self.isDirty) [self message:FTL(@"Save first (⌘S) to open your changes there")];
    [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:_path]] withApplicationAtURL:app
                            configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

#pragma mark Saving

- (BOOL)saveReturningError:(NSString **)error {
    [_grid commitEditing];
    if (!_book.hasEdits) return YES;
    NSString *err = nil;
    NSData *out = [_book savedData:&err];
    if (!out) { if (error) *error = err; return NO; }
    // read the result back before replacing the file: a package we can't parse would not be written
    XLWorkbook *check = [[XLWorkbook alloc] initWithData:out error:&err];
    if (!check) { if (error) *error = [NSString stringWithFormat:FTL(@"The saved workbook didn’t read back (%@); the file was not changed"), err]; return NO; }
    err = FOWriteFile(_path, out);
    if (err) { if (error) *error = err; return NO; }
    NSUInteger sheet = _sheetIndex, r = _grid.row, c = _grid.col;
    _book = check;
    [self rebuildTabs];
    [self showSheet:MIN(sheet, _book.sheets.count - 1)];
    [_grid selectRow:r col:c extend:NO];
    [self changed];
    return YES;
}

- (void)changed { if (self.onChange) self.onChange(); }

- (NSString *)status {
    XLSheet *s = _grid.sheet;
    NSMutableString *t = [NSMutableString stringWithFormat:FTL(@"Excel workbook   %@ · %@ × %@"), s.name,
                          [NSString stringWithFormat:FTLP(s.rowCount, @"%lu row", @"%lu rows"), (unsigned long)s.rowCount],
                          [NSString stringWithFormat:FTLP(s.columnCount, @"%lu column", @"%lu columns"), (unsigned long)s.columnCount]];
    if (s.readOnlyReason) [t appendFormat:@"   %@", s.readOnlyReason];
    if (_book.hasFormulaEdits || [s isUncomputedFormulaAt:_grid.row col:_grid.col])
        [t appendString:FTL(@"   Formulas are recalculated when the file is opened in Excel or Numbers")];
    if (fabs(_grid.zoom - 1) > 0.01) [t appendFormat:@"   %.0f%%", _grid.zoom * 100];
    return t;
}

#pragma mark Find, zoom

- (BOOL)find:(NSString *)text backward:(BOOL)back {
    XLSheet *s = _grid.sheet;
    NSUInteger rows = s.rowCount, cols = s.columnCount, total = rows * cols;
    if (!text.length || !total || total > 20000000) return NO;
    NSUInteger start = _grid.row * cols + MIN(_grid.col, cols - 1);
    for (NSUInteger k = 1; k <= total; k++) {
        NSUInteger i = back ? (start + total - k) % total : (start + k) % total;
        NSUInteger r = i / cols, c = i % cols;
        NSString *v = [s displayAt:r col:c colour:NULL];
        if (v.length && [v rangeOfString:text options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            [_grid selectRow:r col:c extend:NO];
            return YES;
        }
    }
    NSBeep();
    return NO;
}

- (void)setZoomTo:(CGFloat)z {
    _grid.zoom = z;
    [NSUserDefaults.standardUserDefaults setDouble:_grid.zoom forKey:@"sheetZoom"];
    [self changed];
}
- (void)ftZoomIn { [self setZoomTo:round((_grid.zoom + 0.1) * 10) / 10]; }
- (void)ftZoomOut { [self setZoomTo:round((_grid.zoom - 0.1) * 10) / 10]; }
- (void)ftZoomToFit { [self setZoomTo:1]; }
- (void)ftZoomActualSize { [self setZoomTo:1]; }
- (void)ftRotate:(NSInteger)q {}
- (CGFloat)zoomPercent { return _grid.zoom * 100; }

@end

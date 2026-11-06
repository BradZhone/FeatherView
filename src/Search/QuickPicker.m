#import "QuickPicker.h"

@implementation PickerItem
+ (instancetype)title:(NSString *)t subtitle:(NSString *)s payload:(id)p {
    PickerItem *i = [PickerItem new];
    i.title = t; i.subtitle = s; i.payload = p;
    return i;
}
@end

@interface PickerPanel : NSPanel
@end
@implementation PickerPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface PickerTable : NSTableView
@end
@implementation PickerTable
- (BOOL)acceptsFirstResponder { return NO; }      // typing stays in the search field
@end

@implementation QuickPicker {
    PickerPanel *_panel;
    NSTextField *_field, *_status;
    PickerTable *_table;
    NSArray<PickerItem *> *_items;
    __weak NSWindow *_parent;
    BOOL _dismissed;
}

- (NSString *)query { return _field.stringValue; }

- (void)showInWindow:(NSWindow *)parent {
    _parent = parent;
    CGFloat w = MIN(620, parent.frame.size.width - 60), h = 380;
    NSRect pf = parent.frame;
    NSRect fr = NSMakeRect(NSMidX(pf) - w / 2, NSMaxY(pf) - 90 - h, w, h);
    _panel = [[PickerPanel alloc] initWithContentRect:fr styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.releasedWhenClosed = NO;

    NSVisualEffectView *bg = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
    bg.material = NSVisualEffectMaterialMenu;
    bg.state = NSVisualEffectStateActive;
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 10;
    bg.layer.masksToBounds = YES;
    _panel.contentView = bg;

    _field = [[NSTextField alloc] initWithFrame:NSMakeRect(12, h - 42, w - 24, 30)];
    _field.font = [NSFont systemFontOfSize:17];
    _field.bezeled = NO;
    _field.drawsBackground = NO;
    _field.focusRingType = NSFocusRingTypeNone;
    _field.placeholderString = _placeholder;
    _field.delegate = self;
    [bg addSubview:_field];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, h - 50, w, 1)];
    sep.boxType = NSBoxSeparator;
    [bg addSubview:sep];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 24, w, h - 76)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    _table = [[PickerTable alloc] initWithFrame:sv.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    col.width = w - 20;
    [_table addTableColumn:col];
    _table.headerView = nil;
    _table.backgroundColor = NSColor.clearColor;
    _table.rowHeight = 24;
    _table.style = NSTableViewStyleInset;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.action = @selector(clicked:);
    sv.documentView = _table;
    [bg addSubview:sv];

    _status = [NSTextField labelWithString:@""];
    _status.frame = NSMakeRect(14, 4, w - 28, 16);
    _status.font = [NSFont systemFontOfSize:11];
    _status.textColor = NSColor.tertiaryLabelColor;
    _status.stringValue = _footnote ?: @"";
    [bg addSubview:_status];

    [parent addChildWindow:_panel ordered:NSWindowAbove];
    [_panel makeKeyAndOrderFront:nil];
    [_panel makeFirstResponder:_field];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resigned:)
                                               name:NSWindowDidResignKeyNotification object:_panel];
    if (self.onQuery) self.onQuery(@"");
}

- (void)resigned:(NSNotification *)n { [self dismiss]; }

- (void)dismiss {
    if (_dismissed) return;
    _dismissed = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_parent removeChildWindow:_panel];
    [_panel orderOut:nil];
    [_parent makeKeyWindow];
    void (^d)(void) = self.onDismiss;
    if (d) d();
}

- (void)setItems:(NSArray<PickerItem *> *)items {
    _items = [items copy];
    [_table reloadData];
    if (_items.count) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_table scrollRowToVisible:0];
    }
}

- (void)setStatus:(NSString *)s { _status.stringValue = s.length ? s : (_footnote ?: @""); }
- (void)setFootnote:(NSString *)f { _footnote = [f copy]; if (!_status.stringValue.length) _status.stringValue = _footnote ?: @""; }

- (BOOL)deleteSelected {
    NSInteger r = _table.selectedRow;
    if (r < 0 || r >= (NSInteger)_items.count || !self.onDelete || !self.onDelete(_items[r])) { NSBeep(); return YES; }
    NSMutableArray *a = [_items mutableCopy];
    [a removeObjectAtIndex:r];
    _items = a;
    [_table reloadData];
    if (_items.count) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:MIN(r, (NSInteger)_items.count - 1)] byExtendingSelection:NO];
    return YES;
}

- (void)controlTextDidChange:(NSNotification *)n { if (self.onQuery) self.onQuery(_field.stringValue); }

- (void)move:(NSInteger)d {
    if (!_items.count) return;
    NSInteger r = MIN(MAX(0, _table.selectedRow + d), (NSInteger)_items.count - 1);
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
    [_table scrollRowToVisible:r];
}

- (void)pickRow:(NSInteger)r {
    if (r < 0 || r >= (NSInteger)_items.count) return;
    QuickPicker *keep = self;                 // owner may drop us in onDismiss
    PickerItem *it = _items[r];
    void (^pick)(PickerItem *) = self.onPick;
    [keep dismiss];
    if (pick) pick(it);
}

- (void)clicked:(id)s { [self pickRow:_table.clickedRow]; }

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:)) { [self move:1]; return YES; }
    if (sel == @selector(moveUp:)) { [self move:-1]; return YES; }
    if (sel == @selector(pageDown:) || sel == @selector(scrollPageDown:)) { [self move:10]; return YES; }
    if (sel == @selector(pageUp:) || sel == @selector(scrollPageUp:)) { [self move:-10]; return YES; }
    if (sel == @selector(insertNewline:)) { [self pickRow:_table.selectedRow]; return YES; }
    if (sel == @selector(cancelOperation:)) { [self dismiss]; return YES; }
    if (sel == @selector(deleteToBeginningOfLine:) && self.onDelete && !_field.stringValue.length) return [self deleteSelected];
    return NO;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return _items.count; }

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSTextField *tf = [t makeViewWithIdentifier:@"pick" owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = @"pick";
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    PickerItem *it = _items[row];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:it.title
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.labelColor}];
    if (it.subtitle.length)
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:it.subtitle]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    tf.attributedStringValue = s;
    return tf;
}

@end

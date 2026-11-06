#import "DefaultAppsPanel.h"

@implementation DefaultAppsPanel {
    NSWindow *_sheet;
    NSMutableArray<NSButton *> *_boxes;
    NSMutableArray<NSTextField *> *_current;
    NSTextField *_status;
    NSButton *_apply;
    NSArray<FileTypeGroup *> *_groups;
}

- (instancetype)init {
    if ((self = [super init])) { _apps = [DefaultApps new]; _groups = DefaultApps.groups; }
    return self;
}

- (NSArray<NSButton *> *)checkboxes { return _boxes; }

static NSTextField *small(NSString *s, NSColor *c) {
    NSTextField *l = [NSTextField wrappingLabelWithString:s];
    l.font = [NSFont systemFontOfSize:11];
    l.textColor = c;
    return l;
}

- (void)buildSheet {
    _boxes = [NSMutableArray array];
    _current = [NSMutableArray array];
    NSMutableArray *rows = [NSMutableArray array];
    for (FileTypeGroup *g in _groups) {
        NSButton *b = [NSButton checkboxWithTitle:g.title target:nil action:nil];
        NSString *exts = [@"." stringByAppendingString:[g.extensions componentsJoinedByString:@" ."]];
        if (g.unsupportedReason) { b.enabled = NO; exts = [NSString stringWithFormat:@"%@\n%@", exts, g.unsupportedReason]; }
        NSTextField *e = small(exts, NSColor.secondaryLabelColor);
        e.preferredMaxLayoutWidth = 300;
        NSTextField *c = small(@"", NSColor.secondaryLabelColor);
        [_boxes addObject:b];
        [_current addObject:c];
        [rows addObject:@[b, e, c]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 10;
    grid.columnSpacing = 14;
    [grid columnAtIndex:0].width = 120;
    [grid columnAtIndex:1].width = 300;
    [grid columnAtIndex:2].width = 150;
    for (NSInteger i = 0; i < grid.numberOfRows; i++) [grid rowAtIndex:i].yPlacement = NSGridCellPlacementTop;

    NSTextField *title = [NSTextField labelWithString:@"用 FeatherView 打开这些文件"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField *hint = small(@"勾选后，在访达里双击这类文件会用 FeatherView 打开。取消勾选会还给原来的应用。"
                              @"右侧是当前的默认应用。", NSColor.secondaryLabelColor);
    hint.preferredMaxLayoutWidth = 600;
    _status = small(@"", NSColor.systemRedColor);
    _status.preferredMaxLayoutWidth = 600;
    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\e";
    _apply = [NSButton buttonWithTitle:@"应用" target:self action:@selector(apply:)];
    _apply.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[cancel, _apply]];
    NSStackView *all = [NSStackView stackViewWithViews:@[title, hint, grid, _status, buttons]];
    all.orientation = NSUserInterfaceLayoutOrientationVertical;
    all.alignment = NSLayoutAttributeLeading;
    all.spacing = 12;
    all.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    [all setCustomSpacing:18 afterView:hint];
    [all setCustomSpacing:18 afterView:grid];
    [buttons.trailingAnchor constraintEqualToAnchor:grid.trailingAnchor].active = YES;

    _sheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES];
    _sheet.contentView = all;
    [self refresh];
    [all layoutSubtreeIfNeeded];
    [_sheet setContentSize:all.fittingSize];
}

- (void)refresh {
    for (NSUInteger i = 0; i < _groups.count; i++) {
        BOOL on = [_apps featherIsDefaultFor:_groups[i]];
        _boxes[i].state = on ? NSControlStateValueOn : NSControlStateValueOff;
        _current[i].stringValue = on ? @"FeatherView" : [@"现在：" stringByAppendingString:[_apps currentDefaultName:_groups[i]]];
    }
}

- (void)beginSheetForWindow:(NSWindow *)w {
    [self buildSheet];
    _status.stringValue = @"";
    [w beginSheet:_sheet completionHandler:nil];
}

- (void)cancel:(id)s { [_sheet.sheetParent endSheet:_sheet]; }

- (void)apply:(id)s { [self applyThen:nil]; }

- (void)applyThen:(void (^)(NSString *error))finished {
    _apply.enabled = NO;
    __block NSUInteger pending = 0;
    NSMutableArray *errors = [NSMutableArray array];
    void (^maybeDone)(void) = ^{
        if (pending) return;
        self->_apply.enabled = YES;
        [self refresh];
        NSString *err = errors.count ? [errors componentsJoinedByString:@"；"] : nil;
        self->_status.stringValue = err ?: @"";
        if (!err && !finished) [self->_sheet.sheetParent endSheet:self->_sheet];
        if (finished) finished(err);
    };
    for (NSUInteger i = 0; i < _groups.count; i++) {
        BOOL want = _boxes[i].state == NSControlStateValueOn, now = [_apps featherIsDefaultFor:_groups[i]];
        if (want == now || _groups[i].unsupportedReason) continue;
        pending++;
        NSString *title = _groups[i].title;
        [_apps setGroup:_groups[i] toFeather:want done:^(NSString *error) {
            if (error) [errors addObject:[NSString stringWithFormat:@"%@：%@", title, error]];
            pending--;
            maybeDone();
        }];
    }
    maybeDone();
}

@end

#import "WelcomeView.h"
#import "CanvasView.h"

@implementation WelcomeView {
    NSStackView *_stack;
    NSArray<NSString *> *_recent;
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    FTClipToBounds(self);
    _stack = [NSStackView new];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment = NSLayoutAttributeLeading;
    _stack.spacing = 6;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    NSLayoutConstraint *top = [_stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:90];
    top.priority = NSLayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [_stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_stack.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor constant:-48],
        [_stack.widthAnchor constraintLessThanOrEqualToConstant:460],
        [_stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:24],
        top]];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r { [NSColor.textBackgroundColor setFill]; NSRectFill(NSIntersectionRect(r, self.bounds)); }

static NSTextField *label(NSString *s, NSFont *f, NSColor *c) {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = f;
    l.textColor = c;
    l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return l;
}

- (NSButton *)link:(NSString *)title detail:(NSString *)detail action:(SEL)action target:(id)target {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bordered = NO;
    b.alignment = NSTextAlignmentLeft;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:title
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.linkColor}];
    if (detail.length)
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:detail]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    b.attributedTitle = s;
    [b.cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
    return b;
}

- (void)reloadWithRoot:(NSString *)root recent:(NSArray<NSString *> *)recent {
    for (NSView *v in _stack.arrangedSubviews.copy) [v removeFromSuperview];
    _recent = [recent copy];
    NSFont *head = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];

    [_stack addArrangedSubview:label(root ? root.lastPathComponent : @"Feather",
                                     [NSFont systemFontOfSize:26 weight:NSFontWeightLight], NSColor.labelColor)];
    if (root) [_stack addArrangedSubview:label(root.stringByAbbreviatingWithTildeInPath, [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor)];
    [_stack setCustomSpacing:26 afterView:_stack.arrangedSubviews.lastObject];

    [_stack addArrangedSubview:label(@"开始", head, NSColor.secondaryLabelColor)];
    if (root) {
        [_stack addArrangedSubview:[self link:@"快速打开文件" detail:@"⌘P" action:NSSelectorFromString(@"quickOpen:") target:nil]];
        [_stack addArrangedSubview:[self link:@"在工作区中搜索" detail:@"⇧⌘F" action:NSSelectorFromString(@"searchWorkspace:") target:nil]];
        [_stack addArrangedSubview:[self link:@"新建文件" detail:@"⌘N" action:NSSelectorFromString(@"newFile:") target:nil]];
    }
    [_stack addArrangedSubview:[self link:@"打开文件夹…" detail:@"⌘O" action:NSSelectorFromString(@"openFolder:") target:nil]];
    [_stack setCustomSpacing:26 afterView:_stack.arrangedSubviews.lastObject];

    NSMutableArray *others = [NSMutableArray array];
    for (NSString *r in _recent) if (![r isEqualToString:root]) [others addObject:r];
    if (others.count) {
        [_stack addArrangedSubview:label(@"最近的工作区", head, NSColor.secondaryLabelColor)];
        for (NSUInteger i = 0; i < MIN(others.count, (NSUInteger)8); i++) {
            NSString *r = others[i];
            NSButton *b = [self link:r.lastPathComponent detail:r.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath
                              action:@selector(recentClicked:) target:self];
            b.tag = (NSInteger)[_recent indexOfObject:r];
            b.toolTip = r;
            [_stack addArrangedSubview:b];
        }
    }
}

- (void)recentClicked:(NSButton *)b {
    if (b.tag >= 0 && b.tag < (NSInteger)_recent.count && self.onOpenRoot) self.onOpenRoot(_recent[b.tag]);
}

- (void)resetCursorRects {
    for (NSView *v in _stack.arrangedSubviews)
        if ([v isKindOfClass:NSButton.class]) [self addCursorRect:[self convertRect:v.bounds fromView:v] cursor:NSCursor.pointingHandCursor];
}

@end

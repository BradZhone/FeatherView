#import "WelcomeView.h"
#import "Localization.h"
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

    [_stack addArrangedSubview:label(root ? root.lastPathComponent : @"FeatherView",
                                     [NSFont systemFontOfSize:26 weight:NSFontWeightLight], NSColor.labelColor)];
    if (root) [_stack addArrangedSubview:label(root.stringByAbbreviatingWithTildeInPath, [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor)];
    [_stack setCustomSpacing:26 afterView:_stack.arrangedSubviews.lastObject];

    [_stack addArrangedSubview:label(FTL(@"Start"), head, NSColor.secondaryLabelColor)];
    if (root) {
        [_stack addArrangedSubview:[self link:FTL(@"Quick Open") detail:@"⌘P" action:NSSelectorFromString(@"quickOpen:") target:nil]];
        [_stack addArrangedSubview:[self link:FTL(@"Search in Workspace") detail:@"⇧⌘F" action:NSSelectorFromString(@"searchWorkspace:") target:nil]];
        [_stack addArrangedSubview:[self link:FTL(@"New Document") detail:FTL(@"⌘N, no need to save it first") action:NSSelectorFromString(@"newUntitled:") target:nil]];
        [_stack addArrangedSubview:[self link:FTL(@"New File…") detail:@"⌥⌘N" action:NSSelectorFromString(@"newFile:") target:nil]];
    }
    [_stack addArrangedSubview:[self link:FTL(@"Open Folder…") detail:@"⌘O" action:NSSelectorFromString(@"openFolder:") target:nil]];
    [_stack setCustomSpacing:26 afterView:_stack.arrangedSubviews.lastObject];

    NSMutableArray *others = [NSMutableArray array];
    for (NSString *r in _recent) if (![r isEqualToString:root]) [others addObject:r];
    if (others.count) {
        [_stack addArrangedSubview:label(FTL(@"Recent Workspaces"), head, NSColor.secondaryLabelColor)];
        for (NSUInteger i = 0; i < MIN(others.count, (NSUInteger)8); i++) {
            NSString *r = others[i];
            NSButton *b = [self link:r.lastPathComponent detail:r.stringByDeletingLastPathComponent.stringByAbbreviatingWithTildeInPath
                              action:@selector(recentClicked:) target:self];
            b.tag = (NSInteger)[_recent indexOfObject:r];
            b.toolTip = r;
            NSButton *x = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:FTL(@"Remove from Recent")]
                                             target:self action:@selector(removeClicked:)];
            x.bordered = NO;
            x.contentTintColor = NSColor.tertiaryLabelColor;
            x.toolTip = FTL(@"Remove from Recent (the folder itself is not affected)");
            x.tag = b.tag;
            [x setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSStackView *row = [NSStackView stackViewWithViews:@[b, x]];
            row.spacing = 2;
            [_stack addArrangedSubview:row];
        }
    }
}

- (void)recentClicked:(NSButton *)b {
    if (b.tag >= 0 && b.tag < (NSInteger)_recent.count && self.onOpenRoot) self.onOpenRoot(_recent[b.tag]);
}

- (void)removeClicked:(NSButton *)b {
    if (b.tag >= 0 && b.tag < (NSInteger)_recent.count && self.onRemoveRecent) self.onRemoveRecent(_recent[b.tag]);
}

- (void)resetCursorRects {
    for (NSView *v in _stack.arrangedSubviews) {
        NSArray *buttons = [v isKindOfClass:NSStackView.class] ? [(NSStackView *)v arrangedSubviews] : @[v];
        for (NSView *b in buttons)
            if ([b isKindOfClass:NSButton.class]) [self addCursorRect:[self convertRect:b.bounds fromView:b] cursor:NSCursor.pointingHandCursor];
    }
}

@end

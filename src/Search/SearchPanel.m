#import "SearchPanel.h"
#import "Localization.h"
#import "WorkspaceSearch.h"
#import "FileWalker.h"
#import "FileIcons.h"

static const NSUInteger kNamesInAll = 8;          // file-name rows shown above the content results before "显示全部"
static const NSUInteger kNamesMax = 500;
static const NSTimeInterval kTypingDelay = 0.25;

#pragma mark Model

typedef NS_ENUM(NSInteger, SectionKind) { SectionNames, SectionContents };

@interface SRSection : NSObject
@property (nonatomic) SectionKind kind;
@end
@implementation SRSection @end

@interface SRFile : NSObject                       // content matches of one file
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSMutableArray<SearchHit *> *hits;
@end
@implementation SRFile @end

@interface SRName : NSObject                       // a matching file name
@property (nonatomic, copy) NSString *path, *rel;
@property (nonatomic) NSRange nameRange;
@end
@implementation SRName @end

@interface SRMore : NSObject                       // "显示全部 N 个"
@end
@implementation SRMore @end

#pragma mark Views

@interface SRFlippedView : NSView
@end
@implementation SRFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Count pill on file rows.
@interface SRBadge : NSView
@property (nonatomic, copy) NSString *text;
@end
@implementation SRBadge
- (NSDictionary *)attrs {
    return @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightSemibold],
             NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
}
- (NSSize)intrinsicContentSize {
    NSSize s = [_text ?: @"" sizeWithAttributes:self.attrs];
    return NSMakeSize(MAX(18, ceil(s.width) + 10), 16);
}
- (void)setText:(NSString *)t { _text = [t copy]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)r {
    NSRect b = NSInsetRect(self.bounds, 0, 0.5);
    [[NSColor.labelColor colorWithAlphaComponent:0.09] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:b xRadius:b.size.height / 2 yRadius:b.size.height / 2] fill];
    NSSize s = [_text sizeWithAttributes:self.attrs];
    [_text drawAtPoint:NSMakePoint(NSMidX(b) - s.width / 2, NSMidY(b) - s.height / 2) withAttributes:self.attrs];
}
@end

// Section headers get a tinted band, file rows a hairline above them, so files are easy to tell apart.
@interface SRRowView : NSTableRowView
@property (nonatomic) NSInteger kind;              // 0 plain, 1 section, 2 file
@end
@implementation SRRowView
- (void)drawBackgroundInRect:(NSRect)dirty {
    [super drawBackgroundInRect:dirty];
    if (_kind == 1) {
        [[NSColor.labelColor colorWithAlphaComponent:0.05] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    } else if (_kind == 2) {
        [[NSColor.separatorColor colorWithAlphaComponent:0.3] setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, self.bounds.size.width, 1), NSCompositingOperationSourceOver);
    }
}
@end

static NSTextField *label(NSFont *f, NSColor *c, NSLineBreakMode mode) {
    NSTextField *t = [NSTextField labelWithString:@""];
    t.font = f; t.textColor = c; t.lineBreakMode = mode;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.usesSingleLineMode = YES;
    t.maximumNumberOfLines = 1;
    t.cell.wraps = NO;
    t.cell.scrollable = NO;
    t.cell.truncatesLastVisibleLine = YES;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}

static NSColor *matchFill(BOOL selected) {
    if (selected) return [NSColor colorWithWhite:1 alpha:0.28];
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
        return dark ? [NSColor colorWithSRGBRed:0.95 green:0.62 blue:0.20 alpha:0.42] : [NSColor colorWithSRGBRed:1.0 green:0.78 blue:0.25 alpha:0.55];
    }];
}

// icon · name · folder · [badge]
@interface SRFileCell : NSTableCellView
@property (nonatomic, strong) NSTextField *name, *dir;
@property (nonatomic, strong) SRBadge *badge;
@property (nonatomic, copy) NSString *nameText, *dirText;
@property (nonatomic) NSRange nameMatch;
@end
@implementation SRFileCell
- (instancetype)initWithBadge:(BOOL)withBadge {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, 22)])) return nil;
    NSImageView *iv = [NSImageView new];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightRegular];
    self.imageView = iv;
    _name = label([NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], NSColor.labelColor, NSLineBreakByTruncatingTail);
    _dir = label([NSFont systemFontOfSize:11], NSColor.tertiaryLabelColor, NSLineBreakByTruncatingHead);
    [_name setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_name setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *v in @[iv, _name, _dir]) [self addSubview:v];
    NSMutableArray *c = [@[[iv.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:1],
                           [iv.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                           [iv.widthAnchor constraintEqualToConstant:16],
                           [_name.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:5],
                           [_name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                           [_dir.leadingAnchor constraintEqualToAnchor:_name.trailingAnchor constant:6],
                           [_dir.firstBaselineAnchor constraintEqualToAnchor:_name.firstBaselineAnchor]] mutableCopy];
    if (withBadge) {
        _badge = [SRBadge new];
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        [_badge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:_badge];
        [c addObjectsFromArray:@[[_badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
                                 [_badge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                                 [_dir.trailingAnchor constraintLessThanOrEqualToAnchor:_badge.leadingAnchor constant:-6]]];
    } else {
        [c addObject:[_dir.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6]];
    }
    [NSLayoutConstraint activateConstraints:c];
    return self;
}
- (void)refresh {
    BOOL sel = self.backgroundStyle == NSBackgroundStyleEmphasized;
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:_nameText ?: @""
        attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold],
                     NSForegroundColorAttributeName: sel ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor}];
    if (_nameMatch.location != NSNotFound && NSMaxRange(_nameMatch) <= s.length && _nameMatch.length < s.length)
        [s addAttribute:NSBackgroundColorAttributeName value:matchFill(sel) range:_nameMatch];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [s addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, s.length)];
    _name.attributedStringValue = s;
    _dir.stringValue = _dirText ?: @"";
    _dir.textColor = sel ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.75] : NSColor.tertiaryLabelColor;
}
- (void)setBackgroundStyle:(NSBackgroundStyle)s { [super setBackgroundStyle:s]; [self refresh]; }
@end

// line number gutter · monospaced preview with every match highlighted
@interface SRHitCell : NSTableCellView
@property (nonatomic, strong) NSTextField *num, *text;
@property (nonatomic, strong) SearchHit *hit;
@end
@implementation SRHitCell
- (instancetype)init {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 200, 20)])) return nil;
    _num = label([NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], NSColor.tertiaryLabelColor, NSLineBreakByClipping);
    _num.alignment = NSTextAlignmentRight;
    _text = label([NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular], NSColor.labelColor, NSLineBreakByTruncatingTail);
    [self addSubview:_num]; [self addSubview:_text];
    [NSLayoutConstraint activateConstraints:@[
        [_num.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_num.widthAnchor constraintEqualToConstant:30],
        [_num.firstBaselineAnchor constraintEqualToAnchor:_text.firstBaselineAnchor],
        [_text.leadingAnchor constraintEqualToAnchor:_num.trailingAnchor constant:7],
        [_text.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-4],
        [_text.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
    return self;
}
- (void)refresh {
    BOOL sel = self.backgroundStyle == NSBackgroundStyleEmphasized;
    _num.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)_hit.line];
    _num.textColor = sel ? [NSColor.alternateSelectedControlTextColor colorWithAlphaComponent:0.7] : NSColor.tertiaryLabelColor;
    NSString *p = _hit.preview ?: @"";
    NSArray<NSValue *> *ranges = _hit.previewMatches;
    // Narrow sidebar: if the first match would be cut off, drop text in front of it (monospaced, so columns = width).
    NSFont *mono = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    CGFloat cw = [@"M" sizeWithAttributes:@{NSFontAttributeName: mono}].width;
    NSInteger cols = (NSInteger)((self.bounds.size.width - 41) / MAX(cw, 1));
    NSRange first = ranges.count ? ranges[0].rangeValue : NSMakeRange(NSNotFound, 0);
    if (first.location != NSNotFound && cols > 12 && (NSInteger)NSMaxRange(first) > cols - 1 && first.location > 6) {
        NSUInteger cut = first.location - MIN(first.location, (NSUInteger)MAX(4, cols / 4));
        cut = [p rangeOfComposedCharacterSequenceAtIndex:cut].location;
        NSInteger shift = 1 - (NSInteger)cut;                        // "…" replaces the dropped text
        p = [@"…" stringByAppendingString:[p substringFromIndex:cut]];
        NSMutableArray *moved = [NSMutableArray array];
        for (NSValue *v in ranges) {
            NSRange r = v.rangeValue;
            if ((NSInteger)r.location + shift >= 1) [moved addObject:[NSValue valueWithRange:NSMakeRange(r.location + shift, r.length)]];
        }
        ranges = moved;
    }
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:p attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: sel ? NSColor.alternateSelectedControlTextColor : NSColor.secondaryLabelColor}];
    for (NSValue *v in ranges) {
        NSRange r = v.rangeValue;
        if (NSMaxRange(r) > p.length) continue;
        [s addAttributes:@{NSBackgroundColorAttributeName: matchFill(sel),
                           NSForegroundColorAttributeName: sel ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
                           NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightSemibold]} range:r];
    }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [s addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, s.length)];
    _text.attributedStringValue = s;
}
- (void)setFrameSize:(NSSize)size {
    BOOL changed = fabs(size.width - self.frame.size.width) > 0.5;
    [super setFrameSize:size];
    if (changed && _hit) [self refresh];
}
- (void)setBackgroundStyle:(NSBackgroundStyle)s { [super setBackgroundStyle:s]; [self refresh]; }
@end

// Results list: Return opens, Esc goes back to the query, ⌘C copies the path.
@interface SROutlineView : NSOutlineView
@property (nonatomic, copy) void (^onReturn)(void), (^onEscape)(void), (^onCopy)(void), (^onUpFromTop)(void);
@end
@implementation SROutlineView
- (void)keyDown:(NSEvent *)e {
    unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~(NSEventModifierFlagFunction | NSEventModifierFlagNumericPad);
    if ((c == '\r' || c == 3) && self.onReturn) { self.onReturn(); return; }
    if (c == 27 && self.onEscape) { self.onEscape(); return; }
    if (c == NSUpArrowFunctionKey && !m && self.selectedRow <= 0 && self.onUpFromTop) { self.onUpFromTop(); return; }
    [super keyDown:e];
}
- (void)copy:(id)s { if (self.onCopy) self.onCopy(); }
@end

@implementation SearchPanel {
    SRFlippedView *_view;
    NSSearchField *_field;
    NSTextField *_filterField, *_status;
    NSSegmentedControl *_scopeControl;
    NSButton *_caseButton, *_wordButton, *_regexButton, *_collapseButton;
    NSProgressIndicator *_spinner;
    SROutlineView *_ov;
    WorkspaceSearch *_engine;
    SRSection *_namesSection, *_contentSection;
    SRMore *_more;
    NSMutableArray<SRName *> *_names;
    NSUInteger _nameTotal;
    BOOL _showAllNames;
    NSMutableArray<SRFile *> *_files;
    NSMutableDictionary<NSString *, SRFile *> *_byPath;
    NSMutableSet *_collapsed;                     // file paths and section kinds the user folded
    NSUInteger _hitCount, _gen;
    BOOL _contentRunning, _namesRunning, _truncated, _reloadPending, _ranking, _rankAgain;
    BOOL _searchedNames, _searchedContent, _globOnly, _reloading, _suppressOpen;
    NSString *_error, *_activeQuery;
    SearchOptions *_activeOptions;
    CFAbsoluteTime _started;
    FileList *_fileList;
    CFAbsoluteTime _fileListAt;
    NSTimer *_typing;
}

static NSButton *toggle(NSString *title, NSString *tip, id target, SEL action, BOOL underline) {
    NSFont *f = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightSemibold];
    NSMutableDictionary *a = [@{NSFontAttributeName: f} mutableCopy];
    if (underline) a[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:a];
    b.bezelStyle = NSBezelStyleRecessed;
    b.showsBorderOnlyWhileMouseInside = NO;
    [b setButtonType:NSButtonTypePushOnPushOff];
    b.controlSize = NSControlSizeSmall;
    b.toolTip = tip;
    b.cell.accessibilityLabel = tip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

static NSButton *iconButton(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] target:target action:action];
    b.bordered = NO;
    b.toolTip = tip;
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:18].active = YES;
    return b;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _engine = [WorkspaceSearch new];
    _respectGitignore = YES;
    _namesSection = [SRSection new]; _namesSection.kind = SectionNames;
    _contentSection = [SRSection new]; _contentSection.kind = SectionContents;
    _more = [SRMore new];
    _names = [NSMutableArray array];
    _files = [NSMutableArray array];
    _byPath = [NSMutableDictionary dictionary];
    _collapsed = [NSMutableSet set];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;

    _view = [[SRFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 260, 600)];
    _field = [NSSearchField new];
    _field.placeholderString = FTL(@"Search file names and contents");
    _field.delegate = self;
    _field.sendsSearchStringImmediately = YES;
    _field.target = self;
    _field.action = @selector(fieldAction:);
    _field.translatesAutoresizingMaskIntoConstraints = NO;

    _scopeControl = [NSSegmentedControl segmentedControlWithLabels:@[FTL(@"All"), FTL(@"Names"), FTL(@"Contents")]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(optionChanged:)];
    _scopeControl.controlSize = NSControlSizeSmall;
    _scopeControl.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _scopeControl.segmentDistribution = NSSegmentDistributionFillEqually;
    _scopeControl.translatesAutoresizingMaskIntoConstraints = NO;
    _scopeControl.selectedSegment = MIN(2, MAX(0, [ud integerForKey:@"searchScope"]));

    _caseButton = toggle(@"Aa", FTL(@"Match Case"), self, @selector(optionChanged:), NO);
    _wordButton = toggle(@"ab", FTL(@"Whole Word"), self, @selector(optionChanged:), YES);
    _regexButton = toggle(@".*", FTL(@"Regular Expression"), self, @selector(optionChanged:), NO);
    _caseButton.state = [ud boolForKey:@"searchCase"]; _wordButton.state = [ud boolForKey:@"searchWord"]; _regexButton.state = [ud boolForKey:@"searchRegex"];

    _filterField = [NSTextField textFieldWithString:[ud stringForKey:@"searchFilter"] ?: @""];
    _filterField.placeholderString = FTL(@"Scope: src, *.ts, !test");
    _filterField.toolTip = FTL(@"Search only these files, separated by commas; a leading ! excludes.\nts or .ts = extension, src = folder, src/app = path, *.test.ts = wildcard");
    _filterField.font = [NSFont systemFontOfSize:11.5];
    _filterField.controlSize = NSControlSizeSmall;
    _filterField.bezelStyle = NSTextFieldRoundedBezel;
    _filterField.delegate = self;
    _filterField.target = self;
    _filterField.action = @selector(fieldAction:);
    _filterField.translatesAutoresizingMaskIntoConstraints = NO;

    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _status = label([NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSLineBreakByTruncatingTail);
    _status.stringValue = FTL(@"Type a name, an extension (.svg) or text");
    _collapseButton = iconButton(@"rectangle.compress.vertical", FTL(@"Collapse All"), self, @selector(toggleCollapseAll:));
    _collapseButton.hidden = YES;

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    line.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *sv = [NSScrollView new];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.drawsBackground = NO;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    _ov = [[SROutlineView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"r"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_ov addTableColumn:col];
    _ov.outlineTableColumn = col;
    _ov.headerView = nil;
    _ov.style = NSTableViewStylePlain;
    _ov.backgroundColor = NSColor.clearColor;
    _ov.indentationPerLevel = 12;
    _ov.intercellSpacing = NSMakeSize(0, 0);
    _ov.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _ov.autosaveExpandedItems = NO;
    _ov.dataSource = self;
    _ov.delegate = self;
    _ov.target = self;
    _ov.action = @selector(clicked:);
    _ov.doubleAction = @selector(doubleClicked:);
    _ov.menu = [NSMenu new];
    _ov.menu.delegate = self;
    __weak SearchPanel *weakSelf = self;
    _ov.onReturn = ^{ [weakSelf openSelected:YES]; };
    _ov.onEscape = ^{ SearchPanel *me = weakSelf; [me->_view.window makeFirstResponder:me->_field]; };
    _ov.onUpFromTop = _ov.onEscape;
    _ov.onCopy = ^{ [weakSelf copyPaths:nil]; };
    sv.documentView = _ov;

    for (NSView *v in @[_field, _scopeControl, _caseButton, _wordButton, _regexButton, _filterField, _spinner, _status, _collapseButton, line, sv])
        [_view addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [_field.topAnchor constraintEqualToAnchor:_view.topAnchor constant:6],
        [_field.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [_field.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],

        [_scopeControl.topAnchor constraintEqualToAnchor:_field.bottomAnchor constant:6],
        [_scopeControl.leadingAnchor constraintEqualToAnchor:_field.leadingAnchor],
        [_caseButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:_scopeControl.trailingAnchor constant:6],
        [_caseButton.centerYAnchor constraintEqualToAnchor:_scopeControl.centerYAnchor],
        [_wordButton.leadingAnchor constraintEqualToAnchor:_caseButton.trailingAnchor constant:2],
        [_wordButton.centerYAnchor constraintEqualToAnchor:_scopeControl.centerYAnchor],
        [_regexButton.leadingAnchor constraintEqualToAnchor:_wordButton.trailingAnchor constant:2],
        [_regexButton.centerYAnchor constraintEqualToAnchor:_scopeControl.centerYAnchor],
        [_regexButton.trailingAnchor constraintEqualToAnchor:_field.trailingAnchor],

        [_filterField.topAnchor constraintEqualToAnchor:_scopeControl.bottomAnchor constant:6],
        [_filterField.leadingAnchor constraintEqualToAnchor:_field.leadingAnchor],
        [_filterField.trailingAnchor constraintEqualToAnchor:_field.trailingAnchor],

        [_spinner.leadingAnchor constraintEqualToAnchor:_field.leadingAnchor constant:2],
        [_spinner.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],
        [_spinner.widthAnchor constraintEqualToConstant:12], [_spinner.heightAnchor constraintEqualToConstant:12],
        [_status.topAnchor constraintEqualToAnchor:_filterField.bottomAnchor constant:7],
        [_status.leadingAnchor constraintEqualToAnchor:_spinner.trailingAnchor constant:4],
        [_status.trailingAnchor constraintLessThanOrEqualToAnchor:_collapseButton.leadingAnchor constant:-4],
        [_collapseButton.trailingAnchor constraintEqualToAnchor:_field.trailingAnchor],
        [_collapseButton.centerYAnchor constraintEqualToAnchor:_status.centerYAnchor],

        [line.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:6],
        [line.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [sv.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [sv.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [sv.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor]]];
    [_scopeControl setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return self;
}

- (NSView *)view { return _view; }
- (NSOutlineView *)resultsView { return _ov; }

#pragma mark Options

- (SearchScope)scope { return (SearchScope)MAX(0, _scopeControl.selectedSegment); }
- (void)setScope:(SearchScope)s { _scopeControl.selectedSegment = s; [self saveOptions]; }
- (BOOL)caseSensitive { return _caseButton.state == NSControlStateValueOn; }
- (BOOL)wholeWord { return _wordButton.state == NSControlStateValueOn; }
- (BOOL)regex { return _regexButton.state == NSControlStateValueOn; }
- (void)setCaseSensitive:(BOOL)v { _caseButton.state = v; [self saveOptions]; }
- (void)setWholeWord:(BOOL)v { _wordButton.state = v; [self saveOptions]; }
- (void)setRegex:(BOOL)v { _regexButton.state = v; [self saveOptions]; }
- (NSString *)query { return _field.stringValue; }
- (void)setQuery:(NSString *)q { _field.stringValue = q ?: @""; }
- (NSString *)filterText { return _filterField.stringValue; }
- (void)setFilterText:(NSString *)f { _filterField.stringValue = f ?: @""; [self saveOptions]; }
- (BOOL)busy { return _contentRunning || _namesRunning; }
- (NSUInteger)nameCount { return _nameTotal; }
- (NSUInteger)contentFileCount { return _files.count; }
- (NSUInteger)hitCount { return _hitCount; }
- (NSString *)statusText { return _status.stringValue; }
- (BOOL)hasResults { return _names.count || _files.count; }

- (void)saveOptions {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setInteger:self.scope forKey:@"searchScope"];
    [ud setBool:self.caseSensitive forKey:@"searchCase"];
    [ud setBool:self.wholeWord forKey:@"searchWord"];
    [ud setBool:self.regex forKey:@"searchRegex"];
    [ud setObject:_filterField.stringValue forKey:@"searchFilter"];
}

- (void)setRoot:(NSString *)root {
    _root = [root copy];
    [_fileList cancel];
    _fileList = nil;
    [self clearAndCancel];
    [self updateStatus];
}

- (void)setIncludeHidden:(BOOL)h {
    if (h == _includeHidden) return;
    _includeHidden = h;
    [_fileList cancel];
    _fileList = nil;
    if (_activeQuery.length) [self runNow];
}

- (void)fileSystemChanged { _fileListAt = 0; }
- (void)setRespectGitignore:(BOOL)v { if (v == _respectGitignore) return; _respectGitignore = v; if (_activeQuery.length) [self runNow]; }

- (void)focusWithQuery:(NSString *)q {
    [_view.window makeFirstResponder:_field];
    if (q.length && ![q isEqualToString:_field.stringValue]) { _field.stringValue = q; [self runNow]; }
    else [_field selectText:nil];
}

- (void)optionChanged:(id)s { [self saveOptions]; [self runNow]; }
- (void)fieldAction:(id)s { [self saveOptions]; [self runNow]; }            // Return, or the field's ⓧ
- (void)controlTextDidChange:(NSNotification *)n {
    [_typing invalidate];
    _typing = [NSTimer scheduledTimerWithTimeInterval:kTypingDelay target:self selector:@selector(typed:) userInfo:nil repeats:NO];
}
- (void)typed:(NSTimer *)t { _typing = nil; [self saveOptions]; [self runNow]; }

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(moveDown:) && _ov.numberOfRows) {
        [_view.window makeFirstResponder:_ov];
        NSInteger r = 0;
        while (r < _ov.numberOfRows && [[_ov itemAtRow:r] isKindOfClass:SRSection.class]) r++;
        if (r < _ov.numberOfRows) [self selectRow:r];
        return YES;
    }
    return NO;
}

#pragma mark Running

- (void)clearAndCancel {
    [_typing invalidate]; _typing = nil;
    _gen++;
    [_engine cancel];
    [_names removeAllObjects]; _nameTotal = 0; _showAllNames = NO;
    [_files removeAllObjects]; [_byPath removeAllObjects];
    _hitCount = 0; _truncated = NO; _error = nil;
    _contentRunning = _namesRunning = _searchedNames = _searchedContent = NO;
    _globOnly = NO;
    _activeQuery = nil;
    for (id k in _collapsed.allObjects) if ([k isKindOfClass:NSString.class]) [_collapsed removeObject:k];
    [self reloadNow];
}

- (void)runNow {
    NSString *q = _field.stringValue;
    NSString *trimmed = [q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [self clearAndCancel];
    if (!trimmed.length || !_root) { [self updateStatus]; return; }
    _activeQuery = q;
    SearchOptions *o = [SearchOptions new];
    o.caseSensitive = self.caseSensitive; o.wholeWord = self.wholeWord; o.regex = self.regex; o.includeHidden = _includeHidden;
    o.respectGitignore = _respectGitignore;
    o.filter = [FWPathFilter filterWithString:_filterField.stringValue];
    _activeOptions = o;
    NSString *err = nil;
    if (![o matcherFor:trimmed error:&err]) { _error = err; [self updateStatus]; return; }
    SearchScope sc = self.scope;
    _globOnly = !o.regex && FWQueryIsGlob(trimmed);                 // "*.svg" is a name pattern, not text
    _searchedNames = sc != SearchScopeContents || _globOnly;
    _searchedContent = sc != SearchScopeNames && !_globOnly;
    _started = CFAbsoluteTimeGetCurrent();
    if (_searchedNames) { _namesRunning = YES; [self startNames]; }
    if (_searchedContent) {
        _contentRunning = YES;
        NSUInteger gen = _gen;
        __weak SearchPanel *weakSelf = self;
        [_engine search:q root:_root options:o
                onBatch:^(NSArray<SearchHit *> *hits, NSUInteger files) { [weakSelf appendHits:hits gen:gen]; }
                 onDone:^(BOOL truncated) { [weakSelf contentDone:truncated gen:gen]; }];
    }
    [self updateStatus];
}

// File names come from a cached listing of the workspace (rescanned when older than 20 s or after changes).
- (void)startNames {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!_fileList || ![_fileList.root isEqualToString:_root] || (_fileList.done && now - _fileListAt > 20)) {
        [_fileList cancel];
        FileList *list = [[FileList alloc] initWithRoot:_root includeHidden:_includeHidden];
        _fileList = list;
        _fileListAt = now;
        __weak SearchPanel *weakSelf = self;
        [list startWithProgress:^(BOOL done) {
            SearchPanel *me = weakSelf;
            if (!me || me->_fileList != list) return;
            if (done) me->_fileListAt = CFAbsoluteTimeGetCurrent();
            if (me->_namesRunning) [me rankNames];
        }];
    }
    [self rankNames];
}

static NSArray<FWNameMatch *> *regexNames(NSRegularExpression *re, NSArray<NSString *> *paths, FWPathFilter *filter,
                                          NSUInteger limit, NSUInteger *total) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *rel in paths) {
        NSString *name = rel.lastPathComponent;
        NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
        NSInteger score = m ? 600 : ([re firstMatchInString:rel options:0 range:NSMakeRange(0, rel.length)] ? 200 : 0);
        if (!score || (filter && ![filter allowsFile:rel])) continue;
        FWNameMatch *x = [FWNameMatch new];
        x.rel = rel; x.score = score; x.nameRange = m ? m.range : NSMakeRange(NSNotFound, 0);
        [out addObject:x];
    }
    *total = out.count;
    [out sortUsingComparator:^NSComparisonResult(FWNameMatch *a, FWNameMatch *b) {
        if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
        return a.rel.length < b.rel.length ? NSOrderedAscending : a.rel.length > b.rel.length ? NSOrderedDescending : NSOrderedSame;
    }];
    return out.count > limit ? [out subarrayWithRange:NSMakeRange(0, limit)] : out;
}

// Ranks off the main thread; requests that arrive meanwhile are folded into one more pass.
- (void)rankNames {
    if (!_namesRunning) return;
    if (_ranking) { _rankAgain = YES; return; }
    _ranking = YES;
    NSUInteger gen = _gen;
    NSString *q = [_activeQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    SearchOptions *o = _activeOptions;
    BOOL listDone = _fileList.done;
    NSArray<NSString *> *paths = _fileList.snapshot;
    __weak SearchPanel *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger total = 0;
        NSArray<FWNameMatch *> *ms = o.regex ? regexNames([o matcherFor:q error:NULL], paths, o.filter, kNamesMax, &total)
                                             : FWNameSearch(q, paths, o.filter, kNamesMax, &total);
        dispatch_async(dispatch_get_main_queue(), ^{
            SearchPanel *me = weakSelf;
            if (!me) return;
            me->_ranking = NO;
            if (gen == me->_gen) [me setNames:ms total:total final:listDone];
            if (me->_rankAgain || gen != me->_gen) { me->_rankAgain = NO; [me rankNames]; }
        });
    });
}

// The listing can be tens of MB for a big folder: keep it only while the user is searching.
- (void)scheduleListRelease {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(releaseList) object:nil];
    [self performSelector:@selector(releaseList) withObject:nil afterDelay:60];
}
- (void)releaseList { if (!_namesRunning) { [_fileList cancel]; _fileList = nil; } }

- (void)setNames:(NSArray<FWNameMatch *> *)ms total:(NSUInteger)total final:(BOOL)final {
    [_names removeAllObjects];
    for (FWNameMatch *m in ms) {
        SRName *n = [SRName new];
        n.rel = m.rel; n.path = [_root stringByAppendingPathComponent:m.rel]; n.nameRange = m.nameRange;
        [_names addObject:n];
    }
    _nameTotal = total;
    if (final) { _namesRunning = NO; [self scheduleListRelease]; }
    [self scheduleReload];
    [self updateStatus];
}

- (void)appendHits:(NSArray<SearchHit *> *)hits gen:(NSUInteger)gen {
    if (gen != _gen) return;
    for (SearchHit *h in hits) {
        SRFile *f = _byPath[h.path];
        if (!f) {
            f = [SRFile new];
            f.path = h.path;
            f.hits = [NSMutableArray array];
            _byPath[h.path] = f;
            [_files addObject:f];
        }
        [f.hits addObject:h];
    }
    _hitCount += hits.count;
    [self scheduleReload];
    [self updateStatus];
}

- (void)contentDone:(BOOL)truncated gen:(NSUInteger)gen {
    if (gen != _gen) return;
    _contentRunning = NO;
    _truncated = truncated;
    [self reloadNow];
    [self updateStatus];
}

- (void)updateStatus {
    BOOL busy = self.busy;
    if (busy) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.toolTip = nil;
    NSString *q = [_activeQuery stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (_error) { _status.stringValue = _error; _status.textColor = NSColor.systemRedColor; return; }
    if (!_root) { _status.stringValue = FTL(@"Open a folder first"); return; }
    if (!q.length) { _status.stringValue = FTL(@"Type a name, an extension (.svg) or text"); return; }
    NSMutableArray *parts = [NSMutableArray array];
    if (_searchedNames && (_nameTotal || !busy))
        [parts addObject:[NSString stringWithFormat:FTLP(_nameTotal, @"%lu name%@", @"%lu names%@"), (unsigned long)_nameTotal, _nameTotal > kNamesMax ? [NSString stringWithFormat:FTL(@" (first %lu listed)"), (unsigned long)kNamesMax] : @""]];
    if (_searchedContent && (_hitCount || !busy))
        [parts addObject:[NSString stringWithFormat:FTL(@"%2$@ in %1$@%3$@"),
            [NSString stringWithFormat:FTLP(_files.count, @"%lu file", @"%lu files"), (unsigned long)_files.count],
            [NSString stringWithFormat:FTLP(_hitCount, @"%lu match", @"%lu matches"), (unsigned long)_hitCount],
            _truncated ? FTL(@" (limit reached)") : @""]];
    if (busy) { _status.stringValue = [FTL(@"Searching… ") stringByAppendingString:[parts componentsJoinedByString:@" · "]]; return; }
    if (!_nameTotal && !_hitCount) { _status.stringValue = [NSString stringWithFormat:FTL(@"No results for “%@”"), q]; return; }
    _status.stringValue = [parts componentsJoinedByString:@" · "];
    _status.toolTip = [NSString stringWithFormat:FTL(@"Took %.2f s%@%@"), CFAbsoluteTimeGetCurrent() - _started, _globOnly ? FTL(@"\nWildcards match file names only") : @"",
                       _searchedContent ? (_engine.usedRipgrep ? FTL(@"\nContents searched with ripgrep") : FTL(@"\nContents searched with the built-in scanner")) : @""];
}

#pragma mark Results list

- (void)scheduleReload {
    if (_reloadPending) return;
    _reloadPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reloadNow]; });
}

- (void)reloadNow {
    _reloadPending = NO;
    id selected = _ov.selectedRow >= 0 ? [_ov itemAtRow:_ov.selectedRow] : nil;
    _reloading = YES;
    [_ov reloadData];
    for (SRSection *s in [self rootItems]) {
        if ([_collapsed containsObject:@(s.kind)]) continue;
        [_ov expandItem:s];
        if (s.kind == SectionContents)
            for (SRFile *f in _files) if (![_collapsed containsObject:f.path]) [_ov expandItem:f];
    }
    _reloading = NO;
    NSInteger row = selected ? [_ov rowForItem:selected] : -1;
    if (row >= 0) { _suppressOpen = YES; [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; _suppressOpen = NO; }
    _collapseButton.hidden = _files.count < 2;
}

- (NSArray<SRSection *> *)rootItems {
    NSMutableArray *a = [NSMutableArray array];
    if (_names.count) [a addObject:_namesSection];
    if (_files.count) [a addObject:_contentSection];
    return a;
}

- (BOOL)namesCapped { return !_showAllNames && self.scope != SearchScopeNames && _files.count && _names.count > kNamesInAll + 1; }

- (NSArray *)childrenOf:(id)item {
    if (!item) return [self rootItems];
    if (item == _namesSection) {
        if (!self.namesCapped) return _names;
        return [[_names subarrayWithRange:NSMakeRange(0, kNamesInAll)] arrayByAddingObject:(id)_more];
    }
    if (item == _contentSection) return _files;
    if ([item isKindOfClass:SRFile.class]) return [(SRFile *)item hits];
    return @[];
}

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item { return [self childrenOf:item].count; }
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item { return [self childrenOf:item][i]; }
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return [item isKindOfClass:SRSection.class] || [item isKindOfClass:SRFile.class]; }

- (CGFloat)outlineView:(NSOutlineView *)ov heightOfRowByItem:(id)item {
    if ([item isKindOfClass:SRSection.class]) return 24;
    if ([item isKindOfClass:SRFile.class]) return 26;
    if ([item isKindOfClass:SRName.class]) return 24;
    return 21;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)ov rowViewForItem:(id)item {
    SRRowView *r = [SRRowView new];
    r.kind = [item isKindOfClass:SRSection.class] ? 1 : ([item isKindOfClass:SRFile.class] && [_files indexOfObjectIdenticalTo:item] > 0) ? 2 : 0;
    return r;
}

- (NSString *)relativeDir:(NSString *)path {
    NSString *dir = path.stringByDeletingLastPathComponent;
    if ([dir isEqualToString:_root]) return @"";
    if ([dir hasPrefix:_root]) return [dir substringFromIndex:MIN(dir.length, _root.length + 1)];
    return dir.stringByAbbreviatingWithTildeInPath;
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    if ([item isKindOfClass:SRSection.class]) {
        NSTableCellView *c = [ov makeViewWithIdentifier:@"section" owner:self];
        if (!c) {
            c = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
            c.identifier = @"section";
            NSTextField *t = label([NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor, NSLineBreakByTruncatingTail);
            [c addSubview:t];
            c.textField = t;
            [NSLayoutConstraint activateConstraints:@[[t.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:1],
                                                      [t.trailingAnchor constraintLessThanOrEqualToAnchor:c.trailingAnchor constant:-6],
                                                      [t.centerYAnchor constraintEqualToAnchor:c.centerYAnchor]]];
        }
        BOOL names = [(SRSection *)item kind] == SectionNames;
        NSString *title = names ? FTL(@"Names") : FTL(@"Contents");
        NSString *count = names ? [NSString stringWithFormat:@"%lu", (unsigned long)_nameTotal]
                                : [NSString stringWithFormat:@"%@ · %@", [NSString stringWithFormat:FTLP(_hitCount, @"%lu match", @"%lu matches"), (unsigned long)_hitCount],
                                   [NSString stringWithFormat:FTLP(_files.count, @"%lu file", @"%lu files"), (unsigned long)_files.count]];
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
            NSKernAttributeName: @0.4}];
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:count] attributes:@{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}]];
        c.textField.attributedStringValue = s;
        return c;
    }
    if ([item isKindOfClass:SRFile.class] || [item isKindOfClass:SRName.class]) {
        BOOL file = [item isKindOfClass:SRFile.class];
        SRFileCell *c = [ov makeViewWithIdentifier:file ? @"file" : @"name" owner:self];
        if (!c) { c = [[SRFileCell alloc] initWithBadge:file]; c.identifier = file ? @"file" : @"name"; }
        NSString *path = file ? [(SRFile *)item path] : [(SRName *)item path];
        NSString *name = path.lastPathComponent;
        c.imageView.image = FTFileIcon(name, NO);
        c.imageView.contentTintColor = FTFileTint(name, NO);
        c.nameText = name;
        c.dirText = [self relativeDir:path];
        c.nameMatch = file ? NSMakeRange(NSNotFound, 0) : [(SRName *)item nameRange];
        if (file) c.badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)[(SRFile *)item hits].count];
        c.toolTip = path.stringByAbbreviatingWithTildeInPath;
        [c refresh];
        return c;
    }
    if ([item isKindOfClass:SRMore.class]) {
        NSTableCellView *c = [ov makeViewWithIdentifier:@"more" owner:self];
        if (!c) {
            c = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 21)];
            c.identifier = @"more";
            NSTextField *t = label([NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium], NSColor.linkColor, NSLineBreakByTruncatingTail);
            [c addSubview:t];
            c.textField = t;
            [NSLayoutConstraint activateConstraints:@[[t.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:21],
                                                      [t.centerYAnchor constraintEqualToAnchor:c.centerYAnchor]]];
        }
        c.textField.stringValue = _nameTotal > kNamesMax
            ? [NSString stringWithFormat:FTL(@"%lu more names, show the first %lu…"), (unsigned long)(_nameTotal - kNamesInAll), (unsigned long)kNamesMax]
            : [NSString stringWithFormat:FTLP(_nameTotal - kNamesInAll, @"%lu more name, show it…", @"%lu more names, show all…"), (unsigned long)(_nameTotal - kNamesInAll)];
        return c;
    }
    SRHitCell *c = [ov makeViewWithIdentifier:@"hit" owner:self];
    if (!c) { c = [SRHitCell new]; c.identifier = @"hit"; }
    c.hit = item;
    [c refresh];
    return c;
}

- (BOOL)outlineView:(NSOutlineView *)ov shouldSelectItem:(id)item { return ![item isKindOfClass:SRSection.class]; }

- (void)outlineViewItemDidCollapse:(NSNotification *)n {
    if (_reloading) return;
    id item = n.userInfo[@"NSObject"];
    [_collapsed addObject:[item isKindOfClass:SRSection.class] ? @([(SRSection *)item kind]) : [(SRFile *)item path]];
}
- (void)outlineViewItemDidExpand:(NSNotification *)n {
    if (_reloading) return;
    id item = n.userInfo[@"NSObject"];
    [_collapsed removeObject:[item isKindOfClass:SRSection.class] ? @([(SRSection *)item kind]) : [(SRFile *)item path]];
}

#pragma mark Opening

- (void)selectRow:(NSInteger)row {
    [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_ov scrollRowToVisible:row];
}

// focus: YES moves the keyboard to the editor (click / Return); NO keeps it in the results list.
- (void)openItem:(id)item focus:(BOOL)focus {
    if ([item isKindOfClass:SRMore.class]) { _showAllNames = YES; [self reloadNow]; return; }
    if ([item isKindOfClass:SRSection.class]) {
        if ([_ov isItemExpanded:item]) [_ov collapseItem:item]; else [_ov expandItem:item];
        return;
    }
    if ([item isKindOfClass:SRName.class]) { if (self.onOpenFile) self.onOpenFile([(SRName *)item path], focus); return; }
    SearchHit *hit = [item isKindOfClass:SRFile.class] ? [(SRFile *)item hits].firstObject : item;
    if (hit && self.onOpen) self.onOpen(hit, focus);
}

- (void)clicked:(id)sender {
    NSInteger row = _ov.clickedRow;
    if (row < 0) return;
    id item = [_ov itemAtRow:row];
    if ([item isKindOfClass:SRFile.class]) {                          // the triangle toggles, the rest opens
        NSPoint p = [_ov convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
        if (NSPointInRect(p, NSInsetRect([_ov frameOfOutlineCellAtRow:row], -4, 0))) return;
    }
    [self openItem:item focus:NO];
}

- (void)doubleClicked:(id)sender {
    NSInteger row = _ov.clickedRow;
    if (row >= 0) [self openItem:[_ov itemAtRow:row] focus:YES];
}

- (void)openSelected:(BOOL)focus { if (_ov.selectedRow >= 0) [self openItem:[_ov itemAtRow:_ov.selectedRow] focus:focus]; }

// Arrow keys preview the selection; mouse clicks are handled in clicked:.
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    if (_suppressOpen || NSApp.currentEvent.type != NSEventTypeKeyDown || _ov.selectedRow < 0) return;
    id item = [_ov itemAtRow:_ov.selectedRow];
    if ([item isKindOfClass:SRMore.class]) return;
    [self openItem:item focus:NO];
    [_view.window makeFirstResponder:_ov];
}

// Every leaf in display order: content hits, or file names when there are no content hits.
- (NSArray *)leaves {
    NSMutableArray *a = [NSMutableArray array];
    for (SRFile *f in _files) [a addObjectsFromArray:f.hits];
    if (!a.count) [a addObjectsFromArray:_names];
    return a;
}

- (void)selectNextResult:(BOOL)backward {
    NSArray *leaves = self.leaves;
    if (!leaves.count) { NSBeep(); return; }
    id cur = _ov.selectedRow >= 0 ? [_ov itemAtRow:_ov.selectedRow] : nil;
    // a selected file row sits just before its first hit
    NSInteger i = -1;
    if ([cur isKindOfClass:SRFile.class]) {
        NSUInteger first = [leaves indexOfObjectIdenticalTo:[(SRFile *)cur hits].firstObject];
        i = first == NSNotFound ? -1 : (NSInteger)first - 1;
    } else if (cur) {
        NSUInteger k = [leaves indexOfObjectIdenticalTo:cur];
        i = k == NSNotFound ? -1 : (NSInteger)k;
    }
    NSInteger n = (NSInteger)leaves.count;
    NSUInteger next = backward ? (NSUInteger)((i <= 0 ? n : i) - 1) : (NSUInteger)((i + 1) % n);
    id target = leaves[next];
    if ([target isKindOfClass:SearchHit.class]) {
        [_collapsed removeObject:@(SectionContents)];
        [_ov expandItem:_contentSection];
        SRFile *f = _byPath[[(SearchHit *)target path]];
        [_collapsed removeObject:f.path];
        [_ov expandItem:f];
    } else {
        [_collapsed removeObject:@(SectionNames)];
        if (next >= kNamesInAll && self.namesCapped) { _showAllNames = YES; [self reloadNow]; }
        [_ov expandItem:_namesSection];
    }
    NSInteger row = [_ov rowForItem:target];
    if (row < 0) return;
    _suppressOpen = YES;
    [self selectRow:row];
    _suppressOpen = NO;
    [self openItem:target focus:NO];
}

#pragma mark Menu and copying

- (id)menuItemTarget { NSInteger r = _ov.clickedRow >= 0 ? _ov.clickedRow : _ov.selectedRow; return r >= 0 ? [_ov itemAtRow:r] : nil; }

- (NSString *)pathOf:(id)item {
    if ([item isKindOfClass:SRFile.class]) return [(SRFile *)item path];
    if ([item isKindOfClass:SRName.class]) return [(SRName *)item path];
    if ([item isKindOfClass:SearchHit.class]) return [(SearchHit *)item path];
    return nil;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    id item = self.menuItemTarget;
    NSString *path = [self pathOf:item];
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *t, SEL a) {
        NSMenuItem *m = [menu addItemWithTitle:t action:a keyEquivalent:@""];
        m.target = self;
        m.representedObject = item;
        return m;
    };
    if (path) {
        add(FTL(@"Open"), @selector(menuOpen:));
        add(FTL(@"Reveal in File Tree"), @selector(menuReveal:));
        add(FTL(@"Show in Finder"), @selector(menuFinder:));
        [menu addItem:NSMenuItem.separatorItem];
        add(FTL(@"Copy Path"), @selector(copyPaths:));
        add(FTL(@"Copy Relative Path"), @selector(copyRelative:));
        if ([item isKindOfClass:SearchHit.class]) add(FTL(@"Copy Line"), @selector(copyLine:));
    }
    if (_files.count > 1) {
        if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
        add(self.anyFileExpanded ? FTL(@"Collapse All") : FTL(@"Expand All"), @selector(toggleCollapseAll:));
    }
}

- (void)menuOpen:(NSMenuItem *)m { [self openItem:m.representedObject focus:YES]; }
- (void)menuReveal:(NSMenuItem *)m { NSString *p = [self pathOf:m.representedObject]; if (p && self.onReveal) self.onReveal(p); }
- (void)menuFinder:(NSMenuItem *)m {
    NSString *p = [self pathOf:m.representedObject];
    if (p) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p]]];
}

- (void)putString:(NSString *)s {
    if (!s.length) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}
- (void)copyPaths:(id)s {
    id item = [s isKindOfClass:NSMenuItem.class] ? [(NSMenuItem *)s representedObject] : self.menuItemTarget;
    [self putString:[self pathOf:item]];
}
- (void)copyRelative:(NSMenuItem *)m {
    NSString *p = [self pathOf:m.representedObject];
    [self putString:[p hasPrefix:_root] ? [p substringFromIndex:MIN(p.length, _root.length + 1)] : p];
}
- (void)copyLine:(NSMenuItem *)m {
    NSString *t = [[(SearchHit *)m.representedObject preview] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    [self putString:[t hasPrefix:@"…"] ? [t substringFromIndex:1] : t];
}

- (BOOL)anyFileExpanded {
    for (SRFile *f in _files) if ([_ov isItemExpanded:f]) return YES;
    return NO;
}

- (void)toggleCollapseAll:(id)s {
    BOOL collapse = self.anyFileExpanded;
    for (SRFile *f in _files) {
        if (collapse) { [_collapsed addObject:f.path]; [_ov collapseItem:f]; }
        else { [_collapsed removeObject:f.path]; [_ov expandItem:f]; }
    }
    _collapseButton.image = [NSImage imageWithSystemSymbolName:collapse ? @"rectangle.expand.vertical" : @"rectangle.compress.vertical"
                                      accessibilityDescription:collapse ? FTL(@"Expand All") : FTL(@"Collapse All")];
    _collapseButton.toolTip = collapse ? FTL(@"Expand All") : FTL(@"Collapse All");
}

@end


#import "TerminalPanel.h"
#import "TerminalView.h"
#import "TabBarView.h"
#import "FTSplitView.h"
#import "Localization.h"

static const CGFloat kHeightHandleH = 6;
static const CGFloat kColumnHeaderH = 30;
static const NSUInteger kMaxTerminalColumns = 3;

@interface TerminalColumnHostView : FTTabDropView
@property (nonatomic, strong) TabBarView *tabBar;
@property (nonatomic, strong) TerminalView *content;
@property (nonatomic, strong) NSButton *plusButton, *hideButton;
@property (nonatomic, copy) void (^onNew)(void);
@property (nonatomic, copy) void (^onHide)(void);
- (void)layoutColumn;
@end

@implementation TerminalColumnHostView

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    FTClipToBounds(self);
    _tabBar = [[TabBarView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, kColumnHeaderH)];
    _plusButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:FTL(@"New Terminal")]
                                   target:self action:@selector(newTerminal:)];
    _hideButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:FTL(@"Hide Terminal Panel")]
                                   target:self action:@selector(hidePanel:)];
    _plusButton.toolTip = FTL(@"New Terminal");
    _hideButton.toolTip = FTL(@"Hide Terminal Panel");
    for (NSButton *button in @[_plusButton, _hideButton]) {
        button.bordered = NO;
        button.imagePosition = NSImageOnly;
        button.contentTintColor = NSColor.secondaryLabelColor;
        button.focusRingType = NSFocusRingTypeNone;
        [self addSubview:button];
    }
    [self addSubview:_tabBar];
    return self;
}

- (void)setContent:(TerminalView *)content {
    if (_content == content) return;
    [_content removeFromSuperview];
    _content = content;
    if (content) {
        content.autoresizingMask = 0;
        [self addSubview:content positioned:NSWindowBelow relativeTo:_tabBar];
    }
    [self layoutColumn];
}

- (void)newTerminal:(id)sender { if (self.onNew) self.onNew(); }
- (void)hidePanel:(id)sender { if (self.onHide) self.onHide(); }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSRect)dropContentRect {
    return NSMakeRect(0, kColumnHeaderH, self.bounds.size.width,
                      MAX(0, self.bounds.size.height - kColumnHeaderH));
}
- (void)layoutColumn {
    NSRect b = self.bounds;
    CGFloat controls = self.hideButton.hidden ? 26 : 52;
    _plusButton.hidden = b.size.width < controls;
    CGFloat tabWidth = MAX(0, b.size.width - controls);
    _tabBar.frame = NSMakeRect(0, 0, tabWidth, kColumnHeaderH);
    _plusButton.frame = NSMakeRect(tabWidth, 0, 26, kColumnHeaderH);
    _hideButton.frame = NSMakeRect(MAX(0, b.size.width - 26), 0, 26, kColumnHeaderH);
    _content.frame = NSMakeRect(0, kColumnHeaderH, b.size.width, MAX(0, b.size.height - kColumnHeaderH));
    self.needsDisplay = YES;
}

- (void)layout { [super layout]; [self layoutColumn]; }
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize { [self layoutColumn]; }

- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, kColumnHeaderH - 1, self.bounds.size.width, 1));
}

@end

// State and host identities survive tab moves and column reordering, including at the split cap.
@interface TerminalColumnState : NSObject
@property (nonatomic, strong) NSMutableArray<TSession *> *sessions;
@property (nonatomic, strong) TSession *active;
@property (nonatomic, strong) TerminalColumnHostView *host;
@end

@implementation TerminalColumnState
- (instancetype)init {
    if ((self = [super init])) {
        _sessions = [NSMutableArray array];
        _host = [[TerminalColumnHostView alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];
    }
    return self;
}
@end

@interface TerminalPanel () {
    FTSplitView *_split;
    NSMutableArray<TerminalColumnState *> *_columns;
    TerminalColumnState *_focusedColumn;
    NSMapTable<TSession *, TerminalView *> *_views;
    BOOL _draggingHeight;
    NSPoint _dragAnchor;
    CGFloat _startHeight;
}
@end

@implementation TerminalPanel

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    FTClipToBounds(self);
    _columns = [NSMutableArray array];
    _views = [NSMapTable strongToStrongObjectsMapTable];
    _split = [[FTSplitView alloc] initWithFrame:NSZeroRect];
    _split.minimumItemWidth = 180;
    __weak typeof(self) weakSelf = self;
    _split.onFocusItem = ^(NSInteger index) {
        TerminalPanel *panel = weakSelf;
        if (!panel || index < 0 || index >= (NSInteger)panel->_columns.count) return;
        NSResponder *responder = panel.window.firstResponder;
        if ([responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:panel->_columns[index].host])
            [panel syncFocus];
        else [panel focusSession:panel->_columns[index].active];
    };
    _split.onMaximizeChange = ^(BOOL maximized) {
        TerminalPanel *panel = weakSelf;
        if (!panel) return;
        NSInteger index = panel->_split.focused;
        if (index >= 0 && index < (NSInteger)panel->_columns.count) {
            panel->_focusedColumn = panel->_columns[(NSUInteger)index];
            if (panel.currentView) [panel.window makeFirstResponder:panel.currentView];
        }
        [panel stateChanged];
    };
    [self addSubview:_split];
    [self layout];
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSArray<TSession *> *)sessions {
    NSMutableArray<TSession *> *sessions = [NSMutableArray array];
    for (TerminalColumnState *column in _columns) [sessions addObjectsFromArray:column.sessions];
    return [sessions copy];
}

- (TSession *)activeSession { return _focusedColumn.active; }
- (NSUInteger)columnCount { return _columns.count; }
- (NSView *)currentView { return self.activeSession ? [_views objectForKey:self.activeSession] : nil; }

- (NSArray<NSView *> *)columnViews {
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithCapacity:_columns.count];
    for (TerminalColumnState *column in _columns) [views addObject:column.host];
    return [views copy];
}

- (NSArray<TabBarView *> *)tabBars {
    NSMutableArray<TabBarView *> *bars = [NSMutableArray arrayWithCapacity:_columns.count];
    for (TerminalColumnState *column in _columns) [bars addObject:column.host.tabBar];
    return [bars copy];
}

- (NSUInteger)tabCount {
    NSUInteger count = 0;
    for (TerminalColumnState *column in _columns) count += column.sessions.count;
    return count;
}

- (BOOL)isMaximized { return _split.isMaximized; }
- (void)setMaximized:(BOOL)maximized {
    [self syncFocus];
    _split.maximized = maximized && _columns.count > 1;
}

- (void)stateChanged { if (self.onStateChange) self.onStateChange(); }

- (TerminalColumnState *)columnForSession:(TSession *)session {
    if (!session) return nil;
    for (TerminalColumnState *column in _columns)
        if ([column.sessions indexOfObjectIdenticalTo:session] != NSNotFound) return column;
    return nil;
}

- (BOOL)containsSession:(TSession *)t { return [self columnForSession:t] != nil; }

- (TerminalView *)viewForSession:(TSession *)session {
    TerminalView *view = [_views objectForKey:session];
    if (!view) {
        view = self.viewProvider ? self.viewProvider(session) : [[TerminalView alloc] initWithSession:session];
        [_views setObject:view forKey:session];
    }
    return view;
}

- (BOOL)canMoveSession:(TSession *)session toColumn:(NSUInteger)index zone:(FTTabDropZone)zone {
    if (!session || zone < FTTabDropInto || zone > FTTabDropAfter) return NO;
    if (!_columns.count) return index == 0;
    if (index >= _columns.count) return NO;
    if (zone == FTTabDropInto) return YES;
    TerminalColumnState *source = [self columnForSession:session];
    if (source == _columns[index] && source.sessions.count == 1) return NO;
    return _columns.count < kMaxTerminalColumns || (source && source.sessions.count == 1);
}

- (BOOL)canDropToken:(NSString *)token terminal:(BOOL)terminal column:(TerminalColumnState *)column zone:(FTTabDropZone)zone {
    if (!terminal || !column) return NO;
    NSUInteger index = [_columns indexOfObjectIdenticalTo:column];
    TSession *session = [TSession sessionForDragToken:token];
    if (index == NSNotFound || ![self canMoveSession:session toColumn:index zone:zone]) return NO;
    return [self containsSession:session] || self.onDropTerminal != nil;
}

- (BOOL)dropToken:(NSString *)token terminal:(BOOL)terminal column:(TerminalColumnState *)column zone:(FTTabDropZone)zone index:(NSInteger)tabIndex {
    if (![self canDropToken:token terminal:terminal column:column zone:zone]) return NO;
    NSUInteger index = [_columns indexOfObjectIdenticalTo:column];
    TSession *session = [TSession sessionForDragToken:token];
    if ([self containsSession:session]) return [self moveSession:session toColumn:index zone:zone index:tabIndex];
    return self.onDropTerminal ? self.onDropTerminal(token, index, zone, tabIndex) : NO;
}

- (TerminalColumnState *)newColumn {
    TerminalColumnState *column = [TerminalColumnState new];
    __weak typeof(self) weakSelf = self;
    __weak TerminalColumnState *weakColumn = column;
    TabBarView *bar = column.host.tabBar;
    bar.tabDragType = FTTerminalDragType;
    bar.onSelect = ^(NSInteger index) {
        TerminalColumnState *col = weakColumn;
        if (index >= 0 && index < (NSInteger)col.sessions.count) [weakSelf focusSession:col.sessions[(NSUInteger)index]];
    };
    bar.onDoubleClick = ^(NSInteger index) {
        TerminalPanel *panel = weakSelf;
        TerminalColumnState *col = weakColumn;
        if (!panel || index < 0 || index >= (NSInteger)col.sessions.count) return;
        [panel focusSession:col.sessions[(NSUInteger)index]];
        if (panel.columnCount > 1) panel.maximized = !panel.maximized;
    };
    bar.onClose = ^(NSInteger index) {
        TerminalPanel *panel = weakSelf;
        TerminalColumnState *col = weakColumn;
        if (index >= 0 && index < (NSInteger)col.sessions.count && panel.onClose) panel.onClose(col.sessions[(NSUInteger)index]);
    };
    bar.tabDragTokenForIndex = ^NSString *(NSInteger index) {
        TerminalColumnState *col = weakColumn;
        return index >= 0 && index < (NSInteger)col.sessions.count ? [TSession registerDragSession:col.sessions[(NSUInteger)index]] : nil;
    };
    bar.canDropTab = ^BOOL(NSString *token, BOOL terminal) {
        return [weakSelf canDropToken:token terminal:terminal column:weakColumn zone:FTTabDropInto];
    };
    bar.onDropTab = ^BOOL(NSString *token, BOOL terminal, NSInteger index) {
        return [weakSelf dropToken:token terminal:terminal column:weakColumn zone:FTTabDropInto index:index];
    };
    column.host.canDropTab = ^BOOL(NSString *token, BOOL terminal, FTTabDropZone zone) {
        return [weakSelf canDropToken:token terminal:terminal column:weakColumn zone:zone];
    };
    column.host.onDropTab = ^BOOL(NSString *token, BOOL terminal, FTTabDropZone zone, NSInteger index) {
        return [weakSelf dropToken:token terminal:terminal column:weakColumn zone:zone index:index];
    };
    column.host.onNew = ^{
        TerminalPanel *panel = weakSelf;
        TerminalColumnState *col = weakColumn;
        if (!panel || !col || [panel->_columns indexOfObjectIdenticalTo:col] == NSNotFound) return;
        [panel focusSession:col.active];
        if (panel.onNew) panel.onNew();
    };
    column.host.onHide = ^{ TerminalPanel *panel = weakSelf; if (panel.onHide) panel.onHide(); };
    return column;
}

// Clear stale host attachments before installing any moved view in its new host.
- (void)updateColumns {
    if (!_focusedColumn || [_columns indexOfObjectIdenticalTo:_focusedColumn] == NSNotFound) _focusedColumn = _columns.firstObject;
    for (TerminalColumnState *column in _columns) {
        if (column.host.content != [_views objectForKey:column.active]) column.host.content = nil;
    }
    for (TerminalColumnState *column in _columns) {
        column.host.content = [self viewForSession:column.active];
        column.host.hideButton.hidden = column != _columns.lastObject;
    }
    NSArray<NSView *> *hosts = self.columnViews;
    if (![_split.items isEqualToArray:hosts]) _split.items = hosts;
    _split.focused = _focusedColumn ? (NSInteger)[_columns indexOfObjectIdenticalTo:_focusedColumn] : 0;
    [self refreshTitles];
    [self layout];
}

- (void)addSession:(TSession *)t {
    if (!t) return;
    if ([self containsSession:t]) { [self focusSession:t]; return; }
    [self syncFocus];
    if (!_focusedColumn) {
        _focusedColumn = [self newColumn];
        [_columns addObject:_focusedColumn];
    }
    [_focusedColumn.sessions addObject:t];
    _focusedColumn.active = t;
    [self viewForSession:t];
    [self updateColumns];
    [self.window makeFirstResponder:self.currentView];
    [self stateChanged];
}

- (void)removeSession:(TSession *)t fromColumn:(TerminalColumnState *)column {
    NSUInteger index = [column.sessions indexOfObjectIdenticalTo:t];
    [column.sessions removeObjectAtIndex:index];
    if (column.active == t) column.active = column.sessions.count ? column.sessions[MIN(index, column.sessions.count - 1)] : nil;
}

- (void)removeSession:(TSession *)t {
    TerminalColumnState *column = [self columnForSession:t];
    if (!column) return;
    [self syncFocus];
    NSResponder *responder = self.window.firstResponder;
    BOOL hadFocus = [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:self];
    TerminalView *view = [_views objectForKey:t];
    if (column.host.content == view) column.host.content = nil;
    [view removeFromSuperview];
    [self removeSession:t fromColumn:column];
    if (!column.sessions.count) {
        NSUInteger index = [_columns indexOfObjectIdenticalTo:column];
        [_columns removeObjectAtIndex:index];
        if (_focusedColumn == column) _focusedColumn = _columns.count ? _columns[MIN(index, _columns.count - 1)] : nil;
    }
    // Detach before releasing the cache entry; a replacement editor view owns its own callbacks.
    [_views removeObjectForKey:t];
    [self updateColumns];
    if (hadFocus) [self.window makeFirstResponder:self.currentView];
    [self stateChanged];
}

- (BOOL)moveSession:(TSession *)t toColumn:(NSUInteger)index zone:(FTTabDropZone)zone index:(NSInteger)tabIndex {
    if (![self canMoveSession:t toColumn:index zone:zone]) return NO;
    TerminalColumnState *source = [self columnForSession:t];
    TerminalColumnState *target = _columns.count ? _columns[index] : nil;
    if (!target) {
        target = [self newColumn];
        [_columns addObject:target];
        zone = FTTabDropInto;
    }
    [self viewForSession:t];
    if (zone != FTTabDropInto && source.sessions.count == 1) {
        // Reuse a sole source column, so relocation still works with all three slots occupied.
        [_columns removeObjectIdenticalTo:source];
        NSUInteger at = [_columns indexOfObjectIdenticalTo:target] + (zone == FTTabDropAfter ? 1 : 0);
        [_columns insertObject:source atIndex:at];
        target = source;
    } else {
        NSUInteger insertion = tabIndex < 0 ? target.sessions.count : MIN((NSUInteger)tabIndex, target.sessions.count);
        if (source == target) {
            NSUInteger from = [source.sessions indexOfObjectIdenticalTo:t];
            if (from < insertion) insertion--;
        }
        if (source) {
            [self removeSession:t fromColumn:source];
            if (!source.sessions.count && source != target) {
                source.host.content = nil;
                [_columns removeObjectIdenticalTo:source];
            }
        }
        if (zone != FTTabDropInto && _columns.count) {
            NSUInteger at = [_columns indexOfObjectIdenticalTo:target] + (zone == FTTabDropAfter ? 1 : 0);
            target = [self newColumn];
            [_columns insertObject:target atIndex:at];
            insertion = 0;
        }
        [target.sessions insertObject:t atIndex:MIN(insertion, target.sessions.count)];
        target.active = t;
    }
    _focusedColumn = target;
    [self updateColumns];
    [self.window makeFirstResponder:self.currentView];
    [self stateChanged];
    return YES;
}

- (void)focusSession:(TSession *)t {
    TerminalColumnState *column = [self columnForSession:t];
    if (!column) return;
    BOOL changed = _focusedColumn != column || column.active != t;
    _focusedColumn = column;
    column.active = t;
    [self updateColumns];
    [self.window makeFirstResponder:self.currentView];
    if (changed) [self stateChanged];
}

- (void)syncFocus {
    NSResponder *responder = self.window.firstResponder;
    if (![responder isKindOfClass:NSView.class]) return;
    for (TerminalColumnState *column in _columns) {
        if (![(NSView *)responder isDescendantOf:column.host]) continue;
        BOOL changed = _focusedColumn != column;
        _focusedColumn = column;
        NSUInteger index = [_columns indexOfObjectIdenticalTo:column];
        if (_split.focused != (NSInteger)index) _split.focused = (NSInteger)index;
        if (changed) [self stateChanged];
        return;
    }
}

- (void)refreshTitles {
    for (TerminalColumnState *column in _columns) {
        NSMutableArray<TabItem *> *items = [NSMutableArray arrayWithCapacity:column.sessions.count];
        for (TSession *session in column.sessions) {
            NSString *directory = session.screen.cwd.length ? session.screen.cwd : session.directory;
            TabItem *item = [TabItem new];
            item.title = session.exited ? FTL(@"ended") : (directory.lastPathComponent ?: @"/");
            item.toolTip = session.screen.title.length ? [NSString stringWithFormat:@"%@\n%@", session.screen.title, directory] : directory;
            [items addObject:item];
        }
        column.host.tabBar.items = items;
        NSUInteger selected = [column.sessions indexOfObjectIdenticalTo:column.active];
        column.host.tabBar.selectedIndex = selected == NSNotFound ? -1 : (NSInteger)selected;
        [column.host.tabBar reload];
    }
}

- (void)closeTabAtIndex:(NSUInteger)i {
    NSArray<TSession *> *sessions = self.sessions;
    if (i < sessions.count && self.onClose) self.onClose(sessions[i]);
}

#pragma mark Layout and height handle

- (void)layout {
    [super layout];
    NSRect b = self.bounds;
    _split.frame = NSMakeRect(0, kHeightHandleH, b.size.width, MAX(0, b.size.height - kHeightHandleH));
    [_split applyLayout];
    for (TerminalColumnState *column in _columns) [column.host layoutColumn];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [self layout];
    [self.window invalidateCursorRectsForView:self];
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirty);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
    NSRectFill(NSMakeRect(MAX(0, self.bounds.size.width / 2 - 24), 2, MIN(48, self.bounds.size.width), 2));
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    _draggingHeight = point.y >= 0 && point.y < kHeightHandleH;
    if (!_draggingHeight) return;
    _dragAnchor = event.locationInWindow;
    _startHeight = self.bounds.size.height;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_draggingHeight) return;
    CGFloat maximum = self.superview ? MAX(120, self.superview.bounds.size.height - 120) : 600;
    // Window coordinates remain fixed while the panel's top edge and local origin move.
    CGFloat height = MIN(maximum, MAX(120, _startHeight + event.locationInWindow.y - _dragAnchor.y));
    if (fabs(height - self.bounds.size.height) >= 1 && self.onHeightChange) self.onHeightChange(height);
}

- (void)mouseUp:(NSEvent *)event { _draggingHeight = NO; }

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:NSMakeRect(0, 0, self.bounds.size.width, MIN(kHeightHandleH, self.bounds.size.height)) cursor:NSCursor.resizeUpDownCursor];
}

@end

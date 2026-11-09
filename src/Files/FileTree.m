#import "FileTree.h"
#import "FileOps.h"
#import "FileIcons.h"
#import "FileWalker.h"
#include <dirent.h>
#include <sys/stat.h>

@interface FileNode () {
@public
    NSString *_rootPath;              // only set on the root
    NSArray<FileNode *> *_children;   // nil = not loaded yet
}
@property (nonatomic, readwrite) NSString *name;
@property (nonatomic, readwrite) BOOL isDir;
@property (nonatomic, readwrite, weak) FileNode *parent;
@end

@implementation FileNode
- (NSString *)path { return _rootPath ?: [_parent.path stringByAppendingPathComponent:_name]; }
@end

@implementation FileOutlineView
- (void)keyDown:(NSEvent *)e {
    NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagFunction & ~NSEventModifierFlagNumericPad;
    unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
    if ((c == '\r' || c == 3) && m == 0 && self.numberOfSelectedRows == 1) { [NSApp sendAction:@selector(renameItem:) to:nil from:self]; return; }
    if ((c == NSBackspaceCharacter || c == NSDeleteCharacter) && m == NSEventModifierFlagCommand && self.selectedRow >= 0) {
        [NSApp sendAction:@selector(trashItem:) to:nil from:self]; return;
    }
    [super keyDown:e];
}
@end

@implementation FileTree {
    __weak NSOutlineView *_ov;
    FileNode *_root;
    NSInteger _suppressSelect;
    NSUInteger _refreshGen;
}

- (instancetype)initWithOutlineView:(NSOutlineView *)ov {
    if (!(self = [super init])) return nil;
    _ov = ov;
    ov.dataSource = self;
    ov.delegate = self;
    ov.target = self;
    ov.action = @selector(clicked:);
    ov.doubleAction = @selector(doubleClicked:);
    ov.allowsMultipleSelection = YES;
    return self;
}

- (void)setRootPath:(NSString *)p {
    _rootPath = [p copy];
    _root = [FileNode new];
    _root->_rootPath = _rootPath;
    _root.isDir = YES;
    _suppressSelect++;
    [_ov reloadData];
    _suppressSelect--;
}

- (void)reloadAndReveal:(NSString *)path {
    _suppressSelect++;
    [self rescan:_root];
    [_ov reloadData];
    _suppressSelect--;
    [self revealPath:path];
}

- (void)setShowHidden:(BOOL)h { _showHidden = h; [self reload]; }

// One folder's entries as name → is a folder; safe on any thread.
static NSDictionary<NSString *, NSNumber *> *listFolder(NSString *dirPath, BOOL showHidden) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    DIR *d = opendir(dirPath.fileSystemRepresentation);
    if (!d) return out;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (!showHidden && e->d_name[0] == '.') continue;
        if (FWIsAlwaysHidden(@(e->d_name))) continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:e->d_name length:strlen(e->d_name)];
        BOOL dir = e->d_type == DT_DIR;
        if (e->d_type == DT_LNK || e->d_type == DT_UNKNOWN) {
            struct stat st;
            dir = stat([dirPath stringByAppendingPathComponent:name].fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
        }
        out[name] = @(dir);
    }
    closedir(d);
    return out;
}

- (NSArray<FileNode *> *)scan:(FileNode *)node reuse:(NSArray<FileNode *> *)old {
    return [self nodesFor:listFolder(node.path, _showHidden) parent:node reuse:old];
}

- (NSArray<FileNode *> *)nodesFor:(NSDictionary<NSString *, NSNumber *> *)entries parent:(FileNode *)node reuse:(NSArray<FileNode *> *)old {
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (FileNode *n in old) byName[n.name] = n;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *name in entries) {
        BOOL dir = entries[name].boolValue;
        FileNode *n = byName[name];
        if (!n || n.isDir != dir) { n = [FileNode new]; n.name = name; n.isDir = dir; }
        n.parent = node;
        [out addObject:n];
    }
    [out sortUsingComparator:^NSComparisonResult(FileNode *a, FileNode *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return out;
}

- (NSArray<FileNode *> *)childrenOf:(FileNode *)n {
    if (!n->_children) n->_children = [self scan:n reuse:nil];
    return n->_children;
}

- (void)rescan:(FileNode *)n {
    if (!n || !n->_children) return;
    n->_children = [self scan:n reuse:n->_children];
    for (FileNode *c in n->_children) if (c.isDir) [self rescan:c];
}

// Folders already shown are re-read on a background queue; the outline only reloads if something changed.
- (void)refreshInBackground {
    if (!_root) return;
    NSMutableArray<FileNode *> *dirs = [NSMutableArray array], *stack = [NSMutableArray arrayWithObject:_root];
    while (stack.count) {
        FileNode *n = stack.lastObject; [stack removeLastObject];
        if (!n->_children) continue;
        [dirs addObject:n];
        for (FileNode *c in n->_children) if (c.isDir) [stack addObject:c];
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (FileNode *n in dirs) [paths addObject:n.path];
    NSUInteger gen = ++_refreshGen;
    BOOL hidden = _showHidden;
    FileNode *root = _root;
    __weak FileTree *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableArray *lists = [NSMutableArray array];
        for (NSString *p in paths) [lists addObject:listFolder(p, hidden)];
        dispatch_async(dispatch_get_main_queue(), ^{
            FileTree *me = weakSelf;
            if (!me || me->_refreshGen != gen || me->_root != root) return;
            BOOL changed = NO;
            for (NSUInteger i = 0; i < dirs.count; i++) {
                FileNode *n = dirs[i];
                NSDictionary *now = lists[i];
                if (now.count == n->_children.count) {
                    BOOL same = YES;
                    for (FileNode *c in n->_children) if (![now[c.name] isEqual:@(c.isDir)]) { same = NO; break; }
                    if (same) continue;
                }
                n->_children = [me nodesFor:now parent:n reuse:n->_children];
                changed = YES;
            }
            if (!changed) return;
            NSArray *sel = me.selectedPaths;
            me->_suppressSelect++;
            [me->_ov reloadData];
            me->_suppressSelect--;
            if (sel.count) [me revealPaths:sel];
            if (me.onRefreshed) me.onRefreshed();
        });
    });
}

- (void)reload {
    if (!_root) return;                                  // no folder open yet
    NSArray *sel = self.selectedPaths;
    _suppressSelect++;
    [self rescan:_root];
    [_ov reloadData];
    _suppressSelect--;
    if (sel.count) [self revealPaths:sel];
}

- (NSString *)selectedPath {
    FileNode *n = [_ov itemAtRow:_ov.selectedRow];
    return n.path;
}

- (NSArray<NSString *> *)pathsForRows:(NSIndexSet *)rows {
    NSMutableArray *out = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        FileNode *n = [self->_ov itemAtRow:(NSInteger)r];
        if (n) [out addObject:n.path];
    }];
    return out;
}

- (NSArray<NSString *> *)selectedPaths { return [self pathsForRows:_ov.selectedRowIndexes]; }

- (NSString *)clickedPath {
    NSInteger r = _ov.clickedRow;
    return r >= 0 ? [(FileNode *)[_ov itemAtRow:r] path] : nil;
}

- (NSArray<NSString *> *)clickedPaths {
    NSInteger r = _ov.clickedRow;
    if (r < 0) return @[];
    if ([_ov.selectedRowIndexes containsIndex:(NSUInteger)r]) return self.selectedPaths;
    return [self pathsForRows:[NSIndexSet indexSetWithIndex:(NSUInteger)r]];
}

// Expands the ancestors of path; returns its row or -1.
- (NSInteger)expandTo:(NSString *)path {
    if (!_root || !FOPathIsWithin(path, _rootPath) || [path isEqualToString:_rootPath]) return -1;
    NSString *rel = [path substringFromIndex:_rootPath.length];
    FileNode *cur = _root;
    for (NSString *comp in rel.pathComponents) {
        if ([comp isEqualToString:@"/"]) continue;
        FileNode *next = nil;
        for (FileNode *c in [self childrenOf:cur]) if ([c.name isEqualToString:comp]) { next = c; break; }
        if (!next) return -1;
        if (cur != _root) [_ov expandItem:cur];
        cur = next;
    }
    return [_ov rowForItem:cur];
}

- (void)revealPath:(NSString *)path {
    if (!_root || !FOPathIsWithin(path, _rootPath) || [path isEqualToString:_rootPath]) return;
    [self revealPaths:@[path]];
}

- (void)revealPaths:(NSArray<NSString *> *)paths {
    if (!_root) return;
    for (NSString *p in paths) [self expandTo:p];
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];       // second pass: expanding shifted earlier rows
    for (NSString *p in paths) { NSInteger r = [self expandTo:p]; if (r >= 0) [rows addIndex:(NSUInteger)r]; }
    _suppressSelect++;
    if (rows.count) { [_ov selectRowIndexes:rows byExtendingSelection:NO]; [_ov scrollRowToVisible:(NSInteger)rows.firstIndex]; }
    else [_ov deselectAll:nil];
    _suppressSelect--;
}

// Single click: folders toggle (unless the disclosure triangle already did), files open as preview.
// ⇧ / ⌘ clicks only change the selection.
- (void)clicked:(id)sender {
    NSInteger row = _ov.clickedRow;
    FileNode *n = [_ov itemAtRow:row];
    if (!n) return;
    NSEventModifierFlags m = NSApp.currentEvent.modifierFlags;
    if ((m & (NSEventModifierFlagShift | NSEventModifierFlagCommand)) || _ov.numberOfSelectedRows > 1) return;
    if (n.isDir) {
        NSPoint p = [_ov convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
        if (NSPointInRect(p, NSInsetRect([_ov frameOfOutlineCellAtRow:row], -4, 0))) return;
        if ([_ov isItemExpanded:n]) [_ov.animator collapseItem:n]; else [_ov.animator expandItem:n];
        return;
    }
    if (self.onOpen) self.onOpen(n.path, NO);
}

- (void)doubleClicked:(id)sender {
    FileNode *n = [_ov itemAtRow:_ov.clickedRow];
    if (n && !n.isDir && self.onOpen) self.onOpen(n.path, YES);
}

#pragma mark Data source / delegate

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(FileNode *)item {
    if (!_root) return 0;
    return [self childrenOf:item ?: _root].count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(FileNode *)item {
    return [self childrenOf:item ?: _root][i];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(FileNode *)item { return item.isDir; }


- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(FileNode *)item {
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
        cell.identifier = @"cell";
        NSImageView *iv = [NSImageView imageViewWithImage:[NSImage new]];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
        iv.translatesAutoresizingMaskIntoConstraints = tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv]; [cell addSubview:tf];
        cell.imageView = iv; cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:16],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:5],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
    }
    cell.textField.stringValue = item.name;
    cell.imageView.image = FTFileIcon(item.name, item.isDir);
    cell.imageView.contentTintColor = item.isDir ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    return cell;
}

// Arrow-key navigation previews files; mouse clicks are handled in clicked:.
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    if (_suppressSelect || NSApp.currentEvent.type != NSEventTypeKeyDown || _ov.numberOfSelectedRows != 1) return;
    FileNode *node = [_ov itemAtRow:_ov.selectedRow];
    if (node && !node.isDir && self.onOpen) self.onOpen(node.path, NO);
}

@end

#import "FileTree.h"
#import "FileOps.h"
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
    if ((c == '\r' || c == 3) && m == 0 && self.selectedRow >= 0) { [NSApp sendAction:@selector(renameItem:) to:nil from:self]; return; }
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
}

- (instancetype)initWithOutlineView:(NSOutlineView *)ov {
    if (!(self = [super init])) return nil;
    _ov = ov;
    ov.dataSource = self;
    ov.delegate = self;
    ov.target = self;
    ov.action = @selector(clicked:);
    ov.doubleAction = @selector(doubleClicked:);
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

- (NSArray<FileNode *> *)scan:(FileNode *)node reuse:(NSArray<FileNode *> *)old {
    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (FileNode *n in old) byName[n.name] = n;
    NSString *dirPath = node.path;
    NSMutableArray *out = [NSMutableArray array];
    DIR *d = opendir(dirPath.fileSystemRepresentation);
    if (!d) return out;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (!_showHidden && e->d_name[0] == '.') continue;
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:e->d_name length:strlen(e->d_name)];
        BOOL dir = e->d_type == DT_DIR;
        if (e->d_type == DT_LNK || e->d_type == DT_UNKNOWN) {
            struct stat st;
            dir = stat([dirPath stringByAppendingPathComponent:name].fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode);
        }
        FileNode *n = byName[name];
        if (!n || n.isDir != dir) { n = [FileNode new]; n.name = name; n.isDir = dir; }
        n.parent = node;
        [out addObject:n];
    }
    closedir(d);
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
    if (!n->_children) return;
    n->_children = [self scan:n reuse:n->_children];
    for (FileNode *c in n->_children) if (c.isDir) [self rescan:c];
}

- (void)reload {
    NSString *sel = self.selectedPath;
    _suppressSelect++;
    [self rescan:_root];
    [_ov reloadData];
    _suppressSelect--;
    if (sel) [self revealPath:sel];
}

- (NSString *)selectedPath {
    FileNode *n = [_ov itemAtRow:_ov.selectedRow];
    return n.path;
}

- (NSString *)clickedPath {
    NSInteger r = _ov.clickedRow;
    return r >= 0 ? [(FileNode *)[_ov itemAtRow:r] path] : nil;
}

- (void)revealPath:(NSString *)path {
    if (!_root || !FOPathIsWithin(path, _rootPath) || [path isEqualToString:_rootPath]) return;
    NSString *rel = [path substringFromIndex:_rootPath.length];
    FileNode *cur = _root;
    BOOL found = YES;
    for (NSString *comp in rel.pathComponents) {
        if ([comp isEqualToString:@"/"]) continue;
        FileNode *next = nil;
        for (FileNode *c in [self childrenOf:cur]) if ([c.name isEqualToString:comp]) { next = c; break; }
        if (!next) { found = NO; break; }
        if (cur != _root) [_ov expandItem:cur];
        cur = next;
    }
    _suppressSelect++;
    NSInteger row = found ? [_ov rowForItem:cur] : -1;
    if (row >= 0) { [_ov selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; [_ov scrollRowToVisible:row]; }
    else [_ov deselectAll:nil];
    _suppressSelect--;
}

// Single click: folders toggle (unless the disclosure triangle already did), files open as preview.
- (void)clicked:(id)sender {
    NSInteger row = _ov.clickedRow;
    FileNode *n = [_ov itemAtRow:row];
    if (!n) return;
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

static NSString *symbolFor(FileNode *n) {
    if (n.isDir) return @"folder";
    NSString *e = n.name.pathExtension.lowercaseString;
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp", @"svg"] containsObject:e]) return @"photo";
    if ([@[@"pdf"] containsObject:e]) return @"doc.richtext";
    if ([@[@"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"wav"] containsObject:e]) return @"play.rectangle";
    if ([@[@"zip", @"gz", @"tar", @"7z", @"rar", @"dmg"] containsObject:e]) return @"archivebox";
    if ([@[@"c", @"h", @"m", @"swift", @"js", @"ts", @"py", @"go", @"rs", @"java", @"rb", @"sh", @"json", @"html", @"css"] containsObject:e])
        return @"chevron.left.forwardslash.chevron.right";
    return @"doc";
}

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
    cell.imageView.image = [NSImage imageWithSystemSymbolName:symbolFor(item) accessibilityDescription:item.isDir ? @"文件夹" : @"文件"];
    cell.imageView.contentTintColor = item.isDir ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    return cell;
}

// Arrow-key navigation previews files; mouse clicks are handled in clicked:.
- (void)outlineViewSelectionDidChange:(NSNotification *)n {
    if (_suppressSelect || NSApp.currentEvent.type != NSEventTypeKeyDown) return;
    FileNode *node = [_ov itemAtRow:_ov.selectedRow];
    if (node && !node.isDir && self.onOpen) self.onOpen(node.path, NO);
}

@end

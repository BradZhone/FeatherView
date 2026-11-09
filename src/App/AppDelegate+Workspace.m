#import "AppDelegate.h"
#import "Localization.h"
#import "FileOps.h"
#import "FileWalker.h"

static const NSUInteger kMaxRecent = 10;

@interface PickerGeneration : NSObject
@property (atomic) NSUInteger value;
@end
@implementation PickerGeneration @end

@implementation AppDelegate (Workspace)

#pragma mark Recent workspaces

- (NSArray<NSString *> *)recentRoots {
    NSArray *a = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"recentRoots"] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in a) {
        BOOL dir = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir) [out addObject:p];
    }
    return out;
}

// The stored list keeps folders that are missing right now (a disk that is not mounted); only the menus skip them.
- (void)noteRecentRoot:(NSString *)root {
    NSMutableArray *a = [[NSUserDefaults.standardUserDefaults stringArrayForKey:@"recentRoots"] mutableCopy] ?: [NSMutableArray array];
    [a removeObject:root];
    [a insertObject:root atIndex:0];
    while (a.count > kMaxRecent) [a removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:a forKey:@"recentRoots"];
}

// Only the list entry: the folder's saved tabs (and untitled documents) come back when it is opened again.
- (void)removeRecentRoot:(NSString *)root {
    if (!root.length) return;
    NSMutableArray *a = [[NSUserDefaults.standardUserDefaults stringArrayForKey:@"recentRoots"] mutableCopy] ?: [NSMutableArray array];
    [a removeObject:root];
    [NSUserDefaults.standardUserDefaults setObject:a forKey:@"recentRoots"];
    [self refreshWorkspaceUI];
}
- (void)removeRecent:(NSMenuItem *)s { [self removeRecentRoot:s.representedObject]; }

- (void)openRecent:(NSMenuItem *)s { [self switchToRoot:s.representedObject]; }
- (void)clearRecent:(id)s {
    NSArray *keep = _tree.rootPath ? @[_tree.rootPath] : @[];
    [NSUserDefaults.standardUserDefaults setObject:keep forKey:@"recentRoots"];
    [self refreshWorkspaceUI];
}

- (void)openFolder:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.prompt = FTL(@"Open");
    p.directoryURL = [NSURL fileURLWithPath:_tree.rootPath ?: NSHomeDirectory()];
    [p beginSheetModalForWindow:_win completionHandler:^(NSModalResponse r) {
        if (r == NSModalResponseOK) [self switchToRoot:p.URL.path.stringByStandardizingPath];
    }];
}

#pragma mark Pickers

- (void)presentPicker:(QuickPicker *)p cleanup:(void (^)(void))cleanup {
    [_picker dismiss];
    _picker = p;
    __weak AppDelegate *weakSelf = self;
    __weak QuickPicker *weakP = p;
    p.onDismiss = ^{
        if (cleanup) cleanup();
        AppDelegate *me = weakSelf;
        if (me && me->_picker == weakP) me->_picker = nil;
    };
    [p showInWindow:_win];
}

- (void)switchWorkspace:(id)s {
    QuickPicker *p = [QuickPicker new];
    p.placeholder = FTL(@"Switch Workspace");
    NSArray *roots = self.recentRoots;
    __weak QuickPicker *weakP = p;
    p.onQuery = ^(NSString *q) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSNumber *i in FWRank(q, roots, 50)) {
            NSString *r = roots[i.unsignedIntegerValue];
            [items addObject:[PickerItem title:r.lastPathComponent subtitle:[r.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath] payload:r]];
        }
        [items addObject:[PickerItem title:FTL(@"Open Another Folder…") subtitle:@"⌘O" payload:NSNull.null]];
        [weakP setItems:items];
    };
    p.onPick = ^(PickerItem *it) {
        if (it.payload == NSNull.null) [self openFolder:nil];
        else [self switchToRoot:it.payload];
    };
    p.onDelete = ^BOOL(PickerItem *it) {                                  // ⌘⌫ removes it from the list
        if (![it.payload isKindOfClass:NSString.class] || [it.payload isEqualToString:self->_tree.rootPath]) return NO;
        [self removeRecentRoot:it.payload];
        return YES;
    };
    p.footnote = FTL(@"⌘⌫ removes from the list");
    [self presentPicker:p cleanup:nil];
}

- (void)quickOpen:(id)s {
    if (!_tree.rootPath) return;
    QuickPicker *p = [QuickPicker new];
    p.placeholder = [NSString stringWithFormat:FTL(@"Find files by name in %@"), _tree.rootPath.lastPathComponent];
    FileList *list = [[FileList alloc] initWithRoot:_tree.rootPath includeHidden:_tree.showHidden];   // follows 显示隐藏文件
    PickerGeneration *gen = [PickerGeneration new];
    __weak QuickPicker *weakP = p;
    NSString *root = _tree.rootPath;

    void (^refilter)(void) = ^{
        QuickPicker *picker = weakP;
        if (!picker) return;
        NSString *q = picker.query;
        NSUInteger g = ++gen.value;
        NSArray<NSString *> *paths = list.snapshot;
        BOOL done = list.done;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSNumber *> *idx;
            if (q.length) idx = FWRank(q, paths, 200);
            else {
                NSMutableArray *a = [NSMutableArray array];
                for (NSUInteger i = 0; i < MIN(paths.count, (NSUInteger)200); i++) [a addObject:@(i)];
                idx = a;
            }
            if (gen.value != g) return;
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:idx.count];
            for (NSNumber *n in idx) {
                NSString *rel = paths[n.unsignedIntegerValue];
                NSString *dir = rel.stringByDeletingLastPathComponent;
                [items addObject:[PickerItem title:rel.lastPathComponent subtitle:dir payload:rel]];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen.value != g) return;
                [weakP setItems:items];
                [weakP setStatus:[NSString stringWithFormat:FTLP(paths.count, @"%@%lu file", @"%@%lu files"), done ? @"" : FTL(@"Scanning… "), (unsigned long)paths.count]];
            });
        });
    };
    p.onQuery = ^(NSString *q) { refilter(); };
    p.onPick = ^(PickerItem *it) { [self openFile:[root stringByAppendingPathComponent:it.payload]]; };
    [self presentPicker:p cleanup:^{ [list cancel]; }];
    [list startWithProgress:^(BOOL done) { refilter(); }];
}

#pragma mark File operations

- (void)showError:(NSString *)msg title:(NSString *)title {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = msg;
    if (_win.attachedSheet) [a runModal];
    else [a beginSheetModalForWindow:_win completionHandler:nil];
}

// Sheet with a text field; the base name (before the extension) is preselected.
- (void)promptName:(NSString *)title initial:(NSString *)initial button:(NSString *)button
              done:(void (^)(NSString *name))done {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    [a addButtonWithTitle:button];
    [a addButtonWithTitle:FTL(@"Cancel")];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    tf.stringValue = initial;
    a.accessoryView = tf;
    a.window.initialFirstResponder = tf;
    [a beginSheetModalForWindow:_win completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *err = FOValidateName(name);
        if (err) { dispatch_async(dispatch_get_main_queue(), ^{ [self showError:err title:FTL(@"Invalid name")]; }); return; }
        done(name);
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSText *ed = tf.currentEditor;
        NSString *ext = initial.pathExtension;
        NSUInteger len = ext.length && initial.length > ext.length + 1 ? initial.length - ext.length - 1 : initial.length;
        ed.selectedRange = NSMakeRange(0, len);
    });
}

// Directory that new items go into: the target itself if it is a folder, else its parent.
- (NSString *)directoryForNewItem:(id)sender {
    NSString *t = [self targetPathFrom:sender] ?: _tree.rootPath;
    if (!FOPathIsWithin(t, _tree.rootPath)) t = _tree.rootPath;
    BOOL dir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:t isDirectory:&dir];
    return dir ? t : t.stringByDeletingLastPathComponent;
}

- (void)createItem:(id)sender directory:(BOOL)isDir {
    NSString *dir = [self directoryForNewItem:sender];
    if (!dir) return;
    NSString *title = [NSString stringWithFormat:FTL(@"New %2$@ in “%1$@”"), dir.lastPathComponent, isDir ? FTL(@"Folder") : FTL(@"File")];
    [self promptName:title initial:isDir ? FTL(@"New Folder") : FTL(@"Untitled.txt") button:FTL(@"Create") done:^(NSString *name) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSString *err = FOCreate(p, isDir);
        if (err) { [self showError:err title:FTL(@"Couldn’t Create")]; return; }
        [self->_tree reloadAndReveal:p];
        [self->_search fileSystemChanged];
        if (!isDir) [self->_content openPath:p preview:NO focus:YES layout:MarkupSource];   // new .md starts in the editor
    }];
}

- (void)newFile:(id)s { [self createItem:s directory:NO]; }
- (void)newFolder:(id)s { [self createItem:s directory:YES]; }

- (void)renameItem:(id)sender {
    NSString *from = [self targetPathFrom:sender];
    if (!from || [from isEqualToString:_tree.rootPath]) return;
    [self promptName:FTL(@"Rename") initial:from.lastPathComponent button:FTL(@"Rename") done:^(NSString *name) {
        NSString *to = [from.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
        NSString *err = FORename(from, to);
        if (err) { [self showError:err title:FTL(@"Couldn’t Rename")]; return; }
        [self->_content pathMoved:from to:to];
        [self->_search fileSystemChanged];
        [self->_tree reloadAndReveal:to];
        [self updateTitle];
    }];
}

// Without the workspace root and without items inside another selected folder (the folder takes them along).
- (NSArray<NSString *> *)trashablePaths:(NSArray<NSString *> *)paths {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in paths) {
        if ([p isEqualToString:_tree.rootPath] || [out containsObject:p]) continue;
        BOOL covered = NO;
        for (NSString *q in paths) if (![q isEqualToString:p] && ![q isEqualToString:_tree.rootPath] && FOPathIsWithin(p, q)) { covered = YES; break; }
        if (!covered) [out addObject:p];
    }
    return out;
}

- (void)trashItem:(id)sender {
    NSArray<NSString *> *paths = [self trashablePaths:[self targetPathsFrom:sender]];
    if (!paths.count) return;
    for (NSString *p in paths) if (![_content closePathsWithin:p]) return;    // asks about unsaved tabs; cancel = nothing trashed
    NSMutableArray *errors = [NSMutableArray array];
    for (NSString *p in paths) {
        NSString *err = _trashHandler ? _trashHandler(p) : FOTrash(p);
        if (err) [errors addObject:paths.count > 1 ? [NSString stringWithFormat:FTL(@"%@: %@"), p.lastPathComponent, err] : err];
    }
    [_tree reloadAndReveal:_content.currentPath ?: paths.firstObject.stringByDeletingLastPathComponent];
    [_search fileSystemChanged];
    [self updateTitle];
    if (errors.count) [self showError:[errors componentsJoinedByString:@"\n"] title:FTL(@"Couldn’t Move to Trash")];
}

@end

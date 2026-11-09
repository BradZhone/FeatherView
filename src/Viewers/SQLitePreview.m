#import "BinaryPreviews.h"
#import "Localization.h"
#import "TablePreview.h"
#import "TableModel.h"
#import "CanvasView.h"
#import "DataPreviews.h"
#include <sqlite3.h>
#include <stdatomic.h>

static const NSUInteger kMaxRows = 5000;
static const unsigned long long kMaxCopyBytes = 256ull << 20;

@implementation SQLitePreview {
    sqlite3 *_db;
    dispatch_queue_t _q;
    NSArray<NSDictionary *> *_items;              // name, type, sql, count
    NSMutableDictionary<NSString *, NSString *> *_counts;
    NSTableView *_list;
    NSSegmentedControl *_mode;
    NSTextField *_sql;
    NSScrollView *_schemaScroll;
    NSTextView *_schema;
    TablePreview *_grid;
    NSString *_current;
    unsigned long long _bytes;
    NSString *_copyDir, *_note;                   // a WAL database opened from a temporary copy
    _Atomic(NSUInteger) _queryGen;
}

// Nothing may write a file: not even VACUUM INTO or ATTACH, which a read-only connection still allows.
static int authorize(void *ctx, int action, const char *a, const char *b, const char *db, const char *trigger) {
    switch (action) {
        case SQLITE_SELECT: case SQLITE_READ: case SQLITE_FUNCTION: case SQLITE_RECURSIVE: return SQLITE_OK;
        case SQLITE_PRAGMA: return SQLITE_OK;    // reads only: the connection itself is read-only
        default: return SQLITE_DENY;
    }
}

static BOOL readable(sqlite3 *db) {
    sqlite3_stmt *st = NULL;
    BOOL ok = sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW;
    sqlite3_finalize(st);
    return ok;
}

// A WAL database needs its -shm file, which can't be created in a read-only folder; immutable=1 would
// skip the -wal and hide recent changes. So such a database is read from a temporary copy.
static sqlite3 *openReadOnly(NSString *path, NSString **copyDir, NSString **note) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && readable(db)) return db;
    sqlite3_close(db); db = NULL;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *wal = [path stringByAppendingString:@"-wal"];
    unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize] + [[fm attributesOfItemAtPath:wal error:nil] fileSize];
    if ([fm fileExistsAtPath:wal] && size <= kMaxCopyBytes) {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"feather-sqlite-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *copy = [dir stringByAppendingPathComponent:path.lastPathComponent];
        if ([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil] &&
            [fm copyItemAtPath:path toPath:copy error:nil] && [fm copyItemAtPath:wal toPath:[copy stringByAppendingString:@"-wal"] error:nil] &&
            sqlite3_open_v2(copy.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && readable(db)) {
            *copyDir = dir;
            *note = FTL(@"read from a copy: the folder is read-only");
            return db;
        }
        sqlite3_close(db); db = NULL;
        [fm removeItemAtPath:dir error:nil];
    }
    NSString *uri = [@"file:" stringByAppendingString:[[NSURL fileURLWithPath:path].path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
    uri = [uri stringByAppendingString:@"?immutable=1"];
    if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) == SQLITE_OK && readable(db)) {
        if ([fm fileExistsAtPath:wal]) *note = FTL(@"the most recent changes may be missing (the folder is read-only)");
        return db;
    }
    sqlite3_close(db);
    return NULL;
}

static NSString *quoted(NSString *ident) { return [NSString stringWithFormat:@"\"%@\"", [ident stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]]; }

static NSString *cellString(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
        case SQLITE_NULL: return @"NULL";
        case SQLITE_BLOB: return [NSString stringWithFormat:FTLP((NSUInteger)sqlite3_column_bytes(st, i), @"<BLOB %d byte>", @"<BLOB %d bytes>"), sqlite3_column_bytes(st, i)];
        default: {
            const unsigned char *t = sqlite3_column_text(st, i);
            return t ? ([NSString stringWithUTF8String:(const char *)t] ?: @"?") : @"";
        }
    }
}

- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path {
    NSString *copyDir = nil, *note = nil;
    sqlite3 *db = openReadOnly(path, &copyDir, &note);
    if (!db) return nil;
    sqlite3_busy_timeout(db, 200);
    sqlite3_set_authorizer(db, authorize, NULL);
    sqlite3_stmt *st = NULL;
    const char *q = "SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name";
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        if (copyDir) [NSFileManager.defaultManager removeItemAtPath:copyDir error:nil];
        return nil;
    }
    NSMutableArray *items = [NSMutableArray array];
    while (sqlite3_step(st) == SQLITE_ROW) [items addObject:@{@"name": cellString(st, 0), @"type": cellString(st, 1), @"sql": cellString(st, 2)}];
    sqlite3_finalize(st);
    if (!(self = [super initWithFrame:frame])) { sqlite3_close(db); return nil; }
    FTClipToBounds(self);
    _db = db; _items = items; _counts = [NSMutableDictionary dictionary];
    _copyDir = copyDir; _note = note;
    _q = dispatch_queue_create("feather.sqlite", DISPATCH_QUEUE_SERIAL);
    _bytes = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
    [self buildViews];
    [self countRows];
    if (items.count) { [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [self showTable:items[0][@"name"]]; }
    return self;
}

- (void)dealloc {
    sqlite3 *db = _db;
    NSString *dir = _copyDir;
    sqlite3_interrupt(db);
    dispatch_async(_q, ^{ sqlite3_close_v2(db); if (dir) [NSFileManager.defaultManager removeItemAtPath:dir error:nil]; });
}
- (BOOL)isFlipped { return YES; }
- (TablePreview *)grid { return _grid; }
- (NSArray<NSString *> *)tableNames { return [_items valueForKey:@"name"]; }
- (NSString *)status {
    NSUInteger views = 0;
    for (NSDictionary *i in _items) if ([i[@"type"] isEqual:@"view"]) views++;
    NSString *s = [NSString stringWithFormat:FTLP(_items.count - views, @"SQLite database (read-only)   %lu table%@   %@", @"SQLite database (read-only)   %lu tables%@   %@"), (unsigned long)(_items.count - views),
            views ? [NSString stringWithFormat:FTLP(views, @" · %lu view", @" · %lu views"), (unsigned long)views] : @"", [NSByteCountFormatter stringFromByteCount:(long long)_bytes countStyle:NSByteCountFormatterCountStyleFile]];
    return _note ? [NSString stringWithFormat:@"%@   (%@)", s, _note] : s;
}

// Table sizes, counted in the background (capped so a huge table doesn't stall).
- (void)countRows {
    NSArray *names = self.tableNames;
    sqlite3 *db = _db;
    __weak SQLitePreview *weakSelf = self;
    dispatch_async(_q, ^{
        for (NSString *n in names) {
            NSString *q = [NSString stringWithFormat:@"SELECT count(*) FROM (SELECT 1 FROM %@ LIMIT 1000001)", quoted(n)];
            sqlite3_stmt *st = NULL;
            NSString *c = @"?";
            if (sqlite3_prepare_v2(db, q.UTF8String, -1, &st, NULL) == SQLITE_OK && sqlite3_step(st) == SQLITE_ROW) {
                long long k = sqlite3_column_int64(st, 0);
                c = k > 1000000 ? FTL(@"1M+") : FTGrouped((NSUInteger)k);
            }
            sqlite3_finalize(st);
            dispatch_async(dispatch_get_main_queue(), ^{ SQLitePreview *me = weakSelf; if (me) { me->_counts[n] = c; [me->_list reloadData]; } });
        }
    });
}

static int progress(void *ctx) {
    void **p = ctx;
    return atomic_load((_Atomic(NSUInteger) *)p[0]) != (NSUInteger)(uintptr_t)p[1];      // a newer query: stop this one
}

// A new query stops the one still running (a slow view or a runaway recursive query), so it never queues behind it.
- (void)runSQL:(NSString *)sql label:(NSString *)label {
    sqlite3 *db = _db;
    __weak SQLitePreview *weakSelf = self;
    _grid.extraInfo = FTL(@"Querying…");
    NSUInteger gen = atomic_fetch_add(&_queryGen, 1) + 1;
    _Atomic(NSUInteger) *genp = &_queryGen;
    dispatch_async(_q, ^{
        if (atomic_load(genp) != gen) return;
        void *ctx[2] = {(void *)genp, (void *)(uintptr_t)gen};
        sqlite3_progress_handler(db, 2000, progress, ctx);
        sqlite3_stmt *st = NULL;
        NSMutableArray *rows = [NSMutableArray array], *headers = [NSMutableArray array];
        NSString *err = nil;
        BOOL more = NO;
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) err = @(sqlite3_errmsg(db));
        else if (!sqlite3_stmt_readonly(st)) err = FTL(@"This database is opened read-only; only queries that read are run");
        else {
            int n = sqlite3_column_count(st);
            for (int i = 0; i < n; i++) [headers addObject:@(sqlite3_column_name(st, i) ?: "?")];
            int rc;
            while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
                if (rows.count == kMaxRows) { more = YES; break; }
                NSMutableArray *r = [NSMutableArray arrayWithCapacity:n];
                for (int i = 0; i < n; i++) [r addObject:cellString(st, i)];
                [rows addObject:r];
            }
            if (rc != SQLITE_ROW && rc != SQLITE_DONE) err = @(sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
        sqlite3_progress_handler(db, 0, NULL, NULL);
        if (atomic_load(genp) != gen) return;                  // superseded: its result isn't shown
        dispatch_async(dispatch_get_main_queue(), ^{
            SQLitePreview *me = weakSelf;
            if (!me || atomic_load(&me->_queryGen) != gen) return;
            [me->_grid setModel:[ArrayTable tableWithHeaders:headers rows:rows truncated:more]];
            me->_grid.extraInfo = err ? [@"⚠️ " stringByAppendingString:err] : more ? [NSString stringWithFormat:FTL(@"%@ · first %lu rows shown"), label, (unsigned long)kMaxRows] : label;
            if (me.onChange) me.onChange();
        });
    });
}

- (void)showTable:(NSString *)name {
    _current = name;
    for (NSDictionary *i in _items) if ([i[@"name"] isEqual:name]) _schema.string = i[@"sql"] ?: @"";
    [self runSQL:[NSString stringWithFormat:@"SELECT * FROM %@", quoted(name)] label:name];
}
- (void)runQuery:(NSString *)sql { if (sql.length) { _mode.selectedSegment = 0; [self modeChanged:nil]; [self runSQL:sql label:FTL(@"Query Result")]; } }

#pragma mark Views

- (void)buildViews {
    _list = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"t"];
    c.title = FTL(@"Tables");
    [_list addTableColumn:c];
    _list.headerView = nil;
    _list.style = NSTableViewStyleSourceList;
    _list.rowHeight = 22;
    _list.dataSource = self; _list.delegate = self;
    NSScrollView *ls = [NSScrollView new];
    ls.documentView = _list;
    ls.hasVerticalScroller = YES; ls.autohidesScrollers = YES; ls.drawsBackground = NO;
    ls.translatesAutoresizingMaskIntoConstraints = NO;

    _mode = [NSSegmentedControl segmentedControlWithLabels:@[FTL(@"Data"), FTL(@"Schema")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    _mode.selectedSegment = 0;
    _mode.controlSize = NSControlSizeSmall;
    _mode.translatesAutoresizingMaskIntoConstraints = NO;
    _sql = [NSTextField textFieldWithString:@""];
    _sql.placeholderString = FTL(@"SELECT … (read-only, Return to run)");
    _sql.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    _sql.controlSize = NSControlSizeSmall;
    _sql.target = self; _sql.action = @selector(sqlEntered:);
    _sql.translatesAutoresizingMaskIntoConstraints = NO;
    _grid = [[TablePreview alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    _schema = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _schema.editable = NO;
    _schema.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular];
    _schema.textContainerInset = NSMakeSize(12, 12);
    _schema.autoresizingMask = NSViewWidthSizable;
    _schemaScroll = [NSScrollView new];
    _schemaScroll.documentView = _schema;
    _schemaScroll.hasVerticalScroller = YES;
    _schemaScroll.hidden = YES;
    _schemaScroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *v = [NSBox new], *h = [NSBox new];
    v.boxType = h.boxType = NSBoxSeparator;
    v.translatesAutoresizingMaskIntoConstraints = h.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *x in @[ls, v, _mode, _sql, h, _grid, _schemaScroll]) [self addSubview:x];
    [NSLayoutConstraint activateConstraints:@[
        [ls.topAnchor constraintEqualToAnchor:self.topAnchor], [ls.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [ls.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [ls.widthAnchor constraintEqualToConstant:190],
        [v.topAnchor constraintEqualToAnchor:self.topAnchor], [v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [v.leadingAnchor constraintEqualToAnchor:ls.trailingAnchor], [v.widthAnchor constraintEqualToConstant:1],
        [_mode.leadingAnchor constraintEqualToAnchor:v.trailingAnchor constant:8], [_mode.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [_sql.leadingAnchor constraintEqualToAnchor:_mode.trailingAnchor constant:8], [_sql.centerYAnchor constraintEqualToAnchor:_mode.centerYAnchor],
        [_sql.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [h.topAnchor constraintEqualToAnchor:_mode.bottomAnchor constant:6], [h.leadingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [h.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_grid.topAnchor constraintEqualToAnchor:h.bottomAnchor], [_grid.leadingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_grid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor], [_grid.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_schemaScroll.topAnchor constraintEqualToAnchor:h.bottomAnchor], [_schemaScroll.leadingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_schemaScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor], [_schemaScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
}

- (void)modeChanged:(id)s { BOOL schema = _mode.selectedSegment == 1; _schemaScroll.hidden = !schema; _grid.hidden = schema; }
- (void)sqlEntered:(NSTextField *)f { [self runQuery:[f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)_items.count; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)row {
    NSDictionary *i = _items[(NSUInteger)row];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:i[@"name"] attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12.5]}];
    NSString *extra = [i[@"type"] isEqual:@"view"] ? FTL(@"  view") : (_counts[i[@"name"]] ? [@"  " stringByAppendingString:_counts[i[@"name"]]] : @"");
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:extra attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}]];
    return s;
}
- (BOOL)tableView:(NSTableView *)t shouldEditTableColumn:(NSTableColumn *)c row:(NSInteger)r { return NO; }
- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger r = _list.selectedRow;
    if (r >= 0 && ![_items[(NSUInteger)r][@"name"] isEqual:_current]) [self showTable:_items[(NSUInteger)r][@"name"]];
}

@end

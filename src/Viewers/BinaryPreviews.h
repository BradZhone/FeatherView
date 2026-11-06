#import <Cocoa/Cocoa.h>
@class TablePreview;

// SQLite database, read-only: tables and views with row counts, the first rows of the chosen one, its
// CREATE statement, and a box for running your own SELECT. The file is opened read-only, so nothing can change it.
@interface SQLitePreview : NSView <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path;   // nil if it can't be opened
@property (nonatomic, readonly) NSArray<NSString *> *tableNames;
@property (nonatomic, readonly) TablePreview *grid;
- (void)showTable:(NSString *)name;
- (void)runQuery:(NSString *)sql;
@property (nonatomic, readonly) NSString *status;          // "3 张表 · 12 KB" for the status bar
@property (nonatomic, copy) void (^onChange)(void);
@end

// Archive contents (zip, jar, tar, tgz, 7z, …) listed with bsdtar; double-click extracts that entry to a
// temporary folder and opens it.
@interface ArchivePreview : NSView
- (instancetype)initWithFrame:(NSRect)frame path:(NSString *)path;
@property (nonatomic, readonly) TablePreview *grid;
@property (nonatomic, readonly) NSUInteger entryCount;
@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, copy) void (^onOpenFile)(NSString *path);
@property (nonatomic, copy) void (^onChange)(void);
@property (nonatomic, readonly) NSString *status;
@end

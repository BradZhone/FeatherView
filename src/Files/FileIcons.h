#import <Cocoa/Cocoa.h>

// SF Symbol and tint for a file, by name. Shared by the file tree and search results.
NSString *FTFileSymbol(NSString *name, BOOL isDir);
NSColor *FTFileTint(NSString *name, BOOL isDir);
NSImage *FTFileIcon(NSString *name, BOOL isDir);

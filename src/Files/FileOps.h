#import <Foundation/Foundation.h>

// Returns an error message if `name` is not a usable single path component, else nil.
NSString *FOValidateName(NSString *name);

// Creates an empty file or a directory. Fails if it already exists. Returns error message or nil.
NSString *FOCreate(NSString *path, BOOL directory);

// Renames within the same directory; never overwrites. Case-only renames are allowed.
NSString *FORename(NSString *from, NSString *to);

// Moves to the Trash (recoverable).
NSString *FOTrash(NSString *path);

// YES if `path` is `base` or lies inside it.
BOOL FOPathIsWithin(NSString *path, NSString *base);

// Replaces a file's contents without risking the original: a temporary file in the same folder gets the
// data, the original's permissions, extended attributes and ACLs, then is renamed over it. A file with other
// hard links, or in a folder that can't take new files, is written in place. Read-only files are refused.
// The caller must not have the file memory-mapped. Returns an error message or nil.
NSString *FOWriteFile(NSString *path, NSData *data);

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

#import "FileOps.h"
#import "Localization.h"
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *errnoMessage(int e) {
    switch (e) {
        case EEXIST: return FTL(@"An item with that name already exists");
        case EACCES: case EPERM: return FTL(@"Permission denied");
        case ENOENT: return FTL(@"The file doesn’t exist");
        case EROFS: return FTL(@"The disk is read-only");
        case ENOSPC: return FTL(@"Not enough disk space");
        default: return @(strerror(e));
    }
}

NSString *FOValidateName(NSString *name) {
    NSString *t = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return FTL(@"The name can’t be empty");
    if ([t isEqualToString:@"."] || [t isEqualToString:@".."]) return FTL(@"Invalid name");
    if ([t rangeOfString:@"/"].location != NSNotFound || [t rangeOfString:@":"].location != NSNotFound)
        return FTL(@"The name can’t contain / or :");
    if ([t rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound)
        return FTL(@"Invalid name");
    if ([t lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255) return FTL(@"The name is too long");
    return nil;
}

NSString *FOCreate(NSString *path, BOOL directory) {
    const char *p = path.fileSystemRepresentation;
    if (directory) return mkdir(p, 0755) == 0 ? nil : errnoMessage(errno);
    int fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) return errnoMessage(errno);
    close(fd);
    return nil;
}

NSString *FORename(NSString *from, NSString *to) {
    if ([from isEqualToString:to]) return nil;
    const char *a = from.fileSystemRepresentation, *b = to.fileSystemRepresentation;
    struct stat sa, sb;
    if (lstat(a, &sa) != 0) return errnoMessage(errno);
    if (lstat(b, &sb) == 0) {
        // On case-insensitive volumes "a.txt" -> "A.txt" resolves to the same inode: allowed.
        if (sa.st_dev != sb.st_dev || sa.st_ino != sb.st_ino) return errnoMessage(EEXIST);
        return rename(a, b) == 0 ? nil : errnoMessage(errno);
    }
    return renamex_np(a, b, RENAME_EXCL) == 0 ? nil : errnoMessage(errno);
}

NSString *FOTrash(NSString *path) {
    NSError *e = nil;
    if ([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:nil error:&e]) return nil;
    return e.localizedDescription ?: FTL(@"Couldn’t Move to Trash");
}

BOOL FOPathIsWithin(NSString *path, NSString *base) {
    if (!path || !base) return NO;
    if ([path isEqualToString:base]) return YES;
    NSString *b = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
    return [path hasPrefix:b];
}

#import <Cocoa/Cocoa.h>
#import "Markdown.h"

// Markdown AST → attributed string for a read-only TextKit 1 NSTextView (text blocks/tables need TextKit 1).
// The image cache survives re-renders; remote https images load in the background.
@interface MarkdownRenderer : NSObject
@property (nonatomic, copy) NSString *baseDir;            // resolves relative image paths
@property (nonatomic) CGFloat maxImageWidth;
@property (nonatomic, copy) void (^onImageLoaded)(void);  // a remote image arrived; caller re-renders
- (NSAttributedString *)render:(MDDocument *)doc;
@property (class, nonatomic) BOOL loadsRemoteImages;     // default YES; off: https images show their alt text
// From the last render: block start positions (source line → character index), heading anchors.
@property (nonatomic, readonly) NSArray<NSNumber *> *mapLines, *mapLocs;
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *anchors;
@end

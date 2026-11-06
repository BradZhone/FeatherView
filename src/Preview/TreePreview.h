#import <Cocoa/Cocoa.h>
#import "DataPreviews.h"
@class JSONNode;

// Collapsible JSON / property-list tree: name, type and size, coloured values, a filter that keeps the
// matching nodes and their parents, copy value / path ($.a.b[0]) / subtree as JSON. A file that stops
// parsing while being edited keeps showing the last good tree with the error above it.
@interface TreePreview : NSView <FTDataPreview, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate>
- (void)setRoot:(JSONNode *)root;                  // binary plists: no source text
@property (nonatomic, readonly) JSONNode *root;
@property (nonatomic, readonly) NSOutlineView *outlineView;
@property (nonatomic, readonly) NSString *errorText, *infoText;
@property (nonatomic, copy) NSString *filterText;
- (void)expandToDepth:(NSUInteger)depth;
@end

#import "TreePreview.h"
#import "JSONTree.h"

@interface TreePreview () {
@public
    NSSearchField *_filter;
    NSTextField *_info, *_error;
    NSButton *_expandAll, *_collapseAll;
    NSLayoutConstraint *_errorHeight;
    NSOutlineView *_ov;
    JSONNode *_root;
    NSUInteger _nodeCount, _parseGen, _filterGen;
    NSHashTable<JSONNode *> *_visible;         // filter on: nodes shown (matches, their parents and subtrees)
    NSString *_path;
    NSTimer *_filterTimer;
}
- (NSArray<JSONNode *> *)childrenOf:(JSONNode *)n;
- (void)installRoot:(JSONNode *)root keepExpansion:(BOOL)keep;
@end

@interface TreePreview (Filter)                 // filter, menu, copy
- (void)applyFilter;
- (void)updateInfo;
- (void)doubleClicked:(id)sender;
@end

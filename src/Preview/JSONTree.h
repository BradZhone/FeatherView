#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, JSONKind) { JSONObject, JSONArray, JSONString, JSONNumber, JSONBool, JSONNull, JSONData, JSONDate };

// One value of a JSON (or property list) document. Keys keep their order in the file.
@interface JSONNode : NSObject
@property (nonatomic, copy) NSString *key;                  // object member name; nil for array elements and the root
@property (nonatomic) NSUInteger index;                     // position in the parent
@property (nonatomic) JSONKind kind;
@property (nonatomic, copy) NSString *text;                 // scalar value as text (strings unescaped); nil for containers
@property (nonatomic, strong) NSArray<JSONNode *> *children;
@property (nonatomic, weak) JSONNode *parent;
@property (nonatomic) NSUInteger line;                      // 1-based line where the value starts (0 for plists)
@property (nonatomic, readonly) NSString *path;             // $.dependencies["@types/node"][0]
- (NSString *)JSONStringPretty:(BOOL)pretty;                // the subtree as JSON
- (NSString *)displayKey;                                   // name, [index], or "根"
@end

// Lenient on purpose: // and /* */ comments, trailing commas, 'single quotes' and unquoted keys are accepted
// (tsconfig, .jsonc, JSON5-ish files). On failure returns nil and *error is "第 3 行第 14 列：缺少 }".
JSONNode *JSONParse(NSData *utf8, NSString **error);
JSONNode *JSONFromPropertyList(id plist);                   // NSDictionary / NSArray / … from NSPropertyListSerialization
NSUInteger JSONNodeCount(JSONNode *root, NSUInteger limit); // stops counting at limit

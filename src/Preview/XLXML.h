#import <Foundation/Foundation.h>

// A forward-only scanner over the bytes of an XML part, reporting tags with their byte ranges, so that a
// worksheet can later be changed by splicing exactly those ranges. Not a validating parser: comments,
// processing instructions, CDATA and DOCTYPE are skipped; names are compared without namespace prefix.
typedef struct {
    NSUInteger start, end;         // '<' … just after '>'
    NSUInteger nameStart, nameLen; // qualified name
    NSUInteger localStart;         // local name (after the prefix)
    NSUInteger attrStart, attrEnd; // between the name and '>' / '/>'
    BOOL closing, selfClosing;
} XLTag;

BOOL XLNextTag(const uint8_t *x, NSUInteger n, NSUInteger from, XLTag *t);
BOOL XLTagIs(const uint8_t *x, const XLTag *t, const char *local);
NSString *XLAttr(const uint8_t *x, const XLTag *t, const char *name);                  // decoded value or nil
BOOL XLAttrRange(const uint8_t *x, const XLTag *t, const char *name, NSRange *value);   // raw value bytes
NSString *XLAttrLocal(const uint8_t *x, const XLTag *t, const char *local);   // any prefix: r:id, x:id …
NSString *XLPrefix(const uint8_t *x, const XLTag *t);                                  // "x:" or ""
NSString *XLDecode(const uint8_t *p, NSUInteger n);                                    // entities
NSString *XLDecodeOOXML(NSString *s);                                                  // _xHHHH_ escapes
NSString *XLEscape(NSString *s);                                                       // for text and attribute values
// "AB12" → column 27, row 11 (0-based). NO for anything else.
BOOL XLParseRef(const uint8_t *p, NSUInteger n, NSUInteger *row, NSUInteger *col);
BOOL XLParseRefString(NSString *s, NSUInteger *row, NSUInteger *col);
NSString *XLColumnName(NSUInteger col);
NSString *XLCellName(NSUInteger row, NSUInteger col);

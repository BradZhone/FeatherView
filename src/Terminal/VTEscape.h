#import <Foundation/Foundation.h>

@protocol TTEndpoint;

// Escape-sequence parser: a byte stream in, endpoint calls out. Handles C0 controls, ESC, CSI (with
// private markers and parameters), OSC and DCS/SOS/PM/APC strings, and decodes UTF-8 across feed
// boundaries. Unknown sequences are consumed and ignored, so a stray stream can never wedge it.
@interface VTEscape : NSObject

- (instancetype)initWithEndpoint:(id<TTEndpoint>)endpoint;
- (void)feed:(const uint8_t *)bytes length:(NSUInteger)length;

@end

// Characters that occupy two cells (CJK, full-width forms, common emoji).
BOOL TWideChar(uint32_t ch);

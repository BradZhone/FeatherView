#import "VTEscape.h"
#import "TScreen.h"

static const NSUInteger kMaxParams = 32, kMaxOsc = 4096;

typedef enum { StGround, StEsc, StEscInter, StCsi, StOsc, StOscEsc, StStr, StStrEsc, StCharset } VTState;

BOOL TWideChar(uint32_t ch) {
    return (ch >= 0x1100 && ch <= 0x115F) || (ch >= 0x2E80 && ch <= 0x303E) || (ch >= 0x3041 && ch <= 0x33FF) ||
           (ch >= 0x3400 && ch <= 0x4DBF) || (ch >= 0x4E00 && ch <= 0x9FFF) || (ch >= 0xA000 && ch <= 0xA4CF) ||
           (ch >= 0xAC00 && ch <= 0xD7A3) || (ch >= 0xF900 && ch <= 0xFAFF) || (ch >= 0xFE10 && ch <= 0xFE19) ||
           (ch >= 0xFE30 && ch <= 0xFE6B) || (ch >= 0xFF00 && ch <= 0xFF60) || (ch >= 0xFFE0 && ch <= 0xFFE6) ||
           (ch >= 0x1F300 && ch <= 0x1F9FF) || (ch >= 0x20000 && ch <= 0x3FFFD);
}

@implementation VTEscape {
    id<TTEndpoint> _ep;
    VTState _state;
    NSInteger _params[kMaxParams];
    NSUInteger _nparams, _param;
    BOOL _digits;
    uint8_t _private;
    uint32_t _u32;                     // UTF-8 accumulator
    NSUInteger _uLeft;
    NSMutableData *_osc;
    NSUInteger _oscN;                  // the OSC number, parsed from the head
    BOOL _oscHeadDone;
    BOOL _putAnything;                 // REP (CSI b) repeats the last printed character
}

- (instancetype)initWithEndpoint:(id<TTEndpoint>)endpoint {
    if (!(self = [super init])) return nil;
    _ep = endpoint;
    return self;
}

- (void)feed:(const uint8_t *)b length:(NSUInteger)n {
    for (NSUInteger i = 0; i < n; i++) [self step:b[i]];
}

- (void)step:(uint8_t)b {
    switch (_state) {
        case StGround: [self ground:b]; return;
        case StEsc: [self esc:b]; return;
        case StEscInter: if (b < 0x20 || b >= 0x30) _state = StGround; return;   // charset /DEC lines: consume
        case StCsi: [self csi:b]; return;
        case StOsc: [self osc:b]; return;
        case StOscEsc: [self oscEsc:b]; return;
        case StStr: if (b == 0x1B) _state = StStrEsc; return;                    // DCS, SOS, PM, APC: skipped
        case StStrEsc: if (b == '\\') _state = StGround; else _state = StStr; return;
        case StCharset: _state = StGround; return;
    }
}

#pragma mark Ground

- (void)ground:(uint8_t)b {
    if (b < 0x80) { _uLeft = 0; [self ascii:b]; return; }
    if (_uLeft) {
        if ((b & 0xC0) == 0x80) {
            _u32 = (_u32 << 6) | (b & 0x3F);
            if (--_uLeft) return;
            uint32_t ch = _u32 <= 0x10FFFF && !(_u32 >= 0xD800 && _u32 <= 0xDFFF) ? _u32 : 0xFFFD;
            [_ep putChar:ch wide:TWideChar(ch)];
            _putAnything = YES;
            return;
        }
        [_ep putChar:0xFFFD wide:NO];                          // broken sequence: replacement, then this byte
        _uLeft = 0;
    }
    NSUInteger need = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : 0;
    if (b >= 0xF8) { [_ep putChar:0xFFFD wide:NO]; return; }
    if (!_uLeft) { _u32 = b & (0xFF >> (need + 2)); _uLeft = need; }
}

- (void)ascii:(uint8_t)b {
    if (b >= 0x20 && b != 0x7F) {
        [_ep putChar:b wide:NO];
        _putAnything = YES;
        return;
    }
    switch (b) {
        case 0x07: [_ep bell]; return;
        case 0x08: [_ep backspace]; return;
        case 0x09: [_ep tab]; return;
        case 0x0A: case 0x0B: case 0x0C: [_ep lineFeed]; return;
        case 0x0D: [_ep carriageReturn]; return;
        case 0x1B: _state = StEsc; _nparams = _param = 0; _digits = NO; _private = 0; return;
        case 0x0E: case 0x0F: return;                          // SO / SI (charsets: ignored)
        default: return;                                       // NUL and friends
    }
}

#pragma mark ESC

- (void)esc:(uint8_t)b {
    _state = StGround;
    switch (b) {
        case '[': _state = StCsi; _nparams = _param = 0; _digits = NO; _private = 0; return;
        case ']': _state = StOsc; _osc = [NSMutableData data]; _oscN = 0; _oscHeadDone = NO; return;
        case 'P': case 'X': case '^': case '_': _state = StStr; return;
        case '(': case ')': case '*': case '+': case '#': case '%': _state = StEscInter; return;
        case '7': [_ep saveCursor]; return;
        case '8': [_ep restoreCursor]; return;
        case 'D': [_ep lineFeed]; return;
        case 'E': [_ep carriageReturn]; [_ep lineFeed]; return;
        case 'M': [_ep reverseLineFeed]; return;
        case 'H': [_ep setTabStop]; return;
        case 'c': [_ep reset]; return;
        default: return;                                       // = > \\ and the rest: no-op
    }
}

#pragma mark CSI

- (void)csi:(uint8_t)b {
    if (b >= '0' && b <= '9') { _digits = YES; _param = _param * 10 + (b - '0'); return; }
    if (b == ';' || b == ':') {
        if (_nparams < kMaxParams) _params[_nparams++] = (NSInteger)MIN(_param, (NSUInteger)99999);
        _param = 0;
        _digits = NO;
        return;
    }
    if (b >= 0x3C && b <= 0x3F) { _private = b; return; }      // ? < = >
    if (b >= 0x20 && b <= 0x2F) return;                        // intermediates: ignored
    if (b < 0x40) return;
    if (_digits || _nparams) {
        if (_nparams < kMaxParams) _params[_nparams++] = (NSInteger)MIN(_param, (NSUInteger)99999);
    }
    NSUInteger n = _nparams;
    NSInteger p[kMaxParams];
    memcpy(p, _params, n * sizeof(NSInteger));
    BOOL priv = _private == '?';
    _state = StGround;
    _nparams = _param = 0;
    _digits = NO;
    _private = 0;
    [self dispatch:b params:p count:n private:priv];
}

static NSUInteger arg(const NSInteger *p, NSUInteger n, NSUInteger i) {
    return i < n && p[i] > 0 ? (NSUInteger)p[i] : 1;           // 0 and missing both mean the default 1
}

- (void)dispatch:(uint8_t)f params:(const NSInteger *)p count:(NSUInteger)n private:(BOOL)priv {
    id<TTEndpoint> ep = _ep;
    if (f == 'm' && !priv) { [ep sgr:p count:n]; return; }
    if (priv) {
        if (f != 'h' && f != 'l') return;
        BOOL on = f == 'h';
        for (NSUInteger i = 0; i < n; i++) {
            switch (p[i]) {
                case 1: [ep setAppCursorKeys:on]; break;
                case 5: [ep setInverseScreen:on]; break;
                case 6: [ep setOriginMode:on]; break;
                case 7: [ep setAutoWrap:on]; break;
                case 25: [ep setCursorVisible:on]; break;
                case 47: on ? [ep enterAltScreen:NO] : [ep leaveAltScreen]; break;
                case 1047: on ? [ep enterAltScreen:YES] : [ep leaveAltScreen]; break;
                case 1049:
                    if (on) { [ep saveCursor]; [ep enterAltScreen:YES]; }
                    else { [ep leaveAltScreen]; [ep restoreCursor]; }
                    break;
                case 1000: [ep setMouseMode:on ? TMousePress : TMouseOff]; break;
                case 1002: [ep setMouseMode:on ? TMouseDrag : TMouseOff]; break;
                case 1003: [ep setMouseMode:on ? TMouseAny : TMouseOff]; break;
                case 1006: [ep setSGRMouse:on]; break;
                case 2004: [ep setBracketedPaste:on]; break;
                default: break;
            }
        }
        return;
    }
    switch (f) {
        case 'A': [ep cursorUp:arg(p, n, 0)]; break;
        case 'B': case 'e': [ep cursorDown:arg(p, n, 0)]; break;
        case 'C': case 'a': [ep cursorForward:arg(p, n, 0)]; break;
        case 'D': [ep cursorBack:arg(p, n, 0)]; break;
        case 'E': [ep cursorDown:arg(p, n, 0)]; [ep cursorToColumn:0]; break;
        case 'F': [ep cursorUp:arg(p, n, 0)]; [ep cursorToColumn:0]; break;
        case 'G': case '`': [ep cursorToColumn:n && p[0] > 0 ? (NSUInteger)p[0] - 1 : 0]; break;
        case 'H': case 'f': [ep cursorToRow:[self rowOf:p count:n] col:n > 1 && p[1] > 0 ? (NSUInteger)p[1] - 1 : 0 origin:YES]; break;
        case 'I': for (NSUInteger k = 0; k < arg(p, n, 0); k++) [ep tab]; break;
        case 'J': [ep eraseInDisplay:n && p[0] ? p[0] : 0]; break;
        case 'K': [ep eraseInLine:n && p[0] ? p[0] : 0]; break;
        case 'L': [ep insertLines:arg(p, n, 0)]; break;
        case 'M': [ep deleteLines:arg(p, n, 0)]; break;
        case 'P': [ep deleteChars:arg(p, n, 0)]; break;
        case 'S': [ep scrollUp:arg(p, n, 0)]; break;
        case 'T': [ep scrollDown:arg(p, n, 0)]; break;
        case 'X': [ep eraseChars:arg(p, n, 0)]; break;
        case 'Z': for (NSUInteger k = 0; k < arg(p, n, 0); k++) [ep backwardTab]; break;
        case '@': [ep insertChars:arg(p, n, 0)]; break;
        case 'b': [ep repeatLastChar:arg(p, n, 0)]; break;
        case 'd': [ep cursorToRow:n && p[0] > 0 ? (NSUInteger)p[0] - 1 : 0]; break;
        case 'h': case 'l': break;                              // non-private modes (IRM, LNM): ignored
        case 'r':
            [ep setScrollRegionTop:(n > 0 && p[0] > 0 ? (NSUInteger)p[0] - 1 : 0)
                            bottom:(n > 1 && p[1] > 0 ? (NSUInteger)p[1] - 1 : NSUIntegerMax)];
            break;
        case 's': [ep saveCursor]; break;
        case 'u': [ep restoreCursor]; break;
        default: break;                                        // n t c q and the rest: ignored
    }
}

- (NSUInteger)rowOf:(const NSInteger *)p count:(NSUInteger)n { return n > 0 && p[0] > 0 ? (NSUInteger)p[0] - 1 : 0; }

#pragma mark OSC

- (void)osc:(uint8_t)b {
    if (b == 0x07) { [self oscDone]; return; }
    if (b == 0x1B) { _state = StOscEsc; return; }
    if (_osc.length > kMaxOsc) { _state = StGround; return; }  // runaway string
    if (!_oscHeadDone) {
        if (b == ';') { _oscHeadDone = YES; return; }
        if (b >= '0' && b <= '9') _oscN = _oscN * 10 + (b - '0');
        return;
    }
    [_osc appendBytes:&b length:1];
}

- (void)oscEsc:(uint8_t)b {
    if (b == '\\') { _state = StGround; [self oscDone]; return; }
    _state = StOsc;                                            // abnormal: back to collecting
    const uint8_t esc = 0x1B; [_osc appendBytes:&esc length:1];
    [self osc:b];
}

- (void)oscDone {
    _state = StGround;
    if (_oscN == 0 || _oscN == 2) {
        NSString *t = [[NSString alloc] initWithData:_osc encoding:NSUTF8StringEncoding];
        if (t) [_ep setTitle:[t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    } else if (_oscN == 7) {
        NSString *u = [[NSString alloc] initWithData:_osc encoding:NSUTF8StringEncoding];
        if (u) [_ep setCwd:u];
    }
    _osc = nil;
}

@end

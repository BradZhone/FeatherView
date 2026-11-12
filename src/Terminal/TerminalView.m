#import "TerminalView.h"
#import "VTEscape.h"
#import "Localization.h"
#include <CoreText/CoreText.h>

static CGFloat gFontSize = 13;

// The first 16 palette entries follow the appearance; 16-255 are the standard xterm cube and greys.
static void themeColors(BOOL dark, uint32_t *out16, uint32_t *bg, uint32_t *fg) {
    if (dark) {
        uint32_t c[16] = {0x31363F, 0xE06C60, 0x7DBE50, 0xD9A94A, 0x6CA4E8, 0xC586C0, 0x56B6C2, 0x9DA5AE,
                          0x737A82, 0xF07178, 0x8CC265, 0xE5C07B, 0x82AAFF, 0xD55FDE, 0x69C3CE, 0xE6E6E6};
        memcpy(out16, c, sizeof c);
        *bg = 0x1B1E23;
        *fg = 0xD6DADF;
    } else {
        uint32_t c[16] = {0x495057, 0xC13B32, 0x338A22, 0x9A6A00, 0x2258A8, 0x8A3E9C, 0x1C7C74, 0x7A8087,
                          0x6B7178, 0xD9534F, 0x4E9A06, 0xB07D00, 0x3D6DD0, 0xA854B8, 0x22A094, 0xB9BEC4};
        memcpy(out16, c, sizeof c);
        *bg = 0xFFFFFF;
        *fg = 0x24292E;
    }
}

// A terminal view: draws its session's screen, sends keys and mouse events to the PTY. The session
// owns all state (screen, scrollback, process), so placement switches just build a new view.
@interface TerminalView () <NSTextInputClient> {
    TSession *_session;
    CGFloat _size;
    CTFontRef _font, _italicFont;
    CGFloat _ascent, _cellH, _cellW;
    BOOL _followBottom;
    NSUInteger _lastBell;
    CFTimeInterval _flashUntil;
    // selection: two cells of the scrollable text (history lines first, then screen rows)
    NSInteger _aLine, _aCol, _bLine, _bCol;
    NSString *_marked;                     // IME composition
    NSRange _markedSel;
    NSRange _hoverLink;                    // UTF-16 range in the hovered row's text
    NSUInteger _hoverRow;
    NSString *_hoverText;
    NSTrackingArea *_tracking;
    BOOL _dragging;
    NSTimer *_autoscroll;
    NSPoint _dragPoint, _pressPoint;
    NSDataDetector *_linkDetector;
}
- (void)applyFont;
- (void)syncSize;
- (void)write:(NSString *)s;
- (void)selectionRange:(NSInteger *)aLine col:(NSInteger *)aCol endLine:(NSInteger *)bLine col2:(NSInteger *)bCol;
@end
@implementation TerminalView

+ (CGFloat)defaultFontSize { return gFontSize; }
+ (void)setDefaultFontSize:(CGFloat)s { gFontSize = MIN(MAX(s, 8), 32); }

- (instancetype)initWithSession:(TSession *)session {
    if (!(self = [super initWithFrame:NSZeroRect])) return nil;
    _session = session;
    _size = gFontSize;
    _followBottom = NO;                     // pinned only once the user (or output) reaches the bottom
    _aLine = _aCol = _bLine = _bCol = -1;
    _hoverLink = NSMakeRange(NSNotFound, 0);
    _linkDetector = [[NSDataDetector alloc] initWithTypes:NSTextCheckingTypeLink error:nil];
    __weak typeof(self) weakSelf = self;
    session.onChange = ^{ [weakSelf terminalChanged]; };
    session.onExit = ^{ weakSelf.needsDisplay = YES; };
    [self applyFont];
    return self;
}

- (void)dealloc {
    // the callbacks only hold a weak self, so a released view's callbacks are harmless no-ops;
    // clearing them here would also erase the callbacks of the view that replaced this one
    if (_font) CFRelease(_font);
    if (_italicFont) CFRelease(_italicFont);
    [_autoscroll invalidate];
}

- (TSession *)session { return _session; }

#pragma mark Font

- (void)applyFont {
    if (_font) CFRelease(_font);
    NSFont *mono = [NSFont monospacedSystemFontOfSize:_size weight:NSFontWeightRegular];
    _font = mono ? (CTFontRef)CFBridgingRetain(mono) : CTFontCreateWithName(CFSTR("Menlo"), _size, NULL);
    _ascent = ceil(CTFontGetAscent(_font));
    UniChar ch = 'M';
    CGGlyph g;
    CGSize adv;
    CTFontGetGlyphsForCharacters(_font, &ch, &g, 1);
    CTFontGetAdvancesForGlyphs(_font, kCTFontOrientationHorizontal, &g, &adv, 1);
    _cellW = MAX(adv.width, 1);
    _cellH = ceil(_ascent + CTFontGetDescent(_font) + CTFontGetLeading(_font)) + 2;
    if (_italicFont) CFRelease(_italicFont);
    _italicFont = CTFontCreateCopyWithSymbolicTraits(_font, 0, NULL, kCTFontItalicTrait, kCTFontItalicTrait);
}

- (CGFloat)fontSize { return _size; }

- (void)setFontSize:(CGFloat)size {
    size = MIN(MAX(size, 8), 32);
    if (fabs(size - _size) < 0.01) return;
    _size = size;
    gFontSize = size;                      // the next terminal opens at this size
    [[NSUserDefaults standardUserDefaults] setDouble:size forKey:@"terminalFontSize"];
    [self applyFont];
    [self syncSize];
}

#pragma mark Geometry

- (NSUInteger)columns { return MAX((NSUInteger)4, (NSUInteger)floor((self.bounds.size.width - 6 - [CanvasView indicatorWidth]) / _cellW)); }
- (NSUInteger)rows { return MAX((NSUInteger)2, (NSUInteger)floor((self.bounds.size.height - 6) / _cellH)); }

- (CGFloat)contentHeight { return ([_session.screen historyCount] + [_session.screen rows]) * _cellH + 8; }

- (void)syncSize {
    TScreen *s = _session.screen;
    NSUInteger c = self.columns, r = self.rows;
    if (c != s.cols || r != s.rows) [_session resizeCols:c rows:r];
    if (_followBottom) self.scrollY = self.maxScrollY;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (_session) [self syncSize];
}

- (void)setScrollY:(CGFloat)y {
    [super setScrollY:y];
    _followBottom = self.scrollY >= self.maxScrollY - 0.5;
}

- (void)terminalChanged {
    // stay pinned to the bottom while output flows (within one line of it before the change)
    CGFloat max = self.maxScrollY;
    if (_followBottom || self.scrollY >= max - _cellH - 0.5) self.scrollY = max;
    self.needsDisplay = YES;
}

#pragma mark Colors

- (NSColor *)colorOf:(uint32_t)rgb defaultColor:(NSColor *)def {
    if (!rgb) return def;
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

// fg: TCDefault → label, palette (bold palette 0-7 uses the bright half), or RGB
- (NSColor *)fgOf:(TCell)c {
    TScreen *s = _session.screen;
    uint32_t v = c.fg;
    if (v == TCDefault) return [self colorOf:s.defaultFg == TCDefault ? 0 : s.defaultFg defaultColor:NSColor.labelColor];
    if (v & TCPal) {
        NSUInteger i = v & 0xFF;
        if ((c.attrs & TFBold) && i < 8) i += 8;
        return [self colorOf:_session.screen.palette[i] defaultColor:NSColor.labelColor];
    }
    return [self colorOf:v defaultColor:NSColor.labelColor];
}

- (NSColor *)bgOf:(TCell)c {
    TScreen *s = _session.screen;
    uint32_t v = c.bg;
    if (v == TCDefault) return [self colorOf:s.defaultBg == TCDefault ? 0 : s.defaultBg defaultColor:NSColor.textBackgroundColor];
    if (v & TCPal) return [self colorOf:_session.screen.palette[v & 0xFF] defaultColor:NSColor.textBackgroundColor];
    return [self colorOf:v defaultColor:NSColor.textBackgroundColor];
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirty {
    TScreen *s = _session.screen;
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
    static NSInteger lastDark = -1;
    if (dark != lastDark) {                    // apply the theme palette once; SGR resolves against it
        lastDark = dark;
        uint32_t c[16], bg, fg;
        themeColors(dark, c, &bg, &fg);
        [s setPalette16:c];
        s.defaultBg = bg;
        s.defaultFg = fg;
    }
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    if (s.inverse) {
        [NSColor.labelColor setFill];
        NSRectFill(dirty);
    } else {
        [[self bgOf:(TCell){0, TCDefault, TCDefault, 0}] setFill];
        NSRectFill(dirty);
    }

    NSUInteger history = [s historyCount];
    NSUInteger first = (NSUInteger)MAX(0, floor(self.scrollY / _cellH));
    NSUInteger last = MIN(history + s.rows, (NSUInteger)ceil((self.scrollY + NSMaxY(dirty)) / _cellH) + 1);
    BOOL focused = self.window.firstResponder == self && self.window.isKeyWindow;
    CGContextSetTextMatrix(cg, CGAffineTransformMakeScale(1, -1));

    // selection underlay
    NSInteger aL, aC, bL, bC;
    [self selectionRange:&aL col:&aC endLine:&bL col2:&bC];
    if (aL >= 0) {
        [[NSColor.selectedTextBackgroundColor colorWithAlphaComponent:0.55] setFill];
        for (NSUInteger abs = first; abs < last; abs++) {
            NSInteger line = (NSInteger)abs;
            if (line < aL || line > bL) continue;
            NSInteger c0 = line == aL ? aC : 0, c1 = line == bL ? bC : (NSInteger)s.cols - 1;
            NSRectFillUsingOperation(NSMakeRect(8 + c0 * _cellW, 8 + abs * _cellH - self.scrollY,
                                                MAX(_cellW, (c1 - c0 + 1) * _cellW), _cellH), NSCompositingOperationSourceOver);
        }
    }

    TCell *scratch = calloc(s.cols, sizeof(TCell));
    for (NSUInteger abs = first; abs < last; abs++) {
        CGFloat top = 8 + abs * _cellH - self.scrollY;
        if (top + _cellH < NSMinY(dirty) || top > NSMaxY(dirty)) continue;
        NSUInteger n = 0;
        const TCell *cells;
        if (abs < history) {
            cells = [s historyCells:abs];
            n = [s historyLength:abs];
        } else {
            NSUInteger r = abs - history;
            for (NSUInteger c = 0; c < s.cols; c++) scratch[c] = [s cellAtRow:r col:c];
            cells = scratch;
            n = s.cols;
        }
        [self drawCells:cells count:n top:top cg:cg absolute:abs focused:focused];
    }
    free(scratch);

    if (_marked.length && focused) {
        CGFloat x = 8 + MIN(s.cursorCol, s.cols - 1) * _cellW;
        CGFloat y = 8 + (history + s.cursorRow) * _cellH - self.scrollY;
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:_marked attributes:@{
            (id)kCTFontAttributeName: (__bridge id)_font,
            (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.labelColor.CGColor,
            (id)kCTUnderlineStyleAttributeName: @(kCTUnderlineStyleSingle)}];
        CTLineRef l = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGContextSetTextPosition(cg, x, y + _ascent);
        CTLineDraw(l, cg);
        CFRelease(l);
    }

    if (s.bellCount != _lastBell) {
        _lastBell = s.bellCount;
        _flashUntil = [NSDate timeIntervalSinceReferenceDate] + 0.15;
    }
    if ([NSDate timeIntervalSinceReferenceDate] < _flashUntil) {
        [[NSColor.controlAccentColor colorWithAlphaComponent:0.18] setFill];
        NSRectFillUsingOperation(dirty, NSCompositingOperationSourceOver);
    }
    [self drawScrollIndicator];
}

// UTF-8 text of one cell
- (NSString *)textOfChar:(uint32_t)ch {
    char buf[4];
    NSInteger m = ch < 0x80 ? 1 : ch < 0x800 ? 2 : ch < 0x10000 ? 3 : 4;
    if (ch < 0x80) buf[0] = (char)ch;
    else if (ch < 0x800) { buf[0] = 0xC0 | (ch >> 6); buf[1] = 0x80 | (ch & 0x3F); }
    else if (ch < 0x10000) { buf[0] = 0xE0 | (ch >> 12); buf[1] = 0x80 | ((ch >> 6) & 0x3F); buf[2] = 0x80 | (ch & 0x3F); }
    else { buf[0] = 0xF0 | (ch >> 18); buf[1] = 0x80 | ((ch >> 12) & 0x3F); buf[2] = 0x80 | ((ch >> 6) & 0x3F); buf[3] = 0x80 | (ch & 0x3F); }
    return [[NSString alloc] initWithBytes:buf length:m encoding:NSUTF8StringEncoding] ?: @"?";
}

// Runs of same-styled cells, backgrounds first, then text, then underlines; the cursor over its cell.
- (void)drawCells:(const TCell *)cells count:(NSUInteger)n top:(CGFloat)top cg:(CGContextRef)cg absolute:(NSUInteger)absolute focused:(BOOL)focused {
    TScreen *s = _session.screen;
    NSUInteger history = [s historyCount];
    NSUInteger curR = s.cursorRow, curC = s.cursorCol;
    BOOL cursorRow = s.cursorVisible && absolute == history + curR;
    for (NSUInteger i = 0; i < n;) {
        TCell c = cells[i];
        if (!c.ch || (c.attrs & TFCont)) { i++; continue; }
        NSUInteger j = i + 1;
        while (j < n && cells[j].ch && !(cells[j].attrs & TFCont) && cells[j].fg == c.fg && cells[j].bg == c.bg && cells[j].attrs == c.attrs) j++;
        CGFloat x = 8 + i * _cellW, w = (j - i) * _cellW;
        NSColor *bg = [self bgOf:c];
        if (![bg isEqual:[self bgOf:(TCell){0, TCDefault, TCDefault, 0}]]) {
            [bg setFill];
            NSRectFillUsingOperation(NSMakeRect(x, top, w, _cellH), NSCompositingOperationSourceOver);
        }
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:[self textOfRange:cells from:i to:j]
                                                                 attributes:@{(id)kCTFontAttributeName: (__bridge id)((c.attrs & TFItalic) && _italicFont ? _italicFont : _font),
                                                                              (id)kCTForegroundColorAttributeName: (__bridge id)[self fgOf:c].CGColor}];
        CTLineRef l = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGContextSetTextPosition(cg, x, top + _ascent + 1);
        CTLineDraw(l, cg);
        CFRelease(l);
        NSColor *fg = [self fgOf:c];
        if (c.attrs & (TFUnderline | TFStrike)) {
            [fg setFill];
            CGFloat y = (c.attrs & TFStrike) ? top + _cellH / 2 : top + _ascent + 3;
            NSRectFillUsingOperation(NSMakeRect(x, y, w, 1), NSCompositingOperationSourceOver);
        }
        i = j;
    }
    // the cursor over what it covers (block when focused, a thin outline otherwise)
    if (cursorRow && curC < s.cols) {
        CGFloat x = 8 + curC * _cellW;
        TCell under = cells[curC];
        if (focused) {
            [NSColor.controlAccentColor setFill];
            NSRectFillUsingOperation(NSMakeRect(x, top, _cellW * (under.attrs & TFWide ? 2 : 1), _cellH), NSCompositingOperationSourceOver);
            if (under.ch) {
                NSAttributedString *as = [[NSAttributedString alloc] initWithString:[self textOfChar:under.ch]
                                                                         attributes:@{(id)kCTFontAttributeName: (__bridge id)_font,
                                                                                      (id)kCTForegroundColorAttributeName: (__bridge id)NSColor.textBackgroundColor.CGColor}];
                CTLineRef l = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
                CGContextSetTextPosition(cg, x, top + _ascent + 1);
                CTLineDraw(l, cg);
                CFRelease(l);
            }
        } else {
            [[NSColor.controlAccentColor colorWithAlphaComponent:0.9] setStroke];
            NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSMakeRect(x + 0.5, top + 0.5, _cellW * (under.attrs & TFWide ? 2 : 1) - 1, _cellH - 1)];
            p.lineWidth = 1;
            [p stroke];
        }
    }
}

- (NSString *)textOfRange:(const TCell *)cells from:(NSUInteger)i to:(NSUInteger)j {
    NSMutableString *t = [NSMutableString string];
    char buf[4];
    for (NSUInteger k = i; k < j; k++) {
        if (cells[k].attrs & TFCont) continue;
        uint32_t ch = cells[k].ch;
        NSInteger m = ch < 0x80 ? 1 : ch < 0x800 ? 2 : ch < 0x10000 ? 3 : 4;
        if (ch < 0x80) buf[0] = (char)ch;
        else if (ch < 0x800) { buf[0] = 0xC0 | (ch >> 6); buf[1] = 0x80 | (ch & 0x3F); }
        else if (ch < 0x10000) { buf[0] = 0xE0 | (ch >> 12); buf[1] = 0x80 | ((ch >> 6) & 0x3F); buf[2] = 0x80 | (ch & 0x3F); }
        else { buf[0] = 0xF0 | (ch >> 18); buf[1] = 0x80 | ((ch >> 12) & 0x3F); buf[2] = 0x80 | ((ch >> 6) & 0x3F); buf[3] = 0x80 | (ch & 0x3F); }
        [t appendString:[[NSString alloc] initWithBytes:buf length:m encoding:NSUTF8StringEncoding] ?: @"?"];
    }
    return t;
}

#pragma mark Selection

- (void)selectionRange:(NSInteger *)aLine col:(NSInteger *)aCol endLine:(NSInteger *)bLine col2:(NSInteger *)bC {
    if (_aLine < 0 || (_aLine == _bLine && _aCol == _bCol)) { *aLine = *bLine = -1; return; }
    if (_aLine < _bLine || (_aLine == _bLine && _aCol <= _bCol)) {
        *aLine = _aLine; *aCol = _aCol; *bLine = _bLine; *bC = _bCol;
    } else {
        *aLine = _bLine; *aCol = _bCol; *bLine = _aLine; *bC = _aCol;
    }
}

- (NSString *)selectedText {
    NSInteger aL, aC, bL, bC;
    [self selectionRange:&aL col:&aC endLine:&bL col2:&bC];
    if (aL < 0) return @"";
    TScreen *s = _session.screen;
    NSUInteger history = [s historyCount];
    NSMutableString *out = [NSMutableString string];
    for (NSInteger line = aL; line <= bL && out.length < (NSUInteger)1 << 20; line++) {
        NSInteger c0 = line == aL ? MAX(aC, 0) : 0;
        NSInteger c1 = line == bL ? bC : (NSInteger)s.cols - 1;
        if (line < 0) continue;
        NSMutableString *row = [NSMutableString string];
        for (NSInteger c = c0; c <= c1; c++) {
            TCell cell;
            if ((NSUInteger)line < history) {
                NSUInteger n = [s historyLength:line];
                NSUInteger idx = (NSUInteger)c;
                if (idx >= n) break;
                cell = [s historyCells:line][idx];
            } else {
                NSUInteger r = (NSUInteger)line - history;
                if (r >= s.rows || c >= (NSInteger)s.cols) break;
                cell = [s cellAtRow:r col:(NSUInteger)c];
            }
            if (cell.attrs & TFCont) continue;
            [row appendString:cell.ch ? [self textOfChar:cell.ch] : @" "];
        }
        if (out.length) [out appendString:@"\n"];
        [out appendString:row];
    }
    NSMutableString *clean = [NSMutableString string];
    for (NSString *row in [out componentsSeparatedByString:@"\n"]) {
        if (clean.length) [clean appendString:@"\n"];
        [clean appendString:[row stringByReplacingOccurrencesOfString:@"[ \t]+$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, row.length)]];
    }
    return clean;
}

- (BOOL)hasSelection { return _aLine >= 0 && (_aLine != _bLine || _aCol != _bCol); }

#pragma mark Keys

- (void)write:(NSString *)s { [_session writeString:s]; }

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }

- (void)keyDown:(NSEvent *)e {
    if ([self.inputContext handleEvent:e]) return;
    NSData *d = [self bytesForEvent:e];
    if (d.length) [_session writeData:d];
}

// The input context turns control keys into text commands (this is how Enter, Delete and the arrows
// arrive); translate them back into the shell's sequences. Arrows honour the current modifiers.
- (NSData *)bytesForArrow:(NSString *)letter {
    NSEventModifierFlags m = NSApp.currentEvent ? NSApp.currentEvent.modifierFlags : 0;
    BOOL app = _session.screen.appCursorKeys;
    if (m & (NSEventModifierFlagControl | NSEventModifierFlagShift | NSEventModifierFlagOption))
        return [[NSString stringWithFormat:@"\x1b[1;%ld%@", (long)(1 + ((m & NSEventModifierFlagShift) ? 1 : 0) +
                                                                ((m & NSEventModifierFlagOption) ? 2 : 0) + ((m & NSEventModifierFlagControl) ? 4 : 0)),
                letter] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *pre = app ? @"\x1bO" : @"\x1b[";
    return [[pre stringByAppendingString:letter] dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)doCommandBySelector:(SEL)sel {
    NSData *d = nil;
    if (sel == @selector(insertNewline:)) d = [@"\r" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(deleteBackward:) || sel == @selector(deleteBackwardByDecomposingPreviousCharacter:)) d = [@"\x7f" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(deleteForward:)) d = [@"\x1b[3~" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(deleteWordBackward:)) d = [@"\x17" dataUsingEncoding:NSUTF8StringEncoding];        // ⌃W
    else if (sel == @selector(deleteWordForward:)) d = [@"\x1b\x7f" dataUsingEncoding:NSUTF8StringEncoding];   // ⌥⌫
    else if (sel == @selector(moveUp:) || sel == @selector(moveUpAndModifySelection:)) d = [self bytesForArrow:@"A"];
    else if (sel == @selector(moveDown:) || sel == @selector(moveDownAndModifySelection:)) d = [self bytesForArrow:@"B"];
    else if (sel == @selector(moveRight:) || sel == @selector(moveRightAndModifySelection:)) d = [self bytesForArrow:@"C"];
    else if (sel == @selector(moveLeft:) || sel == @selector(moveLeftAndModifySelection:)) d = [self bytesForArrow:@"D"];
    else if (sel == @selector(moveWordLeft:)) d = [@"\x1b" @"b" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(moveWordRight:)) d = [@"\x1b" @"f" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(moveToBeginningOfLine:) || sel == @selector(moveToBeginningOfDocument:)) d = [@"\x01" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(moveToEndOfLine:) || sel == @selector(moveToEndOfDocument:)) d = [@"\x05" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(pageUp:) || sel == @selector(scrollPageUp:) || sel == @selector(pageUpAndModifySelection:)) d = [@"\x1b[5~" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(pageDown:) || sel == @selector(scrollPageDown:) || sel == @selector(pageDownAndModifySelection:)) d = [@"\x1b[6~" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(insertTab:)) d = [@"\t" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(insertBacktab:)) d = [@"\x1b[Z" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(cancelOperation:)) d = [@"\x1b" dataUsingEncoding:NSUTF8StringEncoding];
    else if (sel == @selector(transpose:)) d = [@"\x14" dataUsingEncoding:NSUTF8StringEncoding];               // ⌃T
    if (d.length) [_session writeData:d];
}

// Escape sequences for the keys a shell expects; plain characters go through as typed.
- (NSData *)bytesForEvent:(NSEvent *)e {
    NSEventModifierFlags m = e.modifierFlags;
    BOOL cmd = (m & NSEventModifierFlagCommand) != 0;
    BOOL ctrl = (m & NSEventModifierFlagControl) != 0;
    BOOL alt = (m & NSEventModifierFlagOption) != 0;
    NSString *ign = e.charactersIgnoringModifiers;
    unichar k = ign.length ? [ign characterAtIndex:0] : 0;
    if (k >= NSUpArrowFunctionKey && k <= NSF24FunctionKey) {
        NSString *s = nil;
        BOOL app = _session.screen.appCursorKeys;
        NSString *pre = app ? @"\x1bO" : @"\x1b[";
        switch (k) {
            case NSUpArrowFunctionKey: s = [pre stringByAppendingString:@"A"]; break;
            case NSDownArrowFunctionKey: s = [pre stringByAppendingString:@"B"]; break;
            case NSRightArrowFunctionKey: s = [pre stringByAppendingString:@"C"]; break;
            case NSLeftArrowFunctionKey: s = [pre stringByAppendingString:@"D"]; break;
            case NSHomeFunctionKey: s = [pre stringByAppendingString:@"H"]; break;
            case NSEndFunctionKey: s = [pre stringByAppendingString:@"F"]; break;
            case NSPageUpFunctionKey: s = @"\x1b[5~"; break;
            case NSPageDownFunctionKey: s = @"\x1b[6~"; break;
            case NSInsertFunctionKey: s = @"\x1b[2~"; break;
            case NSDeleteFunctionKey: s = @"\x1b[3~"; break;
            default:
                if (k >= NSF1FunctionKey && k <= NSF12FunctionKey) {
                    NSInteger nn = k - NSF1FunctionKey + 11;         // 11..14, then 15..24
                    if (nn > 14) nn += 1;
                    s = [NSString stringWithFormat:@"\x1b[%ld~", (long)nn];
                }
                break;
        }
        return [s dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (cmd) return nil;                                    // ⌘ keys belong to the menus
    NSString *s = nil;
    switch (k) {
        case 0x7F: s = @"\x7f"; break;                       // delete
        case '\r': case 3: s = @"\r"; break;
        case '\t': s = (m & NSEventModifierFlagShift) ? @"\x1b[Z" : @"\t"; break;
        case 27: s = @"\x1b"; break;
        default: break;
    }
    if (ctrl) {
        unichar raw = k;
        if (raw >= 'a' && raw <= 'z') s = [NSString stringWithFormat:@"%c", (char)(raw - 'a' + 1)];
        else if (raw >= 'A' && raw <= 'Z') s = [NSString stringWithFormat:@"%c", (char)(raw - 'A' + 1)];
        else if (raw == ' ') s = @"\0";
        else if (raw == '[') s = @"\x1b";
        else if (raw == '\\') s = @"\x1c";
        else if (raw == ']') s = @"\x1d";
        else if (raw == '^') s = @"\x1e";
        else if (raw == '_' || raw == '/') s = @"\x1f";
        return [s dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (s) return [s dataUsingEncoding:NSUTF8StringEncoding];
    NSString *typed = e.characters;
    if (!typed.length) return nil;
    if (alt && typed.length == 1 && [typed characterAtIndex:0] < 0x80)
        return [[@"\x1b" stringByAppendingString:typed] dataUsingEncoding:NSUTF8StringEncoding];
    return [typed dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark Mouse

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (NSUInteger)modifierBits:(NSEvent *)e {
    NSEventModifierFlags m = e.modifierFlags;
    return ((m & NSEventModifierFlagShift) ? 4 : 0) + ((m & NSEventModifierFlagOption) ? 8 : 0) + ((m & NSEventModifierFlagControl) ? 16 : 0);
}

- (BOOL)appWantsMouse { return _session.screen.mouseMode != TMouseOff && !_session.exited; }

- (NSInteger)lineAtPoint:(NSPoint)p { return (NSInteger)floor((p.y + self.scrollY - 8) / _cellH); }
- (NSInteger)colAtPoint:(NSPoint)p { return (NSInteger)MAX(0, floor((p.x - 8) / _cellW)); }

- (void)sendMouse:(NSInteger)code at:(NSPoint)p release:(BOOL)release event:(NSEvent *)e {
    NSInteger col = [self colAtPoint:p] + 1, row = [self lineAtPoint:p] - (NSInteger)[_session.screen historyCount] + 1;
    if (row < 1) return;
    [self write:[NSString stringWithFormat:@"\x1b[<%ld;%ld;%ld%c", (long)(code + (NSInteger)[self modifierBits:e]), (long)col, (long)row, release ? 'm' : 'M']];
}

- (void)canvasMouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _pressPoint = p;
    if ([self appWantsMouse]) { [self sendMouse:e.clickCount == 2 ? 1 : 0 at:p release:NO event:e]; return; }
    _aLine = _bLine = [self lineAtPoint:p];
    _aCol = _bCol = [self colAtPoint:p];
    if (e.clickCount == 2) [self extendWordSelection];
    else if (e.clickCount >= 3) _bCol = (NSInteger)_session.screen.cols - 1;
    _dragging = YES;
    self.needsDisplay = YES;
}

// One cell of the scrollable text (history lines first, then screen rows).
- (TCell)absCell:(NSInteger)line col:(NSInteger)col {
    TScreen *s = _session.screen;
    NSUInteger history = [s historyCount];
    if (line < 0 || col < 0) return (TCell){0, 0, 0, 0};
    if ((NSUInteger)line < history) {
        NSUInteger n = [s historyLength:line];
        return (NSUInteger)col < n ? [s historyCells:line][(NSUInteger)col] : (TCell){0, 0, 0, 0};
    }
    NSUInteger r = (NSUInteger)line - history;
    return r < s.rows && (NSUInteger)col < s.cols ? [s cellAtRow:r col:(NSUInteger)col] : (TCell){0, 0, 0, 0};
}

// Double click: the run of non-blank cells around the anchor.
- (void)extendWordSelection {
    NSInteger line = _aLine, col = _aCol;
    TCell at = [self absCell:line col:col];
    if (!at.ch) { _aCol = _bCol = col; return; }
    BOOL wide = at.ch >= 0x80;
    NSInteger a = col, b = col;
    while (a > 0) {
        TCell p1 = [self absCell:line col:a - 1];
        if (!p1.ch || p1.ch == ' ' || (p1.attrs & TFCont)) break;
        if (!wide && p1.ch >= 0x80) break;
        a--;
    }
    while (b < (NSInteger)_session.screen.cols - 1) {
        TCell p2 = [self absCell:line col:b + 1];
        if (!p2.ch || p2.ch == ' ' || (p2.attrs & TFCont)) break;
        if (!wide && p2.ch >= 0x80) break;
        b++;
    }
    _aCol = a;
    _bCol = b;
}

- (void)canvasMouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self appWantsMouse]) { [self sendMouse:32 at:p release:NO event:e]; return; }
    if (!_dragging) return;
    _dragPoint = p;
    [self dragSelectTo:p];
    CGFloat over = p.y < 0 ? p.y : (p.y > self.bounds.size.height ? p.y - self.bounds.size.height : 0);
    if (over) {
        self.scrollY += (over < 0 ? -1 : 1) * _cellH * MIN(5, 1 + fabs(over) / 30);
        if (!_autoscroll) {
            __weak typeof(self) weakSelf = self;
            _autoscroll = [NSTimer scheduledTimerWithTimeInterval:0.06 repeats:YES block:^(NSTimer *t) {
                typeof(self) me = weakSelf;
                if (!me || !(NSEvent.pressedMouseButtons & 1)) { [t invalidate]; if (me) me->_autoscroll = nil; return; }
                [me dragSelectTo:me->_dragPoint];
            }];
        }
    } else if (_autoscroll) {
        [_autoscroll invalidate];
        _autoscroll = nil;
    }
}

- (void)dragSelectTo:(NSPoint)p {
    _bLine = [self lineAtPoint:p];
    _bCol = [self colAtPoint:p];
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)e {
    [_autoscroll invalidate];
    _autoscroll = nil;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self appWantsMouse]) { [self sendMouse:0 at:p release:YES event:e]; return; }
    _dragging = NO;
    if (fabs(p.x - _pressPoint.x) < 3 && fabs(p.y - _pressPoint.y) < 3 && _hoverLink.length && _hoverText &&
        NSMaxRange(_hoverLink) <= _hoverText.length) {
        NSURL *u = [NSURL URLWithString:[_hoverText substringWithRange:_hoverLink]];
        if (u.host) [[NSWorkspace sharedWorkspace] openURL:u];
    }
}

- (void)scrollWheel:(NSEvent *)e {
    if ([self appWantsMouse]) {
        CGFloat dy = e.scrollingDeltaY;
        if (!dy) return;
        NSInteger clicks = (NSInteger)MAX(1, round(fabs(dy) / ([e hasPreciseScrollingDeltas] ? 4 : 1)));
        NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
        for (NSInteger i = 0; i < MIN(clicks, (NSInteger)10); i++) [self sendMouse:dy < 0 ? 64 : 65 at:p release:NO event:e];
        return;
    }
    [super scrollWheel:e];
}

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self appWantsMouse] && _session.screen.mouseMode == TMouseAny) { [self sendMouse:32 at:p release:NO event:e]; return; }
    NSInteger line = [self lineAtPoint:p];
    NSUInteger history = [_session.screen historyCount];
    NSString *row = nil;
    if (line >= (NSInteger)history && line - (NSInteger)history < (NSInteger)[_session.screen rows])
        row = [_session.screen textOfRow:(NSUInteger)line - history];
    NSRange found = NSMakeRange(NSNotFound, 0);
    if (row.length && row.length < 20000) {
        for (NSTextCheckingResult *m in [_linkDetector matchesInString:row options:0 range:NSMakeRange(0, row.length)]) {
            if (NSLocationInRange([self colAtPoint:p], m.range)) { found = m.range; break; }
        }
    }
    _hoverRow = found.location != NSNotFound ? (NSUInteger)line - history : 0;
    _hoverText = row;
    if (found.location != _hoverLink.location || found.length != _hoverLink.length) {
        _hoverLink = found;
        self.needsDisplay = YES;
        [self.window invalidateCursorRectsForView:self];
    }
}

- (void)mouseExited:(NSEvent *)e {
    if (_hoverLink.length) { _hoverLink = NSMakeRange(NSNotFound, 0); self.needsDisplay = YES; }
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:_hoverLink.length ? NSCursor.pointingHandCursor : NSCursor.IBeamCursor];
}

- (NSMenu *)menuForEvent:(NSEvent *)e {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *copy = [[NSMenuItem alloc] initWithTitle:FTL(@"Copy") action:@selector(copy:) keyEquivalent:@""];
    copy.target = self;
    NSMenuItem *paste = [[NSMenuItem alloc] initWithTitle:FTL(@"Paste") action:@selector(paste:) keyEquivalent:@""];
    paste.target = self;
    NSMenuItem *all = [[NSMenuItem alloc] initWithTitle:FTL(@"Select All") action:@selector(selectAll:) keyEquivalent:@""];
    all.target = self;
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:FTL(@"Clear") action:@selector(clear:) keyEquivalent:@""];
    clear.target = self;
    [m addItem:copy];
    [m addItem:paste];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:all];
    [m addItem:clear];
    return m;
}

#pragma mark Commands (menu targets)

- (void)copy:(id)sender {
    NSString *s = self.selectedText;
    if (!s.length) {                                          // no selection: ⌘C means interrupt
        [_session writeData:[@"\x03" dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

- (void)paste:(id)sender {
    NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    s = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    if (_session.screen.bracketedPaste) s = [NSString stringWithFormat:@"\x1b[200~%@\x1b[201~", s];
    [_session writeString:s];
}

- (void)selectAll:(id)sender {
    _aLine = 0;
    _aCol = 0;
    _bLine = (NSInteger)([_session.screen historyCount] + [_session.screen rows]) - 1;
    _bCol = (NSInteger)_session.screen.cols - 1;
    self.needsDisplay = YES;
}

- (void)clear:(id)sender {
    TScreen *s = _session.screen;
    [s clearScrollback];
    [s cursorToRow:0 col:0 origin:NO];
    [s eraseInDisplay:2];
    _aLine = _bLine = -1;
    _followBottom = YES;
    self.scrollY = 0;
    self.needsDisplay = YES;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(copy:)) return YES;          // without a selection it interrupts
    if (item.action == @selector(paste:)) return [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].length > 0;
    return YES;
}

#pragma mark NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)rr {
    NSString *s = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    _marked = nil;
    s = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\r"] stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    [_session writeString:s];
    self.needsDisplay = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)sel replacementRange:(NSRange)rr {
    _marked = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)string string] : string;
    _markedSel = sel;
    self.needsDisplay = YES;
}

- (void)unmarkText { _marked = nil; self.needsDisplay = YES; }
- (BOOL)hasMarkedText { return _marked.length > 0; }
- (NSRange)markedRange { return _marked.length ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(0, 0); }

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)actual {
    NSString *s = self.selectedText;
    if (!s.length || r.location > s.length) return nil;
    NSRange clipped = NSIntersectionRange(r, NSMakeRange(0, s.length));
    if (actual) *actual = clipped;
    return [[NSAttributedString alloc] initWithString:[s substringWithRange:clipped]];
}

- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)actual {
    TScreen *s = _session.screen;
    NSUInteger history = [s historyCount];
    NSRect local = NSMakeRect(8 + s.cursorCol * _cellW, 8 + (history + s.cursorRow) * _cellH - self.scrollY, _cellW, _cellH);
    if (actual) *actual = r;
    return [self.window convertRectToScreen:[self convertRect:local toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)p { return 0; }

@end

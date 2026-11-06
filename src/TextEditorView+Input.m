#import "TextEditorView+Private.h"

@implementation TextEditorView (Input)

#pragma mark Mouse

- (void)canvasMouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self minimapPressAt:p]) return;
    if (_markedText) { [self.inputContext discardMarkedText]; [self unmarkText]; }
    NSUInteger off = [self offsetAtPoint:p];
    _desiredX = -1;
    if (e.clickCount == 2) {
        NSRange w = [self wordRangeAt:off];
        _anchor = w.location; _caret = NSMaxRange(w);
        _coalesceBroken = YES;
        [self notifyChange];
    } else if (e.clickCount >= 3) {
        NSUInteger L = [_buf lineForOffset:off];
        _anchor = [_buf lineStart:L];
        _caret = L + 1 < _buf.lineCount ? [_buf lineStart:L + 1] : _buf.length;
        _coalesceBroken = YES;
        [self notifyChange];
    } else {
        [self moveCaretTo:off extend:(e.modifierFlags & NSEventModifierFlagShift) != 0];
    }
}

- (void)mouseUp:(NSEvent *)e {
    if (_mapDragging) { _mapDragging = NO; self.needsDisplay = YES; }
    [super mouseUp:e];
}

- (void)canvasMouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_mapDragging) { [self minimapDragTo:p]; return; }
    if (p.y < 0) self.scrollY -= _lineHeight;
    else if (p.y > self.bounds.size.height) self.scrollY += _lineHeight;
    _caret = [self offsetAtPoint:p];
    [self notifyChange];
}

#pragma mark Keys

- (void)keyDown:(NSEvent *)e {
    if (![self.inputContext handleEvent:e]) [super keyDown:e];
}

- (void)doCommandBySelector:(SEL)sel {
    if ([self respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:sel withObject:nil];
        #pragma clang diagnostic pop
    }
}

- (void)horizontal:(BOOL)fwd extend:(BOOL)ext {
    NSRange sel = self.selection;
    if (!ext && sel.length) { [self moveCaretTo:fwd ? NSMaxRange(sel) : sel.location extend:NO]; return; }
    [self moveCaretTo:fwd ? [self nextCharOffset:_caret] : [self prevCharOffset:_caret] extend:ext];
    _desiredX = -1;
}

- (void)vertical:(NSInteger)dir lines:(NSUInteger)count extend:(BOOL)ext {
    NSUInteger L = [_buf lineForOffset:_caret];
    if (_desiredX < 0) _desiredX = [self xForOffset:_caret];
    CGFloat keep = _desiredX;
    NSUInteger target;
    if (dir < 0) target = L >= count ? [self offsetForX:keep line:L - count] : 0;
    else target = L + count < _buf.lineCount ? [self offsetForX:keep line:L + count] : _buf.length;
    [self moveCaretTo:target extend:ext];
    _desiredX = keep;
}

- (NSUInteger)pageLines { return MAX(1, (NSUInteger)(self.bounds.size.height / _lineHeight) - 2); }
- (NSUInteger)lineHome { return [_buf lineStart:[_buf lineForOffset:_caret]]; }
- (NSUInteger)lineEndOff { return [_buf lineEnd:[_buf lineForOffset:_caret]]; }

- (void)moveLeft:(id)s  { [self horizontal:NO extend:NO]; }
- (void)moveRight:(id)s { [self horizontal:YES extend:NO]; }
- (void)moveLeftAndModifySelection:(id)s  { [self horizontal:NO extend:YES]; }
- (void)moveRightAndModifySelection:(id)s { [self horizontal:YES extend:YES]; }
- (void)moveUp:(id)s   { [self vertical:-1 lines:1 extend:NO]; }
- (void)moveDown:(id)s { [self vertical:1 lines:1 extend:NO]; }
- (void)moveUpAndModifySelection:(id)s   { [self vertical:-1 lines:1 extend:YES]; }
- (void)moveDownAndModifySelection:(id)s { [self vertical:1 lines:1 extend:YES]; }
- (void)pageUp:(id)s   { [self vertical:-1 lines:self.pageLines extend:NO]; }
- (void)pageDown:(id)s { [self vertical:1 lines:self.pageLines extend:NO]; }
- (void)pageUpAndModifySelection:(id)s   { [self vertical:-1 lines:self.pageLines extend:YES]; }
- (void)pageDownAndModifySelection:(id)s { [self vertical:1 lines:self.pageLines extend:YES]; }
- (void)scrollPageUp:(id)s   { self.scrollY -= self.bounds.size.height; }
- (void)scrollPageDown:(id)s { self.scrollY += self.bounds.size.height; }
- (void)moveWordLeft:(id)s  { [self moveCaretTo:[self wordBoundary:_caret forward:NO] extend:NO]; }
- (void)moveWordRight:(id)s { [self moveCaretTo:[self wordBoundary:_caret forward:YES] extend:NO]; }
- (void)moveWordLeftAndModifySelection:(id)s  { [self moveCaretTo:[self wordBoundary:_caret forward:NO] extend:YES]; }
- (void)moveWordRightAndModifySelection:(id)s { [self moveCaretTo:[self wordBoundary:_caret forward:YES] extend:YES]; }
- (void)moveToLeftEndOfLine:(id)s  { [self moveCaretTo:self.lineHome extend:NO]; }
- (void)moveToRightEndOfLine:(id)s { [self moveCaretTo:self.lineEndOff extend:NO]; }
- (void)moveToLeftEndOfLineAndModifySelection:(id)s  { [self moveCaretTo:self.lineHome extend:YES]; }
- (void)moveToRightEndOfLineAndModifySelection:(id)s { [self moveCaretTo:self.lineEndOff extend:YES]; }
- (void)moveToBeginningOfLine:(id)s { [self moveToLeftEndOfLine:s]; }
- (void)moveToEndOfLine:(id)s { [self moveToRightEndOfLine:s]; }
- (void)moveToBeginningOfDocument:(id)s { [self moveCaretTo:0 extend:NO]; }
- (void)moveToEndOfDocument:(id)s { [self moveCaretTo:_buf.length extend:NO]; }
- (void)moveToBeginningOfDocumentAndModifySelection:(id)s { [self moveCaretTo:0 extend:YES]; }
- (void)moveToEndOfDocumentAndModifySelection:(id)s { [self moveCaretTo:_buf.length extend:YES]; }
- (void)scrollToBeginningOfDocument:(id)s { self.scrollY = 0; }
- (void)scrollToEndOfDocument:(id)s { self.scrollY = self.contentHeight; }

- (void)deleteBackward:(id)s {
    NSRange sel = self.selection;
    if (sel.length) { [self replaceRange:sel withString:@"" kind:GroupOther]; return; }
    if (_caret == 0) return;
    NSUInteger p = [self prevCharOffset:_caret];
    [self replaceRange:NSMakeRange(p, _caret - p) withString:@"" kind:GroupBackspace];
}

- (void)deleteForward:(id)s {
    NSRange sel = self.selection;
    if (!sel.length) sel = NSMakeRange(_caret, [self nextCharOffset:_caret] - _caret);
    if (sel.length) [self replaceRange:sel withString:@"" kind:GroupOther];
}

- (void)deleteWordBackward:(id)s {
    NSUInteger p = [self wordBoundary:_caret forward:NO];
    if (p < _caret) [self replaceRange:NSMakeRange(p, _caret - p) withString:@"" kind:GroupOther];
}

- (void)deleteToBeginningOfLine:(id)s {
    NSUInteger h = self.lineHome;
    if (h < _caret) [self replaceRange:NSMakeRange(h, _caret - h) withString:@"" kind:GroupOther];
    else [self deleteBackward:s];
}

- (void)insertNewline:(id)s {
    NSUInteger ls = self.lineHome, i = ls;
    while (i < _caret && ([_buf byteAt:i] == ' ' || [_buf byteAt:i] == '\t')) i++;
    NSString *indent = [[NSString alloc] initWithData:[_buf dataInRange:NSMakeRange(ls, i - ls)] encoding:NSUTF8StringEncoding];
    NSString *nl = _buf.usesCRLF ? @"\r\n" : @"\n";
    [self replaceRange:self.selection withString:[nl stringByAppendingString:indent ?: @""] kind:GroupOther];
    _coalesceBroken = YES;
}

- (void)insertTab:(id)s { [self replaceRange:self.selection withString:_indentUnit kind:GroupTyping]; }
- (void)cancelOperation:(id)s { if (self.selection.length) [self moveCaretTo:_caret extend:NO]; }

#pragma mark NSTextInputClient (ranges are UTF-16 indices within the caret line)

static NSString *plain(id s) { return [s isKindOfClass:NSAttributedString.class] ? [s string] : s; }

- (void)insertText:(id)string replacementRange:(NSRange)rr {
    NSString *s = plain(string);
    BOOL wasMarked = _markedText != nil;
    _markedText = nil;
    if (!s.length) { [self notifyChange]; return; }
    BOOL single = !wasMarked && s.length <= 2 && ![s containsString:@"\n"];
    [self replaceRange:self.selection withString:s kind:single ? GroupTyping : GroupOther];
    if (!single) _coalesceBroken = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)sel replacementRange:(NSRange)rr {
    NSString *s = plain(string);
    if (!_markedText && self.selection.length) [self replaceRange:self.selection withString:@"" kind:GroupOther];
    _markedText = s.length ? [s copy] : nil;
    _markedSel = sel;
    [self scrollCaretVisible];
    self.needsDisplay = YES;
}

- (void)unmarkText {
    if (_markedText) { NSString *s = _markedText; _markedText = nil; [self insertText:s replacementRange:NSMakeRange(NSNotFound, 0)]; }
}

- (BOOL)hasMarkedText { return _markedText != nil; }

- (NSRange)markedRange {
    if (!_markedText) return NSMakeRange(NSNotFound, 0);
    NSUInteger u = [self utf16Index:_caret inLine:[_buf lineForOffset:_caret]];
    return NSMakeRange(u, _markedText.length);
}

- (NSRange)selectedRange {
    NSUInteger L = [_buf lineForOffset:_caret];
    NSRange sel = self.selection;
    NSUInteger a = [self utf16Index:MAX(sel.location, [_buf lineStart:L]) inLine:L];
    NSUInteger b = [self utf16Index:MIN(NSMaxRange(sel), [_buf lineEnd:L]) inLine:L];
    if (_markedText) return NSMakeRange(a + _markedSel.location, _markedSel.length);
    return NSMakeRange(a, b >= a ? b - a : 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)actual {
    NSString *s = [self lineString:[_buf lineForOffset:_caret]];
    NSRange clipped = NSIntersectionRange(r, NSMakeRange(0, s.length));
    if (actual) *actual = clipped;
    return [[NSAttributedString alloc] initWithString:[s substringWithRange:clipped]];
}

- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)actual {
    NSUInteger L = [_buf lineForOffset:_caret];
    CGFloat x = self.textOriginX + [self xForOffset:_caret];
    if (_markedText && r.location != NSNotFound) {
        CTLineRef line = [self createLine:_markedText];
        NSUInteger base = [self utf16Index:_caret inLine:L];
        NSUInteger in = r.location > base ? MIN(r.location - base, _markedText.length) : 0;
        x += CTLineGetOffsetForStringIndex(line, in, NULL);
        CFRelease(line);
    }
    NSRect local = NSMakeRect(x, 4 + L * _lineHeight - self.scrollY, 1, _lineHeight);
    if (actual) *actual = r;
    return [self.window convertRectToScreen:[self convertRect:local toView:nil]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)screenPoint {
    NSPoint w = [self.window convertPointFromScreen:screenPoint];
    NSUInteger off = [self offsetAtPoint:[self convertPoint:w fromView:nil]];
    NSUInteger L = [_buf lineForOffset:off];
    return L == [_buf lineForOffset:_caret] ? [self utf16Index:off inLine:L] : NSNotFound;
}

@end

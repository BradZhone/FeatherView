#import "TextEditorView+Private.h"

@implementation TextEditorView (Input)

#pragma mark Mouse

- (void)canvasMouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self minimapPressAt:p]) return;
    if (_markedText) { [self unmarkText]; [self.inputContext discardMarkedText]; }      // a click commits the composition
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
    [_dragScroll invalidate]; _dragScroll = nil;
    if (_mapDragging) { _mapDragging = NO; self.needsDisplay = YES; }
    [super mouseUp:e];
}

// Dragging a selection above or below the view keeps scrolling while the mouse is held still there.
- (void)dragTo:(NSPoint)p {
    NSRect b = self.bounds;
    CGFloat over = p.y < 0 ? p.y : p.y > b.size.height ? p.y - b.size.height : 0;
    if (over) self.scrollY += (over < 0 ? -1 : 1) * _lineHeight * MIN(5, 1 + fabs(over) / 40);
    _caret = [self offsetAtPoint:NSMakePoint(p.x, MIN(MAX(p.y, 0), b.size.height - 1))];
    [self scrollCaretVisible];
    [self notifyChange];
    if (over && !_dragScroll) {
        __weak TextEditorView *weakSelf = self;
        _dragScroll = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
            TextEditorView *me = weakSelf;
            if (!me || !(NSEvent.pressedMouseButtons & 1)) { [t invalidate]; if (me) me->_dragScroll = nil; return; }
            [me dragTo:me->_dragPoint];
        }];
    } else if (!over) { [_dragScroll invalidate]; _dragScroll = nil; }
}

- (void)canvasMouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (_mapDragging) { [self minimapDragTo:p]; return; }
    _dragPoint = p;
    [self dragTo:p];
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

// Moves by visual rows, so wrapped lines are walked row by row.
- (void)vertical:(NSInteger)dir lines:(NSUInteger)count extend:(BOOL)ext {
    CGFloat x = 0;
    NSUInteger row = [self rowOfOffset:_caret x:&x];
    if (_desiredX < 0) _desiredX = x;
    CGFloat keep = _desiredX;
    NSUInteger target;
    if (dir < 0) target = row >= count ? [self offsetInRow:row - count x:keep] : 0;
    else target = row + count < self.rowCount ? [self offsetInRow:row + count x:keep] : _buf.length;
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

// Emacs keys that AppKit's standard key bindings send (⌃A ⌃E ⌃K ⌃Y ⌃T ⌃O …).
- (void)moveForward:(id)s  { [self moveRight:s]; }
- (void)moveBackward:(id)s { [self moveLeft:s]; }
- (void)moveForwardAndModifySelection:(id)s  { [self moveRightAndModifySelection:s]; }
- (void)moveBackwardAndModifySelection:(id)s { [self moveLeftAndModifySelection:s]; }
- (void)moveToBeginningOfParagraph:(id)s { [self moveToLeftEndOfLine:s]; }
- (void)moveToEndOfParagraph:(id)s { [self moveToRightEndOfLine:s]; }
- (void)moveToBeginningOfParagraphAndModifySelection:(id)s { [self moveToLeftEndOfLineAndModifySelection:s]; }
- (void)moveToEndOfParagraphAndModifySelection:(id)s { [self moveToRightEndOfLineAndModifySelection:s]; }
- (void)moveParagraphBackwardAndModifySelection:(id)s { [self moveToLeftEndOfLineAndModifySelection:s]; }
- (void)moveParagraphForwardAndModifySelection:(id)s { [self moveToRightEndOfLineAndModifySelection:s]; }
- (void)deleteForwardByDecomposingPreviousCharacter:(id)s { [self deleteForward:s]; }
- (void)deleteBackwardByDecomposingPreviousCharacter:(id)s { [self deleteBackward:s]; }
- (void)deleteWordForward:(id)s {
    NSUInteger p = [self wordBoundary:_caret forward:YES];
    if (p > _caret) [self replaceRange:NSMakeRange(_caret, p - _caret) withString:@"" kind:GroupOther];
}
- (void)deleteToEndOfParagraph:(id)s {                     // ⌃K: to the end of the line, or the line break
    NSUInteger e = self.lineEndOff;
    if (e == _caret) e = [self nextCharOffset:_caret];
    if (e <= _caret) return;
    NSRange r = NSMakeRange(_caret, e - _caret);
    _killed = [[NSString alloc] initWithData:[_buf dataInRange:r] encoding:NSUTF8StringEncoding];
    [self replaceRange:r withString:@"" kind:GroupOther];
}
- (void)deleteToEndOfLine:(id)s { [self deleteToEndOfParagraph:s]; }
- (void)yank:(id)s { if (_killed.length) [self replaceRange:self.selection withString:_killed kind:GroupOther]; }
- (void)insertNewlineIgnoringFieldEditor:(id)s {            // ⌃O: a line break after the caret
    NSUInteger c = _caret;
    [self replaceRange:self.selection withString:_buf.usesCRLF ? @"\r\n" : @"\n" kind:GroupOther];
    [self moveCaretTo:c extend:NO];
}
- (void)transpose:(id)s {                                   // ⌃T: swap the characters around the caret
    if (self.selection.length || _caret == 0) return;
    NSUInteger L = [_buf lineForOffset:_caret], c = _caret;
    if (c >= [_buf lineEnd:L]) c = [self prevCharOffset:c];
    NSUInteger a = [self prevCharOffset:c], b = [self nextCharOffset:c];
    if (a >= c || b <= c || a < [_buf lineStart:L]) return;
    NSString *x = [[NSString alloc] initWithData:[_buf dataInRange:NSMakeRange(a, c - a)] encoding:NSUTF8StringEncoding];
    NSString *y = [[NSString alloc] initWithData:[_buf dataInRange:NSMakeRange(c, b - c)] encoding:NSUTF8StringEncoding];
    if (x && y) [self replaceRange:NSMakeRange(a, b - a) withString:[y stringByAppendingString:x] kind:GroupOther];
}
- (void)centerSelectionInVisibleArea:(id)s {
    CGFloat x = 0;
    NSUInteger row = [self rowOfOffset:_caret x:&x];
    self.scrollY = MAX(0, 4 + row * _lineHeight - self.bounds.size.height / 2);
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

// Tab / Shift-Tab with a selection over several lines indent / outdent each line, as one undo step.
- (BOOL)rewriteSelectedLines:(NSString *(^)(NSString *line))f {
    NSRange sel = self.selection;
    NSUInteger L0 = [_buf lineForOffset:sel.location], L1 = [_buf lineForOffset:MAX(sel.location, NSMaxRange(sel) - (sel.length ? 1 : 0))];
    NSUInteger a = [_buf lineStart:L0], b = [_buf lineEnd:L1];
    NSString *block = [[NSString alloc] initWithData:[_buf dataInRange:NSMakeRange(a, b - a)] encoding:NSUTF8StringEncoding];
    if (!block) return NO;
    NSString *nl = _buf.usesCRLF ? @"\r\n" : @"\n";
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *l in [block componentsSeparatedByString:nl]) [out addObject:f(l)];
    NSString *joined = [out componentsJoinedByString:nl];
    if ([joined isEqualToString:block]) return YES;
    [self replaceRange:NSMakeRange(a, b - a) withString:joined kind:GroupOther];
    _anchor = a;                                               // keep the lines selected for the next Tab
    _coalesceBroken = YES;
    [self notifyChange];
    return YES;
}

static NSString *outdented(NSString *l, NSString *unit) {
    if ([l hasPrefix:@"\t"]) return [l substringFromIndex:1];
    NSUInteger n = 0;
    while (n < l.length && n < MAX(unit.length, (NSUInteger)1) && [l characterAtIndex:n] == ' ') n++;
    if (n == 0 && [unit isEqualToString:@"\t"]) while (n < l.length && n < 4 && [l characterAtIndex:n] == ' ') n++;
    return [l substringFromIndex:n];
}

- (BOOL)selectionSpansLines {
    NSRange sel = self.selection;
    return sel.length && [_buf lineForOffset:sel.location] != [_buf lineForOffset:NSMaxRange(sel) - 1];
}

- (void)insertTab:(id)s {
    NSString *unit = _indentUnit;
    if (self.selectionSpansLines) { [self rewriteSelectedLines:^NSString *(NSString *l) { return l.length ? [unit stringByAppendingString:l] : l; }]; return; }
    [self replaceRange:self.selection withString:_indentUnit kind:GroupTyping];
}

- (void)insertBacktab:(id)s {
    NSString *unit = _indentUnit;
    [self rewriteSelectedLines:^NSString *(NSString *l) { return outdented(l, unit); }];
}
- (void)cancelOperation:(id)s { if (self.selection.length) [self moveCaretTo:_caret extend:NO]; }

#pragma mark NSTextInputClient (ranges are UTF-16 indices within the caret line)

static NSString *plain(id s) { return [s isKindOfClass:NSAttributedString.class] ? [s string] : s; }

// A replacement range (UTF-16, caret line) as a byte range; NSNotFound means the selection.
- (NSRange)bytesForReplacement:(NSRange)rr {
    if (rr.location == NSNotFound) return self.selection;
    NSUInteger L = [_buf lineForOffset:_caret];
    NSUInteger a = [self byteOffsetForUTF16:rr.location inLine:L], b = [self byteOffsetForUTF16:NSMaxRange(rr) inLine:L];
    return NSMakeRange(MIN(a, b), MAX(a, b) - MIN(a, b));
}

- (void)insertText:(id)string replacementRange:(NSRange)rr {
    NSString *s = plain(string);
    BOOL wasMarked = _markedText != nil;
    _markedText = nil;
    if (wasMarked) [self refreshRowsOfLine:[_buf lineForOffset:_caret]];
    if (!s.length && rr.location == NSNotFound) { [self notifyChange]; return; }
    if ([s containsString:@"\n"] || [s containsString:@"\r"]) {        // dictation, services: the file's line endings
        s = [[s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
        if (_buf.usesCRLF) s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
    }
    // press-and-hold accents and reconversion replace text before the caret
    NSRange target = wasMarked ? self.selection : [self bytesForReplacement:rr];
    BOOL single = !wasMarked && rr.location == NSNotFound && s.length <= 2 && ![s containsString:@"\n"];
    [self replaceRange:target withString:s kind:single ? GroupTyping : GroupOther];
    if (!single) _coalesceBroken = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)sel replacementRange:(NSRange)rr {
    NSString *s = plain(string);
    NSRange target = _markedText ? NSMakeRange(NSNotFound, 0) : [self bytesForReplacement:rr];
    if (target.location != NSNotFound && target.length) [self replaceRange:target withString:@"" kind:GroupOther];
    _markedText = s.length ? [s copy] : nil;
    _markedSel = sel;
    [self refreshRowsOfLine:[_buf lineForOffset:_caret]];
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
    CGFloat cx = 0;
    NSUInteger row = [self rowOfOffset:_caret x:&cx];
    CGFloat x = self.textOriginX + cx;
    if (_markedText && r.location != NSNotFound) {
        CTLineRef line = [self createLine:_markedText];
        NSUInteger base = [self utf16Index:_caret inLine:L];
        NSUInteger in = r.location > base ? MIN(r.location - base, _markedText.length) : 0;
        x += CTLineGetOffsetForStringIndex(line, in, NULL);
        CFRelease(line);
    }
    NSRect local = NSMakeRect(x, 4 + row * _lineHeight - self.scrollY, 1, _lineHeight);
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

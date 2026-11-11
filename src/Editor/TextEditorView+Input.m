#import "TextEditorView+Private.h"

@implementation TextEditorView (Input)

#pragma mark Mouse

- (void)canvasMouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self minimapPressAt:p]) return;
    if (_markedText) { [self unmarkText]; [self.inputContext discardMarkedText]; }      // a click commits the composition
    NSEventModifierFlags mods = e.modifierFlags;
    BOOL opt = (mods & NSEventModifierFlagOption) != 0, shift = (mods & NSEventModifierFlagShift) != 0;
    _ignoreDrag = NO;
    _columnDrag = NO;
    [_autoClosed removeAllIndexes];
    if (opt && shift && e.clickCount == 1) {                                        // column selection
        [self rememberCursors];
        [self dropExtraCursors];
        [self beginColumnSelectionAt:p];
        return;
    }
    CGFloat g = self.gutterWidth;
    if (p.x < g && p.x >= g - 18 && e.clickCount == 1) {                           // the fold control
        NSUInteger L = [self lineAtPoint:p];
        if (L != NSNotFound && ([self lineFolded:L] || [self startsRegion:L])) { [self toggleFoldAtLine:L]; return; }
    }
    if (_folds.length && p.x >= g) {                                                  // the ⋯ of a folded line
        NSUInteger L = [self lineAtPoint:p];
        if (L != NSNotFound && [self lineFolded:L] && NSPointInRect(p, [self foldBoxOfLine:L])) { [self toggleFoldAtLine:L]; return; }
    }
    NSUInteger off = [self offsetAtPoint:p];
    _desiredX = -1;
    if (opt && e.clickCount == 1) { [self addCursorAt:off]; return; }              // adds (or removes) a cursor
    if (!opt) { [self dropExtraCursors]; [_cursorHistory removeAllObjects]; }
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
        [self moveCaretTo:off extend:shift];
    }
}

- (NSUInteger)lineAtPoint:(NSPoint)p {
    CGFloat y = p.y + self.scrollY - 4;
    if (y < 0) return NSNotFound;
    NSUInteger row = (NSUInteger)(y / _lineHeight);
    return row < self.rowCount ? [self lineOfRow:row] : NSNotFound;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                 NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)setGutterHover:(BOOL)h { if (h != _gutterHover) { _gutterHover = h; self.needsDisplay = YES; } }
- (void)mouseMoved:(NSEvent *)e { [self setGutterHover:[self convertPoint:e.locationInWindow fromView:nil].x < self.gutterWidth]; }
- (void)mouseExited:(NSEvent *)e { [self setGutterHover:NO]; }

- (void)mouseUp:(NSEvent *)e {
    [_dragScroll invalidate]; _dragScroll = nil;
    if (_mapDragging) { _mapDragging = NO; self.needsDisplay = YES; }
    if (_extra.length && !_columnDrag) {                     // a ⌥ drag may have run into other cursors
        NSUInteger p = 0;
        NSData *c = [self cursors:&p];
        [self setCursors:c.bytes count:c.length / sizeof(Sel) primary:p];
        self.needsDisplay = YES;
    }
    _columnDrag = NO;
    _ignoreDrag = NO;
    [super mouseUp:e];
}

// Dragging a selection above or below the view keeps scrolling while the mouse is held still there.
- (void)dragTo:(NSPoint)p {
    NSRect b = self.bounds;
    CGFloat over = p.y < 0 ? p.y : p.y > b.size.height ? p.y - b.size.height : 0;
    if (over) self.scrollY += (over < 0 ? -1 : 1) * _lineHeight * MIN(5, 1 + fabs(over) / 40);
    NSPoint in = NSMakePoint(p.x, MIN(MAX(p.y, 0), b.size.height - 1));
    if (_columnDrag) [self columnSelectTo:in];
    else {
        _caret = [self offsetAtPoint:in];
        [self scrollCaretVisible];
        [self notifyChange];
    }
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
    if (_ignoreDrag) return;
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
    [self moveCursors:^NSUInteger(Sel *s) {
        if (!ext && s->anchor != s->caret) return fwd ? SelEnd(*s) : SelStart(*s);
        return fwd ? [self nextCharOffset:s->caret] : [self prevCharOffset:s->caret];
    } extend:ext keepColumn:NO];
}

// Moves by visual rows, so wrapped lines are walked row by row.
- (void)vertical:(NSInteger)dir lines:(NSUInteger)count extend:(BOOL)ext {
    NSUInteger rows = self.rowCount, len = _buf.length;
    [self moveCursors:^NSUInteger(Sel *s) {
        CGFloat x = 0;
        NSUInteger row = [self rowOfOffset:s->caret x:&x];
        if (s->x < 0) s->x = x;
        if (dir < 0) return row >= count ? [self offsetInRow:row - count x:s->x] : 0;
        return row + count < rows ? [self offsetInRow:row + count x:s->x] : len;
    } extend:ext keepColumn:YES];
}

- (NSUInteger)pageLines { return MAX(1, (NSUInteger)(self.bounds.size.height / _lineHeight) - 2); }
- (NSUInteger)homeOf:(NSUInteger)off { return [_buf lineStart:[_buf lineForOffset:off]]; }
- (NSUInteger)endOf:(NSUInteger)off { return [_buf lineEnd:[_buf lineForOffset:off]]; }
- (NSUInteger)lineHome { return [self homeOf:_caret]; }
- (NSUInteger)lineEndOff { return [self endOf:_caret]; }
// ⌘←: the first non-blank character, or the start of the line if the caret is already there.
- (NSUInteger)smartHomeOf:(NSUInteger)off {
    NSUInteger L = [_buf lineForOffset:off], fnb = [self firstNonBlankOf:L];
    return off == fnb ? [_buf lineStart:L] : fnb;
}

- (void)toLine:(BOOL)end smart:(BOOL)smart extend:(BOOL)ext {
    [self moveCursors:^NSUInteger(Sel *s) {
        return end ? [self endOf:s->caret] : smart ? [self smartHomeOf:s->caret] : [self homeOf:s->caret];
    } extend:ext keepColumn:NO];
}

- (void)byWord:(BOOL)fwd extend:(BOOL)ext {
    [self moveCursors:^NSUInteger(Sel *s) { return [self wordBoundary:s->caret forward:fwd]; } extend:ext keepColumn:NO];
}

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
- (void)moveWordLeft:(id)s  { [self byWord:NO extend:NO]; }
- (void)moveWordRight:(id)s { [self byWord:YES extend:NO]; }
- (void)moveWordLeftAndModifySelection:(id)s  { [self byWord:NO extend:YES]; }
- (void)moveWordRightAndModifySelection:(id)s { [self byWord:YES extend:YES]; }
- (void)moveToLeftEndOfLine:(id)s  { [self toLine:NO smart:YES extend:NO]; }
- (void)moveToRightEndOfLine:(id)s { [self toLine:YES smart:NO extend:NO]; }
- (void)moveToLeftEndOfLineAndModifySelection:(id)s  { [self toLine:NO smart:YES extend:YES]; }
- (void)moveToRightEndOfLineAndModifySelection:(id)s { [self toLine:YES smart:NO extend:YES]; }
- (void)moveToBeginningOfLine:(id)s { [self moveToLeftEndOfLine:s]; }
- (void)moveToEndOfLine:(id)s { [self moveToRightEndOfLine:s]; }
- (void)moveToBeginningOfLineAndModifySelection:(id)s { [self moveToLeftEndOfLineAndModifySelection:s]; }
- (void)moveToEndOfLineAndModifySelection:(id)s { [self moveToRightEndOfLineAndModifySelection:s]; }
- (void)moveToBeginningOfDocument:(id)s { [self moveCaretTo:0 extend:NO]; }
- (void)moveToEndOfDocument:(id)s { [self moveCaretTo:_buf.length extend:NO]; }
- (void)moveToBeginningOfDocumentAndModifySelection:(id)s { [self moveCaretTo:0 extend:YES]; }
- (void)moveToEndOfDocumentAndModifySelection:(id)s { [self moveCaretTo:_buf.length extend:YES]; }
- (void)scrollToBeginningOfDocument:(id)s { self.scrollY = 0; }
- (void)scrollToEndOfDocument:(id)s { self.scrollY = self.contentHeight; }

#pragma mark Deleting

static BOOL anySelection(TextEditorView *v) {
    NSUInteger p = 0;
    NSData *c = [v cursors:&p];
    const Sel *s = c.bytes;
    for (NSUInteger i = 0; i < c.length / sizeof(Sel); i++) if (s[i].anchor != s[i].caret) return YES;
    return NO;
}

// Each cursor deletes its selection, or the range `f` gives for a caret.
- (void)deleteWith:(NSRange (^)(NSUInteger caret))f kind:(GroupKind)kind {
    BOOL sel = anySelection(self);
    [self editCursors:^NSRange(Sel s, NSString **t, NSInteger *a, NSInteger *c) {
        if (s.anchor != s.caret) return SelRange(s);
        if (sel) return NSMakeRange(NSNotFound, 0);
        NSRange r = f(s.caret);
        return r.length ? r : NSMakeRange(NSNotFound, 0);
    } kind:sel ? GroupOther : kind];
}

// Backspace in the indentation removes spaces back to the previous tab stop.
- (NSUInteger)backspaceStart:(NSUInteger)caret {
    NSUInteger L = [_buf lineForOffset:caret], ls = [_buf lineStart:L];
    if (caret == ls || [_indentUnit isEqualToString:@"\t"]) return [self prevCharOffset:caret];
    for (NSUInteger i = ls; i < caret; i++) if ([_buf byteAt:i] != ' ') return [self prevCharOffset:caret];
    NSUInteger w = MAX(_indentWidth, (NSUInteger)1), col = caret - ls, to = (col - 1) / w * w;
    return ls + to;
}

- (void)deleteBackward:(id)s {
    if ([self autoPairBackspace]) return;
    [self deleteWith:^NSRange(NSUInteger c) {
        if (c == 0) return NSMakeRange(0, 0);
        NSUInteger p = [self backspaceStart:c];
        return NSMakeRange(p, c - p);
    } kind:GroupBackspace];
}

- (void)deleteForward:(id)s {
    [self deleteWith:^NSRange(NSUInteger c) { return NSMakeRange(c, [self nextCharOffset:c] - c); } kind:GroupOther];
}

// Emacs keys that AppKit's standard key bindings send (⌃A ⌃E ⌃K ⌃Y ⌃T ⌃O …).
- (void)moveForward:(id)s  { [self moveRight:s]; }
- (void)moveBackward:(id)s { [self moveLeft:s]; }
- (void)moveForwardAndModifySelection:(id)s  { [self moveRightAndModifySelection:s]; }
- (void)moveBackwardAndModifySelection:(id)s { [self moveLeftAndModifySelection:s]; }
- (void)moveToBeginningOfParagraph:(id)s { [self toLine:NO smart:NO extend:NO]; }       // ⌃A: column 0
- (void)moveToEndOfParagraph:(id)s { [self moveToRightEndOfLine:s]; }
- (void)moveToBeginningOfParagraphAndModifySelection:(id)s { [self toLine:NO smart:NO extend:YES]; }
- (void)moveToEndOfParagraphAndModifySelection:(id)s { [self moveToRightEndOfLineAndModifySelection:s]; }
- (void)moveParagraphBackwardAndModifySelection:(id)s { [self toLine:NO smart:NO extend:YES]; }
- (void)moveParagraphForwardAndModifySelection:(id)s { [self moveToRightEndOfLineAndModifySelection:s]; }
- (void)deleteForwardByDecomposingPreviousCharacter:(id)s { [self deleteForward:s]; }
- (void)deleteBackwardByDecomposingPreviousCharacter:(id)s { [self deleteBackward:s]; }
- (void)deleteWordForward:(id)s {
    [self deleteWith:^NSRange(NSUInteger c) { NSUInteger p = [self wordBoundary:c forward:YES]; return NSMakeRange(c, p > c ? p - c : 0); } kind:GroupOther];
}
- (void)deleteWordBackward:(id)s {
    [self deleteWith:^NSRange(NSUInteger c) { NSUInteger p = [self wordBoundary:c forward:NO]; return NSMakeRange(p, c > p ? c - p : 0); } kind:GroupOther];
}
- (void)deleteToBeginningOfLine:(id)s {                    // ⌘⌫
    [self deleteWith:^NSRange(NSUInteger c) {
        NSUInteger h = [self homeOf:c];
        if (h < c) return NSMakeRange(h, c - h);
        NSUInteger p = [self prevCharOffset:c];
        return NSMakeRange(p, c - p);
    } kind:GroupOther];
}
- (void)deleteToEndOfParagraph:(id)s {                     // ⌃K: to the end of the line, or the line break
    NSRange (^range)(NSUInteger) = ^NSRange(NSUInteger c) {
        NSUInteger e = [self endOf:c];
        if (e == c) e = [self nextCharOffset:c];
        return NSMakeRange(c, e > c ? e - c : 0);
    };
    NSRange k = self.selection.length ? self.selection : range(_caret);
    _killed = [self stringIn:k];
    [self deleteWith:range kind:GroupOther];
}
- (void)deleteToEndOfLine:(id)s { [self deleteToEndOfParagraph:s]; }
- (void)yank:(id)s {
    NSString *k = _killed;
    if (!k.length) return;
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) { *t = k; return SelRange(sel); } kind:GroupOther];
}
- (void)insertNewlineIgnoringFieldEditor:(id)s {            // ⌃O: a line break after the caret
    NSString *nl = self.newline;
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) { *t = nl; *a = 0; *c = 0; return SelRange(sel); } kind:GroupOther];
}
- (void)transpose:(id)s {                                   // ⌃T: swap the characters around the caret
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) {
        if (sel.anchor != sel.caret || sel.caret == 0) return NSMakeRange(NSNotFound, 0);
        NSUInteger L = [self->_buf lineForOffset:sel.caret], at = sel.caret;
        if (at >= [self->_buf lineEnd:L]) at = [self prevCharOffset:at];
        NSUInteger x = [self prevCharOffset:at], y = [self nextCharOffset:at];
        if (x >= at || y <= at || x < [self->_buf lineStart:L]) return NSMakeRange(NSNotFound, 0);
        *t = [[self stringIn:NSMakeRange(at, y - at)] stringByAppendingString:[self stringIn:NSMakeRange(x, at - x)]];
        return NSMakeRange(x, y - x);
    } kind:GroupOther];
}
- (void)centerSelectionInVisibleArea:(id)s {
    CGFloat x = 0;
    NSUInteger row = [self rowOfOffset:_caret x:&x];
    self.scrollY = MAX(0, 4 + row * _lineHeight - self.bounds.size.height / 2);
}

#pragma mark Typing

// Enter keeps the line's indentation, adds a level after an opening bracket (or a Python colon), and
// puts a closing bracket right after the caret on a line of its own.
- (void)insertNewline:(id)s {
    NSString *nl = self.newline, *unit = _indentUnit;
    BOOL colon = [@[@"py", @"pyi", @"pyw"] containsObject:_path.pathExtension.lowercaseString];
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) {
        NSUInteger at = SelStart(sel), L = [self->_buf lineForOffset:at], ls = [self->_buf lineStart:L];
        NSUInteger i = ls;
        while (i < at && ([self->_buf byteAt:i] == ' ' || [self->_buf byteAt:i] == '\t')) i++;
        NSString *indent = [self stringIn:NSMakeRange(ls, i - ls)];
        NSUInteger before = at;
        while (before > ls && ([self->_buf byteAt:before - 1] == ' ' || [self->_buf byteAt:before - 1] == '\t')) before--;
        uint8_t prev = before > ls ? [self->_buf byteAt:before - 1] : 0, next = SelEnd(sel) < self->_buf.length ? [self->_buf byteAt:SelEnd(sel)] : 0;
        BOOL open = prev == '{' || prev == '[' || prev == '(' || (colon && prev == ':');
        BOOL close = (prev == '{' && next == '}') || (prev == '[' && next == ']') || (prev == '(' && next == ')');
        NSString *inner = open ? [indent stringByAppendingString:unit] : indent;
        NSString *text = [nl stringByAppendingString:inner];
        if (close) text = [text stringByAppendingFormat:@"%@%@", nl, indent];
        *t = text;
        NSInteger caret = (NSInteger)[[nl stringByAppendingString:inner] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        *a = caret; *c = caret;
        return SelRange(sel);
    } kind:GroupOther];
    _coalesceBroken = YES;
}

- (NSUInteger)columnOf:(NSUInteger)off {
    NSUInteger ls = [self homeOf:off], col = 0;
    for (NSUInteger i = ls; i < off; i++) {
        uint8_t b = [_buf byteAt:i];
        if (b == '\t') col = (col / 4 + 1) * 4;
        else if ((b & 0xC0) != 0x80) col++;
    }
    return col;
}

- (BOOL)anySelectionSpansLines {
    NSUInteger p = 0;
    NSData *c = [self cursors:&p];
    const Sel *s = c.bytes;
    for (NSUInteger i = 0; i < c.length / sizeof(Sel); i++)
        if (s[i].anchor != s[i].caret && [_buf lineForOffset:SelStart(s[i])] != [_buf lineForOffset:SelEnd(s[i]) - 1]) return YES;
    return NO;
}

- (void)insertTab:(id)s {
    if (self.anySelectionSpansLines) { [self indentLines:s]; return; }
    BOOL spaces = ![_indentUnit isEqualToString:@"\t"];
    NSUInteger w = MAX(_indentWidth, (NSUInteger)1);
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) {
        NSUInteger col = [self columnOf:SelStart(sel)];
        *t = spaces ? [@"        " substringToIndex:w - col % w] : @"\t";
        return SelRange(sel);
    } kind:GroupTyping];
}

- (void)insertBacktab:(id)s { [self outdentLines:s]; }

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
    BOOL single = !wasMarked && rr.location == NSNotFound && s.length <= 2 && ![s containsString:@"\n"];
    // press-and-hold accents and reconversion replace text before the caret (the primary cursor's)
    if (!wasMarked && rr.location != NSNotFound) {
        [self replaceRange:[self bytesForReplacement:rr] withString:s kind:GroupOther];
        _coalesceBroken = YES;
        return;
    }
    if (single && [self autoPairInsert:s]) return;
    [self editCursors:^NSRange(Sel sel, NSString **t, NSInteger *a, NSInteger *c) { *t = s; return SelRange(sel); }
                 kind:single ? GroupTyping : GroupOther];
    if (!single) _coalesceBroken = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)sel replacementRange:(NSRange)rr {
    NSString *s = plain(string);
    if (!_markedText) {
        if (_extra.length) {
            // composing at several cursors: their selections go first; the text is shown at the primary one
            // and inserted at all of them when it is committed
            if (anySelection(self))
                [self editCursors:^NSRange(Sel x, NSString **t, NSInteger *a, NSInteger *c) { return x.anchor != x.caret ? SelRange(x) : NSMakeRange(NSNotFound, 0); } kind:GroupOther];
        } else {
            NSRange target = [self bytesForReplacement:rr];
            if (target.length) [self replaceRange:target withString:@"" kind:GroupOther];
        }
    }
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

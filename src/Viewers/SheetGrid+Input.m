#import "SheetGrid.h"
#import "Localization.h"

@implementation SheetGrid (Input)

#pragma mark Mouse

- (void)canvasMouseDown:(NSEvent *)e {
    [self commitEditing];
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL shift = (e.modifierFlags & NSEventModifierFlagShift) != 0;
    NSUInteger r = 0, c = 0;
    NSUInteger lastR = MAX(_sheet.rowCount, (NSUInteger)1) - 1, lastC = MAX(_sheet.columnCount, (NSUInteger)1) - 1;
    if (p.y < self.headerHeight || p.x < self.headerWidth) {                        // headers select whole columns / rows
        BOOL colHead = p.y < self.headerHeight && p.x >= self.headerWidth, rowHead = p.x < self.headerWidth && p.y >= self.headerHeight;
        if (colHead) [self cellAtPoint:NSMakePoint(p.x, self.headerHeight + 1) row:&r col:&c];
        if (rowHead) [self cellAtPoint:NSMakePoint(self.headerWidth + 1, p.y) row:&r col:&c];
        if (colHead) { if (!shift) _anchorCol = c; _col = c; _anchorRow = 0; _row = lastR; }
        else if (rowHead) { if (!shift) _anchorRow = r; _row = r; _anchorCol = 0; _col = lastC; }
        else { _anchorRow = _anchorCol = 0; _row = lastR; _col = lastC; }              // the corner
        self.needsDisplay = YES;
        if (self.onSelect) self.onSelect();
        return;
    }
    if (![self cellAtPoint:p row:&r col:&c]) return;
    [self selectRow:r col:c extend:shift];
    if (e.clickCount == 2 && !shift) [self beginEditing:nil];
}

- (void)canvasMouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect b = self.bounds;
    if (p.y > NSMaxY(b)) self.scrollY += 20; else if (p.y < self.headerHeight + self.frozenH && self.scrollY > 0) self.scrollY -= 20;
    if (p.x > NSMaxX(b)) self.scrollX += 20; else if (p.x < self.headerWidth + self.frozenW && self.scrollX > 0) self.scrollX -= 20;
    NSPoint q = NSMakePoint(MIN(MAX(p.x, self.headerWidth + 1), NSMaxX(b) - 1), MIN(MAX(p.y, self.headerHeight + 1), NSMaxY(b) - 1));
    NSUInteger r, c;
    if ([self cellAtPoint:q row:&r col:&c]) { _row = r; _col = c; self.needsDisplay = YES; if (self.onSelect) self.onSelect(); }
}

#pragma mark Keys

- (void)keyDown:(NSEvent *)e {
    NSString *ch = e.charactersIgnoringModifiers;
    NSEventModifierFlags m = e.modifierFlags;
    BOOL shift = (m & NSEventModifierFlagShift) != 0, cmd = (m & NSEventModifierFlagCommand) != 0;
    unichar k = ch.length ? [ch characterAtIndex:0] : 0;
    NSUInteger lastR = MAX(_sheet.rowCount, (NSUInteger)1) - 1, lastC = MAX(_sheet.columnCount, (NSUInteger)1) - 1;
    NSUInteger page = MAX((NSUInteger)1, (NSUInteger)(self.bounds.size.height / MAX(1.0, _ry[1] - _ry[0])) - 2);
    switch (k) {
        case NSUpArrowFunctionKey: [self selectRow:cmd ? 0 : (_row ? _row - 1 : 0) col:_col extend:shift]; return;
        case NSDownArrowFunctionKey: [self selectRow:cmd ? lastR : _row + 1 col:_col extend:shift]; return;
        case NSLeftArrowFunctionKey: [self selectRow:_row col:cmd ? 0 : (_col ? _col - 1 : 0) extend:shift]; return;
        case NSRightArrowFunctionKey: [self selectRow:_row col:cmd ? lastC : _col + 1 extend:shift]; return;
        case NSPageUpFunctionKey: [self selectRow:_row > page ? _row - page : 0 col:_col extend:shift]; return;
        case NSPageDownFunctionKey: [self selectRow:_row + page col:_col extend:shift]; return;
        case NSHomeFunctionKey: [self selectRow:cmd ? 0 : _row col:0 extend:shift]; return;
        case NSEndFunctionKey: [self selectRow:cmd ? lastR : _row col:lastC extend:shift]; return;
        case '\t': case 0x19: [self selectRow:_row col:shift || k == 0x19 ? (_col ? _col - 1 : 0) : _col + 1 extend:NO]; return;
        case '\r': case 3: [self selectRow:shift ? (_row ? _row - 1 : 0) : _row + 1 col:_col extend:NO]; return;
        case NSF2FunctionKey: [self beginEditing:nil]; return;
        case 0x7F: case NSDeleteFunctionKey: [self delete:nil]; return;
        case 0x1B: return;
    }
    if (cmd || (m & NSEventModifierFlagControl) || !e.characters.length || (k >= 0xF700 && k <= 0xF8FF)) { [super keyDown:e]; return; }
    if (![self beginEditing:@""]) return;                                          // typing replaces the cell
    NSTextView *tv = (NSTextView *)_field.currentEditor;
    if (![tv.inputContext handleEvent:e]) [tv keyDown:e];                            // through the input method (Chinese, accents …)
}

#pragma mark Editing

- (BOOL)beginEditing:(NSString *)initial {
    if (_field) return YES;
    NSString *why = [_sheet whyReadOnlyAt:_row col:_col];
    if (why) { NSBeep(); if (self.onMessage) self.onMessage(why); return NO; }
    [self scrollToActive];
    NSRect r = NSInsetRect([self rectForRow:_row col:_col], 1, 1);
    r.size.width = MAX(r.size.width, 80);
    _field = [[NSTextField alloc] initWithFrame:r];
    _field.bezeled = NO; _field.bordered = NO; _field.focusRingType = NSFocusRingTypeNone;
    _field.drawsBackground = YES; _field.backgroundColor = NSColor.textBackgroundColor;
    _field.font = [self fontFor:[_sheet styleAt:_row col:_col]];
    _field.stringValue = initial ?: [_sheet editTextAt:_row col:_col];
    _field.delegate = self;
    _field.usesSingleLineMode = NO;
    _field.cell.wraps = NO; _field.cell.scrollable = YES;
    [self addSubview:_field];
    [self.window makeFirstResponder:_field];
    NSText *ed = _field.currentEditor;
    if (initial) [ed setSelectedRange:NSMakeRange(ed.string.length, 0)];
    if (self.onEditingText) self.onEditingText(_field.stringValue);
    return YES;
}

- (void)endField {
    [_field removeFromSuperview];
    _field = nil;
    [self.window makeFirstResponder:self];
    self.needsDisplay = YES;
}

- (void)commitEditing {
    if (!_field || _committing) return;
    _committing = YES;
    NSString *t = _field.stringValue;
    BOOL ok = !self.onEdit || self.onEdit(_row, _col, t);
    if (ok) [self endField];
    _committing = NO;
    if (ok && self.onSelect) self.onSelect();
}

- (void)cancelEditing {
    if (!_field) return;
    [self endField];
    if (self.onSelect) self.onSelect();
}

- (void)controlTextDidChange:(NSNotification *)n { if (self.onEditingText) self.onEditingText(_field.stringValue); }
- (void)controlTextDidEndEditing:(NSNotification *)n { if (_field && !_committing) [self commitEditing]; }

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(insertNewline:)) { [self commitEditing]; if (!_field) [self selectRow:_row + 1 col:_col extend:NO]; return YES; }
    if (sel == @selector(insertTab:)) { [self commitEditing]; if (!_field) [self selectRow:_row col:_col + 1 extend:NO]; return YES; }
    if (sel == @selector(insertBacktab:)) { [self commitEditing]; if (!_field) [self selectRow:_row col:_col ? _col - 1 : 0 extend:NO]; return YES; }
    if (sel == @selector(cancelOperation:)) { [self cancelEditing]; return YES; }
    if (sel == @selector(insertNewlineIgnoringFieldEditor:)) { [tv insertText:@"\n" replacementRange:tv.selectedRange]; return YES; }   // ⌥↩: a line break in the cell
    return NO;
}

#pragma mark Clipboard

- (NSPasteboard *)pb { return self.pasteboard ?: NSPasteboard.generalPasteboard; }

- (void)copy:(id)sender {
    XLRange s = self.selection;
    if ((s.lastRow - s.row + 1) * (s.lastCol - s.col + 1) > 2000000) { NSBeep(); return; }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger r = s.row; r <= s.lastRow; r++) {
        for (NSUInteger c = s.col; c <= s.lastCol; c++) {
            if (c > s.col) [out appendString:@"\t"];
            [out appendString:[[[_sheet displayAt:r col:c colour:NULL] stringByReplacingOccurrencesOfString:@"\t" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        }
        [out appendString:@"\n"];
    }
    [self.pb clearContents];
    [self.pb setString:out forType:NSPasteboardTypeString];
}

- (void)paste:(id)sender {
    NSString *s = [self.pb stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    if ([s hasSuffix:@"\n"]) s = [s substringToIndex:s.length - 1];
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    if (lines.count * 16 > 200000) { NSBeep(); return; }
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSArray *cells = [lines[i] componentsSeparatedByString:@"\t"];
        for (NSUInteger j = 0; j < cells.count; j++)
            if (self.onEdit && !self.onEdit(_row + i, _col + j, cells[j])) { [self invalidate]; return; }
    }
    _anchorRow = _row; _anchorCol = _col;
    _row += lines.count - 1; _col += [lines.lastObject componentsSeparatedByString:@"\t"].count - 1;
    [self invalidate];
    if (self.onSelect) self.onSelect();
}

- (void)delete:(id)sender {
    XLRange s = self.selection;
    if ((s.lastRow - s.row + 1) * (s.lastCol - s.col + 1) > 1000000) { NSBeep(); return; }
    for (NSUInteger r = s.row; r <= s.lastRow; r++)
        for (NSUInteger c = s.col; c <= s.lastCol; c++)
            if ([_sheet editTextAt:r col:c].length && self.onEdit && !self.onEdit(r, c, @"")) { [self invalidate]; return; }
    [self invalidate];
    if (self.onSelect) self.onSelect();
}

- (void)selectAll:(id)sender {
    _anchorRow = _anchorCol = 0;
    _row = MAX(_sheet.rowCount, (NSUInteger)1) - 1; _col = MAX(_sheet.columnCount, (NSUInteger)1) - 1;
    self.needsDisplay = YES;
    if (self.onSelect) self.onSelect();
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(paste:) || a == @selector(delete:)) return !_sheet.readOnlyReason;
    return [self respondsToSelector:a];
}

@end

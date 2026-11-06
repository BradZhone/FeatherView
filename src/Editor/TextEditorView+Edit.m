#import "TextEditorView+Private.h"
#import "Localization.h"
#include <sys/stat.h>

@implementation TextEditorView (Edit)

- (NSRange)selection {
    NSUInteger a = MIN(_caret, _anchor), b = MAX(_caret, _anchor);
    return NSMakeRange(a, b - a);
}

- (void)notifyChange {
    self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}

- (void)moveCaretTo:(NSUInteger)off extend:(BOOL)extend {
    _caret = MIN(off, _buf.length);
    if (!extend) _anchor = _caret;
    _coalesceBroken = YES;
    [self scrollCaretVisible];
    [self notifyChange];
}

- (void)applyOp:(EditOp *)op inverse:(BOOL)inv {
    BOOL ins = op.isInsert != inv;
    [self beginEdit:NSMakeRange(op.offset, ins ? 0 : op.bytes.length)];
    if (ins) [_buf insertBytes:op.bytes.bytes length:op.bytes.length at:op.offset];
    else [_buf deleteRange:NSMakeRange(op.offset, op.bytes.length)];
    [self endEdit];
    _editCount++;
}

// Undo / redo of a group; big groups (replace all) rebuild the wrap table once.
- (void)applyGroup:(EditGroup *)g inverse:(BOOL)inv {
    BOOL bulk = g.ops.count > 64;
    CGFloat top = bulk ? [self beginBulkEdit] : 0;
    for (EditOp *op in (inv ? g.ops.reverseObjectEnumerator : g.ops.objectEnumerator)) [self applyOp:op inverse:inv];
    if (bulk) [self endBulkEdit:top];
}

- (void)replaceRange:(NSRange)r withString:(NSString *)s kind:(GroupKind)kind {
    NSData *ins = [s dataUsingEncoding:NSUTF8StringEncoding];
    EditGroup *g = _undo.lastObject;
    BOOL coalesce = !_coalesceBroken && g && g.kind == kind && kind != GroupOther && g.caretAfter == _caret &&
                    ((kind == GroupTyping && r.length == 0 && r.location == _caret) ||
                     (kind == GroupBackspace && NSMaxRange(r) == _caret && !ins.length));
    if (!coalesce) {
        g = [EditGroup new];
        g.ops = [NSMutableArray array];
        g.caretBefore = _caret;
        g.kind = kind;
        g.serial = ++_serial;
        [_undo addObject:g];
        if (_undo.count > 2000) [_undo removeObjectAtIndex:0];
    }
    [_redo removeAllObjects];
    [self beginEdit:r];
    if (r.length) {
        EditOp *d = [EditOp new];
        d.isInsert = NO; d.offset = r.location; d.bytes = [_buf dataInRange:r];
        [_buf deleteRange:r];
        [g.ops addObject:d];
    }
    if (ins.length) {
        EditOp *i = [EditOp new];
        i.isInsert = YES; i.offset = r.location; i.bytes = ins;
        [_buf insertBytes:ins.bytes length:ins.length at:r.location];
        [g.ops addObject:i];
    }
    [self endEdit];
    _caret = _anchor = r.location + ins.length;
    g.caretAfter = _caret;
    _coalesceBroken = NO;
    if (r.length || ins.length) _editCount++;
    _desiredX = -1;
    [self scrollCaretVisible];
    [self notifyChange];
}

- (void)undo:(id)sender {
    EditGroup *g = _undo.lastObject;
    if (!g) { NSBeep(); return; }
    [_undo removeLastObject];
    [self applyGroup:g inverse:YES];
    [_redo addObject:g];
    _caret = _anchor = MIN(g.caretBefore, _buf.length);
    _coalesceBroken = YES;
    [self scrollCaretVisible];
    [self notifyChange];
}

- (void)redo:(id)sender {
    EditGroup *g = _redo.lastObject;
    if (!g) { NSBeep(); return; }
    [_redo removeLastObject];
    [self applyGroup:g inverse:NO];
    [_undo addObject:g];
    _caret = _anchor = MIN(g.caretAfter, _buf.length);
    _coalesceBroken = YES;
    [self scrollCaretVisible];
    [self notifyChange];
}

- (NSString *)selectedString {
    NSRange r = self.selection;
    return r.length ? [[NSString alloc] initWithData:[_buf dataInRange:r] encoding:NSUTF8StringEncoding] : nil;
}

- (void)copy:(id)sender {
    NSString *s = self.selectedString;
    if (!s) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:s forType:NSPasteboardTypeString];
}

- (void)cut:(id)sender {
    if (!self.selection.length) return;
    [self copy:sender];
    [self replaceRange:self.selection withString:@"" kind:GroupOther];
}

- (void)paste:(id)sender {
    NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!s.length) return;
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    if (_buf.usesCRLF) s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"];
    [self replaceRange:self.selection withString:s kind:GroupOther];
}

- (void)selectAll:(id)sender {
    _anchor = 0; _caret = _buf.length;
    [self notifyChange];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(undo:)) return _undo.count > 0;
    if (a == @selector(redo:)) return _redo.count > 0;
    if (a == @selector(copy:) || a == @selector(cut:)) return self.selection.length > 0;
    return YES;
}

@end

@implementation TextEditorView (Document)

- (BOOL)findString:(NSString *)s backward:(BOOL)back {
    NSData *n = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!n.length) return NO;
    NSRange sel = self.selection;
    NSUInteger from = back ? sel.location : (sel.length ? sel.location + 1 : _caret);
    NSUInteger hit = [_buf find:n from:from backward:back];
    if (hit == NSNotFound) { NSBeep(); return NO; }
    _anchor = hit; _caret = hit + n.length;
    _coalesceBroken = YES;
    [self scrollCaretVisible];
    [self notifyChange];
    return YES;
}

- (void)gotoLine:(NSUInteger)line {
    line = MIN(MAX(line, 1), _buf.lineCount) - 1;
    [self moveCaretTo:[_buf lineStart:line] extend:NO];
    self.scrollY = MAX(0, [self yForLine:line] - self.bounds.size.height / 3);
}

- (BOOL)save:(NSString **)error {
    NSString *real = _path.stringByResolvingSymlinksInPath;
    NSString *tmpl = [real.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".feather-XXXXXX"];
    char tmp[PATH_MAX];
    strlcpy(tmp, tmpl.fileSystemRepresentation, sizeof tmp);
    int fd = mkstemp(tmp);
    if (fd < 0) { if (error) *error = FTL(@"Couldn’t create a temporary file in this folder"); return NO; }

    BOOL ok;
    if (_encoding == NSUTF8StringEncoding) {
        ok = [_buf writeToFD:fd];
    } else {
        NSData *u8 = [_buf dataInRange:NSMakeRange(0, _buf.length)];
        NSString *s = [[NSString alloc] initWithData:u8 encoding:NSUTF8StringEncoding];
        NSData *out = [s dataUsingEncoding:_encoding allowLossyConversion:NO];
        ok = out && write(fd, out.bytes, out.length) == (ssize_t)out.length;
        if (!out && error) *error = FTL(@"The text can’t be saved in its original encoding");
    }
    struct stat st;
    if (ok && stat(real.fileSystemRepresentation, &st) == 0) fchmod(fd, st.st_mode & 07777);
    ok = ok && fsync(fd) == 0;
    close(fd);
    // rename keeps the old inode alive, so the current mmap stays valid
    if (!ok || rename(tmp, real.fileSystemRepresentation) != 0) {
        unlink(tmp);
        if (error && !*error) *error = FTL(@"Write failed");
        return NO;
    }
    _savedSerial = _undo.count ? _undo.lastObject.serial : 0;
    _coalesceBroken = YES;
    [self notifyChange];
    return YES;
}

@end

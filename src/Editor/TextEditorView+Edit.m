#import "TextEditorView+Private.h"
#import "Localization.h"
#include <sys/stat.h>
#include <copyfile.h>
#include <fcntl.h>
#import "FileKind.h"

@implementation TextEditorView (Edit)

- (NSRange)selection {
    NSUInteger a = MIN(_caret, _anchor), b = MAX(_caret, _anchor);
    return NSMakeRange(a, b - a);
}

- (PTUnicodeIndex *)unicodeIndexFor:(NSString *)needle {
    if (![PTUnicodeIndex needsUnicode:needle]) return nil;
    if (!_uindex || _uindexEdit != _editCount) { _uindex = [[PTUnicodeIndex alloc] initWithTable:_buf]; _uindexEdit = _editCount; }
    return _uindex;
}

- (void)notifyChange {
    self.needsDisplay = YES;
    if (self.onChange) self.onChange();
    if (NSWorkspace.sharedWorkspace.isVoiceOverEnabled) {
        NSAccessibilityPostNotification(self, NSAccessibilitySelectedTextChangedNotification);
        if (_editCount != _axEdit) { _axEdit = _editCount; NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification); }
    }
}

- (void)moveCaretTo:(NSUInteger)off extend:(BOOL)extend {
    _caret = MIN(off, _buf.length);
    _desiredX = -1;                                            // vertical moves set it again afterwards
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
    if (g.swapBuffer) {
        CGFloat top = [self beginBulkEdit];
        PieceTable *other = g.swapBuffer;
        g.swapBuffer = _buf;
        _buf = other;
        _editCount++;
        [self endBulkEdit:top];
        return;
    }
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
        [self pushUndo:g];
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

// The oldest group is dropped past the limit. The saved state is "the serial on top of the stack", so it
// must stay reachable or unreachable as before: saved with an empty stack is now unreachable, and saved
// right after the dropped group is now the empty stack.
- (void)pushUndo:(EditGroup *)g {
    [_undo addObject:g];
    if (_undo.count <= 2000) return;
    EditGroup *dropped = _undo.firstObject;
    [_undo removeObjectAtIndex:0];
    if (_savedSerial == 0) _savedSerial = NSUIntegerMax;
    else if (_savedSerial == dropped.serial) _savedSerial = 0;
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
    PTUnicodeIndex *ui = [self unicodeIndexFor:s];
    NSRange hit = ui ? [ui find:s from:from backward:back] : NSMakeRange([_buf find:n from:from backward:back], n.length);
    if (hit.location == NSNotFound) { NSBeep(); return NO; }
    _anchor = hit.location; _caret = NSMaxRange(hit);
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

// The bytes as they go to disk: UTF-8 as is, other encodings converted (UTF-16 with its BOM, in its byte order).
- (NSData *)encodedContents:(NSString **)error {
    if (_encoding == NSUTF8StringEncoding) return nil;          // written straight from the buffer
    NSData *u8 = [_buf dataInRange:NSMakeRange(0, _buf.length)];
    NSString *s = [[NSString alloc] initWithData:u8 encoding:NSUTF8StringEncoding];
    NSMutableData *out = [NSMutableData data];
    if (_encoding == NSUTF16BigEndianStringEncoding) [out appendBytes:"\xFE\xFF" length:2];
    if (_encoding == NSUTF16LittleEndianStringEncoding) [out appendBytes:"\xFF\xFE" length:2];
    NSData *body = [s dataUsingEncoding:_encoding allowLossyConversion:NO];
    if (!body) { if (error) *error = FTL(@"The text can’t be saved in its original encoding"); return nil; }
    [out appendData:body];
    return out;
}

static BOOL writeAll(int fd, const void *p, size_t n) {
    const uint8_t *b = p;
    while (n) {
        ssize_t w = write(fd, b, n);
        if (w < 0) { if (errno == EINTR) continue; return NO; }
        b += w; n -= (size_t)w;
    }
    return YES;
}

- (BOOL)save:(NSString **)error {
    NSString *real = _path.stringByResolvingSymlinksInPath;
    // The file is replaced by a rename, which only needs a writable folder: check the file itself first.
    if (access(real.fileSystemRepresentation, W_OK) != 0 && errno != ENOENT) {
        if (error) *error = errno == EROFS ? FTL(@"The disk is read-only") : FTL(@"The file is read-only");
        return NO;
    }
    NSString *encErr = nil;
    NSData *encoded = [self encodedContents:&encErr];
    if (encErr) { if (error) *error = encErr; return NO; }

    struct stat st;
    BOOL exists = stat(real.fileSystemRepresentation, &st) == 0;
    // A file with other hard links must be written in place, or they would keep the old text. In place
    // means truncating the file, so only when this buffer isn't a mapping of it (small files are read).
    BOOL inPlace = exists && st.st_nlink > 1 && !FKIsMappedSize((unsigned long long)st.st_size);
    NSString *tmpl = [real.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".feather-XXXXXX"];
    char tmp[PATH_MAX];
    strlcpy(tmp, tmpl.fileSystemRepresentation, sizeof tmp);
    int fd = inPlace ? -1 : mkstemp(tmp);
    if (fd < 0 && !inPlace && exists && errno == EACCES && !FKIsMappedSize((unsigned long long)st.st_size))
        inPlace = YES;                                          // writable file in a folder we can't create files in
    if (inPlace) {
        NSData *all = encoded ?: [_buf dataInRange:NSMakeRange(0, _buf.length)];
        fd = open(real.fileSystemRepresentation, O_WRONLY | O_TRUNC);
        if (fd < 0) { if (error) *error = FTL(@"Write failed"); return NO; }
        BOOL ok = writeAll(fd, all.bytes, all.length) && fsync(fd) == 0;
        close(fd);
        if (!ok) { if (error) *error = FTL(@"Write failed"); return NO; }
    } else {
        if (fd < 0) { if (error) *error = FTL(@"Couldn’t create a temporary file in this folder"); return NO; }
        BOOL ok = encoded ? writeAll(fd, encoded.bytes, encoded.length) : [_buf writeToFD:fd];
        if (ok && exists) {
            fchmod(fd, st.st_mode & 07777);
            // Finder tags, quarantine, ACLs and the like belong to the file, so the new copy gets them too.
            copyfile_state_t cs = copyfile_state_alloc();
            int from = open(real.fileSystemRepresentation, O_RDONLY);
            if (from >= 0) { fcopyfile(from, fd, cs, COPYFILE_XATTR | COPYFILE_ACL); close(from); }
            copyfile_state_free(cs);
        }
        ok = ok && fsync(fd) == 0;
        close(fd);
        // rename keeps the old inode alive, so the current mmap stays valid
        if (!ok || rename(tmp, real.fileSystemRepresentation) != 0) {
            unlink(tmp);
            if (error && !*error) *error = FTL(@"Write failed");
            return NO;
        }
    }
    _savedSerial = _undo.count ? _undo.lastObject.serial : 0;
    _coalesceBroken = YES;
    [self notifyChange];
    return YES;
}
@end

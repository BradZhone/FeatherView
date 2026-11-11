#import "TextEditorView+Private.h"
#import "Localization.h"
#include <sys/stat.h>
#include <copyfile.h>
#include <fcntl.h>
#import "FileKind.h"


@implementation EditBatch @end
@implementation EditGroup @end

@implementation EditList {
    NSMutableData *_ranges;                 // NSRange[]
    NSMutableArray<NSData *> *_data;
    NSMutableData *_shift;                  // NSInteger[]: total length change of the items before i
    BOOL _shiftValid;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _ranges = [NSMutableData data];
    _data = [NSMutableArray array];
    return self;
}

- (NSUInteger)count { return _data.count; }
- (NSRange)rangeAt:(NSUInteger)i { return ((const NSRange *)_ranges.bytes)[i]; }
- (NSData *)dataAt:(NSUInteger)i { return _data[i]; }

- (NSUInteger)replace:(NSRange)r with:(NSString *)s {
    return [self replace:r withData:[s dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]];
}

- (NSUInteger)replace:(NSRange)r withData:(NSData *)d {
    _shiftValid = NO;
    NSMutableData *text = [d mutableCopy];
    // an earlier item this one overlaps (or that ends inside it) becomes part of it
    while (_data.count) {
        NSRange p = [self rangeAt:_data.count - 1];
        BOOL overlaps = r.location < NSMaxRange(p) || (r.location < p.location) ||
                        (r.location == p.location && r.length && p.length);
        if (!overlaps) break;
        NSUInteger a = MIN(p.location, r.location), b = MAX(NSMaxRange(p), NSMaxRange(r));
        NSMutableData *joined = [_data.lastObject mutableCopy];
        [joined appendData:text];
        text = joined;
        r = NSMakeRange(a, b - a);
        [_data removeLastObject];
        _ranges.length -= sizeof(NSRange);
    }
    [_ranges appendBytes:&r length:sizeof r];
    [_data addObject:text];
    return _data.count - 1;
}

- (const NSInteger *)shifts {
    if (!_shiftValid) {
        NSUInteger n = _data.count;
        _shift = [NSMutableData dataWithLength:(n + 1) * sizeof(NSInteger)];
        NSInteger *sh = _shift.mutableBytes, acc = 0;
        const NSRange *rs = _ranges.bytes;
        for (NSUInteger i = 0; i < n; i++) { sh[i] = acc; acc += (NSInteger)_data[i].length - (NSInteger)rs[i].length; }
        sh[n] = acc;
        _shiftValid = YES;
    }
    return _shift.bytes;
}

- (NSUInteger)newStartOf:(NSUInteger)i { return (NSUInteger)((NSInteger)[self rangeAt:i].location + [self shifts][i]); }

- (NSUInteger)map:(NSUInteger)off right:(BOOL)right {
    NSUInteger n = _data.count;
    const NSRange *rs = _ranges.bytes;
    const NSInteger *sh = [self shifts];
    // first item that doesn't end before off
    NSUInteger lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi) / 2; if (NSMaxRange(rs[mid]) < off) lo = mid + 1; else hi = mid; }
    for (NSUInteger i = lo; i < n; i++) {
        NSRange r = rs[i];
        NSUInteger start = (NSUInteger)((NSInteger)r.location + sh[i]), end = start + _data[i].length;
        if (off < r.location) return (NSUInteger)((NSInteger)off + sh[i]);
        if (off > r.location && off < NSMaxRange(r)) return start;            // inside a replaced range
        if (off == r.location && off == NSMaxRange(r)) {                     // an insertion here
            if (!right) return start;
            continue;
        }
        if (off == r.location) return start;                                  // a replacement starts here
        if (right && i + 1 < n && rs[i + 1].location == off) continue;        // at its end, and another starts
        return end;
    }
    return (NSUInteger)((NSInteger)off + sh[n]);
}

@end

@implementation TextEditorView (Edit)

- (NSRange)selection {
    NSUInteger a = MIN(_caret, _anchor), b = MAX(_caret, _anchor);
    return NSMakeRange(a, b - a);
}

- (NSString *)stringIn:(NSRange)r {
    return [[NSString alloc] initWithData:[_buf dataInRange:r] encoding:NSUTF8StringEncoding] ?: @"";
}

- (NSString *)newline { return _buf.usesCRLF ? @"\r\n" : @"\n"; }

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
    [self dropExtraCursors];
    _caret = MIN(off, _buf.length);
    _desiredX = -1;                                            // vertical moves set it again afterwards
    if (!extend) _anchor = _caret;
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [self scrollCaretVisible];
    [self notifyChange];
}

#pragma mark Applying edits

// The batch as replacements of the current text: forward, or undoing it (the text it produced back).
- (void)applyBatch:(EditBatch *)b inverse:(BOOL)inv {
    NSUInteger n = b.edits.length / sizeof(BatchEdit);
    const BatchEdit *e = b.edits.bytes;
    const uint8_t *rem = b.removed.bytes, *ins = b.inserted.bytes;
    PTEdit *pe = malloc(MAX(n, (NSUInteger)1) * sizeof(PTEdit));
    NSUInteger ro = 0, io = 0;
    NSInteger delta = 0;
    for (NSUInteger k = 0; k < n; k++) {
        if (inv) pe[k] = (PTEdit){(NSUInteger)((NSInteger)e[k].location + delta), e[k].inserted, rem + ro, e[k].removed};
        else pe[k] = (PTEdit){e[k].location, e[k].removed, ins + io, e[k].inserted};
        if (inv) delta += (NSInteger)e[k].inserted - (NSInteger)e[k].removed;
        ro += e[k].removed; io += e[k].inserted;
    }
    [self applyBufferEdits:pe count:n];
    free(pe);
}

- (void)applyBufferEdits:(const PTEdit *)pe count:(NSUInteger)n {
    if (!n) return;
    [self prepareFoldsForEdits:pe count:n];
    if (n == 1) {
        [self beginEdit:NSMakeRange(pe[0].location, pe[0].removed)];
        [_buf applyEdits:pe count:1];
        [self endEdit];
    } else {
        [self wrapApplyEdits:pe count:n];
    }
    _editCount++;
}

// Undo / redo of a group; Replace All swaps the whole buffer.
- (void)applyGroup:(EditGroup *)g inverse:(BOOL)inv {
    if (g.swapBuffer) {
        [self clearFolds];
        CGFloat top = [self beginBulkEdit];
        PieceTable *other = g.swapBuffer;
        g.swapBuffer = _buf;
        _buf = other;
        _editCount++;
        [self endBulkEdit:top];
        return;
    }
    [self applyBatch:g.batch inverse:inv];
}

static BOOL sameCursors(NSData *a, NSUInteger pa, NSData *b, NSUInteger pb) {
    if (a.length != b.length || pa != pb) return NO;
    const Sel *x = a.bytes, *y = b.bytes;
    for (NSUInteger i = 0; i < a.length / sizeof(Sel); i++) if (x[i].anchor != y[i].anchor || x[i].caret != y[i].caret) return NO;
    return YES;
}

// Typing / backspacing at the same cursors as the last batch continues it: each new edit must start
// where that edit's text ends (it may eat back into it, or past it into the text before).
static BOOL mergeInto(EditBatch *p, EditBatch *b) {
    NSUInteger n = p.edits.length / sizeof(BatchEdit);
    if (b.edits.length != p.edits.length) return NO;
    const BatchEdit *pe = p.edits.bytes, *ne = b.edits.bytes;
    NSMutableData *edits = [NSMutableData dataWithLength:p.edits.length];
    BatchEdit *out = edits.mutableBytes;
    NSMutableData *removed = [NSMutableData data], *inserted = [NSMutableData data];
    const uint8_t *prem = p.removed.bytes, *pins = p.inserted.bytes, *nrem = b.removed.bytes, *nins = b.inserted.bytes;
    NSUInteger pro = 0, pio = 0, nro = 0, nio = 0, prevEnd = 0;     // prevEnd: in the old text
    NSInteger shift = 0;                                            // p's length change before edit k
    for (NSUInteger k = 0; k < n; k++) {
        NSUInteger P = (NSUInteger)((NSInteger)pe[k].location + shift);   // where edit k's text starts now
        NSUInteger end = P + pe[k].inserted;
        if (ne[k].location + ne[k].removed != end) return NO;
        if (ne[k].removed && ne[k].inserted) return NO;
        NSUInteger eat = ne[k].removed, keep = pe[k].inserted, extra = 0;
        if (eat > keep) { extra = eat - keep; keep = 0; } else keep -= eat;
        if (extra > pe[k].location || pe[k].location - extra < prevEnd) return NO;
        BatchEdit m = {pe[k].location - extra, pe[k].removed + extra, keep + ne[k].inserted};
        out[k] = m;
        // removed: the bytes the new edit took from before p's text, then p's own
        if (extra) [removed appendBytes:nrem + nro length:extra];
        [removed appendBytes:prem + pro length:pe[k].removed];
        [inserted appendBytes:pins + pio length:keep];
        [inserted appendBytes:nins + nio length:ne[k].inserted];
        prevEnd = m.location + m.removed;
        shift += (NSInteger)pe[k].inserted - (NSInteger)pe[k].removed;
        pro += pe[k].removed; pio += pe[k].inserted; nro += ne[k].removed; nio += ne[k].inserted;
    }
    p.edits = edits; p.removed = removed; p.inserted = inserted;
    return YES;
}

- (void)commit:(EditList *)edits selections:(const Sel *)after count:(NSUInteger)na primary:(NSUInteger)pa kind:(GroupKind)kind {
    NSUInteger pb = 0;
    NSMutableData *before = [self cursors:&pb];
    NSMutableData *mapped = nil;
    if (!after) {
        NSUInteger n = before.length / sizeof(Sel);
        mapped = [NSMutableData dataWithLength:before.length];
        const Sel *b = before.bytes;
        Sel *m = mapped.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            if (b[i].anchor == b[i].caret) { NSUInteger c = [edits map:b[i].caret right:YES]; m[i] = SelMake(c, c); continue; }
            BOOL fwd = b[i].caret > b[i].anchor;
            NSUInteger s0 = [edits map:SelStart(b[i]) right:NO], s1 = [edits map:SelEnd(b[i]) right:YES];
            m[i] = fwd ? SelMake(s0, s1) : SelMake(s1, s0);
        }
        after = mapped.bytes; na = n; pa = pb;
    }

    // the edits that change something, in the buffer's terms
    EditBatch *batch = [EditBatch new];
    batch.edits = [NSMutableData data]; batch.removed = [NSMutableData data]; batch.inserted = [NSMutableData data];
    NSUInteger n = edits.count;
    PTEdit *pe = malloc(MAX(n, (NSUInteger)1) * sizeof(PTEdit));
    NSUInteger k = 0;
    for (NSUInteger i = 0; i < n; i++) {
        NSRange r = [edits rangeAt:i];
        NSData *d = [edits dataAt:i];
        if (NSMaxRange(r) > _buf.length) r = NSIntersectionRange(r, NSMakeRange(0, _buf.length));
        if (!r.length && !d.length) continue;
        NSData *old = r.length ? [_buf dataInRange:r] : nil;
        if (old && [old isEqualToData:d]) continue;
        BatchEdit be = {r.location, r.length, d.length};
        [batch.edits appendBytes:&be length:sizeof be];
        if (old) [batch.removed appendData:old];
        [batch.inserted appendData:d];
        pe[k++] = (PTEdit){r.location, r.length, d.bytes, d.length};
    }
    if (!k) {
        free(pe);
        [self setCursors:after count:na primary:pa];
        _coalesceBroken = YES;
        [self cursorsChanged];
        return;
    }

    EditGroup *g = _undo.lastObject;
    BOOL coalesce = !_coalesceBroken && g && !g.swapBuffer && g.kind == kind && kind != GroupOther &&
                    sameCursors(g.selsAfter, g.primaryAfter, before, pb) && mergeInto(g.batch, batch);
    if (!coalesce) {
        g = [EditGroup new];
        g.batch = batch;
        g.selsBefore = before;
        g.primaryBefore = pb;
        g.kind = kind;
        g.serial = ++_serial;
        [self pushUndo:g];
    }
    [_redo removeAllObjects];
    [self applyBufferEdits:pe count:k];
    free(pe);
    [self shiftAutoClosed:edits];
    [self setCursors:after count:na primary:pa];
    NSUInteger pNow = 0;
    g.selsAfter = [self cursors:&pNow];
    g.primaryAfter = pNow;
    _coalesceBroken = NO;
    _desiredX = -1;
    [_cursorHistory removeAllObjects];
    [self cursorsChanged];
}

- (void)replaceRange:(NSRange)r withString:(NSString *)s kind:(GroupKind)kind {
    [self dropExtraCursors];
    EditList *e = [EditList new];
    [e replace:r with:s];
    NSUInteger c = r.location + [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    Sel after = SelMake(c, c);
    [self commit:e selections:&after count:1 primary:0 kind:kind];
}

- (void)editCursors:(CursorEdit)f kind:(GroupKind)kind {
    NSUInteger primary = 0;
    NSMutableData *cur = [self cursors:&primary];
    NSUInteger n = cur.length / sizeof(Sel);
    const Sel *c = cur.bytes;
    EditList *e = [EditList new];
    // per cursor: the item it edited (or NSNotFound) and its new selection relative to that item's start
    NSMutableData *meta = [NSMutableData dataWithLength:n * 3 * sizeof(NSInteger)];
    NSInteger *m = meta.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        NSString *text = @"";
        NSInteger a = NSIntegerMin, b = NSIntegerMin;
        NSRange r = f(c[i], &text, &a, &b);
        if (r.location == NSNotFound) { m[3 * i] = -1; continue; }
        NSUInteger len = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        NSUInteger before = e.count;
        NSUInteger item = [e replace:r with:text];
        // merged into an earlier item: the selection goes after this text, at the item's end
        NSInteger base = 0;
        if (e.count <= before) base = (NSInteger)([e dataAt:item].length - len);
        if (a == NSIntegerMin) a = (NSInteger)len;
        if (b == NSIntegerMin) b = a;
        m[3 * i] = (NSInteger)item; m[3 * i + 1] = base + a; m[3 * i + 2] = base + b;
    }
    NSMutableData *after = [NSMutableData dataWithLength:n * sizeof(Sel)];
    Sel *s = after.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        if (m[3 * i] < 0) {
            BOOL fwd = c[i].caret >= c[i].anchor;
            NSUInteger s0 = [e map:SelStart(c[i]) right:NO], s1 = [e map:SelEnd(c[i]) right:c[i].anchor != c[i].caret];
            s[i] = fwd ? SelMake(s0, s1) : SelMake(s1, s0);
            continue;
        }
        NSUInteger start = [e newStartOf:(NSUInteger)m[3 * i]];
        s[i] = SelMake((NSUInteger)MAX(0, (NSInteger)start + m[3 * i + 1]), (NSUInteger)MAX(0, (NSInteger)start + m[3 * i + 2]));
    }
    [self commit:e selections:s count:n primary:primary kind:kind];
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

- (void)restoreCursors:(NSData *)sels primary:(NSUInteger)p {
    [self setCursors:sels.bytes count:sels.length / sizeof(Sel) primary:p];
    _coalesceBroken = YES;
    [_autoClosed removeAllIndexes];
    [_cursorHistory removeAllObjects];
    [self cursorsChanged];
}

- (void)undo:(id)sender {
    EditGroup *g = _undo.lastObject;
    if (!g) { NSBeep(); return; }
    [_undo removeLastObject];
    [self applyGroup:g inverse:YES];
    [_redo addObject:g];
    [self restoreCursors:g.selsBefore primary:g.primaryBefore];
}

- (void)redo:(id)sender {
    EditGroup *g = _redo.lastObject;
    if (!g) { NSBeep(); return; }
    [_redo removeLastObject];
    [self applyGroup:g inverse:NO];
    [_undo addObject:g];
    [self restoreCursors:g.selsAfter primary:g.primaryAfter];
}

- (NSString *)selectedString {
    NSRange r = self.selection;
    return r.length ? [[NSString alloc] initWithData:[_buf dataInRange:r] encoding:NSUTF8StringEncoding] : nil;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(undo:)) return _undo.count > 0;
    if (a == @selector(redo:)) return _redo.count > 0;
    if (a == @selector(undoCursor:)) return _cursorHistory.count > 0;
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
    [self dropExtraCursors];
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

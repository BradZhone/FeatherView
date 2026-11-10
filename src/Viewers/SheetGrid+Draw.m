#import "SheetGrid.h"

static NSColor *argb(uint32_t c) {
    return [NSColor colorWithSRGBRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
}

static NSUInteger lastLE(const CGFloat *edges, NSUInteger n, CGFloat v) {
    NSUInteger lo = 0, hi = n;
    while (lo < hi) { NSUInteger mid = (lo + hi + 1) / 2; if (edges[mid] <= v) lo = mid; else hi = mid - 1; }
    return lo;
}

static void stroke(XLLine s, uint32_t colour, NSPoint a, NSPoint b) {
    if (!s) return;
    CGFloat w = s == XLLineMedium ? 2 : s == XLLineThick ? 3 : 1;
    BOOL vertical = a.x == b.x;
    CGFloat off = (int)w % 2 ? 0.5 : 0;
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = s == XLLineDouble ? 1 : w;
    if (s == XLLineDashed) { CGFloat d[] = {4, 2}; [p setLineDash:d count:2 phase:0]; }
    if (s == XLLineDotted || s == XLLineHair) { CGFloat d[] = {1, 1.5}; [p setLineDash:d count:2 phase:0]; }
    [(colour ? argb(colour) : NSColor.labelColor) setStroke];
    for (int k = 0; k < (s == XLLineDouble ? 2 : 1); k++) {
        CGFloat d = off + k * 2;
        [p moveToPoint:NSMakePoint(a.x + (vertical ? d : 0), a.y + (vertical ? 0 : d))];
        [p lineToPoint:NSMakePoint(b.x + (vertical ? d : 0), b.y + (vertical ? 0 : d))];
    }
    [p stroke];
}

@implementation SheetGrid (Draw)

- (NSFont *)fontFor:(XLStyle *)st {
    NSString *key = [NSString stringWithFormat:@"%@|%.1f|%d%d", st.fontName, st.fontSize, st.bold, st.italic];
    NSFont *f = _fonts[key];
    if (f) return f;
    // Windows / Office fonts that macOS doesn't ship, mapped to the closest system font
    static NSDictionary *subs;
    if (!subs) subs = @{@"calibri": @"Helvetica Neue", @"calibri light": @"Helvetica Neue", @"cambria": @"Georgia", @"segoe ui": @"Helvetica Neue",
                        @"simsun": @"Songti SC", @"宋体": @"Songti SC", @"nsimsun": @"Songti SC", @"等线": @"PingFang SC", @"dengxian": @"PingFang SC",   // l10n: data (font names)
                        @"microsoft yahei": @"PingFang SC", @"微软雅黑": @"PingFang SC", @"simhei": @"Heiti SC", @"黑体": @"Heiti SC",   // l10n: data (font names)
                        @"ms gothic": @"Hiragino Sans", @"meiryo": @"Hiragino Sans", @"malgun gothic": @"Apple SD Gothic Neo"};
    CGFloat size = MAX(4, round(st.fontSize * 4 / 3 * _zoom * 0.9 * 2) / 2);
    f = [NSFont fontWithName:st.fontName size:size] ?: [NSFont fontWithName:subs[st.fontName.lowercaseString] ?: @"Helvetica Neue" size:size] ?: [NSFont systemFontOfSize:size];
    CGFloat digit = [@"0" sizeWithAttributes:@{NSFontAttributeName: f}].width, want = 7.0 * st.fontSize / 11 * _zoom;
    if (digit > want * 1.02) f = [NSFont fontWithDescriptor:f.fontDescriptor size:MAX(size * 0.8, size * want / digit)] ?: f;   // Excel's column unit is that digit
    NSFontTraitMask traits = (st.bold ? NSBoldFontMask : 0) | (st.italic ? NSItalicFontMask : 0);
    if (traits) f = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:traits];
    _fonts[key] = f;
    return f;
}

// One quadrant of the sheet: rows [r0, r1), columns [c0, c1), clipped to `clip`.
- (void)drawRows:(NSUInteger)r0 to:(NSUInteger)r1 cols:(NSUInteger)c0 to:(NSUInteger)c1 clip:(NSRect)clip {
    if (r0 >= r1 || c0 >= c1 || NSIsEmptyRect(clip)) return;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(clip);
    XLSheet *sh = _sheet;
    NSColor *grid = [NSColor.labelColor colorWithAlphaComponent:0.12];
    CGFloat top = [self yOfRow:r0], bottom = [self yOfRow:r1], left = [self xOfCol:c0], right = [self xOfCol:c1];
    if (sh.showGridLines) {
        [grid setFill];                                                                   // translucent: blend, don't copy
        for (NSUInteger r = r0; r <= r1; r++) if (r == r1 || _ry[r + 1] > _ry[r] || r == r0) NSRectFillUsingOperation(NSMakeRect(left, [self yOfRow:r] - 0.5, right - left, 1), NSCompositingOperationSourceOver);
        for (NSUInteger c = c0; c <= c1; c++) NSRectFillUsingOperation(NSMakeRect([self xOfCol:c] - 0.5, top, 1, bottom - top), NSCompositingOperationSourceOver);
    }
    // merges reaching into this quadrant are drawn whole from their anchor
    NSMutableArray<NSValue *> *merges = [NSMutableArray array];
    for (NSValue *v in sh.merges) {
        XLRange m; [v getValue:&m];
        if (m.lastRow >= r0 && m.row < r1 && m.lastCol >= c0 && m.col < c1) [merges addObject:v];
    }
    NSColor *paper = NSColor.textBackgroundColor;
    for (NSValue *v in merges) {                                                       // no grid lines inside a merge
        XLRange m; [v getValue:&m];
        XLStyle *st = [sh styleAt:m.row col:m.col];
        NSRect rr = [self rectForRow:m.row col:m.col];
        [(st.fillColor ? argb(st.fillColor) : paper) setFill];
        NSRectFill(NSInsetRect(rr, 0.5, 0.5));
    }
    // fills
    for (NSUInteger r = r0; r < r1; r++) {
        if (_ry[r + 1] == _ry[r]) continue;
        for (NSUInteger c = c0; c < c1; c++) {
            if (_cx[c + 1] == _cx[c]) continue;
            XLStyle *st = [sh styleAt:r col:c];
            if (!st.fillColor || [sh mergeAt:r col:c range:NULL]) continue;
            [argb(st.fillColor) setFill];
            NSRectFill(NSMakeRect([self xOfCol:c], [self yOfRow:r], _cx[c + 1] - _cx[c], _ry[r + 1] - _ry[r]));
        }
    }
    // text and borders
    for (NSUInteger r = r0; r < r1; r++) {
        if (_ry[r + 1] == _ry[r]) continue;
        for (NSUInteger c = c0; c < c1; c++) {
            XLRange m;
            BOOL merged = [sh mergeAt:r col:c range:&m];
            if (merged && (m.row != r || m.col != c)) continue;
            [self drawCellAt:r col:c merged:merged clip:clip lastCol:c1];
        }
    }
    for (NSValue *v in merges) {                                                       // anchors outside this quadrant
        XLRange m; [v getValue:&m];
        if (m.row < r0 || m.col < c0) [self drawCellAt:m.row col:m.col merged:YES clip:clip lastCol:c1];
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawCellAt:(NSUInteger)r col:(NSUInteger)c merged:(BOOL)merged clip:(NSRect)clip lastCol:(NSUInteger)c1 {
    XLSheet *sh = _sheet;
    NSRect cell = [self rectForRow:r col:c];
    if (cell.size.width <= 0 || cell.size.height <= 0) return;
    XLStyle *st = [sh styleAt:r col:c];
    stroke(st.top, st.topColor, NSMakePoint(NSMinX(cell), NSMinY(cell)), NSMakePoint(NSMaxX(cell), NSMinY(cell)));
    stroke(st.bottom, st.bottomColor, NSMakePoint(NSMinX(cell), NSMaxY(cell) - 1), NSMakePoint(NSMaxX(cell), NSMaxY(cell) - 1));
    stroke(st.left, st.leftColor, NSMakePoint(NSMinX(cell), NSMinY(cell)), NSMakePoint(NSMinX(cell), NSMaxY(cell)));
    stroke(st.right, st.rightColor, NSMakePoint(NSMaxX(cell) - 1, NSMinY(cell)), NSMakePoint(NSMaxX(cell) - 1, NSMaxY(cell)));
    uint32_t fmtColour = 0;
    NSString *text = [sh displayAt:r col:c colour:&fmtColour];
    if (!text.length) return;
    XLType type = [sh typeAt:r col:c];
    BOOL formula = [sh isUncomputedFormulaAt:r col:c];
    NSFont *font = [self fontFor:st];
    NSColor *colour;
    uint32_t fc = fmtColour ?: st.fontColor;
    if (formula) colour = NSColor.secondaryLabelColor;
    else if (fc && !(st.fillColor == 0 && (fc & 0xFFFFFF) == 0)) colour = argb(fc);     // black on no fill follows dark mode
    else colour = st.fillColor ? NSColor.blackColor : NSColor.labelColor;
    if (formula) font = [NSFontManager.sharedFontManager convertFont:font toHaveTrait:NSItalicFontMask];
    NSMutableDictionary *a = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: colour} mutableCopy];
    if (st.underline) a[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    if (st.strike) a[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    XLHAlign h = st.hAlign;
    if (h == XLAlignGeneral) h = type == XLNumber ? XLAlignRight : (type == XLBool || type == XLError) ? XLAlignCenter : XLAlignLeft;
    CGFloat pad = 3 * _zoom + st.indent * 8 * _zoom;
    NSRect box = NSInsetRect(cell, 0, 0);
    box.origin.x += pad; box.size.width -= 2 * pad;
    if (st.wrap) {
        NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
        p.alignment = h == XLAlignRight ? NSTextAlignmentRight : h == XLAlignCenter ? NSTextAlignmentCenter : NSTextAlignmentLeft;
        p.lineBreakMode = NSLineBreakByWordWrapping;
        a[NSParagraphStyleAttributeName] = p;
        NSRect need = [text boundingRectWithSize:NSMakeSize(box.size.width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
        CGFloat y = st.vAlign == XLAlignTop ? NSMinY(cell) + 1 : st.vAlign == XLAlignVCenter ? NSMidY(cell) - need.size.height / 2 : NSMaxY(cell) - need.size.height - 1;
        [NSGraphicsContext saveGraphicsState];
        NSRectClip(NSIntersectionRect(cell, clip));
        [text drawWithRect:NSMakeRect(box.origin.x, y, box.size.width, need.size.height) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }
    NSString *one = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    CGFloat w = ceil([one sizeWithAttributes:a].width);
    NSRect area = cell;
    if (w > box.size.width) {
        if (type == XLNumber && !formula) { one = @"###"; w = ceil([one sizeWithAttributes:a].width); }   // numbers never spill
        else if (!merged && h == XLAlignLeft) {                                            // text spills into empty cells on the right
            NSUInteger k = c + 1;
            CGFloat reach = NSMaxX(cell);
            while (reach - NSMinX(cell) < w + pad * 2 && k < _nCols && k < c + 64 && ![sh displayAt:r col:k colour:NULL].length) {
                reach = [self xOfCol:k + 1]; k++;
            }
            area.size.width = reach - NSMinX(cell);
            if (area.size.width - pad > w) {                                               // cover the grid lines it crosses
                [(st.fillColor ? argb(st.fillColor) : NSColor.textBackgroundColor) setFill];
                NSRectFill(NSMakeRect(NSMaxX(cell) - 1, NSMinY(cell) + 0.5, NSMaxX(area) - NSMaxX(cell) - 1, cell.size.height - 1));
            }
        }
    }
    CGFloat x = h == XLAlignRight ? NSMaxX(box) - w : h == XLAlignCenter ? NSMidX(cell) - w / 2 : NSMinX(box);
    CGFloat lh = ceil(font.ascender - font.descender);
    CGFloat y = st.vAlign == XLAlignTop ? NSMinY(cell) + 1 : st.vAlign == XLAlignVCenter ? NSMidY(cell) - lh / 2 : NSMaxY(cell) - lh - 1.5 * _zoom;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSIntersectionRect(area, clip));
    [one drawAtPoint:NSMakePoint(x, y) withAttributes:a];
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawHeadersFrom:(NSUInteger)c0 to:(NSUInteger)c1 clip:(NSRect)clip vertical:(BOOL)vertical selected:(NSRange)sel {
    if (c0 >= c1 || NSIsEmptyRect(clip)) return;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(clip);
    NSFont *f = [NSFont systemFontOfSize:round(11 * MIN(_zoom, 1.4))];
    NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSDictionary *as = @{NSFontAttributeName: [NSFont systemFontOfSize:f.pointSize weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor};
    for (NSUInteger k = c0; k < c1; k++) {
        CGFloat start = vertical ? [self yOfRow:k] : [self xOfCol:k], len = vertical ? _ry[k + 1] - _ry[k] : _cx[k + 1] - _cx[k];
        if (len <= 0) continue;
        NSRect r = vertical ? NSMakeRect(0, start, self.headerWidth, len) : NSMakeRect(start, 0, len, self.headerHeight);
        BOOL on = NSLocationInRange(k, sel);
        if (on) { [[NSColor.controlAccentColor colorWithAlphaComponent:0.18] setFill]; NSRectFillUsingOperation(r, NSCompositingOperationSourceOver); }
        [NSColor.separatorColor setFill];
        NSRectFill(vertical ? NSMakeRect(0, NSMaxY(r) - 0.5, r.size.width, 0.5) : NSMakeRect(NSMaxX(r) - 0.5, 0, 0.5, r.size.height));
        NSString *t = vertical ? [NSString stringWithFormat:@"%lu", (unsigned long)k + 1] : XLColumnName(k);
        NSSize ts = [t sizeWithAttributes:on ? as : a];
        if (ts.width < r.size.width - 2) [t drawAtPoint:NSMakePoint(NSMidX(r) - ts.width / 2, NSMidY(r) - ts.height / 2) withAttributes:on ? as : a];
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [NSColor.textBackgroundColor setFill];
    NSRectFill(b);
    if (!_sheet || !_nRows || !_nCols) return;
    CGFloat hw = self.headerWidth, hh = self.headerHeight, fw = self.frozenW, fh = self.frozenH;
    NSUInteger fr = self.frozenRows, fc = self.frozenCols;
    // visible scrolling range
    NSUInteger rs = MIN(_nRows, MAX(fr, lastLE(_ry, _nRows, fh + self.scrollY))), cs = MIN(_nCols, MAX(fc, lastLE(_cx, _nCols, fw + self.scrollX)));
    NSUInteger re = MIN(_nRows, lastLE(_ry, _nRows, self.scrollY + b.size.height) + 1), ce = MIN(_nCols, lastLE(_cx, _nCols, self.scrollX + b.size.width) + 1);
    NSRect body = NSMakeRect(hw + fw, hh + fh, b.size.width - hw - fw, b.size.height - hh - fh);
    NSRect topBand = NSMakeRect(hw + fw, hh, body.size.width, fh), leftBand = NSMakeRect(hw, hh + fh, fw, body.size.height);
    [self drawRows:rs to:re cols:cs to:ce clip:body];
    [self drawRows:0 to:fr cols:cs to:ce clip:topBand];
    [self drawRows:rs to:re cols:0 to:fc clip:leftBand];
    [self drawRows:0 to:fr cols:0 to:fc clip:NSMakeRect(hw, hh, fw, fh)];
    // past the last row / column
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.6] setFill];
    CGFloat endX = [self xOfCol:_nCols], endY = [self yOfRow:_nRows];
    if (endX < NSMaxX(b)) NSRectFillUsingOperation(NSMakeRect(endX, hh, NSMaxX(b) - endX, b.size.height), NSCompositingOperationSourceOver);
    if (endY < NSMaxY(b)) NSRectFillUsingOperation(NSMakeRect(hw, endY, b.size.width, NSMaxY(b) - endY), NSCompositingOperationSourceOver);
    [self drawSelectionClip:NSMakeRect(hw, hh, b.size.width - hw, b.size.height - hh)];
    if (fr) { [NSColor.tertiaryLabelColor setFill]; NSRectFill(NSMakeRect(hw, hh + fh - 0.5, b.size.width, 1)); }
    if (fc) { [NSColor.tertiaryLabelColor setFill]; NSRectFill(NSMakeRect(hw + fw - 0.5, hh, 1, b.size.height)); }
    // headers
    [[NSColor.windowBackgroundColor blendedColorWithFraction:0.04 ofColor:NSColor.labelColor] setFill];
    NSRectFill(NSMakeRect(0, 0, b.size.width, hh));
    NSRectFill(NSMakeRect(0, 0, hw, b.size.height));
    XLRange sel = self.selection;
    NSRange sc = NSMakeRange(sel.col, sel.lastCol - sel.col + 1), sr = NSMakeRange(sel.row, sel.lastRow - sel.row + 1);
    [self drawHeadersFrom:0 to:fc clip:NSMakeRect(hw, 0, fw, hh) vertical:NO selected:sc];
    [self drawHeadersFrom:cs to:ce clip:NSMakeRect(hw + fw, 0, b.size.width - hw - fw, hh) vertical:NO selected:sc];
    [self drawHeadersFrom:0 to:fr clip:NSMakeRect(0, hh, hw, fh) vertical:YES selected:sr];
    [self drawHeadersFrom:rs to:re clip:NSMakeRect(0, hh + fh, hw, b.size.height - hh - fh) vertical:YES selected:sr];
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, hh - 0.5, b.size.width, 0.5));
    NSRectFill(NSMakeRect(hw - 0.5, 0, 0.5, b.size.height));
    [self drawScrollIndicator];
}

- (void)drawSelectionClip:(NSRect)clip {
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(clip);
    XLRange s = self.selection;
    NSRect a = [self rectForRow:s.row col:s.col], z = [self rectForRow:s.lastRow col:s.lastCol];
    NSRect all = NSUnionRect(a, z);
    NSColor *accent = NSColor.controlAccentColor;
    if (s.row != s.lastRow || s.col != s.lastCol) {
        [[accent colorWithAlphaComponent:0.14] setFill];
        NSRectFillUsingOperation(all, NSCompositingOperationSourceOver);
    }
    NSRect act = [self rectForRow:_row col:_col];
    [accent setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSInsetRect(all, 0.5, 0.5)];
    p.lineWidth = 2;
    [p stroke];
    if (s.row != s.lastRow || s.col != s.lastCol) {
        NSBezierPath *q = [NSBezierPath bezierPathWithRect:NSInsetRect(act, 1.5, 1.5)];
        q.lineWidth = 1;
        [q stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
}

@end

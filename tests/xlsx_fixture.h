// A small .xlsx built from XML text, covering what the workbook model must handle: shared strings (one rich),
// number formats, a shared formula, an array formula, a table, a merge, frozen panes, a second sheet whose
// elements use an "x:" prefix and an empty <sheetData/>, a calcChain and no <calcPr>.
#import "ZipArchive.h"

static NSData *XLFixture(void) {
    uint8_t eocd[22] = {0x50, 0x4b, 0x05, 0x06};
    ZipArchive *empty = [[ZipArchive alloc] initWithData:[NSData dataWithBytes:eocd length:22] error:NULL];
    NSString *ns = @"xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"";
    NSDictionary<NSString *, NSString *> *parts = @{
        @"[Content_Types].xml": @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
            "<Override PartName=\"/xl/calcChain.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml\"/></Types>",
        @"_rels/.rels": @"<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
        @"xl/_rels/workbook.xml.rels": @"<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
            "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"/xl/worksheets/sheet2.xml\"/>"
            "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            "<Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
            "<Relationship Id=\"rId5\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain\" Target=\"calcChain.xml\"/></Relationships>",
        @"xl/workbook.xml": [NSString stringWithFormat:@"<?xml version=\"1.0\"?><workbook %@><workbookPr/><bookViews><workbookView activeTab=\"0\"/></bookViews>"
            "<sheets><sheet name=\"Data 数据\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Prefixed\" sheetId=\"2\" r:id=\"rId2\"/></sheets></workbook>", ns],
        @"xl/sharedStrings.xml": @"<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"4\" uniqueCount=\"4\">"
            "<si><t>Name</t></si><si><t>Amount</t></si><si><r><rPr><b/></rPr><t>Bold </t></r><r><t>part</t></r><rPh><t>ignored</t></rPh></si><si><t xml:space=\"preserve\"> a &amp; b </t></si></sst>",
        @"xl/styles.xml": @"<?xml version=\"1.0\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"yyyy-mm-dd\"/></numFmts>"
            "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font></fonts>"
            "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
            "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF4472C4\"/></patternFill></fill></fills>"
            "<borders count=\"2\"><border/><border><left style=\"thin\"><color rgb=\"FF999999\"/></left><bottom style=\"medium\"/></border></borders>"
            "<cellXfs count=\"5\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"1\"><alignment horizontal=\"center\"/></xf>"
            "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"4\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellXfs></styleSheet>",
        @"xl/worksheets/sheet1.xml": [NSString stringWithFormat:@"<?xml version=\"1.0\"?><worksheet %@><dimension ref=\"A1:D6\"/>"
            "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" state=\"frozen\"/></sheetView></sheetViews>"
            "<cols><col min=\"1\" max=\"1\" width=\"20\" customWidth=\"1\"/><col min=\"4\" max=\"4\" width=\"9\" hidden=\"1\"/></cols><sheetData>"
            "<row r=\"1\" spans=\"1:4\"><c r=\"A1\" s=\"1\" t=\"s\"><v>0</v></c><c r=\"B1\" s=\"1\" t=\"s\"><v>1</v></c><c r=\"C1\" s=\"1\" t=\"inlineStr\"><is><t>Date</t></is></c></row>"
            "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>2</v></c><c r=\"B2\" s=\"3\"><v>1234.5</v></c><c r=\"C2\" s=\"2\"><v>46027</v></c><c r=\"D2\"><f t=\"shared\" ref=\"D2:D3\" si=\"0\">B2*2</f><v>2469</v></c></row>"
            "<row r=\"3\"><c r=\"A3\" t=\"s\"><v>3</v></c><c r=\"B3\" s=\"4\"><v>0.125</v></c><c r=\"D3\"><f t=\"shared\" si=\"0\"/><v>0.25</v></c></row>"
            "<row r=\"4\"><c r=\"A4\" t=\"b\"><v>1</v></c><c r=\"B4\" t=\"e\"><v>#DIV/0!</v></c><c r=\"C4\"><f t=\"array\" ref=\"C4:C5\">B2:B3*2</f><v>2469</v></c></row>"
            "<row r=\"5\"><c r=\"C5\"><v>0.25</v></c></row>"
            "<row r=\"6\"/></sheetData><mergeCells count=\"1\"><mergeCell ref=\"A7:B7\"/></mergeCells>"
            "<tableParts count=\"1\"><tablePart r:id=\"rIdT\"/></tableParts></worksheet>", ns],
        @"xl/worksheets/_rels/sheet1.xml.rels": @"<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            "<Relationship Id=\"rIdT\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" Target=\"../tables/table1.xml\"/></Relationships>",
        @"xl/tables/table1.xml": @"<?xml version=\"1.0\"?><table xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" id=\"1\" name=\"T\" ref=\"F10:G12\"><tableColumns count=\"2\"><tableColumn id=\"1\" name=\"X\"/><tableColumn id=\"2\" name=\"Y\"/></tableColumns></table>",
        @"xl/worksheets/sheet2.xml": @"<?xml version=\"1.0\"?><x:worksheet xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><x:sheetData/></x:worksheet>",
        @"xl/calcChain.xml": @"<?xml version=\"1.0\"?><calcChain xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><c r=\"D2\" i=\"1\"/></calcChain>",
        @"docProps/untouched.bin": @"keep these bytes exactly",
    };
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    for (NSString *k in parts) data[k] = [parts[k] dataUsingEncoding:NSUTF8StringEncoding];
    return [empty dataReplacing:data removing:[NSSet set] error:NULL];
}

@IsTest
private class DocGenHtmlRendererTest {
    @IsTest
    static void testBasicParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Hello World</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<body>'), 'Should contain body tag');
            System.assert(html.contains('Hello World'), 'Should contain text');
            System.assert(html.contains('<p>'), 'Should contain paragraph tag');
        }
    }

    @IsTest
    static void testBoldItalicUnderline() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:b/><w:i/><w:u w:val="single"/></w:rPr><w:t>Styled</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<b>'), 'Should contain bold');
            System.assert(html.contains('<i>'), 'Should contain italic');
            System.assert(html.contains('<u>'), 'Should contain underline');
            System.assert(html.contains('Styled'), 'Should contain text');
        }
    }

    @IsTest
    static void testParagraphAlignment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>Centered</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('text-align:center'), 'Should have center alignment');
        }
    }

    @IsTest
    static void testFontSizeAndColor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:sz w:val="28"/><w:color w:val="FF0000"/></w:rPr><w:t>Big Red</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('font-size:14'), 'Should have 14pt font (28/2)');
            System.assert(html.contains('#FF0000'), 'Should have red color');
        }
    }

    @IsTest
    static void testTable() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl>' +
                '<w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>Cell 1</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:p><w:r><w:t>Cell 2</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<table'), 'Should contain table');
            System.assert(html.contains('<tr>'), 'Should contain row');
            System.assert(html.contains('<td'), 'Should contain cell');
            System.assert(html.contains('Cell 1'), 'Should contain cell text');
            System.assert(html.contains('Cell 2'), 'Should contain cell text');
        }
    }

    @IsTest
    static void testTableColgroupFromTblGrid() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Three identical-width columns declared in <w:tblGrid>, but only the
            // first cell has content. Without colgroup emission + table-layout:fixed,
            // Flying Saucer's auto-layout would collapse the empty columns to ~0
            // width and redistribute their space to the populated column — producing
            // visible column misalignment when the same template is used across
            // multiple iterations where some rows have empty cells.
            //
            // Widths are emitted as percentages of the grid total (not absolute pt)
            // so the column proportions are preserved while the table itself remains
            // sized to its container — avoids right-side overflow when the grid sum
            // exceeds printable page width.
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl>' +
                '<w:tblPr></w:tblPr>' +
                '<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>Filled</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:p></w:p></w:tc>' +
                '<w:tc><w:p></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<colgroup>'), 'Should emit <colgroup> from <w:tblGrid>. HTML: ' + html);
            // 2000 twips out of 6000 total = 33.33%
            System.assert(
                html.contains('<col style="width:33.33%"/>'),
                'Should emit per-column width as % of grid total (2000/6000 = 33.33%). HTML: ' + html
            );
            System.assert(
                html.contains('table-layout:fixed'),
                'Should force table-layout:fixed when explicit grid widths exist. HTML: ' + html
            );
        }
    }

    @IsTest
    static void testTableNoColgroupWithoutTblGrid() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Table without <w:tblGrid> — verify the fix is gated on grid presence
            // and doesn't change rendering of tables that don't declare explicit
            // column widths (preserves backward compatibility).
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl>' +
                '<w:tblPr></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<table'), 'Should still emit table');
            System.assert(!html.contains('<colgroup>'), 'Should not emit colgroup without <w:tblGrid>');
            System.assert(
                !html.contains('table-layout:fixed'),
                'Should not force fixed layout without explicit grid widths'
            );
        }
    }

    @IsTest
    static void testTableCellShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="E2EFDA"/></w:tcPr>' +
                '<w:p><w:r><w:t>Shaded</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('#E2EFDA'), 'Should contain shading color');
        }
    }

    @IsTest
    static void testLineBreak() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Before</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>After</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<br/>'), 'Should contain line break');
            System.assert(html.contains('Before'), 'Should contain text before break');
            System.assert(html.contains('After'), 'Should contain text after break');
        }
    }

    @IsTest
    static void testImageWithBase64() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image data'));
            Map<String, String> images = new Map<String, String>{ 'rIdImg1' => fakeBase64 };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);

            System.assert(html.contains('<img'), 'Should contain image tag');
            System.assert(html.contains('data:image/png;base64,'), 'Should contain base64 data URI');
        }
    }

    @IsTest
    static void testEmptyDocument() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml('');
            System.assert(html.contains('<body>'), 'Should return valid HTML for empty input');
            System.assert(html.contains('</body>'), 'Should close body tag');
        }
    }

    @IsTest
    static void testNullDocument() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml(null);
            System.assert(html.contains('<body>'), 'Should return valid HTML for null input');
        }
    }

    @IsTest
    static void testNoImagesOverload() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Test'), 'Should handle no-image overload');
        }
    }

    @IsTest
    static void testMultipleRuns() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p>' +
                '<w:r><w:t>Hello </w:t></w:r>' +
                '<w:r><w:rPr><w:b/></w:rPr><w:t>World</w:t></w:r>' +
                '</w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Hello '), 'Should contain first run text');
            System.assert(html.contains('<b>'), 'Should contain bold tag');
            System.assert(html.contains('World'), 'Should contain second run text');
        }
    }

    @IsTest
    static void testSpacingAndIndent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:before="120" w:after="240"/><w:ind w:left="720"/></w:pPr>' +
                '<w:r><w:t>Indented</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('margin-top:'), 'Should have top margin');
            System.assert(html.contains('margin-bottom:'), 'Should have bottom margin');
            System.assert(html.contains('margin-left:'), 'Should have left indent');
        }
    }

    // =========================================================================
    // Additional coverage tests
    // =========================================================================

    @IsTest
    static void testNullImagesMap() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Exercises the images == null guard in convertToHtml
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, null);
            System.assert(html.contains('Text'), 'Should handle null images map');
        }
    }

    @IsTest
    static void testParagraphAlignmentRightAndJustify() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers right/end and both/distribute alignment branches
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>Right</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="end"/></w:pPr><w:r><w:t>End</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:t>Justify</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:jc w:val="distribute"/></w:pPr><w:r><w:t>Distribute</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('text-align:right'), 'Should have right alignment');
            System.assert(html.contains('text-align:justify'), 'Should have justify alignment');
        }
    }

    @IsTest
    static void testIndentRightAndFirstLine() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:ind w:right and w:firstLine branches
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:ind w:left="360" w:right="360" w:firstLine="720"/></w:pPr>' +
                '<w:r><w:t>Indented</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-right:'), 'Should have right indent');
            System.assert(html.contains('text-indent:'), 'Should have first line indent');
        }
    }

    @IsTest
    static void testStrikethrough() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:strike branch
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:strike/></w:rPr><w:t>Struck</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<s>'), 'Should contain strikethrough');
            System.assert(html.contains('Struck'), 'Should contain text');
        }
    }

    @IsTest
    static void testFontFamilyAndHighlight() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:rFonts (hAnsi fallback) and w:highlight branches
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:rFonts w:hAnsi="Times New Roman"/><w:highlight w:val="yellow"/></w:rPr><w:t>Highlighted</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Times New Roman'), 'Should contain font family from hAnsi');
            System.assert(html.contains('background-color:yellow'), 'Should contain highlight');
        }
    }

    @IsTest
    static void testColorAuto() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers the color == 'auto' skip branch
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:color w:val="auto"/></w:rPr><w:t>Auto</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(!html.contains('color:#auto'), 'Should not include auto color');
            System.assert(html.contains('Auto'), 'Should contain text');
        }
    }

    @IsTest
    static void testTableWidthPercent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers tblW with type=pct branch
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Cell</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('width:') && html.contains('%'), 'Should have percentage width from pct type');
        }
    }

    @IsTest
    static void testTableCellWidthTypes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers tcW with pct type and dxa type branches
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:tcPr><w:tcW w:w="2500" w:type="pct"/></w:tcPr><w:p><w:r><w:t>Pct</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:tcPr><w:tcW w:w="2880" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>Dxa</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            // Authored a top-only table border (no insideH/insideV): the <table> gets a
            // top border and cells get NONE — not a forced full black box per cell.
            System.assert(html.contains('border-top:'), 'Table should carry its authored top border');
            System.assert(!html.contains('border:0.5pt solid #000'), 'Top-only border must not box every cell');
            System.assert(html.contains('Pct'), 'Should contain pct cell text');
            System.assert(html.contains('Dxa'), 'Should contain dxa cell text');
        }
    }

    @IsTest
    static void testPartialTableBorderFidelity() {
        // A footer-style table: explicit tblBorders with ONLY a top rule (orange) and
        // every other side "none". Faithful output = a single top border on the <table>,
        // no interior grid, no per-cell box — NOT the old forced full black grid.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:tbl><w:tblPr>' +
                '<w:tblStyle w:val="TableGrid"/>' +
                '<w:tblBorders>' +
                '<w:top w:val="single" w:sz="4" w:color="FA6414"/>' +
                '<w:left w:val="none"/><w:bottom w:val="none"/><w:right w:val="none"/>' +
                '<w:insideH w:val="none"/><w:insideV w:val="none"/>' +
                '</w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>L</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:p><w:r><w:t>R</w:t></w:r></w:p></w:tc>' +
                '</w:tr></w:tbl></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(
                html.contains('border-top:0.5pt solid #FA6414'),
                'Authored orange top rule must survive with its color. Got: ' + html
            );
            System.assert(
                !html.contains('border-left'),
                'Top-only border must not add any vertical grid line. Got: ' + html
            );
            System.assert(
                !html.contains('border:0.5pt solid #000'),
                'Top-only border must not box every cell in black. Got: ' + html
            );
        }
    }

    @IsTest
    static void testExplicitGridBorderAppliesToCells() {
        // Explicit insideH/insideV grid → cells inherit those interior borders (the
        // full-grid case), each in the authored color.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:tbl><w:tblPr><w:tblBorders>' +
                '<w:top w:val="single" w:sz="4" w:color="000000"/>' +
                '<w:bottom w:val="single" w:sz="4" w:color="000000"/>' +
                '<w:left w:val="single" w:sz="4" w:color="000000"/>' +
                '<w:right w:val="single" w:sz="4" w:color="000000"/>' +
                '<w:insideH w:val="single" w:sz="4" w:color="000000"/>' +
                '<w:insideV w:val="single" w:sz="4" w:color="000000"/>' +
                '</w:tblBorders></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>' +
                '<w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>' +
                '</w:tr></w:tbl></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            // Cells get interior left/right borders (insideV) — proves the grid is drawn.
            System.assert(
                html.contains('border-left:0.5pt solid #000000'),
                'Interior grid must reach cells. Got: ' + html
            );
        }
    }

    @IsTest
    static void testCellVerticalAlignment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:vAlign branch
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:vAlign w:val="center"/></w:tcPr>' +
                '<w:p><w:r><w:t>Centered</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            // #246 — this assertion previously demanded `vertical-align:center`, which
            // is INVALID CSS: table cells accept top | middle | bottom only. Flying
            // Saucer dropped the declaration and the cell fell back to the stylesheet
            // default of `top`, so every centre-aligned Word cell rendered top-aligned
            // while this test passed. Word's "center" must be translated to "middle".
            System.assert(
                html.contains('vertical-align:middle'),
                'Word w:vAlign="center" must emit CSS vertical-align:middle: ' + html
            );
            System.assert(
                !html.contains('vertical-align:center'),
                'vertical-align:center is not valid CSS and must never be emitted: ' + html
            );
        }
    }

    @IsTest
    static void testImageJpegDetection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers JPEG detection branch (base64 starting with /9j/)
            String jpegBase64 = '/9j/4AAQSkZJRgABAQEASABIAAD';
            Map<String, String> images = new Map<String, String>{ 'rIdImg1' => jpegBase64 };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('image/jpeg'), 'Should detect JPEG MIME type');
        }
    }

    @IsTest
    static void testImageMissingRelId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers relId == null return '' branch
            Map<String, String> images = new Map<String, String>();

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(!html.contains('<img'), 'Should not produce img tag when no blip embed');
        }
    }

    @IsTest
    static void testImageMissingBase64() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers base64 == null return '' branch (relId exists but not in images map)
            Map<String, String> images = new Map<String, String>();

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdMissing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(!html.contains('<img'), 'Should not produce img tag when base64 not in map');
        }
    }

    @IsTest
    static void testImageDimensionFallbackFromAExt() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers the fallback to a:ext for cx/cy when wp:extent is absent
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake image'));
            Map<String, String> images = new Map<String, String>{ 'rIdImg2' => fakeBase64 };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdImg2" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '<pic:spPr><a:xfrm><a:ext cx="1905000" cy="952500"/></a:xfrm></pic:spPr>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should contain image tag');
        }
    }

    @IsTest
    static void testEmptyParagraphRendersNbsp() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers blank content branch in processParagraph
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="center"/></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('&nbsp;'), 'Empty paragraph should render nbsp');
        }
    }

    @IsTest
    static void testSelfClosingParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:p/> self-closing paragraph handling
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p/>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should produce valid HTML');
        }
    }

    @IsTest
    static void testSelfClosingTextElement() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers self-closing <w:t/> skip in extractTextContent
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t/><w:t>After</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('After'), 'Should skip self-closing w:t and continue');
        }
    }

    @IsTest
    static void testNoBodyTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers extractBodyContent when no w:body tag exists
            String xml =
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:p><w:r><w:t>NoBody</w:t></w:r></w:p></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should still produce valid HTML');
        }
    }

    @IsTest
    static void testBodyWithoutClosingTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers extractBodyContent when no </w:body> close tag
            String xml =
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Open</w:t></w:r></w:p></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Open'), 'Should handle missing close body tag');
        }
    }

    @IsTest
    static void testDrawingOutsideRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers standalone w:drawing outside of w:r in processRuns
            String fakeBase64 = EncodingUtil.base64Encode(Blob.valueOf('fake'));
            Map<String, String> images = new Map<String, String>{ 'rIdStandalone' => fakeBase64 };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="952500" cy="476250"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdStandalone" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should process drawing outside of w:r');
        }
    }

    @IsTest
    static void testSectPrStripping() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers sectPr stripping from body content
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Before</w:t></w:r></w:p>' +
                '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Before'), 'Should contain text');
            System.assert(!html.contains('pgSz'), 'Should strip section properties');
        }
    }

    @IsTest
    static void testRunWithAttributeStart() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:r ...> with attributes (runStart2 branch)
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r w:rsidR="00112233"><w:t>WithAttr</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('WithAttr'), 'Should handle runs with attributes');
        }
    }

    @IsTest
    static void testParagraphWithAttributes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers <w:p ...> with attributes
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p w:rsidR="00112233"><w:r><w:t>ParaAttr</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('ParaAttr'), 'Should handle paragraphs with attributes');
        }
    }

    @IsTest
    static void testExtractElementSelfClosing() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers self-closing element in extractElement
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:jc w:val="left"/></w:pPr><w:r><w:t>Left</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Left'), 'Should handle self-closing elements in pPr');
        }
    }

    @IsTest
    static void testFontWithAsciiAttr() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers w:rFonts w:ascii path (primary path)
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:rFonts w:ascii="Courier New"/></w:rPr><w:t>Mono</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('Courier New'), 'Should contain ascii font');
        }
    }

    @IsTest
    static void testCellShadingAutoFill() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Covers fill == 'auto' skip branch in cell shading
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:shd w:val="clear" w:fill="auto"/></w:tcPr>' +
                '<w:p><w:r><w:t>AutoFill</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(!html.contains('background-color:#auto'), 'Should not include auto fill');
            System.assert(html.contains('AutoFill'), 'Should contain text');
        }
    }

    // =========================================================================
    // Barcode rendering — renderBarcodeHtml, renderCode128Html
    // =========================================================================

    @IsTest
    static void testRenderBarcodeCode128() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Build XML with a barcode marker in the text content
            String barcodeMarker = '##BARCODE:code128::ABC-123##';
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' +
                barcodeMarker +
                '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            // Should render CSS bars, not the raw marker text
            System.assert(html.contains('display:inline-block'), 'Should render as CSS bars');
            System.assert(html.contains('background:'), 'Should contain bar colors');
            System.assert(!html.contains('##BARCODE:'), 'Should not contain raw marker');
        }
    }

    // --- HTML-template path: replaceBarcodeMarkersInHtml (v3.15) ---------------

    @IsTest
    static void testReplaceBarcodeMarkersInHtmlCode128() {
        // Marker embedded in already-HTML content (e.g. an HTML template table cell).
        String html = '<td class="x">SKU: ##BARCODE:code128:200x44:PWG-1001##</td>';
        String out = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(html);
        System.assert(!out.contains('##BARCODE:'), 'Marker must be converted, not left raw');
        System.assert(out.contains('display:inline-block'), 'Should render Code 128 CSS bars');
        // Surrounding HTML must be preserved unescaped (not &lt;td&gt;).
        System.assert(out.contains('<td class="x">'), 'Surrounding HTML must not be escaped');
        System.assert(out.contains('SKU:'), 'Surrounding text preserved');
    }

    @IsTest
    static void testReplaceBarcodeMarkersInHtmlQr() {
        String html = '<div>Scan: ##BARCODE:qr:160:https://verify.portwood.dev/c/ABC##</div>';
        String out = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(html);
        System.assert(!out.contains('##BARCODE:'), 'QR marker must be converted');
        System.assert(out.contains('display:inline-block'), 'Should render QR CSS modules');
        System.assert(out.contains('<div>'), 'Surrounding HTML preserved');
    }

    @IsTest
    static void testReplaceBarcodeMarkersInHtmlMultipleAndNoMarker() {
        // Two markers in one body (e.g. a loop) are both converted.
        String html = '<tr><td>##BARCODE:code128::A1##</td><td>##BARCODE:qr::A1##</td></tr>';
        String out = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(html);
        System.assert(!out.contains('##BARCODE:'), 'All markers converted');
        System.assert(
            out.contains('<tr><td>') && out.contains('</td><td>'),
            'Surrounding table HTML preserved around both markers'
        );
        // No marker / null / blank are passthrough.
        System.assertEquals('<p>no codes</p>', DocGenHtmlRenderer.replaceBarcodeMarkersInHtml('<p>no codes</p>'));
        System.assertEquals(null, DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(null));
        System.assertEquals('', DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(''));
    }

    @IsTest
    static void testRenderBarcodeCode128WithSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:code128:300x80:TEST##';
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' +
                barcodeMarker +
                '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            // pt-based renderer: 80px request → 60pt height, integer-pt bars
            // (px-specified absolute offsets pick up Flying Saucer point
            // rounding that breaks scanners — see renderLinearBarcodeHtml).
            System.assert(html.contains('height:60pt'), 'Should use custom height 80px → 60pt: ' + html);
            System.assert(html.contains('display:inline-block'), 'Should render as bars');
            System.assert(html.contains('position:absolute'), 'Bars are absolutely positioned (zero-gap)');
        }
    }

    // =========================================================================
    // QR code rendering — renderQrHtml
    // =========================================================================

    @IsTest
    static void testRenderBarcodeQr() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:qr::Hello##';
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' +
                barcodeMarker +
                '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            // QR renders as position:relative container with absolute spans
            System.assert(html.contains('position:relative'), 'Should render QR with position:relative container');
            System.assert(html.contains('position:absolute'), 'Should render QR modules as absolute spans');
            System.assert(!html.contains('##BARCODE:'), 'Should not contain raw marker');
        }
    }

    @IsTest
    static void testRenderBarcodeQrWithSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String barcodeMarker = '##BARCODE:qr:200:TestQR##';
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' +
                barcodeMarker +
                '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('position:relative'), 'Should render QR container');
        }
    }

    @IsTest
    static void testRenderBarcodeSurroundingText() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Text before and after barcode marker
            String barcodeMarker = 'Before##BARCODE:code128::VAL##After';
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>' +
                barcodeMarker +
                '</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Before'), 'Should preserve text before barcode');
            System.assert(html.contains('After'), 'Should preserve text after barcode');
        }
    }

    // =========================================================================
    // List rendering — <w:numPr> for bulleted/numbered lists
    // =========================================================================

    @IsTest
    static void testBulletedList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:numPr with odd numId = bullet list
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Bullet One</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Bullet Two</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ul>'), 'Should contain unordered list');
            System.assert(html.contains('<li'), 'Should contain list items');
            System.assert(html.contains('Bullet One'), 'Should contain first item');
            System.assert(html.contains('Bullet Two'), 'Should contain second item');
            System.assert(html.contains('</ul>'), 'Should close list');
        }
    }

    @IsTest
    static void testNumberedList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Set numbering.xml so the renderer can resolve numId 2 as decimal
            DocGenHtmlRenderer.numberingXml =
                '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>' +
                '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>' +
                '</w:numbering>';

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Step One</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Step Two</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ol>'), 'Should contain ordered list');
            System.assert(html.contains('<li'), 'Should contain list items');
            System.assert(html.contains('Step One'), 'Should contain first item');
            System.assert(html.contains('</ol>'), 'Should close ordered list');

            DocGenHtmlRenderer.numberingXml = null;
        }
    }

    @IsTest
    static void testListStyleParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // ListParagraph style without numPr
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/></w:pPr>' +
                '<w:r><w:t>List Item</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<ul>') || html.contains('<ol>'), 'Should render as list');
            System.assert(html.contains('List Item'), 'Should contain list text');
        }
    }

    @IsTest
    static void testListNumIdZero() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // numId 0 means "no list" in OOXML
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="0"/></w:numPr></w:pPr>' +
                '<w:r><w:t>Not a list</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(!html.contains('<ul>') && !html.contains('<ol>'), 'numId 0 should not produce a list');
            System.assert(html.contains('Not a list'), 'Should contain text');
        }
    }

    // =========================================================================
    // Tab stops — processTabRun
    // =========================================================================

    @IsTest
    static void testTabStop() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:tab/></w:r><w:r><w:t>After tab</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('width:36pt'), 'Should render tab as fixed-width space');
            System.assert(html.contains('After tab'), 'Should contain text after tab');
        }
    }

    @IsTest
    static void testTabStopWithStyledText() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Tab run that also contains text with run properties
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:b/></w:rPr><w:tab/><w:t>TabText</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('width:36pt'), 'Should render tab space');
            System.assert(html.contains('TabText'), 'Should contain text after tab');
        }
    }

    // =========================================================================
    // Subscript/Superscript — w:vertAlign
    // =========================================================================

    @IsTest
    static void testSubscript() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>2</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<sub>'), 'Should contain subscript tag');
            System.assert(html.contains('</sub>'), 'Should close subscript tag');
        }
    }

    @IsTest
    static void testSuperscript() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>TM</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<sup>'), 'Should contain superscript tag');
            System.assert(html.contains('</sup>'), 'Should close superscript tag');
        }
    }

    // =========================================================================
    // Cell borders — addBorderStyles with <w:tcBorders>
    // =========================================================================

    @IsTest
    static void testCellBorders() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcBorders>' +
                '<w:top w:val="single" w:sz="8" w:color="FF0000"/>' +
                '<w:bottom w:val="dashed" w:sz="4" w:color="00FF00"/>' +
                '<w:left w:val="dotted" w:sz="4" w:color="0000FF"/>' +
                '<w:right w:val="double" w:sz="12" w:color="000000"/>' +
                '</w:tcBorders>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>Bordered</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('border-top:'), 'Should have top border');
            System.assert(html.contains('border-bottom:'), 'Should have bottom border');
            System.assert(html.contains('border-left:'), 'Should have left border');
            System.assert(html.contains('border-right:'), 'Should have right border');
            System.assert(html.contains('#FF0000'), 'Should have red top border');
            System.assert(html.contains('dashed'), 'Should have dashed bottom border');
            System.assert(html.contains('dotted'), 'Should have dotted left border');
            System.assert(html.contains('double'), 'Should have double right border');
        }
    }

    @IsTest
    static void testCellBordersStartEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:start and w:end instead of w:left and w:right
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcBorders>' +
                '<w:start w:val="single" w:sz="4" w:color="111111"/>' +
                '<w:end w:val="single" w:sz="4" w:color="222222"/>' +
                '</w:tcBorders>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>StartEnd</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('border-left:'), 'Should have left border from w:start');
            System.assert(html.contains('border-right:'), 'Should have right border from w:end');
        }
    }

    // =========================================================================
    // Cell padding — addCellPaddingStyles with <w:tcMar>
    // =========================================================================

    @IsTest
    static void testCellPadding() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcMar>' +
                '<w:top w:w="100" w:type="dxa"/>' +
                '<w:bottom w:w="200" w:type="dxa"/>' +
                '<w:left w:w="150" w:type="dxa"/>' +
                '<w:right w:w="150" w:type="dxa"/>' +
                '</w:tcMar>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>Padded</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('padding:'), 'Should have padding style');
            System.assert(html.contains('Padded'), 'Should contain text');
        }
    }

    @IsTest
    static void testCellPaddingStartEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // w:start and w:end instead of w:left and w:right
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr>' +
                '<w:tcMar>' +
                '<w:top w:w="80" w:type="dxa"/>' +
                '<w:bottom w:w="80" w:type="dxa"/>' +
                '<w:start w:w="120" w:type="dxa"/>' +
                '<w:end w:w="120" w:type="dxa"/>' +
                '</w:tcMar>' +
                '</w:tcPr>' +
                '<w:p><w:r><w:t>StartEndPad</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('padding:'), 'Should have padding using start/end');
        }
    }

    // =========================================================================
    // Cell merge — <w:gridSpan> (column span)
    // =========================================================================

    @IsTest
    static void testCellGridSpan() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr>' +
                '<w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr>' +
                '<w:p><w:r><w:t>Spanning 3 columns</w:t></w:r></w:p></w:tc>' +
                '</w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('colspan="3"'), 'Should have colspan=3');
            System.assert(html.contains('Spanning 3 columns'), 'Should contain spanned text');
        }
    }

    // =========================================================================
    // fontFaceCss parameter — custom font CSS injection
    // =========================================================================

    @IsTest
    static void testFontFaceCssInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>Custom Font</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String fontCss = '@font-face { font-family: "CustomFont"; src: url("data:font/woff2;base64,ABC"); }';
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), fontCss);

            System.assert(html.contains('@font-face'), 'Should contain custom font-face CSS');
            System.assert(html.contains('CustomFont'), 'Should contain custom font name');
            System.assert(html.contains('Custom Font'), 'Should contain body text');
            // The custom CSS should come before the base styles
            Integer fontFacePos = html.indexOf('@font-face');
            Integer baseStylePos = html.indexOf('@page');
            System.assert(fontFacePos < baseStylePos, 'Font-face CSS should come before base styles');
        }
    }

    @IsTest
    static void testFontFaceCssNull() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:t>No Custom Font</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            // Null fontFaceCss should use default prefix
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), null);

            System.assert(!html.contains('@font-face'), 'Should not contain font-face when null');
            System.assert(html.contains('No Custom Font'), 'Should contain body text');
        }
    }

    // =========================================================================
    // Image with Salesforce URL — exercises URL-based img rendering
    // =========================================================================

    @IsTest
    static void testImageWithSfcUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, String> images = new Map<String, String>{
                'rIdSfc1' => '/sfc/servlet.shepherd/version/download/068000000000001'
            };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdSfc1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);

            System.assert(html.contains('<img'), 'Should contain img tag');
            System.assert(html.contains('/sfc/servlet.shepherd'), 'Should use Salesforce URL directly');
            System.assert(!html.contains('data:image'), 'Should not use data URI for SF URLs');
        }
    }

    // =========================================================================
    // Heading styles
    // =========================================================================

    @IsTest
    static void testHeadingStyles() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Section</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<h1'), 'Should contain h1 tag');
            System.assert(html.contains('<h2'), 'Should contain h2 tag');
            System.assert(html.contains('Title'), 'Should contain heading text');
        }
    }

    @IsTest
    static void testTitleStyle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Doc Title</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<h1'), 'Title style should render as h1');
            System.assert(html.contains('26pt'), 'Title should have 26pt font size');
            System.assert(html.contains('Doc Title'), 'Should contain title text');
        }
    }

    // =========================================================================
    // All caps and small caps
    // =========================================================================

    @IsTest
    static void testAllCaps() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:caps/></w:rPr><w:t>lowercase text</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('LOWERCASE TEXT'), 'Should uppercase text with w:caps');
        }
    }

    @IsTest
    static void testSmallCaps() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:smallCaps/></w:rPr><w:t>small caps</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('SMALL CAPS'), 'Should uppercase text with smallCaps');
            System.assert(html.contains('font-variant:small-caps'), 'Should add small-caps font variant');
        }
    }

    // =========================================================================
    // Page break rendering
    // =========================================================================

    @IsTest
    static void testPageBreakInParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t>After Break</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('page-break-before:always'), 'Should contain page break');
            System.assert(html.contains('After Break'), 'Should contain text after break');
        }
    }

    @IsTest
    static void testPageBreakInRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="page"/></w:r><w:r><w:t>Next Page</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('page-break-before:always'), 'Should contain page break from run');
        }
    }

    // =========================================================================
    // Hyperlink rendering
    // =========================================================================

    // A <w:hyperlink r:id="..."> the way Word writes it for Insert → Link.
    private static String hyperlinkDocXml(String linkText) {
        return '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p><w:hyperlink r:id="rId5" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<w:r><w:t>' +
            linkText +
            '</w:t></w:r>' +
            '</w:hyperlink></w:p>' +
            '</w:body></w:document>';
    }

    // word/_rels/document.xml.rels holding one hyperlink relationship for rId5.
    private static String hyperlinkRelsXml(String target, String targetMode) {
        return '<?xml version="1.0" encoding="UTF-8"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
            '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"' +
            ' Target="' +
            target +
            '"' +
            (targetMode == null ? '' : ' TargetMode="' + targetMode + '"') +
            '/>' +
            '</Relationships>';
    }

    // #363 — with the rels resolved, a Word-authored link emits a real <a href>.
    @IsTest
    static void testHyperlinkResolvesUrlFromRels() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = DocGenHtmlRenderer.resolveHyperlinkRelIds(
                hyperlinkDocXml('form X'),
                hyperlinkRelsXml('https://example.com/formX', 'External')
            );

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<a href='), 'Word-authored hyperlink should emit an anchor. Got: ' + html);
            System.assert(
                html.contains('<a href="https://example.com/formX"'),
                'Anchor should carry the URL resolved from the rels part. Got: ' + html
            );
            System.assert(html.contains('form X'), 'Should contain link text');
            System.assert(html.contains('color:#0563C1'), 'Should have link color');
            System.assert(html.contains('text-decoration:underline'), 'Should have underline');
        }
    }

    // A query string's & is escaped in the rels part and must reach the href that way,
    // neither raw (malformed HTML) nor double-escaped.
    @IsTest
    static void testHyperlinkQueryStringAmpersandStaysEscaped() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = DocGenHtmlRenderer.resolveHyperlinkRelIds(
                hyperlinkDocXml('Report'),
                hyperlinkRelsXml('https://example.com/r?a=1&amp;b=2', 'External')
            );

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(
                html.contains('<a href="https://example.com/r?a=1&amp;b=2"'),
                'Ampersand should stay XML-escaped exactly once. Got: ' + html
            );
            System.assert(!html.contains('&amp;amp;'), 'Ampersand should not be double-escaped. Got: ' + html);
        }
    }

    // Internal (non-External) targets are file paths, not URLs — no anchor.
    @IsTest
    static void testHyperlinkInternalTargetNotLinked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = DocGenHtmlRenderer.resolveHyperlinkRelIds(
                hyperlinkDocXml('Click Here'),
                hyperlinkRelsXml('other.docx', null)
            );

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(!html.contains('<a href='), 'Internal target should not emit an anchor. Got: ' + html);
            System.assert(html.contains('Click Here'), 'Should still render the text');
            System.assert(html.contains('color:#0563C1'), 'Should keep the link styling');
        }
    }

    // A hand-built .docx can point a relationship at a script URL; the styled-span
    // fallback is the correct output, since this HTML also renders in the signature viewer.
    @IsTest
    static void testHyperlinkUnsafeSchemeNotLinked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(
                    hyperlinkDocXml('Click Here'),
                    hyperlinkRelsXml('javascript:alert(1)', 'External')
                )
            );
            System.assert(!html.contains('<a href='), 'javascript: should not become an anchor. Got: ' + html);
            System.assert(!html.containsIgnoreCase('javascript:'), 'Script URL should not reach output. Got: ' + html);

            // Entity-obfuscated variant — the raw prefix isn't what a browser resolves.
            String obfuscated = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(
                    hyperlinkDocXml('Click Here'),
                    hyperlinkRelsXml('java&#115;cript:alert(1)', 'External')
                )
            );
            System.assert(
                !obfuscated.contains('<a href='),
                'Obfuscated script URL should not link. Got: ' + obfuscated
            );
        }
    }

    // mailto: is what Word writes for an email link and must survive.
    @IsTest
    static void testHyperlinkMailtoResolves() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String html = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(
                    hyperlinkDocXml('Email us'),
                    hyperlinkRelsXml('mailto:sales@example.com', 'External')
                )
            );
            System.assert(
                html.contains('<a href="mailto:sales@example.com"'),
                'mailto: link should resolve. Got: ' + html
            );
        }
    }

    // Without a rels part there is nothing to resolve — the pre-#363 styled-span
    // fallback stays, and it must not throw or drop the text.
    @IsTest
    static void testHyperlinkWithoutRelsFallsBackToStyledText() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = hyperlinkDocXml('Click Here');
            System.assertEquals(xml, DocGenHtmlRenderer.resolveHyperlinkRelIds(xml, null), 'Null rels is a no-op');

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(!html.contains('<a href='), 'No rels means no URL to emit. Got: ' + html);
            System.assert(html.contains('Click Here'), 'Should contain link text');
            System.assert(html.contains('color:#0563C1'), 'Should have link color');
            System.assert(html.contains('text-decoration:underline'), 'Should have underline');
        }
    }

    // Rich-text-generated links already carry w:docgen-url; resolution must leave them alone.
    @IsTest
    static void testHyperlinkRichTextUrlNotRestamped() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p>' +
                '<w:hyperlink w:docgen-url="https://example.com/rich" r:id="rId5"' +
                ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                '<w:r><w:t>Rich</w:t></w:r></w:hyperlink>' +
                '</w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(xml, hyperlinkRelsXml('https://example.com/rels', 'External'))
            );

            System.assert(
                html.contains('<a href="https://example.com/rich"'),
                'Existing docgen-url should win over the rels target. Got: ' + html
            );
            System.assert(!html.contains('example.com/rels'), 'Should not restamp a resolved link. Got: ' + html);
        }
    }

    // An in-document bookmark has no r:id at all — left alone, per #363's scope note.
    @IsTest
    static void testHyperlinkAnchorOnlyUnchanged() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:hyperlink w:anchor="_Toc123">' +
                '<w:r><w:t>Section 2</w:t></w:r></w:hyperlink></w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(xml, hyperlinkRelsXml('https://example.com/x', 'External'))
            );

            System.assert(!html.contains('<a href='), 'Bookmark link should not borrow an unrelated target');
            System.assert(html.contains('Section 2'), 'Should contain link text');
        }
    }

    // Two links in one paragraph, one resolvable and one not — each takes its own branch,
    // and the surrounding runs survive the rewrite intact.
    @IsTest
    static void testHyperlinkMixedResolutionInOneParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
                ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                '<w:body><w:p>' +
                '<w:r><w:t xml:space="preserve">See </w:t></w:r>' +
                '<w:hyperlink r:id="rId5"><w:r><w:t>form X</w:t></w:r></w:hyperlink>' +
                '<w:r><w:t xml:space="preserve"> and </w:t></w:r>' +
                '<w:hyperlink r:id="rId9"><w:r><w:t>form Y</w:t></w:r></w:hyperlink>' +
                '<w:r><w:t> today.</w:t></w:r>' +
                '</w:p></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(
                DocGenHtmlRenderer.resolveHyperlinkRelIds(
                    xml,
                    hyperlinkRelsXml('https://example.com/formX', 'External')
                )
            );

            System.assert(html.contains('<a href="https://example.com/formX"'), 'rId5 should link. Got: ' + html);
            System.assertEquals(1, html.countMatches('<a href='), 'Only rId5 resolves; rId9 has no rel. Got: ' + html);
            System.assert(html.contains('form Y'), 'Unresolved link keeps its text');
            System.assert(html.contains('See ') && html.contains(' today.'), 'Surrounding runs preserved');
        }
    }

    // =========================================================================
    // Horizontal rule (empty paragraph with bottom border)
    // =========================================================================

    @IsTest
    static void testHorizontalRule() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:color="000000"/></w:pBdr></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<hr/>'), 'Should render horizontal rule');
        }
    }

    // =========================================================================
    // Letter spacing
    // =========================================================================

    @IsTest
    static void testLetterSpacing() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:spacing w:val="40"/></w:rPr><w:t>Spaced</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('letter-spacing:'), 'Should contain letter-spacing style');
        }
    }

    // =========================================================================
    // Header row (th)
    // =========================================================================

    @IsTest
    static void testTableHeaderRow() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:trPr><w:tblHeader/></w:trPr>' +
                '<w:tc><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Data</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<th'), 'Should render header cell as th');
            System.assert(html.contains('<td'), 'Should render data cell as td');
        }
    }

    @IsTest
    static void testRepeatHeaderRowWrappedInThead() {
        // A row carrying <w:tblHeader/> (the structural flag {RepeatHeader} injects) must
        // be grouped into <thead>, which Flying Saucer reprints on every page. Data rows
        // stay outside it.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:t>Code</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>105</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl></w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('<thead>'), 'Repeat-header row must be grouped into <thead>. Got: ' + html);
            System.assert(
                html.indexOf('Code') < html.indexOf('</thead>'),
                'Header text must sit inside <thead>. Got: ' + html
            );
            System.assert(
                html.indexOf('</thead>') < html.indexOf('105'),
                'Data rows must follow </thead>, not be inside it. Got: ' + html
            );
        }
    }

    // =========================================================================
    // Hyperlink rendering
    // =========================================================================

    @IsTest
    static void testHyperlinkExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:hyperlink r:id="rId5" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                '<w:r><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr><w:t>Click here</w:t></w:r>' +
                '</w:hyperlink></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);

            System.assert(html.contains('Click here'), 'Should contain hyperlink text');
            System.assert(html.contains('text-decoration:underline'), 'Should have underline styling');
        }
    }

    @IsTest
    static void testHyperlinkEmptyContent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Hyperlink with no inner runs — should render empty
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:hyperlink></w:hyperlink></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<body>'), 'Should produce valid HTML');
        }
    }

    // =========================================================================
    // convertToHtml with fontFaceCss
    // =========================================================================

    @IsTest
    static void testConvertToHtmlWithFontFaceCss() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>FontTest</w:t></w:r></w:p></w:body></w:document>';

            String fontCss = '@font-face { font-family: "Custom"; src: url("data:;base64,abc"); }';
            String html = DocGenHtmlRenderer.convertToHtml(xml, new Map<String, String>(), fontCss);

            System.assert(html.contains('@font-face'), 'Should inject font-face CSS');
            System.assert(html.contains('FontTest'), 'Should contain text');
        }
    }

    // =========================================================================
    // Page break in run (w:br type="page")
    // =========================================================================

    @IsTest
    static void testPageBreakInRunExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="page"/></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-before:always'), 'Should contain page break');
        }
    }

    // =========================================================================
    // Column break in run
    // =========================================================================

    @IsTest
    static void testColumnBreakInRun() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:br w:type="column"/></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<br/>'), 'Column break should render as br');
        }
    }

    // =========================================================================
    // Paragraph with page break before (w:pageBreakBefore)
    // =========================================================================

    @IsTest
    static void testPageBreakBeforeParagraph() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pageBreakBefore/></w:pPr><w:r><w:t>After break</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-before:always'), 'Should have page break before');
            System.assert(html.contains('After break'), 'Should contain text after break');
        }
    }

    // =========================================================================
    // Horizontal rule (empty paragraph with bottom border)
    // =========================================================================

    @IsTest
    static void testHorizontalRuleExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:color="000000"/></w:pBdr></w:pPr></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<hr/>'), 'Should render as horizontal rule');
        }
    }

    // =========================================================================
    // Heading styles (h1-h6) and Title/Subtitle
    // =========================================================================

    @IsTest
    static void testHeadingStylesExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>H1</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>' +
                '<w:p><w:pPr><w:pStyle w:val="Subtitle"/></w:pPr><w:r><w:t>Sub</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<h1'), 'Should contain h1 for Heading1');
            System.assert(html.contains('26pt'), 'Should contain Title style with 26pt');
            System.assert(html.contains('14pt'), 'Should contain Subtitle style with 14pt');
        }
    }

    // =========================================================================
    // Paragraph shading
    // =========================================================================

    @IsTest
    static void testParagraphShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:shd w:val="clear" w:fill="FFFF00"/></w:pPr>' +
                '<w:r><w:t>Highlighted</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('background-color:#FFFF00'), 'Should have paragraph shading');
        }
    }

    // =========================================================================
    // Paragraph borders
    // =========================================================================

    @IsTest
    static void testParagraphBorders() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr>' +
                '<w:top w:val="single" w:sz="4" w:color="FF0000"/>' +
                '<w:bottom w:val="dashed" w:sz="4" w:color="00FF00"/>' +
                '<w:left w:val="dotted" w:sz="4" w:color="0000FF"/>' +
                '<w:right w:val="double" w:sz="4" w:color="000000"/>' +
                '</w:pBdr></w:pPr>' +
                '<w:r><w:t>Bordered</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('border-top:'), 'Should have top border');
            System.assert(html.contains('border-bottom:'), 'Should have bottom border');
            System.assert(html.contains('padding:4pt'), 'Should have padding when borders exist');
        }
    }

    // =========================================================================
    // Keep with next / Keep lines together
    // =========================================================================

    @IsTest
    static void testKeepWithNextAndKeepLines() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:keepNext/><w:keepLines/></w:pPr>' +
                '<w:r><w:t>Keep</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('page-break-after:avoid'), 'Should have keepNext CSS');
            System.assert(html.contains('page-break-inside:avoid'), 'Should have keepLines CSS');
        }
    }

    // =========================================================================
    // Line spacing — exact and auto modes
    // =========================================================================

    @IsTest
    static void testLineSpacingExact() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="exact"/></w:pPr>' +
                '<w:r><w:t>Exact spacing</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('line-height:'), 'Should have line-height for exact spacing');
        }
    }

    @IsTest
    static void testLineSpacingAuto() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr>' +
                '<w:r><w:t>Auto spacing</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('line-height:1.5'), 'Should have 1.5x line-height for 360/240');
        }
    }

    // =========================================================================
    // Hanging indent
    // =========================================================================

    @IsTest
    static void testHangingIndent() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:ind w:hanging="360"/></w:pPr>' +
                '<w:r><w:t>Hanging</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('text-indent:-'), 'Should have negative text-indent for hanging');
            System.assert(html.contains('padding-left:'), 'Should have compensating padding-left');
        }
    }

    // =========================================================================
    // All caps and small caps
    // =========================================================================

    @IsTest
    static void testAllCapsExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:caps/></w:rPr><w:t>hello</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('HELLO'), 'Should uppercase text for caps');
        }
    }

    @IsTest
    static void testSmallCapsExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:smallCaps/></w:rPr><w:t>test</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('font-variant:small-caps'), 'Should have small-caps style');
        }
    }

    // =========================================================================
    // Run shading (w:shd in rPr)
    // =========================================================================

    @IsTest
    static void testRunShading() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:shd w:val="clear" w:fill="00FF00"/></w:rPr><w:t>Shaded</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('background-color:#00FF00'), 'Should have run shading color');
        }
    }

    // =========================================================================
    // Letter spacing
    // =========================================================================

    @IsTest
    static void testLetterSpacingExtended() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:rPr><w:spacing w:val="40"/></w:rPr><w:t>Spaced</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('letter-spacing:'), 'Should have letter spacing');
        }
    }

    // =========================================================================
    // Table alignment (center and right)
    // =========================================================================

    @IsTest
    static void testTableAlignmentCenter() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:jc w:val="center"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Centered Table</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-left:auto'), 'Should center table with auto margins');
            System.assert(html.contains('margin-right:auto'), 'Should center table with auto margins');
        }
    }

    @IsTest
    static void testTableAlignmentRight() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr><w:jc w:val="right"/></w:tblPr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Right Table</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('margin-left:auto'), 'Should right-align table with margin-left:auto');
        }
    }

    // =========================================================================
    // Cell colspan (w:gridSpan)
    // =========================================================================

    @IsTest
    static void testCellColspan() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:tbl><w:tblPr></w:tblPr>' +
                '<w:tr><w:tc><w:tcPr><w:gridSpan w:val="3"/></w:tcPr>' +
                '<w:p><w:r><w:t>Spanning</w:t></w:r></w:p></w:tc></w:tr>' +
                '</w:tbl>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('colspan="3"'), 'Should have colspan attribute');
        }
    }

    // =========================================================================
    // Image with URL path (not base64)
    // =========================================================================

    @IsTest
    static void testImageWithRelativeUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Map<String, String> images = new Map<String, String>{
                'rIdUrl' => '/sfc/servlet.shepherd/version/download/068000000000001'
            };

            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:r><w:drawing>' +
                '<wp:inline xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="1905000" cy="952500"/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:blipFill><a:blip r:embed="rIdUrl" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></pic:blipFill>' +
                '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml, images);
            System.assert(html.contains('<img'), 'Should contain img tag');
            System.assert(html.contains('/sfc/servlet.shepherd'), 'Should use relative URL directly');
        }
    }

    // =========================================================================
    // ListNumber style detection
    // =========================================================================

    @IsTest
    static void testListNumberStyle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pStyle w:val="ListNumber"/></w:pPr>' +
                '<w:r><w:t>Numbered Item</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            System.assert(html.contains('<ol>'), 'ListNumber should render as ordered list');
            System.assert(html.contains('Numbered Item'), 'Should contain list text');
        }
    }

    // =========================================================================
    // Border style nil/none renders no border
    // =========================================================================

    @IsTest
    static void testBorderNilRendersNoBorder() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml =
                '<?xml version="1.0" encoding="UTF-8"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body>' +
                '<w:p><w:pPr><w:pBdr>' +
                '<w:top w:val="nil"/>' +
                '</w:pBdr></w:pPr>' +
                '<w:r><w:t>NoBorder</w:t></w:r></w:p>' +
                '</w:body></w:document>';

            String html = DocGenHtmlRenderer.convertToHtml(xml);
            // Check body content only (skip <head> CSS which contains border-top in hr rule)
            String body = html.substringAfter('<body>');
            System.assert(!body.contains('border-top:'), 'nil border should not render');
            System.assert(html.contains('NoBorder'), 'Should contain text');
        }
    }

    // =========================================================================
    // RTL / Bidi Tests
    // =========================================================================

    @IsTest
    static void testRtlParagraphTextReversed() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:pPr><w:bidi/></w:pPr>' +
            '<w:r><w:rPr><w:rtl/></w:rPr><w:t>\u05E9\u05DC\u05D5\u05DD</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('\u05DD\u05D5\u05DC\u05E9'), 'Hebrew should be reversed');
        System.assert(html.contains('text-align:right'), 'RTL paragraph should be right-aligned');
    }

    @IsTest
    static void testRtlRunEnglishNotReversed() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:pPr><w:bidi/></w:pPr>' +
            '<w:r><w:rPr><w:rtl/></w:rPr><w:t>James Smith</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('James Smith'), 'English text should not be reversed');
    }

    @IsTest
    static void testRtlTableBidiVisualReversesCells() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:tbl><w:tblPr><w:bidiVisual/><w:tblBorders>' +
            '<w:top w:val="single" w:sz="4" w:color="000000"/></w:tblBorders></w:tblPr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>CellA</w:t></w:r></w:p></w:tc>' +
            '<w:tc><w:p><w:r><w:t>CellB</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        Integer posB = html.indexOf('CellB');
        Integer posA = html.indexOf('CellA');
        System.assert(posB < posA, 'bidiVisual should reverse cell order');
    }

    @IsTest
    static void testRtlRunOrderReversed() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:pPr><w:bidi/></w:pPr>' +
            '<w:r><w:rPr><w:rtl/></w:rPr><w:t>\u05E8\u05D0\u05E9\u05D5\u05DF</w:t></w:r>' +
            '<w:r><w:rPr><w:rtl/></w:rPr><w:t>\u05E9\u05E0\u05D9</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        Integer pos1 = html.indexOf('\u05DF\u05D5\u05E9\u05D0\u05E8');
        Integer pos2 = html.indexOf('\u05D9\u05E0\u05E9');
        System.assert(pos2 < pos1, 'RTL runs should be reversed in order');
    }

    @IsTest
    static void testRtlDefaultStyleInherited() {
        DocGenHtmlRenderer.stylesXml = TestDataFactory.buildRtlStylesXml();
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:rPr><w:rtl/></w:rPr><w:t>\u05E9\u05DC\u05D5\u05DD</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('text-align: right'), 'Body should inherit RTL from Normal style');
        System.assert(html.contains('Arial Unicode MS'), 'RTL doc should use Arial Unicode MS');
        DocGenHtmlRenderer.stylesXml = null;
    }

    @IsTest
    static void testRtlComplexScriptFont() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:rPr><w:rtl/><w:rFonts w:cs="David"/></w:rPr>' +
            '<w:t>\u05E9\u05DC\u05D5\u05DD</w:t></w:r></w:p></w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Arial Unicode MS'), 'RTL run should use Arial Unicode MS');
    }

    @IsTest
    static void testRtlIndentStartEndFallback() {
        String xml =
            '<?xml version="1.0" encoding="UTF-8"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:pPr><w:bidi/><w:ind w:start="720" w:end="360"/></w:pPr>' +
            '<w:r><w:t>Test</w:t></w:r></w:p></w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('margin-left'), 'w:start should fallback to margin-left');
        System.assert(html.contains('margin-right'), 'w:end should fallback to margin-right');
    }

    @IsTest
    static void testRtlFullDocument() {
        DocGenHtmlRenderer.stylesXml = TestDataFactory.buildRtlStylesXml();
        String xml = TestDataFactory.buildRtlDocXml();
        String html = DocGenHtmlRenderer.convertToHtml(xml);
        System.assert(html.contains('Arial Unicode MS'), 'RTL doc should use Arial Unicode MS');
        System.assert(html.contains('text-align: right'), 'RTL doc should be right-aligned');
        System.assert(html.contains('<table'), 'Should contain table');
        DocGenHtmlRenderer.stylesXml = null;
    }

    // Word picture watermarks are inserted as VML inside the header XML —
    // <w:pict><v:shape><v:imagedata r:id="..."/></v:shape></w:pict>. v1.65+ the
    // renderer converts these into @page { background-image: url(...) } CSS
    // (Flying Saucer's true page-bleed mechanism) instead of inline divs.
    @IsTest
    static void testVmlPictWatermarkRendering() {
        String headerXml =
            '<w:hdr><w:p><w:r><w:pict>' +
            '<v:shape id="PowerPlusWaterMarkObject" style="position:absolute;width:468pt;height:240pt" type="#_x0000_t75">' +
            '<v:imagedata r:id="rIdImg1" o:title=""/>' +
            '</v:shape>' +
            '</w:pict></w:r></w:p></w:hdr>';
        String docXml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
            '<!-- DOCGEN_HEADER_START -->' +
            headerXml +
            '<!-- DOCGEN_HEADER_END -->' +
            '<w:p><w:r><w:t>Body</w:t></w:r></w:p></w:body></w:document>';
        Map<String, String> images = new Map<String, String>{
            'rIdImg1' => '/sfc/servlet.shepherd/version/download/068000000000000'
        };
        String html = DocGenHtmlRenderer.convertToHtml(docXml, images, null);
        System.assert(html.contains('background-image: url'), 'VML pict should produce @page background-image CSS');
        System.assert(html.contains('068000000000000'), '@page background URL must reference the watermark CV');
        System.assert(html.contains('Body'), 'Body content must still render alongside the watermark');
    }

    // v1.65+ admin-uploaded watermark override beats any Word VML watermark in the template.
    @IsTest
    static void testOoxmlOnOffElementParsing() {
        // Self-closing — implicit val="1" per spec
        System.assertEquals(true, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi/>', 'w:bidi'));
        // Attributed without val — defaults to true per spec
        System.assertEquals(true, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:foo="x"/>', 'w:bidi'));
        // Truthy values
        System.assertEquals(true, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="1"/>', 'w:bidi'));
        System.assertEquals(true, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="true"/>', 'w:bidi'));
        System.assertEquals(true, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="on"/>', 'w:bidi'));
        // Falsy values — these are the regression case (LibreOffice .doc→.docx conversion)
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="0"/>', 'w:bidi'));
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="false"/>', 'w:bidi'));
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi w:val="off"/>', 'w:bidi'));
        // Element absent
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:pPr></w:pPr>', 'w:bidi'));
        // Blank inputs
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue(null, 'w:bidi'));
        System.assertEquals(false, DocGenHtmlRenderer.isOoxmlOnOffElementTrue('<w:bidi/>', null));
    }

    @IsTest
    static void testLibreOfficeNormalStyleNotMisreadAsRtl() {
        // Regression for v1.80 #53: LibreOffice's .doc→.docx conversion injects
        // <w:bidi w:val="0"/> into the Normal style for English LTR documents.
        // The pre-decomp path passes styles.xml to the renderer (the ZIP path
        // doesn't) — before the fix, isDefaultStyleRtl() matched <w:bidi w:val="0"/>
        // and emitted text-align:right on body, which broke layout.
        DocGenHtmlRenderer.stylesXml =
            '<?xml version="1.0"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:style w:type="paragraph" w:styleId="Normal">' +
            '<w:name w:val="Normal"/><w:qFormat/>' +
            '<w:pPr><w:widowControl/><w:bidi w:val="0"/></w:pPr>' +
            '</w:style></w:styles>';
        try {
            String docXml =
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>';
            String html = DocGenHtmlRenderer.convertToHtml(docXml);
            System.assert(
                !html.contains('text-align: right'),
                'Body CSS must not emit text-align:right for an LTR doc whose Normal style has <w:bidi w:val="0"/>'
            );
        } finally {
            DocGenHtmlRenderer.stylesXml = null;
        }
    }

    @IsTest
    static void testHebrewNormalStyleStillDetectsRtl() {
        // Positive case: a real Hebrew/Arabic doc has <w:bidi/> (self-closing) in Normal.
        // After the v1.80 fix, this still must trigger RTL handling.
        DocGenHtmlRenderer.stylesXml =
            '<?xml version="1.0"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:style w:type="paragraph" w:styleId="Normal">' +
            '<w:name w:val="Normal"/><w:qFormat/>' +
            '<w:pPr><w:bidi/></w:pPr>' +
            '</w:style></w:styles>';
        try {
            String docXml =
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>שלום</w:t></w:r></w:p></w:body></w:document>';
            String html = DocGenHtmlRenderer.convertToHtml(docXml);
            System.assert(
                html.contains('text-align: right'),
                'Body CSS must emit text-align:right for an RTL doc whose Normal style has <w:bidi/>'
            );
        } finally {
            DocGenHtmlRenderer.stylesXml = null;
        }
    }

    @IsTest
    static void testFirstPageDistinctHeaderFooterRunningElements() {
        // Regression for v1.80 #57: <w:titlePg/> + separate "first" headerReference
        // must produce @page :first running elements pointing at the first-typed
        // header, not suppress the page-1 header entirely.
        String docXml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
            '<!-- DOCGEN_HEADER_START --><w:hdr><w:p><w:r><w:t>Default Header</w:t></w:r></w:p></w:hdr><!-- DOCGEN_HEADER_END -->' +
            '<!-- DOCGEN_HEADER_FIRST_START --><w:hdr><w:p><w:r><w:t>First Page Header</w:t></w:r></w:p></w:hdr><!-- DOCGEN_HEADER_FIRST_END -->' +
            '<!-- DOCGEN_FOOTER_START --><w:ftr><w:p><w:r><w:t>Default Footer</w:t></w:r></w:p></w:ftr><!-- DOCGEN_FOOTER_END -->' +
            '<!-- DOCGEN_FOOTER_FIRST_START --><w:ftr><w:p><w:r><w:t>First Page Footer</w:t></w:r></w:p></w:ftr><!-- DOCGEN_FOOTER_FIRST_END -->' +
            '<w:p><w:r><w:t>Body</w:t></w:r></w:p>' +
            '<w:sectPr><w:titlePg/></w:sectPr>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml);

        // Both default and first-page running elements must be wired up
        System.assert(
            html.contains('docgen-running-header-first'),
            'Expected first-page running header to be declared'
        );
        System.assert(
            html.contains('docgen-running-footer-first'),
            'Expected first-page running footer to be declared'
        );
        // @page :first must point at the first-typed elements (NOT suppress them)
        System.assert(html.contains('@page :first'), 'Expected @page :first rule to be emitted for titlePg doc');
        System.assert(
            html.contains('content: element(docgen-running-header-first)'),
            'Expected @page :first @top-center to point at first-page header running element'
        );
        // The body divs that get hoisted into running positions
        System.assert(html.contains('id="docgen-header-first"'), 'Expected first-page header div in body');
        System.assert(html.contains('First Page Header'), 'Expected first-page header content to render');
    }

    @IsTest
    static void testRunningHeaderFooterCarryDesignerRegionMarkers() {
        // DESIGNER_PLAN_V2 step 3 — a Word template's <w:hdr>/<w:ftr> used to land
        // inline at the top of the converted HTML, so switching that template to
        // HTML put the running header into the document BODY, where it printed once
        // in the flow instead of on every page.
        //
        // data-dg-region tells the Designer these divs are running chrome, so the
        // import routes them into Header_Html__c / Footer_Html__c. It is an
        // annotation only: Flying Saucer selects these divs by #id, so the running
        // element wiring and the rendered output are unchanged.
        String docXml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
            '<!-- DOCGEN_HEADER_START --><w:hdr><w:p><w:r><w:t>Running Header Text</w:t></w:r></w:p></w:hdr><!-- DOCGEN_HEADER_END -->' +
            '<!-- DOCGEN_FOOTER_START --><w:ftr><w:p><w:r><w:t>Running Footer Text</w:t></w:r></w:p></w:ftr><!-- DOCGEN_FOOTER_END -->' +
            '<w:p><w:r><w:t>Body Paragraph</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml);

        System.assert(
            html.contains('id="docgen-header" data-dg-region="header"'),
            'Expected the running header div to be marked as a header region for the Designer'
        );
        System.assert(
            html.contains('id="docgen-footer" data-dg-region="footer"'),
            'Expected the running footer div to be marked as a footer region for the Designer'
        );
        // The annotation must not disturb the running-element wiring that makes the
        // header repeat on every page.
        System.assert(
            html.contains('#docgen-header { position: running(docgen-running-header); }'),
            'Expected the running header CSS to be unchanged by the region annotation'
        );
        System.assert(
            html.contains('content: element(docgen-running-header)'),
            'Expected the @page margin box to still pull in the running header'
        );
        System.assert(html.contains('Running Header Text'), 'Expected header content to still render');
        System.assert(html.contains('Running Footer Text'), 'Expected footer content to still render');
        System.assert(html.contains('Body Paragraph'), 'Expected body content to still render');
    }

    @IsTest
    static void testTitlePgWithoutFirstHeaderFallsBackToSuppression() {
        // Backward compat: docs with <w:titlePg/> but no first-typed header
        // should suppress the default header on page 1 (legacy v1 behavior).
        String docXml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
            '<!-- DOCGEN_HEADER_START --><w:hdr><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:hdr><!-- DOCGEN_HEADER_END -->' +
            '<w:p><w:r><w:t>Body</w:t></w:r></w:p>' +
            '<w:sectPr><w:titlePg/></w:sectPr>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml);
        System.assert(html.contains('@page :first'), 'Expected @page :first rule');
        System.assert(
            html.contains('@top-center { content: normal'),
            'Expected default header to be suppressed on page 1'
        );
    }

    @IsTest
    static void testExtractMarkerSection() {
        Map<String, String> r = DocGenHtmlRenderer.extractMarkerSection(
            'before<!-- A -->payload<!-- B -->after',
            'A',
            'B'
        );
        System.assertEquals('payload', r.get('content'));
        System.assertEquals('beforeafter', r.get('remainder'));

        // Marker not present — content empty, remainder unchanged
        r = DocGenHtmlRenderer.extractMarkerSection('hello world', 'X', 'Y');
        System.assertEquals('', r.get('content'));
        System.assertEquals('hello world', r.get('remainder'));

        // Blank input
        r = DocGenHtmlRenderer.extractMarkerSection(null, 'X', 'Y');
        System.assertEquals('', r.get('content'));
    }

    @IsTest
    static void testDrawingEmitsHtmlWidthHeightAttributes() {
        // Regression for v1.80 #58: high-resolution embedded images (e.g. Mantis ROM
        // proposal: 15068×5731 native, Word displays at 8.46"×2.39" = 813×229 px) were
        // rendering at native pixel size in PDF because Flying Saucer's image scaler
        // resolves dimensions from HTML width/height attributes BEFORE applying CSS.
        // Without explicit attrs the engine fell back to natural pixel dimensions and
        // the CSS width:Xpx didn't override it. Fix: emit width="N" height="N" alongside
        // the inline style so Flying Saucer locks size at the HTML attribute layer.
        // EMU per px = 9525. 813px * 9525 = 7,743,825 EMU. 229px * 9525 = 2,181,225 EMU.
        String docXml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"' +
            ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"' +
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>' +
            '<w:p><w:r><w:drawing>' +
            '<wp:anchor><wp:extent cx="7743825" cy="2181225"/>' +
            '<a:graphic><a:graphicData><a:blip r:embed="rIdMantisHero"/></a:graphicData></a:graphic>' +
            '</wp:anchor></w:drawing></w:r></w:p></w:body></w:document>';
        Map<String, String> images = new Map<String, String>{
            'rIdMantisHero' => '/sfc/servlet.shepherd/version/download/068000000000ABC'
        };
        String html = DocGenHtmlRenderer.convertToHtml(docXml, images, null);
        System.assert(
            html.contains('width="813"'),
            'Drawing must emit HTML width attribute matching wp:extent — got: ' + html
        );
        System.assert(html.contains('height="229"'), 'Drawing must emit HTML height attribute matching wp:extent');
        // CSS still emitted as defense-in-depth
        System.assert(html.contains('width:813px;height:229px'), 'CSS width/height must still be emitted');
    }

    @IsTest
    static void testWatermarkOverrideBeatsVmlWatermark() {
        DocGenHtmlRenderer.overrideWatermarkCvId = '068000000000999';
        try {
            String headerXml =
                '<w:hdr><w:p><w:r><w:pict>' +
                '<v:shape id="PowerPlusWaterMarkObject" style="width:400pt;height:300pt" type="#_x0000_t75">' +
                '<v:imagedata r:id="rIdImg1"/>' +
                '</v:shape>' +
                '</w:pict></w:r></w:p></w:hdr>';
            String docXml =
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
                '<!-- DOCGEN_HEADER_START -->' +
                headerXml +
                '<!-- DOCGEN_HEADER_END -->' +
                '<w:p><w:r><w:t>Body</w:t></w:r></w:p></w:body></w:document>';
            Map<String, String> images = new Map<String, String>{
                'rIdImg1' => '/sfc/servlet.shepherd/version/download/068000000000111'
            };
            String html = DocGenHtmlRenderer.convertToHtml(docXml, images, null);
            System.assert(
                html.contains('068000000000999'),
                'Admin override CV must win over the Word VML watermark CV'
            );
            System.assert(!html.contains('068000000000111'), 'VML watermark CV should be skipped when override is set');
        } finally {
            DocGenHtmlRenderer.overrideWatermarkCvId = null;
        }
    }

    @IsTest
    static void injectAdminWatermark_htmlTemplate_overlayAfterBodyOpen() {
        DocGenHtmlRenderer.overrideWatermarkCvId = '068000000000999';
        try {
            String html = '<html><head><style>@page { size: A4 landscape; }</style></head><body><p>Hi</p></body></html>';
            String out = DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(html);
            System.assert(
                out.contains('<body><div class="docgen-watermark"'),
                'Overlay must be injected right after <body> — got: ' + out
            );
            System.assert(out.contains('068000000000999'), 'Overlay must reference the watermark CV');
            // A4 landscape: 11.693in wide x 8.268in tall
            System.assert(out.contains('width:11.693in'), 'A4 landscape width expected — got: ' + out);
            System.assert(out.contains('height:8.268in'), 'A4 landscape height expected');
            System.assert(out.contains('position:fixed'), 'Overlay must be position:fixed so it repeats every page');
        } finally {
            DocGenHtmlRenderer.overrideWatermarkCvId = null;
        }
    }

    @IsTest
    static void injectAdminWatermark_noWatermarkOrNoBody_safe() {
        String html = '<html><body><p>Hi</p></body></html>';
        System.assertEquals(
            html,
            DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(html),
            'No override set — HTML must pass through untouched'
        );
        DocGenHtmlRenderer.overrideWatermarkCvId = '068000000000999';
        try {
            // Explicit two-value size wins over keywords; no <body> tag → prepend
            String bare = '<div>@page is elsewhere</div>';
            String out = DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(bare);
            System.assert(out.startsWith('<div class="docgen-watermark"'), 'Overlay prepends when no body tag');
            System.assert(out.contains('width:8.5in'), 'Defaults to Letter portrait when no @page size');
            String sized = '<html><head><style>@page { size: 8.5in 14in; margin: 0.5in; }</style></head><body>x</body></html>';
            String out2 = DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(sized);
            System.assert(out2.contains('width:8.500in'), 'Explicit inch width honored — got: ' + out2);
            System.assert(out2.contains('height:14.000in'), 'Explicit inch height honored');
            // Page-setup overrides beat source @page
            DocGenHtmlRenderer.pageSizeOverride = 'Legal';
            DocGenHtmlRenderer.orientationOverride = 'Landscape';
            try {
                String out3 = DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(sized);
                System.assert(
                    out3.contains('width:14in') || out3.contains('width:14.0in'),
                    'Legal landscape width from override — got: ' + out3
                );
            } finally {
                DocGenHtmlRenderer.pageSizeOverride = null;
                DocGenHtmlRenderer.orientationOverride = null;
            }
        } finally {
            DocGenHtmlRenderer.overrideWatermarkCvId = null;
        }
    }

    @IsTest
    static void numericEntities_decimalAndHex_decodeToUnicode() {
        String input = 'Em&#8212;dash, middle&#183;dot, hex&#x2014;dash, curly&#8220;quote&#8221;.';
        String output = DocGenHtmlRenderer.unescapeXmlEntities(input);
        System.assertEquals(
            'Em—dash, middle·dot, hex—dash, curly“quote”.',
            output,
            'Numeric entities (decimal + hex) must decode to literal Unicode'
        );
    }

    @IsTest
    static void numericEntities_malformedAndControl_leftIntact() {
        System.assertEquals(
            '&#abc;',
            DocGenHtmlRenderer.decodeNumericEntities('&#abc;'),
            'Non-numeric body must be preserved'
        );
        System.assertEquals(
            '&#xZZ;',
            DocGenHtmlRenderer.decodeNumericEntities('&#xZZ;'),
            'Invalid hex must be preserved'
        );
        System.assertEquals(
            '&#0;',
            DocGenHtmlRenderer.decodeNumericEntities('&#0;'),
            'NUL control char must be preserved'
        );
        System.assertEquals(
            '&#7;',
            DocGenHtmlRenderer.decodeNumericEntities('&#7;'),
            'BEL control char must be preserved'
        );
        System.assertEquals(
            'no entities here',
            DocGenHtmlRenderer.decodeNumericEntities('no entities here'),
            'Plain text must be returned unchanged'
        );
    }

    @IsTest
    static void numericEntities_combineWithNamedEntities() {
        String input = 'A &amp; B &#8212; C &lt; D';
        String output = DocGenHtmlRenderer.unescapeXmlEntities(input);
        System.assertEquals('A & B — C < D', output, 'Numeric and named entities decode together');
    }

    @IsTest
    static void unwrapTextboxes_styledParagraph_doesNotSplitOrLeakMarker() {
        // Regression: the enclosing-paragraph lookup used lastIndexOf('<w:p', ...),
        // which prefix-matches <w:pStyle>/<w:pPr> sitting between the real <w:p> and
        // the textbox. It landed mid-paragraph, split the <w:p>, orphaned its <w:pPr>,
        // and leaked the __DGTXBX_OPEN sentinel as raw text. Here the textbox lives in
        // a styled paragraph — the exact shape that triggered the leak. Dimensions
        // mirror a real reported case (top~0.206in, w~3.575in, h~0.906in).
        String xml =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body>' +
            '<w:p>' +
            '<w:pPr><w:pStyle w:val="Heading1"/></w:pPr>' +
            '<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor>' +
            '<wp:positionH relativeFrom="column"><wp:posOffset>0</wp:posOffset></wp:positionH>' +
            '<wp:positionV relativeFrom="paragraph"><wp:posOffset>188595</wp:posOffset></wp:positionV>' +
            '<wp:extent cx="3268980" cy="828040"/>' +
            '<wps:wsp><wps:txbx><w:txbxContent>' +
            '<w:p><w:r><w:t>BoxText</w:t></w:r></w:p>' +
            '</w:txbxContent></wps:txbx><wps:bodyPr vert="horz"/></wps:wsp>' +
            '</wp:anchor></w:drawing></mc:Choice>' +
            '<mc:Fallback><w:pict><v:rect><v:textbox><w:txbxContent>' +
            '<w:p><w:r><w:t>FallbackText</w:t></w:r></w:p>' +
            '</w:txbxContent></v:textbox></v:rect></w:pict></mc:Fallback>' +
            '</mc:AlternateContent></w:r>' +
            '</w:p>' +
            '</w:body></w:document>';

        String result = DocGenHtmlRenderer.unwrapTextboxes(xml);

        System.assert(result.contains('__DGTXBX_OPEN'), 'Textbox sentinel marker should be emitted');
        System.assert(result.contains('BoxText'), 'Textbox inner content must be preserved');
        // The whole styled <w:p> is replaced as a unit — with the prefix bug the
        // paragraph split, leaving an orphaned <w:pPr> in the output.
        System.assert(
            !result.contains('<w:pPr>'),
            'Enclosing styled paragraph must be replaced whole, not split (no orphaned <w:pPr>): ' + result
        );
        System.assert(!result.contains('<mc:AlternateContent'), 'AlternateContent textbox should be unwrapped');
    }

    @IsTest
    static void findEnclosingParagraphStart_skipsPrefixFalseMatches() {
        // <w:pPr>/<w:pStyle> share the '<w:p' prefix; the helper must skip them and
        // return the real <w:p> open tag.
        String xml = '<w:body><w:p><w:pPr><w:pStyle w:val="X"/></w:pPr><w:r>HERE</w:r></w:p></w:body>';
        Integer hereIdx = xml.indexOf('HERE');
        Integer pStart = DocGenHtmlRenderer.findEnclosingParagraphStart(xml, hereIdx);
        System.assertEquals(xml.indexOf('<w:p>'), pStart, 'Should return the real <w:p>, not <w:pPr>/<w:pStyle>');
    }
}

/**
 * Coverage for DocGenDocxTemplateLinter — the Word/PowerPoint slice of the
 * upload-time fidelity report (issue #272).
 *
 * The reference semantics live in scripts/docgen-template-lint.js (the offline
 * Node preflight); what is asserted here is the Apex port: each of the nine
 * checks fires on the fixture that trips it, stays quiet when it shouldn't,
 * every finding is a warning (never a blocker), and the saveTemplate hook hands
 * the report back without changing the save outcome.
 *
 * Fixtures are minimal Office packages built with Compression.ZipWriter — the
 * same construction the rest of the suite uses (DocGenControllerTests ~904).
 */
@isTest
private class DocGenDocxTemplateLinterTest {
    private static final String XML_HEAD =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">';

    private static DocGenAiHtmlValidator.Finding findRule(List<DocGenAiHtmlValidator.Finding> findings, String rule) {
        for (DocGenAiHtmlValidator.Finding f : findings) {
            if (f.rule == rule) {
                return f;
            }
        }
        return null;
    }

    private static List<String> ruleNames(List<DocGenAiHtmlValidator.Finding> findings) {
        List<String> names = new List<String>();
        for (DocGenAiHtmlValidator.Finding f : findings) {
            names.add(f.rule);
        }
        return names;
    }

    // -----------------------------------------------------------------------
    // Fixture builders — minimal valid Office packages, after TestDataFactory.
    // -----------------------------------------------------------------------

    /** A ZIP carrying the supplied document.xml body as a .docx. */
    private static Blob buildDocx(String documentXml) {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry('word/document.xml', Blob.valueOf(documentXml));
        return zw.getArchive();
    }

    /** A paragraph of WordprocessingML text. */
    private static String p(String text) {
        return '<w:p><w:r><w:t>' + text + '</w:t></w:r></w:p>';
    }

    /** A single-row WordprocessingML table whose one cell carries the row text. */
    private static String tableRow(String cellText) {
        return '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>' + cellText + '</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';
    }

    /** A ZIP with the supplied slides as a .pptx (one slide per string). */
    private static Blob buildPptx(List<String> slidesXml) {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf('<?xml version="1.0"?><Types/>'));
        for (Integer i = 0; i < slidesXml.size(); i++) {
            zw.addEntry('ppt/slides/slide' + (i + 1) + '.xml', Blob.valueOf(slidesXml[i]));
        }
        return zw.getArchive();
    }

    private static String slide(String text) {
        return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" ' +
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>' +
            text +
            '</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
    }

    // -----------------------------------------------------------------------
    // The nine checks
    // -----------------------------------------------------------------------

    @isTest
    static void cleanDocxProducesZeroFindings() {
        String xml = XML_HEAD + '<w:body>' + p('Hello {Name}, {Industry}.') + '</w:body></w:document>';
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        Test.stopTest();
        System.assertEquals(0, findings.size(), 'A clean single-run template must report nothing: ' + findings);
    }

    @isTest
    static void fragmentedTagIsReported() {
        // Word splits the tag across two runs when formatting changes mid-tag.
        String xml =
            XML_HEAD + '<w:body><w:p><w:r><w:t>{Na</w:t></w:r><w:r><w:t>me}</w:t></w:r></w:p></w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Merge tag split across runs');
        System.assertNotEquals(null, f, 'the tag spans two runs — warn: ' + findings);
        System.assert(f.detail.contains('{Name}'), 'the warning must name the reconstructed tag: ' + f.detail);
    }

    @isTest
    static void unmatchedLoopOpenIsReported() {
        String xml = XML_HEAD + '<w:body>' + p('{#Lines}{Name}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Loop opener with no closer');
        System.assertNotEquals(null, f, 'an opener with no closer fails the merge at generation time');
        System.assert(f.detail.contains('{#Lines}'), 'the warning must name the tag: ' + f.detail);
    }

    @isTest
    static void unmatchedLoopCloseIsReported() {
        String xml = XML_HEAD + '<w:body>' + p('{Name}{/Lines}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Loop closer with no opener');
        System.assertNotEquals(null, f, 'a closer with no opener must be flagged');
        System.assert(f.detail.contains('{/Lines}'), 'the warning must name the tag: ' + f.detail);
    }

    @isTest
    static void balancedLoopWithElseIsClean() {
        String xml = XML_HEAD + '<w:body>' + tableRow('{#Lines}{Name}{:else}none{/Lines}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertEquals(null, findRule(findings, 'Loop opener with no closer'), 'balanced loop: ' + findings);
        System.assertEquals(null, findRule(findings, 'Loop closer with no opener'), 'balanced loop: ' + findings);
        System.assertEquals(null, findRule(findings, 'Empty loop'), 'the {:else} counts as content: ' + findings);
    }

    @isTest
    static void loopInsideOneTableRowIsClean() {
        // Both tags inside cells of the SAME row — the canonical table-loop shape.
        String xml =
            XML_HEAD +
            '<w:body><w:tbl><w:tr><w:tc>' +
            '<w:p><w:r><w:t>{#Lines}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{/Lines}</w:t></w:r></w:p>' +
            '</w:tc></w:tr></w:tbl></w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertEquals(
            null,
            findRule(findings, 'Loop not inside a single table row'),
            'row encloses both: ' + findings
        );
        System.assertEquals(null, findRule(findings, 'Row-binding collision'), 'only one loop: ' + findings);
    }

    @isTest
    static void loopWithoutEnclosingRowWarnsAboutTheFallback() {
        // Both tags live in plain paragraphs — no <w:tr> encloses them, so the
        // engine falls back to paragraph-level repeat.
        String xml = XML_HEAD + '<w:body>' + p('{#Lines}') + p('{Name}') + p('{/Lines}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertNotEquals(
            null,
            findRule(findings, 'Loop not inside a single table row'),
            'no row encloses the pair — warn about the fallback: ' + findings
        );
    }

    @isTest
    static void closingTagOutsideAnyContainerIsReported() {
        // The closer escaped to the body root, outside every paragraph.
        String xml =
            XML_HEAD +
            '<w:body>' +
            p('{#Lines}{Name}') +
            '<w:r><w:t>{/Lines}</w:t></w:r>' +
            '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertNotEquals(
            null,
            findRule(findings, 'Closing tag outside a container'),
            'the closer escaped its cell: ' + findings
        );
    }

    @isTest
    static void nestedSameRelLoopIsReported() {
        String xml =
            XML_HEAD +
            '<w:body>' +
            tableRow('{#Lines}{Name}{#Lines}{Number}{/Lines}{/Lines}') +
            '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Nested loops on the same relationship');
        System.assertNotEquals(null, f, 'two forward loops over Lines — almost always a typo: ' + findings);
        System.assert(f.detail.contains('Lines'), 'the warning must name the relationship: ' + f.detail);
    }

    @isTest
    static void nestedSameRelInversePatternIsAllowed() {
        // {^Lines}{:else}…{#Lines}…{/Lines}…{/Lines} — the canonical inverse-loop
        // conditional. Not a typo, so no warning.
        String xml =
            XML_HEAD +
            '<w:body>' +
            tableRow('{^Lines}{:else}{#Lines}{Name}{/Lines}{/Lines}') +
            '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertEquals(
            null,
            findRule(findings, 'Nested loops on the same relationship'),
            'the inverse-loop conditional is deliberate: ' + findings
        );
    }

    @isTest
    static void emptyLoopIsReported() {
        String xml = XML_HEAD + '<w:body>' + p('{#Lines}{/Lines}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Empty loop');
        System.assertNotEquals(null, f, 'an empty loop iterates to nothing: ' + findings);
        System.assert(f.detail.contains('{#Lines}'), 'the warning must name the loop: ' + f.detail);
    }

    @isTest
    static void rowBindingCollisionIsReported() {
        // {#Lines} and {#Opportunities} both bind to the SAME row.
        String xml =
            XML_HEAD +
            '<w:body><w:tbl><w:tr><w:tc>' +
            '<w:p><w:r><w:t>{#Lines}{#Opportunities}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{/Opportunities}{/Lines}</w:t></w:r></w:p>' +
            '</w:tc></w:tr></w:tbl></w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        System.assertNotEquals(
            null,
            findRule(findings, 'Row-binding collision'),
            'both loops fight for the row: ' + findings
        );
    }

    @isTest
    static void entityEncodedIfOperatorIsReported() {
        // Word stores '>' as &gt; in OOXML; the IF parser does not decode it, so
        // the expression always evaluates false on installs before v1.69.
        String xml = XML_HEAD + '<w:body>' + p('{#IF Amount &gt; 0}positive{/IF}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'HTML-encoded IF operator');
        System.assertNotEquals(null, f, 'the expression can never be true: ' + findings);
        System.assert(f.detail.contains('&gt;'), 'the warning must name the encoded operator: ' + f.detail);
        System.assert(f.detail.contains('!='), 'and suggest the safe rewrite: ' + f.detail);
    }

    @isTest
    static void nestedIfBlocksAreReported() {
        String xml = XML_HEAD + '<w:body>' + p('{#IF A != 0}{#IF B != 0}x{/IF}{/IF}') + '</w:body></w:document>';
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(buildDocx(xml));
        DocGenAiHtmlValidator.Finding f = findRule(findings, 'Nested IF blocks');
        System.assertNotEquals(null, f, 'nested IFs corrupt the parser on older installs: ' + findings);
    }

    // -----------------------------------------------------------------------
    // PowerPoint: text-level checks run; table-structure checks are skipped.
    // -----------------------------------------------------------------------

    @isTest
    static void pptxBalancedLoopIsCleanOfStructuralWarnings() {
        Blob pptx = buildPptx(new List<String>{ slide('{#Lines}{Name}{/Lines}') });
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(pptx);
        System.assertEquals(
            null,
            findRule(findings, 'Loop not inside a single table row'),
            'PPTX has no <w:tr> — the paragraph-fallback warning would be noise: ' + findings
        );
        System.assertEquals(null, findRule(findings, 'Loop opener with no closer'), 'balanced slide: ' + findings);
    }

    @isTest
    static void pptxUnmatchedLoopIsReported() {
        Blob pptx = buildPptx(new List<String>{ slide('{#Lines}{Name}') });
        List<DocGenAiHtmlValidator.Finding> findings = DocGenDocxTemplateLinter.lint(pptx);
        System.assertNotEquals(
            null,
            findRule(findings, 'Loop opener with no closer'),
            '<a:t> runs must be read like <w:t>: ' + findings
        );
    }

    // -----------------------------------------------------------------------
    // Never throws, never blocks.
    // -----------------------------------------------------------------------

    @isTest
    static void lintNeverThrowsOnGarbage() {
        Test.startTest();
        List<DocGenAiHtmlValidator.Finding> nullBlob = DocGenDocxTemplateLinter.lint(null);
        List<DocGenAiHtmlValidator.Finding> notAZip = DocGenDocxTemplateLinter.lint(
            Blob.valueOf('this is definitely not a zip archive')
        );
        List<DocGenAiHtmlValidator.Finding> emptyZip = DocGenDocxTemplateLinter.lint(
            buildDocx('<?xml version="1.0"?><w:document/>')
        );
        Test.stopTest();
        System.assertEquals(0, nullBlob.size(), 'null input is an empty report, not an exception');
        System.assertEquals(0, notAZip.size(), 'an unreadable archive must not throw');
        System.assertEquals(0, emptyZip.size(), 'a document with no runs reports nothing: ' + emptyZip);
    }

    // -----------------------------------------------------------------------
    // The hook: saveTemplate returns the warnings with the save result.
    // -----------------------------------------------------------------------

    private static DocGen_Template__c newWordTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Docx Lint Hook ' + System.now().getTime(),
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        return tpl;
    }

    @isTest
    static void saveReturnsWarningsKeysWithoutBlocking() {
        DocGen_Template__c tpl = newWordTemplate();
        String badBody = XML_HEAD + '<w:body>' + p('{#Lines}{Name}') + '</w:body></w:document>';
        ContentVersion cv = new ContentVersion(
            Title = 'DocxLintBody',
            PathOnClient = 'DocxLintBody.docx',
            VersionData = buildDocx(badBody)
        );
        insert cv;

        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => tpl.Name,
            'Type__c' => 'Word',
            'Base_Object_API__c' => 'Account',
            'Output_Format__c' => 'PDF',
            'Query_Config__c' => 'Name',
            'Test_Record_Id__c' => null,
            'Document_Title_Format__c' => null
        };
        Test.startTest();
        Map<String, Object> res = DocGenController.saveTemplate(fields, true, cv.Id);
        Test.stopTest();

        System.assertNotEquals(null, res.get('createdVersionId'), 'warnings never block the save');
        System.assert(res.containsKey('warnings'), 'the save result must carry the fidelity report');
        System.assert(res.containsKey('warningCount'), 'and its count');
        List<DocGenAiHtmlValidator.Finding> warnings = (List<DocGenAiHtmlValidator.Finding>) res.get('warnings');
        System.assertNotEquals(
            null,
            findRule(warnings, 'Loop opener with no closer'),
            'an unmatched loop in the uploaded DOCX must warn: ' + warnings
        );
        System.assertEquals(warnings.size(), (Integer) res.get('warningCount'), 'count must match the list');
        for (DocGenAiHtmlValidator.Finding f : warnings) {
            System.assertEquals('warning', f.action, 'lint never repairs or removes — every finding is a warning');
        }
    }

    @isTest
    static void saveReturnsCleanWarningsForACleanDocx() {
        DocGen_Template__c tpl = newWordTemplate();
        String cleanBody = XML_HEAD + '<w:body>' + p('Hello {Name}.') + '</w:body></w:document>';
        ContentVersion cv = new ContentVersion(
            Title = 'DocxLintBodyClean',
            PathOnClient = 'DocxLintBodyClean.docx',
            VersionData = buildDocx(cleanBody)
        );
        insert cv;

        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => tpl.Name,
            'Type__c' => 'Word',
            'Base_Object_API__c' => 'Account',
            'Output_Format__c' => 'PDF',
            'Query_Config__c' => 'Name',
            'Test_Record_Id__c' => null,
            'Document_Title_Format__c' => null
        };
        Test.startTest();
        Map<String, Object> res = DocGenController.saveTemplate(fields, true, cv.Id);
        Test.stopTest();

        System.assertNotEquals(null, res.get('createdVersionId'), 'the save still succeeds');
        System.assertEquals(
            0,
            (Integer) res.get('warningCount'),
            'a clean DOCX body warns about nothing: ' + res.get('warnings')
        );
    }

    @isTest
    static void saveDoesNotLintNonOfficeTypes() {
        // The HTML path has its own linter; saveTemplate must not run the DOCX
        // one for HTML bodies (a text blob would just fail the ZIP read anyway).
        DocGen_Template__c tpl = newWordTemplate();
        ContentVersion cv = new ContentVersion(
            Title = 'HtmlBody',
            PathOnClient = 'Body.html',
            VersionData = Blob.valueOf('<html><body><p>{#Lines}</p></body></html>')
        );
        insert cv;

        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => tpl.Name,
            'Type__c' => 'HTML',
            'Base_Object_API__c' => 'Account',
            'Output_Format__c' => 'PDF',
            'Query_Config__c' => 'Name',
            'Test_Record_Id__c' => null,
            'Document_Title_Format__c' => null
        };
        Test.startTest();
        Map<String, Object> res = DocGenController.saveTemplate(fields, true, cv.Id);
        Test.stopTest();

        System.assertNotEquals(null, res.get('createdVersionId'), 'the save still succeeds');
        System.assertEquals(
            0,
            (Integer) res.get('warningCount'),
            'non-Office uploads are outside this linter: ' + res.get('warnings')
        );
    }
}

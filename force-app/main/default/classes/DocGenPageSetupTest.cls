/**
 * v1.68 — exercises the page-setup override path:
 *   - Page_Size__c × Page_Orientation__c × Page_Margins__c on Template + Version
 *   - DocGenHtmlRenderer override statics (size, orientation, margins, custom)
 *   - DocGenService.wrapHtmlForPdf size/margin CSS resolution
 *   - DocGenController.saveTemplate persisting new fields on template + version
 */
@IsTest
private class DocGenPageSetupTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'PageSetup Test Co');
    }

    private static Id createHtmlTemplate(String size, String orient, String margins, String custom) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'PageSetup ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Page_Size__c = size,
            Page_Orientation__c = orient,
            Page_Margins__c = margins,
            Custom_Margins__c = custom
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'b.html',
            VersionData = Blob.valueOf('<html><body><p>Page setup test {Name}</p></body></html>'),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Page_Size__c = size,
            Page_Orientation__c = orient,
            Page_Margins__c = margins,
            Custom_Margins__c = custom
        );
        return tmpl.Id;
    }

    @IsTest
    static void sizeOrientationMatrixDrivesWrappedHtml() {
        Account a = [SELECT Id FROM Account LIMIT 1];

        // Letter Landscape — size CSS should be "11in 8.5in"
        Id letterLand = createHtmlTemplate('Letter', 'Landscape', 'Default', null);
        Test.startTest();
        DocGenService.generatePdfBlob(letterLand, a.Id);
        String html1 = DocGenService.lastRenderedHtml;
        System.assert(
            html1.contains('11.0in 8.5in') || html1.contains('11in 8.5in'),
            'Letter Landscape CSS should declare 11x8.5: ' + html1
        );

        // Legal Portrait — "8.5in 14in"
        Id legalPort = createHtmlTemplate('Legal', 'Portrait', 'Default', null);
        DocGenService.generatePdfBlob(legalPort, a.Id);
        String html2 = DocGenService.lastRenderedHtml;
        System.assert(
            html2.contains('8.5in 14') || html2.contains('8.5in 14.0in'),
            'Legal Portrait CSS should declare 8.5x14: ' + html2
        );

        // A4 Landscape — ~11.69in 8.27in
        Id a4Land = createHtmlTemplate('A4', 'Landscape', 'Default', null);
        DocGenService.generatePdfBlob(a4Land, a.Id);
        String html3 = DocGenService.lastRenderedHtml;
        System.assert(html3.contains('11.69in 8.27in'), 'A4 Landscape CSS should declare 11.69x8.27: ' + html3);
        Test.stopTest();
    }

    @IsTest
    static void marginPresetsResolveToExpectedCss() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        // Narrow → margin: 0.5in
        Id narrow = createHtmlTemplate('Letter', 'Portrait', 'Narrow', null);
        DocGenService.generatePdfBlob(narrow, a.Id);
        System.assert(DocGenService.lastRenderedHtml.contains('margin: 0.5in'), 'Narrow → 0.5in');

        // Normal → margin: 1in
        Id normal = createHtmlTemplate('Letter', 'Portrait', 'Normal', null);
        DocGenService.generatePdfBlob(normal, a.Id);
        System.assert(DocGenService.lastRenderedHtml.contains('margin: 1in'), 'Normal → 1in');

        // Wide → margin: 1.5in
        Id wide = createHtmlTemplate('Letter', 'Portrait', 'Wide', null);
        DocGenService.generatePdfBlob(wide, a.Id);
        System.assert(DocGenService.lastRenderedHtml.contains('margin: 1.5in'), 'Wide → 1.5in');

        // Default for size + landscape → 0.5in (size-aware default)
        Id defLand = createHtmlTemplate('Letter', 'Landscape', 'Default', null);
        DocGenService.generatePdfBlob(defLand, a.Id);
        System.assert(DocGenService.lastRenderedHtml.contains('margin: 0.5in'), 'Default landscape → 0.5in');

        // Default for size + portrait → 1in
        Id defPort = createHtmlTemplate('Letter', 'Portrait', 'Default', null);
        DocGenService.generatePdfBlob(defPort, a.Id);
        System.assert(
            DocGenService.lastRenderedHtml.contains('margin: 1.0in') ||
            DocGenService.lastRenderedHtml.contains('margin: 1in'),
            'Default portrait → 1in'
        );
        Test.stopTest();
    }

    @IsTest
    static void customMarginsParse() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        // 4-value custom — emits T,R,B,L margin
        Id fourVal = createHtmlTemplate('Letter', 'Portrait', 'Custom', '0.5,0.75,0.5,0.75');
        DocGenService.generatePdfBlob(fourVal, a.Id);
        String h1 = DocGenService.lastRenderedHtml;
        System.assert(h1.contains('margin: 0.5in 0.75in 0.5in 0.75in'), 'Custom 4-value margin: ' + h1);

        // 1-value custom — applies to all sides
        Id oneVal = createHtmlTemplate('Letter', 'Portrait', 'Custom', '0.6');
        DocGenService.generatePdfBlob(oneVal, a.Id);
        System.assert(
            DocGenService.lastRenderedHtml.contains('margin: 0.6in 0.6in 0.6in 0.6in'),
            '1-value applies to all sides'
        );

        // Invalid custom string falls back to size default
        Id invalid = createHtmlTemplate('Letter', 'Portrait', 'Custom', 'not a number');
        DocGenService.generatePdfBlob(invalid, a.Id);
        System.assert(DocGenService.lastRenderedHtml.contains('margin: 1'), 'Invalid custom falls back to default');

        // Clamping: out-of-range values get clamped to 0.1–3.0
        Id clamped = createHtmlTemplate('Letter', 'Portrait', 'Custom', '5.0,0.05,2.0,1.0');
        DocGenService.generatePdfBlob(clamped, a.Id);
        String h4 = DocGenService.lastRenderedHtml;
        System.assert(
            h4.contains('margin: 3.0in 0.1in 2.0in 1.0in') || h4.contains('margin: 3in 0.1in 2in 1in'),
            'Clamped to range: ' + h4
        );
        Test.stopTest();
    }

    @IsTest
    static void fromSourceMarginsFallbackToDefaultForHtml() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        // FromSource on HTML templates has no <w:pgMar> — should fall back to size default.
        Id fs = createHtmlTemplate('Letter', 'Landscape', 'FromSource', null);
        DocGenService.generatePdfBlob(fs, a.Id);
        // Landscape default is 0.5in
        System.assert(
            DocGenService.lastRenderedHtml.contains('margin: 0.5in'),
            'FromSource on HTML falls back to landscape default 0.5in'
        );
        Test.stopTest();
    }

    @IsTest
    static void saveTemplatePersistsPageSetupOnTemplateAndVersion() {
        // createTemplate path: insert directly (LDS does this client-side normally)
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'SaveTest ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Page_Size__c = 'A4',
            Page_Orientation__c = 'Landscape',
            Page_Margins__c = 'Wide'
        );
        insert t;

        // Provide a tiny CV so saveTemplate's createVersion path can attach it
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_html_body_' + t.Id,
            PathOnClient = 'b.docx',
            VersionData = Blob.valueOf('STUB'),
            FirstPublishLocationId = t.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        Test.startTest();
        // Details-only save — flips fields on template
        Map<String, Object> detailsFields = new Map<String, Object>{
            'Id' => t.Id,
            'Name' => t.Name,
            'Type__c' => 'Word',
            'Output_Format__c' => 'PDF',
            'Base_Object_API__c' => 'Account',
            'Page_Size__c' => 'Legal',
            'Page_Orientation__c' => 'Portrait',
            'Page_Margins__c' => 'Custom',
            'Custom_Margins__c' => '0.5,0.5,0.5,0.5'
        };
        DocGenController.saveTemplate(detailsFields, false, null);

        DocGen_Template__c after1 = [
            SELECT Page_Size__c, Page_Orientation__c, Page_Margins__c, Custom_Margins__c
            FROM DocGen_Template__c
            WHERE Id = :t.Id
        ];
        System.assertEquals('Legal', after1.Page_Size__c);
        System.assertEquals('Portrait', after1.Page_Orientation__c);
        System.assertEquals('Custom', after1.Page_Margins__c);
        System.assertEquals('0.5,0.5,0.5,0.5', after1.Custom_Margins__c);

        // Save-as-new-version — snapshot lands on the new active version
        Map<String, Object> versionFields = new Map<String, Object>{
            'Id' => t.Id,
            'Name' => t.Name,
            'Type__c' => 'Word',
            'Output_Format__c' => 'PDF',
            'Base_Object_API__c' => 'Account',
            'Page_Size__c' => 'A4',
            'Page_Orientation__c' => 'Landscape',
            'Page_Margins__c' => 'FromSource',
            'Custom_Margins__c' => null
        };
        DocGenController.saveTemplate(versionFields, true, cv.Id);

        DocGen_Template_Version__c activeVer = [
            SELECT Page_Size__c, Page_Orientation__c, Page_Margins__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :t.Id AND Is_Active__c = TRUE
            LIMIT 1
        ];
        System.assertEquals('A4', activeVer.Page_Size__c);
        System.assertEquals('Landscape', activeVer.Page_Orientation__c);
        System.assertEquals('FromSource', activeVer.Page_Margins__c);
        Test.stopTest();
    }

    @IsTest
    static void getAllTemplatesIncludesPageSetupFields() {
        // Verify the wired SOQL pulls the new fields — without them the LWC's
        // edit-modal load defaults back to Portrait/Letter/Default.
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'WireTest ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Page_Size__c = 'Legal',
            Page_Orientation__c = 'Landscape',
            Page_Margins__c = 'Wide',
            Custom_Margins__c = ''
        );
        insert t;

        Test.startTest();
        List<DocGen_Template__c> tmpls = DocGenController.getAllTemplates();
        Test.stopTest();

        DocGen_Template__c found;
        for (DocGen_Template__c tt : tmpls)
            if (tt.Id == t.Id) {
                found = tt;
                break;
            }
        System.assertNotEquals(null, found, 'Template should be in getAllTemplates result');
        System.assertEquals('Legal', found.Page_Size__c);
        System.assertEquals('Landscape', found.Page_Orientation__c);
        System.assertEquals('Wide', found.Page_Margins__c);
    }

    // v1.90 — when source HTML declares @page itself, the engine must NOT emit
    // size:/margin: in its own @page rule (would fight the author CSS and could
    // override the author's intended margin). Confirms `hasSourcePageRule` short
    // circuit and the conditional emission path in wrapHtmlForPdf.
    // Returns the contents of the FIRST <style> block (the engine-injected one)
    // so assertions target only what the engine wrote, not the author's CSS.
    private static String engineStyleBlock(String wrapped) {
        Integer open = wrapped.indexOf('<style>');
        System.assertNotEquals(-1, open, 'wrapped HTML missing <style>: ' + wrapped);
        Integer close = wrapped.indexOf('</style>', open);
        return wrapped.substring(open + 7, close);
    }

    @IsTest
    static void sourcePageRuleSuppressesEngineSizeAndMargin() {
        DocGenHtmlRenderer.pageSizeOverride = null;
        DocGenHtmlRenderer.orientationOverride = null;
        DocGenHtmlRenderer.marginsOverride = null;
        DocGenHtmlRenderer.customMarginsOverride = null;
        String authored = '@page { size: A4 landscape; margin: 15mm; } table { border: 1px solid #000; }';
        String wrapped = DocGenService.wrapHtmlForPdf('<p>hi</p>', authored, null, null);

        // No header/footer + author owns @page → engine emits no @page rule at all
        String engine = engineStyleBlock(wrapped);
        System.assert(!engine.contains('@page'), 'Engine block must not emit @page: ' + engine);
        System.assert(!engine.contains('margin: 1in'), 'Engine must not inject default 1in margin: ' + engine);
        // Author CSS must still be present (in the second <style>)
        System.assert(wrapped.contains('size: A4 landscape'), 'Author @page size must survive');
        System.assert(wrapped.contains('margin: 15mm'), 'Author @page margin must survive');
    }

    @IsTest
    static void sourcePageRulePlusHeaderEmitsOnlyMarginBox() {
        DocGenHtmlRenderer.pageSizeOverride = null;
        DocGenHtmlRenderer.orientationOverride = null;
        DocGenHtmlRenderer.marginsOverride = null;
        DocGenHtmlRenderer.customMarginsOverride = null;
        String authored = '@page { size: A4 landscape; margin: 15mm; }';
        String wrapped = DocGenService.wrapHtmlForPdf('<p>body</p>', authored, '<span>My header</span>', null);

        // Engine must still emit @page so it can set @top-center, but the @page rule
        // itself must not contain size: or margin: (those belong to the author).
        String engine = engineStyleBlock(wrapped);
        System.assert(engine.contains('@page {'), 'Engine emits @page wrapper for margin-box');
        System.assert(engine.contains('@top-center'), 'Engine emits @top-center for header');
        Integer pageStart = engine.indexOf('@page {');
        // Walk forward to the matching } that closes the @page rule (accounting for
        // the nested @top-center). Two opens, two closes.
        Integer firstClose = engine.indexOf('}', pageStart);
        Integer secondClose = engine.indexOf('}', firstClose + 1);
        String pageRule = engine.substring(pageStart, secondClose + 1);
        System.assert(!pageRule.contains('size:'), 'Engine @page must not declare size: ' + pageRule);
        System.assert(!pageRule.contains('margin:'), 'Engine @page must not declare margin: ' + pageRule);
    }

    @IsTest
    static void noSourcePageRuleStillInjectsEngineDefaults() {
        DocGenHtmlRenderer.pageSizeOverride = null;
        DocGenHtmlRenderer.orientationOverride = null;
        DocGenHtmlRenderer.marginsOverride = null;
        DocGenHtmlRenderer.customMarginsOverride = null;
        String wrapped = DocGenService.wrapHtmlForPdf('<p>x</p>', 'p { color: red; }', null, null);
        // No author @page → engine MUST inject size + margin (existing behavior)
        System.assert(wrapped.contains('size: letter'), 'Engine should inject default size when author has none');
        System.assert(wrapped.contains('margin: 1in'), 'Engine should inject default margin when author has none');
    }

    // =====================================================================
    // #243 — explicit record page-setup beats an author @page.
    //
    // Word carries orientation in <w:sectPr>, not in markup, so admins set
    // Page_Orientation__c on the template record. After a Word→HTML conversion the
    // converted HTML's own @page was winning unconditionally (the v1.90 rule) and the
    // admin's landscape choice was silently discarded.
    // =====================================================================

    @IsTest
    static void explicitLandscapeOverridesAuthorPageSize() {
        DocGenHtmlRenderer.pageSizeOverride = 'Letter';
        DocGenHtmlRenderer.orientationOverride = 'Landscape';
        DocGenHtmlRenderer.marginsOverride = 'Default';
        DocGenHtmlRenderer.customMarginsOverride = null;
        // Converted-from-Word HTML brings its own portrait @page.
        String authored = '@page { size: 8.5in 11in; margin: 1in; } p { color: red; }';
        String wrapped = DocGenService.wrapHtmlForPdf('<p>hi</p>', authored, null, null);

        System.assert(
            wrapped.contains('size: 11.0in 8.5in'),
            'Explicit Landscape must win over the author @page size: ' + wrapped
        );
        System.assert(
            !wrapped.contains('size: 8.5in 11in'),
            'The competing author size declaration must be stripped: ' + wrapped
        );
        // Only the size declaration is removed — the rest of the author CSS survives.
        System.assert(wrapped.contains('color: red'), 'Unrelated author CSS must survive: ' + wrapped);
        System.assert(
            wrapped.contains('margin: 1in'),
            'Author margin survives when no explicit margin override is set: ' + wrapped
        );
    }

    @IsTest
    static void defaultPortraitLetterStillDefersToAuthorPage() {
        // Portrait + Letter are the FIELD DEFAULTS and cannot be distinguished from
        // "the admin never touched this", so they must NOT override author CSS. This
        // is what keeps the v1.90 fix for #60 / #71 intact.
        DocGenHtmlRenderer.pageSizeOverride = 'Letter';
        DocGenHtmlRenderer.orientationOverride = 'Portrait';
        DocGenHtmlRenderer.marginsOverride = 'Default';
        DocGenHtmlRenderer.customMarginsOverride = null;
        String authored = '@page { size: A4 landscape; margin: 15mm; }';
        String wrapped = DocGenService.wrapHtmlForPdf('<p>hi</p>', authored, null, null);

        System.assert(wrapped.contains('size: A4 landscape'), 'Author @page size must survive: ' + wrapped);
        System.assert(wrapped.contains('margin: 15mm'), 'Author @page margin must survive: ' + wrapped);
        String engine = engineStyleBlock(wrapped);
        System.assert(!engine.contains('@page'), 'Engine must emit no @page for default values: ' + engine);
    }

    @IsTest
    static void explicitMarginOverrideAlsoStripsAuthorMargin() {
        DocGenHtmlRenderer.pageSizeOverride = 'A4';
        DocGenHtmlRenderer.orientationOverride = 'Portrait';
        DocGenHtmlRenderer.marginsOverride = 'Narrow';
        DocGenHtmlRenderer.customMarginsOverride = null;
        String authored = '@page { size: 8.5in 11in; margin: 2in; }';
        String wrapped = DocGenService.wrapHtmlForPdf('<p>hi</p>', authored, null, null);

        System.assert(wrapped.contains('margin: 0.5in'), 'Narrow preset must be applied: ' + wrapped);
        System.assert(!wrapped.contains('margin: 2in'), 'Author margin must be stripped: ' + wrapped);
    }

    @IsTest
    static void stripSourcePageDeclIsSurgical() {
        // The (^|;) anchor is what stops `size` matching `font-size` and `margin`
        // matching `margin-top`. Without it this rewrite would corrupt author CSS.
        String css = '@page { size: A4; margin: 1in; margin-top: 2in; } body { font-size: 10pt; margin-left: 3pt; }';
        String stripped = DocGenService.stripSourcePageDecl(css, 'size');
        System.assert(!stripped.contains('size: A4'), 'The @page size must go: ' + stripped);
        System.assert(stripped.contains('font-size: 10pt'), 'font-size must NOT be treated as size: ' + stripped);
        System.assert(stripped.contains('margin: 1in'), 'Sibling declarations must survive: ' + stripped);

        String noMargin = DocGenService.stripSourcePageDecl(css, 'margin');
        System.assert(noMargin.contains('margin-top: 2in'), 'margin-top must NOT match margin: ' + noMargin);
        System.assert(noMargin.contains('margin-left: 3pt'), 'Rules outside @page are untouched: ' + noMargin);
        System.assert(noMargin.contains('size: A4'), 'Only the named declaration is removed: ' + noMargin);
    }

    @IsTest
    static void explicitOverrideDetection() {
        DocGenHtmlRenderer.orientationOverride = 'Portrait';
        DocGenHtmlRenderer.pageSizeOverride = 'Letter';
        System.assert(!DocGenService.hasExplicitPageOverride(), 'Portrait+Letter are defaults, not explicit');
        DocGenHtmlRenderer.orientationOverride = 'Landscape';
        System.assert(DocGenService.hasExplicitPageOverride(), 'Landscape can only be a deliberate choice');
        DocGenHtmlRenderer.orientationOverride = 'Portrait';
        DocGenHtmlRenderer.pageSizeOverride = 'A4';
        System.assert(DocGenService.hasExplicitPageOverride(), 'A4 can only be a deliberate choice');

        DocGenHtmlRenderer.marginsOverride = 'Default';
        System.assert(!DocGenService.hasExplicitMarginOverride(), 'Default preset is not explicit');
        DocGenHtmlRenderer.marginsOverride = 'FromSource';
        System.assert(!DocGenService.hasExplicitMarginOverride(), 'FromSource defers to the document by definition');
        DocGenHtmlRenderer.marginsOverride = 'Wide';
        System.assert(DocGenService.hasExplicitMarginOverride(), 'A named preset is explicit');
    }

    // =====================================================================
    // #245 / #246 — cell rendering
    // =====================================================================

    @IsTest
    static void cellsWrapUnbreakableStrings() {
        // table-layout: fixed gives a long unbroken token nowhere to go; without an
        // explicit wrap rule it runs straight through the cell border.
        DocGenHtmlRenderer.pageSizeOverride = null;
        DocGenHtmlRenderer.orientationOverride = null;
        DocGenHtmlRenderer.marginsOverride = null;
        DocGenHtmlRenderer.customMarginsOverride = null;
        String wrapped = DocGenService.wrapHtmlForPdf('<table><tr><td>x</td></tr></table>', '', null, null);
        System.assert(wrapped.contains('word-wrap: break-word'), 'Engine CSS must break long tokens: ' + wrapped);
        System.assert(wrapped.contains('overflow-wrap: break-word'), 'Standard spelling emitted too: ' + wrapped);
    }

    @IsTest
    static void longHyperlinkTextGetsPdfBreaksWithoutChangingHref() {
        String url =
            'https://www.example.com/portwood/document-generation/salesforce/testing/long-url-overflow/' +
            'page-boundary-validation/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        String wrapped = DocGenService.wrapHtmlForPdf('<p><a href="' + url + '">' + url + '</a></p>', '', null, null);

        System.assert(wrapped.contains('href="' + url + '"'), 'Link destination must remain exact: ' + wrapped);
        System.assert(wrapped.contains('<wbr/>'), 'Long visible URL text should receive PDF break points: ' + wrapped);
        System.assert(
            !wrapped.contains('href="' + url.substring(0, 24) + '<wbr/>'),
            'Break points must not be inserted into href attributes: ' + wrapped
        );
    }

    @IsTest
    static void shortHyperlinkTextIsLeftAlone() {
        String wrapped = DocGenService.wrapHtmlForPdf(
            '<p><a href="https://example.com/support">Support</a></p>',
            '',
            null,
            null
        );

        System.assert(!wrapped.contains('<wbr/>'), 'Short link labels should not be modified: ' + wrapped);
        System.assert(wrapped.contains('>Support</a>'), 'Short link text should remain unchanged: ' + wrapped);
    }

    @IsTest
    static void longStyledHyperlinkTextGetsPdfBreaks() {
        String url =
            'https://www.example.com/portwood/document-generation/salesforce/testing/long-url-overflow/' +
            'page-boundary-validation/abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        String label =
            '<span style="font-weight:bold">' +
            url.substring(0, 65) +
            '</span><span>' +
            url.substring(65) +
            '</span>';
        String wrapped = DocGenService.wrapHtmlForPdf('<p><a href="' + url + '">' + label + '</a></p>', '', null, null);

        System.assert(wrapped.contains('href="' + url + '"'), 'Styled link destination must remain exact: ' + wrapped);
        System.assert(
            wrapped.contains('<wbr/>'),
            'Styled long visible URL text should receive break points: ' + wrapped
        );
        System.assert(
            wrapped.contains('<span style="font-weight:bold">'),
            'Existing inline styling must survive: ' + wrapped
        );
    }

    @IsTest
    static void wordVAlignCenterBecomesCssMiddle() {
        // Word says center; CSS table cells only accept top | middle | bottom.
        // Emitting "center" verbatim produced an INVALID declaration that Flying
        // Saucer dropped, so every centre-aligned Word cell rendered top-aligned.
        System.assertEquals('middle', DocGenHtmlRenderer.toCssVerticalAlign('center'), 'center must map to middle');
        System.assertEquals('middle', DocGenHtmlRenderer.toCssVerticalAlign('CENTER'), 'match is case-insensitive');
        System.assertEquals(
            'middle',
            DocGenHtmlRenderer.toCssVerticalAlign('both'),
            'Word "both" is closest to middle'
        );
        System.assertEquals('top', DocGenHtmlRenderer.toCssVerticalAlign('top'), 'top passes through');
        System.assertEquals('bottom', DocGenHtmlRenderer.toCssVerticalAlign('bottom'), 'bottom passes through');
        System.assertEquals(null, DocGenHtmlRenderer.toCssVerticalAlign('nonsense'), 'unknown yields no declaration');
        System.assertEquals(null, DocGenHtmlRenderer.toCssVerticalAlign(null), 'null yields no declaration');
    }
}

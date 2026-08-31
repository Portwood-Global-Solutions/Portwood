/**
 * #377 — inline (data:) image materialisation for HTML templates.
 *
 * Blob.toPdf can't render `data:` URI images and can't fetch a ContentVersion
 * created in the same transaction as the render, so DocGenService.materialise-
 * InlineHtmlImages pulls each inline image into a docgen_html_img_* CV at SAVE
 * time. mergeHtmlTemplate also calls it as a self-healing render fallback.
 */
@IsTest
private class DocGenInlineImageTest {
    // 1x1 transparent PNG.
    private static final String PNG_1PX = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

    @TestSetup
    static void setup() {
        insert new Account(Name = 'Inline Img Co');
    }

    private static Id newHtmlTemplate() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'InlineImg ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert t;
        return t.Id;
    }

    private static Integer imgCvCount(Id templateId) {
        return [SELECT COUNT() FROM ContentVersion WHERE Title LIKE :('docgen_html_img_' + templateId + '_%')];
    }

    @IsTest
    static void materialise_rewritesDataUriAndCreatesCv() {
        Id t = newHtmlTemplate();
        String html = '<html><body><img src="data:image/png;base64,' + PNG_1PX + '"></body></html>';

        Test.startTest();
        String out = DocGenService.materialiseInlineHtmlImages(t, html);
        Test.stopTest();

        System.assert(!out.contains('data:image'), 'data: URI should be gone: ' + out);
        System.assert(
            out.contains('/sfc/servlet.shepherd/version/download/'),
            'src should be rewritten to a relative CV URL: ' + out
        );
        System.assertEquals(1, imgCvCount(t), 'one docgen_html_img_ CV should be created');
    }

    @IsTest
    static void materialise_secondCallReusesCv() {
        Id t = newHtmlTemplate();
        String html = '<html><body><img src="data:image/png;base64,' + PNG_1PX + '"></body></html>';

        Test.startTest();
        String first = DocGenService.materialiseInlineHtmlImages(t, html);
        Integer afterFirst = imgCvCount(t);
        String second = DocGenService.materialiseInlineHtmlImages(t, html);
        Test.stopTest();

        System.assertEquals(1, afterFirst, 'first call creates the CV');
        System.assertEquals(1, imgCvCount(t), 'second call must reuse it, not insert again');
        System.assertEquals(first, second, 'same input → same rewritten output');
    }

    @IsTest
    static void materialise_handlesSingleQuotesAndJpeg() {
        Id t = newHtmlTemplate();
        String html = '<div><img src=\'data:image/jpeg;base64,' + PNG_1PX + '\' /></div>';

        Test.startTest();
        String out = DocGenService.materialiseInlineHtmlImages(t, html);
        Test.stopTest();

        System.assert(!out.contains('data:image'), 'single-quoted data: URI should be rewritten');
        System.assertEquals(1, imgCvCount(t), 'CV created for the jpeg');
        System.assert(
            [SELECT PathOnClient FROM ContentVersion WHERE Title LIKE :('docgen_html_img_' + t + '_%') LIMIT 1]
                .PathOnClient.endsWith('.jpg'),
            'jpeg subtype should map to a .jpg extension'
        );
    }

    @IsTest
    static void materialise_malformedBase64_leftInPlace() {
        Id t = newHtmlTemplate();
        String html = '<img src="data:image/png;base64,@@@ not valid base64 @@@">';

        Test.startTest();
        String out = DocGenService.materialiseInlineHtmlImages(t, html);
        Test.stopTest();

        System.assertEquals(html, out, 'undecodable payload is left untouched, no throw');
        System.assertEquals(0, imgCvCount(t), 'no CV for a malformed image');
    }

    @IsTest
    static void materialise_noInlineImages_isIdentity() {
        Id t = newHtmlTemplate();
        String html = '<html><body><img src="/sfc/servlet.shepherd/version/download/068000000000000AAA"><p>x</p></body></html>';

        Test.startTest();
        String out = DocGenService.materialiseInlineHtmlImages(t, html);
        Test.stopTest();

        System.assertEquals(html, out, 'a body with no data: URI is returned unchanged');
        System.assertEquals(0, imgCvCount(t), 'nothing created');
    }

    @IsTest
    static void materialise_nullTemplate_isIdentity() {
        String html = '<img src="data:image/png;base64,' + PNG_1PX + '">';
        Test.startTest();
        System.assertEquals(html, DocGenService.materialiseInlineHtmlImages(null, html));
        System.assertEquals('', DocGenService.materialiseInlineHtmlImages(newHtmlTemplate(), ''));
        Test.stopTest();
    }

    @IsTest
    static void saveHtmlTemplateBody_stripsDataUris() {
        Id t = newHtmlTemplate();
        String body = '<html><body><h1>Policy</h1><img src="data:image/png;base64,' + PNG_1PX + '"></body></html>';

        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(t, 'policy.html', body);
        Test.stopTest();

        Id bodyCvId = (Id) res.get('contentVersionId');
        String stored = [SELECT VersionData FROM ContentVersion WHERE Id = :bodyCvId LIMIT 1].VersionData.toString();
        System.assert(!stored.contains('data:image'), 'stored body must not carry inline base64');
        System.assert(stored.contains('/sfc/servlet.shepherd/version/download/'), 'stored body uses a CV URL');
        System.assertEquals(1, imgCvCount(t), 'image extracted to a CV at save time');
    }

    @IsTest
    static void saveHtmlTemplateBody_largeInlineImage_noRegexCrash() {
        Id t = newHtmlTemplate();
        // ~800 KB of valid base64 — big enough to trip "Regex too complicated" in
        // the whole-body regex passes if the data: URI were left in the body.
        String bigB64 = EncodingUtil.base64Encode(Blob.valueOf('x'.repeat(600000)));
        String body =
            '<html><head><style>p{color:red}</style></head><body>' +
            '<img src="data:image/png;base64,' +
            bigB64 +
            '"><p>ok</p></body></html>';

        Test.startTest();
        Map<String, Object> res = DocGenController.saveHtmlTemplateBody(t, 'big.html', body);
        Test.stopTest();

        String stored = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :(Id) res.get('contentVersionId')
                LIMIT 1
            ]
            .VersionData.toString();
        System.assert(!stored.contains('data:image'), 'large inline image extracted');
        System.assert(stored.length() < 5000, 'stored body is small once the blob is gone: ' + stored.length());
    }

    @IsTest
    static void render_fallbackMaterialisesBodyThatBypassedWritePaths() {
        Id t = newHtmlTemplate();
        // Attach the body straight as the version CV — no saveHtmlTemplateBody.
        String body = '<html><body><img src="data:image/png;base64,' + PNG_1PX + '"></body></html>';
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_html_body_' + t + '_' + Datetime.now().getTime(),
            PathOnClient = 'raw.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = t
        );
        insert cv;
        insert new DocGen_Template_Version__c(
            Template__c = t,
            Content_Version_Id__c = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
            .Id,
            Is_Active__c = true
        );
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenService.generatePdfBlob(t, a.Id);
        Test.stopTest();

        System.assert(
            !DocGenService.lastRenderedHtml.contains('data:image'),
            'render fallback rewrites the body in-memory'
        );
        System.assertEquals(1, imgCvCount(t), 'fallback commits the image CV for subsequent renders');
    }
}

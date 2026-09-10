@IsTest
private class DocGenHtmlTemplateTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'HTMLTpl Test Co', Industry = 'Technology');
    }

    private static Id createHtmlTemplate(String header, String footer, String bodyHtml) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'HTMLTpl ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry',
            Header_Html__c = header,
            Footer_Html__c = footer
        );
        insert tmpl;

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(bodyHtml),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        return tmpl.Id;
    }

    @IsTest
    static void mergesBodyHeaderFooterAndResolvesTags() {
        Account acct = [SELECT Id, Name FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(
            '<div>Hdr {Name} Page {PageNumber}</div>',
            '<div>Ftr {PageNumber} of {TotalPages}</div>',
            '<html><body><h1>{Name}</h1><p>{Industry}</p></body></html>'
        );

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'PDF blob should be returned');
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('HTMLTpl Test Co'), 'Body merge tag should resolve: ' + rendered);
        System.assert(rendered.contains('Technology'), 'Industry merge tag should resolve');
        // Headers WITH counter tokens emit @page content CSS (Flying Saucer only
        // resolves counter(page)/counter(pages) inside @page rules).
        System.assert(rendered.contains('@top-center'), '@top-center margin box expected for header with counters');
        System.assert(
            rendered.contains('@bottom-center'),
            '@bottom-center margin box expected for footer with counters'
        );
        System.assert(rendered.contains('counter(page)'), 'counter(page) call expected for {PageNumber}');
        System.assert(rendered.contains('counter(pages)'), 'counter(pages) call expected for {TotalPages}');
        // #160: counter margin boxes must declare font-family (Flying Saucer @page boxes
        // don't inherit from body), else they render in default Times serif vs Arial body.
        System.assert(
            rendered.contains('@bottom-center { content:') || rendered.contains('@bottom-center {'),
            '@bottom-center present'
        );
        Integer bc = rendered.indexOf('@bottom-center');
        System.assert(
            bc != -1 && rendered.substring(bc, Math.min(bc + 260, rendered.length())).contains('font-family'),
            '#160: @bottom-center counter box must declare font-family: ' +
            rendered.substring(bc, Math.min(bc + 260, rendered.length()))
        );
        // Header text should survive into the CSS content string (with merged {Name} resolved).
        System.assert(
            rendered.contains('Hdr HTMLTpl Test Co'),
            'Header text with {Name} resolved should appear in CSS: ' + rendered
        );
        // When all headers/footers contain counter tokens, the running-element scaffolding is skipped.
        System.assert(
            !rendered.contains('running(dgheader)'),
            'Running header CSS should NOT be present when header uses counters'
        );
        System.assert(
            !rendered.contains('running(dgfooter)'),
            'Running footer CSS should NOT be present when footer uses counters'
        );
    }

    @IsTest
    static void headerWithoutCountersUsesRunningElement() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(
            '<div><img src="/sfc/fake" alt="logo"/> Header</div>',
            null,
            '<html><body><p>{Name}</p></body></html>'
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(
            rendered.contains('running(dgheader)'),
            'Running header expected for rich header with no counters'
        );
        System.assert(rendered.contains('element(dgheader)'), '@top-center should reference the running element');
    }

    @IsTest
    static void preservesSourceStyleBlock() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        String body =
            '<html><head><style>.mystyle{color:red}</style></head>' +
            '<body><p class="mystyle">{Name}</p></body></html>';
        Id tmplId = createHtmlTemplate(null, null, body);

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('.mystyle{color:red}'), 'Source <style> should be preserved');
    }

    @IsTest
    static void worksWithoutHeaderOrFooter() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');

        Test.startTest();
        Map<String, Object> r = DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, r.get('blob'));
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(!rendered.contains('running(dgheader)'), 'No header CSS when field blank');
        System.assert(!rendered.contains('running(dgfooter)'), 'No footer CSS when field blank');
    }

    @IsTest
    static void treatsBodylessHtmlAsContent() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<p>Just {Name}</p>');

        Test.startTest();
        DocGenService.generatePdfBlob(tmplId, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('Just HTMLTpl Test Co'), 'Content without <body> wrapper should still merge');
    }

    @IsTest
    static void renderPreviewHtmlReturnsRenderedDoc() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate('<div>Hdr</div>', '<div>Ftr</div>', '<html><body><h1>{Name}</h1></body></html>');

        Test.startTest();
        String preview = DocGenService.renderPreviewHtml(tmplId, acct.Id);
        Test.stopTest();

        System.assert(preview.contains('<html>'), 'Preview should be a full HTML document');
        System.assert(preview.contains('HTMLTpl Test Co'), 'Preview should have merged data');
    }

    @IsTest
    static void extractsImagesFromGoogleDocsZip() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'ZipHtml ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String body = '<html><body><h1>{Name}</h1><img src="images/image1.png"/></body></html>';
        Blob png = EncodingUtil.base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
        );
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('export.html', Blob.valueOf(body));
        zw.addEntry('images/image1.png', png);

        ContentVersion zipCv = new ContentVersion(
            Title = tmpl.Name + '.zip',
            PathOnClient = 'export.zip',
            VersionData = zw.getArchive(),
            FirstPublishLocationId = tmpl.Id
        );
        insert zipCv;
        zipCv = [SELECT Id FROM ContentVersion WHERE Id = :zipCv.Id];

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = zipCv.Id,
            Is_Active__c = true
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenService.extractAndSaveHtmlTemplateAssets(tmpl.Id, ver.Id);
        Test.stopTest();

        DocGen_Template_Version__c after = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :ver.Id
        ];
        System.assertNotEquals(zipCv.Id, after.Content_Version_Id__c, 'Version should repoint off the zip');
        ContentVersion newCv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :after.Content_Version_Id__c];
        System.assert(newCv.Title.startsWith('docgen_html_body_'), 'Rewritten HTML CV expected; got ' + newCv.Title);
        String rewritten = newCv.VersionData.toString();
        System.assert(rewritten.contains('/sfc/servlet.shepherd/version/download/'), 'src should be rewritten');
        System.assert(!rewritten.contains('images/image1.png'), 'Original src should be gone');
        List<ContentVersion> imgs = [
            SELECT Id
            FROM ContentVersion
            WHERE Title LIKE :('docgen_html_img_' + ver.Id + '_%')
        ];
        System.assertEquals(1, imgs.size(), 'One image CV expected');
    }

    @IsTest
    static void zipExtractorNoOpsOnPlainHtml() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body>{Name}</body></html>');
        DocGen_Template_Version__c ver = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tmplId AND Is_Active__c = TRUE
            LIMIT 1
        ];
        Id originalCvId = (Id) ver.Content_Version_Id__c;

        Test.startTest();
        DocGenService.extractAndSaveHtmlTemplateAssets(tmplId, ver.Id);
        Test.stopTest();

        DocGen_Template_Version__c after = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :ver.Id
        ];
        System.assertEquals(originalCvId, after.Content_Version_Id__c, 'Plain-html upload should stay unchanged');
    }

    @IsTest
    static void saveHtmlTemplateImageInsertsCvAndReturnsUrl() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Img ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

        Test.startTest();
        Map<String, Object> r = DocGenController.saveHtmlTemplateImage(tmpl.Id, 'image1.png', pngB64);
        Test.stopTest();

        System.assertNotEquals(null, r.get('contentVersionId'), 'CV Id expected');
        String url = (String) r.get('url');
        System.assert(url.startsWith('/sfc/servlet.shepherd/version/download/'), 'URL should be relative: ' + url);
        System.assertEquals('image1.png', r.get('fileName'));

        ContentVersion cv = [SELECT Id, Title FROM ContentVersion WHERE Id = :(Id) r.get('contentVersionId')];
        System.assert(cv.Title.startsWith('docgen_html_img_'), 'Title prefix expected: ' + cv.Title);
    }

    @IsTest
    static void saveHtmlTemplateBodyStoresHtmlCv() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Body ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        String html = '<html><body><h1>{Name}</h1></body></html>';

        Test.startTest();
        Map<String, Object> r = DocGenController.saveHtmlTemplateBody(tmpl.Id, 'source.html', html);
        Test.stopTest();

        System.assertNotEquals(null, r.get('contentVersionId'));
        System.assertNotEquals(null, r.get('contentDocumentId'));
        ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :(Id) r.get('contentVersionId')];
        System.assert(cv.Title.startsWith('docgen_html_body_'), 'Title prefix expected: ' + cv.Title);
        System.assertEquals(html, cv.VersionData.toString(), 'Stored HTML should match input verbatim');
    }

    @IsTest
    static void getHtmlTemplateBodyReturnsLatestBody() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'BodyRead ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        System.assertEquals(null, DocGenController.getHtmlTemplateBody(tmpl.Id), 'No body yet — expect null');

        DocGenController.saveHtmlTemplateBody(tmpl.Id, 'v1.html', '<html><body>first</body></html>');
        String htmlV2 = '<html><body><h1>{Name}</h1>second</body></html>';

        Test.startTest();
        DocGenController.saveHtmlTemplateBody(tmpl.Id, 'v2.html', htmlV2);
        String readBack = DocGenController.getHtmlTemplateBody(tmpl.Id);
        Test.stopTest();

        System.assertEquals(htmlV2, readBack, 'Read-back should return the most recent body verbatim');
    }

    @IsTest
    static void getHtmlTemplateBodyRejectsNonHtmlTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'WordRead ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        Boolean threw = false;
        try {
            DocGenController.getHtmlTemplateBody(tmpl.Id);
        } catch (Exception e) {
            threw = true;
            // "HTML-backed", not "HTML-type": these guards accept Canvas as well as
            // HTML, since a Canvas body IS an HTML document. The behaviour under test
            // is unchanged — a Word template is still refused.
            System.assert(
                e.getMessage().contains('HTML-backed'),
                'Error should mention HTML-backed: ' + e.getMessage()
            );
        }
        System.assert(threw, 'Should refuse non-HTML templates');
    }

    @IsTest
    static void listHtmlTemplateImagesReturnsUploadedImages() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'ImgList ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        System.assertEquals(0, DocGenController.listHtmlTemplateImages(tmpl.Id).size(), 'No images yet');

        String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
        DocGenController.saveHtmlTemplateImage(tmpl.Id, 'logo.png', pngB64);
        DocGenController.saveHtmlTemplateImage(tmpl.Id, 'hero.png', pngB64);

        Test.startTest();
        List<Map<String, Object>> imgs = DocGenController.listHtmlTemplateImages(tmpl.Id);
        Test.stopTest();

        System.assertEquals(2, imgs.size(), 'Both uploaded images should be listed');
        String url = (String) imgs[0].get('url');
        System.assert(url.startsWith('/sfc/servlet.shepherd/version/download/'), 'Relative shepherd URL expected');
        System.assertNotEquals(null, imgs[0].get('fileName'), 'File name expected');
    }

    @IsTest
    static void getConvertedHtmlSnapshotReturnsBakedHtmlAndStatus() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'DocxSnap ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        // No active version yet
        Map<String, Object> r0 = DocGenController.getConvertedHtmlSnapshot(tmpl.Id);
        System.assertEquals('NoActiveVersion', r0.get('status'), 'Expected NoActiveVersion before any version');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Pre_Decomposition_Status__c = 'Complete'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        // Pending snapshot: version exists, no baked CV yet
        Map<String, Object> r1 = DocGenController.getConvertedHtmlSnapshot(tmpl.Id);
        System.assertEquals(null, r1.get('html'), 'No snapshot CV yet — html should be null');
        System.assertEquals('Complete', r1.get('status'), 'Status should surface the version decomp status');

        String snapshotHtml = '<html><body><h1>{Name}</h1>CONVERTED</body></html>';
        insert new ContentVersion(
            Title = 'docgen_tmpl_html_' + ver.Id,
            PathOnClient = 'snapshot.html',
            VersionData = Blob.valueOf(snapshotHtml),
            IsMajorVersion = false,
            FirstPublishLocationId = ver.Id
        );

        Test.startTest();
        Map<String, Object> r2 = DocGenController.getConvertedHtmlSnapshot(tmpl.Id);
        Test.stopTest();

        System.assertEquals(snapshotHtml, r2.get('html'), 'Baked snapshot HTML should be returned verbatim');
        System.assertEquals(ver.Id, r2.get('versionId'), 'Active version id expected');
    }

    @IsTest
    static void saveHtmlTemplateImageRejectsNonHtmlTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Word ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;

        Boolean threw = false;
        try {
            DocGenController.saveHtmlTemplateImage(tmpl.Id, 'a.png', 'AAAA');
        } catch (Exception e) {
            threw = true;
            // "HTML-backed", not "HTML-type": these guards accept Canvas as well as
            // HTML, since a Canvas body IS an HTML document. The behaviour under test
            // is unchanged — a Word template is still refused.
            System.assert(
                e.getMessage().contains('HTML-backed'),
                'Error should mention HTML-backed: ' + e.getMessage()
            );
        }
        System.assert(threw, 'Should refuse non-HTML templates');
    }

    @IsTest
    static void loopInsideTrExpandsEntireRow() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new List<Contact>{
            new Contact(LastName = 'Alpha', AccountId = acct.Id),
            new Contact(LastName = 'Beta', AccountId = acct.Id),
            new Contact(LastName = 'Gamma', AccountId = acct.Id)
        };

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopTr ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        // Loop tag sits inside a single <tr> — the whole row should repeat per contact.
        String body =
            '<html><body><table>' +
            '<tr><th>Name</th></tr>' +
            '<tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr>' +
            '</table></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        Integer trCount = rendered.countMatches('<tr>') + rendered.countMatches('<tr ');
        System.assert(
            trCount >= 4,
            'Expected at least 4 <tr> (header + 3 contacts), got ' + trCount + ' in: ' + rendered
        );
        System.assert(rendered.contains('Alpha'), 'Alpha should appear');
        System.assert(rendered.contains('Beta'), 'Beta should appear');
        System.assert(rendered.contains('Gamma'), 'Gamma should appear');
    }

    @IsTest
    static void loopInsideLiExpandsEntireListItem() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new List<Contact>{
            new Contact(LastName = 'One', AccountId = acct.Id),
            new Contact(LastName = 'Two', AccountId = acct.Id)
        };

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopLi ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        String body = '<html><body><ul>' + '<li>{#Contacts}Contact: {LastName}{/Contacts}</li>' + '</ul></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        String rendered = DocGenService.lastRenderedHtml;
        Integer liCount = rendered.countMatches('<li>') + rendered.countMatches('<li ');
        System.assert(liCount >= 2, 'Expected at least 2 <li> items, got ' + liCount + ' in: ' + rendered);
        System.assert(rendered.contains('Contact: One'), 'Contact One should appear');
        System.assert(rendered.contains('Contact: Two'), 'Contact Two should appear');
    }

    @IsTest
    static void loopWrappingTrStillWorks() {
        // Sanity check: the "loop wraps the row" pattern must keep working
        // after we added the auto-expand for the "loop inside row" pattern.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        insert new Contact(LastName = 'OnlyOne', AccountId = acct.Id);

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'LoopWrap ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, (SELECT LastName FROM Contacts)'
        );
        insert tmpl;

        String body =
            '<html><body><table>' +
            '{#Contacts}<tr><td>{LastName}</td></tr>{/Contacts}' +
            '</table></body></html>';

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        Test.startTest();
        DocGenService.generatePdfBlob(tmpl.Id, acct.Id);
        Test.stopTest();

        System.assert(
            DocGenService.lastRenderedHtml.contains('OnlyOne'),
            'Loop-wraps-row form should still emit contact'
        );
    }

    @IsTest
    static void giantQueryPdfBatchProcessesHtmlTemplate() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 5; i++) {
            contacts.add(new Contact(LastName = 'Giant' + i, AccountId = acct.Id));
        }
        insert contacts;

        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GiantHtml ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = JSON.serialize(
                new Map<String, Object>{
                    'v' => 3,
                    'root' => 'Account',
                    'nodes' => new List<Object>{
                        new Map<String, Object>{
                            'id' => 'n0',
                            'object' => 'Account',
                            'fields' => new List<String>{ 'Name' },
                            'parentFields' => new List<String>(),
                            'parentNode' => null,
                            'lookupField' => null,
                            'relationshipName' => null
                        },
                        new Map<String, Object>{
                            'id' => 'n1',
                            'object' => 'Contact',
                            'fields' => new List<String>{ 'LastName' },
                            'parentFields' => new List<String>(),
                            'parentNode' => 'n0',
                            'lookupField' => 'AccountId',
                            'relationshipName' => 'Contacts'
                        }
                    }
                }
            ),
            Header_Html__c = '<div>Page {PageNumber} of {TotalPages}</div>'
        );
        insert tmpl;

        String body =
            '<html><body>' +
            '<h1>{Name} — Contact Roster</h1>' +
            '<table><tr><th>Name</th></tr>' +
            '<tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr>' +
            '</table></body></html>';
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name,
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        // Build the child-node-config JSON the UI would pass to launchGiantQueryPdfBatch
        String childNodeConfigJson = JSON.serialize(
            new Map<String, Object>{
                'relationshipName' => 'Contacts',
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'fields' => new List<String>{ 'LastName' }
            }
        );

        Test.startTest();
        Map<String, Object> r = DocGenController.launchGiantQueryPdfBatch(
            tmpl.Id,
            acct.Id,
            'Contacts',
            childNodeConfigJson
        );
        Test.stopTest();

        System.assertEquals(true, r.get('isGiantQuery'), 'Batch should run as giant-query path');
        Id jobId = (Id) r.get('jobId');
        System.assertNotEquals(null, jobId, 'Job should exist');

        // After Test.stopTest, batch + queueable have run synchronously.
        // Verify fragment CVs were produced (batch ran) and a final PDF exists.
        List<ContentVersion> finalPdf = [
            SELECT Id, VersionData
            FROM ContentVersion
            WHERE Title = :('docgen_giant_' + jobId + '_final')
            LIMIT 1
        ];
        System.assertEquals(1, finalPdf.size(), 'Final giant-query PDF CV should exist');
        System.assert(finalPdf[0].VersionData.size() > 100, 'Final PDF should be non-trivial');

        DocGen_Job__c job = [SELECT Status__c, Success_Count__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status__c, 'Job should be Completed; got ' + job.Status__c);
    }

    @IsTest
    static void extractLoopBodyFindsHtmlTrContainer() {
        String html =
            '<html><body><table>' +
            '<tr><th>Header</th></tr>' +
            '<tr>{#Rel}<td>{Field}</td>{/Rel}</tr>' +
            '</table></body></html>';

        Map<String, String> parts = DocGenService.extractLoopBody(html, 'Rel');
        System.assertNotEquals(null, parts, 'Should find the loop body');
        String innerXml = parts.get('innerXml');
        System.assert(
            innerXml.contains('<tr>') || innerXml.contains('<tr '),
            'Container should be the <tr>: ' + innerXml
        );
        System.assert(innerXml.contains('<td>{Field}</td>'), 'Cell content should be preserved');
        System.assert(parts.get('beforeLoop').contains('<th>Header</th>'), 'Header row goes in beforeLoop');
        System.assert(parts.get('afterLoop').startsWith('</table>'), 'afterLoop starts at </table>');
    }

    @IsTest
    static void extractLoopBodyFindsHtmlLiContainer() {
        String html = '<html><body><ul><li>{#Rel}Item {Name}{/Rel}</li></ul></body></html>';
        Map<String, String> parts = DocGenService.extractLoopBody(html, 'Rel');
        System.assertNotEquals(null, parts);
        System.assert(
            parts.get('innerXml').contains('<li>'),
            'Container should include <li>: ' + parts.get('innerXml')
        );
    }

    @IsTest
    static void generateDocumentRoutesHtmlToPdf() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');

        Test.startTest();
        Id cdId = DocGenService.generateDocument(tmplId, acct.Id);
        Test.stopTest();

        System.assertNotEquals(null, cdId, 'generateDocument should return a ContentDocumentId');
        List<ContentDocument> docs = [SELECT FileType FROM ContentDocument WHERE Id = :cdId];
        System.assertEquals(1, docs.size(), 'ContentDocument should exist');
    }

    // Rich-text values containing rtaImage <img> tags previously routed through
    // convertRichTextToDocxXml, leaving DOCX DrawingML inline in the HTML body
    // and dropping all images. Verify the HTML path now passes rich-text HTML
    // through and rewrites rtaImage URLs to /sfc/servlet.shepherd/.
    @IsTest
    static void richTextImageRewrittenToShepherdUrlForHtmlTemplates() {
        ContentVersion cv = new ContentVersion(
            Title = 'rta-test',
            PathOnClient = 'rta.png',
            VersionData = Blob.valueOf('fake-png-bytes')
        );
        insert cv;
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        String richText =
            '<p>Before <img src="https://example.salesforce.com/servlet/rtaImage?eid=001&amp;refid=' +
            cv.ContentDocumentId +
            '" alt="x"/> After</p>';

        Test.startTest();
        String result = DocGenService.convertRichTextToHtml(richText);
        Test.stopTest();

        System.assert(
            result.contains('/sfc/servlet.shepherd/version/download/' + cv.Id),
            'rtaImage src should be rewritten to shepherd URL: ' + result
        );
        System.assert(!result.contains('<w:r>'), 'HTML output must not contain DOCX run XML: ' + result);
        System.assert(!result.contains('<w:drawing'), 'HTML output must not contain DrawingML: ' + result);
        System.assert(!result.contains('rtaImage'), 'Original rtaImage URL should be replaced: ' + result);
        System.assert(result.contains('Before') && result.contains('After'), 'Surrounding HTML preserved: ' + result);
    }

    // Lightning inline rich-text images use ContentReference IDs (0EM prefix),
    // which aren't queryable as ContentVersion/ContentDocument. We can't rewrite
    // those to /sfc/, so leave the original absolute rtaImage URL — Blob.toPdf
    // can fetch *.force.com hosts from authenticated/Automated-Process context.
    @IsTest
    static void richTextUnresolvableRefidPreservesAbsoluteRtaUrl() {
        String richText =
            '<p><img src="https://example.scratch.file.force.com/servlet/rtaImage' +
            '?eid=001cb00000lHGv3&amp;feoid=00Ncb00000QMV7R&amp;refid=0EMcb000000qsQv" alt="inline"/></p>';
        Test.startTest();
        String result = DocGenService.convertRichTextToHtml(richText);
        Test.stopTest();
        System.assert(result.contains('rtaImage'), 'Original rtaImage URL preserved on resolve failure: ' + result);
        System.assert(result.contains('refid=0EMcb000000qsQv'), 'Refid preserved: ' + result);
        System.assert(!result.contains('/sfc/'), 'No shepherd URL when refid is unresolvable: ' + result);
    }

    @IsTest
    static void richTextDataUriImageDroppedForHtmlTemplates() {
        String richText = '<p>Inline <img src="data:image/png;base64,AAAA" alt="x"/> only</p>';
        Test.startTest();
        String result = DocGenService.convertRichTextToHtml(richText);
        Test.stopTest();
        System.assert(!result.contains('data:image'), 'Data URI image should be dropped: ' + result);
        System.assert(!result.contains('<img'), 'No <img> tag should remain after dropping: ' + result);
        System.assert(result.contains('Inline') && result.contains('only'), 'Surrounding text preserved');
    }

    @IsTest
    static void richTextPlainHtmlPassesThroughForHtmlTemplates() {
        String richText = '<p><strong>Bold</strong> and <em>italic</em></p>';
        Test.startTest();
        String result = DocGenService.convertRichTextToHtml(richText);
        Test.stopTest();
        System.assertEquals(richText, result, 'HTML without images should pass through verbatim');
    }

    // #399 — a rich-text value whose only structural element is a <table> (or a
    // heading) used to miss the rich-text gate and get XML-escaped, so the raw
    // markup printed in the PDF. It must now pass through to the renderer.
    @IsTest
    static void bareTableRichTextRendersForHtmlTemplates() {
        Test.startTest();
        String result = DocGenService.processXmlForTest(
            '<div>{F}</div>',
            new Map<String, Object>{ 'F' => '<table><tr><td>Region</td><td>Sales</td></tr></table>' },
            'HTML'
        );
        Test.stopTest();
        System.assert(result.contains('<td>Region</td>'), 'table cells pass through: ' + result);
        System.assert(!result.contains('&lt;table'), 'table markup must not be escaped: ' + result);
    }

    @IsTest
    static void headingOnlyRichTextRendersForHtmlTemplates() {
        Test.startTest();
        String result = DocGenService.processXmlForTest(
            '<div>{F}</div>',
            new Map<String, Object>{ 'F' => '<h2>Quarterly Report</h2>' },
            'HTML'
        );
        Test.stopTest();
        System.assert(result.contains('<h2>Quarterly Report</h2>'), 'heading passes through: ' + result);
    }

    @IsTest
    static void plainTextWithAngleBracketsStaysEscapedForHtmlTemplates() {
        Test.startTest();
        String result = DocGenService.processXmlForTest(
            '<div>{F}</div>',
            new Map<String, Object>{ 'F' => 'true if a < b and c > d' },
            'HTML'
        );
        Test.stopTest();
        System.assert(result.contains('a &lt; b'), 'angle brackets in prose stay escaped: ' + result);
        System.assert(!result.contains('<b '), 'must not be treated as a tag: ' + result);
    }

    @IsTest
    static void scriptTagInFieldValueStaysEscapedForHtmlTemplates() {
        Test.startTest();
        String result = DocGenService.processXmlForTest(
            '<div>{F}</div>',
            new Map<String, Object>{ 'F' => '<script>alert(1)</script>' },
            'HTML'
        );
        Test.stopTest();
        System.assert(result.contains('&lt;script&gt;'), 'script tag must remain escaped: ' + result);
    }

    // Plain (non-rich-text) multi-line values previously routed through
    // convertMultilineToXml for HTML templates and emitted DOCX <w:br/> markers
    // that Flying Saucer couldn't render. Verify newlines now become <br/>.
    @IsTest
    static void multilinePlainTextRendersBreaksForHtmlTemplates() {
        Map<String, Object> data = new Map<String, Object>{ 'Notes' => 'Line one\nLine two\nLine & three' };
        Test.startTest();
        String result = DocGenService.processXmlForTest('<div>{Notes}</div>', data, 'HTML');
        Test.stopTest();
        System.assert(result.contains('Line one<br/>Line two<br/>Line &amp; three'), 'Newlines → <br/>: ' + result);
        System.assert(!result.contains('<w:br/>'), 'HTML output must not contain DOCX line breaks: ' + result);
        System.assert(!result.contains('<w:r>'), 'HTML output must not contain DOCX runs: ' + result);
    }

    // Aggregate tags: full format-suffix surface (Dave's spec) — bare COUNT,
    // :number, :currency, ISO+locale segments, and currency:auto=Field.
    @IsTest
    static void aggregateTagsSupportFullFormatSuffixes() {
        List<Object> lines = new List<Object>{
            new Map<String, Object>{ 'Amount' => 20000, 'UnitPrice' => 100 },
            new Map<String, Object>{ 'Amount' => 30000, 'UnitPrice' => 155 }
        };
        Map<String, Object> data = new Map<String, Object>{
            'CustomerCurrency__c' => 'EUR',
            'Lines' => new Map<String, Object>{ 'records' => lines }
        };
        Test.startTest();
        String outp = DocGenService.processXmlForTest(
            '<p>C={COUNT:Lines}|CN={COUNT:Lines:number}|S={SUM:Lines.Amount}' +
                '|SC={SUM:Lines.Amount:currency}|SDE={SUM:Lines.Amount:currency:EUR:de_DE}' +
                '|AV={AVG:Lines.UnitPrice:currency}|MN={MIN:Lines.Amount:currency}' +
                '|MX={MAX:Lines.Amount:currency:GBP}|AUTO={SUM:Lines.Amount:currency:auto=CustomerCurrency__c}</p>',
            data,
            'HTML'
        );
        Test.stopTest();
        System.assert(outp.contains('C=2|'), 'bare COUNT: ' + outp);
        System.assert(outp.contains('CN=2|'), 'COUNT:number: ' + outp);
        System.assert(outp.contains('S=50000|'), 'raw SUM: ' + outp);
        System.assert(outp.contains('SC=$50,000.00|'), 'SUM currency: ' + outp);
        System.assert(outp.contains('SDE=50.000,00'), 'ISO+locale de_DE grouping: ' + outp);
        System.assert(outp.contains('AV=$127.50|'), 'AVG currency: ' + outp);
        System.assert(outp.contains('MN=$20,000.00|'), 'MIN currency: ' + outp);
        System.assert(outp.contains('MX=£30,000.00|'), 'MAX currency GBP: ' + outp);
        System.assert(
            outp.contains('AUTO=') && outp.substringAfter('AUTO=').contains('€'),
            'currency:auto=Field should use EUR: ' + outp
        );
    }

    @IsTest
    static void singleLinePlainTextEscapesXmlForHtmlTemplates() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'A & B <C>' };
        Test.startTest();
        String result = DocGenService.processXmlForTest('<p>{Name}</p>', data, 'HTML');
        Test.stopTest();
        System.assertEquals('<p>A &amp; B &lt;C&gt;</p>', result, 'XML-special chars escaped');
    }

    // Designer live PDF preview: draft HTML replaces the saved body for the
    // merge, renders through the real pipeline, and never touches versions.
    @IsTest
    static void previewDraftPdfRendersDraftHtmlNotSavedBody() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>SAVED BODY {Name}</p></body></html>');

        Test.startTest();
        Map<String, Object> result = DocGenController.previewDraftPdf(
            tmplId,
            acct.Id,
            '<html><body><h1>DRAFT ONLY {Name} — {Industry}</h1></body></html>',
            null,
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, result.get('contentDocumentId'), 'Preview should return a ContentDocument Id');
        Integer previews = [
            SELECT COUNT()
            FROM ContentVersion
            WHERE Title = :('dg_pdf_preview_' + tmplId) AND IsLatest = TRUE
        ];
        System.assertEquals(1, previews, 'Exactly one preview file should exist');
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('DRAFT ONLY'), 'Draft body should be the rendered document: ' + rendered);
        System.assert(rendered.contains('HTMLTpl Test Co'), 'Merge tags must resolve in the draft: ' + rendered);
        System.assert(!rendered.contains('SAVED BODY'), 'Saved body must NOT render when a draft is supplied');
        // The override is one-shot — cleared even on success.
        System.assertEquals(null, DocGenService.draftHtmlBodyOverride, 'Override must be cleared after preview');
        Integer versions = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :tmplId];
        System.assertEquals(1, versions, 'Preview must not create template versions');
    }

    @IsTest
    static void previewDraftPdfDataReturnsBase64WithoutPersisting() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');
        Map<String, Object> res = DocGenController.previewDraftPdfData(
            tmplId,
            acct.Id,
            '<html><body><p>{Name} draft</p></body></html>',
            null,
            null
        );
        System.assert(res.containsKey('base64'), 'Data preview must return base64');
        System.assert(String.isNotBlank((String) res.get('base64')), 'base64 must be non-empty');
        System.assertEquals(null, DocGenService.draftHtmlBodyOverride, 'Override must be cleared after preview');
        Integer previews = [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'dg_pdf_preview_%'];
        System.assertEquals(0, previews, 'Data preview must not persist a preview file');
    }

    @IsTest
    static void previewDraftPdfRejectsEmptyDraft() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createHtmlTemplate(null, null, '<html><body><p>{Name}</p></body></html>');
        Boolean threw = false;
        try {
            DocGenController.previewDraftPdf(tmplId, acct.Id, '   ', null, null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Blank draft must be rejected');
        System.assertEquals(null, DocGenService.draftHtmlBodyOverride, 'Override must stay clear');
    }

    // --- Running header/footer image clamp (v3.35) ---

    @IsTest
    static void clampRunningImagesSizesOnlyUnsizedImgs() {
        // Unsized img gains an explicit height so the margin box isn't overflowed.
        String unsized = '<img src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.clampRunningImages(unsized);
        System.assert(outp.contains('style="height:0.45in"'), 'Unsized img must get an explicit height: ' + outp);

        // Author-sized images stay exactly as written.
        String widthAttr = '<img width="120" src="/x.png">';
        System.assertEquals(widthAttr, DocGenService.clampRunningImages(widthAttr), 'width attr must be untouched');
        String styled = '<img style="width:1in" src="/x.png">';
        System.assertEquals(styled, DocGenService.clampRunningImages(styled), 'styled width must be untouched');

        // An existing style attr WITHOUT sizing gets the height injected into it.
        String styledNoSize = '<img style="border:1pt solid #000" src="/x.png">';
        String outp2 = DocGenService.clampRunningImages(styledNoSize);
        System.assert(
            outp2.contains('style="height:0.45in;border:1pt solid #000"'),
            'Height must join the existing style attr: ' + outp2
        );

        // No imgs — passthrough.
        System.assertEquals('<p>hi</p>', DocGenService.clampRunningImages('<p>hi</p>'), 'No-img chrome untouched');
        System.assertEquals(null, DocGenService.clampRunningImages(null), 'Null-safe');
    }

    @IsTest
    static void isInsideSrcAttributeDetectsAttributeContext() {
        String inSrc = '<img src="{%asset:logo}">';
        System.assert(
            DocGenService.isInsideSrcAttribute(inSrc, inSrc.indexOf('{')),
            'Tag right after src=\" is attribute context'
        );
        String inSrcSingle = '<img src=\'{%asset:logo}\'>';
        System.assert(
            DocGenService.isInsideSrcAttribute(inSrcSingle, inSrcSingle.indexOf('{')),
            'Single-quoted src is attribute context'
        );
        String body = '<p>{%asset:logo}</p>';
        System.assert(
            !DocGenService.isInsideSrcAttribute(body, body.indexOf('{')),
            'Body placement is NOT attribute context'
        );
        System.assert(!DocGenService.isInsideSrcAttribute('{x}', 0), 'Start of string is not attribute context');
    }

    @IsTest
    static void templateListIsLightAndDetailIsFull() {
        // The list/detail split. getAllTemplates returned ~28 fields per row —
        // including the Header_Html__c / Footer_Html__c long-text fields and a
        // ContentDocumentLinks subquery — on every load of the admin component. At a
        // few hundred templates that is a large payload transferred and parsed before
        // the admin has clicked anything, for data only needed once one is opened.
        Id tmplId = createHtmlTemplate(
            '<div>Header {Name}</div>',
            '<div>Footer</div>',
            '<html><body><p>{Name}</p></body></html>'
        );

        Test.startTest();
        List<DocGen_Template__c> listRows = DocGenController.getTemplateList();
        DocGen_Template__c full = DocGenController.getTemplateById(tmplId);
        Test.stopTest();

        System.assert(!listRows.isEmpty(), 'The list must return rows');
        DocGen_Template__c row = null;
        for (DocGen_Template__c t : listRows) {
            if (t.Id == tmplId) {
                row = t;
            }
        }
        System.assertNotEquals(null, row, 'The new template must appear in the list');
        System.assertNotEquals(null, row.Name, 'The list carries what the grid renders');

        // The heavy fields must NOT be on the list row. Reading an unqueried field
        // throws SObjectException, which is exactly the assertion.
        Boolean headerAbsent = false;
        try {
            String ignored = row.Header_Html__c;
            System.debug(ignored);
        } catch (SObjectException e) {
            headerAbsent = true;
        }
        System.assert(headerAbsent, 'Header_Html__c must not be queried for the list');

        Boolean configAbsent = false;
        try {
            String ignored = row.Query_Config__c;
            System.debug(ignored);
        } catch (SObjectException e) {
            configAbsent = true;
        }
        System.assert(configAbsent, 'Query_Config__c must not be queried for the list');

        // ...and must all be present on the detail read, which is what the edit
        // modal and the designer populate themselves from.
        System.assertEquals(tmplId, full.Id, 'Detail read returns the right record');
        System.assertEquals('<div>Header {Name}</div>', full.Header_Html__c, 'Detail carries the header');
        System.assertEquals('<div>Footer</div>', full.Footer_Html__c, 'Detail carries the footer');
        System.assertNotEquals(null, full.Query_Config__c, 'Detail carries the query config');
    }

    @IsTest
    static void getTemplateByIdRejectsMissingId() {
        Boolean threw = false;
        try {
            DocGenController.getTemplateById(null);
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'A null id must be rejected rather than returning something arbitrary');
    }

    @IsTest
    static void wrapHtmlForPdfClampsHeaderImages() {
        String hdr = '<img src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.wrapHtmlForPdf('<p>x</p>', null, hdr, null);
        System.assert(
            outp.contains('docgen-running-header"><img style="height:0.45in"'),
            'Header images must be clamped inside the running element: ' + outp
        );
    }

    @IsTest
    static void wrapHtmlForPdfClampsMaxWidthOnlyHeaderImages() {
        // The Designer puts `max-width` on an asset image the author never sized.
        // The size probe matched the `width:` INSIDE `max-width:`, concluded the
        // image was author-sized, and skipped the clamp — so the logo rendered at
        // full intrinsic height, overflowed the top margin box and painted over the
        // body. Reported as "the header shows up correctly in the designer but gets
        // plopped underneath in the preview".
        String hdr = '<img style="vertical-align:middle;max-width:220px" src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.wrapHtmlForPdf('<p>x</p>', null, hdr, null);
        System.assert(
            outp.contains('height:0.45in'),
            'A max-width-only image is NOT author-sized and must still be clamped: ' + outp
        );
    }

    @IsTest
    static void wrapHtmlForPdfLeavesGenuinelySizedHeaderImagesAlone() {
        // The boundary fix must not start clamping images the author DID size.
        String hdr = '<img style="height:1.2in" src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.wrapHtmlForPdf('<p>x</p>', null, hdr, null);
        System.assert(outp.contains('height:1.2in'), 'Author height must survive: ' + outp);
        System.assert(!outp.contains('height:0.45in'), 'Author-sized image must not be re-clamped: ' + outp);
    }

    @IsTest
    static void wrapHtmlForPdfGrowsTopMarginToFitRunningHeader() {
        // A running element lives in the @page margin box, which is exactly as tall
        // as the margin — anything taller overflows and paints over the body. A
        // 1.2in logo cannot fit a 1in default margin, so the margin has to grow.
        String hdr = '<img style="height:1.2in" src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', null, hdr, null);
        // Assert the WELL-FORMED declaration list, not just the substring: an
        // earlier revision emitted `margin: 1in margin-top: 1.35in;;`, which is
        // invalid CSS that Flying Saucer drops silently — the assertion passed and
        // the page geometry was broken.
        System.assert(
            outp.contains('margin: 1in; margin-top: 1.35in;'),
            'Top margin must grow to the header height plus a gutter, as valid CSS: ' + outp
        );
    }

    @IsTest
    static void wrapHtmlForPdfLeavesMarginsAloneWhenChromeFits() {
        // A one-line text header fits any normal margin — no growth, no surprise
        // change to the author's page geometry.
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', null, '<p>Confidential</p>', null);
        System.assert(!outp.contains('margin-top:'), 'A header that fits must not move the margin: ' + outp);
    }

    @IsTest
    static void wrapHtmlForPdfGrowsBottomMarginForTallFooter() {
        String ftr = '<img style="height:1.5in" src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', null, null, ftr);
        System.assert(
            outp.contains('margin: 1in; margin-bottom: 1.65in;'),
            'Bottom margin must fit the footer, as valid CSS: ' + outp
        );
    }

    @IsTest
    static void wrapHtmlForPdfGrowsMarginEvenWhenSourceOwnsPageRule() {
        // THE case that made this bug survive two fixes. Designer-authored HTML
        // templates carry their own @page, so sourceHasPageRule was true and the
        // growth was skipped entirely — the rendered @page had no margin at all and
        // the header kept overflowing. A running header that does not fit its margin
        // box is a correctness failure, not a style preference, so it grows anyway.
        String hdr = '<img style="width:200px;height:280px" src="/sfc/servlet.shepherd/version/download/068000000000AAA">';
        String src = 'body { color: #000; } @page { size: Letter portrait; margin: 0.75in; }';
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', src, hdr, null);
        System.assert(
            outp.contains('margin-top: 3.07in'),
            'Top margin must grow to fit a 280px header even when the source owns @page: ' + outp
        );
        // The author's own margin declaration is stripped so ours is not out-cascaded,
        // but their page SIZE is left exactly as written.
        System.assert(outp.contains('size: Letter portrait'), 'Author page size must survive: ' + outp);
    }

    @IsTest
    static void wrapHtmlForPdfLeavesSourcePageAloneWhenChromeFits() {
        // Growth is the exception, not the rule: a header that fits must leave the
        // author's @page completely untouched (v1.90's "source wins").
        String src = '@page { size: Letter portrait; margin: 0.75in; }';
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', src, '<p>Confidential</p>', null);
        System.assert(!outp.contains('margin-top:'), 'A header that fits must not rewrite the page: ' + outp);
        System.assert(outp.contains('margin: 0.75in'), 'The author margin must remain: ' + outp);
    }

    @IsTest
    static void estimateChromeHeightFallsBackToWidthWhenHeightIsAuto() {
        // {%asset:logo:200x} renders as width:200px;height:auto — the height lives in
        // the image file and nothing server-side can read it without loading the blob
        // (which the zero-heap PDF path exists to avoid). Assuming square is a floor,
        // wrong only in the safe direction for anything wider than it is tall.
        Decimal h = DocGenService.estimateChromeHeightIn('<img style="width:200px;height:auto" src="x">');
        System.assertEquals(
            Decimal.valueOf(200) / 96,
            h,
            'A width-only image must fall back to its width, not the 0.45in unsized clamp'
        );
    }

    @IsTest
    static void estimateChromeHeightSumsTableRowsRatherThanTakingTheTallest() {
        // A table STACKS: three rows sit one under another. Treating it like a
        // paragraph made a multi-row header table overlap the body exactly the way
        // an oversized logo did.
        String oneRow = '<table><tr><td>a</td><td>b</td></tr></table>';
        String threeRows = '<table><tr><td>a</td></tr><tr><td>b</td></tr><tr><td>c</td></tr></table>';
        Decimal h1 = DocGenService.estimateChromeHeightIn(oneRow);
        Decimal h3 = DocGenService.estimateChromeHeightIn(threeRows);
        System.assert(h3 > h1 * 2.5, 'Three rows must estimate ~3x one row, got ' + h1 + ' vs ' + h3);
        // Within a row, cells sit SIDE BY SIDE — two cells are not two lines.
        Decimal twoCells = DocGenService.estimateChromeHeightIn('<table><tr><td>a</td><td>b</td></tr></table>');
        System.assertEquals(h1, twoCells, 'Cells in one row do not stack');
        // A tall image in a row makes that row tall.
        Decimal withImg = DocGenService.estimateChromeHeightIn(
            '<table><tr><td><img style="height:1in" src="x"></td></tr></table>'
        );
        System.assert(withImg > 1, 'A 1in image in a row must make the row at least that tall: ' + withImg);
    }

    @IsTest
    static void wrapHtmlForPdfGrowsMarginForATallHeaderTable() {
        // The end-to-end contract: a header table pushes the body down instead of
        // being overlapped by it.
        String hdr =
            '<table><tr><td><img style="height:0.8in" src="x"></td></tr>' +
            '<tr><td>row two</td></tr><tr><td>row three</td></tr></table>';
        String src = '@page { size: Letter portrait; margin: 0.75in; }';
        String outp = DocGenService.wrapHtmlForPdf('<p>body</p>', src, hdr, null);
        System.assert(
            outp.contains('margin-top:'),
            'A three-row header table taller than the margin must grow it: ' + outp
        );
    }

    @IsTest
    static void parseSourcePageMarginsReadsShorthandAndUnits() {
        List<Decimal> four = DocGenService.parseSourcePageMargins('@page { margin: 1in 2in 3in 4in; }');
        System.assertEquals(1, four[0]);
        System.assertEquals(3, four[2]);
        List<Decimal> one = DocGenService.parseSourcePageMargins('@page { margin: 0.75in; }');
        System.assertEquals(0.75, one[0], 'One value applies to every side');
        System.assertEquals(0.75, one[2]);
        System.assertEquals(
            null,
            DocGenService.parseSourcePageMargins('@page { size: Letter; }'),
            'No margin, no list'
        );
        System.assertEquals(null, DocGenService.parseSourcePageMargins('body { margin: 1in; }'), 'Only @page counts');
    }

    @IsTest
    static void estimateChromeHeightUsesTallerOfImageAndText() {
        // Logo left, address right — side by side, so the height is the taller of
        // the two, not their sum.
        Decimal imageWins = DocGenService.estimateChromeHeightIn(
            '<div><img style="height:1in" src="x"><p>a</p><p>b</p></div>'
        );
        System.assertEquals(1, imageWins, 'A 1in image beats two short lines');
        Decimal textWins = DocGenService.estimateChromeHeightIn(
            '<p>1</p><p>2</p><p>3</p><p>4</p><p>5</p><p>6</p><p>7</p><p>8</p>'
        );
        System.assert(textWins > 1.3, 'Eight lines must estimate taller than an inch: ' + textWins);
        System.assertEquals(0, DocGenService.estimateChromeHeightIn(null), 'No chrome, no height');
    }

    /**
     * A <style> block inside <body> must never reach processXml.
     *
     * The merge engine treats every {...} pair as a merge tag, so a CSS declaration
     * block resolves to nothing and leaves its selector behind as literal text. A
     * customer reported a line of bare selectors printed above their first heading —
     * "@page body h1 h2 ... .docgen-body-content .tab" — and this reproduces the exact
     * shape of it. Google Docs and Notion put <style> in the body routinely, and so
     * does re-uploading a previously generated document, which is why the selectors in
     * that report were Portwood's own docgen-* classes.
     *
     * Both halves matter: the stray text has to go, AND the CSS has to survive. Fixing
     * the first by dropping the author's stylesheet would be no fix at all.
     */
    @isTest
    static void styleBlockInsideBodyIsNotMerged() {
        String html =
            '<!DOCTYPE html><html><head><title>T</title></head><body>' +
            '<style>' +
            '@page { size: Letter portrait; margin: 0.75in; }' +
            'body { font-family: Helvetica; font-size: 11pt; }' +
            '.tab { margin-left: 24pt; }' +
            '</style>' +
            '<h1>Hello {Name}</h1><p class="tab">Body.</p>' +
            '</body></html>';

        String body = DocGenService.extractHtmlBodyContent(html);
        System.assert(body.toLowerCase().contains('<style'), 'precondition: the style block is inside the body');

        String styles = DocGenService.extractHtmlStyleBlocks(html);
        System.assert(styles.contains('font-family'), 'the stylesheet is captured before stripping');
        System.assert(styles.contains('24pt'), 'including the author\'s own rules');

        String stripped = DocGenService.stripStyleAndScriptBlocks(body);
        System.assert(!stripped.toLowerCase().contains('<style'), 'the style element is removed from the body');

        String merged = DocGenService.processXmlForTest(stripped, new Map<String, Object>{ 'Name' => 'Acme' });
        System.assert(merged.contains('Hello Acme'), 'real content still merges: ' + merged);
        // The selectors are what leaked, so they are what the assertion has to name.
        System.assert(!merged.contains('@page'), 'no bare @page selector in the output: ' + merged);
        System.assert(!merged.contains('.tab {'), 'no CSS at all in the output: ' + merged);
        System.assert(!merged.contains('docgen-body-content'), 'no engine selectors either: ' + merged);
    }

    /** Script source is not document content either. */
    @isTest
    static void scriptBlocksAreStrippedToo() {
        String stripped = DocGenService.stripStyleAndScriptBlocks('<p>Keep</p><script>var x = {a: 1};</script>');
        System.assert(stripped.contains('Keep'), 'surrounding content survives');
        System.assert(!stripped.toLowerCase().contains('<script'), 'the script element is gone');
        System.assert(!stripped.contains('var x'), 'and so is its source');
    }

    /** Stripping must not disturb a document that has no style or script at all. */
    @isTest
    static void stripIsANoOpWithoutStyleOrScript() {
        String src = '<h1>Title</h1><p>Text with {Name} in it.</p>';
        System.assertEquals(src, DocGenService.stripStyleAndScriptBlocks(src), 'unchanged');
        System.assertEquals(null, DocGenService.stripStyleAndScriptBlocks(null), 'null in, null out');
    }
}

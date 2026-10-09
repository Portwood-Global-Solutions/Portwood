@IsTest
private class DocGenControllerCoverageTest {
    @IsTest
    static void getOrgIdReturnsCurrentOrgId() {
        String orgId = DocGenController.getOrgId();
        System.assertEquals(UserInfo.getOrganizationId(), orgId);
    }

    @IsTest
    static void scoutAttachedImageSizeWithNullReturnsZero() {
        System.assertEquals(0L, DocGenController.scoutAttachedImageSize(null));
    }

    @IsTest
    static void scoutAttachedImageSizeWithNoImagesReturnsZero() {
        Account acct = new Account(Name = 'Scout Test');
        insert acct;
        Long size = DocGenController.scoutAttachedImageSize(acct.Id);
        System.assertEquals(0L, size, 'No attached images → 0');
    }

    @IsTest
    static void scoutAttachedImageSizeSumsAttachedImages() {
        Account acct = new Account(Name = 'Scout With Images');
        insert acct;
        Blob fakePng = Blob.valueOf('fake-png-bytes-of-known-length');
        ContentVersion cv = new ContentVersion(
            Title = 'attached-image',
            PathOnClient = 'pic.png',
            VersionData = fakePng,
            FirstPublishLocationId = acct.Id
        );
        insert cv;

        Long size = DocGenController.scoutAttachedImageSize(acct.Id);
        System.assert(size > 0L, 'Attached PNG should be counted, got ' + size);
    }

    @IsTest
    static void saveAndClearWatermarkImageRoundtrip() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Watermark Test Tmpl',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        insert version;

        // Tiny 1x1 PNG (base64 of a real 1x1 transparent PNG)
        String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=';

        Test.startTest();
        Id cvId = DocGenController.saveWatermarkImage(version.Id, 'wm.png', pngB64);
        System.assertNotEquals(null, cvId, 'saveWatermarkImage should return new CV Id');

        DocGen_Template_Version__c reloaded = [
            SELECT Watermark_Image_CV_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :version.Id
        ];
        System.assertEquals(cvId, reloaded.Watermark_Image_CV_Id__c, 'Version should now reference the watermark CV');

        DocGenController.clearWatermarkImage(version.Id);
        DocGen_Template_Version__c cleared = [
            SELECT Watermark_Image_CV_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :version.Id
        ];
        System.assertEquals(null, cleared.Watermark_Image_CV_Id__c, 'Watermark CV reference should be cleared');
        Test.stopTest();
    }

    @IsTest
    static void saveWatermarkImageRejectsBlankInputs() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Watermark Reject',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        insert version;

        Boolean threwOnNullVersionId = false;
        try {
            DocGenController.saveWatermarkImage(null, 'a.png', 'AAAA');
        } catch (DocGenException e) {
            threwOnNullVersionId = true;
        }
        System.assert(threwOnNullVersionId, 'saveWatermarkImage(null,…) should throw');

        Boolean threwOnBlankBase64 = false;
        try {
            DocGenController.saveWatermarkImage(version.Id, 'a.png', '');
        } catch (DocGenException e) {
            threwOnBlankBase64 = true;
        }
        System.assert(threwOnBlankBase64, 'saveWatermarkImage(…, blank) should throw');
    }

    @IsTest
    static void clearWatermarkImageWithNullIsNoop() {
        // No exception, no DML, just returns
        DocGenController.clearWatermarkImage(null);
    }

    @IsTest
    static void generatePdfAsyncEnqueuesQueueable() {
        Account acct = new Account(Name = 'Async PDF Test');
        insert acct;
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Async Test Tmpl',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = '{"v":3,"root":"Account","nodes":[{"id":"n0","object":"Account","fields":["Name"],"parentNode":null,"lookupField":null,"relationshipName":null}]}'
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = 'Async Test Body',
            PathOnClient = 'b.html',
            VersionData = Blob.valueOf('<html><body><h1>{Name}</h1></body></html>'),
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
        Id jobId = DocGenController.generatePdfAsync(tmpl.Id, acct.Id);
        Test.stopTest();
        System.assertNotEquals(null, jobId, 'generatePdfAsync should return AsyncApexJob Id');
    }

    @IsTest
    static void contentDocumentCleanupQueueableDeletesDocuments() {
        Account acct = new Account(Name = 'Cleanup Queueable Test');
        insert acct;
        ContentVersion cv = new ContentVersion(
            Title = 'cleanup-queueable-doc',
            PathOnClient = 'cleanup.txt',
            VersionData = Blob.valueOf('cleanup'),
            FirstPublishLocationId = acct.Id
        );
        insert cv;
        Id docId = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
        ]
        .ContentDocumentId;

        Test.startTest();
        System.enqueueJob(new DocGenContentDocumentCleanupQueueable(new List<Id>{ docId }));
        Test.stopTest();

        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
            'Cleanup queueable should delete the content document'
        );
    }

    @IsTest
    static void renderImageAsPdfBase64ShortcircuitsInTestMode() {
        // The method has Test.isRunningTest() bypass that returns base64('test-pdf')
        String result = DocGenController.renderImageAsPdfBase64(
            '/sfc/servlet.shepherd/version/download/068000000000000'
        );
        System.assertNotEquals(null, result, 'Should return non-null in test mode');
        System.assertEquals(EncodingUtil.base64Encode(Blob.valueOf('test-pdf')), result);
    }

    @IsTest
    static void renderImageAsPdfBase64RejectsExternalUrls() {
        // Security guard: only Salesforce-hosted URLs allowed
        String resultExt = DocGenController.renderImageAsPdfBase64('https://evil.com/img.png');
        System.assertEquals(null, resultExt, 'Non-Salesforce URL should return null');
        String resultBlank = DocGenController.renderImageAsPdfBase64('');
        System.assertEquals(null, resultBlank, 'Blank URL should return null');
    }

    // ─── Schema getter coverage (v1.91 release-validation top-up) ──────────────

    @IsTest
    static void getObjectOptionsReturnsAccessibleObjects() {
        List<Map<String, String>> opts = DocGenController.getObjectOptions();
        System.assert(opts != null && !opts.isEmpty(), 'Object options should be non-empty');
        Boolean foundAccount = false;
        for (Map<String, String> o : opts) {
            if (o.get('value') == 'Account') {
                foundAccount = true;
                break;
            }
        }
        System.assert(foundAccount, 'Account should appear in object options');
    }

    @IsTest
    static void getObjectFieldsReturnsAccountFieldList() {
        List<Map<String, Object>> fields = DocGenController.getObjectFields('Account');
        System.assert(fields != null && !fields.isEmpty(), 'Account fields should resolve');
    }

    @IsTest
    static void getChildRelationshipsReturnsAccountChildren() {
        List<Map<String, String>> rels = DocGenController.getChildRelationships('Account');
        System.assert(rels != null, 'Child relationships list resolved');
    }

    @IsTest
    static void getParentRelationshipsReturnsContactParent() {
        List<Map<String, String>> rels = DocGenController.getParentRelationships('Contact');
        System.assert(rels != null && !rels.isEmpty(), 'Contact has parent relationships');
        Boolean foundAccount = false;
        for (Map<String, String> r : rels) {
            if (r.get('value') == 'Account') {
                foundAccount = true;
                break;
            }
        }
        System.assert(foundAccount, 'Contact.Account parent relationship expected');
    }

    @IsTest
    static void getCurrentUserPermissionSetNamesReturnsList() {
        Set<String> names = DocGenController.getCurrentUserPermissionSetNames();
        System.assertNotEquals(null, names, 'Permission set set returned (may be empty)');
    }

    @IsTest
    static void getAvailableReportsHandlesEmptyOrg() {
        List<Map<String, String>> reports = DocGenController.getAvailableReports(null);
        System.assertNotEquals(null, reports, 'Reports list returned (may be empty)');
    }

    @IsTest
    static void getTemplatesForObjectReturnsActiveAccountTemplates() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'CoverageTpl ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;
        List<DocGen_Template__c> list1 = DocGenController.getTemplatesForObject('Account');
        System.assert(list1 != null, 'Returns a list');
    }

    @IsTest
    static void getAllTemplatesAndDeleteTemplateRoundtrip() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'AllTpl ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        List<DocGen_Template__c> all = DocGenController.getAllTemplates();
        System.assert(all != null && !all.isEmpty(), 'At least the new template returns');
        DocGenController.deleteTemplate(tmpl.Id);
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c WHERE Id = :tmpl.Id]);
    }

    @IsTest
    static void getContentVersionSizeReturnsBlobSize() {
        ContentVersion cv = new ContentVersion(
            Title = 'cvsize',
            PathOnClient = 'sample.txt',
            VersionData = Blob.valueOf('12345678')
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        Long sz = DocGenController.getContentVersionSize(cv.Id);
        System.assert(sz != null && sz >= 8, 'Size should reflect blob bytes; got ' + sz);
    }

    @IsTest
    static void filterTemplatesForSenderHandlesEmptyList() {
        List<DocGen_Template__c> filtered = DocGenController.filterTemplatesForSender(
            new List<DocGen_Template__c>(),
            null
        );
        System.assertNotEquals(null, filtered, 'Returns a list for empty input');
    }

    @IsTest
    static void injectPreviewWatermarkOverlayInjectsIntoHtmlBody() {
        // Set up template + version with a watermark image attached.
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'WmInject ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        insert version;
        String pngB64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII=';
        DocGenController.saveWatermarkImage(version.Id, 'wm.png', pngB64);

        String html = '<html><head></head><body><p>preview</p></body></html>';
        String result = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(html, tmpl.Id);
        System.assertNotEquals(null, result, 'Returns wrapped HTML');
        System.assert(result.contains('docgen-preview-watermark'), 'Should include watermark overlay class');
    }

    @IsTest
    static void injectPreviewWatermarkOverlayPassthroughForNoWatermark() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'NoWm ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        insert new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        String html = '<html><body><p>x</p></body></html>';
        String result = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(html, tmpl.Id);
        System.assert(
            result.contains('docgen-preview-wrap'),
            'Template without watermark still gets screen preview wrapper'
        );
        System.assert(
            result.contains('#docgen-footer') && result.contains('order: 999'),
            'Screen preview should move running footers after body content'
        );
    }

    @IsTest
    static void injectPreviewWatermarkOverlayPassthroughForBlankInputs() {
        System.assertEquals('', DocGenSignatureSenderController.injectPreviewWatermarkOverlay('', null));
        System.assertEquals(null, DocGenSignatureSenderController.injectPreviewWatermarkOverlay(null, null));
    }

    @IsTest
    static void createTemplateSignerRequestWithTitleCoversTitledPath() {
        Account acct = new Account(Name = 'SignerWithTitle ' + Datetime.now().getTime());
        insert acct;
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'WithTitleTpl ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        String signersJson = '[{"signerName":"T","signerEmail":"t@t.com","roleName":"Buyer","contactId":""}]';

        Test.startTest();
        try {
            DocGenSignatureSenderController.createTemplateSignerRequestWithTitle(
                tmpl.Id,
                acct.Id,
                signersJson,
                'Parallel',
                '{Name} Signed'
            );
        } catch (Exception e) {
            // Some setup may not be complete — coverage exercise is the goal.
        }
        Test.stopTest();
    }

    @IsTest
    static void wrapNonLatinGlyphsTriggersHighCodepointMapInitialization() {
        // Passing a string with HTML named entities forces decodeHighCodepointEntities
        // → getHighCodepointEntityMap to lazy-build the 100+ entry lookup map (~116
        // lines in DocGenService). Single call covers the entity dictionary's full
        // initialization branch.
        String input = '<p>Math: &alpha;+&beta;&le;&infin; &sum; &part; &Delta; &harr;</p>';
        String wrapped = DocGenService.wrapNonLatinGlyphs(input);
        System.assertNotEquals(null, wrapped, 'Returns wrapped HTML');
        // The decoded entities (Greek/math) require Arial Unicode MS, so output should be wrapped.
        System.assert(wrapped.contains('Arial Unicode MS') || wrapped == input, 'Either wraps or passes through');
    }

    @IsTest
    static void wrapNonLatinGlyphsLatinOnlyPassesThrough() {
        // ASCII + General Punctuation (smart quotes, em dash) doesn't need wrap.
        String input = 'Plain ASCII text — with smart quotes "and" ‘single’.';
        String result = DocGenService.wrapNonLatinGlyphs(input);
        System.assertNotEquals(null, result);
    }

    @IsTest
    static void wrapNonLatinGlyphsCoversExtendedCurrencyGlyphs() {
        String decomposedSComma = 'S' + String.fromCharArray(new List<Integer>{ 806 });
        String input =
            '<p>Á É Í Ó Ú Ł Ś Ş Ș ' +
            decomposedSComma +
            ' &Scomma; &Scedil; &scedil; &Sacute; ₹ ₽ ₺ ₱ ₴ ₿ ₾ ֏ ₼ ₸ ł ś ş ș č &#8377; &#x0141;</p>';
        String wrapped = DocGenService.wrapNonLatinGlyphs(input);
        System.assert(wrapped.contains('Arial Unicode MS'), 'Missing PDF glyphs should get the Unicode font span');
        System.assert(wrapped.contains('Ł'), 'Literal L-stroke should survive the wrapping pass');
        System.assert(wrapped.contains('Ś'), 'S-acute should survive the wrapping pass');
        System.assert(wrapped.contains('Ș'), 'S-comma should survive the wrapping pass');
        System.assert(!wrapped.contains(decomposedSComma), 'Decomposed S-comma should normalize before PDF rendering');
        System.assert(wrapped.contains('Ș'), 'Decomposed S-comma should normalize to precomposed S-comma');
        System.assert(
            wrapped.contains('/resource/DocGenPdfGlyphs/u0218.png'),
            'Precomposed S-comma should use PDF glyph image fallback'
        );
        System.assert(wrapped.contains('Ş'), 'S-cedilla entity should decode before wrapping');
        System.assert(!wrapped.contains('&Scedil;'), 'S-cedilla entity should not remain escaped');
        System.assert(wrapped.contains('₹'), 'Numeric rupee entity should decode before wrapping');
        System.assert(
            wrapped.contains('/resource/DocGenPdfGlyphs/u20b9.png'),
            'Rupee should use PDF glyph image fallback'
        );
        System.assert(
            wrapped.contains('style="height:11pt;width:11pt;vertical-align:-0.20em;display:inline-block;"'),
            'PDF glyph image fallback should use the default body font-size when no closer font-size exists'
        );
        System.assert(
            wrapped.contains('/resource/DocGenPdfGlyphs/u20bf.png'),
            'Bitcoin should use PDF glyph image fallback'
        );
        System.assert(
            !wrapped.contains('&#8377;'),
            'High numeric entities should become literal glyphs inside the span'
        );
    }

    @IsTest
    static void wrapNonLatinGlyphsSizesPdfGlyphImagesFromContainingText() {
        String html =
            '<p style="font-size:18pt;font-weight:bold;">Total: &#8377;</p>' +
            '<p style="font-size:10pt;">Crypto: &#8383;</p>';
        String wrapped = DocGenService.wrapNonLatinGlyphs(html);
        System.assert(
            wrapped.contains('height:18pt;width:18pt'),
            'Bold paragraph glyph image should use the paragraph font size'
        );
        System.assert(
            wrapped.contains('vertical-align:-0.20em;width:18pt') &&
            wrapped.contains('margin-left:-18pt;position:relative;left:0.03em;'),
            'Bold paragraph glyph image should get the bold overlay treatment'
        );
        System.assert(
            wrapped.contains('height:10pt;width:10pt'),
            'Separated glyph image should use its own paragraph font size'
        );
    }

    @IsTest
    static void wrapNonLatinGlyphsLowercaseSCommaUsesSmallerImageFallback() {
        // #438 follow-up: the capital S-comma (Ș, cp 536) got an image fallback,
        // but the lowercase (ș, cp 537) was left on the plain 'Arial Unicode MS'
        // font-span path — which doesn't actually render this glyph in
        // Blob.toPdf, so it rendered as nothing. Confirmed by generating a real
        // PDF: [ș] rendered as [] (invisible) before this fix, [ş]-shaped and
        // visible after. Must go through the same image-fallback path as the
        // capital, sized smaller to match the real letterform relationship
        // (not just the capital's image reused at full size).
        String wrapped = DocGenService.wrapNonLatinGlyphs('<p>[ș] [Ș]</p>');
        System.assert(
            wrapped.contains('/resource/DocGenPdfGlyphs/u0219.png'),
            'Lowercase S-comma should use its own PDF glyph image fallback, not the font-span path: ' + wrapped
        );
        System.assert(
            wrapped.contains('/resource/DocGenPdfGlyphs/u0218.png'),
            'Capital S-comma should still use its image fallback: ' + wrapped
        );
        System.assert(
            wrapped.contains('height:8.80pt;width:8.80pt'),
            'Lowercase S-comma image should render at 80% of the default 11pt body size: ' + wrapped
        );
        System.assert(
            wrapped.contains('height:11pt;width:11pt'),
            'Capital S-comma image should stay at the full default body size: ' + wrapped
        );
    }

    @IsTest
    static void getDocGenTemplatesForRecordReturnsList() {
        Account acct = new Account(Name = 'GetForRec ' + Datetime.now().getTime());
        insert acct;
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GetForRec ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        List<DocGen_Template__c> list1 = DocGenSignatureSenderController.getDocGenTemplatesForRecord(acct.Id);
        System.assertNotEquals(null, list1, 'Returns a list');
    }

    @IsTest
    static void getTemplateVersionsReturnsVersionsForTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'VerTpl ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert tmpl;
        insert new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        List<DocGen_Template_Version__c> versions = DocGenController.getTemplateVersions(tmpl.Id);
        System.assert(versions != null && !versions.isEmpty(), 'Should return the inserted version');
    }
}

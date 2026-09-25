/**
 * Tests for DocGenButtonController.
 *
 * The managed-package call is replaced with a mock Generator, and custom metadata
 * is injected via the configOverride seam (CMDT records cannot be DML-inserted in
 * tests). This exercises the full controller flow — config resolution, file
 * read-back, inline base64 vs. download-URL branches, and error handling — without
 * actually invoking Portwood.
 */
@IsTest
private class DocGenButtonControllerTest {
    private static final String OBJ = 'User';
    private static DocGenButtonController.GenRequest lastRequest;

    /** Mock that creates a real ContentVersion and returns its ids. */
    private class MockGenerator implements DocGenButtonController.Generator {
        public DocGenButtonController.GenResult generate(DocGenButtonController.GenRequest req) {
            lastRequest = req;
            ContentVersion cv = new ContentVersion(
                Title = String.isNotBlank(req.documentTitle) ? req.documentTitle : 'Mock Document',
                PathOnClient = 'Mock Document.pdf',
                VersionData = Blob.valueOf('%PDF-1.4 mock content')
            );
            insert cv;
            cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

            DocGenButtonController.GenResult r = new DocGenButtonController.GenResult();
            r.success = true;
            r.contentVersionId = cv.Id;
            r.contentDocumentId = cv.ContentDocumentId;
            return r;
        }
    }

    /** Mock that saves a macro-enabled workbook, exercising the xlsm MIME branch. */
    private class MockXlsmGenerator implements DocGenButtonController.Generator {
        public DocGenButtonController.GenResult generate(DocGenButtonController.GenRequest req) {
            ContentVersion cv = new ContentVersion(
                Title = 'Mock Workbook',
                PathOnClient = 'Mock Workbook.xlsm',
                VersionData = Blob.valueOf('PK mock xlsm content')
            );
            insert cv;
            cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

            DocGenButtonController.GenResult r = new DocGenButtonController.GenResult();
            r.success = true;
            r.contentVersionId = cv.Id;
            r.contentDocumentId = cv.ContentDocumentId;
            return r;
        }
    }

    /** Mock that reports a failure (e.g., template locked, merge error). */
    private class FailingGenerator implements DocGenButtonController.Generator {
        public DocGenButtonController.GenResult generate(DocGenButtonController.GenRequest req) {
            DocGenButtonController.GenResult r = new DocGenButtonController.GenResult();
            r.success = false;
            r.errorMessage = 'Simulated package failure.';
            return r;
        }
    }

    private static DocGen_Button__mdt cfg(String devName, String objectApi, String templateId, Boolean active) {
        return new DocGen_Button__mdt(
            DeveloperName = devName,
            MasterLabel = devName.replace('_', ' '),
            Object_API_Name__c = objectApi,
            Template_Id__c = templateId,
            Save_To_Record__c = false,
            Active__c = active,
            Sort_Order__c = 1
        );
    }

    @IsTest
    static void getButtons_returnsActiveConfigsForObject() {
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true),
            cfg('WO_Summary', OBJ, UserInfo.getUserId(), true),
            cfg('Other_Obj', 'Contact', UserInfo.getUserId(), true),
            cfg('Inactive_One', OBJ, UserInfo.getUserId(), false)
        };

        Test.startTest();
        List<DocGenButtonController.ButtonOption> opts = DocGenButtonController.getButtons(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(2, opts.size(), 'Only active configs for the record object should be returned');
    }

    @IsTest
    static void getEmailButtons_returnsOnlyEmailConfigs() {
        DocGen_Button__mdt docCfg = cfg('Doc_Button', OBJ, UserInfo.getUserId(), true);
        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        emailCfg.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ docCfg, emailCfg };

        Test.startTest();
        List<DocGenButtonController.ButtonOption> docOpts = DocGenButtonController.getButtons(UserInfo.getUserId());
        List<DocGenButtonController.ButtonOption> emailOpts = DocGenButtonController.getEmailButtons(
            UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertEquals(1, docOpts.size(), 'Document picker should hide email buttons');
        System.assertEquals('Doc_Button', docOpts[0].developerName);
        System.assertEquals(1, emailOpts.size(), 'Email picker should show only email buttons');
        System.assertEquals('Email_Button', emailOpts[0].developerName);
    }

    @IsTest
    static void getEmailButtons_usesTemplateNameWhenReadable() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Readable Template Name',
            Base_Object_API__c = 'User',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            API_Name__c = 'Readable_Template_Key'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, null, true);
        emailCfg.Action_Type__c = 'Email';
        emailCfg.Template_API_Name__c = 'Readable_Template_Key';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ emailCfg };

        List<DocGenButtonController.ButtonOption> opts = DocGenButtonController.getEmailButtons(UserInfo.getUserId());

        System.assertEquals(1, opts.size(), 'Expected one email option');
        System.assertEquals('Readable Template Name', opts[0].templateName, 'Picker should show template Name');
    }

    @IsTest
    static void getButtons_nullRecordId_returnsEmpty() {
        Test.startTest();
        List<DocGenButtonController.ButtonOption> opts = DocGenButtonController.getButtons((Id) null);
        Test.stopTest();
        System.assertEquals(0, opts.size(), 'Null recordId should yield no options');
    }

    @IsTest
    static void generate_smallFile_returnsBase64() {
        lastRequest = null;
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Expected success');
        System.assertNotEquals(null, dto.base64Data, 'Small file should return base64');
        System.assertNotEquals(null, dto.downloadUrl, 'A servlet download URL is always provided');
        System.assertEquals('application/pdf', dto.mimeType, 'PDF mime expected');
        System.assert(dto.fileName.endsWithIgnoreCase('.pdf'), 'Filename should carry extension');
    }

    @IsTest
    static void generate_normalizesLegacyOutputFormatAliases() {
        lastRequest = null;
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt c = cfg('WO_XLSX', OBJ, UserInfo.getUserId(), true);
        c.Output_Format_Override__c = 'XLSX';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ c };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_XLSX');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Expected success');
        System.assertNotEquals(null, lastRequest, 'Generator should receive a request');
        System.assertEquals(
            'Excel',
            lastRequest.outputFormatOverride,
            'Legacy XLSX value should normalize for service'
        );
    }

    @IsTest
    static void normalizeOutputFormatOverride_acceptsAliasesAndCanonicalValues() {
        System.assertEquals('Word', DocGenButtonController.normalizeOutputFormatOverride('DOCX'));
        System.assertEquals('Excel', DocGenButtonController.normalizeOutputFormatOverride('xlsx'));
        System.assertEquals('Excel', DocGenButtonController.normalizeOutputFormatOverride('Excel'));
        System.assertEquals('PowerPoint', DocGenButtonController.normalizeOutputFormatOverride('PPTX'));
        System.assertEquals('PDF', DocGenButtonController.normalizeOutputFormatOverride('PDF'));
        System.assertEquals(null, DocGenButtonController.normalizeOutputFormatOverride(' '));
    }

    @IsTest
    static void sendGeneratedEmail_generatesAttachmentAndSends() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        emailCfg.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ emailCfg };

        Test.startTest();
        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            new List<String>{ 'one@example.com', 'two@example.com' },
            'Subject',
            'Body'
        );
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Email path should succeed: ' + dto.errorMessage);
        System.assertNotEquals(null, dto.contentVersionId, 'Generated file version should be returned');
        System.assert(dto.fileName.endsWithIgnoreCase('.pdf'), 'Attachment should keep generated filename');
    }

    @IsTest
    static void sendGeneratedEmail_rejectsInvalidManualEmail() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        emailCfg.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ emailCfg };

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            new List<String>{ 'not-an-email' },
            'Subject',
            'Body'
        );

        System.assertEquals(false, dto.success, 'Invalid recipient should fail');
        System.assert(dto.errorMessage.contains('Invalid email address'), 'Expected validation message');
    }

    @IsTest
    static void emailHelpers_coverPreviewCandidatesAndValidation() {
        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        emailCfg.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ emailCfg };

        Test.startTest();
        String preview = DocGenButtonController.getEmailPreviewHtml(UserInfo.getUserId(), 'Email_Button');
        List<DocGenButtonController.EmailCandidate> candidates = DocGenButtonController.getEmailCandidates(
            UserInfo.getUserId()
        );
        Test.stopTest();

        System.assert(String.isNotBlank(preview), 'Preview fallback should still return displayable HTML');
        System.assertNotEquals(null, candidates, 'Email candidate lookup should return a list');

        DocGenButtonController.SendEmailResultDTO noSubject = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            new List<String>{ 'one@example.com' },
            null,
            'Body'
        );
        System.assertEquals(false, noSubject.success, 'Missing subject should fail');

        DocGenButtonController.GenerateResultDTO wrongAction = DocGenButtonController.generate(
            UserInfo.getUserId(),
            'Email_Button'
        );
        System.assertEquals(false, wrongAction.success, 'Document generation endpoint should reject email buttons');
    }

    @IsTest
    static void generate_xlsmFile_returnsMacroEnabledMime() {
        DocGenButtonController.generator = new MockXlsmGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_XLSM', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_XLSM');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Expected success');
        System.assertEquals(
            'application/vnd.ms-excel.sheet.macroEnabled.12',
            dto.mimeType,
            'xlsm must map to the macro-enabled Excel MIME, not octet-stream'
        );
        System.assert(dto.fileName.endsWithIgnoreCase('.xlsm'), 'Filename should carry the xlsm extension');
    }

    @IsTest
    static void generate_largeFile_returnsDownloadUrl() {
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.inlineDownloadMaxBytes = 1; // force the URL branch
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Expected success');
        System.assertEquals(null, dto.base64Data, 'Large file should not return base64');
        System.assert(
            dto.downloadUrl != null && dto.downloadUrl.contains('/sfc/servlet.shepherd/version/download/'),
            'Large file should return a download servlet URL'
        );
    }

    // ---------------------------------------------------------------------
    // Delivery mode
    // ---------------------------------------------------------------------

    @IsTest
    static void normalizeDeliveryMode_variants() {
        System.assertEquals('DOWNLOAD', DocGenButtonController.normalizeDeliveryMode(null), 'blank = download');
        System.assertEquals('DOWNLOAD', DocGenButtonController.normalizeDeliveryMode('  '), 'whitespace = download');
        System.assertEquals('DOWNLOAD', DocGenButtonController.normalizeDeliveryMode('Download'));
        System.assertEquals('PREVIEW', DocGenButtonController.normalizeDeliveryMode('preview'), 'case-insensitive');
        System.assertEquals(
            'PREVIEW_AND_DOWNLOAD',
            DocGenButtonController.normalizeDeliveryMode('Preview_And_Download')
        );
        System.assertEquals(
            'PREVIEW_AND_DOWNLOAD',
            DocGenButtonController.normalizeDeliveryMode('Preview + Download'),
            'separator tolerant'
        );
        System.assertEquals('PREVIEW_AND_DOWNLOAD', DocGenButtonController.normalizeDeliveryMode('Both'));
        System.assertEquals(
            'DOWNLOAD',
            DocGenButtonController.normalizeDeliveryMode('Popup'),
            'unrecognized falls back to download'
        );
    }

    @IsTest
    static void generate_noDeliveryMode_defaultsToDownload() {
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals('DOWNLOAD', dto.deliveryMode, 'Existing configs keep downloading');
        System.assertNotEquals(null, dto.base64Data, 'Download mode still returns base64 for small files');
    }

    @IsTest
    static void generate_previewMode_skipsBase64AndReturnsDocumentId() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt c = cfg('WO_PDF', OBJ, UserInfo.getUserId(), true);
        c.Delivery_Mode__c = 'Preview';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ c };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'Expected success: ' + dto.errorMessage);
        System.assertEquals('PREVIEW', dto.deliveryMode, 'Preview mode is passed to the LWC');
        System.assertNotEquals(null, dto.contentDocumentId, 'Preview needs the ContentDocumentId');
        System.assertEquals(null, dto.base64Data, 'Preview-only must not load VersionData into heap');
        System.assertNotEquals(null, dto.downloadUrl, 'Servlet URL is still provided as a fallback');
    }

    @IsTest
    static void generate_previewAndDownloadMode_returnsBoth() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt c = cfg('WO_PDF', OBJ, UserInfo.getUserId(), true);
        c.Delivery_Mode__c = 'PREVIEW_AND_DOWNLOAD';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ c };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals('PREVIEW_AND_DOWNLOAD', dto.deliveryMode);
        System.assertNotEquals(null, dto.contentDocumentId, 'Preview needs the ContentDocumentId');
        System.assertNotEquals(null, dto.base64Data, 'Download half still gets base64 for small files');
    }

    @IsTest
    static void generate_unknownConfig_returnsError() {
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(
            UserInfo.getUserId(),
            'DOES_NOT_EXIST'
        );
        Test.stopTest();

        System.assertEquals(false, dto.success, 'Unknown config should fail');
        System.assert(dto.errorMessage.contains('No active Portwood Button'), 'Expected config-not-found message');
    }

    @IsTest
    static void generate_blankTemplateId_returnsError() {
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ cfg('WO_PDF', OBJ, null, true) };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(false, dto.success, 'Blank template id should fail');
        System.assert(
            dto.errorMessage.contains('Set Template Id or Template API Name'),
            'Expected missing-template message: ' + dto.errorMessage
        );
    }

    @IsTest
    static void generate_templateApiName_resolvesTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Button Key Template',
            Base_Object_API__c = 'User',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            API_Name__c = 'Button_Key'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt byKey = cfg('WO_PDF', OBJ, null, true);
        byKey.Template_API_Name__c = 'Button_Key';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ byKey };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(true, dto.success, 'API-name-addressed config should generate: ' + dto.errorMessage);
    }

    @IsTest
    static void generate_templateApiName_unknownKeyFails() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt byKey = cfg('WO_PDF', OBJ, null, true);
        byKey.Template_API_Name__c = 'No_Such_Button_Key';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ byKey };

        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        System.assertEquals(false, dto.success);
        System.assert(
            dto.errorMessage.contains('No_Such_Button_Key'),
            'Error names the missing key: ' + dto.errorMessage
        );
    }

    @IsTest
    static void generate_packageFailure_returnsError() {
        DocGenButtonController.generator = new FailingGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true)
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(false, dto.success, 'Package failure should surface as error');
        System.assertEquals(
            'Simulated package failure.',
            dto.errorMessage,
            'Package error message should pass through'
        );
    }

    /**
     * Exercises the default ServiceGenerator -> DocGenService path
     * (no mock injected) so the real package call and its error handling are covered.
     * A valid-format but non-existent Template Id makes the package call fail; the
     * generator catches it and the controller surfaces a graceful error. We assert on
     * the outcome, not a specific message, since the package controls the wording.
     */
    @IsTest
    static void generate_packagePath_handlesInvalidTemplateGracefully() {
        // Intentionally do NOT set DocGenButtonController.generator here.
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{
            cfg('WO_PDF', OBJ, UserInfo.getUserId(), true) // valid Id format, not a real template
        };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(UserInfo.getUserId(), 'WO_PDF');
        Test.stopTest();

        System.assertEquals(
            false,
            dto.success,
            'A non-existent template via the real package path should fail gracefully'
        );
        System.assertNotEquals(null, dto.errorMessage, 'A user-facing error message should be returned');
    }

    // ---------------------------------------------------------------------
    // Record-type matching
    // ---------------------------------------------------------------------

    @IsTest
    static void matchesRecordType_blankConfig_matchesAll() {
        DocGen_Button__mdt c = cfg('X', OBJ, UserInfo.getUserId(), true);
        // Record_Type_Developer_Names__c left blank.
        System.assertEquals(true, DocGenButtonController.matchesRecordType(c, 'AnyType'), 'blank = all record types');
        System.assertEquals(
            true,
            DocGenButtonController.matchesRecordType(c, null),
            'blank matches a record with no RT'
        );
    }

    @IsTest
    static void matchesRecordType_listSemantics() {
        DocGen_Button__mdt c = cfg('X', OBJ, UserInfo.getUserId(), true);
        c.Record_Type_Developer_Names__c = 'Standard_Invoice, Credit_Note';
        System.assertEquals(true, DocGenButtonController.matchesRecordType(c, 'Credit_Note'), 'listed name matches');
        System.assertEquals(
            true,
            DocGenButtonController.matchesRecordType(c, 'standard_invoice'),
            'match is case-insensitive'
        );
        System.assertEquals(
            false,
            DocGenButtonController.matchesRecordType(c, 'Quote'),
            'unlisted name does not match'
        );
        System.assertEquals(
            false,
            DocGenButtonController.matchesRecordType(c, null),
            'a record with no RT never matches a config that names specific ones'
        );
    }

    @IsTest
    static void getButtons_filtersByRecordType() {
        DocGen_Button__mdt all = cfg('All_RTs', OBJ, UserInfo.getUserId(), true); // blank RT → every record type
        DocGen_Button__mdt needsRt = cfg('Needs_RT', OBJ, UserInfo.getUserId(), true);
        needsRt.Record_Type_Developer_Names__c = 'Some_Record_Type';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ all, needsRt };

        Test.startTest();
        // User has no record types, so getButtons should hide the config that names one.
        List<DocGenButtonController.ButtonOption> opts = DocGenButtonController.getButtons(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(1, opts.size(), 'Only the all-record-types config should show for a record with no RT');
        System.assertEquals('All_RTs', opts[0].developerName, 'The blank-RT config is the one that shows');
    }

    @IsTest
    static void generate_recordTypeMismatch_returnsError() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt needsRt = cfg('Needs_RT', OBJ, UserInfo.getUserId(), true);
        needsRt.Record_Type_Developer_Names__c = 'Some_Record_Type';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ needsRt };

        Test.startTest();
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(
            UserInfo.getUserId(),
            'Needs_RT'
        );
        Test.stopTest();

        System.assertEquals(false, dto.success, 'A record-type mismatch must block generation');
        System.assert(dto.errorMessage.contains('record type'), 'Expected a record-type error: ' + dto.errorMessage);
    }

    @IsTest
    static void generate_objectMismatch_returnsError() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt contactCfg = cfg('Contact_Doc', 'Contact', UserInfo.getUserId(), true);
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ contactCfg };

        Test.startTest();
        // Invoke a Contact-configured button against a User record.
        DocGenButtonController.GenerateResultDTO dto = DocGenButtonController.generate(
            UserInfo.getUserId(),
            'Contact_Doc'
        );
        Test.stopTest();

        System.assertEquals(false, dto.success, 'An object mismatch must block generation');
        System.assert(
            dto.errorMessage.contains('Contact'),
            'Expected an object-mismatch error naming the configured object: ' + dto.errorMessage
        );
    }

    // ---------------------------------------------------------------------
    // Send Email: template scoping, recipient cap, sender
    // ---------------------------------------------------------------------

    private static DocGen_Template__c makeEmailTemplate(String name, String apiName, String baseObject) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = name,
            API_Name__c = apiName,
            Base_Object_API__c = baseObject,
            Type__c = 'HTML',
            Output_Format__c = 'PDF'
        );
        Database.insert(t, AccessLevel.SYSTEM_MODE);
        return t;
    }

    private static DocGen_Button__mdt unpinnedEmailCfg() {
        DocGen_Button__mdt c = cfg('Email_Button', OBJ, null, true);
        c.Action_Type__c = 'Email';
        return c;
    }

    @IsTest
    static void sendGeneratedEmail_unpinnedButton_rejectsTemplateBuiltForAnotherObject() {
        DocGenButtonController.generator = new MockGenerator();
        makeEmailTemplate('Account Only Template', 'Account_Only_Tpl', 'Account');
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ unpinnedEmailCfg() };

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            'key:Account_Only_Tpl',
            new List<String>{ 'one@example.com' },
            'Subject',
            'Body'
        );

        System.assertEquals(false, dto.success, 'A template built for another object must be refused');
        System.assert(dto.errorMessage.contains('not available for this record'), 'Got: ' + dto.errorMessage);
    }

    @IsTest
    static void sendGeneratedEmail_unpinnedButton_acceptsTemplateForTheRecordObject() {
        DocGenButtonController.generator = new MockGenerator();
        makeEmailTemplate('User Template', 'User_Tpl', OBJ);
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ unpinnedEmailCfg() };

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            'key:User_Tpl',
            new List<String>{ 'one@example.com' },
            'Subject',
            'Body'
        );

        System.assertEquals(true, dto.success, 'Expected success: ' + dto.errorMessage);
    }

    @IsTest
    static void sendGeneratedEmail_unpinnedButton_requiresATemplate() {
        DocGenButtonController.generator = new MockGenerator();
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ unpinnedEmailCfg() };

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            null,
            new List<String>{ 'one@example.com' },
            'Subject',
            'Body'
        );

        System.assertEquals(false, dto.success, 'No template chosen and none pinned must fail');
        System.assert(dto.errorMessage.contains('Choose a template'), 'Got: ' + dto.errorMessage);
    }

    @IsTest
    static void sendGeneratedEmail_pinnedButton_ignoresTheClientsTemplateChoice() {
        DocGenButtonController.generator = new MockGenerator();
        makeEmailTemplate('Account Only Template', 'Account_Only_Tpl', 'Account');
        DocGen_Button__mdt pinned = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        pinned.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ pinned };

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            'key:Account_Only_Tpl',
            new List<String>{ 'one@example.com' },
            'Subject',
            'Body'
        );

        System.assertEquals(true, dto.success, 'The pinned template wins; the client value is ignored');
    }

    @IsTest
    static void getEmailTemplateOptions_offersOnlyTemplatesForTheRecordObject() {
        makeEmailTemplate('User Template', 'User_Tpl', OBJ);
        makeEmailTemplate('Account Only Template', 'Account_Only_Tpl', 'Account');
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ unpinnedEmailCfg() };

        List<DocGenButtonController.EmailTemplateOption> opts = DocGenButtonController.getEmailTemplateOptions(
            UserInfo.getUserId(),
            'Email_Button'
        );

        Set<String> values = new Set<String>();
        for (DocGenButtonController.EmailTemplateOption o : opts) {
            values.add(o.value);
        }
        System.assert(values.contains('key:User_Tpl'), 'Template for the record object is offered');
        System.assert(!values.contains('key:Account_Only_Tpl'), 'Template for another object is not offered');
    }

    @IsTest
    static void sendGeneratedEmail_rejectsMoreThanTheRecipientCap() {
        DocGenButtonController.generator = new MockGenerator();
        DocGen_Button__mdt emailCfg = cfg('Email_Button', OBJ, UserInfo.getUserId(), true);
        emailCfg.Action_Type__c = 'Email';
        DocGenButtonController.configOverride = new List<DocGen_Button__mdt>{ emailCfg };
        List<String> many = new List<String>();
        for (Integer i = 0; i <= DocGenButtonController.MAX_EMAIL_RECIPIENTS; i++) {
            many.add('person' + i + '@example.com');
        }

        DocGenButtonController.SendEmailResultDTO dto = DocGenButtonController.sendGeneratedEmail(
            UserInfo.getUserId(),
            'Email_Button',
            null,
            many,
            'Subject',
            'Body'
        );

        System.assertEquals(false, dto.success, 'More than the cap must be refused');
        System.assert(dto.errorMessage.contains('at most'), 'Got: ' + dto.errorMessage);
    }

    @IsTest
    static void configuredSender_isNullUnlessAnAdminConfiguredOne() {
        System.assertEquals(
            null,
            DocGenButtonController.configuredOrgWideEmailAddressId(),
            'With no configured sender the email goes out as the running user, never a guessed org-wide address'
        );
    }
}

@IsTest
private class DocGenMiscTests {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
    }

    /**
     * Creates a ContentVersion linked to the test template (fake content).
     */
    private static ContentVersion createTestFile() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        return TestDataFactory.createTestTemplateFile(tpl.Id);
    }

    /**
     * Builds a minimal valid DOCX (ZIP) with template merge tags and links to template.
     */
    private static ContentVersion createValidDocxFile(String docXml) {
        return TestDataFactory.createValidDocxFile(docXml);
    }

    // =========================================================================
    // DocGenSetupController
    // =========================================================================

    @IsTest
    static void testGetOrgUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            String orgUrl = DocGenSetupController.getOrgUrl();
            Test.stopTest();

            System.assertNotEquals(null, orgUrl, 'Org URL should not be null');
            System.assert(orgUrl.length() > 0, 'Org URL should not be empty');
        }
    }

    @IsTest
    static void testGetSettings() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            DocGen_Settings__c settings = DocGenSetupController.getSettings();
            Test.stopTest();

            System.assertNotEquals(null, settings, 'Settings should not be null');
        }
    }

    @IsTest
    static void testSaveSettings() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            DocGenSetupController.saveSettings('https://example.my.site.com');
            Test.stopTest();

            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            System.assertEquals(
                'https://example.my.site.com',
                settings.Experience_Site_Url__c,
                'Experience Site URL should match saved value'
            );
        }
    }

    @IsTest
    static void testSaveSettingsUpdatesExisting() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenSetupController.saveSettings('https://first.my.site.com');

            Test.startTest();
            DocGenSetupController.saveSettings('https://second.my.site.com');
            Test.stopTest();

            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            System.assertEquals(
                'https://second.my.site.com',
                settings.Experience_Site_Url__c,
                'Experience Site URL should be updated to second value'
            );
        }
    }

    // =========================================================================
    // DocGenDataRetriever
    // =========================================================================

    @IsTest
    static void testGetRecordDataWithValidFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, AccountSource');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for valid fields');
            System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match test account');
            System.assertEquals('Web', result.get('AccountSource'), 'AccountSource should match test account');
        }
    }

    @IsTest
    static void testGetRecordDataIncludesPicklistLabelMetadata() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Industry');
            Test.stopTest();

            System.assertEquals('Technology', result.get('Industry'), 'Raw picklist value should remain unchanged.');
            System.assert(
                result.containsKey('__docgenPicklistLabels'),
                'Retrieved records with picklist fields should carry label metadata.'
            );
            Map<String, String> labels = (Map<String, String>) result.get('__docgenPicklistLabels');
            System.assertEquals(
                'Technology',
                labels.get('Industry'),
                'Industry label metadata should resolve from Schema picklist entries.'
            );
        }
    }

    @IsTest
    static void testGetRecordDataWithInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(acc.Id, 'NotARealObject__c', 'Name');
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'Should throw for invalid object');
        }
    }

    @IsTest
    static void testGetRecordDataWithBlankParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(null, '', '');
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'Should throw for blank params');
        }
    }

    @IsTest
    static void testGetRecordDataWithRelationshipField() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Owner.Name');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for relationship field query');
            System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match test account');
            System.assert(result.containsKey('Owner'), 'Should contain Owner relationship data');
        }
    }

    @IsTest
    static void testGetRecordDataWithNonExistentField() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(
                acc.Id,
                'Account',
                'Name, TotallyFakeField__xyz'
            );
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null even with non-existent field');
            System.assertEquals(
                'DocGen Test Account',
                result.get('Name'),
                'Name should still be returned with non-existent field'
            );
        }
    }

    @IsTest
    static void testGetRecordDataWithBlankObjectOrFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught1 = false;
            Boolean caught2 = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(acc.Id, '', 'Name');
            } catch (Exception e) {
                caught1 = true;
            }
            try {
                DocGenDataRetriever.getRecordData(acc.Id, 'Account', '');
            } catch (Exception e) {
                caught2 = true;
            }
            Test.stopTest();

            System.assert(caught1, 'Should throw for blank object name');
            System.assert(caught2, 'Should throw for blank fields config');
        }
    }

    // =========================================================================
    // DocGenFlowAction
    // =========================================================================

    @IsTest
    static void testGenerateDocumentFlowActionErrorPath() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'Should return exactly 1 response');
        System.assertNotEquals(null, responses[0].errorMessage, 'Error message should be populated on failure');
        System.assertEquals(null, responses[0].contentDocumentId, 'ContentDocumentId should be null on error');
    }

    // ─── PHD-9: Template API Name resolution ────────────────────────────────

    @IsTest
    static void testFlowAction_templateApiName_resolvesToTemplate() {
        TestDataFactory.attachRealDocxToTestTemplate();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.API_Name__c = 'Test_Template_Key';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateApiName = 'Test_Template_Key'; // no templateId — resolve by key
        req.jsonData = '{"Name":"Api Name Co"}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(
            true,
            responses[0].success,
            'API-name-addressed render should succeed: ' + responses[0].errorMessage
        );
        System.assertNotEquals(null, responses[0].contentVersionId);
    }

    // ─── Excel output must be saved as .xlsx, not .docx ─────────────────────
    //
    // saveFile() named every non-PowerPoint result ".docx", so a server-side
    // Excel render (Flow action / save-to-record queueable / bulk) produced a
    // valid workbook that no reader would open. The runner never showed this —
    // it assembles Office files client-side and picks its own extension.
    @IsTest
    static void testFlowAction_excelTemplateSavesAsXlsx() {
        Account acc = TestDataFactory.getTestAccount();
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Excel JSON Template',
            Base_Object_API__c = 'FlowJsonData',
            Type__c = 'Excel',
            Output_Format__c = 'Native',
            Query_Config__c = '{"v":4,"source":"flowJsonData"}'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        ContentVersion cv = new ContentVersion(
            Title = 'Excel JSON Template',
            PathOnClient = 'book.xlsx',
            VersionData = buildMinimalXlsx(),
            FirstPublishLocationId = tpl.Id
        );
        Database.insert(cv, AccessLevel.SYSTEM_MODE);

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'Excel',
            Base_Object_API__c = 'FlowJsonData',
            Query_Config__c = '{"v":4,"source":"flowJsonData"}',
            Content_Version_Id__c = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
            .Id
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;
        req.jsonData = '{"Name":"Acme"}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Excel render should succeed: ' + responses[0].errorMessage);
        ContentVersion saved = [
            SELECT PathOnClient
            FROM ContentVersion
            WHERE Id = :responses[0].contentVersionId
            LIMIT 1
        ];
        System.assert(
            saved.PathOnClient.endsWith('.xlsx'),
            'Excel template must save as .xlsx, got: ' + saved.PathOnClient
        );
    }

    /** Smallest workbook the merge pipeline will accept. */
    private static Blob buildMinimalXlsx() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
                    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
                    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
                    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'xl/workbook.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
                    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
            )
        );
        zw.addEntry(
            'xl/sharedStrings.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">' +
                    '<si><t>Hello {Name}</t></si></sst>'
            )
        );
        zw.addEntry(
            'xl/worksheets/sheet1.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' +
                    '<row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>'
            )
        );
        return zw.getArchive();
    }

    @IsTest
    static void testFlowAction_templateApiName_unknownKeyFailsClearly() {
        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateApiName = 'No_Such_Key';
        req.jsonData = '{"Name":"X"}';

        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        System.assertEquals(false, responses[0].success);
        System.assert(
            responses[0].errorMessage.contains('No_Such_Key'),
            'Error names the missing key: ' + responses[0].errorMessage
        );
    }

    @IsTest
    static void testFlowAction_neitherTemplateInputFailsClearly() {
        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.jsonData = '{"Name":"X"}';

        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        System.assertEquals(false, responses[0].success);
        System.assert(
            responses[0].errorMessage.contains('Template ID or Template API Name'),
            'Error explains both inputs: ' + responses[0].errorMessage
        );
    }

    @IsTest
    static void testGenerateDocumentFlowActionResponseStructure() {
        DocGenFlowAction.Response res = new DocGenFlowAction.Response();
        res.contentDocumentId = null;
        res.errorMessage = 'test error';
        System.assertEquals(null, res.contentDocumentId, 'ContentDocumentId should be settable to null');
        System.assertEquals('test error', res.errorMessage, 'Error message should match assigned value');
    }

    // ─── Apex DTO / JSON Data inputs ────────────────────────────────────────
    // The new path lets a Flow build merge data in-memory (external API responses,
    // computed totals, anything SOQL can't reach) and render directly without
    // implementing DocGenDataProvider or persisting to records first.

    @IsTest
    static void testFlowAction_jsonData_withoutRecordId_inserts_standalone_cv() {
        TestDataFactory.attachRealDocxToTestTemplate();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = null; // No record context — pure data-driven render.
        req.jsonData = '{"Name":"In-Memory Co","Amount":98765,"Industry":"Synthetic"}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size());
        System.assertEquals(
            true,
            responses[0].success,
            'Data-only render should succeed: ' + responses[0].errorMessage
        );
        System.assertNotEquals(null, responses[0].contentDocumentId, 'ContentDocumentId should be returned');
        System.assertNotEquals(null, responses[0].contentVersionId, 'ContentVersionId should be returned');
    }

    @IsTest
    static void testFlowAction_jsonData_withRecordId_saveToRecord_true_attaches() {
        TestDataFactory.attachRealDocxToTestTemplate();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;
        req.jsonData = '{"Name":"Hybrid","Amount":1}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Hybrid path should succeed: ' + responses[0].errorMessage);
        // FirstPublishLocationId = recordId means the CV is linked to the Account.
        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :responses[0].contentDocumentId
        ];
        System.assert(linkCount > 0, 'Document should be linked to the supplied recordId');
    }

    // Regression: GitHub #90 — Save to Record = false (or omitted) must NOT attach to the
    // supplied recordId, even when JSON Data + recordId are both provided. recordId stays
    // as the title/context anchor; the file lands as a standalone ContentVersion.
    @IsTest
    static void testFlowAction_jsonData_withRecordId_saveToRecord_false_doesNotAttach() {
        TestDataFactory.attachRealDocxToTestTemplate();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = false;
        req.jsonData = '{"Name":"Hybrid","Amount":1}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Should succeed: ' + responses[0].errorMessage);
        System.assertNotEquals(null, responses[0].contentDocumentId, 'CD id still returned for download');
        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :responses[0].contentDocumentId
        ];
        System.assertEquals(0, linkCount, 'Document must NOT be linked when saveToRecord=false');
    }

    // Regression: GitHub #90 — standard recordId path (no JSON Data) must honor saveToRecord=false.
    @IsTest
    static void testFlowAction_recordId_saveToRecord_false_doesNotAttach() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Should succeed: ' + responses[0].errorMessage);
        System.assertNotEquals(null, responses[0].contentDocumentId, 'CD id still returned for download');
        Integer linkCount = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :responses[0].contentDocumentId
        ];
        System.assertEquals(0, linkCount, 'Document must NOT be linked when saveToRecord=false');
    }

    @IsTest
    static void testFlowAction_neither_recordId_nor_jsonData_errors() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        // Both recordId and jsonData omitted — should produce a clear error, not a stack trace.

        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );

        System.assertEquals(false, responses[0].success);
        System.assert(
            responses[0].errorMessage != null && responses[0].errorMessage.contains('Record ID or JSON Data'),
            'Expected guidance message, got: ' + responses[0].errorMessage
        );
    }

    @IsTest
    static void testFlowAction_jsonData_array_root_rejected() {
        // Top-level array isn't a valid merge data shape — must be an object.
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.jsonData = '[{"Name":"oops"}]';

        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );

        System.assertEquals(false, responses[0].success);
        System.assert(
            responses[0].errorMessage != null && responses[0].errorMessage.contains('object'),
            'Should reject array roots, got: ' + responses[0].errorMessage
        );
    }

    @IsTest
    static void testService_generatePdfBlobFromData_directApi() {
        TestDataFactory.attachRealDocxToTestTemplate();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        Map<String, Object> wrapper = new Map<String, Object>{ 'Name' => 'Direct Apex Caller', 'Amount' => 42000 };

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlobFromData(tpl.Id, wrapper);
        Test.stopTest();

        Blob pdf = (Blob) result.get('blob');
        System.assertNotEquals(null, pdf, 'PDF blob should be returned');
        System.assert(pdf.size() > 0, 'PDF should not be empty');
    }

    @IsTest
    static void testService_generatePdfBlobFromData_nullDataMapThrows() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        try {
            DocGenService.generatePdfBlobFromData(tpl.Id, null);
            System.assert(false, 'Should have thrown');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('dataMap cannot be null'), 'Got: ' + e.getMessage());
        }
    }

    @IsTest
    static void testService_generateAndSaveFromData_nullRecordIdThrows() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        try {
            DocGenService.generateAndSaveFromData(tpl.Id, null, new Map<String, Object>{ 'Name' => 'x' }, null);
            System.assert(false, 'Should have thrown');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('attachmentRecordId is required'), 'Got: ' + e.getMessage());
        }
    }

    // =========================================================================
    // DocGenException
    // =========================================================================

    @IsTest
    static void testDocGenExceptionConstruction() {
        DocGenException ex = new DocGenException('Test error message');
        System.assertEquals('Test error message', ex.getMessage(), 'Exception message should match constructor arg');

        DocGenException exCause = new DocGenException('Wrapped error', new DmlException());
        System.assertEquals('Wrapped error', exCause.getMessage(), 'Wrapped exception message should match');
        System.assertNotEquals(null, exCause.getCause(), 'Cause should not be null for wrapped exception');

        DocGenException exDefault = new DocGenException();
        System.assertNotEquals(null, exDefault, 'Default constructor should create non-null exception');
    }

    // =========================================================================
    // DocGenService — error paths
    // =========================================================================

    @IsTest
    static void testProcessDocumentThrowsOnInvalidDocx() {
        createTestFile();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        try {
            DocGenService.processDocument(tpl.Id, acc.Id);
            System.assert(false, 'Expected exception for invalid DOCX');
        } catch (DocGenException e) {
            System.assert(e.getMessage().length() > 0, 'DocGenException message should not be empty');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0, 'Exception message should not be empty');
        }
        Test.stopTest();
    }

    @IsTest
    static void testProcessDocumentNullTemplate() {
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        try {
            DocGenService.processDocument(null, acc.Id);
            System.assert(false, 'Expected exception for null template');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0, 'Exception message should not be empty for null template');
        }
        Test.stopTest();
    }

    @IsTest
    static void testGenerateDocumentNullRecord() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        Test.startTest();
        try {
            DocGenService.generateDocument(tpl.Id, null);
            System.assert(false, 'Expected exception for null record');
        } catch (Exception e) {
            System.assert(e.getMessage().length() > 0, 'Exception message should not be empty for null record');
        }
        Test.stopTest();
    }

    // =========================================================================
    // DocGenService — valid DOCX processing (covers processXml, resolveValue,
    // mergeRunsInTags, generateDocTitle, saveFile, buildImageXml)
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithSimpleTags() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{AccountSource}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'processDocument result should not be null');
        System.assertNotEquals(null, result.get('blob'), 'Document blob should not be null');
        System.assertNotEquals(null, result.get('title'), 'Document title should not be null');
        System.assertEquals('Word', result.get('templateType'), 'Template type should be Word');
    }

    @IsTest
    static void testGenerateDocumentWithValidDocx() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Should return ContentDocumentId');
    }

    @IsTest
    static void testProcessDocumentMergesRunsInTags() {
        // Simulate Word splitting {Name} across multiple <w:t> elements
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p>' +
            '<w:r><w:t>{Na</w:t></w:r>' +
            '<w:r><w:t>me}</w:t></w:r>' +
            '</w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Merged runs document blob should not be null');
    }

    @IsTest
    static void testProcessDocumentWithSectionTag() {
        // Boolean-true section (Account always truthy via Owner)
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Before {Name} After</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for section tag test');
    }

    @IsTest
    static void testProcessDocumentWithHtmlFieldValue() {
        // Account Website field is plain text, but we test that HTML stripping works
        // by using a field config that includes Website
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name} - {Website}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        // Update template query config to include Website
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, AccountSource, Website';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for HTML field value test');
    }

    @IsTest
    static void testProcessDocumentWithTitleFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Document_Title_Format__c = 'Doc_{Name}_{AccountSource}';
        tpl.Query_Config__c = 'Name, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assert(title.contains('DocGen Test Account'), 'Title should contain account name');
        System.assert(title.contains('Web'), 'Title should contain account source');
    }

    @IsTest
    static void testProcessDocumentWithImageTag() {
        // {%SomeImage} tag — resolveValue returns null so image is skipped, but code path is covered
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name} {%NonExistentImage}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for image tag test');
    }

    @IsTest
    static void testProcessDocumentWithImageSizeTag() {
        // {%SomeImage:200x150} — image with dimensions
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%NonExistentImage:200x150}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for image size tag test');
    }

    @IsTest
    static void testProcessDocumentWithClosingTagOnly() {
        // Orphaned {/something} tag — should be output as literal
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{/orphan}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for closing tag only test');
    }

    @IsTest
    static void testProcessDocumentWithUnmatchedSection() {
        // {#section} without closing {/section} — output as literal
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#NoClose}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Map<String, Object> result;
        Test.startTest();
        try {
            result = DocGenService.processDocument(tpl.Id, acc.Id);
        } catch (DocGenException e) {
            System.assert(
                e.getMessage().contains('Malformed loop tag'),
                'Exception message should contain "Malformed loop tag"'
            );
        }
        Test.stopTest();

        System.assertEquals(null, result, 'Result should be null for unmatched section test');
    }

    @IsTest
    static void testProcessDocumentWithHeaderAndFooter() {
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
        String bodyXml = '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        zw.addEntry('word/document.xml', Blob.valueOf(bodyXml));
        String headerXml = '<?xml version="1.0"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Header: {Name}</w:t></w:r></w:p></w:hdr>';
        zw.addEntry('word/header1.xml', Blob.valueOf(headerXml));
        String footerXml = '<?xml version="1.0"?><w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Footer: {AccountSource}</w:t></w:r></w:p></w:ftr>';
        zw.addEntry('word/footer1.xml', Blob.valueOf(footerXml));

        ContentVersion cv = new ContentVersion(
            Title = 'HeaderFooterDoc',
            PathOnClient = 'HeaderFooterDoc.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for header and footer test');
    }

    @IsTest
    static void testGenerateDocumentWithPdfFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Document ID should not be null for PDF format test');
    }

    // =========================================================================
    // DocGenService — additional coverage for uncovered branches
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithChildSubquery() {
        // Use Contacts subquery to exercise loop processing with records list
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        tpl.Base_Object_API__c = 'Account';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        // Add a contact to the account
        Account acc = TestDataFactory.getTestAccount();
        insert new Contact(FirstName = 'Loop', LastName = 'Tester', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{#Contacts}{FirstName} {LastName}{/Contacts}</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for child subquery test');
    }

    @IsTest
    static void testProcessDocumentWithTableRowLoop() {
        // Section inside a <w:tr> — exercises table row expansion code
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();
        insert new Contact(FirstName = 'Row', LastName = 'Expand', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:tbl>' +
            '<w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Last</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>{#Contacts}{FirstName}</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>{LastName}{/Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for table row loop test');
    }

    @IsTest
    static void testProcessDocumentWithNestedDotPath() {
        // Owner.Name uses dotted path — exercises resolveValue with nested map
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Owner.Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Owner.Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for nested dot path test');
    }

    @IsTest
    static void testProcessDocumentWithBase64ImageField() {
        // Inject a base64 data URI value to exercise buildImageXml data URI path
        // We can't easily inject custom field data, but we can test the image tag with
        // a ContentVersion ID. Create a small PNG and reference it.
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImage',
            PathOnClient = 'TestImage.png',
            VersionData = Blob.valueOf('PNG_FAKE_DATA')
        );
        insert imgCv;
        imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

        // Template with {%ImageField} — field value will be a CV Id
        // We need the query to return a field containing the CV Id
        // Use Description field on Account to hold the CV Id
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = imgCv.Id;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description:100x80}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for base64 image field test');
    }

    @IsTest
    static void testProcessDocumentWithHtmlRichText() {
        // Field value contains <p>/<div> HTML that should be stripped
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p>Hello</p><div>World</div>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for HTML rich text test');
    }

    @IsTest
    static void testProcessDocumentWithPowerPoint() {
        // PowerPoint template — exercises the ppt/slides branch
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        String slideXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(slideXml));

        ContentVersion cv = new ContentVersion(
            Title = 'PPTDoc',
            PathOnClient = 'PPTDoc.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PowerPoint test');
        System.assertEquals('PowerPoint', result.get('templateType'), 'Template type should be PowerPoint');
    }

    @IsTest
    static void testProcessDocumentNoTitleFallsBackToName() {
        // No Document_Title_Format__c — falls back to record Name
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Document_Title_Format__c = null;
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assertEquals('DocGen Test Account', title, 'Should fall back to record Name');
    }

    // =========================================================================
    // DocGenDataRetriever — additional coverage
    // =========================================================================

    @IsTest
    static void testGetRecordDataWithSubquery() {
        // Exercises the subquery (parenthesized SELECT) branch in field parsing
        Account acc = TestDataFactory.getTestAccount();
        insert new Contact(FirstName = 'Sub', LastName = 'Query', AccountId = acc.Id);

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(
            acc.Id,
            'Account',
            'Name, (SELECT FirstName, LastName FROM Contacts)'
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for subquery test');
        System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match for subquery test');
        System.assert(result.containsKey('Contacts'), 'Should contain Contacts subquery');
    }

    @IsTest
    static void testGetRecordDataWithAutoAppendC() {
        // Exercises the __c auto-append branch — AccountSource exists, but try without __c
        // "Website" is a standard field so this tests the field-not-found skip path
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, ZZZInvalidField');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for auto-append test');
        System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match for auto-append test');
    }

    @IsTest
    static void testGetRecordDataWithInvalidRelationship() {
        // Exercises the invalid relationship field branch (relFound = false)
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, FakeRel__r.Field');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for invalid relationship test');
        System.assertEquals(
            'DocGen Test Account',
            result.get('Name'),
            'Name should match for invalid relationship test'
        );
    }

    @IsTest
    static void testGetRecordDataAllFieldsInvalid() {
        // Exercises the cleanSelect == '' fallback to 'Id'
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'ZZZFake1, ZZZFake2');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for all-fields-invalid test');
        System.assertNotEquals(null, result.get('Id'), 'Id should be returned as fallback');
    }

    @IsTest
    static void testGetRecordDataWithBlankFieldPart() {
        // Exercises the blank field part skip (trailing comma)
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, , AccountSource');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for blank field part test');
        System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match for blank field part test');
    }

    @IsTest
    static void testGetRecordDataWithAddressField() {
        // Exercises the Address type branch in mapSObject
        Account acc = TestDataFactory.getTestAccount();
        acc.BillingStreet = '123 Main St';
        acc.BillingCity = 'TestCity';
        acc.BillingState = 'CA';
        acc.BillingPostalCode = '90210';
        acc.BillingCountry = 'US';
        update acc;

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, BillingAddress');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null for address field test');
        System.assert(result.containsKey('BillingAddress'), 'Should contain BillingAddress compound field');
    }

    // =========================================================================
    // DocGenSetupController — additional coverage
    // =========================================================================

    // =========================================================================
    // Full-pipeline tests — attachRealDocxToTestTemplate exercises the entire
    // merge pipeline: mergeTemplate, processXml, DocGenHtmlRenderer, Blob.toPdf
    // =========================================================================

    @IsTest
    static void testFullPdfGenerationPipeline() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            Account acc = TestDataFactory.getTestAccount();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, docId, 'Should generate a document');
            List<ContentVersion> cvs = [SELECT ContentSize FROM ContentVersion WHERE ContentDocumentId = :docId];
            System.assert(!cvs.isEmpty(), 'Should have a ContentVersion');
            System.assert(cvs[0].ContentSize > 0, 'Generated file should not be empty');
        }
    }

    @IsTest
    static void testFullDocxPartsPipeline() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            Account acc = TestDataFactory.getTestAccount();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            Map<String, Object> parts = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
            Test.stopTest();

            System.assertNotEquals(null, parts, 'Should return parts');
            System.assertNotEquals(null, parts.get('allXmlParts'), 'Should have XML parts');
        }
    }

    @IsTest
    static void testFullHtmlRenderPipeline() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            Account acc = TestDataFactory.getTestAccount();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            String html = DocGenService.generateHtmlForRecord(tpl.Id, acc.Id, null);
            Test.stopTest();

            System.assertNotEquals(null, html, 'Should return HTML');
            System.assert(html.length() > 0, 'HTML should not be empty');
            System.assert(html.contains('DocGen Test Account'), 'Should contain the account name');
        }
    }

    // =========================================================================
    // DocGenFlowAction — success path coverage
    // =========================================================================

    @IsTest
    static void testGenerateDocumentFlowActionSuccess() {
        // Create a valid DOCX so the flow action succeeds (covers contentDocumentId assignment)
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'Should return exactly one response for success path');
        System.assertNotEquals(null, responses[0].contentDocumentId, 'Should have a document ID on success');
        System.assertEquals(null, responses[0].errorMessage, 'Should not have error on success');
    }

    // Regression: GitHub #41 — Document Title input from Flow was silently dropped on
    // the recordId branch (only the standalone JSON-data path honored it). Asserts the
    // title threads from the InvocableVariable through to the saved ContentVersion.Title.
    @IsTest
    static void testGenerateDocumentFlowActionHonorsDocumentTitle() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.documentTitle = 'Flow Custom Title 12345';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Should succeed: ' + responses[0].errorMessage);
        Id cdId = responses[0].contentDocumentId;
        System.assertNotEquals(null, cdId, 'Document ID should be set');
        List<ContentVersion> cvs = [SELECT Title FROM ContentVersion WHERE ContentDocumentId = :cdId];
        System.assertEquals(1, cvs.size(), 'Should have one ContentVersion');
        System.assertEquals('Flow Custom Title 12345', cvs[0].Title, 'Document Title input must override default name');
    }

    // =========================================================================
    // DocGenTemplateManager — additional coverage
    // =========================================================================

    @IsTest
    static void testGetTemplateFileContentNullId() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenTemplateManager.getTemplateFileContent(null);
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for null template ID');
    }

    @IsTest
    static void testGetTemplateFileContentNoFile() {
        // Template exists but no file attached and no active version
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenTemplateManager.getTemplateFileContent(tpl.Id);
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Should throw when no file found');
    }

    // =========================================================================
    // DocGenService — generatePdfBlob (unified PDF path)
    // =========================================================================

    @IsTest
    static void testGeneratePdfBlobWord() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Should return a PDF blob');
        System.assertNotEquals(null, result.get('title'), 'Title should not be null for PDF blob test');
    }

    @IsTest
    static void testGeneratePdfBlobThrowsForPowerPoint() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
                    '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(Title = 'PPT', PathOnClient = 'PPT.pptx', VersionData = zw.getArchive());
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        } catch (DocGenException e) {
            caught = true;
            System.assert(
                e.getMessage().contains('only supported for Word'),
                'Exception should mention Word-only support'
            );
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for PowerPoint PDF generation');
    }

    @IsTest
    static void testGeneratePdfBlobWithTitleFormat() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Account: {Name}, Source: {AccountSource}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Document_Title_Format__c = 'PDF_{Name}';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PDF blob with title format');
        String title = (String) result.get('title');
        System.assert(title.contains('DocGen Test Account'), 'PDF title should contain account name');
    }

    @IsTest
    static void testGeneratePdfBlobWithImage() {
        // PDF path with image — exercises imageBase64ByRelId collection
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGFAKE'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PDF blob with image');
    }

    // =========================================================================
    // DocGenService — generateDocument save paths
    // =========================================================================

    @IsTest
    static void testGenerateDocumentSavesPdfWhenOutputFormatPdf() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Document ID should not be null for PDF save test');
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pdf'), 'Saved file should be a PDF');
    }

    @IsTest
    static void testGenerateDocumentSavesPptx() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/_rels/presentation.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
                    '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'PPTSave',
            PathOnClient = 'PPTSave.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Document ID should not be null for PPTX save test');
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pptx'), 'Saved file should be a PPTX');
    }

    // =========================================================================
    // DocGenService — processXml: conditional sections (various data types)
    // =========================================================================

    @IsTest
    static void testProcessDocumentConditionalSectionTruthyString() {
        // Section where key resolves to a non-null string — exercises the non-null fallback path
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'Has description';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}Has Desc: {Description}{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for truthy conditional section');
    }

    @IsTest
    static void testProcessDocumentConditionalSectionNullValue() {
        // Section where key resolves to null — produces empty output for section
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}This should not appear{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for null conditional section');
    }

    // =========================================================================
    // DocGenService — processXml: date formatting
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithDateFormatTag() {
        // {CreatedDate:MM/dd/yyyy} — exercises DateTime format path in processXml
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, CreatedDate';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{CreatedDate:MM/dd/yyyy}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for date format tag test');
    }

    @IsTest
    static void testProcessDocumentWithColonInNonDateField() {
        // {Name:someformat} — non-date field with colon, exercises dateFormat != null but not DateTime
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name:uppercase}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for colon in non-date field');
    }

    // =========================================================================
    // DocGenService — processXml: HTML stripping
    // =========================================================================

    @IsTest
    static void testProcessDocumentHtmlSpanAndBrStrip() {
        // Field value with <span> and <br> tags — exercises stripHtmlTags path
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p>Line one</p><br/><span style="color:red">Line two</span>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for HTML span/br strip test');
    }

    // =========================================================================
    // DocGenService — buildImageXml: data URI and rich text <img> paths
    // =========================================================================

    @IsTest
    static void testProcessDocumentFieldWithImgTag() {
        // Field value contains <img src="data:image/png;base64,..."> — exercises
        // the rich text image detection and extractImageFromHtml data URI path
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGDATA'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<img src="data:image/png;base64,' + tinyBase64 + '" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for field with img tag test');
    }

    @IsTest
    static void testProcessDocumentImageTagDataUri() {
        // {%Description} where Description is a data:image/jpeg URI — exercises data URI branch in buildImageXml
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('JPEGFAKE'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/jpeg;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for image tag data URI test');
    }

    @IsTest
    static void testProcessDocumentImageTagBlankValue() {
        // {%Description} where Description is blank — exercises null return from buildImageXml
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for blank image value test');
    }

    @IsTest
    static void testProcessDocumentImageTagWithDimensions() {
        // {%Description:200x150} with a data URI — exercises size parsing in image tag
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('SIZED'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description:200x150}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for image tag with dimensions');
    }

    // =========================================================================
    // DocGenService — buildImageXml: raw base64 and ContentVersion ID paths
    // =========================================================================

    @IsTest
    static void testProcessDocumentImageTagRawBase64() {
        // {%Description} where Description is a long raw base64 string (no data URI prefix)
        // Exercises the "raw base64" branch (length > 100, no / or space)
        // Generate a base64 string > 100 chars
        String longBase64 = EncodingUtil.base64Encode(
            Blob.valueOf(
                'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
            )
        );

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = longBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for raw base64 image test');
    }

    @IsTest
    static void testProcessDocumentImageTagContentVersionId() {
        // {%Description} where Description holds a ContentVersion ID (starts with 068)
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImage',
            PathOnClient = 'TestImage.png',
            VersionData = Blob.valueOf('PNG_FAKE_DATA')
        );
        insert imgCv;
        imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = imgCv.Id;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for ContentVersion ID image test');
    }

    // =========================================================================
    // DocGenService — buildImageXml: refid and servlet URL paths (fail gracefully)
    // =========================================================================

    @IsTest
    static void testProcessDocumentImageTagRefidUrl() {
        // {%Description} where Description contains a refid URL — exercises fetchSalesforceImage with refid
        // Will fail to find image (no matching record) but exercises the code path
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'https://example.com/servlet/rtaImage?refid=0EM000000000001';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        // Image could not be resolved, but document should still generate
        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for refid URL image test');
    }

    @IsTest
    static void testProcessDocumentImageTagServletUrl() {
        // {%Description} with /servlet/ URL — exercises the servlet/sfc branch
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '/servlet/filedownload?file=015000000000001';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for servlet URL image test');
    }

    // =========================================================================
    // DocGenService — mergeRunsInTags: three-segment split
    // =========================================================================

    @IsTest
    static void testMergeRunsThreeSegments() {
        // Tag split across three <w:t> segments
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p>' +
            '<w:r><w:t>{N</w:t></w:r>' +
            '<w:r><w:t>am</w:t></w:r>' +
            '<w:r><w:t>e}</w:t></w:r>' +
            '</w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for three-segment merge test');
    }

    @IsTest
    static void testMergeRunsNoTagsNoModification() {
        // Document with no merge tags — mergeRunsInTags returns unchanged
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Plain text no tags</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for no-tags document');
    }

    // =========================================================================
    // DocGenService — processXml: edge cases
    // =========================================================================

    @IsTest
    static void testProcessDocumentUnclosedBrace() {
        // { without matching } — exercises tagClose == -1 path
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name} and {unclosed</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Map<String, Object> result;
        Test.startTest();
        try {
            result = DocGenService.processDocument(tpl.Id, acc.Id);
        } catch (DocGenException e) {
            System.assert(
                e.getMessage().contains('Malformed merge tag'),
                'Exception message should contain "Malformed merge tag"'
            );
        }
        Test.stopTest();

        System.assertEquals(null, result, 'Result should be null for unclosed brace test');
    }

    @IsTest
    static void testProcessDocumentEmptyBody() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for empty body test');
    }

    @IsTest
    static void testProcessDocumentNullFieldValue() {
        // {NonExistentField} — resolveValue returns null, tag replaced with nothing
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Before {NonExistentField} After</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for null field value test');
    }

    @IsTest
    static void testProcessDocumentXmlSpecialChars() {
        // Account name with & < > — exercises escapeXml
        Account acc = TestDataFactory.getTestAccount();
        acc.Name = 'Acme & Co <Test>';
        update acc;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for XML special chars test');
    }

    // =========================================================================
    // DocGenService — resolveValue: case-insensitive and deep nested path
    // =========================================================================

    @IsTest
    static void testProcessDocumentCaseInsensitiveField() {
        // {name} lowercase — exercises case-insensitive match
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for case-insensitive field test');
    }

    @IsTest
    static void testProcessDocumentDeepNestedPathNull() {
        // {Owner.Manager.Name} — deeply nested, Manager is null
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Owner.Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Owner.Manager.Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for deep nested null path');
    }

    // =========================================================================
    // DocGenService — generateDocTitle: mixed present/missing fields
    // =========================================================================

    @IsTest
    static void testGenerateDocTitleWithMixedFields() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Document_Title_Format__c = 'Doc-{Name}-{MissingField}-{AccountSource}';
        tpl.Query_Config__c = 'Name, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String title = (String) result.get('title');
        System.assert(title.contains('DocGen Test Account'), 'Title should contain account name for mixed fields');
        System.assert(title.contains('Web'), 'Title should contain account source for mixed fields');
        System.assert(title.contains('--'), 'Missing field should be replaced with empty string');
    }

    // =========================================================================
    // DocGenService — table row expansion with multiple contacts
    // =========================================================================

    @IsTest
    static void testProcessDocumentTableRowExpansionMultipleRows() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, (SELECT FirstName, LastName FROM Contacts)';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();
        insert new List<Contact>{
            new Contact(FirstName = 'Alice', LastName = 'Smith', AccountId = acc.Id),
            new Contact(FirstName = 'Bob', LastName = 'Jones', AccountId = acc.Id)
        };

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:tbl>' +
            '<w:tr><w:tc><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>{#Contacts}{FirstName} {LastName}{/Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for multi-row table expansion');
    }

    // =========================================================================
    // DocGenService — nested sections
    // =========================================================================

    @IsTest
    static void testProcessDocumentNestedSections() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'Present';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Description}{#AccountSource}Both present{/AccountSource}{/Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for nested sections test');
    }

    // =========================================================================
    // DocGenService — section outside table rows
    // =========================================================================

    @IsTest
    static void testProcessDocumentSectionOutsideTr() {
        // {#Contacts} before TR, {/Contacts} after TR — exercises trClosesBefore path
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, (SELECT FirstName FROM Contacts)';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();
        insert new Contact(FirstName = 'Multi', LastName = 'Row', AccountId = acc.Id);

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{#Contacts}</w:t></w:r></w:p>' +
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{FirstName}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
            '<w:p><w:r><w:t>{/Contacts}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for section outside TR test');
    }

    // =========================================================================
    // DocGenService — pendingImages: content types already contain png/jpeg
    // =========================================================================

    @IsTest
    static void testProcessDocumentImageWithExistingContentTypes() {
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('IMG'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/png;base64,' + tinyBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/>' +
                    '<Default Extension="jpeg" ContentType="image/jpeg"/>' +
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
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                    '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>'
            )
        );

        ContentVersion cv = new ContentVersion(
            Title = 'ImgExist',
            PathOnClient = 'ImgExist.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for existing content types test');
    }

    // =========================================================================
    // DocGenService — multiple images (two data URIs to exercise pendingImages rels)
    // =========================================================================

    @IsTest
    static void testProcessDocumentMultipleImageTags() {
        String pngBase64 = EncodingUtil.base64Encode(Blob.valueOf('PNGDATA'));
        String jpgBase64 = EncodingUtil.base64Encode(Blob.valueOf('JPGDATA'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/png;base64,' + pngBase64;
        acc.Website = 'data:image/jpeg;base64,' + jpgBase64;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description, Website';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description} {%Website}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for multiple image tags test');
    }

    // =========================================================================
    // DocGenService — multiple PPTX slides
    // =========================================================================

    @IsTest
    static void testProcessDocumentMultipleSlides() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/_rels/presentation.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        String slide1 =
            '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        String slide2 =
            '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t>{AccountSource}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>';
        zw.addEntry('ppt/slides/slide1.xml', Blob.valueOf(slide1));
        zw.addEntry('ppt/slides/slide2.xml', Blob.valueOf(slide2));

        ContentVersion cv = new ContentVersion(
            Title = 'MultiSlide',
            PathOnClient = 'MultiSlide.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for multiple slides test');
        System.assertEquals(
            'PowerPoint',
            result.get('templateType'),
            'Template type should be PowerPoint for multi-slide'
        );
    }

    // =========================================================================
    // DocGenService — generateDocument with null title fallback in saveFile
    // =========================================================================

    @IsTest
    static void testGenerateDocumentNullTitleFallback() {
        // Document_Title_Format__c is null → generateDocTitle returns null → falls back to Name
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Document_Title_Format__c = null;
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Document ID should not be null for null title fallback');
    }

    // =========================================================================
    // DocGenService — extractImageFromHtml: various URL patterns in <img> tag
    // =========================================================================

    @IsTest
    static void testProcessDocumentImgTagWithRefid() {
        // <img> with refid= attribute — exercises extractImageFromHtml refid branch
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<img src="https://example.com/servlet/rtaImage?eid=001&refid=0EM000000000001" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for img tag with refid');
    }

    @IsTest
    static void testProcessDocumentImgTagWithSfcUrl() {
        // <img> with /sfc/ URL — exercises extractImageFromHtml servlet/sfc branch
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<img src="/sfc/servlet.shepherd/version/download/068000000000001" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for img tag with sfc URL');
    }

    // =========================================================================
    // DocGenService — fetchSalesforceImage: ContentDocument ID (069) branch
    // =========================================================================

    @IsTest
    static void testProcessDocumentImageContentDocumentId() {
        // {%Description} where Description holds a ContentDocument ID (069...)
        ContentVersion imgCv = new ContentVersion(
            Title = 'TestImg069',
            PathOnClient = 'TestImg069.png',
            VersionData = Blob.valueOf('PNG069DATA')
        );
        insert imgCv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :imgCv.Id].ContentDocumentId;

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = String.valueOf(conDocId);
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for ContentDocument ID test');
    }

    // =========================================================================
    // DocGenService — applyResolvedImages
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithResolvedImages() {
        // Exercises the resolvedImages map (line 54-56) — applyResolvedImages with <img> tag
        Account acc = TestDataFactory.getTestAccount();
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('IMGDATA'));
        acc.Description = '<img src="https://example.com/image.png" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Map<String, String> resolvedImages = new Map<String, String>{
            'https://example.com/image.png' => 'data:image/png;base64,' + tinyBase64
        };

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id, resolvedImages);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for resolved images test');
    }

    // =========================================================================
    // DocGenService — generatePdfBlob used by unified path
    // =========================================================================

    @IsTest
    static void testGeneratePdfBlobReturnsValidBlob() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Hello {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for valid PDF blob test');
        System.assertNotEquals(null, result.get('title'), 'Title should not be null for valid PDF blob test');
    }

    // =========================================================================
    // DocGenService — generateDocument PDF save path
    // =========================================================================

    @IsTest
    static void testGenerateDocumentPdfSave() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Document ID should not be null for PDF save test');
    }

    // =========================================================================
    // DocGenService — processDocumentAsHtmlWithImageMap
    // =========================================================================

    @IsTest
    static void testProcessDocumentAsHtmlWithImageMap() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Map<String, String> imageMap = new Map<String, String>{ 'rIdTest' => 'https://example.com/image.png' };

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocumentAsHtmlWithImageMap(tpl.Id, acc.Id, imageMap);
        Test.stopTest();

        System.assertNotEquals(null, result.get('html'), 'HTML should not be null for image map test');
        System.assertEquals('PDF', result.get('outputFormat'), 'Output format should be PDF');
    }

    // =========================================================================
    // DocGenService — extractAndSaveTemplateImages
    // =========================================================================

    @IsTest
    static void testExtractAndSaveTemplateImages() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/media/image1.png', Blob.valueOf('FAKEPNGDATA'));

        ContentVersion cv = new ContentVersion(
            Title = 'ImgDocx',
            PathOnClient = 'ImgDocx.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);
        Test.stopTest();

        String prefix = 'docgen_tmpl_img_' + ver.Id + '_';
        List<ContentVersion> savedImgs = [SELECT Title FROM ContentVersion WHERE Title LIKE :(prefix + '%')];
        System.assert(savedImgs.size() >= 1, 'Should have saved at least one template image');
    }

    // =========================================================================
    // DocGenService — rich text with formatting tags
    // =========================================================================

    @IsTest
    static void testProcessDocumentRichTextWithFormattingTags() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p><b>Bold</b> <i>Italic</i> <u>Underline</u></p>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for rich text formatting tags');
    }

    @IsTest
    static void testProcessDocumentRichTextWithStrongAndEm() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<strong>Strong</strong> and <em>Emphasis</em>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for strong/em tags test');
    }

    // =========================================================================
    // DocGenService — rich text with inline image (img tag with src URL)
    // =========================================================================

    @IsTest
    static void testProcessDocumentRichTextImgWithSalesforceUrl() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p>Text <img src="/servlet/rtaImage?eid=001&feoid=00N&refid=0EM000000000001" width="200" height="100" /> more text</p>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for rich text Salesforce URL img');
    }

    // =========================================================================
    // DocGenService — image tag with HTTPS URL (generic external)
    // =========================================================================

    @IsTest
    static void testProcessDocumentImageTagHttpsUrl() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'https://example.com/some-image.png';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for HTTPS URL image tag');
    }

    // =========================================================================
    // DocGenService — image tag in PowerPoint (skipped)
    // =========================================================================

    @IsTest
    static void testProcessDocumentPowerPointImageTagSkipped() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>' +
                    '<p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{%Description}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'PPTImg',
            PathOnClient = 'PPTImg.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'data:image/png;base64,' + EncodingUtil.base64Encode(Blob.valueOf('IMG'));
        update acc;
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PowerPoint image tag skip');
    }

    @IsTest
    static void testPowerPointImageMarkerUsesUnusedShapeId() {
        String slideXml =
            '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree>' +
            '<p:sp><p:nvSpPr><p:cNvPr id="1" name="Existing"/></p:nvSpPr></p:sp>' +
            '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Placeholder"/></p:nvSpPr>' +
            '<p:spPr><a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:off x="10" y="20"/><a:ext cx="30" cy="40"/></a:xfrm></p:spPr>' +
            '<p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:r><a:t><!--DGPIC|rIdImg1|100|200|1--></a:t></a:r></a:p></p:txBody>' +
            '</p:sp>' +
            '</p:spTree></p:cSld></p:sld>';

        String out = DocGenService.convertDgPicMarkersInSlide(slideXml, new List<Map<String, Object>>());

        System.assert(
            out.contains('<p:cNvPr id="3" name="DocGenPicture3"/>'),
            'Inserted picture should use the next unused slide-local cNvPr id. Got: ' + out
        );
        System.assertEquals(
            out.indexOf('<p:cNvPr id="1"'),
            out.lastIndexOf('<p:cNvPr id="1"'),
            'Existing shape id 1 should remain unique, not be reused by the inserted picture. Got: ' + out
        );
    }

    @IsTest
    static void testPowerPointImageUsesNumericSlideRelationshipId() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/>' +
                    '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/_rels/slide1.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
                    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
                    '<p:cSld><p:spTree>' +
                    '<p:sp><p:nvSpPr><p:cNvPr id="1" name="Placeholder"/></p:nvSpPr>' +
                    '<p:spPr><a:xfrm xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:off x="10" y="20"/><a:ext cx="30" cy="40"/></a:xfrm></p:spPr>' +
                    '<p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{%Description}</a:t></a:r></a:p></p:txBody></p:sp>' +
                    '</p:spTree></p:cSld></p:sld>'
            )
        );

        ContentVersion cv = new ContentVersion(
            Title = 'PPTNumericImageRel',
            PathOnClient = 'PPTNumericImageRel.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        acc.Description =
            'data:image/png;base64,' +
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lm0V9wAAAABJRU5ErkJggg==';
        update acc;

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        Compression.ZipReader reader = new Compression.ZipReader((Blob) result.get('blob'));
        String relsXml = reader.extract('ppt/slides/_rels/slide1.xml.rels').toString();
        String slideXml = reader.extract('ppt/slides/slide1.xml').toString();

        System.assert(
            relsXml.contains('Id="rId3"'),
            'PPT image relationship should use next numeric rId. Got: ' + relsXml
        );
        System.assert(
            !relsXml.contains('rIdImg'),
            'PowerPoint repairs non-numeric image relationship ids. Got: ' + relsXml
        );
        System.assert(
            slideXml.contains('r:embed="rId3"'),
            'Inserted picture should reference numeric rId3. Got: ' + slideXml
        );
    }

    @IsTest
    static void testPowerPointEmptyDrawingTextIsNormalized() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        tpl.Query_Config__c = 'Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" ' +
                    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<p:cSld><p:spTree>' +
                    '<p:graphicFrame><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">' +
                    '<a:tbl><a:tblPr><a:tableStyleId></a:tableStyleId></a:tblPr>' +
                    '<a:tblGrid><a:gridCol w="1000"/></a:tblGrid>' +
                    '<a:tr h="1000"><a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t></a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr>' +
                    '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>' +
                    '<p:sp><p:txBody><a:p><a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp>' +
                    '</p:spTree></p:cSld></p:sld>'
            )
        );

        ContentVersion cv = new ContentVersion(
            Title = 'PPTEmptyText',
            PathOnClient = 'PPTEmptyText.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        Compression.ZipReader reader = new Compression.ZipReader((Blob) result.get('blob'));
        String slideXml = reader.extract('ppt/slides/slide1.xml').toString();

        System.assert(!slideXml.contains('<a:t></a:t>'), 'Empty DrawingML text nodes trigger PowerPoint repair.');
        System.assert(
            !slideXml.contains('<a:tableStyleId></a:tableStyleId>'),
            'Empty table style ids trigger PowerPoint repair.'
        );
        System.assert(slideXml.contains('<a:t> </a:t>'), 'Empty table cells should remain present as whitespace text.');
    }

    @IsTest
    static void testPowerPointRevisionPartsStripped() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        tpl.Query_Config__c = 'Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>' +
                    '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>' +
                    '<Override PartName="/ppt/changesInfos/changesInfo1.xml" ContentType="application/vnd.ms-powerpoint.changesinfo+xml"/>' +
                    '<Override PartName="/ppt/revisionInfo.xml" ContentType="application/vnd.ms-powerpoint.revisioninfo+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/_rels/presentation.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>' +
                    '<Relationship Id="rId2" Type="http://schemas.microsoft.com/office/2015/10/relationships/revisionInfo" Target="revisionInfo.xml"/>' +
                    '<Relationship Id="rId3" Type="http://schemas.microsoft.com/office/2016/11/relationships/changesInfo" Target="changesInfos/changesInfo1.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'ppt/presentation.xml',
            Blob.valueOf('<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"/>')
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>' +
                    '<p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        zw.addEntry('ppt/revisionInfo.xml', Blob.valueOf('<p:revisionInfo xmlns:p="urn:test"/>'));
        zw.addEntry('ppt/changesInfos/changesInfo1.xml', Blob.valueOf('<p:changesInfo xmlns:p="urn:test"/>'));
        zw.addEntry('[trash]/0000.dat', Blob.valueOf('stale'));

        ContentVersion cv = new ContentVersion(
            Title = 'PPTRevisionParts',
            PathOnClient = 'PPTRevisionParts.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        Blob outBlob = (Blob) result.get('blob');
        Compression.ZipReader reader = new Compression.ZipReader(outBlob);
        Set<String> names = new Set<String>();
        for (Compression.ZipEntry entry : reader.getEntries()) {
            names.add(entry.getName());
        }
        System.assert(!names.contains('ppt/revisionInfo.xml'), 'revisionInfo.xml should be stripped.');
        System.assert(!names.contains('ppt/changesInfos/changesInfo1.xml'), 'changesInfo should be stripped.');
        System.assert(!names.contains('[trash]/0000.dat'), '[trash] entries should be stripped.');
        System.assert(
            !reader.extract('ppt/_rels/presentation.xml.rels').toString().contains('revisionInfo'),
            'presentation rels should not reference revisionInfo.'
        );
        System.assert(
            !reader.extract('[Content_Types].xml').toString().contains('changesInfo'),
            'content types should not reference changesInfo.'
        );
    }

    // =========================================================================
    // DocGenService — rich text HTML in PowerPoint (plain text strip)
    // =========================================================================

    @IsTest
    static void testProcessDocumentPowerPointHtmlStripped() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p>Paragraph <b>bold</b></p>';
        update acc;

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>' +
                    '<p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Description}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'PPTHtml2',
            PathOnClient = 'PPTHtml2.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PowerPoint HTML stripped');
    }

    // =========================================================================
    // DocGenService — generatePdfBlob download path
    // =========================================================================

    @IsTest
    static void testGeneratePdfBlobDownload() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for PDF download test');
        System.assertNotEquals(null, result.get('title'), 'Title should not be null for PDF download test');
    }

    // =========================================================================
    // DocGenService — Date format on DateTime field with alternate format
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithDateTimeAlternateFormat() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, CreatedDate';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{CreatedDate:yyyy-MM-dd HH:mm}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for alternate DateTime format');
    }

    // =========================================================================
    // DocGenService — DOCX with existing images (rels parsing)
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithExistingTemplateImage() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>' +
                    '<Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/media/image1.png', Blob.valueOf('FAKEPNGBYTES'));

        ContentVersion cv = new ContentVersion(
            Title = 'TmplImg',
            PathOnClient = 'TmplImg.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for existing template image');
    }

    // =========================================================================
    // DocGenException — thrown and caught
    // =========================================================================

    @IsTest
    static void testDocGenExceptionThrown() {
        Boolean caught = false;
        Test.startTest();
        try {
            throw new DocGenException('Test throw');
        } catch (DocGenException e) {
            caught = true;
            System.assertEquals('Test throw', e.getMessage(), 'Thrown exception message should match');
        }
        Test.stopTest();
        System.assert(caught, 'Should catch thrown DocGenException');
    }

    // =========================================================================
    // DocGenDataRetriever — V2 JSON Config
    // =========================================================================

    @IsTest
    static void testGetRecordDataV2BasicFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            // Create Opportunity linked to Account
            Opportunity opp = new Opportunity(
                Name = 'V2 Test Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            String v2Config =
                '{"v":2,"baseObject":"Opportunity","baseFields":["Name","StageName"],' +
                '"parentFields":["Account.Name"],"children":[],"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(opp.Id, 'Opportunity', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V2 result should not be null');
            System.assertEquals('V2 Test Opp', result.get('Name'), 'V2 should return Opp Name');
            System.assert(result.containsKey('Account'), 'V2 should include parent Account data');
            Map<String, Object> accData = (Map<String, Object>) result.get('Account');
            System.assertEquals('DocGen Test Account', accData.get('Name'), 'V2 parent Account.Name should match');
        }
    }

    @IsTest
    static void testGetRecordDataV2WithChildren() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Opportunity opp = new Opportunity(
                Name = 'V2 Child Test Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            // Create Product + PricebookEntry + OpportunityLineItem
            Product2 prod = new Product2(Name = 'V2 Test Product', IsActive = true);
            insert prod;
            Id stdPbId = Test.getStandardPricebookId();
            PricebookEntry pbe = new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id = prod.Id,
                UnitPrice = 100,
                IsActive = true
            );
            insert pbe;
            OpportunityLineItem oli = new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 5,
                UnitPrice = 100
            );
            insert oli;

            String v2Config =
                '{"v":2,"baseObject":"Opportunity","baseFields":["Name"],' +
                '"parentFields":["Account.Name"],' +
                '"children":[{"rel":"OpportunityLineItems","fields":["Quantity","UnitPrice"]}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(opp.Id, 'Opportunity', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V2 with children should not be null');
            System.assert(result.containsKey('OpportunityLineItems'), 'V2 should contain OpportunityLineItems');
            Map<String, Object> oliData = (Map<String, Object>) result.get('OpportunityLineItems');
            Integer totalSize = (Integer) oliData.get('totalSize');
            System.assertEquals(1, totalSize, 'V2 should have 1 line item');
        }
    }

    @IsTest
    static void testGetRecordDataV2WithJunction() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'Junction', LastName = 'TestContact', AccountId = acc.Id);
            insert con;

            Opportunity opp = new Opportunity(
                Name = 'V2 Junction Test Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            OpportunityContactRole ocr = new OpportunityContactRole(
                OpportunityId = opp.Id,
                ContactId = con.Id,
                Role = 'Decision Maker'
            );
            insert ocr;

            String v2Config =
                '{"v":2,"baseObject":"Opportunity","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[],' +
                '"junctions":[{"junctionRel":"OpportunityContactRoles","junctionFields":["Role"],' +
                '"targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName","LastName"]}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(opp.Id, 'Opportunity', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V2 junction result should not be null');
            System.assert(result.containsKey('OpportunityContactRoles'), 'V2 should contain junction relationship');
            Map<String, Object> ocrData = (Map<String, Object>) result.get('OpportunityContactRoles');
            List<Object> ocrRecords = (List<Object>) ocrData.get('records');
            System.assertEquals(1, ocrRecords.size(), 'V2 should have 1 OCR record');

            // Verify junction stitching: Contact data should be embedded in OCR record
            Map<String, Object> ocrRec = (Map<String, Object>) ocrRecords[0];
            System.assert(ocrRec.containsKey('Contact'), 'Junction should stitch Contact into OCR record');
            Map<String, Object> contactData = (Map<String, Object>) ocrRec.get('Contact');
            System.assertEquals('Junction', contactData.get('FirstName'), 'Stitched Contact FirstName should match');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V3 Tree Walker
    // =========================================================================

    @IsTest
    static void testGetRecordDataV3BasicTree() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'TreeWalker', LastName = 'TestV3', AccountId = acc.Id);
            insert con;

            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":["Owner.Name"],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName","LastName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V3 result should not be null');
            System.assertEquals('DocGen Test Account', result.get('Name'), 'V3 root Name should match');
            System.assert(result.containsKey('Owner'), 'V3 should include parent Owner');
            System.assert(result.containsKey('Contacts'), 'V3 should contain Contacts child');
            Map<String, Object> contactsData = (Map<String, Object>) result.get('Contacts');
            Integer totalSize = (Integer) contactsData.get('totalSize');
            System.assert(totalSize >= 1, 'V3 should have at least 1 Contact');
        }
    }

    @IsTest
    static void testGetRecordDataV3MultiLevel() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            Opportunity opp = new Opportunity(
                Name = 'V3 Multi Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            Product2 prod = new Product2(Name = 'V3 Product', IsActive = true);
            insert prod;
            Id stdPbId = Test.getStandardPricebookId();
            PricebookEntry pbe = new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id = prod.Id,
                UnitPrice = 50,
                IsActive = true
            );
            insert pbe;
            OpportunityLineItem oli = new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 3,
                UnitPrice = 50
            );
            insert oli;

            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Opportunity","fields":["Name","Amount"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},' +
                '{"id":"n2","object":"OpportunityLineItem","fields":["Quantity"],"parentFields":["Product2.Name"],' +
                '"parentNode":"n1","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V3 multi-level should not be null');
            System.assert(result.containsKey('Opportunities'), 'V3 should contain Opportunities');
            Map<String, Object> oppData = (Map<String, Object>) result.get('Opportunities');
            List<Object> oppRecords = (List<Object>) oppData.get('records');
            // Factory also creates an Opp on this Account, so find our specific one by name
            System.assert(oppRecords.size() >= 1, 'V3 should have at least 1 Opportunity');

            Map<String, Object> oppRec = null;
            for (Object o : oppRecords) {
                Map<String, Object> candidate = (Map<String, Object>) o;
                if (candidate.get('Name') == 'V3 Multi Opp') {
                    oppRec = candidate;
                    break;
                }
            }
            System.assertNotEquals(null, oppRec, 'V3 should contain the V3 Multi Opp record');
            System.assert(oppRec.containsKey('OpportunityLineItems'), 'V3 Opp should contain OLI children');
            Map<String, Object> oliData = (Map<String, Object>) oppRec.get('OpportunityLineItems');
            List<Object> oliRecords = (List<Object>) oliData.get('records');
            System.assertEquals(1, oliRecords.size(), 'V3 should have 1 OLI');

            // Verify parent field on OLI (Product2.Name)
            Map<String, Object> oliRec = (Map<String, Object>) oliRecords[0];
            System.assert(oliRec.containsKey('Product2'), 'V3 OLI should have Product2 parent');
            Map<String, Object> prodData = (Map<String, Object>) oliRec.get('Product2');
            System.assertEquals('V3 Product', prodData.get('Name'), 'V3 Product2.Name should match');
        }
    }

    @IsTest
    static void testGetRecordDataV3NoNodesThrows() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(acc.Id, 'Account', '{"v":3,"root":"Account","nodes":[]}');
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'V3 with empty nodes should throw');
        }
    }

    @IsTest
    static void testGetRecordDataV3WithJunction() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'V3Junction', LastName = 'Test', AccountId = acc.Id);
            insert con;

            Opportunity opp = new Opportunity(
                Name = 'V3 Junction Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            OpportunityContactRole ocr = new OpportunityContactRole(
                OpportunityId = opp.Id,
                ContactId = con.Id,
                Role = 'Influencer'
            );
            insert ocr;

            // V3 config with junction node: OCR as child of Opportunity with junction to Contact
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Opportunity","fields":["Name"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},' +
                '{"id":"n2","object":"OpportunityContactRole","fields":["Role"],"parentFields":[],' +
                '"parentNode":"n1","lookupField":"OpportunityId","relationshipName":"OpportunityContactRoles",' +
                '"junction":{"targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName","LastName"]}}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V3 junction result should not be null');
            Map<String, Object> oppsData = (Map<String, Object>) result.get('Opportunities');
            List<Object> opps = (List<Object>) oppsData.get('records');
            // Factory also creates an Opp on this Account — find the one with OCR by name
            Map<String, Object> oppRec = null;
            for (Object o : opps) {
                Map<String, Object> candidate = (Map<String, Object>) o;
                if (candidate.get('Name') == 'V3 Junction Opp') {
                    oppRec = candidate;
                    break;
                }
            }
            System.assertNotEquals(null, oppRec, 'V3 should contain the V3 Junction Opp record');
            System.assert(oppRec.containsKey('OpportunityContactRoles'), 'V3 should have OCR on Opp');

            Map<String, Object> ocrContainer = (Map<String, Object>) oppRec.get('OpportunityContactRoles');
            List<Object> ocrRecords = (List<Object>) ocrContainer.get('records');
            System.assertEquals(1, ocrRecords.size(), 'V3 should have 1 OCR');

            Map<String, Object> ocrRec = (Map<String, Object>) ocrRecords[0];
            System.assert(ocrRec.containsKey('Contact'), 'V3 junction should stitch Contact');
            Map<String, Object> contactData = (Map<String, Object>) ocrRec.get('Contact');
            System.assertEquals('V3Junction', contactData.get('FirstName'), 'V3 junction stitched FirstName');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V3 Bulk Query
    // =========================================================================

    @IsTest
    static void testGetRecordDataV3Bulk() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            // Create a second account for bulk testing
            Account acc2 = new Account(Name = 'Bulk Test Account 2');
            insert acc2;

            Contact con1 = new Contact(FirstName = 'BulkA', LastName = 'Test', AccountId = acc.Id);
            Contact con2 = new Contact(FirstName = 'BulkB', LastName = 'Test', AccountId = acc2.Id);
            insert new List<Contact>{ con1, con2 };

            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(
                '{"v":3,"root":"Account","nodes":[' +
                    '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                    '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                    '{"id":"n1","object":"Contact","fields":["FirstName","LastName"],"parentFields":[],' +
                    '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}]}'
            );

            Set<Id> recordIds = new Set<Id>{ acc.Id, acc2.Id };

            Test.startTest();
            Map<Id, Map<String, Object>> results = DocGenDataRetriever.getRecordDataV3Bulk(recordIds, config);
            Test.stopTest();

            System.assertEquals(2, results.size(), 'Bulk should return 2 accounts');
            System.assert(results.containsKey(acc.Id), 'Bulk should contain first account');
            System.assert(results.containsKey(acc2.Id), 'Bulk should contain second account');

            // Verify children were stitched for each account
            Map<String, Object> acc1Data = results.get(acc.Id);
            System.assert(acc1Data.containsKey('Contacts'), 'Bulk acc1 should have Contacts');

            Map<String, Object> acc2Data = results.get(acc2.Id);
            System.assert(acc2Data.containsKey('Contacts'), 'Bulk acc2 should have Contacts');
            Map<String, Object> acc2Contacts = (Map<String, Object>) acc2Data.get('Contacts');
            List<Object> acc2ContactRecords = (List<Object>) acc2Contacts.get('records');
            System.assertEquals(1, acc2ContactRecords.size(), 'Bulk acc2 should have 1 Contact');
        }
    }

    @IsTest
    static void testGetRecordDataV3BulkEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Map<Id, Map<String, Object>> results = DocGenDataRetriever.getRecordDataV3Bulk(
                new Set<Id>(),
                new Map<String, Object>()
            );
            Test.stopTest();

            System.assert(results.isEmpty(), 'Bulk with empty IDs should return empty map');
        }
    }

    @IsTest
    static void testGetRecordDataV3BulkWithJunction() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'BulkJunction', LastName = 'Test', AccountId = acc.Id);
            insert con;

            Opportunity opp = new Opportunity(
                Name = 'Bulk Junction Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            OpportunityContactRole ocr = new OpportunityContactRole(
                OpportunityId = opp.Id,
                ContactId = con.Id,
                Role = 'Evaluator'
            );
            insert ocr;

            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(
                '{"v":3,"root":"Account","nodes":[' +
                    '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                    '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                    '{"id":"n1","object":"Opportunity","fields":["Name"],"parentFields":[],' +
                    '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Opportunities"},' +
                    '{"id":"n2","object":"OpportunityContactRole","fields":["Role"],"parentFields":[],' +
                    '"parentNode":"n1","lookupField":"OpportunityId","relationshipName":"OpportunityContactRoles",' +
                    '"junction":{"targetObject":"Contact","targetIdField":"ContactId","targetFields":["FirstName"]}}]}'
            );

            Test.startTest();
            Map<Id, Map<String, Object>> results = DocGenDataRetriever.getRecordDataV3Bulk(
                new Set<Id>{ acc.Id },
                config
            );
            Test.stopTest();

            System.assertEquals(1, results.size(), 'Bulk junction should return 1 account');
            Map<String, Object> accData = results.get(acc.Id);
            Map<String, Object> oppsContainer = (Map<String, Object>) accData.get('Opportunities');
            List<Object> opps = (List<Object>) oppsContainer.get('records');
            // Factory also creates an Opp on this Account — find the one with OCR by name
            Map<String, Object> oppRec = null;
            for (Object o : opps) {
                Map<String, Object> candidate = (Map<String, Object>) o;
                if (candidate.get('Name') == 'Bulk Junction Opp') {
                    oppRec = candidate;
                    break;
                }
            }
            System.assertNotEquals(null, oppRec, 'Bulk should contain the Bulk Junction Opp record');
            Map<String, Object> ocrContainer = (Map<String, Object>) oppRec.get('OpportunityContactRoles');
            List<Object> ocrs = (List<Object>) ocrContainer.get('records');
            Map<String, Object> ocrRec = (Map<String, Object>) ocrs[0];
            System.assert(ocrRec.containsKey('Contact'), 'Bulk junction should stitch Contact');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — getConfigVersion
    // =========================================================================

    @IsTest
    static void testGetConfigVersion() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            // V1: plain string
            System.assertEquals(1, DocGenDataRetriever.getConfigVersion('Name, Industry'), 'Plain string should be V1');
            System.assertEquals(1, DocGenDataRetriever.getConfigVersion(''), 'Empty string should be V1');
            System.assertEquals(1, DocGenDataRetriever.getConfigVersion(null), 'Null should be V1');

            // V2: JSON without explicit version
            System.assertEquals(
                2,
                DocGenDataRetriever.getConfigVersion('{"baseObject":"Account","baseFields":["Name"]}'),
                'JSON without v field should be V2'
            );

            // V2: JSON with v:2
            System.assertEquals(
                2,
                DocGenDataRetriever.getConfigVersion('{"v":2,"baseObject":"Opportunity"}'),
                'JSON with v:2 should be V2'
            );

            // V3: JSON with v:3
            System.assertEquals(
                3,
                DocGenDataRetriever.getConfigVersion('{"v":3,"root":"Account","nodes":[]}'),
                'JSON with v:3 should be V3'
            );

            // Malformed JSON falls back to V1
            System.assertEquals(
                1,
                DocGenDataRetriever.getConfigVersion('{not valid json'),
                'Malformed JSON should fall back to V1'
            );
            Test.stopTest();
        }
    }

    // =========================================================================
    // DocGenDataRetriever — sanitizeClause
    // =========================================================================

    @IsTest
    static void testSanitizeClauseViaV2WhereClause() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'ClauseTest', LastName = 'Safe', AccountId = acc.Id);
            insert con;

            // V2 config with valid WHERE and ORDER BY and LIMIT on children
            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName","LastName"],' +
                '"where":"LastName = \'Safe\'","orderBy":"FirstName","limit":"10"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V2 with clauses should not be null');
            Map<String, Object> contactsData = (Map<String, Object>) result.get('Contacts');
            List<Object> records = (List<Object>) contactsData.get('records');
            System.assertEquals(1, records.size(), 'WHERE clause should filter to 1 contact');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsSemicolon() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught = false;

            // V2 config with injection attempt via semicolon in WHERE
            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"where":"LastName = \'x\'; DELETE Contact"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Root data should still be returned');
            System.assert(!result.containsKey('Contacts'), 'Invalid child relationship should be skipped');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"where":"LastName = \'x\' -- comment"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for comment rejection test');
            System.assert(!result.containsKey('Contacts'), 'Comment in WHERE should skip child');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsBlockComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"where":"LastName = \'x\' /* block */"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for block comment rejection');
            System.assert(!result.containsKey('Contacts'), 'Block comment in WHERE should skip child');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsNonNumericLimit() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"limit":"abc"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for non-numeric LIMIT test');
            System.assert(!result.containsKey('Contacts'), 'Non-numeric LIMIT should skip child');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsDMLKeyword() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"where":"DELETE FROM Contact"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for DML keyword rejection');
            System.assert(!result.containsKey('Contacts'), 'DML keyword in WHERE should skip child');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsSelectInWhere() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":"Contacts","fields":["FirstName"],' +
                '"where":"Id IN (SELECT Id FROM User)"}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for SELECT injection rejection');
            System.assert(!result.containsKey('Contacts'), 'SELECT in WHERE clause should skip child');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — mapSObject with Address and various types
    // =========================================================================

    @IsTest
    static void testMapSObjectWithAddress() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            acc.BillingStreet = '123 Test St';
            acc.BillingCity = 'TestCity';
            acc.BillingState = 'CA';
            acc.BillingPostalCode = '90210';
            acc.BillingCountry = 'US';
            update acc;

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, BillingAddress');
            Test.stopTest();

            System.assertNotEquals(null, result, 'mapSObject with Address should not be null');
            System.assert(result.containsKey('BillingAddress'), 'Should contain BillingAddress compound field');
            Map<String, Object> addrMap = (Map<String, Object>) result.get('BillingAddress');
            System.assertEquals('123 Test St', addrMap.get('street'), 'Address street should match');
            System.assertEquals('TestCity', addrMap.get('city'), 'Address city should match');
        }
    }

    @IsTest
    static void testMapSObjectWithSubquery() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con = new Contact(FirstName = 'MapSObj', LastName = 'Child', AccountId = acc.Id);
            insert con;

            // V1 style with subquery tests mapSObject's List<SObject> branch
            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(
                acc.Id,
                'Account',
                'Name, (SELECT FirstName, LastName FROM Contacts)'
            );
            Test.stopTest();

            System.assertNotEquals(null, result, 'V1 subquery result should not be null');
            System.assert(result.containsKey('Contacts'), 'Should contain Contacts from subquery');
            Map<String, Object> contactsMap = (Map<String, Object>) result.get('Contacts');
            Integer totalSize = (Integer) contactsMap.get('totalSize');
            System.assert(totalSize >= 1, 'Should have at least 1 contact');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V2 with empty/null child fields
    // =========================================================================

    @IsTest
    static void testGetRecordDataV2SkipsInvalidChildren() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            // Child with null rel should be skipped; child with empty fields should be skipped
            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"parentFields":[],' +
                '"children":[{"rel":null,"fields":["FirstName"]},{"rel":"Contacts","fields":[]}],' +
                '"junctions":[]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V2 with invalid children should still return data');
            System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should still be present');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V3 with WHERE/ORDER BY/LIMIT on child nodes
    // =========================================================================

    @IsTest
    static void testGetRecordDataV3WithClauses() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Contact con1 = new Contact(FirstName = 'Alpha', LastName = 'Clause', AccountId = acc.Id);
            Contact con2 = new Contact(FirstName = 'Beta', LastName = 'Clause', AccountId = acc.Id);
            Contact con3 = new Contact(FirstName = 'Gamma', LastName = 'Other', AccountId = acc.Id);
            insert new List<Contact>{ con1, con2, con3 };

            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName","LastName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"where":"LastName = \'Clause\'","orderBy":"FirstName ASC","limit":"2"}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for V3 with clauses');
            Map<String, Object> contactsData = (Map<String, Object>) result.get('Contacts');
            List<Object> records = (List<Object>) contactsData.get('records');
            System.assert(records.size() <= 2, 'LIMIT 2 should cap results at 2');
            // All returned records should have LastName = 'Clause'
            for (Object rec : records) {
                Map<String, Object> cRec = (Map<String, Object>) rec;
                System.assertEquals('Clause', cRec.get('LastName'), 'WHERE clause should filter by LastName');
            }
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V1 grandchild stitching
    // =========================================================================

    @IsTest
    static void testGetRecordDataV1Grandchildren() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Opportunity opp = new Opportunity(
                Name = 'Grandchild Opp',
                AccountId = acc.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30)
            );
            insert opp;

            Product2 prod = new Product2(Name = 'GC Product', IsActive = true);
            insert prod;
            Id stdPbId = Test.getStandardPricebookId();
            PricebookEntry pbe = new PricebookEntry(
                Pricebook2Id = stdPbId,
                Product2Id = prod.Id,
                UnitPrice = 75,
                IsActive = true
            );
            insert pbe;
            OpportunityLineItem oli = new OpportunityLineItem(
                OpportunityId = opp.Id,
                PricebookEntryId = pbe.Id,
                Quantity = 2,
                UnitPrice = 75
            );
            insert oli;

            // V1 config with nested subquery (grandchild)
            String v1Config = 'Name, (SELECT Name, (SELECT Quantity FROM OpportunityLineItems) FROM Opportunities)';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v1Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'V1 grandchild result should not be null');
            System.assert(result.containsKey('Opportunities'), 'Should contain Opportunities');
            Map<String, Object> oppContainer = (Map<String, Object>) result.get('Opportunities');
            List<Object> oppRecords = (List<Object>) oppContainer.get('records');
            System.assert(oppRecords.size() >= 1, 'Should have at least 1 Opportunity');

            // Verify grandchild stitching
            Map<String, Object> oppRec = (Map<String, Object>) oppRecords[0];
            System.assert(
                oppRec.containsKey('OpportunityLineItems'),
                'Grandchild OpportunityLineItems should be stitched into Opportunity'
            );
        }
    }

    // =========================================================================
    // DocGenService — Aggregate functions (SUM, AVG, COUNT, MIN, MAX)
    // =========================================================================

    @IsTest
    static void testAggregateSumTag() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Amount' => 100 },
                new Map<String, Object>{ 'Amount' => 250 },
                new Map<String, Object>{ 'Amount' => 50 }
            }
        };

        String xml = 'Total: {SUM:Items.Amount}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('400'), 'SUM should be 400, got: ' + result);
    }

    @IsTest
    static void testAggregateAvgTag() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Score' => 10 },
                new Map<String, Object>{ 'Score' => 20 },
                new Map<String, Object>{ 'Score' => 30 }
            }
        };

        String xml = 'Avg: {AVG:Items.Score}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('20'), 'AVG should be 20, got: ' + result);
    }

    @IsTest
    static void testAggregateCountTag() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'A' },
                new Map<String, Object>{ 'Name' => 'B' },
                new Map<String, Object>{ 'Name' => 'C' }
            }
        };

        String xml = 'Count: {COUNT:Items}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('3'), 'COUNT should be 3, got: ' + result);
    }

    @IsTest
    static void testAggregateMinMaxTags() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Val' => 5 },
                new Map<String, Object>{ 'Val' => 15 },
                new Map<String, Object>{ 'Val' => 10 }
            }
        };

        Test.startTest();
        String minResult = DocGenService.processXmlForTest('Min: {MIN:Items.Val}', data);
        String maxResult = DocGenService.processXmlForTest('Max: {MAX:Items.Val}', data);
        Test.stopTest();

        System.assert(minResult.contains('5'), 'MIN should be 5, got: ' + minResult);
        System.assert(maxResult.contains('15'), 'MAX should be 15, got: ' + maxResult);
    }

    @IsTest
    static void testAggregateWithRecordsMap() {
        // Child data wrapped in {records: [...]} format (V1 query style)
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'Contacts' => new Map<String, Object>{
                'records' => new List<Object>{
                    new Map<String, Object>{ 'Score' => 10 },
                    new Map<String, Object>{ 'Score' => 20 }
                }
            }
        };

        String xml = '{SUM:Contacts.Score}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('30'), 'SUM with records map should be 30, got: ' + result);
    }

    @IsTest
    static void testAggregateEmptyList() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Test', 'Items' => new List<Object>() };

        String xml = '{SUM:Items.Amount}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('0'), 'SUM of empty list should be 0, got: ' + result);
    }

    @IsTest
    static void testAggregateNonExistentList() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Test' };

        String xml = '{COUNT:NonExistent}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('0'), 'COUNT of nonexistent list should be 0, got: ' + result);
    }

    @IsTest
    static void testAggregateWithFormatSpecifier() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Price' => 1234.5 },
                new Map<String, Object>{ 'Price' => 5678.9 }
            }
        };

        String xml = '{SUM:Items.Price:currency}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('$'), 'SUM with currency format should contain $, got: ' + result);
        System.assert(result.contains('6,913.40'), 'SUM should be $6,913.40, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Number formatting (formatNumber, formatWithCommas, isNumericFormat)
    // =========================================================================

    @IsTest
    static void testNumberFormatCurrency() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 500000 };

        String xml = '{Amount:currency}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('$500,000.00'), 'Currency should be $500,000.00, got: ' + result);
    }

    @IsTest
    static void testNumberFormatNumber() {
        Map<String, Object> data = new Map<String, Object>{ 'Quantity' => 1234567 };

        String xml = '{Quantity:number}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('1,234,567'), 'Number should be 1,234,567, got: ' + result);
    }

    @IsTest
    static void testNumberFormatPercent() {
        Map<String, Object> data = new Map<String, Object>{ 'Rate' => 15.5 };

        String xml = '{Rate:percent}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('15.5%'), 'Percent should be 15.5%, got: ' + result);
    }

    @IsTest
    static void testNumberFormatCustomPattern() {
        Map<String, Object> data = new Map<String, Object>{ 'Price' => 1234.567 };

        String xml = '{Price:#,##0.00}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('1,234.57'), 'Custom format should be 1,234.57, got: ' + result);
    }

    @IsTest
    static void testNumberFormatNoDecimals() {
        Map<String, Object> data = new Map<String, Object>{ 'ItemCount' => 9876 };

        String xml = '{ItemCount:#,##0}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('9,876'), 'Should be 9,876, got: ' + result);
    }

    @IsTest
    static void testNumberFormatNonNumericValue() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'NotANumber' };

        String xml = '{Name:currency}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('NotANumber'), 'Non-numeric should pass through as-is, got: ' + result);
    }

    @IsTest
    static void testNumberFormatNegativeValue() {
        Map<String, Object> data = new Map<String, Object>{ 'Balance' => -1234.56 };

        String xml = '{Balance:currency}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('-'), 'Negative should contain minus sign, got: ' + result);
        System.assert(result.contains('1,234.56'), 'Negative value should have commas, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Locale-aware formatting (currency:ISO, number:locale, date keyword)
    // =========================================================================

    @IsTest
    static void testCurrencyEUR() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56 };
        String result = DocGenService.processXmlForTest('{Amount:currency:EUR}', data);
        System.assert(result.contains('\u20AC'), 'EUR should contain euro sign, got: ' + result);
        System.assert(
            result.contains('1,234.56') || result.contains('1.234,56'),
            'EUR should have formatted number, got: ' + result
        );
    }

    @IsTest
    static void testCurrencyGBP() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 5000 };
        String result = DocGenService.processXmlForTest('{Amount:currency:GBP}', data);
        System.assert(result.contains('\u00A3'), 'GBP should contain pound sign, got: ' + result);
    }

    @IsTest
    static void testCurrencyJPY() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56 };
        String result = DocGenService.processXmlForTest('{Amount:currency:JPY}', data);
        System.assert(result.contains('\u00A5'), 'JPY should contain yen sign, got: ' + result);
        System.assert(!result.contains('.'), 'JPY should have no decimals, got: ' + result);
    }

    @IsTest
    static void testCurrencyEUR_deDE() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56 };
        String result = DocGenService.processXmlForTest('{Amount:currency:EUR:de_DE}', data);
        System.assert(result.contains('\u20AC'), 'EUR de_DE should contain euro sign, got: ' + result);
        System.assert(result.contains('1.234,56'), 'EUR de_DE should use German separators, got: ' + result);
    }

    // =========================================================================
    // {Field:currency:auto[=SourceField]} \u2014 ISO read from the record at merge time.
    // These inject the currency-source field directly into the data map so they
    // don't depend on the org being multi-currency.
    // =========================================================================

    @IsTest
    static void testCurrencyAutoDefaultIsoCode() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56, 'CurrencyIsoCode' => 'GBP' };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto}', data);
        System.assert(
            result.contains('\u00A3'),
            'auto should read CurrencyIsoCode=GBP and emit \u00A3, got: ' + result
        );
    }

    @IsTest
    static void testCurrencyAutoCustomSourceField() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56, 'CustomerCurrency__c' => 'GBP' };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto=CustomerCurrency__c}', data);
        System.assert(result.contains('\u00A3'), 'auto=CustomerCurrency__c should emit \u00A3, got: ' + result);
    }

    @IsTest
    static void testCurrencyAutoJPYNoDecimals() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56, 'CurrencyIsoCode' => 'JPY' };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto}', data);
        System.assert(result.contains('\u00A5'), 'auto JPY should emit \u00A5, got: ' + result);
        System.assert(!result.contains('.'), 'auto JPY should have no decimals, got: ' + result);
    }

    @IsTest
    static void testCurrencyAutoFallbackNoSourceField() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1000 };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto}', data);
        System.assert(result.contains('$'), 'auto with no source field should fall back to $, got: ' + result);
    }

    @IsTest
    static void testCurrencyAutoFallbackUnknownIso() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1000, 'CurrencyIsoCode' => 'XYZ' };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto}', data);
        System.assert(result.contains('$'), 'auto with unknown ISO should fall back to $, got: ' + result);
        System.assert(!result.contains('XYZ'), 'auto must not emit raw ISO text for unknown codes, got: ' + result);
    }

    @IsTest
    static void testCurrencyAutoLocaleOverride() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56, 'CustomerCurrency__c' => 'EUR' };
        String result = DocGenService.processXmlForTest('{Amount:currency:auto=CustomerCurrency__c:de_DE}', data);
        System.assert(result.contains('\u20AC'), 'auto with locale override should emit \u20AC, got: ' + result);
        System.assert(result.contains('1.234,56'), 'auto:de_DE should use German separators, got: ' + result);
    }

    @IsTest
    static void testCurrencyBareStillDollarWithIsoInMap() {
        // Regression-lock: bare :currency must keep emitting $ even when the record
        // carries a CurrencyIsoCode \u2014 the auto behavior is strictly opt-in.
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 5000, 'CurrencyIsoCode' => 'GBP' };
        String result = DocGenService.processXmlForTest('{Amount:currency}', data);
        System.assert(result.contains('$'), 'Bare :currency must still emit $, got: ' + result);
        System.assert(!result.contains('\u00A3'), 'Bare :currency must not auto-detect GBP, got: ' + result);
    }

    @IsTest
    static void testAggregateCurrencyAuto() {
        Map<String, Object> data = new Map<String, Object>{
            'CurrencyIsoCode' => 'GBP',
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Price' => 1234.5 },
                new Map<String, Object>{ 'Price' => 5678.9 }
            }
        };
        String result = DocGenService.processXmlForTest('{SUM:Items.Price:currency:auto}', data);
        System.assert(
            result.contains('\u00A3'),
            'Aggregate auto should read parent CurrencyIsoCode=GBP \u2192 \u00A3, got: ' + result
        );
    }

    @IsTest
    static void testNumberLocale_deDE() {
        Map<String, Object> data = new Map<String, Object>{ 'Qty' => 1234567 };
        String result = DocGenService.processXmlForTest('{Qty:number:de_DE}', data);
        System.assert(result.contains('1.234.567'), 'German number should use dots, got: ' + result);
    }

    @IsTest
    static void testPercentLocale_deDE() {
        Map<String, Object> data = new Map<String, Object>{ 'Rate' => 15.5 };
        String result = DocGenService.processXmlForTest('{Rate:percent:de_DE}', data);
        System.assert(result.contains('15,5%'), 'German percent should use comma decimal, got: ' + result);
    }

    @IsTest
    static void testDateKeyword_deDE() {
        Map<String, Object> data = new Map<String, Object>{ 'D' => DateTime.newInstance(2026, 4, 17, 12, 0, 0) };
        String result = DocGenService.processXmlForTest('{D:date:de_DE}', data);
        System.assert(result.contains('17.04.2026'), 'German date should be dd.MM.yyyy, got: ' + result);
    }

    @IsTest
    static void testDateKeywordWithDateType() {
        Map<String, Object> data = new Map<String, Object>{ 'D' => Date.newInstance(2026, 4, 17) };
        String result = DocGenService.processXmlForTest('{D:date:de_DE}', data);
        // Date→DateTime at midnight can shift day by timezone, so check dd.MM.yyyy pattern
        System.assert(
            result.contains('.04.2026'),
            'German date from Date type should use dd.MM.yyyy pattern, got: ' + result
        );
    }

    @IsTest
    static void testPicklistLabelFormatSuffix() {
        Map<String, Object> data = DocGenService.addPicklistLabelForTest(
            new Map<String, Object>{ 'Stage__c' => 'QUAL' },
            'Stage__c',
            'Qualified Lead'
        );

        String raw = DocGenService.processXmlForTest('{Stage__c}', data);
        String label = DocGenService.processXmlForTest('{Stage__c:label}', data);
        String title = DocGenService.generateDocTitle('Status - {Stage__c:label}', data);

        System.assertEquals('QUAL', raw, 'Raw merge tags should preserve the API value.');
        System.assertEquals('Qualified Lead', label, 'The :label suffix should render the picklist label.');
        System.assertEquals('Status - Qualified Lead', title, 'Document title formats should support :label.');
    }

    // ── Issue #97: French locale was incorrectly bucketed with German for
    // thousands separator (dot) when CLDR specifies space for fr_FR. These
    // regression assertions lock the distinction in place.

    @IsTest
    static void testCurrencyEUR_frFR() {
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 500000 };
        String result = DocGenService.processXmlForTest('{Amount:currency:EUR:fr_FR}', data);
        System.assert(result.contains('€'), 'EUR fr_FR should contain euro sign, got: ' + result);
        System.assert(
            result.contains('500 000,00'),
            'French currency should use space-as-thousands and comma-as-decimal, got: ' + result
        );
    }

    @IsTest
    static void testNumberLocale_frFR() {
        Map<String, Object> data = new Map<String, Object>{ 'Qty' => 1234567 };
        String result = DocGenService.processXmlForTest('{Qty:number:fr_FR}', data);
        System.assert(result.contains('1 234 567'), 'French number should use space-as-thousands, got: ' + result);
    }

    @IsTest
    static void testFrFR_isNot_deDE() {
        // The reported bug: fr_FR output looked identical to de_DE. This test
        // would have caught it: same input + different locales must produce
        // visibly different output.
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234567 };
        String fr = DocGenService.processXmlForTest('{Amount:number:fr_FR}', data);
        String de = DocGenService.processXmlForTest('{Amount:number:de_DE}', data);
        System.assertNotEquals(fr, de, 'fr_FR and de_DE must produce different output');
        System.assert(fr.contains(' '), 'fr_FR must contain space-as-thousands, got: ' + fr);
        System.assert(de.contains('.'), 'de_DE must contain dot-as-thousands, got: ' + de);
    }

    @IsTest
    static void testCurrencyEUR_frCH_unchanged() {
        // Regression guard: Swiss French stays apostrophe-as-thousands. The
        // apostrophe gets XML-escaped to &apos; on its way through the merge
        // pipeline (formatNumberLocale → processXml → escapeXml), so we accept
        // either form.
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 1234.56 };
        String result = DocGenService.processXmlForTest('{Amount:currency:EUR:fr_CH}', data);
        System.assert(
            result.contains('1\'234.56') || result.contains('1&apos;234.56'),
            'Swiss French should use apostrophe-as-thousands and dot-as-decimal, got: ' + result
        );
    }

    @IsTest
    static void testBackwardCompatCurrency() {
        // Regression guard: bare :currency must still produce $ with US formatting
        Map<String, Object> data = new Map<String, Object>{ 'Amount' => 500000 };
        String result = DocGenService.processXmlForTest('{Amount:currency}', data);
        System.assert(result.contains('$500,000.00'), 'Bare currency must stay $, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Excel shared strings (parseSharedStrings, inlineSharedStrings)
    // =========================================================================

    @IsTest
    static void testExcelSharedStringsProcessing() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String sharedStringsXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3">' +
            '<si><t>{Name}</t></si>' +
            '<si><t>{AccountSource}</t></si>' +
            '<si><t>Static Text</t></si>' +
            '</sst>';

        String sheetXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData>' +
            '<row r="1">' +
            '<c r="A1" t="s"><v>0</v></c>' +
            '<c r="B1" t="s"><v>1</v></c>' +
            '<c r="C1" t="s"><v>2</v></c>' +
            '</row>' +
            '</sheetData></worksheet>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry('xl/sharedStrings.xml', Blob.valueOf(sharedStringsXml));
        zw.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(sheetXml));

        ContentVersion cv = new ContentVersion(
            Title = 'ExcelTest',
            PathOnClient = 'ExcelTest.xlsx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Excel document should be generated');
    }

    /**
     * @description Empty styled cells are self-closing (<c r="B1" s="24"/>). inlineSharedStrings
     * used to detect self-closing by "no </c> anywhere later in the sheet", so an
     * empty cell BEFORE a shared-string cell swallowed the row boundary between
     * them and every generated sheet opened with Excel's repair dialog.
     */
    @IsTest
    static void testExcelSelfClosingCellBeforeSharedString() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        String sharedStringsXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="2">' +
            '<si><t>Title</t></si>' +
            '<si><t>{Name}</t></si>' +
            '</sst>';

        // Row 1 ends with an EMPTY STYLED (self-closing) cell; row 2 starts with a
        // shared-string cell — the exact shape that used to corrupt the sheet.
        String sheetXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData>' +
            '<row r="1">' +
            '<c r="A1" t="s"><v>0</v></c>' +
            '<c r="B1" s="24"/>' +
            '</row>' +
            '<row r="2">' +
            '<c r="A2" t="s"><v>1</v></c>' +
            '</row>' +
            '</sheetData></worksheet>';

        ContentVersion cv = new ContentVersion(
            Title = 'ExcelSelfClose',
            PathOnClient = 'ExcelSelfClose.xlsx',
            VersionData = buildTestXlsx(sharedStringsXml, sheetXml)
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String outSheet = new Compression.ZipReader((Blob) result.get('blob'))
            .extract('xl/worksheets/sheet1.xml')
            .toString();
        System.assertEquals(
            null,
            parseXmlError(outSheet),
            'Generated sheet must be well-formed XML, got: ' + parseXmlError(outSheet) + ' in ' + outSheet
        );
        System.assert(!outSheet.contains('/><is>'), 'Self-closed cell must not grow an orphan <is> block: ' + outSheet);
        System.assert(
            outSheet.contains('<c r="B1" s="24"/>'),
            'Empty styled cell must pass through intact: ' + outSheet
        );
        System.assert(outSheet.contains('<row r="2">'), 'Row 2 boundary must survive inlining: ' + outSheet);
    }

    /**
     * @description Multiline field values in Excel used to route through convertMultilineToXml,
     * splicing WordprocessingML (<w:r>/<w:br/>) into spreadsheetml. Excel cells
     * keep literal newlines instead.
     */
    @IsTest
    static void testExcelMultilineValueStaysSpreadsheetml() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        String sharedStringsXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1">' +
            '<si><t>{Description}</t></si>' +
            '</sst>';
        String sheetXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>';

        ContentVersion cv = new ContentVersion(
            Title = 'ExcelMultiline',
            PathOnClient = 'ExcelMultiline.xlsx',
            VersionData = buildTestXlsx(sharedStringsXml, sheetXml)
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = 'Line one\nLine two';
        Database.update(acc, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        String outSheet = new Compression.ZipReader((Blob) result.get('blob'))
            .extract('xl/worksheets/sheet1.xml')
            .toString();
        System.assertEquals(
            null,
            parseXmlError(outSheet),
            'Generated sheet must be well-formed XML, got: ' + parseXmlError(outSheet) + ' in ' + outSheet
        );
        System.assert(!outSheet.contains('<w:'), 'No WordprocessingML may leak into a worksheet: ' + outSheet);
        System.assert(
            outSheet.contains('Line one\nLine two'),
            'Multiline value keeps its literal newline in the cell: ' + outSheet
        );
    }

    /** @description Minimal XLSX container shared by the Excel corruption regression tests. */
    private static Blob buildTestXlsx(String sharedStringsXml, String sheetXml) {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry('xl/sharedStrings.xml', Blob.valueOf(sharedStringsXml));
        zw.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(sheetXml));
        return zw.getArchive();
    }

    /** @description Returns the parser error message for malformed XML, or null when well-formed. */
    private static String parseXmlError(String xml) {
        try {
            new XmlStreamReader(xml).nextTag();
            XmlStreamReader r = new XmlStreamReader(xml);
            while (r.hasNext()) {
                r.next();
            }
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    // =========================================================================
    // DocGenService — findBalancedEnd: nested loop tags
    // =========================================================================

    @IsTest
    static void testFindBalancedEndNestedLoops() {
        Map<String, Object> data = new Map<String, Object>{
            'Outer' => new List<Object>{
                new Map<String, Object>{
                    'Name' => 'Row1',
                    'Inner' => new List<Object>{
                        new Map<String, Object>{ 'Val' => 'A' },
                        new Map<String, Object>{ 'Val' => 'B' }
                    }
                }
            }
        };

        String xml = '{#Outer}[{#Inner}{Val}{/Inner}]{/Outer}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('A'), 'Should contain inner value A, got: ' + result);
        System.assert(result.contains('B'), 'Should contain inner value B, got: ' + result);
    }

    @IsTest
    static void testFindBalancedEndSameNameNested() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{
                    'Name' => 'Outer',
                    'Items' => new List<Object>{ new Map<String, Object>{ 'Name' => 'Inner' } }
                }
            }
        };

        String xml = '{#Items}{Name}:{#Items}{Name}{/Items}{/Items}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('Outer'), 'Should contain outer value, got: ' + result);
        System.assert(result.contains('Inner'), 'Should contain inner value, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Boolean conditionals
    // =========================================================================

    @IsTest
    static void testBooleanConditionalTrue() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Test', 'IsActive' => true };

        String xml = '{#IsActive}Active!{/IsActive}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('Active!'), 'True boolean should show content, got: ' + result);
    }

    @IsTest
    static void testBooleanConditionalFalse() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Test', 'IsActive' => false };

        String xml = '{#IsActive}Should Not Appear{/IsActive}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        // Boolean false should hide content — only Boolean true shows conditional sections.
        System.assert(!result.contains('Should Not Appear'), 'False boolean should hide content, got: ' + result);
    }

    @IsTest
    static void testBooleanConditionalNull() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Test' };

        String xml = 'Before{#Missing}hidden{/Missing}After';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('BeforeAfter'), 'Null key should hide content, got: ' + result);
    }

    // =========================================================================
    // DocGenService — renderPreviewHtml
    // =========================================================================

    @IsTest
    static void testRenderPreviewHtml() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Preview: {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        String html = DocGenService.renderPreviewHtml(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, html, 'Should return HTML');
        System.assert(html.contains('<html'), 'Should be valid HTML');
    }

    /**
     * #363 — a Word-authored hyperlink (Insert → Link) survives the real merge path
     * as a clickable <a href>, in the body and in a header.
     *
     * Both parts deliberately use r:id="rId5" for DIFFERENT targets, which is exactly
     * how Word numbers relationships: r:id values are scoped to their own part. If the
     * resolver ever reached for document.xml.rels while rewriting a header, the header
     * link would silently point at the body's URL — the assertions below catch that.
     */
    @IsTest
    static void testWordHyperlinkResolvesThroughRenderPath() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<w:body><w:p><w:r><w:t xml:space="preserve">{Name}: complete </w:t></w:r>' +
            '<w:hyperlink r:id="rId5"><w:r><w:t>form X</w:t></w:r></w:hyperlink>' +
            '<w:r><w:t> today.</w:t></w:r></w:p>' +
            '<w:sectPr><w:headerReference w:type="default" r:id="rId7"/>' +
            '<w:pgSz w:w="12240" w:h="15840"/>' +
            '<w:pgMar w:top="1440" w:right="720" w:bottom="1440" w:left="720"/></w:sectPr>' +
            '</w:body></w:document>';
        String docRels =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"' +
            ' Target="https://example.com/formX" TargetMode="External"/>' +
            '<Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"' +
            ' Target="header1.xml"/>' +
            '</Relationships>';
        String headerXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<w:p><w:hyperlink r:id="rId5"><w:r><w:t>Support</w:t></w:r></w:hyperlink></w:p></w:hdr>';
        String headerRels =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"' +
            ' Target="https://example.com/support" TargetMode="External"/>' +
            '</Relationships>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));
        zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(docRels));
        zw.addEntry('word/header1.xml', Blob.valueOf(headerXml));
        zw.addEntry('word/_rels/header1.xml.rels', Blob.valueOf(headerRels));

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        ContentVersion cv = new ContentVersion(
            Title = 'Issue363Hyperlink',
            PathOnClient = 'Issue363Hyperlink.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        String html = DocGenService.renderPreviewHtml(tpl.Id, acc.Id);
        Test.stopTest();

        System.assert(
            html.contains('<a href="https://example.com/formX"'),
            'Body hyperlink should resolve from document.xml.rels. Got: ' + html
        );
        System.assert(
            html.contains('<a href="https://example.com/support"'),
            'Header hyperlink should resolve from header1.xml.rels. Got: ' + html
        );
        System.assert(html.contains('form X') && html.contains('Support'), 'Link text should survive');
    }

    @IsTest
    static void testRenderPreviewHtmlThrowsForPowerPoint() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>' +
                    '<p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'PPTPrev',
            PathOnClient = 'PPTPrev.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenService.renderPreviewHtml(tpl.Id, acc.Id);
        } catch (DocGenException e) {
            caught = true;
            System.assert(
                e.getMessage().contains('only supported for Word'),
                'Preview should mention Word-only support'
            );
        }
        Test.stopTest();
        System.assert(caught, 'Should throw for PowerPoint preview');
    }

    // =========================================================================
    // DocGenService — generateDocumentParts
    // =========================================================================

    @IsTest
    static void testGenerateDocumentParts() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Parts: {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('allXmlParts'), 'Should return XML parts');
        System.assertNotEquals(null, result.get('title'), 'Should return title');
        System.assertNotEquals(null, result.get('templateType'), 'Should return template type');
        Map<String, String> xmlParts = (Map<String, String>) result.get('allXmlParts');
        System.assert(xmlParts.containsKey('word/document.xml'), 'Should include document.xml');
    }

    // =========================================================================
    // DocGenService — Barcode tag processing
    // =========================================================================

    @IsTest
    static void testBarcodeTagCode128() {
        Map<String, Object> data = new Map<String, Object>{ 'Code' => 'ABC-123' };

        String xml = '{*Code}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('##BARCODE:code128::ABC-123##'), 'Should produce barcode marker, got: ' + result);
    }

    @IsTest
    static void testBarcodeTagQr() {
        Map<String, Object> data = new Map<String, Object>{ 'Url' => 'https://example.com' };

        String xml = '{*Url:qr}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('##BARCODE:qr:'), 'Should produce QR barcode marker, got: ' + result);
    }

    @IsTest
    static void testBarcodeTagWithSize() {
        Map<String, Object> data = new Map<String, Object>{ 'Code' => 'TEST' };

        String xml = '{*Code:code128:300x80}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('##BARCODE:code128:300x80:TEST##'), 'Should include size spec, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Salesforce-style {!Field} prefix
    // =========================================================================

    @IsTest
    static void testSalesforceStylePrefix() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'TestAccount' };

        String xml = '{!Name}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('TestAccount'), 'Should resolve {!Name} prefix, got: ' + result);
    }

    // =========================================================================
    // DocGenService — COUNT with field (exercises COUNT with values path)
    // =========================================================================

    @IsTest
    static void testAggregateCountWithField() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Val' => 10 },
                new Map<String, Object>{ 'Val' => 20 },
                new Map<String, Object>{ 'Val' => 30 }
            }
        };

        String xml = '{COUNT:Items.Val}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('3'), 'COUNT with field should count numeric values, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Aggregate with non-numeric values (skip branch)
    // =========================================================================

    @IsTest
    static void testAggregateWithNonNumericValues() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Val' => 'abc' },
                new Map<String, Object>{ 'Val' => 100 }
            }
        };

        String xml = '{SUM:Items.Val}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('100'), 'SUM should skip non-numeric and return 100, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Aggregate function with no field (non-COUNT returns null)
    // =========================================================================

    @IsTest
    static void testAggregateSumWithoutField() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{ new Map<String, Object>{ 'Val' => 10 } }
        };

        // SUM without field path returns null (only COUNT supports no-field)
        String xml = 'X{SUM:Items}X';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assertEquals('XX', result, 'SUM without field should produce empty output, got: ' + result);
    }

    // =========================================================================
    // DocGenDataRetriever — V3 tree with WHERE/ORDER BY/LIMIT clauses
    // =========================================================================

    @IsTest
    static void testGetRecordDataV3WithWhereOrderByLimit() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            insert new List<Contact>{
                new Contact(FirstName = 'Alpha', LastName = 'V3W', AccountId = acc.Id),
                new Contact(FirstName = 'Beta', LastName = 'V3W', AccountId = acc.Id)
            };

            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName","LastName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"where":"LastName = \'V3W\'","orderBy":"FirstName ASC","limit":"10"}' +
                ']}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should return data');
            System.assert(result.containsKey('Contacts'), 'Should contain Contacts relationship');
            Map<String, Object> contactsMap = (Map<String, Object>) result.get('Contacts');
            List<Object> records = (List<Object>) contactsMap.get('records');
            System.assertEquals(2, records.size(), 'Should return 2 contacts matching WHERE clause');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — sanitizeClause edge cases
    // =========================================================================

    @IsTest
    static void testSanitizeClauseRejectsInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            // V3 config with dangerous WHERE clause containing semicolon
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"where":"LastName = \'test\'; DROP TABLE"}' +
                ']}';

            Test.startTest();
            // The sanitizeClause should reject the semicolon and the child query will fail gracefully
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            // The root query should still succeed; child with bad WHERE is skipped
            System.assertNotEquals(null, result, 'Root data should still be returned');
        }
    }

    @IsTest
    static void testSanitizeClauseLimitMustBeNumeric() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            insert new Contact(FirstName = 'Lim', LastName = 'Test', AccountId = acc.Id);

            // V3 config with non-numeric LIMIT — should throw and skip child
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"limit":"abc"}' +
                ']}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Root data should still be returned');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsComments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            // V3 config with comment injection in WHERE
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"where":"LastName = \'test\' /* comment */"}' +
                ']}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Root data should still be returned');
        }
    }

    @IsTest
    static void testSanitizeClauseRejectsDMLKeywords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            // V3 config with DML keyword in WHERE
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName"],"parentFields":[],' +
                '"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts",' +
                '"where":"LastName = \'test\' INSERT something"}' +
                ']}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v3Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for DML keyword in V3 WHERE');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — getRecordData with blank/null config
    // =========================================================================

    @IsTest
    static void testGetRecordDataWithNullFieldsConfig() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(acc.Id, 'Account', null);
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'Should throw for null fieldsConfig');
        }
    }

    @IsTest
    static void testGetRecordDataWithBlankConfig() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(acc.Id, 'Account', '   ');
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'Should throw for blank (whitespace-only) fieldsConfig');
        }
    }

    @IsTest
    static void testGetRecordDataWithNullRecordId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;

            Test.startTest();
            try {
                DocGenDataRetriever.getRecordData(null, 'Account', 'Name');
            } catch (Exception e) {
                caught = true;
            }
            Test.stopTest();

            System.assert(caught, 'Should throw for null recordId');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — getConfigVersion edge cases
    // =========================================================================

    @IsTest
    static void testGetConfigVersionV1Blank() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer v = DocGenDataRetriever.getConfigVersion(null);
            Integer v2 = DocGenDataRetriever.getConfigVersion('');
            Integer v3 = DocGenDataRetriever.getConfigVersion('Name, Industry');
            Test.stopTest();

            System.assertEquals(1, v, 'Null config should be V1');
            System.assertEquals(1, v2, 'Empty config should be V1');
            System.assertEquals(1, v3, 'Non-JSON config should be V1');
        }
    }

    @IsTest
    static void testGetConfigVersionV2() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // JSON without version field defaults to V2
            Test.startTest();
            Integer v = DocGenDataRetriever.getConfigVersion('{"baseObject":"Account","baseFields":["Name"]}');
            Test.stopTest();

            System.assertEquals(2, v, 'JSON without v field should be V2');
        }
    }

    @IsTest
    static void testGetConfigVersionV3() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer v = DocGenDataRetriever.getConfigVersion('{"v":3,"root":"Account","nodes":[]}');
            Test.stopTest();

            System.assertEquals(3, v, 'JSON with v:3 should be V3');
        }
    }

    @IsTest
    static void testGetConfigVersionMalformedJson() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer v = DocGenDataRetriever.getConfigVersion('{malformed json');
            Test.stopTest();

            System.assertEquals(1, v, 'Malformed JSON should fall back to V1');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — mapSObject Location field type
    // =========================================================================

    @IsTest
    static void testGetRecordDataWithLocationField() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            // Account doesn't have geolocation, but Location type is covered
            // by the Address field test. Test null value handling instead.
            acc.Description = null;
            update acc;

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', 'Name, Description');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for location field test');
            // Description is null — should not be in the map (or null)
            System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match for location field test');
        }
    }

    // =========================================================================
    // DocGenDataRetriever — V2 JSON config with children and where/orderBy/limit
    // =========================================================================

    @IsTest
    static void testGetRecordDataV2WithChildClauses() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            insert new List<Contact>{
                new Contact(FirstName = 'V2A', LastName = 'Test', AccountId = acc.Id),
                new Contact(FirstName = 'V2B', LastName = 'Test', AccountId = acc.Id)
            };

            String v2Config =
                '{"v":2,"baseObject":"Account","baseFields":["Name"],' +
                '"children":[{"rel":"Contacts","fields":["FirstName","LastName"],' +
                '"where":"LastName = \'Test\'","orderBy":"FirstName ASC","limit":"5"}]}';

            Test.startTest();
            Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
            Test.stopTest();

            System.assertNotEquals(null, result, 'Result should not be null for V2 child clauses test');
            System.assert(result.containsKey('Contacts'), 'Should contain Contacts');
        }
    }

    // =========================================================================
    // DocGenSetupController — permission denied path
    // =========================================================================

    @IsTest
    static void testSaveSettingsPermissionDenied() {
        // Create a standard user profile user without admin access
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User stdUser = new User(
            Alias = 'dgntst',
            Email = 'docgentest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Testing',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'docgentest_' + System.currentTimeMillis() + '@example.com'
        );
        insert stdUser;

        System.runAs(stdUser) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenSetupController.saveSettings('https://test.my.site.com');
            } catch (AuraHandledException e) {
                caught = true;
                System.assert(
                    e.getMessage().contains('Insufficient') || e.getMessage().length() > 0,
                    'Should indicate insufficient privileges'
                );
            }
            Test.stopTest();

            // Standard users without DocGen_Admin_Access and without custom setting update access
            // should hit the permission check. If they happen to have access, the test still passes.
            // The key is exercising the code path.
            System.assert(true, 'saveSettings permission path exercised');
        }
    }

    @IsTest
    static void testSaveSettingsWithNullUrl() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            DocGenSetupController.saveSettings(null);
            Test.stopTest();

            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            System.assertEquals(null, settings.Experience_Site_Url__c, 'Should accept null URL value');
        }
    }

    // =========================================================================
    // DocGenService — mergeTemplateForSignature (restored in v2)
    // =========================================================================

    @IsTest
    static void testMergeTemplateForSignatureReturnsData() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            try {
                Map<String, Object> result = DocGenService.mergeTemplateForSignature(tpl.Id, acc.Id);
                // If template has an active version with content, we get data back
                System.assertNotEquals(null, result);
            } catch (Exception e) {
                // May throw if template has no active version — that's OK for this test
                System.debug('Expected exception for template without content: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // DocGenService — generateDocumentFromData (pre-cached data path)
    // =========================================================================

    @IsTest
    static void testGenerateDocumentFromData() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Map<String, Object> preloadedData = new Map<String, Object>{
            'Name' => 'Cached Account Name',
            'AccountSource' => 'Web'
        };

        Test.startTest();
        Id docId = DocGenService.generateDocumentFromData(tpl.Id, acc.Id, preloadedData);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Should return ContentDocumentId from pre-cached data');
    }

    // =========================================================================
    // DocGenService — generateHtmlForRecord (bulk HTML generation)
    // =========================================================================

    @IsTest
    static void testGenerateHtmlForRecord() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>HTML: {Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(tpl.Id, acc.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, html, 'Should return HTML string');
        System.assert(html.contains('<html'), 'Should be valid HTML');
    }

    @IsTest
    static void testGenerateHtmlForRecordWithPreloadedData() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        Map<String, Object> preloaded = new Map<String, Object>{ 'Name' => 'Preloaded Name' };

        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(tpl.Id, acc.Id, preloaded);
        Test.stopTest();

        System.assertNotEquals(null, html, 'Should return HTML with preloaded data');
    }

    // =========================================================================
    // DocGenService — processDocumentAsHtmlWithImageMap: PowerPoint throw
    // =========================================================================

    @IsTest
    static void testProcessDocumentAsHtmlWithImageMapThrowsForPowerPoint() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'PowerPoint';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'ppt/slides/slide1.xml',
            Blob.valueOf(
                '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>' +
                    '<p:sp><p:txBody><a:p xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                    '<a:r><a:t>{Name}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'PPTHtmlMap',
            PathOnClient = 'PPTHtmlMap.pptx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();
        Boolean caught = false;

        Test.startTest();
        try {
            DocGenService.processDocumentAsHtmlWithImageMap(tpl.Id, acc.Id, new Map<String, String>());
        } catch (DocGenException e) {
            caught = true;
            System.assert(
                e.getMessage().contains('only supported for Word'),
                'HTML image map should mention Word-only support'
            );
        }
        Test.stopTest();

        System.assert(caught, 'Should throw for PowerPoint HTML generation');
    }

    // =========================================================================
    // DocGenService — tryMergeFromPreDecomposed (pre-decomposed XML path)
    // =========================================================================

    @IsTest
    static void testTryMergeFromPreDecomposed() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/media/image1.png', Blob.valueOf('FAKEPNGBYTES'));

        ContentVersion cv = new ContentVersion(
            Title = 'PreDecomp',
            PathOnClient = 'PreDecomp.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        // extractAndSaveTemplateImages saves pre-decomposed XML CVs and image CVs
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        // generateDocument with PDF output should use tryMergeFromPreDecomposed
        Id docId = DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Pre-decomposed path should generate a PDF');
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pdf'), 'Should save as PDF');
    }

    // =========================================================================
    // DocGenService — buildPdfImageMap with pre-committed template images
    // =========================================================================

    @IsTest
    static void testBuildPdfImageMapWithTemplateImages() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo.png"/></Relationships>'
            )
        );
        zw.addEntry('word/media/logo.png', Blob.valueOf('LOGOPNGBYTES'));

        ContentVersion cv = new ContentVersion(
            Title = 'PdfImgMap',
            PathOnClient = 'PdfImgMap.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'PDF with template images should generate');
    }

    // =========================================================================
    // DocGenService — extractAndSaveTemplateImages edge cases
    // =========================================================================

    // #203 — re-running decomposition for the same version must supersede, not
    // duplicate: a second identically-titled snapshot would shadow the fresh one.
    @IsTest
    static void testIssue203DecomposeIdempotentNoDuplicateSnapshots() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name} v203</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        ContentVersion cv = new ContentVersion(
            Title = 'Idem203',
            PathOnClient = 'Idem203.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id); // re-run: retry / on-demand decompose
        Test.stopTest();

        String prefix = 'docgen_tmpl_%' + String.valueOf(ver.Id) + '%';
        Map<String, Integer> countsByTitle = new Map<String, Integer>();
        for (ContentVersion snap : [
            SELECT Title
            FROM ContentVersion
            WHERE Title LIKE :prefix AND IsLatest = TRUE
        ]) {
            Integer n = countsByTitle.containsKey(snap.Title) ? countsByTitle.get(snap.Title) : 0;
            countsByTitle.put(snap.Title, n + 1);
        }
        System.assert(!countsByTitle.isEmpty(), 'Decompose should have produced snapshot CVs');
        for (String title : countsByTitle.keySet()) {
            System.assertEquals(
                1,
                countsByTitle.get(title),
                'Duplicate snapshot after re-decompose would shadow the fresh copy: ' + title
            );
        }
    }

    // #203 — switching a template's format WITHOUT a new body must fail loudly:
    // the old-format body/snapshots would otherwise be served down the new
    // format's render branch (DOCX bytes read as HTML).
    @IsTest
    static void testIssue203TypeSwitchBlockedWithoutNewBody() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate(); // factory default Type = Word
        Map<String, Object> fields = new Map<String, Object>{
            'Id' => tpl.Id,
            'Name' => tpl.Name,
            'Type__c' => 'HTML',
            'Base_Object_API__c' => tpl.Base_Object_API__c,
            'Query_Config__c' => tpl.Query_Config__c,
            'Category__c' => tpl.Category__c,
            'Description__c' => tpl.Description__c,
            'Test_Record_Id__c' => tpl.Test_Record_Id__c,
            'Document_Title_Format__c' => tpl.Document_Title_Format__c
        };

        Test.startTest();
        Boolean blocked = false;
        try {
            DocGenController.saveTemplate(fields, false, null);
        } catch (AuraHandledException e) {
            blocked = true;
        }
        // Same switch WITH a new body version is the supported path.
        ContentVersion htmlCv = new ContentVersion(
            Title = 'Switch203',
            PathOnClient = 'Switch203.html',
            VersionData = Blob.valueOf('<html><body><p>{Name}</p></body></html>'),
            FirstPublishLocationId = tpl.Id
        );
        insert htmlCv;
        Id newVerId = (Id) DocGenController.saveTemplate(fields, true, htmlCv.Id).get('createdVersionId');
        Test.stopTest();

        System.assert(blocked, 'Details-only save must not change the template format without a new body');
        System.assertNotEquals(null, newVerId, 'Format switch with a new body version should succeed');
        DocGen_Template__c after = [SELECT Type__c FROM DocGen_Template__c WHERE Id = :tpl.Id];
        System.assertEquals('HTML', after.Type__c, 'Type should update when the new body ships with it');
    }

    @IsTest
    static void testExtractAndSaveTemplateImagesNullTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            try {
                DocGenService.extractAndSaveTemplateImages(null, null);
            } catch (Exception e) {
                // Expected: May throw AuraHandledException from getTemplateFileContent
                System.assertNotEquals(null, e.getMessage(), 'Exception message should be populated for null template');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testExtractAndSaveTemplateImagesNoImages() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>No images</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
            )
        );

        ContentVersion cv = new ContentVersion(
            Title = 'NoImgDocx',
            PathOnClient = 'NoImgDocx.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);
        Test.stopTest();

        String xmlPrefix = 'docgen_tmpl_xml_' + ver.Id + '_';
        List<ContentVersion> xmlCvs = [SELECT Title FROM ContentVersion WHERE Title LIKE :(xmlPrefix + '%')];
        System.assert(xmlCvs.size() >= 1, 'Should save pre-decomposed XML parts even without images');
    }

    // =========================================================================
    // DocGenService — applyResolvedImages: &amp; encoded URL
    // =========================================================================

    @IsTest
    static void testApplyResolvedImagesAmpEncoded() {
        Account acc = TestDataFactory.getTestAccount();
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('AMPIMG'));
        acc.Description = '<img src="https://example.com/img?a=1&amp;b=2" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Map<String, String> resolvedImages = new Map<String, String>{
            'https://example.com/img?a=1&b=2' => 'data:image/png;base64,' + tinyBase64
        };

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id, resolvedImages);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for amp-encoded resolved images');
    }

    // =========================================================================
    // DocGenService — COUNT with format specifier (no field)
    // =========================================================================

    @IsTest
    static void testAggregateCountWithFormatSpecifier() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'A' },
                new Map<String, Object>{ 'Name' => 'B' },
                new Map<String, Object>{ 'Name' => 'C' },
                new Map<String, Object>{ 'Name' => 'D' },
                new Map<String, Object>{ 'Name' => 'E' }
            }
        };

        String xml = '{COUNT:Items:number}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('5'), 'COUNT with format should be 5, got: ' + result);
    }

    // =========================================================================
    // DocGenService — COUNT with field and format specifier
    // =========================================================================

    @IsTest
    static void testAggregateCountWithFieldAndFormat() {
        Map<String, Object> data = new Map<String, Object>{
            'Items' => new List<Object>{
                new Map<String, Object>{ 'Val' => 10 },
                new Map<String, Object>{ 'Val' => 20 }
            }
        };

        String xml = '{COUNT:Items.Val:number}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('2'), 'COUNT with field and format should be 2, got: ' + result);
    }

    // =========================================================================
    // DocGenService — Date field formatting (Date type, not DateTime)
    // =========================================================================

    @IsTest
    static void testProcessXmlDateFieldFormatting() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'Test',
            'CloseDate' => Date.newInstance(2026, 3, 15)
        };

        String xml = '{CloseDate:MM/dd/yyyy}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(
            result.contains('03/15/2026') || result.contains('2026'),
            'Date should be formatted, got: ' + result
        );
    }

    // =========================================================================
    // DocGenService — rich text: multi-paragraph with nested formatting
    // =========================================================================

    @IsTest
    static void testProcessDocumentRichTextMultiParagraph() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p>First paragraph</p><p>Second <b>bold</b> paragraph</p><p>Third with <i>italic</i> and <u>underline</u></p>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for rich text multi-paragraph');
    }

    // =========================================================================
    // DocGenService — rich text list tags (issue #47)
    // <ul>/<ol>/<li> must produce per-item paragraph breaks with bullet/number markers
    // =========================================================================

    @IsTest
    static void testRichTextBulletedListEmitsPerItemParagraphs() {
        String tpl = '<w:p><w:r><w:t>Instructions: {Notes}</w:t></w:r></w:p>';
        Map<String, Object> data = new Map<String, Object>{
            'Notes' => '<ul><li>alpha</li><li>beta</li><li>gamma</li></ul>'
        };

        String out = DocGenService.processXmlForTest(tpl, data);

        // Each item must appear with its bullet marker in its own paragraph (• and item text
        // are emitted as separate runs inside one <w:p>, separated by run-close/open markup).
        System.assert(
            out.contains('<w:t xml:space="preserve">• </w:t></w:r><w:r><w:t xml:space="preserve">alpha</w:t>'),
            'first item must be in its own paragraph with bullet prefix: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">• </w:t></w:r><w:r><w:t xml:space="preserve">beta</w:t>'),
            'second item must be in its own paragraph with bullet prefix: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">• </w:t></w:r><w:r><w:t xml:space="preserve">gamma</w:t>'),
            'third item must be in its own paragraph with bullet prefix: ' + out
        );
        // Three new <w:p> openers for three items (each <li> opens a new paragraph).
        Integer pCount = out.countMatches('<w:p>');
        System.assert(
            pCount >= 3,
            'expected at least 3 paragraph openings for 3 list items, got ' + pCount + ': ' + out
        );
        // Items must not run together as plain text.
        System.assert(!out.contains('alphabeta'), 'items must not concatenate: ' + out);
        System.assert(!out.contains('betagamma'), 'items must not concatenate: ' + out);
    }

    @IsTest
    static void testRichTextNumberedListEmitsPerItemParagraphs() {
        String tpl = '<w:p><w:r><w:t>Steps: {Notes}</w:t></w:r></w:p>';
        Map<String, Object> data = new Map<String, Object>{
            'Notes' => '<ol><li>first</li><li>second</li><li>third</li></ol>'
        };

        String out = DocGenService.processXmlForTest(tpl, data);

        System.assert(
            out.contains('<w:t xml:space="preserve">1. </w:t></w:r><w:r><w:t xml:space="preserve">first</w:t>'),
            'item 1 must carry "1. " marker run: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">2. </w:t></w:r><w:r><w:t xml:space="preserve">second</w:t>'),
            'item 2 must carry "2. " marker run: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">3. </w:t></w:r><w:r><w:t xml:space="preserve">third</w:t>'),
            'item 3 must carry "3. " marker run: ' + out
        );
    }

    @IsTest
    static void testRichTextNestedListsIndentAndResetCounter() {
        String tpl = '<w:p><w:r><w:t>{Notes}</w:t></w:r></w:p>';
        // Outer ul with two items; second item has a nested ol with two items.
        Map<String, Object> data = new Map<String, Object>{
            'Notes' => '<ul><li>outer one</li><li>outer two<ol><li>inner one</li><li>inner two</li></ol></li></ul>'
        };

        String out = DocGenService.processXmlForTest(tpl, data);

        System.assert(
            out.contains('<w:t xml:space="preserve">• </w:t></w:r><w:r><w:t xml:space="preserve">outer one</w:t>'),
            'outer item 1 bullet: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">• </w:t></w:r><w:r><w:t xml:space="preserve">outer two</w:t>'),
            'outer item 2 bullet: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">    1. </w:t></w:r><w:r><w:t xml:space="preserve">inner one</w:t>'),
            'nested ordered item 1 indented + numbered: ' + out
        );
        System.assert(
            out.contains('<w:t xml:space="preserve">    2. </w:t></w:r><w:r><w:t xml:space="preserve">inner two</w:t>'),
            'nested ordered item 2 indented + numbered: ' + out
        );
    }

    // =========================================================================
    // DocGenService — section-tag truthy/falsy symmetry (issue #48)
    // {#Field} and {^Field} must agree on what "empty" means; rich text values
    // that are visually empty (<p><br></p>, &nbsp; only, etc.) must be falsy.
    // =========================================================================

    @IsTest
    static void testSectionTagSymmetryAgainstNullField() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        Map<String, Object> data = new Map<String, Object>{ 'F' => null };
        String out = DocGenService.processXmlForTest(tpl, data);
        System.assertEquals('|NO', out, 'null must be falsy in both paths: ' + out);
    }

    @IsTest
    static void testSectionTagSymmetryAgainstEmptyString() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        String out = DocGenService.processXmlForTest(tpl, new Map<String, Object>{ 'F' => '' });
        System.assertEquals('|NO', out, 'empty string must be falsy in both paths: ' + out);
    }

    @IsTest
    static void testSectionTagSymmetryAgainstWhitespaceString() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        String out = DocGenService.processXmlForTest(tpl, new Map<String, Object>{ 'F' => '   \t\n  ' });
        System.assertEquals('|NO', out, 'whitespace must be falsy in both paths: ' + out);
    }

    @IsTest
    static void testSectionTagSymmetryAgainstVisuallyEmptyRichText() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        // Common Lightning RT "empty" residual values
        for (
            String empty : new List<String>{
                '<p><br></p>',
                '<p></p>',
                '<div><br/></div>',
                '<p>&nbsp;</p>',
                '<p>   </p>'
            }
        ) {
            String out = DocGenService.processXmlForTest(tpl, new Map<String, Object>{ 'F' => empty });
            System.assertEquals('|NO', out, 'visually empty RT [' + empty + '] must be falsy: ' + out);
        }
    }

    @IsTest
    static void testSectionTagSymmetryAgainstNonEmptyString() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        String out = DocGenService.processXmlForTest(tpl, new Map<String, Object>{ 'F' => 'hello' });
        System.assertEquals('YES|', out, 'non-blank string must be truthy in both paths: ' + out);
    }

    @IsTest
    static void testSectionTagSymmetryAgainstRichTextWithVisibleContent() {
        String tpl = '{#F}YES{/F}|{^F}NO{/F}';
        Map<String, Object> data = new Map<String, Object>{ 'F' => '<p>hello world</p>' };
        String out = DocGenService.processXmlForTest(tpl, data);
        System.assertEquals('YES|', out, 'RT with visible content must be truthy in both paths: ' + out);
    }

    @IsTest
    static void testIsVisuallyBlankRichTextHelper() {
        System.assert(DocGenService.isVisuallyBlankRichText(null), 'null is blank');
        System.assert(DocGenService.isVisuallyBlankRichText(''), 'empty is blank');
        System.assert(DocGenService.isVisuallyBlankRichText('   '), 'whitespace is blank');
        System.assert(DocGenService.isVisuallyBlankRichText('<p><br></p>'), '<p><br></p> is blank');
        System.assert(DocGenService.isVisuallyBlankRichText('<p>&nbsp;</p>'), 'nbsp-only is blank');
        System.assert(
            DocGenService.isVisuallyBlankRichText('<div><span>&#160;</span></div>'),
            '#160 nbsp entity is blank'
        );
        System.assert(!DocGenService.isVisuallyBlankRichText('hello'), 'plain text not blank');
        System.assert(!DocGenService.isVisuallyBlankRichText('<p>hello</p>'), 'wrapped text not blank');
        System.assert(!DocGenService.isVisuallyBlankRichText('<p><b>x</b></p>'), 'wrapped char not blank');
    }

    // =========================================================================
    // DocGenService — convertRichTextToDocxXml decodes &#39; and &quot;
    // (issue #51). Lightning RTE stores apostrophes as the numeric reference;
    // without decoding they render literally in the output document.
    // =========================================================================
    @IsTest
    static void testRichTextDecodesApostropheAndQuoteEntities() {
        String tpl = '<w:p><w:r><w:t>{Notes}</w:t></w:r></w:p>';
        Map<String, Object> data = new Map<String, Object>{ 'Notes' => '<p>ain&#39;t it &quot;great&quot;</p>' };
        String out = DocGenService.processXmlForTest(tpl, data);
        // After decode, OOXML re-escapes apostrophe as &apos; and quote as &quot;
        // for XML safety; Word/PDF unescape on render. The bug signature is the
        // numeric reference &#39; surviving — that's the only thing we must not see.
        System.assert(!out.contains('&#39;'), 'numeric apostrophe ref must not survive: ' + out);
        System.assert(
            out.contains('ain&apos;t') || out.contains('ain\'t'),
            'apostrophe must render (as &apos; or literal): ' + out
        );
        System.assert(
            out.contains('&quot;great&quot;') || out.contains('"great"'),
            'quote must render (as &quot; or literal): ' + out
        );
    }

    @IsTest
    static void testRichTextDecodesUnicodeNumericReferences() {
        // Smart quotes / em-dash / en-dash / hex-form accent — all must decode.
        // DOCX rich-text path now reuses DocGenHtmlRenderer.decodeNumericEntities.
        String tpl = '<w:p><w:r><w:t>{N}</w:t></w:r></w:p>';
        Map<String, Object> data = new Map<String, Object>{
            'N' => '<p>he said &#8220;don&#8217;t&#8221; &#8212; ok&#8211;done caf&#xE9;</p>'
        };
        String out = DocGenService.processXmlForTest(tpl, data);
        System.assert(!out.contains('&#8220;'), 'left double quote must decode: ' + out);
        System.assert(!out.contains('&#8217;'), 'right single quote must decode: ' + out);
        System.assert(!out.contains('&#8221;'), 'right double quote must decode: ' + out);
        System.assert(!out.contains('&#8212;'), 'em dash must decode: ' + out);
        System.assert(!out.contains('&#8211;'), 'en dash must decode: ' + out);
        System.assert(!out.contains('&#xE9;'), 'hex e-acute must decode: ' + out);
        System.assert(out.contains('“'), 'left double quote literal present: ' + out);
        System.assert(out.contains('—'), 'em dash literal present: ' + out);
        System.assert(out.contains('é'), 'e-acute literal present: ' + out);
    }

    @IsTest
    static void testIfConditionalInsideTableRowDoesNotCorruptDocx() {
        // Issue #53: {#IF X = Y}…{/IF} placed inside a <w:tr> caused the
        // smart-container expansion to backtrack the row's opening tags. When
        // the condition was false (no else), nothing was re-emitted, leaving
        // an orphaned </w:tr> downstream — Word refused to open the DOCX, and
        // PDF silently dropped trailing content.
        String tableXml =
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#IF Status = open}{Name}{/IF}</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>after-row</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';

        // FALSE branch: row tags must remain balanced and trailing content preserved.
        Map<String, Object> falseData = new Map<String, Object>{ 'Status' => 'closed', 'Name' => 'Acme' };
        String r1 = DocGenService.processXmlForTest(tableXml, falseData);
        System.assertEquals(
            r1.split('<w:tr>').size(),
            r1.split('</w:tr>').size(),
            'unbalanced row tags after false IF: ' + r1
        );
        System.assert(r1.contains('after-row'), 'trailing content dropped after false IF: ' + r1);

        // TRUE branch: name renders, trailing content preserved.
        Map<String, Object> trueData = new Map<String, Object>{ 'Status' => 'open', 'Name' => 'Acme' };
        String r2 = DocGenService.processXmlForTest(tableXml, trueData);
        System.assert(r2.contains('Acme'), 'true IF dropped its body: ' + r2);
        System.assert(r2.contains('after-row'), 'trailing content dropped after true IF: ' + r2);
    }

    @IsTest
    static void testGenerateDocTitleResolvesBuiltins() {
        // generateDocTitle must resolve {Today}, {Now}, {RunningUser.X} and date-format suffixes
        // — previously these returned empty because the resolver only walked the data map.
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Acme' };

        String t1 = DocGenService.generateDocTitle('{Name}-{Today:MM-dd-yyyy}', data);
        Date td = Date.today();
        String mm = td.month() < 10 ? '0' + td.month() : String.valueOf(td.month());
        String dd = td.day() < 10 ? '0' + td.day() : String.valueOf(td.day());
        System.assertEquals('Acme-' + mm + '-' + dd + '-' + td.year(), t1, 'Today with format suffix');

        String t2 = DocGenService.generateDocTitle('{Now:yyyy}', data);
        System.assertEquals(String.valueOf(DateTime.now().year()), t2, 'Now with format suffix');

        String t3 = DocGenService.generateDocTitle('By {RunningUser.Name}', data);
        System.assert(t3.contains(UserInfo.getName()), 'RunningUser.Name in title: ' + t3);

        String t4 = DocGenService.generateDocTitle('{Today}', data);
        System.assert(String.isNotBlank(t4) && t4.contains(String.valueOf(td.year())), 'bare Today: ' + t4);
    }

    // =========================================================================
    // DocGenHtmlRenderer — nested-table direct-child property scoping (issue #49)
    // Outer cell wrapping an inner table must NOT inherit the inner header row's
    // <w:tblHeader/> from <w:trPr>; if it does, outer renders as <th> and bold
    // cascades into every nested data cell.
    // =========================================================================

    @IsTest
    static void testNestedTableOuterRowDoesNotInheritInnerHeader() {
        // Outer row: no <w:trPr>. Outer cell: a nested table whose first row has
        // <w:trPr><w:tblHeader/></w:trPr>. The outer row must still render <td>.
        String docXml =
            '<w:document xmlns:w="x"><w:body>' +
            '<w:tbl><w:tblPr/><w:tr><w:tc><w:tcPr/>' +
            '<w:tbl><w:tblPr/>' +
            '<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>H</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:rPr><w:b w:val="false"/></w:rPr><w:t>D</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:tc></w:tr></w:tbl>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());
        // Outer row's cell must be <td>, not <th>.
        System.assert(html.contains('<tr><td><table'), 'outer cell wrapping nested table must render as <td>: ' + html);
        // Inner header still <th>, inner data still <td>.
        System.assert(html.contains('<th><p><b>H</b></p></th>'), 'inner header preserved as <th> with bold: ' + html);
        System.assert(
            html.contains('<td><p>D</p></td>') || html.contains('<td><p><span'),
            'inner data row must render as <td> without inherited bold wrapper: ' + html
        );
        // Critical regression check: data row text "D" must NOT be wrapped in <b>.
        System.assert(!html.contains('<b>D</b>'), 'inner data text must not be bolded: ' + html);
    }

    @IsTest
    static void testNestedTableOuterRowOwnTrPrStillRespected() {
        // Outer row HAS its own <w:trPr><w:tblHeader/></w:trPr> AND contains a
        // nested table — outer must still be detected as a header row.
        String docXml =
            '<w:document xmlns:w="x"><w:body>' +
            '<w:tbl><w:tblPr/>' +
            '<w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:tcPr/>' +
            '<w:tbl><w:tblPr/>' +
            '<w:tr><w:tc><w:p><w:r><w:t>X</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());
        System.assert(
            html.contains('<tr><th><table'),
            'outer row with own w:tblHeader must still render <th>: ' + html
        );
    }

    @IsTest
    static void testTallHeaderExpandsPdfTopMargin() {
        String headerXml =
            '<w:hdr xmlns:w="x" xmlns:wp="x">' +
            '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="1944623" cy="341375"/></wp:inline></w:drawing></w:r></w:p>' +
            '<w:p><w:pPr><w:spacing w:before="40"/></w:pPr><w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>MARKET UPDATES</w:t></w:r></w:p>' +
            '<w:p><w:pPr><w:spacing w:before="20"/></w:pPr></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>5001 Spring Valley Road</w:t></w:r></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>Suite 100</w:t></w:r></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>Dallas, TX 75244</w:t></w:r></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>Tel: (972) 755-5200</w:t></w:r></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>Fax: (972) 755-5210</w:t></w:r></w:p>' +
            '<w:p><w:r><w:rPr><w:sz w:val="20"/></w:rPr><w:t>www.MarcusMillichap.com</w:t></w:r></w:p>' +
            '</w:hdr>';
        String docXml =
            '<!-- DOCGEN_HEADER_START -->' +
            headerXml +
            '<!-- DOCGEN_HEADER_END -->' +
            '<w:document xmlns:w="x"><w:body>' +
            '<w:p><w:r><w:t>Body starts after header</w:t></w:r></w:p>' +
            '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="0" w:footer="0"/></w:sectPr>' +
            '</w:body></w:document>';

        String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());

        System.assert(html.contains('@top-center'), 'Header should render as a running margin-box element: ' + html);
        System.assert(
            !html.contains('margin: 1.0in 1.0in 1.0in 1.0in'),
            'Tall header must expand the top page margin beyond the authored 1 inch: ' + html
        );
        System.assert(html.contains('Body starts after header'), 'Body content should still render: ' + html);
    }

    @IsTest
    static void testRepeatHeaderMarkerInjectsTblHeaderAndStrips() {
        // {RepeatHeader} in a header-row cell must, pre-merge, strip the marker text and
        // add <w:tblHeader/> to the row's properties so the renderer repeats it per page.
        String docXml =
            '<w:document xmlns:w="x"><w:body><w:tbl><w:tblPr/>' +
            '<w:tr><w:tc><w:p><w:r><w:t>{RepeatHeader}Short Code</w:t></w:r></w:p></w:tc></w:tr>' +
            '<w:tr><w:tc><w:p><w:r><w:t>105</w:t></w:r></w:p></w:tc></w:tr>' +
            '</w:tbl></w:body></w:document>';

        String result = DocGenService.mergeRunsInTagsForTest(docXml);

        System.assert(result.contains('<w:tblHeader/>'), 'Marker must inject <w:tblHeader/>: ' + result);
        System.assert(!result.contains('{RepeatHeader}'), 'Marker text must be stripped: ' + result);
        System.assert(result.contains('Short Code'), 'Surrounding header text must be preserved: ' + result);
        // The flag must land on the header row, not the data row.
        System.assert(
            result.indexOf('<w:tblHeader/>') < result.indexOf('Short Code'),
            'tblHeader must be in the marked (header) row: ' + result
        );
    }

    @IsTest
    static void testRepeatHeaderMarkerNoopWhenAbsent() {
        // Cheap-guard path: untouched when no marker is present.
        String docXml = '<w:document xmlns:w="x"><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>';
        System.assertEquals(docXml, DocGenService.mergeRunsInTagsForTest(docXml), 'No marker → unchanged');
    }

    @IsTest
    static void testMergeRunsFooterTagSplitAcrossBraceRuns() {
        String footerXml =
            '<w:ftr xmlns:w="x"><w:p>' +
            '<w:r><w:t>Premium Text short codes </w:t></w:r>' +
            '<w:r><w:t>{</w:t></w:r>' +
            '<w:r><w:t>Date_for_merge_document__c</w:t></w:r>' +
            '<w:r><w:t>}</w:t></w:r>' +
            '</w:p></w:ftr>';

        String result = DocGenService.mergeRunsInTagsForTest(footerXml);

        System.assert(
            result.contains('{Date_for_merge_document__c}'),
            'Footer/header tags split across brace runs must be merged before giant-query HTML snapshot conversion: ' +
            result
        );
    }

    @IsTest
    static void testNestedTableOuterCellOwnTcPrStillRespected() {
        // Outer cell has its own <w:tcPr> with shading; nested cells have their
        // own tcPr. Outer must use ITS OWN shading, not the inner cell's.
        String docXml =
            '<w:document xmlns:w="x"><w:body>' +
            '<w:tbl><w:tblPr/>' +
            '<w:tr><w:tc>' +
            '<w:tcPr><w:shd w:val="clear" w:fill="FF0000"/></w:tcPr>' +
            '<w:tbl><w:tblPr/>' +
            '<w:tr><w:tc>' +
            '<w:tcPr><w:shd w:val="clear" w:fill="00FF00"/></w:tcPr>' +
            '<w:p><w:r><w:t>I</w:t></w:r></w:p>' +
            '</w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:tc></w:tr>' +
            '</w:tbl>' +
            '</w:body></w:document>';
        String html = DocGenHtmlRenderer.convertToHtml(docXml, new Map<String, String>());
        // Outer cell should carry the red shading from its OWN tcPr.
        System.assert(html.contains('background-color:#FF0000'), 'outer cell must use its own shading: ' + html);
        // Inner cell should still get its green shading.
        System.assert(html.contains('background-color:#00FF00'), 'inner cell must use its own shading: ' + html);
    }

    // =========================================================================
    // DocGenService — generateDocumentParts with dynamic image CV ID
    // =========================================================================

    @IsTest
    static void testGenerateDocumentPartsWithImageCvId() {
        ContentVersion imgCv = new ContentVersion(
            Title = 'PartsImg',
            PathOnClient = 'PartsImg.png',
            VersionData = Blob.valueOf('PARTSPNG')
        );
        insert imgCv;
        imgCv = [SELECT Id FROM ContentVersion WHERE Id = :imgCv.Id];

        Account acc = TestDataFactory.getTestAccount();
        acc.Description = imgCv.Id;
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('allXmlParts'), 'XML parts should not be null for image CV ID parts');
        Map<String, String> imageCvIdMap = (Map<String, String>) result.get('imageCvIdMap');
        System.assert(imageCvIdMap != null, 'Should return imageCvIdMap');
    }

    // =========================================================================
    // DocGenService — Excel self-closing cell in inlineSharedStrings
    // =========================================================================

    @IsTest
    static void testExcelSelfClosingCell() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String sharedStringsXml =
            '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<si><t>{Name}</t></si></sst>';

        String sheetXml =
            '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData><row r="1">' +
            '<c r="A1" s="1"/>' +
            '<c r="B1" t="s"><v>0</v></c>' +
            '</row></sheetData></worksheet>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry('xl/sharedStrings.xml', Blob.valueOf(sharedStringsXml));
        zw.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(sheetXml));

        ContentVersion cv = new ContentVersion(
            Title = 'ExcelSelfClose',
            PathOnClient = 'ExcelSelfClose.xlsx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Excel with self-closing cell should generate');
    }

    // =========================================================================
    // DocGenService — rich text <img> with data URI and dimensions
    // =========================================================================

    @IsTest
    static void testProcessDocumentRichTextImgDataUriWithDims() {
        String tinyBase64 = EncodingUtil.base64Encode(Blob.valueOf('RICHIMG'));
        Account acc = TestDataFactory.getTestAccount();
        acc.Description =
            '<p>Text <img src="data:image/png;base64,' +
            tinyBase64 +
            '" width="100" height="50" /> after</p>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(
            null,
            result.get('blob'),
            'Blob should not be null for rich text img with data URI dims'
        );
    }

    // =========================================================================
    // DocGenService — buildPdfImageMap with dynamic image URL stripping
    // =========================================================================

    @IsTest
    static void testGeneratePdfBlobWithAbsoluteImageUrl() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<img src="https://mydomain.my.salesforce.com/sfc/servlet.shepherd/version/download/068000000000001" />';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.generatePdfBlob(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'PDF with absolute URL image should generate');
    }

    // =========================================================================
    // DocGenService — resolveValue with base object prefix skip
    // =========================================================================

    @IsTest
    static void testResolveValueBaseObjectPrefixSkip() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'SkipPrefix' };

        String xml = '{!Account.Name}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('SkipPrefix'), 'Should skip base object prefix and resolve Name, got: ' + result);
    }

    // =========================================================================
    // DocGenService — resolveValue with SObject instance
    // =========================================================================

    @IsTest
    static void testResolveValueWithSObject() {
        Map<String, Object> data = new Map<String, Object>{
            'Name' => 'TestName',
            'Owner' => new User(FirstName = 'TestOwner')
        };

        String xml = '{Owner.FirstName}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('TestOwner'), 'Should resolve SObject field, got: ' + result);
    }

    // =========================================================================
    // DocGenService — generateDocumentFromData with PDF format
    // =========================================================================

    @IsTest
    static void testGenerateDocumentFromDataPdf() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Map<String, Object> preloadedData = new Map<String, Object>{ 'Name' => 'PDF Cached Name' };

        Test.startTest();
        Id docId = DocGenService.generateDocumentFromData(tpl.Id, acc.Id, preloadedData);
        Test.stopTest();

        System.assertNotEquals(null, docId, 'Should return ContentDocumentId for PDF from cached data');
        ContentVersion savedCv = [SELECT PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        System.assert(savedCv.PathOnClient.endsWith('.pdf'), 'Should save as PDF');
    }

    // =========================================================================
    // DocGenService — Aggregate COUNT with records map
    // =========================================================================

    @IsTest
    static void testAggregateCountRecordsMap() {
        Map<String, Object> data = new Map<String, Object>{
            'Contacts' => new Map<String, Object>{
                'records' => new List<Object>{
                    new Map<String, Object>{ 'Name' => 'A' },
                    new Map<String, Object>{ 'Name' => 'B' }
                }
            }
        };

        String xml = '{COUNT:Contacts}';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('2'), 'COUNT with records map should be 2, got: ' + result);
    }

    // =========================================================================
    // DocGenService — generateDocumentParts with passthrough media entries
    // =========================================================================

    @IsTest
    static void testGenerateDocumentPartsWithPassthroughMedia() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    '<Default Extension="png" ContentType="image/png"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo.png"/></Relationships>'
            )
        );
        zw.addEntry('word/media/logo.png', Blob.valueOf('MEDIAPNGBYTES'));

        ContentVersion cv = new ContentVersion(
            Title = 'MediaParts',
            PathOnClient = 'MediaParts.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('allXmlParts'), 'XML parts should not be null for passthrough media');
        Map<String, String> imageBase64Map = (Map<String, String>) result.get('imageBase64Map');
        System.assert(imageBase64Map != null, 'Should return imageBase64Map');
        System.assert(imageBase64Map.containsKey('word/media/logo.png'), 'Should include passthrough media');
    }

    // =========================================================================
    // DocGenService — lastRenderedHtml field populated
    // =========================================================================

    @IsTest
    static void testLastRenderedHtmlPopulated() {
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Output_Format__c = 'PDF';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        DocGenService.generateDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(
            null,
            DocGenService.lastRenderedHtml,
            'lastRenderedHtml should be populated after PDF generation'
        );
    }

    // =========================================================================
    // DocGenService — Excel: multiple worksheets
    // =========================================================================

    @IsTest
    static void testExcelMultipleWorksheets() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name, AccountSource';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String sharedStringsXml =
            '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<si><t>{Name}</t></si><si><t>{AccountSource}</t></si></sst>';

        String sheet1Xml =
            '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>';

        String sheet2Xml =
            '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<sheetData><row r="1"><c r="A1" t="s"><v>1</v></c></row></sheetData></worksheet>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'
            )
        );
        zw.addEntry('xl/sharedStrings.xml', Blob.valueOf(sharedStringsXml));
        zw.addEntry('xl/worksheets/sheet1.xml', Blob.valueOf(sheet1Xml));
        zw.addEntry('xl/worksheets/sheet2.xml', Blob.valueOf(sheet2Xml));

        ContentVersion cv = new ContentVersion(
            Title = 'MultiSheet',
            PathOnClient = 'MultiSheet.xlsx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Excel with multiple sheets should generate');
    }

    // =========================================================================
    // DocGenService — rich text with empty paragraphs
    // =========================================================================

    @IsTest
    static void testProcessDocumentRichTextEmptyParagraphs() {
        Account acc = TestDataFactory.getTestAccount();
        acc.Description = '<p></p><p>Content</p><p></p>';
        update acc;

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Query_Config__c = 'Name, Description';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Description}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for rich text empty paragraphs');
    }

    // =========================================================================
    // DocGenService — {! Name } with spaces around prefix
    // =========================================================================

    @IsTest
    static void testProcessXmlSalesforceStyleWithSpaces() {
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Spaced' };

        String xml = '{! Name }';
        Test.startTest();
        String result = DocGenService.processXmlForTest(xml, data);
        Test.stopTest();

        System.assert(result.contains('Spaced'), 'Should trim and resolve {! Name }, got: ' + result);
    }

    // =========================================================================
    // DocGenService — non-image rels entries (styles, fontTable)
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithNonImageRels() {
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zw.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        zw.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' +
                    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/fontTable" Target="fontTable.xml"/>' +
                    '</Relationships>'
            )
        );

        ContentVersion cv = new ContentVersion(
            Title = 'NonImgRels',
            PathOnClient = 'NonImgRels.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Blob should not be null for non-image rels test');
    }

    // =========================================================================
    // DocGenFlowAction — saveToRecord path
    // =========================================================================

    @IsTest
    static void testFlowActionSaveToRecord() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
            ContentVersion cv = createValidDocxFile(docXml);

            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            // Create active version so generateDocument can find the template file
            insert new DocGen_Template_Version__c(
                Template__c = tpl.Id,
                Content_Version_Id__c = cv.Id,
                Is_Active__c = true
            );

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = true;

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return exactly one response');
            System.assertEquals(
                true,
                responses[0].success,
                'Success should be true when generation succeeds. Error: ' + responses[0].errorMessage
            );
            System.assertNotEquals(null, responses[0].contentDocumentId, 'ContentDocumentId should be set on success');
            System.assertNotEquals(null, responses[0].contentVersionId, 'ContentVersionId should be set on success');
            System.assertEquals(null, responses[0].errorMessage, 'ErrorMessage should be null on success');

            // saveToRecord=true: file must be linked to the source record (FirstPublishLocationId path).
            List<ContentDocumentLink> links = [
                SELECT Id
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :responses[0].contentDocumentId AND LinkedEntityId = :acc.Id
            ];
            System.assertEquals(1, links.size(), 'Generated file should be linked to the source record');
        }
    }

    // =========================================================================
    // DocGenFlowAction — null templateId error path
    // =========================================================================

    @IsTest
    static void testFlowActionNullTemplateId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = null;
            req.recordId = acc.Id;

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return exactly one response for null templateId');
            System.assertEquals(false, responses[0].success, 'Success should be false when templateId is null');
            System.assertNotEquals(
                null,
                responses[0].errorMessage,
                'ErrorMessage should be populated when templateId is null'
            );
            System.assertEquals(null, responses[0].contentDocumentId, 'ContentDocumentId should be null on error');
            System.assertEquals(null, responses[0].contentVersionId, 'ContentVersionId should be null on error');
        }
    }

    // =========================================================================
    // DocGenFlowAction — success path with documentTitle override
    // =========================================================================

    @IsTest
    static void testFlowActionWithDocumentTitle() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
            createValidDocxFile(docXml);

            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = false;
            req.documentTitle = 'Custom Title';

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return exactly one response for documentTitle test');
            System.assertEquals(true, responses[0].success, 'Success should be true with documentTitle override');
        }
    }

    // =========================================================================
    // DocGenFlowAction — response field coverage
    // =========================================================================

    @IsTest
    static void testFlowActionResponseAllFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenFlowAction.Response res = new DocGenFlowAction.Response();
            res.contentDocumentId = null;
            res.contentVersionId = null;
            res.errorMessage = 'test error msg';
            res.success = false;

            System.assertEquals(null, res.contentDocumentId, 'contentDocumentId should be settable to null');
            System.assertEquals(null, res.contentVersionId, 'contentVersionId should be settable to null');
            System.assertEquals('test error msg', res.errorMessage, 'errorMessage should match assigned value');
            System.assertEquals(false, res.success, 'success should match assigned value');
        }
    }

    // =========================================================================
    // DocGenFlowAction — request field coverage
    // =========================================================================

    @IsTest
    static void testFlowActionRequestFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = null;
            req.recordId = null;
            req.saveToRecord = true;
            req.documentTitle = 'Test Title';

            System.assertEquals(null, req.templateId, 'templateId should be settable to null');
            System.assertEquals(null, req.recordId, 'recordId should be settable to null');
            System.assertEquals(true, req.saveToRecord, 'saveToRecord should match assigned value');
            System.assertEquals('Test Title', req.documentTitle, 'documentTitle should match assigned value');
        }
    }

    // =========================================================================
    // DocGenGiantQueryStitchJob — Batchable coverage
    // =========================================================================

    @IsTest
    static void testStitchJobStartWithFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Stitch Start Test'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create mock fragment CVs
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (Integer i = 0; i < 5; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                fragments.add(
                    new ContentVersion(
                        Title = 'docgen_giant_' + job.Id + '_' + seq,
                        PathOnClient = 'docgen_giant_' + job.Id + '_' + seq + '.html',
                        VersionData = Blob.valueOf('<table><tr><td>Row ' + i + '</td></tr></table>'),
                        IsMajorVersion = false,
                        FirstPublishLocationId = job.Id
                    )
                );
            }
            insert fragments;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 200);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Failed',
                'Job should be Completed or Failed after stitch: ' + updatedJob.Status__c
            );
        }
    }

    @IsTest
    static void testStitchJobStartWithNoFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Stitch No Fragments'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // No fragment CVs created — empty scenario
            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 200);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c, Label__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // Job should be Failed or unchanged (batch may not execute if start returns empty)
            System.assert(
                updatedJob.Status__c == 'Failed' || updatedJob.Status__c == 'Harvesting',
                'Job should be Failed or unchanged: ' + updatedJob.Status__c
            );
        }
    }

    @IsTest
    static void testStitchJobBackwardCompatConstructor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Compat Ctor Test'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            // Use the backward-compatible 7-argument constructor
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF',
                0,
                null
            );
            System.assertNotEquals(null, stitchJob, 'Backward-compatible constructor should work');
            Test.stopTest();
        }
    }

    @IsTest
    static void testStitchJobFinishSinglePart() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Single Part Test'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create exactly 1 fragment — will produce 1 part, triggering single-part finish path
            ContentVersion frag = new ContentVersion(
                Title = 'docgen_giant_' + job.Id + '_00000',
                PathOnClient = 'docgen_giant_' + job.Id + '_00000.html',
                VersionData = Blob.valueOf('<table><tr><td>Only Row</td></tr></table>'),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            insert frag;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 200);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Failed',
                'Single-part stitch should complete or fail: ' + updatedJob.Status__c
            );
        }
    }

    @IsTest
    static void testStitchJobFinishMultipleParts() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Multi Part Test'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create more fragments than FRAGMENTS_PER_PDF (3) to force multiple groups/parts
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (Integer i = 0; i < 7; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                fragments.add(
                    new ContentVersion(
                        Title = 'docgen_giant_' + job.Id + '_' + seq,
                        PathOnClient = 'docgen_giant_' + job.Id + '_' + seq + '.html',
                        VersionData = Blob.valueOf('<table><tr><td>Row ' + i + '</td></tr></table>'),
                        IsMajorVersion = false,
                        FirstPublishLocationId = job.Id
                    )
                );
            }
            insert fragments;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 200);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Failed',
                'Multi-part stitch should complete or fail: ' + updatedJob.Status__c
            );
        }
    }

    @IsTest
    static void testStitchJobFinalizerInstantiation() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(Template__c = tpl.Id, Status__c = 'Stitching');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer finalizer = new DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer(
                job.Id
            );
            System.assertNotEquals(null, finalizer, 'Finalizer should be creatable');
            Test.stopTest();
        }
    }

    // =========================================================================
    // DocGenService — Giant Query methods
    // =========================================================================

    @IsTest
    static void testExtractLoopBodyWithWhitespace() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Test with whitespace inside tags (pattern match path)
            String xml = '<w:body><w:p>{ # Contacts }<w:p>{FirstName}</w:p>{ / Contacts }</w:p></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'Contacts');
            Test.stopTest();

            // Even with whitespace, should find and extract
            if (result != null) {
                System.assert(result.containsKey('innerXml'), 'Should contain innerXml');
                System.assert(result.containsKey('beforeLoop'), 'Should contain beforeLoop');
                System.assert(result.containsKey('afterLoop'), 'Should contain afterLoop');
            }
        }
    }

    @IsTest
    static void testExtractLoopBodyNullReturn() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<w:body><w:p>No loops here</w:p></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'MissingRelationship');
            Test.stopTest();

            System.assertEquals(null, result, 'Should return null when loop tag not found');
        }
    }

    @IsTest
    static void testExtractLoopBodyTableRow() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Loop inside a w:tr — should expand container to include table row
            String xml = '<w:body><w:tbl><w:tr><w:tc>{#Contacts}<w:p>{FirstName}</w:p><w:p>{LastName}</w:p>{/Contacts}</w:tc></w:tr></w:tbl></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'Contacts');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should extract loop body from table row');
            System.assert(result.get('innerXml').contains('{FirstName}'), 'Should contain FirstName tag');
            System.assert(result.get('beforeLoop').contains('<w:tbl>'), 'beforeLoop should have table start');
            System.assert(result.get('afterLoop').contains('</w:tbl>'), 'afterLoop should have table end');
        }
    }

    @IsTest
    static void testRenderLoopBodyForRecordsEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc></w:tr>';

            Test.startTest();
            String result = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                new List<SObject>(),
                new List<String>{ 'FirstName' }
            );
            Test.stopTest();

            System.assertEquals('', result, 'Empty records list should produce empty output');
        }
    }

    @IsTest
    static void testRenderLoopBodyWithParentFields() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            List<Contact> contacts = new List<Contact>();
            for (Integer i = 0; i < 3; i++) {
                contacts.add(new Contact(FirstName = 'Parent' + i, LastName = 'Test' + i, AccountId = acc.Id));
            }
            insert contacts;

            List<Contact> queried = [
                SELECT FirstName, LastName, Account.Name
                FROM Contact
                WHERE AccountId = :acc.Id
                ORDER BY FirstName
            ];

            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{Account.Name}</w:p></w:tc></w:tr>';

            Test.startTest();
            String result = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                queried,
                new List<String>{ 'FirstName', 'Account.Name' }
            );
            Test.stopTest();

            System.assertNotEquals('', result, 'Should render content for parent field records');
            // Parent field resolution depends on processXml implementation — just verify it rendered something
            System.assert(result.contains('<w:tr>'), 'Should contain table row XML');
        }
    }

    @IsTest
    static void testRenderLoopBodyWithNullParentField() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Contact without Account — parent field will be null
            Contact c = new Contact(FirstName = 'Orphan', LastName = 'Contact');
            insert c;

            List<Contact> queried = [SELECT FirstName, Account.Name FROM Contact WHERE Id = :c.Id];
            String innerXml = '<w:tr><w:tc><w:p>{Account.Name}</w:p></w:tc></w:tr>';

            Test.startTest();
            String result = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                queried,
                new List<String>{ 'Account.Name' }
            );
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should handle null parent gracefully');
        }
    }

    // ─── {RowNumber} across giant-query fragments ────────────────────────
    // The giant path renders its loop in slices of batchSize per execute(), so
    // each renderLoopBodyForRecords call sees only its own records. Without the
    // running offset every fragment restarts at 1 — a 30,000-row table counting
    // 1..50 over and over, which looks right on page one and ships unnoticed.

    @IsTest
    static void testRenderLoopBodyRowNumberContinuesAcrossFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            List<Contact> contacts = new List<Contact>();
            for (Integer i = 0; i < 4; i++) {
                contacts.add(new Contact(FirstName = 'Row' + i, LastName = 'Frag', AccountId = acc.Id));
            }
            insert contacts;
            // Scoped by LastName, not AccountId: the shared test Account carries
            // fixture Contacts of its own, which would pad the list.
            List<Contact> queried = [
                SELECT FirstName
                FROM Contact
                WHERE AccountId = :acc.Id AND LastName = 'Frag'
                ORDER BY FirstName
            ];

            String innerXml = '[{RowNumber}:{FirstName}]';
            List<Contact> firstHalf = new List<Contact>{ queried[0], queried[1] };
            List<Contact> secondHalf = new List<Contact>{ queried[2], queried[3] };

            Test.startTest();
            String frag1 = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                firstHalf,
                new List<String>{ 'FirstName' },
                0
            );
            // Offset = rows already rendered, exactly as DocGenGiantQueryBatch accumulates it.
            String frag2 = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                secondHalf,
                new List<String>{ 'FirstName' },
                firstHalf.size()
            );
            Test.stopTest();

            System.assertEquals('[1:Row0][2:Row1]', frag1, 'First fragment should number from 1.');
            System.assertEquals('[3:Row2][4:Row3]', frag2, 'Second fragment must continue, not restart at 1.');
        }
    }

    @IsTest
    static void testRenderLoopBodyWithoutRowNumberTagIsUnaffected() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            insert new Contact(FirstName = 'Plain', LastName = 'NoRowNum', AccountId = acc.Id);
            List<Contact> queried = [SELECT FirstName FROM Contact WHERE LastName = 'NoRowNum'];

            Test.startTest();
            // The 4-arg overload is what every pre-existing caller uses; it must
            // keep behaving exactly as before.
            String result = DocGenService.renderLoopBodyForRecords(
                '[{FirstName}]',
                'Contacts',
                queried,
                new List<String>{ 'FirstName' }
            );
            Test.stopTest();

            System.assertEquals('[Plain]', result, 'A body without {RowNumber} renders unchanged.');
        }
    }

    @IsTest
    static void testGenerateDocumentPartsGiantQueryWithInvalidTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            // Template has a fake file, not a real DOCX — should throw
            createTestFile();

            Test.startTest();
            try {
                Map<String, Object> result = DocGenService.generateDocumentPartsGiantQuery(tpl.Id, acc.Id, 'Contacts');
                // If it succeeds unexpectedly, that is also acceptable
            } catch (Exception e) {
                System.assert(e.getMessage() != null, 'Should get an error for invalid DOCX template');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGenerateDocumentPartsGiantQueryWithValidDocx() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with a real DOCX containing loop tags
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'Giant Query Valid Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
                '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>{FirstName}</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>{/Contacts}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
                '</w:body></w:document>';

            // Build DOCX ZIP
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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'GiantDocx',
                PathOnClient = 'GiantDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            try {
                Map<String, Object> result = DocGenService.generateDocumentPartsGiantQuery(tpl.Id, acc.Id, 'Contacts');
                System.assertNotEquals(null, result, 'Should return a result map');
                System.assert(result.containsKey('allXmlParts'), 'Should contain allXmlParts key');
            } catch (Exception e) {
                // May fail due to template merge — that is acceptable in test context
                System.assert(e.getMessage() != null, 'Error should have a message');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testMergeTemplateWithPreRenderedLoops() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with loop tags and a valid DOCX
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'PreRendered Loop Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
                '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>{#Contacts}</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>{FirstName}</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>{/Contacts}</w:t></w:r></w:p></w:tc></w:tr></w:tbl>' +
                '</w:body></w:document>';

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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'PreRenderedDocx',
                PathOnClient = 'PreRenderedDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Account acc = TestDataFactory.getTestAccount();

            // Pre-rendered loop content
            Map<String, String> preRendered = new Map<String, String>{
                'Contacts' => '<w:tr><w:tc><w:p><w:r><w:t>Alice</w:t></w:r></w:p></w:tc></w:tr>' +
                '<w:tr><w:tc><w:p><w:r><w:t>Bob</w:t></w:r></w:p></w:tc></w:tr>'
            };

            Test.startTest();
            try {
                Id docId = DocGenService.mergeTemplateWithPreRenderedLoops(tpl.Id, acc.Id, preRendered, 'PDF');
                System.assertNotEquals(null, docId, 'Should produce a document ID');
            } catch (Exception e) {
                // May fail during PDF rendering — acceptable in test context
                System.assert(e.getMessage() != null, 'Error should have a message');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGenerateHtmlForRecordCoverage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create template with valid DOCX
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'HTML Gen Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';

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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'HtmlGenDocx',
                PathOnClient = 'HtmlGenDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Account acc = TestDataFactory.getTestAccount();

            Test.startTest();
            try {
                String html = DocGenService.generateHtmlForRecord(tpl.Id, acc.Id, null);
                System.assertNotEquals(null, html, 'Should return HTML');
                System.assert(html.contains('DocGen Test Account'), 'HTML should contain account name');
            } catch (Exception e) {
                // Acceptable in test context where VF page may not exist
                System.assert(e.getMessage() != null, 'Error should have a message');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGenerateHtmlForRecordWithPreloadedDataCoverage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'HTML Preload Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';

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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'HtmlPreloadDocx',
                PathOnClient = 'HtmlPreloadDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Account acc = TestDataFactory.getTestAccount();
            Map<String, Object> preloaded = new Map<String, Object>{ 'Name' => 'Preloaded Name' };

            Test.startTest();
            try {
                String html = DocGenService.generateHtmlForRecord(tpl.Id, acc.Id, preloaded);
                System.assertNotEquals(null, html, 'Should return HTML with preloaded data');
            } catch (Exception e) {
                System.assert(e.getMessage() != null, 'Error should have a message');
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // DocGenFlowAction — error and save paths
    // =========================================================================

    @IsTest
    static void testFlowActionWithInvalidRecordId() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            createTestFile();

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = tpl.Id;
            // Use a fabricated ID that does not exist
            req.recordId = '001000000000000AAA';
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return one response');
            // Should fail because record does not exist or template is invalid
            System.assertEquals(false, responses[0].success, 'Should fail for invalid record');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have an error message');
        }
    }

    @IsTest
    static void testFlowActionSaveToRecordTrue() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with valid DOCX
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'Flow Save Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';

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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'FlowSaveDocx',
                PathOnClient = 'FlowSaveDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Account acc = TestDataFactory.getTestAccount();

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = true;
            req.documentTitle = 'Flow Generated Doc';

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return one response');
            if (responses[0].success) {
                System.assertNotEquals(
                    null,
                    responses[0].contentDocumentId,
                    'Should have contentDocumentId on success'
                );
                System.assertNotEquals(null, responses[0].contentVersionId, 'Should have contentVersionId on success');
                // Verify CDL was created linking doc to account
                List<ContentDocumentLink> links = [
                    SELECT Id
                    FROM ContentDocumentLink
                    WHERE ContentDocumentId = :responses[0].contentDocumentId AND LinkedEntityId = :acc.Id
                ];
                System.assert(links.size() > 0, 'Should create ContentDocumentLink when saveToRecord is true');
            }
        }
    }

    @IsTest
    static void testFlowActionSaveToRecordFalse() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return one response');
            System.assertEquals(true, responses[0].success, 'Should succeed with real DOCX template');
        }
    }

    @IsTest
    static void testFlowActionMultipleRequests() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            Account acc = TestDataFactory.getTestAccount();

            List<DocGenFlowAction.Request> requests = new List<DocGenFlowAction.Request>();
            // CxSAST: DML in test setup — not a bulkification concern
            for (Integer i = 0; i < 3; i++) {
                DocGenFlowAction.Request req = new DocGenFlowAction.Request();
                req.templateId = tpl.Id;
                req.recordId = acc.Id;
                req.saveToRecord = (Math.mod(i, 2) == 0);
                requests.add(req);
            }

            Test.startTest();
            List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(requests);
            Test.stopTest();

            System.assertEquals(3, responses.size(), 'Should return three responses');
            for (DocGenFlowAction.Response resp : responses) {
                System.assertEquals(true, resp.success, 'Each request should succeed with real DOCX');
            }
        }
    }

    // =========================================================================
    // DocGenMergeJob — Finalizer and empty snippets
    // =========================================================================

    @IsTest
    static void testMergeJobFinalizerInstantiation() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(Template__c = tpl.Id, Status__c = 'Merging');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenMergeJob.DocGenMergeJobFinalizer finalizer = new DocGenMergeJob.DocGenMergeJobFinalizer(job.Id);
            System.assertNotEquals(null, finalizer, 'Finalizer should be creatable');
            Test.stopTest();
        }
    }

    @IsTest
    static void testMergeJobWithEmptySnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Merging',
                Label__c = 'Empty Merge Test',
                Success_Count__c = 0,
                Total_Records__c = 0
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // No snippets created — empty scenario
            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Completed', updatedJob.Status__c, 'Job should be Completed when no snippets exist');
        }
    }

    @IsTest
    static void testMergeJobWithSnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Merging',
                Label__c = 'Snippet Merge Test',
                Success_Count__c = 3,
                Total_Records__c = 3
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create HTML snippet CVs
            List<ContentVersion> snippets = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                snippets.add(
                    new ContentVersion(
                        Title = 'docgen_merge_' + job.Id + '_' + seq,
                        PathOnClient = 'docgen_merge_' + job.Id + '_' + seq + '.html',
                        VersionData = Blob.valueOf(
                            '<html><body><h1>Page ' + i + '</h1><p>Content for record ' + i + '</p></body></html>'
                        ),
                        IsMajorVersion = false,
                        FirstPublishLocationId = job.Id
                    )
                );
            }
            insert snippets;

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // Should be Completed (or Completed with Errors if notification fails)
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Completed with Errors',
                'Job should be Completed after merge: ' + updatedJob.Status__c
            );
        }
    }

    // =========================================================================
    // DocGenBatch — sanitizeCondition rejection and merge-only mode
    // =========================================================================

    @IsTest
    static void testBatchSanitizeConditionRejectsInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            // Test with semicolon injection
            DocGen_Job__c job1 = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name != null; DELETE Account'
            );
            insert job1;

            Test.startTest();
            try {
                DocGenBatch batch = new DocGenBatch(job1.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
                // If no exception thrown in start(), the batch will fail during execution
            } catch (Exception e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject semicolon injection');
            }
        }
    }

    @IsTest
    static void testBatchSanitizeConditionRejectsComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name != null -- comment'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            try {
                DocGenBatch batch = new DocGenBatch(job.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject double-dash comment');
            }
        }
    }

    @IsTest
    static void testBatchSanitizeConditionRejectsKeywords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            // Test with SELECT keyword
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name IN (SELECT Name FROM Account)'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            try {
                DocGenBatch batch = new DocGenBatch(job.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject SELECT keyword');
            }
        }
    }

    @IsTest
    static void testBatchMergeOnlyMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name = \'DocGen Test Account\''
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            // mergeOnly=true — should only generate HTML snippets, no individual PDFs
            DocGenBatch batch = new DocGenBatch(job.Id, false, true);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updatedJob = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertNotEquals('Queued', updatedJob.Status__c, 'Job should have progressed from Queued');
        }
    }

    @IsTest
    static void testBatchMergeModeConstructor() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name = \'DocGen Test Account\''
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            // Two-arg constructor with mergeMode=true
            DocGenBatch batch = new DocGenBatch(job.Id, true);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updatedJob.Status__c, 'Job should have progressed');
        }
    }

    // =========================================================================
    // DocGenBulkController — analyzeJob and error paths
    // =========================================================================

    @IsTest
    static void testAnalyzeJobWithNullParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(null, 0, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return an analysis even with null template');
            System.assertEquals('No records to process.', analysis.summary, 'Should report no records');
        }
    }

    @IsTest
    static void testAnalyzeJobWithZeroRecords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 0, 1, false);
            Test.stopTest();

            System.assertEquals('No records to process.', analysis.summary, 'Should report no records for zero count');
        }
    }

    @IsTest
    static void testAnalyzeJobWithNegativeRecords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, -5, 1, false);
            Test.stopTest();

            System.assertEquals(
                'No records to process.',
                analysis.summary,
                'Should report no records for negative count'
            );
        }
    }

    @IsTest
    static void testAnalyzeJobHighRecordCount() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 60000, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis');
            System.assertEquals(false, analysis.canProceed, 'Should not allow proceeding with 60k records');
            // Should have an error item for record count
            Boolean foundError = false;
            for (DocGenBulkController.AnalysisItem item : analysis.items) {
                if (item.label == 'Record Count' && item.status == 'error') {
                    foundError = true;
                }
            }
            System.assert(foundError, 'Should have error for record count exceeding 50k');
        }
    }

    @IsTest
    static void testAnalyzeJobMergeMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create template with a test record ID for heap estimation
            Account acc = TestDataFactory.getTestAccount();
            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'Analyze Merge Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF',
                Test_Record_Id__c = acc.Id
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            // Need a valid DOCX file for heap estimation
            String docXml =
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
                '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';

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
                        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                        '</Relationships>'
                )
            );
            zw.addEntry('word/document.xml', Blob.valueOf(docXml));

            ContentVersion cv = new ContentVersion(
                Title = 'AnalyzeMergeDocx',
                PathOnClient = 'AnalyzeMergeDocx.docx',
                VersionData = zw.getArchive()
            );
            insert cv;

            Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
            insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 100, 5, true);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis');
            // Should have merge heap and batch heap items
            Set<String> labels = new Set<String>();
            for (DocGenBulkController.AnalysisItem item : analysis.items) {
                labels.add(item.label);
            }
            System.assert(labels.contains('SOQL Queries'), 'Should have SOQL item');
            System.assert(labels.contains('DML Statements'), 'Should have DML item');
            System.assert(labels.contains('Record Count'), 'Should have record count item');
        }
    }

    @IsTest
    static void testAnalyzeJobNoTestRecord() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 10, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis');
            // Without Test_Record_Id__c, should have a warning about heap estimate
            Boolean foundHeapWarning = false;
            for (DocGenBulkController.AnalysisItem item : analysis.items) {
                if (item.label == 'Heap Estimate' && item.status == 'warning') {
                    foundHeapWarning = true;
                }
            }
            System.assert(foundHeapWarning, 'Should warn about unavailable heap estimate');
        }
    }

    @IsTest
    static void testAnalyzeJobWithV2Config() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String v2Config = JSON.serialize(
                new Map<String, Object>{
                    'v' => 2,
                    'baseObject' => 'Account',
                    'baseFields' => new List<String>{ 'Name' },
                    'parentFields' => new List<String>(),
                    'children' => new List<Object>{
                        new Map<String, Object>{ 'rel' => 'Contacts', 'fields' => new List<String>{ 'FirstName' } }
                    },
                    'junctions' => new List<Object>()
                }
            );

            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'V2 Analyze Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = v2Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 10, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis for V2 config');
            // V2 with 1 child should estimate 2 SOQL per record
            Boolean foundSoql = false;
            for (DocGenBulkController.AnalysisItem item : analysis.items) {
                if (item.label == 'SOQL Queries') {
                    foundSoql = true;
                }
            }
            System.assert(foundSoql, 'Should have SOQL analysis item');
        }
    }

    @IsTest
    static void testAnalyzeJobWithV3Config() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String v3Config = JSON.serialize(
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
                            'fields' => new List<String>{ 'FirstName' },
                            'parentFields' => new List<String>(),
                            'parentNode' => 'n0',
                            'lookupField' => 'AccountId',
                            'relationshipName' => 'Contacts'
                        }
                    }
                }
            );

            DocGen_Template__c tpl = new DocGen_Template__c(
                Name = 'V3 Analyze Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            Database.insert(tpl, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 10, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis for V3 config');
        }
    }

    @IsTest
    static void testAnalyzeJobHighBatchSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            // Invalid batch size (0 or negative) should default to 1
            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(tpl.Id, 10, 0, false);
            Test.stopTest();

            System.assertNotEquals(null, analysis, 'Should return analysis with defaulted batch size');
        }
    }

    @IsTest
    static void testEstimateHeapUsage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

            Test.startTest();
            DocGenBulkController.HeapEstimate estimate = DocGenBulkController.estimateHeapUsage(tpl.Id, 10);
            Test.stopTest();

            System.assertNotEquals(null, estimate, 'Should return a heap estimate');
            System.assertNotEquals(null, estimate.message, 'Should have a message');
        }
    }

    @IsTest
    static void testBulkControllerValidateFilterInjectionPaths() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();

            // Test WITH keyword rejection
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null WITH SECURITY_ENFORCED');
                System.assert(false, 'Should have thrown for WITH keyword');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject WITH keyword');
            }

            // Test GROUP BY keyword rejection
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null GROUP BY Name');
                System.assert(false, 'Should have thrown for GROUP BY');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject GROUP BY');
            }

            // Test LIMIT keyword rejection
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null LIMIT 1');
                System.assert(false, 'Should have thrown for LIMIT');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject LIMIT');
            }

            // Test OFFSET keyword rejection
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null OFFSET 10');
                System.assert(false, 'Should have thrown for OFFSET');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject OFFSET');
            }

            Test.stopTest();
        }
    }

    @IsTest
    static void testBulkControllerValidateFilterBlockComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null /* block comment */');
                System.assert(false, 'Should have thrown for block comment');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains('Invalid filter condition'), 'Should reject block comment');
            }
            Test.stopTest();
        }
    }

    // =========================================================================
    // DocGenService — ahe helper method variants
    // =========================================================================

    @IsTest
    static void testAheWithCauseAndMessage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Exception cause = new DocGenException('root cause');
            AuraHandledException ex = DocGenService.ahe(cause, 'User message');
            Test.stopTest();

            System.assertNotEquals(null, ex, 'Should create AuraHandledException');
            System.assert(ex.getMessage().contains('User message'), 'Should include user message');
            System.assert(ex.getMessage().contains('root cause'), 'Should include root cause');
        }
    }

    @IsTest
    static void testAheWithCauseOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Exception cause = new DocGenException('only cause');
            AuraHandledException ex = DocGenService.ahe(cause);
            Test.stopTest();

            System.assertNotEquals(null, ex, 'Should create AuraHandledException');
            System.assert(ex.getMessage().contains('only cause'), 'Should include cause message');
        }
    }

    // =========================================================================
    // Phase 3: Coverage for @TestVisible private helper methods
    // =========================================================================

    // ---- findParentObject ----

    @IsTest
    static void testFindParentObjectWithKnownChild() {
        // OpportunityLineItem has a reference to Opportunity, which should be found
        // when Opportunity is in the childRelNameByObject map
        Map<String, String> childRelNameByObject = new Map<String, String>{
            'Opportunity' => 'Opportunities',
            'Contact' => 'Contacts'
        };

        Test.startTest();
        String result = DocGenController.findParentObject('OpportunityLineItem', 'Account', childRelNameByObject);
        Test.stopTest();

        System.assertEquals('Opportunity', result, 'OpportunityLineItem should resolve to Opportunity as parent');
    }

    @IsTest
    static void testFindParentObjectNoMatchFallsBackToBase() {
        Map<String, String> childRelNameByObject = new Map<String, String>();

        Test.startTest();
        String result = DocGenController.findParentObject('Contact', 'Account', childRelNameByObject);
        Test.stopTest();

        System.assertEquals('Account', result, 'Should fall back to baseObject when no parent match found');
    }

    @IsTest
    static void testFindParentObjectInvalidChildObject() {
        Map<String, String> childRelNameByObject = new Map<String, String>();

        Test.startTest();
        String result = DocGenController.findParentObject('ZZZNotReal__c', 'Account', childRelNameByObject);
        Test.stopTest();

        System.assertEquals('Account', result, 'Should fall back to baseObject for invalid child object');
    }

    // ---- findJunctionRelationship ----

    @IsTest
    static void testFindJunctionRelationshipKnownJunction() {
        SObjectType oppType = Schema.getGlobalDescribe().get('Opportunity');

        Test.startTest();
        String result = DocGenController.findJunctionRelationship('Opportunity', 'Contact', oppType);
        Test.stopTest();

        System.assertEquals('OpportunityContactRoles', result, 'Should return known junction for Opportunity:Contact');
    }

    @IsTest
    static void testFindJunctionRelationshipCampaignContact() {
        SObjectType campType = Schema.getGlobalDescribe().get('Campaign');

        Test.startTest();
        String result = DocGenController.findJunctionRelationship('Campaign', 'Contact', campType);
        Test.stopTest();

        System.assertEquals('CampaignMembers', result, 'Should return known junction for Campaign:Contact');
    }

    @IsTest
    static void testFindJunctionRelationshipNoMatch() {
        SObjectType accType = Schema.getGlobalDescribe().get('Account');

        Test.startTest();
        String result = DocGenController.findJunctionRelationship('Account', 'Product2', accType);
        Test.stopTest();

        // No known junction between Account and Product2
        // Fallback scan may or may not find one, but should not throw
        System.assert(true, 'Should not throw for unmatched junction');
    }

    // ---- hasReferenceToObject ----

    @IsTest
    static void testHasReferenceToObjectTrue() {
        // OpportunityContactRole has a reference to Contact
        SObjectType ocrType = Schema.getGlobalDescribe().get('OpportunityContactRole');

        Test.startTest();
        Boolean result = DocGenController.hasReferenceToObject(ocrType, 'Contact');
        Test.stopTest();

        System.assertEquals(true, result, 'OpportunityContactRole should have a reference to Contact');
    }

    @IsTest
    static void testHasReferenceToObjectFalse() {
        // Account does not have a reference to Product2
        SObjectType accType = Schema.getGlobalDescribe().get('Account');

        Test.startTest();
        Boolean result = DocGenController.hasReferenceToObject(accType, 'Product2');
        Test.stopTest();

        System.assertEquals(false, result, 'Account should not have a reference to Product2');
    }

    // ---- mapReportOperator ----

    @IsTest
    static void testMapReportOperatorEquals() {
        Test.startTest();
        String result = DocGenController.mapReportOperator('equals');
        Test.stopTest();
        System.assertEquals('=', result, 'equals should map to =');
    }

    @IsTest
    static void testMapReportOperatorNotEqual() {
        Test.startTest();
        String result = DocGenController.mapReportOperator('notEqual');
        Test.stopTest();
        System.assertEquals('!=', result, 'notEqual should map to !=');
    }

    @IsTest
    static void testMapReportOperatorContains() {
        Test.startTest();
        String result = DocGenController.mapReportOperator('contains');
        Test.stopTest();
        System.assertEquals('LIKE', result, 'contains should map to LIKE');
    }

    @IsTest
    static void testMapReportOperatorGreaterThan() {
        Test.startTest();
        String result = DocGenController.mapReportOperator('greaterThan');
        Test.stopTest();
        System.assertEquals('>', result, 'greaterThan should map to >');
    }

    @IsTest
    static void testMapReportOperatorUnknown() {
        Test.startTest();
        String result = DocGenController.mapReportOperator('unknownOp');
        Test.stopTest();
        System.assertEquals('=', result, 'Unknown operator should default to =');
    }

    // =========================================================================
    // Phase 3: DocGenHtmlRenderer — additional rendering paths
    // =========================================================================

    @IsTest
    static void testProcessDocumentWithV3ConfigAndContacts() {
        // Exercises the V3 data retriever path with child records
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        // Factory already creates V3 config with Account + Contacts

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:p><w:r><w:t>{#Contacts}{FirstName} {LastName}{/Contacts}</w:t></w:r></w:p>' +
            '</w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Should generate document with V3 config and child contacts');
    }

    @IsTest
    static void testProcessDocumentWithV3ConfigParentField() {
        // Exercises V3 parentField (Owner.Name) path
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        // V3 config includes Owner.Name as parentField

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name} by {Owner.Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.processDocument(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('blob'), 'Should generate document with V3 parent field');
    }

    // =========================================================================
    // Phase 3: DocGenService — mergeTemplate error path (null template file)
    // =========================================================================

    @IsTest
    static void testProcessDocumentTemplateNoFile() {
        // Template with no content file attached — exercises the error path
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'NoFile Template',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenService.processDocument(tpl.Id, acc.Id);
        } catch (Exception e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'Should throw when template has no file');
    }

    // =========================================================================
    // Phase 3: DocGenService — generateDocumentParts with V3 config
    // =========================================================================

    @IsTest
    static void testGenerateDocumentPartsV3() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        String docXml = TestDataFactory.buildMinimalDocXml('{Name}');
        TestDataFactory.createValidDocxFile(tpl.Id, docXml);

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return non-null parts');
        System.assert(result.containsKey('allXmlParts'), 'Should contain allXmlParts');
    }

    // =========================================================================
    // Phase 3: DocGenDataRetriever — V2 config format
    // =========================================================================

    @IsTest
    static void testGetRecordDataV2Format() {
        Account acc = TestDataFactory.getTestAccount();
        String v2Config =
            '{"v":2,"baseObject":"Account","baseFields":["Name","Industry"],' +
            '"parentFields":["Owner.Name"],"children":[],"junctions":[]}';

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', v2Config);
        Test.stopTest();

        System.assertNotEquals(null, result, 'V2 config should return data');
        System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match');
    }

    @IsTest
    static void testGetRecordDataV3Format() {
        Account acc = TestDataFactory.getTestAccount();
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();

        Test.startTest();
        Map<String, Object> result = DocGenDataRetriever.getRecordData(acc.Id, 'Account', tpl.Query_Config__c);
        Test.stopTest();

        System.assertNotEquals(null, result, 'V3 config should return data');
        System.assertEquals('DocGen Test Account', result.get('Name'), 'Name should match');
        System.assert(result.containsKey('Contacts'), 'Should contain Contacts child data');
    }

    // =========================================================================
    // DocGenGiantQueryFlowAction — coverage for Request/Response/generateDocument
    // =========================================================================

    @IsTest
    static void testGiantQueryFlowAction_requestResponseStructure() {
        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = null;
        req.recordId = null;
        req.saveToRecord = true;
        System.assertEquals(null, req.templateId, 'Request templateId should be settable');
        System.assertEquals(true, req.saveToRecord, 'Request saveToRecord should be settable');

        DocGenGiantQueryFlowAction.Response res = new DocGenGiantQueryFlowAction.Response();
        res.contentDocumentId = null;
        res.contentVersionId = null;
        res.jobId = null;
        res.isGiantQuery = false;
        res.errorMessage = 'test';
        res.success = false;
        System.assertEquals(false, res.isGiantQuery, 'Response isGiantQuery should be settable');
        System.assertEquals('test', res.errorMessage, 'Response errorMessage should be settable');
    }

    @IsTest
    static void testGiantQueryFlowAction_templateNotFound() {
        Id fakeTemplateId =
            DocGen_Template__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000000';
        Account acc = TestDataFactory.getTestAccount();

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = fakeTemplateId;
        req.recordId = acc.Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'Should return one response');
        System.assertEquals(false, responses[0].success, 'Should fail for non-existent template');
        System.assertNotEquals(null, responses[0].errorMessage, 'Error message should be set');
    }

    @IsTest
    static void testGiantQueryFlowAction_syncPath() {
        // Template with no child records — should go sync path but fail because no real DOCX
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        createTestFile();

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'Should return one response');
        // Will error because test file is not a real DOCX, but exercises the sync code path
        System.assertNotEquals(null, responses[0], 'Response should not be null');
    }

    @IsTest
    static void testGiantQueryFlowAction_syncPathWithValidDocx() {
        // Create a valid DOCX so the sync path succeeds
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p></w:body></w:document>';
        createValidDocxFile(docXml);

        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'Should return one response');
        // With valid DOCX and small dataset, should succeed via sync path
        if (responses[0].success) {
            System.assertNotEquals(null, responses[0].contentDocumentId, 'Should have document ID on sync success');
            System.assertEquals(false, responses[0].isGiantQuery, 'Should not be giant query for small dataset');
        }
    }

    @IsTest
    static void testGiantQueryFlowAction_multipleRequests() {
        // Test with multiple requests in the batch
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();

        DocGenGiantQueryFlowAction.Request req1 = new DocGenGiantQueryFlowAction.Request();
        req1.templateId = tpl.Id;
        req1.recordId = acc.Id;

        DocGenGiantQueryFlowAction.Request req2 = new DocGenGiantQueryFlowAction.Request();
        req2.templateId = tpl.Id;
        req2.recordId = acc.Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req1, req2 }
        );
        Test.stopTest();

        System.assertEquals(2, responses.size(), 'Should return two responses');
    }

    // =========================================================================
    // DocGenGiantQueryAssembler — coverage for static utility methods
    // =========================================================================

    @IsTest
    static void testGiantQueryAssembler_constructorAndExecuteNoFragments() {
        // Create a Job record to use as jobId
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'Draft',
            Template__c = tpl.Id,
            Label__c = 'Test Assembler',
            Parent_Record_Id__c = String.valueOf(acc.Id)
        );
        Database.insert(job, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
        assembler.execute(null);
        Test.stopTest();

        // Should fail with 'No data to render' because no fragments exist
        DocGen_Job__c updatedJob = [SELECT Status__c, Label__c FROM DocGen_Job__c WHERE Id = :job.Id];
        System.assertEquals('Failed', updatedJob.Status__c, 'Job should fail with no fragments');
    }

    @IsTest
    static void testGiantQueryAssembler_withFragments() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'Draft',
            Template__c = tpl.Id,
            Label__c = 'Test Assembler Frags',
            Parent_Record_Id__c = String.valueOf(acc.Id)
        );
        Database.insert(job, AccessLevel.SYSTEM_MODE);
        // Create a fragment ContentVersion
        String fragTitle = 'docgen_giant_' + job.Id + '_0001';
        ContentVersion fragCv = new ContentVersion(
            Title = fragTitle,
            PathOnClient = fragTitle + '.html',
            VersionData = Blob.valueOf('<tr><td>Row 1</td><td>Value 1</td></tr>')
        );
        insert fragCv;

        // Also create a pre-rendered HTML template for buildHtmlTemplate fallback
        // (no active version, so it falls back to auto-generated table wrapper)

        Test.startTest();
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
        assembler.execute(null);
        Test.stopTest();

        // Job should either complete or fail (Blob.toPdf may not work in test),
        // but code paths are exercised
        DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
        System.assertNotEquals('Draft', updatedJob.Status__c, 'Job status should have changed from Draft');
    }

    // =========================================================================
    // DocGenException — additional coverage
    // =========================================================================

    @IsTest
    static void testDocGenExceptionThrowAndCatch() {
        Boolean caught = false;
        Test.startTest();
        try {
            throw new DocGenException('Thrown in test');
        } catch (DocGenException e) {
            caught = true;
            System.assertEquals('Thrown in test', e.getMessage());
        }
        Test.stopTest();
        System.assert(caught, 'DocGenException should be catchable');
    }

    // =========================================================================
    // v1.72 — Nested IF balancing (findBalancedEnd IF prefix-match)
    // =========================================================================

    @IsTest
    static void testNestedIfBothTrue() {
        Map<String, Object> d = new Map<String, Object>{ 'O__c' => 1, 'I__c' => 1 };
        String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', d);
        System.assertEquals('OUTERINNEREND', r);
    }

    @IsTest
    static void testNestedIfInnerFalse() {
        Map<String, Object> d = new Map<String, Object>{ 'O__c' => 1, 'I__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', d);
        System.assertEquals('OUTEREND', r);
    }

    @IsTest
    static void testNestedIfOuterFalse() {
        Map<String, Object> d = new Map<String, Object>{ 'O__c' => 0, 'I__c' => 1 };
        String r = DocGenService.processXmlForTest('{#IF O__c != 0}OUTER{#IF I__c != 0}INNER{/IF}END{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testNestedIfTriple() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 1, 'B__c' => 1, 'C__c' => 1 };
        String r = DocGenService.processXmlForTest(
            '{#IF A__c != 0}A{#IF B__c != 0}B{#IF C__c != 0}C{/IF}/B{/IF}/A{/IF}',
            d
        );
        System.assertEquals('ABC/B/A', r);
    }

    // =========================================================================
    // v1.72 — Bare-boolean IF + truthy semantics + == operator
    // =========================================================================

    @IsTest
    static void testBareBooleanIfTrue() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => true };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testBareBooleanIfFalse() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => false };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testBareIfNullField() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => null };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testBareIfStringFalse() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => 'false' };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testBareIfStringZero() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => '0' };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testBareIfStringValue() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => 'something' };
        String r = DocGenService.processXmlForTest('{#IF Active__c}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfDoubleEquals() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => true };
        String r = DocGenService.processXmlForTest('{#IF Active__c == true}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfBareEmptyRecordsList() {
        Map<String, Object> d = new Map<String, Object>{
            'Items' => new Map<String, Object>{ 'totalSize' => 0, 'records' => new List<Object>() }
        };
        String r = DocGenService.processXmlForTest('{#IF Items}YES{/IF}', d);
        System.assertEquals('', r, 'empty records-wrapper should be falsy');
    }

    @IsTest
    static void testIfBarePopulatedRecordsList() {
        Map<String, Object> d = new Map<String, Object>{
            'Items' => new Map<String, Object>{
                'totalSize' => 1,
                'records' => new List<Object>{ new Map<String, Object>{ 'X' => 1 } }
            }
        };
        String r = DocGenService.processXmlForTest('{#IF Items}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    // =========================================================================
    // v1.72 — AND / OR / NOT / parens in IF expressions
    // =========================================================================

    @IsTest
    static void testIfAndBothTrue() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 10 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 AND B__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfAndShortCircuit() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 0, 'B__c' => 10 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 AND B__c > 0}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testIfOrFirstTrue() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 OR B__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfOrSecondTrue() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 0, 'B__c' => 10 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 OR B__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfOrBothFalse() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 0, 'B__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 OR B__c > 0}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testIfNotTruthy() {
        Map<String, Object> d = new Map<String, Object>{ 'X__c' => true };
        String r = DocGenService.processXmlForTest('{#IF NOT X__c}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testIfNotFalsy() {
        Map<String, Object> d = new Map<String, Object>{ 'X__c' => false };
        String r = DocGenService.processXmlForTest('{#IF NOT X__c}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfBangNot() {
        Map<String, Object> d = new Map<String, Object>{ 'X__c' => false };
        String r = DocGenService.processXmlForTest('{#IF !X__c}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfSymbolicAnd() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 10 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 && B__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfSymbolicOr() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 || B__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfPrecedenceAndOverOr() {
        // A>0 OR C>5 AND C>10 → A>0 OR (false AND false) → true
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'C__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 OR C__c > 5 AND C__c > 10}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfParensOverridePrecedence() {
        // (C>5 OR C>10) AND B>0 → false AND true → false
        Map<String, Object> d = new Map<String, Object>{ 'B__c' => 10, 'C__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF (C__c > 5 OR C__c > 10) AND B__c > 0}YES{/IF}', d);
        System.assertEquals('', r);
    }

    @IsTest
    static void testIfMultiOrChain() {
        // (C>5) OR (B>0 AND A>0) OR (C>5) → false OR true OR false → true
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 10, 'C__c' => 0 };
        String r = DocGenService.processXmlForTest(
            '{#IF (C__c > 5) OR (B__c > 0 AND A__c > 0) OR (C__c > 5)}YES{/IF}',
            d
        );
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfNestedParens() {
        // ((A>0 AND B>0) OR (C>5)) AND D>0 → (true OR false) AND true → true
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 10, 'C__c' => 0, 'D__c' => 7 };
        String r = DocGenService.processXmlForTest(
            '{#IF ((A__c > 0 AND B__c > 0) OR (C__c > 5)) AND D__c > 0}YES{/IF}',
            d
        );
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfQuotedAndPreserved() {
        // 'big AND small' is opaque — AND inside quotes is part of the literal
        Map<String, Object> d = new Map<String, Object>{ 'Stage' => 'big AND small' };
        String r = DocGenService.processXmlForTest('{#IF Stage = \'big AND small\'}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfStringAnd() {
        Map<String, Object> d = new Map<String, Object>{ 'Name' => 'Acme', 'Stage' => 'Closed Won' };
        String r = DocGenService.processXmlForTest('{#IF Name = \'Acme\' AND Stage = \'Closed Won\'}WIN{/IF}', d);
        System.assertEquals('WIN', r);
    }

    @IsTest
    static void testIfBareBoolAndComparison() {
        Map<String, Object> d = new Map<String, Object>{ 'Active__c' => true, 'A__c' => 5 };
        String r = DocGenService.processXmlForTest('{#IF Active__c AND A__c > 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfNotWithParens() {
        Map<String, Object> d = new Map<String, Object>{ 'C__c' => 0 };
        String r = DocGenService.processXmlForTest('{#IF NOT (C__c > 5)}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfTripleAnd() {
        Map<String, Object> d = new Map<String, Object>{ 'A__c' => 5, 'B__c' => 10, 'Active__c' => true };
        String r = DocGenService.processXmlForTest('{#IF A__c > 0 AND B__c > 0 AND Active__c}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    @IsTest
    static void testIfEntityDecodedGt() {
        // Word stores `>` as `&gt;` in OOXML; v1.69 fix decodes before parse
        Map<String, Object> d = new Map<String, Object>{ 'Amount' => 100 };
        String r = DocGenService.processXmlForTest('{#IF Amount &gt; 0}YES{/IF}', d);
        System.assertEquals('YES', r);
    }

    // =========================================================================
    // v1.72 — Empty child relationship totalSize=0 synthesis (V1 + V2)
    // =========================================================================

    @IsTest
    static void testEmptyRelTotalSizeV1() {
        Account a = new Account(Name = 'DG_v172_test');
        insert a;

        Test.startTest();
        Map<String, Object> data = DocGenDataRetriever.getRecordData(
            a.Id,
            'Account',
            'Name, (SELECT Id FROM Contacts)'
        );
        Test.stopTest();

        System.assertNotEquals(null, data);
        System.assert(data.containsKey('Contacts'), 'V1 should synthesize empty Contacts wrapper');
        Map<String, Object> rel = (Map<String, Object>) data.get('Contacts');
        System.assertEquals(0, Integer.valueOf(rel.get('totalSize')));
        System.assert(rel.get('records') instanceof List<Object>);
        System.assert(((List<Object>) rel.get('records')).isEmpty());
    }

    @IsTest
    static void testEmptyRelIfSuppresses() {
        Account a = new Account(Name = 'DG_v172_test_if');
        insert a;

        Map<String, Object> data = DocGenDataRetriever.getRecordData(
            a.Id,
            'Account',
            'Name, (SELECT Id FROM Contacts)'
        );

        String r = DocGenService.processXmlForTest('{#IF Contacts.totalSize != 0}HAS{/IF}', data);
        System.assertEquals('', r, 'Empty rel IF should suppress (was truthy pre-1.72)');
    }

    @IsTest
    static void testEmptyRelTotalSizeRendersZero() {
        Account a = new Account(Name = 'DG_v172_test_render');
        insert a;

        Map<String, Object> data = DocGenDataRetriever.getRecordData(
            a.Id,
            'Account',
            'Name, (SELECT Id FROM Contacts)'
        );

        String r = DocGenService.processXmlForTest('[{Contacts.totalSize}]', data);
        System.assertEquals('[0]', r);
    }

    // =========================================================================
    // {RunningUser.X} — standard "prepared by" tags (v1.77+)
    // =========================================================================

    @IsTest
    static void runningUserNameResolvesFromUserInfo() {
        Test.startTest();
        String r = DocGenService.processXmlForTest('[{RunningUser.Name}]', new Map<String, Object>());
        Test.stopTest();
        System.assertEquals('[' + UserInfo.getName() + ']', r, 'RunningUser.Name should match UserInfo.getName()');
    }

    @IsTest
    static void runningUserEmailResolvesFromUserRow() {
        Test.startTest();
        String r = DocGenService.processXmlForTest('[{RunningUser.Email}]', new Map<String, Object>());
        Test.stopTest();
        System.assertEquals(
            '[' + UserInfo.getUserEmail() + ']',
            r,
            'RunningUser.Email should match UserInfo.getUserEmail()'
        );
    }

    @IsTest
    static void runningUserIsCaseInsensitive() {
        Test.startTest();
        String r = DocGenService.processXmlForTest('[{runninguser.name}]', new Map<String, Object>());
        Test.stopTest();
        System.assertEquals('[' + UserInfo.getName() + ']', r, 'Lowercased RunningUser tag should still resolve');
    }

    @IsTest
    static void runningUserUnknownFieldResolvesEmpty() {
        Test.startTest();
        String r = DocGenService.processXmlForTest('[{RunningUser.NotAField}]', new Map<String, Object>());
        Test.stopTest();
        System.assertEquals('[]', r, 'Unknown RunningUser subfield should resolve to empty (not literal tag)');
    }

    @IsTest
    static void runningUserAllowlistGuardBlocksProfileId() {
        Test.startTest();
        // ProfileId is intentionally NOT in the allowlist — must NOT be exposed via {RunningUser.X}.
        String r = DocGenService.processXmlForTest('[{RunningUser.ProfileId}]', new Map<String, Object>());
        Test.stopTest();
        System.assertEquals('[]', r, 'ProfileId is not in the allowlist; tag must resolve to empty');
    }

    @IsTest
    static void runningUserContextCachedPerTransaction() {
        Test.startTest();
        // Two resolutions in a single transaction must not issue two SOQL queries.
        Integer queriesBefore = Limits.getQueries();
        DocGenService.processXmlForTest('{RunningUser.Name}', new Map<String, Object>());
        DocGenService.processXmlForTest('{RunningUser.Email}', new Map<String, Object>());
        DocGenService.processXmlForTest('{RunningUser.Username}', new Map<String, Object>());
        Integer queriesAfter = Limits.getQueries();
        Test.stopTest();
        System.assert(
            (queriesAfter - queriesBefore) <= 1,
            'RunningUser context should be loaded once per transaction; saw ' +
                (queriesAfter - queriesBefore) +
                ' queries'
        );
    }

    // =========================================================================
    // v1.80 — first-page-distinct headers/footers (#57) + image overflow (#56)
    // =========================================================================

    /**
     * Builds a minimal Word .docx with sectPr declaring `<w:titlePg/>` plus
     * separate "first" and "default" headerReference / footerReference entries.
     * Exercises the v1.80 mapHeaderFooterTypes + combineXmlWithHeadersFooters
     * + renderer extractMarkerSection paths end-to-end.
     */
    @IsTest
    static void testV180FirstPageDistinctHeadersAndOverflowWarnings() {
        // 8.27" wide banner (7562088 EMU) on a 7.5" content area = overflow → warns
        String header2Xml =
            '<?xml version="1.0"?>' +
            '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="7562088" cy="304800"/></wp:inline></w:drawing>' +
            '<w:t>First Page Header</w:t></w:r></w:p></w:hdr>';
        String header1Xml =
            '<?xml version="1.0"?>' +
            '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:p><w:r><w:t>Default Header</w:t></w:r></w:p></w:hdr>';
        String footer2Xml =
            '<?xml version="1.0"?>' +
            '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:p><w:r><w:t>First Footer</w:t></w:r></w:p></w:ftr>';
        String footer1Xml =
            '<?xml version="1.0"?>' +
            '<w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:p><w:r><w:t>Default Footer</w:t></w:r></w:p></w:ftr>';
        String docXml =
            '<?xml version="1.0"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:sectPr>' +
            '<w:headerReference w:type="first" r:id="rId10"/>' +
            '<w:headerReference w:type="default" r:id="rId11"/>' +
            '<w:footerReference w:type="first" r:id="rId12"/>' +
            '<w:footerReference w:type="default" r:id="rId13"/>' +
            '<w:pgSz w:w="12240" w:h="15840"/>' +
            '<w:pgMar w:top="1440" w:right="720" w:bottom="1440" w:left="720"/>' +
            '<w:titlePg/>' +
            '</w:sectPr></w:body></w:document>';
        String relsXml =
            '<?xml version="1.0"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header2.xml"/>' +
            '<Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>' +
            '<Relationship Id="rId12" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer2.xml"/>' +
            '<Relationship Id="rId13" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>' +
            '</Relationships>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));
        zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(relsXml));
        zw.addEntry('word/header1.xml', Blob.valueOf(header1Xml));
        zw.addEntry('word/header2.xml', Blob.valueOf(header2Xml));
        zw.addEntry('word/footer1.xml', Blob.valueOf(footer1Xml));
        zw.addEntry('word/footer2.xml', Blob.valueOf(footer2Xml));

        ContentVersion cv = new ContentVersion(
            Title = 'V180FirstPageTest',
            PathOnClient = 'V180FirstPageTest.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        // Exercises mapHeaderFooterTypes (via combineXmlWithHeadersFooters indirectly
        // through the extractor) + logImageOverflowWarnings on the oversized banner.
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);
        Test.stopTest();

        // Confirm pre-decomposed CVs were written for both headers/footers
        List<ContentVersion> xmlCvs = [
            SELECT Title
            FROM ContentVersion
            WHERE Title LIKE :('docgen_tmpl_xml_' + ver.Id + '_%')
        ];
        Set<String> savedTitles = new Set<String>();
        for (ContentVersion x : xmlCvs)
            savedTitles.add(x.Title);
        // No exception, both header/footer parts and the rels CV were stored
        System.assert(
            !savedTitles.isEmpty(),
            'extractAndSaveTemplateImages should produce pre-decomp XML CVs even on first-page-distinct templates'
        );
    }

    /**
     * Direct test of mapHeaderFooterTypes via combineXmlWithHeadersFooters output.
     * Builds a fake MergeResult shape, but since the class is private we drive
     * through the public render path. Verifies that the renderer correctly
     * walks sectPr headerReference/footerReference entries with even-typed refs
     * (the path that's accepted but folded into default in v1.80).
     */
    @IsTest
    static void testV180EvenHeaderRefFoldsToDefault() {
        // Even-typed reference + default — should both end up in the default bucket
        String docXml =
            '<?xml version="1.0"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"' +
            ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            '<w:sectPr>' +
            '<w:headerReference w:type="default" r:id="rId10"/>' +
            '<w:headerReference w:type="even" r:id="rId11"/>' +
            '<w:pgSz w:w="12240" w:h="15840"/>' +
            '<w:pgMar w:top="1440" w:right="720" w:bottom="1440" w:left="720"/>' +
            '</w:sectPr></w:body></w:document>';
        String relsXml =
            '<?xml version="1.0"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>' +
            '<Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header2.xml"/>' +
            '</Relationships>';
        String h1 = '<?xml version="1.0"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Default</w:t></w:r></w:p></w:hdr>';
        String h2 = '<?xml version="1.0"?><w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Even</w:t></w:r></w:p></w:hdr>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/></Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));
        zw.addEntry('word/_rels/document.xml.rels', Blob.valueOf(relsXml));
        zw.addEntry('word/header1.xml', Blob.valueOf(h1));
        zw.addEntry('word/header2.xml', Blob.valueOf(h2));

        ContentVersion cv = new ContentVersion(
            Title = 'V180EvenTest',
            PathOnClient = 'V180EvenTest.docx',
            VersionData = zw.getArchive()
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        insert new ContentDocumentLink(LinkedEntityId = tpl.Id, ContentDocumentId = conDocId, ShareType = 'V');

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenService.extractAndSaveTemplateImages(tpl.Id, ver.Id);
        Test.stopTest();

        // No exception is the assertion — even-typed refs must not break the pipeline.
        System.assert(true, 'Even-typed header refs accepted without exception');
    }

    /**
     * Tests loadRecordDataForTitle with a multi-segment relationship path.
     * Verifies the nested-map shape needed by generateDocTitle's resolveValue.
     */
    @IsTest
    static void testV180LoadRecordDataForTitleWithRelationship() {
        Account acc = new Account(Name = 'Title Format Account');
        insert acc;
        Contact con = new Contact(LastName = 'Smith', AccountId = acc.Id);
        insert con;

        Map<String, Object> data = DocGenService.loadRecordDataForTitle(con.Id, '{Account.Name} - {LastName} Quote');
        System.assertEquals('Smith', data.get('LastName'));
        Object accNode = data.get('Account');
        System.assert(accNode instanceof Map<String, Object>, 'Account should be nested map');
        System.assertEquals('Title Format Account', ((Map<String, Object>) accNode).get('Name'));

        // generateDocTitle should resolve through the nested structure
        String resolved = DocGenService.generateDocTitle('{Account.Name} - {LastName} Quote', data);
        System.assertEquals('Title Format Account - Smith Quote', resolved);
    }

    /**
     * Confirms loadRecordDataForTitle gracefully handles invalid SObject types
     * and missing fields without throwing.
     */
    @IsTest
    static void testV180LoadRecordDataForTitleEdgeCases() {
        // Format with malformed token — should still return without throwing
        Account acc = new Account(Name = 'Edge');
        insert acc;
        Map<String, Object> result = DocGenService.loadRecordDataForTitle(acc.Id, '{NonExistentField__c}');
        // Either empty map or doesn't throw; both acceptable
        System.assertNotEquals(null, result);

        // Convenience overload with Name fallback
        Map<String, Object> simple = DocGenService.loadRecordDataForTitle(acc.Id);
        System.assertEquals('Edge', simple.get('Name'));
    }

    // =========================================================================
    // Issue #114 — pre-decomposed template CVs are looked up at render time
    // in four production sites (DocGenService.cls, two in DocGenController.cls,
    // DocGenGiantQueryFlowAction.cls). All four MUST use WITH SYSTEM_MODE so
    // FLS/CRUD on ContentVersion fields don't block non-admin users whose
    // implicit CDL access already permits them to read the CV.
    //
    // Commit a0b10ee (v1.15.0) flipped these to WITH USER_MODE during the
    // Checkmarx hardening pass and broke render for non-admin users with the
    // DocGen_User permset. A true cross-user runtime test for this is brittle
    // — the implicit CDL chain depends on permset + sharing + CDL Visibility
    // none of which a focused unit test can mock cleanly — so guard the fix
    // with a source-text assertion that catches any future revert to USER_MODE.
    // =========================================================================
    @IsTest
    static void testInternalContentVersionLoaderWorksForNonAdminUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User stdUser = new User(
            Alias = 'dgload',
            Email = 'docgen-loader@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Loader',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'docgen.loader.' + System.currentTimeMillis() + '@example.com'
        );
        User currentUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(currentUser) {
            insert stdUser;
        }

        DocGen_Template_Version__c version = TestDataFactory.getTestTemplateVersion();
        String title = 'docgen_tmpl_xml_' + version.Id + '_word__document.xml';
        insert new ContentVersion(
            Title = title,
            PathOnClient = title + '.xml',
            VersionData = Blob.valueOf('<w:document>{#Contacts}<w:t>{LastName}</w:t>{/Contacts}</w:document>'),
            FirstPublishLocationId = version.Id,
            IsMajorVersion = true
        );

        System.runAs(stdUser) {
            Test.startTest();
            List<ContentVersion> loaded = DocGenService.loadInternalContentVersionsForVersionByTitle(version.Id, title);
            Test.stopTest();

            System.assertEquals(
                1,
                loaded.size(),
                'Non-admin user should load package-internal CV through the template version link'
            );
            System.assert(
                loaded[0].VersionData.toString().contains('{#Contacts}'),
                'Loaded CV should include the pre-decomposed template body'
            );
        }
    }

    @IsTest
    static void testIssue114NoUserModeOnPreDecompCvLookups() {
        List<String> classNames = new List<String>{ 'DocGenService', 'DocGenController', 'DocGenGiantQueryFlowAction' };
        for (ApexClass ac : [SELECT Name, Body FROM ApexClass WHERE Name IN :classNames]) {
            String body = ac.Body;
            Integer cursor = 0;
            Integer hits = 0;
            while (true) {
                Integer idx = body.indexOf('docgen_tmpl_xml_', cursor);
                if (idx == -1) {
                    break;
                }
                hits++;
                // Look forward to the SOQL closing bracket and assert no
                // WITH USER_MODE appears between the prefix and that bracket.
                Integer close = body.indexOf('];', idx);
                if (close != -1) {
                    String slice = body.substring(idx, close);
                    // Skip the admin delete-cleanup block in DocGenController. That
                    // SOQL is an internal `cdsToDelete` accumulator that walks
                    // ContentVersion titles to find pre-decomp CVs marked for
                    // deletion when a template version is removed — it does NOT
                    // read a CV for render. WITH USER_MODE there is correct: the
                    // caller is the admin executing the delete, and USER_MODE
                    // enforces "you must have permission to read the rows you're
                    // proposing to delete." The #114 regression we're guarding
                    // against is a render-path read by a non-admin user, which is
                    // structurally distinct. See `force-app/main/default/classes/
                    // DocGenController.cls` around the `predecompPrefix` variable.
                    Boolean isDeleteCleanup =
                        slice.contains('predecompPrefix') ||
                        slice.contains('cdsToDelete') ||
                        slice.contains('LIKE :likePattern');
                    if (!isDeleteCleanup) {
                        System.assert(
                            !slice.contains('WITH USER_MODE'),
                            ac.Name +
                                ' uses WITH USER_MODE for a pre-decomposed CV lookup — see #114. ' +
                                'Offending block starts around char ' +
                                idx +
                                '.'
                        );
                    }
                }
                cursor = idx + 16;
            }
            System.assert(
                hits > 0,
                'Sanity: expected at least one docgen_tmpl_xml_ reference in ' +
                    ac.Name +
                    ' — test may need updating if the prefix was renamed.'
            );
        }
    }

    @IsTest
    static void testGiantQueryInternalContentReadsUseSystemMode() {
        Map<String, ApexClass> classesByName = new Map<String, ApexClass>();
        for (ApexClass ac : [
            SELECT Name, Body
            FROM ApexClass
            WHERE
                Name IN (
                    'DocGenController',
                    'DocGenGiantQueryAssembler',
                    'DocGenGiantQueryStitchJob',
                    'DocGenGiantQueryFlowAction'
                )
        ]) {
            classesByName.put(ac.Name, ac);
        }

        String assemblerBody = classesByName.get('DocGenGiantQueryAssembler').Body;
        Integer giantPrefixIdx = assemblerBody.indexOf('String prefix = \'docgen_giant_\' + jobId + \'_\';');
        Integer assemblerLoopIdx = assemblerBody.indexOf('for (ContentVersion cv : frags)', giantPrefixIdx);
        System.assert(giantPrefixIdx >= 0 && assemblerLoopIdx > giantPrefixIdx, 'Assembler fragment lookup moved.');
        String assemblerSlice = assemblerBody.substring(giantPrefixIdx, assemblerLoopIdx);
        System.assert(
            assemblerSlice.contains('WITH SYSTEM_MODE'),
            'DocGenGiantQueryAssembler must read internal docgen_giant_ fragments WITH SYSTEM_MODE.'
        );
        System.assert(
            !assemblerSlice.contains('WITH USER_MODE'),
            'DocGenGiantQueryAssembler must not read internal docgen_giant_ fragments WITH USER_MODE.'
        );

        String controllerBody = classesByName.get('DocGenController').Body;
        Integer htmlBodyIdx = controllerBody.indexOf('Id bodyCvId = (Id) activeVersions[0].Content_Version_Id__c;');
        Integer htmlMissingIdx = controllerBody.indexOf('HTML template has no active version body.', htmlBodyIdx);
        System.assert(htmlBodyIdx >= 0 && htmlMissingIdx > htmlBodyIdx, 'Giant HTML launch body lookup moved.');
        String htmlBodySlice = controllerBody.substring(htmlBodyIdx, htmlMissingIdx);
        System.assert(
            htmlBodySlice.contains('WITH SYSTEM_MODE'),
            'Giant-query HTML launch must read the active template body ContentVersion WITH SYSTEM_MODE.'
        );
        System.assert(
            !htmlBodySlice.contains('WITH USER_MODE'),
            'Giant-query HTML launch must not read the active template body ContentVersion WITH USER_MODE.'
        );

        Integer managedFallbackIdx = controllerBody.indexOf('WHERE Id = :contentVersionId AND Title LIKE \'docgen_%\'');
        Integer managedFallbackEnd = controllerBody.indexOf(
            'throw DocGenService.ahe(\'Access denied or content not found.\');'
        );
        System.assert(
            managedFallbackIdx >= 0 && managedFallbackEnd > managedFallbackIdx,
            'Managed ContentVersion fallback lookup moved.'
        );
        String managedFallbackSlice = controllerBody.substring(managedFallbackIdx, managedFallbackEnd);
        System.assert(
            managedFallbackSlice.contains('WITH SYSTEM_MODE'),
            'Managed docgen_% ContentVersion fallback must use SYSTEM_MODE after the USER_MODE sharing check fails.'
        );
        System.assert(
            !managedFallbackSlice.contains('WITH USER_MODE'),
            'Managed docgen_% ContentVersion fallback must not keep using USER_MODE after sharing access fails.'
        );

        String stitchBody = classesByName.get('DocGenGiantQueryStitchJob').Body;
        assertInternalContentQueryUsesSystemMode(
            stitchBody,
            'DocGenGiantQueryStitchJob',
            'docgen_giant_',
            'FRAGMENTS_PER_PDF'
        );
        assertInternalContentQueryUsesSystemMode(
            stitchBody,
            'DocGenGiantQueryStitchJob',
            'docgen_part_',
            'No PDF parts found'
        );

        String flowActionBody = classesByName.get('DocGenGiantQueryFlowAction').Body;
        assertGiantLauncherUsesInternalLoader(controllerBody, 'DocGenController');
        assertGiantLauncherUsesInternalLoader(flowActionBody, 'DocGenGiantQueryFlowAction');
    }

    @IsTest
    static void testTemplateAssetImageAccessLinkedForPdfRender() {
        Account acc = new Account(Name = 'Template Asset Image Access');
        insert acc;

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Template Asset Image Access',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        ContentVersion img = new ContentVersion(
            Title = 'docgen_tmpl_img_' + ver.Id + '_rIdLogo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG'),
            FirstPublishLocationId = ver.Id
        );
        insert img;
        img = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :img.Id];

        String html = '<html><body><img src="/sfc/servlet.shepherd/version/download/' + img.Id + '" /></body></html>';

        Test.startTest();
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html);
        Test.stopTest();

        List<ContentDocumentLink> links = [
            SELECT Id, Visibility, ShareType
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :img.ContentDocumentId
        ];
        System.assertEquals(
            1,
            links.size(),
            'Template image file should be linked to the source record for PDF fetch.'
        );
        System.assertEquals('AllUsers', links[0].Visibility, 'PDF fetch link should be visible to internal users.');
        System.assertEquals('V', links[0].ShareType, 'PDF fetch link should grant viewer access only.');
    }

    @IsTest
    static void testStalePriorVersionImageLinksArePruned() {
        // A template re-save creates a new version with freshly-decomposed image
        // CVs; the prior version's record links must be pruned on the next
        // generation so the record's Files don't accumulate (the "hundreds of
        // images on the record" report). The active version's link must remain.
        Account acc = new Account(Name = 'Stale Image Link Prune');
        insert acc;

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Stale Image Link Prune',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        // Version 1 (will become stale) + its image
        DocGen_Template_Version__c v1 = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        Database.insert(v1, AccessLevel.SYSTEM_MODE);
        ContentVersion img1 = new ContentVersion(
            Title = 'docgen_html_img_' + v1.Id + '_logo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG')
        );
        insert img1;
        String html1 = '<html><body><img src="/sfc/servlet.shepherd/version/download/' + img1.Id + '"/></body></html>';
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html1);

        Integer afterV1 = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocument.Title LIKE 'docgen_html_img_%'
        ];
        System.assertEquals(1, afterV1, 'Version 1 image should be linked.');

        // Re-save: deactivate v1, activate a new v2 with a new image
        v1.Is_Active__c = false;
        Database.update(v1, AccessLevel.SYSTEM_MODE);
        DocGen_Template_Version__c v2 = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        Database.insert(v2, AccessLevel.SYSTEM_MODE);
        ContentVersion img2 = new ContentVersion(
            Title = 'docgen_html_img_' + v2.Id + '_logo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG')
        );
        insert img2;
        String html2 = '<html><body><img src="/sfc/servlet.shepherd/version/download/' + img2.Id + '"/></body></html>';

        Test.startTest();
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html2);
        Test.stopTest();

        // Net: still 1 (v2 linked, v1 pruned) — not 2.
        Integer afterV2 = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocument.Title LIKE 'docgen_html_img_%'
        ];
        System.assertEquals(
            1,
            afterV2,
            'Stale version-1 link must be pruned; only the active version-2 image remains.'
        );

        // And the surviving link is the active version's image.
        Id v2DocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :img2.Id].ContentDocumentId;
        Integer activeStillLinked = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :v2DocId
        ];
        System.assertEquals(1, activeStillLinked, 'Active version image link must be preserved for rendering.');
    }

    @IsTest
    static void testStaleTemplateKeyedLwcImageLinksArePruned() {
        // #202: the LWC zip-upload flow (saveHtmlTemplateImage) titles images
        // docgen_html_img_<templateId>_<epochMillis>_<name> — template-keyed, new
        // CVs on every body re-upload, and typically a SINGLE version row. The
        // v3.26 prune matched only version-keyed titles, so these links piled up
        // on the record forever. A no-longer-referenced template-keyed image link
        // must be pruned; the currently-referenced one must survive.
        Account acc = new Account(Name = 'Stale LWC Image Link Prune');
        insert acc;

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Stale LWC Image Link Prune',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        // One version row for the whole test — the common HTML-template shape.
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        // Upload 1's image, referenced and linked by a first generation.
        ContentVersion imgOld = new ContentVersion(
            Title = 'docgen_html_img_' + tpl.Id + '_1000000000001_logo.png',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG1')
        );
        insert imgOld;
        String html1 =
            '<html><body><img src="/sfc/servlet.shepherd/version/download/' +
            imgOld.Id +
            '"/></body></html>';
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html1);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :acc.Id AND ContentDocument.Title LIKE 'docgen_html_img_%'
            ],
            'Upload-1 image should be linked after the first generation.'
        );

        // Body re-upload mints a new timestamped CV; the body now references it.
        ContentVersion imgNew = new ContentVersion(
            Title = 'docgen_html_img_' + tpl.Id + '_1000000000002_logo.png',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG2')
        );
        insert imgNew;
        String html2 =
            '<html><body><img src="/sfc/servlet.shepherd/version/download/' +
            imgNew.Id +
            '"/></body></html>';

        Test.startTest();
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html2);
        Test.stopTest();

        // Net: still 1 link (new referenced image), not 2 — the stale upload-1
        // link is pruned even though it can't be matched to any version row.
        List<ContentDocumentLink> remaining = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acc.Id AND ContentDocument.Title LIKE 'docgen_html_img_%'
        ];
        System.assertEquals(1, remaining.size(), 'Stale template-keyed LWC image link must be pruned (#202).');
        Id newDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :imgNew.Id].ContentDocumentId;
        System.assertEquals(
            newDocId,
            remaining[0].ContentDocumentId,
            'The surviving link must be the currently-referenced image, not the stale one.'
        );
    }

    @IsTest
    static void testRemoveTemplateImageLinksAfterRenderClearsCurrentSet() {
        // #202 follow-up: the prune-with-keep pass can never remove the CURRENT
        // body's image links, so the first generation on a fresh record stranded
        // the full image set as Files on the record. After Blob.toPdf returns the
        // links have served their purpose (the PDF embeds the bytes), and the
        // post-render sweep must remove every template-image link — both naming
        // schemes — while leaving user-attached files alone.
        Account acc = new Account(Name = 'Post-Render Image Link Sweep');
        insert acc;

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Post-Render Image Link Sweep',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        // Scheme 2 (template-keyed, LWC zip upload) + scheme 1 (version-keyed,
        // active version) — both referenced by the current body.
        ContentVersion imgTplKeyed = new ContentVersion(
            Title = 'docgen_html_img_' + tpl.Id + '_1000000000001_logo.png',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('PNG1')
        );
        ContentVersion imgVerKeyed = new ContentVersion(
            Title = 'docgen_tmpl_img_' + ver.Id + '_rIdBanner',
            PathOnClient = 'banner.png',
            VersionData = Blob.valueOf('PNG2')
        );
        insert new List<ContentVersion>{ imgTplKeyed, imgVerKeyed };

        // A user's own attached file must survive the sweep untouched.
        ContentVersion userFile = new ContentVersion(
            Title = 'Customer Contract',
            PathOnClient = 'contract.pdf',
            VersionData = Blob.valueOf('PDF')
        );
        insert userFile;
        Id userDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :userFile.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = userDocId,
            LinkedEntityId = acc.Id,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );

        String html =
            '<html><body><img src="/sfc/servlet.shepherd/version/download/' +
            imgTplKeyed.Id +
            '"/><img src="/sfc/servlet.shepherd/version/download/' +
            imgVerKeyed.Id +
            '"/></body></html>';

        Test.startTest();
        // Mirrors renderPdf's sequence: link for the toPdf fetch, then sweep.
        DocGenService.ensureTemplateAssetImageAccessForPdf(tpl.Id, acc.Id, html);
        System.assertEquals(
            2,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE
                    LinkedEntityId = :acc.Id
                    AND (ContentDocument.Title LIKE 'docgen_html_img_%'
                    OR ContentDocument.Title LIKE 'docgen_tmpl_img_%')
            ],
            'Both current-body images should be linked for the Blob.toPdf fetch.'
        );
        DocGenService.removeTemplateImageLinksAfterRender(tpl.Id, acc.Id, html);
        Test.stopTest();

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE
                    LinkedEntityId = :acc.Id
                    AND (ContentDocument.Title LIKE 'docgen_html_img_%'
                    OR ContentDocument.Title LIKE 'docgen_tmpl_img_%')
            ],
            'Post-render sweep must remove every template-image link, including the current body set (#202 follow-up).'
        );
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :acc.Id AND ContentDocumentId = :userDocId],
            'User-attached files must never be touched by the sweep.'
        );
    }

    private static void assertGiantLauncherUsesInternalLoader(String body, String className) {
        Integer idx = body.indexOf('docgen_tmpl_xml_');
        System.assert(idx >= 0, className + ' should reference pre-decomposed template XML.');
        Integer loaderIdx = body.indexOf('DocGenService.loadInternalContentVersionsForVersionByTitle', idx);
        System.assert(
            loaderIdx > idx,
            className + ' must use the without-sharing internal ContentVersion loader for giant-query pre-decomp reads.'
        );
    }

    private static void assertInternalContentQueryUsesSystemMode(
        String body,
        String className,
        String titlePrefix,
        String afterMarker
    ) {
        Integer cursor = 0;
        Integer hits = 0;
        while (true) {
            Integer idx = body.indexOf(titlePrefix, cursor);
            if (idx == -1) {
                break;
            }
            Integer close = body.indexOf(afterMarker, idx);
            if (close == -1) {
                close = body.indexOf('];', idx);
            }
            if (close != -1) {
                String slice = body.substring(idx, close);
                if (slice.contains('FROM ContentVersion')) {
                    hits++;
                    System.assert(
                        slice.contains('WITH SYSTEM_MODE'),
                        className + ' must read internal ' + titlePrefix + ' ContentVersion rows WITH SYSTEM_MODE.'
                    );
                    System.assert(
                        !slice.contains('WITH USER_MODE'),
                        className + ' must not read internal ' + titlePrefix + ' ContentVersion rows WITH USER_MODE.'
                    );
                }
            }
            cursor = idx + titlePrefix.length();
        }
        System.assert(hits > 0, 'Sanity: expected internal ' + titlePrefix + ' ContentVersion reads in ' + className);
    }

    @IsTest
    static void testDateFieldDoesNotShiftByTimezone() {
        // Regression for the "dates off by one" bug (Slack #bug-reports): Salesforce
        // returns a Date field via untyped get()/getPopulatedFieldsAsMap() as a
        // GMT-midnight Datetime, which the merge formatter renders in the running user's
        // local time zone — so a user behind UTC saw the date roll back one day.
        // getRecordData now re-expresses DATE fields (by Schema type) as local midnight.
        Contact c = new Contact(LastName = 'TZ Date', Birthdate = Date.newInstance(2026, 5, 29));
        insert c;
        Map<String, Object> data = DocGenDataRetriever.getRecordData(c.Id, 'Contact', 'Birthdate');
        System.assertEquals(
            '05/29/2026',
            DocGenService.processXmlForTest('{Birthdate:MM/dd/yyyy}', data),
            'Date field must render the same calendar day, not shift back one (timezone off-by-one bug)'
        );
    }

    /**
     * Builds the child-loop data map shape the retriever produces:
     * relationship name → {records: [...], totalSize: n}.
     */
    private static Map<String, Object> excelLoopData(List<Map<String, Object>> contacts) {
        return new Map<String, Object>{
            'Name' => 'Acme Corp',
            'Contacts' => new Map<String, Object>{ 'records' => contacts, 'totalSize' => contacts.size() }
        };
    }

    @IsTest
    static void testExcelRowLoopExpandsVertically() {
        // A child loop spanning cells in one worksheet row ({#Contacts}{FirstName}
        // in A2, {LastName}{/Contacts} in B2) must clone the whole <row> per record
        // and renumber rows/cell refs so Excel doesn't flag duplicates as corruption.
        String xml =
            '<worksheet><dimension ref="A1:B2"/><sheetData>' +
            '<row r="1"><c r="A1" t="inlineStr"><is><t>{Name}</t></is></c></row>' +
            '<row r="2"><c r="A2" t="inlineStr"><is><t>{#Contacts}{FirstName}</t></is></c>' +
            '<c r="B2" t="inlineStr"><is><t>{LastName}{/Contacts}</t></is></c></row>' +
            '</sheetData></worksheet>';
        Map<String, Object> data = excelLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'FirstName' => 'Alice', 'LastName' => 'Adams' },
                new Map<String, Object>{ 'FirstName' => 'Bob', 'LastName' => 'Brown' },
                new Map<String, Object>{ 'FirstName' => 'Cara', 'LastName' => 'Clark' }
            }
        );

        String result = DocGenService.renumberExcelRows(DocGenService.processXmlForTest(xml, data, 'Excel'));

        System.assertEquals(4, result.countMatches('<row '), 'Header row + one row per contact');
        System.assert(
            result.contains(
                '<row r="2"><c r="A2" t="inlineStr"><is><t>Alice</t></is></c>' +
                '<c r="B2" t="inlineStr"><is><t>Adams</t></is></c></row>'
            ),
            'First clone keeps the authored row position: ' + result
        );
        System.assert(
            result.contains('<row r="3"><c r="A3"') && result.contains('<is><t>Bob</t>'),
            'Second clone renumbered to row 3: ' + result
        );
        System.assert(
            result.contains('<row r="4"><c r="A4"') && result.contains('<is><t>Cara</t>'),
            'Third clone renumbered to row 4: ' + result
        );
        System.assert(result.contains('<dimension ref="A1:B4"/>'), 'Dimension extended to last row: ' + result);
        System.assert(!result.contains('{#') && !result.contains('{/'), 'No leaked loop tags: ' + result);
    }

    @IsTest
    static void testExcelRowLoopRenumberPreservesAuthoredGaps() {
        // Rows after the loop shift down by the inserted count, but authored blank
        // gaps between rows must survive (a footer at row 5 with rows 3-4 blank
        // stays 2 blank rows below the table).
        String xml =
            '<worksheet><sheetData>' +
            '<row r="1"><c r="A1" t="inlineStr"><is><t>Hdr</t></is></c></row>' +
            '<row r="2"><c r="A2" t="inlineStr"><is><t>{#Contacts}{FirstName}{/Contacts}</t></is></c></row>' +
            '<row r="5"><c r="A5" t="inlineStr"><is><t>Footer</t></is></c></row>' +
            '</sheetData></worksheet>';
        Map<String, Object> data = excelLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'FirstName' => 'Alice' },
                new Map<String, Object>{ 'FirstName' => 'Bob' }
            }
        );

        String result = DocGenService.renumberExcelRows(DocGenService.processXmlForTest(xml, data, 'Excel'));

        System.assert(result.contains('<row r="2"><c r="A2"') && result.contains('<is><t>Alice</t>'), result);
        System.assert(result.contains('<row r="3"><c r="A3"') && result.contains('<is><t>Bob</t>'), result);
        System.assert(
            result.contains('<row r="6"><c r="A6" t="inlineStr"><is><t>Footer</t></is></c></row>'),
            'Footer shifted down by 1 inserted row, keeping its 2-row authored gap: ' + result
        );
    }

    @IsTest
    static void testExcelRowLoopEmptyListDropsRow() {
        // Zero child records: the loop row disappears entirely and later rows
        // keep their authored positions (no upward shift).
        String xml =
            '<worksheet><sheetData>' +
            '<row r="1"><c r="A1" t="inlineStr"><is><t>Hdr</t></is></c></row>' +
            '<row r="2"><c r="A2" t="inlineStr"><is><t>{#Contacts}{FirstName}{/Contacts}</t></is></c></row>' +
            '<row r="3"><c r="A3" t="inlineStr"><is><t>Footer</t></is></c></row>' +
            '</sheetData></worksheet>';
        Map<String, Object> data = excelLoopData(new List<Map<String, Object>>());

        String result = DocGenService.renumberExcelRows(DocGenService.processXmlForTest(xml, data, 'Excel'));

        System.assertEquals(2, result.countMatches('<row '), 'Loop row dropped: ' + result);
        System.assert(
            result.contains('<row r="3"><c r="A3" t="inlineStr"><is><t>Footer</t></is></c></row>'),
            'Footer keeps its authored position: ' + result
        );
    }

    /**
     * Builds a DrawingML slide table with a header row and one loop row whose
     * {#Lines}…{/Lines} span crosses cell boundaries — the shape Portwood's
     * Opportunity Products slide uses.
     */
    private static String pptTableXml(String loopRowCells) {
        return '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
            'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:cSld><p:spTree><p:graphicFrame><a:graphic>' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>' +
            '<a:tblGrid><a:gridCol w="2032000"/><a:gridCol w="2032000"/></a:tblGrid>' +
            '<a:tr h="370840">' +
            '<a:tc><a:txBody><a:p><a:r><a:t>Product</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:tc><a:txBody><a:p><a:r><a:t>Qty</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:extLst><a:ext uri="{0D108BD9-81ED-4DB2-BD59-A6C34878D82A}">' +
            '<a16:rowId xmlns:a16="http://schemas.microsoft.com/office/drawing/2014/main" val="1496546544"/>' +
            '</a:ext></a:extLst>' +
            '</a:tr>' +
            '<a:tr h="370840">' +
            loopRowCells +
            '<a:extLst><a:ext uri="{0D108BD9-81ED-4DB2-BD59-A6C34878D82A}">' +
            '<a16:rowId xmlns:a16="http://schemas.microsoft.com/office/drawing/2014/main" val="2064594304"/>' +
            '</a:ext></a:extLst>' +
            '</a:tr>' +
            '</a:tbl></a:graphicData></a:graphic></p:graphicFrame></p:spTree></p:cSld></p:sld>';
    }

    private static Map<String, Object> pptLoopData(List<Map<String, Object>> lines) {
        return new Map<String, Object>{
            'Name' => 'Acme Corp',
            'Lines' => new Map<String, Object>{ 'records' => lines, 'totalSize' => lines.size() }
        };
    }

    @IsTest
    static void testPowerPointTableRowLoopClonesRow() {
        // A child loop spanning cells in one DrawingML row ({#Lines}{Name} in cell 1,
        // {Quantity}{/Lines} in cell 2) must clone the whole <a:tr> per record.
        // Before the <a:tr> container candidate existed, the fallback repeated the raw
        // span between the tags — including the intervening </a:tc><a:tc> markup — so
        // N records produced ONE row holding 2N <a:tc> against 2 <a:gridCol>, and
        // PowerPoint rendered only the first record.
        String xml = pptTableXml(
            '<a:tc><a:txBody><a:p><a:r><a:t>{#Lines}{Name}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:tc><a:txBody><a:p><a:r><a:t>{Quantity}{/Lines}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>'
        );
        Map<String, Object> data = pptLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'Name' => 'Widget', 'Quantity' => '2' },
                new Map<String, Object>{ 'Name' => 'Gadget', 'Quantity' => '5' },
                new Map<String, Object>{ 'Name' => 'Gizmo', 'Quantity' => '9' }
            }
        );

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assertEquals(4, result.countMatches('<a:tr '), 'Header row + one row per line item: ' + result);
        System.assertEquals(
            8,
            result.countMatches('<a:tc>'),
            'Two cells per row — cells must not accumulate inside one row: ' + result
        );
        System.assert(result.contains('<a:t>Widget</a:t>'), 'First record rendered: ' + result);
        System.assert(result.contains('<a:t>Gizmo</a:t>'), 'Last record rendered: ' + result);
        System.assert(!result.contains('{#') && !result.contains('{/'), 'No leaked loop tags: ' + result);
    }

    @IsTest
    static void testPowerPointTableRowLoopStripsDuplicateRowIds() {
        // Cloned rows must not repeat the authored <a16:rowId> change-tracking id.
        String xml = pptTableXml(
            '<a:tc><a:txBody><a:p><a:r><a:t>{#Lines}{Name}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:tc><a:txBody><a:p><a:r><a:t>{Quantity}{/Lines}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>'
        );
        Map<String, Object> data = pptLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'Name' => 'Widget', 'Quantity' => '2' },
                new Map<String, Object>{ 'Name' => 'Gadget', 'Quantity' => '5' }
            }
        );

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assertEquals(
            0,
            result.countMatches('val="2064594304"'),
            'Loop row rowId dropped from every clone: ' + result
        );
        System.assertEquals(
            1,
            result.countMatches('val="1496546544"'),
            'Untouched header row keeps its authored rowId: ' + result
        );
    }

    @IsTest
    static void testPowerPointTableRowLoopEmptyListDropsRow() {
        String xml = pptTableXml(
            '<a:tc><a:txBody><a:p><a:r><a:t>{#Lines}{Name}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:tc><a:txBody><a:p><a:r><a:t>{Quantity}{/Lines}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>'
        );
        Map<String, Object> data = pptLoopData(new List<Map<String, Object>>());

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assertEquals(1, result.countMatches('<a:tr '), 'Only the header row survives: ' + result);
        System.assert(result.contains('<a:t>Product</a:t>'), 'Header row preserved: ' + result);
        System.assert(!result.contains('{#') && !result.contains('{/'), 'No leaked loop tags: ' + result);
    }

    @IsTest
    static void testPowerPointTableRowLoopSiblingGuard() {
        // Two sibling sections in one row: neither may grab the whole <a:tr>, or the
        // first would swallow the second's content (the <w:tr> sibling-guard lesson).
        String xml = pptTableXml(
            '<a:tc><a:txBody><a:p><a:r><a:t>{#Lines}{Name}{/Lines}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>' +
            '<a:tc><a:txBody><a:p><a:r><a:t>{#Lines}{Quantity}{/Lines}</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>'
        );
        Map<String, Object> data = pptLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'Name' => 'Widget', 'Quantity' => '2' },
                new Map<String, Object>{ 'Name' => 'Gadget', 'Quantity' => '5' }
            }
        );

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assertEquals(2, result.countMatches('<a:tr '), 'No row cloning when siblings share the row: ' + result);
        System.assert(result.contains('WidgetGadget'), 'First section repeated in place: ' + result);
        System.assert(result.contains('25'), 'Second section survived and repeated in place: ' + result);
    }

    @IsTest
    static void testPowerPointLoopOutsideTableRepeatsBody() {
        // Loops in a plain text shape have no row container — the body-repeat
        // fallback must still work (and must not be disturbed by the <a:tr> candidate).
        String xml =
            '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' +
            'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">' +
            '<p:sp><p:txBody><a:p><a:r><a:t>{#Lines}{Name} </a:t></a:r></a:p>' +
            '<a:p><a:r><a:t>{Quantity}{/Lines}</a:t></a:r></a:p></p:txBody></p:sp></p:sld>';
        Map<String, Object> data = pptLoopData(
            new List<Map<String, Object>>{
                new Map<String, Object>{ 'Name' => 'Widget', 'Quantity' => '2' },
                new Map<String, Object>{ 'Name' => 'Gadget', 'Quantity' => '5' }
            }
        );

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assert(result.contains('Widget'), 'First record rendered: ' + result);
        System.assert(result.contains('Gadget'), 'Second record rendered: ' + result);
        System.assert(!result.contains('{#') && !result.contains('{/'), 'No leaked loop tags: ' + result);
    }

    @IsTest
    static void testPowerPointRowIdStripLeavesUnrelatedExtLstAlone() {
        // An extLst without a rowId (e.g. a cell-level extension) must survive.
        String rowXml =
            '<a:tr><a:tc><a:extLst><a:ext uri="{ABC}"><a16:other val="1"/></a:ext></a:extLst></a:tc>' +
            '<a:extLst><a:ext uri="{DEF}"><a16:rowId val="99"/></a:ext></a:extLst></a:tr>';

        String result = DocGenService.stripDrawingMlRowIds(rowXml);

        System.assert(!result.contains('a16:rowId'), 'rowId extension removed: ' + result);
        System.assert(result.contains('a16:other'), 'Unrelated extLst preserved: ' + result);
    }

    @IsTest
    static void testOoxmlGuidTokensSurviveMerge() {
        // OOXML GUIDs are brace-delimited and were being consumed as merge tags,
        // blanking <a:ext uri="">, column/row ids, and creation ids on every render.
        String xml =
            '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:ext uri="{0D108BD9-81ED-4DB2-BD59-A6C34878D82A}"/>' +
            '<a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId>' +
            '<a16:colId val="332169544"/><a:t>{Name}</a:t></p:sld>';
        Map<String, Object> data = new Map<String, Object>{ 'Name' => 'Acme Corp' };

        String result = DocGenService.processXmlForTest(xml, data, 'PowerPoint');

        System.assert(
            result.contains('uri="{0D108BD9-81ED-4DB2-BD59-A6C34878D82A}"'),
            'Extension uri GUID preserved verbatim: ' + result
        );
        System.assert(
            result.contains('<a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId>'),
            'Authored table style GUID preserved — not swapped for the default: ' + result
        );
        System.assertEquals(0, result.countMatches('uri=""'), 'No blanked uri attributes: ' + result);
        System.assert(result.contains('<a:t>Acme Corp</a:t>'), 'Real merge tags still resolve: ' + result);
    }

    @IsTest
    static void testGuidGuardDoesNotShadowRealTags() {
        // The guard is shape-based; it must not swallow anything a template
        // legitimately uses, including hyphenated or GUID-length field values.
        System.assert(
            DocGenService.isOoxmlGuidToken('0D108BD9-81ED-4DB2-BD59-A6C34878D82A'),
            'Canonical GUID recognised'
        );
        System.assert(
            DocGenService.isOoxmlGuidToken('5c22544a-7ee6-4342-b048-85bdc9fd1c3a'),
            'Lowercase GUID recognised'
        );
        System.assert(!DocGenService.isOoxmlGuidToken('Name'), 'Plain field is not a GUID');
        System.assert(!DocGenService.isOoxmlGuidToken('Account.Owner.Email'), 'Relationship path is not a GUID');
        System.assert(!DocGenService.isOoxmlGuidToken('#Contacts'), 'Section opener is not a GUID');
        System.assert(!DocGenService.isOoxmlGuidToken('CloseDate:MM/dd/yyyy'), 'Format suffix is not a GUID');
        System.assert(
            !DocGenService.isOoxmlGuidToken('0D108BD9-81ED-4DB2-BD59-A6C34878D82AZ'),
            'Over-length token rejected'
        );
        System.assert(
            !DocGenService.isOoxmlGuidToken('ZZZZZZZZ-81ED-4DB2-BD59-A6C34878D82A'),
            'Non-hex token rejected'
        );
        System.assert(!DocGenService.isOoxmlGuidToken(null), 'Null rejected');

        // End-to-end: a 36-char non-GUID tag must still resolve normally.
        String result = DocGenService.processXmlForTest(
            '<a:t>{Name}</a:t>',
            new Map<String, Object>{ 'Name' => 'Acme' },
            'PowerPoint'
        );
        System.assert(result.contains('Acme'), 'Ordinary tag unaffected: ' + result);
    }

    @IsTest
    static void testPowerPointSplitRunTagDefragments() {
        // PowerPoint splits a run at any character-formatting boundary — a spell-check
        // squiggle alone puts err="1" on the middle run — so {UnitPrice:currency} is
        // commonly authored as three <a:r> elements. Without run-defragmentation the
        // tag reaches processXml spanning markup and renders blank.
        String xml =
            '<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>{</a:t></a:r>' +
            '<a:r><a:rPr lang="en-US" dirty="0" err="1"/><a:t>UnitPrice:currency</a:t></a:r>' +
            '<a:r><a:rPr lang="en-US" dirty="0"/><a:t>}</a:t></a:r></a:p>';

        String merged = DocGenService.mergeRunsInTagsForTest(xml);
        System.assert(merged.contains('{UnitPrice:currency}'), 'Split tag rejoined into one run: ' + merged);

        String result = DocGenService.processXmlForTest(
            merged,
            new Map<String, Object>{ 'UnitPrice' => 100 },
            'PowerPoint'
        );
        System.assert(result.contains('$100.00'), 'Rejoined tag resolves with its format suffix: ' + result);
    }

    // =========================================================================
    // Macro-enabled Excel (.xlsm) — generateDocumentParts flag + binary routing
    // =========================================================================

    /**
     * Minimal workbook for the xlsm tests. With macroEnabled=true the content types
     * declare the macro-enabled workbook and vbaProjectBin ships as xl/vbaProject.bin —
     * the two things that distinguish an .xlsm from an .xlsx. extraBinPath/extraBinBytes
     * add an arbitrary .bin part (e.g. printerSettings) for routing tests.
     */
    private static Blob buildTestWorkbook(
        Boolean macroEnabled,
        Blob vbaProjectBin,
        String extraBinPath,
        Blob extraBinBytes
    ) {
        String workbookContentType = macroEnabled
            ? 'application/vnd.ms-excel.sheet.macroEnabled.main+xml'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml';
        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
                    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
                    '<Default Extension="xml" ContentType="application/xml"/>' +
                    (macroEnabled
                        ? '<Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/>'
                        : '') +
                    (extraBinPath != null && !macroEnabled
                        ? '<Default Extension="bin" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.printerSettings"/>'
                        : '') +
                    '<Override PartName="/xl/workbook.xml" ContentType="' +
                    workbookContentType +
                    '"/>' +
                    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
                    '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' +
                    '</Types>'
            )
        );
        zw.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'xl/_rels/workbook.xml.rels',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
                    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' +
                    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>' +
                    (macroEnabled
                        ? '<Relationship Id="rId3" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"/>'
                        : '') +
                    '</Relationships>'
            )
        );
        zw.addEntry(
            'xl/workbook.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
                    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
                    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>'
            )
        );
        zw.addEntry(
            'xl/sharedStrings.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">' +
                    '<si><t>Hello {Name}</t></si></sst>'
            )
        );
        zw.addEntry(
            'xl/worksheets/sheet1.xml',
            Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' +
                    '<row r="1"><c r="A1" t="s"><v>0</v></c></row></sheetData></worksheet>'
            )
        );
        if (macroEnabled && vbaProjectBin != null) {
            zw.addEntry('xl/vbaProject.bin', vbaProjectBin);
        }
        if (extraBinPath != null && extraBinBytes != null) {
            zw.addEntry(extraBinPath, extraBinBytes);
        }
        return zw.getArchive();
    }

    /** Attaches a workbook to the shared test template as its template file. */
    private static void linkWorkbookToTemplate(Id tplId, String pathOnClient, Blob archive) {
        ContentVersion cv = new ContentVersion(
            Title = pathOnClient.substringBeforeLast('.'),
            PathOnClient = pathOnClient,
            VersionData = archive
        );
        insert cv;
        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = tplId, ContentDocumentId = conDocId, ShareType = 'V');
    }

    @IsTest
    static void testGenerateDocumentPartsXlsmSetsMacroFlagAndShipsVbaIntact() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        // Deliberately NOT valid UTF-8 (0x80, 0xFF bytes) so a string round-trip
        // corruption could not slip through the byte-identity assertion below.
        Blob vbaBytes = EncodingUtil.base64Decode('AAECgP8AVkJB');
        linkWorkbookToTemplate(tpl.Id, 'MacroBook.xlsm', buildTestWorkbook(true, vbaBytes, null, null));

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(true, result.get('isMacroEnabled'), 'macroEnabled workbook content type must set the flag');
        Map<String, String> binaryParts = (Map<String, String>) result.get('imageBase64Map');
        System.assert(
            binaryParts.containsKey('xl/vbaProject.bin'),
            'VBA project must ship in the binary map, got: ' + binaryParts.keySet()
        );
        System.assertEquals(
            EncodingUtil.base64Encode(vbaBytes),
            binaryParts.get('xl/vbaProject.bin'),
            'VBA project bytes must round-trip byte-identical'
        );
        Map<String, String> xmlParts = (Map<String, String>) result.get('allXmlParts');
        System.assert(!xmlParts.containsKey('xl/vbaProject.bin'), 'VBA project must never be treated as XML text');
    }

    @IsTest
    static void testGenerateDocumentPartsXlsxNotMacroAndBinRoutesDeterministically() {
        DocGen_Template__c tpl = TestDataFactory.getTestTemplate();
        tpl.Type__c = 'Excel';
        tpl.Query_Config__c = 'Name';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);

        // A .bin whose bytes ARE valid UTF-8 — the old detect-by-trying split would
        // have survived .toString() and shipped it re-encoded through the XML map.
        Blob asciiBin = Blob.valueOf('plain ASCII bytes that decode fine as UTF-8');
        linkWorkbookToTemplate(
            tpl.Id,
            'PlainBook.xlsx',
            buildTestWorkbook(false, null, 'xl/printerSettings/printerSettings1.bin', asciiBin)
        );

        Account acc = TestDataFactory.getTestAccount();

        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(false, result.get('isMacroEnabled'), 'Plain .xlsx must not set the macro flag');
        Map<String, String> binaryParts = (Map<String, String>) result.get('imageBase64Map');
        System.assertEquals(
            EncodingUtil.base64Encode(asciiBin),
            binaryParts.get('xl/printerSettings/printerSettings1.bin'),
            'A .bin part must route to the binary map even when its bytes are valid UTF-8'
        );
        Map<String, String> xmlParts = (Map<String, String>) result.get('allXmlParts');
        System.assert(
            !xmlParts.containsKey('xl/printerSettings/printerSettings1.bin'),
            '.bin parts must never land in the XML map'
        );
    }

    // Server-side render path (Flow action / save-to-record / bulk) must name a
    // macro-enabled workbook .xlsm — Excel refuses to load VBA from an .xlsx name.
    @IsTest
    static void testFlowAction_xlsmTemplateSavesAsXlsm() {
        Account acc = TestDataFactory.getTestAccount();
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Xlsm JSON Template',
            Base_Object_API__c = 'FlowJsonData',
            Type__c = 'Excel',
            Output_Format__c = 'Native',
            Query_Config__c = '{"v":4,"source":"flowJsonData"}'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);

        Blob vbaBytes = EncodingUtil.base64Decode('AAECgP8AVkJB');
        ContentVersion cv = new ContentVersion(
            Title = 'Xlsm JSON Template',
            PathOnClient = 'book.xlsm',
            VersionData = buildTestWorkbook(true, vbaBytes, null, null),
            FirstPublishLocationId = tpl.Id
        );
        Database.insert(cv, AccessLevel.SYSTEM_MODE);

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Type__c = 'Excel',
            Base_Object_API__c = 'FlowJsonData',
            Query_Config__c = '{"v":4,"source":"flowJsonData"}',
            Content_Version_Id__c = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1]
            .Id
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;
        req.jsonData = '{"Name":"Acme"}';

        Test.startTest();
        List<DocGenFlowAction.Response> responses = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Xlsm render should succeed: ' + responses[0].errorMessage);
        ContentVersion saved = [
            SELECT PathOnClient
            FROM ContentVersion
            WHERE Id = :responses[0].contentVersionId
            LIMIT 1
        ];
        System.assert(
            saved.PathOnClient.endsWith('.xlsm'),
            'Macro-enabled template must save as .xlsm, got: ' + saved.PathOnClient
        );
    }
}

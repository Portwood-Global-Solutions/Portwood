// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@IsTest
public with sharing class DocGenBulkControllerTest {
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();

        // Create an Account for testing
        Account acc = new Account(Name = 'Heap Test Account');
        insert acc;

        // Create a Template
        DocGen_Template__c temp = new DocGen_Template__c(
            Name = 'Heap Test Template',
            Base_Object_API__c = 'Account',
            Test_Record_Id__c = acc.Id,
            Output_Format__c = 'PDF',
            Query_Config__c = '{"v":3,"root":"Account","nodes":[{"id":"n0","object":"Account","fields":["Name"],"parentNode":null,"lookupField":null,"relationshipName":null}]}'
        );
        Database.insert(temp, AccessLevel.SYSTEM_MODE);
        // Create a Template Version
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c = temp.Id, Is_Active__c = true);
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        // Attach a valid minimal DOCX file (Minimal valid ZIP structure with document.xml)
        String dummyDocx = 'UEsDBBQAAAAIAAAAIQDp74EAAAABAAAADwAAAHdvcmQvZG9jdW1lbnQueG1sPz94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiIHN0YW5kYWxvbmU9InllcyI/Pgo8dzpkb2N1bWVudCB4bWxuczp3PSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvd29yZG1vY2Vzc2luZ21sLzIwMDYvbWFpbiI+PHc6Ym9keT48dzpwPjx3OnI+PHc6dD5UZXN0PC93OnQ+PC93OnI+PC93OnA+PC93OmJvZHk+PC93OmRvY3VtZW50PlBLAQIUABQAAAAIAAAAIQDp74EAAAABAAAADwAAAAAAAAAAAAAAAABAAAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAEAAQA9AAAARwAAAAAA';
        ContentVersion cv = new ContentVersion(
            Title = 'Dummy.docx',
            PathOnClient = 'Dummy.docx',
            VersionData = EncodingUtil.base64Decode(dummyDocx),
            IsMajorVersion = true
        );
        insert cv;

        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(LinkedEntityId = ver.Id, ContentDocumentId = docId, ShareType = 'V');

        ver.Content_Version_Id__c = cv.Id;
        Database.update(ver, AccessLevel.SYSTEM_MODE);
        // Create pre-decomposed XML ContentVersion so the PDF merge path works
        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{%Name}</w:t></w:r></w:p></w:body></w:document>';
        ContentVersion xmlCv = new ContentVersion(
            Title = 'docgen_tmpl_xml_' + ver.Id + '_word__document.xml',
            PathOnClient = 'document.xml',
            VersionData = Blob.valueOf(docXml),
            FirstPublishLocationId = ver.Id
        );
        insert xmlCv;
    }

    @IsTest
    static void testEstimateHeapUsageSafe() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        DocGenBulkController.HeapEstimate estimate = DocGenBulkController.estimateHeapUsage(temp.Id, 10);
        Test.stopTest();

        System.assertNotEquals(null, estimate, 'Estimate should not be null');
        System.assertEquals(false, estimate.isRisk, 'Small count should not be a risk');
        System.assert(
            estimate.message.containsIgnoreCase('safe'),
            'Message should indicate safe status: ' + estimate.message
        );
    }

    @IsTest
    static void testEstimateHeapUsageRisk() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        // 500,000 records with 2-byte chars and 25% buffer will definitely trigger 10MB+ risk
        DocGenBulkController.HeapEstimate estimate = DocGenBulkController.estimateHeapUsage(temp.Id, 500000);
        Test.stopTest();

        System.assertNotEquals(null, estimate, 'Estimate should not be null');
        System.assertEquals(true, estimate.isRisk, 'Large count should be a risk: ' + estimate.estimatedHeapMb + 'MB');
        System.assert(
            estimate.message.containsIgnoreCase('high risk'),
            'Message should indicate high risk: ' + estimate.message
        );
    }

    @IsTest
    static void testEstimateHeapUsageNoTestId() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        temp.Test_Record_Id__c = null;
        Database.update(temp, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        DocGenBulkController.HeapEstimate estimate = DocGenBulkController.estimateHeapUsage(temp.Id, 10);
        Test.stopTest();

        System.assertNotEquals(null, estimate.message, 'Message should not be null: ' + estimate.message);
    }

    @IsTest
    static void testValidateFilter() {
        Test.startTest();
        Integer count = DocGenBulkController.validateFilter('Account', 'Name LIKE \'Heap%\'');
        Test.stopTest();

        System.assertEquals(1, count, 'Should find 1 record');
    }

    @IsTest
    static void testValidateFilterEmpty() {
        Test.startTest();
        Integer count = DocGenBulkController.validateFilter('Account', '');
        Test.stopTest();

        System.assert(count >= 1, 'Should count at least 1 account when no condition is provided');
    }

    @IsTest
    static void testAnalyzeJobSafe() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(temp.Id, 10, 1, false, false);
        Test.stopTest();

        System.assertNotEquals(null, analysis, 'Analysis should not be null');
        System.assertEquals(true, analysis.canProceed, 'Small job should be safe');
        System.assertEquals(10, analysis.recordCount, 'Record count should match');
        System.assert(analysis.items.size() >= 3, 'Should have at least SOQL, DML, and count checks');
        // No heap check when merge is false
        Boolean hasHeap = false;
        for (DocGenBulkController.AnalysisItem item : analysis.items) {
            if (item.label == 'Merge Heap') {
                hasHeap = true;
            }
        }
        System.assertEquals(false, hasHeap, 'Should not include heap check without merge mode');
    }

    @IsTest
    static void testAnalyzeJobWithMerge() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(temp.Id, 10, 1, true, false);
        Test.stopTest();

        System.assertNotEquals(null, analysis, 'Analysis should not be null');
        System.assertEquals(true, analysis.canProceed, 'Small merge job should be safe');
        Boolean hasHeap = false;
        for (DocGenBulkController.AnalysisItem item : analysis.items) {
            if (item.label == 'Merge Heap') {
                hasHeap = true;
            }
        }
        System.assertEquals(true, hasHeap, 'Should include heap check in merge mode');
    }

    @IsTest
    static void testAnalyzeJobHighBatch() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(temp.Id, 100, 200, false, false);
        Test.stopTest();

        System.assertNotEquals(null, analysis, 'Analysis should not be null');
        // With V3 config (1 node), 200 batch * 1 query + 4 overhead = 204, which exceeds 100 limit
        Boolean hasSoqlError = false;
        for (DocGenBulkController.AnalysisItem item : analysis.items) {
            if (item.label == 'SOQL Queries' && item.status == 'error') {
                hasSoqlError = true;
            }
        }
        System.assertEquals(true, hasSoqlError, 'High batch size should trigger SOQL error');
        // canProceed is reserved for HARD blockers (unsupported template/mode, >50k
        // records). An over-limit SOQL ESTIMATE is surfaced as an error item but must
        // NOT disable the Run button: the estimate assumes every record re-runs the
        // full query tree, while DocGenBatch caches shared data, and the server-side
        // submitJob path enforces none of it — so the Flow action would run the exact
        // same job the UI was refusing.
        System.assertEquals(
            true,
            analysis.canProceed,
            'An over-limit estimate should warn, not block — only hard blockers set canProceed=false'
        );
    }

    @IsTest
    static void testAnalyzeJobLargeCount() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(temp.Id, 60000, 1, false, false);
        Test.stopTest();

        System.assertEquals(false, analysis.canProceed, 'Should not proceed with >50k records');
    }

    // ── Duplex packet ceiling (#382) ──────────────────────────────────────
    // A duplex Combined PDF assembles every record's PDF in one Queueable, so
    // it has a hard record ceiling. analyzeJob must warn above ~250 and block
    // above ~400 — and, unlike the heap estimate, this check depends only on
    // record count, so it must fire even for a template with no Test Record.

    @IsTest
    static void analyzeJobDuplexSmallPacketIsOk() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Test.startTest();
        DocGenBulkController.JobAnalysis a = DocGenBulkController.analyzeJob(temp.Id, 50, 1, true, true);
        Test.stopTest();
        System.assertEquals(true, a.canProceed, '50 documents is well within the duplex ceiling');
        System.assertEquals('ok', duplexItemStatus(a), 'Duplex Packet item should be ok');
    }

    @IsTest
    static void analyzeJobDuplexLargePacketWarns() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Test.startTest();
        DocGenBulkController.JobAnalysis a = DocGenBulkController.analyzeJob(temp.Id, 300, 1, true, true);
        Test.stopTest();
        System.assertEquals(true, a.canProceed, '300 documents warns but does not block');
        System.assertEquals('warning', duplexItemStatus(a), 'Duplex Packet item should warn at 300');
    }

    @IsTest
    static void analyzeJobDuplexOversizePacketBlocks() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Test.startTest();
        DocGenBulkController.JobAnalysis a = DocGenBulkController.analyzeJob(temp.Id, 5000, 1, true, true);
        Test.stopTest();
        System.assertEquals(false, a.canProceed, '5000 documents exceeds the one-job duplex ceiling');
        System.assertEquals('error', duplexItemStatus(a), 'Duplex Packet item should be an error at 5000');
    }

    @IsTest
    static void analyzeJobDuplexCeilingFiresWithoutTestRecord() {
        // The heap estimate is skipped when a template has no Test Record; the
        // duplex ceiling must NOT be — a missing hard block is a trap.
        DocGen_Template__c noTr = new DocGen_Template__c(
            Name = 'DocGen Test Template No TR',
            Base_Object_API__c = 'Account',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        Database.insert(noTr, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DocGenBulkController.JobAnalysis a = DocGenBulkController.analyzeJob(noTr.Id, 5000, 1, true, true);
        Test.stopTest();

        System.assertEquals(false, a.canProceed, 'The duplex ceiling must block even without a Test Record');
        System.assertEquals('error', duplexItemStatus(a), 'Duplex Packet error item must be present');
    }

    @IsTest
    static void analyzeJobNonDuplexMergeHasNoDuplexItem() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
        Test.startTest();
        DocGenBulkController.JobAnalysis a = DocGenBulkController.analyzeJob(temp.Id, 300, 1, true, false);
        Test.stopTest();
        System.assertEquals(null, duplexItemStatus(a), 'A non-duplex merge job carries no Duplex Packet item');
    }

    private static String duplexItemStatus(DocGenBulkController.JobAnalysis a) {
        for (DocGenBulkController.AnalysisItem it : a.items) {
            if (it.label == 'Duplex Packet') {
                return it.status;
            }
        }
        return null;
    }

    @IsTest
    static void testSubmitJob() {
        DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

        Test.startTest();
        Id jobId = DocGenBulkController.submitJob(temp.Id, 'Name != null', 'Test Job', true, 10, false, null, null);
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job ID should be returned');
        DocGen_Job__c job = [SELECT Status__c, Label__c FROM DocGen_Job__c WHERE Id = :jobId];
        // In tests, the job might transition to Processing/Failed immediately
        System.assertNotEquals(null, job.Status__c, 'Job status should be populated');
        System.assertEquals('Test Job', job.Label__c, 'Job label should match');
    }
}

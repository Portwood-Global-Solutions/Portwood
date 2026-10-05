// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@IsTest
private class DocGenBulkFlowActionTest {
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        DocGen_Template__c temp = new DocGen_Template__c(
            Name = 'Test Bulk Template',
            Base_Object_API__c = 'Account',
            Type__c = 'Word'
        );
        Database.insert(temp, AccessLevel.SYSTEM_MODE);
        insert new Account(Name = 'Test Account 1', Website = 'https://test1.com');
        insert new Account(Name = 'Test Account 2', Website = 'https://test2.com');
    }

    @IsTest
    static void testGenerateBulkDocuments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.queryCondition = 'Name = \'Test Account 1\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].jobId, 'Should have a jobId');

            DocGen_Job__c job = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            // Note: Status might be Processing or Completed depending on execution speed in test
            System.assertNotEquals(null, job.Status__c, 'Job should have a status');
        }
    }

    @IsTest
    static void duplexPaddingInputReachesTheJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            // Combined PDF + duplex on → the flag is persisted.
            DocGenBulkFlowAction.Request mergeReq = new DocGenBulkFlowAction.Request();
            mergeReq.templateId = temp.Id;
            mergeReq.queryCondition = 'Name = \'Test Account 1\'';
            mergeReq.combinedPdfOnly = true;
            mergeReq.duplexPadding = true;

            // Individual Files only (no combined bundle) + duplex on → forced off.
            DocGenBulkFlowAction.Request indivReq = new DocGenBulkFlowAction.Request();
            indivReq.templateId = temp.Id;
            indivReq.queryCondition = 'Name = \'Test Account 2\'';
            indivReq.combinedPdfOnly = false;
            indivReq.keepIndividualFiles = false;
            indivReq.duplexPadding = true;

            Test.startTest();
            List<DocGenBulkFlowAction.Response> res = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ mergeReq, indivReq }
            );
            Test.stopTest();

            DocGen_Job__c onJob = [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :res[0].jobId];
            DocGen_Job__c offJob = [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :res[1].jobId];
            System.assertEquals(true, onJob.Duplex_Padding__c, 'Combined PDF job should carry the duplex flag');
            System.assertNotEquals(
                true,
                offJob.Duplex_Padding__c,
                'Individual Files job must not carry the duplex flag'
            );
        }
    }

    @IsTest
    static void testGenerateBulkDocumentsErrorPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a null templateId to trigger the error/catch branch
            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = null;
            req.queryCondition = 'Name = \'Test\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should have one response');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have an error message');
            System.assertEquals(null, responses[0].jobId, 'Should not have a jobId on error');

            List<DocGen_Error_Log__c> logs = [
                SELECT Context__c, Operation__c, Message__c
                FROM DocGen_Error_Log__c
                WHERE Context__c = 'DocGenBulkFlowAction'
            ];
            System.assertEquals(1, logs.size(), 'Bulk Flow failures should create a diagnostic log');
            System.assertEquals('Generate Bulk Documents', logs[0].Operation__c);
            System.assert(logs[0].Message__c != null, 'Diagnostic log should preserve the failure message');
        }
    }

    // ─── Template API Name addressing ────────────────────────────────────
    // Mirrors DocGenFlowAction so a Flow can reference a bulk template by its
    // stable API Name instead of an environment-specific record Id.

    @IsTest
    static void testGenerateBulk_byTemplateApiName() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            temp.API_Name__c = 'Bulk_Template_Api_Key';
            Database.update(temp, AccessLevel.SYSTEM_MODE);

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateApiName = 'Bulk_Template_Api_Key';
            req.queryCondition = 'Name = \'Test Account 1\'';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(true, responses[0].success, 'API Name should resolve: ' + responses[0].errorMessage);
            System.assertNotEquals(null, responses[0].jobId, 'Should have a jobId when addressed by API Name');

            DocGen_Job__c job = [SELECT Template__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            System.assertEquals(temp.Id, job.Template__c, 'Job should target the template matched by API Name');
        }
    }

    @IsTest
    static void testGenerateBulk_unknownTemplateApiNameReturnsError() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateApiName = 'No_Such_Template_Api_Name';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(false, responses[0].success, 'Unknown API Name should fail the request');
            System.assertEquals(null, responses[0].jobId, 'No job should be created for an unknown API Name');
            System.assert(
                responses[0].errorMessage.contains('No_Such_Template_Api_Name'),
                'Error should name the API Name that failed to resolve: ' + responses[0].errorMessage
            );
        }
    }

    // ─── Record-IDs collection input ─────────────────────────────────────
    // Lets a Flow that has already filtered records (e.g. via decision logic
    // or a Get Records collection) hand them directly to bulk generation
    // without saving a Query Filter or building a WHERE clause manually.

    @IsTest
    static void testBuildEffectiveCondition_idsOnly() {
        Account a = TestDataFactory.accountByName('Test Account 1');
        String result = DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ a.Id });
        System.assert(result.startsWith('Id IN ('), 'Should start with Id IN, got: ' + result);
        System.assert(result.contains(a.Id), 'Should include the supplied ID');
    }

    @IsTest
    static void testBuildEffectiveCondition_idsAndCondition_combine() {
        Account a = TestDataFactory.accountByName('Test Account 1');
        String result = DocGenBulkFlowAction.buildEffectiveCondition('Industry = \'Tech\'', new List<String>{ a.Id });
        // Expect the user condition to be parenthesized then AND-ed with Id IN
        System.assert(result.contains('Industry'), 'Should preserve user condition');
        System.assert(result.contains('AND Id IN ('), 'Should AND-combine, got: ' + result);
    }

    @IsTest
    static void testBuildEffectiveCondition_userOnly() {
        String result = DocGenBulkFlowAction.buildEffectiveCondition('Industry = \'Tech\'', null);
        System.assertEquals('Industry = \'Tech\'', result);
    }

    @IsTest
    static void testBuildEffectiveCondition_invalidIdRejected() {
        try {
            DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ 'not-an-id-haha' });
            System.assert(false, 'Should have thrown for invalid ID');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('Invalid record ID'), 'Got: ' + e.getMessage());
        }
    }

    @IsTest
    static void testBuildEffectiveCondition_blanksSkipped() {
        Account a = TestDataFactory.accountByName('Test Account 1');
        String result = DocGenBulkFlowAction.buildEffectiveCondition(null, new List<String>{ '', null, a.Id, '   ' });
        System.assertEquals('Id IN (\'' + a.Id + '\')', result, 'Blanks should be skipped silently');
    }

    @IsTest
    static void testGenerateBulk_withRecordIdsInput_endToEnd() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            // Two records cause Apex's batch framework to fire 2 chunks at the
            // default batchSize=1, which trips the test-mode "no more than one
            // executeBatch" governor. Two record IDs at batchSize=200 is the
            // valid shape — one Id IN clause, one chunk, one batch invocation.
            List<Account> accts = [SELECT Id FROM Account LIMIT 2];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.recordIds = new List<String>{ accts[0].Id, accts[1].Id };
            req.batchSize = 200;

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(
                true,
                responses[0].success,
                'IDs-only path should succeed: ' + responses[0].errorMessage
            );
            DocGen_Job__c job = [SELECT Query_Condition__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            System.assert(
                job.Query_Condition__c.startsWith('Id IN ('),
                'Job should be scoped by Id IN, got: ' + job.Query_Condition__c
            );
            System.assert(job.Query_Condition__c.contains(accts[0].Id), 'Should target first Account');
            System.assert(job.Query_Condition__c.contains(accts[1].Id), 'Should target second Account');
        }
    }

    @IsTest
    static void testGenerateBulk_sortOrderReachesTheJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            // Scoped to one record: an unfiltered set spans more than one batch
            // execution, and a test method may only trigger executeBatch once.
            req.queryCondition = 'Name = \'Test Account 1\'';
            req.sortOrder = 'name desc';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(
                true,
                responses[0].success,
                'Sorted Flow job should start: ' + responses[0].errorMessage
            );
            DocGen_Job__c job = [SELECT Sort_Order__c FROM DocGen_Job__c WHERE Id = :responses[0].jobId];
            System.assertEquals(
                'Name DESC NULLS LAST',
                job.Sort_Order__c,
                'The Flow input should be validated and canonicalized like the runner\'s.'
            );
        }
    }

    @IsTest
    static void testGenerateBulk_badSortOrderFailsTheActionNotTheInterview() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c temp = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGenBulkFlowAction.Request req = new DocGenBulkFlowAction.Request();
            req.templateId = temp.Id;
            req.sortOrder = 'Bogus__c ASC';

            Test.startTest();
            List<DocGenBulkFlowAction.Response> responses = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ req }
            );
            Test.stopTest();

            // Reported on the outputs — a fault would take the whole Flow down.
            System.assertEquals(false, responses[0].success, 'A bad sort field should fail the action.');
            System.assertNotEquals(null, responses[0].errorMessage, 'The Flow author needs to be told why.');
        }
    }

    @IsTest
    static void testBulkFlowActionResponseCoverage() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGenBulkFlowAction.Response res = new DocGenBulkFlowAction.Response();
            res.jobId = null;
            res.errorMessage = 'test';
            System.assertEquals(null, res.jobId, 'jobId should be null when not set');
            System.assertEquals('test', res.errorMessage, 'errorMessage should match assigned value');
        }
    }
}

/**
 * #593 — "Save as New Version Of" on the Generate Document Flow action.
 *
 * Covers: a filled-in box versions the existing file and returns the NEW version's Id;
 * an empty box behaves exactly as before (new file each run); a bad / missing /
 * inaccessible / read-only file gives a clear error and writes nothing.
 */
@IsTest
private class DocGenFlowActionVersionTest {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
    }

    private static DocGenFlowAction.Request buildRequest(String saveAsNewVersionOf) {
        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = TestDataFactory.getTestTemplate().Id;
        req.recordId = TestDataFactory.getTestAccount().Id;
        req.saveAsNewVersionOf = saveAsNewVersionOf;
        return req;
    }

    private static DocGenFlowAction.Response run(DocGenFlowAction.Request req) {
        return DocGenFlowAction.generateDocument(new List<DocGenFlowAction.Request>{ req })[0];
    }

    private static ContentVersion createExistingFile(String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('existing file v1')
        );
        insert cv;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
    }

    private static Integer versionCount(Id docId) {
        return [SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId = :docId];
    }

    private static User buildStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return new User(
            Alias = 'dgver',
            Email = 'dgversiontest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'VersionTestUser',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'dgversiontest_' + System.currentTimeMillis() + '@example.com.docgen'
        );
    }

    // =========================================================================
    // Running twice → one file, two versions, and the Flow gets the newest one
    // =========================================================================

    @IsTest
    static void runTwice_secondRunWithBoxFilled_givesOneFileWithTwoVersions() {
        TestDataFactory.attachRealDocxToTestTemplate();

        Test.startTest();
        DocGenFlowAction.Response first = run(buildRequest(null));
        System.assertEquals(true, first.success, 'First run should create a file: ' + first.errorMessage);

        DocGenFlowAction.Response second = run(buildRequest(first.contentDocumentId));
        Test.stopTest();

        System.assertEquals(true, second.success, 'Second run should add a version: ' + second.errorMessage);
        System.assertEquals(
            first.contentDocumentId,
            second.contentDocumentId,
            'Second run must return the SAME file, not a new one'
        );
        System.assertEquals(2, versionCount(first.contentDocumentId), 'The file should now have exactly 2 versions');

        ContentVersion latest = [
            SELECT Id, VersionNumber
            FROM ContentVersion
            WHERE ContentDocumentId = :first.contentDocumentId AND IsLatest = TRUE
        ];
        System.assertEquals(
            latest.Id,
            second.contentVersionId,
            'Flow must get back the newest version Id (v' + latest.VersionNumber + '), not v1'
        );
        System.assertNotEquals(
            first.contentVersionId,
            second.contentVersionId,
            'Second run must not return the first version Id'
        );
    }

    @IsTest
    static void newVersionOfUploadedFile_returnsNewVersionNotV1() {
        // The exact bug the old "first version found" lookup had: an existing v1 file.
        TestDataFactory.attachRealDocxToTestTemplate();
        ContentVersion v1 = createExistingFile('Existing Contract');

        Test.startTest();
        DocGenFlowAction.Response res = run(buildRequest(v1.ContentDocumentId));
        Test.stopTest();

        System.assertEquals(true, res.success, 'Error: ' + res.errorMessage);
        System.assertEquals(v1.ContentDocumentId, res.contentDocumentId);
        System.assertNotEquals(v1.Id, res.contentVersionId, 'Must not return the old v1 Id');
        ContentVersion returned = [SELECT IsLatest, VersionNumber FROM ContentVersion WHERE Id = :res.contentVersionId];
        System.assertEquals(true, returned.IsLatest, 'Returned version must be the latest');
        System.assertEquals('2', returned.VersionNumber);
    }

    @IsTest
    static void contentVersionIdInBox_isResolvedToItsFile() {
        TestDataFactory.attachRealDocxToTestTemplate();
        ContentVersion v1 = createExistingFile('Versioned By CV Id');

        Test.startTest();
        DocGenFlowAction.Response res = run(buildRequest(v1.Id)); // 068… instead of 069…
        Test.stopTest();

        System.assertEquals(true, res.success, 'Error: ' + res.errorMessage);
        System.assertEquals(v1.ContentDocumentId, res.contentDocumentId);
        System.assertEquals(2, versionCount(v1.ContentDocumentId));
    }

    @IsTest
    static void jsonDataWithoutRecord_boxFilled_addsVersion() {
        TestDataFactory.attachRealDocxToTestTemplate();
        ContentVersion v1 = createExistingFile('Data Driven');

        DocGenFlowAction.Request req = buildRequest(' ' + v1.ContentDocumentId + ' '); // stray spaces tolerated
        req.recordId = null;
        req.jsonData = '{"Name":"In-Memory Co"}';

        Test.startTest();
        DocGenFlowAction.Response res = run(req);
        Test.stopTest();

        System.assertEquals(true, res.success, 'Error: ' + res.errorMessage);
        System.assertEquals(v1.ContentDocumentId, res.contentDocumentId);
        System.assertEquals(2, versionCount(v1.ContentDocumentId));
        System.assertEquals(
            [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :v1.ContentDocumentId AND IsLatest = TRUE].Id,
            res.contentVersionId
        );
    }

    @IsTest
    static void newVersion_withSaveToRecord_linksFileToRecord() {
        TestDataFactory.attachRealDocxToTestTemplate();
        ContentVersion v1 = createExistingFile('Link Me');
        DocGenFlowAction.Request req = buildRequest(v1.ContentDocumentId);
        req.saveToRecord = true;

        Test.startTest();
        DocGenFlowAction.Response res = run(req);
        Test.stopTest();

        System.assertEquals(true, res.success, 'Error: ' + res.errorMessage);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :v1.ContentDocumentId AND LinkedEntityId = :req.recordId
            ],
            'Versioned file should be attached to the record when Save to Record is true'
        );
    }

    // =========================================================================
    // Empty box → exactly like before: a new file every run
    // =========================================================================

    @IsTest
    static void emptyBox_createsNewFileEachRun() {
        TestDataFactory.attachRealDocxToTestTemplate();
        Integer docsBefore = [SELECT COUNT() FROM ContentDocument];

        Test.startTest();
        DocGenFlowAction.Response first = run(buildRequest(null));
        DocGenFlowAction.Response second = run(buildRequest('   ')); // whitespace counts as empty
        Test.stopTest();

        System.assertEquals(true, first.success, 'Error: ' + first.errorMessage);
        System.assertEquals(true, second.success, 'Error: ' + second.errorMessage);
        System.assertNotEquals(
            first.contentDocumentId,
            second.contentDocumentId,
            'Empty box must create a separate file each time'
        );
        System.assertEquals(docsBefore + 2, [SELECT COUNT() FROM ContentDocument], 'Two new files expected');
        System.assertEquals(1, versionCount(first.contentDocumentId));
        System.assertEquals(1, versionCount(second.contentDocumentId));
        System.assertEquals(
            first.contentDocumentId,
            [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :first.contentVersionId].ContentDocumentId,
            'Returned version Id must belong to the returned file'
        );
        System.assertEquals(null, DocGenService.saveAsNewVersionOf, 'No versioning state may be left behind');
    }

    // =========================================================================
    // Bad ID → clear error, nothing written
    // =========================================================================

    @IsTest
    static void malformedId_givesClearError() {
        TestDataFactory.attachRealDocxToTestTemplate();
        Integer versionsBefore = [SELECT COUNT() FROM ContentVersion];

        DocGenFlowAction.Response res = run(buildRequest('not-a-real-id'));

        System.assertEquals(false, res.success);
        System.assert(
            res.errorMessage.contains('Save as New Version Of') && res.errorMessage.contains('not a valid file ID'),
            'Expected a clear invalid-ID message, got: ' + res.errorMessage
        );
        System.assertEquals(versionsBefore, [SELECT COUNT() FROM ContentVersion], 'Nothing must be saved on error');
    }

    @IsTest
    static void nonFileId_givesClearError() {
        Account acc = TestDataFactory.getTestAccount();

        DocGenFlowAction.Response res = run(buildRequest(acc.Id));

        System.assertEquals(false, res.success);
        System.assert(
            res.errorMessage.contains('Account ID, not a file ID'),
            'Expected a wrong-type message, got: ' + res.errorMessage
        );
    }

    @IsTest
    static void deletedFile_givesClearError() {
        ContentVersion v1 = createExistingFile('To Be Deleted');
        Id deletedDocId = v1.ContentDocumentId;
        delete new ContentDocument(Id = deletedDocId);

        DocGenFlowAction.Response res = run(buildRequest(deletedDocId));

        System.assertEquals(false, res.success);
        System.assert(
            res.errorMessage.contains('no file found with ID ' + deletedDocId),
            'Expected a not-found message, got: ' + res.errorMessage
        );
    }

    @IsTest
    static void fileUserCannotSee_reportsNotFound() {
        ContentVersion v1 = createExistingFile('Private File');
        User u = buildStandardUser();
        insert u;
        // Built as admin: the standard user can't read the template, and doesn't need to —
        // the request fails at file validation, before any template/record access.
        DocGenFlowAction.Request req = buildRequest(v1.ContentDocumentId);

        DocGenFlowAction.Response res;
        System.runAs(u) {
            res = run(req);
        }

        System.assertEquals(false, res.success);
        System.assert(
            res.errorMessage.contains('no file found') && res.errorMessage.contains('access'),
            'Expected not-found-or-no-access message, got: ' + res.errorMessage
        );
        System.assertEquals(1, versionCount(v1.ContentDocumentId), 'File must be untouched');
    }

    @IsTest
    static void viewOnlyUser_getsClearPermissionError() {
        ContentVersion v1 = createExistingFile('Read Only For User');
        User u = buildStandardUser();
        insert u;
        insert new ContentDocumentLink(
            ContentDocumentId = v1.ContentDocumentId,
            LinkedEntityId = u.Id,
            ShareType = 'V'
        );

        String message;
        System.runAs(u) {
            try {
                DocGenService.insertAsNewVersion(
                    new ContentVersion(
                        Title = 'Attempt',
                        PathOnClient = 'Attempt.pdf',
                        VersionData = Blob.valueOf('x')
                    ),
                    v1.ContentDocumentId
                );
            } catch (DocGenException e) {
                message = e.getMessage();
            }
        }

        System.assertNotEquals(null, message, 'A viewer must not be able to add a version');
        System.assert(
            message.contains('don\'t have permission to add a new version'),
            'Expected a clear permission message, got: ' + message
        );
        System.assertEquals(1, versionCount(v1.ContentDocumentId), 'File must be untouched');
    }
}

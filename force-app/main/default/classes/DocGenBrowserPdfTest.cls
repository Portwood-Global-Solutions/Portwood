// CxSAST: Test fixtures only; production permission boundaries are exercised below.
@IsTest
private class DocGenBrowserPdfTest {
    private static final String REVISION = '0123456789abcdef0123456789abcdef';

    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Browser PDF Test',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Is_Active__c = true
        );
        insert template;
        ContentVersion html = new ContentVersion(
            Title = 'Browser PDF Test HTML',
            PathOnClient = 'template.html',
            VersionData = Blob.valueOf('<html><body><h1>{Name}</h1></body></html>'),
            FirstPublishLocationId = template.Id
        );
        insert html;
        insert new DocGen_Template_Version__c(
            Template__c = template.Id,
            Content_Version_Id__c = html.Id,
            Is_Active__c = true
        );
        insert new List<Account>{ new Account(Name = 'Zulu'), new Account(Name = 'Alpha') };
    }

    private static DocGen_Job__c makeJob(String status, Integer count, Integer success) {
        DocGen_Job__c job = new DocGen_Job__c(
            Template__c = [SELECT Id FROM DocGen_Template__c LIMIT 1]
            .Id,
            Label__c = 'Statements & receipts',
            Status__c = status,
            Browser_Merge__c = true,
            Browser_Revision__c = REVISION,
            Total_Records__c = count,
            Success_Count__c = success,
            Error_Count__c = count - success
        );
        insert job;
        return job;
    }

    private static ContentVersion makePdf(String title, String text) {
        return new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 ' + text),
            SharingPrivacy = 'P',
            SharingOption = 'R'
        );
    }

    private static DocGen_Browser_Pdf_Block__c block(
        Id jobId,
        Integer firstOrdinal,
        List<Id> sources,
        List<Id> pins,
        Integer success
    ) {
        return new DocGen_Browser_Pdf_Block__c(
            Job__c = jobId,
            First_Ordinal__c = firstOrdinal,
            Last_Ordinal__c = firstOrdinal + sources.size() - 1,
            Source_Ids__c = JSON.serialize(sources),
            Version_Ids__c = JSON.serialize(pins),
            Success_Count__c = success,
            Complete__c = success == sources.size()
        );
    }

    @IsTest
    static void readsPinnedVersionsInOrdinalOrderAndRejectsUnavailableBytes() {
        DocGen_Job__c job = makeJob('Completed', 2, 2);
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name DESC];
        List<ContentVersion> files = new List<ContentVersion>{ makePdf('First', 'one'), makePdf('Second', 'two') };
        insert files;
        insert new List<DocGen_Browser_Pdf_Block__c>{
            block(job.Id, 2, new List<Id>{ accounts[1].Id }, new List<Id>{ files[1].Id }, 1),
            block(job.Id, 1, new List<Id>{ accounts[0].Id }, new List<Id>{ files[0].Id }, 1)
        };
        ContentVersion first = [
            SELECT ContentDocumentId, ContentSize, Checksum
            FROM ContentVersion
            WHERE Id = :files[0].Id
        ];
        ContentVersion latest = makePdf('Updated', 'different content');
        latest.ContentDocumentId = first.ContentDocumentId;
        insert latest;
        System.assertEquals(true, DocGenBrowserPdf.describe(job.Id).ready);
        System.assert(DocGenBrowserPdf.downloadUrl(job.Id).contains('jobId=' + job.Id));
        DocGenBrowserPdf.ManifestPage all = DocGenBrowserPdf.getManifestPage(job.Id, REVISION, 0);
        System.assertEquals(2, all.sources.size());
        System.assertEquals(1, all.sources[0].ordinal);
        System.assertEquals(files[0].Id, all.sources[0].versionId, 'A later version is not a replacement for the pin.');
        System.assertEquals(first.ContentSize, all.sources[0].bytes);
        System.assertEquals(first.Checksum.toLowerCase(), all.sources[0].checksum);
        System.assertEquals(files[1].Id, all.sources[1].versionId);
        System.assertEquals(2, all.nextAfterOrdinal);
        System.assertEquals(true, all.done);
        System.assertEquals(0, DocGenBrowserPdf.getManifestPage(job.Id, REVISION, 2).sources.size());
        System.assertEquals(
            EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 two')),
            DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 2 })[0]
        );

        System.assertEquals(
            new List<String>{
                EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 two')),
                EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 one'))
            },
            DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 2, 1 }),
            'Batched bytes must follow the caller’s order and keep the historical version pin.'
        );

        Boolean rejectedDuplicateOrdinal = false;
        try {
            DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 1, 1 });
        } catch (DocGenException e) {
            rejectedDuplicateOrdinal = e.getMessage().contains('duplicate');
        }
        System.assert(rejectedDuplicateOrdinal, 'A source cannot appear twice in one batch.');

        Boolean rejectedWrongRevision = false;
        try {
            DocGenBrowserPdf.getSources(job.Id, 'invalid-revision', new List<Integer>{ 1, 2 });
        } catch (DocGenException e) {
            rejectedWrongRevision = true;
        }
        System.assert(rejectedWrongRevision, 'A different revision may not read a completed job.');

        delete new ContentDocument(Id = first.ContentDocumentId);
        Boolean rejectedDeletedVersion = false;
        try {
            DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 2, 1 });
        } catch (DocGenException e) {
            rejectedDeletedVersion = true;
        }
        System.assert(rejectedDeletedVersion, 'A missing original File must fail instead of silently dropping a page.');
    }

    @IsTest
    static void standardPortwoodUserCannotReadAnotherUsersSources() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User requester = new User(
            Alias = 'docgpdf',
            Email = 'docgen-pdf-test@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'DocGen Browser PDF Test',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standard.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'docgen-pdf-test.' +
                UserInfo.getOrganizationId() +
                '.' +
                System.currentTimeMillis() +
                '@example.com'
        );
        PermissionSet downloadUser = [
            SELECT Id
            FROM PermissionSet
            WHERE Name IN ('DocGen_User', 'portwoodglobal__DocGen_User')
            LIMIT 1
        ];
        insert requester;
        insert new PermissionSetAssignment(AssigneeId = requester.Id, PermissionSetId = downloadUser.Id);
        User owner = new User(Id = UserInfo.getUserId());
        DocGen_Job__c job;
        System.runAs(owner) {
            job = makeJob('Completed', 1, 1);
        }

        System.runAs(requester) {
            System.assertEquals(true, DocGen_Job__c.sObjectType.getDescribe().isAccessible());
            Boolean denied = false;
            try {
                DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 1 });
            } catch (DocGenException e) {
                denied = e.getMessage().contains('unavailable');
            }
            System.assert(denied, 'Read access to Portwood Jobs does not authorize another user’s browser PDF.');
        }
    }

    @IsTest
    static void rejectsReadWhoseCombinedSizeExceedsOneMiB() {
        DocGen_Job__c job = makeJob('Completed', 2, 2);
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name];
        String tail = 'x'.leftPad(525000, 'x');
        List<ContentVersion> files = new List<ContentVersion>{ makePdf('First', tail), makePdf('Second', tail) };
        insert files;
        insert block(
            job.Id,
            1,
            new List<Id>{ accounts[0].Id, accounts[1].Id },
            new List<Id>{ files[0].Id, files[1].Id },
            2
        );

        Test.startTest();
        DocGenBrowserPdf.ManifestPage page = DocGenBrowserPdf.getManifestPage(job.Id, REVISION, 0);
        System.assertEquals(2, page.sources.size());
        System.assert(page.sources[0].bytes < DocGenBrowserPdf.MAX_SOURCE_BYTES);
        System.assert(page.sources[1].bytes < DocGenBrowserPdf.MAX_SOURCE_BYTES);
        Boolean rejectedOverBudget = false;
        try {
            DocGenBrowserPdf.getSources(job.Id, REVISION, new List<Integer>{ 1, 2 });
        } catch (DocGenException e) {
            rejectedOverBudget = e.getMessage().contains('up to 1 MiB');
        }
        Test.stopTest();
        System.assert(rejectedOverBudget, 'Two individually supported sources may exceed the combined byte budget.');
    }

    @IsTest
    static void rendersOnlyMissingSourceAndSavesAStandalonePrivatePdf() {
        DocGen_Job__c job = makeJob('Processing', 2, 1);
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name DESC];
        ContentVersion completed = makePdf('Already completed', 'keep me');
        insert completed;
        insert block(job.Id, 1, new List<Id>{ accounts[0].Id, accounts[1].Id }, new List<Id>{ completed.Id, null }, 1);

        Test.startTest();
        Id batchId = Database.executeBatch(new DocGenBrowserPdfBatch(job.Id), 1);
        update new DocGen_Job__c(Id = job.Id, Browser_Batch_Id__c = String.valueOf(batchId));
        Test.stopTest();

        DocGenBrowserPdf.JobDescription result = DocGenBrowserPdf.describe(job.Id);
        System.assertEquals('Completed', result.status, 'The remaining source should render successfully.');
        System.assertEquals(2, result.successCount);
        DocGenBrowserPdf.ManifestPage page = DocGenBrowserPdf.getManifestPage(job.Id, REVISION, 0);
        System.assertEquals(
            completed.Id,
            page.sources[0].versionId,
            'The successful source should not be rendered twice.'
        );
        Id newPdf = page.sources[1].versionId;
        ContentVersion cv = [
            SELECT SharingPrivacy, SharingOption, FirstPublishLocationId
            FROM ContentVersion
            WHERE Id = :newPdf
        ];
        System.assertEquals('P', cv.SharingPrivacy);
        System.assertEquals('R', cv.SharingOption);
        System.assertNotEquals(job.Id, cv.FirstPublishLocationId, 'No File should be attached to the public job.');
        System.assertNotEquals(
            accounts[1].Id,
            cv.FirstPublishLocationId,
            'No File should be attached to the source record.'
        );
    }
}

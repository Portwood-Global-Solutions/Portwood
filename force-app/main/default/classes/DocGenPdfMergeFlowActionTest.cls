@IsTest
private class DocGenPdfMergeFlowActionTest {
    private static ContentVersion source(String title, Blob data) {
        ContentVersion cv = new ContentVersion(Title = title, PathOnClient = title + '.pdf', VersionData = data);
        insert cv;
        return cv;
    }
    private static DocGenPdfMergeFlowAction.Request request(List<Id> ids) {
        DocGenPdfMergeFlowAction.Request req = new DocGenPdfMergeFlowAction.Request();
        if (ids != null) {
            req.contentVersionIds = new List<String>();
            for (Id id : ids)
                req.contentVersionIds.add(id == null ? null : String.valueOf(id));
        }
        return req;
    }
    @IsTest
    static void textAndTextCollectionsProduceTheSameOrderedPacket() {
        ContentVersion a = source('Two pages', DocGenPdfMergeFixtures.classic());
        ContentVersion b = source('One page', DocGenPdfMergeFixtures.modern());
        DocGenPdfMergeFlowAction.Request collection = new DocGenPdfMergeFlowAction.Request();
        collection.contentVersionIds = new List<String>{ ' ' + b.Id + ' ', String.valueOf(a.Id), String.valueOf(b.Id) };
        DocGenPdfMergeFlowAction.Request csv = new DocGenPdfMergeFlowAction.Request();
        csv.contentVersionIdsText = ' ' + b.Id + ', ' + a.Id + ',' + b.Id + ' ';
        DocGenPdfMergeFlowAction.Request separated = new DocGenPdfMergeFlowAction.Request();
        separated.contentVersionIds = new List<String>();
        separated.contentVersionIdsText = b.Id + ';\n' + a.Id + '\t' + b.Id;
        Test.startTest();
        List<DocGenPdfMergeFlowAction.Response> results = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ collection, csv, separated }
        );
        Test.stopTest();
        Blob expected;
        for (DocGenPdfMergeFlowAction.Response result : results) {
            System.assertEquals(true, result.success, JSON.serialize(result));
            ContentVersion output = [SELECT VersionData FROM ContentVersion WHERE Id = :result.contentVersionId];
            System.assertEquals(4, DocGenPdfMerger.pageCount(output.VersionData));
            if (expected == null)
                expected = output.VersionData;
            else
                System.assertEquals(
                    EncodingUtil.base64Encode(expected),
                    EncodingUtil.base64Encode(output.VersionData),
                    'Input formats must preserve the same order and repeated IDs'
                );
        }
        System.assertEquals(' ' + b.Id + ' ', collection.contentVersionIds[0], 'Normalization must not mutate input');
    }
    @IsTest
    static void rejectsAmbiguousMalformedAndBlankTextIds() {
        DocGenPdfMergeFlowAction.Request both = request(new List<Id>{ '068000000000001', '068000000000002' });
        both.contentVersionIdsText = '068000000000001,068000000000002';
        DocGenPdfMergeFlowAction.Request malformed = new DocGenPdfMergeFlowAction.Request();
        malformed.contentVersionIdsText = 'not-an-id,068000000000001';
        DocGenPdfMergeFlowAction.Request blank = new DocGenPdfMergeFlowAction.Request();
        blank.contentVersionIds = new List<String>{ '068000000000001', '   ' };
        DocGenPdfMergeFlowAction.Request wrongType = new DocGenPdfMergeFlowAction.Request();
        wrongType.contentVersionIdsText = '069000000000001;069000000000002';
        DocGenPdfMergeFlowAction.Request single = new DocGenPdfMergeFlowAction.Request();
        single.contentVersionIdsText = '068000000000001';
        Test.startTest();
        List<DocGenPdfMergeFlowAction.Response> results = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ both, malformed, blank, wrongType, single }
        );
        Test.stopTest();
        List<String> messages = new List<String>{
            'just one',
            'Invalid ContentVersion ID',
            'nonblank',
            '068',
            'at least two'
        };
        for (Integer i = 0; i < results.size(); i++) {
            System.assertEquals(false, results[i].success);
            System.assertEquals(null, results[i].contentVersionId);
            System.assert(results[i].errorMessage.contains(messages[i]), JSON.serialize(results[i]));
        }
    }
    @IsTest
    static void mergesUploadedVersionsAndLinksToRecord() {
        Account account = new Account(Name = 'PDF merge target');
        insert account;
        ContentVersion a = source('First', DocGenPdfMergeFixtures.classic());
        ContentVersion b = source('Second', DocGenPdfMergeFixtures.modern());
        DocGenPdfMergeFlowAction.Request req = request(new List<Id>{ b.Id, a.Id, b.Id });
        req.documentTitle = 'Packet.pdf';
        req.relatedRecordId = account.Id;
        Test.startTest();
        DocGenPdfMergeFlowAction.Response result = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ req }
        )[0];
        Test.stopTest();
        System.assertEquals(true, result.success, JSON.serialize(result));
        ContentVersion output = [
            SELECT Title, PathOnClient, VersionData, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :result.contentVersionId
        ];
        System.assertEquals('Packet', output.Title);
        System.assertEquals('Packet.pdf', output.PathOnClient);
        System.assertEquals(result.contentDocumentId, output.ContentDocumentId);
        System.assertEquals(4, DocGenPdfMerger.pageCount(output.VersionData));
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :result.contentDocumentId AND LinkedEntityId = :account.Id
            ]
        );
        System.assertEquals(
            2,
            [SELECT COUNT() FROM ContentVersion WHERE Id IN :new List<Id>{ a.Id, b.Id }],
            'Sources are retained'
        );
    }
    @IsTest
    static void mixedRequestsKeepResponseOrderAndIsolateFailure() {
        ContentVersion a = source('First', DocGenPdfMergeFixtures.classic());
        ContentVersion b = source('Second', DocGenPdfMergeFixtures.modern());
        ContentVersion bad = source('Corrupt', Blob.valueOf('%PDF-1.7\ninvalid'));
        Test.startTest();
        Integer statements = Limits.getDmlStatements();
        List<DocGenPdfMergeFlowAction.Response> results = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{
                request(new List<Id>{ a.Id, b.Id }),
                request(new List<Id>{ bad.Id, b.Id }),
                request(new List<Id>{ b.Id, a.Id })
            }
        );
        System.assertEquals(1, Limits.getDmlStatements() - statements, 'One bulk insert for all successful packets');
        Test.stopTest();
        System.assertEquals(3, results.size());
        System.assertEquals(true, results[0].success, JSON.serialize(results[0]));
        System.assertEquals(false, results[1].success);
        System.assertEquals(null, results[1].contentVersionId);
        System.assertNotEquals(null, results[1].errorMessage);
        System.assertEquals(true, results[2].success, JSON.serialize(results[2]));
        System.assertNotEquals(results[0].contentDocumentId, results[2].contentDocumentId);
        Set<Id> createdDocuments = new Set<Id>{ results[0].contentDocumentId, results[2].contentDocumentId };
        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId IN :createdDocuments AND LinkedEntityId != :UserInfo.getUserId()
            ]
        );
    }
    @IsTest
    static void validatesEmptyNullAndWrongIds() {
        Test.startTest();
        System.assertEquals(0, DocGenPdfMergeFlowAction.mergePdfs(null).size());
        System.assertEquals(0, DocGenPdfMergeFlowAction.mergePdfs(new List<DocGenPdfMergeFlowAction.Request>()).size());
        List<DocGenPdfMergeFlowAction.Response> results = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{
                null,
                request(null),
                request(new List<Id>()),
                request(new List<Id>{ null, null }),
                request(new List<Id>{ '069000000000001', '069000000000002' }),
                request(new List<Id>{ '068000000000001', '068000000000002' })
            }
        );
        Test.stopTest();
        System.assertEquals(6, results.size());
        for (DocGenPdfMergeFlowAction.Response r : results) {
            System.assertEquals(false, r.success);
            System.assertNotEquals(null, r.errorMessage);
            System.assertEquals(null, r.contentVersionId);
        }
    }
    @IsTest
    static void rejectsNonPdfBeforeReadingBlobs() {
        ContentVersion a = source('Valid', DocGenPdfMergeFixtures.classic());
        ContentVersion text = new ContentVersion(
            Title = 'Text',
            PathOnClient = 'text.txt',
            VersionData = Blob.valueOf('Text')
        );
        insert text;
        Test.startTest();
        Integer queries = Limits.getQueries();
        DocGenPdfMergeFlowAction.Response r = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ request(new List<Id>{ a.Id, text.Id }) }
        )[0];
        System.assertEquals(1, Limits.getQueries() - queries, 'Metadata only, no VersionData query');
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('Every source'), JSON.serialize(r));
    }
    @IsTest
    static void rejectsOversizeBeforeReadingBlobs() {
        String padding = 'x'.repeat(DocGenPdfMergeFlowAction.SYNC_INPUT_LIMIT / 2 + 1);
        ContentVersion a = source('Too big', Blob.valueOf(padding));
        Test.startTest();
        Integer queries = Limits.getQueries();
        DocGenPdfMergeFlowAction.Response r = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ request(new List<Id>{ a.Id, a.Id }) }
        )[0];
        System.assertEquals(1, Limits.getQueries() - queries);
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('size budget'), JSON.serialize(r));
    }
    @IsTest
    static void padsOddDocumentsAndUsesExactHistoricalVersion() {
        ContentVersion a = source('One', DocGenPdfMergeFixtures.modern());
        ContentVersion previous = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :a.Id];
        insert new ContentVersion(
            Title = 'One newer',
            PathOnClient = 'one.pdf',
            ContentDocumentId = previous.ContentDocumentId,
            VersionData = DocGenPdfMergeFixtures.classic()
        );
        DocGenPdfMergeFlowAction.Request req = request(new List<Id>{ a.Id, a.Id });
        req.padOddDocuments = true;
        Test.startTest();
        DocGenPdfMergeFlowAction.Response r = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ req }
        )[0];
        Test.stopTest();
        System.assertEquals(true, r.success, JSON.serialize(r));
        ContentVersion output = [SELECT VersionData FROM ContentVersion WHERE Id = :r.contentVersionId];
        System.assertEquals(
            4,
            DocGenPdfMerger.pageCount(output.VersionData),
            'Exact old 1-page version plus one blank each'
        );
        System.assertEquals(2, DocGenPdfMerger.blankPageCount(output.VersionData));
    }
    @IsTest
    static void rejectsInaccessiblePrivateFiles() {
        Profile standard = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User user = new User(
            Alias = 'pdfuser',
            Email = 'pdf-user@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'PDF Restricted',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/New_York',
            ProfileId = standard.Id,
            Username = 'pdf-user-' + UserInfo.getOrganizationId() + '@example.com'
        );
        insert user;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            ContentVersion a = source('Private PDF', DocGenPdfMergeFixtures.classic());
            System.runAs(user) {
                Test.startTest();
                DocGenPdfMergeFlowAction.Response r = DocGenPdfMergeFlowAction.mergePdfs(
                    new List<DocGenPdfMergeFlowAction.Request>{ request(new List<Id>{ a.Id, a.Id }) }
                )[0];
                Test.stopTest();
                System.assertEquals(false, r.success);
                System.assertEquals(null, r.contentVersionId);
                System.assert(r.errorMessage.contains('inaccessible'), JSON.serialize(r));
            }
        }
    }
    @IsTest
    static void failedAttachmentDoesNotLeaveAnOrphanOutput() {
        ContentVersion a = source('PDF', DocGenPdfMergeFixtures.modern());
        DocGenPdfMergeFlowAction.Request good = request(new List<Id>{ a.Id, a.Id });
        DocGenPdfMergeFlowAction.Request bad = request(new List<Id>{ a.Id, a.Id });
        bad.relatedRecordId = '001000000000001';
        Test.startTest();
        List<DocGenPdfMergeFlowAction.Response> r = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ bad, good }
        );
        Test.stopTest();
        System.assertEquals(false, r[0].success);
        System.assertEquals(null, r[0].contentVersionId);
        System.assertEquals(true, r[1].success, JSON.serialize(r[1]));
        System.assertEquals(1, [SELECT COUNT() FROM ContentVersion WHERE Title = 'Merged Document']);
    }
    @IsTest
    static void returnsAnErrorInsteadOfExceedingTheQueryBudget() {
        ContentVersion cv = source('Query budget', DocGenPdfMergeFixtures.generation());
        Test.startTest();
        for (Integer i = 0; i < Limits.getLimitQueries() - 1; i++) {
            List<User> users = [SELECT Id FROM User LIMIT 1];
        }
        DocGenPdfMergeFlowAction.Response result = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ request(new List<Id>{ cv.Id, cv.Id }) }
        )[0];
        Test.stopTest();
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('SOQL'), result.errorMessage);
    }
    @IsTest
    static void rejectsTooManyPartsAndInvalidTitles() {
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 101; i++)
            ids.add('068000000000001');
        DocGenPdfMergeFlowAction.Request badTitle = request(new List<Id>{ '068000000000001', '068000000000001' });
        badTitle.documentTitle = 'x'.repeat(256);
        Test.startTest();
        List<DocGenPdfMergeFlowAction.Response> results = DocGenPdfMergeFlowAction.mergePdfs(
            new List<DocGenPdfMergeFlowAction.Request>{ request(ids), badTitle }
        );
        Test.stopTest();
        System.assertEquals(false, results[0].success);
        System.assert(results[0].errorMessage.contains('100'), results[0].errorMessage);
        System.assertEquals(false, results[1].success);
        System.assert(results[1].errorMessage.contains('255'), results[1].errorMessage);
    }
}

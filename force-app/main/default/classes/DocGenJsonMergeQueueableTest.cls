/**
 * Unit tests for DocGenJsonMergeQueueable (#403) — the async worker
 * DocGenFlowAction routes to when DocGenFlowHeapRouter decides a request needs
 * the larger async heap budget. Templates here are intentionally small/fast —
 * the heap-threshold behavior itself is DocGenFlowHeapRouter's job and is
 * covered by DocGenFlowHeapRouterTest; this file is scoped to "does the
 * Queueable actually do the right thing once it's running."
 */
@isTest
private class DocGenJsonMergeQueueableTest {
    private static Id makeTemplate() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'JsonMergeQueueable Test Template',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Query_Config__c = 'Name'
        );
        insert t;

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = t.Id,
            Is_Active__c = true,
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        insert ver;

        String docXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>Company: {Name}</w:t></w:r></w:p></w:body></w:document>';
        String relsXml =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>' +
            '</Relationships>';
        String contentTypes =
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
            '<Default Extension="xml" ContentType="application/xml"/>' +
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
            '</Types>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(contentTypes));
        zw.addEntry('_rels/.rels', Blob.valueOf(relsXml));
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));
        Blob docxBlob = zw.getArchive();

        ContentVersion cv = new ContentVersion(
            Title = 'JsonMergeQueueable Test',
            PathOnClient = 'jmq_test.docx',
            VersionData = docxBlob,
            FirstPublishLocationId = t.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];
        ver.Content_Version_Id__c = cv.Id;
        update ver;

        return t.Id;
    }

    private static Id makeJob(Id templateId, Id recordId) {
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'Draft',
            Template__c = templateId,
            Label__c = 'Test job',
            Parent_Record_Id__c = String.valueOf(recordId)
        );
        insert job;
        return job.Id;
    }

    @isTest
    static void successfulGenerationCompletesJobAndLinksToBothRecordAndJob() {
        Account acct = new Account(Name = 'JMQ Test Corp');
        insert acct;
        Id templateId = makeTemplate();
        Id jobId = makeJob(templateId, acct.Id);

        Test.startTest();
        System.enqueueJob(
            new DocGenJsonMergeQueueable(templateId, acct.Id, '{"Name":"JMQ Test Corp"}', null, null, true, jobId)
        );
        Test.stopTest();

        DocGen_Job__c job = [SELECT Status__c, Error_Log__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status__c);
        System.assertEquals(null, job.Error_Log__c);

        List<ContentDocumentLink> jobLinks = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :jobId
        ];
        System.assertEquals(1, jobLinks.size(), 'The finished document must be linked to the Job record.');

        List<ContentDocumentLink> recordLinks = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acct.Id AND ContentDocumentId = :jobLinks[0].ContentDocumentId
        ];
        System.assertEquals(
            1,
            recordLinks.size(),
            'saveToRecord=true must also link the same document to the source record.'
        );
    }

    @isTest
    static void saveToRecordFalseLinksOnlyToJobNotToRecord() {
        Account acct = new Account(Name = 'JMQ Test Corp 2');
        insert acct;
        Id templateId = makeTemplate();
        Id jobId = makeJob(templateId, acct.Id);

        Test.startTest();
        System.enqueueJob(
            new DocGenJsonMergeQueueable(templateId, acct.Id, '{"Name":"JMQ Test Corp 2"}', null, null, false, jobId)
        );
        Test.stopTest();

        DocGen_Job__c job = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Completed', job.Status__c);

        List<ContentDocumentLink> jobLinks = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :jobId
        ];
        System.assertEquals(1, jobLinks.size());

        List<ContentDocumentLink> recordLinks = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acct.Id AND ContentDocumentId = :jobLinks[0].ContentDocumentId
        ];
        System.assertEquals(
            0,
            recordLinks.size(),
            'saveToRecord=false must not attach the file to the source record\'s Files list.'
        );
    }

    @isTest
    static void invalidJsonArrayMarksJobFailedWithReason() {
        Account acct = new Account(Name = 'JMQ Test Corp 3');
        insert acct;
        Id templateId = makeTemplate();
        Id jobId = makeJob(templateId, acct.Id);

        Test.startTest();
        System.enqueueJob(
            new DocGenJsonMergeQueueable(
                templateId,
                acct.Id,
                '[1,2,3]', // deserializes to a List, not a Map — must fail cleanly, not crash
                null,
                null,
                false,
                jobId
            )
        );
        Test.stopTest();

        DocGen_Job__c job = [SELECT Status__c, Error_Log__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Failed', job.Status__c);
        System.assert(String.isNotBlank(job.Error_Log__c));
        System.assert(job.Error_Log__c.contains('Background generation failed'));
    }

    @isTest
    static void bogusTemplateIdMarksJobFailedWithReason() {
        Account acct = new Account(Name = 'JMQ Test Corp 4');
        insert acct;
        // Real Id shape, guaranteed not to exist: create then delete.
        DocGen_Template__c throwaway = new DocGen_Template__c(
            Name = 'Throwaway',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Query_Config__c = 'Name'
        );
        insert throwaway;
        Id bogusTemplateId = throwaway.Id;
        delete throwaway;
        // Template__c is a required field on the Job — use a real (different)
        // template for the job record itself; the bogus Id is what's passed to
        // the Queueable's own generation call below, which is what must fail.
        Id realTemplateId = makeTemplate();
        Id jobId = makeJob(realTemplateId, acct.Id);

        Test.startTest();
        System.enqueueJob(
            new DocGenJsonMergeQueueable(bogusTemplateId, acct.Id, '{"Name":"x"}', null, null, false, jobId)
        );
        Test.stopTest();

        DocGen_Job__c job = [SELECT Status__c, Error_Log__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals('Failed', job.Status__c);
        System.assert(String.isNotBlank(job.Error_Log__c));
    }

    @isTest
    static void describeFailureUsesTheReasonWhenPresentAndAGenericMessageWhenNot() {
        String withReason = DocGenJsonMergeQueueable.describeFailure('Apex heap size too large: 12345678');
        System.assert(withReason.contains('Apex heap size too large'));
        System.assert(withReason.startsWith('Background generation ran out of resources'));

        String withoutReason = DocGenJsonMergeQueueable.describeFailure('');
        System.assertEquals('Background generation failed unexpectedly (no further detail available).', withoutReason);

        String nullReason = DocGenJsonMergeQueueable.describeFailure(null);
        System.assertEquals('Background generation failed unexpectedly (no further detail available).', nullReason);
    }
}

/**
 * Unit tests for DocGenFlowAction's #403 routing branches (sync/async/reject
 * based on DocGenFlowHeapRouter's decision, plus the already-async guard).
 * The pre-existing sync jsonData path (record found/not found, malformed JSON,
 * etc.) already has coverage elsewhere (DocGenControllerTests, DocGenMiscTests)
 * — this file is scoped to what's new.
 *
 * Templates are built to specific sizes using DocGenFlowHeapRouter's own public
 * constants (not hardcoded numbers) so these tests stay correct if the
 * constants are retuned later, and each large template is built by adding
 * chunks directly to the ZipWriter one at a time (never accumulated in a
 * List first) to keep test-method heap usage safe regardless of target size —
 * the same technique used to build and verify the real fix in docgen-verify.
 */
@isTest
private class DocGenFlowActionTest {
    private static Id buildTemplate(String name, Integer targetPadBytes) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = name,
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
            '<Default Extension="bin" ContentType="application/octet-stream"/>' +
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' +
            '</Types>';

        Compression.ZipWriter zw = new Compression.ZipWriter();
        zw.addEntry('[Content_Types].xml', Blob.valueOf(contentTypes));
        zw.addEntry('_rels/.rels', Blob.valueOf(relsXml));
        zw.addEntry('word/document.xml', Blob.valueOf(docXml));

        if (targetPadBytes != null && targetPadBytes > 0) {
            Blob aesKey = Crypto.generateAesKey(256);
            Integer chunkSize = 700000;
            Integer totalPad = 0;
            Integer chunkIdx = 0;
            while (totalPad < targetPadBytes) {
                Integer thisChunk = Math.min(chunkSize, targetPadBytes - totalPad);
                String seed = '0';
                for (Integer i = 0; i < 20 && seed.length() < thisChunk + 100; i++) {
                    seed = seed + seed;
                }
                seed = seed.left(thisChunk);
                Blob plainChunk = Blob.valueOf(seed);
                seed = null;
                Blob iv = Crypto.generateAesKey(128);
                Blob cipherChunk = Crypto.encrypt('AES256', aesKey, iv, plainChunk);
                plainChunk = null;
                zw.addEntry('word/media/pad' + chunkIdx + '.bin', cipherChunk);
                totalPad += cipherChunk.size();
                cipherChunk = null;
                chunkIdx++;
            }
        }

        Blob docxBlob = zw.getArchive();

        ContentVersion cv = new ContentVersion(
            Title = name,
            PathOnClient = 'test.docx',
            VersionData = docxBlob,
            FirstPublishLocationId = t.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];
        ver.Content_Version_Id__c = cv.Id;
        update ver;

        return t.Id;
    }

    @isTest
    static void smallTemplateRoutesSyncUnchangedBehavior() {
        Account acct = new Account(Name = 'FlowAction Sync Test');
        insert acct;
        Id templateId = buildTemplate('Sync Test Template', null);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = templateId;
        req.recordId = acct.Id;
        req.saveToRecord = false;
        req.jsonData = '{"Name":"FlowAction Sync Test"}';

        Test.startTest();
        List<DocGenFlowAction.Response> resp = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, resp[0].success);
        System.assertEquals(null, resp[0].isAsync);
        System.assertEquals(null, resp[0].jobId);
        System.assertNotEquals(null, resp[0].contentDocumentId);
    }

    @isTest
    static void largeTemplateRoutesAsyncAndCompletesViaQueueable() {
        Account acct = new Account(Name = 'FlowAction Async Test');
        insert acct;
        // Comfortably over the non-PDF safe-sync ceiling, comfortably under the
        // safe-async ceiling — must land in ASYNC, not SYNC or REJECT.
        Integer syncCeiling = (Integer) ((DocGenFlowHeapRouter.safeSyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        Id templateId = buildTemplate('Async Test Template', syncCeiling + 500000);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = templateId;
        req.recordId = acct.Id;
        req.saveToRecord = true;
        req.jsonData = '{"Name":"FlowAction Async Test"}';

        Test.startTest();
        List<DocGenFlowAction.Response> resp = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest(); // flushes the enqueued DocGenJsonMergeQueueable synchronously

        System.assertEquals(true, resp[0].success);
        System.assertEquals(true, resp[0].isAsync);
        System.assertNotEquals(null, resp[0].jobId);
        System.assertEquals(null, resp[0].contentDocumentId);

        DocGen_Job__c job = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :resp[0].jobId];
        System.assertEquals('Completed', job.Status__c);
    }

    @isTest
    static void hugeTemplateRejectsCleanlyInsteadOfCrashing() {
        Account acct = new Account(Name = 'FlowAction Reject Test');
        insert acct;
        Integer asyncCeiling = (Integer) ((DocGenFlowHeapRouter.safeAsyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        Id templateId = buildTemplate('Reject Test Template', asyncCeiling + 500000);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = templateId;
        req.recordId = acct.Id;
        req.saveToRecord = false;
        req.jsonData = '{"Name":"FlowAction Reject Test"}';

        Test.startTest();
        List<DocGenFlowAction.Response> resp = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, resp[0].success);
        System.assert(resp[0].errorMessage.contains('too large'));
        System.assertEquals(null, resp[0].isAsync);
        System.assertEquals(null, resp[0].jobId);
    }

    @isTest
    static void pdfOverrideStaysSyncEvenAtSizeThatWouldRouteAsyncAsDocx() {
        Account acct = new Account(Name = 'FlowAction PDF Test');
        insert acct;
        Integer syncCeiling = (Integer) ((DocGenFlowHeapRouter.safeSyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        Id templateId = buildTemplate('PDF Override Test Template', syncCeiling + 500000);

        DocGenFlowAction.Request req = new DocGenFlowAction.Request();
        req.templateId = templateId;
        req.recordId = acct.Id;
        req.saveToRecord = false;
        req.outputFormatOverride = 'PDF';
        req.jsonData = '{"Name":"FlowAction PDF Test"}';

        Test.startTest();
        List<DocGenFlowAction.Response> resp = DocGenFlowAction.generateDocument(
            new List<DocGenFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, resp[0].success);
        System.assertEquals(
            null,
            resp[0].isAsync,
            'PDF has a higher ceiling than DOCX at this size (#403) and should stay synchronous.'
        );
        System.assertNotEquals(null, resp[0].contentDocumentId);
    }

    @isTest
    static void cannotEnqueueFromAnAlreadyAsyncContext() {
        Account acct = new Account(Name = 'FlowAction Guard Test');
        insert acct;
        Integer syncCeiling = (Integer) ((DocGenFlowHeapRouter.safeSyncHeapBytes() -
        DocGenFlowHeapRouter.BASE_OVERHEAD_BYTES) / DocGenFlowHeapRouter.TEMPLATE_HEAP_MULTIPLIER);
        Id templateId = buildTemplate('Guard Test Template', syncCeiling + 500000);

        Test.startTest();
        System.enqueueJob(new AsyncGuardProbe(templateId, acct.Id));
        Test.stopTest();

        Account refreshed = [SELECT Description FROM Account WHERE Id = :acct.Id];
        System.assert(
            refreshed.Description != null && refreshed.Description.contains('already running asynchronously'),
            'Calling DocGenFlowAction from inside a Queueable must be refused with a clear error, not silently ' +
                'attempt (and fail) to enqueue a second async job. Got: ' +
                refreshed.Description
        );
    }

    /** Runs DocGenFlowAction.generateDocument from inside a Queueable so System.isQueueable() is true. */
    public class AsyncGuardProbe implements Queueable {
        private Id templateId;
        private Id recordId;

        public AsyncGuardProbe(Id templateId, Id recordId) {
            this.templateId = templateId;
            this.recordId = recordId;
        }

        public void execute(QueueableContext ctx) {
            DocGenFlowAction.Request req = new DocGenFlowAction.Request();
            req.templateId = templateId;
            req.recordId = recordId;
            req.saveToRecord = false;
            req.jsonData = '{"Name":"Guard Probe"}';

            List<DocGenFlowAction.Response> resp = DocGenFlowAction.generateDocument(
                new List<DocGenFlowAction.Request>{ req }
            );
            // Stash the result on the record so the test (a separate transaction
            // by the time this Queueable runs) can read it back.
            update new Account(Id = recordId, Description = String.valueOf(resp[0].errorMessage));
        }
    }
}

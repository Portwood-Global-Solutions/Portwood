@IsTest
private class DocGenGiantQueryFlowActionTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'GQFA Test Co', Industry = 'Technology');
    }

    private static Id createSyncHtmlTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GQFA Tpl ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry'
        );
        insert tmpl;

        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf('<html><body><h1>{Name}</h1><p>{Industry}</p></body></html>'),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        return tmpl.Id;
    }

    @IsTest
    static void syncPathReturnsContentDocumentId() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createSyncHtmlTemplate();

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmplId;
        req.recordId = acct.Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, responses.size(), 'One response per request');
        DocGenGiantQueryFlowAction.Response r = responses[0];
        System.assertEquals(true, r.success, 'Sync path should succeed: ' + r.errorMessage);
        System.assertEquals(false, r.isGiantQuery, 'V1 config + small dataset = sync');
        System.assertNotEquals(null, r.contentDocumentId, 'CD id returned');
        System.assertNotEquals(null, r.contentVersionId, 'CV id returned');
    }

    @IsTest
    static void syncPathWithSaveToRecordLinksFile() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        Id tmplId = createSyncHtmlTemplate();

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmplId;
        req.recordId = acct.Id;
        req.saveToRecord = true;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, responses[0].success, 'Should succeed');
        // The link helper inserts a ContentDocumentLink — confirm one points to the record.
        List<ContentDocumentLink> cdls = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :acct.Id AND ContentDocumentId = :responses[0].contentDocumentId
        ];
        System.assert(!cdls.isEmpty(), 'CDL to the source record should exist');
    }

    @IsTest
    static void v3ConfigSmallDatasetTakesSyncPath() {
        // V3 JSON config triggers the scout-counts path (lines 88-108). With a
        // child count under 2000, giantRelationship stays null and falls through
        // to sync — exercising the configVersion>=3 branch without async setup.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GQFA V3 ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = '{"version":3,"nodes":[{"relationshipName":"Contacts","fields":["LastName"]}]}'
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf('<html><body><h1>{Name}</h1></body></html>'),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmpl.Id;
        req.recordId = acct.Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        DocGenGiantQueryFlowAction.Response r = responses[0];
        System.assertEquals(false, r.isGiantQuery, 'Under threshold = sync');
        System.assertEquals(true, r.success, 'Sync V3 path should succeed: ' + r.errorMessage);
    }

    @IsTest
    static void invalidTemplateIdSurfacesAsError() {
        // Valid Id shape, no template → load query returns empty → throws inside the action's try block.
        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = '001000000000000AAA'; // wrong sObject prefix but valid Id format
        req.recordId = [SELECT Id FROM Account LIMIT 1].Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, responses[0].success, 'Bad template id should fail gracefully');
        System.assertNotEquals(null, responses[0].errorMessage, 'errorMessage populated');
    }

    // ---------------------------------------------------------------------
    // #374 — heap-aware routing
    // ---------------------------------------------------------------------

    private static final String V3_CONTACTS =
        '{"v":3,"root":"Account","nodes":[' +
        '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],"parentNode":null,"lookupField":null,"relationshipName":null},' +
        '{"id":"n1","object":"Contact","fields":["LastName","Description"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
        ']}';

    // Few rows, each heavy: the router routes async on the SAMPLED payload, and
    // the row count stays under DocGenGiantQueryBatch's 50-row page size so the
    // batch runs in exactly one execute() (the test-context executeBatch limit).
    private static void seedContacts(Id acctId, Integer howMany, Integer descLen) {
        String descText = null;
        if (descLen != null && descLen > 0) {
            descText = 'x'.rightPad(descLen, 'x');
        }
        List<Contact> cs = new List<Contact>();
        for (Integer i = 0; i < howMany; i++) {
            cs.add(new Contact(LastName = 'G' + i, AccountId = acctId, Description = descText));
        }
        insert cs;
    }

    /** Word template with a pre-decomposed word/document.xml carrying a {#Contacts} loop. */
    private static Id createGiantWordTemplate(String queryConfig) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GQFA Word ' + Datetime.now().getTime(),
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = queryConfig
        );
        insert tmpl;

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c = tmpl.Id, Is_Active__c = true);
        insert ver;

        String documentXml =
            '<w:document><w:body><w:tbl><w:tr><w:tc><w:p>' +
            '{#Contacts}<w:r><w:t>{LastName}</w:t></w:r>{/Contacts}' +
            '</w:p></w:tc></w:tr></w:tbl></w:body></w:document>';
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_tmpl_xml_' + ver.Id + '_word__document.xml',
            PathOnClient = 'document.xml',
            VersionData = Blob.valueOf(documentXml),
            FirstPublishLocationId = ver.Id
        );
        insert cv;
        return tmpl.Id;
    }

    @IsTest
    static void heavyDatasetRoutesToTheGiantBatch() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        seedContacts(acct.Id, 40, 20000); // 40 rows, ~20KB each -> over the sampled heap estimate
        Id tmplId = createGiantWordTemplate(V3_CONTACTS);

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmplId;
        req.recordId = acct.Id;
        req.saveToRecord = true;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        DocGenGiantQueryFlowAction.Response r = responses[0];
        System.assertEquals(true, r.success, 'Routing must succeed: ' + r.errorMessage);
        System.assertEquals(true, r.isGiantQuery, '300 heavy rows route async, not sync');
        System.assertNotEquals(null, r.jobId, 'a Job Id is returned for polling');
        System.assertEquals(null, r.contentDocumentId, 'async path returns no sync document id');
        Test.stopTest();

        System.assertEquals(
            1,
            [SELECT COUNT() FROM DocGen_Job__c WHERE Id = :r.jobId],
            'the Giant Query job was created'
        );
    }

    @IsTest
    static void v1FlatConfigOverBudgetIsRefusedNotCrashedNorCorrupted() {
        // Pre-#374 a large V1 template crashed (uncatchable heap LimitException).
        // It is NOT auto-routed to the batch — that path skips processXml and
        // could silently drop parent-level tags. It fails loud with guidance.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        seedContacts(acct.Id, 40, 20000);
        Id tmplId = createGiantWordTemplate('Name, (SELECT LastName, Description FROM Contacts)');

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmplId;
        req.recordId = acct.Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        DocGenGiantQueryFlowAction.Response r = responses[0];
        Test.stopTest();

        System.assertEquals(false, r.success, 'V1 over budget is refused, not run');
        System.assertEquals(false, r.isGiantQuery, 'and not sent to the batch');
        System.assertEquals(null, r.jobId, 'no job created');
        System.assert(
            r.errorMessage.containsIgnoreCase('V3') || r.errorMessage.containsIgnoreCase('Runner'),
            'error tells the admin how to proceed: ' + r.errorMessage
        );
    }

    @IsTest
    static void smallDatasetStillGeneratesSynchronously() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        seedContacts(acct.Id, 3, 0);
        Id tmplId = createGiantWordTemplate(V3_CONTACTS);

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmplId;
        req.recordId = acct.Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, responses[0].isGiantQuery, '3 contacts stay on the synchronous path');
    }

    @IsTest
    static void htmlTemplateOverBudgetPointsToTheRunner() {
        // launchGiantBatch only handles Word (pre-decomposed document.xml). An
        // over-budget HTML template used to fall through to the crash-prone sync
        // path; now it fails fast with actionable guidance.
        Account acct = [SELECT Id FROM Account LIMIT 1];
        seedContacts(acct.Id, 40, 20000);
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'GQFA HTML big ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = V3_CONTACTS
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'b.html',
            VersionData = Blob.valueOf('<html><body>{#Contacts}<p>{Description}</p>{/Contacts}</body></html>'),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tmpl.Id;
        req.recordId = acct.Id;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, responses[0].success, 'HTML over budget is refused, not crashed');
        System.assert(
            responses[0].errorMessage.containsIgnoreCase('Runner'),
            'error points to the Runner: ' + responses[0].errorMessage
        );
    }

    @IsTest
    static void giantRouteFromAnAsyncContextReturnsAClearError() {
        Account acct = [SELECT Id FROM Account LIMIT 1];
        seedContacts(acct.Id, 40, 20000);
        Id tmplId = createGiantWordTemplate(V3_CONTACTS);

        Test.startTest();
        System.enqueueJob(new AsyncActionCaller(tmplId, acct.Id));
        Test.stopTest();

        System.assertNotEquals(null, asyncResponses, 'the queueable ran the action');
        System.assertEquals(false, asyncResponses[0].success, 'cannot start a batch from a queueable');
        System.assert(
            asyncResponses[0].errorMessage.containsIgnoreCase('asynchronously'),
            'error explains the async-context limitation: ' + asyncResponses[0].errorMessage
        );
    }

    private static List<DocGenGiantQueryFlowAction.Response> asyncResponses;

    private class AsyncActionCaller implements Queueable {
        private Id templateId;
        private Id recordId;
        AsyncActionCaller(Id templateId, Id recordId) {
            this.templateId = templateId;
            this.recordId = recordId;
        }
        public void execute(QueueableContext qc) {
            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = templateId;
            req.recordId = recordId;
            asyncResponses = DocGenGiantQueryFlowAction.generateDocument(
                new List<DocGenGiantQueryFlowAction.Request>{ req }
            );
        }
    }
}

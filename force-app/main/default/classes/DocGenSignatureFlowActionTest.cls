// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@isTest
private class DocGenSignatureFlowActionTest {
    @testSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
        TestDataFactory.attachRealDocxToTestTemplate();
    }

    private static DocGenSignatureFlowAction.Request buildRequest() {
        DocGen_Template__c tmpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.templateId = tmpl.Id;
        r.relatedRecordId = acc.Id;
        r.signerNames = new List<String>{ 'Alice Flow', 'Bob Flow' };
        r.signerEmails = new List<String>{ 'alice@flow.test', 'bob@flow.test' };
        r.signerRoles = new List<String>{ 'Buyer', 'Seller' };
        r.signerContactIds = null;
        return r;
    }

    @IsTest
    static void createsRequestAsDocGenUserWithoutTokenFieldAccess() {
        DocGenSignatureFlowAction.Request request = buildRequest();
        User sender = new User(
            Alias = 'docsend',
            Email = 'docsend@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'DocGen Sender',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
            .Id,
            Username = 'docsend.' + System.now().getTime() + '@example.test'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert sender;
            insert new PermissionSetAssignment(
                AssigneeId = sender.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1]
                .Id
            );
        }
        update new Account(Id = request.relatedRecordId, OwnerId = sender.Id);
        insert new DocGen_Template__Share(
            ParentId = request.templateId,
            UserOrGroupId = sender.Id,
            AccessLevel = 'Read',
            RowCause = Schema.DocGen_Template__Share.RowCause.Manual
        );
        request.sendEmails = false;
        DocGenSignatureFlowAction.Result result;
        System.runAs(sender) {
            System.assertEquals(false, DocGen_Signature_Request__c.Secure_Token__c.getDescribe().isAccessible());
            System.assertEquals(false, DocGen_Signature_Request__c.Secure_Token__c.getDescribe().isCreateable());
            System.assertEquals(false, DocGen_Signer__c.Secure_Token__c.getDescribe().isAccessible());
            System.assertEquals(false, DocGen_Signer__c.Secure_Token__c.getDescribe().isCreateable());
            Test.startTest();
            result = DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ request })[0];
            Test.stopTest();
        }

        System.assertEquals(true, result.success, 'Signature request failed: ' + result.errorMessage);
        System.assertNotEquals(null, result.signatureRequestId);
        DocGen_Signature_Request__c stored = [
            SELECT Secure_Token__c, Template__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :result.signatureRequestId
        ];
        System.assertEquals(request.templateId, stored.Template__c);
        System.assert(String.isNotBlank(stored.Secure_Token__c), 'Request verification token must be generated');
        List<DocGen_Signer__c> signers = [
            SELECT Secure_Token__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :result.signatureRequestId
        ];
        System.assertEquals(2, signers.size());
        for (DocGen_Signer__c signer : signers) {
            System.assert(String.isNotBlank(signer.Secure_Token__c), 'Signer token must be generated');
        }
    }

    // =========================================================================
    // Happy path — default silent behavior from Flow
    // =========================================================================

    @isTest
    static void testGenerate_defaultSilent() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        // sendEmails left null — sends like every pre-#195 release (so existing
        // subscriber Flows keep emailing signers); in this OWA-less test context
        // the send path bails before Messaging.sendEmail, so invocations stay 0.

        Integer emailsBefore = Limits.getEmailInvocations();

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        Integer emailsAfter = Limits.getEmailInvocations();
        System.assertEquals(emailsBefore, emailsAfter, 'Flow default must not send emails');

        System.assertEquals(1, results.size(), 'One result per request');
        DocGenSignatureFlowAction.Result r = results[0];
        System.assertNotEquals(null, r.signatureRequestId, 'signatureRequestId populated');
        System.assertEquals(2, r.signerUrls.size(), 'Two signer URLs');
        System.assertEquals(2, r.signerNames.size(), 'Two signer names echoed');
        System.assertEquals(2, r.signerEmails.size(), 'Two signer emails echoed');
        System.assertEquals(2, r.signerRoles.size(), 'Two signer roles echoed');
        System.assertEquals('Alice Flow', r.signerNames[0]);
        System.assertEquals('alice@flow.test', r.signerEmails[0]);
        System.assertEquals('Buyer', r.signerRoles[0]);
        System.assert(r.signerUrls[0].contains('token='), 'URL contains signing token');

        // Verify the signature request + signers were persisted
        DocGen_Signature_Request__c persisted = [
            SELECT Id, Template__c, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :r.signatureRequestId
            LIMIT 1
        ];
        System.assertEquals('Sent', persisted.Status__c);
        List<DocGen_Signer__c> signers = [
            SELECT Id, Role_Name__c, Signer_Email__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :r.signatureRequestId
            ORDER BY Sort_Order__c
        ];
        System.assertEquals(2, signers.size());
        System.assertEquals('Buyer', signers[0].Role_Name__c);
        System.assertEquals('Seller', signers[1].Role_Name__c);
    }

    // =========================================================================
    // Explicit sendEmails = true path
    // =========================================================================

    @isTest
    static void testGenerate_sendEmailsExplicit() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        req.sendEmails = true;

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertNotEquals(null, results[0].signatureRequestId);
        System.assertEquals(2, results[0].signerUrls.size());
    }

    // =========================================================================
    // #195 — explicit sendEmails = false suppresses the branded invites entirely
    // =========================================================================

    @isTest
    static void testGenerate_sendEmailsFalse_suppressesInvites() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        req.sendEmails = false;

        Integer emailsBefore = Limits.getEmailInvocations();

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(Limits.getEmailInvocations(), emailsBefore, 'sendEmails=false must not send');
        System.assertEquals(1, results.size());
        DocGenSignatureFlowAction.Result r = results[0];
        System.assertNotEquals(null, r.signatureRequestId, 'request still created');
        System.assertEquals(2, r.signerUrls.size(), 'signer URLs still returned for the Flow to send itself');

        // The email block must be skipped ENTIRELY — not just fail on a missing
        // OWA. A send attempt would write Email_Status__c (either 'Sent' or the
        // no-OWA error); suppression leaves it untouched.
        DocGen_Signature_Request__c persisted = [
            SELECT Email_Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :r.signatureRequestId
            LIMIT 1
        ];
        System.assertEquals(null, persisted.Email_Status__c, 'no send attempt when sendEmails=false');
    }

    // =========================================================================
    // Multi-request bulk invocation
    // =========================================================================

    @isTest
    static void testGenerate_multipleRequests() {
        DocGenSignatureFlowAction.Request r1 = buildRequest();
        DocGenSignatureFlowAction.Request r2 = buildRequest();
        r2.signerNames = new List<String>{ 'Carol Flow' };
        r2.signerEmails = new List<String>{ 'carol@flow.test' };
        r2.signerRoles = new List<String>{ 'Witness' };

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r1, r2 }
        );
        Test.stopTest();

        System.assertEquals(2, results.size(), 'One result per request');
        System.assertEquals(2, results[0].signerUrls.size());
        System.assertEquals(1, results[1].signerUrls.size());
        System.assertEquals('Witness', results[1].signerRoles[0]);
    }

    // =========================================================================
    // Role defaulting (empty / short roles list → "Signer")
    // =========================================================================

    @isTest
    static void testGenerate_roleDefaulting() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerRoles = null; // no roles → should default to "Signer"

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals('Signer', results[0].signerRoles[0]);
        System.assertEquals('Signer', results[0].signerRoles[1]);
    }

    @isTest
    static void testGenerate_partialRolesList() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerRoles = new List<String>{ 'Buyer' }; // only one role for two signers

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals('Buyer', results[0].signerRoles[0]);
        System.assertEquals('Signer', results[0].signerRoles[1], 'Missing role defaults to "Signer"');
    }

    // =========================================================================
    // Empty / null input list
    // =========================================================================

    @isTest
    static void testGenerate_emptyInputList() {
        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>()
        );
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    @isTest
    static void testGenerate_nullInputList() {
        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(null);
        Test.stopTest();
        System.assertEquals(0, results.size());
    }

    // =========================================================================
    // Validation failures
    // =========================================================================

    @isTest
    static void testValidate_nullTemplateId() {
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.relatedRecordId = TestDataFactory.getTestAccount().Id;
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Template Id'));
        }
        Test.stopTest();
        System.assert(caught, 'Missing templateId must throw');
    }

    @isTest
    static void testValidate_nullRelatedRecordId() {
        DocGenSignatureFlowAction.Request r = new DocGenSignatureFlowAction.Request();
        r.templateId = TestDataFactory.getTestTemplate().Id;
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Missing relatedRecordId must throw');
    }

    @isTest
    static void testValidate_emptySignerNames() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>();
        r.signerEmails = new List<String>();

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('signer'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    @isTest
    static void testValidate_signerListLengthMismatch() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerEmails = new List<String>{ 'a@test.com' }; // two names, one email

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
        }
        Test.stopTest();
        System.assert(caught, 'Length mismatch must throw');
    }

    @isTest
    static void testValidate_blankSignerName() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>{ '' };
        r.signerEmails = new List<String>{ 'x@test.com' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Name'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    @isTest
    static void testValidate_blankSignerEmail() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerNames = new List<String>{ 'X' };
        r.signerEmails = new List<String>{ '' };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ r });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Email'));
        }
        Test.stopTest();
        System.assert(caught);
    }

    // =========================================================================
    // Contact Ids provided for signers
    // =========================================================================

    @isTest
    static void testGenerate_withContactIds() {
        List<Contact> contacts = TestDataFactory.getTestContacts();
        System.assert(contacts.size() >= 2, 'Need at least two test contacts');

        DocGenSignatureFlowAction.Request r = buildRequest();
        r.signerContactIds = new List<String>{ contacts[0].Id, contacts[1].Id };

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        List<DocGen_Signer__c> signers = [
            SELECT Contact__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :results[0].signatureRequestId
            ORDER BY Sort_Order__c
        ];
        System.assertEquals(contacts[0].Id, signers[0].Contact__c, 'First signer linked to first contact');
        System.assertEquals(contacts[1].Id, signers[1].Contact__c, 'Second signer linked to second contact');
    }

    // =========================================================================
    // Null request in the input list
    // =========================================================================

    @isTest
    static void testValidate_nullRequestInList() {
        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ null });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('null'), 'Error mentions null');
        }
        Test.stopTest();
        System.assert(caught, 'Null request must throw');
    }

    // =========================================================================
    // Template not found
    // =========================================================================

    @isTest
    static void testGenerate_templateNotFound() {
        DocGenSignatureFlowAction.Request r = buildRequest();
        r.templateId = '001000000000000AAA'; // any fake Id

        Test.startTest();
        // Runtime errors (like template not found) are caught and returned in Result
        // so Flows get a structured error instead of crashing the Flow.
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ r }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success, 'Invalid template Id should result in success=false');
        System.assertNotEquals(null, results[0].errorMessage, 'Error message should be populated');
    }

    // =========================================================================
    // Standalone DocGenSigner collection (v2.7) — the Flow-buildable input
    // =========================================================================

    @isTest
    static void testGenerate_signerRecordsHappyPath() {
        DocGen_Template__c tmpl = TestDataFactory.getTestTemplate();
        Account acc = TestDataFactory.getTestAccount();
        DocGenSignatureFlowAction.Request req = new DocGenSignatureFlowAction.Request();
        req.templateId = tmpl.Id;
        req.relatedRecordId = acc.Id;

        DocGenSigner s1 = new DocGenSigner();
        s1.name = 'Dana Records';
        s1.email = 'dana@records.test';
        s1.role = 'Buyer';
        DocGenSigner s2 = new DocGenSigner();
        s2.name = 'Evan Records';
        s2.email = 'evan@records.test';
        // role left blank -> defaults to "Signer"
        req.signerRecords = new List<DocGenSigner>{ s1, s2 };

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        DocGenSignatureFlowAction.Result r = results[0];
        System.assertEquals(true, r.success, 'signerRecords path should succeed: ' + r.errorMessage);
        System.assertEquals(2, r.signerUrls.size(), 'Two signer URLs from signerRecords');
        System.assertEquals('Buyer', r.signerRoles[0]);
        System.assertEquals('Signer', r.signerRoles[1], 'Blank role defaults to Signer');

        List<DocGen_Signer__c> persisted = [
            SELECT Signer_Email__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :r.signatureRequestId
            ORDER BY Sort_Order__c
        ];
        System.assertEquals(2, persisted.size());
        System.assertEquals('dana@records.test', persisted[0].Signer_Email__c);
    }

    @isTest
    static void testValidate_signerRecords_blankName() {
        DocGenSignatureFlowAction.Request req = new DocGenSignatureFlowAction.Request();
        req.templateId = TestDataFactory.getTestTemplate().Id;
        req.relatedRecordId = TestDataFactory.getTestAccount().Id;
        DocGenSigner s = new DocGenSigner();
        s.name = '';
        s.email = 'x@test.com';
        req.signerRecords = new List<DocGenSigner>{ s };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ req });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Name'));
        }
        Test.stopTest();
        System.assert(caught, 'Blank name in signerRecords must throw');
    }

    @isTest
    static void testValidate_signerRecords_blankEmail() {
        DocGenSignatureFlowAction.Request req = new DocGenSignatureFlowAction.Request();
        req.templateId = TestDataFactory.getTestTemplate().Id;
        req.relatedRecordId = TestDataFactory.getTestAccount().Id;
        DocGenSigner s = new DocGenSigner();
        s.name = 'No Email';
        s.email = '';
        s.contactId = null;
        req.signerRecords = new List<DocGenSigner>{ s };

        Test.startTest();
        Boolean caught = false;
        try {
            DocGenSignatureFlowAction.generate(new List<DocGenSignatureFlowAction.Request>{ req });
        } catch (DocGenException e) {
            caught = true;
            System.assert(e.getMessage().contains('Email'));
        }
        Test.stopTest();
        System.assert(caught, 'Blank email in signerRecords must throw');
    }

    @isTest
    static void testGenerate_expirationDaysStampsWindow() {
        DocGenSignatureFlowAction.Request req = buildRequest();
        req.expirationDays = 7;

        Test.startTest();
        List<DocGenSignatureFlowAction.Result> results = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'Send should succeed: ' + results[0].errorMessage);
        DocGen_Signature_Request__c created = [
            SELECT Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :results[0].signatureRequestId
        ];
        System.assertNotEquals(null, created.Expires_At__c, 'Expiration must be stamped at send');
        Long deltaMs = created.Expires_At__c.getTime() - System.now().addDays(7).getTime();
        System.assert(
            Math.abs(deltaMs) < 5 * 60 * 1000,
            'Link Expiration input must set a ~7-day window; delta ms=' + deltaMs
        );
    }
}

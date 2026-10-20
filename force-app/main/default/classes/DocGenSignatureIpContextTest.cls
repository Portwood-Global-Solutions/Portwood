@IsTest
private class DocGenSignatureIpContextTest {
    private static final String TOKEN = 'a'.repeat(64);
    @IsTest
    static void contextIsBoundToSignerAndAuthenticatedAcrossTransactions() {
        DocGenSignatureIpContext.initialize();
        String context = DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42');
        System.assertEquals('203.0.113.42', DocGenSignatureIpContext.verify(TOKEN, context));
        System.assertEquals(null, DocGenSignatureIpContext.verify('b'.repeat(64), context));
        System.assertEquals(null, DocGenSignatureIpContext.verify(TOKEN, context + 'tampered'));
        System.assertEquals(null, DocGenSignatureIpContext.verify(TOKEN, 'sfip1.bad.bad'));
        System.assertEquals(
            '2001:db8::42',
            DocGenSignatureIpContext.verify(TOKEN, DocGenSignatureIpContext.issue(TOKEN, '2001:db8::42'))
        );
        System.assertEquals(1, [SELECT COUNT() FROM DocGen_Security__c], 'One private key is reused.');
    }
    @IsTest
    static void alteredPayloadAndExpiredProofAreRejected() {
        DocGenSignatureIpContext.initialize();
        String context = DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42');
        List<String> parts = context.split('\\.');
        Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(
            EncodingUtil.base64Decode(parts[1]).toString()
        );
        data.put('ip', '198.51.100.99');
        String payload = EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(data)));
        System.assertEquals(null, DocGenSignatureIpContext.verify(TOKEN, 'sfip1.' + payload + '.' + parts[2]));
        Long expires = Datetime.now().getTime() - 1000;
        data.put('expires', String.valueOf(expires));
        data.put('issued', String.valueOf(expires - DocGenSignatureIpContext.LIFETIME_MS));
        payload = EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(data)));
        Blob key = EncodingUtil.convertFromHex([SELECT Key__c FROM DocGen_Security__c LIMIT 1].Key__c);
        context =
            'sfip1.' +
            payload +
            '.' +
            EncodingUtil.base64Encode(Crypto.generateMac('HmacSHA256', Blob.valueOf(payload), key));
        System.assertEquals(null, DocGenSignatureIpContext.verify(TOKEN, context));
        Boolean rejected = false;
        try {
            DocGenSignatureController.resolveClientIp(context, TOKEN);
        } catch (AuraHandledException expected) {
            rejected = true;
        }
        System.assert(rejected, 'A stale network observation must require a reload.');
    }
    @IsTest
    static void pageRequestCapturesIpButRejectedLinksDoNotInitializeSecrets() {
        Test.setCurrentPage(Page.DocGenSignaturePdf);
        ApexPages.currentPage().getParameters().put('token', TOKEN);
        ApexPages.currentPage().getHeaders().put('X-Forwarded-For', '203.0.113.42, 192.0.2.10');
        DocGenSignatureController rejected = new DocGenSignatureController();
        rejected.getInitialPage();
        System.assertEquals('', rejected.getNativeIpProof());
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Security__c]);
        Account account = new Account(Name = 'Native IP test');
        insert account;
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Related_Record_Id__c = account.Id,
            Status__c = 'Sent'
        );
        insert request;
        insert new DocGen_Signer__c(
            Signature_Request__c = request.Id,
            Signer_Name__c = 'Fictional Example',
            Signer_Email__c = 'example@example.invalid',
            Secure_Token__c = TOKEN,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        DocGenSignatureController controller = new DocGenSignatureController();
        DocGenSignatureIpContext.initialize();
        Integer writesBefore = Limits.getDmlStatements();
        controller.getInitialPage();
        System.assertEquals(writesBefore, Limits.getDmlStatements(), 'A guest page render is read-only.');
        System.assertEquals('203.0.113.42', controller.getNativeIpAddress());
        String context = controller.getNativeIpProof();
        System.assertEquals('203.0.113.42', DocGenSignatureIpContext.verify(TOKEN, context));
        ApexPages.currentPage().getHeaders().clear();
        System.assertEquals(
            '203.0.113.42',
            DocGenSignatureController.resolveClientIp(context, TOKEN),
            'Stateless remoting uses the authenticated page observation.'
        );
        System.assertEquals(
            'Pending',
            [SELECT Status__c FROM DocGen_Signer__c LIMIT 1].Status__c,
            'Capture never signs or marks a link viewed.'
        );
    }
    @IsTest
    static void missingOrInvalidAddressDoesNotCreateAKey() {
        System.assertEquals('', DocGenSignatureIpContext.issue(TOKEN, 'Unknown'));
        System.assertEquals('', DocGenSignatureIpContext.issue('bad', '203.0.113.42'));
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Security__c]);
        System.assertEquals(null, DocGenSignatureIpContext.verify(TOKEN, 'sfip1.a.b'));
    }
    @IsTest
    static void signatureAuditRetainsNativeIpWithoutRequestHeaders() {
        Account account = new Account(Name = 'Native audit test');
        insert account;
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Related_Record_Id__c = account.Id,
            Status__c = 'Sent',
            Require_Email_Verification__c = false
        );
        insert request;
        insert new DocGen_Signer__c(
            Signature_Request__c = request.Id,
            Signer_Name__c = 'Fictional Example',
            Signer_Email__c = 'example@example.invalid',
            Secure_Token__c = TOKEN,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        DocGenSignatureIpContext.initialize();
        String context = DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42');
        Test.startTest();
        DocGenSignatureController.SavePdfSignatureResult result = DocGenSignatureController.savePdfSignature(
            TOKEN,
            'Fictional Example',
            true,
            context,
            'TestAgent',
            null
        );
        Test.stopTest();
        System.assertEquals(true, result.success);
        System.assertEquals(
            '203.0.113.42',
            [SELECT IP_Address__c FROM DocGen_Signature_Audit__c LIMIT 1].IP_Address__c
        );
    }
    @IsTest
    static void platformObservationTakesPriorityOverForwardingHints() {
        Test.setCurrentPage(Page.DocGenSignaturePdf);
        ApexPages.currentPage().getHeaders().put('X-Salesforce-SIP', '203.0.113.42');
        ApexPages.currentPage().getHeaders().put('X-Forwarded-For', '198.51.100.99');
        System.assertEquals('203.0.113.42', DocGenSignatureController.resolveClientIp('192.0.2.1', TOKEN));
    }
    @IsTest
    static void documentQueriesCannotReadTheSigningKey() {
        DocGenSignatureIpContext.initialize();
        DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42');
        System.assertEquals(true, DocGenController.getObjectFields('DocGen_Security__c').isEmpty());
        for (
            String query : new List<String>{
                'SELECT Key__c FROM DocGen_Security__c',
                'SELECT portwoodglobal__Key__c FROM portwoodglobal__DocGen_Security__c'
            }
        ) {
            Boolean rejected = false;
            try {
                DocGenSignatureIpContext.publicQuery(query);
            } catch (DocGenException expected) {
                rejected = true;
            }
            System.assert(rejected);
        }
        System.assertEquals('SELECT Id FROM Account', DocGenSignatureIpContext.publicQuery('SELECT Id FROM Account'));
        DocGen_Security__c settings = [SELECT Id FROM DocGen_Security__c LIMIT 1];
        Boolean rejected = false;
        try {
            DocGenDataRetriever.getRecordData(settings.Id, 'DocGen_Security__c', 'Key__c');
        } catch (DocGenException expected) {
            rejected = true;
        }
        System.assert(rejected, 'A template query must not reveal the proof signing key.');
    }
    @IsTest
    static void authorizedSetupInitializesKeyWithoutGuestWrites() {
        System.assertEquals(
            '',
            DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42'),
            'Rendering cannot initialize a missing key.'
        );
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Security__c]);
        DocGenSetupController.saveSettings('https://example.my.salesforce-sites.com');
        System.assertEquals(1, [SELECT COUNT() FROM DocGen_Security__c]);
        DocGenSignatureIpContext.initialize();
        System.assertEquals(1, [SELECT COUNT() FROM DocGen_Security__c], 'Setup is idempotent.');
        System.assertNotEquals('', DocGenSignatureIpContext.issue(TOKEN, '203.0.113.42'));
    }
}

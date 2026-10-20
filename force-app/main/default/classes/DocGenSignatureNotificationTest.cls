@IsTest
private class DocGenSignatureNotificationTest {
    @TestSetup
    static void setup() {
        Account account = new Account(Name = 'Parallel notification test');
        insert account;
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Related_Record_Id__c = account.Id,
            Source_Document_Id__c = '068000000000001AAA',
            Status__c = 'In Progress',
            Signing_Order__c = 'Parallel'
        );
        insert request;
        List<DocGen_Signer__c> signers = new List<DocGen_Signer__c>();
        for (Integer order = 1; order <= 4; order++) {
            signers.add(
                new DocGen_Signer__c(
                    Signature_Request__c = request.Id,
                    Signer_Name__c = 'Signer ' + order,
                    Signer_Email__c = 'signer' + order + '@example.com',
                    Role_Name__c = 'Role ' + order,
                    Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
                    Status__c = 'Pending',
                    Sort_Order__c = order
                )
            );
        }
        insert signers;
    }

    private static List<DocGen_Signer__c> signers() {
        return [
            SELECT Id, Signature_Request__c, Status__c, Secure_Token__c, Sort_Order__c
            FROM DocGen_Signer__c
            ORDER BY Sort_Order__c
        ];
    }

    private static DocGen_Signature_PDF__e completion(DocGen_Signer__c signer) {
        return new DocGen_Signature_PDF__e(Request_Id__c = signer.Signature_Request__c, Signer_Id__c = signer.Id);
    }

    private static void assertNotice(Integer index, Integer signerOrder) {
        Messaging.SingleEmailMessage message = DocGenSignatureEmailService.senderNotificationMessages[index];
        System.assertEquals('Signature Update: Signer ' + signerOrder + ' has signed', message.getSubject());
        System.assert(
            message.getHtmlBody().contains('Signer ' + signerOrder + ' (Role ' + signerOrder + ')'),
            'The body must use the same signer and role as the subject: ' + message.getHtmlBody()
        );
    }

    @IsTest
    static void lowerOrderSignerCompletingLaterGetsOwnNotification() {
        List<DocGen_Signer__c> signers = signers();
        DocGenSignatureEmailService.senderNotificationMessages = new List<Messaging.SingleEmailMessage>();
        Test.startTest();
        signers[2].Status__c = 'Signed';
        update signers[2];
        DocGenSignaturePdfEventHandler.handle(new List<DocGen_Signature_PDF__e>{ completion(signers[2]) });
        signers[0].Status__c = 'Signed';
        update signers[0];
        DocGenSignaturePdfEventHandler.handle(new List<DocGen_Signature_PDF__e>{ completion(signers[0]) });
        Test.stopTest();
        System.assertEquals(2, DocGenSignatureEmailService.senderNotificationMessages.size());
        assertNotice(0, 3);
        assertNotice(1, 1);
    }

    @IsTest
    static void batchedEventsKeepEachSignerIdentity() {
        List<DocGen_Signer__c> signers = signers();
        signers[0].Status__c = 'Signed';
        signers[2].Status__c = 'Signed';
        update signers;
        DocGenSignatureEmailService.senderNotificationMessages = new List<Messaging.SingleEmailMessage>();
        Test.startTest();
        DocGenSignaturePdfEventHandler.handle(
            new List<DocGen_Signature_PDF__e>{ completion(signers[2]), completion(signers[0]) }
        );
        Test.stopTest();
        System.assertEquals(2, DocGenSignatureEmailService.senderNotificationMessages.size());
        assertNotice(0, 3);
        assertNotice(1, 1);
    }

    @IsTest
    static void requestOnlyEventWithOneSignedSignerRemainsCompatible() {
        List<DocGen_Signer__c> signers = signers();
        signers[2].Status__c = 'Signed';
        update signers[2];
        DocGenSignatureEmailService.senderNotificationMessages = new List<Messaging.SingleEmailMessage>();
        Test.startTest();
        DocGenSignaturePdfEventHandler.handle(
            new List<DocGen_Signature_PDF__e>{
                new DocGen_Signature_PDF__e(Request_Id__c = signers[0].Signature_Request__c)
            }
        );
        Test.stopTest();
        System.assertEquals(1, DocGenSignatureEmailService.senderNotificationMessages.size());
        assertNotice(0, 3);
    }

    @IsTest
    static void requestOnlyEventDoesNotGuessAmongMultipleSignedSigners() {
        List<DocGen_Signer__c> signers = signers();
        signers[0].Status__c = 'Signed';
        signers[2].Status__c = 'Signed';
        update signers;
        DocGenSignatureEmailService.senderNotificationMessages = new List<Messaging.SingleEmailMessage>();
        Test.startTest();
        DocGenSignaturePdfEventHandler.handle(
            new List<DocGen_Signature_PDF__e>{
                new DocGen_Signature_PDF__e(Request_Id__c = signers[0].Signature_Request__c)
            }
        );
        Test.stopTest();
        System.assertEquals(
            0,
            DocGenSignatureEmailService.senderNotificationMessages.size(),
            'A request-only event cannot identify which of several signed people caused it'
        );
    }

    @IsTest
    static void invalidForeignAndPendingSignersCannotBeAttributed() {
        List<DocGen_Signer__c> signers = signers();
        signers[2].Status__c = 'Signed';
        update signers[2];
        DocGen_Signature_Request__c foreignRequest = new DocGen_Signature_Request__c(
            Status__c = 'In Progress',
            Source_Document_Id__c = '068000000000001AAA'
        );
        insert foreignRequest;
        DocGen_Signer__c foreignSigner = new DocGen_Signer__c(
            Signature_Request__c = foreignRequest.Id,
            Signer_Name__c = 'Unrelated signer',
            Signer_Email__c = 'other@example.com',
            Status__c = 'Signed',
            Sort_Order__c = 1
        );
        insert foreignSigner;
        Id requestId = signers[0].Signature_Request__c;
        DocGenSignatureEmailService.senderNotificationMessages = new List<Messaging.SingleEmailMessage>();
        Test.startTest();
        DocGenSignaturePdfEventHandler.handle(
            new List<DocGen_Signature_PDF__e>{
                new DocGen_Signature_PDF__e(Request_Id__c = requestId, Signer_Id__c = foreignSigner.Id),
                completion(signers[1]),
                new DocGen_Signature_PDF__e(Request_Id__c = requestId, Signer_Id__c = 'not-an-id')
            }
        );
        Test.stopTest();
        System.assertEquals(
            0,
            DocGenSignatureEmailService.senderNotificationMessages.size(),
            'Only the signed signer bound to the event request can be named'
        );
    }
}

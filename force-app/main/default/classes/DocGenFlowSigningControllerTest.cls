@IsTest
private class DocGenFlowSigningControllerTest {
    private static final String TOKEN_A = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
    private static final String TOKEN_B = 'b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3';

    private static DocGen_Signature_Request__c makeRequest(String status, Datetime expiresAt, String originalCv) {
        Account acc = new Account(Name = 'Flow Signing Test');
        insert acc;
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Signer_Name__c = 'Req Owner',
            Signer_Email__c = 'owner@test.com',
            Related_Record_Id__c = acc.Id,
            Secure_Token__c = 'c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4',
            Status__c = status,
            Expires_At__c = expiresAt,
            Original_Document_CV_Id__c = originalCv
        );
        Database.insert(req, AccessLevel.SYSTEM_MODE);
        return req;
    }

    private static DocGen_Signer__c makeSigner(Id reqId, String token, String status, Integer order) {
        DocGen_Signer__c s = new DocGen_Signer__c(
            Signature_Request__c = reqId,
            Signer_Name__c = 'Signer ' + order,
            Signer_Email__c = 'signer' + order + '@test.com',
            Role_Name__c = 'Member',
            Secure_Token__c = token,
            Status__c = status,
            Sort_Order__c = order
        );
        Database.insert(s, AccessLevel.SYSTEM_MODE);
        return s;
    }

    @IsTest
    static void invalidTokenShapeIsRejected() {
        for (String bad : new List<String>{ null, '', 'short', 'z'.repeat(64) }) {
            try {
                DocGenFlowSigningController.getSignerStatus(bad);
                System.assert(false, 'expected an exception for token: ' + bad);
            } catch (AuraHandledException e) {
                System.assert(true);
            }
        }
    }

    @IsTest
    static void unknownTokenIsUnavailableNotAnError() {
        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals(true, st.isUnavailable);
        System.assertEquals(false, st.isSigned);
        System.assertEquals(null, st.signerStatus);
    }

    @IsTest
    static void pendingSignerOnMultiSignerRequestIsNotSignedNorComplete() {
        DocGen_Signature_Request__c req = makeRequest('Sent', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Pending', 1);
        makeSigner(req.Id, TOKEN_B, 'Pending', 2);

        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals('Pending', st.signerStatus);
        System.assertEquals(false, st.isSigned);
        System.assertEquals(false, st.isUnavailable);
        System.assertEquals(false, st.isExpired);
        System.assertEquals(false, st.requestComplete);
        System.assertEquals(false, st.isPreparedPdf);
    }

    @IsTest
    static void signedSoleSignerIsSignedAndRequestComplete() {
        DocGen_Signature_Request__c req = makeRequest('Signed', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Signed', 1);

        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals(true, st.isSigned);
        System.assertEquals(true, st.requestComplete);
        // Already signed must not be reported unavailable, or a refresh mid-Flow would show an error.
        System.assertEquals(false, st.isUnavailable);
    }

    @IsTest
    static void signedSignerWaitingOnAnotherIsSignedButRequestNotComplete() {
        DocGen_Signature_Request__c req = makeRequest('In Progress', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Signed', 1);
        makeSigner(req.Id, TOKEN_B, 'Pending', 2);

        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals(true, st.isSigned);
        System.assertEquals(false, st.requestComplete);
    }

    @IsTest
    static void cancelledRequestMakesAnUnsignedSignerUnavailable() {
        DocGen_Signature_Request__c req = makeRequest('Cancelled', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Pending', 1);

        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals(true, st.isUnavailable);
        System.assertEquals(false, st.isSigned);
    }

    @IsTest
    static void declinedSignerIsUnavailable() {
        DocGen_Signature_Request__c req = makeRequest('Sent', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Declined', 1);

        System.assertEquals(true, DocGenFlowSigningController.getSignerStatus(TOKEN_A).isUnavailable);
    }

    @IsTest
    static void expiredLinkIsFlagged() {
        DocGen_Signature_Request__c req = makeRequest('Sent', Datetime.now().addDays(-1), null);
        makeSigner(req.Id, TOKEN_A, 'Pending', 1);

        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_A);
        System.assertEquals(true, st.isExpired);
        System.assertEquals(false, st.isSigned);
    }

    @IsTest
    static void preparedPdfRequestIsFlagged() {
        DocGen_Signature_Request__c req = makeRequest('Sent', Datetime.now().addDays(2), '068000000000001AAA');
        makeSigner(req.Id, TOKEN_A, 'Pending', 1);

        System.assertEquals(true, DocGenFlowSigningController.getSignerStatus(TOKEN_A).isPreparedPdf);
    }

    @IsTest
    static void statusLookupNeverReturnsAnotherSignersData() {
        DocGen_Signature_Request__c req = makeRequest('In Progress', Datetime.now().addDays(2), null);
        makeSigner(req.Id, TOKEN_A, 'Signed', 1);
        makeSigner(req.Id, TOKEN_B, 'Pending', 2);

        // Token B's holder sees only their own state.
        DocGenFlowSigningController.SignerStatus st = DocGenFlowSigningController.getSignerStatus(TOKEN_B);
        System.assertEquals('Pending', st.signerStatus);
        System.assertEquals(false, st.isSigned);
    }
}

/**
 * Token-keyed, READ-ONLY signer status for the Flow-screen signing component
 * (docGenFlowSigner). Written beside DocGenSignatureController, not into it: that class
 * is shared by every signing path and its guest-context behavior is load-bearing, so the
 * Flow component adds this small additive endpoint instead of touching it.
 *
 * WHAT IT ANSWERS
 * The existing validateToken reports "already signed" only as an error string
 * (isValid=false, errorMessage='You have already signed this document.'). A component
 * cannot reliably branch on message text, so this returns structured fields: is the
 * signer already signed, is the link expired or no longer available, is the whole
 * request complete, and is it a prepared-PDF request (a path the Flow component does not
 * support). The component uses it on load and after a page refresh mid-Flow.
 *
 * SECURITY MODEL
 * Same capability model as DocGenSignatureController (see DocGenSignatureGuestSecurity):
 * the 64-hex per-signer Secure_Token__c is the credential, the lookup is by token
 * equality only, nothing is returned about any other signer, and it never writes.
 *  - without sharing: the caller is a portal user with no sharing on the signer record;
 *    the token, not record sharing, is the access control (as for the VF signing page).
 *  - SYSTEM_MODE query, behind the same guest-aware FLS guards the signing path uses.
 *  - Deliberately NOT cacheable: a status that is stale after signing would let the
 *    Flow advance on a lie (or sit on a signed document).
 *  - Never keyed by a guessable Id.
 */
public without sharing class DocGenFlowSigningController {
    public class SignerStatus {
        /** Signer.Status__c: Pending | Viewed | Signed | Declined | Cancelled (null when unavailable). */
        @AuraEnabled
        public String signerStatus;
        /** Request.Status__c, for diagnostics only; the component keys off the booleans below. */
        @AuraEnabled
        public String requestStatus;
        @AuraEnabled
        public Boolean isSigned = false;
        /** The link is past its expiry. */
        @AuraEnabled
        public Boolean isExpired = false;
        /** No signer for this token, or the request was cancelled/declined/is still a draft. */
        @AuraEnabled
        public Boolean isUnavailable = false;
        /** Every signer on the request has signed. */
        @AuraEnabled
        public Boolean requestComplete = false;
        /** A prepared uploaded-PDF request (sender-placed fields); the Flow component does not support these. */
        @AuraEnabled
        public Boolean isPreparedPdf = false;
        /** The caller's source IP from the platform session, for the certificate line. Null for guests / when unavailable. */
        @AuraEnabled
        public String clientIp;
    }

    @AuraEnabled
    public static SignerStatus getSignerStatus(String token) {
        if (!DocGenSignatureGuestSecurity.isValidTokenShape(token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c', 'Secure_Token__c', 'CreatedDate' }
        );
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Status__c', 'Expires_At__c', 'Original_Document_CV_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signature_Request__c,
                CreatedDate,
                Signature_Request__r.Status__c,
                Signature_Request__r.Expires_At__c,
                Signature_Request__r.Original_Document_CV_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; token-keyed, read-only

        SignerStatus out = new SignerStatus();
        if (signers.isEmpty()) {
            out.isUnavailable = true;
            return out;
        }
        DocGen_Signer__c signer = signers[0];
        String reqStatus = signer.Signature_Request__r.Status__c;
        out.signerStatus = signer.Status__c;
        out.requestStatus = reqStatus;
        out.isSigned = signer.Status__c == 'Signed';
        out.isPreparedPdf = String.isNotBlank(signer.Signature_Request__r.Original_Document_CV_Id__c);
        out.isExpired = DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate);
        // A signed signer stays "signed" even after the request moves to Signed; only
        // an unsigned signer on a cancelled/declined/draft request is unavailable.
        if (!out.isSigned && (reqStatus == 'Cancelled' || reqStatus == 'Declined' || reqStatus == 'Draft')) {
            out.isUnavailable = true;
        }
        if (signer.Status__c == 'Declined' || signer.Status__c == 'Cancelled') {
            out.isUnavailable = true;
        }

        DocGenFlsGuard.guestAssertAccessible(DocGen_Signer__c.sObjectType, new Set<String>{ 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Integer unsignedCount = [
            SELECT COUNT()
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c AND Status__c != 'Signed'
            WITH SYSTEM_MODE
        ]; // NOPMD ApexCRUDViolation - count only, scoped to the token holder's own request
        out.requestComplete = unsignedCount == 0;
        out.clientIp = sessionIp();
        return out;
    }

    /** Source IP from the platform session. Null for guests and whenever the platform will not say. */
    private static String sessionIp() {
        if (Test.isRunningTest() || UserInfo.getUserType() == 'Guest') {
            return null;
        }
        try {
            Map<String, String> session = Auth.SessionManagement.getCurrentSession();
            String ip = session == null ? null : session.get('SourceIp');
            return String.isBlank(ip) ? null : ip;
        } catch (Exception e) {
            return null;
        }
    }
}

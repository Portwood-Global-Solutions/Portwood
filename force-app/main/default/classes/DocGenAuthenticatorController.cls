public without sharing class DocGenAuthenticatorController {
    // SHA-256 hex digest = 64 lowercase/uppercase hex characters.
    // Both capabilities in this class are 64-hex: the document hash (verifyDocument)
    // and the request verification token (verifyByRequestId).
    private static final Pattern SHA256_HEX = Pattern.compile('^[a-fA-F0-9]{64}$');

    /**
     * Verifies a document by its SHA-256 hash.
     */
    @AuraEnabled
    @RemoteAction
    public static List<VerificationResult> verifyDocument(String fileHash) {
        List<VerificationResult> results = new List<VerificationResult>();

        // Strict input validation: must be a 64-char hex string (SHA-256 digest).
        // Reject early with empty list if the input is malformed — never reach SOQL.
        if (String.isBlank(fileHash) || fileHash.length() != 64 || !SHA256_HEX.matcher(fileHash).matches()) {
            return results;
        }

        // Public document verifier — the capability is holding the SHA-256 hash
        // of the signed PDF. Describe check below is the explicit CRUD/FLS
        // enforcement signal documented in DocGenSignatureGuestSecurity.
        DocGenSignatureGuestSecurity.assertAuditReadable();
        // Field allowlist: Signature_Request__c, Signed_Date__c, IP_Address__c,
        // Signer_Name__c, Signer_Email__c, Consent_Captured__c, PIN_Verified_At__c,
        // Document_Hash_SHA256__c, Signer__r.Role_Name__c — only verification-
        // contract fields are returned. SYSTEM_MODE is required because guest
        // profile has no DocGen_Signature_Audit__c CRUD by design; the hash
        // IS the capability.
        //
        // For chained guided signing, earlier signer audits retain the hash of
        // the document as it existed when they signed. First find the request
        // that owns the uploaded hash, then return every signer audit for that
        // request without mutating historical hashes.
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Audit__c.sObjectType,
            new Set<String>{
                'Signed_Date__c',
                'IP_Address__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Consent_Captured__c',
                'PIN_Verified_At__c',
                'Document_Hash_SHA256__c',
                'Signature_Request__c',
                'Signer__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> matchingAudits = [
            SELECT Signature_Request__c
            FROM DocGen_Signature_Audit__c
            WHERE Document_Hash_SHA256__c = :fileHash AND Signer_Name__c != 'SYSTEM'
            WITH SYSTEM_MODE
        ];

        Set<Id> requestIds = new Set<Id>();
        for (DocGen_Signature_Audit__c audit : matchingAudits) {
            if (audit.Signature_Request__c != null) {
                requestIds.add(audit.Signature_Request__c);
            }
        }
        if (requestIds.isEmpty()) {
            return results;
        }

        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> audits = [
            SELECT
                Id,
                Signature_Request__c,
                Signed_Date__c,
                IP_Address__c,
                Signer_Name__c,
                Signer_Email__c,
                Consent_Captured__c,
                PIN_Verified_At__c,
                Document_Hash_SHA256__c,
                Signer__r.Role_Name__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c IN :requestIds AND Signer_Name__c != 'SYSTEM'
            WITH SYSTEM_MODE
            ORDER BY Signed_Date__c ASC
        ];

        for (DocGen_Signature_Audit__c audit : audits) {
            VerificationResult res = new VerificationResult();
            res.isValid = true;
            res.signerName = audit.Signer_Name__c;
            res.signerEmail = audit.Signer_Email__c;
            res.roleName = audit.Signer__r != null ? audit.Signer__r.Role_Name__c : null;
            res.signedDate = audit.Signed_Date__c;
            res.ipAddress = audit.IP_Address__c;
            res.documentHash = audit.Document_Hash_SHA256__c;
            res.consentCaptured = audit.Consent_Captured__c;
            res.pinVerifiedAt = audit.PIN_Verified_At__c;
            res.message = 'Authentic Document Verified';
            results.add(res);
        }
        return results;
    }

    /**
     * Looks up all audit records for a signature request via the request's
     * unguessable Secure_Token__c (the verify link printed on the certificate
     * carries ?token=...). The token IS the capability — possession of the
     * signed document (which displays the link) is what authorizes viewing the
     * audit roster. The previous version keyed on the raw record Id, which is
     * enumerable, allowing anonymous PII harvest; that IDOR is closed here.
     * The method name is retained for managed-package/binary compatibility.
     */
    @AuraEnabled
    @RemoteAction
    public static List<VerificationResult> verifyByRequestId(String requestToken) {
        List<VerificationResult> results = new List<VerificationResult>();

        // SECURITY (hotfix): the capability is now the request's unguessable
        // 64-hex Secure_Token__c, NOT the raw Signature_Request__c Id. Salesforce
        // record Ids are enumerable (fixed key-prefix, appear in URLs, partially
        // sequential), so the previous Id-keyed lookup let any anonymous guest
        // harvest every signer's name/email/IP for a guessed request. The verify
        // link printed on the certificate now carries this token (?token=...).
        // Legacy ?id= links (15/18-char Ids) fail this 64-hex check and return
        // empty — those documents are still verifiable by upload (verifyDocument).
        if (
            String.isBlank(requestToken) ||
            requestToken.length() != 64 ||
            !SHA256_HEX.matcher(requestToken).matches()
        ) {
            return results;
        }

        // Public verifier — capability is holding the request Secure_Token__c.
        // Describe check below is the explicit CRUD/FLS enforcement signal
        // documented in DocGenSignatureGuestSecurity.
        DocGenSignatureGuestSecurity.assertAuditReadable();
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Audit__c.sObjectType,
            new Set<String>{
                'Signed_Date__c',
                'IP_Address__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Consent_Captured__c',
                'PIN_Verified_At__c',
                'Document_Hash_SHA256__c',
                'Signer__c'
            }
        );
        // Field allowlist matches the documented verification contract.
        // SYSTEM_MODE is required for guest-profile access.
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> audits = [
            SELECT
                Id,
                Signed_Date__c,
                IP_Address__c,
                Signer_Name__c,
                Signer_Email__c,
                Consent_Captured__c,
                PIN_Verified_At__c,
                Document_Hash_SHA256__c,
                Signer__r.Role_Name__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__r.Secure_Token__c = :requestToken AND Signer_Name__c != 'SYSTEM'
            WITH SYSTEM_MODE
            ORDER BY Signed_Date__c ASC
        ];

        for (DocGen_Signature_Audit__c audit : audits) {
            VerificationResult res = new VerificationResult();
            res.isValid = true;
            res.signerName = audit.Signer_Name__c;
            res.signerEmail = audit.Signer_Email__c;
            res.roleName = audit.Signer__r.Role_Name__c;
            res.signedDate = audit.Signed_Date__c;
            res.ipAddress = audit.IP_Address__c;
            res.documentHash = audit.Document_Hash_SHA256__c;
            res.consentCaptured = audit.Consent_Captured__c;
            res.pinVerifiedAt = audit.PIN_Verified_At__c;
            res.message = 'Signature verified';
            results.add(res);
        }
        return results;
    }

    public class VerificationResult {
        @AuraEnabled
        public Boolean isValid { get; set; }
        @AuraEnabled
        public String message { get; set; }
        @AuraEnabled
        public String signerName { get; set; }
        @AuraEnabled
        public String signerEmail { get; set; }
        @AuraEnabled
        public String roleName { get; set; }
        @AuraEnabled
        public Datetime signedDate { get; set; }
        @AuraEnabled
        public String ipAddress { get; set; }
        @AuraEnabled
        public String documentHash { get; set; }
        @AuraEnabled
        public Boolean consentCaptured { get; set; }
        @AuraEnabled
        public Datetime pinVerifiedAt { get; set; }
    }
}

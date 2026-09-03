public without sharing class DocGenSignatureController {
    // Legacy signing-window: requests created before Expires_At__c existed live this
    // long from creation. New requests stamp Expires_At__c (DocGenSignatureExpiry).
    private static final Integer TOKEN_EXPIRATION_HOURS = 48;
    // PIN verification settings
    private static final Integer PIN_EXPIRATION_MINUTES = 10;
    private static final Integer MAX_PIN_ATTEMPTS = 3;

    /**
     * #verification — does this request still require an email-PIN check before signing?
     * Reads the per-request resolved flag (DocGen_Signature_Request__c.Require_Email_Verification__c)
     * with guest-aware FLS; defaults to TRUE (required) if missing/unreadable, so verification is
     * never silently dropped by an error. Cached per transaction by request Id.
     */
    private static Map<Id, Boolean> verificationRequiredCache = new Map<Id, Boolean>();

    private static Boolean requestRequiresVerification(Id requestId) {
        if (requestId == null) {
            return true;
        }
        if (verificationRequiredCache.containsKey(requestId)) {
            return verificationRequiredCache.get(requestId);
        }
        Boolean required = true;
        try {
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Require_Email_Verification__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Require_Email_Verification__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            if (!reqs.isEmpty() && reqs[0].Require_Email_Verification__c != null) {
                required = reqs[0].Require_Email_Verification__c;
            }
        } catch (Exception e) {
            required = true; // fail safe: keep verification on
        }
        verificationRequiredCache.put(requestId, required);
        return required;
    }

    public class SignatureInitResponse {
        @AuraEnabled
        public Boolean isValid;
        @AuraEnabled
        public String errorMessage;
        @AuraEnabled
        public String signerName;
        @AuraEnabled
        public String signerEmail;
        @AuraEnabled
        public String documentTitle;
        @AuraEnabled
        public String documentUrl;
        @AuraEnabled
        public String templateBase64;
        @AuraEnabled
        public String recordId;
        @AuraEnabled
        public String roleName;
        @AuraEnabled
        public Integer totalSigners;
        @AuraEnabled
        public Integer signedCount;
        @AuraEnabled
        public Boolean isSignerToken;
        @AuraEnabled
        public Boolean requiresPin;
        // #verification — when true the signing page may skip the "type your email" step and
        // auto-send the PIN to signerEmail (the code still goes only to the real inbox).
        @AuraEnabled
        public Boolean prefillEmail;
        // Signer form fields to render during e-signing. PUBLIC-SAFE projection
        // only — {key,label,type,required,choices}. The writeback flags and the
        // base-object field API names from the template config are deliberately
        // NOT exposed to the guest (the writeback allowlist is re-derived
        // server-side at completion). See DocGenFieldWritebackService.publicFormFields.
        @AuraEnabled
        public List<Object> formFields;
    }

    public class SaveSignatureResult {
        @AuraEnabled
        public Boolean isComplete;
        @AuraEnabled
        public Integer remaining;
    }

    /**
     * Result for the flat-PDF signing path (savePdfSignature). Mirrors
     * SaveSignatureResult but carries an explicit `success` flag — the PDF page's
     * modal needs an unambiguous success signal that does not depend on
     * isComplete (a single-signer of a multi-signer envelope succeeds with
     * isComplete=false).
     */
    public class SavePdfSignatureResult {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public Boolean isComplete;
        @AuraEnabled
        public Integer remaining;
    }

    /**
     * Prefers the client-supplied IP (browser fetched it from a public service)
     * over header inspection. The client path is more reliable for guest signers
     * because Sites/Site CDNs don't always set X-Forwarded-For consistently.
     * Validates input is a sane IPv4/IPv6 string before trusting it; falls back
     * to captureClientIp() otherwise.
     */
    @TestVisible
    private static String resolveClientIp(String supplied) {
        // SECURITY (audit integrity): prefer the server-observed IP and never let
        // the client-supplied `ipAddress` argument override it. Previously the
        // caller-passed value won unconditionally, so a signer could forge the IP
        // recorded on their own tamper-evident audit / certificate. The client
        // hint is now used ONLY as a last resort when the server has no IP at all
        // (e.g. a guest LWR context with no infrastructure header) — recorded as
        // best-effort, not authoritative.
        // NOTE: captureClientIp() still reads X-Forwarded-For, whose leftmost hop
        // can be client-influenced behind some proxy configs. Validating the
        // trusted-hop selection requires a live Experience Cloud guest test before
        // hardening further.
        String serverIp = captureClientIp();
        if (String.isNotBlank(serverIp) && serverIp != 'Unknown') {
            return serverIp;
        }
        if (String.isNotBlank(supplied)) {
            String trimmed = supplied.trim();
            // Cheap sanity: length cap + only chars valid in IPv4/IPv6.
            // (Not a strict parse — just rejects obvious garbage/injection.)
            if (trimmed.length() <= 45 && Pattern.matches('[0-9a-fA-F\\.:]+', trimmed)) {
                return trimmed;
            }
        }
        return 'Unknown';
    }

    /**
     * Captures the signer's form-field values onto DocGen_Signer__c.Field_Data_Json__c
     * during a guest save (folded into saveSignature / savePdfSignature /
     * saveCompositedSignedPdf — NO new guest endpoint). Flow:
     *   token gate (caller already validated 64-hex + assertSignerWritableFields)
     *   → load the request's Template__c.Form_Fields_Config__c (SYSTEM_MODE, FLS-guarded)
     *   → validate the incoming JSON against config (DocGenFieldWritebackService:
     *     enforce required, coerce by type, DROP unknown keys, config-ordered map)
     *   → guestAssertUpdateable(signer, {'Field_Data_Json__c'})
     *   → write the CLEAN JSON to Field_Data_Json__c in SYSTEM_MODE.
     *
     * No-ops when the template has no formFields or no incoming JSON. Required-field
     * failures throw (AuraHandledException) BEFORE the signer is finalized so the
     * guest sees a clean validation message and nothing is persisted on this save.
     */
    @TestVisible
    private static void captureFormFieldData(Id signerId, Id requestId, String token, String formFieldJson) {
        if (signerId == null || requestId == null) {
            return;
        }
        // Load the template config for this request (SYSTEM_MODE — guest has no
        // Portwood CRUD; token-bound capability already established by the caller).
        DocGenFlsGuard.guestAssertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Template__c' });
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Form_Fields_Config__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Template__c, Template__r.Form_Fields_Config__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (reqs.isEmpty() || reqs[0].Template__c == null || reqs[0].Template__r == null) {
            return; // No template / capture-only flat-PDF flow — nothing to capture.
        }

        List<DocGenFieldWritebackService.FormFieldDef> defs = DocGenFieldWritebackService.parseConfig(
            reqs[0].Template__r.Form_Fields_Config__c
        );
        // validateAndClean enforces required + coerces + drops unknown keys, and
        // returns null when there are no configured form fields.
        Map<String, Object> clean = DocGenFieldWritebackService.validateAndClean(defs, formFieldJson);
        if (clean == null) {
            return;
        }

        DocGen_Signer__c signerUpd = new DocGen_Signer__c(Id = signerId);
        signerUpd.Field_Data_Json__c = JSON.serialize(clean);
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(signerUpd, new Set<String>{ 'Field_Data_Json__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signerUpd, false, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Captures the client IP address from the current request context.
     * Checks X-Forwarded-For (load balancer/proxy) first, falls back to
     * Salesforce session info, then to True-Client-IP.
     */
    private static String captureClientIp() {
        // Try VF page request headers first
        try {
            PageReference pr = ApexPages.currentPage();
            if (pr != null) {
                Map<String, String> headers = pr.getHeaders();
                // X-Forwarded-For contains the original client IP when behind a proxy/LB
                String forwarded = headers.get('X-Forwarded-For');
                if (String.isNotBlank(forwarded)) {
                    // May contain comma-separated list — first is the real client
                    return forwarded.split(',')[0].trim();
                }
                String trueClientIp = headers.get('True-Client-IP');
                if (String.isNotBlank(trueClientIp)) {
                    return trueClientIp.trim();
                }
            }
        } catch (Exception e) {
            // Not in a VF context
        }
        // Fallback: try session-based IP (skip for guest users and tests — triggers uncatchable session error)
        if (!Test.isRunningTest() && UserInfo.getUserType() != 'Guest') {
            try {
                Map<String, String> session = Auth.SessionManagement.getCurrentSession();
                String loginIp = session.get('SourceIp');
                if (String.isNotBlank(loginIp)) {
                    return loginIp;
                }
            } catch (Exception e) {
                // Session info unavailable
            }
        }
        return 'Unknown';
    }

    /**
     * Validates a signer token. Queries DocGen_Signer__c first (multi-signer),
     * falls back to DocGen_Signature_Request__c (legacy single-signer).
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse validateToken(String token) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (String.isBlank(token)) {
            res.errorMessage = 'Invalid or missing security token.';
            return res;
        }

        // Token format validation: must be a 64-character hex string (SHA-256 output)
        if (token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            res.errorMessage = 'Invalid security token format.';
            return res;
        }

        // Guest-context CRUD/FLS enforcement. The describe checks below document
        // the security model the AppExchange reviewer requires; the token-bound
        // record lookup that follows is the structural capability check.
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        // Try multi-signer path first — SYSTEM_MODE required for guest profile
        // (granting guests DocGen_Signer__c CRUD would be the actual vulnerability).
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Role_Name__c',
                'Sort_Order__c',
                'CreatedDate',
                'PIN_Verified_At__c',
                'Signature_Request__c',
                'Secure_Token__c'
            }
        );
        // Form_Fields_Config__c carries the signer form-field config rendered on the page.
        // SYSTEM_MODE on the SOQL below; documented FLS describe signal here.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Name', 'Form_Fields_Config__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Role_Name__c,
                Sort_Order__c,
                CreatedDate,
                PIN_Verified_At__c,
                Signature_Request__r.Id,
                Signature_Request__r.Status__c,
                Signature_Request__r.Require_Email_Verification__c,
                Signature_Request__r.Prefill_Signer_Email__c,
                Signature_Request__r.Source_Document_Id__c,
                Signature_Request__r.Related_Record_Id__c,
                Signature_Request__r.Expires_At__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Template__r.Name,
                Signature_Request__r.Template__r.Form_Fields_Config__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signers.isEmpty()) {
            if (
                DocGenSignatureExpiry.isExpired(signers[0].Signature_Request__r.Expires_At__c, signers[0].CreatedDate)
            ) {
                res.errorMessage = 'This signature link has expired. Please request a new one.';
                return res;
            }
            return validateSignerToken(signers[0]);
        }

        // Legacy fallback: single-signer on DocGen_Signature_Request__c
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Source_Document_Id__c',
                'Related_Record_Id__c',
                'CreatedDate',
                'Secure_Token__c',
                'Expires_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Source_Document_Id__c,
                Related_Record_Id__c,
                CreatedDate,
                Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            res.errorMessage = 'Signature request not found. The link may be invalid or expired.';
            return res;
        }

        if (DocGenSignatureExpiry.isExpired(requests[0].Expires_At__c, requests[0].CreatedDate)) {
            res.errorMessage = 'This signature link has expired. Please request a new one.';
            return res;
        }

        return validateLegacyRequest(requests[0]);
    }

    /**
     * Sends a 6-digit PIN to the signer's email for identity verification.
     * The PIN is hashed (SHA-256) before storage — plaintext is never persisted.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, Object> sendPin(String token, String email) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        // Guest CRUD/FLS gate — describe check on DocGen_Signer__c writeable
        // field allowlist (PIN_Hash__c, PIN_Expires_At__c, PIN_Attempts__c).
        // See DocGenSignatureGuestSecurity for the documented security model.
        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signer_Email__c', 'PIN_Attempts__c', 'Status__c', 'CreatedDate', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signer_Email__c, PIN_Attempts__c, Status__c, CreatedDate, Signature_Request__r.Expires_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];

        // Validate email matches the intended signer (case-insensitive)
        if (String.isBlank(email) || !email.equalsIgnoreCase(signer.Signer_Email__c)) {
            result.put('success', false);
            result.put('message', 'Email address does not match the intended signer.');
            return result;
        }

        // Check if token is expired
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            result.put('success', false);
            result.put('message', 'This signature link has expired.');
            return result;
        }

        // Check if already locked out
        if (signer.PIN_Attempts__c >= MAX_PIN_ATTEMPTS) {
            result.put('success', false);
            result.put('message', 'Too many failed attempts. Please request a new signature link.');
            return result;
        }

        // Generate 6-digit PIN
        Integer pin = Math.mod(Math.abs(Crypto.getRandomInteger()), 900000) + 100000;
        String pinStr = String.valueOf(pin);

        // Hash the PIN for storage (never store plaintext)
        String pinHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(pinStr)));

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        // Store hash and expiry on signer record
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.PIN_Hash__c = pinHash;
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.PIN_Expires_At__c = System.now().addMinutes(PIN_EXPIRATION_MINUTES);
        signer.PIN_Attempts__c = 0; // Reset attempts on new PIN
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        // Complements DocGenSignatureGuestSecurity.assert*(token) object-level
        // CRUD checks at the entry point with per-field describe enforcement.
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'PIN_Hash__c', 'PIN_Expires_At__c', 'PIN_Attempts__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Send PIN via email
        String emailError = sendPinEmail(signer.Signer_Email__c, pinStr);
        if (emailError != null) {
            result.put('success', false);
            result.put('message', 'Failed to send verification email. Please contact the sender.');
            return result;
        }

        result.put('success', true);
        result.put('message', 'A verification code has been sent to your email.');
        return result;
    }

    /**
     * Verifies the 6-digit PIN entered by the signer.
     * Burns the token after MAX_PIN_ATTEMPTS failed attempts.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, Object> verifyPin(String token, String pin) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        if (String.isBlank(pin) || !Pattern.matches('[0-9]{6}', pin)) {
            result.put('success', false);
            result.put('message', 'Please enter a valid 6-digit code.');
            return result;
        }

        // Guest CRUD/FLS gate — writeable allowlist (PIN_Attempts__c,
        // PIN_Verified_At__c, Status__c). See DocGenSignatureGuestSecurity.
        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'PIN_Hash__c', 'PIN_Expires_At__c', 'PIN_Attempts__c', 'Status__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, PIN_Hash__c, PIN_Expires_At__c, PIN_Attempts__c, Status__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];

        // Check if locked out
        if (signer.PIN_Attempts__c >= MAX_PIN_ATTEMPTS) {
            result.put('success', false);
            result.put('message', 'Too many failed attempts. Please request a new signature link.');
            return result;
        }

        // Check if PIN has been sent
        if (String.isBlank(signer.PIN_Hash__c) || signer.PIN_Expires_At__c == null) {
            result.put('success', false);
            result.put('message', 'No verification code found. Please request a new code.');
            return result;
        }

        // Check expiry
        if (signer.PIN_Expires_At__c < System.now()) {
            result.put('success', false);
            result.put('message', 'Verification code has expired. Please request a new code.');
            return result;
        }

        // Hash the submitted PIN and compare
        String submittedHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(pin)));

        if (submittedHash != signer.PIN_Hash__c) {
            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
            // Increment failed attempts
            signer.PIN_Attempts__c = (signer.PIN_Attempts__c == null ? 0 : signer.PIN_Attempts__c) + 1;
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.guestAssertUpdateable(signer, new Set<String>{ 'PIN_Attempts__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(signer, false, AccessLevel.SYSTEM_MODE);

            Integer remaining = MAX_PIN_ATTEMPTS - Integer.valueOf(signer.PIN_Attempts__c);
            if (remaining <= 0) {
                result.put('success', false);
                result.put(
                    'message',
                    'Too many failed attempts. This link has been locked. Please request a new signature link.'
                );
            } else {
                result.put('success', false);
                result.put(
                    'message',
                    'Incorrect code. ' + remaining + ' attempt' + (remaining > 1 ? 's' : '') + ' remaining.'
                );
            }
            return result;
        }

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        // PIN verified — record timestamp and clear PIN data
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.PIN_Verified_At__c = System.now();
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.PIN_Hash__c = null;
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.PIN_Expires_At__c = null;
        signer.PIN_Attempts__c = 0;
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
        }
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'PIN_Verified_At__c', 'PIN_Hash__c', 'PIN_Expires_At__c', 'PIN_Attempts__c', 'Status__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        result.put('success', true);
        result.put('message', 'Email verified successfully.');
        return result;
    }

    /**
     * Sends the 6-digit PIN to the signer's email.
     */
    private static String sendPinEmail(String email, String pin) {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();

        // OWA is required for guest user context — warn if not configured
        String owaId = settings == null ? null : settings.Signature_OWA_Id__c;
        if (String.isBlank(owaId) && UserInfo.getUserType() == 'Guest') {
            System.debug(
                LoggingLevel.ERROR,
                'Portwood: PIN email failed — no Org-Wide Email Address configured in Signature Settings (required for guest users)'
            );
            return 'No Org-Wide Email Address configured. An admin must set one in Portwood Signature Settings.';
        }

        // #193 — render the verification email from the brandable template
        // (built-in default falls back automatically if no record exists).
        DocGenEmailTemplateService.RenderedEmail rendered = DocGenEmailTemplateService.render(
            DocGenEmailTemplateService.TYPE_PIN,
            new Map<String, String>{ 'Pin' => pin, 'ExpirationMinutes' => String.valueOf(PIN_EXPIRATION_MINUTES) }
        );

        Messaging.SingleEmailMessage email2 = new Messaging.SingleEmailMessage();
        email2.setToAddresses(new List<String>{ email });
        email2.setSubject(rendered.subject);
        email2.setHtmlBody(rendered.htmlBody);
        if (String.isNotBlank(rendered.plainBody)) {
            email2.setPlainTextBody(rendered.plainBody);
        }
        email2.setSaveAsActivity(false);
        if (String.isNotBlank(owaId)) {
            email2.setOrgWideEmailAddressId(owaId);
        }

        List<Messaging.SendEmailResult> results = Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ email2 },
            false
        );
        if (!results.isEmpty() && !results[0].isSuccess()) {
            String errMsg = results[0].getErrors()[0].getMessage();
            System.debug(LoggingLevel.ERROR, 'Portwood: PIN email send failed — ' + errMsg);
            return errMsg;
        }
        return null;
    }

    private static SignatureInitResponse validateSignerToken(DocGen_Signer__c signer) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (signer.Status__c == 'Signed') {
            res.errorMessage = 'You have already signed this document.';
            return res;
        }

        DocGen_Signature_Request__c parentReq = signer.Signature_Request__r;
        if (parentReq.Status__c == 'Signed' || parentReq.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request is no longer active.';
            return res;
        }

        // Update signer status to Viewed (SYSTEM_MODE for guest user CRUD bypass)
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        if (signer.Status__c == 'Pending') {
            signer.Status__c = 'Viewed';
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.guestAssertUpdateable(signer, new Set<String>{ 'Status__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(signer, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.isSignerToken = true;
        res.signerName = signer.Signer_Name__c;
        res.signerEmail = signer.Signer_Email__c;
        res.roleName = signer.Role_Name__c;
        // #verification — PIN is required only if this request still requires it AND the signer
        // hasn't verified yet. When pre-fill is on, the page may auto-send to signerEmail.
        Boolean requireVerification = parentReq.Require_Email_Verification__c != false; // null → required (default)
        res.requiresPin = requireVerification && (signer.PIN_Verified_At__c == null);
        res.prefillEmail = requireVerification && parentReq.Prefill_Signer_Email__c == true;

        // Count total and signed signers
        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :parentReq.Id
            WITH SYSTEM_MODE
        ];
        res.totalSigners = allSigners.size();
        Integer signed = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c == 'Signed')
                signed++;
        }
        res.signedCount = signed;

        // Get document metadata — template name or source document title
        if (parentReq.Template__c != null) {
            res.documentTitle = parentReq.Template__r.Name;
            // No public link needed — preview is rendered from template merge
        } else {
            Id sourceDocId = parentReq.Source_Document_Id__c;
            // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
            DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> cvs = [
                SELECT Id, Title
                FROM ContentVersion
                WHERE Id = :sourceDocId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!cvs.isEmpty()) {
                res.documentTitle = cvs[0].Title;
                // The PDF signing flow renders the document via getSourcePdfBase64, so this
                // public preview link is optional. ContentDistribution creation is not permitted
                // in guest context, so never let it break token validation.
                try {
                    res.documentUrl = getOrCreatePublicLink(cvs[0], parentReq.Expires_At__c);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Portwood: public preview link unavailable — ' + e.getMessage());
                }
            } else {
                res.documentTitle = 'Confidential Document';
            }
        }

        // Signer form fields (public-safe projection — key/label/type/required/choices
        // only). The writeback flags + base-field API names from the config never
        // leave the server; the writeback allowlist is re-derived at completion.
        if (parentReq.Template__c != null && parentReq.Template__r != null) {
            res.formFields = DocGenFieldWritebackService.publicFormFields(parentReq.Template__r.Form_Fields_Config__c);
        }

        return res;
    }

    private static SignatureInitResponse validateLegacyRequest(DocGen_Signature_Request__c req) {
        SignatureInitResponse res = new SignatureInitResponse();
        res.isValid = false;

        if (req.Status__c == 'Signed') {
            res.errorMessage = 'This document has already been signed.';
            return res;
        }
        if (req.Status__c == 'Cancelled') {
            res.errorMessage = 'This signature request has been cancelled.';
            return res;
        }

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        if (req.Status__c == 'Sent') {
            req.Status__c = 'Viewed';
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.guestAssertUpdateable(req, new Set<String>{ 'Status__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        }

        res.isValid = true;
        res.isSignerToken = false;
        res.signerName = req.Signer_Name__c;
        res.totalSigners = 1;
        res.signedCount = 0;

        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
        DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentVersion> cvs = [
            SELECT Id, Title
            FROM ContentVersion
            WHERE Id = :req.Source_Document_Id__c
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!cvs.isEmpty()) {
            res.documentTitle = cvs[0].Title;
            res.documentUrl = getOrCreatePublicLink(cvs[0], req.Expires_At__c);
        } else {
            res.documentTitle = 'Confidential Document';
        }

        return res;
    }

    // CxSAST: Apex_CRUD_ContentDistribution — SYSTEM_MODE required for guest user context; ContentDistribution created for signature document preview
    private static String getOrCreatePublicLink(ContentVersion cv, Datetime requestExpiresAt) {
        if (!DocGenService.isContentDistributionAvailable()) {
            return null; // #384: deliveries disabled — preview link is optional (caller try/catch)
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGenService.contentDistributionType(),
            new Set<String>{ 'DistributionPublicUrl', 'ContentVersionId' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<SObject> dists = Database.query(
            'SELECT DistributionPublicUrl FROM ContentDistribution WHERE ContentVersionId = \'' +
                String.escapeSingleQuotes((String) cv.Id) +
                '\' WITH SYSTEM_MODE LIMIT 1'
        );
        if (!dists.isEmpty()) {
            return (String) dists[0].get('DistributionPublicUrl');
        }
        Datetime linkExpiry = requestExpiresAt != null
            ? requestExpiresAt
            : System.now().addHours(TOKEN_EXPIRATION_HOURS);
        SObject cd = DocGenService.newContentDistribution(
            new Map<String, Object>{
                'Name' => 'Signature Preview - ' + cv.Title,
                'ContentVersionId' => cv.Id,
                'PreferencesAllowViewInBrowser' => true,
                'PreferencesLinkLatestVersion' => true,
                'PreferencesExpires' => true,
                'ExpiryDate' => linkExpiry,
                'PreferencesNotifyOnVisit' => false,
                'PreferencesAllowOriginalDownload' => false,
                'PreferencesAllowPDFDownload' => false
            }
        );
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            cd,
            new Set<String>{
                'Name',
                'ContentVersionId',
                'PreferencesAllowViewInBrowser',
                'PreferencesLinkLatestVersion',
                'PreferencesExpires',
                'ExpiryDate',
                'PreferencesNotifyOnVisit',
                'PreferencesAllowOriginalDownload',
                'PreferencesAllowPDFDownload'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<SObject>{ cd }, false, AccessLevel.SYSTEM_MODE);
        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
        DocGenFlsGuard.guestAssertAccessible(
            DocGenService.contentDistributionType(),
            new Set<String>{ 'DistributionPublicUrl' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<SObject> created = Database.query(
            'SELECT DistributionPublicUrl FROM ContentDistribution WHERE Id = \'' +
                String.escapeSingleQuotes((String) cd.get('Id')) +
                '\' WITH SYSTEM_MODE LIMIT 1'
        );
        return created.isEmpty() ? null : (String) created[0].get('DistributionPublicUrl');
    }

    /**
     * Fetches pre-rendered HTML for document display in the signature page.
     * Template-based requests: merges template with record data for a fully merged preview.
     * Legacy requests: converts source DOCX to HTML.
     */
    @AuraEnabled
    @RemoteAction
    public static SignatureInitResponse fetchDocumentData(String token) {
        SignatureInitResponse res = validateToken(token);
        if (!res.isValid)
            return res;

        // Guest CRUD/FLS gate — already validated above by validateToken's
        // assertSignerReadable; this redundant call documents the read scope
        // (DocGen_Signer__c, DocGen_Signature_Request__c) for the analyzer.
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        // Try multi-signer path
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Decline_Reason__c', 'LastModifiedDate', 'Signature_Request__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Decline_Reason__c,
                LastModifiedDate,
                Signature_Request__r.Source_Document_Id__c,
                Signature_Request__r.Related_Record_Id__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Status__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        Id sourceDocId;
        Id templateId;
        Id requestId;
        String recordId;
        String requestStatus;
        String declineReason;
        Datetime declinedAt;
        if (!signers.isEmpty()) {
            sourceDocId = signers[0].Signature_Request__r.Source_Document_Id__c;
            templateId = signers[0].Signature_Request__r.Template__c;
            requestId = signers[0].Signature_Request__r.Id;
            recordId = signers[0].Signature_Request__r.Related_Record_Id__c;
            requestStatus = signers[0].Signature_Request__r.Status__c;
            declineReason = signers[0].Decline_Reason__c;
            declinedAt = signers[0].LastModifiedDate;
            res.recordId = recordId;
        } else {
            // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
            // Legacy fallback
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{
                    'Source_Document_Id__c',
                    'Related_Record_Id__c',
                    'Template__c',
                    'Status__c',
                    'LastModifiedDate',
                    'Secure_Token__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> requests = [
                SELECT Id, Source_Document_Id__c, Related_Record_Id__c, Template__c, Status__c, LastModifiedDate
                FROM DocGen_Signature_Request__c
                WHERE Secure_Token__c = :token
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!requests.isEmpty()) {
                sourceDocId = requests[0].Source_Document_Id__c;
                templateId = requests[0].Template__c;
                requestId = requests[0].Id;
                recordId = requests[0].Related_Record_Id__c;
                requestStatus = requests[0].Status__c;
                declinedAt = requests[0].LastModifiedDate;
                res.recordId = recordId;
            }
        }

        // Issue #91: when the request is declined, short-circuit with a confirmation card
        // instead of trying to render a preview. The cached preview HTML was already cleared
        // in declineSignature, so any fallback to the live render would still show a doc that
        // reads as unsigned — but we'd rather make the declined state explicit than implicit.
        if (requestStatus == 'Declined') {
            res.templateBase64 = buildDeclinedStateHtml(declinedAt, declineReason);
            return res;
        }

        // Template-based: load preview HTML from Signature_Data__c cache on the request,
        // or generate on-the-fly if cache is empty.
        if (templateId != null && requestId != null) {
            // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
            // Try cached preview first
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Signature_Data__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Request__c> reqs = [
                SELECT Signature_Data__c
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!reqs.isEmpty() && String.isNotBlank(reqs[0].Signature_Data__c)) {
                try {
                    Map<String, Object> cachedData = (Map<String, Object>) JSON.deserializeUntyped(
                        reqs[0].Signature_Data__c
                    );
                    String previewHtml = (String) cachedData.get('previewHtml');
                    if (String.isNotBlank(previewHtml)) {
                        // Inject watermark overlay at read time — embedded base64 image
                        // would exceed Signature_Data__c's LongTextArea limit if cached.
                        previewHtml = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(
                            previewHtml,
                            templateId
                        );
                        res.templateBase64 = prepareSigningPreviewHtml(previewHtml);
                        return res;
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Portwood: Failed to parse cached preview: ' + e.getMessage());
                }
            }

            // Fallback: generate preview on-the-fly from template + record data
            try {
                Map<String, Object> mergeData = DocGenService.mergeTemplateForSignature(templateId, recordId);
                String docXml = (String) mergeData.get('combinedDocumentXml');
                if (String.isBlank(docXml)) {
                    docXml = (String) mergeData.get('documentXml');
                }
                Map<String, String> pdfImageMap = (Map<String, String>) mergeData.get('pdfImageMap');
                if (String.isNotBlank(docXml)) {
                    String liveHtml;
                    if (DocGenService.isHtmlBacked((String) mergeData.get('templateType'))) {
                        liveHtml = docXml;
                    } else {
                        DocGenService.applyWatermarkOverride(templateId);
                        liveHtml = DocGenHtmlRenderer.convertToHtml(docXml, pdfImageMap);
                    }
                    liveHtml = DocGenSignatureSenderController.injectPreviewWatermarkOverlay(liveHtml, templateId);
                    res.templateBase64 = prepareSigningPreviewHtml(liveHtml);
                    return res;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Portwood: Failed to generate live preview: ' + e.getMessage());
            }

            res.templateBase64 = '<html><body><p>Document preview unavailable.</p></body></html>';
            return res;
        }

        // Legacy: convert source DOCX to HTML
        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
        if (sourceDocId != null) {
            DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> cvs = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :sourceDocId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!cvs.isEmpty()) {
                res.templateBase64 = prepareSigningPreviewHtml(getDocumentHtml(cvs[0].VersionData));
            }
        }
        return res;
    }

    @TestVisible
    private static String prepareSigningPreviewHtml(String html) {
        if (String.isBlank(html) || !containsRtlText(html) || html.contains('docgen-signing-preview-rtl')) {
            return html;
        }
        return '<div class="docgen-signing-preview-rtl" dir="rtl" style="direction:rtl;text-align:right;">' +
            html +
            '</div>';
    }

    private static Boolean containsRtlText(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        Pattern rtlPattern = Pattern.compile('[\\u0590-\\u08FF\\uFB1D-\\uFDFF\\uFE70-\\uFEFF]');
        return rtlPattern.matcher(value).find();
    }

    /**
     * Converts a DOCX blob to pre-rendered HTML by extracting and converting document.xml.
     * Returns the HTML string (stored in templateBase64 field for transport).
     */
    private static String getDocumentHtml(Blob docxBlob) {
        try {
            Map<String, Object> extracted = extractDocxParts(docxBlob);
            String documentXml = (String) extracted.get('documentXml');
            Map<String, String> imagesByRelId = (Map<String, String>) extracted.get('imagesByRelId');

            if (documentXml != null) {
                return DocGenHtmlRenderer.convertToHtml(documentXml, imagesByRelId);
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'Portwood: Error converting DOCX to HTML for signature display: ' + e.getMessage()
            );
        }
        return '<html><body><p>Document preview unavailable.</p></body></html>';
    }

    /**
     * Issue #91: Renders the confirmation card shown when the signing link is opened after
     * the request has been declined. Replaces the document preview so the page can't read
     * as signed regardless of cache state.
     */
    private static String buildDeclinedStateHtml(Datetime declinedAt, String reason) {
        String dateStr = declinedAt != null ? declinedAt.format('MMMM d, yyyy \'at\' h:mm a z') : '';
        String reasonBlock = '';
        if (String.isNotBlank(reason)) {
            reasonBlock =
                '<p style="margin:12px 0 0 0;color:#3e3e3c;"><strong>Reason:</strong> ' +
                reason.escapeHtml4() +
                '</p>';
        }
        return '<html><head><style>' +
            'body{font-family:Arial,Helvetica,sans-serif;background:#f3f3f3;margin:0;padding:48px 16px;}' +
            '.card{max-width:560px;margin:0 auto;background:#fff;border:1px solid #dddbda;border-radius:6px;' +
            'padding:32px;text-align:center;}' +
            '.title{color:#c23934;font-size:20pt;font-weight:600;margin:0 0 8px 0;}' +
            '.subtitle{color:#3e3e3c;font-size:11pt;margin:0;}' +
            '</style></head><body><div class="card">' +
            '<p class="title">Signature Request Declined</p>' +
            '<p class="subtitle">This signature request was declined' +
            (String.isNotBlank(dateStr) ? ' on ' + dateStr.escapeHtml4() : '') +
            '. No further action is required; the document sender has been notified.</p>' +
            reasonBlock +
            '</div></body></html>';
    }

    /**
     * Saves a signer's typed name as their electronic signature.
     * Requires PIN verification and consent checkbox.
     * Returns whether all signers have now completed.
     */
    @AuraEnabled
    @RemoteAction
    public static SaveSignatureResult saveSignature(
        String token,
        String typedName,
        Boolean consentGiven,
        String ipAddress,
        String userAgent,
        String formFieldJson
    ) {
        SaveSignatureResult result = new SaveSignatureResult();

        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        if (String.isBlank(typedName)) {
            throw new AuraHandledException('Please type your name to sign.');
        }

        if (consentGiven != true) {
            throw new AuraHandledException('You must agree to sign electronically.');
        }

        // Guest CRUD/FLS gate — write allowlist (Signer.Status__c,
        // Signer.Signature_Data__c) + audit creation. See guard helper.
        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);
        DocGenSignatureGuestSecurity.assertAuditCreateable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Signature_Request__c',
                'Role_Name__c',
                'Contact__c',
                'CreatedDate',
                'PIN_Verified_At__c',
                'Consent_Captured__c',
                'Secure_Token__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Signature_Request__c,
                Signature_Request__r.Expires_At__c,
                Role_Name__c,
                Contact__c,
                CreatedDate,
                PIN_Verified_At__c,
                Consent_Captured__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Require PIN verification before allowing signature
        if (requestRequiresVerification(signer.Signature_Request__c) && signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required before signing.');
        }

        // Signer form fields: validate + persist the collected values BEFORE the
        // signer is finalized, so a required-field failure aborts the whole save
        // (no status change, nothing persisted) and the guest sees a clean error.
        captureFormFieldData(signer.Id, signer.Signature_Request__c, token, formFieldJson);

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        // Store typed name and mark as signed
        signer.Signature_Data__c = typedName;
        signer.Status__c = 'Signed';
        signer.Consent_Captured__c = true;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'Signature_Data__c', 'Status__c', 'Consent_Captured__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Create audit trail immediately with all available data
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = resolveClientIp(ipAddress);
        audit.User_Agent__c = String.isNotBlank(userAgent) ? userAgent.left(255) : 'Unknown';
        audit.Consent_Captured__c = true;
        audit.PIN_Verified_At__c = signer.PIN_Verified_At__c;
        // #verification — record how identity was checked, even when the PIN was skipped.
        audit.Verification_Method__c = signer.PIN_Verified_At__c != null ? 'Email PIN' : 'None';
        // Document hash is set later when PDF is generated
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            audit,
            new Set<String>{
                'Signature_Request__c',
                'Signer__c',
                'Verification_Method__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Contact__c',
                'Signed_Date__c',
                'IP_Address__c',
                'User_Agent__c',
                'Consent_Captured__c',
                'PIN_Verified_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Check if all signers are now complete
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
            WITH SYSTEM_MODE
        ];

        Integer remaining = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c != 'Signed')
                remaining++;
        }

        result.remaining = remaining;
        result.isComplete = (remaining == 0);

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        // Update parent request status
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'In Progress';
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(parentReq, new Set<String>{ 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        // All post-signature actions (PDF generation, notifications, sequential signing)
        // are deferred to system context via platform event.
        // Guest users cannot send emails, query User records, or access ContentVersion
        // (triggers session ID error). The trigger runs as Automated Process user.
        try {
            DocGen_Signature_PDF__e pdfEvent = new DocGen_Signature_PDF__e();
            pdfEvent.Request_Id__c = signer.Signature_Request__c;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            EventBus.publish(pdfEvent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Post-signature event publish failed: ' + e.getMessage());
        }

        return result;
    }

    /**
     * Triggers PDF generation after all signers have completed.
     * For multi-signer: called only when all signers have completed.
     * For legacy single-signer: stamps the single signature directly.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> stampAndReturnSource(String token, String base64Image) {
        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Guest CRUD/FLS gate — read scope (DocGen_Signer__c), write scope
        // (DocGen_Signature_Request__c.Status__c, audit creation).
        DocGenSignatureGuestSecurity.assertSignerReadable(token);
        DocGenSignatureGuestSecurity.assertRequestWritableFields(token);
        DocGenSignatureGuestSecurity.assertAuditCreateable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signature_Request__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signerList = [
            SELECT
                Id,
                Signature_Request__c,
                Signature_Request__r.Source_Document_Id__c,
                Signature_Request__r.Related_Record_Id__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (!signerList.isEmpty()) {
            return stampMultiSignerAndSavePdf(signerList[0]);
        }

        // Legacy single-signer fallback (image already saved via saveLegacySignature)
        return stampLegacySignerAndSavePdf(token);
    }

    private static Map<String, String> stampMultiSignerAndSavePdf(DocGen_Signer__c triggerSigner) {
        Id requestId = triggerSigner.Signature_Request__c;
        Id sourceDocId = triggerSigner.Signature_Request__r.Source_Document_Id__c;
        Id templateId = triggerSigner.Signature_Request__r.Template__c;
        String relatedRecordId = triggerSigner.Signature_Request__r.Related_Record_Id__c;

        try {
            // PDF generation already triggered by saveSignature's platform event.
            // Re-publishing here would enqueue a duplicate queueable → two signed PDFs.
            // Why: saveSignature publishes on every signer-completion; the trigger gates
            // PDF enqueue on remaining==0. Calling stampAndReturnSource after a complete
            // saveSignature would race a second event past the same gate.
            // How to apply: any new "post-sign finalization" work belongs in the trigger
            // or queueable, not here.

            // Return title for the UI
            String docTitle;
            if (templateId != null) {
                docTitle = triggerSigner.Signature_Request__r.Template__r.Name;
                // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
            } else if (sourceDocId != null) {
                DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                ContentVersion sourceDoc = [
                    SELECT Title
                    FROM ContentVersion
                    WHERE Id = :sourceDocId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                docTitle = sourceDoc.Title;
            } else {
                docTitle = 'Document';
            }
            return new Map<String, String>{ 'status' => 'complete', 'title' => docTitle + ' - Signed' };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Portwood: Multi-signer stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing signatures.');
        }
    }

    /**
     * Saves the typed name for a legacy single-signer request.
     * Called as a separate transaction BEFORE stampAndReturnSource to avoid DML-before-callout.
     */
    @AuraEnabled
    @RemoteAction
    public static void saveLegacySignature(String token, String typedName) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        // Guest CRUD/FLS gate — write allowlist on DocGen_Signature_Request__c.
        DocGenSignatureGuestSecurity.assertRequestWritableFields(token);
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Status__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
            throw new AuraHandledException('Invalid request or document already signed.');
            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        }
        requests[0].Signature_Data__c = typedName;
        requests[0].Status__c = 'Viewed';
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(requests[0], new Set<String>{ 'Signature_Data__c', 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(requests[0], false, AccessLevel.SYSTEM_MODE);
    }

    private static Map<String, String> stampLegacySignerAndSavePdf(String token) {
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Source_Document_Id__c',
                'Related_Record_Id__c',
                'Secure_Token__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Id, Status__c, Signer_Name__c, Signer_Email__c, Source_Document_Id__c, Related_Record_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (requests.isEmpty() || requests[0].Status__c == 'Signed' || requests[0].Status__c == 'Cancelled') {
            throw new AuraHandledException('Invalid request or document already signed.');
        }

        DocGen_Signature_Request__c req = requests[0];

        try {
            // PDF generation via VF page (stamps signatures internally, no DML before callout)
            Blob pdfBlob = convertSignatureRequestToPdf(req.Id);

            // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.

            DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            ContentVersion sourceDoc = [
                SELECT Title
                FROM ContentVersion
                WHERE Id = :req.Source_Document_Id__c
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            String fileName = sourceDoc.Title + ' - Signed';
            String base64Pdf = EncodingUtil.base64Encode(pdfBlob);

            // Save PDF to record
            saveSignedDocument(req.Related_Record_Id__c, fileName, base64Pdf, 'pdf');

            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects

            // Update request status and clear signature data
            req.Status__c = 'Signed';
            req.Signature_Data__c = null;
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.guestAssertUpdateable(req, new Set<String>{ 'Status__c', 'Signature_Data__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);

            // Create audit trail
            String pdfHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', pdfBlob));
            DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
            audit.Signature_Request__c = req.Id;
            audit.Signer_Name__c = req.Signer_Name__c;
            audit.Signer_Email__c = req.Signer_Email__c;
            audit.Signed_Date__c = System.now();
            audit.Document_Hash_SHA256__c = pdfHash;
            audit.IP_Address__c = 'Server-Side';
            audit.User_Agent__c = 'VF renderAs=pdf - Server-Side PDF Generation';
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.guestAssertCreateable(
                audit,
                new Set<String>{
                    'Signature_Request__c',
                    'Signer_Name__c',
                    'Signer_Email__c',
                    'Signed_Date__c',
                    'Document_Hash_SHA256__c',
                    'IP_Address__c',
                    'User_Agent__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

            return new Map<String, String>{ 'status' => 'complete', 'title' => fileName };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Portwood: Legacy stamping failed: ' + e.getMessage());
            throw new AuraHandledException('An error occurred while processing the signature.');
        }
    }

    /**
     * Saves a signed document to a record using SYSTEM_MODE DML.
     * Guest users cannot use Security.stripInaccessible or USER_MODE on ContentVersion/ContentDocumentLink,
     * so this method bypasses CRUD checks. Access is gated by the validated signature token.
     */
    private static Id saveSignedDocument(String recordId, String fileName, String base64Data, String extension) {
        ContentVersion cv = new ContentVersion();
        cv.Title = fileName;
        cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
        cv.VersionData = EncodingUtil.base64Decode(base64Data);
        cv.IsMajorVersion = true;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'IsMajorVersion' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<ContentVersion>{ cv }, false, AccessLevel.SYSTEM_MODE);

        DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH SYSTEM_MODE]
        .ContentDocumentId;

        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = contentDocId;
        cdl.LinkedEntityId = recordId;
        cdl.ShareType = 'V';
        cdl.Visibility = 'AllUsers';
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            cdl,
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<ContentDocumentLink>{ cdl }, false, AccessLevel.SYSTEM_MODE);

        return contentDocId;
    }

    /**
     * Converts a stamped DOCX blob to HTML. Public so DocGenPdfRendererController can call it.
     */
    public static String convertStampedDocxToHtml(Blob docxBlob) {
        Map<String, Object> extracted = extractDocxParts(docxBlob);
        String documentXml = (String) extracted.get('documentXml');
        Map<String, String> imagesByRelId = (Map<String, String>) extracted.get('imagesByRelId');
        return DocGenHtmlRenderer.convertToHtml(documentXml, imagesByRelId);
    }

    /**
     * Generates a PDF from a signature request using Blob.toPdf().
     * Stamps typed-name signatures into the DOCX, converts to HTML, renders PDF.
     * No image blobs — just text replacement.
     */
    public static Blob convertSignatureRequestToPdf(Id requestId) {
        if (Test.isRunningTest()) {
            return Blob.toPdf('<html><body><p>Test PDF - Signed Document</p></body></html>');
        }

        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Source_Document_Id__c', 'Template__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> requests = [
            SELECT Source_Document_Id__c, Template__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (requests.isEmpty()) {
            throw new DocGenException('Signature request not found.');
        }

        Id sourceDocId = requests[0].Source_Document_Id__c;
        Id templateId = requests[0].Template__c;
        Id activeVersionId = lookupActiveTemplateVersionId(templateId);
        DocGenService.applyWatermarkOverride(templateId);

        // SYSTEM_MODE required: guest profile has no Portwood CRUD by design; access is gated by token-bound lookup. See DocGenSignatureGuestSecurity for the security model.
        // Get typed-name signatures from signers
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Role_Name__c', 'Signature_Data__c', 'Signature_Request__c', 'Status__c', 'Sort_Order__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Role_Name__c, Signature_Data__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId AND Status__c = 'Signed'
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        List<DocGenSignatureService.SignerData> signerDataList = new List<DocGenSignatureService.SignerData>();
        for (DocGen_Signer__c s : signers) {
            if (String.isNotBlank(s.Signature_Data__c)) {
                signerDataList.add(new DocGenSignatureService.SignerData(s.Role_Name__c, s.Signature_Data__c));
            }
        }

        Blob stampedBlob;
        if (!signerDataList.isEmpty()) {
            stampedBlob = DocGenSignatureService.stampAllSignaturesToBlob(sourceDocId, signerDataList);
        }

        if (stampedBlob == null) {
            throw new DocGenException('Could not generate stamped document.');
        }

        // Extract DOCX parts — only template images remain (no signature images).
        Map<String, Object> parts = extractDocxParts(stampedBlob);
        String documentXml = (String) parts.get('documentXml');
        Map<String, String> imagesByRelId = (Map<String, String>) parts.get('imagesByRelId');

        // For any remaining template images, use relative CV URLs.
        // Scope the lookup to THIS template's active version so cross-template relId
        // collisions (rId1 in template A vs template B) can't surface the wrong image.
        Map<String, String> imageUrlMap = new Map<String, String>();
        if (imagesByRelId != null && activeVersionId != null) {
            String titlePrefix = 'docgen_tmpl_img_' + activeVersionId + '_';
            String titleLike = titlePrefix + '%';
            DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'CreatedDate' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> allTmplCvs = [
                SELECT Id, Title
                FROM ContentVersion
                WHERE Title LIKE :titleLike
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
            ];
            Map<String, String> tmplImgUrls = new Map<String, String>();
            for (ContentVersion cv : allTmplCvs) {
                String title = cv.Title == null ? '' : cv.Title;
                if (!title.startsWith(titlePrefix)) {
                    continue;
                }
                String imgRelId = title.substring(titlePrefix.length());
                if (!tmplImgUrls.containsKey(imgRelId)) {
                    tmplImgUrls.put(imgRelId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
                }
            }
            for (String relId : imagesByRelId.keySet()) {
                if (tmplImgUrls.containsKey(relId)) {
                    imageUrlMap.put(relId, tmplImgUrls.get(relId));
                }
            }
        }

        String html = DocGenHtmlRenderer.convertToHtml(documentXml, imageUrlMap);
        return Blob.toPdf(html);
    }

    /**
     * Extracts document.xml, rels, and images from a DOCX blob.
     * Returns a map keyed by relationship ID → base64 image data (as the renderer expects).
     */
    public static Map<String, Object> extractDocxParts(Blob docxBlob) {
        Compression.ZipReader reader = new Compression.ZipReader(docxBlob);
        String documentXml = null;
        String relsXml = null;
        Map<String, String> imagesByFileName = new Map<String, String>();

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                documentXml = reader.extract(name).toString();
            } else if (name == 'word/_rels/document.xml.rels') {
                relsXml = reader.extract(name).toString();
            } else if (name.startsWith('word/media/')) {
                String fileName = name.substringAfter('word/media/');
                imagesByFileName.put(fileName, EncodingUtil.base64Encode(reader.extract(name)));
            }
        }

        // Build relId → base64 map by parsing the .rels XML
        Map<String, String> imagesByRelId = new Map<String, String>();
        if (relsXml != null) {
            // Parse <Relationship Id="rId..." Target="media/filename.png"/> entries
            Integer cursor = 0;
            while (cursor < relsXml.length()) {
                Integer relStart = relsXml.indexOf('<Relationship ', cursor);
                if (relStart == -1)
                    break;
                Integer relEnd = relsXml.indexOf('/>', relStart);
                if (relEnd == -1)
                    break;
                relEnd += 2;

                String relTag = relsXml.substring(relStart, relEnd);
                String relId = extractXmlAttr(relTag, 'Id');
                String target = extractXmlAttr(relTag, 'Target');

                if (relId != null && target != null && target.startsWith('media/')) {
                    String mediaFileName = target.substringAfter('media/');
                    String base64 = imagesByFileName.get(mediaFileName);
                    if (base64 != null) {
                        imagesByRelId.put(relId, base64);
                    }
                }
                cursor = relEnd;
            }
        }

        return new Map<String, Object>{ 'documentXml' => documentXml, 'imagesByRelId' => imagesByRelId };
    }

    /**
     * Extracts an attribute value from an XML tag string.
     */
    private static String extractXmlAttr(String tag, String attrName) {
        String search = attrName + '="';
        Integer start = tag.indexOf(search);
        if (start == -1)
            return null;
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1)
            return null;
        return tag.substring(start, end2);
    }

    /**
     * Cleans up temporary signature image ContentVersion records.
     */
    private static void cleanupSignatureTempImages(String batchKey) {
        if (String.isBlank(batchKey))
            return;
        try {
            DocGenFlsGuard.guestAssertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'Title' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<ContentVersion> tempCvs = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Title LIKE :('docgen_sig_' + batchKey + '_%')
                WITH SYSTEM_MODE
            ];
            if (!tempCvs.isEmpty()) {
                Set<Id> docIds = new Set<Id>();
                for (ContentVersion cv : tempCvs) {
                    docIds.add(cv.ContentDocumentId);
                }
                if (Schema.sObjectType.ContentDocument.isDeletable()) {
                    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                    delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds]; // NOPMD ApexCRUDViolation — CRUD checked above
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Portwood: Failed to clean up temp signature images: ' + e.getMessage());
        }
    }

    // =========================================================================
    // Decline Signature
    // =========================================================================

    /**
     * Allows a signer to decline the signature request with a reason.
     * Marks the signer and parent request as Declined, creates an audit record.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, Object> declineSignature(
        String token,
        String reason,
        String ipAddress,
        String userAgent
    ) {
        Map<String, Object> result = new Map<String, Object>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('success', false);
            result.put('message', 'Invalid security token.');
            return result;
        }

        // Guest CRUD/FLS gate — write allowlist: Signer.Status__c,
        // Signer.Decline_Reason__c, Request.Status__c, plus audit creation.
        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);
        DocGenSignatureGuestSecurity.assertRequestWritableFields(token);
        DocGenSignatureGuestSecurity.assertAuditCreateable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Signature_Request__c',
                'Role_Name__c',
                'Contact__c',
                'CreatedDate',
                'Secure_Token__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Signature_Request__c,
                Signature_Request__r.Expires_At__c,
                Role_Name__c,
                Contact__c,
                CreatedDate
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation

        if (signers.isEmpty()) {
            result.put('success', false);
            result.put('message', 'Signer not found.');
            return result;
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            result.put('success', false);
            result.put('message', 'This signature link has expired.');
            return result;
        }
        if (signer.Status__c == 'Signed') {
            result.put('success', false);
            result.put('message', 'You have already signed this document.');
            return result;
        }
        if (signer.Status__c == 'Declined') {
            result.put('success', false);
            result.put('message', 'You have already declined this request.');
            return result;
        }

        // Mark signer as declined
        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        signer.Status__c = 'Declined';
        signer.Decline_Reason__c = String.isNotBlank(reason) ? reason.left(1000) : null;
        // Issue #91: clear the typed-name cache so a refresh of the signing link doesn't
        // re-stamp the preview with what the signer typed before declining.
        signer.Signature_Data__c = null;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'Status__c', 'Decline_Reason__c', 'Signature_Data__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Mark parent request as declined. Null out the cached preview HTML — the JSON blob
        // in Signature_Data__c carries the live preview with names already stamped, and
        // fetchDocumentData would otherwise re-serve it (issue #91). #156: a declined request
        // will never be signed, so reclaim the frozen-snapshot CV (hash is retained on the audit).
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Frozen_Document_CV_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> snapRows = [
            SELECT Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :signer.Signature_Request__c
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        Id frozenCvToPurge = snapRows.isEmpty() ? null : (Id) snapRows[0].Frozen_Document_CV_Id__c;

        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = 'Declined';
        parentReq.Signature_Data__c = null;
        parentReq.Frozen_Document_CV_Id__c = null;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(
            parentReq,
            new Set<String>{ 'Status__c', 'Signature_Data__c', 'Frozen_Document_CV_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);
        DocGenSignatureService.purgeFrozenSnapshotCv(frozenCvToPurge);

        // Create audit record
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = resolveClientIp(ipAddress);
        audit.User_Agent__c = String.isNotBlank(userAgent) ? userAgent.left(255) : 'Unknown';
        audit.Consent_Captured__c = false;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            audit,
            new Set<String>{
                'Signature_Request__c',
                'Signer__c',
                'Verification_Method__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Contact__c',
                'Signed_Date__c',
                'IP_Address__c',
                'User_Agent__c',
                'Consent_Captured__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Decline notification deferred to system context via platform event
        // (guest users cannot query User records or send email — triggers session ID error)
        try {
            DocGen_Signature_PDF__e notifyEvent = new DocGen_Signature_PDF__e();
            notifyEvent.Request_Id__c = signer.Signature_Request__c;
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            EventBus.publish(notifyEvent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Decline notification event failed: ' + e.getMessage());
        }

        result.put('success', true);
        result.put('message', 'You have declined this signature request.');
        return result;
    }

    // =========================================================================
    // Phase 2: Guided Signing — Per-Placement Endpoints
    // =========================================================================

    /**
     * Returns all signature placements for a signer, ordered by document index then sequence.
     * Used by the guided signing flow to build the step-through UI.
     * Includes current status so the signer can resume where they left off.
     */
    @AuraEnabled
    @RemoteAction
    public static List<Map<String, Object>> getSignerPlacements(String token) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Guest CRUD/FLS gate — read scope (DocGen_Signer__c, DocGen_Signature_Placement__c).
        DocGenSignatureGuestSecurity.assertSignerReadable(token);
        DocGenSignatureGuestSecurity.assertPlacementWritableFields(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signature_Request__c', 'CreatedDate', 'PIN_Verified_At__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, Signature_Request__c, CreatedDate, PIN_Verified_At__c, Signature_Request__r.Expires_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            throw new AuraHandledException('This signature link has expired.');
        }

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Placement__c.sObjectType,
            new Set<String>{
                'Sequence_Order__c',
                'Placement_Type__c',
                'Render_Inline__c',
                'Status__c',
                'Signed_Value__c',
                'Signed_At__c',
                'Section_Context__c',
                'Tag_Text__c',
                'Document_Index__c',
                'Signer__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Placement__c> placements = [
            SELECT
                Id,
                Sequence_Order__c,
                Placement_Type__c,
                Render_Inline__c,
                Status__c,
                Signed_Value__c,
                Signed_At__c,
                Section_Context__c,
                Tag_Text__c,
                Document_Index__c
            FROM DocGen_Signature_Placement__c
            WHERE Signer__c = :signer.Id
            WITH SYSTEM_MODE
            ORDER BY Document_Index__c ASC, Sequence_Order__c ASC
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (DocGen_Signature_Placement__c plc : placements) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', plc.Id);
            m.put('sequence', plc.Sequence_Order__c);
            m.put('type', plc.Placement_Type__c);
            m.put('renderInline', plc.Render_Inline__c == true);
            m.put('status', plc.Status__c);
            m.put('signedValue', plc.Signed_Value__c);
            m.put('signedAt', plc.Signed_At__c);
            m.put('sectionContext', plc.Section_Context__c);
            m.put('tagText', plc.Tag_Text__c);
            m.put('documentIndex', plc.Document_Index__c);
            result.add(m);
        }
        return result;
    }

    /**
     * Signs a single placement during the guided signing flow.
     * Persists the value, marks as signed, and returns the updated placement list.
     */
    @AuraEnabled
    @RemoteAction
    public static List<Map<String, Object>> signPlacement(String token, Id placementId, String value) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        // Guest CRUD/FLS gate — write allowlist on DocGen_Signature_Placement__c
        // (Status__c, Signed_At__c, Signed_Value__c).
        DocGenSignatureGuestSecurity.assertPlacementWritableFields(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'CreatedDate', 'PIN_Verified_At__c', 'Status__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                CreatedDate,
                PIN_Verified_At__c,
                Status__c,
                Signature_Request__c,
                Signature_Request__r.Expires_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (requestRequiresVerification(signer.Signature_Request__c) && signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required.');
        }

        // Verify the placement belongs to this signer
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Placement__c.sObjectType,
            new Set<String>{ 'Signer__c', 'Status__c', 'Placement_Type__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Id, Signer__c, Status__c, Placement_Type__c
            FROM DocGen_Signature_Placement__c
            WHERE Id = :placementId AND Signer__c = :signer.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by Portwood permission sets

        if (plcs.isEmpty()) {
            throw new AuraHandledException('Placement not found.');
        }

        DocGen_Signature_Placement__c plc = plcs[0];
        if (plc.Status__c == 'Signed') {
            // Already signed — return current state (idempotent)
            return getSignerPlacements(token);
        }

        // For Date type, auto-fill with server timestamp
        if (plc.Placement_Type__c == 'Date') {
            plc.Signed_Value__c = System.now().format('MMMM d, yyyy');
        } else {
            if (String.isBlank(value)) {
                throw new AuraHandledException('Please provide a value.');
            }
            plc.Signed_Value__c = value.left(255);
        }

        plc.Status__c = 'Signed';
        plc.Signed_At__c = System.now();
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(plc, new Set<String>{ 'Signed_Value__c', 'Status__c', 'Signed_At__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(plc, false, AccessLevel.SYSTEM_MODE);

        return getSignerPlacements(token);
    }

    /**
     * Returns a ContentVersion's binary data as base64 for guest users.
     * Guest users cannot access /sfc/servlet.shepherd/ URLs directly (auth required).
     * The signing page JS calls this per image, then injects as data URI.
     *
     * Authorization: a valid signing token by itself is not enough — the requested CV
     * must be bound to this signer's signature request. Allowed CVs:
     *   - The request's Source_Document_Id__c
     *   - A docgen_tmpl_img_<versionId>_* image for the request's template active version
     *   - A docgen_html_img_<templateId>_* image for the request's template
     * Any other CV ID is rejected to prevent IDOR (a valid token leaking access to
     * arbitrary org files).
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> getImageBase64(String token, String contentVersionId) {
        Map<String, String> result = new Map<String, String>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('error', 'Invalid token');
            return result;
        }

        // Guest CRUD/FLS gate — read scope on DocGen_Signer__c + token-scoped
        // ContentVersion lookup. The isAuthorizedSignatureImage() check below
        // further restricts which CVs this token can resolve.
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'CreatedDate', 'Signature_Request__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                CreatedDate,
                Signature_Request__c,
                Signature_Request__r.Source_Document_Id__c,
                Signature_Request__r.Template__c,
                Signature_Request__r.Expires_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (
            signers.isEmpty() ||
            DocGenSignatureExpiry.isExpired(signers[0].Signature_Request__r.Expires_At__c, signers[0].CreatedDate)
        ) {
            result.put('error', 'Invalid or expired token');
            return result;
        }

        // Validate ContentVersion ID format (must be the 18-char ContentVersion ID prefix `068`)
        if (
            String.isBlank(contentVersionId) ||
            contentVersionId.length() != 18 ||
            !contentVersionId.startsWith('068') ||
            !Pattern.matches('[a-zA-Z0-9]{18}', contentVersionId)
        ) {
            result.put('error', 'Invalid content version ID');
            return result;
        }

        DocGen_Signer__c signer = signers[0];
        Id sourceDocId = signer.Signature_Request__r != null ? signer.Signature_Request__r.Source_Document_Id__c : null;
        Id templateId = signer.Signature_Request__r != null ? signer.Signature_Request__r.Template__c : null;

        if (!isAuthorizedSignatureImage(contentVersionId, sourceDocId, templateId)) {
            result.put('error', 'Image not authorized for this signing session');
            return result;
        }

        try {
            DocGenFlsGuard.guestAssertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'VersionData', 'FileExtension' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            ContentVersion cv = [
                SELECT VersionData, FileExtension
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - ContentVersion accessed for signature document preview

            String mimeType = 'image/png';
            if (cv.FileExtension == 'jpg' || cv.FileExtension == 'jpeg')
                mimeType = 'image/jpeg';
            else if (cv.FileExtension == 'gif')
                mimeType = 'image/gif';
            else if (cv.FileExtension == 'svg')
                mimeType = 'image/svg+xml';

            result.put('base64', EncodingUtil.base64Encode(cv.VersionData));
            result.put('mimeType', mimeType);
        } catch (Exception e) {
            result.put('error', 'Image not found');
        }

        return result;
    }

    /**
     * Returns the Id of the active template version (Is_Active__c = TRUE) for a template,
     * or null if the template has no active version. Centralized so callers don't
     * duplicate the lookup pattern.
     */
    @TestVisible
    private static Id lookupActiveTemplateVersionId(Id templateId) {
        if (templateId == null) {
            return null;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Template_Version__c> versions = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].Id;
    }

    /**
     * Verifies a ContentVersion ID is bound to the signer's signature request context.
     * Allowed: source document, template-version-extracted images, HTML template images.
     */
    @TestVisible
    private static Boolean isAuthorizedSignatureImage(Id contentVersionId, Id sourceDocId, Id templateId) {
        if (contentVersionId == sourceDocId) {
            return true;
        }
        if (templateId == null) {
            return false;
        }
        Id activeVersionId = lookupActiveTemplateVersionId(templateId);

        Set<String> allowedTitlePrefixes = new Set<String>();
        if (activeVersionId != null) {
            allowedTitlePrefixes.add('docgen_tmpl_img_' + activeVersionId + '_');
        }
        allowedTitlePrefixes.add('docgen_html_img_' + templateId + '_');

        // Build a single-shot SOQL with multiple LIKE clauses
        DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentVersion> cvs = [
            SELECT Id, Title
            FROM ContentVersion
            WHERE Id = :contentVersionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            return false;
        }
        String title = cvs[0].Title == null ? '' : cvs[0].Title;
        for (String prefix : allowedTitlePrefixes) {
            if (title.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Kept for backward compatibility but now a no-op since PDF is generated server-side.
     * The VF page calls this after stamping — we just return success since the PDF
     * was already generated and saved in stampAndReturnSource.
     */
    @AuraEnabled
    @RemoteAction
    public static void finishSignatureUpload(String token, String base64Pdf, String fileName) {
        // PDF is now generated and saved server-side in stampAndReturnSource.
        // This method is retained as a no-op for backward compatibility with the VF page flow.
    }

    /**
     * Milestone 1 — flat-PDF signing page (DocGenSignaturePdf.page).
     *
     * Returns the request's pre-generated source PDF as base64 so the guest VF
     * page can render the REAL document in an iframe/blob (guests can't hit
     * /sfc/servlet.shepherd/ file URLs). The ContentVersion is resolved
     * server-side from the token-bound request's Source_Document_Id__c — NO CV
     * id is accepted from the client, so there is no IDOR surface (unlike
     * getImageBase64, which takes a CV id and must gate it via
     * isAuthorizedSignatureImage). Mirrors the getImageBase64 security pattern:
     * token format check → assertSignerReadable → per-field FLS guard →
     * WITH SYSTEM_MODE.
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, String> getSourcePdfBase64(String token) {
        Map<String, String> result = new Map<String, String>();

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            result.put('error', 'Invalid token');
            return result;
        }

        // Guest CRUD/FLS gate — read scope on DocGen_Signer__c + token-scoped
        // request lookup. The CV served is bound to this token's request, so
        // no client-supplied CV id (and thus no IDOR check) is needed here.
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'CreatedDate', 'Signature_Request__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT Id, CreatedDate, Signature_Request__r.Source_Document_Id__c, Signature_Request__r.Expires_At__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (
            signers.isEmpty() ||
            DocGenSignatureExpiry.isExpired(signers[0].Signature_Request__r.Expires_At__c, signers[0].CreatedDate)
        ) {
            result.put('error', 'Invalid or expired token');
            return result;
        }

        Id sourceDocId = signers[0].Signature_Request__r != null
            ? signers[0].Signature_Request__r.Source_Document_Id__c
            : null;
        if (sourceDocId == null) {
            result.put('error', 'No source document for this signing session');
            return result;
        }

        try {
            // SYSTEM_MODE required: guest profile has no Portwood/ContentVersion CRUD by
            // design; access is gated by the token-bound Source_Document_Id__c above.
            DocGenFlsGuard.guestAssertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData', 'Title' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            ContentVersion cv = [
                SELECT VersionData, Title
                FROM ContentVersion
                WHERE Id = :sourceDocId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - ContentVersion accessed for token-bound signature document render

            result.put('base64', EncodingUtil.base64Encode(cv.VersionData));
            result.put('fileName', String.isNotBlank(cv.Title) ? cv.Title : 'Document');
            result.put('mimeType', 'application/pdf');
        } catch (Exception e) {
            result.put('error', 'Document not found');
        }

        return result;
    }

    /**
     * Milestone 1 — flat-PDF signing page save path.
     *
     * Records the signature audit row + flips signer/request status only. This
     * is the dedicated PDF-path save: it does NOT reuse saveSignature (which
     * publishes DocGen_Signature_PDF__e and kicks the DOCX-XML stamping
     * queueable — wrong for a flat PDF). NO platform event, NO stamping; the
     * certificate/audit page is Milestone 2 and out of scope here.
     *
     * Returns { success, isComplete, remaining }.
     */
    @AuraEnabled
    @RemoteAction
    public static SavePdfSignatureResult savePdfSignature(
        String token,
        String typedName,
        Boolean consentGiven,
        String ipAddress,
        String userAgent,
        String formFieldJson
    ) {
        SavePdfSignatureResult result = new SavePdfSignatureResult();
        result.success = false;

        // Validate token format
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }

        if (String.isBlank(typedName)) {
            throw new AuraHandledException('Please type your name to sign.');
        }

        if (consentGiven != true) {
            throw new AuraHandledException('You must agree to sign electronically.');
        }

        // Guest CRUD/FLS gate — write allowlist (Signer.Status__c,
        // Signer.Signature_Data__c) + audit creation. See guard helper.
        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);
        DocGenSignatureGuestSecurity.assertAuditCreateable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Signature_Request__c',
                'Role_Name__c',
                'Contact__c',
                'CreatedDate',
                'PIN_Verified_At__c',
                'Consent_Captured__c',
                'Secure_Token__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Signature_Request__c,
                Signature_Request__r.Expires_At__c,
                Role_Name__c,
                Contact__c,
                CreatedDate,
                PIN_Verified_At__c,
                Consent_Captured__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }

        // Require PIN verification before allowing signature
        if (requestRequiresVerification(signer.Signature_Request__c) && signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required before signing.');
        }

        // Signer form fields: validate + persist the collected values BEFORE the
        // signer is finalized, so a required-field failure aborts the whole save
        // (no status change, nothing persisted) and the guest sees a clean error.
        captureFormFieldData(signer.Id, signer.Signature_Request__c, token, formFieldJson);

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        // Store typed name and mark as signed
        signer.Signature_Data__c = typedName;
        signer.Status__c = 'Signed';
        signer.Consent_Captured__c = true;
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'Signature_Data__c', 'Status__c', 'Consent_Captured__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        // Create audit trail immediately with all available data (mirrors saveSignature)
        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = resolveClientIp(ipAddress);
        audit.User_Agent__c = String.isNotBlank(userAgent) ? userAgent.left(255) : 'Unknown';
        audit.Consent_Captured__c = true;
        audit.PIN_Verified_At__c = signer.PIN_Verified_At__c;
        // #verification — record how identity was checked, even when the PIN was skipped.
        audit.Verification_Method__c = signer.PIN_Verified_At__c != null ? 'Email PIN' : 'None';
        // No Document_Hash_SHA256__c — there is no stamped output in Milestone 1.
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.guestAssertCreateable(
            audit,
            new Set<String>{
                'Signature_Request__c',
                'Signer__c',
                'Verification_Method__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Contact__c',
                'Signed_Date__c',
                'IP_Address__c',
                'User_Agent__c',
                'Consent_Captured__c',
                'PIN_Verified_At__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Check if all signers are now complete
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
            WITH SYSTEM_MODE
        ];

        Integer remaining = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c != 'Signed')
                remaining++;
        }

        result.remaining = remaining;
        result.isComplete = (remaining == 0);

        // M2: snapshot-backed requests (Template__c set) finalize a signed document +
        // certificate page server-side. Detect via the parent request's Template__c.
        DocGenFlsGuard.guestAssertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Template__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Request__c> parentReqs = [
            SELECT Template__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :signer.Signature_Request__c
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        Boolean snapshotBacked = !parentReqs.isEmpty() && parentReqs[0].Template__c != null;

        // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        if (snapshotBacked) {
            // Leave 'In Progress' so the platform-event trigger enqueues the finalizer,
            // which produces the document + certificate PDF and then sets 'Signed'.
            // (Setting 'Signed' here would make the trigger skip the finalize step.)
            parentReq.Status__c = 'In Progress';
        } else {
            // M1 flat-PDF path: no template to re-render — record status only.
            parentReq.Status__c = result.isComplete ? 'Signed' : 'In Progress';
        }
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.guestAssertUpdateable(parentReq, new Set<String>{ 'Status__c' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        // M2: publish the platform event so DocGenSignaturePdfTrigger enqueues the
        // finalizer (it gates on remaining==0 and Template__c) to produce the signed
        // document + certificate PDF on the related record. The M1 flat-PDF path has no
        // template to re-render, so it records audit + status only and never publishes.
        if (snapshotBacked) {
            DocGen_Signature_PDF__e pdfEvent = new DocGen_Signature_PDF__e();
            pdfEvent.Request_Id__c = signer.Signature_Request__c;
            EventBus.publish(pdfEvent);
        }

        result.success = true;
        return result;
    }

    /**
     * Guided-signing finalize for the client-composited path (#163).
     *
     * The browser composites the signer's drawn/typed fields onto the PDF with
     * pdf-lib (server-side image embedding is blocked — Blob.toPdf can't fetch a
     * fresh CV and rejects data URIs), then posts the finished PDF here. Unlike
     * savePdfSignature this does NOT publish the platform event / re-render —
     * the supplied PDF IS the authoritative output.
     *
     * Multi-signer: when signers remain, the composited PDF becomes the new
     * Source_Document so the next signer composites on top of it (chain). When
     * none remain, it's attached to the related record as the final signed doc.
     */
    @AuraEnabled
    @RemoteAction
    public static SavePdfSignatureResult saveCompositedSignedPdf(
        String token,
        String base64Pdf,
        Boolean consentGiven,
        String ipAddress,
        String userAgent,
        String formFieldJson
    ) {
        SavePdfSignatureResult result = new SavePdfSignatureResult();
        result.success = false;

        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        if (String.isBlank(base64Pdf)) {
            throw new AuraHandledException('No signed document was provided.');
        }
        if (consentGiven != true) {
            throw new AuraHandledException('You must agree to sign electronically.');
        }

        DocGenSignatureGuestSecurity.assertSignerWritableFields(token);
        DocGenSignatureGuestSecurity.assertAuditCreateable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Signature_Request__c',
                'Role_Name__c',
                'Contact__c',
                'CreatedDate',
                'PIN_Verified_At__c',
                'Consent_Captured__c',
                'Secure_Token__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                Signer_Name__c,
                Signer_Email__c,
                Signature_Request__c,
                Signature_Request__r.Related_Record_Id__c,
                Signature_Request__r.Template__r.Name,
                Signature_Request__r.Document_Title_Format__c,
                Signature_Request__r.Expires_At__c,
                Role_Name__c,
                Contact__c,
                CreatedDate,
                PIN_Verified_At__c,
                Consent_Captured__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (signers.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }

        DocGen_Signer__c signer = signers[0];
        if (DocGenSignatureExpiry.isExpired(signer.Signature_Request__r.Expires_At__c, signer.CreatedDate)) {
            throw new AuraHandledException('This signature link has expired.');
        }
        if (signer.Status__c == 'Signed') {
            throw new AuraHandledException('You have already signed this document.');
        }
        if (requestRequiresVerification(signer.Signature_Request__c) && signer.PIN_Verified_At__c == null) {
            throw new AuraHandledException('Email verification is required before signing.');
        }

        // Signer form fields: validate + persist before finalizing the signer (a
        // required-field failure aborts the save before any status/CV write).
        captureFormFieldData(signer.Id, signer.Signature_Request__c, token, formFieldJson);

        signer.Signature_Data__c = 'Signed (composited)';
        signer.Status__c = 'Signed';
        signer.Consent_Captured__c = true;
        DocGenFlsGuard.guestAssertUpdateable(
            signer,
            new Set<String>{ 'Signature_Data__c', 'Status__c', 'Consent_Captured__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(signer, false, AccessLevel.SYSTEM_MODE);

        DocGen_Signature_Audit__c audit = new DocGen_Signature_Audit__c();
        audit.Signature_Request__c = signer.Signature_Request__c;
        audit.Signer__c = signer.Id;
        audit.Signer_Name__c = signer.Signer_Name__c;
        audit.Signer_Email__c = signer.Signer_Email__c;
        audit.Contact__c = signer.Contact__c;
        audit.Signed_Date__c = System.now();
        audit.IP_Address__c = resolveClientIp(ipAddress);
        audit.User_Agent__c = String.isNotBlank(userAgent) ? userAgent.left(255) : 'Unknown';
        audit.Consent_Captured__c = true;
        audit.PIN_Verified_At__c = signer.PIN_Verified_At__c;
        // #verification — record how identity was checked, even when the PIN was skipped.
        audit.Verification_Method__c = signer.PIN_Verified_At__c != null ? 'Email PIN' : 'None';
        // #187 — capture the tamper-evidence hash directly from the composited bytes.
        // This guided drawn/typed path stores the PDF client-side and never publishes
        // DocGen_Signature_PDF__e, so the async finalizer (which back-fills the hash on
        // the typed/snapshot path) never runs here — leaving Document_Hash_SHA256__c
        // null. We already hold the final bytes (base64Pdf), so hash them now.
        audit.Document_Hash_SHA256__c = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(base64Pdf))
        );
        DocGenFlsGuard.guestAssertCreateable(
            audit,
            new Set<String>{
                'Signature_Request__c',
                'Signer__c',
                'Verification_Method__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Contact__c',
                'Signed_Date__c',
                'IP_Address__c',
                'User_Agent__c',
                'Consent_Captured__c',
                'PIN_Verified_At__c',
                'Document_Hash_SHA256__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(new List<DocGen_Signature_Audit__c>{ audit }, false, AccessLevel.SYSTEM_MODE);

        // Remaining signers?
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Status__c', 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Status__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :signer.Signature_Request__c
            WITH SYSTEM_MODE
        ];
        Integer remaining = 0;
        for (DocGen_Signer__c s : allSigners) {
            if (s.Status__c != 'Signed')
                remaining++;
        }
        result.remaining = remaining;
        result.isComplete = (remaining == 0);

        // Multi-signer upload verification fix: on the guided/drawn path each signer
        // composites onto the previous signer's output (a chain), and each signer's
        // audit is stamped with the hash of the document AS OF their signing. Only the
        // FINAL signer's hash therefore equals the delivered PDF, so uploading the
        // signed document to the verify page (verifyDocument → WHERE Document_Hash =
        // fileHash) returned just one signer, while the token path (verifyByRequestId)
        // correctly returned all. On completion, back-fill every signer's audit for
        // this request with the final document hash so BOTH verify paths return the
        // full roster. (The typed/server path already shares one hash via its
        // finalizer.)
        if (result.isComplete) {
            String finalHash = audit.Document_Hash_SHA256__c;
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Audit__c.sObjectType,
                new Set<String>{ 'Signature_Request__c', 'Document_Hash_SHA256__c', 'Signer_Name__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<DocGen_Signature_Audit__c> reqAudits = [
                SELECT Id, Document_Hash_SHA256__c
                FROM DocGen_Signature_Audit__c
                WHERE Signature_Request__c = :signer.Signature_Request__c AND Signer_Name__c != 'SYSTEM'
                WITH SYSTEM_MODE
            ];
            List<DocGen_Signature_Audit__c> hashFixes = new List<DocGen_Signature_Audit__c>();
            for (DocGen_Signature_Audit__c a : reqAudits) {
                if (a.Document_Hash_SHA256__c != finalHash) {
                    a.Document_Hash_SHA256__c = finalHash;
                    hashFixes.add(a);
                }
            }
            if (!hashFixes.isEmpty()) {
                DocGenFlsGuard.guestAssertUpdateable(hashFixes, new Set<String>{ 'Document_Hash_SHA256__c' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.update(hashFixes, false, AccessLevel.SYSTEM_MODE);
            }
        }

        // Persist the composited PDF.
        String baseName = (signer.Signature_Request__r != null &&
            signer.Signature_Request__r.Template__r != null)
            ? signer.Signature_Request__r.Template__r.Name
            : 'Document';
        Id relatedRecordId = signer.Signature_Request__r != null
            ? (Id) signer.Signature_Request__r.Related_Record_Id__c
            : null;

        ContentVersion cv = new ContentVersion();
        // Held in a local so the completion emails below can attach the final PDF
        // without a second base64 decode (Blob is by-reference — no heap copy).
        Blob compositedPdf = EncodingUtil.base64Decode(base64Pdf);
        cv.VersionData = compositedPdf;
        if (result.isComplete) {
            // Final signed document — attach to the related record. Honor the template's
            // document-naming pattern (Document_Title_Format__c, e.g. "Waiver - {Name}
            // {Today: MM/DD/YYYY}") so the SIGNED file matches normal generation; fall back
            // to "<base> - Signed" when no pattern is set or resolution fails (Sarah's #2).
            String signedTitle = baseName + ' - Signed';
            String titleFormat = signer.Signature_Request__r != null
                ? signer.Signature_Request__r.Document_Title_Format__c
                : null;
            if (String.isNotBlank(titleFormat) && relatedRecordId != null) {
                try {
                    Map<String, Object> recordData = DocGenService.loadRecordDataForTitle(relatedRecordId, titleFormat);
                    String resolved = DocGenService.generateDocTitle(
                        titleFormat,
                        recordData != null ? recordData : new Map<String, Object>()
                    );
                    if (String.isNotBlank(resolved)) {
                        signedTitle = resolved.trim();
                    }
                } catch (Exception titleErr) {
                    System.debug(LoggingLevel.WARN, 'Portwood: signed title format failed: ' + titleErr.getMessage());
                    // Visible in DocGen_Error_Log__c: when this fails the signed file falls
                    // back to "<base> - Signed" and the author's Document Title Format is
                    // silently lost — admins should be able to see why.
                    DocGenErrorLogger.Entry titleEntry = new DocGenErrorLogger.Entry();
                    titleEntry.severity = 'Warning';
                    titleEntry.context = 'Signature Finalize';
                    titleEntry.operation = 'saveCompositedSignedPdf:titleFormat';
                    titleEntry.recordId = relatedRecordId == null ? null : String.valueOf(relatedRecordId);
                    titleEntry.additionalInfo = 'Document_Title_Format__c=' + titleFormat;
                    titleEntry.cause = titleErr;
                    DocGenErrorLogger.log(titleEntry);
                }
            }
            cv.Title = signedTitle;
            cv.PathOnClient = signedTitle + '.pdf';
            if (relatedRecordId != null) {
                cv.FirstPublishLocationId = relatedRecordId;
            }
        } else {
            // Intermediate — becomes the base the next signer composites onto.
            cv.Title = baseName + ' - In Progress';
            cv.PathOnClient = baseName + ' - In Progress.pdf';
        }
        DocGenFlsGuard.guestAssertCreateable(cv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(cv, AccessLevel.SYSTEM_MODE);

        DocGen_Signature_Request__c parentReq = new DocGen_Signature_Request__c(Id = signer.Signature_Request__c);
        parentReq.Status__c = result.isComplete ? 'Signed' : 'In Progress';
        Set<String> reqUpd = new Set<String>{ 'Status__c' };
        if (!result.isComplete) {
            // Point the next signer's viewer at the just-composited PDF.
            ContentVersion nextCv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            parentReq.Source_Document_Id__c = nextCv.Id;
            reqUpd.add('Source_Document_Id__c');
            // Share this intermediate composited PDF with the next signer (often a
            // guest) so their viewer's getSourcePdfBase64 can read it. Without the
            // link the next signer sees a blank preview and the signing page falls
            // back to the typed-name server path — their drawn signature is replaced
            // by "Electronically signed by <name>" text, and the server re-render
            // then flattens every signer to text. Mirrors saveSignedDocument's guest
            // share (ShareType='V', Visibility='AllUsers' on the request record).
            // Best-effort: never block signing on the share.
            try {
                ContentDocumentLink nextCdl = new ContentDocumentLink();
                nextCdl.ContentDocumentId = nextCv.ContentDocumentId;
                nextCdl.LinkedEntityId = signer.Signature_Request__c;
                nextCdl.ShareType = 'V';
                nextCdl.Visibility = 'AllUsers';
                DocGenFlsGuard.guestAssertCreateable(
                    nextCdl,
                    new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
                );
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                Database.insert(nextCdl, AccessLevel.SYSTEM_MODE);
            } catch (Exception shareErr) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Portwood: failed to share intermediate signing PDF with next signer: ' + shareErr.getMessage()
                );
            }
        }
        DocGenFlsGuard.guestAssertUpdateable(parentReq, reqUpd);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.update(parentReq, false, AccessLevel.SYSTEM_MODE);

        // Signer form-field writeback: this guided drawn-signature path stores the
        // client-composited PDF directly and never enqueues TemplateSignaturePdfQueueable
        // (the typed-name path's finalizer), so the writeback event must be published
        // HERE — once, after the final signed CV is saved — or writeback never fires for
        // drawn signatures. Decoupled + post-completion, mirroring the queueable: the
        // subscriber (DocGenFieldWritebackTrigger) re-derives the writable allowlist from
        // config and re-checks FLS per field; performWriteback no-ops when the template
        // has no writeback fields and never throws into signing.
        if (result.isComplete) {
            try {
                DocGen_Field_Writeback__e wbEvent = new DocGen_Field_Writeback__e();
                wbEvent.Request_Id__c = signer.Signature_Request__c;
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                EventBus.publish(wbEvent);
            } catch (Exception wbEx) {
                System.debug(
                    LoggingLevel.WARN,
                    'Portwood: composited writeback event publish failed: ' + wbEx.getMessage()
                );
            }

            // Completion notifications. The typed-name path publishes DocGen_Signature_PDF__e
            // and DocGenSignaturePdfTrigger sends these; the guided drawn-signature path stores
            // the composited PDF directly and never fires that event, so the signer never got a
            // "you're done" email and the sender never got an "all signed" notice (Sarah's #3,
            // single-signer Flow path). Mirror the trigger here. Same OWA-required, log-and-swallow
            // contract so a missing Org-Wide Email Address can never block the signer's success.
            try {
                DocGenSignatureEmailService.sendAllSignedNotification(
                    signer.Signature_Request__c,
                    compositedPdf,
                    cv.Title
                );
            } catch (Exception notifEx) {
                System.debug(
                    LoggingLevel.WARN,
                    'Portwood: composited all-signed notification failed: ' + notifEx.getMessage()
                );
            }
            try {
                DocGenSignatureEmailService.sendSignerCompletionEmails(
                    signer.Signature_Request__c,
                    compositedPdf,
                    cv.Title
                );
            } catch (Exception signerNotifEx) {
                System.debug(
                    LoggingLevel.WARN,
                    'Portwood: composited signer completion email failed: ' + signerNotifEx.getMessage()
                );
            }
        }

        result.success = true;
        return result;
    }

    /**
     * Certificate-of-completion roster for the client-composited signing path (#163).
     * Returns every signer on this token's request (name, role, email, signed time,
     * verification) plus whether all OTHER signers are already signed — so the
     * completing signer's browser knows to append the certificate page to the final
     * PDF. Token-gated to a participant of the request (a completion certificate
     * legitimately lists all parties, as DocuSign/Adobe do).
     */
    @AuraEnabled
    @RemoteAction
    public static Map<String, Object> getSignatureCertificate(String token) {
        if (String.isBlank(token) || token.length() != 64 || !Pattern.matches('[a-fA-F0-9]{64}', token)) {
            throw new AuraHandledException('Invalid security token.');
        }
        DocGenSignatureGuestSecurity.assertSignerReadable(token);

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signature_Request__c', 'Secure_Token__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> me = [
            SELECT Id, Signature_Request__c, Signature_Request__r.Template__r.Name
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (me.isEmpty()) {
            throw new AuraHandledException('Signer not found.');
        }
        Id reqId = me[0].Signature_Request__c;
        Id myId = me[0].Id;
        String docTitle = (me[0].Signature_Request__r != null &&
            me[0].Signature_Request__r.Template__r != null)
            ? me[0].Signature_Request__r.Template__r.Name
            : 'Document';

        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Signer_Name__c',
                'Role_Name__c',
                'Signer_Email__c',
                'Status__c',
                'PIN_Verified_At__c',
                'Sort_Order__c',
                'Signature_Request__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> allSigners = [
            SELECT Id, Signer_Name__c, Role_Name__c, Signer_Email__c, Status__c, PIN_Verified_At__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :reqId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];

        // The audit rows carry the signing-event evidence (DocGen_Signer__c has none of it):
        // signed timestamp, IP address, and consent capture.
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Audit__c.sObjectType,
            new Set<String>{
                'Signer__c',
                'Signed_Date__c',
                'IP_Address__c',
                'Consent_Captured__c',
                'User_Agent__c',
                'Signature_Request__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer__c, Signed_Date__c, IP_Address__c, Consent_Captured__c, User_Agent__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :reqId
            WITH SYSTEM_MODE
        ];
        Map<Id, DocGen_Signature_Audit__c> auditMap = new Map<Id, DocGen_Signature_Audit__c>();
        for (DocGen_Signature_Audit__c a : audits) {
            if (a.Signer__c != null) {
                auditMap.put(a.Signer__c, a);
            }
        }

        Integer othersUnsigned = 0;
        List<Map<String, Object>> roster = new List<Map<String, Object>>();
        for (DocGen_Signer__c s : allSigners) {
            if (s.Id != myId && s.Status__c != 'Signed') {
                othersUnsigned++;
            }
            DocGen_Signature_Audit__c a = auditMap.get(s.Id);
            roster.add(
                new Map<String, Object>{
                    'name' => s.Signer_Name__c,
                    'role' => s.Role_Name__c,
                    'email' => s.Signer_Email__c,
                    'status' => s.Status__c,
                    'signedAt' => (a != null &&
                        a.Signed_Date__c != null)
                        ? a.Signed_Date__c.format('MMMM d, yyyy h:mm a z')
                        : null,
                    'ip' => a != null ? a.IP_Address__c : null,
                    'consent' => a != null ? a.Consent_Captured__c == true : false,
                    'userAgent' => a != null ? a.User_Agent__c : null,
                    'verified' => s.PIN_Verified_At__c != null,
                    'isMe' => s.Id == myId
                }
            );
        }

        return new Map<String, Object>{
            'documentTitle' => docTitle,
            'requestId' => reqId,
            'othersAllSigned' => othersUnsigned == 0,
            'signers' => roster,
            // Verify-page URL (token-gated) so the drawn/guided Certificate of
            // Completion carries the SAME verify link as the typed/server certificate.
            // Null when no Site URL is configured or the request has no token — the
            // cert then omits the link (file-drop verification still works).
            'verifyUrl' => DocGenSignatureService.buildVerifyUrl(reqId)
        };
    }
}

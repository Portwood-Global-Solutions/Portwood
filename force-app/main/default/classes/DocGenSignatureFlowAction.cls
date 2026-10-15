/**
 * Flow-invocable action to create a Portwood signature request and return signing links.
 *
 * Uses the full v3 signature pipeline — guided signing, placement creation,
 * OWA-based emails, signing order, email status tracking.
 *
 * PREREQUISITES:
 * 1. A Portwood template with {@Signature_Role} tags in the active version
 * 2. An Org-Wide Email Address configured in Portwood > Signatures settings
 * 3. A Salesforce Site configured for the signing page
 *
 * QUICK START:
 * 1. In your Flow, use Assignment elements to build a collection of Portwood Signers
 * 2. Drag "Portwood: Create Signature Request" into your Flow
 * 3. Set Template Id, Related Record Id, and the Signers collection
 * 4. The action returns signing URLs and a request ID for downstream automation
 */
global with sharing class DocGenSignatureFlowAction { // NOPMD AvoidGlobalModifier - required for @InvocableMethod visibility in subscriber orgs
    /**
     * Represents one signer in a signature request.
     * In Flow, create a collection of these and pass it to the Signers input.
     *
     * Fields carry BOTH @InvocableVariable AND @AuraEnabled. @InvocableVariable
     * binds them as inputs on the action; @AuraEnabled is what makes Signer
     * selectable as an Apex-Defined data type when a Flow author creates the
     * variable/collection to hold signers. Without @AuraEnabled the action still
     * appears but the type is absent from the variable picker, so the Signers
     * collection can't be built. Do not remove @AuraEnabled as "redundant."
     *
     * A SUBSCRIBER org additionally requires the explicit `global` no-arg
     * constructor below: in a managed package the implicit constructor is
     * public (invisible to subscribers), so without it Flow cannot instantiate
     * Signer and the type never appears in the Apex-Defined picker — even with
     * `global` class + `@AuraEnabled` fields. Do not remove the constructor.
     */
    global class Signer {
        // Required for subscriber-org Flow to instantiate this Apex-Defined type.
        global Signer() {
        }

        @InvocableVariable(
            required=true
            label='Name'
            description='The signer\'s full legal name. This is what appears on the signed document.'
        )
        @AuraEnabled
        global String name;

        @InvocableVariable(
            required=true
            label='Email'
            description='The signer\'s email address. They will receive the signing link at this address.'
        )
        @AuraEnabled
        global String email;

        @InvocableVariable(
            label='Role'
            description='Matches the {@Signature_Role} tag in your template. Example: "Buyer" matches {@Signature_Buyer}. Defaults to "Signer" if blank.'
        )
        @AuraEnabled
        global String role;

        @InvocableVariable(
            label='Contact Id'
            description='Optional. The Salesforce Contact record Id for this signer. Links the signature audit trail to the Contact for reporting.'
        )
        @AuraEnabled
        global Id contactId;
    }

    global class Request {
        @InvocableVariable(
            label='Template Id'
            description='The Id of the Portwood Template to use. Provide this OR Template API Name. The template must have an active version with {@Signature_Role} tags.'
        )
        global Id templateId;

        @InvocableVariable(
            label='Template API Name'
            description='The template\'s API Name field — a stable key that survives sandbox-to-production deploys, unlike a record Id. Provide this OR Template Id.'
        )
        global String templateApiName;

        @InvocableVariable(
            required=true
            label='Related Record Id'
            description='The record this signature request is for. In a record-triggered Flow, use {!$Record.Id}. The signed PDF will be attached to this record when all signers complete.'
        )
        global Id relatedRecordId;

        // DEPRECATED inner-type input. Inner classes never appear in Flow's
        // Apex-Defined variable picker, so this was never buildable as a Flow
        // variable. Kept (a managed package can't drop a published global member)
        // and `required` relaxed so the action is usable without it. Use
        // `signerRecords` (standalone DocGenSigner) instead.
        @InvocableVariable(
            label='Signers (legacy inner type — not selectable in Flow)'
            description='DEPRECATED. Used the inner Signer type, which Flow cannot expose as an Apex-Defined variable. Use the "Signers" input (DocGenSigner collection) instead.'
        )
        global List<Signer> signers;

        @InvocableVariable(
            label='Signers'
            description='A collection of Portwood Signers. Create an Apex-Defined variable of type DocGenSigner (Name + Email required; Role and Contact Id optional), add each to a collection with an Assignment element, and pass it here. Recommended input.'
        )
        global List<DocGenSigner> signerRecords;

        // Keep legacy inputs for backward compatibility with existing Flows
        @InvocableVariable(
            label='Signer Names (Legacy)'
            description='DEPRECATED — use Signers collection instead. A list of names, one per signer.'
        )
        global List<String> signerNames;

        @InvocableVariable(
            label='Signer Emails (Legacy)'
            description='DEPRECATED — use Signers collection instead. A list of emails matching Signer Names.'
        )
        global List<String> signerEmails;

        @InvocableVariable(label='Signer Roles (Legacy)' description='DEPRECATED — use Signers collection instead.')
        global List<String> signerRoles;

        @InvocableVariable(
            label='Signer Contact Ids (Legacy)'
            description='DEPRECATED — use Signers collection instead.'
        )
        global List<String> signerContactIds;

        @InvocableVariable(
            label='Send Branded Emails'
            description='Set to FALSE if your Flow sends its own emails using the Signer URLs output — Portwood will create the request and URLs without emailing signers. Leave blank or TRUE (default) to have Portwood send branded invitation emails automatically (requires an Org-Wide Email Address in Portwood settings).'
        )
        global Boolean sendEmails;

        @InvocableVariable(
            label='Signing Order'
            description='Enter "Parallel" (default) to email all signers at once, "Sequential" to send one at a time (each signer emailed only after the previous completes), or "Single" for a one-signer document.'
        )
        global String signingOrder;

        @InvocableVariable(
            label='Custom Email Message'
            description='Optional. Replaces the default body message in the signature request email for this send only (the branded layout and signing button are kept). Leave blank to use the configured Email Template.'
        )
        global String emailMessage;

        @InvocableVariable(
            label='Custom Email Subject'
            description='Optional. Replaces the subject line of the signature request email for this send only. Supports merge tokens like {DocumentTitle} and {SignerName}. Leave blank to use the configured Email Template subject.'
        )
        global String emailSubject;

        @InvocableVariable(
            label='Require Email Verification'
            description='Optional (#verification). TRUE forces the one-time email-PIN check before signing; FALSE skips it. Leave blank to inherit the template default, then the org default.'
        )
        global Boolean requireEmailVerification;

        @InvocableVariable(
            label='Pre-fill Signer Email'
            description='Optional. TRUE auto-sends the verification code to the known signer email (skips the type-your-email step); FALSE makes the signer type it. Leave blank to inherit the template/org default.'
        )
        global Boolean prefillSignerEmail;

        @InvocableVariable(
            label='Link Expiration (Days)'
            description='Optional. Signing links for this request expire this many days after send (1-365). Leave blank to use the org default from Portwood Settings.'
        )
        global Integer expirationDays;

        @InvocableVariable(
            label='Attached Documents'
            description='Optional (#412). File Ids (ContentDocument or ContentVersion) of PDFs on the related record — e.g. engineering drawings — to show signers alongside the template. Each is pinned to its current version; signers must open every one and confirm they reviewed them before they can approve, and the signed PDF lists them in an approval register. The template must allow it: its Attached Documents setting must be Optional or Required (a Required template refuses a send without any), and Decline must not be hidden. It also needs {@Signature_...} tags or no signature tags at all, not a {#Signatures} loop block. Limits are set in Signature Settings (default 100 files, 20 MB each, 200 MB in total).'
        )
        global List<String> attachedDocumentIds;

        @InvocableVariable(
            label='Attached Documents Position'
            description='Optional (#412). Before (default) shows the attached documents ahead of the template; After shows them after it.'
        )
        global String attachedDocumentPosition;
    }

    global class Result {
        @InvocableVariable(
            label='Signature Request Id'
            description='The Id of the created Portwood Signature Request record. Use this to track status, create related records, or link in downstream Flow elements.'
        )
        global Id signatureRequestId;

        @InvocableVariable(
            label='Signer URLs'
            description='A collection of unique signing URLs — one per signer, in the same order as the Signers input. Each URL is valid until the request expires (org default or the Link Expiration input). Use these in Send Email actions, Slack posts, or custom notifications.'
        )
        global List<String> signerUrls;

        @InvocableVariable(
            label='Signer Names'
            description='The resolved signer names, in order. Useful for building email templates in your Flow.'
        )
        global List<String> signerNames;

        @InvocableVariable(label='Signer Emails' description='The resolved signer emails, in order.')
        global List<String> signerEmails;

        @InvocableVariable(
            label='Signer Roles'
            description='The resolved role names per signer. Shows "Signer" for any role not specified.'
        )
        global List<String> signerRoles;

        @InvocableVariable(
            label='Email Status'
            description='Shows the email delivery result. If signers report not receiving their link, check this. Common issues: no OWA configured, email deliverability set to System Only, daily limit exceeded, or OWA not set to All Profiles.'
        )
        global String emailStatus;

        @InvocableVariable(
            label='Success'
            description='TRUE if the signature request was created successfully. FALSE if there was an error — check Error Message.'
        )
        global Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='Error details if Success is FALSE. Common: template not found, missing signer data, or permission issues.'
        )
        global String errorMessage;
    }

    @InvocableMethod(
        label='Portwood: Create Signature Request'
        description='Creates a signature request with guided signing. Pass a collection of Signers (Name + Email + Role). Returns signing URLs. Supports sequential signing, initials, dates, and all v3 tag types.'
        category='Document Generation'
    )
    global static List<Result> generate(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null)
            return results;
        for (Request req : requests) {
            results.add(processOne(req));
        }
        return results;
    }

    private static Result processOne(Request req) {
        Result r = new Result();
        r.success = false;
        r.signerUrls = new List<String>();
        r.signerNames = new List<String>();
        r.signerEmails = new List<String>();
        r.signerRoles = new List<String>();

        // Validation throws (preserves existing Flow behavior where bad input stops the Flow)
        if (req == null) {
            throw new DocGenException('Request is null');
        }
        if (req.templateId == null) {
            // PHD-9 — allow addressing the template by its stable API Name.
            req.templateId = DocGenService.templateIdByApiName(req.templateApiName);
        }
        if (req.templateId == null) {
            throw new DocGenException(
                'Template Id is required — pass the Id of a Portwood Template record or its Template API Name.'
            );
        }
        if (req.relatedRecordId == null) {
            throw new DocGenException('Related Record Id is required — pass the record this signature is for.');
        }
        // Build signer inputs — prefer the new Signer collection, fall back to legacy lists
        // buildSignerInputs throws on validation errors (blank names/emails, length mismatch)
        List<Map<String, Object>> signerInputs = buildSignerInputs(req);
        if (signerInputs.isEmpty()) {
            throw new DocGenException(
                'At least one signer is required. Pass a Signers collection or Signer Names + Emails.'
            );
        }

        // Runtime errors (template not found, DML failures) are caught and returned in Result.
        // The savepoint makes a failed send all-or-nothing: without it, work done before the
        // failure (request, signers, queued invites) would commit with the Flow told it failed.
        Savepoint beforeSend = Database.setSavepoint();
        try {
            // A Template Id that does not resolve is the likeliest Flow-author
            // mistake — a deleted template, or one copied from another org.
            //
            // The signature controller reports failures with AuraHandledException.
            // That type can only be THROWN from an Aura/VF request; raised anywhere
            // else it becomes
            //
            //     System.LimitException: Can only throw this exception type from
            //     VisualForce or Aura context
            //
            // which is UNCATCHABLE — so this very try/catch never saw it, and the
            // Flow interview faulted with a cryptic platform error instead of the
            // Success=false + Error Message this action promises.
            //
            // INSIDE the try on purpose: template-not-found is a RUNTIME error,
            // which this contract returns to the Flow. The block further up is for
            // INPUT validation, which deliberately stops the Flow instead.
            List<DocGen_Template__c> tmplCheck = [
                SELECT Id
                FROM DocGen_Template__c
                WHERE Id = :req.templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - package-internal existence probe
            if (tmplCheck.isEmpty()) {
                throw new DocGenException(
                    'Template not found: ' +
                        req.templateId +
                        ' — check the Template Id or Template API Name. It may have been deleted, or belong to another org.'
                );
            }
            // Resolve signing order. "Single" = an explicit one-signer request (behaves
            // like Parallel for delivery, but lets authors say so clearly — Sarah's #4).
            String signingOrder = String.isNotBlank(req.signingOrder) ? req.signingOrder : 'Parallel';
            if (signingOrder != 'Parallel' && signingOrder != 'Sequential' && signingOrder != 'Single') {
                signingOrder = 'Parallel';
            }

            // Consolidated signing (#170): ALL templates route to the GUIDED PDF path
            // (DocGenSignaturePdf.page), which stamps the real signature/date into the
            // final PDF via the reliable client-side composite — the same path the Sender
            // LWC uses. Templates with {@Signature_...} tags position chips at those tags;
            // tag-less legacy templates get an auto-appended "Signatures" block (option b)
            // so they sign through the same path with zero author change. The classic page
            // is deprecated — one signing path for Flow and LWC alike.
            String signersJson = JSON.serialize(signerInputs);
            DocGenSignatureSenderController.GuidedPdfSendOptions options = new DocGenSignatureSenderController.GuidedPdfSendOptions();
            options.templateId = req.templateId;
            options.relatedRecordId = req.relatedRecordId;
            options.signersJson = signersJson;
            options.signingOrder = signingOrder;
            // documentTitleFormat left null — inherited from the template
            options.emailMessage = req.emailMessage; // #193 — optional send-time custom message
            options.emailSubject = req.emailSubject; // #193 — optional send-time custom subject
            options.requireVerification = req.requireEmailVerification; // #verification — null = inherit template/org
            options.prefillSignerEmail = req.prefillSignerEmail;
            options.sendEmails = req.sendEmails; // #195 — false suppresses Portwood's invites (Flow sends its own)
            options.expirationDays = req.expirationDays; // null = org-default signing window
            options.attachedDocumentIds = req.attachedDocumentIds; // #412 — existing record PDFs shown alongside the template
            options.attachedDocumentPosition = req.attachedDocumentPosition;
            List<DocGenSignatureSenderController.SignerResult> signerResults = DocGenSignatureSenderController.sendGuidedPdfRequest(
                options
            );

            // Find the request ID
            if (!signerResults.isEmpty()) {
                String firstEmail = (String) signerInputs[0].get('signerEmail');
                // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
                // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
                // calls Schema.SObjectField.getDescribe().isAccessible() on every field
                // the SELECT lists; throws DocGenException with the offending field name
                // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
                // package-build @TestSetup FLS-propagation issue documented in
                // DocGenFlsGuard.cls.
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signer__c.sObjectType,
                    new Set<String>{ 'Signature_Request__c', 'Signer_Email__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Signer__c> createdSigners = [
                    SELECT Signature_Request__c
                    FROM DocGen_Signer__c
                    WHERE
                        Signer_Email__c = :firstEmail
                        AND Signature_Request__r.Template__c = :req.templateId
                        AND Signature_Request__r.Related_Record_Id__c = :req.relatedRecordId
                    WITH SYSTEM_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ]; // NOPMD ApexCRUDViolation - package-internal
                if (!createdSigners.isEmpty()) {
                    r.signatureRequestId = createdSigners[0].Signature_Request__c;
                }
            }

            // Populate result
            for (DocGenSignatureSenderController.SignerResult sr : signerResults) {
                r.signerUrls.add(sr.signerUrl);
                r.signerNames.add(sr.signerName);
                r.signerEmails.add(sr.signerEmail);
                r.signerRoles.add(sr.roleName);
            }

            // Read email status
            if (r.signatureRequestId != null) {
                DocGenFlsGuard.assertAccessible(
                    DocGen_Signature_Request__c.sObjectType,
                    new Set<String>{ 'Email_Status__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                DocGen_Signature_Request__c reqRecord = [
                    SELECT Email_Status__c
                    FROM DocGen_Signature_Request__c
                    WHERE Id = :r.signatureRequestId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ]; // NOPMD
                r.emailStatus = reqRecord.Email_Status__c;
            }

            r.success = true;
        } catch (Exception e) {
            Database.rollback(beforeSend);
            r.errorMessage = e.getMessage();
            r.success = false;
        }

        return r;
    }

    /**
     * Builds signer input maps from either the new Signer collection or legacy parallel lists.
     * New Signer collection takes priority.
     */
    private static List<Map<String, Object>> buildSignerInputs(Request req) {
        List<Map<String, Object>> inputs = new List<Map<String, Object>>();

        // Preferred: the standalone DocGenSigner collection — the only signer type
        // Flow can expose as an Apex-Defined variable (inner classes never appear).
        if (req.signerRecords != null && !req.signerRecords.isEmpty()) {
            for (DocGenSigner s : req.signerRecords) {
                if (String.isBlank(s.name)) {
                    throw new DocGenException('Each signer must have a Name.');
                }
                if (String.isBlank(s.email)) {
                    throw new DocGenException(
                        'Each signer must have an Email. Signer "' + s.name + '" is missing an email.'
                    );
                }
                inputs.add(
                    new Map<String, Object>{
                        'signerName' => s.name,
                        'signerEmail' => s.email,
                        'roleName' => String.isNotBlank(s.role) ? s.role : 'Signer',
                        'contactId' => s.contactId
                    }
                );
            }
            return inputs;
        }

        // Legacy inner-type collection (still supported; not Flow-buildable)
        if (req.signers != null && !req.signers.isEmpty()) {
            for (Signer s : req.signers) {
                if (String.isBlank(s.name)) {
                    throw new DocGenException('Each signer must have a Name.');
                }
                if (String.isBlank(s.email)) {
                    throw new DocGenException(
                        'Each signer must have an Email. Signer "' + s.name + '" is missing an email.'
                    );
                }
                inputs.add(
                    new Map<String, Object>{
                        'signerName' => s.name,
                        'signerEmail' => s.email,
                        'roleName' => String.isNotBlank(s.role) ? s.role : 'Signer',
                        'contactId' => s.contactId
                    }
                );
            }
            return inputs;
        }

        // Fall back to legacy parallel lists
        if (req.signerNames != null && !req.signerNames.isEmpty()) {
            if (req.signerEmails == null || req.signerEmails.size() != req.signerNames.size()) {
                throw new DocGenException(
                    'Signer Emails must match Signer Names. Got ' +
                        (req.signerEmails == null ? 0 : req.signerEmails.size()) +
                        ' emails for ' +
                        req.signerNames.size() +
                        ' names.'
                );
            }
            for (Integer i = 0; i < req.signerNames.size(); i++) {
                if (String.isBlank(req.signerNames[i])) {
                    throw new DocGenException('Signer Name at position ' + (i + 1) + ' is blank.');
                }
                if (String.isBlank(req.signerEmails[i])) {
                    throw new DocGenException('Signer Email at position ' + (i + 1) + ' is blank.');
                }
                String role = (req.signerRoles != null &&
                    i < req.signerRoles.size() &&
                    String.isNotBlank(req.signerRoles[i]))
                    ? req.signerRoles[i]
                    : 'Signer';
                String contactId = (req.signerContactIds != null &&
                    i < req.signerContactIds.size())
                    ? req.signerContactIds[i]
                    : null;
                inputs.add(
                    new Map<String, Object>{
                        'signerName' => req.signerNames[i],
                        'signerEmail' => req.signerEmails[i],
                        'roleName' => role,
                        'contactId' => contactId
                    }
                );
            }
        }

        return inputs;
    }
}

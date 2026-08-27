/**
 * Sends Portwood signature-flow emails. As of #193 all message rendering is
 * delegated to DocGenEmailTemplateService (record-driven, admin-brandable,
 * built-in-default fallback). This class keeps the send-side concerns:
 * recipient/OWA/reply-to wiring, sequential-signing logic, delivery-status
 * write-back, and best-effort error logging.
 */
// "without sharing" + guest FLS-guard variants are load-bearing: the guided
// drawn-signature path finishes inside the GUEST signer's transaction
// (saveCompositedSignedPdf), and every read here is an internal, requestId-scoped
// config lookup — the guest has no sharing on DocGen_Signature_Request__c, so a
// "with sharing" SYSTEM_MODE query returns no rows and the completion emails
// silently fail (logged as "List has no rows" / "Insufficient FLS ...Template__c").
// Same security model as DocGenSignatureController (also without sharing): the
// capability is the validated signing token upstream, not record sharing.
public without sharing class DocGenSignatureEmailService {
    /**
     * Data wrapper for each signer email to send.
     */
    public class SignerEmail {
        public String signerName;
        public String signerEmail;
        public String roleName;
        public String signatureUrl;
        public Id contactId;

        public SignerEmail(String signerName, String signerEmail, String roleName, String signatureUrl, Id contactId) {
            this.signerName = signerName;
            this.signerEmail = signerEmail;
            this.roleName = roleName;
            this.signatureUrl = signatureUrl;
            this.contactId = contactId;
        }
    }

    // =========================================================================
    // Signer request / reminder emails (T1 / T2)
    // =========================================================================

    public static void sendSignatureRequestEmails(List<SignerEmail> signers, String documentTitle) {
        sendSignatureRequestEmails(signers, documentTitle, null, null);
    }

    public static void sendSignatureRequestEmails(List<SignerEmail> signers, String documentTitle, Id requestId) {
        sendSignatureRequestEmails(signers, documentTitle, requestId, null);
    }

    /**
     * Sends signature request emails. messageOverride (optional) replaces the
     * {Message} token for this send only — the send-time custom message — and
     * never touches the branded chrome or the signing button.
     */
    public static void sendSignatureRequestEmails(
        List<SignerEmail> signers,
        String documentTitle,
        Id requestId,
        String messageOverride
    ) {
        sendSignatureRequestEmails(signers, documentTitle, requestId, messageOverride, null);
    }

    /**
     * Adds an optional per-send subjectOverride (merge-token aware) on top of the
     * messageOverride — the send-time "subject + message" customization.
     */
    public static void sendSignatureRequestEmails(
        List<SignerEmail> signers,
        String documentTitle,
        Id requestId,
        String messageOverride,
        String subjectOverride
    ) {
        sendRequestLikeEmails(
            signers,
            documentTitle,
            requestId,
            messageOverride,
            DocGenEmailTemplateService.TYPE_REQUEST,
            subjectOverride
        );
    }

    /** Reminder variant — same recipients/branding, the reminder template. */
    public static void sendSignatureReminderEmails(List<SignerEmail> signers, String documentTitle, Id requestId) {
        sendRequestLikeEmails(signers, documentTitle, requestId, null, DocGenEmailTemplateService.TYPE_REMINDER, null);
    }

    /**
     * #208 — the request's document template's Default_Email_Message__c, or null.
     * FLS-guard + SYSTEM_MODE (internal config read; USER_MODE on a new packaged
     * field breaks the namespaced build and guest senders lack template read).
     */
    @TestVisible
    private static String templateDefaultMessage(Id requestId) {
        if (requestId == null) {
            return null;
        }
        DocGenFlsGuard.guestAssertAccessible(DocGen_Signature_Request__c.sObjectType, new Set<String>{ 'Template__c' });
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Default_Email_Message__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Template__c, Template__r.Default_Email_Message__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (reqs.isEmpty() || reqs[0].Template__c == null) {
            return null;
        }
        return reqs[0].Template__r.Default_Email_Message__c;
    }

    /**
     * The request's stamped Expires_At__c, or null (legacy request / no requestId).
     * FLS-guard + SYSTEM_MODE (internal config read; USER_MODE on a new packaged
     * field breaks the namespaced build and guest senders lack request read).
     */
    private static Datetime requestExpiresAt(Id requestId) {
        if (requestId == null) {
            return null;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Expires_At__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signature_Request__c> reqs = [
            SELECT Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return reqs.isEmpty() ? null : reqs[0].Expires_At__c;
    }

    private static void sendRequestLikeEmails(
        List<SignerEmail> signers,
        String documentTitle,
        Id requestId,
        String messageOverride,
        String templateType,
        String subjectOverride
    ) {
        if (signers == null || signers.isEmpty()) {
            return;
        }

        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        // #369 — the request's template's Brand, if any, supplies its own OWA
        // ahead of the org default; getBrand() already excludes inactive brands.
        Id brandId = DocGenBrandResolver.resolveBrandForRequest(requestId);
        DocGen_Brand__c activeBrand = DocGenBrandResolver.getBrand(brandId);
        String owaId = (activeBrand != null && String.isNotBlank(activeBrand.OWA_Id__c))
            ? activeBrand.OWA_Id__c
            : (settings == null ? null : settings.Signature_OWA_Id__c);
        String senderName = UserInfo.getName();
        String senderEmail = UserInfo.getUserEmail();

        // OWA is required for signature emails — guest users cannot send without one,
        // and consistent branding requires all emails come from the same address.
        if (String.isBlank(owaId)) {
            String errMsg = 'Emails not sent — no Org-Wide Email Address configured. Set one in Portwood > Signatures settings.';
            System.debug(LoggingLevel.ERROR, 'Portwood: ' + errMsg);
            updateEmailStatus(requestId, errMsg);
            return;
        }

        // {ExpirationHours} reflects the request's actual signing window (stamped
        // Expires_At__c, or the legacy 48h when no requestId / no stamp).
        String expirationHours = String.valueOf(DocGenSignatureExpiry.effectiveHours(requestExpiresAt(requestId)));

        String defaultMessage = DocGenEmailTemplateService.defaultMessage(templateType);
        // #208 — when the sender supplied no message, a Default_Email_Message__c on
        // the request's document template beats the generic type default. A send-time
        // override (handled inside render) still wins over both.
        if (String.isBlank(messageOverride)) {
            String tplDefault = templateDefaultMessage(requestId);
            if (String.isNotBlank(tplDefault)) {
                defaultMessage = tplDefault;
            }
        }

        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        for (SignerEmail signer : signers) {
            Map<String, String> tokens = new Map<String, String>{
                'SignerName' => signer.signerName,
                'SignerEmail' => signer.signerEmail,
                'RoleName' => signer.roleName,
                'DocumentTitle' => documentTitle,
                'SenderName' => senderName,
                'SignatureUrl' => signer.signatureUrl,
                'ExpirationHours' => expirationHours,
                'Message' => defaultMessage
            };
            DocGenEmailTemplateService.RenderedEmail rendered = DocGenEmailTemplateService.render(
                templateType,
                tokens,
                messageOverride,
                brandId
            );

            String subject = String.isNotBlank(subjectOverride)
                ? DocGenEmailTemplateService.renderSubject(subjectOverride, tokens)
                : rendered.subject;

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setSubject(subject);
            email.setHtmlBody(rendered.htmlBody);
            if (String.isNotBlank(rendered.plainBody)) {
                email.setPlainTextBody(rendered.plainBody);
            }
            email.setSaveAsActivity(false);
            email.setOrgWideEmailAddressId(owaId);

            // Reply-to the creating user so signer replies reach a human, not the OWA.
            if (String.isNotBlank(senderEmail)) {
                email.setReplyTo(senderEmail);
            }

            // Use Contact as recipient if available (enables activity tracking).
            if (signer.contactId != null) {
                email.setTargetObjectId(signer.contactId);
                email.setTreatTargetObjectAsRecipient(true);
            } else {
                email.setToAddresses(new List<String>{ signer.signerEmail });
            }

            emails.add(email);
        }

        if (!emails.isEmpty()) {
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(emails, false);
            List<String> statusParts = new List<String>();
            Boolean anyFailed = false;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    statusParts.add(signers[i].signerEmail + ': Sent');
                } else {
                    anyFailed = true;
                    for (Messaging.SendEmailError err : results[i].getErrors()) {
                        String errDetail = err.getMessage() + ' (code: ' + err.getStatusCode() + ')';
                        statusParts.add(signers[i].signerEmail + ': FAILED — ' + errDetail);
                        System.debug(
                            LoggingLevel.ERROR,
                            'Portwood: Signature email failed for ' + signers[i].signerEmail + ': ' + errDetail
                        );
                    }
                }
            }
            String statusMsg = String.join(statusParts, '\n');
            if (anyFailed) {
                statusMsg =
                    'EMAIL DELIVERY ERRORS\n' +
                    statusMsg +
                    '\n\nCheck: (1) Org-Wide Email Address is set to "All Profiles" (2) Email Deliverability is "All Email" (3) Daily email limit not exceeded';
            }
            updateEmailStatus(requestId, statusMsg);
        }
    }

    // =========================================================================
    // Sender Notifications (T4 / T5 / T6)
    // =========================================================================

    /** Notifies the sender that a signer has completed their signature. */
    public static void sendSignerCompletedNotification(Id requestId, DocGen_Signer__c signer) {
        sendSenderNotification(
            requestId,
            DocGenEmailTemplateService.TYPE_SIGNER_COMPLETED,
            new Map<String, String>{
                'SignerName' => signer.Signer_Name__c,
                'RoleName' => signer.Role_Name__c,
                'RequestId' => String.valueOf(requestId)
            }
        );
    }

    /** Notifies the sender that all signers have completed. */
    public static void sendAllSignedNotification(Id requestId) {
        sendAllSignedNotification(requestId, null, null);
    }

    /**
     * All-signed sender notification with the finalized PDF attached. signedPdf
     * null (or over the attachment cap) sends the plain notification.
     */
    public static void sendAllSignedNotification(Id requestId, Blob signedPdf, String fileName) {
        sendSenderNotification(
            requestId,
            DocGenEmailTemplateService.TYPE_ALL_SIGNED,
            new Map<String, String>{ 'RequestId' => String.valueOf(requestId) },
            buildPdfAttachment(signedPdf, fileName)
        );
    }

    /** Notifies the sender that a signer has declined. */
    public static void sendDeclineNotification(Id requestId, DocGen_Signer__c signer, String reason) {
        sendSenderNotification(
            requestId,
            DocGenEmailTemplateService.TYPE_DECLINED,
            new Map<String, String>{
                'SignerName' => signer.Signer_Name__c,
                'RoleName' => signer.Role_Name__c,
                'RequestId' => String.valueOf(requestId),
                'Message' => String.isNotBlank(reason) ? ('Reason: ' + reason) : ''
            }
        );
    }

    /**
     * Sends a notification email to the user who created the signature request,
     * rendered from the template for the given type.
     */
    private static void sendSenderNotification(Id requestId, String templateType, Map<String, String> tokens) {
        sendSenderNotification(requestId, templateType, tokens, null);
    }

    private static void sendSenderNotification(
        Id requestId,
        String templateType,
        Map<String, String> tokens,
        Messaging.EmailFileAttachment attachment
    ) {
        try {
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'CreatedById' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c req = [
                SELECT CreatedById
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD

            DocGenFlsGuard.guestAssertAccessible(User.sObjectType, new Set<String>{ 'Email' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            User sender = [SELECT Email FROM User WHERE Id = :req.CreatedById WITH SYSTEM_MODE LIMIT 1]; // NOPMD
            if (String.isBlank(sender.Email)) {
                return;
            }

            // #369 — the request's template's Brand, if any, supplies its own
            // identity/OWA ahead of the org default.
            Id brandId = DocGenBrandResolver.resolveBrandForRequest(requestId);
            DocGen_Brand__c activeBrand = DocGenBrandResolver.getBrand(brandId);
            DocGenEmailTemplateService.RenderedEmail rendered = DocGenEmailTemplateService.render(
                templateType,
                tokens,
                null,
                brandId
            );

            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ sender.Email });
            email.setSubject(rendered.subject);
            email.setHtmlBody(rendered.htmlBody);
            if (String.isNotBlank(rendered.plainBody)) {
                email.setPlainTextBody(rendered.plainBody);
            }
            email.setSaveAsActivity(false);
            if (attachment != null) {
                email.setFileAttachments(new List<Messaging.EmailFileAttachment>{ attachment });
            }

            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            String owaId = (activeBrand != null && String.isNotBlank(activeBrand.OWA_Id__c))
                ? activeBrand.OWA_Id__c
                : (settings == null ? null : settings.Signature_OWA_Id__c);
            if (String.isNotBlank(owaId)) {
                email.setOrgWideEmailAddressId(owaId);
            }

            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email }, false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Sender notification failed: ' + e.getMessage());
            logSignatureEmailFailure('sendSenderNotification', requestId, e);
        }
    }

    // =========================================================================
    // Signer completion confirmation (T7)
    // =========================================================================

    /**
     * Sends a completion confirmation to the SIGNERS themselves once everyone has
     * signed. Branded like the request email. Best-effort: a missing OWA or a send
     * error is surfaced to Email_Status__c / the error log, never thrown, so it
     * can't block the finalize that calls it.
     */
    public static void sendSignerCompletionEmails(Id requestId) {
        sendSignerCompletionEmails(requestId, null, null);
    }

    /**
     * Completion confirmation with the finalized PDF attached. One attachment
     * instance is reused across every signer's message (the Blob rides along by
     * reference — no per-recipient heap copies). signedPdf null (or over the
     * attachment cap) sends the plain confirmation.
     */
    public static void sendSignerCompletionEmails(Id requestId, Blob signedPdf, String fileName) {
        Messaging.EmailFileAttachment attachment = buildPdfAttachment(signedPdf, fileName);
        try {
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signature_Request__c.sObjectType,
                new Set<String>{ 'Template__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            DocGen_Signature_Request__c req = [
                SELECT
                    Template__c,
                    (
                        SELECT Signer_Name__c, Signer_Email__c
                        FROM Signers__r
                        WHERE Status__c = 'Signed'
                    )
                FROM DocGen_Signature_Request__c
                WHERE Id = :requestId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD
            if (req.Signers__r == null || req.Signers__r.isEmpty()) {
                return;
            }

            // #369 — the request's template's Brand, if any, supplies its own
            // identity/OWA ahead of the org default.
            Id brandId = DocGenBrandResolver.resolveBrandForRequest(requestId);
            DocGen_Brand__c activeBrand = DocGenBrandResolver.getBrand(brandId);
            DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
            String owaId = (activeBrand != null && String.isNotBlank(activeBrand.OWA_Id__c))
                ? activeBrand.OWA_Id__c
                : (settings == null ? null : settings.Signature_OWA_Id__c);
            if (String.isBlank(owaId)) {
                // Guest/async sends require an OWA; surface the reason instead of failing silently.
                updateEmailStatus(
                    requestId,
                    'Signer completion emails not sent — no Org-Wide Email Address configured. Set one in Portwood > Signatures settings.'
                );
                return;
            }

            // Resolve a friendly document name (best-effort, guarded).
            String docTitle = 'your document';
            if (req.Template__c != null) {
                DocGenFlsGuard.guestAssertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<DocGen_Template__c> tpls = [
                    SELECT Name
                    FROM DocGen_Template__c
                    WHERE Id = :req.Template__c
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!tpls.isEmpty() && String.isNotBlank(tpls[0].Name)) {
                    docTitle = tpls[0].Name;
                }
            }

            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            for (DocGen_Signer__c s : req.Signers__r) {
                if (String.isBlank(s.Signer_Email__c)) {
                    continue;
                }
                DocGenEmailTemplateService.RenderedEmail rendered = DocGenEmailTemplateService.render(
                    DocGenEmailTemplateService.TYPE_COMPLETION,
                    new Map<String, String>{ 'SignerName' => s.Signer_Name__c, 'DocumentTitle' => docTitle },
                    null,
                    brandId
                );
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{ s.Signer_Email__c });
                email.setSubject(rendered.subject);
                email.setHtmlBody(rendered.htmlBody);
                if (String.isNotBlank(rendered.plainBody)) {
                    email.setPlainTextBody(rendered.plainBody);
                }
                email.setSaveAsActivity(false);
                email.setOrgWideEmailAddressId(owaId);
                if (attachment != null) {
                    email.setFileAttachments(new List<Messaging.EmailFileAttachment>{ attachment });
                }
                emails.add(email);
            }
            if (!emails.isEmpty()) {
                Messaging.sendEmail(emails, false);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Signer completion emails failed: ' + e.getMessage());
            logSignatureEmailFailure('sendSignerCompletionEmails', requestId, e);
        }
    }

    /**
     * Shared PDF attachment for completion emails. Returns null when there is no
     * PDF or it exceeds the email attachment cap (the notification still goes out
     * plain — the signed document is always on the related record regardless).
     */
    private static final Integer MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;

    private static Messaging.EmailFileAttachment buildPdfAttachment(Blob pdf, String fileName) {
        if (pdf == null) {
            return null;
        }
        if (pdf.size() > MAX_ATTACHMENT_BYTES) {
            System.debug(
                LoggingLevel.WARN,
                'Portwood: signed PDF (' + pdf.size() + ' bytes) exceeds the email attachment cap — sending without it.'
            );
            return null;
        }
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        String name = String.isNotBlank(fileName) ? fileName : 'Signed Document';
        att.setFileName(name.endsWith('.pdf') ? name : name + '.pdf');
        att.setContentType('application/pdf');
        att.setBody(pdf);
        return att;
    }

    // =========================================================================
    // Shared helpers
    // =========================================================================

    /**
     * Records a swallowed signature-email failure to DocGen_Error_Log__c so admins can
     * see it on the Error Log tab instead of only in a debug log. Best-effort.
     */
    private static void logSignatureEmailFailure(String operation, Id requestId, Exception cause) {
        DocGenErrorLogger.Entry entry = new DocGenErrorLogger.Entry();
        entry.severity = 'Warning';
        entry.context = 'Signature Email';
        entry.operation = operation;
        entry.recordId = requestId == null ? null : String.valueOf(requestId);
        entry.cause = cause;
        DocGenErrorLogger.log(entry);
    }

    /**
     * Updates the Email_Status__c field on a signature request with delivery status.
     * Helps admins diagnose email delivery issues without checking debug logs.
     */
    private static void updateEmailStatus(Id requestId, String status) {
        if (requestId == null || String.isBlank(status)) {
            return;
        }
        try {
            DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Id = requestId);
            req.Email_Status__c = status.left(1000);
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.guestAssertUpdateable(req, new Set<String>{ 'Email_Status__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(req, false, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: Could not update email status: ' + e.getMessage());
        }
    }
}

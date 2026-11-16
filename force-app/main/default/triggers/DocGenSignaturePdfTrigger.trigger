/**
 * Platform Event trigger for signature PDF generation and notifications.
 * Runs as Automated Process user (system context), bypassing guest user
 * limitations on ContentVersion access and email sending.
 * Published by the guest user VF page after each signature action.
 */
trigger DocGenSignaturePdfTrigger on DocGen_Signature_PDF__e(after insert) {
    Set<Id> requestIds = new Set<Id>();
    for (DocGen_Signature_PDF__e evt : Trigger.New) {
        if (evt.Request_Id__c == null)
            continue;
        requestIds.add(evt.Request_Id__c);
    }

    // Query requests with signer status counts
    /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
    Map<Id, DocGen_Signature_Request__c> requestMap = new Map<Id, DocGen_Signature_Request__c>(
        [
            SELECT
                Id,
                Template__c,
                Template_Ids__c,
                Status__c,
                Signing_Order__c,
                Source_Document_Id__c,
                Render_Data_Snapshot__c,
                (
                    SELECT
                        Id,
                        Status__c,
                        Signer_Name__c,
                        Signer_Email__c,
                        Role_Name__c,
                        Secure_Token__c,
                        Contact__c,
                        Signature_Data__c,
                        Decline_Reason__c,
                        Sort_Order__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c ASC
                )
            FROM DocGen_Signature_Request__c
            WHERE Id IN :requestIds
            WITH SYSTEM_MODE
        ]
    ); // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets

    // Bulkified template name lookup — collect all template Ids up front,
    // run one SOQL pass, then reference the map inside the per-event loop
    // (replaces an in-loop SOQL on the sequential signing path).
    Set<Id> templateIds = new Set<Id>();
    for (DocGen_Signature_Request__c req : requestMap.values()) {
        if (req.Template__c != null) {
            templateIds.add(req.Template__c);
        }
    }
    Map<Id, String> templateNameMap = new Map<Id, String>();
    if (!templateIds.isEmpty()) {
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (DocGen_Template__c t : [
            SELECT Id, Name
            FROM DocGen_Template__c
            WHERE Id IN :templateIds
            WITH SYSTEM_MODE
        ]) {
            // NOPMD ApexCRUDViolation - package-internal custom object; CRUD controlled by DocGen permission sets
            templateNameMap.put(t.Id, t.Name);
        }
    }

    for (DocGen_Signature_PDF__e evt : Trigger.New) {
        try {
            Id requestId = evt.Request_Id__c;
            if (requestId == null)
                continue;
            DocGen_Signature_Request__c req = requestMap.get(requestId);
            if (req == null)
                continue;

            // Count remaining unsigned signers and detect declines
            Integer remaining = 0;
            DocGen_Signer__c lastSignedSigner = null;
            DocGen_Signer__c eventSigner = null;
            DocGen_Signer__c nextPendingSigner = null;
            DocGen_Signer__c declinedSigner = null;
            for (DocGen_Signer__c s : req.Signers__r) {
                if (s.Status__c == 'Signed') {
                    lastSignedSigner = s;
                    if (String.valueOf(s.Id) == evt.Signer_Id__c) {
                        eventSigner = s;
                    }
                } else if (s.Status__c == 'Declined') {
                    declinedSigner = s;
                } else if (s.Status__c == 'Pending' && nextPendingSigner == null) {
                    nextPendingSigner = s;
                    remaining++;
                } else if (s.Status__c != 'Signed') {
                    remaining++;
                }
            }

            // Handle decline notification
            if (declinedSigner != null && req.Status__c == 'Declined') {
                try {
                    DocGenSignatureEmailService.sendDeclineNotification(
                        requestId,
                        declinedSigner,
                        declinedSigner.Decline_Reason__c
                    );
                } catch (Exception decEx) {
                    System.debug(LoggingLevel.WARN, 'DocGen: Decline notification failed: ' + decEx.getMessage());
                }
                continue;
            }

            if (remaining == 0 && req.Status__c != 'Signed') {
                // All signers complete — generate PDF. The all-signed (sender) and
                // completion (signer) emails are sent by the queueables AFTER the
                // final CV insert, so the finalized PDF can ride along as an email
                // attachment — at this point in the trigger it doesn't exist yet.
                if (req.Template__c != null) {
                    System.enqueueJob(new DocGenSignatureService.TemplateSignaturePdfQueueable(requestId));
                } else {
                    System.enqueueJob(new DocGenSignatureService.SignaturePdfQueueable(requestId));
                }
            } else if (remaining > 0) {
                // Not all done — send "signer completed" notification
                // Use the signer carried by the event. Parallel signers can finish
                // out of order, so Sort_Order__c cannot identify who just signed.
                DocGen_Signer__c completedSigner = eventSigner != null ? eventSigner : lastSignedSigner;
                if (completedSigner != null) {
                    try {
                        DocGenSignatureEmailService.sendSignerCompletedNotification(requestId, completedSigner);
                    } catch (Exception notifEx) {
                        System.debug(LoggingLevel.WARN, 'DocGen: Signer notification failed: ' + notifEx.getMessage());
                    }
                }

                // Sequential signing: send email to next signer
                if (req.Signing_Order__c == 'Sequential' && nextPendingSigner != null) {
                    try {
                        String siteUrl = DocGenSignatureSenderController.getSiteBaseUrl();
                        // Route sequential signer 2+ to the SAME page the first signer got.
                        // PDF-viewer requests (snapshot re-render or send-existing-CV) set
                        // Render_Data_Snapshot__c or Source_Document_Id__c; the classic
                        // typed-name flow sets neither. Without this, follow-up signers on a
                        // PDF-viewer request were emailed the legacy /DocGenSignature page.
                        Boolean isPdfViewer = req.Render_Data_Snapshot__c != null || req.Source_Document_Id__c != null;
                        String signingPath = isPdfViewer
                            ? DocGenSignatureSenderController.getSigningPdfPagePath()
                            : DocGenSignatureSenderController.getSigningPagePath();
                        String sigUrl = siteUrl + signingPath + '?token=' + nextPendingSigner.Secure_Token__c;

                        String docTitle = 'Document';
                        if (req.Template__c != null && templateNameMap.containsKey(req.Template__c)) {
                            String tName = templateNameMap.get(req.Template__c);
                            if (tName != null)
                                docTitle = tName;
                        }

                        DocGenSignatureEmailService.sendSignatureRequestEmails(
                            new List<DocGenSignatureEmailService.SignerEmail>{
                                new DocGenSignatureEmailService.SignerEmail(
                                    nextPendingSigner.Signer_Name__c,
                                    nextPendingSigner.Signer_Email__c,
                                    nextPendingSigner.Role_Name__c,
                                    sigUrl,
                                    nextPendingSigner.Contact__c
                                )
                            },
                            docTitle,
                            requestId
                        );
                    } catch (Exception seqEx) {
                        System.debug(
                            LoggingLevel.WARN,
                            'DocGen: Sequential signer email failed: ' + seqEx.getMessage()
                        );
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DocGen: Signature PDF event trigger error: ' + e.getMessage());
        }
    }
}

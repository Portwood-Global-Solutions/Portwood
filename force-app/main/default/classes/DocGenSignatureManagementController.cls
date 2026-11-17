public with sharing class DocGenSignatureManagementController {
    private static final Set<String> ACTIVE_REQUESTS = new Set<String>{ 'Sent', 'In Progress' };
    private static final Set<String> ACTIVE_SIGNERS = new Set<String>{ 'Pending', 'Viewed' };

    @AuraEnabled
    public static List<Map<String, Object>> listRequests(Id recordId) {
        assertAdmin(recordId);
        String relatedId = String.valueOf(recordId);
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Name',
                'Status__c',
                'CreatedDate',
                'Expires_At__c',
                'Document_Title_Format__c',
                'Template__c',
                'Email_Status__c',
                'PDF_Internal_Preview__c',
                'Related_Record_Id__c'
            }
        );
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signer_Name__c', 'Signer_Email__c', 'Role_Name__c', 'Status__c', 'Sort_Order__c' }
        );
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (DocGen_Signature_Request__c request : [
            SELECT
                Id,
                Name,
                Status__c,
                CreatedDate,
                Expires_At__c,
                Document_Title_Format__c,
                Template__r.Name,
                Email_Status__c,
                PDF_Internal_Preview__c,
                (
                    SELECT Id, Signer_Name__c, Signer_Email__c, Role_Name__c, Status__c
                    FROM Signers__r
                    ORDER BY Sort_Order__c, Id
                )
            FROM DocGen_Signature_Request__c
            WHERE Related_Record_Id__c = :relatedId AND Status__c != 'Draft'
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 100
        ]) {
            Boolean active = ACTIVE_REQUESTS.contains(request.Status__c);
            Boolean emailActions = active && request.PDF_Internal_Preview__c != true;
            Boolean canCorrect =
                emailActions && !DocGenSignatureExpiry.isExpired(request.Expires_At__c, request.CreatedDate);
            List<Map<String, Object>> signers = new List<Map<String, Object>>();
            for (DocGen_Signer__c signer : request.Signers__r) {
                signers.add(
                    new Map<String, Object>{
                        'id' => signer.Id,
                        'name' => signer.Signer_Name__c,
                        'email' => signer.Signer_Email__c,
                        'role' => signer.Role_Name__c,
                        'status' => signer.Status__c,
                        'canCorrect' => canCorrect && ACTIVE_SIGNERS.contains(signer.Status__c)
                    }
                );
            }
            result.add(
                new Map<String, Object>{
                    'id' => request.Id,
                    'name' => request.Name,
                    'status' => request.Status__c,
                    'title' => String.isNotBlank(request.Document_Title_Format__c)
                        ? request.Document_Title_Format__c
                        : (request.Template__r == null ? request.Name : request.Template__r.Name),
                    'created' => request.CreatedDate,
                    'expires' => request.Expires_At__c,
                    'deliveryStatus' => request.Email_Status__c,
                    'active' => active,
                    'canResend' => emailActions,
                    'signers' => signers
                }
            );
        }
        return result;
    }

    @AuraEnabled
    public static void manageRequest(Id recordId, Id requestId, String action) {
        DocGen_Signature_Request__c request = lockRequest(recordId, requestId);
        if (!ACTIVE_REQUESTS.contains(request.Status__c))
            throw DocGenService.ahe('This request is no longer active.');
        if (action == 'revoke') {
            DocGenSignatureSenderController.cancelSignatureRequest(request.Id);
        } else if (action == 'resend' && request.PDF_Internal_Preview__c != true) {
            resendActiveSigners(request);
        } else {
            throw DocGenService.ahe('Unsupported signature request action.');
        }
    }

    @AuraEnabled
    public static Boolean correctEmail(
        Id recordId,
        Id requestId,
        Id signerId,
        String expectedEmail,
        String correctedEmail
    ) {
        String email = correctedEmail == null ? '' : correctedEmail.trim();
        if (email.length() > 80 || !Pattern.matches('[^\\s@,;<>]+@[^\\s@,;<>]+\\.[^\\s@,;<>]+', email))
            throw DocGenService.ahe('Enter a valid email address.');
        DocGen_Signature_Request__c request = lockRequest(recordId, requestId);
        if (
            !ACTIVE_REQUESTS.contains(request.Status__c) ||
            request.PDF_Internal_Preview__c == true ||
            DocGenSignatureExpiry.isExpired(request.Expires_At__c, request.CreatedDate)
        )
            throw DocGenService.ahe(
                'Email correction is only available for active, unexpired signature requests sent by email.'
            );

        List<DocGen_Signer__c> signers = readSigners(request.Id);
        List<DocGen_Signer__c> eligible = activeSigners(request, signers);
        DocGen_Signer__c selected;
        for (DocGen_Signer__c signer : signers) {
            if (signer.Id == signerId) {
                selected = signer;
                break;
            }
        }
        if (selected == null || !ACTIVE_SIGNERS.contains(selected.Status__c))
            throw DocGenService.ahe('Only unsigned, active signers can be corrected.');
        String previousEmail = selected.Signer_Email__c == null ? '' : selected.Signer_Email__c;
        if (!previousEmail.equalsIgnoreCase(expectedEmail == null ? '' : expectedEmail))
            throw DocGenService.ahe('This email address changed. Refresh the request and try again.');
        if (email.equalsIgnoreCase(previousEmail))
            throw DocGenService.ahe('Enter an email address different from the current one.');

        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Placement__c.sObjectType,
            new Set<String>{ 'Signer__c', 'Status__c' }
        );
        if (
            [
                SELECT COUNT()
                FROM DocGen_Signature_Placement__c
                WHERE Signer__c = :signerId AND Status__c = 'Signed'
                WITH SYSTEM_MODE
            ] > 0
        ) {
            throw DocGenService.ahe(
                'This signer already completed a field. Revoke and recreate the request to change the recipient.'
            );
        }

        Boolean sendNow = eligible.contains(selected);
        DocGen_Signer_Email_Change__c audit = new DocGen_Signer_Email_Change__c(
            Signature_Request__c = request.Id,
            Signer__c = selected.Id,
            Previous_Email__c = selected.Signer_Email__c,
            Corrected_Email__c = email
        );
        // Audit creation and token invalidation commit together. Use system DML behind the
        // explicit admin and record gates because audit create access is reserved to this action.
        insert audit;
        selected.Signer_Email__c = email;
        // A Contact link routes email to Contact.Email, including later sequential sends.
        // Clear the association so every later delivery uses the explicitly corrected address.
        selected.Contact__c = null;
        resetSigner(selected);
        DocGenFlsGuard.assertUpdateable(
            selected,
            signerResetFields(new Set<String>{ 'Signer_Email__c', 'Contact__c' })
        );
        Database.update(selected, AccessLevel.SYSTEM_MODE);
        if (sendNow)
            send(request, new List<DocGen_Signer__c>{ selected });
        return sendNow;
    }

    private static void assertAdmin(Id recordId) {
        if (
            UserInfo.getUserType() == 'Guest' ||
            [
                SELECT COUNT()
                FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSet.Name = 'DocGen_Admin'
            ] == 0
        )
            throw DocGenService.ahe('Portwood Admin access is required.');
        DocGenSignaturePreparationController.assertSenderRecordAccess(recordId);
    }

    private static DocGen_Signature_Request__c lockRequest(Id recordId, Id requestId) {
        assertAdmin(recordId);
        String relatedId = String.valueOf(recordId);
        DocGenFlsGuard.assertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{
                'Related_Record_Id__c',
                'Status__c',
                'CreatedDate',
                'Expires_At__c',
                'Signing_Order__c',
                'Template__c',
                'Document_Title_Format__c',
                'Source_Document_Id__c',
                'Render_Data_Snapshot__c',
                'PDF_Internal_Preview__c'
            }
        );
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Name' });
        Id userId = UserInfo.getUserId();
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :requestId
        ];
        if (access.isEmpty() || !access[0].HasEditAccess)
            throw DocGenService.ahe('This signature request is unavailable for the current record.');
        List<DocGen_Signature_Request__c> requests = [
            SELECT
                Id,
                Status__c,
                CreatedDate,
                Expires_At__c,
                Signing_Order__c,
                Template__r.Name,
                Document_Title_Format__c,
                Source_Document_Id__c,
                Render_Data_Snapshot__c,
                PDF_Internal_Preview__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :requestId AND Related_Record_Id__c = :relatedId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (requests.isEmpty())
            throw DocGenService.ahe('This signature request is unavailable for the current record.');
        return requests[0];
    }

    private static List<DocGen_Signer__c> readSigners(Id requestId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Signature_Request__c',
                'Status__c',
                'Sort_Order__c',
                'Signer_Name__c',
                'Signer_Email__c',
                'Role_Name__c',
                'Contact__c'
            }
        );
        return [
            SELECT Id, Status__c, Sort_Order__c, Signer_Name__c, Signer_Email__c, Role_Name__c, Contact__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c, Id
        ];
    }

    private static List<DocGen_Signer__c> activeSigners(
        DocGen_Signature_Request__c request,
        List<DocGen_Signer__c> signers
    ) {
        List<DocGen_Signer__c> eligible = new List<DocGen_Signer__c>();
        for (DocGen_Signer__c signer : signers) {
            if (ACTIVE_SIGNERS.contains(signer.Status__c)) {
                eligible.add(signer);
                if (request.Signing_Order__c == 'Sequential')
                    break;
            }
        }
        return eligible;
    }

    private static Set<String> signerResetFields(Set<String> fields) {
        fields.addAll(
            new Set<String>{
                'Secure_Token__c',
                'Status__c',
                'PIN_Hash__c',
                'PIN_Expires_At__c',
                'PIN_Attempts__c',
                'PIN_Verified_At__c'
            }
        );
        return fields;
    }

    private static void resetSigner(DocGen_Signer__c signer) {
        signer.Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        signer.Status__c = 'Pending';
        signer.PIN_Hash__c = null;
        signer.PIN_Expires_At__c = null;
        signer.PIN_Attempts__c = 0;
        signer.PIN_Verified_At__c = null;
    }

    private static void resendActiveSigners(DocGen_Signature_Request__c request) {
        List<DocGen_Signer__c> eligible = activeSigners(request, readSigners(request.Id));
        if (eligible.isEmpty())
            throw DocGenService.ahe('There are no active signers to resend to.');
        for (DocGen_Signer__c signer : eligible)
            resetSigner(signer);
        DocGenFlsGuard.assertUpdateable(eligible, signerResetFields(new Set<String>()));
        Database.update(eligible, AccessLevel.SYSTEM_MODE);
        DocGen_Signature_Request__c expiry = new DocGen_Signature_Request__c(
            Id = request.Id,
            Expires_At__c = DocGenSignatureExpiry.computeExpiry(null)
        );
        DocGenFlsGuard.assertUpdateable(expiry, new Set<String>{ 'Expires_At__c' });
        Database.update(expiry, AccessLevel.SYSTEM_MODE);
        send(request, eligible);
    }

    private static void send(DocGen_Signature_Request__c request, List<DocGen_Signer__c> signers) {
        String base = DocGenSignatureSenderController.getSiteBaseUrl();
        String path = DocGenSignatureSenderController.resolveSigningPath(request);
        String title = String.isNotBlank(request.Document_Title_Format__c)
            ? request.Document_Title_Format__c
            : (request.Template__r == null ? 'Document' : request.Template__r.Name);
        List<DocGenSignatureEmailService.SignerEmail> emails = new List<DocGenSignatureEmailService.SignerEmail>();
        for (DocGen_Signer__c signer : signers) {
            emails.add(
                new DocGenSignatureEmailService.SignerEmail(
                    signer.Signer_Name__c,
                    signer.Signer_Email__c,
                    signer.Role_Name__c,
                    base + path + '?token=' + signer.Secure_Token__c,
                    signer.Contact__c
                )
            );
        }
        DocGenSignatureEmailService.sendSignatureRequestEmails(emails, title, request.Id);
    }
}

/**
 * Existing record PDFs attached to a guided signature request (#412 — drawing approval).
 *
 * A signer sees the signing template plus each attachment as its own document, fetched one at a
 * time by token + index through DocGenSignatureAttachmentRest — never merged — and must open every
 * attachment before they can approve. The signed output stays the approval record (the template
 * pages, the signatures and a register listing each attachment by version and SHA-256); the
 * attachments themselves stay untouched on the related record.
 *
 * Send side (the sender's USER_MODE): resolveForSend validates the chosen files and pins each to a
 * ContentVersion; createForRequest stores one DocGen_Signature_Attachment__c per file and one
 * DocGen_Signer_Attachment__c per signer × file (the per-signer review row: viewed now, markup in
 * #412 M2).
 *
 * Signer side (guest): every read and write is keyed by the signer's secure token and runs in
 * SYSTEM_MODE behind the guest FLS guards, the same model as getSourcePdfBase64 — see
 * DocGenSignatureGuestSecurity. No record Id ever comes from, or goes to, the browser; attachments
 * are addressed by their position (index) within the token's own request.
 */
public inherited sharing class DocGenSignatureAttachments {
    @TestVisible
    private static Integer maxAttachments = 100;
    @TestVisible
    private static Long maxBytesPerAttachment = 20L * 1024L * 1024L; // 20 MB
    @TestVisible
    private static Boolean failCreateForTest = false; // proves a failed send commits nothing

    public static final String MODE_OFF = 'Off';
    public static final String MODE_OPTIONAL = 'Optional';
    public static final String MODE_REQUIRED = 'Required';

    public static final String POSITION_BEFORE = 'Before';
    public static final String POSITION_AFTER = 'After';

    private static final Set<String> ATTACHMENT_FIELDS = new Set<String>{
        'Signature_Request__c',
        'Content_Version_Id__c',
        'Content_Document_Id__c',
        'Title__c',
        'Version_Number__c',
        'File_Size__c',
        'Platform_Checksum__c',
        'Position__c',
        'Sort_Order__c'
    };

    /** One validated, pinned file to attach. */
    public class AttachmentSpec {
        public Id contentVersionId;
        public Id contentDocumentId;
        public String title;
        public String versionNumber;
        public Long size;
        public String checksum;
        public String position;
        public Integer sortOrder;
    }

    /** Outcome of a guest operation: status follows HTTP semantics so the REST endpoint can relay it. */
    public class GuestResult {
        public Integer status = 200;
        public String error;
        public DocGen_Signer__c signer;
        public Blob bytes;
        public String sha256;
        public String title;
    }

    // =====================================================================
    // SEND SIDE
    // =====================================================================

    /**
     * The template decides whether a request may carry attached documents
     * (DocGen_Template__c.Attached_Documents__c): Off (the default, also blank) refuses any,
     * Required refuses none, Optional allows either. One rule for every entry point — the
     * Signature Sender and the Create Signature Request Flow action both call it.
     */
    public static void assertTemplateAllows(String mode, Integer attachmentCount) {
        String m = String.isBlank(mode) ? MODE_OFF : mode;
        Integer count = attachmentCount == null ? 0 : attachmentCount;
        if (m == MODE_OFF && count > 0) {
            throw new DocGenException(
                'This template does not take attached documents. To attach PDFs from the record, set ' +
                'Attached Documents on the template to Optional or Required.'
            );
        }
        if (m == MODE_REQUIRED && count == 0) {
            throw new DocGenException(
                'This template requires at least one attached document. Choose the PDFs from the record to attach.'
            );
        }
    }

    /** The per-file size cap, for the sender's picker. */
    public static Long maxBytesPerFile() {
        return maxBytesPerAttachment;
    }

    /**
     * Validates the files a sender chose and pins each one to a ContentVersion, in the order given.
     * Accepts ContentVersion (068) or ContentDocument (069) Ids; a ContentDocument resolves to its
     * latest version at send time. Every file must be a PDF the sender can read, attached to the
     * related record, and within the size cap. Throws DocGenException (catchable from Flow, unlike
     * AuraHandledException) with a message fit for the sender when anything is wrong — nothing is
     * created.
     */
    public static List<AttachmentSpec> resolveForSend(String relatedRecordId, List<String> ids, String position) {
        List<AttachmentSpec> specs = new List<AttachmentSpec>();
        if (ids == null || ids.isEmpty()) {
            return specs;
        }
        String pos = normalizePosition(position);
        if (String.isBlank(relatedRecordId)) {
            throw new DocGenException('Attached documents need a related record.');
        }

        List<Id> ordered = new List<Id>();
        Set<Id> seen = new Set<Id>();
        Set<Id> cvIds = new Set<Id>();
        Set<Id> cdIds = new Set<Id>();
        for (String raw : ids) {
            if (String.isBlank(raw)) {
                continue;
            }
            Id fileId;
            try {
                fileId = Id.valueOf(raw.trim());
            } catch (Exception e) {
                throw new DocGenException('"' + raw + '" is not a valid file Id.');
            }
            Schema.SObjectType t = fileId.getSobjectType();
            if (t == ContentVersion.sObjectType) {
                cvIds.add(fileId);
            } else if (t == ContentDocument.sObjectType) {
                cdIds.add(fileId);
            } else {
                throw new DocGenException('"' + raw + '" is not a file Id.');
            }
            if (seen.add(fileId)) {
                ordered.add(fileId);
            }
        }
        if (ordered.isEmpty()) {
            return specs;
        }
        if (ordered.size() > maxAttachments) {
            throw new DocGenException(
                'A signature request can carry at most ' + maxAttachments + ' attached documents.'
            );
        }

        // USER_MODE: the sender must be able to read every file they attach.
        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, Title, VersionNumber, ContentSize, FileExtension, Checksum
            FROM ContentVersion
            WHERE Id IN :cvIds OR (ContentDocumentId IN :cdIds AND IsLatest = TRUE)
            WITH USER_MODE
        ];
        Map<Id, ContentVersion> byVersion = new Map<Id, ContentVersion>();
        Map<Id, ContentVersion> latestByDocument = new Map<Id, ContentVersion>();
        Set<Id> documentIds = new Set<Id>();
        for (ContentVersion cv : versions) {
            byVersion.put(cv.Id, cv);
            if (cdIds.contains(cv.ContentDocumentId)) {
                latestByDocument.put(cv.ContentDocumentId, cv);
            }
            documentIds.add(cv.ContentDocumentId);
        }
        Set<Id> linked = new Set<Id>();
        if (!documentIds.isEmpty()) {
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :relatedRecordId AND ContentDocumentId IN :documentIds
                WITH USER_MODE
            ]) {
                linked.add(link.ContentDocumentId);
            }
        }

        Set<Id> usedDocuments = new Set<Id>();
        for (Id fileId : ordered) {
            ContentVersion cv = fileId.getSobjectType() == ContentVersion.sObjectType
                ? byVersion.get(fileId)
                : latestByDocument.get(fileId);
            if (cv == null) {
                throw new DocGenException('One of the selected files was not found, or you do not have access to it.');
            }
            if (!usedDocuments.add(cv.ContentDocumentId)) {
                continue; // the same file selected twice (e.g. by version and by document)
            }
            if (cv.FileExtension == null || !cv.FileExtension.equalsIgnoreCase('pdf')) {
                throw new DocGenException(
                    '"' + cv.Title + '" is not a PDF. Only PDF files can be attached for signing.'
                );
            }
            if (cv.ContentSize != null && cv.ContentSize > maxBytesPerAttachment) {
                throw new DocGenException(
                    '"' +
                        cv.Title +
                        '" is ' +
                        megabytes(cv.ContentSize) +
                        ' MB. Attached documents can be at most ' +
                        megabytes(maxBytesPerAttachment) +
                        ' MB each.'
                );
            }
            if (!linked.contains(cv.ContentDocumentId)) {
                throw new DocGenException('"' + cv.Title + '" is not attached to this record.');
            }
            AttachmentSpec spec = new AttachmentSpec();
            spec.contentVersionId = cv.Id;
            spec.contentDocumentId = cv.ContentDocumentId;
            spec.title = cv.Title;
            spec.versionNumber = cv.VersionNumber;
            spec.size = cv.ContentSize;
            spec.checksum = cv.Checksum;
            spec.position = pos;
            spec.sortOrder = specs.size();
            specs.add(spec);
        }
        return specs;
    }

    /**
     * Stores the pinned attachments on a request. Called inside the send transaction right after
     * the request is inserted and BEFORE signers are created and invited, so a failure here can
     * never leave a live, invited request without its attachments (whose absence would open the
     * approve gate).
     */
    public static List<DocGen_Signature_Attachment__c> createForRequest(Id requestId, List<AttachmentSpec> specs) {
        List<DocGen_Signature_Attachment__c> rows = new List<DocGen_Signature_Attachment__c>();
        if (requestId == null || specs == null || specs.isEmpty()) {
            return rows;
        }
        for (AttachmentSpec s : specs) {
            rows.add(
                new DocGen_Signature_Attachment__c(
                    Signature_Request__c = requestId,
                    Content_Version_Id__c = s.contentVersionId,
                    Content_Document_Id__c = s.contentDocumentId,
                    Title__c = s.title == null ? null : s.title.left(255),
                    Version_Number__c = s.versionNumber,
                    File_Size__c = s.size,
                    Platform_Checksum__c = s.checksum,
                    Position__c = s.position,
                    Sort_Order__c = s.sortOrder
                )
            );
        }
        if (failCreateForTest) {
            throw new DocGenException('Forced attachment failure');
        }
        DocGenFlsGuard.assertCreateable(rows, ATTACHMENT_FIELDS);
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Database.insert(rows, AccessLevel.SYSTEM_MODE);
        return rows;
    }

    /**
     * One review row per signer × attachment, once the signers exist. A missing row is
     * recreated on first serve (reviewFor) and the approve gate counts attachments, not rows,
     * so this step can't open the gate.
     */
    public static void createReviewRows(Id requestId, List<DocGen_Signature_Attachment__c> rows) {
        if (requestId == null || rows == null || rows.isEmpty()) {
            return;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Signer__c.sObjectType, new Set<String>{ 'Signature_Request__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Signer__c> signers = [
            SELECT Id
            FROM DocGen_Signer__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
        ];
        List<DocGen_Signer_Attachment__c> reviews = new List<DocGen_Signer_Attachment__c>();
        for (DocGen_Signer__c signer : signers) {
            for (DocGen_Signature_Attachment__c row : rows) {
                reviews.add(new DocGen_Signer_Attachment__c(Signer__c = signer.Id, Attachment__c = row.Id));
            }
        }
        if (!reviews.isEmpty()) {
            DocGenFlsGuard.assertCreateable(reviews, new Set<String>{ 'Signer__c', 'Attachment__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(reviews, AccessLevel.SYSTEM_MODE);
        }
    }

    // =====================================================================
    // SIGNER SIDE (guest, token-bound)
    // =====================================================================

    /** Does this request carry attachments? */
    public static Boolean requestHasAttachments(Id requestId) {
        return attachmentCount(requestId) > 0;
    }

    /**
     * The attachment manifest for one signer, in display order. Public-safe: index, title,
     * version, size, position, SHA-256 (once known) and when this signer opened it — never a
     * record or file Id.
     */
    public static List<Map<String, Object>> manifestForSigner(Id requestId, Id signerId) {
        List<Map<String, Object>> manifest = new List<Map<String, Object>>();
        if (requestId == null) {
            return manifest;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Attachment__c.sObjectType,
            new Set<String>{
                'Signature_Request__c',
                'Title__c',
                'Version_Number__c',
                'File_Size__c',
                'Position__c',
                'Sort_Order__c',
                'Sha256__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Attachment__c> rows = [
            SELECT Id, Title__c, Version_Number__c, File_Size__c, Position__c, Sort_Order__c, Sha256__c
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC
        ];
        if (rows.isEmpty()) {
            return manifest;
        }
        Map<Id, Datetime> viewedAt = new Map<Id, Datetime>();
        if (signerId != null) {
            DocGenFlsGuard.guestAssertAccessible(
                DocGen_Signer_Attachment__c.sObjectType,
                new Set<String>{ 'Signer__c', 'Attachment__c', 'Viewed_At__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            for (DocGen_Signer_Attachment__c review : [
                SELECT Attachment__c, Viewed_At__c
                FROM DocGen_Signer_Attachment__c
                WHERE Signer__c = :signerId
                WITH SYSTEM_MODE
            ]) {
                viewedAt.put(review.Attachment__c, review.Viewed_At__c);
            }
        }
        for (DocGen_Signature_Attachment__c row : rows) {
            Datetime viewed = viewedAt.get(row.Id);
            manifest.add(
                new Map<String, Object>{
                    'index' => row.Sort_Order__c == null ? 0 : row.Sort_Order__c.intValue(),
                    'title' => row.Title__c,
                    'version' => row.Version_Number__c,
                    'size' => row.File_Size__c == null ? 0 : row.File_Size__c.longValue(),
                    'position' => String.isBlank(row.Position__c) ? POSITION_BEFORE : row.Position__c,
                    'sha256' => row.Sha256__c,
                    'viewedAt' => viewed == null ? null : isoUtc(viewed)
                }
            );
        }
        return manifest;
    }

    /**
     * The approval register for the signed PDF: every attachment in order, with each signer who
     * opened it and when. Rides on the signature certificate, which already shows every signer's
     * name to each signer of the request. Empty when the request has no attachments.
     */
    /**
     * The register for a signer's own request, only once their link passes the full guest gate
     * (PIN verified when required, not expired, request still open) — the certificate endpoint
     * it rides on checks less. Empty otherwise.
     */
    public static List<Map<String, Object>> registerForToken(String token) {
        GuestResult gate = resolveSigner(token);
        if (gate.status != 200) {
            return new List<Map<String, Object>>();
        }
        return registerForRequest(gate.signer.Signature_Request__c);
    }

    public static List<Map<String, Object>> registerForRequest(Id requestId) {
        List<Map<String, Object>> register = manifestForSigner(requestId, null);
        if (register.isEmpty()) {
            return register;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer_Attachment__c.sObjectType,
            new Set<String>{ 'Signer__c', 'Attachment__c', 'Viewed_At__c' }
        );
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{ 'Signer_Name__c', 'Sort_Order__c' }
        );
        Map<Integer, List<Map<String, Object>>> openedByIndex = new Map<Integer, List<Map<String, Object>>>();
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        for (DocGen_Signer_Attachment__c review : [
            SELECT Viewed_At__c, Signer__r.Signer_Name__c, Attachment__r.Sort_Order__c
            FROM DocGen_Signer_Attachment__c
            WHERE Attachment__r.Signature_Request__c = :requestId AND Viewed_At__c != NULL
            WITH SYSTEM_MODE
            ORDER BY Signer__r.Sort_Order__c ASC, Viewed_At__c ASC
        ]) {
            Integer index = review.Attachment__r.Sort_Order__c == null
                ? 0
                : review.Attachment__r.Sort_Order__c.intValue();
            if (!openedByIndex.containsKey(index)) {
                openedByIndex.put(index, new List<Map<String, Object>>());
            }
            openedByIndex.get(index)
                .add(
                    new Map<String, Object>{
                        'name' => review.Signer__r.Signer_Name__c,
                        'at' => review.Viewed_At__c.format('MMMM d, yyyy h:mm a z')
                    }
                );
        }
        for (Map<String, Object> entry : register) {
            entry.remove('viewedAt');
            List<Map<String, Object>> openedBy = openedByIndex.get((Integer) entry.get('index'));
            entry.put('openedBy', openedBy == null ? new List<Map<String, Object>>() : openedBy);
        }
        return register;
    }

    /**
     * The path the signing page fetches attachments from: the Apex REST resource on the same
     * Site (same origin, so the browser sends no credentials and needs no CORS), namespace-aware.
     */
    public static String endpointPath() {
        String ns = DocGenSignatureAttachments.class.getName().substringBefore('.');
        Boolean namespaced = String.isNotBlank(ns) && ns != 'DocGenSignatureAttachments';
        String prefix = Site.getPathPrefix();
        return (String.isBlank(prefix) ? '' : prefix) +
            '/services/apexrest/' +
            (namespaced ? ns + '/' : '') +
            'signature-attachment';
    }

    /**
     * Token gate shared by every guest attachment operation — mirrors getSourcePdfBase64 and the
     * finalize endpoints: token shape, guest CRUD/FLS gate, token-keyed signer lookup, expiry,
     * terminal states, and the email-PIN check when the request requires it.
     */
    public static GuestResult resolveSigner(String token) {
        GuestResult r = new GuestResult();
        if (!DocGenSignatureGuestSecurity.isValidTokenShape(token)) {
            return fail(r, 400, 'Invalid security token.');
        }
        try {
            DocGenSignatureGuestSecurity.assertSignerReadable(token);
        } catch (Exception e) {
            return fail(r, 403, 'Invalid security token.');
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer__c.sObjectType,
            new Set<String>{
                'Status__c',
                'CreatedDate',
                'PIN_Verified_At__c',
                'Signature_Request__c',
                'Secure_Token__c'
            }
        );
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Request__c.sObjectType,
            new Set<String>{ 'Status__c', 'Expires_At__c', 'Require_Email_Verification__c', 'Related_Record_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer__c> signers = [
            SELECT
                Id,
                Status__c,
                CreatedDate,
                PIN_Verified_At__c,
                Signature_Request__c,
                Signature_Request__r.Status__c,
                Signature_Request__r.Expires_At__c,
                Signature_Request__r.Require_Email_Verification__c,
                Signature_Request__r.Related_Record_Id__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :token
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (signers.isEmpty()) {
            return fail(r, 403, 'This signing link is not valid.');
        }
        DocGen_Signer__c signer = signers[0];
        DocGen_Signature_Request__c req = signer.Signature_Request__r;
        if (req == null || DocGenSignatureExpiry.isExpired(req.Expires_At__c, signer.CreatedDate)) {
            return fail(r, 410, 'This signing link has expired.');
        }
        Set<String> closed = new Set<String>{ 'Signed', 'Cancelled', 'Declined' };
        if (closed.contains(req.Status__c) || closed.contains(signer.Status__c)) {
            return fail(r, 409, 'This signature request is no longer active.');
        }
        if (req.Require_Email_Verification__c != false && signer.PIN_Verified_At__c == null) {
            return fail(r, 403, 'Email verification is required before viewing attached documents.');
        }
        r.signer = signer;
        return r;
    }

    /**
     * Serves one attachment's bytes to the signer the token belongs to. Verifies the pinned
     * version is still there and unchanged (platform checksum), computes SHA-256, stores it on
     * first serve and refuses to serve bytes that no longer match it.
     */
    public static GuestResult serve(String token, Integer index) {
        GuestResult r = resolveSigner(token);
        if (r.status != 200) {
            return r;
        }
        if (index == null || index < 0) {
            return fail(r, 400, 'Missing or invalid attachment index.');
        }
        DocGen_Signature_Attachment__c row = attachmentAt(r.signer.Signature_Request__c, index);
        if (row == null) {
            return fail(r, 404, 'Attached document not found.');
        }
        DocGenFlsGuard.guestAssertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionData', 'Checksum', 'ContentSize', 'ContentDocumentId' }
        );
        // SYSTEM_MODE: the guest has no file access by design; the file served is the one pinned
        // on the token's own request, addressed by index — no client-supplied Id. The stored
        // pointer is re-verified before any bytes go out (privileged users can edit the rows): the
        // version must belong to the pinned document, still be linked to the request's related
        // record (the send-time rule), and match the checksum captured at send.
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<ContentVersion> versions = [
            SELECT VersionData, Checksum, ContentSize, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :row.Content_Version_Id__c
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        String unavailable = '"' + row.Title__c + '" is no longer available. Please contact the sender.';
        if (versions.isEmpty() || versions[0].ContentDocumentId != row.Content_Document_Id__c) {
            return fail(r, 410, unavailable);
        }
        ContentVersion cv = versions[0];
        if (!linkedToRecord(cv.ContentDocumentId, r.signer.Signature_Request__r.Related_Record_Id__c)) {
            return fail(r, 410, unavailable);
        }
        if (String.isBlank(row.Platform_Checksum__c) || cv.Checksum != row.Platform_Checksum__c) {
            return fail(r, 409, '"' + row.Title__c + '" has changed since it was sent. Please contact the sender.');
        }
        String sha = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', cv.VersionData));
        if (String.isNotBlank(row.Sha256__c) && row.Sha256__c != sha) {
            return fail(r, 409, '"' + row.Title__c + '" has changed since it was sent. Please contact the sender.');
        }
        if (String.isBlank(row.Sha256__c)) {
            row.Sha256__c = sha;
            DocGenFlsGuard.guestAssertUpdateable(row, new Set<String>{ 'Sha256__c' });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(row, false, AccessLevel.SYSTEM_MODE);
        }
        // Delivery evidence for this signer: Viewed At can only be recorded once the bytes went out.
        DocGen_Signer_Attachment__c review = reviewFor(r.signer.Id, row.Id);
        if (review.Fetched_At__c == null) {
            review.Fetched_At__c = System.now();
            saveReview(review, 'Fetched_At__c');
        }
        r.bytes = cv.VersionData;
        r.sha256 = sha;
        r.title = row.Title__c;
        return r;
    }

    /**
     * Records that the signer opened attachment [index] (the signing page calls this once the
     * attachment's first page has rendered). Refused until the file has been delivered to this
     * signer's link (serve), so "opened" always means the bytes reached them. Idempotent: the
     * first view time is kept.
     */
    public static Map<String, Object> markViewed(String token, Integer index) {
        GuestResult r = resolveSigner(token);
        if (r.status != 200) {
            return new Map<String, Object>{ 'success' => false, 'message' => r.error };
        }
        DocGen_Signature_Attachment__c row = index == null ? null : attachmentAt(r.signer.Signature_Request__c, index);
        if (row == null) {
            return new Map<String, Object>{ 'success' => false, 'message' => 'Attached document not found.' };
        }
        DocGen_Signer_Attachment__c review = reviewFor(r.signer.Id, row.Id);
        if (review.Fetched_At__c == null) {
            return new Map<String, Object>{
                'success' => false,
                'message' => 'Open the attached document before it can be marked as opened.'
            };
        }
        if (review.Viewed_At__c == null) {
            review.Viewed_At__c = System.now();
            saveReview(review, 'Viewed_At__c');
        }
        return new Map<String, Object>{
            'success' => true,
            'viewedAt' => isoUtc(review.Viewed_At__c),
            'remaining' => unviewedCount(r.signer.Id, r.signer.Signature_Request__c)
        };
    }

    // This signer's review row for one attachment; a new, unsaved row if the send-time row is
    // missing (e.g. a signer added after send).
    private static DocGen_Signer_Attachment__c reviewFor(Id signerId, Id attachmentId) {
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer_Attachment__c.sObjectType,
            new Set<String>{ 'Signer__c', 'Attachment__c', 'Viewed_At__c', 'Fetched_At__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signer_Attachment__c> reviews = [
            SELECT Id, Viewed_At__c, Fetched_At__c
            FROM DocGen_Signer_Attachment__c
            WHERE Signer__c = :signerId AND Attachment__c = :attachmentId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return reviews.isEmpty()
            ? new DocGen_Signer_Attachment__c(Signer__c = signerId, Attachment__c = attachmentId)
            : reviews[0];
    }

    private static void saveReview(DocGen_Signer_Attachment__c review, String field) {
        if (review.Id == null) {
            DocGenFlsGuard.guestAssertCreateable(review, new Set<String>{ 'Signer__c', 'Attachment__c', field });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.insert(review, AccessLevel.SYSTEM_MODE);
        } else {
            DocGenFlsGuard.guestAssertUpdateable(review, new Set<String>{ field });
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            Database.update(review, AccessLevel.SYSTEM_MODE);
        }
    }

    /**
     * Approve gate: null when the signer may finalize; otherwise a message for the signer. Counts
     * against the request's attachments (not just existing review rows) so a missing review row
     * can never read as "all opened".
     */
    public static String validateAllViewed(Id signerId, Id requestId) {
        Integer remaining = unviewedCount(signerId, requestId);
        if (remaining <= 0) {
            return null;
        }
        return 'Open every attached document before approving (' +
            remaining +
            ' not yet opened). Decline is still available.';
    }

    /**
     * Fallback gate: requests with attachments only finalize through the guided, client-composited
     * path (it renders the approval register). The server re-render fallbacks are refused for them.
     */
    public static String fallbackError(Id requestId) {
        if (!requestHasAttachments(requestId)) {
            return null;
        }
        return 'This request includes attached documents, so it must be signed on the document itself. ' +
            'Please reload the signing page and complete each field.';
    }

    // =====================================================================
    // HELPERS
    // =====================================================================

    @TestVisible
    private static Integer unviewedCount(Id signerId, Id requestId) {
        Integer total = attachmentCount(requestId);
        if (total == 0) {
            return 0;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signer_Attachment__c.sObjectType,
            new Set<String>{ 'Signer__c', 'Attachment__c', 'Viewed_At__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        // Distinct attachments, so a duplicated review row can't count one file twice.
        List<AggregateResult> agg = [
            SELECT COUNT_DISTINCT(Attachment__c) n
            FROM DocGen_Signer_Attachment__c
            WHERE Signer__c = :signerId AND Viewed_At__c != NULL AND Attachment__r.Signature_Request__c = :requestId
            WITH SYSTEM_MODE
        ];
        Integer viewed = agg.isEmpty() || agg[0].get('n') == null ? 0 : (Integer) agg[0].get('n');
        return Math.max(0, total - viewed);
    }

    public static Integer attachmentCount(Id requestId) {
        if (requestId == null) {
            return 0;
        }
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Attachment__c.sObjectType,
            new Set<String>{ 'Signature_Request__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        return [
            SELECT COUNT()
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c = :requestId
            WITH SYSTEM_MODE
        ];
    }

    private static Boolean linkedToRecord(Id contentDocumentId, String relatedRecordId) {
        if (contentDocumentId == null || String.isBlank(relatedRecordId)) {
            return false;
        }
        Id recordId;
        try {
            recordId = Id.valueOf(relatedRecordId);
        } catch (Exception e) {
            return false;
        }
        DocGenFlsGuard.guestAssertAccessible(
            ContentDocumentLink.sObjectType,
            new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        Integer links = [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :recordId
            WITH SYSTEM_MODE
        ];
        return links > 0;
    }

    private static DocGen_Signature_Attachment__c attachmentAt(Id requestId, Integer index) {
        DocGenFlsGuard.guestAssertAccessible(
            DocGen_Signature_Attachment__c.sObjectType,
            new Set<String>{
                'Signature_Request__c',
                'Sort_Order__c',
                'Content_Version_Id__c',
                'Content_Document_Id__c',
                'Platform_Checksum__c',
                'Sha256__c',
                'Title__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
        List<DocGen_Signature_Attachment__c> rows = [
            SELECT Id, Content_Version_Id__c, Content_Document_Id__c, Platform_Checksum__c, Sha256__c, Title__c
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c = :requestId AND Sort_Order__c = :index
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static String normalizePosition(String position) {
        if (String.isBlank(position) || position.trim().equalsIgnoreCase(POSITION_BEFORE)) {
            return POSITION_BEFORE;
        }
        if (position.trim().equalsIgnoreCase(POSITION_AFTER)) {
            return POSITION_AFTER;
        }
        throw new DocGenException('Attached document position must be Before or After.');
    }

    private static GuestResult fail(GuestResult r, Integer status, String message) {
        r.status = status;
        r.error = message;
        return r;
    }

    private static String megabytes(Long bytes) {
        return String.valueOf((Decimal.valueOf(bytes) / (1024 * 1024)).setScale(1));
    }

    private static String isoUtc(Datetime dt) {
        return dt == null ? null : dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
}

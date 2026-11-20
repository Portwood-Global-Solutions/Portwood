/**
 * #412 — existing record PDFs attached to a guided signature request:
 *   - send-side validation and pinning (sender controller + Flow action)
 *   - the guest surface: manifest, REST fetch, view tracking — token, PIN, expiry,
 *     terminal-state and index gates
 *   - the approve gate (every document opened, review confirmed), the refused server
 *     re-render fallbacks, and the register
 *   - Decline must stay available, and the org-wide limits
 */
@IsTest
private class DocGenSignatureAttachmentsTest {
    @TestSetup
    static void setup() {
        Account a = new Account(Name = 'Drawing Approval Co');
        insert a;
        insert new ContentVersion(
            Title = 'GA-001 General Arrangement',
            PathOnClient = 'GA-001.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 drawing one'),
            FirstPublishLocationId = a.Id
        );
        insert new ContentVersion(
            Title = 'GA-002 Sections',
            PathOnClient = 'GA-002.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 drawing two'),
            FirstPublishLocationId = a.Id
        );
        insert new ContentVersion(
            Title = 'Site photo',
            PathOnClient = 'photo.png',
            VersionData = Blob.valueOf('not a pdf'),
            FirstPublishLocationId = a.Id
        );
    }

    // ---------------------------------------------------------------- helpers

    // An approval template that takes attached documents (the template opts in).
    private static Id createTaggedTemplate() {
        return createTaggedTemplate('Optional');
    }

    private static Id createTaggedTemplate(String attachedDocuments) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Drawing Approval ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Attached_Documents__c = attachedDocuments
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(
                '<html><body><h1>{Name}</h1><p>Approved: {@Signature_Approver:1:Full}</p></body></html>'
            ),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        return tmpl.Id;
    }

    private static Account account() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    private static Id documentId(String title) {
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Title = :title AND IsLatest = TRUE LIMIT 1]
        .ContentDocumentId;
    }

    private static List<String> drawingIds() {
        return new List<String>{ documentId('GA-001 General Arrangement'), documentId('GA-002 Sections') };
    }

    private static String oneSigner() {
        return '[{"signerName":"Ada Approver","signerEmail":"ada@example.com","roleName":"Approver"}]';
    }

    private static String twoSigners() {
        return '[{"signerName":"Ada Approver","signerEmail":"ada@example.com","roleName":"Approver"},' +
            '{"signerName":"Ben Builder","signerEmail":"ben@example.com","roleName":"Approver"}]';
    }

    private static void send(Id tplId, String signers, List<String> ids, String position, Boolean requirePin) {
        DocGenSignatureSenderController.GuidedPdfSendOptions options = new DocGenSignatureSenderController.GuidedPdfSendOptions();
        options.templateId = tplId;
        options.relatedRecordId = account().Id;
        options.signersJson = signers;
        options.signingOrder = 'Parallel';
        options.requireVerification = requirePin;
        options.prefillSignerEmail = false;
        options.sendEmails = false;
        options.expirationDays = 7;
        options.attachedDocumentIds = ids;
        options.attachedDocumentPosition = position;
        DocGenSignatureSenderController.createGuidedPdfSignatureRequestV2(options);
    }

    private static DocGen_Signer__c signer(Id tplId) {
        return [
            SELECT Id, Secure_Token__c, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__r.Template__c = :tplId
            ORDER BY Sort_Order__c ASC
            LIMIT 1
        ];
    }

    private static void signAllPlacements(Id signerId) {
        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Id
            FROM DocGen_Signature_Placement__c
            WHERE Signer__c = :signerId
        ];
        for (DocGen_Signature_Placement__c p : plcs) {
            p.Status__c = 'Signed';
            p.Signed_Value__c = 'Ada Approver';
            p.Signed_At__c = System.now();
        }
        update plcs;
    }

    private static String expectSendError(Id tplId, List<String> ids, String position) {
        try {
            send(tplId, oneSigner(), ids, position, false);
        } catch (AuraHandledException e) {
            return e.getMessage();
        }
        Assert.fail('Expected the send to be refused');
        return null;
    }

    private static void hideDeclineOrgWide() {
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Hide_Decline__c = true;
        upsert settings;
    }

    private static DocGenSignatureController.SavePdfSignatureResult composite(String token) {
        return DocGenSignatureController.saveCompositedSignedPdf(
            token,
            EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 composited')),
            true,
            '1.2.3.4',
            'JUnit/1.0',
            '{}'
        );
    }

    // ------------------------------------------------------------- send side

    @IsTest
    static void send_pinsEachFileAndCreatesReviewRowsPerSigner() {
        Id tplId = createTaggedTemplate();
        Test.startTest();
        send(tplId, twoSigners(), drawingIds(), 'After', false);
        Test.stopTest();

        Id reqId = signer(tplId).Signature_Request__c;
        List<DocGen_Signature_Attachment__c> rows = [
            SELECT
                Title__c,
                Content_Version_Id__c,
                Content_Document_Id__c,
                Platform_Checksum__c,
                Position__c,
                Sort_Order__c,
                Sha256__c,
                File_Size__c,
                Version_Number__c
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c = :reqId
            ORDER BY Sort_Order__c
        ];
        Assert.areEqual(2, rows.size(), 'One row per attached file');
        Assert.areEqual('GA-001 General Arrangement', rows[0].Title__c, 'Selection order is kept');
        Assert.areEqual(0, rows[0].Sort_Order__c.intValue(), 'Index 0 first');
        Assert.areEqual(1, rows[1].Sort_Order__c.intValue(), 'Index 1 second');
        Assert.areEqual('After', rows[0].Position__c, 'Position stored');
        ContentVersion latest = [
            SELECT Id, Checksum
            FROM ContentVersion
            WHERE ContentDocumentId = :rows[0].Content_Document_Id__c AND IsLatest = TRUE
        ];
        Assert.areEqual(latest.Id, rows[0].Content_Version_Id__c, 'A document Id pins its latest version');
        Assert.areEqual(latest.Checksum, rows[0].Platform_Checksum__c, 'Platform checksum captured at send');
        Assert.isNull(rows[0].Sha256__c, 'SHA-256 is computed on first serve, not at send');
        Assert.isTrue(rows[0].File_Size__c > 0, 'Size captured');
        Assert.areEqual(
            4,
            [SELECT COUNT() FROM DocGen_Signer_Attachment__c WHERE Attachment__r.Signature_Request__c = :reqId],
            'One review row per signer per attachment'
        );
    }

    @IsTest
    static void send_contentVersionIdPinsThatVersionAndDuplicatesCollapse() {
        Id tplId = createTaggedTemplate();
        Id docId = documentId('GA-001 General Arrangement');
        Id v1 = [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :docId AND IsLatest = TRUE].Id;
        insert new ContentVersion(
            ContentDocumentId = docId,
            PathOnClient = 'GA-001.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 drawing one rev B')
        );
        Test.startTest();
        send(tplId, oneSigner(), new List<String>{ v1, docId, ' ' }, null, false);
        Test.stopTest();
        List<DocGen_Signature_Attachment__c> rows = [
            SELECT Content_Version_Id__c, Position__c
            FROM DocGen_Signature_Attachment__c
            WHERE Signature_Request__c = :signer(tplId).Signature_Request__c
        ];
        Assert.areEqual(1, rows.size(), 'The same document selected twice is attached once');
        Assert.areEqual(v1, rows[0].Content_Version_Id__c, 'A version Id pins exactly that version');
        Assert.areEqual('Before', rows[0].Position__c, 'Position defaults to Before');
    }

    @IsTest
    static void send_refusesBadSelections() {
        Id tplId = createTaggedTemplate();
        Account other = new Account(Name = 'Unrelated');
        insert other;
        ContentVersion foreign = new ContentVersion(
            Title = 'Other record drawing',
            PathOnClient = 'other.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 other'),
            FirstPublishLocationId = other.Id
        );
        insert foreign;

        Test.startTest();
        String notPdf = expectSendError(tplId, new List<String>{ documentId('Site photo') }, 'Before');
        String notLinked = expectSendError(tplId, new List<String>{ documentId('Other record drawing') }, 'Before');
        String badId = expectSendError(tplId, new List<String>{ 'not-an-id' }, 'Before');
        String wrongType = expectSendError(tplId, new List<String>{ account().Id }, 'Before');
        String badPosition = expectSendError(tplId, drawingIds(), 'Sideways');
        DocGenSignatureAttachments.maxAttachments = 1;
        String tooMany = expectSendError(tplId, drawingIds(), 'Before');
        DocGenSignatureAttachments.maxAttachments = null;
        DocGenSignatureAttachments.maxBytesPerAttachment = 5;
        String tooBig = expectSendError(tplId, drawingIds(), 'Before');
        DocGenSignatureAttachments.maxBytesPerAttachment = null;
        DocGenSignatureAttachments.maxBytesPerRequest = 25;
        String tooMuch = expectSendError(tplId, drawingIds(), 'Before');
        Test.stopTest();

        Assert.isTrue(notPdf.contains('is not a PDF'), notPdf);
        Assert.isTrue(notLinked.contains('not attached to this record'), notLinked);
        Assert.isTrue(badId.contains('not a valid file Id'), badId);
        Assert.isTrue(wrongType.contains('not a file Id'), wrongType);
        Assert.isTrue(badPosition.contains('Before or After'), badPosition);
        Assert.isTrue(tooMany.contains('at most 1'), tooMany);
        Assert.isTrue(tooBig.contains('MB each'), tooBig);
        Assert.isTrue(tooMuch.contains('MB of attached documents'), tooMuch);
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signature_Request__c], 'A refused send creates nothing');
    }

    @IsTest
    static void send_withoutAttachmentsBehavesAsBefore() {
        Id tplId = createTaggedTemplate();
        Test.startTest();
        send(tplId, oneSigner(), null, null, false);
        Test.stopTest();
        DocGen_Signer__c s = signer(tplId);
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signature_Attachment__c], 'No attachment rows');
        DocGenSignatureController.SignatureInitResponse init = DocGenSignatureController.validateToken(
            s.Secure_Token__c
        );
        Assert.areEqual(0, init.attachmentCount, 'Init reports no attachments');
        signAllPlacements(s.Id);
        Assert.isTrue(composite(s.Secure_Token__c).success, 'Signing is unchanged without attachments');
    }

    @IsTest
    static void getAttachableRecordPdfs_listsPdfsOnly() {
        DocGenSignatureAttachments.maxBytesPerAttachment = 10;
        List<Map<String, Object>> files = DocGenSignatureSenderController.getAttachableRecordPdfs(account().Id);
        Assert.areEqual(2, files.size(), 'Only the two PDFs');
        Assert.areEqual('GA-001 General Arrangement', files[0].get('title'), 'Sorted by title');
        Assert.isNotNull(files[0].get('contentVersionId'), 'Latest version reported');
        Assert.areEqual(true, files[0].get('tooLarge'), 'Over the cap is flagged, not hidden');
        Assert.areEqual(10L, files[0].get('maxBytes'), 'The limit is reported for the note');
        Assert.areEqual(0, DocGenSignatureSenderController.getAttachableRecordPdfs(null).size(), 'Null record');
    }

    @IsTest
    static void flowAction_passesAttachmentsAndReportsBadOnesAsErrors() {
        Id tplId = createTaggedTemplate();
        DocGenSigner s = new DocGenSigner();
        s.name = 'Ada Approver';
        s.email = 'ada@example.com';
        s.role = 'Approver';

        DocGenSignatureFlowAction.Request good = new DocGenSignatureFlowAction.Request();
        good.templateId = tplId;
        good.relatedRecordId = account().Id;
        good.signerRecords = new List<DocGenSigner>{ s };
        good.sendEmails = false;
        good.requireEmailVerification = false;
        good.attachedDocumentIds = drawingIds();
        good.attachedDocumentPosition = 'Before';

        DocGenSignatureFlowAction.Request bad = new DocGenSignatureFlowAction.Request();
        bad.templateId = tplId;
        bad.relatedRecordId = account().Id;
        bad.signerRecords = new List<DocGenSigner>{ s };
        bad.sendEmails = false;
        bad.requireEmailVerification = false;
        bad.attachedDocumentIds = new List<String>{ documentId('Site photo') };

        Test.startTest();
        DocGenSignatureFlowAction.Result okResult = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ good }
        )[0];
        DocGenSignatureFlowAction.Result badResult = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ bad }
        )[0];
        Test.stopTest();

        Assert.isTrue(okResult.success, 'Flow send failed: ' + okResult.errorMessage);
        Assert.areEqual(
            2,
            [
                SELECT COUNT()
                FROM DocGen_Signature_Attachment__c
                WHERE Signature_Request__c = :okResult.signatureRequestId
            ],
            'Flow-sent attachments stored'
        );
        Assert.isFalse(badResult.success, 'A bad attachment is reported, not thrown');
        Assert.isTrue(badResult.errorMessage.contains('is not a PDF'), badResult.errorMessage);
    }

    // ------------------------------------------------------------ guest side

    @IsTest
    static void manifest_isPublicSafeAndPinGated() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', true);
        DocGen_Signer__c s = signer(tplId);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse init = DocGenSignatureController.validateToken(
            s.Secure_Token__c
        );
        Map<String, Object> beforePin = DocGenSignatureController.getAttachmentManifest(s.Secure_Token__c);
        s.PIN_Verified_At__c = System.now();
        update s;
        Map<String, Object> afterPin = DocGenSignatureController.getAttachmentManifest(s.Secure_Token__c);
        Map<String, Object> badToken = DocGenSignatureController.getAttachmentManifest('zz');
        Test.stopTest();

        Assert.areEqual(2, init.attachmentCount, 'Init carries only the count');
        Assert.areEqual(false, beforePin.get('success'), 'No manifest before the email PIN check');
        Assert.areEqual(true, afterPin.get('success'), 'Manifest after the PIN check');
        Assert.isTrue(((String) afterPin.get('endpoint')).endsWith('signature-attachment'), 'REST path returned');
        List<Map<String, Object>> entries = (List<Map<String, Object>>) afterPin.get('attachments');
        Assert.areEqual(2, entries.size(), 'Both attachments listed');
        Assert.areEqual(
            new Set<String>{ 'index', 'title', 'version', 'size', 'position', 'sha256', 'viewedAt' },
            entries[0].keySet(),
            'Manifest exposes no record or file Id'
        );
        Assert.areEqual(false, badToken.get('success'), 'Malformed token refused');
    }

    @IsTest
    static void serve_streamsBytesStoresHashAndRefusesChangedFiles() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/signature-attachment';
        req.httpMethod = 'GET';
        req.addHeader('x-portwood-token', s.Secure_Token__c); // lower-case, as HTTP/2 sends it
        req.addParameter('index', '0');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        DocGenSignatureAttachmentRest.fetchAttachment();
        RestResponse ok = RestContext.response;

        DocGen_Signature_Attachment__c row = [
            SELECT Id, Sha256__c, Platform_Checksum__c
            FROM DocGen_Signature_Attachment__c
            WHERE Sort_Order__c = 0
        ];
        String storedSha = row.Sha256__c;
        String expected = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf('%PDF-1.4 drawing one'))
        );

        // Second index; then out of range; then a "changed" file.
        DocGenSignatureAttachments.GuestResult second = DocGenSignatureAttachments.serve(s.Secure_Token__c, 1);
        DocGenSignatureAttachments.GuestResult missing = DocGenSignatureAttachments.serve(s.Secure_Token__c, 2);
        DocGenSignatureAttachments.GuestResult negative = DocGenSignatureAttachments.serve(s.Secure_Token__c, -1);
        row.Sha256__c = 'f'.repeat(64);
        update row;
        DocGenSignatureAttachments.GuestResult tampered = DocGenSignatureAttachments.serve(s.Secure_Token__c, 0);
        row.Sha256__c = expected;
        row.Platform_Checksum__c = 'deadbeef';
        update row;
        DocGenSignatureAttachments.GuestResult replaced = DocGenSignatureAttachments.serve(s.Secure_Token__c, 0);
        Test.stopTest();

        Assert.areEqual(200, ok.statusCode, 'Served');
        Assert.areEqual('%PDF-1.4 drawing one', ok.responseBody.toString(), 'Raw bytes, not base64');
        Assert.areEqual('application/pdf', ok.headers.get('Content-Type'), 'PDF content type');
        Assert.areEqual(expected, ok.headers.get('X-Portwood-Sha256'), 'Hash sent for the client check');
        Assert.areEqual('no-store', ok.headers.get('Cache-Control'), 'Never cached');
        Assert.areEqual(expected, storedSha, 'Hash stored on first serve');
        Assert.areEqual(200, second.status, 'Second attachment served');
        Assert.areEqual(404, missing.status, 'Index past the end');
        Assert.areEqual(400, negative.status, 'Negative index');
        Assert.areEqual(409, tampered.status, 'Bytes no longer matching the stored hash are refused');
        Assert.areEqual(409, replaced.status, 'A changed platform checksum is refused');
    }

    @IsTest
    static void serve_tokenExpiryAndTerminalGates() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', true);
        DocGen_Signer__c s = signer(tplId);
        String token = s.Secure_Token__c;

        Test.startTest();
        Integer badShape = DocGenSignatureAttachments.serve('nope', 0).status;
        Integer unknown = DocGenSignatureAttachments.serve('a'.repeat(64), 0).status;
        Integer needsPin = DocGenSignatureAttachments.serve(token, 0).status;
        s.PIN_Verified_At__c = System.now();
        update s;
        Integer verified = DocGenSignatureAttachments.serve(token, 0).status;
        DocGen_Signature_Request__c r = new DocGen_Signature_Request__c(
            Id = s.Signature_Request__c,
            Expires_At__c = System.now().addDays(-1)
        );
        update r;
        Integer expired = DocGenSignatureAttachments.serve(token, 0).status;
        r.Expires_At__c = System.now().addDays(1);
        r.Status__c = 'Cancelled';
        update r;
        Integer cancelled = DocGenSignatureAttachments.serve(token, 0).status;
        Test.stopTest();

        Assert.areEqual(400, badShape, 'Malformed token');
        Assert.areEqual(403, unknown, 'Unknown token');
        Assert.areEqual(403, needsPin, 'Email PIN required first');
        Assert.areEqual(200, verified, 'Served once verified');
        Assert.areEqual(410, expired, 'Expired link');
        Assert.areEqual(409, cancelled, 'Closed request');
    }

    @IsTest
    static void rest_reportsErrorsAsJson() {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/signature-attachment';
        req.httpMethod = 'GET';
        req.addParameter('index', 'abc');
        RestContext.request = req;
        RestContext.response = new RestResponse();
        DocGenSignatureAttachmentRest.fetchAttachment();
        Assert.areEqual(400, RestContext.response.statusCode, 'No token header');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString()
        );
        Assert.isNotNull(body.get('error'), 'Error message returned');
        Assert.isNull(DocGenSignatureAttachmentRest.header(null, 'X-Portwood-Token'), 'Null request');
    }

    @IsTest
    static void approveGate_requiresEveryAttachmentOpened_thenRegisters() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        signAllPlacements(s.Id);

        Test.startTest();
        DocGenSignatureController.SavePdfSignatureResult blocked = composite(s.Secure_Token__c);
        Map<String, Object> unfetched = DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 0);
        DocGenSignatureAttachments.serve(s.Secure_Token__c, 0); // delivers the bytes to this signer
        Map<String, Object> first = DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 0);
        Datetime firstAt = [SELECT Viewed_At__c FROM DocGen_Signer_Attachment__c WHERE Attachment__r.Sort_Order__c = 0]
        .Viewed_At__c;
        Map<String, Object> again = DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 0);
        Map<String, Object> outOfRange = DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 9);
        DocGenSignatureController.SavePdfSignatureResult stillBlocked = composite(s.Secure_Token__c);
        DocGenSignatureAttachments.serve(s.Secure_Token__c, 1); // stores the SHA-256
        Map<String, Object> second = DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 1);
        DocGenSignatureController.confirmAttachmentsReviewed(s.Secure_Token__c);
        Map<String, Object> cert = DocGenSignatureController.getSignatureCertificate(s.Secure_Token__c);
        DocGenSignatureController.SavePdfSignatureResult approved = composite(s.Secure_Token__c);
        Test.stopTest();

        Assert.isFalse(blocked.success, 'Approval refused with nothing opened');
        Assert.areEqual(false, unfetched.get('success'), 'Cannot claim to have opened a file never delivered');
        Assert.isTrue(blocked.message.contains('2 not yet opened'), blocked.message);
        Assert.areEqual(true, first.get('success'), 'View recorded');
        Assert.areEqual(1, first.get('remaining'), 'One left');
        Assert.areEqual(true, again.get('success'), 'Idempotent');
        Assert.areEqual(
            firstAt,
            [SELECT Viewed_At__c FROM DocGen_Signer_Attachment__c WHERE Attachment__r.Sort_Order__c = 0].Viewed_At__c,
            'First view time kept'
        );
        Assert.areEqual(false, outOfRange.get('success'), 'Unknown index refused');
        Assert.isTrue(stillBlocked.message.contains('1 not yet opened'), stillBlocked.message);
        Assert.areEqual(0, second.get('remaining'), 'All opened');

        List<Object> register = (List<Object>) cert.get('attachments');
        Assert.areEqual(2, register.size(), 'Register lists both');
        Map<String, Object> entry = (Map<String, Object>) register[1];
        Assert.isNotNull(entry.get('sha256'), 'Served attachment carries its hash');
        List<Object> openedBy = (List<Object>) entry.get('openedBy');
        Assert.areEqual(1, openedBy.size(), 'Opened by the signer');
        Assert.areEqual('Ada Approver', ((Map<String, Object>) openedBy[0]).get('name'), 'Signer named');
        Assert.isFalse(entry.containsKey('viewedAt'), 'Register uses openedBy, not the per-signer field');

        Assert.isTrue(approved.success, 'Approval failed: ' + approved.message);
        Assert.areEqual(
            'Signed',
            [SELECT Status__c FROM DocGen_Signature_Request__c WHERE Id = :s.Signature_Request__c].Status__c,
            'Request completes once every attachment was opened'
        );
    }

    @IsTest
    static void serverFallbacksAreRefusedButDeclineWorks() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        signAllPlacements(s.Id);

        Test.startTest();
        DocGenSignatureController.SaveSignatureResult reRender = DocGenSignatureController.saveSignature(
            s.Secure_Token__c,
            'Ada Approver',
            true,
            '1.2.3.4',
            'JUnit/1.0',
            '{}'
        );
        DocGenSignatureController.SavePdfSignatureResult flat = DocGenSignatureController.savePdfSignature(
            s.Secure_Token__c,
            'Ada Approver',
            true,
            '1.2.3.4',
            'JUnit/1.0',
            '{}'
        );
        Map<String, Object> declined = DocGenSignatureController.declineSignature(
            s.Secure_Token__c,
            'Section B-B is wrong',
            '1.2.3.4',
            'JUnit/1.0'
        );
        Test.stopTest();

        Assert.isFalse(reRender.success, 'Server re-render refused');
        Assert.isTrue(reRender.message.contains('attached documents'), reRender.message);
        Assert.isFalse(flat.success, 'Flat typed-name path refused');
        Assert.isTrue(flat.message.contains('attached documents'), flat.message);
        Assert.areEqual(true, declined.get('success'), 'Decline needs no attachment to be opened');
    }

    @IsTest
    static void markViewed_isScopedToTheTokensOwnRequest() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        send(tplId, oneSigner(), new List<String>{ documentId('GA-002 Sections') }, 'Before', false);
        List<DocGen_Signer__c> signers = [
            SELECT Id, Secure_Token__c, Signature_Request__c
            FROM DocGen_Signer__c
            ORDER BY CreatedDate ASC, Id ASC
        ];
        Assert.areEqual(2, signers.size(), 'Two requests');

        Test.startTest();
        // Index 1 exists only on the first request; the second signer's token can't reach it.
        Map<String, Object> cross = DocGenSignatureController.markAttachmentViewed(signers[1].Secure_Token__c, 1);
        Test.stopTest();

        Assert.areEqual(false, cross.get('success'), 'Another request\'s attachment is unreachable');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM DocGen_Signer_Attachment__c WHERE Viewed_At__c != NULL],
            'Nothing marked'
        );
    }

    // ------------------------------------------------- security review fixes

    @IsTest
    static void certificate_withholdsRegisterUntilPinVerified() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', true);
        DocGen_Signer__c s = signer(tplId);

        Test.startTest();
        List<Object> beforePin = (List<Object>) DocGenSignatureController.getSignatureCertificate(s.Secure_Token__c)
            .get('attachments');
        s.PIN_Verified_At__c = System.now();
        update s;
        List<Object> afterPin = (List<Object>) DocGenSignatureController.getSignatureCertificate(s.Secure_Token__c)
            .get('attachments');
        Test.stopTest();

        Assert.areEqual(0, beforePin.size(), 'No register before the email PIN check');
        Assert.areEqual(2, afterPin.size(), 'Register once verified');
    }

    @IsTest
    static void serve_reverifiesThePinnedFileBeforeSendingBytes() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        DocGen_Signature_Attachment__c first = [
            SELECT Id, Content_Version_Id__c, Content_Document_Id__c, Platform_Checksum__c
            FROM DocGen_Signature_Attachment__c
            WHERE Sort_Order__c = 0
        ];
        DocGen_Signature_Attachment__c second = [
            SELECT Id, Content_Document_Id__c
            FROM DocGen_Signature_Attachment__c
            WHERE Sort_Order__c = 1
        ];
        Account other = new Account(Name = 'Elsewhere');
        insert other;
        ContentVersion foreign = new ContentVersion(
            Title = 'Not on this record',
            PathOnClient = 'foreign.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 foreign'),
            FirstPublishLocationId = other.Id
        );
        insert foreign;
        foreign = [SELECT Id, ContentDocumentId, Checksum FROM ContentVersion WHERE Id = :foreign.Id];

        Test.startTest();
        // Blank checksum → fail closed.
        update new DocGen_Signature_Attachment__c(Id = first.Id, Platform_Checksum__c = null);
        Integer blankChecksum = DocGenSignatureAttachments.serve(s.Secure_Token__c, 0).status;
        // Version re-pointed to another document's version → refused.
        update new DocGen_Signature_Attachment__c(
            Id = first.Id,
            Platform_Checksum__c = first.Platform_Checksum__c,
            Content_Version_Id__c = foreign.Id
        );
        Integer wrongDocument = DocGenSignatureAttachments.serve(s.Secure_Token__c, 0).status;
        // Whole pointer re-aimed at a file that isn't linked to the request's record → refused.
        update new DocGen_Signature_Attachment__c(
            Id = first.Id,
            Content_Document_Id__c = foreign.ContentDocumentId,
            Platform_Checksum__c = foreign.Checksum
        );
        Integer notLinked = DocGenSignatureAttachments.serve(s.Secure_Token__c, 0).status;
        // A file unlinked from the record after send is no longer served.
        delete [
            SELECT Id
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :second.Content_Document_Id__c AND LinkedEntityId = :account().Id
        ];
        Integer unlinked = DocGenSignatureAttachments.serve(s.Secure_Token__c, 1).status;
        Test.stopTest();

        Assert.areEqual(409, blankChecksum, 'A blank checksum fails closed');
        Assert.areEqual(410, wrongDocument, 'A version from another document is refused');
        Assert.areEqual(410, notLinked, 'A file not linked to the related record is refused');
        Assert.areEqual(410, unlinked, 'A file unlinked after send is refused');
    }

    @IsTest
    static void flowAction_failedSendCommitsNothing() {
        Id tplId = createTaggedTemplate();
        DocGenSigner sg = new DocGenSigner();
        sg.name = 'Ada Approver';
        sg.email = 'ada@example.com';
        sg.role = 'Approver';
        DocGenSignatureFlowAction.Request req = new DocGenSignatureFlowAction.Request();
        req.templateId = tplId;
        req.relatedRecordId = account().Id;
        req.signerRecords = new List<DocGenSigner>{ sg };
        req.sendEmails = false;
        req.requireEmailVerification = false;
        req.attachedDocumentIds = drawingIds();

        Test.startTest();
        DocGenSignatureAttachments.failCreateForTest = true;
        DocGenSignatureFlowAction.Result r = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ req }
        )[0];
        Test.stopTest();

        Assert.isFalse(r.success, 'Reported as failed');
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signature_Request__c], 'No request left behind');
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signer__c], 'No signer left behind');
    }

    @IsTest
    static void cancelledSignerAndDuplicateReviewRowsDontOpenTheGate() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        signAllPlacements(s.Id);
        DocGen_Signature_Attachment__c first = [
            SELECT Id
            FROM DocGen_Signature_Attachment__c
            WHERE Sort_Order__c = 0
        ];

        Test.startTest();
        DocGenSignatureAttachments.serve(s.Secure_Token__c, 0);
        DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 0);
        // A duplicate (signer, attachment) row, also viewed, must not count as the second file.
        insert new DocGen_Signer_Attachment__c(
            Signer__c = s.Id,
            Attachment__c = first.Id,
            Fetched_At__c = System.now(),
            Viewed_At__c = System.now()
        );
        DocGenSignatureController.SavePdfSignatureResult blocked = composite(s.Secure_Token__c);
        update new DocGen_Signer__c(Id = s.Id, Status__c = 'Cancelled');
        Integer cancelled = DocGenSignatureAttachments.serve(s.Secure_Token__c, 1).status;
        Test.stopTest();

        Assert.isFalse(blocked.success, 'One file opened twice is still one file');
        Assert.isTrue(blocked.message.contains('1 not yet opened'), blocked.message);
        Assert.areEqual(409, cancelled, 'A cancelled signer is closed');
    }

    @IsTest
    static void requestTokenSubmitPathIsRefusedForAttachmentRequests() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        String requestToken = [
            SELECT Secure_Token__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :signer(tplId).Signature_Request__c
        ]
        .Secure_Token__c;

        Test.startTest();
        String message;
        try {
            DocGenSignatureService.handleSignatureSubmission(requestToken, 'Ada Approver');
        } catch (Exception e) {
            message = e.getMessage();
        }
        Test.stopTest();

        Assert.isNotNull(message, 'Refused');
        Assert.isTrue(message.contains('attached documents'), message);
    }

    @IsTest
    static void rest_setsFileHeadersAndSafeName() {
        Assert.areEqual(
            'GA-001 _ rev_B_',
            DocGenSignatureAttachmentRest.safeFileName('GA-001 / rev"B"'),
            'Unsafe chars'
        );
        Assert.areEqual('document', DocGenSignatureAttachmentRest.safeFileName(null), 'Default name');
    }

    // ------------------------------------------------------ template opt-in

    @IsTest
    static void template_offRefusesAttachments_requiredRefusesNone() {
        Id offTpl = createTaggedTemplate('Off');
        Id requiredTpl = createTaggedTemplate('Required');
        DocGen_Template__c blank = new DocGen_Template__c(Id = createTaggedTemplate('Off'));
        blank.Attached_Documents__c = null;
        update blank;

        Test.startTest();
        String offMessage = expectSendError(offTpl, drawingIds(), 'Before');
        String blankMessage = expectSendError(blank.Id, drawingIds(), 'Before');
        String requiredMessage = expectSendError(requiredTpl, null, null);
        send(requiredTpl, oneSigner(), drawingIds(), 'Before', false); // Required + attachments: fine
        send(offTpl, oneSigner(), null, null, false); // Off + none: today's behaviour
        Test.stopTest();

        Assert.isTrue(offMessage.contains('does not take attached documents'), offMessage);
        Assert.isTrue(blankMessage.contains('does not take attached documents'), 'Blank means Off: ' + blankMessage);
        Assert.isTrue(requiredMessage.contains('requires at least one attached document'), requiredMessage);
        Assert.areEqual(2, [SELECT COUNT() FROM DocGen_Signature_Request__c], 'Only the two valid sends');
    }

    @IsTest
    static void template_ruleAppliesToFlowAndPackets() {
        Id requiredTpl = createTaggedTemplate('Required');
        Id offTpl = createTaggedTemplate('Off');
        DocGenSigner s = new DocGenSigner();
        s.name = 'Ada Approver';
        s.email = 'ada@example.com';
        s.role = 'Approver';
        DocGenSignatureFlowAction.Request noDrawings = new DocGenSignatureFlowAction.Request();
        noDrawings.templateId = requiredTpl;
        noDrawings.relatedRecordId = account().Id;
        noDrawings.signerRecords = new List<DocGenSigner>{ s };
        noDrawings.sendEmails = false;
        noDrawings.requireEmailVerification = false;

        Test.startTest();
        DocGenSignatureFlowAction.Result flowResult = DocGenSignatureFlowAction.generate(
            new List<DocGenSignatureFlowAction.Request>{ noDrawings }
        )[0];
        String packetMessage;
        try {
            DocGenSignatureSenderController.createGuidedPacketSignatureRequest(
                JSON.serialize(new List<Id>{ offTpl, requiredTpl }),
                account().Id,
                oneSigner(),
                'Parallel',
                null
            );
        } catch (AuraHandledException e) {
            packetMessage = e.getMessage();
        }
        Test.stopTest();

        Assert.isFalse(flowResult.success, 'Flow send of a Required template without attachments is refused');
        Assert.isTrue(flowResult.errorMessage.contains('requires at least one'), flowResult.errorMessage);
        Assert.isNotNull(packetMessage, 'A packet with a Required template is refused');
        Assert.isTrue(packetMessage.contains('must be sent on its own'), packetMessage);
        Assert.areEqual(0, [SELECT COUNT() FROM DocGen_Signature_Request__c], 'Nothing created');
    }

    @IsTest
    static void templateEditor_savesAttachedDocuments_andListsIt() {
        Id tplId = createTaggedTemplate('Off');
        Test.startTest();
        DocGenController.saveTemplate(
            new Map<String, Object>{
                'Id' => tplId,
                'Name' => 'Drawing Approval',
                'Type__c' => 'HTML',
                'Base_Object_API__c' => 'Account',
                'Query_Config__c' => 'Name',
                'Attached_Documents__c' => 'Required'
            },
            false,
            null
        );
        List<DocGen_Template__c> forSender = DocGenSignatureSenderController.getDocGenTemplatesForRecord(account().Id);
        Test.stopTest();
        Assert.areEqual(
            'Required',
            [SELECT Attached_Documents__c FROM DocGen_Template__c WHERE Id = :tplId].Attached_Documents__c,
            'Editor save persists the setting'
        );
        Boolean listed = false;
        for (DocGen_Template__c t : forSender) {
            if (t.Id == tplId) {
                listed = t.Attached_Documents__c == 'Required';
            }
        }
        Assert.isTrue(listed, 'The sender reads the setting with the template list');
    }

    // ------------------------------------------------- review confirmation

    @IsTest
    static void approveGate_requiresReviewConfirmation_andRegistersIt() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), new List<String>{ documentId('GA-001 General Arrangement') }, 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        signAllPlacements(s.Id);

        Test.startTest();
        Map<String, Object> early = DocGenSignatureController.confirmAttachmentsReviewed(s.Secure_Token__c);
        DocGenSignatureAttachments.serve(s.Secure_Token__c, 0);
        DocGenSignatureController.markAttachmentViewed(s.Secure_Token__c, 0);
        DocGenSignatureController.SavePdfSignatureResult unconfirmed = composite(s.Secure_Token__c);
        Map<String, Object> confirmed = DocGenSignatureController.confirmAttachmentsReviewed(s.Secure_Token__c);
        Datetime firstAt = [SELECT Attachments_Reviewed_At__c FROM DocGen_Signer__c WHERE Id = :s.Id]
        .Attachments_Reviewed_At__c;
        Map<String, Object> again = DocGenSignatureController.confirmAttachmentsReviewed(s.Secure_Token__c);
        List<Object> reviews = (List<Object>) DocGenSignatureController.getSignatureCertificate(s.Secure_Token__c)
            .get('attachmentReviews');
        DocGenSignatureController.SavePdfSignatureResult approved = composite(s.Secure_Token__c);
        Test.stopTest();

        Assert.areEqual(false, early.get('success'), 'No confirmation before every document is opened');
        Assert.isTrue(((String) early.get('message')).contains('not yet opened'), (String) early.get('message'));
        Assert.isFalse(unconfirmed.success, 'Opening alone does not approve');
        Assert.isTrue(unconfirmed.message.contains('Confirm that you have reviewed'), unconfirmed.message);
        Assert.areEqual(true, confirmed.get('success'), 'Confirmation recorded');
        Assert.isNotNull(confirmed.get('reviewedAt'), 'Confirmation time returned');
        Assert.areEqual(true, again.get('success'), 'Idempotent');
        Assert.areEqual(
            firstAt,
            [SELECT Attachments_Reviewed_At__c FROM DocGen_Signer__c WHERE Id = :s.Id].Attachments_Reviewed_At__c,
            'First confirmation time kept'
        );
        Assert.areEqual(1, reviews.size(), 'Register lists the confirmation');
        Assert.areEqual('Ada Approver', ((Map<String, Object>) reviews[0]).get('name'), 'Signer named');
        Assert.isTrue(approved.success, 'Approval failed: ' + approved.message);
    }

    @IsTest
    static void confirmReviewed_isGatedAndNeedsAttachments() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', true);
        DocGen_Signer__c pinSigner = signer(tplId);
        Id plainTpl = createTaggedTemplate();
        send(plainTpl, oneSigner(), null, null, false);
        DocGen_Signer__c plainSigner = signer(plainTpl);

        Test.startTest();
        Map<String, Object> beforePin = DocGenSignatureController.confirmAttachmentsReviewed(pinSigner.Secure_Token__c);
        List<Object> reviewsBeforePin = (List<Object>) DocGenSignatureController.getSignatureCertificate(
                pinSigner.Secure_Token__c
            )
            .get('attachmentReviews');
        Map<String, Object> noAttachments = DocGenSignatureController.confirmAttachmentsReviewed(
            plainSigner.Secure_Token__c
        );
        Map<String, Object> badToken = DocGenSignatureController.confirmAttachmentsReviewed('nope');
        Test.stopTest();

        Assert.areEqual(false, beforePin.get('success'), 'PIN gate applies');
        Assert.areEqual(0, reviewsBeforePin.size(), 'No confirmations before the PIN check');
        Assert.areEqual(false, noAttachments.get('success'), 'Nothing to confirm without attachments');
        Assert.areEqual(false, badToken.get('success'), 'Bad token refused');
        Assert.areEqual(
            0,
            [SELECT COUNT() FROM DocGen_Signer__c WHERE Attachments_Reviewed_At__c != NULL],
            'Nothing recorded'
        );
    }

    // ------------------------------------------------------------- decline

    @IsTest
    static void send_refusedWhileDeclineIsHidden() {
        Id tplId = createTaggedTemplate();
        DocGen_Template__c hiding = new DocGen_Template__c(Id = createTaggedTemplate(), Hide_Signer_Decline__c = true);
        update hiding;

        Test.startTest();
        String templateMessage = expectSendError(hiding.Id, drawingIds(), 'Before');
        send(hiding.Id, oneSigner(), null, null, false); // no attachments: Hide Decline works as before
        hideDeclineOrgWide();
        String orgMessage = expectSendError(tplId, drawingIds(), 'Before');
        Test.stopTest();

        Assert.isTrue(templateMessage.contains('Hide Decline on this template'), templateMessage);
        Assert.isTrue(orgMessage.contains('Hide Decline Button in Signature Settings'), orgMessage);
        Assert.areEqual(1, [SELECT COUNT() FROM DocGen_Signature_Request__c], 'Only the send without attachments');
    }

    @IsTest
    static void declineStaysAvailableIfHiddenAfterSend() {
        Id tplId = createTaggedTemplate();
        send(tplId, oneSigner(), drawingIds(), 'Before', false);
        DocGen_Signer__c s = signer(tplId);
        hideDeclineOrgWide();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse init = DocGenSignatureController.validateToken(
            s.Secure_Token__c
        );
        Map<String, Object> declined = DocGenSignatureController.declineSignature(
            s.Secure_Token__c,
            'Wrong revision',
            '1.2.3.4',
            'JUnit/1.0'
        );
        Test.stopTest();

        Assert.isTrue(init.showDecline, 'A request with attached documents always offers Decline');
        Assert.areEqual(true, declined.get('success'), 'And the server accepts it');
    }

    // -------------------------------------------------------------- limits

    @IsTest
    static void limits_comeFromSettingsWithDefaults() {
        Map<String, Integer> defaults = DocGenSignatureAttachments.limitSettings();
        Long defaultFileBytes = DocGenSignatureAttachments.maxBytesPerFile();
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        settings.Signature_Attachment_Max_Files__c = 1;
        settings.Signature_Attachment_Max_File_MB__c = 5;
        settings.Signature_Attachment_Max_Total_MB__c = 0; // out of range: the default applies
        upsert settings;
        Id tplId = createTaggedTemplate();

        Test.startTest();
        String tooMany = expectSendError(tplId, drawingIds(), 'Before');
        Test.stopTest();

        Assert.areEqual(100, defaults.get('maxFiles'), 'Default files');
        Assert.areEqual(20, defaults.get('maxFileMb'), 'Default MB per file');
        Assert.areEqual(200, defaults.get('maxTotalMb'), 'Default total MB');
        Assert.areEqual(20L * 1024 * 1024, defaultFileBytes, 'Default bytes per file');
        Assert.areEqual(1, DocGenSignatureAttachments.maxFiles(), 'Setting applies');
        Assert.areEqual(5L * 1024 * 1024, DocGenSignatureAttachments.maxBytesPerFile(), 'MB setting applies');
        Assert.areEqual(200L * 1024 * 1024, DocGenSignatureAttachments.maxBytesTotal(), 'Out of range: default');
        Assert.isTrue(tooMany.contains('at most 1 attached'), tooMany);
    }

    @IsTest
    static void saveAttachmentLimits_validatesAndStores() {
        Test.startTest();
        DocGenSetupController.saveAttachmentLimits(10, 50, 150);
        Map<String, Object> saved = DocGenSetupController.getSettingsFresh();
        List<String> refusals = new List<String>();
        for (
            List<Integer> bad : new List<List<Integer>>{
                new List<Integer>{ 0, 50, 150 },
                new List<Integer>{ 10, 201, 150 },
                new List<Integer>{ 51, 50, 150 },
                new List<Integer>{ 30, 50, 20 }
            }
        ) {
            try {
                DocGenSetupController.saveAttachmentLimits(bad[0], bad[1], bad[2]);
                refusals.add(null);
            } catch (AuraHandledException e) {
                refusals.add(e.getMessage());
            }
        }
        DocGenSetupController.saveAttachmentLimits(null, null, null);
        Map<String, Object> cleared = DocGenSetupController.getSettingsFresh();
        Test.stopTest();

        Assert.areEqual(10, saved.get('Signature_Attachment_Max_File_MB__c'), 'MB per file saved');
        Assert.areEqual(50, saved.get('Signature_Attachment_Max_Files__c'), 'Files saved');
        Assert.areEqual(150, saved.get('Signature_Attachment_Max_Total_MB__c'), 'Total saved');
        Assert.isTrue(refusals[0].contains('from 1 to 50'), String.valueOf(refusals[0]));
        Assert.isTrue(refusals[1].contains('from 1 to 200'), String.valueOf(refusals[1]));
        Assert.isTrue(refusals[2].contains('from 1 to 50'), String.valueOf(refusals[2]));
        Assert.isTrue(refusals[3].contains('at least the max size of one document'), String.valueOf(refusals[3]));
        Assert.areEqual(20, cleared.get('Signature_Attachment_Max_File_MB__c'), 'Blank reports the default');
        Assert.areEqual(100, cleared.get('Signature_Attachment_Max_Files__c'), 'Blank reports the default');
        Assert.areEqual(200, cleared.get('Signature_Attachment_Max_Total_MB__c'), 'Blank reports the default');
    }
}

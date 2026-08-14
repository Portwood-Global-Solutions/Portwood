/**
 * Tests for the guided PDF-signing path (#163):
 *   - DocGenSignatureSenderController.createGuidedPdfSignatureRequest
 *   - DocGenSignatureController.saveCompositedSignedPdf
 *   - DocGenSignatureController.getSignatureCertificate
 */
@IsTest
private class DocGenGuidedSigningTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'Guided Sig Co', Industry = 'Technology');
    }

    // HTML template with three placement tags (initials / full / date).
    private static Id createTaggedTemplate() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Guided ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry'
        );
        insert tmpl;

        String body =
            '<html><body>' +
            '<h1>{Name}</h1>' +
            '<p>Initials: {@Signature_Member:1:Initials}</p>' +
            '<p>Signature: {@Signature_Member:2:Full}</p>' +
            '<p>Date: {@Signature_Member:3:Date}</p>' +
            '</body></html>';
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        return tmpl.Id;
    }

    private static String signersJson() {
        return '[{"signerName":"Member One","signerEmail":"m1@example.com","roleName":"Member"}]';
    }

    private static String signersJson2() {
        return '[' +
            '{"signerName":"Member One","signerEmail":"m1@example.com","roleName":"Member"},' +
            '{"signerName":"Member Two","signerEmail":"m2@example.com","roleName":"Witness"}' +
            ']';
    }

    @IsTest
    static void createsGuidedRequestWithSentinelPlacements() {
        Id tplId = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();

        DocGen_Signature_Request__c req = [
            SELECT Id, Template__c, Source_Document_Id__c, Frozen_Document_CV_Id__c, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tplId
            LIMIT 1
        ];
        System.assertNotEquals(null, req.Source_Document_Id__c, 'Viewing PDF should be stored as Source_Document');
        System.assertNotEquals(null, req.Frozen_Document_CV_Id__c, 'Frozen sentinel body should be captured (CV)');

        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Tag_Text__c, Placement_Type__c, Status__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__c = :req.Id
            ORDER BY Sequence_Order__c
        ];
        System.assertEquals(3, plcs.size(), 'Three placements created from the three tags');
        for (DocGen_Signature_Placement__c p : plcs) {
            System.assert(
                p.Tag_Text__c != null && p.Tag_Text__c.startsWith('@@SIG-'),
                'Placement should key on a unique sentinel, got: ' + p.Tag_Text__c
            );
            System.assertEquals('Pending', p.Status__c, 'Placement starts Pending');
        }
    }

    @IsTest
    static void guidedRequest_stampsDefaultExpiry() {
        Id tplId = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();

        DocGen_Signature_Request__c req = [
            SELECT Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tplId
            LIMIT 1
        ];
        System.assertNotEquals(null, req.Expires_At__c, 'Every new request stamps its signing window');
        Long deltaMs = req.Expires_At__c.getTime() - System.now().addDays(2).getTime();
        System.assert(
            Math.abs(deltaMs) < 5 * 60 * 1000,
            'Org default (unset setting) = 2 days, matching the historical 48h; delta ms=' + deltaMs
        );
    }

    @IsTest
    static void synthesizesPlacementsForTaglessTemplate() {
        // #170 option (b): a tag-less legacy template is no longer rejected — the guided
        // path auto-appends a "Signatures" block (Full + Date per signer) so it signs
        // through the one consolidated path with zero author change.
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'NoTags ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf('<html><body><p>{Name}</p></body></html>'),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tmpl.Id, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();

        DocGen_Signature_Request__c req = [
            SELECT Id, Source_Document_Id__c, Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tmpl.Id
            LIMIT 1
        ];
        System.assertNotEquals(null, req.Source_Document_Id__c, 'Tag-less template should still produce a viewing PDF');
        System.assertNotEquals(null, req.Frozen_Document_CV_Id__c, 'Frozen body should be captured (CV)');

        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Tag_Text__c, Placement_Type__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__c = :req.Id
        ];
        // One signer → synthesized Full + Date.
        System.assertEquals(2, plcs.size(), 'Synthesized Full + Date placements for the one signer');
        Set<String> types = new Set<String>();
        for (DocGen_Signature_Placement__c p : plcs) {
            types.add(p.Placement_Type__c);
            System.assert(
                p.Tag_Text__c != null && p.Tag_Text__c.startsWith('@@SIG-'),
                'Synthesized placement keys on a sentinel: ' + p.Tag_Text__c
            );
        }
        System.assert(types.contains('Full') && types.contains('Date'), 'Both Full and Date synthesized: ' + types);
    }

    @IsTest
    static void createsGuidedPacketAcrossTwoTemplates() {
        // #170 consolidation: multi-template packets sign through the guided path —
        // one combined viewing PDF + cross-document sentinel placements (Document_Index).
        Id t1 = createTaggedTemplate();
        Id t2 = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];
        String idsJson = JSON.serialize(new List<Id>{ t1, t2 });

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPacketSignatureRequest(
            idsJson,
            a.Id,
            signersJson(),
            'Parallel',
            null
        );
        Test.stopTest();

        DocGen_Signature_Request__c req = [
            SELECT Id, Template_Ids__c, Source_Document_Id__c, Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :t1
            LIMIT 1
        ];
        System.assertNotEquals(null, req.Source_Document_Id__c, 'Combined viewing PDF should be stored');
        System.assertNotEquals(null, req.Template_Ids__c, 'Template_Ids__c set for a packet');
        System.assertNotEquals(null, req.Frozen_Document_CV_Id__c, 'Frozen multi-document body captured (CV)');

        List<DocGen_Signature_Placement__c> plcs = [
            SELECT Document_Index__c, Tag_Text__c
            FROM DocGen_Signature_Placement__c
            WHERE Signature_Request__c = :req.Id
        ];
        System.assertEquals(6, plcs.size(), '3 tags x 2 documents = 6 placements');
        Set<Integer> docIdxs = new Set<Integer>();
        for (DocGen_Signature_Placement__c p : plcs) {
            docIdxs.add(Integer.valueOf(p.Document_Index__c));
            System.assert(
                p.Tag_Text__c != null && p.Tag_Text__c.startsWith('@@SIG-'),
                'Packet placement keys on a unique sentinel: ' + p.Tag_Text__c
            );
        }
        System.assert(docIdxs.contains(0) && docIdxs.contains(1), 'Placements span both documents: ' + docIdxs);
    }

    @IsTest
    static void compositeFinalizeAndCertificate() {
        Id tplId = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);

        DocGen_Signer__c signer = [
            SELECT Id, Secure_Token__c, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__r.Template__c = :tplId
            LIMIT 1
        ];
        signer.PIN_Verified_At__c = System.now();
        update signer;
        String token = signer.Secure_Token__c;

        Test.startTest();
        // Certificate roster: single signer => this signer completes the request.
        Map<String, Object> cert = DocGenSignatureController.getSignatureCertificate(token);
        System.assertEquals(true, cert.get('othersAllSigned'), 'Single signer completes the request');
        List<Object> roster = (List<Object>) cert.get('signers');
        System.assertEquals(1, roster.size(), 'One signer on the roster');

        // Finalize with a client-composited PDF.
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 composited test'));
        DocGenSignatureController.SavePdfSignatureResult r = DocGenSignatureController.saveCompositedSignedPdf(
            token,
            b64,
            true,
            '1.2.3.4',
            'JUnit/1.0',
            '{}'
        );
        Test.stopTest();

        System.assertEquals(true, r.success, 'Composite save succeeds');
        System.assertEquals(true, r.isComplete, 'Single signer => complete');
        System.assertEquals(0, r.remaining, 'No remaining signers');

        DocGen_Signer__c after = [SELECT Status__c FROM DocGen_Signer__c WHERE Id = :signer.Id];
        System.assertEquals('Signed', after.Status__c, 'Signer marked Signed');

        DocGen_Signature_Request__c req = [
            SELECT Status__c
            FROM DocGen_Signature_Request__c
            WHERE Id = :signer.Signature_Request__c
        ];
        System.assertEquals('Signed', req.Status__c, 'Request completed');

        // Final signed document attached to the related record.
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :a.Id AND ContentDocument.Title LIKE '%Signed%'
        ];
        System.assert(!links.isEmpty(), 'Signed document attached to the related record');

        // Audit row with IP captured.
        List<DocGen_Signature_Audit__c> audits = [
            SELECT IP_Address__c, Consent_Captured__c
            FROM DocGen_Signature_Audit__c
            WHERE Signer__c = :signer.Id
        ];
        System.assert(!audits.isEmpty(), 'Audit row created');
        System.assertEquals('1.2.3.4', audits[0].IP_Address__c, 'IP captured on audit');
        System.assertEquals(true, audits[0].Consent_Captured__c, 'Consent captured on audit');
    }

    @IsTest
    static void compositedDrawnPath_firesWriteback() {
        // Regression #173: the guided DRAWN path (saveCompositedSignedPdf) stores the
        // client-composited PDF directly and never enqueues the typed-path finalizer, so
        // it must publish DocGen_Field_Writeback__e itself. Before the fix it didn't, so
        // signer form-field writeback silently no-op'd for every drawn signature. Driving
        // the real save method inside start/stopTest flushes the event through the trigger.
        Id tplId = createTaggedTemplate();
        update new DocGen_Template__c(
            Id = tplId,
            Form_Fields_Config__c = '{"formFields":[{"key":"wbdesc","fieldApiName":"Description","type":"text","writeback":true}]}'
        );
        Account a = [SELECT Id FROM Account LIMIT 1];
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);

        DocGen_Signer__c signer = [
            SELECT Id, Secure_Token__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__r.Template__c = :tplId
            LIMIT 1
        ];
        signer.PIN_Verified_At__c = System.now();
        update signer;

        Test.startTest();
        DocGenSignatureController.SavePdfSignatureResult r = DocGenSignatureController.saveCompositedSignedPdf(
            signer.Secure_Token__c,
            EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 drawn composite')),
            true,
            '1.2.3.4',
            'JUnit/1.0',
            '{"wbdesc":"WRITTEN VIA DRAWN PATH","hackerKey":"INJECTED"}'
        );
        // stopTest delivers the published DocGen_Field_Writeback__e → DocGenFieldWritebackTrigger
        // runs performWriteback (the subscriber) which writes the captured value to the record.
        Test.stopTest();

        System.assertEquals(true, r.isComplete, 'Single signer completes the request');
        Account after = [SELECT Description FROM Account WHERE Id = :a.Id];
        System.assertEquals(
            'WRITTEN VIA DRAWN PATH',
            after.Description,
            'Drawn path must publish the writeback event so the captured form field reaches the record'
        );
    }

    @IsTest
    static void compositedPath_stampsDocumentHashOnAudit() {
        // Regression #187: the guided composited path (saveCompositedSignedPdf) stores the
        // PDF client-side and never publishes DocGen_Signature_PDF__e, so the async finalizer
        // that back-fills Document_Hash_SHA256__c never runs — the audit was left with a null
        // hash. The fix hashes the composited bytes directly at audit insert. Assert the audit
        // now carries the SHA-256 of exactly the bytes that were signed.
        Id tplId = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);

        DocGen_Signer__c signer = [
            SELECT Id, Secure_Token__c, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__r.Template__c = :tplId
            LIMIT 1
        ];
        signer.PIN_Verified_At__c = System.now();
        update signer;

        String b64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 composited audit-hash test bytes'));
        String expectedHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(b64))
        );

        Test.startTest();
        DocGenSignatureController.saveCompositedSignedPdf(
            signer.Secure_Token__c,
            b64,
            true,
            '1.2.3.4',
            'JUnit/1.0',
            null
        );
        Test.stopTest();

        List<DocGen_Signature_Audit__c> audits = [
            SELECT Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :signer.Signature_Request__c AND Signer__c = :signer.Id
        ];
        System.assertEquals(1, audits.size(), 'Exactly one audit for the composited signer');
        System.assertEquals(
            expectedHash,
            audits[0].Document_Hash_SHA256__c,
            'Composited path must stamp the SHA-256 of the signed bytes on the audit (#187)'
        );
    }

    @IsTest
    static void multiSigner_uploadVerificationReturnsAllSigners() {
        // Regression: on the guided/drawn path each signer composites onto the previous
        // signer's PDF (a chain), so each signer's audit was stamped with the hash of the
        // document AS OF their signing. Only the FINAL signer's hash matched the delivered
        // file, so uploading the signed PDF to the verify page (verifyDocument, hash lookup)
        // returned just ONE signer while the token path (verifyByRequestId) returned all. On
        // completion we back-fill every signer's audit with the final document hash so BOTH
        // verify paths return the full roster.
        Id tplId = createTaggedTemplate();
        Account a = [SELECT Id FROM Account LIMIT 1];
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson2(), 'Parallel', null);

        List<DocGen_Signer__c> signers = [
            SELECT Id, Secure_Token__c, Signature_Request__c, Signer_Email__c
            FROM DocGen_Signer__c
            WHERE Signature_Request__r.Template__c = :tplId
            ORDER BY Signer_Email__c ASC
        ];
        System.assertEquals(2, signers.size(), 'Two signers created');
        for (DocGen_Signer__c s : signers) {
            s.PIN_Verified_At__c = System.now();
        }
        update signers;
        Id requestId = signers[0].Signature_Request__c;

        // Distinct bytes per signing step so the intermediate and final hashes differ.
        String intermediateB64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 signer-one only'));
        String finalB64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 both signers plus certificate'));
        String intermediateHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(intermediateB64))
        );
        String finalHash = EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(finalB64))
        );

        Test.startTest();
        // Signer one signs first — request stays In Progress (one signer remains).
        DocGenSignatureController.SavePdfSignatureResult r1 = DocGenSignatureController.saveCompositedSignedPdf(
            signers[0].Secure_Token__c,
            intermediateB64,
            true,
            '1.1.1.1',
            'JUnit/1.0',
            null
        );
        System.assertEquals(false, r1.isComplete, 'First signer does not complete the request');
        // Signer two completes — triggers the audit-hash back-fill.
        DocGenSignatureController.SavePdfSignatureResult r2 = DocGenSignatureController.saveCompositedSignedPdf(
            signers[1].Secure_Token__c,
            finalB64,
            true,
            '2.2.2.2',
            'JUnit/1.0',
            null
        );
        Test.stopTest();

        System.assertEquals(true, r2.isComplete, 'Second signer completes the request');

        // Both signers' audits now carry the SAME final document hash.
        List<DocGen_Signature_Audit__c> audits = [
            SELECT Signer_Name__c, Document_Hash_SHA256__c
            FROM DocGen_Signature_Audit__c
            WHERE Signature_Request__c = :requestId AND Signer_Name__c != 'SYSTEM'
        ];
        System.assertEquals(2, audits.size(), 'One audit per signer');
        for (DocGen_Signature_Audit__c au : audits) {
            System.assertEquals(
                finalHash,
                au.Document_Hash_SHA256__c,
                'Every signer audit must carry the final document hash after completion: ' + au.Signer_Name__c
            );
        }

        // Uploading the delivered PDF (final hash) now returns BOTH signers — the bug was
        // that this returned only the last signer.
        List<DocGenAuthenticatorController.VerificationResult> byUpload = DocGenAuthenticatorController.verifyDocument(
            finalHash
        );
        System.assertEquals(
            2,
            byUpload.size(),
            'verifyDocument(finalHash) must return every signer, not just the last one'
        );

        // The pre-completion intermediate hash was overwritten and no longer resolves.
        List<DocGenAuthenticatorController.VerificationResult> byIntermediate = DocGenAuthenticatorController.verifyDocument(
            intermediateHash
        );
        System.assertEquals(
            0,
            byIntermediate.size(),
            'Intermediate composite hash must no longer match after back-fill'
        );
    }

    @IsTest
    static void formFieldViewingSentinels_hideTagLeaveLocatable() {
        // The viewing PDF must NOT show the literal {?key} tag; it leaves a white,
        // PDF.js-locatable @@FF-<key>@@ sentinel for the drawn-path client to stamp.
        String html = '<p>Favorite color: {?favColor} and size {?size|M} done.</p>';
        Test.startTest();
        String out = DocGenSignatureSenderController.applyFormFieldViewingSentinels(html);
        Test.stopTest();
        System.assert(!out.contains('{?favColor}'), 'literal {?key} tag removed from viewing html: ' + out);
        System.assert(!out.contains('{?size|M}'), 'literal {?key|fallback} tag removed');
        System.assert(out.contains('@@FF-favColor@@'), 'locatable form-field sentinel present');
        System.assert(out.contains('@@FF-size@@'), 'fallback variant reduces to the bare-key sentinel');
        System.assert(out.contains('color:#ffffff'), 'sentinel wrapped white (invisible in the viewing PDF)');
    }

    @IsTest
    static void guidedRequest_keepsFormFieldTagInFrozenBody() {
        // The FROZEN body must keep the bare {?key} tag so the typed-name finalize
        // re-render resolves it server-side (only the viewing render hides it).
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'FF Frozen ' + Datetime.now().getTime(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Form_Fields_Config__c = '{"formFields":[{"key":"favColor","label":"Color","type":"text"}]}'
        );
        insert tmpl;
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(
                '<html><body><p>Color: {?favColor}</p><p>Sign: {@Signature_Signer:1:Full}</p></body></html>'
            ),
            FirstPublishLocationId = tmpl.Id
        );
        insert cv;
        cv = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        insert new DocGen_Template_Version__c(
            Template__c = tmpl.Id,
            Content_Version_Id__c = cv.Id,
            Is_Active__c = true
        );
        Account a = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tmpl.Id, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();

        DocGen_Signature_Request__c req = [
            SELECT Frozen_Document_CV_Id__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tmpl.Id
            LIMIT 1
        ];
        // #156: frozen body lives in a ContentVersion (no size cap) — load it to inspect.
        System.assertNotEquals(null, req.Frozen_Document_CV_Id__c, 'Frozen snapshot CV captured');
        String frozenJson = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :req.Frozen_Document_CV_Id__c
                LIMIT 1
            ]
            .VersionData.toString();
        System.assert(
            frozenJson.contains('{?favColor}'),
            'Frozen body must retain the {?favColor} tag for the typed-path re-render'
        );
    }

    @IsTest
    static void rejectsInvalidTokens() {
        Test.startTest();
        Boolean a = false, b = false;
        try {
            DocGenSignatureController.getSignatureCertificate('short');
        } catch (Exception e) {
            a = true;
        }
        try {
            DocGenSignatureController.saveCompositedSignedPdf('short', 'x', true, '1.1.1.1', 'ua', '{}');
        } catch (Exception e) {
            b = true;
        }
        Test.stopTest();
        System.assert(a, 'getSignatureCertificate rejects bad token');
        System.assert(b, 'saveCompositedSignedPdf rejects bad token');
    }

    // Regression (#189): when a request has no frozen snapshot, the finalizer LIVE re-merges
    // and the body carries the ORIGINAL {@Signature_*} tags — not the @@SIG-n@@ sentinels the
    // placements key on. The finalizer re-applies resentinelSignatureBody so stampSignaturesInXml's
    // Tag_Text__c match lands; without it the signature silently never stamps (blank line).
    // #156 made the CV-backed snapshot the primary path (no size cap), so this re-merge is now
    // only the fallback for legacy/snapshot-less requests — resentinel keeps that path correct.
    @IsTest
    static void resentinelRestoresSentinelsInDocumentOrder() {
        String body =
            'Signature: {@Signature_Buyer} Date: {@Signature_Buyer:1:DatePick} ' + 'Witness: {@Signature_Witness}';
        String out = DocGenSignatureSenderController.resentinelSignatureBody(body);
        // Document order → @@SIG-0@@ = first tag, etc. (matches createGuidedPdfSignatureRequest).
        System.assert(out.contains('Signature: @@SIG-0@@'), 'first tag → @@SIG-0@@: ' + out);
        System.assert(out.contains('Date: @@SIG-1@@'), 'second tag → @@SIG-1@@: ' + out);
        System.assert(out.contains('Witness: @@SIG-2@@'), 'third tag → @@SIG-2@@: ' + out);
        System.assert(!out.contains('{@Signature'), 'no original signature tags remain: ' + out);
    }

    @IsTest
    static void resentinelIsIdempotentAndHandlesBareTag() {
        // Frozen-path body already carries sentinels → no-op.
        String frozen = 'Signature: @@SIG-0@@';
        System.assertEquals(frozen, DocGenSignatureSenderController.resentinelSignatureBody(frozen));
        // Bare {@Signature} fallback applies only when no role-scoped tags exist.
        String bare = DocGenSignatureSenderController.resentinelSignatureBody('Sign here: {@Signature}');
        System.assertEquals('Sign here: @@SIG-0@@', bare);
        // Blank/null are safe.
        System.assertEquals(null, DocGenSignatureSenderController.resentinelSignatureBody(null));
    }

    // #156: the frozen snapshot is persisted to a ContentVersion (no 131072-char cap) and
    // round-trips intact, so large/image-heavy templates get a true point-in-time snapshot
    // instead of degrading to a live re-merge at sign time.
    @IsTest
    static void frozenSnapshotRoundTripsThroughContentVersion() {
        Map<String, Object> doc = new Map<String, Object>{
            'templateType' => 'HTML',
            'combinedDocumentXml' => '<html><body>Sign: @@SIG-0@@</body></html>',
            'relsXml' => '',
            'contentTypesXml' => '',
            'docTitle' => 'T',
            'stylesXml' => '',
            'numberingXml' => ''
        };
        String frozenJson = DocGenSignatureService.buildFrozenDocumentJson(
            new List<Map<String, Object>>{ doc },
            new List<Id>{ null }
        );
        System.assert(String.isNotBlank(frozenJson), 'snapshot json built');

        Test.startTest();
        Id cvId = DocGenSignatureService.saveFrozenSnapshotCv(frozenJson);
        Test.stopTest();

        System.assertNotEquals(null, cvId, 'snapshot persisted to a ContentVersion');
        String roundTrip = [SELECT VersionData FROM ContentVersion WHERE Id = :cvId LIMIT 1].VersionData.toString();
        System.assertEquals(frozenJson, roundTrip, 'CV content round-trips exactly');
        List<Map<String, Object>> docs = DocGenSignatureService.loadFrozenMergeData(roundTrip);
        System.assertNotEquals(null, docs, 'snapshot loads back into renderable merge data');
        System.assertEquals(
            '<html><body>Sign: @@SIG-0@@</body></html>',
            (String) docs[0].get('combinedDocumentXml'),
            'frozen body preserved through the CV round-trip'
        );
        // saveFrozenSnapshotCv is null-safe for a blank snapshot.
        System.assertEquals(null, DocGenSignatureService.saveFrozenSnapshotCv(null));
    }

    // #156 storage lifecycle: a completed/declined/cancelled request reclaims its snapshot CV
    // (the Snapshot_Hash__c stays as tamper-evidence). purgeFrozenSnapshotCv deletes the file.
    @IsTest
    static void purgeFrozenSnapshotCvReclaimsTheFile() {
        Id cvId = DocGenSignatureService.saveFrozenSnapshotCv('{"v":1,"templateType":"HTML","docs":[]}');
        System.assertNotEquals(null, cvId, 'snapshot CV created');
        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId LIMIT 1].ContentDocumentId;
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocument WHERE Id = :cdId], 'file exists before purge');

        Test.startTest();
        DocGenSignatureService.purgeFrozenSnapshotCv(cvId);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :cdId], 'file reclaimed after purge');
        // Null-safe / idempotent: purging null or an already-gone CV does not throw.
        DocGenSignatureService.purgeFrozenSnapshotCv(null);
        DocGenSignatureService.purgeFrozenSnapshotCv(cvId);
    }

    // ─── #330: a PDF template must not be handed to the ZIP reader ───────────
    //
    // extractTemplatePlainText branched on isHtmlBacked, which is HTML-or-Canvas
    // only, so every other type — INCLUDING PDF — fell through to the
    // pre-decomposed word/document.xml lookup. A PDF is never decomposed into
    // that, so the lookup found nothing and dropped to
    // getActiveTemplateDocumentXml, which does:
    //
    //     new Compression.ZipReader(cvs[0].VersionData)
    //
    // A PDF is not a ZIP. Apex throws compression.ZipException "Could not load
    // Zip", which is what elliottr saw from BOTH the sender LWC and the Flow
    // action — both reach it through createGuidedPdfSignatureRequest.

    /** A minimal fillable PDF: catalog -> AcroForm -> two text widgets. */
    private static Blob fillableAcroFormPdf() {
        return Blob.valueOf(
            '%PDF-1.4\n' +
                '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
                '2 0 obj\n<< /Type /Pages /Kids [4 0 R] /Count 1 >>\nendobj\n' +
                '3 0 obj\n<< /Fields [5 0 R 6 0 R] >>\nendobj\n' +
                '4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] >>\nendobj\n' +
                '5 0 obj\n<< /FT /Tx /T (Name) /Subtype /Widget /Rect [10 10 200 30] >>\nendobj\n' +
                '6 0 obj\n<< /FT /Tx /T (Owner.Email) /Subtype /Widget /Rect [10 40 200 60] /V (old) >>\nendobj\n' +
                'xref\n0 7\n0000000000 65535 f \n0000000009 00000 n \n0000000076 00000 n \n' +
                '0000000135 00000 n \n0000000184 00000 n \n0000000281 00000 n \n0000000357 00000 n \n' +
                'trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n'
        );
    }

    private static DocGen_Template__c pdfTemplateWithBody(Blob body) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'PdfSig330',
            Type__c = 'PDF',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Query_Config__c = 'Name'
        );
        insert t;
        ContentVersion cv = new ContentVersion(Title = 'pdf330', PathOnClient = 'pdf330.pdf', VersionData = body);
        insert cv;
        ContentVersion r = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        insert new DocGen_Template_Version__c(
            Template__c = t.Id,
            Is_Active__c = true,
            Content_Version_Id__c = r.Id,
            Type__c = 'PDF'
        );
        insert new ContentDocumentLink(LinkedEntityId = t.Id, ContentDocumentId = r.ContentDocumentId, ShareType = 'V');
        return t;
    }

    @IsTest
    static void pdfTemplatePlacementScanDoesNotUnzipThePdf() {
        DocGen_Template__c t = pdfTemplateWithBody(fillableAcroFormPdf());

        Test.startTest();
        List<DocGenSignatureSenderController.PlacementInfo> placements;
        try {
            placements = DocGenSignatureSenderController.getTemplateSignaturePlacements(t.Id);
        } catch (Exception e) {
            System.assert(
                false,
                'A PDF template must never reach the ZIP reader. Got: ' + e.getTypeName() + ' :: ' + e.getMessage()
            );
        }
        Test.stopTest();

        // A PDF positions signatures through AcroForm fields, not {@Signature_*}
        // text tags, so "no text placements" is the correct answer here.
        System.assertEquals(0, placements == null ? 0 : placements.size(), 'A PDF has no text-tag placements.');
    }

    @IsTest
    static void signatureRequestSucceedsForAFillablePdfTemplate() {
        DocGen_Template__c t = pdfTemplateWithBody(fillableAcroFormPdf());
        Account a = new Account(Name = 'Acme 330');
        insert a;
        String signers = '[{"name":"Ada Test","email":"ada@example.com","roleName":"Signer 1","order":1}]';

        Test.startTest();
        List<DocGenSignatureSenderController.SignerResult> res;
        try {
            res = DocGenSignatureSenderController.createGuidedPdfSignatureRequest(
                t.Id,
                a.Id,
                signers,
                'Sequential',
                null
            );
        } catch (Exception e) {
            System.assert(false, 'Signature request on a PDF template threw: ' + e.getMessage());
        }
        Test.stopTest();

        System.assertEquals(1, res == null ? 0 : res.size(), 'One signer in, one signer link out.');
    }
}

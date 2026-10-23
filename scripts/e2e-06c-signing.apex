// DocGen E2E Test 06c — Signature REDEMPTION (the half after the email is sent)
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0
//
// WHY THIS SCRIPT EXISTS
// ----------------------
// e2e-06/06b stop at "the email goes out". Nothing covered the signer opening
// the link and signing.
//
// e2e-06's placement checks are the sharpest example: they INSERT and UPDATE
// DocGen_Signature_Placement__c by hand, then assert the values came back. That
// proves the OBJECT accepts writes. It runs no line of the code that creates
// placements from a template, and would pass unchanged if the parser stopped
// producing placements entirely.
//
// What is new here is CONTENT correctness against a real render: unit tests
// sign Blob.valueOf('%PDF-1.4 composited test') — a string that is not a PDF —
// so nothing proved a real template renders to a real document with the merge
// resolved and the signature tags sentinelised.
//
// NOT COVERED, deliberately: PIN redemption (verifyPin). The code is emailed and
// stored hashed, so anonymous Apex cannot obtain it. This sets PIN_Verified_At__c
// directly, as DocGenGuidedSigningTest does — the PIN gate stays unproven
// end-to-end here, and e2e-06d covers it by seeding a known hash.

Integer pass = 0;
Integer fail = 0;

Id acctId;
Id tmplId;
Id reqId;

// ===== Look up test data =====
List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
if (accts.isEmpty() || tmpls.isEmpty()) {
    System.debug('========================================');
    System.debug('E2E-06C SIGNING — PASS: 0  FAIL: 1  ABORTED (run e2e-02 first)');
    System.debug('========================================');
    return;
}
acctId = accts[0].Id;
tmplId = tmpls[0].Id;

// ===== 1. Create a guided request — this RENDERS a real PDF =====
// One render only. Blob.toPdf on a real template is the most expensive thing in
// this script, and a second one risks a CPU limit, which prints no summary line
// at all and reads as though the script never ran.
try {
    String signersJson = '[{"signerName":"Carol Redeem","signerEmail":"carol@e2etest.example.com","roleName":"Signer"}]';
    DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tmplId, acctId, signersJson, 'Parallel', null);
    List<DocGen_Signature_Request__c> reqs = [
        SELECT Id
        FROM DocGen_Signature_Request__c
        WHERE Template__c = :tmplId AND Signer_Email__c = NULL
        ORDER BY CreatedDate DESC
        LIMIT 1
    ];
    // Fall back to the newest request on this template if the guided path stamps
    // Signer_Email__c after all — the point is to find the one just created.
    if (reqs.isEmpty()) {
        reqs = [
            SELECT Id
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tmplId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }
    reqId = reqs.isEmpty() ? null : reqs[0].Id;
    if (reqId != null) {
        pass++;
        System.debug('GUIDED REQUEST CREATED: PASS — ' + reqId);
    } else {
        fail++;
        System.debug('GUIDED REQUEST CREATED: FAIL — no request row');
    }
} catch (Exception e) {
    fail++;
    System.debug('GUIDED REQUEST CREATED: FAIL — ' + e.getMessage());
}

if (reqId == null) {
    System.debug('========================================');
    System.debug('E2E-06C SIGNING — PASS: ' + pass + '  FAIL: ' + fail + '  ABORTED (no request)');
    System.debug('========================================');
    return;
}

DocGen_Signature_Request__c req = [
    SELECT Id, Status__c, Source_Document_Id__c, Frozen_Document_CV_Id__c, Expires_At__c, Related_Record_Id__c
    FROM DocGen_Signature_Request__c
    WHERE Id = :reqId
];

// ===== 2. The viewing document is a REAL PDF, not an empty shell =====
// A zero-byte or non-PDF body still satisfies "Source_Document_Id__c is set",
// which is why the assertion reads the bytes rather than the Id.
try {
    if (req.Source_Document_Id__c == null) {
        fail++;
        System.debug('VIEWING PDF IS REAL: FAIL — Source_Document_Id__c null');
    } else {
        ContentVersion cv = [
            SELECT VersionData, ContentSize
            FROM ContentVersion
            WHERE Id = :req.Source_Document_Id__c
            LIMIT 1
        ];
        // Base64, NOT VersionData.toString(): a real PDF is binary and toString()
        // throws "BLOB is not a valid UTF-8 string" on it. The irony is that the
        // throw only happens once the file IS a genuine PDF — the naive check
        // passes for a text file pretending to be one and fails for the real
        // thing. 'JVBERi0' is the base64 of '%PDF-'.
        String head = EncodingUtil.base64Encode(cv.VersionData);
        // 1 KB floor: a PDF of a merged template is several KB. A header-only
        // file would satisfy a prefix check and prove nothing.
        if (head.startsWith('JVBERi0') && cv.ContentSize > 1000) {
            pass++;
            System.debug('VIEWING PDF IS REAL: PASS — ' + cv.ContentSize + ' bytes');
        } else {
            fail++;
            System.debug('VIEWING PDF IS REAL: FAIL — head64=' + head.left(12) + ' size=' + cv.ContentSize);
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('VIEWING PDF IS REAL: FAIL — ' + e.getMessage());
}

// ===== 3. The frozen snapshot merged, and sentinelised its signature tags =====
// This is the content assertion nothing else makes. Three separate ways the
// snapshot can be wrong, each with its own message so a failure names itself:
//   a. no @@SIG- sentinel  -> placements key on text that is not in the body,
//      so the signature stamps nowhere and the page is silently blank (#189)
//   b. a raw {@Signature tag survives -> the signer sees the tag as literal text
//   c. an unresolved {Name} merge tag -> the merge never ran
try {
    if (req.Frozen_Document_CV_Id__c == null) {
        fail++;
        System.debug('FROZEN SNAPSHOT CONTENT: FAIL — no snapshot CV (#156 path did not run)');
    } else {
        String frozen = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :req.Frozen_Document_CV_Id__c
                LIMIT 1
            ]
            .VersionData.toString();
        Boolean hasSentinel = frozen.contains('@@SIG-');
        Boolean rawTagLeft = frozen.contains('{@Signature');
        Boolean unmerged = frozen.contains('{Name}');
        if (hasSentinel && !rawTagLeft && !unmerged) {
            pass++;
            System.debug('FROZEN SNAPSHOT CONTENT: PASS — sentinelised and merged');
        } else {
            fail++;
            System.debug(
                'FROZEN SNAPSHOT CONTENT: FAIL — sentinel=' +
                    hasSentinel +
                    ' rawSignatureTagLeft=' +
                    rawTagLeft +
                    ' unmergedNameTag=' +
                    unmerged
            );
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('FROZEN SNAPSHOT CONTENT: FAIL — ' + e.getMessage());
}

// ===== 4. Placements were CREATED BY THE PARSER (not inserted by this script) =====
try {
    List<DocGen_Signature_Placement__c> plcs = [
        SELECT Tag_Text__c, Status__c, Placement_Type__c
        FROM DocGen_Signature_Placement__c
        WHERE Signature_Request__c = :reqId
    ];
    Boolean allSentinel = !plcs.isEmpty();
    Boolean allPending = !plcs.isEmpty();
    for (DocGen_Signature_Placement__c p : plcs) {
        if (p.Tag_Text__c == null || !p.Tag_Text__c.startsWith('@@SIG-')) {
            allSentinel = false;
        }
        if (p.Status__c != 'Pending') {
            allPending = false;
        }
    }
    if (allSentinel && allPending) {
        pass++;
        System.debug('PLACEMENTS GENERATED: PASS — ' + plcs.size() + ' sentinel-keyed, all Pending');
    } else {
        fail++;
        System.debug(
            'PLACEMENTS GENERATED: FAIL — count=' + plcs.size() + ' sentinel=' + allSentinel + ' pending=' + allPending
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('PLACEMENTS GENERATED: FAIL — ' + e.getMessage());
}

// ===== 5. Signing window stamped =====
try {
    if (req.Expires_At__c != null && req.Expires_At__c > System.now()) {
        pass++;
        System.debug('SIGNING WINDOW STAMPED: PASS — ' + req.Expires_At__c);
    } else {
        fail++;
        System.debug('SIGNING WINDOW STAMPED: FAIL — ' + req.Expires_At__c);
    }
} catch (Exception e) {
    fail++;
    System.debug('SIGNING WINDOW STAMPED: FAIL — ' + e.getMessage());
}

// ===== 6. Certificate roster, before anyone signs =====
DocGen_Signer__c signer;
String signerToken;
try {
    signer = [
        SELECT Id, Secure_Token__c, Status__c, Signature_Request__c
        FROM DocGen_Signer__c
        WHERE Signature_Request__c = :reqId
        LIMIT 1
    ];
    signerToken = signer.Secure_Token__c;
    // PIN gate bypassed on purpose — see the header note. This is the one step
    // of the redemption flow this script cannot honestly claim to cover.
    update new DocGen_Signer__c(Id = signer.Id, PIN_Verified_At__c = System.now());

    Map<String, Object> cert = DocGenSignatureController.getSignatureCertificate(signerToken);
    List<Object> roster = (List<Object>) cert.get('signers');
    if (roster != null && roster.size() == 1 && cert.get('othersAllSigned') == true) {
        pass++;
        System.debug('CERTIFICATE ROSTER: PASS — 1 signer, sole signer completes');
    } else {
        fail++;
        System.debug(
            'CERTIFICATE ROSTER: FAIL — roster=' +
                (roster == null ? 0 : roster.size()) +
                ' othersAllSigned=' +
                cert.get('othersAllSigned')
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('CERTIFICATE ROSTER: FAIL — ' + e.getMessage());
}

// ===== 7. Sign it =====
// Bytes chosen so the SHA-256 assertion below is meaningful: the audit must
// carry the hash of exactly what was signed (#187), so the test hashes the same
// bytes independently rather than reading the hash back and comparing it to
// itself.
// TEST-NET-3 (RFC 5737), so it can never collide with a real client address —
// this value is a decoy the audit must REFUSE to record. See step 10.
final String FORGED_IP = '203.0.113.7';
String signedB64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 e2e-06c signed bytes ' + System.now().getTime()));
String expectedHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', EncodingUtil.base64Decode(signedB64)));
// #407: sign each placement first, as the guided UI does.
for (DocGen_Signature_Placement__c p : [
    SELECT Id
    FROM DocGen_Signature_Placement__c
    WHERE Signature_Request__c = :reqId
]) {
    DocGenSignatureController.signPlacement(signerToken, p.Id, 'E2E Signer');
}
try {
    DocGenSignatureController.SavePdfSignatureResult r = DocGenSignatureController.saveCompositedSignedPdf(
        signerToken,
        signedB64,
        true,
        FORGED_IP,
        'E2E/06c',
        null
    );
    if (r.success && r.isComplete && r.remaining == 0) {
        pass++;
        System.debug('SAVE SIGNATURE: PASS — complete, 0 remaining');
    } else {
        fail++;
        System.debug(
            'SAVE SIGNATURE: FAIL — success=' + r.success + ' complete=' + r.isComplete + ' remaining=' + r.remaining
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('SAVE SIGNATURE: FAIL — ' + e.getMessage());
}

// ===== 8. Signing moved the state machine =====
try {
    DocGen_Signer__c after = [SELECT Status__c FROM DocGen_Signer__c WHERE Id = :signer.Id];
    DocGen_Signature_Request__c reqAfter = [SELECT Status__c FROM DocGen_Signature_Request__c WHERE Id = :reqId];
    if (after.Status__c == 'Signed' && reqAfter.Status__c == 'Signed') {
        pass++;
        System.debug('STATUS TRANSITIONS: PASS — signer Signed, request Signed');
    } else {
        fail++;
        System.debug('STATUS TRANSITIONS: FAIL — signer=' + after.Status__c + ' request=' + reqAfter.Status__c);
    }
} catch (Exception e) {
    fail++;
    System.debug('STATUS TRANSITIONS: FAIL — ' + e.getMessage());
}

// ===== 9. The signed document reached the RECORD =====
// The customer-visible outcome. Everything above can pass while the file never
// lands on the record the request was raised against.
try {
    List<ContentDocumentLink> links = [
        SELECT ContentDocument.Title
        FROM ContentDocumentLink
        WHERE LinkedEntityId = :acctId AND ContentDocument.Title LIKE '%Signed%'
    ];
    if (!links.isEmpty()) {
        pass++;
        System.debug('SIGNED DOC ON RECORD: PASS — ' + links[0].ContentDocument.Title);
    } else {
        fail++;
        System.debug('SIGNED DOC ON RECORD: FAIL — nothing attached to ' + acctId);
    }
} catch (Exception e) {
    fail++;
    System.debug('SIGNED DOC ON RECORD: FAIL — ' + e.getMessage());
}

// ===== 10. Audit trail: IP, consent, and the hash of the signed bytes =====
try {
    List<DocGen_Signature_Audit__c> audits = [
        SELECT IP_Address__c, Consent_Captured__c, Document_Hash_SHA256__c
        FROM DocGen_Signature_Audit__c
        WHERE Signer__c = :signer.Id
    ];
    if (audits.isEmpty()) {
        fail++;
        System.debug('AUDIT TRAIL: FAIL — no audit row for the signer');
    } else {
        DocGen_Signature_Audit__c au = audits[0];
        // The IP assertion is an ANTI-FORGERY guard, not an equality check.
        // resolveClientIp deliberately prefers the server-observed IP and uses
        // the caller-supplied one only when the server has none — otherwise a
        // signer could forge the IP on their own tamper-evident audit. So the
        // value passed above is a decoy: asserting it came back would assert the
        // security fix had been REVERTED. What must hold is that an IP was
        // captured and it is not the one the client claimed.
        Boolean ipCaptured = String.isNotBlank(au.IP_Address__c) && au.IP_Address__c != 'Unknown';
        Boolean ipNotForged = au.IP_Address__c != FORGED_IP;
        Boolean consentOk = au.Consent_Captured__c == true;
        Boolean hashOk = au.Document_Hash_SHA256__c == expectedHash;
        if (ipCaptured && ipNotForged && consentOk && hashOk) {
            pass++;
            System.debug('AUDIT TRAIL: PASS — server IP (' + au.IP_Address__c + '), consent, document hash');
        } else {
            fail++;
            System.debug(
                'AUDIT TRAIL: FAIL — ipCaptured=' +
                    ipCaptured +
                    ' ipNotForged=' +
                    ipNotForged +
                    ' (got ' +
                    au.IP_Address__c +
                    ') consent=' +
                    consentOk +
                    ' hash=' +
                    hashOk
            );
        }
    }
} catch (Exception e) {
    fail++;
    System.debug('AUDIT TRAIL: FAIL — ' + e.getMessage());
}

// ===== 11. The delivered document verifies =====
// The recipient-facing promise: upload the signed PDF to the verify page and it
// names who signed it.
try {
    List<DocGenAuthenticatorController.VerificationResult> vs = DocGenAuthenticatorController.verifyDocument(
        expectedHash
    );
    if (vs != null && vs.size() == 1 && vs[0].signerName == 'Carol Redeem') {
        pass++;
        System.debug('VERIFY DELIVERED DOC: PASS');
    } else {
        fail++;
        System.debug('VERIFY DELIVERED DOC: FAIL — ' + (vs == null ? 'null' : String.valueOf(vs.size())) + ' results');
    }
} catch (Exception e) {
    fail++;
    System.debug('VERIFY DELIVERED DOC: FAIL — ' + e.getMessage());
}

// ===== 12. A signed request cannot be signed again =====
// Replay guard: the token stays valid-looking after signing, so the reject has
// to come from status, not the token.
try {
    DocGenSignatureController.SignatureInitResponse replay = DocGenSignatureController.validateToken(signerToken);
    if (replay.isValid == false) {
        pass++;
        System.debug('REPLAY REJECTED: PASS — ' + replay.errorMessage);
    } else {
        fail++;
        System.debug('REPLAY REJECTED: FAIL — a signed request still accepts its token');
    }
} catch (Exception e) {
    fail++;
    System.debug('REPLAY REJECTED: FAIL — ' + e.getMessage());
}

// ===== Cleanup =====
// Every step is individually guarded. A single `delete` that throws inside one
// big try still aborts the transaction at COMMIT with "entity is deleted" —
// which is raised by the platform, not catchable here, and discards the whole
// debug buffer. The script then prints no PASS/FAIL line at all and reads as
// though it never ran, so a tidy-up problem is indistinguishable from a total
// failure of the feature. Deleting the request LAST and letting the platform
// cascade to its children avoids racing the cascade.
Integer cleanupErrors = 0;
// RECORDS ONLY. The files this run created are reclaimed by e2e-08 in a LATER
// transaction, deliberately not here: completing a signature fires the product's
// own post-render ContentDocument sweep, so some are already gone by now, and
// deleting an already-deleted row raises "entity is deleted" at COMMIT —
// uncatchable, and it discards the debug buffer. The script then prints no
// PASS/FAIL line at all and the harness reports "did not finish", hiding twelve
// passing assertions behind a teardown that could never have worked.
try {
    Database.delete([SELECT Id FROM DocGen_Signature_Request__c WHERE Id = :reqId], false);
} catch (Exception e) {
    cleanupErrors++;
    System.debug('CLEANUP (request): ' + e.getMessage());
}
if (cleanupErrors == 0) {
    pass++;
    System.debug('CLEANUP: PASS');
} else {
    fail++;
    System.debug('CLEANUP: FAIL — ' + cleanupErrors + ' step(s) errored');
}

System.debug('========================================');
System.debug(
    'E2E-06C SIGNING — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');

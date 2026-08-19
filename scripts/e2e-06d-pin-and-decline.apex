// DocGen E2E Test 06d — PIN verification gate + decline path
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0
//
// WHY THIS SCRIPT EXISTS
// ----------------------
// e2e-06 proves sendPin STAMPS a PIN (PIN_Hash__c and PIN_Expires_At__c are not
// null). Nothing proved the PIN is ever CHECKED. The whole point of the gate is
// that a wrong code is refused, a stale code is refused, and guessing is capped
// — none of which "a hash was written" tells you.
//
// These paths are reachable from anonymous Apex, which is why they belong here
// rather than in a unit test: verifyPin and declineSignature RETURN their
// failures in a Map instead of throwing AuraHandledException. (saveSignature
// does throw, so its negative paths stay in unit tests — an AuraHandledException
// raised outside an Aura/VF request becomes an uncatchable LimitException.)
//
// The PIN is seeded directly rather than read from an email. That is possible
// only because PIN_Hash__c is an UNSALTED SHA-256 of the 6-digit code, so the
// hash for a chosen PIN can be computed here. Worth stating plainly: the same
// property means anyone able to read the field can recover the code from a
// precomputed table of all 10^6 digests. See the note at the end of this file.

Integer pass = 0;
Integer fail = 0;

List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
if (accts.isEmpty() || tmpls.isEmpty()) {
    System.debug('========================================');
    System.debug('E2E-06D PIN + DECLINE — PASS: 0  FAIL: 1  ABORTED (run e2e-02 first)');
    System.debug('========================================');
    return;
}
Id acctId = accts[0].Id;
Id tmplId = tmpls[0].Id;

// Helpers ---------------------------------------------------------------------
// A token must be exactly 64 hex characters or every entry point rejects it on
// format alone, before any of the logic under test runs.
String freshToken = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Crypto.generateAesKey(256)));
String hashOf = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf('424242')));

// Two requests: the decline path marks its whole request Declined, which would
// contaminate the PIN signers if they shared one.
DocGen_Signature_Request__c pinReq = new DocGen_Signature_Request__c(
    Status__c = 'Sent',
    Related_Record_Id__c = acctId,
    Template__c = tmplId,
    Secure_Token__c = freshToken,
    Expires_At__c = System.now().addDays(30)
);
DocGen_Signature_Request__c decReq = new DocGen_Signature_Request__c(
    Status__c = 'Sent',
    Related_Record_Id__c = acctId,
    Template__c = tmplId,
    Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Crypto.generateAesKey(256))),
    Expires_At__c = System.now().addDays(30)
);
insert new List<DocGen_Signature_Request__c>{ pinReq, decReq };

// #367 — declineSignature now gates on the same org+template switches the
// signing pages use to show/hide the button, off by default. This script's
// decline scenarios need it turned on for their successful-decline assertions
// to hold; reset both back to off in Cleanup below since the template is shared.
DocGenSetupController.saveDeclineSettings(true);
update new DocGen_Template__c(Id = tmplId, Show_Signer_Decline__c = true);

// One signer per scenario. Sharing a signer across scenarios would let an
// earlier assertion's side effect (a spent attempt, a cleared hash, a lockout)
// decide a later one.
Map<String, String> tok = new Map<String, String>();
List<DocGen_Signer__c> signers = new List<DocGen_Signer__c>();
for (String k : new List<String>{ 'nopin', 'expired', 'lockout', 'good', 'decline', 'decline2' }) {
    String t = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(k + Crypto.getRandomLong())));
    tok.put(k, t);
    signers.add(
        new DocGen_Signer__c(
            Signature_Request__c = (k.startsWith('decline') ? decReq.Id : pinReq.Id),
            Signer_Name__c = 'PIN ' + k,
            Signer_Email__c = k + '@e2etest.example.com',
            Secure_Token__c = t,
            Status__c = 'Pending',
            Sort_Order__c = 1
        )
    );
}
insert signers;
Map<String, Id> sid = new Map<String, Id>();
for (DocGen_Signer__c s : signers) {
    sid.put(s.Signer_Name__c.substringAfter('PIN '), s.Id);
}

// ===== 1. A malformed token is refused on format alone =====
try {
    Map<String, Object> r = DocGenSignatureController.verifyPin('short', '123456');
    if (r.get('success') == false && String.valueOf(r.get('message')).containsIgnoreCase('token')) {
        pass++;
        System.debug('PIN REJECTS BAD TOKEN: PASS');
    } else {
        fail++;
        System.debug('PIN REJECTS BAD TOKEN: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN REJECTS BAD TOKEN: FAIL — ' + e.getMessage());
}

// ===== 2. A non-6-digit code is refused before any lookup =====
// Guards the shape of the input: letters must not reach the digest comparison.
try {
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('good'), '12ab');
    if (r.get('success') == false && String.valueOf(r.get('message')).containsIgnoreCase('6-digit')) {
        pass++;
        System.debug('PIN REJECTS MALFORMED CODE: PASS');
    } else {
        fail++;
        System.debug('PIN REJECTS MALFORMED CODE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN REJECTS MALFORMED CODE: FAIL — ' + e.getMessage());
}

// ===== 3. No PIN was ever sent =====
// Must not fall through to "correct" just because there is nothing to compare.
try {
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('nopin'), '424242');
    if (r.get('success') == false) {
        pass++;
        System.debug('PIN REJECTS WHEN NONE SENT: PASS');
    } else {
        fail++;
        System.debug('PIN REJECTS WHEN NONE SENT: FAIL — accepted a code that was never issued');
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN REJECTS WHEN NONE SENT: FAIL — ' + e.getMessage());
}

// ===== 4. An expired PIN is refused even when the digits are right =====
try {
    update new DocGen_Signer__c(
        Id = sid.get('expired'),
        PIN_Hash__c = hashOf,
        PIN_Expires_At__c = System.now().addMinutes(-1)
    );
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('expired'), '424242');
    if (r.get('success') == false && String.valueOf(r.get('message')).containsIgnoreCase('expired')) {
        pass++;
        System.debug('PIN REJECTS EXPIRED CODE: PASS');
    } else {
        fail++;
        System.debug('PIN REJECTS EXPIRED CODE: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN REJECTS EXPIRED CODE: FAIL — ' + e.getMessage());
}

// ===== 5. Guessing is capped at 3 attempts, then locked =====
// The rate limit is the only thing standing between a 6-digit code and a
// brute-force, so "wrong code is refused" is not enough on its own.
try {
    update new DocGen_Signer__c(
        Id = sid.get('lockout'),
        PIN_Hash__c = hashOf,
        PIN_Expires_At__c = System.now().addMinutes(15)
    );
    Boolean firstRefused = DocGenSignatureController.verifyPin(tok.get('lockout'), '000001').get('success') == false;
    DocGenSignatureController.verifyPin(tok.get('lockout'), '000002');
    DocGenSignatureController.verifyPin(tok.get('lockout'), '000003');
    // Fourth attempt uses the CORRECT code. It must still be refused — a lockout
    // that yields to the right answer is not a lockout.
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('lockout'), '424242');
    Boolean locked = r.get('success') == false && String.valueOf(r.get('message')).containsIgnoreCase('too many');
    DocGen_Signer__c after = [SELECT PIN_Attempts__c FROM DocGen_Signer__c WHERE Id = :sid.get('lockout')];
    if (firstRefused && locked && after.PIN_Attempts__c >= 3) {
        pass++;
        System.debug('PIN LOCKS OUT AFTER 3: PASS — attempts=' + after.PIN_Attempts__c);
    } else {
        fail++;
        System.debug(
            'PIN LOCKS OUT AFTER 3: FAIL — firstRefused=' +
                firstRefused +
                ' locked=' +
                locked +
                ' attempts=' +
                after.PIN_Attempts__c
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN LOCKS OUT AFTER 3: FAIL — ' + e.getMessage());
}

// ===== 6. The correct code verifies and CLEARS the secret =====
// Leaving PIN_Hash__c behind would keep a reusable credential on the record
// after it has served its purpose.
try {
    update new DocGen_Signer__c(
        Id = sid.get('good'),
        PIN_Hash__c = hashOf,
        PIN_Expires_At__c = System.now().addMinutes(15)
    );
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('good'), '424242');
    DocGen_Signer__c after = [
        SELECT PIN_Verified_At__c, PIN_Hash__c, PIN_Expires_At__c, PIN_Attempts__c, Status__c
        FROM DocGen_Signer__c
        WHERE Id = :sid.get('good')
    ];
    Boolean ok =
        r.get('success') == true &&
        after.PIN_Verified_At__c != null &&
        after.PIN_Hash__c == null &&
        after.PIN_Expires_At__c == null &&
        after.Status__c == 'Viewed';
    if (ok) {
        pass++;
        System.debug('PIN ACCEPTS CORRECT CODE + CLEARS SECRET: PASS — status=' + after.Status__c);
    } else {
        fail++;
        System.debug(
            'PIN ACCEPTS CORRECT CODE + CLEARS SECRET: FAIL — success=' +
                r.get('success') +
                ' verifiedAt=' +
                after.PIN_Verified_At__c +
                ' hashLeft=' +
                (after.PIN_Hash__c != null) +
                ' status=' +
                after.Status__c
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN ACCEPTS CORRECT CODE + CLEARS SECRET: FAIL — ' + e.getMessage());
}

// ===== 7. A verified PIN is single-use =====
// Replaying the same code after the hash is cleared must not verify again.
try {
    Map<String, Object> r = DocGenSignatureController.verifyPin(tok.get('good'), '424242');
    if (r.get('success') == false) {
        pass++;
        System.debug('PIN IS SINGLE USE: PASS');
    } else {
        fail++;
        System.debug('PIN IS SINGLE USE: FAIL — the same code verified twice');
    }
} catch (Exception e) {
    fail++;
    System.debug('PIN IS SINGLE USE: FAIL — ' + e.getMessage());
}

// ===== 8. Decline refuses a malformed token =====
try {
    Map<String, Object> r = DocGenSignatureController.declineSignature('nope', 'testing', '1.2.3.4', 'E2E/06d');
    if (r.get('success') == false) {
        pass++;
        System.debug('DECLINE REJECTS BAD TOKEN: PASS');
    } else {
        fail++;
        System.debug('DECLINE REJECTS BAD TOKEN: FAIL');
    }
} catch (Exception e) {
    fail++;
    System.debug('DECLINE REJECTS BAD TOKEN: FAIL — ' + e.getMessage());
}

// ===== 9. Declining records the refusal on signer AND request =====
try {
    String reason = 'Terms are unacceptable';
    Map<String, Object> r = DocGenSignatureController.declineSignature(
        tok.get('decline'),
        reason,
        '1.2.3.4',
        'E2E/06d'
    );
    DocGen_Signer__c s = [
        SELECT Status__c, Decline_Reason__c, Signature_Data__c
        FROM DocGen_Signer__c
        WHERE Id = :sid.get('decline')
    ];
    DocGen_Signature_Request__c rq = [SELECT Status__c FROM DocGen_Signature_Request__c WHERE Id = :decReq.Id];
    // Signature_Data__c must be cleared (#91): the cached preview carries the
    // name the signer typed BEFORE declining, and re-serving it would show a
    // declined document as though it had been signed.
    Boolean ok =
        r.get('success') == true &&
        s.Status__c == 'Declined' &&
        s.Decline_Reason__c == reason &&
        s.Signature_Data__c == null &&
        rq.Status__c == 'Declined';
    if (ok) {
        pass++;
        System.debug('DECLINE RECORDS REFUSAL: PASS — reason kept, preview cleared, request Declined');
    } else {
        fail++;
        System.debug(
            'DECLINE RECORDS REFUSAL: FAIL — success=' +
                r.get('success') +
                ' signer=' +
                s.Status__c +
                ' reason=' +
                s.Decline_Reason__c +
                ' previewCleared=' +
                (s.Signature_Data__c == null) +
                ' request=' +
                rq.Status__c
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('DECLINE RECORDS REFUSAL: FAIL — ' + e.getMessage());
}

// ===== 10. Declining twice is refused =====
try {
    Map<String, Object> r = DocGenSignatureController.declineSignature(
        tok.get('decline'),
        'again',
        '1.2.3.4',
        'E2E/06d'
    );
    if (r.get('success') == false && String.valueOf(r.get('message')).containsIgnoreCase('already declined')) {
        pass++;
        System.debug('DOUBLE DECLINE REFUSED: PASS');
    } else {
        fail++;
        System.debug('DOUBLE DECLINE REFUSED: FAIL — ' + r);
    }
} catch (Exception e) {
    fail++;
    System.debug('DOUBLE DECLINE REFUSED: FAIL — ' + e.getMessage());
}

// ===== 11. A declined link opens to a DECLINED CARD, not a signable document =====
// The link deliberately stays valid (#91) — validateToken still returns
// isValid, and closing it would show the signer a generic "invalid link" error
// for something they did on purpose. The guarantee lives one step later: the
// document fetch must short-circuit to the declined card. Asserting the link is
// dead would assert the opposite of the intended design; what actually matters
// is that a declined request can never serve a signable preview again.
try {
    DocGenSignatureController.SignatureInitResponse v = DocGenSignatureController.fetchDocumentData(tok.get('decline'));
    String html = v.templateBase64 == null ? '' : v.templateBase64;
    Boolean showsDeclined = html.contains('Signature Request Declined');
    Boolean leaksReason = html.contains('Terms are unacceptable');
    if (showsDeclined && leaksReason) {
        pass++;
        System.debug('DECLINED STATE SERVED: PASS — declined card with the reason');
    } else {
        fail++;
        System.debug('DECLINED STATE SERVED: FAIL — card=' + showsDeclined + ' reasonShown=' + leaksReason);
    }
} catch (Exception e) {
    fail++;
    System.debug('DECLINED STATE SERVED: FAIL — ' + e.getMessage());
}

// ===== Cleanup — records only; e2e-08 reclaims files in a later transaction =====
Integer cleanupErrors = 0;
try {
    Database.delete([SELECT Id FROM DocGen_Signature_Request__c WHERE Id IN (:pinReq.Id, :decReq.Id)], false);
    // #367 — restore both switches to their default (off); the template is shared
    // across e2e scripts and must not leak this run's state into later ones.
    DocGenSetupController.saveDeclineSettings(false);
    update new DocGen_Template__c(Id = tmplId, Show_Signer_Decline__c = false);
} catch (Exception e) {
    cleanupErrors++;
    System.debug('CLEANUP: ' + e.getMessage());
}
if (cleanupErrors == 0) {
    pass++;
    System.debug('CLEANUP: PASS');
} else {
    fail++;
    System.debug('CLEANUP: FAIL');
}

System.debug('========================================');
System.debug(
    'E2E-06D PIN + DECLINE — PASS: ' +
        pass +
        '  FAIL: ' +
        fail +
        (fail == 0 ? '  ALL TESTS PASSED' : '  FAILURES DETECTED')
);
System.debug('========================================');

// NOTE (not a test assertion — recorded where the next reader will meet it):
// PIN_Hash__c is SHA-256(pin) with no salt and no iteration. The value space is
// 10^6, so a complete lookup table is a few seconds of work and a few tens of
// MB. Anyone who can read the field can therefore recover the live code, and the
// email round-trip the gate is meant to force stops being a factor. Salting with
// the signer Id or Secure_Token__c would close it without changing the flow. The
// token is still required alongside, so this weakens a second factor rather than
// opening the door on its own.

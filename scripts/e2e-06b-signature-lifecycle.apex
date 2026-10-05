// DocGen E2E Test 06b — Signature Lifecycle (expiration, reminder schedule, resend, friendly errors)
// Depends on: e2e-02 (Account 'E2E Test Corp', Template 'E2E Test Template')
// Expected: PASS: N  FAIL: 0
// Note: reminder-schedulable send progression is unit-tested (needs @TestVisible
// threshold injection, unreachable from anonymous Apex), and the friendly-error
// paths (invalid schedule, oversized URL) are unit-tested too — AuraHandledException
// cannot be thrown from anonymous Apex (uncatchable LimitException). This script
// covers the settings round-trip, stamping, enforcement, and resend re-stamp.

Integer pass = 0;
Integer fail = 0;

Id acctId;
List<Account> accts = [SELECT Id FROM Account WHERE Name = 'E2E Test Corp' LIMIT 1];
List<DocGen_Template__c> tmpls = [SELECT Id FROM DocGen_Template__c WHERE Name = 'E2E Test Template' LIMIT 1];
if (accts.isEmpty() || tmpls.isEmpty()) {
    System.debug('========================================');
    System.debug('E2E-06B LIFECYCLE — PASS: 0  FAIL: 1  ABORTED (run e2e-02 first)');
    System.debug('========================================');
    return;
}
acctId = accts[0].Id;

// Snapshot settings so this script restores org state on exit.
DocGen_Settings__c beforeSettings = DocGen_Settings__c.getOrgDefaults();
Boolean prevEnabled = beforeSettings.Signature_Reminder_Enabled__c == true;
Decimal prevHours = beforeSettings.Signature_Reminder_Hours__c;
String prevSchedule = beforeSettings.Signature_Reminder_Schedule__c;
Decimal prevExpDays = beforeSettings.Signature_Expiration_Days__c;

// ===== 1. Reminder schedule + expiration save round-trip (normalized, sorted) =====
try {
    DocGenSetupController.saveReminderSettings(true, 24, ' 168, 24 , 72 ', 30);
    DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
    if (s.Signature_Reminder_Schedule__c == '24,72,168' && s.Signature_Expiration_Days__c == 30) {
        pass++;
        System.debug('REMINDER SCHEDULE SAVE: PASS');
    } else {
        fail++;
        System.debug(
            'REMINDER SCHEDULE SAVE: FAIL — got schedule=' +
                s.Signature_Reminder_Schedule__c +
                ' expDays=' +
                s.Signature_Expiration_Days__c
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('REMINDER SCHEDULE SAVE: FAIL — ' + e.getMessage());
}

// ===== 2. New request stamps Expires_At__c from the 30-day org default =====
Id lifecycleReqId;
try {
    String reqToken = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Crypto.generateAesKey(256)));
    DocGen_Signature_Request__c sr = new DocGen_Signature_Request__c(
        Status__c = 'Sent',
        Related_Record_Id__c = acctId,
        Template__c = tmpls[0].Id,
        Secure_Token__c = reqToken,
        Expires_At__c = DocGenSignatureExpiry.computeExpiry(null)
    );
    insert sr;
    lifecycleReqId = sr.Id;
    DocGen_Signature_Request__c stamped = [
        SELECT Expires_At__c
        FROM DocGen_Signature_Request__c
        WHERE Id = :sr.Id
    ];
    Long deltaMs = stamped.Expires_At__c.getTime() - System.now().addDays(30).getTime();
    if (Math.abs(deltaMs) < 5 * 60 * 1000) {
        pass++;
        System.debug('EXPIRY STAMP (ORG DEFAULT 30D): PASS');
    } else {
        fail++;
        System.debug('EXPIRY STAMP (ORG DEFAULT 30D): FAIL — ' + stamped.Expires_At__c);
    }
} catch (Exception e) {
    fail++;
    System.debug('EXPIRY STAMP (ORG DEFAULT 30D): FAIL — ' + e.getMessage());
}

// ===== 3. Per-send override beats the org default =====
try {
    Datetime overridden = DocGenSignatureExpiry.computeExpiry(7);
    Long deltaMs = overridden.getTime() - System.now().addDays(7).getTime();
    if (Math.abs(deltaMs) < 60000) {
        pass++;
        System.debug('EXPIRY OVERRIDE (7D): PASS');
    } else {
        fail++;
        System.debug('EXPIRY OVERRIDE (7D): FAIL — ' + overridden);
    }
} catch (Exception e) {
    fail++;
    System.debug('EXPIRY OVERRIDE (7D): FAIL — ' + e.getMessage());
}

// ===== 4. Backdated Expires_At__c rejects the signer link =====
Id signerId;
String signerToken = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Crypto.generateAesKey(256)));
try {
    insert new DocGen_Signer__c(
        Signature_Request__c = lifecycleReqId,
        Signer_Name__c = 'Lifecycle Signer',
        Signer_Email__c = 'lifecycle@e2etest.example.com',
        Secure_Token__c = signerToken,
        Status__c = 'Pending',
        Sort_Order__c = 1
    );
    update new DocGen_Signature_Request__c(Id = lifecycleReqId, Expires_At__c = System.now().addMinutes(-5));
    DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(signerToken);
    if (res.isValid == false && res.errorMessage != null && res.errorMessage.containsIgnoreCase('expired')) {
        pass++;
        System.debug('EXPIRED STAMP REJECTS LINK: PASS');
    } else {
        fail++;
        System.debug('EXPIRED STAMP REJECTS LINK: FAIL — valid=' + res.isValid + ' msg=' + res.errorMessage);
    }
} catch (Exception e) {
    fail++;
    System.debug('EXPIRED STAMP REJECTS LINK: FAIL — ' + e.getMessage());
}

// ===== 5. Resend re-stamps a fresh window + rotates tokens =====
try {
    DocGenSignatureSenderController.resendSignatureRequest(lifecycleReqId);
    DocGen_Signature_Request__c resent = [
        SELECT Expires_At__c, Status__c
        FROM DocGen_Signature_Request__c
        WHERE Id = :lifecycleReqId
    ];
    DocGen_Signer__c rotated = [
        SELECT Secure_Token__c, Status__c
        FROM DocGen_Signer__c
        WHERE Signature_Request__c = :lifecycleReqId
        LIMIT 1
    ];
    if (resent.Expires_At__c > System.now() && resent.Status__c == 'Sent' && rotated.Secure_Token__c != signerToken) {
        pass++;
        System.debug('RESEND RESTAMPS + ROTATES: PASS');
    } else {
        fail++;
        System.debug('RESEND RESTAMPS + ROTATES: FAIL — exp=' + resent.Expires_At__c + ' status=' + resent.Status__c);
    }
} catch (Exception e) {
    fail++;
    System.debug('RESEND RESTAMPS + ROTATES: FAIL — ' + e.getMessage());
}

// ===== 6. Guided requests resolve to the PDF signing page =====
try {
    DocGen_Signature_Request__c guided = new DocGen_Signature_Request__c(Source_Document_Id__c = '068000000000001AAA');
    DocGen_Signature_Request__c classic = new DocGen_Signature_Request__c();
    if (
        DocGenSignatureSenderController.resolveSigningPath(guided) ==
        DocGenSignatureSenderController.getSigningPdfPagePath() &&
        DocGenSignatureSenderController.resolveSigningPath(classic) ==
        DocGenSignatureSenderController.getSigningPagePath()
    ) {
        pass++;
        System.debug('SIGNING PATH ROUTING: PASS');
    } else {
        fail++;
        System.debug('SIGNING PATH ROUTING: FAIL');
    }
} catch (Exception e) {
    fail++;
    System.debug('SIGNING PATH ROUTING: FAIL — ' + e.getMessage());
}

// ===== 7. Completion-email attachment overloads are best-effort (never throw) =====
try {
    DocGenSignatureEmailService.sendAllSignedNotification(lifecycleReqId, Blob.valueOf('%PDF-1.4 x'), 'E2E - Signed');
    DocGenSignatureEmailService.sendSignerCompletionEmails(lifecycleReqId, Blob.valueOf('%PDF-1.4 x'), 'E2E - Signed');
    DocGenSignatureEmailService.sendAllSignedNotification(lifecycleReqId, null, null);
    pass++;
    System.debug('ATTACHMENT OVERLOADS NO-THROW: PASS');
} catch (Exception e) {
    fail++;
    System.debug('ATTACHMENT OVERLOADS NO-THROW: FAIL — ' + e.getMessage());
}

// ===== 8. #369 — per-brand sender identity =====
// A template's Sending Brand resolves for its requests and drives the
// signature email's colour + footer + OWA. Sending Brand blank = unchanged.
Id brandTmplId = tmpls[0].Id;
DocGen_Brand__c e2eBrand = new DocGen_Brand__c(
    Name = 'E2E Brand ' + Datetime.now().getTime(),
    Brand_Color__c = '#AB12CD',
    Footer_Text__c = 'E2E brand footer line',
    Company_Name__c = 'E2E Brand Co',
    OWA_Id__c = '0D2000000000001AAA',
    Is_Active__c = true
);
try {
    insert e2eBrand;
    update new DocGen_Template__c(Id = brandTmplId, Brand__c = e2eBrand.Id);

    DocGen_Signature_Request__c brandReq = new DocGen_Signature_Request__c(
        Status__c = 'Sent',
        Template__c = brandTmplId,
        Related_Record_Id__c = acctId,
        Expires_At__c = System.now().addDays(30)
    );
    insert brandReq;

    Boolean resolves = DocGenBrandResolver.resolveBrandForRequest(brandReq.Id) == e2eBrand.Id;
    DocGen_Brand__c got = DocGenBrandResolver.getBrand(e2eBrand.Id);
    Boolean brandRead = got != null && got.Brand_Color__c == '#AB12CD' && got.OWA_Id__c == '0D2000000000001AAA';

    DocGenEmailTemplateService.RenderedEmail em = DocGenEmailTemplateService.render(
        DocGenEmailTemplateService.TYPE_REQUEST,
        new Map<String, String>{
            'SignerName' => 'E2E',
            'CompanyName' => 'x',
            'DocumentTitle' => 'Doc',
            'SignatureUrl' => 'https://example.com/s',
            'ExpirationHours' => '48'
        },
        null,
        e2eBrand.Id
    );
    Boolean colourInEmail = em != null && em.htmlBody != null && em.htmlBody.containsIgnoreCase('AB12CD');
    Boolean footerInEmail = em != null && em.htmlBody != null && em.htmlBody.contains('E2E brand footer line');

    // Sending Brand blank → a fresh request resolves to no brand (default path).
    update new DocGen_Template__c(Id = brandTmplId, Brand__c = null);
    DocGen_Signature_Request__c noBrandReq = new DocGen_Signature_Request__c(
        Status__c = 'Sent',
        Template__c = brandTmplId,
        Related_Record_Id__c = acctId,
        Expires_At__c = System.now().addDays(30)
    );
    insert noBrandReq;
    Boolean blankIsNull = DocGenBrandResolver.resolveBrandForRequest(noBrandReq.Id) == null;

    delete [SELECT Id FROM DocGen_Signature_Request__c WHERE Id IN (:brandReq.Id, :noBrandReq.Id)];

    if (resolves && brandRead && colourInEmail && footerInEmail && blankIsNull) {
        pass++;
        System.debug('PER-BRAND SENDER IDENTITY: PASS');
    } else {
        fail++;
        System.debug(
            'PER-BRAND SENDER IDENTITY: FAIL — resolves=' +
                resolves +
                ' brandRead=' +
                brandRead +
                ' colour=' +
                colourInEmail +
                ' footer=' +
                footerInEmail +
                ' blankNull=' +
                blankIsNull
        );
    }
} catch (Exception e) {
    fail++;
    System.debug('PER-BRAND SENDER IDENTITY: FAIL — ' + e.getMessage());
}

// ===== Cleanup: delete lifecycle request, restore settings =====
try {
    delete [SELECT Id FROM DocGen_Signature_Request__c WHERE Id = :lifecycleReqId];
    // #369 — the shared template must not leak a Sending Brand to later scripts.
    update new DocGen_Template__c(Id = tmpls[0].Id, Brand__c = null);
    if (e2eBrand.Id != null) {
        delete [SELECT Id FROM DocGen_Brand__c WHERE Id = :e2eBrand.Id];
    }
    DocGen_Settings__c restore = DocGen_Settings__c.getOrgDefaults();
    restore.Signature_Reminder_Enabled__c = prevEnabled;
    restore.Signature_Reminder_Hours__c = prevHours;
    restore.Signature_Reminder_Schedule__c = prevSchedule;
    restore.Signature_Expiration_Days__c = prevExpDays;
    upsert restore;
    // saveReminderSettings(true, ...) above scheduled the hourly job; put the cron
    // back to the pre-script state.
    if (!prevEnabled) {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'DocGen Signature Reminders']) {
            System.abortJob(ct.Id);
        }
    }
    pass++;
    System.debug('CLEANUP: PASS');
} catch (Exception e) {
    fail++;
    System.debug('CLEANUP: FAIL — ' + e.getMessage());
}

System.debug('========================================');
System.debug('E2E-06B LIFECYCLE — PASS: ' + pass + '  FAIL: ' + fail + (fail == 0 ? '  ALL TESTS PASSED' : ''));
System.debug('========================================');

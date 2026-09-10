/**
 * Tests for the configurable "Decline to Sign" button (#367): an org-wide "Hide
 * Decline Button" switch AND a per-template one, both plain checkboxes that are
 * unchecked by default — so Decline shows everywhere until an admin turns one on,
 * and nothing changes on upgrade. Checking either one hides Decline. Resolved live
 * on every validateToken call rather than stamped at send time, so an admin flip
 * also reaches signature requests that already went out. Requests with no template
 * at all are gated by the org-wide switch alone.
 */
@IsTest
private class DocGenDeclineToggleTest {
    private static Id createTemplate(Boolean hideDecline) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Decline ' + Datetime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Hide_Signer_Decline__c = hideDecline
        );
        insert tmpl;
        return tmpl.Id;
    }

    /** A template inserted without touching Hide_Signer_Decline__c — it takes the field default (unchecked). */
    private static Id createTemplateFieldDefault() {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Decline ' + Datetime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tmpl;
        return tmpl.Id;
    }

    private static String insertSignerFor(Id templateId) {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent', Template__c = templateId);
        insert req;
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Signer',
            Signer_Email__c = 'signer@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = token,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        return token;
    }

    // ---- Default state: nothing configured → Decline shows (upgrade-safe) ----
    @IsTest
    static void defaultState_declineShows() {
        Id tplId = createTemplateFieldDefault();
        String token = insertSignerFor(tplId);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(true, res.showDecline, 'with nothing configured, Decline shows by default');
    }

    // ---- Template hides Decline → hidden for that template ----
    @IsTest
    static void templateHidden_declineHidden() {
        Id tplId = createTemplate(true);
        String token = insertSignerFor(tplId);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, res.showDecline, 'a template can hide Decline for its own requests');
    }

    // ---- Org master switch hides Decline → hidden everywhere, even for a template that did not ----
    @IsTest
    static void orgHidden_declineHiddenEverywhere() {
        Id tplId = createTemplate(false);
        String token = insertSignerFor(tplId);
        DocGenSetupController.saveDeclineSettings(true);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, res.showDecline, 'the org-wide switch hides Decline regardless of the template');
    }

    // ---- Neither switch set → Decline shows ----
    @IsTest
    static void neitherHidden_declineShows() {
        Id tplId = createTemplate(false);
        String token = insertSignerFor(tplId);
        DocGenSetupController.saveDeclineSettings(false);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(true, res.showDecline, 'org not hiding and template not hiding → Decline shows');
    }

    // ---- Server-side enforcement: declineSignature refuses when the button is hidden,
    // not just validateToken's response — closes the dev-tools-bypass gap. ----
    @IsTest
    static void declineSignature_blockedWhenTemplateHidden() {
        Id tplId = createTemplate(true);
        String token = insertSignerFor(tplId);

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.declineSignature(token, 'test reason', '1.1.1.1', 'ua');
        Test.stopTest();

        System.assertEquals(false, result.get('success'), 'decline is refused when the template hid Decline');
        DocGen_Signer__c s = [SELECT Status__c FROM DocGen_Signer__c WHERE Secure_Token__c = :token];
        System.assertEquals('Pending', s.Status__c, 'signer status is untouched by the refused decline');
    }

    @IsTest
    static void declineSignature_allowedByDefault() {
        Id tplId = createTemplateFieldDefault();
        String token = insertSignerFor(tplId);

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.declineSignature(token, 'test reason', '1.1.1.1', 'ua');
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'decline succeeds with nothing configured (shown by default)');
        DocGen_Signer__c s = [SELECT Status__c FROM DocGen_Signer__c WHERE Secure_Token__c = :token];
        System.assertEquals('Declined', s.Status__c, 'signer status reflects the successful decline');
    }

    // ---- No template on the request (source-document send) → org switch alone decides ----
    @IsTest
    static void noTemplate_orgSwitchAloneDecides() {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(Status__c = 'Sent');
        insert req;
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signer__c(
            Signature_Request__c = req.Id,
            Signer_Name__c = 'Signer',
            Signer_Email__c = 'signer@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = token,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse shownRes = DocGenSignatureController.validateToken(token);
        DocGenSetupController.saveDeclineSettings(true);
        DocGenSignatureController.SignatureInitResponse hiddenRes = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(true, shownRes.showDecline, 'no template + org default → shown');
        System.assertEquals(
            false,
            hiddenRes.showDecline,
            'no template + org hiding → hidden, org switch alone gates it'
        );
    }

    // ---- Legacy request path (no signer rows, request-level Secure_Token__c) ----
    // validateLegacyRequest carries no template, so the org-wide switch alone
    // decides — and it must still default to shown (regression: it left
    // showDecline null, hiding the button on every legacy signing page).
    private static String insertLegacyRequest() {
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Signer_Name__c = 'Legacy Signer',
            Secure_Token__c = token,
            Expires_At__c = System.now().addDays(7)
        );
        return token;
    }

    @IsTest
    static void legacyRequest_declineShowsByDefault() {
        String token = insertLegacyRequest();

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(true, res.isValid, 'legacy request resolves');
        System.assertEquals(true, res.showDecline, 'legacy signing page shows Decline by default');
    }

    @IsTest
    static void legacyRequest_orgSwitchHidesDecline() {
        String token = insertLegacyRequest();
        DocGenSetupController.saveDeclineSettings(true);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, res.showDecline, 'the org-wide switch hides Decline on the legacy path too');
    }

    // ---- Org settings round-trip ----
    @IsTest
    static void saveDeclineSettings_roundTrips() {
        Test.startTest();
        DocGenSetupController.saveDeclineSettings(true);
        Test.stopTest();
        Map<String, Object> s = DocGenSetupController.getSettingsFresh();
        System.assertEquals(true, s.get('Signature_Hide_Decline__c'));
    }

    // ---- Command Hub template editor save path persists the new field ----
    @IsTest
    static void templateEditor_savesHideDeclineField() {
        Id tplId = createTemplate(false);
        Test.startTest();
        DocGenController.saveTemplate(
            new Map<String, Object>{
                'Id' => tplId,
                'Name' => 'Decline Edit',
                'Type__c' => 'HTML',
                'Base_Object_API__c' => 'Account',
                'Query_Config__c' => 'Name',
                'Hide_Signer_Decline__c' => true
            },
            false,
            null
        );
        Test.stopTest();
        DocGen_Template__c t = [SELECT Hide_Signer_Decline__c FROM DocGen_Template__c WHERE Id = :tplId];
        System.assertEquals(true, t.Hide_Signer_Decline__c, 'editor save persists the per-template hide');
    }
}

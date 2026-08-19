/**
 * Tests for the configurable "Decline to Sign" button (#367): an org-wide master
 * switch AND a per-template opt-in, both off by default, both required together for
 * Decline to appear — resolved live on every validateToken call rather than stamped
 * at send time, so an org-wide flip also reaches signature requests that already
 * went out. Requests with no template at all are gated by the org-wide switch alone.
 */
@IsTest
private class DocGenDeclineToggleTest {
    private static Id createTemplate(Boolean showDecline) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Decline ' + Datetime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Show_Signer_Decline__c = showDecline
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

    // ---- Default state: both off → Decline hidden ----
    @IsTest
    static void bothOff_declineHidden() {
        Id tplId = createTemplate(false);
        String token = insertSignerFor(tplId);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, res.showDecline, 'both org and template default off — Decline stays hidden');
    }

    // ---- Template opts in alone (org still off) → still hidden ----
    @IsTest
    static void templateOnly_stillHidden() {
        Id tplId = createTemplate(true);
        String token = insertSignerFor(tplId);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, res.showDecline, 'template alone cannot show Decline while the org switch is off');
    }

    // ---- Org turns on alone (template still off) → still hidden ----
    @IsTest
    static void orgOnly_stillHidden() {
        Id tplId = createTemplate(false);
        String token = insertSignerFor(tplId);
        DocGenSetupController.saveDeclineSettings(true);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(
            false,
            res.showDecline,
            'org alone cannot show Decline while this template has not opted in'
        );
    }

    // ---- Both on → Decline shows ----
    @IsTest
    static void bothOn_declineShows() {
        Id tplId = createTemplate(true);
        String token = insertSignerFor(tplId);
        DocGenSetupController.saveDeclineSettings(true);

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse res = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(true, res.showDecline, 'org on AND template on together show Decline');
    }

    // ---- Server-side enforcement: declineSignature refuses when the button would be
    // hidden, not just validateToken's response — closes the dev-tools-bypass gap. ----
    @IsTest
    static void declineSignature_blockedWhenNotShown() {
        Id tplId = createTemplate(false); // default off, org also off
        String token = insertSignerFor(tplId);

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.declineSignature(token, 'test reason', '1.1.1.1', 'ua');
        Test.stopTest();

        System.assertEquals(false, result.get('success'), 'decline is refused when showDecline resolves to false');
        DocGen_Signer__c s = [SELECT Status__c FROM DocGen_Signer__c WHERE Secure_Token__c = :token];
        System.assertEquals('Pending', s.Status__c, 'signer status is untouched by the refused decline');
    }

    @IsTest
    static void declineSignature_allowedWhenShown() {
        Id tplId = createTemplate(true);
        String token = insertSignerFor(tplId);
        DocGenSetupController.saveDeclineSettings(true);

        Test.startTest();
        Map<String, Object> result = DocGenSignatureController.declineSignature(token, 'test reason', '1.1.1.1', 'ua');
        Test.stopTest();

        System.assertEquals(true, result.get('success'), 'decline succeeds when both org and template show Decline');
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
        DocGenSignatureController.SignatureInitResponse offRes = DocGenSignatureController.validateToken(token);
        DocGenSetupController.saveDeclineSettings(true);
        DocGenSignatureController.SignatureInitResponse onRes = DocGenSignatureController.validateToken(token);
        Test.stopTest();

        System.assertEquals(false, offRes.showDecline, 'no template + org off → hidden');
        System.assertEquals(true, onRes.showDecline, 'no template + org on → shown, org switch alone gates it');
    }

    // ---- Org settings round-trip ----
    @IsTest
    static void saveDeclineSettings_roundTrips() {
        Test.startTest();
        DocGenSetupController.saveDeclineSettings(true);
        Test.stopTest();
        Map<String, Object> s = DocGenSetupController.getSettingsFresh();
        System.assertEquals(true, s.get('Signature_Show_Decline__c'));
    }

    // ---- Command Hub template editor save path persists the new field ----
    @IsTest
    static void templateEditor_savesShowDeclineField() {
        Id tplId = createTemplate(false);
        Test.startTest();
        DocGenController.saveTemplate(
            new Map<String, Object>{
                'Id' => tplId,
                'Name' => 'Decline Edit',
                'Type__c' => 'HTML',
                'Base_Object_API__c' => 'Account',
                'Query_Config__c' => 'Name',
                'Show_Signer_Decline__c' => true
            },
            false,
            null
        );
        Test.stopTest();
        DocGen_Template__c t = [SELECT Show_Signer_Decline__c FROM DocGen_Template__c WHERE Id = :tplId];
        System.assertEquals(true, t.Show_Signer_Decline__c, 'editor save persists the decline opt-in');
    }
}

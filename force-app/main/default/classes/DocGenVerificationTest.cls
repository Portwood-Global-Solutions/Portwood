/**
 * Tests for configurable signer verification (#verification): the org → template →
 * per-send cascade resolved at send and stamped on the request, the verification-aware
 * validateToken response, and the org-default settings round-trip.
 */
@IsTest
private class DocGenVerificationTest {
    @TestSetup
    static void setup() {
        insert new Account(Name = 'Verif Co', Industry = 'Technology');
    }

    private static Id createTaggedTemplate(String verification, String prefill) {
        DocGen_Template__c tmpl = new DocGen_Template__c(
            Name = 'Verif ' + Datetime.now().getTime() + Math.mod(Crypto.getRandomInteger(), 100000),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Industry',
            Signer_Verification__c = verification,
            Prefill_Signer_Email__c = prefill
        );
        insert tmpl;
        String body = '<html><body><h1>{Name}</h1><p>Sign: {@Signature_Member:1:Full}</p></body></html>';
        ContentVersion cv = new ContentVersion(
            Title = tmpl.Name + ' Body',
            PathOnClient = 'body.html',
            VersionData = Blob.valueOf(body),
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

    private static String signersJson() {
        return '[{"signerName":"Member One","signerEmail":"m1@example.com","roleName":"Member"}]';
    }

    private static DocGen_Signature_Request__c reqFor(Id tplId) {
        return [
            SELECT Require_Email_Verification__c, Prefill_Signer_Email__c
            FROM DocGen_Signature_Request__c
            WHERE Template__c = :tplId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
    }

    @IsTest
    static void certificateVerificationUsesPublicSiteBase() {
        String token = DocGenSignatureSenderController.generateRequestVerificationToken();
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Secure_Token__c = token,
            Status__c = 'Sent'
        );
        insert request;

        String url = DocGenSignatureService.buildVerifyUrl(request.Id, ' verify.example.com/portal/s/ ');
        System.assert(url.startsWith('https://verify.example.com/portal/apex/'), url);
        System.assert(url.endsWith('DocGenVerify?token=' + token), url);
        System.assertEquals(
            null,
            DocGenSignatureService.buildVerifyUrl(request.Id, 'https://<CONFIGURE_SITE_URL_IN_SETUP>')
        );
        System.assertEquals(null, DocGenSignatureService.buildVerifyUrl(request.Id, 'ftp://verify.example.com/portal'));
    }

    // ---- Cascade: per-send override wins ----
    @IsTest
    static void perSendOverride_turnsVerificationOff() {
        Id tplId = createTaggedTemplate('Required', 'Inherit'); // template says Required...
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        // ...but the per-send override forces it OFF.
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(
            tplId,
            a.Id,
            signersJson(),
            'Parallel',
            null,
            false,
            true
        );
        Test.stopTest();
        DocGen_Signature_Request__c req = reqFor(tplId);
        System.assertEquals(false, req.Require_Email_Verification__c, 'per-send false overrides template Required');
        System.assertEquals(true, req.Prefill_Signer_Email__c, 'per-send prefill true applied');
    }

    // ---- Cascade: template default applies when no per-send override ----
    @IsTest
    static void templateDefault_off_applies() {
        Id tplId = createTaggedTemplate('Off', 'Yes');
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();
        DocGen_Signature_Request__c req = reqFor(tplId);
        System.assertEquals(false, req.Require_Email_Verification__c, 'template Off resolves to not-required');
        System.assertEquals(true, req.Prefill_Signer_Email__c, 'template prefill Yes resolves to true');
    }

    // ---- Cascade: template Inherit + (no org row) → default required ----
    @IsTest
    static void templateInherit_defaultsRequired() {
        Id tplId = createTaggedTemplate('Inherit', 'Inherit');
        Account a = [SELECT Id FROM Account LIMIT 1];
        Test.startTest();
        DocGenSignatureSenderController.createGuidedPdfSignatureRequest(tplId, a.Id, signersJson(), 'Parallel', null);
        Test.stopTest();
        DocGen_Signature_Request__c req = reqFor(tplId);
        System.assertEquals(true, req.Require_Email_Verification__c, 'inherit with no org default → required');
    }

    // ---- validateToken reflects the request flags ----
    @IsTest
    static void validateToken_reflectsVerificationFlags() {
        DocGen_Signature_Request__c offReq = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Require_Email_Verification__c = false,
            Prefill_Signer_Email__c = true
        );
        insert offReq;
        String offTok = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signer__c(
            Signature_Request__c = offReq.Id,
            Signer_Name__c = 'Off',
            Signer_Email__c = 'off@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = offTok,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );

        DocGen_Signature_Request__c onReq = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Require_Email_Verification__c = true,
            Prefill_Signer_Email__c = true
        );
        insert onReq;
        String onTok = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signer__c(
            Signature_Request__c = onReq.Id,
            Signer_Name__c = 'On',
            Signer_Email__c = 'on@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = onTok,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );

        Test.startTest();
        DocGenSignatureController.SignatureInitResponse offRes = DocGenSignatureController.validateToken(offTok);
        DocGenSignatureController.SignatureInitResponse onRes = DocGenSignatureController.validateToken(onTok);
        Test.stopTest();

        System.assertEquals(false, offRes.requiresPin, 'verification off → no PIN required');
        System.assertEquals(false, offRes.prefillEmail, 'prefill is moot when verification is off');
        System.assertEquals(true, onRes.requiresPin, 'verification on + unverified → PIN required');
        System.assertEquals(true, onRes.prefillEmail, 'prefill surfaces when verification is on');
    }

    // ---- Org-default settings round-trip ----
    @IsTest
    static void saveVerificationSettings_roundTrips() {
        Test.startTest();
        DocGenSetupController.saveVerificationSettings(false, true);
        Test.stopTest();
        Map<String, Object> s = DocGenSetupController.getSettingsFresh();
        System.assertEquals(false, s.get('Signature_Require_Email_Verification__c'));
        System.assertEquals(true, s.get('Signature_Prefill_Signer_Email__c'));
    }

    // ---- Command Hub template editor save path persists the template defaults ----
    @IsTest
    static void templateEditor_savesVerificationFields() {
        Id tplId = createTaggedTemplate('Inherit', 'Inherit');
        Test.startTest();
        DocGenController.saveTemplate(
            new Map<String, Object>{
                'Id' => tplId,
                'Name' => 'Verif Edit',
                'Type__c' => 'HTML',
                'Base_Object_API__c' => 'Account',
                'Query_Config__c' => 'Name',
                'Signer_Verification__c' => 'Off',
                'Prefill_Signer_Email__c' => 'Yes'
            },
            false,
            null
        );
        Test.stopTest();
        DocGen_Template__c t = [
            SELECT Signer_Verification__c, Prefill_Signer_Email__c
            FROM DocGen_Template__c
            WHERE Id = :tplId
        ];
        System.assertEquals('Off', t.Signer_Verification__c, 'editor save persists verification');
        System.assertEquals('Yes', t.Prefill_Signer_Email__c, 'editor save persists prefill');
    }
}

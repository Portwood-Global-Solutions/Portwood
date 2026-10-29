@IsTest
private class DocGenSignatureTypeOnlyTest {
    private static Id createTemplate(Boolean typeOnly) {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Type Only ' + Crypto.getRandomInteger(),
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Signature_Type_Only__c = typeOnly
        );
        insert template;
        return template.Id;
    }

    private static DocGen_Signer__c createSigner(Id templateId) {
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Template__c = templateId,
            Require_Email_Verification__c = false
        );
        insert request;
        DocGen_Signer__c signer = new DocGen_Signer__c(
            Signature_Request__c = request.Id,
            Signer_Name__c = 'Test Signer',
            Signer_Email__c = 'signer@example.com',
            Role_Name__c = 'Signer',
            Secure_Token__c = EncodingUtil.convertToHex(Crypto.generateAesKey(256)),
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        insert signer;
        return signer;
    }

    private static void assertCombination(Boolean orgTypeOnly, Boolean templateTypeOnly, Boolean expected) {
        DocGen_Signer__c signer = createSigner(createTemplate(templateTypeOnly));
        DocGenSetupController.saveSignatureInputSettings(orgTypeOnly);
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse response = DocGenSignatureController.validateToken(
            signer.Secure_Token__c
        );
        Test.stopTest();
        System.assertEquals(true, response.isValid);
        System.assertEquals(expected, response.typeOnly, 'Either checkbox must require typed signatures');
        System.assertEquals(true, response.showDecline, 'Signature input settings must not affect Decline');
    }

    @IsTest
    static void neitherCheckedAllowsDrawing() {
        assertCombination(false, false, false);
    }

    @IsTest
    static void orgCheckedOverridesUncheckedTemplate() {
        assertCombination(true, false, true);
    }

    @IsTest
    static void templateCheckedRequiresTyping() {
        assertCombination(false, true, true);
    }

    @IsTest
    static void bothCheckedRequireTyping() {
        assertCombination(true, true, true);
    }

    @IsTest
    static void unsetSettingsPreserveDrawing() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Existing Template',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert template;
        DocGen_Signer__c signer = createSigner(template.Id);
        Test.startTest();
        System.assertEquals(false, DocGenSignatureController.validateToken(signer.Secure_Token__c).typeOnly);
        Test.stopTest();
    }

    @IsTest
    static void orgSettingAppliesWithoutTemplateAndUpdatesPendingRequests() {
        DocGen_Signer__c signer = createSigner(null);
        Test.startTest();
        System.assertEquals(false, DocGenSignatureController.validateToken(signer.Secure_Token__c).typeOnly);
        DocGenSetupController.saveSignatureInputSettings(true);
        System.assertEquals(true, DocGenSignatureController.validateToken(signer.Secure_Token__c).typeOnly);
        DocGenSetupController.saveSignatureInputSettings(false);
        System.assertEquals(false, DocGenSignatureController.validateToken(signer.Secure_Token__c).typeOnly);
        Test.stopTest();
    }

    @IsTest
    static void templateRestrictionDoesNotAffectOtherTemplates() {
        DocGen_Signer__c restricted = createSigner(createTemplate(true));
        DocGen_Signer__c unrestricted = createSigner(createTemplate(false));
        Test.startTest();
        System.assertEquals(true, DocGenSignatureController.validateToken(restricted.Secure_Token__c).typeOnly);
        System.assertEquals(false, DocGenSignatureController.validateToken(unrestricted.Secure_Token__c).typeOnly);
        Test.stopTest();
    }

    @IsTest
    static void settingsAndTemplateEditorRoundTrip() {
        Id templateId = createTemplate(false);
        Test.startTest();
        DocGenSetupController.saveSignatureInputSettings(true);
        System.assertEquals(true, DocGenSetupController.getSettingsFresh().get('Signature_Type_Only__c'));
        DocGenSetupController.saveSignatureInputSettings(null);
        System.assertEquals(false, DocGenSetupController.getSettingsFresh().get('Signature_Type_Only__c'));
        for (Boolean typeOnly : new List<Boolean>{ true, false }) {
            DocGenController.saveTemplate(
                new Map<String, Object>{
                    'Id' => templateId,
                    'Name' => 'Type Only Editor',
                    'Type__c' => 'HTML',
                    'Base_Object_API__c' => 'Account',
                    'Query_Config__c' => 'Name',
                    'Signature_Type_Only__c' => typeOnly
                },
                false,
                null
            );
            DocGen_Template__c saved = [SELECT Signature_Type_Only__c FROM DocGen_Template__c WHERE Id = :templateId];
            System.assertEquals(typeOnly, saved.Signature_Type_Only__c);
            System.assertEquals(typeOnly, DocGenController.getTemplateById(templateId).Signature_Type_Only__c);
        }
        Test.stopTest();
    }

    private static void assertPlacementInput(Boolean orgTypeOnly, Boolean templateTypeOnly) {
        DocGenSetupController.saveSignatureInputSettings(orgTypeOnly);
        DocGen_Signer__c signer = createSigner(createTemplate(templateTypeOnly));
        List<DocGen_Signature_Placement__c> placements = new List<DocGen_Signature_Placement__c>();
        for (String type : new List<String>{ 'Full', 'Initials' }) {
            placements.add(
                new DocGen_Signature_Placement__c(
                    Signature_Request__c = signer.Signature_Request__c,
                    Signer__c = signer.Id,
                    Placement_Type__c = type,
                    Status__c = 'Pending'
                )
            );
        }
        insert placements;
        Test.startTest();
        for (DocGen_Signature_Placement__c placement : placements) {
            try {
                DocGenSignatureController.signPlacement(signer.Secure_Token__c, placement.Id, 'Signed (drawn)');
                System.assert(false, 'A drawn signature must be rejected when either Type Only checkbox is checked');
            } catch (AuraHandledException expected) {
                DocGen_Signature_Placement__c unchanged = [
                    SELECT Status__c, Signed_Value__c
                    FROM DocGen_Signature_Placement__c
                    WHERE Id = :placement.Id
                ];
                System.assertEquals('Pending', unchanged.Status__c);
                System.assertEquals(null, unchanged.Signed_Value__c);
            }
            String value = placement.Placement_Type__c == 'Full' ? 'Test Signer' : 'TS';
            DocGenSignatureController.signPlacement(signer.Secure_Token__c, placement.Id, value);
            DocGen_Signature_Placement__c saved = [
                SELECT Status__c, Signed_Value__c
                FROM DocGen_Signature_Placement__c
                WHERE Id = :placement.Id
            ];
            System.assertEquals('Signed', saved.Status__c);
            System.assertEquals(value, saved.Signed_Value__c);
        }
        Test.stopTest();
    }

    @IsTest
    static void templateTypeOnlyRequiresTypedSignaturesAndInitials() {
        assertPlacementInput(false, true);
    }

    @IsTest
    static void orgTypeOnlyRequiresTypedSignaturesAndInitials() {
        assertPlacementInput(true, false);
    }

    @IsTest
    static void legacyRequestRespectsTemplateTypeOnly() {
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        insert new DocGen_Signature_Request__c(
            Status__c = 'Sent',
            Signer_Name__c = 'Legacy Signer',
            Template__c = createTemplate(true),
            Secure_Token__c = token,
            Expires_At__c = System.now().addDays(7)
        );
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse response = DocGenSignatureController.validateToken(token);
        Test.stopTest();
        System.assertEquals(true, response.isValid);
        System.assertEquals(true, response.typeOnly);
    }

    @IsTest
    static void drawingStillAcceptedWhenBothUnchecked() {
        DocGen_Signer__c signer = createSigner(createTemplate(false));
        DocGen_Signature_Placement__c placement = new DocGen_Signature_Placement__c(
            Signature_Request__c = signer.Signature_Request__c,
            Signer__c = signer.Id,
            Placement_Type__c = 'Full',
            Status__c = 'Pending'
        );
        insert placement;
        Test.startTest();
        DocGenSignatureController.signPlacement(signer.Secure_Token__c, placement.Id, 'Signed (drawn)');
        Test.stopTest();
        placement = [SELECT Status__c, Signed_Value__c FROM DocGen_Signature_Placement__c WHERE Id = :placement.Id];
        System.assertEquals('Signed', placement.Status__c);
        System.assertEquals('Signed (drawn)', placement.Signed_Value__c);
    }
}

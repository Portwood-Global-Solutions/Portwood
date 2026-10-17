@IsTest
private class DocGenSigningBrandingTest {
    private static final String TOKEN = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    private static final String OTHER_TOKEN = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    private static final String LEGACY_TOKEN = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    @TestSetup
    static void setup() {
        insert new DocGen_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Company_Name__c = 'Org identity',
            Signature_Email_Brand_Color__c = '#246810',
            Signature_Email_Footer_Text__c = 'Org footer',
            Signature_Email_Logo_Url__c = 'https://example.com/org.png'
        );
        Account account = new Account(Name = 'Branding test');
        insert account;
        DocGen_Brand__c brand = new DocGen_Brand__c(
            Name = 'Internal brand name',
            Company_Name__c = 'Acme',
            Brand_Color__c = '#135790',
            Logo_Url__c = 'https://example.com/acme.png',
            Footer_Text__c = 'Shared footer',
            Is_Active__c = true,
            Signing_Color__c = '#FFFF00',
            Signing_Header_Color__c = '#113355',
            Signing_Background_Color__c = '#EEF4FA',
            Signing_Title__c = 'Welcome to Acme',
            Signing_Welcome_Text__c = 'Review your agreement.',
            Signing_Footer_Text__c = 'Acme signing',
            Signing_Completion_Message__c = 'Thank you from Acme.',
            Signing_Support_Url__c = 'https://example.com/help'
        );
        insert brand;
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Agreement',
            Base_Object_API__c = 'Account',
            Brand__c = brand.Id
        );
        insert template;
        DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
            Template__c = template.Id,
            Related_Record_Id__c = account.Id,
            Status__c = 'Sent',
            Require_Email_Verification__c = false
        );
        insert request;
        insert new DocGen_Signer__c(
            Signature_Request__c = request.Id,
            Signer_Name__c = 'Pat',
            Signer_Email__c = 'pat@example.com',
            Secure_Token__c = TOKEN,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        DocGen_Brand__c otherBrand = new DocGen_Brand__c(
            Name = 'Other brand',
            Company_Name__c = 'Other company',
            Is_Active__c = true
        );
        insert otherBrand;
        DocGen_Template__c otherTemplate = new DocGen_Template__c(
            Name = 'Other agreement',
            Base_Object_API__c = 'Account',
            Brand__c = otherBrand.Id
        );
        insert otherTemplate;
        DocGen_Signature_Request__c other = new DocGen_Signature_Request__c(
            Template__c = otherTemplate.Id,
            Related_Record_Id__c = account.Id,
            Status__c = 'Sent'
        );
        insert other;
        insert new DocGen_Signer__c(
            Signature_Request__c = other.Id,
            Signer_Name__c = 'Sam',
            Signer_Email__c = 'sam@example.com',
            Secure_Token__c = OTHER_TOKEN,
            Status__c = 'Pending',
            Sort_Order__c = 1
        );
        insert new DocGen_Signature_Request__c(
            Related_Record_Id__c = account.Id,
            Status__c = 'Sent',
            Secure_Token__c = LEGACY_TOKEN
        );
    }

    @IsTest
    static void validTokenGetsOnlyItsOwnBrand() {
        Test.startTest();
        DocGenSignatureController.SignatureInitResponse result = DocGenSignatureController.validateToken(TOKEN);
        DocGenSignatureController.SignatureInitResponse other = DocGenSignatureController.validateToken(OTHER_TOKEN);
        Test.stopTest();
        System.assertEquals(true, result.isValid);
        System.assertEquals('Acme', result.branding.companyName);
        System.assertEquals('https://example.com/acme.png', result.branding.logoUrl);
        System.assertEquals('#FFFF00', result.branding.color);
        System.assertEquals('#113355', result.branding.headerColor);
        System.assertEquals('#EEF4FA', result.branding.backgroundColor);
        System.assertEquals('Welcome to Acme', result.branding.title);
        System.assertEquals('Review your agreement.', result.branding.welcomeText);
        System.assertEquals('Acme signing', result.branding.footerText);
        System.assertEquals('Thank you from Acme.', result.branding.completionMessage);
        System.assertEquals('https://example.com/help', result.branding.supportUrl);
        System.assertEquals('Other company', other.branding.companyName);
        Map<String, Object> publicValues = (Map<String, Object>) JSON.deserializeUntyped(
            JSON.serialize(result.branding)
        );
        System.assertEquals(
            new Set<String>{
                'page',
                'companyName',
                'logoUrl',
                'color',
                'headerColor',
                'backgroundColor',
                'title',
                'welcomeText',
                'footerText',
                'completionMessage',
                'supportUrl'
            },
            publicValues.keySet(),
            'Only public presentation fields may leave the controller'
        );
        System.assert(!JSON.serialize(result.branding).contains('Internal brand name'));
    }

    @IsTest
    static void invalidExpiredAndInactiveRequestsDoNotExposeBranding() {
        System.assertEquals(null, DocGenSignatureController.validateToken('bad').branding);
        System.assertEquals(
            null,
            DocGenSignatureController.validateToken('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')
                .branding
        );
        DocGen_Signature_Request__c request = [
            SELECT Id, Expires_At__c
            FROM DocGen_Signature_Request__c
            WHERE Template__r.Name = 'Agreement'
        ];
        request.Expires_At__c = System.now().addHours(-1);
        update request;
        System.assertEquals(null, DocGenSignatureController.validateToken(TOKEN).branding);
        request.Expires_At__c = System.now().addHours(1);
        request.Status__c = 'Cancelled';
        update request;
        System.assertEquals(null, DocGenSignatureController.validateToken(TOKEN).branding);
    }

    @IsTest
    static void inactiveBrandAndLegacyRequestUseOrgDefaults() {
        DocGen_Brand__c brand = [SELECT Id FROM DocGen_Brand__c WHERE Company_Name__c = 'Acme'];
        brand.Is_Active__c = false;
        update brand;
        DocGenBrandResolver.clearCache();
        DocGenSigningBranding.Presentation result = DocGenSignatureController.validateToken(TOKEN).branding;
        DocGenSigningBranding.Presentation legacy = DocGenSignatureController.validateToken(LEGACY_TOKEN).branding;
        System.assertEquals('Org identity', result.companyName);
        System.assertEquals('#246810', result.color);
        System.assertEquals('Org footer', result.footerText);
        System.assertEquals('https://example.com/org.png', result.logoUrl);
        System.assertEquals('Review and sign', result.title);
        System.assertEquals('#FFFFFF', result.headerColor);
        System.assertEquals('#F3F2F2', result.backgroundColor);
        System.assertEquals(null, result.supportUrl);
        System.assertEquals('Org identity', legacy.companyName);
    }

    @IsTest
    static void emptyPageValuesInheritSharedIdentityAndRejectUnsafeStoredValues() {
        DocGen_Brand__c brand = [SELECT Id FROM DocGen_Brand__c WHERE Company_Name__c = 'Acme'];
        brand.Signing_Color__c = null;
        brand.Signing_Footer_Text__c = null;
        brand.Signing_Header_Color__c = 'red;bad';
        brand.Logo_Url__c = 'javascript:alert(1)';
        brand.Signing_Support_Url__c = 'http://example.com/help';
        update brand;
        DocGenBrandResolver.clearCache();
        DocGenSigningBranding.Presentation result = DocGenSignatureController.validateToken(TOKEN).branding;
        System.assertEquals('#135790', result.color);
        System.assertEquals('Shared footer', result.footerText);
        System.assertEquals('#FFFFFF', result.headerColor);
        System.assertEquals('https://example.com/org.png', result.logoUrl);
        System.assertEquals(null, result.supportUrl);
    }

    @IsTest
    static void missingOrgDefaultsStillHaveUsableBuiltIns() {
        delete [SELECT Id FROM DocGen_Settings__c];
        DocGenSigningBranding.Presentation result = DocGenSigningBranding.forRequest(null);
        System.assertEquals('Document signing', result.companyName);
        System.assertEquals('#0176D3', result.color);
        System.assertEquals(null, result.logoUrl);
        System.assertNotEquals(null, result.completionMessage);
    }

    @IsTest
    static void brandingSurvivesGuestSharing() {
        List<User> guests = [SELECT Id FROM User WHERE UserType = 'Guest' AND IsActive = TRUE LIMIT 1];
        if (guests.isEmpty())
            return; // Guest coverage is exercised in the Site-enabled scratch org.
        DocGenSignatureController.SignatureInitResponse result;
        System.runAs(guests[0]) {
            Test.startTest();
            result = DocGenSignatureController.validateToken(TOKEN);
            Test.stopTest();
        }
        System.assertEquals(true, result.isValid);
        System.assertEquals('Acme', result.branding.companyName);
        System.assertEquals('https://example.com/acme.png', result.branding.logoUrl);
    }

    @IsTest
    static void validatesAbsoluteHttpsUrls() {
        for (
            String value : new List<String>{
                null,
                '',
                'javascript:alert(1)',
                '//example.com',
                'http://example.com',
                'https://user:password@example.com',
                'https://example.com/\nimage',
                'https://example.com/"image',
                'https://example.com/\\image',
                'https://'
            }
        ) {
            System.assertEquals(
                null,
                DocGenSigningBranding.safeHttpsUrl(value),
                'Unsafe or incomplete URL must be rejected.'
            );
        }
        System.assertEquals(
            'https://example.com/help?q=a&b=c',
            DocGenSigningBranding.safeHttpsUrl(' https://example.com/help?q=a&b=c ')
        );
    }
}

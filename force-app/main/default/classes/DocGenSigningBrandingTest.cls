@IsTest
private class DocGenSigningBrandingTest {
    private static final String ASSET_BASE = URL.getOrgDomainUrl().toExternalForm() + '/resource/';
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
            Signature_Email_Logo_Url__c = 'https://example.com/org.png'.replace('https://example.com/', ASSET_BASE)
        );
        Account account = new Account(Name = 'Branding test');
        insert account;
        DocGen_Brand__c brand = new DocGen_Brand__c(
            Name = 'Internal brand name',
            Company_Name__c = 'Acme',
            Brand_Color__c = '#135790',
            Logo_Url__c = 'https://example.com/acme.png'.replace('https://example.com/', ASSET_BASE),
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
        System.assertEquals(
            'https://example.com/acme.png'.replace('https://example.com/', ASSET_BASE),
            result.branding.logoUrl
        );
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
        System.assertEquals('https://example.com/org.png'.replace('https://example.com/', ASSET_BASE), result.logoUrl);
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
        System.assertEquals('https://example.com/org.png'.replace('https://example.com/', ASSET_BASE), result.logoUrl);
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
        System.assertEquals(
            'https://example.com/acme.png'.replace('https://example.com/', ASSET_BASE),
            result.branding.logoUrl
        );
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
    private static DocGenSigningPageView initialPage(String token) {
        Test.setCurrentPage(Page.DocGenSignaturePdf);
        if (token != null)
            ApexPages.currentPage().getParameters().put('token', token);
        return new DocGenSignatureController().getInitialPage();
    }

    @IsTest
    static void initialRenderIsReadOnlyCachedAndContainsOnlyPresentation() {
        Test.setCurrentPage(Page.DocGenSignature);
        ApexPages.currentPage().getParameters().put('token', TOKEN);
        DocGenSignatureController controller = new DocGenSignatureController();
        Integer writes = Limits.getDmlStatements();
        DocGenSigningPageView view = controller.getInitialPage();
        Integer queries = Limits.getQueries();
        System.assertEquals(true, view.getValid());
        System.assertEquals('Acme', view.getCompanyName());
        System.assertEquals('Acme | Signing with Portwood DocGen', view.getDocumentTitle());
        System.assert(view.getBodyStyle().contains('--signing-action:#FFFF00;--signing-action-text:#000000'));
        System.assert(view.getBodyStyle().contains('--signing-header:#113355;--signing-header-text:#FFFFFF'));
        System.assertEquals(
            'https://example.com/acme.png'.replace('https://example.com/', ASSET_BASE),
            view.getLogoUrl()
        );
        System.assertEquals('', view.getVisibility());
        System.assertEquals('', view.getLogoVisibility());
        System.assertEquals('', view.getSupportVisibility());
        System.assertEquals('', view.getFooterVisibility());
        System.assertEquals('https://example.com/help', view.getSupportUrl());
        System.assertEquals('Acme signing', view.getFooterText());
        System.assertEquals('Thank you from Acme.', view.getCompletionMessage());
        System.assertEquals(view, controller.getInitialPage());
        System.assertEquals(
            queries,
            Limits.getQueries(),
            'Visualforce getter evaluation must reuse the authorized presentation.'
        );
        System.assertEquals(
            writes,
            Limits.getDmlStatements(),
            'Initial rendering must not mark Viewed or publish documents.'
        );
        System.assertEquals(
            'Pending',
            [SELECT Status__c FROM DocGen_Signer__c WHERE Secure_Token__c = :TOKEN].Status__c
        );
        System.assert(!view.getJson().contains('pat@example.com'));
        System.assert(!view.getJson().contains('signerName'));
        System.assert(!view.getJson().contains('Secure_Token'));
        System.assert(!view.getJson().contains('brandingSetId'));
        System.assertEquals('Other company', initialPage(OTHER_TOKEN).getCompanyName());
        System.assertEquals('Org identity', initialPage(LEGACY_TOKEN).getCompanyName());
        System.assertEquals(
            'Sent',
            [SELECT Status__c FROM DocGen_Signature_Request__c WHERE Secure_Token__c = :LEGACY_TOKEN].Status__c
        );
    }

    @IsTest
    static void initialRenderRejectsInvalidExpiredAndInactiveRequests() {
        for (
            String token : new List<String>{
                null,
                'bad',
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            }
        ) {
            DocGenSigningPageView view = initialPage(token);
            System.assertEquals(false, view.getValid());
            System.assertEquals('null', view.getJson());
            System.assertEquals('', view.getBodyStyle());
            System.assertEquals('', view.getBodyClass());
            System.assertEquals('display:none', view.getVisibility());
            System.assertEquals('display:none', view.getLogoVisibility());
            System.assertEquals('display:none', view.getFooterVisibility());
            System.assertEquals('display:none', view.getSupportVisibility());
            System.assertEquals('Portwood DocGen | Document signing', view.getDocumentTitle());
            System.assertEquals('Document signing provided by', view.getServiceContext());
        }
        DocGen_Signature_Request__c request = [
            SELECT Id, Status__c
            FROM DocGen_Signature_Request__c
            WHERE Template__r.Name = 'Agreement'
        ];
        request.Expires_At__c = Datetime.now().addHours(-1);
        update request;
        System.assertEquals(false, initialPage(TOKEN).getValid());
        request.Expires_At__c = Datetime.now().addHours(1);
        request.Status__c = 'Cancelled';
        update request;
        System.assertEquals(false, initialPage(TOKEN).getValid());
        request.Status__c = 'Sent';
        update request;
        DocGen_Signer__c signer = [SELECT Id, Status__c FROM DocGen_Signer__c WHERE Secure_Token__c = :TOKEN];
        signer.Status__c = 'Signed';
        update signer;
        request.Expires_At__c = Datetime.now().addHours(-1);
        update request;
        System.assertEquals(false, initialPage(TOKEN).getValid(), 'Expired completed links remain unavailable.');
    }

    @IsTest
    static void completedSignerHasBrandedReadOnlyConfirmationWithoutPrivateData() {
        DocGen_Signer__c signer = [
            SELECT Id, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :TOKEN
        ];
        signer.Status__c = 'Signed';
        update signer;
        Integer writes = Limits.getDmlStatements();
        DocGenSigningPageView view = initialPage(TOKEN);
        System.assertEquals('Acme', view.getCompanyName());
        System.assertEquals('waiting', view.getCompletionState());
        System.assertEquals('', view.getWaitingVisibility());
        System.assertEquals('display:none', view.getSuccessVisibility());
        System.assertEquals('display:none', view.getLoadingVisibility());
        System.assertEquals('display:none', view.getIntroVisibility());
        DocGenSignatureController.SignatureInitResponse result = DocGenSignatureController.validateToken(TOKEN);
        System.assertEquals(false, result.isValid, 'A confirmation must not reactivate signing.');
        System.assertEquals('waiting', result.completionState);
        System.assertEquals('Acme', result.branding.companyName);
        System.assertEquals(null, result.signerName);
        System.assertEquals(null, result.signerEmail);
        System.assertEquals(null, result.recordId);
        System.assertEquals(null, result.documentTitle);
        System.assertEquals(null, result.documentUrl);
        System.assertEquals(null, result.templateBase64);
        System.assertEquals(null, result.formFields);
        System.assertEquals(null, DocGenSignatureController.fetchDocumentData(TOKEN).documentUrl);
        System.assertEquals(writes, Limits.getDmlStatements(), 'Confirmation performs no DML or publication.');
        update new DocGen_Signature_Request__c(Id = signer.Signature_Request__c, Status__c = 'Signed');
        view = initialPage(TOKEN);
        System.assertEquals('success', view.getCompletionState());
        System.assertEquals('', view.getSuccessVisibility());
        System.assertEquals('display:none', view.getWaitingVisibility());
        System.assertEquals('Thank you from Acme.', view.getCompletionMessage());
        System.assertEquals(false, DocGenSignatureController.validateToken(TOKEN).isValid);
    }

    @IsTest
    static void completedLegacyLinkRetainsBrandingWithoutReopeningDocument() {
        DocGen_Signature_Request__c request = [
            SELECT Id
            FROM DocGen_Signature_Request__c
            WHERE Secure_Token__c = :LEGACY_TOKEN
        ];
        request.Status__c = 'Signed';
        update request;
        Integer writes = Limits.getDmlStatements();
        DocGenSignatureController.SignatureInitResponse result = DocGenSignatureController.validateToken(LEGACY_TOKEN);
        System.assertEquals(false, result.isValid);
        System.assertEquals('success', result.completionState);
        System.assertEquals('Org identity', result.branding.companyName);
        System.assertEquals('success', initialPage(LEGACY_TOKEN).getCompletionState());
        System.assertEquals(null, DocGenSignatureController.fetchDocumentData(LEGACY_TOKEN).documentUrl);
        System.assertEquals(writes, Limits.getDmlStatements());
    }

    @IsTest
    static void completedSignerCannotRevealCancelledDeclinedDraftOrExpiredPresentation() {
        DocGen_Signer__c signer = [
            SELECT Id, Signature_Request__c
            FROM DocGen_Signer__c
            WHERE Secure_Token__c = :TOKEN
        ];
        signer.Status__c = 'Signed';
        update signer;
        for (String status : new List<String>{ 'Cancelled', 'Declined', 'Draft' }) {
            update new DocGen_Signature_Request__c(Id = signer.Signature_Request__c, Status__c = status);
            DocGenSignatureController.SignatureInitResponse result = DocGenSignatureController.validateToken(TOKEN);
            System.assertEquals(false, result.isValid);
            System.assertEquals(null, result.completionState);
            System.assertEquals(null, result.branding);
            System.assertEquals('', initialPage(TOKEN).getCompletionState());
        }
        update new DocGen_Signature_Request__c(
            Id = signer.Signature_Request__c,
            Status__c = 'Signed',
            Expires_At__c = System.now().addHours(-1)
        );
        System.assertEquals(null, DocGenSignatureController.validateToken(TOKEN).branding);
        System.assertEquals('', initialPage(TOKEN).getCompletionState());
    }

    @IsTest
    static void completedConfirmationIsAvailableToGuestWithoutWrites() {
        DocGen_Signer__c signer = [SELECT Id FROM DocGen_Signer__c WHERE Secure_Token__c = :TOKEN];
        signer.Status__c = 'Signed';
        update signer;
        List<User> guests = [SELECT Id FROM User WHERE UserType = 'Guest' AND IsActive = TRUE LIMIT 1];
        if (guests.isEmpty())
            return;
        System.runAs(guests[0]) {
            Integer writes = Limits.getDmlStatements();
            System.assertEquals('Acme', initialPage(TOKEN).getCompanyName());
            System.assertEquals('waiting', initialPage(TOKEN).getCompletionState());
            System.assertEquals(false, DocGenSignatureController.validateToken(TOKEN).isValid);
            System.assertEquals(writes, Limits.getDmlStatements());
        }
    }

    @IsTest
    static void initialAdvancedLayoutUsesSafeStylesAndScriptSafeJson() {
        DocGen_Brand__c brand = [SELECT Id FROM DocGen_Brand__c WHERE Company_Name__c = 'Acme'];
        brand.Company_Name__c = '</script><img src=x onerror=alert(1)>';
        brand.Signing_Page_Config__c = DocGenSigningPageConfig.validateAndSerialize(
            '{"mode":"Advanced","logoUrl":"https://example.com/page.png","bannerUrl":"https://example.com/banner.png","bannerAlt":"Our banner","backgroundUrl":"https://example.com/background.png?a=1&b=2","font":"Humanist","spacing":"Compact","logoAlignment":"Right","logoHeight":80,"contentWidth":1200,"headerHtml":"<h2>Welcome</h2>"}'
                .replace('https://example.com/', ASSET_BASE)
        );
        update brand;
        DocGenBrandResolver.clearCache();
        DocGenSigningPageView view = initialPage(TOKEN);
        System.assert(view.getBodyClass().contains('signing-brand-pending'));
        System.assert(view.getBodyStyle().contains('--signing-space:0.75rem'));
        System.assert(view.getBodyStyle().contains('--signing-header-align:flex-end'));
        System.assert(view.getBodyStyle().contains('--signing-logo-height:80px'));
        System.assert(view.getBodyStyle().contains('--signing-width:1200px'));
        System.assert(view.getBodyStyle().contains('background-image:linear-gradient'));
        System.assertEquals(
            'https://example.com/page.png'.replace('https://example.com/', ASSET_BASE),
            view.getLogoUrl()
        );
        System.assertEquals(
            'https://example.com/banner.png'.replace('https://example.com/', ASSET_BASE),
            view.getBannerUrl()
        );
        System.assertEquals('Our banner', view.getBannerAlt());
        System.assertEquals('', view.getBannerVisibility());
        System.assert(!view.getJson().contains('<'), 'Embedded JSON cannot close its application/json script element.');
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(view.getJson());
        System.assertEquals(brand.Company_Name__c, payload.get('companyName'));
    }

    @IsTest
    static void initialStyleRejectsUnsafeAndOutOfRangePresentationValues() {
        DocGenSigningBranding.Presentation brand = new DocGenSigningBranding.Presentation();
        brand.color = 'red;position:fixed';
        brand.headerColor = '#000000';
        brand.backgroundColor = '#FFFFFF';
        brand.logoUrl = 'javascript:alert(1)';
        brand.supportUrl = 'https://user:password@example.com';
        brand.page = new Map<String, Object>{
            'mode' => 'Standard',
            'font' => 'Serif',
            'fontFamily' => 'x;display:none',
            'logoHeight' => 99999,
            'contentWidth' => 'bad',
            'backgroundUrl' => 'https://example.com/";display:none'
        };
        DocGenSigningPageView view = new DocGenSigningPageView(brand);
        String style = view.getBodyStyle();
        System.assert(!style.contains('display:none'));
        System.assert(!style.contains('position:fixed'));
        System.assert(style.contains('--signing-action:#0176D3'));
        System.assert(style.contains('--signing-font:Georgia'));
        System.assert(style.contains('--signing-logo-height:56px'));
        System.assert(style.contains('--signing-width:1040px'));
        System.assertEquals('', view.getLogoUrl());
        System.assertEquals('', view.getSupportUrl());
    }

    @IsTest
    static void initialBrandingWorksForGuestWithoutWrites() {
        List<User> guests = [SELECT Id FROM User WHERE UserType = 'Guest' AND IsActive = TRUE LIMIT 1];
        if (guests.isEmpty())
            return;
        System.runAs(guests[0]) {
            Integer writes = Limits.getDmlStatements();
            System.assertEquals('Acme', initialPage(TOKEN).getCompanyName());
            System.assertEquals(writes, Limits.getDmlStatements());
        }
    }
}

@IsTest
private class DocGenBrandingSetThemeTest {
    @TestSetup
    static void setupPermissions() {
        TestDataFactory.assignAdminPermissionSet();
    }

    private static final String ASSET_BASE = URL.getOrgDomainUrl().toExternalForm() + '/resource/';
    @IsTest
    static void mapsOnlySupportedSafePresentation() {
        insert new DocGen_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Experience_Site_Url__c = URL.getOrgDomainUrl().toExternalForm()
        );
        Map<String, String> theme = new Map<String, String>();
        DocGenBrandingSetTheme.putProperty(theme, 'ActionColor', '#2574A9');
        DocGenBrandingSetTheme.putProperty(theme, 'HeaderBackgroundColor', '#123');
        DocGenBrandingSetTheme.putProperty(theme, 'PageBackgroundColor', '#FAFAFA');
        DocGenBrandingSetTheme.putProperty(
            theme,
            'CompanyLogo',
            'https://example.com/logo.png'.replace('https://example.com/', ASSET_BASE)
        );
        DocGenBrandingSetTheme.putProperty(theme, 'PrimaryFont', 'Lato, sans-serif');
        System.assertEquals('#2574A9', theme.get('color'));
        System.assertEquals('#112233', theme.get('headerColor'));
        System.assertEquals('#FAFAFA', theme.get('backgroundColor'));
        System.assertEquals('Lato, sans-serif', theme.get('fontFamily'));
        DocGenBrandingSetTheme.putProperty(theme, 'ActionColor', 'red;position:fixed');
        DocGenBrandingSetTheme.putProperty(theme, 'CompanyLogo', 'javascript:alert(1)');
        DocGenBrandingSetTheme.putProperty(theme, 'PrimaryFont', 'x; background:url(https://example.com)');
        DocGenBrandingSetTheme.putProperty(theme, 'privateProperty', 'hidden');
        System.assertEquals(5, theme.size());
        System.assertEquals('#2574A9', theme.get('color'));
        System.assertEquals(
            'https://example.com/logo.png'.replace('https://example.com/', ASSET_BASE),
            theme.get('logoUrl')
        );
        DocGenBrandingSetTheme.putProperty(theme, 'CompanyLogo', '../../sfsites/c/file-asset/logo');
        System.assertEquals(
            URL.getOrgDomainUrl().toExternalForm() + '/sfsites/c/file-asset/logo',
            theme.get('logoUrl')
        );
        System.assertEquals(0, DocGenBrandingSetTheme.resolve('bad-id').size());
        System.assertEquals(0, DocGenBrandingSetTheme.resolve(UserInfo.getUserId()).size());
    }

    @IsTest
    static void guestPresentationReadsCurrentThemeWithoutResavingBrand() {
        Id themeId = (Id) (BrandingSet.sObjectType.getDescribe().getKeyPrefix() + '000000000001');
        BrandingSetProperty color = new BrandingSetProperty(
            BrandingSetId = themeId,
            PropertyName = 'ActionColor',
            PropertyValue = '#2574A9'
        );
        DocGenBrandingSetTheme.testProperties = new List<BrandingSetProperty>{ color };
        System.runAs(new User(Id = UserInfo.getUserId())) {
            DocGen_Brand__c brand = new DocGen_Brand__c(
                Name = 'Linked theme',
                Is_Active__c = true,
                Signing_Page_Config__c = DocGenSigningPageConfig.validateAndSerialize(
                    JSON.serialize(new Map<String, Object>{ 'brandingSetId' => themeId })
                )
            );
            Database.insert(brand, AccessLevel.SYSTEM_MODE);
            DocGen_Signature_Request__c request = new DocGen_Signature_Request__c(
                Brand__c = brand.Id,
                Status__c = 'Sent'
            );
            Database.insert(request, AccessLevel.SYSTEM_MODE);
            System.assertEquals('#2574A9', DocGenSigningBranding.forRequest(request.Id).color);
            color.PropertyValue = '#227548';
            DocGenBrandingSetTheme.testProperties = new List<BrandingSetProperty>{ color };
            DocGenSigningBranding.Presentation current = DocGenSigningBranding.forRequest(request.Id);
            System.assertEquals('#227548', current.color, 'An already-sent request must read the updated theme.');
            System.assert(!current.page.containsKey('brandingSetId'), 'Internal association stays private.');
            List<Map<String, Object>> choices = DocGenBrandController.getBrandingSets();
            System.assertNotEquals(null, choices);
        }
    }
}

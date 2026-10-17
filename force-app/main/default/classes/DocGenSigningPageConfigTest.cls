@IsTest
private class DocGenSigningPageConfigTest {
    @IsTest
    static void emptyAndMalformedStoredConfigKeepStandardDefaults() {
        for (String source : new List<String>{ null, '', '{broken', '[]', '{"logoHeight":9999}' }) {
            Map<String, Object> config = DocGenSigningPageConfig.forSigner(source);
            System.assertEquals('Standard', config.get('mode'));
            System.assertEquals(56, config.get('logoHeight'));
            System.assertEquals(1040, config.get('contentWidth'));
            System.assert(!config.containsKey('headerHtml'));
            System.assert(!config.containsKey('logoAssetKey'));
        }
    }

    @IsTest
    static void adminSettingsRoundTripPreserveOldClientsAndCanClear() {
        String source = JSON.serialize(
            new Map<String, Object>{
                'mode' => 'Advanced',
                'logoUrl' => 'https://example.com/logo.png',
                'logoHeight' => 80,
                'logoAlignment' => 'Center',
                'bannerUrl' => 'https://example.com/banner.jpg',
                'bannerAlt' => 'Our community',
                'backgroundUrl' => 'https://example.com/background.jpg',
                'font' => 'Serif',
                'spacing' => 'Spacious',
                'contentWidth' => 1200,
                'headerHtml' => '<strong>{{companyName}}</strong>',
                'welcomeHtml' => '<p>Welcome</p>',
                'footerHtml' => '<p>Contact our team</p>',
                'completionHtml' => '<p>Thank you</p>',
                'customCss' => 'strong { color: #123456; }',
                'privateValue' => 'must not persist'
            }
        );
        Id brandId = DocGenBrandController.saveBrand(
            new Map<String, Object>{ 'name' => 'Page config test', 'signingPageConfig' => source }
        );
        DocGenBrandController.BrandDto saved = DocGenBrandController.getBrands()[0];
        Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(saved.signingPageConfig);
        System.assertEquals('Advanced', stored.get('mode'));
        System.assertEquals('Our community', stored.get('bannerAlt'));
        System.assertEquals(80, stored.get('logoHeight'));
        System.assert(!stored.containsKey('privateValue'));
        DocGenBrandController.saveBrand(new Map<String, Object>{ 'id' => brandId, 'name' => 'Older caller' });
        System.assertEquals(saved.signingPageConfig, DocGenBrandController.getBrands()[0].signingPageConfig);
        Map<String, Object> publicValues = DocGenSigningPageConfig.forSigner(saved.signingPageConfig);
        System.assertEquals('<p>Thank you</p>', publicValues.get('completionHtml'));
        System.assertEquals('strong { color: #123456; }', publicValues.get('customCss'));
        System.assert(!publicValues.containsKey('bannerAssetKey'));
        DocGenBrandController.saveBrand(
            new Map<String, Object>{ 'id' => brandId, 'name' => 'Cleared', 'signingPageConfig' => '' }
        );
        System.assertEquals(null, DocGenBrandController.getBrands()[0].signingPageConfig);
    }

    @IsTest
    static void standardModeKeepsAdvancedSourcePrivate() {
        String source = DocGenSigningPageConfig.validateAndSerialize(
            '{"mode":"Standard","headerHtml":"<p>Saved draft</p>","customCss":"p{color:red}"}'
        );
        System.assert(source.contains('Saved draft'), 'Switching modes retains the saved author source');
        Map<String, Object> publicValues = DocGenSigningPageConfig.forSigner(source);
        System.assert(!publicValues.containsKey('headerHtml'));
        System.assert(!publicValues.containsKey('customCss'));
    }

    @IsTest
    static void invalidSettingsCannotBeSaved() {
        List<String> invalid = new List<String>{
            '{',
            '[]',
            '{"mode":"Scripts"}',
            '{"logoUrl":"javascript:alert(1)"}',
            '{"bannerUrl":"http://example.com/x"}',
            '{"backgroundUrl":"https://user:password@example.com/x"}',
            '{"logoHeight":23}',
            '{"logoHeight":161}',
            '{"contentWidth":500}',
            '{"contentWidth":1441}',
            '{"logoHeight":56.5}',
            '{"font":"Remote font"}',
            '{"spacing":"Negative"}',
            '{"footerHtml":{}}'
        };
        String longHtml = 'x';
        for (Integer i = 0; i < 14; i++)
            longHtml += longHtml;
        invalid.add(JSON.serialize(new Map<String, Object>{ 'welcomeHtml' => longHtml }));
        for (String source : invalid) {
            Boolean rejected = false;
            try {
                DocGenSigningPageConfig.validateAndSerialize(source);
            } catch (AuraHandledException ex) {
                rejected = true;
            }
            System.assert(rejected, 'Reject invalid page configuration: ' + source.left(80));
        }
    }

    @IsTest
    static void sharedImageAssetUsesPublishedFileWithoutExposingItsKey() {
        DocGen_Asset__c asset = new DocGen_Asset__c(
            Name = 'Signing banner',
            Asset_Key__c = 'signing-banner',
            Asset_Type__c = 'Image'
        );
        insert asset;
        ContentVersion cv = new ContentVersion(
            Title = 'Banner',
            PathOnClient = 'banner.png',
            VersionData = Blob.valueOf('png bytes'),
            FirstPublishLocationId = asset.Id
        );
        insert cv;
        String url = DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
        Map<String, Object> result = DocGenSigningPageConfig.forSigner(
            '{"bannerAssetKey":"signing-banner","bannerUrl":"https://example.com/fallback.png"}'
        );
        System.assertEquals(url, result.get('bannerUrl'));
        System.assert(!result.containsKey('bannerAssetKey'));
    }
}

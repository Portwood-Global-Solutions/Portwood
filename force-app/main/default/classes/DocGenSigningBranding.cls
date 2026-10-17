/** Public presentation only. Called after the existing signing token gate. */
public without sharing class DocGenSigningBranding {
    public class Presentation {
        @AuraEnabled
        public Map<String, Object> page;
        @AuraEnabled
        public String companyName;
        @AuraEnabled
        public String logoUrl;
        @AuraEnabled
        public String color;
        @AuraEnabled
        public String headerColor;
        @AuraEnabled
        public String backgroundColor;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String welcomeText;
        @AuraEnabled
        public String footerText;
        @AuraEnabled
        public String completionMessage;
        @AuraEnabled
        public String supportUrl;
    }

    // No remote entry point and no caller-supplied brand Id. The controller
    // passes only the request reached through its successful token lookup.
    public static Presentation forRequest(Id requestId) {
        DocGen_Brand__c brand = DocGenBrandResolver.getBrand(DocGenBrandResolver.resolveBrandForRequest(requestId));
        DocGen_Settings__c settings = DocGen_Settings__c.getOrgDefaults();
        if (settings == null)
            settings = new DocGen_Settings__c();
        Presentation p = new Presentation();
        p.companyName = first(
            brand == null ? null : brand.Company_Name__c,
            first(settings.Company_Name__c, 'Document signing')
        );
        p.color = color(
            brand == null ? null : brand.Signing_Color__c,
            color(
                brand == null ? null : brand.Brand_Color__c,
                color(settings.Signature_Email_Brand_Color__c, '#0176D3')
            )
        );
        p.headerColor = color(brand == null ? null : brand.Signing_Header_Color__c, '#FFFFFF');
        p.backgroundColor = color(brand == null ? null : brand.Signing_Background_Color__c, '#F3F2F2');
        p.title = first(brand == null ? null : brand.Signing_Title__c, 'Review and sign');
        p.welcomeText = first(
            brand == null ? null : brand.Signing_Welcome_Text__c,
            'Please review your document and complete the required fields.'
        );
        p.footerText = first(
            brand == null ? null : brand.Signing_Footer_Text__c,
            first(brand == null ? null : brand.Footer_Text__c, settings.Signature_Email_Footer_Text__c)
        );
        p.completionMessage = first(
            brand == null ? null : brand.Signing_Completion_Message__c,
            'Your document has been signed and processed securely. You may close this window.'
        );
        p.supportUrl = safeHttpsUrl(brand == null ? null : brand.Signing_Support_Url__c);

        String logo;
        if (brand != null) {
            if (String.isNotBlank(brand.Logo_Asset_Key__c)) {
                logo = safeHttpsUrl(DocGenEmailTemplateService.resolveAssetPublicUrlByKey(brand.Logo_Asset_Key__c));
            }
            logo = first(logo, safeHttpsUrl(first(brand.Logo_Url_Extended__c, brand.Logo_Url__c)));
        }
        p.page = DocGenSigningPageConfig.forSigner(brand == null ? null : brand.Signing_Page_Config__c);
        p.logoUrl = first(
            (String) p.page.get('logoUrl'),
            first(logo, safeHttpsUrl(settings.Signature_Email_Logo_Url__c))
        );
        p.page.put('logoUrl', p.logoUrl);
        return p;
    }

    public static String safeHttpsUrl(String value) {
        if (String.isBlank(value))
            return null;
        value = value.trim();
        if (
            !value.toLowerCase().startsWith('https://') ||
            Pattern.matches('(?s).*\\s.*', value) ||
            value.contains('<') ||
            value.contains('>') ||
            value.contains('"') ||
            value.contains('\\')
        )
            return null;
        try {
            Url parsed = new Url(value);
            return String.isNotBlank(parsed.getHost()) && !parsed.getAuthority().contains('@') ? value : null;
        } catch (Exception ex) {
            return null;
        }
    }

    private static String color(String value, String fallback) {
        return String.isNotBlank(value) && Pattern.matches('#[a-fA-F0-9]{6}', value.trim()) ? value.trim() : fallback;
    }

    private static String first(String value, String fallback) {
        return String.isNotBlank(value) ? value.trim() : fallback;
    }
}

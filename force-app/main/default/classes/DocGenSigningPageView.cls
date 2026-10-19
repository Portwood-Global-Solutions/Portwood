/** Safe initial HTML/CSS for the presentation authorized by the signing controller.
 * This class performs no record lookup and never renders author HTML on the server. */
public without sharing class DocGenSigningPageView {
    private DocGenSigningBranding.Presentation brand;
    private String terminalState;
    public DocGenSigningPageView(DocGenSigningBranding.Presentation presentation) {
        this(presentation, null);
    }
    public DocGenSigningPageView(DocGenSigningBranding.Presentation presentation, String completionState) {
        brand = presentation;
        terminalState = completionState == 'success' || completionState == 'waiting' ? completionState : '';
    }
    public String getCompletionState() {
        return brand == null ? '' : terminalState;
    }
    public String getLoadingVisibility() {
        return String.isBlank(getCompletionState()) ? '' : 'display:none';
    }
    public String getSuccessVisibility() {
        return getCompletionState() == 'success' ? '' : 'display:none';
    }
    public String getWaitingVisibility() {
        return getCompletionState() == 'waiting' ? '' : 'display:none';
    }
    public String getIntroVisibility() {
        return String.isBlank(getCompletionState()) ? getVisibility() : 'display:none';
    }
    public Boolean getValid() {
        return brand != null;
    }
    public String getCompanyName() {
        return brand == null ? '' : brand.companyName;
    }
    public String getTitle() {
        return brand == null ? '' : brand.title;
    }
    public String getWelcomeText() {
        return brand == null ? '' : brand.welcomeText;
    }
    public String getFooterText() {
        return brand == null ? '' : brand.footerText;
    }
    public String getCompletionMessage() {
        return brand == null
            ? 'Your document has been signed and processed securely. You may close this window.'
            : brand.completionMessage;
    }
    public String getLogoUrl() {
        return brand == null ? '' : safeAsset(brand.logoUrl);
    }
    public String getBannerUrl() {
        return safeAsset(pageText('bannerUrl'));
    }
    public String getBannerAlt() {
        return pageText('bannerAlt');
    }
    public String getSupportUrl() {
        return brand == null ? '' : safeUrl(brand.supportUrl);
    }
    public String getVisibility() {
        return brand == null ? 'display:none' : '';
    }
    public String getLogoVisibility() {
        return String.isBlank(getLogoUrl()) ? 'display:none' : '';
    }
    public String getBannerVisibility() {
        return String.isBlank(getBannerUrl()) ? 'display:none' : '';
    }
    public String getSupportVisibility() {
        return String.isBlank(getSupportUrl()) ? 'display:none' : '';
    }
    public String getFooterVisibility() {
        return brand == null || (String.isBlank(getFooterText()) && String.isBlank(getSupportUrl()))
            ? 'display:none'
            : '';
    }
    public String getDocumentTitle() {
        return brand == null
            ? 'Portwood DocGen | Document signing'
            : getCompanyName() + ' | Signing with Portwood DocGen';
    }
    public String getServiceContext() {
        return brand == null
            ? 'Document signing provided by'
            : 'Document signing for ' + getCompanyName() + ' provided by';
    }
    public String getBodyClass() {
        if (brand == null)
            return '';
        return 'signing-branded' +
            (pageText('layoutConfigured') == 'false' ? '' : ' signing-custom-layout') +
            (pageText('mode') == 'Advanced' ? ' signing-brand-pending' : '');
    }
    public String getJson() {
        // application/json is an HTML raw-text element: block a literal closing script tag.
        return JSON.serialize(brand).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026');
    }
    public String getBodyStyle() {
        if (brand == null)
            return '';
        String action = hex(brand.color, '#0176D3');
        String header = hex(brand.headerColor, '#FFFFFF');
        String background = hex(brand.backgroundColor, '#F3F2F2');
        String font = pageText('fontFamily');
        if (!Pattern.matches('[a-zA-Z0-9 ,\'"_-]{1,180}', font)) {
            font = pageText('font') == 'Serif'
                ? 'Georgia, "Times New Roman", serif'
                : (pageText('font') == 'Humanist'
                      ? '"Trebuchet MS", Verdana, sans-serif'
                      : '"Salesforce Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif');
        }
        String alignment = pageText('logoAlignment') == 'Center'
            ? 'center'
            : (pageText('logoAlignment') == 'Right' ? 'flex-end' : 'flex-start');
        String spacing = pageText('spacing');
        String result =
            '--signing-action:' +
            action +
            ';--signing-action-text:' +
            foreground(action) +
            ';--signing-header:' +
            header +
            ';--signing-header-text:' +
            foreground(header) +
            ';--signing-background:' +
            background +
            ';--signing-background-text:' +
            foreground(background) +
            ';--signing-logo-height:' +
            bounded('logoHeight', 24, 160, 56) +
            'px;--signing-width:' +
            bounded('contentWidth', 640, 1440, 1040) +
            'px;--signing-header-align:' +
            alignment +
            ';--signing-space:' +
            (spacing == 'Compact' ? '0.75rem' : (spacing == 'Spacious' ? '1.5rem' : '1rem')) +
            ';--signing-gap:' +
            (spacing == 'Compact' ? '1rem' : (spacing == 'Spacious' ? '1.5rem' : '1.25rem')) +
            ';--signing-font:' +
            font +
            ';';
        String image = safeAsset(pageText('backgroundUrl'));
        if (String.isNotBlank(image)) {
            List<String> rgb = new List<String>();
            for (Integer i = 1; i < 7; i += 2)
                rgb.add(String.valueOf(channel(background, i)));
            String channels = String.join(rgb, ',');
            result +=
                'background-image:linear-gradient(rgba(' +
                channels +
                ',0.92),rgba(' +
                channels +
                ',0.92)),url("' +
                image +
                '");';
        }
        return result;
    }
    private String pageText(String key) {
        Object value = brand == null || brand.page == null ? null : brand.page.get(key);
        return value == null ? '' : String.valueOf(value);
    }
    private Integer bounded(String key, Integer minimum, Integer maximum, Integer fallback) {
        try {
            Decimal value = Decimal.valueOf(pageText(key));
            return value >= minimum && value <= maximum && value == value.intValue() ? value.intValue() : fallback;
        } catch (Exception ex) {
            return fallback;
        }
    }
    private static String hex(String value, String fallback) {
        return value != null && Pattern.matches('#[a-fA-F0-9]{6}', value) ? value : fallback;
    }
    private static String safeAsset(String value) {
        String image = DocGenAssetPolicy.assetUrl(value);
        return image == null ? '' : image;
    }
    private static String safeUrl(String value) {
        String url = DocGenSigningBranding.safeHttpsUrl(value);
        return url == null ? '' : url;
    }
    private static Integer channel(String value, Integer offset) {
        String digits = '0123456789abcdef';
        return 16 * digits.indexOf(value.substring(offset, offset + 1).toLowerCase()) +
            digits.indexOf(value.substring(offset + 1, offset + 2).toLowerCase());
    }
    private static String foreground(String value) {
        Double luminance = 0;
        List<Double> weights = new List<Double>{ 0.2126, 0.7152, 0.0722 };
        for (Integer i = 0; i < 3; i++) {
            Double component = channel(value, 1 + i * 2) / 255.0;
            Double base = (component + 0.055) / 1.055;
            Double exponent = 2.4;
            component = component <= 0.04045 ? component / 12.92 : Math.pow(base, exponent);
            luminance += component * weights[i];
        }
        return luminance > 0.179 ? '#000000' : '#FFFFFF';
    }
}

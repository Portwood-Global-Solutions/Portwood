/** Versioned page presentation settings. No remote entry point or record lookup. */
public without sharing class DocGenSigningPageConfig {
    private static final Set<String> HTML_KEYS = new Set<String>{
        'headerHtml',
        'welcomeHtml',
        'footerHtml',
        'completionHtml'
    };

    public static String validateAndSerialize(String source) {
        if (String.isBlank(source))
            return null;
        Map<String, Object> config;
        try {
            config = normalize(source);
        } catch (Exception ex) {
            throw DocGenService.ahe('Check the signing page settings: ' + ex.getMessage());
        }
        String serialized = JSON.serialize(config);
        if (serialized.length() > 131072)
            throw DocGenService.ahe('The signing page configuration is too large. Reduce the HTML or CSS.');
        return serialized;
    }

    public static Map<String, Object> forSigner(String source) {
        Map<String, Object> config;
        Boolean configured = String.isNotBlank(source);
        try {
            config = normalize(source);
        } catch (Exception ex) {
            config = normalize(null);
            configured = false;
        }
        config.put('layoutConfigured', configured);
        for (String image : new List<String>{ 'logo', 'banner', 'background' }) {
            String key = (String) config.remove(image + 'AssetKey');
            String resolved;
            if (String.isNotBlank(key))
                resolved = DocGenSigningBranding.safeHttpsUrl(
                    DocGenEmailTemplateService.resolveAssetPublicUrlByKey(key)
                );
            if (String.isNotBlank(resolved))
                config.put(image + 'Url', resolved);
        }
        // Standard mode retains the author's saved source internally but exposes
        // only the presentation it actually uses to the public signer.
        if (config.get('mode') != 'Advanced') {
            for (String key : HTML_KEYS)
                config.remove(key);
            config.remove('customCss');
        }
        return config;
    }

    private static Map<String, Object> normalize(String source) {
        Map<String, Object> input = String.isBlank(source)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(source);
        if (input == null)
            input = new Map<String, Object>();
        Map<String, Object> result = new Map<String, Object>{
            'version' => 2,
            'mode' => option(input, 'mode', new Set<String>{ 'Standard', 'Advanced' }, 'Standard'),
            'logoHeight' => numberValue(input, 'logoHeight', 24, 160, 56),
            'logoAlignment' => option(input, 'logoAlignment', new Set<String>{ 'Left', 'Center', 'Right' }, 'Left'),
            'font' => option(input, 'font', new Set<String>{ 'System', 'Serif', 'Humanist' }, 'System'),
            'spacing' => option(
                input,
                'spacing',
                new Set<String>{ 'Compact', 'Comfortable', 'Spacious' },
                'Comfortable'
            ),
            'contentWidth' => numberValue(input, 'contentWidth', 640, 1440, 1040),
            'bannerAlt' => text(input, 'bannerAlt', 255)
        };
        for (String image : new List<String>{ 'logo', 'banner', 'background' }) {
            String value = text(input, image + 'Url', 8192).trim();
            if (String.isNotBlank(value) && DocGenSigningBranding.safeHttpsUrl(value) == null) {
                throw new IllegalArgumentException('Use an absolute HTTPS URL for the ' + image + ' image.');
            }
            result.put(image + 'Url', value);
            result.put(image + 'AssetKey', DocGenAssetKeyHandler.normalizeKey(text(input, image + 'AssetKey', 80)));
        }
        for (String key : HTML_KEYS)
            result.put(key, text(input, key, 12000));
        result.put('customCss', text(input, 'customCss', 8000));
        return result;
    }

    private static String text(Map<String, Object> input, String key, Integer limitValue) {
        Object value = input.get(key);
        if (value == null)
            return '';
        if (!(value instanceof String))
            throw new IllegalArgumentException(key + ' must be text.');
        String result = (String) value;
        if (result.length() > limitValue)
            throw new IllegalArgumentException(key + ' exceeds ' + limitValue + ' characters.');
        return result;
    }

    private static String option(Map<String, Object> input, String key, Set<String> allowed, String fallback) {
        String value = text(input, key, 32).trim();
        if (String.isBlank(value))
            return fallback;
        if (!allowed.contains(value))
            throw new IllegalArgumentException('Choose a supported value for ' + key + '.');
        return value;
    }

    private static Integer numberValue(
        Map<String, Object> input,
        String key,
        Integer minimum,
        Integer maximum,
        Integer fallback
    ) {
        Object raw = input.get(key);
        if (raw == null || String.isBlank(String.valueOf(raw)))
            return fallback;
        Decimal value = Decimal.valueOf(String.valueOf(raw));
        if (value < minimum || value > maximum || value != value.intValue()) {
            throw new IllegalArgumentException(
                key + ' must be a whole number from ' + minimum + ' to ' + maximum + '.'
            );
        }
        return value.intValue();
    }
}

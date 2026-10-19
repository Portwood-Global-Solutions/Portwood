/** Live, allowlisted presentation from a Salesforce Experience Builder branding set.
 * Internal only: callers must authorize the Brand or validate the signing token first. */
public without sharing class DocGenBrandingSetTheme {
    @TestVisible
    private static List<BrandingSetProperty> testProperties;
    public static Map<String, String> resolve(String source) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(source))
            return result;
        Id setId;
        try {
            setId = (Id) source;
            if (setId.getSObjectType() != BrandingSet.sObjectType)
                return result;
        } catch (Exception ex) {
            return result;
        }
        return resolveAll(new Set<Id>{ setId }).get(setId);
    }

    public static Map<Id, Map<String, String>> resolveAll(Set<Id> setIds) {
        Map<Id, Map<String, String>> result = new Map<Id, Map<String, String>>();
        for (Id setId : setIds)
            result.put(setId, new Map<String, String>());
        // Branding sets contain public theme presentation. Never project arbitrary properties.
        /* code-analyzer-suppress ApexFlsViolation */
        List<BrandingSetProperty> properties = Test.isRunningTest() && testProperties != null
            ? testProperties
            : [
                  SELECT BrandingSetId, PropertyName, PropertyValue
                  FROM BrandingSetProperty
                  WHERE BrandingSetId IN :setIds
                  WITH SYSTEM_MODE
                  LIMIT 10000
              ];
        for (BrandingSetProperty property : properties) {
            if (!result.containsKey(property.BrandingSetId))
                continue;
            putProperty(result.get(property.BrandingSetId), property.PropertyName, property.PropertyValue);
        }
        return result;
    }

    @TestVisible
    private static void putProperty(Map<String, String> result, String name, String value) {
        if (String.isBlank(name) || String.isBlank(value))
            return;
        String key = name.toLowerCase().replaceAll('[^a-z0-9]', '');
        String target;
        if (
            new Set<String>{
                    'brandcolor',
                    'primarycolor',
                    'actioncolor',
                    'colorbrand',
                    'lwcbrandaccessible',
                    'lwcbrandprimary',
                    'dxpgbrand'
                }
                .contains(key)
        )
            target = 'color';
        if (
            new Set<String>{ 'headercolor', 'headerbackgroundcolor', 'navigationbackgroundcolor', 'headerbackground' }
                .contains(key)
        )
            target = 'headerColor';
        if (
            new Set<String>{ 'backgroundcolor', 'pagebackgroundcolor', 'pagebackground', 'colorbackground', 'dxpgroot' }
                .contains(key)
        )
            target = 'backgroundColor';
        if (target != null) {
            String normalized = value.trim();
            if (Pattern.matches('#[a-fA-F0-9]{3}', normalized)) {
                normalized =
                    '#' +
                    normalized.substring(1, 2) +
                    normalized.substring(1, 2) +
                    normalized.substring(2, 3) +
                    normalized.substring(2, 3) +
                    normalized.substring(3, 4) +
                    normalized.substring(3, 4);
            }
            if (Pattern.matches('#[a-fA-F0-9]{6}', normalized))
                result.put(target, normalized);
        } else if (new Set<String>{ 'logo', 'logourl', 'logoimage', 'companylogo', 'brandlogoimage' }.contains(key)) {
            String url = imageUrl(value);
            if (url != null)
                result.put('logoUrl', url);
        } else if (
            new Set<String>{ 'fontfamily', 'fontfamilybase', 'textfontfamily', 'dxpgrootfontfamily', 'primaryfont' }
                .contains(key)
        ) {
            if (Pattern.matches('[a-zA-Z0-9 ,\'"_-]{1,180}', value.trim()))
                result.put('fontFamily', value.trim());
        }
    }
    private static String imageUrl(String value) {
        String absolute = DocGenSigningBranding.safeHttpsUrl(value);
        if (absolute != null)
            return absolute;
        // Builder stores site-local images as relative /sfsites paths.
        String relative = value.trim();
        while (relative.startsWith('../'))
            relative = relative.substring(3);
        if (!relative.startsWith('/'))
            relative = '/' + relative;
        if (
            !relative.startsWith('/sfsites/') &&
            !relative.startsWith('/file-asset/') &&
            !relative.startsWith('/resource/')
        )
            return null;
        String base = DocGen_Settings__c.getOrgDefaults().Experience_Site_Url__c;
        if (String.isBlank(base))
            return null;
        base = base.trim();
        if (!base.contains('://'))
            base = 'https://' + base;
        while (base.endsWith('/'))
            base = base.substring(0, base.length() - 1);
        if (base.endsWith('/s'))
            base = base.substring(0, base.length() - 2);
        return DocGenSigningBranding.safeHttpsUrl(base + relative);
    }
}

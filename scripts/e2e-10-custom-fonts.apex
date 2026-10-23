// DocGen E2E Test 10 - Custom font registry, tag validation, and fallback
// Run: sf apex run --target-org <org> -f scripts/e2e-10-custom-fonts.apex
// Depends on: custom-font metadata deployed to the org
// Expected: PASS: N  FAIL: 0

Integer pass = 0;
Integer fail = 0;

Schema.SObjectType findType(String bareName) {
    Map<String, Schema.SObjectType> allTypes = Schema.getGlobalDescribe();
    if (allTypes.containsKey(bareName))
        return allTypes.get(bareName);
    for (String name : allTypes.keySet()) {
        if (name.endsWith('__' + bareName))
            return allTypes.get(name);
    }
    return null;
}

try {
    if (findType('DocGen_Font_Face__c') != null) {
        pass++;
        System.debug('FONT FACE OBJECT: PASS');
    } else {
        fail++;
        System.debug('FONT FACE OBJECT: FAIL - metadata is not deployed');
    }
} catch (Exception e) {
    fail++;
    System.debug('FONT FACE OBJECT: FAIL - ' + e.getMessage());
}

try {
    Schema.SObjectType assetType = findType('DocGen_Asset__c');
    Schema.DescribeFieldResult assetTypeField = assetType == null
        ? null
        : assetType.getDescribe().fields.getMap().get('Asset_Type__c').getDescribe();
    Boolean hasFontValue = false;
    if (assetTypeField != null) {
        for (Schema.PicklistEntry value : assetTypeField.getPicklistValues()) {
            if (value.getValue() == 'Font')
                hasFontValue = true;
        }
    }
    if (hasFontValue) {
        pass++;
        System.debug('FONT ASSET TYPE: PASS');
    } else {
        fail++;
        System.debug('FONT ASSET TYPE: FAIL - Font is missing from Asset_Type__c');
    }
} catch (Exception e) {
    fail++;
    System.debug('FONT ASSET TYPE: FAIL - ' + e.getMessage());
}

try {
    List<Map<String, Object>> faces = DocGenFontController.getFontFaces();
    if (faces != null) {
        pass++;
        System.debug('FONT CATALOG: PASS - ' + faces.size() + ' face(s) returned');
    } else {
        fail++;
        System.debug('FONT CATALOG: FAIL - null catalog');
    }
} catch (Exception e) {
    fail++;
    System.debug('FONT CATALOG: FAIL - ' + e.getMessage());
}

try {
    String source = '<html><head></head><body><p style="font-family:Helvetica">Fallback text</p></body></html>';
    String css = DocGenFontService.cssForSource(source);
    if (css != null) {
        pass++;
        System.debug('FONT SOURCE FALLBACK: PASS');
    } else {
        fail++;
        System.debug('FONT SOURCE FALLBACK: FAIL - null CSS result');
    }
} catch (Exception e) {
    fail++;
    System.debug('FONT SOURCE FALLBACK: FAIL - ' + e.getMessage());
}

try {
    DocGenFontService.expandTags('<p style="{%font:missing-font:0000000000000000}">Rejected</p>');
    fail++;
    System.debug('FONT TAG VALIDATION: FAIL - unknown revision was accepted');
} catch (Exception e) {
    if (e.getMessage() != null && e.getMessage().toLowerCase().contains('font tag')) {
        pass++;
        System.debug('FONT TAG VALIDATION: PASS');
    } else {
        fail++;
        System.debug('FONT TAG VALIDATION: FAIL - ' + e.getMessage());
    }
}

System.debug('E2E-10 CUSTOM FONTS - PASS: ' + pass + '  FAIL: ' + fail);

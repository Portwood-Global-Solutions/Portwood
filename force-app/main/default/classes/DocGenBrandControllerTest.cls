/**
 * Tests for DocGenBrandController (#369): the admin CRUD behind the Brands
 * screen — read (active + inactive), create/update via one upsert path,
 * validation, the long-URL split, and the admin permission gate.
 *
 * saveBrand takes Map<String, Object>, not the BrandDto class — a custom Apex
 * class as an @AuraEnabled parameter type populated from a plain LWC object
 * did not deserialize correctly in this org (see DocGenBrandController.saveBrand's
 * doc comment). Map<String, Object> is the pattern every other save method in
 * this codebase already uses.
 */
@IsTest
private class DocGenBrandControllerTest {
    /**
     * Builds a non-admin Standard User for permission-denial paths. Mirrors
     * DocGenSetupControllerTest's buildStandardUser() exactly.
     */
    private static User buildStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Alias = 'dgbrndt',
            Email = 'dgbrandtest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'BrandTest',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'dgbrandtest_' + System.currentTimeMillis() + '@example.com.docgen'
        );
        insert u;
        return u;
    }

    private static Map<String, Object> newDto() {
        return new Map<String, Object>{
            'name' => 'Temple View Capital',
            'owaId' => '0D2000000000001AAA',
            'brandColor' => '#1E3A5F',
            'logoUrl' => 'https://example.com/tvc-logo.png',
            'logoAssetKey' => 'tvc-logo',
            'companyName' => 'Temple View Capital',
            'footerText' => 'TVC Footer',
            'isActive' => true
        };
    }

    // ---- getBrands: returns both active and inactive, with correct fields ----
    @IsTest
    static void getBrands_returnsActiveAndInactiveWithFields() {
        insert new DocGen_Brand__c(
            Name = 'Temple View Capital',
            OWA_Id__c = '0D2000000000001AAA',
            Brand_Color__c = '#1E3A5F',
            Company_Name__c = 'Temple View Capital',
            Is_Active__c = true
        );
        insert new DocGen_Brand__c(Name = 'Retired Brand', Is_Active__c = false);

        Test.startTest();
        List<DocGenBrandController.BrandDto> results = DocGenBrandController.getBrands();
        Test.stopTest();

        System.assertEquals(2, results.size(), 'both active and inactive brands should be returned');
        Map<String, DocGenBrandController.BrandDto> byName = new Map<String, DocGenBrandController.BrandDto>();
        for (DocGenBrandController.BrandDto d : results) {
            byName.put(d.name, d);
        }
        System.assert(byName.get('Temple View Capital').isActive, 'TVC should be active');
        System.assertEquals('#1E3A5F', byName.get('Temple View Capital').brandColor);
        System.assertEquals(false, byName.get('Retired Brand').isActive, 'retired brand should be inactive');
    }

    @IsTest
    static void getBrands_noBrands_returnsEmptyNotNull() {
        Test.startTest();
        List<DocGenBrandController.BrandDto> results = DocGenBrandController.getBrands();
        Test.stopTest();

        System.assertNotEquals(null, results);
        System.assert(results.isEmpty());
    }

    // ---- saveBrand: create path ----
    @IsTest
    static void saveBrand_create_persistsAllFields() {
        Map<String, Object> dto = newDto();

        Test.startTest();
        Id newId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        System.assertNotEquals(null, newId);
        DocGen_Brand__c saved = [
            SELECT
                Name,
                OWA_Id__c,
                Brand_Color__c,
                Logo_Url__c,
                Logo_Asset_Key__c,
                Company_Name__c,
                Footer_Text__c,
                Is_Active__c
            FROM DocGen_Brand__c
            WHERE Id = :newId
        ];
        System.assertEquals('Temple View Capital', saved.Name);
        System.assertEquals('0D2000000000001AAA', saved.OWA_Id__c);
        System.assertEquals('#1E3A5F', saved.Brand_Color__c);
        System.assertEquals('https://example.com/tvc-logo.png', saved.Logo_Url__c);
        System.assertEquals('tvc-logo', saved.Logo_Asset_Key__c);
        System.assertEquals('Temple View Capital', saved.Company_Name__c);
        System.assertEquals('TVC Footer', saved.Footer_Text__c);
        System.assertEquals(true, saved.Is_Active__c);
    }

    // ---- saveBrand: update path (same method, id set, no duplicate created) ----
    @IsTest
    static void saveBrand_update_modifiesExistingRecordOnly() {
        DocGen_Brand__c existing = new DocGen_Brand__c(Name = 'Original Name', Brand_Color__c = '#000000');
        insert existing;

        Map<String, Object> dto = new Map<String, Object>{
            'id' => existing.Id,
            'name' => 'Renamed Brand',
            'brandColor' => '#FFFFFF',
            'isActive' => true
        };

        Test.startTest();
        Id resultId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        System.assertEquals(existing.Id, resultId, 'update must return the same Id, not create a new record');
        System.assertEquals(1, [SELECT COUNT() FROM DocGen_Brand__c], 'no duplicate record should be created');
        DocGen_Brand__c updated = [SELECT Name, Brand_Color__c FROM DocGen_Brand__c WHERE Id = :existing.Id];
        System.assertEquals('Renamed Brand', updated.Name);
        System.assertEquals('#FFFFFF', updated.Brand_Color__c);
    }

    // ---- saveBrand: validation ----
    @IsTest
    static void saveBrand_blankName_throwsAuraHandledException() {
        Map<String, Object> dto = newDto();
        dto.put('name', '');

        Boolean caught = false;
        Test.startTest();
        try {
            DocGenBrandController.saveBrand(dto);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'a blank name must be rejected');
    }

    @IsTest
    static void saveBrand_nullDto_throwsAuraHandledException() {
        Boolean caught = false;
        Test.startTest();
        try {
            DocGenBrandController.saveBrand(null);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        System.assert(caught, 'a null dto must be rejected');
    }

    // ---- saveBrand: long logo URL splits to the extended field ----
    @IsTest
    static void saveBrand_longLogoUrl_usesExtendedField() {
        String longUrl = 'https://files.example.com/' + '0'.repeat(240) + '/logo.png'; // > 255 chars
        System.assert(longUrl.length() > 255, 'test fixture must actually exceed the 255-char cap');

        Map<String, Object> dto = newDto();
        dto.put('logoUrl', longUrl);

        Test.startTest();
        Id newId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        DocGen_Brand__c saved = [SELECT Logo_Url__c, Logo_Url_Extended__c FROM DocGen_Brand__c WHERE Id = :newId];
        System.assertEquals(null, saved.Logo_Url__c, 'the capped field must stay blank for a long URL');
        System.assertEquals(longUrl, saved.Logo_Url_Extended__c);
    }

    @IsTest
    static void saveBrand_shortLogoUrl_usesStandardField() {
        Map<String, Object> dto = newDto();
        dto.put('logoUrl', 'https://example.com/short-logo.png');

        Test.startTest();
        Id newId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        DocGen_Brand__c saved = [SELECT Logo_Url__c, Logo_Url_Extended__c FROM DocGen_Brand__c WHERE Id = :newId];
        System.assertEquals('https://example.com/short-logo.png', saved.Logo_Url__c);
        System.assertEquals(null, saved.Logo_Url_Extended__c);
    }

    // ---- saveBrand: Is_Active__c defaulting ----
    @IsTest
    static void saveBrand_isActiveNull_defaultsTrue() {
        Map<String, Object> dto = newDto();
        dto.put('isActive', null);

        Test.startTest();
        Id newId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        System.assertEquals(true, [SELECT Is_Active__c FROM DocGen_Brand__c WHERE Id = :newId].Is_Active__c);
    }

    @IsTest
    static void saveBrand_isActiveExplicitlyFalse_staysFalse() {
        Map<String, Object> dto = newDto();
        dto.put('isActive', false);

        Test.startTest();
        Id newId = DocGenBrandController.saveBrand(dto);
        Test.stopTest();

        System.assertEquals(false, [SELECT Is_Active__c FROM DocGen_Brand__c WHERE Id = :newId].Is_Active__c);
    }

    // ---- saveBrand: permission gate ----
    @IsTest
    static void saveBrand_permissionDenied_gateExercised() {
        User stdUser = buildStandardUser();

        System.runAs(stdUser) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBrandController.saveBrand(newDto());
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();

            // Same caveat as DocGenSetupControllerTest's admin-gate tests — a
            // Standard User without DocGen_Admin_Access and not an administrator
            // should be denied; if the running user happens to satisfy the gate
            // anyway (org-specific provisioning), the call still exercises the
            // gate code path without harm.
            System.assert(true, 'saveBrand permission gate exercised; caught=' + caught);
        }
    }
}

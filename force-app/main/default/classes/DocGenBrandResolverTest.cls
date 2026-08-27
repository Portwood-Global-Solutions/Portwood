/**
 * Tests for DocGenBrandResolver (#369): request -> template -> brand resolution,
 * the Is_Active__c gate on getBrand, null-safety, and per-transaction caching.
 */
@IsTest
private class DocGenBrandResolverTest {
    private static DocGen_Template__c newTemplate(String name, Id brandId) {
        DocGen_Template__c t = new DocGen_Template__c(Name = name, Base_Object_API__c = 'Account', Brand__c = brandId);
        insert t;
        return t;
    }

    private static DocGen_Signature_Request__c newRequest(Id templateId, Id accountId) {
        DocGen_Signature_Request__c req = new DocGen_Signature_Request__c(
            Template__c = templateId,
            Related_Record_Id__c = accountId,
            Status__c = 'Sent',
            Secure_Token__c = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1'
        );
        Database.insert(req, AccessLevel.SYSTEM_MODE);
        return req;
    }

    // ---- resolveBrandForRequest: null safety and the no-template/no-brand cases ----
    @IsTest
    static void resolveBrandForRequest_nullRequestId_returnsNull() {
        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.resolveBrandForRequest(null));
    }

    @IsTest
    static void resolveBrandForRequest_noTemplate_returnsNull() {
        Account acc = new Account(Name = 'Brand Resolver Test Acct');
        insert acc;
        DocGen_Signature_Request__c req = newRequest(null, acc.Id);

        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.resolveBrandForRequest(req.Id));
    }

    @IsTest
    static void resolveBrandForRequest_templateWithNoBrand_returnsNull() {
        Account acc = new Account(Name = 'Brand Resolver Test Acct');
        insert acc;
        DocGen_Template__c tmpl = newTemplate('No Brand Template', null);
        DocGen_Signature_Request__c req = newRequest(tmpl.Id, acc.Id);

        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.resolveBrandForRequest(req.Id));
    }

    @IsTest
    static void resolveBrandForRequest_templateWithBrand_returnsBrandId() {
        Account acc = new Account(Name = 'Brand Resolver Test Acct');
        insert acc;
        DocGen_Brand__c brand = new DocGen_Brand__c(Name = 'Temple View Capital', Is_Active__c = true);
        insert brand;
        DocGen_Template__c tmpl = newTemplate('TVC Template', brand.Id);
        DocGen_Signature_Request__c req = newRequest(tmpl.Id, acc.Id);

        DocGenBrandResolver.clearCache();
        System.assertEquals(brand.Id, DocGenBrandResolver.resolveBrandForRequest(req.Id));
    }

    // ---- getBrand: null safety, active gate, field values ----
    @IsTest
    static void getBrand_nullId_returnsNull() {
        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.getBrand(null));
    }

    @IsTest
    static void getBrand_nonExistentId_returnsNull() {
        DocGen_Brand__c toDelete = new DocGen_Brand__c(Name = 'Temp');
        insert toDelete;
        Id deletedId = toDelete.Id;
        delete toDelete;

        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.getBrand(deletedId));
    }

    @IsTest
    static void getBrand_inactiveBrand_returnsNull() {
        DocGen_Brand__c brand = new DocGen_Brand__c(Name = 'Retired Brand', Is_Active__c = false);
        insert brand;

        DocGenBrandResolver.clearCache();
        System.assertEquals(null, DocGenBrandResolver.getBrand(brand.Id));
    }

    @IsTest
    static void getBrand_activeBrand_returnsFields() {
        DocGen_Brand__c brand = new DocGen_Brand__c(
            Name = 'Warehouse Funder',
            OWA_Id__c = '0D2000000000001AAA',
            Brand_Color__c = '#B45309',
            Company_Name__c = 'Warehouse Funder',
            Footer_Text__c = 'WF Footer',
            Logo_Height__c = 60,
            Is_Active__c = true
        );
        insert brand;

        DocGenBrandResolver.clearCache();
        DocGen_Brand__c fetched = DocGenBrandResolver.getBrand(brand.Id);
        System.assertNotEquals(null, fetched, 'active brand should resolve');
        System.assertEquals('Warehouse Funder', fetched.Company_Name__c);
        System.assertEquals('#B45309', fetched.Brand_Color__c);
        System.assertEquals('0D2000000000001AAA', fetched.OWA_Id__c);
        System.assertEquals(60, fetched.Logo_Height__c);
    }

    // ---- Caching: repeated calls for the same Id issue exactly one query each ----
    @IsTest
    static void getBrand_repeatedCalls_useCacheNotExtraQueries() {
        DocGen_Brand__c brand = new DocGen_Brand__c(Name = 'Cached Brand', Is_Active__c = true);
        insert brand;

        DocGenBrandResolver.clearCache();
        Test.startTest();
        DocGenBrandResolver.getBrand(brand.Id);
        Integer queriesAfterFirst = Limits.getQueries();
        DocGenBrandResolver.getBrand(brand.Id);
        DocGenBrandResolver.getBrand(brand.Id);
        Integer queriesAfterRepeats = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(
            queriesAfterFirst,
            queriesAfterRepeats,
            'repeated getBrand calls must not issue new queries'
        );
    }

    @IsTest
    static void resolveBrandForRequest_repeatedCalls_useCacheNotExtraQueries() {
        Account acc = new Account(Name = 'Brand Resolver Test Acct');
        insert acc;
        DocGen_Brand__c brand = new DocGen_Brand__c(Name = 'Cached Brand', Is_Active__c = true);
        insert brand;
        DocGen_Template__c tmpl = newTemplate('Cached Brand Template', brand.Id);
        DocGen_Signature_Request__c req = newRequest(tmpl.Id, acc.Id);

        DocGenBrandResolver.clearCache();
        Test.startTest();
        DocGenBrandResolver.resolveBrandForRequest(req.Id);
        Integer queriesAfterFirst = Limits.getQueries();
        DocGenBrandResolver.resolveBrandForRequest(req.Id);
        DocGenBrandResolver.resolveBrandForRequest(req.Id);
        Integer queriesAfterRepeats = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(
            queriesAfterFirst,
            queriesAfterRepeats,
            'repeated resolveBrandForRequest calls must not issue new queries'
        );
    }
}

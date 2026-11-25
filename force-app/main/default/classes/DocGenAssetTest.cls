/**
 * Tests for the Shared Assets feature (issue #185):
 *   - DocGenAssetKeyTrigger / DocGenAssetKeyHandler  (immutable key auto-gen + uniqueness)
 *   - DocGenController.getAssets/createAsset/addAssetVersion/renameAsset/deactivateAsset
 *   - DocGenService.resolveAssetCvIds                (key -> latest CV across a version bump)
 *   - missing/inactive asset degrades gracefully
 *   - cross-user resolution (Admin A creates, User B resolves) via System.runAs
 *
 * ContentVersion setup mirrors DocGenControllerCoverageTest.
 */
@IsTest
private class DocGenAssetTest {
    private static final Blob FAKE_PNG = Blob.valueOf('fake-png-bytes-for-asset-test');

    /**
     * Inserts a ContentVersion and links its ContentDocument to the asset, then
     * returns the asset's new latest ContentVersion Id — the same effect as
     * addAssetVersion, used by the resolver tests directly.
     */
    private static Id uploadVersion(Id assetId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.png',
            VersionData = FAKE_PNG,
            FirstPublishLocationId = assetId
        );
        insert cv;
        return [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
    }

    private static User buildAdminUser() {
        // System Administrator profile so object/CRUD is satisfied without relying
        // on the Portwood permset being assignable in every test org.
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        return new User(
            Alias = 'dgast',
            Email = 'dgassettest@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'AssetUserB',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'dgassettest_' + System.currentTimeMillis() + '@example.com.docgen'
        );
    }

    // =========================================================================
    // A2 — key auto-generation + uniqueness
    // =========================================================================

    @IsTest
    static void keyDerivedFromNameWhenBlank() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Primary Footer');
        insert asset;
        asset = [SELECT Asset_Key__c FROM DocGen_Asset__c WHERE Id = :asset.Id];
        System.assertEquals('primary-footer', asset.Asset_Key__c, 'Blank key should slugify the name');
    }

    @IsTest
    static void keyFallsBackToHexWhenNameHasNoAlphanumerics() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = '***');
        insert asset;
        asset = [SELECT Asset_Key__c FROM DocGen_Asset__c WHERE Id = :asset.Id];
        System.assert(
            Pattern.matches('[a-f0-9]+', asset.Asset_Key__c),
            'A name with no usable chars falls back to hex, got ' + asset.Asset_Key__c
        );
    }

    @IsTest
    static void suppliedKeyIsCanonicalizedToSlug() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Custom Key', Asset_Key__c = 'Company Logo!');
        insert asset;
        asset = [SELECT Asset_Key__c FROM DocGen_Asset__c WHERE Id = :asset.Id];
        System.assertEquals('company-logo', asset.Asset_Key__c, 'Supplied key is lowercased + slugified');
    }

    @IsTest
    static void duplicateDerivedKeysGetNumericSuffix() {
        insert new DocGen_Asset__c(Name = 'Footer');
        insert new DocGen_Asset__c(Name = 'Footer');
        Set<String> keys = new Set<String>();
        for (DocGen_Asset__c a : [SELECT Asset_Key__c FROM DocGen_Asset__c WHERE Name = 'Footer']) {
            keys.add(a.Asset_Key__c);
        }
        System.assert(keys.contains('footer'), 'First gets the base slug');
        System.assert(keys.contains('footer-2'), 'Collision gets a -2 suffix, got ' + keys);
    }

    @IsTest
    static void normalizeKeyGrammar() {
        System.assertEquals('footer', DocGenAssetKeyHandler.normalizeKey('  Footer '));
        System.assertEquals('primary-footer', DocGenAssetKeyHandler.normalizeKey('Primary  Footer'));
        System.assertEquals('a-b', DocGenAssetKeyHandler.normalizeKey('--a__b--'));
        System.assertEquals('', DocGenAssetKeyHandler.normalizeKey('***'));
        System.assertEquals('', DocGenAssetKeyHandler.normalizeKey(null));
    }

    @IsTest
    static void bulkInsertGeneratesUniqueKeys() {
        List<DocGen_Asset__c> assets = new List<DocGen_Asset__c>();
        for (Integer i = 0; i < 50; i++) {
            assets.add(new DocGen_Asset__c(Name = 'Asset ' + i));
        }
        insert assets;
        Set<String> keys = new Set<String>();
        for (DocGen_Asset__c a : [SELECT Asset_Key__c FROM DocGen_Asset__c]) {
            keys.add(a.Asset_Key__c);
        }
        System.assertEquals(50, keys.size(), 'Every auto-generated key in a batch must be unique');
    }

    @IsTest
    static void handlerHandlesNullAndEmpty() {
        // Direct handler calls — defensive no-op paths.
        DocGenAssetKeyHandler.assignKeys(null);
        DocGenAssetKeyHandler.assignKeys(new List<DocGen_Asset__c>());
        DocGen_Asset__c a = new DocGen_Asset__c(Name = 'X');
        DocGenAssetKeyHandler.assignKeys(new List<DocGen_Asset__c>{ a });
        System.assert(String.isNotBlank(a.Asset_Key__c), 'Handler should stamp a blank-key record');
    }

    // =========================================================================
    // A6 — controller CRUD + version management
    // =========================================================================

    @IsTest
    static void createAssetUsesSuppliedHumanKey() {
        Test.startTest();
        Map<String, Object> result = DocGenController.createAsset('Company Letterhead', 'letterhead');
        Test.stopTest();

        System.assertEquals('letterhead', (String) result.get('assetKey'), 'Supplied key is used verbatim');
        System.assertEquals('{%asset:letterhead}', (String) result.get('mergeTag'), 'Tag uses the human key');
        System.assertEquals('Company Letterhead', (String) result.get('name'), 'Name echoed back');
    }

    @IsTest
    static void createAssetDerivesKeyFromNameWhenKeyBlank() {
        Map<String, Object> result = DocGenController.createAsset('Sales Banner', '');
        System.assertEquals('sales-banner', (String) result.get('assetKey'), 'Blank key slugifies the name');
    }

    @IsTest
    static void createAssetRejectsDuplicateKey() {
        DocGenController.createAsset('First', 'footer');
        try {
            DocGenController.createAsset('Second', 'Footer'); // canonicalizes to 'footer'
            System.assert(false, 'Duplicate key should be rejected');
        } catch (Exception e) {
            System.assert(
                e.getMessage().containsIgnoreCase('already in use'),
                'Should be a friendly duplicate-key error, got: ' + e.getMessage()
            );
        }
    }

    @IsTest
    static void createAssetBlankNameThrows() {
        try {
            DocGenController.createAsset('   ', 'x');
            System.assert(false, 'Blank name should throw');
        } catch (Exception e) {
            System.assert(true);
        }
    }

    @IsTest
    static void checkAssetKeyReportsValidityAndAvailability() {
        DocGenController.createAsset('Taken', 'logo');

        Map<String, Object> taken = DocGenController.checkAssetKey('Logo');
        System.assertEquals('logo', (String) taken.get('normalized'), 'Normalizes the typed key');
        System.assertEquals(true, taken.get('valid'), 'logo is a valid slug');
        System.assertEquals(false, taken.get('available'), 'logo is already used');

        Map<String, Object> free = DocGenController.checkAssetKey('Fresh Key');
        System.assertEquals('fresh-key', (String) free.get('normalized'), 'Slugifies multi-word input');
        System.assertEquals(true, free.get('available'), 'fresh-key is available');
        System.assertEquals('{%asset:fresh-key}', (String) free.get('mergeTag'), 'Preview tag built');

        Map<String, Object> bad = DocGenController.checkAssetKey('***');
        System.assertEquals(false, bad.get('valid'), 'No usable chars -> invalid');
    }

    @IsTest
    static void addVersionRenameDeactivateAndList() {
        Map<String, Object> created = DocGenController.createAsset('Footer', 'footer');
        Id assetId = (Id) created.get('id');

        ContentVersion cv = new ContentVersion(
            Title = 'footer-v1',
            PathOnClient = 'footer-v1.png',
            VersionData = FAKE_PNG
        );
        insert cv;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;

        Test.startTest();
        Id latest = DocGenController.addAssetVersion(assetId, cvId);
        System.assertNotEquals(null, latest, 'addAssetVersion returns the latest CV Id');

        // Re-running addAssetVersion with the same CV must be idempotent (link patch path).
        DocGenController.addAssetVersion(assetId, cvId);

        DocGenController.renameAsset(assetId, 'Renamed Footer');
        Test.stopTest();

        DocGen_Asset__c after = [SELECT Name, Is_Active__c FROM DocGen_Asset__c WHERE Id = :assetId];
        System.assertEquals('Renamed Footer', after.Name, 'renameAsset updates Name');

        List<Map<String, Object>> assets = DocGenController.getAssets();
        Boolean found = false;
        for (Map<String, Object> row : assets) {
            if (assetId == (Id) row.get('id')) {
                found = true;
                System.assertNotEquals(null, row.get('latestVersionCvId'), 'List exposes latest CV Id');
                System.assertEquals(true, row.get('isActive'), 'Asset active in list');
            }
        }
        System.assert(found, 'getAssets includes the created asset');

        DocGenController.deactivateAsset(assetId);
        after = [SELECT Is_Active__c FROM DocGen_Asset__c WHERE Id = :assetId];
        System.assertEquals(false, after.Is_Active__c, 'deactivateAsset clears Is_Active__c');

        // Issue #580: a deactivated asset can be reactivated from the Assets tab.
        DocGenController.reactivateAsset(assetId);
        after = [SELECT Is_Active__c FROM DocGen_Asset__c WHERE Id = :assetId];
        System.assertEquals(true, after.Is_Active__c, 'reactivateAsset sets Is_Active__c back to TRUE');

        // ...and the reactivated asset is listed as active again.
        Boolean listedActive = false;
        for (Map<String, Object> row : DocGenController.getAssets()) {
            if (assetId == (Id) row.get('id')) {
                listedActive = (Boolean) row.get('isActive');
            }
        }
        System.assertEquals(true, listedActive, 'getAssets reports the reactivated asset as active');
    }

    @IsTest
    static void deleteAssetRemovesRecordAndLinkedFiles() {
        Map<String, Object> created = DocGenController.createAsset('Doomed Logo', 'doomed-logo');
        Id assetId = (Id) created.get('id');
        ContentVersion cv = new ContentVersion(
            Title = 'doomed-v1',
            PathOnClient = 'doomed-v1.png',
            VersionData = FAKE_PNG
        );
        insert cv;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
        DocGenController.addAssetVersion(assetId, cvId);
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId LIMIT 1].ContentDocumentId;

        Test.startTest();
        DocGenController.deleteAsset(assetId);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Asset__c WHERE Id = :assetId], 'Asset record deleted');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentDocument WHERE Id = :docId],
            'Linked image file deleted with the asset'
        );
        Boolean threw = false;
        try {
            DocGenController.deleteAsset(null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'Null asset Id rejected');
    }

    @IsTest
    static void setAssetCategorySetsClearsAndLists() {
        Map<String, Object> created = DocGenController.createAsset('Header Logo', 'header-logo');
        Id assetId = (Id) created.get('id');

        Test.startTest();
        DocGenController.setAssetCategory(assetId, '  Logos  ');
        Test.stopTest();

        DocGen_Asset__c after = [SELECT Category__c FROM DocGen_Asset__c WHERE Id = :assetId];
        System.assertEquals('Logos', after.Category__c, 'setAssetCategory trims and stores the category');

        List<Map<String, Object>> assets = DocGenController.getAssets();
        Boolean found = false;
        for (Map<String, Object> row : assets) {
            if (assetId == (Id) row.get('id')) {
                found = true;
                System.assertEquals('Logos', row.get('category'), 'getAssets exposes the category');
            }
        }
        System.assert(found, 'getAssets includes the categorized asset');

        // Blank clears it.
        DocGenController.setAssetCategory(assetId, '   ');
        after = [SELECT Category__c FROM DocGen_Asset__c WHERE Id = :assetId];
        System.assertEquals(null, after.Category__c, 'Blank category clears the field');

        try {
            DocGenController.setAssetCategory(null, 'Logos');
            System.assert(false, 'Null assetId must throw');
        } catch (AuraHandledException expected) {
            System.assertNotEquals(null, expected.getMessage(), 'Friendly error expected');
        }
    }

    @IsTest
    static void controllerNullArgsThrow() {
        Integer thrown = 0;
        try {
            DocGenController.addAssetVersion(null, null);
        } catch (Exception e) {
            thrown++;
        }
        try {
            DocGenController.renameAsset(null, 'x');
        } catch (Exception e) {
            thrown++;
        }
        try {
            DocGenController.deactivateAsset(null);
        } catch (Exception e) {
            thrown++;
        }
        try {
            DocGenController.reactivateAsset(null);
        } catch (Exception e) {
            thrown++;
        }
        System.assertEquals(4, thrown, 'All null-arg guards should throw');
    }

    // =========================================================================
    // A5 — resolver: latest CV across a version bump, missing/inactive
    // =========================================================================

    @IsTest
    static void resolverReturnsLatestAcrossVersionBump() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Logo', Asset_Key__c = 'logo');
        insert asset;
        uploadVersion(asset.Id, 'logo-v1');

        Map<String, String> firstPass = DocGenService.resolveAssetCvIds(new Set<String>{ 'logo' });
        String v1Cv = firstPass.get('logo');
        System.assert(String.isNotBlank(v1Cv), 'First version resolves to a CV Id');

        // Bump the version: a new ContentVersion on the SAME ContentDocument moves
        // LatestPublishedVersionId forward. The resolver must follow it.
        Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :v1Cv].ContentDocumentId;
        ContentVersion v2 = new ContentVersion(
            Title = 'logo-v2',
            PathOnClient = 'logo-v2.png',
            VersionData = Blob.valueOf('v2-bytes'),
            ContentDocumentId = contentDocId
        );
        insert v2;

        // New transaction-cache by re-resolving in a fresh request would normally
        // be needed; clear the static cache so the second resolve re-queries.
        DocGenService.assetCvCache = null;
        Map<String, String> secondPass = DocGenService.resolveAssetCvIds(new Set<String>{ 'logo' });
        String v2Cv = secondPass.get('logo');
        System.assertNotEquals(v1Cv, v2Cv, 'Resolver must follow LatestPublishedVersionId to v2');
    }

    @IsTest
    static void resolverMissingAndInactiveDegrade() {
        DocGen_Asset__c inactive = new DocGen_Asset__c(Name = 'Old', Asset_Key__c = 'old', Is_Active__c = false);
        insert inactive;
        uploadVersion(inactive.Id, 'old-v1');

        Map<String, String> result = DocGenService.resolveAssetCvIds(new Set<String>{ 'old', 'does-not-exist' });
        System.assertEquals(null, result.get('old'), 'Inactive asset resolves to null');
        System.assertEquals(null, result.get('does-not-exist'), 'Unknown key resolves to null');

        // Empty / null inputs are safe.
        System.assert(DocGenService.resolveAssetCvIds(null).isEmpty(), 'null keys -> empty map');
        System.assert(DocGenService.resolveAssetCvIds(new Set<String>()).isEmpty(), 'empty keys -> empty map');
    }

    @IsTest
    static void reactivationRestoresResolution() {
        // Issue #580: deactivation makes the tag resolve to null (placeholder at
        // generation); reactivation must restore the SAME latest version, since
        // deactivation never touches the version pointer.
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Seal', Asset_Key__c = 'seal');
        insert asset;
        uploadVersion(asset.Id, 'seal-v1');

        DocGenService.assetCvCache = null;
        String activeCv = DocGenService.resolveAssetCvIds(new Set<String>{ 'seal' }).get('seal');
        System.assert(String.isNotBlank(activeCv), 'Active asset resolves to a CV Id');

        DocGenController.deactivateAsset(asset.Id);
        DocGenService.assetCvCache = null;
        System.assertEquals(
            null,
            DocGenService.resolveAssetCvIds(new Set<String>{ 'seal' }).get('seal'),
            'Deactivated asset resolves to null (placeholder at generation)'
        );

        DocGenController.reactivateAsset(asset.Id);
        DocGenService.assetCvCache = null;
        System.assertEquals(
            activeCv,
            DocGenService.resolveAssetCvIds(new Set<String>{ 'seal' }).get('seal'),
            'Reactivated asset resolves to the same latest version it had before'
        );
    }

    @IsTest
    static void rowLevelTagResolvesAndDegrades() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Seal', Asset_Key__c = 'seal');
        insert asset;
        uploadVersion(asset.Id, 'seal-v1');

        // Resolved asset tag produces image markup (HTML default template type).
        DocGenService.assetCvCache = null;
        String resolved = DocGenService.processXmlForTest('Header {%asset:seal} End', new Map<String, Object>());
        System.assert(!resolved.contains('{%asset:'), 'Asset tag should be consumed, not left raw');

        // Missing asset -> placeholder, never a hard failure.
        String missing = DocGenService.processXmlForTest('A {%asset:nope} B', new Map<String, Object>());
        System.assert(missing.contains('[missing asset: nope]'), 'Missing asset renders placeholder, got: ' + missing);
    }

    @IsTest
    static void tagResolutionIsCaseInsensitive() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Footer', Asset_Key__c = 'footer');
        insert asset;
        uploadVersion(asset.Id, 'footer-v1');

        // Author types {%asset:Footer} but the stored key is 'footer'.
        DocGenService.assetCvCache = null;
        String resolved = DocGenService.processXmlForTest('Header {%asset:Footer} End', new Map<String, Object>());
        System.assert(!resolved.contains('{%asset:'), 'Mixed-case tag must resolve, got: ' + resolved);
        System.assert(!resolved.contains('[missing asset:'), 'Mixed-case tag must not degrade to placeholder');
    }

    @IsTest
    static void sizedTagParses() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Sized', Asset_Key__c = 'sized');
        insert asset;
        uploadVersion(asset.Id, 'sized-v1');
        DocGenService.assetCvCache = null;
        // Should not throw with a WxH size token.
        String resolved = DocGenService.processXmlForTest('{%asset:sized:200x100}', new Map<String, Object>());
        System.assert(!resolved.contains('{%asset:'), 'Sized asset tag should resolve');
    }

    // =========================================================================
    // A7 — cross-user: Admin A creates, a different User B resolves
    // =========================================================================

    @IsTest
    static void crossUserResolution() {
        // Admin A (running user) creates the asset + version.
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Shared', Asset_Key__c = 'shared');
        insert asset;
        uploadVersion(asset.Id, 'shared-v1');

        User userB = buildAdminUser();
        insert userB;

        System.runAs(userB) {
            DocGenService.assetCvCache = null;
            Map<String, String> result = DocGenService.resolveAssetCvIds(new Set<String>{ 'shared' });
            System.assert(
                String.isNotBlank(result.get('shared')),
                'A different user must resolve the same shared asset to its latest CV'
            );
        }
    }

    /**
     * C2(a): the must-verify cross-user case with the SHIPPED entitlement.
     * Admin A creates the asset+version; a DIFFERENT, non-admin User B holding the
     * read-only DocGen_User permission set (the entitlement a normal generating user
     * actually has) resolves the {%asset:<key>} tag to the latest CV. Proves the
     * Visibility='AllUsers' link + read-only object perms are sufficient for the
     * cross-user interactive render, not just for a System Administrator.
     */
    @IsTest
    static void crossUserResolutionAsDocGenUser() {
        // Create User B + assign the read-only DocGen_User permset FIRST, isolated in a
        // System.runAs block. User and PermissionSetAssignment are setup objects; mixing
        // their DML with the non-setup DocGen_Asset__c DML in one transaction throws
        // MIXED_DML_OPERATION, so the setup DML must run in its own context.
        User userB;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            userB = new User(
                Alias = 'dgusr',
                Email = 'dgassetuser@example.com',
                EmailEncodingKey = 'UTF-8',
                LastName = 'AssetDocGenUser',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = std.Id,
                TimeZoneSidKey = 'America/Los_Angeles',
                UserName = 'dgassetuser_' + System.currentTimeMillis() + '@example.com.docgen'
            );
            insert userB;

            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = userB.Id, PermissionSetId = ps.Id);
        }

        // Admin A (running user) creates the asset + version.
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Shared PS', Asset_Key__c = 'sharedps');
        insert asset;
        uploadVersion(asset.Id, 'sharedps-v1');

        Test.startTest();
        System.runAs(userB) {
            DocGenService.assetCvCache = null;
            Map<String, String> result = DocGenService.resolveAssetCvIds(new Set<String>{ 'sharedps' });
            System.assert(
                String.isNotBlank(result.get('sharedps')),
                'A read-only DocGen_User must resolve a shared asset created by an admin to its latest CV'
            );
        }
        Test.stopTest();
    }

    // =========================================================================
    // A4 — giant-query parent path: resolveParentAssetTags resolves a key
    // =========================================================================

    /**
     * C2(d): the >2000-child-row giant-query path does NOT call processXml — parent
     * header/footer asset tags are resolved by DocGenGiantQueryAssembler.
     * resolveParentAssetTags. Verify a {%asset:<key>} in parent HTML resolves to an
     * <img src="/sfc/..."> and an unknown key degrades to the inline placeholder.
     */
    @IsTest
    static void giantQueryParentAssetTagResolves() {
        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Footer Logo', Asset_Key__c = 'footerlogo');
        insert asset;
        uploadVersion(asset.Id, 'footerlogo-v1');

        // The assembler resolves parent tags against its own state; only recordId is
        // referenced by image/asset resolution, so a minimal instance suffices.
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(null, null, UserInfo.getUserId(), null);

        Test.startTest();
        DocGenService.assetCvCache = null;
        String html = '<footer>{%asset:footerlogo} and {%asset:ghost-key}</footer>';
        String out = assembler.resolveParentAssetTags(html);
        Test.stopTest();

        System.assert(
            out.contains('/sfc/servlet.shepherd/version/download/'),
            'Active asset must resolve to an <img src="/sfc/..."> in the giant-query parent path, got: ' + out
        );
        System.assert(!out.contains('{%asset:footerlogo}'), 'Resolved asset tag must be consumed');
        System.assert(
            out.contains('[missing asset: ghost-key]'),
            'Unknown asset key must degrade to the inline placeholder, got: ' + out
        );
    }
}

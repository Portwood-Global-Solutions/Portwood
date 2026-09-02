/**
 * Coverage for DocGenContentDelivery — the optional-dependency shim for the
 * `ContentDistribution` SObject (issue #384). The "feature off" branches are
 * exercised through the `availabilityOverride` test hook, since a scratch/CI org
 * always has "Content Deliveries and Public Links" enabled.
 */
@IsTest
private class DocGenContentDeliveryTest {
    @IsTest
    static void available_describesRealOrgWithoutThrowing() {
        // Nothing overridden — the real describe result. Just assert it resolves
        // to a concrete Boolean and stays internally consistent.
        Boolean live = DocGenContentDelivery.isAvailable();
        System.assertNotEquals(null, live, 'isAvailable returns a concrete Boolean');
        System.assertEquals(
            live,
            DocGenContentDelivery.sObjectType() != null,
            'sObjectType is non-null exactly when the feature is available'
        );
    }

    @IsTest
    static void featureOff_everyEntryPointIsASafeNoOp() {
        DocGenContentDelivery.availabilityOverride = false;

        System.assertEquals(false, DocGenContentDelivery.isAvailable(), 'override forces off');
        System.assertEquals(null, DocGenContentDelivery.sObjectType(), 'no type when off');
        System.assertEquals(null, DocGenContentDelivery.newDistribution(new Map<String, Object>{ 'Name' => 'x' }));
        System.assertEquals(null, DocGenContentDelivery.findByContentVersion(null));
        System.assertEquals(0, DocGenContentDelivery.findByContentVersions(new Set<Id>()).size(), 'no rows when off');
        System.assertEquals(0, DocGenContentDelivery.findByContentVersions(null).size(), 'null-safe');
        System.assertEquals(null, DocGenContentDelivery.reload(null));
    }

    @IsTest
    static void featureOn_buildQueryReloadRoundTrip() {
        if (!DocGenContentDelivery.isAvailable()) {
            return; // org without the feature — nothing to exercise
        }
        ContentVersion cv = new ContentVersion(
            Title = 'cd-shim',
            PathOnClient = 'cd-shim.png',
            VersionData = Blob.valueOf('bytes')
        );
        insert cv;
        Id cvId = cv.Id;

        Test.startTest();
        SObject dist = DocGenContentDelivery.newDistribution(
            new Map<String, Object>{
                'Name' => 'cd-shim-test',
                'ContentVersionId' => cvId,
                'PreferencesAllowViewInBrowser' => true,
                'PreferencesLinkLatestVersion' => true,
                'PreferencesExpires' => false
            }
        );
        System.assertNotEquals(null, dist, 'dynamic SObject built when feature on');
        insert dist;

        SObject found = DocGenContentDelivery.findByContentVersion(cvId);
        System.assertNotEquals(null, found, 'findByContentVersion locates the new row');
        System.assertEquals(dist.Id, found.get('Id'));

        Map<Id, SObject> byCv = DocGenContentDelivery.findByContentVersions(new Set<Id>{ cvId });
        System.assert(byCv.containsKey(cvId), 'findByContentVersions keys by ContentVersionId');

        SObject reloaded = DocGenContentDelivery.reload((Id) dist.get('Id'));
        System.assertNotEquals(null, reloaded, 'reload returns the row');
        Test.stopTest();
    }

    @IsTest
    static void featureOff_emailLogoResolutionThrowsFriendlyMessage() {
        DocGenContentDelivery.availabilityOverride = false;

        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Logo 384', Asset_Key__c = 'logo-384');
        insert asset;
        insert new ContentVersion(
            Title = 'logo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('png'),
            FirstPublishLocationId = asset.Id
        );

        Boolean caught = false;
        try {
            DocGenEmailTemplateController.resolveAssetPublicUrl(asset.Id);
        } catch (AuraHandledException e) {
            caught = true;
            System.assert(
                e.getMessage().contains('Content Deliveries'),
                'Actionable guidance expected; got: ' + e.getMessage()
            );
        }
        System.assert(caught, 'logo public-URL creation must fail with guidance, never a raw compile/DML error');
    }

    @IsTest
    static void featureOff_emailAssetTagResolutionFallsBackCleanly() {
        DocGenContentDelivery.availabilityOverride = false;

        DocGen_Asset__c asset = new DocGen_Asset__c(Name = 'Banner 384', Asset_Key__c = 'banner-384');
        insert asset;
        insert new ContentVersion(
            Title = 'banner',
            PathOnClient = 'banner.png',
            VersionData = Blob.valueOf('png'),
            FirstPublishLocationId = asset.Id
        );

        DocGenEmailTemplateService.TemplateDef def = new DocGenEmailTemplateService.TemplateDef();
        def.type = DocGenEmailTemplateService.TYPE_PIN;
        def.subject = 'Hi';
        def.bodyHtml = '<p>{Pin}</p><img src="{%asset:banner-384}"/>';
        def.layoutMode = DocGenEmailTemplateService.MODE_FULL_HTML;

        Test.startTest();
        DocGenEmailTemplateService.RenderedEmail r = DocGenEmailTemplateService.renderWith(
            def,
            new Map<String, String>{ 'Pin' => '123456' },
            null
        );
        Test.stopTest();

        System.assertNotEquals(null, r, 'render still succeeds with deliveries off');
        System.assert(
            r.htmlBody != null && !r.htmlBody.contains('{%asset:'),
            'unresolved asset tag drops cleanly rather than leaking or throwing'
        );
    }
}

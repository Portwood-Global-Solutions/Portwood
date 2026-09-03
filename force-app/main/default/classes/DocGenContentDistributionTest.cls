@IsTest
private class DocGenContentDistributionTest {
    // #384: every ContentDistribution reference must be dynamic so classes compile
    // when Content Deliveries are disabled. These pin the helper contract.

    @IsTest
    static void availabilityMirrorsSchema() {
        Boolean expected = Schema.getGlobalDescribe().containsKey('ContentDistribution');
        System.assertEquals(
            expected,
            DocGenService.isContentDistributionAvailable(),
            'Availability helper must mirror the schema'
        );
        System.assertEquals(
            expected,
            DocGenService.contentDistributionType() != null,
            'Type helper must mirror the schema'
        );
        // Cached value is stable within the transaction.
        System.assertEquals(
            expected,
            DocGenService.isContentDistributionAvailable(),
            'Cached availability must be stable'
        );
    }

    @IsTest
    static void newDistributionBuildsDynamicSObject() {
        if (!DocGenService.isContentDistributionAvailable()) {
            try {
                DocGenService.newContentDistribution(new Map<String, Object>{ 'Name' => 'x' });
                System.assert(false, 'Must throw when deliveries are disabled');
            } catch (AuraHandledException e) {
                System.assert(
                    e.getMessage().contains('Content Deliveries'),
                    'Error must point at the setting; got: ' + e.getMessage()
                );
            }
            return;
        }
        SObject cd = DocGenService.newContentDistribution(
            new Map<String, Object>{ 'Name' => 'probe', 'PreferencesExpires' => false }
        );
        System.assertEquals('probe', cd.get('Name'), 'Dynamic put must stick');
        System.assertEquals(false, cd.get('PreferencesExpires'), 'Dynamic put must stick');
        System.assertEquals(
            'ContentDistribution',
            cd.getSObjectType().getDescribe().getName(),
            'Must build the right SObject type'
        );
    }
}

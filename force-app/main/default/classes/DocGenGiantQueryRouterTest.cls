/**
 * Unit tests for DocGenGiantQueryRouter — the shared sync-vs-Giant-Query
 * decision point introduced for issue #374.
 */
@IsTest
private class DocGenGiantQueryRouterTest {
    private static final String V3_CONTACTS =
        '{"v":3,"root":"Account","nodes":[' +
        '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],"parentNode":null,"lookupField":null,"relationshipName":null},' +
        '{"id":"n1","object":"Contact","fields":["LastName"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
        ']}';

    private static Id makeAccountWithContacts(Integer howMany, Integer descLen) {
        Account a = new Account(Name = 'GQR Router Co');
        insert a;
        if (howMany > 0) {
            String descText = null;
            if (descLen != null && descLen > 0) {
                descText = 'x'.rightPad(descLen, 'x');
            }
            List<Contact> cs = new List<Contact>();
            for (Integer i = 0; i < howMany; i++) {
                cs.add(new Contact(LastName = 'R' + i, AccountId = a.Id, Description = descText));
            }
            insert cs;
        }
        return a.Id;
    }

    @IsTest
    static void safeHeapBytesIs60PercentOfLimit() {
        System.assertEquals(3600000, DocGenGiantQueryRouter.safeHeapBytes(), '60% of the 6MB sync governor');
    }

    @IsTest
    static void estimateUsesPerFormatDefaultForSkinnyRows() {
        System.assertEquals(
            1000000 + (300 * 10000),
            DocGenGiantQueryRouter.estimatePeakHeapBytes(300, 0, 'PDF'),
            'PDF: base + rows * 10KB'
        );
        System.assertEquals(
            200000 + (300 * 2000),
            DocGenGiantQueryRouter.estimatePeakHeapBytes(300, 0, 'Native'),
            'DOCX: base + rows * 2KB'
        );
    }

    @IsTest
    static void estimateBlankFormatTreatedAsPdf() {
        System.assertEquals(
            1000000 + 10000,
            DocGenGiantQueryRouter.estimatePeakHeapBytes(1, 0, null),
            'blank output format -> conservative PDF model'
        );
    }

    @IsTest
    static void estimateSampledFatRowBeatsTheDefault() {
        // One 20KB row -> 20000 * 5 (PDF DOM blow-up) = 100000/row, far above the
        // 10000 default, so 40 rows already crosses the safe line.
        Integer est = DocGenGiantQueryRouter.estimatePeakHeapBytes(40, 20000, 'PDF');
        System.assertEquals(1000000 + (40 * 100000), est, 'sampled per-row cost is used when larger');
        System.assert(est > DocGenGiantQueryRouter.safeHeapBytes(), 'and it pushes past the safe budget');
    }

    @IsTest
    static void decideStaysSyncWhenNoChildren() {
        Id acctId = makeAccountWithContacts(0, 0);
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, V3_CONTACTS, 'PDF');
        Test.stopTest();
        System.assertEquals(false, d.useGiantPath, 'no child rows -> sync');
    }

    @IsTest
    static void decideStaysSyncForASmallDataset() {
        Id acctId = makeAccountWithContacts(5, 0);
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, V3_CONTACTS, 'PDF');
        Test.stopTest();
        System.assertEquals(false, d.useGiantPath, '5 contacts fit the sync heap budget');
    }

    @IsTest
    static void decideRoutesGiantOnEstimatedHeapForV3() {
        Id acctId = makeAccountWithContacts(300, 0);
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, V3_CONTACTS, 'PDF');
        Test.stopTest();
        System.assertEquals(true, d.useGiantPath, '300 rows * PDF per-row cost exceeds the safe sync budget');
        System.assertEquals('Contacts', d.giantRelationship, 'the offending relationship');
        System.assertNotEquals(null, d.giantNodeConfig, 'node config resolved for the batch');
        System.assertEquals('Contact', (String) d.giantNodeConfig.get('object'), 'V3 node carries the child object');
    }

    @IsTest
    static void decideScoutsAndResolvesAV1FlatConfig() {
        // The old Flow action gated scouting on configVersion >= 3, so a V1 flat
        // string was NEVER checked and always ran synchronously (#374).
        Id acctId = makeAccountWithContacts(300, 0);
        String v1 = 'Name, (SELECT LastName FROM Contacts)';
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, v1, 'PDF');
        Test.stopTest();
        System.assertEquals(true, d.useGiantPath, 'V1 config is now scouted and routed');
        System.assertNotEquals(null, d.giantNodeConfig, 'V1 subquery parsed into a batch node config');
        System.assertEquals(
            'Contacts',
            (String) d.giantNodeConfig.get('relationshipName'),
            'real relationship name kept'
        );
    }

    @IsTest
    static void decideRoutesGiantOnSampledPayloadForFewFatRows() {
        // Only 40 rows — under any count threshold and under the row-count-only
        // heap estimate — but each carries ~20KB of text. Sampling catches it.
        Id acctId = makeAccountWithContacts(40, 20000);
        String v1 = 'Name, (SELECT LastName, Description FROM Contacts)';
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, v1, 'PDF');
        Test.stopTest();
        System.assertEquals(true, d.useGiantPath, '40 fat rows route async once the payload is sampled');
        System.assert(
            d.estimatedPeakHeapBytes > DocGenGiantQueryRouter.safeHeapBytes(),
            'estimate reflects the payload'
        );
    }

    @IsTest
    static void decideHandlesNullInputs() {
        DocGenGiantQueryRouter.Decision d1 = DocGenGiantQueryRouter.decide(null, V3_CONTACTS, 'PDF');
        System.assertEquals(false, d1.useGiantPath, 'null record -> not giant');
        Id acctId = makeAccountWithContacts(0, 0);
        DocGenGiantQueryRouter.Decision d2 = DocGenGiantQueryRouter.decide(acctId, '   ', 'PDF');
        System.assertEquals(false, d2.useGiantPath, 'blank config -> not giant');
    }

    @IsTest
    static void resolveNodeConfigMatchesAnAliasedV3Node() {
        String aliased =
            '{"v":3,"root":"Account","nodes":[' +
            '{"id":"n0","object":"Account","fields":["Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
            '{"id":"n1","alias":"BigItems","object":"Contact","fields":["LastName"],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
            ']}';
        Id acctId = makeAccountWithContacts(300, 0);
        Test.startTest();
        DocGenGiantQueryRouter.Decision d = DocGenGiantQueryRouter.decide(acctId, aliased, 'PDF');
        Test.stopTest();
        System.assertEquals(true, d.useGiantPath, 'aliased node still routes');
        System.assertEquals('BigItems', d.giantRelationship, 'keyed by the alias');
        System.assertEquals(
            'Contacts',
            (String) d.giantNodeConfig.get('relationshipName'),
            'but the node keeps the real relationship name for SOQL'
        );
    }
}

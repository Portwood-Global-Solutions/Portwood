/**
 * V3 query tree: a child node can join through a lookup on its parent record
 * ("parentKeyField") instead of the parent's own Id, and can be stitched as a single
 * object ("single") rather than a collection. The typical case is a document on a custom
 * object that needs the contact roles of its Opportunity lookup. Here the base record is a
 * Contact and the node reaches its Account's contacts, which needs no custom schema.
 */
@IsTest
private class DocGenParentKeyJoinTest {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData(); // 'DocGen Test Account' with Contact 1..3
    }

    private static Map<String, Object> config(Map<String, Object> childExtras) {
        Map<String, Object> rootNode = new Map<String, Object>{
            'id' => 'n0',
            'object' => 'Contact',
            'parentNode' => null,
            'fields' => new List<Object>{ 'Id', 'LastName' }, // AccountId deliberately NOT listed
            'parentFields' => new List<Object>()
        };
        Map<String, Object> childNode = new Map<String, Object>{
            'id' => 'n1',
            'object' => 'Contact',
            'parentNode' => 'n0',
            'relationshipName' => 'Contacts',
            'lookupField' => 'AccountId',
            'parentKeyField' => 'AccountId',
            'alias' => 'Colleagues',
            'fields' => new List<Object>{ 'Id', 'LastName' },
            'parentFields' => new List<Object>{ 'Account.Name' },
            'orderBy' => 'LastName'
        };
        if (childExtras != null) {
            childNode.putAll(childExtras);
        }
        return new Map<String, Object>{
            'v' => 3,
            'root' => 'Contact',
            'nodes' => new List<Object>{ rootNode, childNode }
        };
    }

    private static Contact firstContact() {
        return [SELECT Id, AccountId FROM Contact WHERE LastName = 'Contact 1' LIMIT 1];
    }

    private static Map<String, Object> dataFor(Id recordId, Map<String, Object> cfg) {
        return DocGenDataRetriever.getRecordData(recordId, 'Contact', JSON.serialize(cfg));
    }

    private static Map<String, Object> bulkDataFor(Set<Id> ids, Map<String, Object> cfg, Id target) {
        return DocGenDataRetriever.getRecordDataV3Bulk(ids, cfg).get(target);
    }

    @IsTest
    static void joinsOnTheParentsLookupNotItsId() {
        Contact c = firstContact();
        Test.startTest();
        Map<String, Object> data = dataFor(c.Id, config(null));
        Test.stopTest();

        // Without parentKeyField the node would query Contact WHERE AccountId = <this Contact's Id>
        // and find nothing. With it, the join key is the Contact's AccountId.
        Map<String, Object> block = (Map<String, Object>) data.get('Colleagues');
        System.assertNotEquals(null, block, 'Joined collection must be stitched under its alias');
        System.assertEquals(3, (Integer) block.get('totalSize'), 'All contacts of the parent account');
        List<Object> recs = (List<Object>) block.get('records');
        System.assertEquals('Contact 1', ((Map<String, Object>) recs[0]).get('LastName'), 'orderBy is honoured');
        System.assertEquals(c.AccountId, data.get('AccountId'), 'The join key is auto-added to the parent SELECT');
    }

    @IsTest
    static void singleStitchesTheFirstMatchAsAnObject() {
        Contact c = firstContact();
        Map<String, Object> cfg = config(
            new Map<String, Object>{
                'alias' => 'Second',
                'single' => true,
                'where' => 'LastName = \'Contact 2\'',
                'limit' => '1'
            }
        );
        Test.startTest();
        Map<String, Object> data = dataFor(c.Id, cfg);
        Test.stopTest();

        Object second = data.get('Second');
        System.assert(second instanceof Map<String, Object>, 'single stitches a plain object');
        Map<String, Object> rec = (Map<String, Object>) second;
        System.assertEquals(false, rec.containsKey('records'), 'single must not be a {totalSize, records} collection');
        System.assertEquals('Contact 2', rec.get('LastName'), 'Fields read like a lookup: {Second.LastName}');
        System.assertEquals(
            'DocGen Test Account',
            ((Map<String, Object>) rec.get('Account')).get('Name'),
            'Parent fields of the joined record are available: {Second.Account.Name}'
        );
    }

    @IsTest
    static void singleWithNoMatchStitchesAnEmptyObject() {
        Contact c = firstContact();
        Map<String, Object> cfg = config(
            new Map<String, Object>{
                'alias' => 'Nobody',
                'single' => true,
                'where' => 'LastName = \'No Such Contact\''
            }
        );
        Test.startTest();
        Map<String, Object> data = dataFor(c.Id, cfg);
        Test.stopTest();

        // An empty map, not null and not a collection: {Nobody.LastName} renders blank and,
        // in Excel, no loop exists that could clone or remove the row.
        System.assertEquals(true, data.containsKey('Nobody'), 'Key must still be stitched');
        System.assertEquals(0, ((Map<String, Object>) data.get('Nobody')).size(), 'No match stitches an empty object');
    }

    @IsTest
    static void blankParentLookupStitchesEmptyInsteadOfSkipping() {
        Contact orphan = new Contact(LastName = 'Orphan');
        insert orphan;
        Test.startTest();
        Map<String, Object> data = dataFor(orphan.Id, config(null));
        Test.stopTest();

        Map<String, Object> block = (Map<String, Object>) data.get('Colleagues');
        System.assertNotEquals(null, block, 'A blank lookup still yields the declared key');
        System.assertEquals(0, (Integer) block.get('totalSize'), 'and an empty collection');
    }

    @IsTest
    static void lookupFieldListedInFieldsNoLongerFailsTheQuery() {
        Contact c = firstContact();
        // The lookup field was appended unconditionally, so listing it too produced
        // "duplicate field selected", the child query was swallowed and the loop rendered empty.
        Map<String, Object> cfg = config(
            new Map<String, Object>{ 'fields' => new List<Object>{ 'Id', 'LastName', 'AccountId' } }
        );
        Test.startTest();
        Map<String, Object> data = dataFor(c.Id, cfg);
        Test.stopTest();

        System.assertEquals(
            3,
            (Integer) ((Map<String, Object>) data.get('Colleagues')).get('totalSize'),
            'Duplicate lookup field must be de-duplicated, not fail the child query'
        );
    }

    @IsTest
    static void plainChildNodeIsUnchanged() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
        String cfg = JSON.serialize(
            new Map<String, Object>{
                'v' => 3,
                'root' => 'Account',
                'nodes' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'n0',
                        'object' => 'Account',
                        'parentNode' => null,
                        'fields' => new List<Object>{ 'Id', 'Name' },
                        'parentFields' => new List<Object>()
                    },
                    new Map<String, Object>{
                        'id' => 'n1',
                        'object' => 'Contact',
                        'parentNode' => 'n0',
                        'relationshipName' => 'Contacts',
                        'lookupField' => 'AccountId',
                        'fields' => new List<Object>{ 'Id', 'LastName', 'AccountId' },
                        'parentFields' => new List<Object>()
                    }
                }
            }
        );
        Test.startTest();
        Map<String, Object> data = DocGenDataRetriever.getRecordData(acc.Id, 'Account', cfg);
        Test.stopTest();

        System.assertEquals(
            3,
            (Integer) ((Map<String, Object>) data.get('Contacts')).get('totalSize'),
            'A node without parentKeyField still joins on the parent Id and stays a collection'
        );
    }

    @IsTest
    static void rejectsAParentKeyFieldThatIsNotALookup() {
        Contact c = firstContact();
        Boolean threw = false;
        Test.startTest();
        try {
            dataFor(c.Id, config(new Map<String, Object>{ 'parentKeyField' => 'LastName' }));
        } catch (DocGenException e) {
            threw = e.getMessage().contains('not a lookup field');
        }
        Test.stopTest();
        System.assert(threw, 'A non-reference parentKeyField must be rejected with a clear message');
    }

    @IsTest
    static void parentKeyNodesAreNotScoutedForTheGiantQueryPath() {
        Contact c = firstContact();
        Map<String, Object> cfg = config(null);
        List<Object> nodes = (List<Object>) cfg.get('nodes');
        nodes.add(
            new Map<String, Object>{
                'id' => 'n2',
                'object' => 'Case',
                'parentNode' => 'n0',
                'relationshipName' => 'Cases',
                'lookupField' => 'ContactId',
                'fields' => new List<Object>{ 'Id' },
                'parentFields' => new List<Object>()
            }
        );
        nodes.add(
            new Map<String, Object>{
                'id' => 'n3',
                'object' => 'Case',
                'parentNode' => 'n0',
                'relationshipName' => 'Cases',
                'alias' => 'LatestCase',
                'single' => true,
                'lookupField' => 'ContactId',
                'fields' => new List<Object>{ 'Id' },
                'parentFields' => new List<Object>()
            }
        );
        Test.startTest();
        Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(c.Id, JSON.serialize(cfg));
        Test.stopTest();

        // The scout counts children against the record's own Id, which is the wrong key for
        // a parentKeyField node, and the giant-query path can follow neither that join nor a
        // single node's one-record shape, so both stay on the standard path. Plain nodes count.
        System.assertEquals(false, counts.containsKey('Colleagues'), 'parentKeyField node must not be scouted');
        System.assertEquals(false, counts.containsKey('LatestCase'), 'single node must not be scouted');
        System.assertEquals(0, counts.get('Cases'), 'A plain child node is still counted');
    }

    @IsTest
    static void bulkPathJoinsEachRecordThroughItsOwnLookup() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
        Account other = new Account(Name = 'Other Account');
        insert other;
        Contact elsewhere = new Contact(LastName = 'Elsewhere', AccountId = other.Id);
        Contact orphan = new Contact(LastName = 'Orphan');
        insert new List<Contact>{ elsewhere, orphan };
        Contact c1 = firstContact();
        Contact c2 = [SELECT Id FROM Contact WHERE LastName = 'Contact 2' LIMIT 1];
        Set<Id> ids = new Set<Id>{ c1.Id, c2.Id, elsewhere.Id, orphan.Id };
        Map<String, Object> cfg = config(new Map<String, Object>{ 'limit' => '2' });

        Test.startTest();
        Map<String, Object> d1 = bulkDataFor(ids, cfg, c1.Id);
        Map<String, Object> d2 = bulkDataFor(ids, cfg, c2.Id);
        Map<String, Object> d3 = bulkDataFor(ids, cfg, elsewhere.Id);
        Map<String, Object> d4 = bulkDataFor(ids, cfg, orphan.Id);
        Test.stopTest();

        // Two records sharing one lookup value each get the rows (LIMIT stays per record);
        // a record on another account gets only its own; a blank lookup gets an empty collection.
        System.assertEquals(2, (Integer) ((Map<String, Object>) d1.get('Colleagues')).get('totalSize'), 'c1: limit 2');
        System.assertEquals(
            2,
            (Integer) ((Map<String, Object>) d2.get('Colleagues')).get('totalSize'),
            'c2 shares the account'
        );
        System.assertEquals(
            1,
            (Integer) ((Map<String, Object>) d3.get('Colleagues')).get('totalSize'),
            'other account: own contact only'
        );
        System.assertEquals(
            0,
            (Integer) ((Map<String, Object>) d4.get('Colleagues')).get('totalSize'),
            'blank lookup: empty'
        );
        System.assertNotEquals(null, acc, 'setup account present');
    }
}

@IsTest
private class DocGenGiantQueryWordTest {
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
    }

    private static Map<String, Object> contacts(String alias, String whereClause) {
        return new Map<String, Object>{
            'id' => alias,
            'parentNode' => 'account',
            'object' => 'Contact',
            'relationshipName' => 'Contacts',
            'lookupField' => 'AccountId',
            'alias' => alias,
            'fields' => new List<String>{ 'FirstName', 'LastName' },
            'where' => whereClause
        };
    }

    private static String queryConfig(List<Object> children) {
        List<Object> nodes = new List<Object>{
            new Map<String, Object>{ 'id' => 'account', 'object' => 'Account', 'fields' => new List<String>{ 'Name' } }
        };
        nodes.addAll(children);
        return JSON.serialize(new Map<String, Object>{ 'v' => 3, 'root' => 'Account', 'nodes' => nodes });
    }

    private static String row(String content) {
        return '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>' + content + '</w:t></w:r></w:p></w:tc></w:tr></w:tbl>';
    }

    @IsTest
    static void plansLargeSiblingsAndMergesTheSmallSibling() {
        Account parent = new Account(Name = 'Word giant query parent');
        insert parent;
        insert new List<Contact>{
            new Contact(AccountId = parent.Id, FirstName = 'First', LastName = 'Streamed'),
            new Contact(AccountId = parent.Id, FirstName = 'Second', LastName = 'Streamed'),
            new Contact(AccountId = parent.Id, FirstName = 'Small sibling', LastName = 'Eager')
        };
        String config = queryConfig(
            new List<Object>{
                contacts('FirstQuery', 'FirstName = \'First\''),
                contacts('SecondQuery', 'FirstName = \'Second\''),
                contacts('SmallQuery', 'LastName = \'Eager\''),
                contacts('UnusedQuery', 'LastName = \'Streamed\'')
            }
        );
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Word giant sibling test',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Base_Object_API__c = 'Account',
            Query_Config__c = config
        );
        insert template;
        String document =
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' +
            '<w:body><w:p><w:r><w:t>{Name}</w:t></w:r></w:p>' +
            row('{#SecondQuery}{LastName}{/SecondQuery}') +
            row('{#SmallQuery}{FirstName}{/SmallQuery}') +
            row('{#FirstQuery}{FirstName}{/FirstQuery}') +
            row('{#SecondQuery}{FirstName}{/SecondQuery}') +
            '</w:body></w:document>';
        ContentVersion cv = TestDataFactory.createValidDocxFile(template.Id, document);
        insert new DocGen_Template_Version__c(
            Template__c = template.Id,
            Is_Active__c = true,
            Content_Version_Id__c = cv.Id
        );

        List<String> streamed = new List<String>{ 'FirstQuery', 'SecondQuery', 'UnusedQuery' };
        Test.startTest();
        Map<String, Object> shell = DocGenController.generateDocumentPartsGiantQueryMulti(
            template.Id,
            parent.Id,
            streamed
        );
        Map<String, Object> data = DocGenDataRetriever.getRecordData(
            parent.Id,
            'Account',
            config,
            new Set<String>(streamed)
        );
        Test.stopTest();

        for (String key : streamed) {
            Assert.isFalse(data.containsKey(key), 'The shell must not prefetch ' + key);
        }
        Assert.isTrue(data.containsKey('SmallQuery'), 'The ordinary sibling still loads in the shell');
        List<Map<String, String>> slots = (List<Map<String, String>>) shell.get('slots');
        Assert.areEqual(3, slots.size(), 'Two different aliases and a repeated placement must be retained');
        Assert.areEqual('SecondQuery', slots[0].get('queryKey'));
        Assert.areEqual('FirstQuery', slots[1].get('queryKey'));
        Assert.areEqual('SecondQuery', slots[2].get('queryKey'));
        Assert.isTrue(slots[0].get('innerXml').contains('{LastName}'));
        Assert.isTrue(slots[2].get('innerXml').contains('{FirstName}'));
        String xml = ((Map<String, String>) shell.get('allXmlParts')).get('word/document.xml');
        Assert.isTrue(xml.contains('Word giant query parent'));
        Assert.isTrue(xml.contains('Small sibling'));
        Assert.isTrue(xml.indexOf(slots[0].get('marker')) < xml.indexOf('Small sibling'));
        Assert.isTrue(xml.indexOf('Small sibling') < xml.indexOf(slots[1].get('marker')));
        Assert.isTrue(xml.indexOf(slots[1].get('marker')) < xml.indexOf(slots[2].get('marker')));
    }

    @IsTest
    static void filtersChildrenWithinTheRequestedParent() {
        Account included = new Account(Name = 'Included parent');
        Account excluded = new Account(Name = 'Excluded parent');
        insert new List<Account>{ included, excluded };
        Contact first = new Contact(AccountId = included.Id, FirstName = 'First', LastName = 'Scoped');
        Contact second = new Contact(AccountId = included.Id, FirstName = 'Second', LastName = 'Scoped');
        insert new List<Contact>{
            first,
            second,
            new Contact(AccountId = excluded.Id, FirstName = 'Second', LastName = 'Out of scope')
        };
        String filter = 'FirstName = \'First\' OR FirstName = \'Second\'';
        String config = queryConfig(new List<Object>{ contacts('ScopedContacts', filter) });

        Test.startTest();
        Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(included.Id, config);
        List<Id> rows = DocGenController.getSortedChildIds(
            'Contact',
            'AccountId',
            included.Id,
            'FirstName ASC',
            filter
        );
        Test.stopTest();

        Assert.areEqual(2, counts.get('ScopedContacts'));
        Assert.areEqual(new List<Id>{ first.Id, second.Id }, rows);
    }

    @IsTest
    static void formatsDateOnItsCalendarDayAndDatetimeInTheUserTimeZone() {
        User westernUser = new User(
            Alias = 'dgdate',
            Email = 'portwood-giant-date@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Giant Query Dates',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = UserInfo.getProfileId(),
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'portwood-giant-date-' + System.currentTimeMillis() + '@example.com'
        );
        insert westernUser;

        System.runAs(westernUser) {
            String rendered = DocGenService.processXmlForTest(
                '{Day:MM/dd/yyyy}|{Instant:MM/dd/yyyy HH:mm}',
                new Map<String, Object>{
                    'Day' => Date.newInstance(2026, 11, 1),
                    'Instant' => Datetime.newInstanceGmt(2026, 11, 1, 0, 0, 0)
                }
            );
            Assert.areEqual('11/01/2026|10/31/2026 17:00', rendered);
        }
    }
}

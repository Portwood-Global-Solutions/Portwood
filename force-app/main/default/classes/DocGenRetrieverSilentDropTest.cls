/**
 * #332 — a child relationship the running user cannot fully read is dropped from the
 * merge data, and the document still generates. That part is deliberate: a partial
 * document beats a failed one. What was wrong is that it happened with no exception,
 * no log, and no signal of any kind, so a Care Plan missing half its Goal Assignments
 * looked exactly like a complete one.
 *
 * Every child query in DocGenDataRetriever runs in USER_MODE, which throws when the
 * running user lacks FLS on ANY field in the select list. Six catch blocks turned that
 * into "this relationship has no records" — in a 2,449-line class with zero logging.
 *
 * These tests pin both halves of the contract:
 *   - the drop still happens, and generation still succeeds (PROOF 1-3)
 *   - it now leaves a Warning row naming the relationship and the cause (PROOF 4)
 *   - a healthy generation stays quiet, so the log does not become noise
 *
 * Note the V1 flat-config path does NOT behave this way — it surfaces a DocGenException
 * for the same misconfiguration. The inconsistency between V1 and V3 is why this went
 * unnoticed; only the V3 node-tree path is silent, and that is the path exercised here.
 */
@IsTest
private class DocGenRetrieverSilentDropTest {
    /**
     * Minimum-access user granted object Read on Account + Contact, but NO field
     * permissions. Wrapped in runAs(current user) so the setup-object DML does not
     * trip MIXED_DML_OPERATION against the Account/Contact inserts.
     */
    private static User buildRestrictedUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
        User u = new User(
            FirstName = 'Silent',
            LastName = 'Drop',
            Email = 'silentdrop@portwood.test',
            Username = 'silentdrop-' + DateTime.now().getTime() + '@portwood.test',
            Alias = 'sdrop',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;

        PermissionSet ps = new PermissionSet(Name = 'DG332Probe', Label = 'DG332 Probe');
        insert ps;
        insert new List<ObjectPermissions>{
            new ObjectPermissions(
                ParentId = ps.Id,
                SobjectType = 'Account',
                PermissionsRead = true,
                PermissionsViewAllRecords = true
            ),
            new ObjectPermissions(
                ParentId = ps.Id,
                SobjectType = 'Contact',
                PermissionsRead = true,
                PermissionsViewAllRecords = true
            )
        };
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    @IsTest
    static void childRelationshipIsDroppedSilentlyWhenAFieldIsNotReadable() {
        User restricted;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            restricted = buildRestrictedUser();
        }

        Account a = new Account(Name = 'Care Plan Account');
        insert a;
        insert new List<Contact>{
            new Contact(LastName = 'Goal One', AccountId = a.Id, Email = 'g1@portwood.test'),
            new Contact(LastName = 'Goal Two', AccountId = a.Id, Email = 'g2@portwood.test'),
            new Contact(LastName = 'Goal Three', AccountId = a.Id, Email = 'g3@portwood.test')
        };

        // V3 node-tree config — the format that routes through processChildNodes and
        // the catch at DocGenDataRetriever.cls:995. Selects Contact.Email, which is
        // object-readable but NOT field-readable for this user.
        String config =
            '{"v":3,"nodes":[' +
            '{"id":"root","object":"Account","fields":["Name"]},' +
            '{"id":"kids","object":"Contact","parentNode":"root","lookupField":"AccountId",' +
            '"relationshipName":"Contacts","fields":["LastName","Email"]}' +
            ']}';

        Map<String, Object> asAdmin = DocGenDataRetriever.getRecordData(a.Id, 'Account', config);
        Map<String, Object> adminKids = (Map<String, Object>) asAdmin.get('Contacts');
        Integer adminCount = (Integer) adminKids.get('totalSize');
        System.assertEquals(3, adminCount, 'Admin baseline: all three child rows present');

        Map<String, Object> asRestricted;
        String caught = null;
        Integer visibleToUser = -1;
        Test.startTest();
        System.runAs(restricted) {
            // The user CAN see the child records — exactly craig's report.
            visibleToUser = [SELECT COUNT() FROM Contact WHERE AccountId = :a.Id];

            try {
                asRestricted = DocGenDataRetriever.getRecordData(a.Id, 'Account', config);
            } catch (Exception e) {
                caught = e.getTypeName() + ' — ' + e.getMessage();
            }
        }
        Test.stopTest();

        System.assertEquals(3, visibleToUser, 'Restricted user can see all three children in a plain query');
        System.assertEquals(null, caught, 'PROOF 1: generation does not fail — no error reaches the caller');

        Object kidsRaw = asRestricted.get('Contacts');
        Integer restrictedCount = kidsRaw == null ? -1 : (Integer) ((Map<String, Object>) kidsRaw).get('totalSize');

        System.assertNotEquals(
            3,
            restrictedCount,
            'PROOF 2: the restricted user does NOT get the three rows the admin got'
        );
        // The catch does `continue` BEFORE parentDataMap.put(child.dataMapKey(), …),
        // so the relationship key is absent entirely rather than present-and-empty.
        // A {#Contacts} loop over a missing key renders nothing at all.
        System.assertEquals(
            null,
            kidsRaw,
            'PROOF 3: the relationship key is absent from the merge map, not present-and-empty'
        );

        // PROOF 4 — the drop now leaves a trace. Generation still succeeds and still
        // returns a partial document; the difference is that an admin can find out why.
        DocGenErrorLogger.flush();
        List<DocGen_Error_Log__c> logs = [
            SELECT Severity__c, Context__c, Operation__c, Message__c
            FROM DocGen_Error_Log__c
            WHERE Context__c = 'DocGenDataRetriever' AND Operation__c = 'childQuery'
        ];
        System.assertEquals(1, logs.size(), 'PROOF 4: exactly one Warning row for the dropped relationship');
        System.assertEquals('Warning', logs[0].Severity__c, 'Logged as a Warning, not an Error — generation succeeded');
        System.assert(
            logs[0].Message__c.contains('Contacts'),
            'The log names the relationship that vanished. Got: ' + logs[0].Message__c
        );
        System.assert(
            logs[0].Message__c.contains('Contact'),
            'The log names the child object. Got: ' + logs[0].Message__c
        );
    }

    /**
     * The admin path must stay quiet — a relationship that resolves correctly should
     * never produce a Warning row, or the log becomes noise nobody reads.
     */
    @IsTest
    static void noWarningIsLoggedWhenEveryChildRelationshipResolves() {
        Account a = new Account(Name = 'Fully Readable Account');
        insert a;
        insert new Contact(LastName = 'Goal One', AccountId = a.Id, Email = 'g1@portwood.test');

        String config =
            '{"v":3,"nodes":[' +
            '{"id":"root","object":"Account","fields":["Name"]},' +
            '{"id":"kids","object":"Contact","parentNode":"root","lookupField":"AccountId",' +
            '"relationshipName":"Contacts","fields":["LastName","Email"]}' +
            ']}';

        Test.startTest();
        Map<String, Object> data = DocGenDataRetriever.getRecordData(a.Id, 'Account', config);
        DocGenErrorLogger.flush();
        Test.stopTest();

        Map<String, Object> kids = (Map<String, Object>) data.get('Contacts');
        System.assertEquals(1, (Integer) kids.get('totalSize'), 'Admin gets the child row');
        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM DocGen_Error_Log__c
                WHERE Context__c = 'DocGenDataRetriever' AND Operation__c = 'childQuery'
            ],
            'A healthy generation logs nothing'
        );
    }
}

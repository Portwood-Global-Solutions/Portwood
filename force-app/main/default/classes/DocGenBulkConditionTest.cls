// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
/**
 * #600 — bulk generation rejected every child-record semi-join, e.g. the NPSP household
 * filter
 *
 *     RecordType.DeveloperName = 'HH_Account'
 *       AND npo02__OppAmountLastYear__c > 0
 *       AND Id IN (SELECT AccountId FROM Contact WHERE Acknowledgement_Preference__c = '…')
 *
 * with "Invalid filter condition.". These tests use the same shape on standard fields
 * (Contact.Title stands in for the preference picklist, Owner.IsActive for the
 * relationship path) so they run in any org.
 */
@IsTest
private class DocGenBulkConditionTest {
    private static final String MAIL = 'Mail - One-Time Year End';
    private static final String MAIL_CONTACTS = 'Id IN (SELECT AccountId FROM Contact WHERE Title = \'' + MAIL + '\')';

    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        Database.insert(
            new DocGen_Template__c(Name = 'Semi-Join Bulk Template', Base_Object_API__c = 'Account', Type__c = 'Word'),
            AccessLevel.SYSTEM_MODE
        );
        // (Apex names are case-insensitive: a local called `mail` would shadow MAIL.)
        Account mailAcct = new Account(Name = 'SJ Mail', Industry = 'Education', AnnualRevenue = 500);
        Account emailAcct = new Account(Name = 'SJ Email', Industry = 'Education', AnnualRevenue = 500);
        Account noRevenue = new Account(Name = 'SJ No Revenue', Industry = 'Education', AnnualRevenue = 0);
        Account banking = new Account(Name = 'SJ Banking', Industry = 'Banking', AnnualRevenue = 500);
        insert new List<Account>{ mailAcct, emailAcct, noRevenue, banking };
        insert new List<Contact>{
            new Contact(LastName = 'Mail', Title = MAIL, AccountId = mailAcct.Id),
            new Contact(LastName = 'Email', Title = 'Email', AccountId = emailAcct.Id),
            new Contact(LastName = 'No Revenue', Title = MAIL, AccountId = noRevenue.Id),
            new Contact(LastName = 'Banking', Title = MAIL, AccountId = banking.Id)
        };
    }

    private static Id accountId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    private static User me() {
        return [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
    }

    // ── The reported filter ─────────────────────────────────────────────────

    @IsTest
    static void validateFilterAcceptsTheReportedHouseholdShape() {
        System.runAs(me()) {
            // Multi-line, exactly as pasted into the Bulk Generation filter box.
            String condition =
                'Owner.IsActive = true\n' +
                '  AND Industry = \'Education\'\n' +
                '  AND AnnualRevenue > 0\n' +
                '  AND Id IN (\n' +
                '      SELECT AccountId FROM Contact\n' +
                '      WHERE Title = \'' +
                MAIL +
                '\'\n' +
                '  )';
            System.assertEquals(
                1,
                DocGenBulkController.validateFilter('Account', condition),
                'Only the Education account with revenue and a mail-preference contact matches.'
            );
        }
    }

    @IsTest
    static void validateFilterAcceptsTheReportedOpportunitySemiJoin() {
        System.runAs(me()) {
            List<OpportunityStage> won = [
                SELECT ApiName
                FROM OpportunityStage
                WHERE IsWon = TRUE AND IsActive = TRUE
                LIMIT 1
            ];
            if (won.isEmpty()) {
                return; // no won stage configured in this org
            }
            insert new Opportunity(
                Name = 'SJ Won',
                AccountId = accountId('SJ Mail'),
                StageName = won[0].ApiName,
                CloseDate = Date.today()
            );
            System.assertEquals(
                1,
                DocGenBulkController.validateFilter(
                    'Account',
                    'Id IN (SELECT AccountId FROM Opportunity WHERE IsWon = true)'
                ),
                'The simple child-query repro from the report must run.'
            );
        }
    }

    @IsTest
    static void validateFilterAcceptsAnAntiJoin() {
        System.runAs(me()) {
            System.assertEquals(
                1,
                DocGenBulkController.validateFilter(
                    'Account',
                    'Industry = \'Education\' AND AnnualRevenue > 0 AND Id NOT IN ' +
                        '(SELECT AccountId FROM Contact WHERE Title = \'' +
                        MAIL +
                        '\')'
                ),
                'NOT IN must leave only the Education account whose contact prefers email.'
            );
        }
    }

    // ── What the parser must still refuse ───────────────────────────────────

    @IsTest
    static void validateFilterRejectsUnsafeOrUnsupportedSemiJoins() {
        List<String> rejected = new List<String>{
            // SOQL forbids a semi-join under OR, or nested inside parentheses
            'Industry = \'Education\' OR ' + MAIL_CONTACTS,
            '(Industry = \'Education\' AND ' +
            MAIL_CONTACTS +
            ')',
            // at most two semi-joins per query
            MAIL_CONTACTS +
            ' AND ' +
            MAIL_CONTACTS +
            ' AND ' +
            MAIL_CONTACTS,
            // a semi-join inside a semi-join
            'Id IN (SELECT AccountId FROM Contact WHERE Id IN (SELECT ContactId FROM Case))',
            // Account Id compared against a User Id
            'Id IN (SELECT OwnerId FROM Contact)',
            // a self-join on a non-ID field
            'Name IN (SELECT Name FROM Account)',
            // unknown field on the inner object
            'Id IN (SELECT AccountId FROM Contact WHERE Not_A_Real_Field__c = 1)',
            // trailing clauses, statement chaining, comments, bind variables
            MAIL_CONTACTS + ' LIMIT 1',
            MAIL_CONTACTS + '; DELETE',
            MAIL_CONTACTS + ' -- x',
            'Id IN (SELECT AccountId FROM Contact WHERE LastName = :x)',
            'Id IN (SELECT AccountId FROM Contact GROUP BY AccountId)'
        };
        System.runAs(me()) {
            for (String condition : rejected) {
                Boolean threw = false;
                try {
                    DocGenBulkController.validateFilter('Account', condition);
                } catch (AuraHandledException e) {
                    threw = true;
                    System.assert(
                        e.getMessage().contains('Invalid'),
                        'Unexpected message for ' + condition + ': ' + e.getMessage()
                    );
                }
                System.assert(threw, 'Must reject: ' + condition);
            }
        }
    }

    @IsTest
    static void hasSubqueryIgnoresSelectInsideLiterals() {
        System.assertEquals(false, DocGenBulkCondition.hasSubquery(null));
        System.assertEquals(false, DocGenBulkCondition.hasSubquery('Name = \'Select Partner\''));
        System.assertEquals(false, DocGenBulkCondition.hasSubquery('Selected__c = true'));
        System.assertEquals(true, DocGenBulkCondition.hasSubquery(MAIL_CONTACTS));
        System.assertEquals(true, DocGenBulkCondition.hasSubquery('Id IN (\nselect\nAccountId FROM Contact)'));
    }

    @IsTest
    static void relatedRecordPickerStillRejectsSubqueries() {
        // sanitizeCondition backs the related-record picker, which nests its filter in
        // parentheses — a semi-join can never be valid there, so it stays rejected.
        Boolean threw = false;
        try {
            DocGenBulkController.sanitizeCondition(MAIL_CONTACTS);
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assert(threw, 'sanitizeCondition must keep rejecting sub-selects.');
    }

    // ── Combining with the template's Record Filter ─────────────────────────

    @IsTest
    static void batchHoistsSemiJoinWhenAddingTemplateRecordFilter() {
        System.runAs(me()) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            // OR in the template filter must stay grouped; the semi-join must not be nested.
            t.Record_Filter__c = 'Industry = \'Education\' OR Industry = \'Banking\'';
            Database.update(t, AccessLevel.SYSTEM_MODE);
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'AnnualRevenue > 0 AND ' + MAIL_CONTACTS,
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            String combined = new DocGenBatch(job.Id).andTemplateFilter(job.Query_Condition__c);

            System.assertEquals(
                2,
                Database.countQuery('SELECT Count() FROM Account WHERE ' + combined),
                'Education + Banking accounts with revenue and a mail contact: ' + combined
            );
        }
    }

    @IsTest
    static void batchAcceptsSemiJoinInTemplateRecordFilter() {
        System.runAs(me()) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            t.Record_Filter__c = MAIL_CONTACTS;
            Database.update(t, AccessLevel.SYSTEM_MODE);
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Industry = \'Education\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            String combined = new DocGenBatch(job.Id).andTemplateFilter(job.Query_Condition__c);

            System.assertEquals(
                2,
                Database.countQuery('SELECT Count() FROM Account WHERE ' + combined),
                'Education accounts with a mail contact (with and without revenue): ' + combined
            );
        }
    }

    // ── End to end ──────────────────────────────────────────────────────────

    @IsTest
    static void bulkJobRunsWithSemiJoinCondition() {
        System.runAs(me()) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Test.startTest();
            Id jobId = DocGenBulkController.submitJobInternal(
                t.Id,
                'Industry = \'Education\' AND AnnualRevenue > 0 AND ' + MAIL_CONTACTS,
                'Semi-join job',
                false,
                200,
                false
            );
            Test.stopTest();

            DocGen_Job__c job = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals(1, job.Total_Records__c, 'The batch must select exactly the matching household.');
        }
    }

    @IsTest
    static void submitRejectsInvalidSemiJoinBeforeCreatingAJob() {
        System.runAs(me()) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Boolean threw = false;
            try {
                DocGenBulkController.submitJobInternal(
                    t.Id,
                    'Industry = \'Education\' OR ' + MAIL_CONTACTS,
                    null,
                    false,
                    1,
                    false
                );
            } catch (DocGenException e) {
                threw = true;
            }
            System.assert(threw, 'An OR around a semi-join must fail at submit time.');
            System.assertEquals(0, [SELECT COUNT() FROM DocGen_Job__c], 'No job may be created for it.');
        }
    }

    @IsTest
    static void flowCombinesSemiJoinWithRecordIds() {
        System.runAs(me()) {
            String combined = DocGenBulkFlowAction.buildEffectiveCondition(
                'Account',
                MAIL_CONTACTS,
                new List<String>{ accountId('SJ Mail'), accountId('SJ Email') }
            );
            System.assertEquals(
                1,
                Database.countQuery('SELECT Count() FROM Account WHERE ' + combined),
                'Both the semi-join and the supplied IDs must restrict the selection: ' + combined
            );
        }
    }

    @IsTest
    static void flowActionRunsSemiJoinWithRecordIdsAndTemplateFilter() {
        System.runAs(me()) {
            DocGen_Template__c t = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            t.Record_Filter__c = 'AnnualRevenue > 0';
            Database.update(t, AccessLevel.SYSTEM_MODE);

            DocGenBulkFlowAction.Request request = new DocGenBulkFlowAction.Request();
            request.templateId = t.Id;
            request.queryCondition = MAIL_CONTACTS;
            // SJ Mail: selected; SJ No Revenue: template filter excludes; SJ Email: semi-join excludes
            request.recordIds = new List<String>{
                accountId('SJ Mail'),
                accountId('SJ No Revenue'),
                accountId('SJ Email')
            };
            request.combinedPdfOnly = false;
            request.batchSize = 200;

            Test.startTest();
            DocGenBulkFlowAction.Response result = DocGenBulkFlowAction.generateBulkDocuments(
                new List<DocGenBulkFlowAction.Request>{ request }
            )[0];
            Test.stopTest();

            System.assertEquals(true, result.success, 'Flow submission failed: ' + result.errorMessage);
            DocGen_Job__c job = [SELECT Total_Records__c FROM DocGen_Job__c WHERE Id = :result.jobId];
            System.assertEquals(1, job.Total_Records__c, 'All three filters must restrict the selected Accounts.');
        }
    }
}

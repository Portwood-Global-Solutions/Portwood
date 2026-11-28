@IsTest
private class DocGenBrowserPdfPlannerTest {
    @IsTest
    static void freezesOrdinalOrderBeforeRendering() {
        TestDataFactory.assignAdminPermissionSet();
        insert new List<Account>{
            new Account(Name = 'Planning Z'),
            new Account(Name = 'Planning A'),
            new Account(Name = 'Planning A')
        };
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Browser plan test',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF'
        );
        insert template;
        DocGen_Job__c job = new DocGen_Job__c(Template__c = template.Id, Status__c = 'Queued', Browser_Merge__c = true);
        insert job;
        List<Account> expected = [SELECT Id FROM Account WHERE Name LIKE 'Planning %' ORDER BY Name, Id];

        Test.startTest();
        DocGenBrowserPdfPlanner.enqueue(job.Id, 'Account', 'Name LIKE \'Planning %\'', 'Name ASC, Id ASC', 3);
        Test.stopTest();

        List<DocGen_Browser_Pdf_Block__c> blocks = [
            SELECT First_Ordinal__c, Last_Ordinal__c, Source_Ids__c
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :job.Id
            ORDER BY First_Ordinal__c
        ];
        System.assertEquals(1, blocks.size());
        System.assertEquals(1, blocks[0].First_Ordinal__c);
        System.assertEquals(3, blocks[0].Last_Ordinal__c);
        System.assertEquals(
            JSON.serialize(new List<Id>{ expected[0].Id, expected[1].Id, expected[2].Id }),
            blocks[0].Source_Ids__c
        );
    }

    @IsTest
    static void freezesContactSemiJoinWithTemplateAudienceAndLiteralIds() {
        TestDataFactory.assignAdminPermissionSet();
        List<Account> accounts = new List<Account>{
            new Account(Name = 'Browser Eligible Alpha'),
            new Account(Name = 'Supported Donor Beta'),
            new Account(Name = 'Browser Eligible Without Receipt Contact'),
            new Account(Name = 'Outside Saved Browser Audience'),
            new Account(Name = 'Supported Donor Outside Selected Ids')
        };
        insert accounts;
        insert new List<Contact>{
            new Contact(LastName = 'Statement Recipient', AccountId = accounts[0].Id),
            new Contact(LastName = 'Statement Recipient', AccountId = accounts[1].Id),
            new Contact(LastName = 'General Enquiries', AccountId = accounts[2].Id),
            new Contact(LastName = 'Statement Recipient', AccountId = accounts[3].Id),
            new Contact(LastName = 'Statement Recipient', AccountId = accounts[4].Id)
        };
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Browser recipient filter',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account',
            Output_Format__c = 'PDF',
            Is_Active__c = true,
            Record_Filter__c = 'Name LIKE \'Browser Eligible %\' OR Name LIKE \'Supported Donor %\''
        );
        insert template;
        List<String> selectedIds = new List<String>();
        for (Integer index = 0; index < 4; index++) {
            selectedIds.add('\'' + accounts[index].Id + '\'');
        }
        String condition =
            'Id IN (' +
            String.join(selectedIds, ', ') +
            ')' +
            ' AND Id IN (SELECT AccountId FROM Contact WHERE LastName = \'Statement Recipient\')';

        Test.startTest();
        Integer rawMatches = DocGenBulkController.validateFilter('Account', condition);
        Integer templateMatches = DocGenBulkController.validateTemplateFilter(template.Id, condition);
        Id jobId = DocGenBulkController.submitBrowserMergeJob(
            template.Id,
            condition,
            'Browser recipients',
            4,
            'Name DESC'
        );
        Test.stopTest();

        System.assertEquals(3, rawMatches, 'A literal IN list and a Contact semi-join must both affect the count.');
        System.assertEquals(2, templateMatches, 'The saved template audience must also affect the count.');
        DocGen_Job__c job = [SELECT Total_Records__c FROM DocGen_Job__c WHERE Id = :jobId];
        System.assertEquals(2, job.Total_Records__c, 'Browser planning must select the same Accounts as validation.');
        List<DocGen_Browser_Pdf_Block__c> blocks = [
            SELECT First_Ordinal__c, Last_Ordinal__c, Source_Ids__c
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId
        ];
        System.assertEquals(1, blocks.size());
        System.assertEquals(1, blocks[0].First_Ordinal__c);
        System.assertEquals(2, blocks[0].Last_Ordinal__c);
        System.assertEquals(
            JSON.serialize(new List<Id>{ accounts[1].Id, accounts[0].Id }),
            blocks[0].Source_Ids__c,
            'Only matching Accounts should be pinned, in the requested order.'
        );
    }
}

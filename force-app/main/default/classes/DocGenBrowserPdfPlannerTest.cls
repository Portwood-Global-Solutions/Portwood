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
}

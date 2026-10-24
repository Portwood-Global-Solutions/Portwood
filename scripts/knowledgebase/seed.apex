// Documentation data only. Run in the dedicated knowledgebase scratch org.
// Re-running keeps the three named example accounts and their sample contacts.
List<Account> existing = [SELECT Id FROM Account WHERE Name = 'Northstar Bikes' LIMIT 1];
if (existing.isEmpty()) {
    List<Account> accounts = new List<Account>{
        new Account(
            Name = 'Northstar Bikes',
            Industry = 'Retail',
            Phone = '317-555-0142',
            Website = 'https://example.com',
            BillingCity = 'Indianapolis',
            BillingState = 'Indiana',
            AnnualRevenue = 1250000,
            Description = 'A fictional bicycle shop used in the Portwood knowledgebase.'
        ),
        new Account(
            Name = 'Willow and Pine',
            Industry = 'Retail',
            Phone = '317-555-0188',
            BillingCity = 'Carmel',
            BillingState = 'Indiana',
            AnnualRevenue = 480000
        ),
        new Account(
            Name = 'Bluebird Studio',
            Industry = 'Media',
            Phone = '317-555-0116',
            BillingCity = 'Bloomington',
            BillingState = 'Indiana',
            AnnualRevenue = 725000
        )
    };
    insert accounts;
    insert new List<Contact>{
        new Contact(
            AccountId = accounts[0].Id,
            FirstName = 'Jordan',
            LastName = 'Rivera',
            Title = 'Owner',
            Email = 'jordan.rivera@example.com'
        ),
        new Contact(
            AccountId = accounts[0].Id,
            FirstName = 'Avery',
            LastName = 'Chen',
            Title = 'Operations Manager',
            Email = 'avery.chen@example.com'
        ),
        new Contact(
            AccountId = accounts[1].Id,
            FirstName = 'Morgan',
            LastName = 'Lee',
            Title = 'Director',
            Email = 'morgan.lee@example.com'
        )
    };
    insert new List<Opportunity>{
        new Opportunity(
            AccountId = accounts[0].Id,
            Name = 'Northstar - Spring Service',
            StageName = 'Closed Won',
            CloseDate = Date.newInstance(2026, 10, 15),
            Amount = 12000
        ),
        new Opportunity(
            AccountId = accounts[0].Id,
            Name = 'Northstar - Fleet Upgrade',
            StageName = 'Prospecting',
            CloseDate = Date.newInstance(2026, 11, 15),
            Amount = 28000
        ),
        new Opportunity(
            AccountId = accounts[1].Id,
            Name = 'Willow - Annual Service',
            StageName = 'Closed Won',
            CloseDate = Date.newInstance(2026, 10, 20),
            Amount = 6000
        )
    };
}
System.debug('Knowledgebase example records are ready. No emails were sent.');

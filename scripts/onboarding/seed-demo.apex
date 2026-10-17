// Developer-only UX fixture. The product onboarding flow never runs this script.
// Scoped to the existing Portwood scratch org; preserves any previously seeded fixture.
if (UserInfo.getOrganizationId() != '00DRu00000aiv7VMAQ') {
    throw new DocGenException('This demo fixture is only authorized in portwood-proposal.');
}
String marker = 'Portwood onboarding UX fixture v1 - fictional CRM data';
List<Account> existing = [
    SELECT Id, Description
    FROM Account
    WHERE Name = 'Northstar Manufacturing - Journey Demo'
    LIMIT 1
];
if (!existing.isEmpty()) {
    if (existing[0].Description != marker)
        throw new DocGenException('Demo name is already in use; preserving the existing record.');
    System.debug(
        'STRESS_RESULT:' + JSON.serialize(new Map<String, Object>{ 'accountId' => existing[0].Id, 'reused' => true })
    );
} else {
    Account customer = new Account(
        Name = 'Northstar Manufacturing - Journey Demo',
        Description = marker,
        Industry = 'Manufacturing',
        Phone = '(317) 555-0142',
        BillingCity = 'Indianapolis',
        BillingState = 'IN'
    );
    insert customer;
    Pricebook2 standard = [SELECT Id, IsActive FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];
    if (!standard.IsActive) {
        standard.IsActive = true;
        update standard;
    }
    List<Product2> products = new List<Product2>{
        new Product2(Name = 'Demo - Launch workshop', IsActive = true),
        new Product2(Name = 'Demo - Implementation services', IsActive = true),
        new Product2(Name = 'Demo - Success support', IsActive = true)
    };
    insert products;
    List<PricebookEntry> prices = new List<PricebookEntry>{
        new PricebookEntry(Pricebook2Id = standard.Id, Product2Id = products[0].Id, UnitPrice = 4500, IsActive = true),
        new PricebookEntry(Pricebook2Id = standard.Id, Product2Id = products[1].Id, UnitPrice = 350, IsActive = true),
        new PricebookEntry(Pricebook2Id = standard.Id, Product2Id = products[2].Id, UnitPrice = 2000, IsActive = true)
    };
    insert prices;
    String openStage = [
        SELECT MasterLabel
        FROM OpportunityStage
        WHERE IsActive = TRUE AND IsClosed = FALSE
        ORDER BY SortOrder DESC
        LIMIT 1
    ]
    .MasterLabel;
    String earlyStage = [
        SELECT MasterLabel
        FROM OpportunityStage
        WHERE IsActive = TRUE AND IsClosed = FALSE
        ORDER BY SortOrder ASC
        LIMIT 1
    ]
    .MasterLabel;
    String closedStage = [SELECT MasterLabel FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = TRUE LIMIT 1]
    .MasterLabel;
    List<Opportunity> deals = new List<Opportunity>{
        new Opportunity(
            Name = 'Northstar - Customer Success Launch',
            AccountId = customer.Id,
            StageName = openStage,
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = standard.Id
        ),
        new Opportunity(
            Name = 'Northstar - Operations Expansion',
            AccountId = customer.Id,
            StageName = earlyStage,
            CloseDate = Date.today().addDays(60),
            Amount = 48000
        ),
        new Opportunity(
            Name = 'Closed QA deal - excluded from summary',
            AccountId = customer.Id,
            StageName = closedStage,
            CloseDate = Date.today(),
            Amount = 99999
        )
    };
    insert deals;
    insert new List<OpportunityLineItem>{
        new OpportunityLineItem(
            OpportunityId = deals[0].Id,
            PricebookEntryId = prices[0].Id,
            Quantity = 1,
            UnitPrice = 4500,
            Description = 'Discovery, planning, and success criteria.'
        ),
        new OpportunityLineItem(
            OpportunityId = deals[0].Id,
            PricebookEntryId = prices[1].Id,
            Quantity = 40,
            UnitPrice = 350,
            Description = 'Configure and launch the agreed solution.'
        ),
        new OpportunityLineItem(
            OpportunityId = deals[0].Id,
            PricebookEntryId = prices[2].Id,
            Quantity = 3,
            UnitPrice = 2000,
            Description = 'Three months of guided adoption.'
        )
    };
    String openStatus = [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = FALSE LIMIT 1].MasterLabel;
    String closedStatus = [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = TRUE LIMIT 1].MasterLabel;
    insert new List<Case>{
        new Case(
            AccountId = customer.Id,
            Subject = 'Confirm rollout access for the operations team',
            Status = openStatus,
            Priority = 'High',
            Origin = 'Web'
        ),
        new Case(
            AccountId = customer.Id,
            Subject = 'Review monthly reporting requirements',
            Status = openStatus,
            Priority = 'Medium',
            Origin = 'Web'
        ),
        new Case(
            AccountId = customer.Id,
            Subject = 'Closed QA case - excluded from summary',
            Status = closedStatus,
            Origin = 'Web'
        )
    };
    insert new List<Contact>{
        new Contact(
            AccountId = customer.Id,
            FirstName = 'Jordan',
            LastName = 'Ellis',
            Title = 'VP of Operations',
            Email = 'jordan@example.com'
        ),
        new Contact(
            AccountId = customer.Id,
            FirstName = 'Taylor',
            LastName = 'Reed',
            Title = 'Customer Success Lead',
            Email = 'taylor@example.com'
        )
    };
    System.debug(
        'STRESS_RESULT:' +
        JSON.serialize(
            new Map<String, Object>{ 'accountId' => customer.Id, 'opportunityId' => deals[0].Id, 'reused' => false }
        )
    );
}

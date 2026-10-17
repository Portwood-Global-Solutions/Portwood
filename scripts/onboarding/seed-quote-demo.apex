// Developer-only fixture. The product never creates CRM records for sample PDFs.
System.assertEquals('00DRu00000aiv7VMAQ', UserInfo.getOrganizationId(), 'Scratch demo scope only.');
System.assert(Schema.getGlobalDescribe().containsKey('Quote'), 'Enable Quotes in this scratch org first.');
Opportunity deal = [
    SELECT Id, Pricebook2Id, Account.Description
    FROM Opportunity
    WHERE Id = '006Ru00000XyLLBIA3'
    LIMIT 1
];
System.assertEquals('Portwood onboarding UX fixture v1 - fictional CRM data', deal.Account.Description);
String name = 'Northstar - Customer Success Quote';
String marker = 'Portwood onboarding Quote fixture v1 - fictional CRM data';
Id dealId = deal.Id;
List<SObject> existing = Database.query(
    'SELECT Id, Description FROM Quote WHERE Name = :name AND OpportunityId = :dealId LIMIT 1'
);
Id quoteId;
if (existing.isEmpty()) {
    SObject quote = Schema.getGlobalDescribe().get('Quote').newSObject();
    quote.put('Name', name);
    quote.put('OpportunityId', deal.Id);
    quote.put('Pricebook2Id', deal.Pricebook2Id);
    quote.put('Description', marker);
    quote.put('ExpirationDate', Date.today().addDays(30));
    quote.put('Tax', 600);
    quote.put('ShippingHandling', 150);
    insert quote;
    quoteId = quote.Id;
    List<SObject> lines = new List<SObject>();
    Integer sortOrder = 1;
    for (OpportunityLineItem item : [
        SELECT PricebookEntryId, Quantity, UnitPrice, Description, Product2.Name
        FROM OpportunityLineItem
        WHERE OpportunityId = :deal.Id
        ORDER BY SortOrder ASC
    ]) {
        SObject line = Schema.getGlobalDescribe().get('QuoteLineItem').newSObject();
        line.put('QuoteId', quoteId);
        line.put('PricebookEntryId', item.PricebookEntryId);
        line.put('Quantity', item.Quantity);
        line.put('UnitPrice', item.UnitPrice);
        line.put('Description', item.Description);
        line.put('Discount', item.Product2.Name.contains('Implementation') ? 10 : 0);
        line.put('SortOrder', sortOrder++);
        lines.add(line);
    }
    insert lines;
} else {
    System.assertEquals(marker, existing[0].get('Description'), 'Do not alter a non-fixture quote.');
    quoteId = existing[0].Id;
}
System.debug(
    'QUOTE_DEMO_RESULT:' +
    JSON.serialize(
        Database.query(
            'SELECT Id, QuoteNumber, Name, Subtotal, TotalPrice, Tax, ShippingHandling, GrandTotal, LineItemCount, IsSyncing FROM Quote WHERE Id = :quoteId'
        )
    )
);

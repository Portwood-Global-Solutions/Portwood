@IsTest
private class DocGenGettingStartedTest {
    @TestSetup
    static void records() {
        Account account = new Account(Name = 'Journey customer', Industry = 'Manufacturing');
        insert account;
        String openStage = [SELECT MasterLabel FROM OpportunityStage WHERE IsClosed = FALSE AND IsActive = TRUE LIMIT 1]
        .MasterLabel;
        String closedStage = [
            SELECT MasterLabel
            FROM OpportunityStage
            WHERE IsClosed = TRUE AND IsActive = TRUE
            LIMIT 1
        ]
        .MasterLabel;
        Opportunity openDeal = new Opportunity(
            Name = 'Open launch',
            AccountId = account.Id,
            StageName = openStage,
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert openDeal;
        insert new Opportunity(
            Name = 'Closed expansion',
            AccountId = account.Id,
            StageName = closedStage,
            CloseDate = Date.today(),
            Amount = 99000
        );
        Product2 product = new Product2(Name = 'Implementation workshop', IsActive = true);
        insert product;
        PricebookEntry price = new PricebookEntry(
            Product2Id = product.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            UnitPrice = 750,
            IsActive = true
        );
        insert price;
        insert new OpportunityLineItem(
            OpportunityId = openDeal.Id,
            PricebookEntryId = price.Id,
            Quantity = 2,
            UnitPrice = 750
        );
        String openStatus = [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = FALSE LIMIT 1].MasterLabel;
        String closedStatus = [SELECT MasterLabel FROM CaseStatus WHERE IsClosed = TRUE LIMIT 1].MasterLabel;
        insert new List<Case>{
            new Case(AccountId = account.Id, Subject = 'Open rollout question', Status = openStatus),
            new Case(AccountId = account.Id, Subject = 'Closed old question', Status = closedStatus)
        };
        insert new Contact(
            AccountId = account.Id,
            LastName = 'Journey',
            Title = 'Operations',
            Email = 'journey@example.com'
        );
        if (Schema.getGlobalDescribe().containsKey('Quote')) {
            SObject quote = Schema.getGlobalDescribe().get('Quote').newSObject();
            quote.put('Name', 'Launch quote');
            quote.put('OpportunityId', openDeal.Id);
            quote.put('Pricebook2Id', Test.getStandardPricebookId());
            quote.put('ExpirationDate', Date.today().addDays(30));
            quote.put('Tax', 100);
            quote.put('ShippingHandling', 25);
            insert quote;
            SObject line = Schema.getGlobalDescribe().get('QuoteLineItem').newSObject();
            line.put('QuoteId', quote.Id);
            line.put('PricebookEntryId', price.Id);
            line.put('Quantity', 2);
            line.put('UnitPrice', 750);
            line.put('Discount', 12.5);
            insert line;
        }
    }
    private static Id starter(String key, Id recordId) {
        return (Id) DocGenGettingStartedController.createStarter(key, recordId).get('templateId');
    }
    @IsTest
    static void readinessSupportsAdmin() {
        System.assertEquals(true, DocGenGettingStartedController.getReadiness().get('canCreate'));
    }
    @IsTest
    static void unavailableQuotesKeepOpportunityFallback() {
        DocGenGettingStartedController.quotesDisabledForTest = true;
        System.assertEquals(false, DocGenGettingStartedController.getReadiness().get('quoteAvailable'));
        try {
            starter('quote', null);
            System.assert(false, 'An unavailable Quote starter must be rejected on the server.');
        } catch (AuraHandledException expected) {
            System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
        }
        Id id = starter('opportunity', null);
        System.assertNotEquals(null, id, 'The opportunity starter still works without Quotes.');
    }
    @IsTest
    static void sampleQuoteUsesDiscountsAndPrivateFileWithoutCrmInsertion() {
        if (!Schema.getGlobalDescribe().containsKey('Quote'))
            return;
        Integer quotes = Database.countQuery('SELECT COUNT() FROM Quote');
        Integer lines = Database.countQuery('SELECT COUNT() FROM QuoteLineItem');
        Id id = starter('quote', null);
        Test.startTest();
        Map<String, Object> result = DocGenGettingStartedController.renderStarter('quote', id, null);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        for (
            String value : new List<String>{
                'Q-001024',
                'Implementation services',
                '24,500',
                '12,600',
                '23,100',
                '23,850',
                '600.00',
                '150.00',
                '10.00'
            }
        )
            System.assert(html.contains(value), value + ': ' + html);
        System.assert(!html.contains('{#QuoteLineItems}'));
        System.assertEquals(true, result.get('sampleData'));
        System.assertEquals(quotes, Database.countQuery('SELECT COUNT() FROM Quote'));
        System.assertEquals(lines, Database.countQuery('SELECT COUNT() FROM QuoteLineItem'));
        Id fileId = (Id) result.get('contentDocumentId');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentDistribution WHERE ContentVersion.ContentDocumentId = :fileId]
        );
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :fileId
        ])
            System.assertEquals(UserInfo.getUserId(), link.LinkedEntityId);
    }
    @IsTest
    static void liveQuoteUsesSalesforceDiscountTaxAndShippingTotals() {
        if (!Schema.getGlobalDescribe().containsKey('Quote'))
            return;
        SObject quote = Database.query(
            'SELECT Id, Subtotal, TotalPrice, GrandTotal FROM Quote WHERE Name = \'Launch quote\' LIMIT 1'
        );
        System.assertEquals(1500, quote.get('Subtotal'));
        System.assertEquals(1312.5, quote.get('TotalPrice'));
        System.assertEquals(1437.5, quote.get('GrandTotal'));
        Id id = starter('quote', quote.Id);
        Test.startTest();
        DocGenGettingStartedController.renderStarter('quote', id, quote.Id);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        for (
            String value : new List<String>{
                'Journey customer',
                'Implementation workshop',
                '1,500',
                '1,312.50',
                '1,437.50',
                '100.00',
                '25.00',
                '12.50'
            }
        )
            System.assert(html.contains(value), value + ': ' + html);
        System.assert(!html.contains('No products have been added'));
    }
    @IsTest
    static void emptyQuoteExplainsMissingProducts() {
        if (!Schema.getGlobalDescribe().containsKey('Quote'))
            return;
        SObject existing = Database.query('SELECT OpportunityId, Pricebook2Id FROM Quote LIMIT 1');
        SObject quote = existing.clone(false, true, false, false);
        quote.put('Name', 'Empty quote');
        insert quote;
        Id id = starter('quote', quote.Id);
        Test.startTest();
        DocGenGettingStartedController.renderStarter('quote', id, quote.Id);
        Test.stopTest();
        System.assert(DocGenService.lastRenderedHtml.contains('No products have been added to this quote'));
    }
    @IsTest
    static void quoteDraftPreviewDoesNotPublish() {
        if (!Schema.getGlobalDescribe().containsKey('Quote'))
            return;
        Id id = starter('quote', null);
        Integer versions = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id];
        Test.startTest();
        DocGenGettingStartedController.previewStarterDraft(
            'quote',
            id,
            '<html><body>Edited quote {QuoteNumber}: {GrandTotal:currency}</body></html>',
            null,
            null
        );
        Test.stopTest();
        System.assert(DocGenService.lastRenderedHtml.contains('Edited quote Q-001024:'));
        System.assert(DocGenService.lastRenderedHtml.contains('23,850'));
        System.assertEquals(versions, [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id]);
        System.assertEquals(null, DocGenService.draftHtmlBodyOverride);
    }
    @IsTest
    static void sampleOpportunityCreatesNoCrmDataAndPrivatePdf() {
        Integer accounts = [SELECT COUNT() FROM Account];
        Integer opportunities = [SELECT COUNT() FROM Opportunity];
        Integer cases = [SELECT COUNT() FROM Case];
        Id templateId = starter('opportunity', null);
        Test.startTest();
        Map<String, Object> result = DocGenGettingStartedController.renderStarter('opportunity', templateId, null);
        Test.stopTest();
        System.assertEquals(true, result.get('sampleData'));
        String html = DocGenService.lastRenderedHtml;
        System.assert(html.contains('Northstar'));
        System.assert(html.contains('Implementation services'));
        System.assert(html.contains('24,500'), html);
        System.assert(!html.contains('{#OpportunityLineItems}'));
        System.assertEquals(accounts, [SELECT COUNT() FROM Account]);
        System.assertEquals(opportunities, [SELECT COUNT() FROM Opportunity]);
        System.assertEquals(cases, [SELECT COUNT() FROM Case]);
        Id fileId = (Id) result.get('contentDocumentId');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentDistribution WHERE ContentVersion.ContentDocumentId = :fileId]
        );
        for (ContentDocumentLink link : [
            SELECT LinkedEntityId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :fileId
        ]) {
            System.assertEquals(
                UserInfo.getUserId(),
                link.LinkedEntityId,
                'Generated example belongs only to the creator.'
            );
        }
    }
    @IsTest
    static void sampleAccountIncludesBothOpenCollections() {
        Id templateId = starter('account', null);
        Test.startTest();
        DocGenGettingStartedController.renderStarter('account', templateId, null);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        System.assert(html.contains('72,500'), html);
        System.assert(html.contains('00001024'));
        System.assert(html.contains('Operations Expansion'));
        System.assert(html.contains('Jordan Ellis'));
    }
    @IsTest
    static void repeatedCreateKeepsCustomizations() {
        Id id = starter('account', null);
        update new DocGen_Template__c(Id = id, Name = 'My edited briefing');
        DocGenController.saveAndPublishHtmlBody(
            id,
            'custom.html',
            '<html><body>My edited content {Name}</body></html>',
            true
        );
        Integer versions = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id];
        Map<String, Object> again = DocGenGettingStartedController.createStarter('account', null);
        System.assertEquals(id, again.get('templateId'));
        System.assertEquals('My edited briefing', again.get('title'));
        System.assertEquals(true, again.get('reused'));
        System.assertEquals(versions, [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id]);
    }
    @IsTest
    static void invalidKeyDoesNotCreateAnything() {
        try {
            starter('anything', null);
            System.assert(false, 'Reject an unknown example.');
        } catch (AuraHandledException expected) {
            System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
        }
    }
    @IsTest
    static void recordTypeMustMatchExample() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        try {
            starter('opportunity', a.Id);
            System.assert(false, 'Reject Account for Opportunity.');
        } catch (AuraHandledException expected) {
            System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
        }
    }
    @IsTest
    static void renderCannotUseUnrelatedTemplate() {
        Id id = starter('account', null);
        try {
            DocGenGettingStartedController.renderStarter('opportunity', id, null);
            System.assert(false, 'Reject another example template.');
        } catch (AuraHandledException expected) {
            System.assertEquals(0, [SELECT COUNT() FROM ContentVersion WHERE FileExtension = 'pdf']);
        }
    }
    @IsTest
    static void liveOpportunityMergesProductsAndTotals() {
        Opportunity deal = [SELECT Id FROM Opportunity WHERE Name = 'Open launch' LIMIT 1];
        Id templateId = starter('opportunity', deal.Id);
        Test.startTest();
        Map<String, Object> result = DocGenGettingStartedController.renderStarter('opportunity', templateId, deal.Id);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        System.assertEquals(false, result.get('sampleData'));
        System.assert(html.contains('Implementation workshop'), html);
        System.assert(html.contains('1,500'), html);
        System.assert(!html.contains('No products have been added'));
    }
    @IsTest
    static void liveAccountFiltersClosedActivity() {
        Account a = [SELECT Id FROM Account LIMIT 1];
        Id templateId = starter('account', a.Id);
        Test.startTest();
        DocGenGettingStartedController.renderStarter('account', templateId, a.Id);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        System.assert(html.contains('Open launch'), html);
        System.assert(html.contains('Open rollout question'), html);
        System.assert(!html.contains('Closed expansion'), html);
        System.assert(!html.contains('Closed old question'), html);
        System.assert(html.contains('journey@example.com'), html);
        System.assert(html.contains('1,500'), html);
    }
    @IsTest
    static void emptyAccountExplainsMissingRelatedData() {
        Account a = new Account(Name = 'New customer');
        insert a;
        Id templateId = starter('account', a.Id);
        Test.startTest();
        DocGenGettingStartedController.renderStarter('account', templateId, a.Id);
        Test.stopTest();
        String html = DocGenService.lastRenderedHtml;
        System.assert(html.contains('No open opportunities'), html);
        System.assert(html.contains('No open support cases'), html);
        System.assert(html.contains('No contacts'), html);
    }
    @IsTest
    static void editedDraftUsesSampleDataWithoutPublishing() {
        Id id = starter('account', null);
        Integer versions = [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id];
        Test.startTest();
        DocGenGettingStartedController.previewStarterDraft(
            'account',
            id,
            '<html><body><h1>Edited draft: {Name}</h1><p>{COUNT:Cases} cases</p></body></html>',
            null,
            null
        );
        Test.stopTest();
        System.assert(DocGenService.lastRenderedHtml.contains('Edited draft: Northstar'));
        System.assertEquals(versions, [SELECT COUNT() FROM DocGen_Template_Version__c WHERE Template__c = :id]);
        System.assertEquals(null, DocGenService.draftHtmlBodyOverride);
    }
}

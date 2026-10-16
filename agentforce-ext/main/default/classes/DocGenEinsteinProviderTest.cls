/**
 * Kept separate from DocGenAiTemplateControllerTest on purpose: this suite names
 * DocGenEinsteinProvider, which mentions ConnectApi.EinsteinLLM and therefore
 * only COMPILES in an org with the Einstein entitlement. Everything else in the
 * feature has to build and test in an org without it, so the dependency is
 * quarantined here and in the provider class itself.
 *
 * Deploy this pair only where Einstein is enabled.
 */
@isTest
private class DocGenEinsteinProviderTest {
    @isTest
    static void neverClaimsAvailabilityInsideATest() {
        // A real generation costs ~13s and real credits, so the provider must
        // not let a test transaction wander into the platform call.
        DocGenEinsteinProvider p = new DocGenEinsteinProvider();
        System.assertEquals('Einstein', p.getName());
        System.assertEquals(false, p.isAvailable());
    }

    @isTest
    static void emptyPromptIsRejectedBeforeThePlatformCall() {
        DocGenEinsteinProvider p = new DocGenEinsteinProvider();
        Test.startTest();
        Boolean threw = false;
        try {
            p.generateHtml('   ');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'an empty prompt must not reach the platform');
    }

    @isTest
    static void aRealPromptExercisesTheCalloutPathAndFailsUsefully() {
        // The bulk of generateHtml is the ConnectApi call and its error
        // handling, which cannot succeed inside a test — ConnectApi has no test
        // context here. That is exactly what makes this worth asserting: the
        // failure must arrive as a DocGenAiException naming the template and the
        // permission set, not as a raw ConnectApiException the author cannot act
        // on. It also covers the catch block, which is most of the method.
        DocGenEinsteinProvider p = new DocGenEinsteinProvider();
        Test.startTest();
        Boolean threw = false;
        try {
            p.generateHtml('Write me a one page invoice for the Account object.');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            threw = true;
            String m = e.getMessage();
            System.assert(
                m.contains(DocGenEinsteinProvider.TEMPLATE_FALLBACK) || m.containsIgnoreCase('prompt template'),
                'the message must name the template to look at: ' + m
            );
            System.assert(
                m.containsIgnoreCase('permission set') || m.containsIgnoreCase('Activated'),
                'and say what to check: ' + m
            );
        } catch (Exception e) {
            System.assert(false, 'must surface as DocGenAiException, got ' + e.getTypeName() + ': ' + e.getMessage());
        }
        Test.stopTest();
        System.assert(threw, 'a failed generation must not return silently');
    }

    @isTest
    static void theConfiguredTemplateNameIsResolved() {
        // An admin can rename the prompt template without editing Apex. Asserted
        // through the failure message rather than by calling the factory: that
        // class is `public`, and `public` is NOT visible across a 2GP package
        // boundary even inside the same namespace. Calling it fails the PACKAGE
        // BUILD with "Type is not visible: portwoodglobal.DocGenAiProviderFactory"
        // — measured 2026-07-26, and the provider's own header warns about it.
        // Reading the custom setting directly is the supported route, and it is
        // what resolveTemplateName() does.
        DocGen_Settings__c s = DocGen_Settings__c.getOrgDefaults();
        s.AI_Prompt_Template__c = 'My_Own_Template';
        upsert s;

        DocGenEinsteinProvider p = new DocGenEinsteinProvider();
        Test.startTest();
        try {
            p.generateHtml('anything');
            System.assert(false, 'ConnectApi cannot succeed in a test, so this must throw');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            System.assert(
                e.getMessage().contains('My_Own_Template'),
                'the configured template name must be the one used: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @isTest
    static void aBlankSettingFallsBackToTheDefaultTemplate() {
        DocGenEinsteinProvider p = new DocGenEinsteinProvider();
        Test.startTest();
        try {
            p.generateHtml('anything');
            System.assert(false, 'must throw');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            System.assert(
                e.getMessage().contains(DocGenEinsteinProvider.TEMPLATE_FALLBACK),
                'blank setting falls back to ' + DocGenEinsteinProvider.TEMPLATE_FALLBACK + ': ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @isTest
    static void fileCapabilitiesPreserveTheExistingProviderContract() {
        Callable provider = new DocGenEinsteinProvider();
        Map<String, Object> capabilities = (Map<String, Object>) provider.call(
            'capabilities',
            new Map<String, Object>()
        );
        System.assertEquals(true, capabilities.get('fileReferences'));
        try {
            provider.call('unknownAction', new Map<String, Object>());
            System.assert(false, 'Unknown actions must fail before generation.');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            System.assert(e.getMessage().contains('Unsupported'));
        }
    }

    @isTest
    static void nonPdfFilesAreRejectedBeforeGeneration() {
        ContentVersion file = new ContentVersion(
            Title = 'Example',
            PathOnClient = 'example.docx',
            VersionData = Blob.valueOf('not a PDF')
        );
        insert file;
        Id documentId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :file.Id].ContentDocumentId;
        Callable provider = new DocGenEinsteinProvider();
        try {
            provider.call(
                'generateWithReference',
                new Map<String, Object>{ 'prompt' => 'Recreate this example', 'documentId' => documentId }
            );
            System.assert(false, 'Raw Word files must use preparation, never native PDF grounding.');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            System.assert(e.getMessage().contains('accessible PDF'));
        }
        try {
            provider.call(
                'generateWithReference',
                new Map<String, Object>{ 'prompt' => '', 'documentId' => documentId }
            );
            System.assert(false, 'Blank prompts must fail before generation.');
        } catch (DocGenEinsteinProvider.DocGenAiException e) {
            System.assert(e.getMessage().contains('describe'));
        }
    }

    @IsTest
    static void planningIsAdvertisedAndRejectsEmptyRequestsBeforeTheModel() {
        Callable provider = new DocGenEinsteinProvider();
        Map<String, Object> capabilities = (Map<String, Object>) provider.call(
            'capabilities',
            new Map<String, Object>()
        );
        System.assertEquals(true, capabilities.get('queryPlanning'));
        try {
            provider.call('planQuery', new Map<String, Object>{ 'prompt' => '   ' });
            System.assert(false);
        } catch (DocGenEinsteinProvider.DocGenAiException expected) {
            System.assert(expected.getMessage().contains('empty'));
        }
    }

    @isTest
    static void factoryResolvesTheProviderByName() {
        // Type.forName is what keeps the rest of the feature deployable in an
        // org without Einstein — prove the name still resolves where it exists.
        System.assertNotEquals(null, Type.forName('DocGenEinsteinProvider'), 'the provider must be resolvable by name');
    }
}

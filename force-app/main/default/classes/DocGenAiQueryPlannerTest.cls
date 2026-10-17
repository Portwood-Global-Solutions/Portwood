@IsTest
private class DocGenAiQueryPlannerTest {
    private static Map<String, Object> accountPlan() {
        return (Map<String, Object>) JSON.deserializeUntyped(
            '{"root":"Account","nodes":[{"id":"root","object":"Account","fields":["Name"],"parentFields":["Owner.Name"],"parentNode":null},{"id":"cases","object":"Case","parentNode":"root","relationshipName":"Cases","fields":["CaseNumber","Subject","Priority","IsClosed"],"filter":{"and":[{"field":"IsClosed","operator":"=","value":false},{"field":"CreatedDate","operator":"=","relativeDate":"LAST_N_DAYS:30"}]},"sort":[{"field":"CreatedDate","direction":"DESC"}]}]}'
        );
    }
    @IsTest
    static void compilesOnlyRequestedFieldsWithTypedFiltersAndRealRelationships() {
        Map<String, Object> result = DocGenAiQueryPlanner.compilePlan(accountPlan());
        System.assertEquals('Account', result.get('objectName'));
        Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped((String) result.get('queryConfig'));
        List<Object> nodes = (List<Object>) config.get('nodes');
        System.assertEquals(2, nodes.size());
        Map<String, Object> root = (Map<String, Object>) nodes[0], child = (Map<String, Object>) nodes[1];
        System.assertEquals(1, ((List<Object>) root.get('fields')).size(), 'No preferred-field padding.');
        System.assertEquals('AccountId', child.get('lookupField'), 'The relationship supplies the real lookup.');
        System.assert(((String) child.get('where')).contains('IsClosed = false'));
        System.assert(((String) child.get('where')).contains('CreatedDate = LAST_N_DAYS:30'));
        System.assertEquals('CreatedDate DESC', child.get('orderBy'));
        System.assertEquals(null, child.get('limit'), 'Never invent a row limit.');
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
    }
    @IsTest
    static void typedStringCannotEscapeAFilterLiteral() {
        Map<String, Object> plan = accountPlan();
        Map<String, Object> child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put(
            'filter',
            new Map<String, Object>{
                'field' => 'Subject',
                'operator' => '=',
                'value' => 'A\\\' OR IsClosed = true OR Subject = \'B'
            }
        );
        Map<String, Object> compiled = DocGenAiQueryPlanner.compilePlan(plan);
        System.assert(((String) compiled.get('queryConfig')).contains('where'));
        insert new Case(Subject = 'A normal open case');
        Map<String, Object> decoded = (Map<String, Object>) JSON.deserializeUntyped(
            (String) compiled.get('queryConfig')
        );
        String predicate = (String) ((Map<String, Object>) ((List<Object>) decoded.get('nodes'))[1]).get('where');
        List<SObject> matches = Database.query('SELECT Id FROM Case WHERE ' + predicate, AccessLevel.USER_MODE);
        System.assertEquals(
            0,
            matches.size(),
            'The injected text must remain a literal, even when an open Case exists.'
        );
    }
    private static void rejected(Map<String, Object> plan, String expected) {
        try {
            DocGenAiQueryPlanner.compilePlan(plan);
            System.assert(false, 'Reject the invalid plan.');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains(expected), e.getMessage());
        }
    }
    @IsTest
    static void refusesInventedFieldsDisconnectedObjectsAndRawClauses() {
        Map<String, Object> plan = accountPlan();
        Map<String, Object> root = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[0];
        root.put('fields', new List<Object>{ 'Imaginary_Amount__c' });
        rejected(plan, 'Unknown or unreadable field');
        plan = accountPlan();
        Map<String, Object> child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put('relationshipName', 'MadeUpCases');
        rejected(plan, 'relationship connects');
        plan = accountPlan();
        child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put('parentNode', 'unrelated');
        rejected(plan, 'earlier query node');
        plan = accountPlan();
        child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put('where', 'IsClosed=false OR Id!=null');
        rejected(plan, 'structured filters');
    }
    @IsTest
    static void refusesFilterAndSortInjectionAndRootScopeChanges() {
        Map<String, Object> plan = accountPlan();
        Map<String, Object> child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put(
            'filter',
            new Map<String, Object>{ 'field' => 'IsClosed', 'operator' => '= false OR Id !=', 'value' => false }
        );
        rejected(plan, 'Unsupported filter');
        plan = accountPlan();
        child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put(
            'filter',
            new Map<String, Object>{ 'field' => 'IsClosed', 'operator' => '=', 'value' => 'false OR Id!=null' }
        );
        rejected(plan, 'true/false');
        plan = accountPlan();
        child = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[1];
        child.put(
            'sort',
            new List<Object>{ new Map<String, Object>{ 'field' => 'CreatedDate', 'direction' => 'DESC LIMIT 50000' } }
        );
        rejected(plan, 'ASC/DESC');
        plan = accountPlan();
        Map<String, Object> root = (Map<String, Object>) ((List<Object>) plan.get('nodes'))[0];
        root.put('filter', new Map<String, Object>{ 'field' => 'Name', 'operator' => '!=', 'value' => null });
        rejected(plan, 'chosen record');
    }
    @IsTest
    static void metadataDiscoveryPagesAndSearchesRatherThanGuessingSelectedFields() {
        Map<String, Object> evidence = DocGenAiQueryPlanner.discover(
            new Map<String, Object>{
                'describe' => new List<Object>{
                    new Map<String, Object>{ 'object' => 'Account', 'search' => 'Name', 'offset' => 0 }
                }
            }
        );
        Map<String, Object> schema = (Map<String, Object>) ((List<Object>) evidence.get('schemas'))[0];
        Boolean found = false;
        for (Object item : (List<Object>) schema.get('fields'))
            if (((Map<String, Object>) item).get('field') == 'Name')
                found = true;
        System.assert(found);
        System.assertNotEquals(null, schema.get('children'));
        System.assertNotEquals(null, schema.get('parents'));
        System.assert(DocGenAiQueryPlanner.instructions().contains('not a data model'));
    }
    private class PlannerProvider implements DocGenAiProvider, Callable {
        public Boolean isAvailable() {
            return true;
        }
        public String getName() {
            return 'Planner test';
        }
        public String generateHtml(String prompt) {
            System.assert(false, 'Planning never calls the HTML carrier.');
            return null;
        }
        public Object call(String action, Map<String, Object> args) {
            if (action == 'capabilities')
                return new Map<String, Object>{ 'queryPlanning' => true, 'fileReferences' => true };
            System.assertEquals('planQuery', action);
            String prompt = (String) args.get('prompt');
            if (prompt.contains('LOOKUP_SCHEMA'))
                return '{"action":"schema","describe":[{"object":"Account","search":"Name","offset":0}]}';
            if (prompt.contains('NEED_CLARIFICATION'))
                return '{"action":"ask","message":"Should the briefing include open cases only, or closed cases too?"}';
            if (prompt.contains('INVALID_PLAN'))
                return '{"action":"ready","message":"Ready","plan":{"root":"Account","nodes":[{"id":"root","object":"Account","fields":["No_Such_Field__c"]}]}}';
            return JSON.serialize(
                new Map<String, Object>{
                    'action' => 'ready',
                    'message' => 'Include the account and its open cases from the last 30 days.',
                    'plan' => accountPlan()
                }
            );
        }
    }
    private static String history(String content) {
        return JSON.serialize(new List<Object>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } });
    }
    @IsTest
    static void conversationDiscoversSchemaAndAsksFocusedQuestionsWithoutSaving() {
        DocGenAiProviderFactory.setProvider(new PlannerProvider());
        System.assertEquals(true, DocGenAiTemplateController.getAiCapabilities().get('queryPlanning'));
        Map<String, Object> schema = DocGenAiQueryPlanner.converse(history('LOOKUP_SCHEMA'), null, null);
        System.assertEquals('schema', schema.get('kind'));
        System.assert(((String) schema.get('historyJson')).contains('Account'));
        Map<String, Object> ask = DocGenAiQueryPlanner.converse(history('NEED_CLARIFICATION'), null, null);
        System.assertEquals('ask', ask.get('kind'));
        System.assert(((String) ask.get('message')).contains('open cases'));
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
    }
    @IsTest
    static void conversationReturnsValidatedPlanAndRepairsInvalidPlans() {
        DocGenAiProviderFactory.setProvider(new PlannerProvider());
        Map<String, Object> result = DocGenAiQueryPlanner.converse(
            history('An account briefing with open cases from the last 30 days.'),
            null,
            null
        );
        System.assertEquals('ready', result.get('kind'));
        System.assertNotEquals(null, result.get('queryConfig'));
        Map<String, Object> repair = DocGenAiQueryPlanner.converse(history('INVALID_PLAN'), null, null);
        System.assertEquals('schema', repair.get('kind'));
        System.assert(((String) repair.get('historyJson')).contains('PLAN VALIDATION FAILED'));
    }
    @IsTest
    static void conversationRejectsMalformedHistoryAndRawWordFile() {
        try {
            DocGenAiQueryPlanner.converse('[]', null, null);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Describe'));
        }
        ContentVersion word = new ContentVersion(
            Title = 'Example',
            PathOnClient = 'example.docx',
            VersionData = Blob.valueOf('word')
        );
        insert word;
        Id document = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :word.Id].ContentDocumentId;
        try {
            DocGenAiQueryPlanner.converse(history('Use this example'), document, null);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Prepare'));
        }
    }
}

/** First-document journey. Starters are opt-in, private to their creator, and never create CRM sample records. */
public with sharing class DocGenGettingStartedController {
    @TestVisible
    private static Boolean quotesDisabledForTest = false;

    // Quote is optional Salesforce functionality. Avoid static references so this package also installs without it.
    private static Boolean quotesAvailable() {
        if (quotesDisabledForTest)
            return false;
        Map<String, Schema.SObjectType> objects = Schema.getGlobalDescribe();
        for (String name : new List<String>{ 'Quote', 'QuoteLineItem' }) {
            Schema.SObjectType objectType = objects.get(name);
            if (objectType == null)
                return false;
            Schema.DescribeSObjectResult described = objectType.getDescribe();
            if (!described.isQueryable() || !described.isAccessible())
                return false;
        }
        return true;
    }
    private static final Set<String> TEMPLATE_FIELDS = new Set<String>{
        'Name',
        'API_Name__c',
        'Category__c',
        'Type__c',
        'Base_Object_API__c',
        'Description__c',
        'Query_Config__c',
        'Output_Format__c',
        'Is_Active__c',
        'Test_Record_Id__c',
        'Document_Title_Format__c'
    };
    private static Map<String, Object> definition(String exampleKey) {
        if (exampleKey != 'quote' && exampleKey != 'opportunity' && exampleKey != 'account') {
            throw new DocGenException('Choose an available example to continue.');
        }
        if (exampleKey == 'quote' && !quotesAvailable())
            throw new DocGenException(
                'Quotes are unavailable for your org or user. Go back to examples and choose the opportunity proposal or account summary.'
            );
        DocGenFlsGuard.assertAccessible(StaticResource.sObjectType, new Set<String>{ 'Body', 'Name' });
        /* code-analyzer-suppress ApexFlsViolation */
        StaticResource resource = [
            SELECT Body
            FROM StaticResource
            WHERE Name = 'DocGenStarterExamples'
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation -- read-only packaged configuration; explicit CRUD/FLS guard above
        return (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(resource.Body.toString()))
            .get(exampleKey);
    }
    private static String starterKey(String exampleKey) {
        return 'pw_start_' + exampleKey + '_' + UserInfo.getUserId();
    }
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getReadiness() {
        Boolean createAllowed =
            DocGen_Template__c.sObjectType.getDescribe().isCreateable() &&
            DocGen_Template_Version__c.sObjectType.getDescribe().isCreateable() &&
            ContentVersion.sObjectType.getDescribe().isCreateable();
        return new Map<String, Object>{
            'canCreate' => createAllowed,
            'quoteAvailable' => quotesAvailable(),
            'canCreateAssets' => DocGen_Asset__c.sObjectType.getDescribe().isCreateable(),
            'canEditAssets' => DocGen_Asset__c.sObjectType.getDescribe().isUpdateable(),
            'canDeleteAssets' => DocGen_Asset__c.sObjectType.getDescribe().isDeletable()
        };
    }
    /** Reuses only this user's starter. Never replaces a customized body or changes an existing template's settings. */
    @AuraEnabled
    public static Map<String, Object> createStarter(String exampleKey, Id recordId) {
        Savepoint checkpoint = Database.setSavepoint();
        try {
            Map<String, Object> def = definition(exampleKey);
            validateRecord(def, recordId);
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, TEMPLATE_FIELDS);
            String apiKey = starterKey(exampleKey);
            Id owner = UserInfo.getUserId();
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> existing = [
                SELECT Id, Name
                FROM DocGen_Template__c
                WHERE API_Name__c = :apiKey AND CreatedById = :owner
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!existing.isEmpty()) {
                return new Map<String, Object>{
                    'templateId' => existing[0].Id,
                    'title' => existing[0].Name,
                    'reused' => true
                };
            }
            DocGen_Template__c template = new DocGen_Template__c(
                Name = (String) def.get('title'),
                API_Name__c = apiKey,
                Category__c = 'Getting started',
                Type__c = 'HTML',
                Base_Object_API__c = (String) def.get('objectApiName'),
                Description__c = (String) def.get('description'),
                Query_Config__c = (String) def.get('query'),
                Output_Format__c = 'PDF',
                Is_Active__c = true,
                Test_Record_Id__c = recordId,
                Document_Title_Format__c = (String) def.get('title') + ' - {Name}'
            );
            DocGenFlsGuard.assertCreateable(template, TEMPLATE_FIELDS);
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(template, AccessLevel.SYSTEM_MODE);
            DocGenController.saveAndPublishHtmlBody(
                template.Id,
                exampleKey + '-starter.html',
                (String) def.get('html'),
                true
            );
            return new Map<String, Object>{ 'templateId' => template.Id, 'title' => template.Name, 'reused' => false };
        } catch (Exception e) {
            Database.rollback(checkpoint);
            throw DocGenService.ahe(
                e,
                'The starter could not be created. Ask your Salesforce admin to assign Portwood Admin, then try again.'
            );
        }
    }
    /** Separate transaction from createStarter so PDF rendering runs before any File DML. */
    @AuraEnabled
    public static Map<String, Object> renderStarter(String exampleKey, Id templateId, Id recordId) {
        try {
            Map<String, Object> def = definition(exampleKey);
            validateRecord(def, recordId);
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, TEMPLATE_FIELDS);
            String apiKey = starterKey(exampleKey);
            Id owner = UserInfo.getUserId();
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> templates = [
                SELECT Id
                FROM DocGen_Template__c
                WHERE Id = :templateId AND API_Name__c = :apiKey AND CreatedById = :owner
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (templates.isEmpty())
                throw new DocGenException('This starter is unavailable. Go back to examples and create it again.');
            Map<String, Object> rendered = recordId == null
                ? DocGenService.generatePdfBlobFromData(templateId, (Map<String, Object>) def.get('sample'))
                : DocGenService.generatePdfBlob(templateId, recordId);
            String title = (recordId == null ? 'Sample - ' : '') + (String) rendered.get('title');
            ContentVersion file = new ContentVersion(
                Title = title,
                PathOnClient = exampleKey + '.pdf',
                VersionData = (Blob) rendered.get('blob'),
                FirstPublishLocationId = UserInfo.getUserId()
            );
            DocGenFlsGuard.assertCreateable(
                file,
                new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(file, AccessLevel.SYSTEM_MODE);
            file = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :file.Id WITH SYSTEM_MODE LIMIT 1];
            return new Map<String, Object>{
                'contentVersionId' => file.Id,
                'contentDocumentId' => file.ContentDocumentId,
                'title' => title,
                'sampleData' => recordId == null
            };
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'The PDF could not be rendered. Check record access and try again.');
        }
    }
    /** Preview an unsaved starter edit with the same fictional data used by onboarding. */
    @AuraEnabled
    public static Map<String, Object> previewStarterDraft(
        String exampleKey,
        Id templateId,
        String draftHtml,
        String draftHeaderHtml,
        String draftFooterHtml
    ) {
        if (String.isBlank(draftHtml))
            throw DocGenService.ahe('Nothing to preview. Add content to your template first.');
        try {
            DocGenService.draftHtmlBodyOverride = draftHtml;
            DocGenService.draftHeaderHtmlOverride = draftHeaderHtml;
            DocGenService.draftFooterHtmlOverride = draftFooterHtml;
            return renderStarter(exampleKey, templateId, null);
        } finally {
            DocGenService.draftHtmlBodyOverride = null;
            DocGenService.draftHeaderHtmlOverride = null;
            DocGenService.draftFooterHtmlOverride = null;
        }
    }
    private static void validateRecord(Map<String, Object> def, Id recordId) {
        if (recordId == null)
            return;
        String objectName = (String) def.get('objectApiName');
        if (recordId.getSObjectType().getDescribe().getName() != objectName) {
            throw new DocGenException('Choose a record from ' + objectName + ' for this example.');
        }
        // A real-record render must obey the caller's sharing, object and field permissions.
        List<SObject> visible = Database.query(
            'SELECT Id FROM ' + objectName + ' WHERE Id = :recordId WITH USER_MODE LIMIT 1'
        );
        if (visible.isEmpty())
            throw new DocGenException('You cannot access this record. Choose another record.');
    }
}

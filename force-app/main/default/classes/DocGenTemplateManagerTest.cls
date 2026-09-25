/**
 * Unit tests for DocGenTemplateManager.getTemplateFileSize (#403) — the cheap
 * ContentVersion.ContentSize lookup DocGenFlowHeapRouter uses to decide sync
 * vs async without paying for a full VersionData load. getTemplateFileContent
 * (the existing method) already gets incidental coverage from every other
 * generation test in the suite; this file is scoped to the new method only.
 */
@isTest
private class DocGenTemplateManagerTest {
    @isTest
    static void nullTemplateIdReturnsZero() {
        System.assertEquals(0, DocGenTemplateManager.getTemplateFileSize(null));
    }

    @isTest
    static void templateWithNoFileAtAllReturnsZero() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Size Test — No File',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Query_Config__c = 'Name'
        );
        insert t;

        Test.startTest();
        Integer size = DocGenTemplateManager.getTemplateFileSize(t.Id);
        Test.stopTest();

        System.assertEquals(0, size);
    }

    @isTest
    static void activeVersionWithContentVersionReturnsItsRealSize() {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Size Test — Active Version',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Query_Config__c = 'Name'
        );
        insert t;

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = t.Id,
            Is_Active__c = true,
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        insert ver;

        String payload = 'x'.repeat(50000);
        ContentVersion cv = new ContentVersion(
            Title = 'Size Test File',
            PathOnClient = 'sizetest.docx',
            VersionData = Blob.valueOf(payload),
            FirstPublishLocationId = t.Id
        );
        insert cv;
        cv = [SELECT Id, ContentSize FROM ContentVersion WHERE Id = :cv.Id];
        ver.Content_Version_Id__c = cv.Id;
        update ver;

        Test.startTest();
        Integer size = DocGenTemplateManager.getTemplateFileSize(t.Id);
        Test.stopTest();

        System.assertEquals(
            cv.ContentSize,
            size,
            'Must report the ContentVersion\'s real ContentSize, not an estimate.'
        );
        System.assert(size > 0);
    }

    @isTest
    static void fallsBackToLatestAttachedFileWhenNoActiveVersionCvId() {
        // Mirrors getTemplateFileContent's own fallback: an active version with a
        // null Content_Version_Id__c (legacy/broken data) falls back to the most
        // recently attached ContentDocumentLink on the template record itself.
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Size Test — Fallback',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Output_Format__c = 'Native',
            Query_Config__c = 'Name'
        );
        insert t;

        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = t.Id,
            Is_Active__c = true,
            Query_Config__c = 'Name',
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
            // Content_Version_Id__c intentionally left null
        );
        insert ver;

        String payload = 'y'.repeat(30000);
        ContentVersion cv = new ContentVersion(
            Title = 'Fallback File',
            PathOnClient = 'fallback.docx',
            VersionData = Blob.valueOf(payload),
            FirstPublishLocationId = t.Id
        );
        insert cv;
        cv = [SELECT Id, ContentSize FROM ContentVersion WHERE Id = :cv.Id];

        Test.startTest();
        Integer size = DocGenTemplateManager.getTemplateFileSize(t.Id);
        Test.stopTest();

        System.assertEquals(cv.ContentSize, size);
    }
}

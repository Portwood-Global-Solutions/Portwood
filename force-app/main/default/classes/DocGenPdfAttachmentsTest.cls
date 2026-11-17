@IsTest
private class DocGenPdfAttachmentsTest {
    private static DocGen_Template__c template() {
        DocGen_Template__c record = new DocGen_Template__c(
            Name = 'PDF Attachment Test',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert record;
        return record;
    }

    private static ContentVersion source(String name, Blob bytes) {
        ContentVersion file = new ContentVersion(Title = name, PathOnClient = name + '.pdf', VersionData = bytes);
        insert file;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :file.Id];
    }

    private static Map<String, Object> entry(Id versionId, String placement) {
        return new Map<String, Object>{ 'versionId' => versionId, 'placement' => placement };
    }

    @IsTest
    static void readsSavedConfigurationAndUsesPinnedVersions() {
        Id templateId = template().Id;
        ContentVersion cover = source('Cover', DocGenPdfMergeFixtures.classic());
        ContentVersion finalSheet = source('Back Sheet', DocGenPdfMergeFixtures.generation());
        String saved = DocGenController.saveTemplatePdfAttachments(
            templateId,
            JSON.serialize(new List<Map<String, Object>>{ entry(finalSheet.Id, 'after'), entry(cover.Id, 'before') })
        );
        System.assert(saved.contains('Back Sheet'));
        System.assertEquals(saved, DocGenController.getTemplatePdfAttachments(templateId));
        insert new ContentVersion(
            Title = 'New Cover Version',
            PathOnClient = 'Cover.pdf',
            ContentDocumentId = cover.ContentDocumentId,
            VersionData = DocGenPdfMergeFixtures.generation()
        );

        Test.startTest();
        Blob combined = DocGenPdfAttachments.includeInPdf(templateId, DocGenPdfMergeFixtures.generation());
        Test.stopTest();

        DocGenPdfDocument doc = new DocGenPdfDocument(combined);
        List<DocGenPdfDocument.Value> pages = doc.pageList;
        System.assertEquals(4, pages.size(), 'Original two-page cover, primary page, and back page');
        System.assertEquals(true, doc.resolve(pages[0]).entries.containsKey('Annots'));
        System.assertEquals(true, doc.resolve(pages[1]).entries.containsKey('Annots'));
        System.assertEquals(false, doc.resolve(pages[2]).entries.containsKey('Annots'));
        System.assertEquals(false, doc.resolve(pages[3]).entries.containsKey('Annots'));
    }

    @IsTest
    static void rejectsDeletedAttachmentWithItsNameAndLeavesEmptyTemplateUnchanged() {
        Id templateId = template().Id;
        ContentVersion cover = source('Expired Cover', DocGenPdfMergeFixtures.classic());
        Blob primary = DocGenPdfMergeFixtures.generation();
        System.assertEquals(primary, DocGenPdfAttachments.includeInPdf(templateId, primary));
        DocGenPdfAttachments.save(
            templateId,
            JSON.serialize(new List<Map<String, Object>>{ entry(cover.Id, 'before') })
        );
        delete new ContentDocument(Id = cover.ContentDocumentId);
        try {
            DocGenPdfAttachments.includeInPdf(templateId, primary);
            System.assert(false, 'A required missing file must prevent output');
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('Expired Cover'), e.getMessage());
            System.assert(e.getMessage().contains('missing or inaccessible'), e.getMessage());
        }
    }
}

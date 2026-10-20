@IsTest
private class DocGenAiReferenceTest {
    private static ContentVersion file(String extension, Blob bytes) {
        ContentVersion cv = new ContentVersion(
            Title = 'Example',
            PathOnClient = 'example.' + extension,
            VersionData = bytes,
            FirstPublishLocationId = UserInfo.getUserId()
        );
        insert cv;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
    }
    private static Blob docx() {
        Compression.ZipWriter zip = new Compression.ZipWriter();
        zip.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Reference agreement</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Product</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Amount</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>'
            )
        );
        zip.addEntry(
            'word/header1.xml',
            Blob.valueOf(
                '<w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:r><w:t>Example letterhead</w:t></w:r></w:p></w:hdr>'
            )
        );
        return zip.getArchive();
    }
    @IsTest
    static void pdfIsReadyWithoutReadingBinaryIntoPrompt() {
        ContentVersion cv = file('pdf', Blob.valueOf('%PDF-1.4 example'));
        Test.startTest();
        Map<String, Object> prepared = DocGenAiReferenceController.prepareReference(cv.ContentDocumentId);
        Test.stopTest();
        System.assertEquals('ready', prepared.get('state'));
        System.assertEquals('pdf', prepared.get('format'));
        System.assertEquals(null, prepared.get('html'));
        System.assertEquals(null, prepared.get('jobId'));
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
    }
    @IsTest
    static void docxPreparationRetainsWordingTableAndHeaderPrivately() {
        ContentVersion cv = file('docx', docx());
        Test.startTest();
        Map<String, Object> prepared = DocGenAiReferenceController.prepareReference(cv.ContentDocumentId);
        Test.stopTest();
        Map<String, Object> ready = DocGenAiReferenceController.getReferenceStatus((Id) prepared.get('jobId'));
        System.assertEquals(
            'ready',
            ready.get('state'),
            JSON.serialize(ready) + JSON.serialize([SELECT Title FROM ContentVersion])
        );
        String html = (String) ready.get('html');
        System.assert(html.contains('Reference agreement'), html);
        System.assert(html.contains('Product'), html);
        System.assert(html.contains('<table'), html);
        System.assert(html.contains('Example letterhead'), html);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
    }
    @IsTest
    static void malformedDocxFailsWithUsefulGuidance() {
        ContentVersion cv = file('docx', Blob.valueOf('not a zip'));
        Test.startTest();
        Map<String, Object> prepared = DocGenAiReferenceController.prepareReference(cv.ContentDocumentId);
        Test.stopTest();
        Map<String, Object> ready = DocGenAiReferenceController.getReferenceStatus((Id) prepared.get('jobId'));
        System.assertEquals('error', ready.get('state'));
        System.assert(((String) ready.get('message')).contains('PDF export'));
    }
    @IsTest
    static void unsupportedFormatDoesNotQueueWork() {
        ContentVersion cv = file('txt', Blob.valueOf('a text file'));
        try {
            DocGenAiReferenceController.prepareReference(cv.ContentDocumentId);
            System.assert(false, 'Reject unsupported reference formats.');
        } catch (AuraHandledException expected) {
            System.assertEquals(0, Limits.getQueueableJobs());
        }
    }
    @IsTest
    static void jobStatusIsScopedToPreparation() {
        try {
            DocGenAiReferenceController.getReferenceStatus(UserInfo.getUserId());
            System.assert(false, 'Reject unrelated ids.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('unavailable'));
        }
    }
    @IsTest
    static void preparedImageCanBeLinkedToItsAuthorsTemplateWithoutPublicSharing() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Reference image test',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account'
        );
        insert template;
        ContentVersion image = new ContentVersion(
            Title = 'docgen_ai_ref_img_test',
            PathOnClient = 'example.png',
            VersionData = Blob.valueOf('fixture'),
            FirstPublishLocationId = UserInfo.getUserId()
        );
        insert image;
        Test.startTest();
        DocGenAiReferenceController.attachReferenceImages(template.Id, new List<Id>{ image.Id });
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :template.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
        ContentVersion unrelated = file('png', Blob.valueOf('not a prepared example'));
        try {
            DocGenAiReferenceController.attachReferenceImages(template.Id, new List<Id>{ unrelated.Id });
            System.assert(false, 'Only prepared images may be attached.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('unavailable'));
        }
    }
    private class FileProvider implements DocGenAiProvider, Callable {
        public Boolean isAvailable() {
            return true;
        }
        public String getName() {
            return 'Native test';
        }
        public String generateHtml(String prompt) {
            return '<html><body>{#Lines.records}<table><tr><td>{#Lines}{Name}{/Lines}</td></tr></table>{/Lines.records}</body></html>';
        }
        public Object call(String action, Map<String, Object> args) {
            if (action == 'capabilities')
                return new Map<String, Object>{ 'fileReferences' => true };
            System.assertEquals('generateWithReference', action);
            System.assertNotEquals(null, args.get('documentId'));
            return '<html><body><h1>Editable {Name}</h1><script>evil()</script><p style="{%font:brand:0123456789abcdef};font-size:11pt">Approved face</p></body></html>';
        }
    }
    @IsTest
    static void repeatedArrayWrapperCannotBecomeASilentEmptyDraft() {
        DocGenAiProviderFactory.setProvider(new FileProvider());
        try {
            DocGenAiTemplateController.generateBodyPreview('Create a quote');
            System.assert(false, 'Nested loops over the same list erase line-item data.');
        } catch (AuraHandledException expected) {
            System.assert(expected.getMessage().contains('same related-list loop twice'));
        }
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Template__c]);
    }
    @IsTest
    static void referenceGenerationUsesNativeFileCapabilityAndValidator() {
        ContentVersion cv = file('pdf', Blob.valueOf('%PDF-1.4 example'));
        DocGenAiProviderFactory.setProvider(new FileProvider());
        System.assertEquals(true, DocGenAiTemplateController.getAiCapabilities().get('fileReferences'));
        Test.startTest();
        DocGenAiTemplateController.GenerationResult result = DocGenAiTemplateController.generateReferencePreview(
            'Recreate my reference',
            cv.ContentDocumentId
        );
        Test.stopTest();
        System.assert(result.html.contains('{Name}'));
        System.assert(result.html.contains('{%font:brand:0123456789abcdef}'));
        System.assert(!result.html.contains('<script'));
        System.assertEquals('Native test', result.providerName);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM DocGen_Template__c],
            'Generation is a preview until the author creates it.'
        );
    }
}

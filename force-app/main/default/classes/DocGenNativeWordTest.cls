@IsTest
private class DocGenNativeWordTest {
    private static Blob archive(String text, Boolean externalTemplate, Boolean externalImage) {
        Compression.ZipWriter writer = new Compression.ZipWriter();
        writer.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p w:metadata="{01234567-89AB-CDEF-0123-456789ABCDEF}"><w:r><w:t>' +
                    text +
                    '</w:t></w:r></w:p></w:body></w:document>'
            )
        );
        writer.addEntry('word/media/image.emf', EncodingUtil.convertFromHex('00010203fffe'));
        writer.addEntry('word/styles.xml', Blob.valueOf('<styles/>'));
        if (externalTemplate) {
            writer.addEntry(
                'word/_rels/settings.xml.rels',
                Blob.valueOf(
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/attachedTemplate" Target="file:///C:/Quote.dotx" TargetMode="External"/></Relationships>'
                )
            );
            writer.addEntry(
                'word/settings.xml',
                Blob.valueOf(
                    '<w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:attachedTemplate r:id="rId1"/><w:zoom w:percent="100"/></w:settings>'
                )
            );
        }
        if (externalImage)
            writer.addEntry(
                'word/_rels/document.xml.rels',
                Blob.valueOf(
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="image" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="https://example.com/image.png" TargetMode="External"/></Relationships>'
                )
            );
        return writer.getArchive();
    }

    @IsTest
    static void staticCopyPreservesEveryContentPartAndDetachesEditingTemplate() {
        Blob source = archive('Quote &amp; terms', true, false);
        Test.startTest();
        Blob result = DocGenNativeWordQueueable.copyIfStatic(source);
        Test.stopTest();
        Compression.ZipReader before = new Compression.ZipReader(source);
        Compression.ZipReader after = new Compression.ZipReader(result);
        System.assertEquals(before.getEntries().size(), after.getEntries().size());
        for (String name : new List<String>{ 'word/document.xml', 'word/styles.xml', 'word/media/image.emf' }) {
            System.assertEquals(
                EncodingUtil.base64Encode(before.extract(name)),
                EncodingUtil.base64Encode(after.extract(name))
            );
        }
        System.assert(!after.extract('word/settings.xml').toString().contains('attachedTemplate'));
        System.assert(after.extract('word/settings.xml').toString().contains('w:zoom'));
        System.assert(!after.extract('word/_rels/settings.xml.rels').toString().contains('file:'));
        DocGenAssetPolicy.assertOfficeResources(after);
    }

    @IsTest
    static void realTagsAndFragmentedTagsUseTheMergeEngine() {
        System.assertEquals(null, DocGenNativeWordQueueable.copyIfStatic(archive('{Name}', false, false)));
        System.assertEquals(
            null,
            DocGenNativeWordQueueable.copyIfStatic(archive('{Na</w:t></w:r><w:r><w:t>me}', false, false))
        );
        System.assertEquals(null, DocGenNativeWordQueueable.copyIfStatic(archive('&#123;Name&#125;', false, false)));
    }

    @IsTest
    static void staticCopiesStillRejectExternalImages() {
        try {
            DocGenNativeWordQueueable.copyIfStatic(archive('Quote', false, true));
            System.assert(false, 'The native copy must keep the Salesforce-only asset policy.');
        } catch (DocGenException expected) {
            System.assert(expected.getMessage().contains('Salesforce-hosted'));
        }
    }

    @IsTest
    static void nativeJobProducesAFileAndLinksItToTheRequestedRecord() {
        Account account = new Account(Name = 'Native Word Record');
        insert account;
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Quote',
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert template;
        ContentVersion source = new ContentVersion(
            Title = 'Quote',
            PathOnClient = 'quote.docx',
            VersionData = archive('Quote', true, false)
        );
        insert source;
        insert new DocGen_Template_Version__c(
            Template__c = template.Id,
            Content_Version_Id__c = source.Id,
            Is_Active__c = true
        );
        Test.startTest();
        Id job = DocGenController.prepareNativeWordDocument(template.Id, account.Id, true);
        Test.stopTest();
        List<ContentVersion> savedFiles = [
            SELECT Id, PathOnClient, CreatedById, IsLatest
            FROM ContentVersion
            WHERE Title = 'Native Word Record'
        ];
        System.assertEquals(1, savedFiles.size(), 'Queueable must create one native file.');
        System.assertEquals(
            DocGenNativeWordQueueable.outputPath(job),
            savedFiles[0].PathOnClient,
            'The poll must use the same job marker.'
        );
        System.assertEquals(UserInfo.getUserId(), savedFiles[0].CreatedById);
        System.assertEquals(true, savedFiles[0].IsLatest);
        Map<String, Object> status = DocGenController.getNativeWordDocumentStatus(job);
        System.assertEquals('Completed', status.get('status'));
        System.assertEquals(false, status.get('requiresMerge'));
        Id cvId = (Id) status.get('contentVersionId');
        ContentVersion result = [SELECT ContentDocumentId, VersionData FROM ContentVersion WHERE Id = :cvId];
        System.assert(result.VersionData.size() > 0);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :result.ContentDocumentId AND LinkedEntityId = :account.Id
            ]
        );
    }

    @IsTest
    static void nativeStatusRejectsAnUnrelatedJobId() {
        try {
            DocGenController.getNativeWordDocumentStatus(null);
            System.assert(false, 'A caller must own a native Word generation job.');
        } catch (DocGenException expected) {
            System.assert(expected.getMessage().contains('access denied'));
        }
    }

    @IsTest
    static void nativeSourceUsesTheActiveVersionAndPinnedTitle() {
        Account account = new Account(Name = 'Native Quote');
        insert account;
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Quote',
            Type__c = 'Word',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Document_Title_Format__c = 'Draft'
        );
        insert template;
        ContentVersion file = new ContentVersion(
            Title = 'Quote',
            PathOnClient = 'quote.docx',
            VersionData = Blob.valueOf('The source metadata endpoint must not parse the archive.')
        );
        insert file;
        insert new DocGen_Template_Version__c(
            Template__c = template.Id,
            Content_Version_Id__c = file.Id,
            Is_Active__c = true,
            Document_Title_Format__c = '{Name} quote'
        );
        Test.startTest();
        Map<String, Object> result = DocGenController.getNativeWordTemplateSource(template.Id, account.Id);
        Test.stopTest();
        System.assertEquals(file.Id, result.get('contentVersionId'));
        System.assertEquals('Native Quote quote', result.get('title'));
        System.assertEquals(2, result.size(), 'Never transfer the archive through Aura.');
    }

    @IsTest
    static void nativeSourceSupportsLegacyLinkedFiles() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Legacy Quote',
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        insert template;
        ContentVersion file = new ContentVersion(
            Title = 'Legacy Quote',
            PathOnClient = 'quote.docx',
            VersionData = Blob.valueOf('legacy'),
            FirstPublishLocationId = template.Id
        );
        insert file;
        Test.startTest();
        Id source = DocGenTemplateManager.getTemplateFileVersionId(template.Id);
        Test.stopTest();
        System.assertEquals(file.Id, source);
        System.assertEquals(
            EncodingUtil.base64Encode(file.VersionData),
            DocGenTemplateManager.getTemplateFileContent(template.Id)
        );
    }

    @IsTest
    static void otherFormatsUseTheExistingPipeline() {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Workbook',
            Type__c = 'Excel',
            Base_Object_API__c = 'Account'
        );
        insert template;
        Test.startTest();
        System.assertEquals(null, DocGenController.getNativeWordTemplateSource(template.Id, null));
        try {
            DocGenController.getNativeWordTemplateSource(null, null);
            System.assert(false, 'Missing or inaccessible templates must not disclose a file pointer.');
        } catch (DocGenException expected) {
            System.assert(expected.getMessage().contains('access denied'));
        }
        Test.stopTest();
    }
}

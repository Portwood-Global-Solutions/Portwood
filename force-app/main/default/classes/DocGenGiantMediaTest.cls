@IsTest
private class DocGenGiantMediaTest {
    @IsTest
    static void resolvesReadableFilesForParentPdfAndNativeWord() {
        Account parent = new Account(Name = 'Giant Query media');
        insert parent;
        ContentVersion logo = new ContentVersion(
            Title = 'Fixture logo',
            PathOnClient = 'logo.png',
            VersionData = Blob.valueOf('synthetic test bytes'),
            FirstPublishLocationId = parent.Id
        );
        insert logo;
        logo = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :logo.Id WITH USER_MODE];
        parent.Description = String.valueOf(logo.ContentDocumentId);
        update parent;

        Map<String, Object> nativeWord = DocGenController.getGiantDocxImage(logo.ContentDocumentId);
        Assert.areEqual(logo.Id, nativeWord.get('contentVersionId'));
        Assert.areEqual('png', nativeWord.get('extension'));
        Assert.areEqual(
            'synthetic test bytes',
            EncodingUtil.base64Decode((String) nativeWord.get('base64')).toString()
        );
        Assert.isNull(DocGenController.getGiantDocxImage(parent.Id));
        Assert.isNull(
            DocGenGiantMedia.fileId('https://images.example.invalid/sfc/servlet.shepherd/version/download/' + logo.Id)
        );

        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(null, null, parent.Id, 'Contacts');
        String html = assembler.resolveParentFieldImageTags(
            '<p>{%Description:100x60}</p><p>{%Image:1}</p><p>{%asset:logo}</p>'
        );
        Assert.isTrue(html.contains('/sfc/servlet.shepherd/version/download/' + logo.Id));
        Assert.isTrue(html.contains('width:100px') || html.contains('width="100"'), html);
        Assert.isTrue(html.contains('{%Image:1}'), 'Positional tags have their own resolver.');
        Assert.isTrue(html.contains('{%asset:logo}'), 'Shared asset tags have their own resolver.');
    }

    @IsTest
    static void refusesUnsupportedFilesBeforeReadingBytes() {
        ContentVersion document = new ContentVersion(
            Title = 'A document',
            PathOnClient = 'document.pdf',
            VersionData = Blob.valueOf('synthetic test bytes')
        );
        insert document;
        Assert.isNull(DocGenController.getGiantDocxImage(document.Id));
    }
}

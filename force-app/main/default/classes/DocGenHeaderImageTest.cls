/** Generated header/footer images must survive PDF conversion and native DOCX assembly. */
@IsTest
private class DocGenHeaderImageTest {
    private static final String PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    private static final String W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
    private static final String R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
    private static final String PACKAGE_R = 'http://schemas.openxmlformats.org/package/2006/relationships';

    @TestSetup
    static void setup() {
        DocGen_Asset__c asset = new DocGen_Asset__c(
            Name = 'Header Logo',
            Asset_Key__c = 'header-logo',
            Asset_Type__c = 'Image',
            Is_Active__c = true
        );
        insert asset;
        ContentVersion image = new ContentVersion(
            Title = 'Header Logo',
            PathOnClient = 'logo.png',
            VersionData = EncodingUtil.base64Decode(PNG),
            FirstPublishLocationId = asset.Id
        );
        insert image;
        insert new Account(
            Name = 'Header Image Record',
            Description = '<img src="/sfc/servlet.shepherd/version/download/' + image.Id + '" width="12" height="12"/>'
        );
    }

    private static String paragraph(String text) {
        return '<w:p><w:r><w:t>' + text + '</w:t></w:r></w:p>';
    }

    private static DocGen_Template__c template(Boolean decompose, Boolean richTextHeader) {
        return template(decompose, richTextHeader, false);
    }

    private static DocGen_Template__c template(Boolean decompose, Boolean richTextHeader, Boolean emptyFooterRels) {
        DocGen_Template__c template = new DocGen_Template__c(
            Name = 'Header Images',
            Type__c = 'Word',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name, Description'
        );
        insert template;
        Compression.ZipWriter zip = new Compression.ZipWriter();
        zip.addEntry(
            '[Content_Types].xml',
            Blob.valueOf(
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>'
            )
        );
        zip.addEntry(
            '_rels/.rels',
            Blob.valueOf(
                '<Relationships xmlns="' +
                    PACKAGE_R +
                    '"><Relationship Id="doc" Type="' +
                    R +
                    '/officeDocument" Target="word/document.xml"/></Relationships>'
            )
        );
        zip.addEntry(
            'word/document.xml',
            Blob.valueOf(
                '<w:document xmlns:w="' +
                    W +
                    '" xmlns:r="' +
                    R +
                    '"><w:body>' +
                    paragraph('{Name}') +
                    paragraph('{%asset:header-logo:24x24}') +
                    paragraph('{#Contacts}{LastName}{/Contacts}') +
                    '<w:sectPr><w:headerReference w:type="default" r:id="header"/><w:footerReference w:type="default" r:id="footer"/></w:sectPr></w:body></w:document>'
            )
        );
        zip.addEntry(
            'word/_rels/document.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="' +
                    PACKAGE_R +
                    '"><Relationship Id="header" Type="' +
                    R +
                    '/header" Target="header1.xml"/><Relationship Id="footer" Type="' +
                    R +
                    '/footer" Target="footer1.xml"/></Relationships>'
            )
        );
        zip.addEntry(
            'word/header1.xml',
            Blob.valueOf(
                '<w:hdr xmlns:w="' +
                    W +
                    '">' +
                    paragraph('HEADER') +
                    paragraph(richTextHeader ? '{Description}' : '{%asset:header-logo:12x12}') +
                    '</w:hdr>'
            )
        );
        zip.addEntry(
            'word/footer1.xml',
            Blob.valueOf(
                '<w:ftr xmlns:w="' +
                    W +
                    '">' +
                    paragraph('FOOTER') +
                    paragraph('{%asset:header-logo:12x12}') +
                    '</w:ftr>'
            )
        );
        // Preserve an existing part relationship; the footer deliberately has no .rels yet.
        zip.addEntry(
            'word/_rels/header1.xml.rels',
            Blob.valueOf(
                '<Relationships xmlns="' +
                    PACKAGE_R +
                    '"><Relationship Id="link" Type="' +
                    R +
                    '/hyperlink" Target="https://portwood.dev" TargetMode="External"/></Relationships>'
            )
        );
        if (emptyFooterRels) {
            zip.addEntry('word/_rels/footer1.xml.rels', Blob.valueOf('<Relationships xmlns="' + PACKAGE_R + '"/>'));
        }
        ContentVersion source = new ContentVersion(
            Title = 'Header Images',
            PathOnClient = 'headers.docx',
            VersionData = zip.getArchive(),
            FirstPublishLocationId = template.Id
        );
        insert source;
        DocGen_Template_Version__c version = new DocGen_Template_Version__c(
            Template__c = template.Id,
            Content_Version_Id__c = source.Id,
            Is_Active__c = true
        );
        insert version;
        if (decompose) {
            DocGenService.extractAndSaveTemplateImages(template.Id, version.Id);
        }
        return template;
    }

    private static Id recordId() {
        return [SELECT Id FROM Account WHERE Name = 'Header Image Record' LIMIT 1].Id;
    }

    private static void assertHtmlImages(String html) {
        Matcher images = Pattern.compile('<img[^>]+src="(/sfc/servlet\\.shepherd/version/download/[^"]+)"')
            .matcher(html);
        Integer count = 0;
        while (images.find()) {
            count++;
        }
        System.assertEquals(3, count, 'Header, body and footer images must all resolve in rendered HTML: ' + html);
        System.assert(html.contains('HEADER') && html.contains('FOOTER'), 'Both chrome regions must be present');
    }

    private static void assertPartImages(Map<String, String> xmlParts) {
        for (String part : new List<String>{ 'document', 'header1', 'footer1' }) {
            String xml = xmlParts.get('word/' + part + '.xml');
            Matcher drawing = Pattern.compile('r:embed="([^"]+)"').matcher(xml);
            System.assert(drawing.find(), 'Missing drawing in ' + part);
            String relId = drawing.group(1);
            String relsXml = xmlParts.get('word/_rels/' + part + '.xml.rels');
            System.assertNotEquals(null, relsXml, 'Image relationship file must exist for ' + part);
            Dom.Document rels = new Dom.Document();
            rels.load(relsXml);
            Boolean found = false;
            for (Dom.XmlNode rel : rels.getRootElement().getChildElements()) {
                if (rel.getAttribute('Id', null) == relId) {
                    System.assertEquals(R + '/image', rel.getAttribute('Type', null));
                    System.assert(rel.getAttribute('Target', null).startsWith('media/docgen_image_'));
                    found = true;
                }
            }
            System.assert(found, 'The drawing must resolve through its own part relationships: ' + part + '/' + relId);
        }
        System.assert(
            xmlParts.get('word/_rels/header1.xml.rels').contains('https://portwood.dev'),
            'Existing header relationships must survive'
        );
    }

    @IsTest
    static void pdfHeaderAndFooterAssetsResolveFromZip() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(t.Id, recordId(), null);
        Test.stopTest();
        assertHtmlImages(html);
    }

    @IsTest
    static void pdfHeaderAndFooterAssetsResolveFromDecomposedParts() {
        DocGen_Template__c t = template(true, false);
        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(t.Id, recordId(), null);
        Test.stopTest();
        assertHtmlImages(html);
    }

    @IsTest
    static void richTextHeaderImagesAlsoResolve() {
        DocGen_Template__c t = template(false, true);
        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(t.Id, recordId(), null);
        Test.stopTest();
        assertHtmlImages(html);
    }

    @IsTest
    static void reusedFileAtDifferentSizesGetsIndependentPdfImages() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        String html = DocGenService.generateHtmlForRecord(t.Id, recordId(), null);
        Test.stopTest();
        assertHtmlImages(html);
        Matcher images = Pattern.compile('<img[^>]+src="(/sfc/servlet\\.shepherd/version/download/[^"]+)"')
            .matcher(html);
        Set<String> sources = new Set<String>();
        while (images.find()) {
            sources.add(images.group(1));
        }
        System.assertEquals(2, sources.size(), 'Different sizes of the same File need distinct PDF cache entries');
        System.assert(html.contains('width="24"') && html.contains('width="12"'), 'Keep the authored image sizes');
    }

    @IsTest
    static void clientWordPartsUsePartRelationships() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(t.Id, recordId());
        Test.stopTest();
        assertPartImages((Map<String, String>) result.get('allXmlParts'));
    }

    @IsTest
    static void clientWordPartsExpandEmptyRelationshipRoots() {
        DocGen_Template__c t = template(false, false, true);
        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentParts(t.Id, recordId());
        Test.stopTest();
        assertPartImages((Map<String, String>) result.get('allXmlParts'));
    }

    @IsTest
    static void giantWordPartsUsePartRelationships() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        Map<String, Object> result = DocGenService.generateDocumentPartsGiantQuery(t.Id, recordId(), 'Contacts');
        Test.stopTest();
        assertPartImages((Map<String, String>) result.get('allXmlParts'));
    }

    @IsTest
    static void giantPdfShellKeepsHeaderImages() {
        DocGen_Template__c t = template(true, false);
        Test.startTest();
        String html = DocGenService.mergeTemplateForGiantQueryPdf(t.Id, recordId(), 'Contacts', 'CHILDREN');
        Test.stopTest();
        assertHtmlImages(html);
    }

    @IsTest
    static void serverWordArchiveUsesPartRelationships() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        Id documentId = DocGenService.generateDocument(t.Id, recordId(), 'Word');
        Test.stopTest();
        assertArchiveImages(documentId);
    }

    @IsTest
    static void preRenderedLoopWordArchiveUsesPartRelationships() {
        DocGen_Template__c t = template(false, false);
        Test.startTest();
        Id documentId = DocGenService.mergeTemplateWithPreRenderedLoops(
            t.Id,
            recordId(),
            new Map<String, String>{ 'Contacts' => paragraph('Merged child') },
            'Native'
        );
        Test.stopTest();
        assertArchiveImages(documentId);
    }

    private static void assertArchiveImages(Id documentId) {
        ContentVersion result = [
            SELECT VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :documentId AND IsLatest = TRUE
            LIMIT 1
        ];
        Compression.ZipReader zip = new Compression.ZipReader(result.VersionData);
        Map<String, String> xmlParts = new Map<String, String>();
        for (Compression.ZipEntry entry : zip.getEntries()) {
            if (entry.getName().endsWith('.xml') || entry.getName().endsWith('.rels')) {
                xmlParts.put(entry.getName(), zip.extract(entry.getName()).toString());
            }
        }
        assertPartImages(xmlParts);
    }
}

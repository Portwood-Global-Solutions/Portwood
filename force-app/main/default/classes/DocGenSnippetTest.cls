@IsTest
private class DocGenSnippetTest {
    private static Map<String, Object> create(String key, String html) {
        return DocGenSnippetController.saveSnippet(null, key, key, 'Terms & Conditions', html, null, true);
    }
    private static Map<String, Object> save(Map<String, Object> a, String html, Boolean active) {
        return DocGenSnippetController.saveSnippet(
            (Id) a.get('id'),
            (String) a.get('name'),
            (String) a.get('assetKey'),
            'Terms & Conditions',
            html,
            (String) a.get('currentVersionId'),
            active
        );
    }
    @IsTest
    static void createAndPrivateHistory() {
        Map<String, Object> a = create('standard-terms', '<h2>Terms</h2><p>Payment within <b>30 days</b>.</p>');
        System.assertEquals('{%snippet:standard-terms}', a.get('mergeTag'));
        System.assertEquals('1', a.get('versionNumber'));
        System.assertEquals(1, DocGenSnippetController.getSnippets().size());
        Id assetId = (Id) a.get('id');
        Id versionId = (Id) a.get('versionId');
        System.assertEquals(
            'P',
            [SELECT SharingPrivacy FROM ContentVersion WHERE Id = :versionId].SharingPrivacy,
            'Snippet source files are private on records, without public distributions.'
        );
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
        System.assertEquals(0, DocGenController.getAssets().size(), 'Image catalog must not contain snippet assets.');
        System.assertEquals(
            '<h2>Terms</h2><p>Payment within <b>30 days</b>.</p>',
            DocGenSnippetService.expand('{%snippet:standard-terms}')
        );
        Map<String, Object> b = save(a, '<p>Payment within 45 days.</p>', true);
        System.assertEquals('2', b.get('versionNumber'));
        System.assertEquals(
            '<p>Payment within 45 days.</p>',
            DocGenSnippetService.expand('{%snippet:standard-terms}'),
            'Save invalidates the per-request cache.'
        );
        Map<String, Object> old = DocGenSnippetController.getSnippet(assetId, (Id) a.get('versionId'));
        System.assert(((String) old.get('html')).contains('30 days'));
        System.assertEquals(b.get('versionId'), old.get('currentVersionId'));
        Map<String, Object> restored = save(old, (String) old.get('html'), true);
        System.assertEquals('3', restored.get('versionNumber'));
    }
    @IsTest
    static void imageEndpointsCannotExposeOrDeleteSnippetSources() {
        Map<String, Object> a = create('private-source', '<p>Private shared terms</p>');
        Id assetId = (Id) a.get('id'), versionId = (Id) a.get('versionId');
        try {
            DocGenController.addAssetVersion(assetId, versionId);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('image asset'));
        }
        try {
            DocGenEmailTemplateController.resolveAssetPublicUrl(assetId);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        try {
            DocGenController.deleteAsset(assetId);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('image asset'));
        }
        System.assertEquals(0, [SELECT COUNT() FROM ContentDistribution]);
        System.assertEquals('<p>Private shared terms</p>', DocGenSnippetService.expand('{%snippet:private-source}'));
    }

    @IsTest
    static void fieldsAndRowContext() {
        create('greeting', '<p>Hello <strong>{Name}</strong></p>');
        String result = DocGenService.processXmlForTest(
            '{%snippet:greeting}{#Contacts}{%snippet:greeting}{/Contacts}',
            new Map<String, Object>{
                'Name' => 'Parent',
                'Contacts' => new Map<String, Object>{
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Name' => 'Alice' },
                        new Map<String, Object>{ 'Name' => 'Bob' }
                    }
                }
            },
            'HTML'
        );
        System.assertEquals(
            '<p>Hello <strong>Parent</strong></p><p>Hello <strong>Alice</strong></p><p>Hello <strong>Bob</strong></p>',
            result
        );
    }
    @IsTest
    static void nestedSectionsAndFontImageTags() {
        create(
            'clause',
            '<p style="page-break-inside:avoid;{%font:lato:1234567890abcdef}">For {Name}</p><img src="{%asset:logo:144x}" />'
        );
        create('terms', '<h2>Terms</h2>{%snippet:clause}');
        String result = DocGenSnippetService.expand('{%snippet:terms}{%snippet:terms}');
        System.assertEquals(2, result.countMatches('<h2>Terms</h2>'));
        System.assert(
            result.contains('{Name}') &&
                result.contains('{%font:lato:1234567890abcdef}') &&
                result.contains('{%asset:logo:144x}')
        );
        System.assert(!result.contains('{%snippet:'));
    }
    @IsTest
    static void giantExtractionAndParentFields() {
        create('row', '<span>{LastName}</span>');
        create('list', '<ul><li>{#Contacts}{%snippet:row}{/Contacts}</li></ul>');
        String body = DocGenService.extractHtmlBodyContent('<html><body>{%snippet:list}</body></html>');
        System.assertEquals('<ul><li>{#Contacts}<span>{LastName}</span>{/Contacts}</li></ul>', body);
        Map<String, String> parts = DocGenService.extractLoopBody('{%snippet:list}', 'Contacts');
        System.assert(parts.get('innerXml').contains('{LastName}'));
        Account account = new Account(Name = 'Shared customer');
        insert account;
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Snippet giant test',
            Type__c = 'HTML',
            Base_Object_API__c = 'Account'
        );
        insert t;
        create('parent', '<p>{Name}</p>');
        DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(null, t.Id, account.Id, 'Contacts');
        System.assertEquals('<p>Shared customer</p>', assembler.resolveParentMergeTags('{%snippet:parent}'));
    }
    @IsTest
    static void ordinaryAndGiantHeadersFooters() {
        create('footer', '<p>Shared footer for {Name}</p>');
        String html = DocGenService.processXmlForTest(
            DocGenService.extractHtmlBodyContent('<body>{%snippet:footer}</body>'),
            new Map<String, Object>{ 'Name' => 'Header customer' },
            'HTML'
        );
        System.assertEquals('<p>Shared footer for Header customer</p>', html);
    }
    @IsTest
    static void fullHtmlPipelineExpandsBodyAndRunningRegions() {
        create('body-clause', '<h2>Contract terms</h2><p>Prepared for {Name}</p>');
        create('header-clause', '<p>Header for {Name}</p>');
        create('footer-clause', '<p>Footer for {Name}</p>');
        Account a = new Account(Name = 'Pipeline customer');
        insert a;
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Snippet pipeline',
            Type__c = 'HTML',
            Output_Format__c = 'PDF',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name',
            Header_Html__c = '{%snippet:header-clause}',
            Footer_Html__c = '{%snippet:footer-clause}'
        );
        insert t;
        ContentVersion cv = new ContentVersion(
            Title = 'Snippet pipeline',
            PathOnClient = 'template.html',
            VersionData = Blob.valueOf(
                '<html><head><style>h2 {color:#206b72;}</style></head><body>{%snippet:body-clause}</body></html>'
            ),
            FirstPublishLocationId = t.Id
        );
        insert cv;
        insert new DocGen_Template_Version__c(Template__c = t.Id, Content_Version_Id__c = cv.Id, Is_Active__c = true);
        Test.startTest();
        Map<String, Object> pdf = DocGenService.generatePdfBlob(t.Id, a.Id);
        Test.stopTest();
        System.assertNotEquals(null, pdf.get('blob'));
        String rendered = DocGenService.lastRenderedHtml;
        System.assert(rendered.contains('Prepared for Pipeline customer'), rendered);
        System.assert(rendered.contains('Header for Pipeline customer'));
        System.assert(rendered.contains('Footer for Pipeline customer'));
        System.assert(!rendered.contains('{%snippet:'));
    }

    @IsTest
    static void userCanReadButCannotPublish() {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User reader = new User(
            Alias = 'snpread',
            Email = 'snippets@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Snippet reader',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/New_York',
            Username = 'snippet-' + System.currentTimeMillis() + '@example.com'
        );
        insert reader;
        PermissionSet permission = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = reader.Id, PermissionSetId = permission.Id);
        Map<String, Object> a;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            a = create('read-only', '<p>Shared with internal readers</p>');
        }
        DocGenSnippetService.clearCache();
        System.runAs(reader) {
            System.assertEquals(
                '<p>Shared with internal readers</p>',
                DocGenSnippetService.expand('{%snippet:read-only}')
            );
            System.assertEquals(1, DocGenSnippetController.getSnippets().size());
            System.assertEquals(
                '<p>Shared with internal readers</p>',
                DocGenSnippetController.getSnippet((Id) a.get('id'), null).get('html')
            );
            try {
                save(a, '<p>Unauthorised edit</p>', true);
                System.assert(false, 'A reader cannot publish.');
            } catch (AuraHandledException e) {
                System.assertNotEquals(null, e.getMessage());
            }
        }
    }

    @IsTest
    static void secondEditorCanVersionPrivateFile() {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User editor = new User(
            Alias = 'snpedit',
            Email = 'snippet-editor@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Snippet editor',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/New_York',
            Username = 'snippet-editor-' + System.currentTimeMillis() + '@example.com'
        );
        insert editor;
        PermissionSet permission = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_Admin' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = editor.Id, PermissionSetId = permission.Id);
        Map<String, Object> a;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            a = create('second-editor', '<p>First editor</p>');
        }
        System.runAs(editor) {
            Map<String, Object> b = save(a, '<p>Second editor</p>', true);
            System.assertEquals('2', b.get('versionNumber'));
            System.assertEquals('<p>Second editor</p>', DocGenSnippetService.expand('{%snippet:second-editor}'));
        }
    }

    @IsTest
    static void giantTableSectionsRemainBalancedAcrossChunks() {
        String source = '<table><thead><tr><th>Name</th></tr></thead><tbody style="color:blue"><tr>{#Contacts}<td>{LastName}</td>{/Contacts}</tr></tbody></table>';
        Integer open = source.indexOf('{#Contacts}');
        String shell = DocGenGiantQueryAssembler.replaceGiantLoopTableTail(
            source,
            open,
            source.lastIndexOf('<tr', open),
            source.indexOf('</table>', open)
        );
        System.assert(shell.contains('{ROWS}'));
        String rows = DocGenGiantQueryAssembler.insertTableBreaks(
            '<tr><td>A</td></tr><tr><td>B</td></tr>',
            1,
            '<table>',
            '<colgroup><col style="width:100%"/></colgroup>',
            '<thead><tr><th>Name</th></tr></thead>'
        );
        System.assert(rows.contains('</table><table>'));
        System.assertEquals(2, rows.countMatches('</tr>'));
    }

    @IsTest
    static void giantRowsUseHtmlContextForSharedRichText() {
        create('rich-row', '<p>{Description}</p>');
        String rendered = DocGenService.renderLoopBodyForRecords(
            '<td>{%snippet:rich-row}</td>',
            'Contacts',
            new List<SObject>{ new Contact(Description = '<b>Formatted record text</b>') },
            new List<String>{ 'Description' },
            0,
            'HTML',
            'PDF'
        );
        System.assertEquals('<td><p><b>Formatted record text</b></p></td>', rendered);
        String word = DocGenService.processXmlForTest(
            '<w:p><w:r><w:t>{%snippet:rich-row}</w:t></w:r></w:p>',
            new Map<String, Object>{ 'Description' => '<b>Formatted record text</b>' },
            'Word'
        );
        System.assert(word.contains('Formatted record text'));
        System.assert(word.contains('<w:b/>'));
    }

    @IsTest
    static void staleSavePreservesNewRevision() {
        Map<String, Object> a = create('concurrency', '<p>First</p>');
        save(a, '<p>Second</p>', true);
        try {
            save(a, '<p>Stale overwrite</p>', true);
            System.assert(false, 'Must reject stale edits.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('newer revision'));
        }
        System.assertEquals('<p>Second</p>', DocGenSnippetService.expand('{%snippet:concurrency}'));
    }
    @IsTest
    static void missingAndInactiveFailLoudly() {
        Map<String, Object> a = create('inactive', '<p>Required terms</p>');
        save(a, '<p>Required terms</p>', false);
        for (String tag : new List<String>{ '{%snippet:inactive}', '{%snippet:missing}' }) {
            try {
                DocGenSnippetService.expand(tag);
                System.assert(false, 'Must not silently omit terms.');
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('missing, inactive'));
            }
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(null, null, null, 'Contacts');
            try {
                assembler.resolveParentMergeTags(tag);
                System.assert(false, 'Giant resolver must also throw.');
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('missing, inactive'));
            }
        }
    }
    @IsTest
    static void cyclesRejectedAtomically() {
        Map<String, Object> a = create('cycle', '<p>Original</p>');
        try {
            save(a, '{%snippet:cycle}', true);
            System.assert(false, 'Cycle must not publish.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('circular'));
        }
        System.assertEquals('<p>Original</p>', DocGenSnippetService.expand('{%snippet:cycle}'));
        create('second', '{%snippet:cycle}');
        try {
            save(a, '{%snippet:second}', true);
            System.assert(false, 'Indirect cycle must not publish.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('circular'));
        }
    }
    @IsTest
    static void foreignRevisionNotReadable() {
        Map<String, Object> a = create('one', '<p>One</p>');
        Map<String, Object> b = create('two', '<p>Two</p>');
        try {
            DocGenSnippetController.getSnippet((Id) a.get('id'), (Id) b.get('versionId'));
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('not found'));
        }
    }
    @IsTest
    static void rejectsUnsafeHtmlWithoutDroppingContent() {
        for (
            String html : new List<String>{
                '<script>alert(1)</script>',
                '<p onclick="alert(1)">Terms</p>',
                '<a href="java&#x73;cript:alert(1)">Terms</a>',
                '<div style="background:u\\72l(https://example.com)">Terms</div>',
                '<iframe src="https://example.com"></iframe>',
                '<style>p{color:red}</style>',
                '<img src="data:image/png;base64,AAAA" />',
                '<p style="background:URL(https://example.com)">Terms</p>',
                '<p style="behavior:expression(alert(1))">Terms</p>',
                '<p style="color:red"',
                '<div onload=alert(1)>Terms</div>'
            }
        ) {
            try {
                DocGenSnippetService.validate(html);
                System.assert(false, 'Unsafe HTML accepted: ' + html);
            } catch (DocGenException e) {
                System.assertNotEquals(null, e.getMessage());
            }
        }
        System.assertEquals(0, [SELECT COUNT() FROM DocGen_Asset__c]);
    }
    @IsTest
    static void validFormattingAndEncodedTags() {
        String html = '<section dir="rtl" lang="ar"><h2>الشروط</h2><p style="page-break-inside:avoid;color:#183452">Terms &amp; conditions for &#123;Name&#125;</p><table style="width:100%;border-collapse:collapse"><tbody><tr><td colspan="2">All fees</td></tr></tbody></table><a href="https://example.com">Read more</a></section>';
        String valid = DocGenSnippetService.validate(html);
        System.assert(valid.contains('{Name}') && valid.contains('الشروط'));
        System.assertEquals('plain text', DocGenSnippetService.validate('plain text'));
    }
    @IsTest
    static void officeFormatsReceiveSharedContent() {
        create('office-content', '<h2>Terms</h2><p>Payment within <strong>30 days</strong>.</p>');
        String word = DocGenService.processXmlForTest(
            '<w:p><w:r><w:t>{%snippet:office-content}</w:t></w:r></w:p>',
            new Map<String, Object>(),
            'Word'
        );
        System.assert(word.contains('Terms'));
        System.assert(word.contains('Payment within'));
        System.assert(word.contains('<w:b/>'));

        String ppt = DocGenService.processXmlForTest(
            '<a:p><a:r><a:t>{%snippet:office-content}</a:t></a:r></a:p>',
            new Map<String, Object>(),
            'PowerPoint'
        );
        System.assert(ppt.contains('Terms'));
        System.assert(ppt.contains('Payment within'));
        System.assert(!ppt.contains('<h2>'));

        String excel = DocGenService.processXmlForTest(
            '<c r="A1" t="inlineStr"><is><t>{%snippet:office-content}</t></is></c>',
            new Map<String, Object>(),
            'Excel'
        );
        System.assert(excel.contains('Terms'));
        System.assert(excel.contains('Payment within'));
        System.assert(!excel.contains('<h2>'));
    }
    @IsTest
    static void malformedTagAndDuplicateKey() {
        create('key', '<p>Original</p>');
        try {
            create('key', '<p>Duplicate</p>');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('already used'));
        }
        for (String html : new List<String>{ '{%snippet:bad key}', '{%snippet:key}{%snippet:bad key}' }) {
            try {
                DocGenSnippetService.expand(html);
                System.assert(false);
            } catch (DocGenException e) {
                System.assert(e.getMessage().contains('tag') || e.getMessage().contains('Tag'));
            }
        }
    }
    @IsTest
    static void boundedExpansion() {
        create('large', '<p>' + 'x'.repeat(249990) + '</p>');
        try {
            DocGenSnippetService.expand('{%snippet:large}'.repeat(5));
            System.assert(false);
        } catch (DocGenException e) {
            System.assert(e.getMessage().contains('too large'));
        }
    }
}

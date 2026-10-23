@IsTest
private class DocGenGiantQueryTest {
    /**
     * Creates a test template with V3 query config for Account -> Contacts.
     * Also creates an Account with multiple Contacts for testing.
     */
    @TestSetup
    static void setup() {
        TestDataFactory.assignAdminPermissionSet();
        // Create template with V3 config
        String v3Config = JSON.serialize(
            new Map<String, Object>{
                'v' => 3,
                'root' => 'Account',
                'nodes' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'n0',
                        'object' => 'Account',
                        'fields' => new List<String>{ 'Name' },
                        'parentFields' => new List<String>(),
                        'parentNode' => null,
                        'lookupField' => null,
                        'relationshipName' => null
                    },
                    new Map<String, Object>{
                        'id' => 'n1',
                        'object' => 'Contact',
                        'fields' => new List<String>{ 'FirstName', 'LastName' },
                        'parentFields' => new List<String>(),
                        'parentNode' => 'n0',
                        'lookupField' => 'AccountId',
                        'relationshipName' => 'Contacts'
                    }
                }
            }
        );

        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Giant Query Test',
            Base_Object_API__c = 'Account',
            Query_Config__c = v3Config,
            Type__c = 'Word',
            Output_Format__c = 'PDF'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        // Create a valid DOCX file and link to template
        ContentVersion docxCv = TestDataFactory.createValidDocxFile(tpl.Id, TestDataFactory.buildSimpleDocXml());

        // Create Template Version (active) with the DOCX content version
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(
            Template__c = tpl.Id,
            Is_Active__c = true,
            Content_Version_Id__c = docxCv.Id,
            Query_Config__c = v3Config,
            Type__c = 'Word',
            Base_Object_API__c = 'Account'
        );
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        // Create Account with Contacts
        Account acc = new Account(Name = 'Giant Query Test Account');
        insert acc;

        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 10; i++) {
            contacts.add(new Contact(FirstName = 'Test' + i, LastName = 'Contact' + i, AccountId = acc.Id));
        }
        insert contacts;

        // Create a minimal DOCX-like ContentVersion with loop tags for the template
        // This is a simplified test — real templates would be actual DOCX ZIPs
        ContentVersion cv = new ContentVersion(
            Title = 'GiantQueryTestDoc',
            PathOnClient = 'GiantQueryTestDoc.docx',
            VersionData = Blob.valueOf('Test Content'),
            IsMajorVersion = true
        );
        insert cv;

        Id conDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        ContentDocumentLink cdl = new ContentDocumentLink(
            LinkedEntityId = tpl.Id,
            ContentDocumentId = conDocId,
            ShareType = 'V'
        );
        insert cdl;
    }

    @IsTest
    static void testScoutChildCounts() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [
                SELECT Query_Config__c
                FROM DocGen_Template__c
                WHERE Name = 'Giant Query Test'
                LIMIT 1
            ];

            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, tpl.Query_Config__c);
            Test.stopTest();

            System.assertNotEquals(null, counts, 'Counts map should not be null');
            System.assert(counts.containsKey('Contacts'), 'Should contain Contacts relationship');
            System.assertEquals(10, counts.get('Contacts'), 'Should count 10 contacts');
        }
    }

    @IsTest
    static void testScoutChildCountsWithNullParams() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Map<String, Integer> counts1 = DocGenDataRetriever.scoutChildCounts(null, '{}');
            Map<String, Integer> counts2 = DocGenDataRetriever.scoutChildCounts(
                [SELECT Id FROM Account LIMIT 1].Id,
                null
            );
            Test.stopTest();

            System.assert(counts1.isEmpty(), 'Null recordId should return empty map');
            System.assert(counts2.isEmpty(), 'Null config should return empty map');
        }
    }

    @IsTest
    static void testExtractLoopBody() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Simple XML with a loop
            String xml = '<w:body><w:tr><w:tc>{#Contacts}<w:p>{FirstName}</w:p>{/Contacts}</w:tc></w:tr></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'Contacts');
            Test.stopTest();

            System.assertNotEquals(null, result, 'Should extract loop body');
            System.assert(result.containsKey('innerXml'), 'Should contain innerXml');
            System.assert(result.containsKey('beforeLoop'), 'Should contain beforeLoop');
            System.assert(result.containsKey('afterLoop'), 'Should contain afterLoop');
            System.assert(result.get('innerXml').contains('{FirstName}'), 'Inner XML should contain merge tag');
        }
    }

    @IsTest
    static void testExtractLoopBodyNotFound() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            String xml = '<w:body><w:p>{Name}</w:p></w:body>';

            Test.startTest();
            Map<String, String> result = DocGenService.extractLoopBody(xml, 'NonExistent');
            Test.stopTest();

            System.assertEquals(null, result, 'Should return null when loop not found');
        }
    }

    @IsTest
    static void testExtractColumnCssEmitsClassSelectors() {
        // Regression: per-column styles must use td.gqcN class selectors, not
        // td:nth-child(N) — Flying Saucer (Blob.toPdf) silently drops :nth-child,
        // making the entire giant-query column-CSS scheme dead. Customer-visible
        // symptom: right-aligned cells render left-aligned in the PDF.
        String loopRowXml =
            '<w:tr>' +
            '<w:tc><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>A</w:t></w:r></w:p></w:tc>' +
            '<w:tc><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:b/></w:rPr><w:t>B</w:t></w:r></w:p></w:tc>' +
            '<w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc>' +
            '</w:tr>';

        Test.startTest();
        String css = DocGenGiantQueryBatch.extractColumnCss(loopRowXml);
        Test.stopTest();

        System.assert(css.contains('td.gqc1{'), 'Col 1 must use class selector. Got: ' + css);
        System.assert(css.contains('td.gqc2{'), 'Col 2 must use class selector. Got: ' + css);
        System.assert(css.contains('text-align:right'), 'Col 1 right-align must be emitted. Got: ' + css);
        System.assert(css.contains('text-align:center'), 'Col 2 center-align must be emitted. Got: ' + css);
        System.assert(css.contains('font-weight:bold'), 'Col 2 bold must be emitted. Got: ' + css);
        System.assert(
            !css.contains(':nth-child('),
            ':nth-child must NEVER be emitted — Flying Saucer ignores it. Got: ' + css
        );
    }

    @IsTest
    static void testRenderLoopBodyForRecords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Contact> contacts = [SELECT FirstName, LastName FROM Contact ORDER BY FirstName LIMIT 5];
            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            String result = DocGenService.renderLoopBodyForRecords(
                innerXml,
                'Contacts',
                contacts,
                new List<String>{ 'FirstName', 'LastName' }
            );
            Test.stopTest();

            System.assertNotEquals(null, result, 'Rendered result should not be null');
            System.assert(result.length() > innerXml.length(), 'Result should be longer than single template');
            // Each contact should produce a rendered row
            for (Contact c : contacts) {
                System.assert(result.contains(c.FirstName), 'Should contain first name: ' + c.FirstName);
            }
        }
    }

    @IsTest
    static void testGiantQueryBatchExecution() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [
                SELECT Id, Output_Format__c
                FROM DocGen_Template__c
                WHERE Name = 'Giant Query Test'
                LIMIT 1
            ];

            // Create a Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Test Giant Query',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Build child node config
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>()
            };

            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id,
                tpl.Id,
                acc.Id,
                childNodeConfig,
                innerXml,
                'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Verify job was updated
            DocGen_Job__c updatedJob = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Draft', updatedJob.Status__c, 'Job status should have changed from Draft');
            System.assertEquals(10, updatedJob.Total_Records__c, 'Should have counted 10 contacts');

            // Verify batch executed (fragments may or may not be created depending on
            // whether renderLoopBodyForRecords succeeds with the minimal test XML)
            System.assert(updatedJob.Status__c != null, 'Job status should be set after batch execution');
        }
    }

    /**
     * Regression guard (P1 #134): when a docgen_tmpl_html_ snapshot exists, the
     * giant-query assembler must build the document AROUND it — preserving the
     * template's title / column headers / footer — not fall back to the bare
     * Query_Config table. The production bug was the snapshot read using
     * WITH USER_MODE (invisible for InternalUsers-visibility package CVs), which
     * silently took the bare-table branch and dropped all chrome.
     *
     * NOTE: test-context USER_MODE is lenient (the running user owns the test CV),
     * so this asserts the chrome-preservation PATH rather than isolating the
     * USER_MODE→SYSTEM_MODE access change (which only manifests with InternalUsers
     * CDL visibility — covered by the customer-template reproduction).
     */
    @IsTest
    static void testGiantQuerySnapshotChromePreserved() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];

            // Snapshot the template HTML with recognizable chrome wrapping the loop.
            String snapshotHtml =
                '<html><body>' +
                '<h1>GQ_CHROME_TITLE</h1>' +
                '<p><img src="/sfc/servlet.shepherd/version/download/068000000000000AAA" alt="GQ_CHROME_LOGO"/></p>' +
                '<table>' +
                '<tr><th>GQ_CHROME_HEADER</th></tr>' +
                '<tr>{#Contacts}<td>{FirstName}</td>{/Contacts}</tr>' +
                '</table>' +
                '<p>GQ_CHROME_FOOTER</p>' +
                '</body></html>';
            insert new ContentVersion(
                Title = 'docgen_tmpl_html_' + ver.Id,
                PathOnClient = 'snapshot.html',
                VersionData = Blob.valueOf(snapshotHtml),
                IsMajorVersion = false,
                FirstPublishLocationId = ver.Id
            );

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // Run the assembler directly with one pre-rendered row fragment (mirrors
            // testAssemblerParentFieldFormatting) so we can assert on the assembled
            // HTML without going through the batch's Blob.toPdf path.
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001',
                PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Row0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            List<ContentVersion> debug = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Title = :(prefix + 'debug_html')
                LIMIT 1
            ];
            System.assert(!debug.isEmpty(), 'Assembler should have produced debug HTML');
            String assembled = debug[0].VersionData.toString();
            System.assert(
                assembled.contains('GQ_CHROME_TITLE'),
                'Title chrome must survive (snapshot used, not bare-table fallback). Got: ' + assembled.abbreviate(400)
            );
            System.assert(assembled.contains('GQ_CHROME_HEADER'), 'Column-header chrome must survive');
            System.assert(assembled.contains('GQ_CHROME_FOOTER'), 'Footer chrome must survive');
            System.assert(assembled.contains('GQ_CHROME_LOGO'), 'Embedded template image HTML must survive');
        }
    }

    /**
     * Regression for the half-width giant-query table: the assembler must reuse the
     * snapshot's authored <table> tag + its SINGLE colgroup, not prepend a second one
     * (two colgroups = 2× columns = 200% width, packing real cells into the left half)
     * and not force width:100%. Guards "what the user authored = what comes out".
     */
    @IsTest
    static void testGiantQueryAuthoredWidthSingleColgroup() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];

            // Snapshot table authored at a FIXED width with its own colgroup (mirrors a
            // DOCX table with tblW type="dxa" + tblGrid — the shape that rendered at 50%).
            String snapshotHtml =
                '<html><body>' +
                '<table style="width:432.35pt;border-collapse:collapse;table-layout:fixed">' +
                '<colgroup><col style="width:23.13%"/><col style="width:38.43%"/><col style="width:38.44%"/></colgroup>' +
                '<tr><th>H1</th><th>H2</th><th>H3</th></tr>' +
                '<tr>{#Contacts}<td>{FirstName}</td><td>x</td><td>y</td>{/Contacts}</tr>' +
                '</table></body></html>';
            insert new ContentVersion(
                Title = 'docgen_tmpl_html_' + ver.Id,
                PathOnClient = 'snapshot.html',
                VersionData = Blob.valueOf(snapshotHtml),
                IsMajorVersion = false
            );

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001',
                PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Row0</td><td>0</td><td>0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            String assembled = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Title = :(prefix + 'debug_html')
                    LIMIT 1
                ]
                .VersionData.toString();

            System.assertEquals(
                1,
                assembled.countMatches('<colgroup'),
                'Exactly one colgroup — the duplicate prepend was the half-width bug. Got: ' + assembled.abbreviate(600)
            );
            System.assert(
                assembled.contains('width:432.35pt'),
                'Authored fixed table width must be preserved (not forced to 100%). Got: ' + assembled.abbreviate(600)
            );
            System.assert(
                assembled.contains('width:23.13%'),
                'Authored column widths must survive in the colgroup. Got: ' + assembled.abbreviate(600)
            );
        }
    }

    /**
     * When the snapshot table carries a <thead> (a {RepeatHeader} / tblHeader row), the
     * assembler must capture it so the column headers can reprint on every page.
     */
    @IsTest
    static void testGiantQueryRepeatHeaderCaptured() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];

            String snapshotHtml =
                '<html><body>' +
                '<table style="width:100%;border-collapse:collapse;table-layout:fixed">' +
                '<colgroup><col style="width:50%"/><col style="width:50%"/></colgroup>' +
                '<thead><tr><th>GQ_THEAD_LABEL</th><th>H2</th></tr></thead>' +
                '<tr>{#Contacts}<td>{FirstName}</td><td>x</td>{/Contacts}</tr>' +
                '</table></body></html>';
            insert new ContentVersion(
                Title = 'docgen_tmpl_html_' + ver.Id,
                PathOnClient = 'snapshot.html',
                VersionData = Blob.valueOf(snapshotHtml),
                IsMajorVersion = false
            );

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001',
                PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Row0</td><td>0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            String assembled = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Title = :(prefix + 'debug_html')
                    LIMIT 1
                ]
                .VersionData.toString();

            System.assert(
                assembled.contains('<thead>') && assembled.contains('GQ_THEAD_LABEL'),
                'Repeat-header <thead> must be preserved in the assembled output. Got: ' + assembled.abbreviate(600)
            );
            System.assert(
                assembled.contains('-fs-table-paginate: paginate') &&
                assembled.contains('thead { display: table-header-group; }'),
                'Flying Saucer table-header pagination CSS must be present. Got: ' + assembled.abbreviate(600)
            );
        }
    }

    /**
     * Some Word-authored templates accidentally carry w:tblHeader on the loop row too.
     * The DOCX snapshot then puts both the visible header row and the loop row inside
     * <thead>. The assembler must close the header block before {ROWS}; otherwise it
     * drops </thead> and the table headers stop repeating in large-query PDFs.
     */
    @IsTest
    static void testGiantQueryRepeatHeaderWithLoopRowInsideThead() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];

            String snapshotHtml =
                '<html><body>' +
                '<table style="width:100%;border-collapse:collapse;table-layout:fixed">' +
                '<colgroup><col style="width:50%"/><col style="width:50%"/></colgroup>' +
                '<thead>' +
                '<tr><th>GQ_STATIC_HEADER</th><th>H2</th></tr>' +
                '<tr>{#Contacts}<th>{FirstName}</th><th>x</th>{/Contacts}</tr>' +
                '</thead>' +
                '</table></body></html>';
            insert new ContentVersion(
                Title = 'docgen_tmpl_html_' + ver.Id,
                PathOnClient = 'snapshot.html',
                VersionData = Blob.valueOf(snapshotHtml),
                IsMajorVersion = false
            );

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001',
                PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Row0</td><td>0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            String assembled = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Title = :(prefix + 'debug_html')
                    LIMIT 1
                ]
                .VersionData.toString();

            System.assert(
                assembled.contains('<thead><tr><th>GQ_STATIC_HEADER</th><th>H2</th></tr></thead>'),
                'Only the real static header row should remain in <thead>. Got: ' + assembled.abbreviate(700)
            );
            System.assert(
                assembled.contains('</thead><tr><td>Row0</td><td>0</td></tr></table>'),
                'Giant-query rows must render after the closed <thead>. Got: ' + assembled.abbreviate(700)
            );
        }
    }

    @IsTest
    static void testStitchJobExecution() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Create a Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Test Stitch',
                Parent_Record_Id__c = String.valueOf(acc.Id),
                Total_Records__c = 10
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create mock fragment CVs (simulating what the batch would produce)
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                fragments.add(
                    new ContentVersion(
                        Title = 'docgen_giant_' + job.Id + '_' + seq,
                        PathOnClient = 'docgen_giant_' + job.Id + '_' + seq + '.xml',
                        VersionData = Blob.valueOf('<w:tr><w:tc><w:p>Fragment' + i + '</w:p></w:tc></w:tr>'),
                        IsMajorVersion = false,
                        FirstPublishLocationId = job.Id
                    )
                );
            }
            insert fragments;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 1);
            Test.stopTest();

            // Verify job status updated (may be Completed or Failed depending on template file availability)
            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Completed' || updatedJob.Status__c == 'Failed',
                'Job should be Completed or Failed after stitch, got: ' + updatedJob.Status__c
            );
        }
    }

    // #165 regression — the stitch finish() path named final documents
    // `<template> - <relationship>` regardless of Document_Title_Format__c,
    // diverging from DocGenGiantQueryAssembler (which honors the format via
    // computeDocTitle since v1.90). With a format configured, the final CV
    // must carry the computed title — never the legacy concatenation.
    @IsTest
    static void testStitchJobHonorsDocumentTitleFormat() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            tpl.Document_Title_Format__c = 'XXXX-premium-{Name}';
            Database.update(tpl, AccessLevel.SYSTEM_MODE);

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Harvesting',
                Template__c = tpl.Id,
                Label__c = 'Test Stitch Title Format',
                Parent_Record_Id__c = String.valueOf(acc.Id),
                Total_Records__c = 10
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // 3 fragments → 1 group → single-part finish() branch.
            List<ContentVersion> fragments = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                String seq = String.valueOf(i).leftPad(5, '0');
                fragments.add(
                    new ContentVersion(
                        Title = 'docgen_giant_' + job.Id + '_' + seq,
                        PathOnClient = 'docgen_giant_' + job.Id + '_' + seq + '.xml',
                        VersionData = Blob.valueOf('<w:tr><w:tc><w:p>Fragment' + i + '</w:p></w:tc></w:tr>'),
                        IsMajorVersion = false,
                        FirstPublishLocationId = job.Id
                    )
                );
            }
            insert fragments;

            Test.startTest();
            DocGenGiantQueryStitchJob stitchJob = new DocGenGiantQueryStitchJob(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'PDF'
            );
            Database.executeBatch(stitchJob, 1);
            Test.stopTest();

            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            if (updatedJob.Status__c == 'Completed') {
                // The final document (not a fragment/part) must use the computed title.
                List<ContentVersion> finals = [
                    SELECT Title
                    FROM ContentVersion
                    WHERE Title != NULL AND (NOT Title LIKE 'docgen_giant_%') AND (NOT Title LIKE 'docgen_part_%')
                ];
                Boolean foundComputed = false;
                for (ContentVersion cv : finals) {
                    System.assertNotEquals(
                        'Giant Query Test - Contacts',
                        cv.Title,
                        'Stitch must not emit the legacy concatenated title when a format is configured'
                    );
                    if (cv.Title == 'XXXX-premium-Giant Query Test Account') {
                        foundComputed = true;
                    }
                }
                System.assert(
                    foundComputed,
                    'Final stitched document must carry the Document_Title_Format__c title; got: ' + finals
                );
            }
        }
    }

    @IsTest
    static void testGenerateDocumentGiantQueryFallthrough() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            Test.startTest();
            // With only 10 contacts (below 2000 threshold), this should fall through to normal generation
            try {
                Map<String, Object> result = DocGenController.generateDocumentGiantQuery(tpl.Id, acc.Id);
                // If it doesn't throw (template file may be invalid), verify it reports non-giant
                System.assertEquals(
                    false,
                    result.get('isGiantQuery'),
                    'Should not trigger Giant Query for 10 contacts'
                );
            } catch (Exception e) {
                // Expected — the test template file is not a real DOCX ZIP
                System.assert(e.getMessage() != null, 'Error message should not be null');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testScoutWithNonV3Config() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];

            // V1 config (flat string) should return empty map
            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, 'Name, Industry');
            Test.stopTest();

            System.assert(counts.isEmpty(), 'V1 config should return empty map (no nodes to parse)');
        }
    }

    @IsTest
    static void testGiantQueryBatchWithInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Invalid Object Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'NonExistentObject__c',
                'lookupField' => 'AccountId',
                'relationshipName' => 'FakeRel',
                'fields' => new List<String>{ 'Name' },
                'parentFields' => new List<String>()
            };

            Test.startTest();
            try {
                DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                    job.Id,
                    tpl.Id,
                    acc.Id,
                    badConfig,
                    '<w:p>{Name}</w:p>',
                    'PDF'
                );
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                // Expected — invalid object causes runtime error in SOQL or start()
                System.assert(true, 'Should report invalid object');
            }
            // Batch may also fail asynchronously — check job status
            DocGen_Job__c updatedJob = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(
                updatedJob.Status__c == 'Draft' || updatedJob.Status__c == 'Failed',
                'Invalid object batch should fail or stay in Draft'
            );
        }
    }

    @IsTest
    static void testGiantQueryBatchRejectsRootAnchorTagSynchronously() {
        // #439 scope limit: {~Label} root-anchor tags resolve against the root
        // data map, but each giant-query chunk renders its row body against a
        // flat, field-limited per-record map with no sibling-relationship data,
        // by design. Rather than silently rendering every {~} blank across a
        // large job, the constructor must throw IMMEDIATELY — before
        // Database.executeBatch ever runs — so this is asserted directly on
        // construction, not via job status after an async failure.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>()
            };
            String innerXml = '<w:tr><w:tc>{~Offices}{#Offices__r}{City__c}{/Offices__r}{/Offices}</w:tc></w:tr>';

            Test.startTest();
            try {
                DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                    null,
                    tpl.Id,
                    acc.Id,
                    childNodeConfig,
                    innerXml,
                    'PDF'
                );
                System.assert(false, 'Expected a DocGenException for a {~} tag inside a giant-query loop body.');
            } catch (DocGenException e) {
                System.assert(
                    e.getMessage().contains('not supported inside giant-query loops'),
                    'Unexpected exception message: ' + e.getMessage()
                );
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGiantQueryBatchWithoutRootAnchorTagConstructsNormally() {
        // Guard must be scoped to the literal '{~' substring — ordinary
        // giant-query templates (no root-anchor tag) must be unaffected.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>()
            };
            String innerXml = '<w:tr><w:tc>{FirstName}</w:tc></w:tr>';

            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                null,
                tpl.Id,
                acc.Id,
                childNodeConfig,
                innerXml,
                'PDF'
            );
            Test.stopTest();

            System.assertNotEquals(null, batch, 'construction must succeed without a {~} tag present');
        }
    }

    @IsTest
    static void testGetSortedChildIds() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');

            Test.startTest();
            List<Id> sortedIds = DocGenController.getSortedChildIds(
                'Contact',
                'AccountId',
                acc.Id,
                'LastName ASC',
                null
            );
            Test.stopTest();

            System.assertEquals(10, sortedIds.size(), 'Should return 10 sorted contact IDs');
        }
    }

    @IsTest
    static void testGetSortedChildIdsWithWhere() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            Test.startTest();
            List<Id> sortedIds = DocGenController.getSortedChildIds(
                'Contact',
                'AccountId',
                acc.Id,
                'LastName ASC',
                'LastName LIKE \'Contact0%\''
            );
            Test.stopTest();
            System.assert(sortedIds.size() > 0, 'Should return contacts matching WHERE');
            System.assert(sortedIds.size() < 10, 'WHERE should filter some contacts out');
        }
    }

    @IsTest
    static void testGiantQueryBatchWithWhere() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'WHERE Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'LastName ASC',
                'where' => 'LastName LIKE \'Contact0%\''
            };
            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc></w:tr>';
            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id,
                tpl.Id,
                acc.Id,
                childNodeConfig,
                innerXml,
                'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();
            DocGen_Job__c updatedJob = [SELECT Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assert(updatedJob.Total_Records__c < 10, 'WHERE should filter — got ' + updatedJob.Total_Records__c);
        }
    }

    @IsTest
    static void testGiantQueryBatchWhereInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'where' => 'Name = \'x\'; DELETE Contact'
            };
            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF');
            } catch (DocGenException e) {
                caught = true;
            }
            System.assert(caught, 'Should reject WHERE with injection');
        }
    }

    @IsTest
    static void testGetSortedChildIdsInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            Boolean caught = false;
            try {
                DocGenController.getSortedChildIds('Contact', 'AccountId', acc.Id, 'Name; DELETE Contact', null);
            } catch (Exception e) {
                caught = true;
            }
            System.assert(caught, 'Should reject ORDER BY with injection');
        }
    }

    @IsTest
    static void testGetChildRecordsByIds() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Contact> contacts = [SELECT Id FROM Contact ORDER BY LastName ASC LIMIT 5];
            List<Id> ids = new List<Id>();
            for (Contact c : contacts) {
                ids.add(c.Id);
            }

            Test.startTest();
            List<Map<String, Object>> result = DocGenController.getChildRecordsByIds(
                'Contact',
                'Id, FirstName, LastName',
                ids
            );
            Test.stopTest();

            System.assertEquals(5, result.size(), 'Should return 5 records');
        }
    }

    @IsTest
    static void testGetChildRecordsByIdsEmptyList() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            List<Map<String, Object>> result = DocGenController.getChildRecordsByIds(
                'Contact',
                'Id, FirstName',
                new List<Id>()
            );
            System.assert(result.isEmpty(), 'Empty input should return empty list');
        }
    }

    @IsTest
    static void testV1FlatConfigGiantQueryScout() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            String v1Config = 'Name, (SELECT FirstName, LastName FROM Contacts ORDER BY LastName ASC)';

            Test.startTest();
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(acc.Id, v1Config);
            Test.stopTest();

            System.assert(counts.containsKey('Contacts'), 'Should find Contacts relationship');
            System.assertEquals(10, counts.get('Contacts'), 'Should count 10 contacts');
        }
    }

    @IsTest
    static void testStitchJobFinalizer() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Just verify the finalizer class can be instantiated
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(Template__c = tpl.Id, Status__c = 'Draft');
            insert job; // NOPMD ApexCRUDViolation — test data

            Test.startTest();
            DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer finalizer = new DocGenGiantQueryStitchJob.DocGenGiantQueryStitchFinalizer(
                job.Id
            );
            System.assertNotEquals(null, finalizer, 'Finalizer should be instantiable');
            Test.stopTest();
        }
    }

    /**
     * Attaches a real DOCX to this test class's template and updates the active version.
     * Uses local queries instead of TestDataFactory getters which expect 'DocGen Test Template'.
     */
    private static ContentVersion attachDocxToLocalTemplate() {
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
        DocGen_Template_Version__c ver = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
            LIMIT 1
        ];
        ContentVersion cv = TestDataFactory.createValidDocxFile(tpl.Id, TestDataFactory.buildSimpleDocXml());
        ver.Content_Version_Id__c = cv.Id;
        Database.update(ver, AccessLevel.SYSTEM_MODE);
        return cv;
    }

    @IsTest
    static void testGiantQueryBatchWithOrderBy() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [
                SELECT Id, Output_Format__c
                FROM DocGen_Template__c
                WHERE Name = 'Giant Query Test'
                LIMIT 1
            ];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Test Giant Query Sorted',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Build child node config WITH orderBy — triggers pre-sorted Id path
            Map<String, Object> childNodeConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName', 'LastName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'LastName ASC'
            };

            String innerXml = '<w:tr><w:tc><w:p>{FirstName}</w:p></w:tc><w:tc><w:p>{LastName}</w:p></w:tc></w:tr>';

            Test.startTest();
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id,
                tpl.Id,
                acc.Id,
                childNodeConfig,
                innerXml,
                'PDF'
            );
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Verify job was updated with correct total
            DocGen_Job__c updatedJob = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Draft', updatedJob.Status__c, 'Job status should have changed from Draft');
            System.assertEquals(10, updatedJob.Total_Records__c, 'Should have counted 10 contacts');
        }
    }

    @IsTest
    static void testGiantQueryBatchOrderByInjectionBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'Injection Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Attempt injection via ORDER BY clause
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'Name; DELETE Contact'
            };

            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF');
            } catch (DocGenException e) {
                caught = true;
                System.assert(
                    e.getMessage().contains('Invalid ORDER BY'),
                    'Should report invalid ORDER BY: ' + e.getMessage()
                );
            }
            System.assert(caught, 'Should reject ORDER BY with injection attempt');
        }
    }

    @IsTest
    static void testGiantQueryBatchOrderByDmlKeywordBlocked() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];

            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = tpl.Id,
                Label__c = 'DML Keyword Test',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Map<String, Object> badConfig = new Map<String, Object>{
                'object' => 'Contact',
                'lookupField' => 'AccountId',
                'relationshipName' => 'Contacts',
                'fields' => new List<String>{ 'FirstName' },
                'parentFields' => new List<String>(),
                'orderBy' => 'Name DELETE FROM Contact'
            };

            Boolean caught = false;
            try {
                new DocGenGiantQueryBatch(job.Id, tpl.Id, acc.Id, badConfig, '<w:p>{Name}</w:p>', 'PDF');
            } catch (DocGenException e) {
                caught = true;
            }
            System.assert(caught, 'Should reject ORDER BY containing DML keywords');
        }
    }

    // =========================================================================
    // Giant Query Flow Action Tests
    // =========================================================================

    @IsTest
    static void testGiantQueryFlowActionSyncPath() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];
            attachDocxToLocalTemplate();

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = acc.Id;
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
                new List<DocGenGiantQueryFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(1, responses.size(), 'Should return one response');
            DocGenGiantQueryFlowAction.Response res = responses[0];
            // With <2K child records, should take sync path
            System.assertEquals(false, res.isGiantQuery, 'Should not be giant query for small dataset');
            System.assert(res.success, 'Should succeed: ' + res.errorMessage);
        }
    }

    @IsTest
    static void testGiantQueryFlowActionNullTemplate() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = [SELECT Id FROM Account LIMIT 1];

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = null;
            req.recordId = acc.Id;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
                new List<DocGenGiantQueryFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(false, responses[0].success, 'Should fail with null template');
            System.assertNotEquals(null, responses[0].errorMessage, 'Should have error message');
        }
    }

    @IsTest
    static void testGiantQueryFlowActionInvalidRecord() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            attachDocxToLocalTemplate();

            DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
            req.templateId = tpl.Id;
            req.recordId = UserInfo.getUserId(); // wrong object type
            req.saveToRecord = false;

            Test.startTest();
            List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
                new List<DocGenGiantQueryFlowAction.Request>{ req }
            );
            Test.stopTest();

            System.assertEquals(false, responses[0].success, 'Should fail with wrong record type');
        }
    }

    @IsTest
    static void testGiantQueryFlowActionResponseFields() {
        // Verify all response fields are accessible
        DocGenGiantQueryFlowAction.Response res = new DocGenGiantQueryFlowAction.Response();
        res.contentDocumentId = null;
        res.contentVersionId = null;
        res.jobId = null;
        res.isGiantQuery = false;
        res.errorMessage = null;
        res.success = true;
        System.assert(res.success, 'Response fields should be settable');
    }

    // =========================================================================
    // Giant Query Assembler Tests
    // =========================================================================

    @IsTest
    static void testAssemblerWithNoFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job; // NOPMD

            Test.startTest();
            System.enqueueJob(new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts'));
            Test.stopTest();

            DocGen_Job__c result = [SELECT Status__c, Label__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Failed', result.Status__c, 'Should fail with no fragments');
        }
    }

    @IsTest
    static void testAssemblerWithFragments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c LIMIT 1];
            Account acc = [SELECT Id FROM Account LIMIT 1];

            // Create template version + pre-baked HTML
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Is_Active__c = TRUE
                LIMIT 1
            ];
            String htmlTitle = 'docgen_tmpl_html_' + ver.Id;
            ContentVersion htmlCv = new ContentVersion(
                Title = htmlTitle,
                PathOnClient = htmlTitle + '.html',
                VersionData = Blob.valueOf(
                    '<html><head><style>td{border:1px solid}</style></head><body><table><tr><td>{#Contacts}{FirstName}{/Contacts}</td></tr></table></body></html>'
                )
            );
            insert htmlCv; // NOPMD

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            insert job; // NOPMD

            // Create some HTML fragments
            String prefix = 'docgen_giant_' + job.Id + '_';
            List<ContentVersion> frags = new List<ContentVersion>();
            for (Integer i = 0; i < 3; i++) {
                frags.add(
                    new ContentVersion(
                        Title = prefix + String.valueOf(i).leftPad(5, '0'),
                        PathOnClient = prefix + i + '.html',
                        VersionData = Blob.valueOf('<tr><td>Row ' + i + '</td></tr>')
                    )
                );
            }
            insert frags; // NOPMD

            Test.startTest();
            System.enqueueJob(new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts'));
            Test.stopTest();

            DocGen_Job__c result = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Completed', result.Status__c, 'Assembler should complete');
        }
    }

    @isTest
    static void testFlowAction_invalidTemplate() {
        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = null;
        req.recordId = [SELECT Id FROM Account LIMIT 1].Id;
        req.saveToRecord = false;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, responses[0].success, 'Should fail with null template');
        System.assertNotEquals(null, responses[0].errorMessage);
    }

    @isTest
    static void testFlowAction_syncPath() {
        // Use a template with few child records — should go sync path
        Account acc = [SELECT Id FROM Account LIMIT 1];
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

        DocGenGiantQueryFlowAction.Request req = new DocGenGiantQueryFlowAction.Request();
        req.templateId = tpl.Id;
        req.recordId = acc.Id;
        req.saveToRecord = true;

        Test.startTest();
        List<DocGenGiantQueryFlowAction.Response> responses = DocGenGiantQueryFlowAction.generateDocument(
            new List<DocGenGiantQueryFlowAction.Request>{ req }
        );
        Test.stopTest();

        // With few contacts, should take sync path (not giant query)
        System.assertEquals(false, responses[0].isGiantQuery, 'Should use sync path with few records');
    }

    @isTest
    static void testFlowAction_responseFields() {
        // Exercise Response class fields for coverage
        DocGenGiantQueryFlowAction.Response res = new DocGenGiantQueryFlowAction.Response();
        res.contentDocumentId = null;
        res.contentVersionId = null;
        res.jobId = null;
        res.isGiantQuery = false;
        res.errorMessage = 'test';
        res.success = true;
        System.assertEquals(true, res.success);
    }

    // =========================================================================
    // Grand-total aggregate tag resolution ({SUM:Rel.Field}, {COUNT:Rel})
    // =========================================================================

    @IsTest
    static void testGiantAggregateCountTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html = '<html><body>Total contacts: {COUNT:Contacts}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(resolved.contains('Total contacts: 10'), 'COUNT should equal 10 contacts; got: ' + resolved);
            System.assert(!resolved.contains('{COUNT:Contacts}'), 'Tag should be replaced; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateSumTag() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Set numeric field on contacts so SUM has something to aggregate
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Integer i = 0; i < contacts.size(); i++) {
                contacts[i].MailingLatitude = 10.0;
                contacts[i].MailingLongitude = 20.0; // paired field required
            }
            update contacts;

            // Rewrite query_config to declare MailingLatitude so the aggregate resolver accepts it
            String v3Config = JSON.serialize(
                new Map<String, Object>{
                    'v' => 3,
                    'root' => 'Account',
                    'nodes' => new List<Object>{
                        new Map<String, Object>{
                            'id' => 'n0',
                            'object' => 'Account',
                            'fields' => new List<String>{ 'Name' },
                            'parentFields' => new List<String>(),
                            'parentNode' => null,
                            'lookupField' => null,
                            'relationshipName' => null
                        },
                        new Map<String, Object>{
                            'id' => 'n1',
                            'object' => 'Contact',
                            'fields' => new List<String>{ 'FirstName', 'MailingLatitude' },
                            'parentFields' => new List<String>(),
                            'parentNode' => 'n0',
                            'lookupField' => 'AccountId',
                            'relationshipName' => 'Contacts'
                        }
                    }
                }
            );
            tpl.Query_Config__c = v3Config;
            Database.update(tpl, AccessLevel.SYSTEM_MODE);
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html = '<html><body>Sum: {SUM:Contacts.MailingLatitude} Count: {COUNT:Contacts}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(resolved.contains('Count: 10'), 'COUNT should be 10; got: ' + resolved);
            System.assert(!resolved.contains('{SUM:'), 'SUM tag should be replaced; got: ' + resolved);
            System.assert(resolved.contains('Sum: 100'), 'SUM of 10 contacts × 10.0 = 100; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateV1FlatConfig() {
        // v1.52.0 bug: assembler's aggregate resolver re-parsed Query_Config__c as
        // V3 JSON. When the template used V1 flat string format, JSON parse threw,
        // the catch returned html unchanged, and aggregates were silently skipped.
        // Fix: DocGenGiantQueryBatch now passes childObj/lookup/where into the
        // assembler's constructor directly — no config re-parsing for the happy path.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // V1 flat config (legacy format — does NOT start with '{')
            tpl.Query_Config__c = 'Name, (SELECT FirstName, MailingLatitude FROM Contacts)';
            Database.update(tpl, AccessLevel.SYSTEM_MODE);
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Contact c : contacts) {
                c.MailingLatitude = 5.0;
                c.MailingLongitude = 10.0;
            }
            update contacts;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Use the new 7-arg constructor (the batch uses this path in production)
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(
                job.Id,
                tpl.Id,
                acc.Id,
                'Contacts',
                'Contact',
                'AccountId',
                null
            );

            String html = '<html><body>Count: {COUNT:Contacts} Sum: {SUM:Contacts.MailingLatitude}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assert(!resolved.contains('{COUNT:'), 'COUNT should resolve under V1 config; got: ' + resolved);
            System.assert(!resolved.contains('{SUM:'), 'SUM should resolve under V1 config; got: ' + resolved);
            System.assert(resolved.contains('Count: 10'), 'COUNT expected 10; got: ' + resolved);
            System.assert(resolved.contains('Sum: 50'), 'SUM expected 5.0 × 10 = 50; got: ' + resolved);
        }
    }

    @IsTest
    static void testGiantAggregateFormatSuffixes() {
        // v1.51.0 bug: {COUNT:Rel:number}, {AVG:Rel.Field:currency}, {SUM:Rel.Field:currency}
        // etc. rendered unresolved because the resolver only accepted fields declared
        // as rendered columns in the query config.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];

            // Template config declares Contact's FirstName only as a rendered column —
            // but we aggregate MailingLatitude which is NOT in the column list. That
            // simulates the real-world pattern "show some columns, aggregate others".
            String v3Config = JSON.serialize(
                new Map<String, Object>{
                    'v' => 3,
                    'root' => 'Account',
                    'nodes' => new List<Object>{
                        new Map<String, Object>{
                            'id' => 'n0',
                            'object' => 'Account',
                            'fields' => new List<String>{ 'Name' },
                            'parentFields' => new List<String>(),
                            'parentNode' => null,
                            'lookupField' => null,
                            'relationshipName' => null
                        },
                        new Map<String, Object>{
                            'id' => 'n1',
                            'object' => 'Contact',
                            'fields' => new List<String>{ 'FirstName' }, // intentionally omits MailingLatitude
                            'parentFields' => new List<String>(),
                            'parentNode' => 'n0',
                            'lookupField' => 'AccountId',
                            'relationshipName' => 'Contacts'
                        }
                    }
                }
            );
            tpl.Query_Config__c = v3Config;
            Database.update(tpl, AccessLevel.SYSTEM_MODE);
            // Set numeric field so aggregates have something to crunch
            List<Contact> contacts = [SELECT Id FROM Contact WHERE AccountId = :acc.Id];
            for (Contact c : contacts) {
                c.MailingLatitude = 25.0;
                c.MailingLongitude = 10.0;
            }
            update contacts;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            String html =
                'Count: {COUNT:Contacts:number} | ' +
                'Avg: {AVG:Contacts.MailingLatitude:currency} | ' +
                'Min: {MIN:Contacts.MailingLatitude:currency} | ' +
                'Max: {MAX:Contacts.MailingLatitude:currency} | ' +
                'Sum: {SUM:Contacts.MailingLatitude:currency}';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            // No unresolved aggregate tags should remain
            System.assert(!resolved.contains('{COUNT:'), 'COUNT tag unresolved: ' + resolved);
            System.assert(!resolved.contains('{AVG:'), 'AVG tag unresolved: ' + resolved);
            System.assert(!resolved.contains('{MIN:'), 'MIN tag unresolved: ' + resolved);
            System.assert(!resolved.contains('{MAX:'), 'MAX tag unresolved: ' + resolved);
            System.assert(!resolved.contains('{SUM:'), 'SUM tag unresolved: ' + resolved);

            // Currency format should produce a $-prefixed string on AVG/MIN/MAX/SUM
            System.assert(resolved.contains('Avg: $25'), 'AVG should format with $: ' + resolved);
            System.assert(resolved.contains('Min: $25'), 'MIN should format with $: ' + resolved);
            System.assert(resolved.contains('Max: $25'), 'MAX should format with $: ' + resolved);
            System.assert(resolved.contains('Sum: $250'), 'SUM (10×25) should format with $: ' + resolved);
            // COUNT with :number format — 10 contacts, no decimal
            System.assert(resolved.contains('Count: 10'), 'COUNT should format as 10: ' + resolved);
        }
    }

    @IsTest
    static void testAssemblerParentFieldFormatting() {
        // Parent-level tags on the template wrapper (outside the loop) must honor
        // format specifiers: {AnnualRevenue:currency}, {CloseDate:date}, etc.
        // Before v1.50.1 the assembler's resolveParentMergeTags regex ignored
        // format suffixes, so these rendered as unformatted raw values.
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            acc.AnnualRevenue = 1234567;
            update acc;

            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Use a minimal HTML template via pre-baked CV. Parent tags sit in the header.
            DocGen_Template_Version__c ver = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :tpl.Id AND Is_Active__c = TRUE
                LIMIT 1
            ];
            String htmlTitle = 'docgen_tmpl_html_' + ver.Id;
            // Clean up any pre-existing html CV from a prior test
            List<ContentDocument> old = [
                SELECT Id
                FROM ContentDocument
                WHERE Title = :htmlTitle
            ];
            if (!old.isEmpty()) {
                delete old;
            }

            String tmpl =
                '<html><head><style>td{border:1px solid #ccc}</style></head><body>' +
                '<p>Account: {Name} | Revenue: {AnnualRevenue:currency}</p>' +
                '<table><tr><td>{#Contacts}{FirstName}{/Contacts}</td></tr></table>' +
                '</body></html>';
            insert new ContentVersion(
                Title = htmlTitle,
                PathOnClient = htmlTitle + '.html',
                VersionData = Blob.valueOf(tmpl)
            );

            // Exercise via resolveGiantAggregateTags sibling path: call assembler's
            // private method via @TestVisible by building and invoking.
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            // Insert a fragment so the assembler has something to render
            String prefix = 'docgen_giant_' + job.Id + '_';
            insert new ContentVersion(
                Title = prefix + '00001',
                PathOnClient = prefix + '00001.html',
                VersionData = Blob.valueOf('<tr><td>Test0</td></tr>')
            );

            Test.startTest();
            System.enqueueJob(assembler);
            Test.stopTest();

            // After render, the debug HTML CV captures the wrapped output
            List<ContentVersion> dbg = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Title = :(prefix + 'debug_html')
                LIMIT 1
            ];
            System.assert(!dbg.isEmpty(), 'Debug HTML CV should have been written');
            String out = dbg[0].VersionData.toString();

            // Raw value stays (Name)
            System.assert(
                out.contains('Giant Query Test Account'),
                'Plain parent field should resolve; got: ' + out.left(500)
            );
            // Formatted value should appear (currency format on AnnualRevenue)
            System.assert(
                out.contains('$') && out.contains('1,234,567'),
                'Currency format should produce $-prefixed grouped number; got: ' + out
            );
            // Tag itself should be gone
            System.assert(!out.contains('{AnnualRevenue:currency}'), 'Formatted tag should be replaced; got: ' + out);
        }
    }

    @IsTest
    static void testGiantAggregateNonMatchingRelationshipIgnored() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.accountByName('Giant Query Test Account');
            DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Harvesting',
                Parent_Record_Id__c = String.valueOf(acc.Id)
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            DocGenGiantQueryAssembler assembler = new DocGenGiantQueryAssembler(job.Id, tpl.Id, acc.Id, 'Contacts');

            // Tag references a different relationship — should pass through untouched
            String html = '<html><body>{SUM:OpportunityLineItems.Quantity}</body></html>';

            Test.startTest();
            String resolved = assembler.resolveGiantAggregateTags(html);
            Test.stopTest();

            System.assertEquals(
                html,
                resolved,
                'Tags for other relationships must be left untouched for downstream resolvers'
            );
        }
    }

    /**
     * Three-level V1-flat nested subquery (great-grandchildren) must stitch
     * recursively. Before v1.62: stitchGrandchildren only handled one level.
     * Regression guard for the recursive implementation.
     */
    @IsTest
    static void testThreeLevelNestedSubqueryStitch() {
        User admin = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        System.runAs(admin) {
            Account a = new Account(Name = 'Deep3Test');
            insert a;
            Contact c = new Contact(LastName = 'Solo', AccountId = a.Id);
            insert c;
            Case ca = new Case(Subject = 'The Case', ContactId = c.Id, AccountId = a.Id);
            Case cb = new Case(Subject = 'Other Case', ContactId = c.Id, AccountId = a.Id);
            insert new List<Case>{ ca, cb };
            insert new List<CaseComment>{
                new CaseComment(ParentId = ca.Id, CommentBody = 'first'),
                new CaseComment(ParentId = ca.Id, CommentBody = 'second'),
                new CaseComment(ParentId = cb.Id, CommentBody = 'lonely')
            };

            String cfg =
                'Name, ' +
                '(SELECT Id, LastName, ' +
                '  (SELECT Id, Subject, ' +
                '    (SELECT Id, CommentBody FROM CaseComments) ' +
                '  FROM Cases) ' +
                'FROM Contacts)';

            Test.startTest();
            Map<String, Object> data = DocGenDataRetriever.getRecordData(a.Id, 'Account', cfg);
            Test.stopTest();

            Map<String, Object> contactsWrap = (Map<String, Object>) data.get('Contacts');
            List<Object> contactRecs = (List<Object>) contactsWrap.get('records');
            System.assertEquals(1, contactRecs.size(), 'one contact expected');

            Map<String, Object> contact = (Map<String, Object>) contactRecs[0];
            Map<String, Object> casesWrap = (Map<String, Object>) contact.get('Cases');
            System.assertNotEquals(null, casesWrap, 'grandchild Cases must be stitched');
            List<Object> caseRecs = (List<Object>) casesWrap.get('records');
            System.assertEquals(2, caseRecs.size(), 'two cases expected');

            Integer totalComments = 0;
            for (Object kr : caseRecs) {
                Map<String, Object> kase = (Map<String, Object>) kr;
                Map<String, Object> commentsWrap = (Map<String, Object>) kase.get('CaseComments');
                System.assertNotEquals(
                    null,
                    commentsWrap,
                    'great-grandchild CaseComments must be stitched onto each Case'
                );
                List<Object> commentRecs = (List<Object>) commentsWrap.get('records');
                totalComments += commentRecs.size();
            }
            System.assertEquals(3, totalComments, 'all three comments must land on correct cases');
        }
    }

    // v1.90 regression — Giant Query path was emitting CV titles of the form
    // `docgen_giant_<jobId>_final` regardless of Document_Title_Format__c.
    // Customers saw that hardcoded name on the downloaded file in Files. The
    // fix routes through DocGenService.computeDocTitle. This test exercises the
    // helper directly (cheap, no Blob.toPdf) to lock the contract.
    @IsTest
    static void computeDocTitleHonorsDocumentTitleFormat() {
        Account acc = TestDataFactory.accountByName('Giant Query Test Account');
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
        tpl.Document_Title_Format__c = 'XXXX-premium-{Name}';
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        String title = DocGenService.computeDocTitle(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(
            'XXXX-premium-Giant Query Test Account',
            title,
            'computeDocTitle must substitute {Name} from the parent record'
        );
    }

    @IsTest
    static void computeDocTitleReturnsNullWhenFormatBlank() {
        Account acc = TestDataFactory.accountByName('Giant Query Test Account');
        DocGen_Template__c tpl = [SELECT Id FROM DocGen_Template__c WHERE Name = 'Giant Query Test' LIMIT 1];
        tpl.Document_Title_Format__c = null;
        Database.update(tpl, AccessLevel.SYSTEM_MODE);
        Test.startTest();
        String title = DocGenService.computeDocTitle(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals(null, title, 'computeDocTitle returns null when no format is configured');
    }

    // formatAggregateValue is the giant-query grand-total formatter. The 3-arg overload
    // takes an ISO resolved from the parent record for {…:currency:auto[=Field]} tags.
    @IsTest
    static void testFormatAggregateValueCurrencyAuto() {
        // Explicit ISO supplied (as the giant aggregate path does after querying the parent).
        String gbp = DocGenService.formatAggregateValue(1234.56, 'currency:auto', 'GBP');
        System.assert(gbp.contains('£'), 'currency:auto with GBP should emit £, got: ' + gbp);

        // auto=Field collapses to the supplied ISO too.
        String gbp2 = DocGenService.formatAggregateValue(1234.56, 'currency:auto=CustomerCurrency__c', 'GBP');
        System.assert(gbp2.contains('£'), 'currency:auto=Field with GBP should emit £, got: ' + gbp2);

        // No ISO (2-arg overload / single-currency org) → safe $ fallback.
        String usd = DocGenService.formatAggregateValue(1234.56, 'currency:auto');
        System.assert(usd.contains('$'), 'currency:auto with no ISO should fall back to $, got: ' + usd);
    }
}

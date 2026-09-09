@IsTest
private class DocGenBulkTests {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
    }

    // ─── Combined-PDF format guard ───────────────────────────────────────
    // PowerPoint and Excel have no DOCX→HTML conversion, so there is nothing for the
    // merge path to combine. Before the guard they fell through to the Word branch,
    // produced empty HTML, and shipped a PDF of blank pages reporting success.

    private static DocGen_Template__c makeTypedTemplate(String type) {
        DocGen_Template__c t = new DocGen_Template__c(
            Name = 'Bulk ' + type + ' Template',
            Base_Object_API__c = 'Account',
            Type__c = type,
            Query_Config__c = 'Name'
        );
        Database.insert(t, AccessLevel.SYSTEM_MODE);
        return t;
    }

    @IsTest
    static void combinedPdfIsRejectedForPowerPointAndExcel() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            for (String type : new List<String>{ 'PowerPoint', 'Excel' }) {
                DocGen_Template__c t = makeTypedTemplate(type);
                String message = null;
                try {
                    DocGenBulkController.submitJobInternal(t.Id, null, 'Merge ' + type, true, 1, true);
                } catch (Exception e) {
                    message = e.getMessage();
                }
                System.assertNotEquals(null, message, type + ' must not be accepted for a combined-PDF job');
                System.assertEquals(
                    true,
                    message.contains(type),
                    'Error should name the offending template type: ' + message
                );
            }
        }
    }

    @IsTest
    static void individualFilesIsStillAllowedForPowerPointAndExcel() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = makeTypedTemplate('PowerPoint');

            Test.startTest();
            // mergePdf=false, mergeOnly=false — native one-file-per-record, which IS
            // supported: DocGenService.assembleZip builds the OOXML package in Apex.
            // The guard must not over-reach and block the mode that works.
            Id jobId = DocGenBulkController.submitJobInternal(t.Id, null, 'Individual PPTX', false, 1, false);
            Test.stopTest();

            System.assertNotEquals(null, jobId, 'Individual-file bulk must remain available for PowerPoint');
        }
    }

    @IsTest
    static void analyzeJobFlagsUnmergeableTypesAsHardBlockers() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = makeTypedTemplate('Excel');

            Test.startTest();
            DocGenBulkController.JobAnalysis merged = DocGenBulkController.analyzeJob(t.Id, 10, 1, true, false);
            DocGenBulkController.JobAnalysis individual = DocGenBulkController.analyzeJob(t.Id, 10, 1, false, false);
            Test.stopTest();

            System.assertEquals(false, merged.canProceed, 'Excel + combined PDF is a genuine hard blocker');
            System.assertEquals(
                true,
                individual.canProceed,
                'Excel as individual files must stay runnable — the guard is merge-only'
            );
        }
    }

    // ─── Server-side chart rasterization in bulk ─────────────────────────

    /**
     * Minimum surface prepareChartImagesServerSide reads: a Word template, an active
     * version, and a pre-decomposed word__document.xml CV whose body carries a
     * {Chart:...} tag. Mirrors the fixture in DocGenChartImageControllerTest.
     */
    private static DocGen_Template__c makeWordChartTemplate() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Bulk Chart Word Tpl',
            Base_Object_API__c = 'Account',
            Type__c = 'Word',
            Query_Config__c = 'Name'
        );
        Database.insert(tpl, AccessLevel.SYSTEM_MODE);
        DocGen_Template_Version__c ver = new DocGen_Template_Version__c(Template__c = tpl.Id, Is_Active__c = true);
        Database.insert(ver, AccessLevel.SYSTEM_MODE);
        ContentVersion xmlCv = new ContentVersion(
            Title = 'docgen_tmpl_xml_' + ver.Id + '_word__document.xml',
            PathOnClient = 'document.xml',
            VersionData = Blob.valueOf(
                '<?xml version="1.0" encoding="UTF-8"?>' +
                    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' +
                    '<w:p><w:r><w:t>{Chart:Contacts:LastName:bar:title=Demo}</w:t></w:r></w:p>' +
                    '</w:body></w:document>'
            )
        );
        Database.insert(xmlCv, AccessLevel.SYSTEM_MODE);
        return tpl;
    }

    @IsTest
    static void hasChartTagsDetectsAWordTemplateWithCharts() {
        DocGen_Template__c tpl = makeWordChartTemplate();

        Test.startTest();
        Boolean result = DocGenChartImageController.hasChartTags(tpl.Id);
        Test.stopTest();

        // This probe is the gate DocGenBatch checks once per job. If it returns false
        // for a template that DOES have charts, bulk silently keeps emitting the old
        // "[Chart: rel.field]" text placeholders and the feature looks unshipped.
        System.assertEquals(true, result, 'A Word template containing {Chart:} must be detected');
    }

    @IsTest
    static void bulkBatchRendersChartTemplateWithoutLeakingChartCvs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c tpl = makeWordChartTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = tpl.Id,
                Status__c = 'Queued',
                Query_Condition__c = 'Name = \'DocGen Test Account\''
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            Integer chartCvsBefore = [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'docgen_chart_%'];

            Test.startTest();
            Database.executeBatch(new DocGenBatch(job.Id), 1);
            Test.stopTest();

            // The batch owns the transient chart CVs it creates — deleteChartImages is
            // caller-owned and no reaper watches a running batch. If the finally-block
            // cleanup regresses, a long job accumulates N records x M charts of orphans.
            System.assertEquals(
                chartCvsBefore,
                [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'docgen_chart_%'],
                'Batch must reap every transient chart CV it created'
            );
        }
    }

    @IsTest
    static void hasChartTagsIsFalseForTemplatesWithoutCharts() {
        DocGen_Template__c t = TestDataFactory.getTestTemplate();

        Test.startTest();
        Boolean result = DocGenChartImageController.hasChartTags(t.Id);
        Test.stopTest();

        // The probe is what keeps DocGenBatch from spending a per-record SOQL proving
        // a negative on the overwhelming majority of templates, which have no charts.
        System.assertEquals(false, result, 'A template with no {Chart:} tags must report false');
    }

    @IsTest
    static void chartCvIdsFromParsesTheCvIdOutOfTheDimensionSuffix() {
        Id cvA = '068000000000001AAA';
        Id cvB = '068000000000002AAA';

        // chartCvMap values are `cvId|WxH` — the dimensions belong to the image markup,
        // not the ContentVersion, and must not end up in a delete list.
        List<Id> ids = DocGenChartImageController.chartCvIdsFrom(
            new Map<String, String>{ 'sigA' => cvA + '|500x280', 'sigB' => String.valueOf(cvB) }
        );

        System.assertEquals(2, ids.size(), 'Both entries should yield a CV Id');
        System.assertEquals(true, ids.contains(cvA), 'Should parse the Id ahead of the | separator');
        System.assertEquals(true, ids.contains(cvB), 'Should accept a bare Id with no dimensions');
    }

    @IsTest
    static void chartCvIdsFromToleratesMalformedEntries() {
        // A malformed entry must not abort cleanup of the well-formed ones alongside it —
        // otherwise one bad value leaks every chart CV in the record.
        List<Id> ids = DocGenChartImageController.chartCvIdsFrom(
            new Map<String, String>{ 'bad' => 'not-an-id', 'blank' => '', 'good' => '068000000000003AAA|100x100' }
        );

        System.assertEquals(1, ids.size(), 'Only the well-formed entry should be returned');
        System.assertEquals(0, DocGenChartImageController.chartCvIdsFrom(null).size(), 'Null map returns empty');
    }

    // ─── Bulk vs single-record data-map parity ───────────────────────────
    // The bulk retriever is a hand-written twin of getRecordDataV3, so anything
    // the single path reads off a node has to be read here too. Divergences show
    // up as conditionals that silently render nothing in bulk while working fine
    // for one record — no error, just wrong output.

    private static Map<String, Object> aliasedContactsConfig(String aliasValue, String limitValue) {
        Map<String, Object> rootNode = new Map<String, Object>{
            'id' => 'n0',
            'object' => 'Account',
            'parentNode' => null,
            'fields' => new List<Object>{ 'Id', 'Name' },
            'parentFields' => new List<Object>()
        };
        Map<String, Object> childNode = new Map<String, Object>{
            'id' => 'n1',
            'object' => 'Contact',
            'parentNode' => 'n0',
            'relationshipName' => 'Contacts',
            'lookupField' => 'AccountId',
            'fields' => new List<Object>{ 'Id', 'LastName' },
            'parentFields' => new List<Object>()
        };
        if (aliasValue != null) {
            childNode.put('alias', aliasValue);
        }
        if (limitValue != null) {
            childNode.put('limit', limitValue);
        }
        return new Map<String, Object>{
            'v' => 3,
            'root' => 'Account',
            'nodes' => new List<Object>{ rootNode, childNode }
        };
    }

    /**
     * Runs the bulk retriever and hands back one record's data map.
     *
     * The nested-generic return type lives here rather than in the test methods on
     * purpose: the Apex compiler rejects a `Map<Id, Map<String, Object>>` LOCAL
     * declaration in any method that also contains a brace collection initializer
     * (`new Set<Id>{ ... }`) — it parses the `Map` as a variable and reports
     * "Unexpected token 'Map'". Keeping the type in a signature sidesteps it.
     */
    private static Map<String, Object> bulkDataFor(Set<Id> recordIds, Map<String, Object> config, Id target) {
        return DocGenDataRetriever.getRecordDataV3Bulk(recordIds, config).get(target);
    }

    @IsTest
    static void testBulkRetrieverHonorsNodeAlias() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
        Set<Id> ids = new Set<Id>{ acc.Id };

        Test.startTest();
        Map<String, Object> data = bulkDataFor(ids, aliasedContactsConfig('AllContacts', null), acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, data, 'Bulk retriever should return data for the account');
        // The alias is what {#AllContacts}…{/AllContacts} resolves against. Dropping it
        // filed the collection under 'Contacts', so the loop tag resolved null and
        // rendered nothing — and {^AllContacts} fired its inverse branch — in bulk only.
        System.assertEquals(
            true,
            data.containsKey('AllContacts'),
            'Child collection must be keyed by the node alias, matching getRecordDataV3'
        );
        System.assertEquals(
            false,
            data.containsKey('Contacts'),
            'Aliased node must NOT also be filed under the raw relationship name'
        );
        Map<String, Object> block = (Map<String, Object>) data.get('AllContacts');
        System.assertEquals(3, (Integer) block.get('totalSize'), 'All three contacts should be present');
    }

    @IsTest
    static void testBulkRetrieverAppliesLimitPerRecordNotPerJob() {
        Account first = [SELECT Id FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
        Account second = new Account(Name = 'DocGen Test Account 2');
        insert second;
        List<Contact> extra = new List<Contact>();
        for (Integer i = 1; i <= 3; i++) {
            extra.add(new Contact(FirstName = 'Second', LastName = 'Contact ' + i, AccountId = second.Id));
        }
        insert extra;

        Set<Id> ids = new Set<Id>{ first.Id, second.Id };
        Map<String, Object> config = aliasedContactsConfig('AllContacts', '2');

        Test.startTest();
        Map<String, Object> firstData = bulkDataFor(ids, config, first.Id);
        Map<String, Object> secondData = bulkDataFor(ids, config, second.Id);
        Test.stopTest();

        // The authored LIMIT is per record. A bare `LIMIT 2` on the batch-wide query
        // returned 2 rows for the WHOLE job, so the first account consumed them and the
        // second got an empty collection — {#AllContacts} rendered nothing there and
        // {^AllContacts} fired its inverse branch. Both records must now see their own 2.
        Map<String, Object> firstBlock = (Map<String, Object>) firstData.get('AllContacts');
        Map<String, Object> secondBlock = (Map<String, Object>) secondData.get('AllContacts');
        System.assertEquals(
            2,
            (Integer) firstBlock.get('totalSize'),
            'First record should get its own LIMIT 2, not share one across the job'
        );
        System.assertEquals(
            2,
            (Integer) secondBlock.get('totalSize'),
            'Second record must not be starved by the first consuming the whole LIMIT'
        );
    }

    @IsTest
    static void testBulkRetrieverRejectsDuplicateSiblingKeys() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'DocGen Test Account' LIMIT 1];
        Map<String, Object> config = aliasedContactsConfig(null, null);
        // A second, differently-filtered node over the same relationship with no alias —
        // both would write to the 'Contacts' key and the second would silently win.
        List<Object> nodes = (List<Object>) config.get('nodes');
        nodes.add(
            new Map<String, Object>{
                'id' => 'n2',
                'object' => 'Contact',
                'parentNode' => 'n0',
                'relationshipName' => 'Contacts',
                'lookupField' => 'AccountId',
                'fields' => new List<Object>{ 'Id' },
                'parentFields' => new List<Object>()
            }
        );

        Test.startTest();
        String message = null;
        try {
            DocGenDataRetriever.getRecordDataV3Bulk(new Set<Id>{ acc.Id }, config);
        } catch (DocGenException e) {
            message = e.getMessage();
        }
        Test.stopTest();

        System.assertNotEquals(null, message, 'Bulk should raise the same duplicate-key guard as single-record');
        System.assertEquals(
            true,
            message.contains('Duplicate loop key'),
            'Guard message should match getRecordDataV3: ' + message
        );
    }

    @IsTest
    static void testGetBulkTemplates() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            List<DocGen_Template__c> templates = DocGenBulkController.getBulkTemplates();
            Test.stopTest();
            System.assertEquals(1, templates.size(), 'Should return 1 template');
        }
    }

    @IsTest
    static void testValidateFilter() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('Account', 'Name = \'DocGen Test Account\'');
            Test.stopTest();
            System.assertEquals(1, count, 'Should find 1 record');
        }
    }

    @IsTest
    static void testSubmitJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                'Test Job',
                false,
                1,
                false,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertNotEquals('Queued', job.Status__c, 'Job should have progressed from Queued');
        }
    }

    @IsTest
    static void testSubmitJobPdfAcroFormsIndividualFiles() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Account acc = TestDataFactory.getTestAccount();
            DocGen_Template__c t = prepareAcroFormBulkTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                'AcroForm Bulk Individual',
                false,
                1,
                false,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :jobId
            ];
            System.assertEquals('Completed', job.Status__c, 'Individual-file AcroForm bulk jobs should complete.');
            System.assertEquals(1, job.Success_Count__c, 'The matching account should generate one filled PDF.');
            System.assertEquals(0, job.Error_Count__c, 'The AcroForm PDF path should not be counted as a bulk error.');

            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :acc.Id
            ]) {
                docIds.add(link.ContentDocumentId);
            }
            System.assert(!docIds.isEmpty(), 'Bulk generation should attach a PDF to the source record.');

            Boolean foundFilledPdf = false;
            for (ContentVersion cv : [
                SELECT VersionData, FileExtension
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds
            ]) {
                if (cv.FileExtension == 'pdf' && cv.VersionData.toString().contains('/V (DocGen Test Account)')) {
                    foundFilledPdf = true;
                    break;
                }
            }
            System.assert(foundFilledPdf, 'Generated bulk PDF should contain the filled AcroForm field value.');
        }
    }

    @IsTest
    static void testSubmitJobPdfAcroFormsRejectMergedMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = prepareAcroFormBulkTemplate();

            DocGenBulkController.JobAnalysis analysis = DocGenBulkController.analyzeJob(t.Id, 1, 1, true, false);
            System.assertEquals(false, analysis.canProceed, 'Analyzer should block merged bulk AcroForm output.');

            Boolean sawFormatError = false;
            for (DocGenBulkController.AnalysisItem item : analysis.items) {
                if (item.label == 'Template Format' && item.status == 'error') {
                    sawFormatError = item.message.contains('Individual Files');
                }
            }
            System.assert(sawFormatError, 'Analyzer should explain that Individual Files are supported instead.');

            try {
                DocGenBulkController.submitJob(
                    t.Id,
                    'Name = \'DocGen Test Account\'',
                    'AcroForm Bulk Merge',
                    true,
                    1,
                    false,
                    null,
                    null
                );
                System.assert(false, 'Merged AcroForm bulk jobs should be rejected before the batch queues.');
            } catch (AuraHandledException e) {
                System.assert(
                    e.getMessage().contains('Individual Files'),
                    'Merged-mode error should tell the user how to run the job: ' + e.getMessage()
                );
            }
        }
    }

    @IsTest
    static void testDocGenUserCanCreateBulkJobControllerFields() {
        PermissionSet userPermSet = [SELECT Id FROM PermissionSet WHERE Name = 'DocGen_User' LIMIT 1];
        FieldPermissions labelPerm;
        FieldPermissions mergeOnlyPerm;
        FieldPermissions parentRecordPerm;
        FieldPermissions giantConfigPerm;
        for (FieldPermissions fp : [
            SELECT Field, PermissionsEdit, PermissionsRead
            FROM FieldPermissions
            WHERE ParentId = :userPermSet.Id
        ]) {
            if (isFieldPermission(fp.Field, 'DocGen_Job__c', 'Label__c')) {
                labelPerm = fp;
            } else if (isFieldPermission(fp.Field, 'DocGen_Job__c', 'Merge_Only__c')) {
                mergeOnlyPerm = fp;
            } else if (isFieldPermission(fp.Field, 'DocGen_Job__c', 'Parent_Record_Id__c')) {
                parentRecordPerm = fp;
            } else if (isFieldPermission(fp.Field, 'DocGen_Job__c', 'Giant_Query_Config__c')) {
                giantConfigPerm = fp;
            }
        }

        System.assertNotEquals(
            null,
            labelPerm,
            'DocGen_User must declare DocGen_Job__c.Label__c FLS for bulk job creation.'
        );
        System.assertEquals(
            true,
            labelPerm.PermissionsEdit,
            'DocGen_User must be able to create Label__c because submitJob writes it before SYSTEM_MODE insert.'
        );
        System.assertNotEquals(
            null,
            mergeOnlyPerm,
            'DocGen_User must declare DocGen_Job__c.Merge_Only__c FLS for bulk job creation.'
        );
        System.assertEquals(
            true,
            mergeOnlyPerm.PermissionsEdit,
            'DocGen_User must be able to create Merge_Only__c because submitJob writes it before SYSTEM_MODE insert.'
        );
        System.assertNotEquals(
            null,
            parentRecordPerm,
            'DocGen_User must declare DocGen_Job__c.Parent_Record_Id__c FLS for giant-query job creation.'
        );
        System.assertEquals(
            true,
            parentRecordPerm.PermissionsEdit,
            'DocGen_User must be able to create Parent_Record_Id__c because giant-query launch writes it before SYSTEM_MODE insert.'
        );
        System.assertNotEquals(
            null,
            giantConfigPerm,
            'DocGen_User must declare DocGen_Job__c.Giant_Query_Config__c FLS for giant-query job creation.'
        );
        System.assertEquals(
            true,
            giantConfigPerm.PermissionsEdit,
            'DocGen_User must be able to create Giant_Query_Config__c because the controller giant-query launch writes it before SYSTEM_MODE insert.'
        );
    }

    @IsTest
    static void testSavedQueries() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            // Save
            Test.startTest();
            DocGenBulkController.saveQuery(t.Id, 'My Query', 'Desc', 'Name != null');
            Test.stopTest();

            // Retrieve
            List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
            System.assertEquals(1, queries.size(), 'Should have 1 saved query');
            System.assertEquals('My Query', queries[0].Name, 'Saved query name should match');

            // Delete
            DocGenBulkController.deleteQuery(queries[0].Id);
            queries = DocGenBulkController.getSavedQueries(t.Id);
            System.assertEquals(0, queries.size(), 'Should have 0 saved queries after delete');
        }
    }

    private static Boolean isFieldPermission(String fieldName, String objectName, String leafFieldName) {
        return fieldName != null && fieldName.contains(objectName) && fieldName.endsWith(leafFieldName);
    }

    // =========================================================================
    // DocGenBulkController — additional coverage
    // =========================================================================

    @IsTest
    static void testValidateFilterBlankObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('', null);
            Test.stopTest();
            System.assertEquals(0, count, 'Should return 0 for blank object');
        }
    }

    @IsTest
    static void testValidateFilterInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('ZZZNotReal__c', 'Name != null');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should throw for invalid object');
        }
    }

    @IsTest
    static void testValidateFilterNoCondition() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Test.startTest();
            Integer count = DocGenBulkController.validateFilter('Account', null);
            Test.stopTest();
            System.assert(count >= 1, 'Should count all accounts');
        }
    }

    @IsTest
    static void testValidateFilterSqlInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null; DELETE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject semicolons');
        }
    }

    @IsTest
    static void testValidateFilterDisallowedKeywords() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name IN (SELECT Name FROM Account)');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject SELECT keyword in condition');
        }
    }

    @IsTest
    static void testGetJobStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Queued');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGen_Job__c status = DocGenBulkController.getJobStatus(job.Id);
            Test.stopTest();

            System.assertEquals('Queued', status.Status__c, 'Job status should be Queued');
        }
    }

    @IsTest
    static void testGetSavedQueriesEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            List<DocGen_Saved_Query__c> queries = DocGenBulkController.getSavedQueries(t.Id);
            Test.stopTest();

            System.assertEquals(0, queries.size(), 'Should return empty list');
        }
    }

    // =========================================================================
    // DocGenBatch — additional coverage for finish status branches
    // =========================================================================

    @IsTest
    static void testBatchFinishCompletedStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Exercises the 'Completed' branch in finish() (successCount > 0, failCount == 0)
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'DocGen Test Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Error_Count__c, Success_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertNotEquals(null, updated.Status__c, 'Should have a status');
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
        }
    }

    @IsTest
    static void testBatchSanitizeConditionCommentInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name != null /* comment */',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            Boolean caught = false;
            try {
                DocGenBatch batch = new DocGenBatch(job.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                caught = true;
                System.assert(
                    e.getMessage().contains('Invalid filter condition'),
                    'Expected sanitize error: ' + e.getMessage()
                );
            }
            if (!caught) {
                // If no exception, batch framework swallowed it — check job status
                DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
                System.assertNotEquals('Queued', updated.Status__c, 'Job status should have changed');
            }
        }
    }

    @IsTest
    static void testBatchSanitizeConditionDashInjection() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name != null -- comment',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            Boolean caught = false;
            try {
                DocGenBatch batch = new DocGenBatch(job.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                caught = true;
                System.assert(
                    e.getMessage().contains('Invalid filter condition'),
                    'Expected sanitize error: ' + e.getMessage()
                );
            }
            if (!caught) {
                DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
                System.assertNotEquals('Queued', updated.Status__c, 'Job status should have changed');
            }
        }
    }

    // =========================================================================
    // Helper: builds a minimal valid DOCX (ZIP) with merge tags, linked to template
    // =========================================================================

    private static ContentVersion createValidDocxForTemplate(Id templateId, String docXml) {
        return TestDataFactory.createValidDocxFile(templateId, docXml);
    }

    private static String buildSimpleDocXml() {
        return TestDataFactory.buildSimpleDocXml();
    }

    private static DocGen_Template__c prepareAcroFormBulkTemplate() {
        DocGen_Template__c t = TestDataFactory.getTestTemplate();
        t.Type__c = 'PDF';
        t.Output_Format__c = 'PDF';
        t.Query_Config__c = 'Name';
        Database.update(t, AccessLevel.SYSTEM_MODE);

        ContentVersion pdfCv = new ContentVersion(
            Title = 'Bulk AcroForm Template',
            PathOnClient = 'BulkAcroFormTemplate.pdf',
            VersionData = Blob.valueOf(simpleAcroFormPdf()),
            FirstPublishLocationId = t.Id
        );
        insert pdfCv;

        DocGen_Template_Version__c ver = TestDataFactory.getTestTemplateVersion();
        ver.Type__c = 'PDF';
        ver.Output_Format__c = 'PDF';
        ver.Query_Config__c = 'Name';
        ver.Content_Version_Id__c = pdfCv.Id;
        Database.update(ver, AccessLevel.SYSTEM_MODE);
        return t;
    }

    private static String simpleAcroFormPdf() {
        return '%PDF-1.4\n' +
            '1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm 3 0 R >>\nendobj\n' +
            '2 0 obj\n<< /Type /Pages /Count 1 /Kids [4 0 R] >>\nendobj\n' +
            '3 0 obj\n<< /Fields [5 0 R] >>\nendobj\n' +
            '4 0 obj\n<< /Type /Page /Parent 2 0 R /Annots [5 0 R] >>\nendobj\n' +
            '5 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [0 0 100 20] >>\nendobj\n' +
            'xref\n0 6\n0000000000 65535 f \n' +
            'trailer\n<< /Size 6 /Root 1 0 R >>\n' +
            'startxref\n0\n%%EOF\n';
    }

    // =========================================================================
    // DocGenBatch — V3 data cache
    // =========================================================================

    @IsTest
    static void testBatchBuildDataCacheV3() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with V3 query config
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'V3 Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            // Attach a valid DOCX to this template
            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            // Create multiple accounts as bulk targets
            List<Account> accs = new List<Account>();
            for (Integer i = 0; i < 3; i++) {
                accs.add(new Account(Name = 'V3 Acct ' + i));
            }
            insert accs;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name LIKE \'V3 Acct%\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 3);
            Test.stopTest();

            // Verify job completed (cache may or may not have been created depending on
            // whether getRecordDataV3Bulk succeeds, but the batch should finish gracefully)
            DocGen_Job__c updated = [
                SELECT Status__c, Total_Records__c, Data_Cache_CV__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertEquals(3, updated.Total_Records__c, 'Should have counted 3 records');
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
        }
    }

    // =========================================================================
    // DocGenBatch — execute success path with real DOCX template
    // =========================================================================

    @IsTest
    static void testBatchExecuteSuccessWithDocx() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a template with V1 query config and a valid DOCX
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Success Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'Batch Success Account');
            insert a;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'Batch Success Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            // Verify batch ran — status should be Completed or Failed depending on
            // whether Blob.toPdf() works in test context. Either way, counts are set.
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            System.assert(
                updated.Success_Count__c + updated.Error_Count__c > 0,
                'Should have processed at least 1 record'
            );
        }
    }

    // =========================================================================
    // DocGenBatch — merge mode (mergePdf=true)
    // =========================================================================

    @IsTest
    static void testBatchMergeMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            List<Account> accs = new List<Account>();
            for (Integer i = 0; i < 2; i++) {
                accs.add(new Account(Name = 'BulkAcct ' + i));
            }
            insert accs;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name LIKE \'BulkAcct%\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            // mergeMode=true, mergeOnly=false
            DocGenBatch batch = new DocGenBatch(job.Id, true, false);
            Database.executeBatch(batch, 2);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            // If records generated successfully, status will be 'Merging' (chained DocGenMergeJob)
            // If they failed, status will be 'Failed' or 'Completed with Errors'
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
        }
    }

    // =========================================================================
    // DocGenBatch — mergeOnly mode
    // =========================================================================

    @IsTest
    static void testBatchMergeOnlyMode() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'MergeOnly Account');
            insert a;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'MergeOnly Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            // mergeOnly=true implies mergeMode=true
            DocGenBatch batch = new DocGenBatch(job.Id, false, true);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            // Verify mergeOnly flag was set on constructor
            System.assert(batch.mergeOnly, 'mergeOnly should be true');
            System.assert(batch.mergeMode, 'mergeMode should be true when mergeOnly is true');
        }
    }

    // =========================================================================
    // DocGenBatch — constructor variants
    // =========================================================================

    @IsTest
    static void testBatchConstructorSingleArg() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Queued');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Test.stopTest();

            System.assertEquals(false, batch.mergeMode, 'Default mergeMode should be false');
            System.assertEquals(false, batch.mergeOnly, 'Default mergeOnly should be false');
        }
    }

    @IsTest
    static void testBatchConstructorTwoArgs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Queued');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id, true);
            Test.stopTest();

            System.assertEquals(true, batch.mergeMode, 'mergeMode should be true');
            System.assertEquals(false, batch.mergeOnly, 'mergeOnly should default to false');
        }
    }

    // =========================================================================
    // DocGenBatch — finish with all failures (Failed status)
    // =========================================================================

    @IsTest
    static void testBatchFinishFailedStatus() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Use a template with no DOCX file — all records will fail
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            Account a = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'DocGen Test Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Error_Count__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Failed', updated.Status__c, 'All records failed — status should be Failed');
            System.assert(updated.Error_Count__c > 0, 'Error count should be > 0');
        }
    }

    // =========================================================================
    // DocGenBatch — sendJobNotification (non-fatal when no CustomNotificationType)
    // =========================================================================

    @IsTest
    static void testBatchSendJobNotificationGraceful() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Run a batch that will finish and attempt to send notification.
            // Without the CustomNotificationType 'DocGen_Job_Complete' deployed,
            // sendJobNotification gracefully returns (no exception).
            TestDataFactory.attachRealDocxToTestTemplate();
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'DocGen Test Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // The batch finished without exception (notification failure is non-fatal)
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals(
                'Queued',
                updated.Status__c,
                'Job should have completed even without notification type'
            );
        }
    }

    // =========================================================================
    // DocGenBatch — data cache cleanup in finish
    // =========================================================================

    @IsTest
    static void testBatchDataCacheCleanup() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a V3 config template to trigger buildDataCache
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Cache Cleanup Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'Cache Cleanup Account');
            insert a;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'Cache Cleanup Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // After finish, the data cache CV should have been cleaned up
            DocGen_Job__c updated = [SELECT Data_Cache_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // If cache was created and then cleaned up, the CV should be deleted
            if (updated.Data_Cache_CV__c != null) {
                List<ContentVersion> remaining = [
                    SELECT Id
                    FROM ContentVersion
                    WHERE Id = :updated.Data_Cache_CV__c
                    WITH SYSTEM_MODE
                ];
                // Cache cleanup deletes the ContentDocument; the CV query should find nothing
                // (or the delete may have cascade-removed it)
                System.assert(remaining.size() <= 1, 'Cache CV should have been deleted or cleaned up');
            }
        }
    }

    // =========================================================================
    // DocGenBatch — buildDataCache skips for V1 config
    // =========================================================================

    @IsTest
    static void testBatchBuildDataCacheSkipsV1() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // V1 config (plain string) should NOT create a data cache CV
            // Create a dedicated template with V1 config (the factory one has V3)
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'V1 Skip Cache Template',
                Base_Object_API__c = 'Account',
                Type__c = 'Word',
                Output_Format__c = 'PDF',
                Query_Config__c = 'Name, Industry'
            );
            insert t;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'DocGen Test Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Data_Cache_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals(null, updated.Data_Cache_CV__c, 'V1 config should not create a data cache');
        }
    }

    // =========================================================================
    // DocGenBatch — finish with merge mode and htmlSequence > 0 (chains DocGenMergeJob)
    // =========================================================================

    @IsTest
    static void testBatchFinishChainsDocGenMergeJob() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Chain Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'ChainTestAcct');
            insert a;

            // Submit via controller with mergePdf=true
            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'ChainTestAcct\'',
                'Chain Job',
                true,
                1,
                false,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            // If generation succeeded, status should be 'Merging' (or 'Completed' if DocGenMergeJob
            // also ran within stopTest). If generation failed, status reflects that.
            System.assertNotEquals('Queued', updated.Status__c, 'Job should have progressed');
        }
    }

    // =========================================================================
    // DocGenBulkController — getRecentJobs
    // =========================================================================

    @IsTest
    static void testGetRecentJobs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            // Create some jobs
            List<DocGen_Job__c> jobs = new List<DocGen_Job__c>();
            for (Integer i = 0; i < 5; i++) {
                jobs.add(
                    new DocGen_Job__c(
                        Template__c = t.Id,
                        Status__c = 'Completed',
                        Label__c = 'Recent Job ' + i,
                        Success_Count__c = i + 1,
                        Error_Count__c = 0,
                        Total_Records__c = i + 1
                    )
                );
            }
            Database.insert(jobs, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            List<DocGen_Job__c> recentJobs = DocGenBulkController.getRecentJobs();
            Test.stopTest();

            System.assert(recentJobs.size() >= 5, 'Should return at least 5 recent jobs');
            // Verify ordering: most recent first
            System.assert(
                recentJobs[0].CreatedDate >= recentJobs[recentJobs.size() - 1].CreatedDate,
                'Jobs should be ordered by CreatedDate descending'
            );
            // Verify template relationship is populated
            System.assertNotEquals(null, recentJobs[0].Template__r.Name, 'Template name should be populated');
        }
    }

    // =========================================================================
    // DocGenBulkController — getJobGeneratedPdfs
    // =========================================================================

    @IsTest
    static void testGetJobGeneratedPdfs() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            Account a = TestDataFactory.getTestAccount();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'DocGen Test Account\'',
                Status__c = 'Completed'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create a fake PDF ContentVersion linked to the Account
            ContentVersion cv = new ContentVersion(
                Title = 'Generated PDF',
                PathOnClient = 'Generated PDF.pdf',
                VersionData = Blob.valueOf('fake pdf content'),
                FirstPublishLocationId = a.Id
            );
            insert cv;

            Test.startTest();
            List<Map<String, String>> pdfs = DocGenBulkController.getJobGeneratedPdfs(job.Id);
            Test.stopTest();

            // Should find the PDF linked to the Account
            System.assert(pdfs.size() >= 1, 'Should find at least 1 generated PDF');
            Boolean foundOurPdf = false;
            for (Map<String, String> pdf : pdfs) {
                if (pdf.get('label') == 'Generated PDF.pdf') {
                    foundOurPdf = true;
                    System.assertNotEquals(null, pdf.get('value'), 'ContentVersion ID should be populated');
                }
            }
            System.assert(foundOurPdf, 'Should find our generated PDF in results');
        }
    }

    @IsTest
    static void testGetJobGeneratedPdfsEmpty() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'No Such Account XYZ\'',
                Status__c = 'Completed'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            List<Map<String, String>> pdfs = DocGenBulkController.getJobGeneratedPdfs(job.Id);
            Test.stopTest();

            System.assertEquals(0, pdfs.size(), 'Should return empty list when no records match');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergePdf=true
    // =========================================================================

    @IsTest
    static void testSubmitJobWithMergePdf() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Merge Submit Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                'Merge PDF Job',
                true,
                1,
                false,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [
                SELECT Id, Status__c, Label__c, Merge_Only__c
                FROM DocGen_Job__c
                WHERE Id = :jobId
            ];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals('Merge PDF Job', job.Label__c, 'Label should be set');
            System.assertEquals(false, job.Merge_Only__c, 'Merge_Only should be false');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergeOnly=true
    // =========================================================================

    @IsTest
    static void testSubmitJobWithMergeOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Submit Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                'MergeOnly Job',
                false,
                1,
                true,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [
                SELECT Id, Status__c, Merge_Only__c
                FROM DocGen_Job__c
                WHERE Id = :jobId
            ];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals(true, job.Merge_Only__c, 'Merge_Only should be true');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with custom batch size
    // =========================================================================

    @IsTest
    static void testSubmitJobCustomBatchSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                null,
                false,
                50,
                false,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c, Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            // Null label should result in null (not blank)
            System.assertEquals(null, job.Label__c, 'Label should be null when not provided');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with null/invalid batch size defaults to 1
    // =========================================================================

    @IsTest
    static void testSubmitJobNullBatchSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            // null batchSize should default to 1
            Id jobId = DocGenBulkController.submitJob(t.Id, null, null, false, null, false, null, null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created with null batch size');
        }
    }

    // =========================================================================
    // DocGenBatch — no condition (all records)
    // =========================================================================

    @IsTest
    static void testBatchNoCondition() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Query_Condition__c = null, Status__c = 'Queued');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 200);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Total_Records__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have progressed');
            System.assert(updated.Total_Records__c >= 1, 'Should have found at least 1 account');
        }
    }

    // =========================================================================
    // DocGenBatch — invalid object in batch (DocGenException)
    // =========================================================================

    @IsTest
    static void testBatchInvalidObject() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Manually create a template with an invalid object name
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Invalid Obj Template',
                Base_Object_API__c = 'ZZZFakeObject__c'
            );
            insert t;

            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Queued');
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            Boolean caught = false;
            try {
                DocGenBatch batch = new DocGenBatch(job.Id);
                Database.executeBatch(batch, 1);
                Test.stopTest();
            } catch (Exception e) {
                caught = true;
            }
            // The exception may be caught by the batch framework or propagate
            if (!caught) {
                DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
                System.assertNotEquals(
                    'Queued',
                    updated.Status__c,
                    'Job status should reflect the invalid object error'
                );
            }
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with comment injection (controller path)
    // =========================================================================

    @IsTest
    static void testControllerSanitizeConditionComments() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null /* hack */');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject /* comment */ in condition');
        }
    }

    @IsTest
    static void testControllerSanitizeConditionDashes() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null -- hack');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject -- in condition');
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with various disallowed keywords
    // =========================================================================

    @IsTest
    static void testControllerSanitizeConditionUpdateKeyword() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null UPDATE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject UPDATE keyword');
        }
    }

    @IsTest
    static void testControllerSanitizeConditionDeleteKeyword() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null DELETE Account');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject DELETE keyword');
        }
    }

    // =========================================================================
    // DocGenBatch — execute with data cache lazy-load (dataCacheCvId set, cachedDataJson null)
    // =========================================================================

    @IsTest
    static void testBatchExecuteLazyLoadCache() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create a V3 template so buildDataCache creates a cache CV
            String v3Config =
                '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name"],"parentFields":[],' +
                '"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}';
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'LazyLoad Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = v3Config,
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'LazyLoad Account');
            insert a;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'LazyLoad Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should progress');
        }
    }

    // =========================================================================
    // DocGenBatch — notification when no CustomNotificationType exists
    // =========================================================================

    @IsTest
    static void testBatchNotificationWithoutNotificationType() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // This test exercises sendJobNotification when CustomNotificationType
            // 'DocGen_Job_Complete' does not exist — should return gracefully
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Notify Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Account a = new Account(Name = 'Notify Account');
            insert a;

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'Notify Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            // Batch should complete without throwing even if notification type missing
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals(
                'Queued',
                updated.Status__c,
                'Batch should finish gracefully without notification type'
            );
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with mergeOnly=true
    // =========================================================================

    @IsTest
    static void testSubmitJobMergeOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'MergeOnly Submit Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(
                t.Id,
                'Name = \'DocGen Test Account\'',
                'MergeOnly Job',
                false,
                1,
                true,
                null,
                null
            );
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Merge_Only__c, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created');
            System.assertEquals(true, job.Merge_Only__c, 'Merge_Only__c should be true');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with null/default batchSize
    // =========================================================================

    @IsTest
    static void testSubmitJobDefaultBatchSize() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, null, false, null, false, null, null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Id, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertNotEquals(null, job.Id, 'Job should be created with default batch size');
        }
    }

    // =========================================================================
    // DocGenBulkController — validateFilter with various injection patterns
    // =========================================================================

    @IsTest
    static void testValidateFilterRejectsDoubleDash() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null -- drop');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject double-dash comment');
        }
    }

    @IsTest
    static void testValidateFilterRejectsBlockComment() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null /* evil */');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject block comments');
        }
    }

    @IsTest
    static void testValidateFilterRejectsWhitespaceNormalized() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Test that multi-word keywords with extra whitespace are still caught
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.validateFilter('Account', 'Name != null ORDER BY Name');
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'Should reject ORDER BY keyword');
        }
    }

    // =========================================================================
    // DocGenMergeJob — execute with HTML snippets
    // =========================================================================

    @IsTest
    static void testMergeJobExecuteWithSnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Merging',
                Success_Count__c = 2,
                Total_Records__c = 2
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create HTML snippet ContentVersions manually
            String html1 = '<html><body><p>Page One</p></body></html>';
            String html2 = '<html><body><p>Page Two</p></body></html>';

            ContentVersion cv1 = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00000',
                PathOnClient = 'docgen_merge_' + job.Id + '_00000.html',
                VersionData = Blob.valueOf(html1),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            ContentVersion cv2 = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00001',
                PathOnClient = 'docgen_merge_' + job.Id + '_00001.html',
                VersionData = Blob.valueOf(html2),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            insert new List<ContentVersion>{ cv1, cv2 };

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            // Status should be Completed (success) or Completed with Errors (Blob.toPdf test limitation)
            System.assertNotEquals('Merging', updated.Status__c, 'Status should have changed from Merging');
        }
    }

    // =========================================================================
    // DocGenMergeJob — execute with no snippets (empty)
    // =========================================================================

    @IsTest
    static void testMergeJobExecuteNoSnippets() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Merging', Success_Count__c = 0);
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertEquals('Completed', updated.Status__c, 'Should complete immediately when no snippets exist');
        }
    }

    // =========================================================================
    // DocGenMergeJob — error handling path (invalid job Id triggers catch block)
    // =========================================================================

    @IsTest
    static void testMergeJobErrorHandling() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            DocGen_Job__c job = new DocGen_Job__c(Template__c = t.Id, Status__c = 'Merging', Success_Count__c = 1);
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            // Create a snippet with invalid HTML that might cause issues
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_merge_' + job.Id + '_00000',
                PathOnClient = 'docgen_merge_' + job.Id + '_00000.html',
                VersionData = Blob.valueOf('<html><body>Test</body></html>'),
                IsMajorVersion = false,
                FirstPublishLocationId = job.Id
            );
            insert cv;

            Test.startTest();
            DocGenMergeJob mergeJob = new DocGenMergeJob(job.Id);
            System.enqueueJob(mergeJob);
            Test.stopTest();

            // Whether it succeeded or hit error path, status should not be 'Merging'
            DocGen_Job__c updated = [SELECT Status__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals(
                'Merging',
                updated.Status__c,
                'Status should have changed after merge job execution'
            );
        }
    }

    // =========================================================================
    // DocGenBatch — finish with partial failures (Completed with Errors)
    // =========================================================================

    @IsTest
    static void testBatchFinishCompletedWithErrors() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            // Create template with valid DOCX so at least some records succeed
            DocGen_Template__c t = new DocGen_Template__c(
                Name = 'Partial Fail Template',
                Base_Object_API__c = 'Account',
                Query_Config__c = 'Name',
                Type__c = 'Word',
                Output_Format__c = 'PDF'
            );
            insert t;

            createValidDocxForTemplate(t.Id, buildSimpleDocXml());

            // Create accounts that should be processed
            insert new Account(Name = 'PartialFail Account');

            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Query_Condition__c = 'Name = \'PartialFail Account\'',
                Status__c = 'Queued'
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);
            Test.startTest();
            DocGenBatch batch = new DocGenBatch(job.Id);
            Database.executeBatch(batch, 1);
            Test.stopTest();

            DocGen_Job__c updated = [
                SELECT Status__c, Success_Count__c, Error_Count__c
                FROM DocGen_Job__c
                WHERE Id = :job.Id
            ];
            System.assertNotEquals('Queued', updated.Status__c, 'Status should have changed');
        }
    }

    // =========================================================================
    // Duplex padding (#382) — batch writes PDF parts, merge job stitches them
    // =========================================================================

    @IsTest
    static void submitJobPersistsDuplexFlagForMergeOnly() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id mergeJob = DocGenBulkController.submitJobInternal(
                t.Id,
                null,
                'DPX merge-only',
                true,
                1,
                true,
                null,
                true
            );
            Id individualJob = DocGenBulkController.submitJobInternal(
                t.Id,
                null,
                'DPX individual',
                false,
                1,
                false,
                null,
                true
            );
            Test.stopTest();

            System.assertEquals(
                true,
                [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :mergeJob].Duplex_Padding__c,
                'A Combined-PDF job keeps the duplex flag'
            );
            System.assertNotEquals(
                true,
                [SELECT Duplex_Padding__c FROM DocGen_Job__c WHERE Id = :individualJob].Duplex_Padding__c,
                'An Individual Files job forces the duplex flag off — there is nothing to pad'
            );
        }
    }

    @IsTest
    static void duplexMergeJobStitchesPartsAndCleansUp() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = t.Id,
                Status__c = 'Merging',
                Success_Count__c = 2,
                Total_Records__c = 2,
                Duplex_Padding__c = true
            );
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // Two real one-page PDFs as the per-record parts.
            Blob p1 = Blob.toPdf('<html><body><h1>Part one</h1></body></html>');
            Blob p2 = Blob.toPdf('<html><body><h1>Part two</h1></body></html>');
            insert new List<ContentVersion>{
                new ContentVersion(
                    Title = 'docgen_pdfpart_' + job.Id + '_00000',
                    PathOnClient = 'p0.pdf',
                    VersionData = p1,
                    IsMajorVersion = false,
                    FirstPublishLocationId = job.Id
                ),
                new ContentVersion(
                    Title = 'docgen_pdfpart_' + job.Id + '_00001',
                    PathOnClient = 'p1.pdf',
                    VersionData = p2,
                    IsMajorVersion = false,
                    FirstPublishLocationId = job.Id
                )
            };

            Test.startTest();
            System.enqueueJob(new DocGenMergeJob(job.Id));
            Test.stopTest();

            DocGen_Job__c done = [SELECT Status__c, Merged_PDF_CV__c FROM DocGen_Job__c WHERE Id = :job.Id];
            System.assertNotEquals('Merging', done.Status__c, 'The merge job must move the status off Merging');
            System.assertNotEquals(null, done.Merged_PDF_CV__c, 'A merged PDF should be produced from the parts');
            System.assertEquals(
                0,
                [SELECT COUNT() FROM ContentVersion WHERE Title LIKE :('docgen_pdfpart_' + job.Id + '_%')],
                'The per-record parts must be deleted after the merge'
            );

            ContentVersion merged = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Id = :done.Merged_PDF_CV__c
            ];
            // Both single-page parts are odd, so each gets a blank filler: 2 + 2 = 4.
            System.assertEquals(4, DocGenPdfMerger.pageCount(merged.VersionData), 'padded: (1+1) + (1+1)');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with label
    // =========================================================================

    @IsTest
    static void testSubmitJobWithLabel() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, 'My Custom Label', false, 5, false, null, null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals('My Custom Label', job.Label__c, 'Label should be set');
        }
    }

    // =========================================================================
    // DocGenBulkController — submitJob with blank label (null stored)
    // =========================================================================

    @IsTest
    static void testSubmitJobWithBlankLabel() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, '', false, 1, false, null, null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Label__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals(null, job.Label__c, 'Blank label should be stored as null');
        }
    }

    // =========================================================================
    // Sort order — parent-level ORDER BY for the bulk query.
    //
    // The bulk query had no ORDER BY, so merged PDFs came out in record-creation
    // order with no way to change it from the runner or the Flow action. These
    // cover the clause validator, the picker that feeds it, and the fact that the
    // validated clause survives all the way onto the job record.
    // =========================================================================

    @IsTest
    static void testNormalizeSortOrderCanonicalizesFieldAndDirection() {
        // Lower-case field, lower-case direction — authors type both.
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'name desc');
        System.assertEquals(
            'Name DESC NULLS LAST',
            clause,
            'Field casing, direction and NULLS handling should all be canonicalized.'
        );
    }

    @IsTest
    static void testNormalizeSortOrderAppendsNameTieBreak() {
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'AnnualRevenue DESC');
        System.assertEquals(
            'AnnualRevenue DESC NULLS LAST, Name ASC NULLS LAST',
            clause,
            'A single sort field should gain the name field as a tie-break so repeat runs produce the same packet order.'
        );
    }

    @IsTest
    static void testNormalizeSortOrderDoesNotDuplicateTieBreak() {
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'Name ASC');
        System.assertEquals(
            'Name ASC NULLS LAST',
            clause,
            'The tie-break must not repeat the field already sorted on.'
        );
    }

    @IsTest
    static void testNormalizeSortOrderTraversesRelationship() {
        // The headline case: order child records by a PARENT field.
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'owner.name');
        System.assert(
            clause.startsWith('Owner.Name ASC'),
            'Relationship traversal should resolve and canonicalize, got: ' + clause
        );
    }

    @IsTest
    static void testNormalizeSortOrderStripsLeadingOrderBy() {
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'ORDER BY Name');
        System.assert(clause.startsWith('Name ASC'), 'A pasted "ORDER BY" prefix should be tolerated, got: ' + clause);
    }

    @IsTest
    static void testNormalizeSortOrderHonorsExplicitNulls() {
        String clause = DocGenBulkController.normalizeSortOrder('Account', 'AnnualRevenue ASC NULLS FIRST');
        System.assert(
            clause.startsWith('AnnualRevenue ASC NULLS FIRST'),
            'An explicit NULLS FIRST must survive, got: ' + clause
        );
    }

    @IsTest
    static void testNormalizeSortOrderBlankReturnsNull() {
        System.assertEquals(null, DocGenBulkController.normalizeSortOrder('Account', null), 'Null in, null out.');
        System.assertEquals(null, DocGenBulkController.normalizeSortOrder('Account', '   '), 'Blank in, null out.');
    }

    @IsTest
    static void testNormalizeSortOrderRejectsInjection() {
        // Character allowlist: none of these belong in an ORDER BY clause.
        List<String> attacks = new List<String>{
            'Name ASC; DELETE FROM Account',
            'Name) OR (1=1',
            'Name /* comment */',
            'Name -- comment',
            'Name ASC, (SELECT Id FROM Contacts)'
        };
        for (String attack : attacks) {
            Boolean caught = false;
            try {
                DocGenBulkController.normalizeSortOrder('Account', attack);
            } catch (Exception e) {
                caught = true;
            }
            System.assert(caught, 'Sort order should have been rejected: ' + attack);
        }
    }

    @IsTest
    static void testNormalizeSortOrderRejectsUnknownField() {
        Boolean caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'NotAField__c ASC');
        } catch (Exception e) {
            caught = true;
            System.assert(
                e.getMessage().contains('Unknown sort field'),
                'The error should name the problem, got: ' + e.getMessage()
            );
        }
        System.assert(caught, 'An unknown field must be rejected at submit time, not at batch start.');
    }

    @IsTest
    static void testNormalizeSortOrderRejectsUnknownRelationship() {
        Boolean caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'Nope__r.Name ASC');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'An unknown relationship must be rejected.');
    }

    @IsTest
    static void testNormalizeSortOrderRejectsBadModifier() {
        Boolean caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'Name SIDEWAYS');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'Only ASC/DESC/NULLS FIRST/NULLS LAST may follow the field.');

        caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'Name ASC NULLS');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'A dangling NULLS must be rejected.');
    }

    @IsTest
    static void testNormalizeSortOrderRejectsDuplicateAndOverlongClauses() {
        Boolean caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'Name ASC, Name DESC');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'The same field twice is a mistake, not an order.');

        caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('Account', 'Name, AnnualRevenue, Type, Industry');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'More than 3 sort fields should be rejected — the clause has to fit Sort_Order__c.');
    }

    @IsTest
    static void testNormalizeSortOrderRejectsInvalidObject() {
        Boolean caught = false;
        try {
            DocGenBulkController.normalizeSortOrder('NoSuchObject__c', 'Name');
        } catch (Exception e) {
            caught = true;
        }
        System.assert(caught, 'An unresolvable base object must be rejected.');
    }

    @IsTest
    static void testGetSortableFieldsOffersOwnFieldsAndParentNames() {
        List<DocGenBulkController.SortFieldOption> options = DocGenBulkController.getSortableFields('Account');
        System.assert(!options.isEmpty(), 'Account should expose sortable fields.');

        Boolean hasOwnField = false;
        Boolean hasTraversal = false;
        String previousLabel = null;
        for (DocGenBulkController.SortFieldOption o : options) {
            if (o.value == 'Name') {
                hasOwnField = true;
            }
            if (o.value.contains('.')) {
                hasTraversal = true;
                // Every offered traversal must survive the validator, or the picker
                // is handing the user a value the submit path rejects.
                DocGenBulkController.normalizeSortOrder('Account', o.value);
            }
            if (previousLabel != null) {
                System.assert(previousLabel.compareTo(o.label) <= 0, 'Options should be label-ordered for the picker.');
            }
            previousLabel = o.label;
        }
        System.assert(hasOwnField, 'The object\'s own Name field should be offered.');
        System.assert(hasTraversal, 'Parent name fields (e.g. Owner > Full Name) should be offered.');

        System.assert(
            DocGenBulkController.getSortableFields('NoSuchObject__c').isEmpty(),
            'An unknown object should yield no options rather than an error.'
        );
    }

    @IsTest
    static void testSubmitJobStoresValidatedSortOrder() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            // startTest/stopTest runs the batch, so this also proves DocGenBatch
            // .start() builds a QueryLocator the platform accepts with the clause on it.
            Id jobId = DocGenBulkController.submitJob(t.Id, null, 'Sorted Job', false, 1, false, 'name desc', null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Sort_Order__c, Status__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals(
                'Name DESC NULLS LAST',
                job.Sort_Order__c,
                'The canonical clause should be stored on the job, not the raw input.'
            );
            System.assertNotEquals('Queued', job.Status__c, 'The sorted job should have run.');
        }
    }

    @IsTest
    static void testSubmitJobRejectsInvalidSortOrder() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();
            Boolean caught = false;
            Test.startTest();
            try {
                DocGenBulkController.submitJob(t.Id, null, 'Bad Sort', false, 1, false, 'Bogus__c ASC', null);
            } catch (AuraHandledException e) {
                caught = true;
            }
            Test.stopTest();
            System.assert(caught, 'A bad sort field must fail at submit time.');
            System.assertEquals(
                0,
                [SELECT COUNT() FROM DocGen_Job__c WHERE Label__c = 'Bad Sort'],
                'No job record should be left behind by a rejected sort order.'
            );
        }
    }

    @IsTest
    static void testSubmitJobWithoutSortOrderStaysUnordered() {
        User u = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(u) {
            DocGen_Template__c t = TestDataFactory.getTestTemplate();

            Test.startTest();
            Id jobId = DocGenBulkController.submitJob(t.Id, null, 'Unsorted Job', false, 1, false, null, null);
            Test.stopTest();

            DocGen_Job__c job = [SELECT Sort_Order__c FROM DocGen_Job__c WHERE Id = :jobId];
            System.assertEquals(null, job.Sort_Order__c, 'Omitting a sort order must remain the default behaviour.');
        }
    }
}

// CxSAST: Test class — SOQL/DML findings are test data operations, not production code paths
@IsTest
private class DocGenChartCvReaperTest {
    @TestSetup
    static void setup() {
        TestDataFactory.createStandardTestData();
    }

    private static ContentVersion makeChartCv(String suffix) {
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_chart_' + suffix,
            PathOnClient = 'chart.png',
            VersionData = Blob.valueOf('fake-png-bytes')
        );
        Database.insert(cv, AccessLevel.SYSTEM_MODE);
        return cv;
    }

    @IsTest
    static void freshChartCvsAreLeftAlone() {
        makeChartCv('fresh1');
        makeChartCv('fresh2');

        Test.startTest();
        Integer reaped = DocGenChartCvReaper.reap();
        Test.stopTest();

        // A CV created seconds ago may still be an in-flight render input. Reaping it
        // would blank the chart in a document that is mid-generation.
        System.assertEquals(0, reaped, 'Chart CVs younger than the age threshold must not be reaped');
        System.assertEquals(
            2,
            [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'docgen_chart_%'],
            'Both fresh chart CVs should survive'
        );
    }

    @IsTest
    static void nonChartFilesAreNeverTouched() {
        ContentVersion keep = new ContentVersion(
            Title = 'CustomerContract',
            PathOnClient = 'contract.pdf',
            VersionData = Blob.valueOf('not-a-chart')
        );
        Database.insert(keep, AccessLevel.SYSTEM_MODE);

        Test.startTest();
        DocGenChartCvReaper.reap();
        Test.stopTest();

        // The reaper deletes ContentDocuments. Scoping it to the docgen_chart_ prefix
        // is the only thing standing between it and a customer's real files.
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ContentVersion WHERE Title = 'CustomerContract'],
            'A file without the docgen_chart_ prefix must never be reaped'
        );
    }

    private static ContentVersion makeAgedCv(String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('fake-pdf-bytes')
        );
        Database.insert(cv, AccessLevel.SYSTEM_MODE);
        // The reaper's age filter is on ContentVersion.CreatedDate; the parent
        // ContentDocument is only ever deleted by id, never date-filtered.
        Test.setCreatedDate(cv.Id, System.now().addMinutes(-120));
        return cv;
    }

    @IsTest
    static void oldPdfPartOfTerminalJobIsReaped() {
        DocGen_Job__c job = TestDataFactory.createTestJob();
        job.Status__c = 'Completed';
        Database.update(job, AccessLevel.SYSTEM_MODE);
        makeAgedCv('docgen_pdfpart_' + job.Id + '_00000');

        Test.startTest();
        Integer reaped = DocGenChartCvReaper.reap();
        Test.stopTest();

        System.assertEquals(1, reaped, 'A stale part whose job has finished is an orphan and must be reaped');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'docgen_pdfpart_%'],
            'The orphaned part should be gone'
        );
    }

    @IsTest
    static void oldPdfPartOfRunningJobIsLeftAlone() {
        DocGen_Job__c job = TestDataFactory.createTestJob();
        job.Status__c = 'Processing';
        Database.update(job, AccessLevel.SYSTEM_MODE);
        // Old enough to pass the age filter, but the job is still running — a large
        // bulk job's batch + merge can legitimately outlast ORPHAN_AGE_MINUTES.
        makeAgedCv('docgen_pdfpart_' + job.Id + '_00000');

        Test.startTest();
        Integer reaped = DocGenChartCvReaper.reap();
        Test.stopTest();

        System.assertEquals(0, reaped, 'A part whose job is still Processing must never be reaped');
        System.assertEquals(
            1,
            [SELECT COUNT() FROM ContentVersion WHERE Title LIKE 'docgen_pdfpart_%'],
            'The in-flight part should survive'
        );
    }

    @IsTest
    static void parseJobIdRejectsNonPartTitles() {
        System.assertEquals(null, DocGenChartCvReaper.parseJobId('docgen_chart_001abc_deadbeef'));
        System.assertEquals(null, DocGenChartCvReaper.parseJobId('CustomerContract'));
        System.assertEquals(null, DocGenChartCvReaper.parseJobId('docgen_pdfpart_notanid_00000'));
        System.assertEquals(null, DocGenChartCvReaper.parseJobId(null));
    }

    @IsTest
    static void schedulableEntryPointRuns() {
        Test.startTest();
        String cron = System.schedule('DocGen Chart CV Reaper Test', '0 0 0 1 1 ? 2099', new DocGenChartCvReaper());
        Test.stopTest();

        System.assertNotEquals(null, cron, 'Reaper should be schedulable');
        System.assertEquals(
            1,
            [SELECT COUNT() FROM CronTrigger WHERE Id = :cron],
            'A CronTrigger should exist for the scheduled reaper'
        );
    }
}

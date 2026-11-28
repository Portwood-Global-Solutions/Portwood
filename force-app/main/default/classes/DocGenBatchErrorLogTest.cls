/**
 * Tests for bulk-batch failure diagnostics (DocGen_Job__c.Error_Log__c).
 *
 * Previously DocGenBatch.execute swallowed per-record failures with a bare
 * `failCount++` — no record Id, no reason, and no signal that a record failed only
 * because it was too large for standard generation. These verify failures are now
 * captured with their reason and that oversized records are flagged with guidance to
 * use the giant-query path (which the bulk batch cannot launch itself).
 */
@isTest
private class DocGenBatchErrorLogTest {
    private static Id newJob() {
        DocGen_Template__c tpl = new DocGen_Template__c(
            Name = 'Batch Err Test Tpl',
            Base_Object_API__c = 'Account',
            Query_Config__c = 'Name'
        );
        insert tpl;
        DocGen_Job__c job = new DocGen_Job__c(Template__c = tpl.Id, Status__c = 'Queued');
        insert job;
        return job.Id;
    }

    private static Id anAccountId() {
        Account a = new Account(Name = 'Batch Err Acct');
        insert a;
        return a.Id;
    }

    @isTest
    static void reportMergeRetryReducesScopeOnlyForSoqlLimits() {
        String soqlLimit = 'First error: Too many SOQL queries: 201';
        System.assertEquals(25, DocGenBatch.smallerReportScope(50, soqlLimit));
        System.assertEquals(12, DocGenBatch.smallerReportScope(25, soqlLimit));
        System.assertEquals(1, DocGenBatch.smallerReportScope(3, soqlLimit));
        System.assertEquals(null, DocGenBatch.smallerReportScope(1, soqlLimit));
        System.assertEquals(null, DocGenBatch.smallerReportScope(null, soqlLimit));
        System.assertEquals(null, DocGenBatch.smallerReportScope(50, 'Apex CPU time limit exceeded'));
    }

    @isTest
    static void heapFailureIsFlaggedWithGiantQueryGuidance() {
        Id jobId = newJob();
        Id recId = anAccountId();
        DocGenBatch batch = new DocGenBatch(jobId);

        HeapPressureException hpe = new HeapPressureException();
        hpe.relationshipName = 'Contacts';
        batch.recordFailure(recId, hpe);

        System.assertEquals(1, batch.heapFailCount, 'Heap pressure counted as an oversized failure');
        batch.failCount = 1;
        String log = batch.buildErrorLog();
        System.assert(log.contains('too large'), 'Oversized guidance present: ' + log);
        System.assert(log.contains('giant-query'), 'Points to the giant-query path: ' + log);
        System.assert(log.contains(String.valueOf(recId)), 'Names the failing record: ' + log);
    }

    @isTest
    static void genericFailureCapturesTypeAndMessage() {
        Id jobId = newJob();
        Id recId = anAccountId();
        DocGenBatch batch = new DocGenBatch(jobId);

        batch.recordFailure(recId, new DocGenException('boom happened'));
        batch.failCount = 1;
        String log = batch.buildErrorLog();

        System.assert(log.contains('boom happened'), 'Captures the exception message: ' + log);
        System.assert(log.contains(String.valueOf(recId)), 'Names the failing record: ' + log);
        System.assertEquals(0, batch.heapFailCount, 'A generic failure is not miscounted as heap pressure');
    }

    @isTest
    static void cappedLogNotesAdditionalFailures() {
        Id jobId = newJob();
        DocGenBatch batch = new DocGenBatch(jobId);

        batch.recordFailure(anAccountId(), new DocGenException('only-captured-line'));
        // Simulate more failures than captured lines (the cap path).
        batch.failCount = 5;
        String log = batch.buildErrorLog();

        System.assert(log.contains('and 4 more'), '"+N more" note surfaces hidden failures: ' + log);
    }

    @isTest
    static void noFailuresProducesNullLog() {
        Id jobId = newJob();
        DocGenBatch batch = new DocGenBatch(jobId);
        System.assertEquals(null, batch.buildErrorLog(), 'No failures → null (Error_Log__c stays empty)');
    }

    // #155 — oversized records are captured by Id (not just counted) so finish() can
    // hand them to the giant-query fallback Queueable.
    @isTest
    static void heapFailureCapturesRecordIdForFallback() {
        Id jobId = newJob();
        Id recId = anAccountId();
        DocGenBatch batch = new DocGenBatch(jobId);

        batch.recordFailure(recId, new HeapPressureException());

        System.assertEquals(1, batch.oversizedRecordIds.size(), 'Oversized record Id captured for fallback');
        System.assertEquals(recId, batch.oversizedRecordIds[0], 'Captured the right record Id');
        System.assertEquals(0, batch.oversizedOverflowCount, 'No overflow under the cap');
    }

    @isTest
    static void genericFailureDoesNotCaptureForFallback() {
        Id jobId = newJob();
        Id recId = anAccountId();
        DocGenBatch batch = new DocGenBatch(jobId);

        // Message deliberately avoids the word "heap" — isHeapError() matches on that substring.
        batch.recordFailure(recId, new DocGenException('some unrelated validation error'));

        System.assertEquals(0, batch.oversizedRecordIds.size(), 'Non-heap failures are not queued for giant-query');
    }

    // #155 — the fallback list is capped; overflow is counted and surfaced in the log
    // rather than silently dropped.
    @isTest
    static void oversizedCapOverflowIsNotedInLog() {
        Id jobId = newJob();
        Id recId = anAccountId();
        DocGenBatch batch = new DocGenBatch(jobId);

        Integer attempts = DocGenBatch.MAX_FALLBACK_RECORDS + 3;
        for (Integer i = 0; i < attempts; i++) {
            batch.recordFailure(recId, new HeapPressureException());
        }
        batch.failCount = attempts;

        System.assertEquals(
            DocGenBatch.MAX_FALLBACK_RECORDS,
            batch.oversizedRecordIds.size(),
            'Fallback list is capped at MAX_FALLBACK_RECORDS'
        );
        System.assertEquals(3, batch.oversizedOverflowCount, 'Overflow beyond the cap is counted');

        String log = batch.buildErrorLog();
        System.assert(
            log.contains('must be generated individually by hand'),
            'Overflow note surfaces the records that exceeded auto-recovery: ' + log
        );
    }
}

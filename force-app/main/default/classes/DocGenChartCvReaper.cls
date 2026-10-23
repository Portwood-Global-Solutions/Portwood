/**
 * Deletes orphaned transient bulk-generation ContentVersions.
 *
 * Two transient CV families are created as render inputs and the CALLER owns cleanup:
 *   docgen_chart_*    — one per chart, from rasterization; life = one transaction
 *   docgen_pdfpart_*  — one per record, from the duplex-padding merge (#382);
 *                       life = the batch run + the chained DocGenMergeJob
 * The runner and DocGenBatch/DocGenMergeJob reap their own on the happy path. A
 * caller that dies mid-flow — an uncatchable heap/CPU limit in the merge job, a
 * killed batch, a browser tab closed — leaves them behind with nothing watching.
 *
 * Once bulk generation produces these per record, the failure mode scales with
 * the job: a failed 500-record duplex merge leaves 500 part CVs. This is the
 * backstop.
 *
 * Two guards keep it from ever deleting a live render input:
 *   - Chart CVs: age only. An hour is far beyond any single-transaction render.
 *   - PDF parts (docgen_pdfpart_<jobId>_<seq>): age AND job state. A large bulk
 *     job's batch + merge can legitimately run past the hour, so a part is only
 *     reaped once its DocGen_Job__c has reached a terminal state (or is gone) —
 *     never while the job is still Processing/Merging.
 *
 * Schedule hourly:
 *   System.schedule('DocGen Chart CV Reaper', '0 0 * * * ?', new DocGenChartCvReaper());
 */
global with sharing class DocGenChartCvReaper implements Schedulable { // NOPMD AvoidGlobalModifier — global so subscribers can schedule it in a managed package
    // Chart CVs live for one transaction. An hour is far beyond any legitimate
    // render, including a batch chunk running at the async CPU ceiling, while
    // still keeping orphans short-lived.
    @TestVisible
    private static final Integer ORPHAN_AGE_MINUTES = 60;

    // Batch-friendly cap. A single scheduled run reaps at most this many; the next
    // run picks up the rest rather than risking the DML row limit in one pass.
    @TestVisible
    private static final Integer MAX_PER_RUN = 500;

    global void execute(SchedulableContext ctx) {
        reap();
    }

    /**
     * Deletes orphaned chart CVs. Returns the number of ContentDocuments removed.
     * Separated from execute() so tests and ad-hoc admin runs can call it directly.
     */
    global static Integer reap() {
        DateTime cutoff = System.now().addMinutes(-ORPHAN_AGE_MINUTES);
        String chartLike = 'docgen_chart_%';
        String partLike = 'docgen_pdfpart_%';

        // SYSTEM_MODE: these are package-internal render artifacts whose
        // ContentDocumentLinks default to Visibility=InternalUsers, which USER_MODE
        // reads silently drop (the #114 quirk) — a USER_MODE query here would report
        // "nothing to clean up" while orphans piled up.
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> orphans = [
            SELECT Title, ContentDocumentId
            FROM ContentVersion
            WHERE (Title LIKE :chartLike OR Title LIKE :partLike) AND CreatedDate < :cutoff AND IsLatest = TRUE
            WITH SYSTEM_MODE
            LIMIT :MAX_PER_RUN
        ];
        if (orphans.isEmpty()) {
            return 0;
        }

        // docgen_pdfpart_<jobId>_<seq> parts belong to a specific bulk job whose
        // batch + chained merge job can run longer than ORPHAN_AGE_MINUTES. Never
        // reap a part while its job is still in flight, no matter how old — only
        // once the job is terminal or gone. Chart CVs carry no job id and stay on
        // the pure age rule.
        Set<Id> partJobIds = new Set<Id>();
        for (ContentVersion cv : orphans) {
            Id jobId = parseJobId(cv.Title);
            if (jobId != null) {
                partJobIds.add(jobId);
            }
        }
        Set<Id> liveJobIds = new Set<Id>();
        if (!partJobIds.isEmpty()) {
            DocGenFlsGuard.assertAccessible(DocGen_Job__c.sObjectType, new Set<String>{ 'Status__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            for (DocGen_Job__c j : [
                SELECT Id
                FROM DocGen_Job__c
                WHERE Id IN :partJobIds AND Status__c NOT IN ('Completed', 'Completed with Errors', 'Failed')
                WITH SYSTEM_MODE
            ]) {
                liveJobIds.add(j.Id);
            }
        }

        // Delete the ContentDocument, not the ContentVersion — deleting the version
        // of a single-version document is not permitted.
        Set<Id> docIds = new Set<Id>();
        for (ContentVersion cv : orphans) {
            Id jobId = parseJobId(cv.Title);
            if (jobId != null && liveJobIds.contains(jobId)) {
                continue; // job still running — its parts are not orphans yet
            }
            if (cv.ContentDocumentId != null) {
                docIds.add(cv.ContentDocumentId);
            }
        }
        if (docIds.isEmpty()) {
            return 0;
        }

        List<ContentDocument> docs = [SELECT Id FROM ContentDocument WHERE Id IN :docIds WITH SYSTEM_MODE];
        if (docs.isEmpty()) {
            return 0;
        }
        // Partial-success delete: one undeletable document (locked by another
        // transaction, already reaped concurrently) must not block the rest.
        Database.delete(docs, false, AccessLevel.SYSTEM_MODE); // NOPMD ApexCRUDViolation — package-internal transient render artifacts
        return docs.size();
    }

    /**
     * Pulls the DocGen_Job__c id out of a `docgen_pdfpart_<jobId>_<seq>` title.
     * Returns null for any other title shape (chart CVs, malformed names) so the
     * caller falls back to the pure age rule for those.
     */
    @TestVisible
    private static Id parseJobId(String title) {
        if (String.isBlank(title) || !title.startsWith('docgen_pdfpart_')) {
            return null;
        }
        String rest = title.substring('docgen_pdfpart_'.length());
        Integer lastUnderscore = rest.lastIndexOf('_');
        if (lastUnderscore <= 0) {
            return null;
        }
        String candidate = rest.substring(0, lastUnderscore);
        try {
            Id parsed = Id.valueOf(candidate);
            return (parsed.getSObjectType() == DocGen_Job__c.sObjectType) ? parsed : null;
        } catch (Exception ignored) {
            return null;
        }
    }
}

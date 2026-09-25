/**
 * Async worker for DocGenFlowAction's custom-JSON path when DocGenFlowHeapRouter
 * decides a DOCX-output request needs the larger async heap budget (12 MB vs
 * 6 MB synchronous) instead of an uncatchable System.LimitException (#403).
 *
 * Does exactly what the synchronous branch of DocGenFlowAction.generateDocument
 * does (DocGenService.generateAndSaveFromData with the same params), just
 * inside a Queueable. The resulting document is linked to the DocGen_Job__c
 * record (so a Flow polling by Job ID can find it via a "Get Records" on
 * ContentDocumentLink, the same way Files work everywhere else in this app —
 * no new lookup field needed) in addition to the source record when
 * saveToRecord is true.
 *
 * A Finalizer handles the case DocGenFlowHeapRouter's estimate is wrong and
 * this run itself hits an uncatchable heap/CPU LimitException — that skips
 * execute()'s own try/catch entirely, so without the finalizer the job would
 * be stuck at "Processing" forever instead of surfacing as Failed. Mirrors
 * DocGenMergeJob's DocGenMergeJobFinalizer (#382 precedent).
 */
public with sharing class DocGenJsonMergeQueueable implements Queueable {
    private final Id templateId;
    private final Id recordId;
    private final String jsonData;
    private final String outputFormatOverride;
    private final String documentTitle;
    private final Boolean saveToRecord;
    private final Id jobId;

    public DocGenJsonMergeQueueable(
        Id templateId,
        Id recordId,
        String jsonData,
        String outputFormatOverride,
        String documentTitle,
        Boolean saveToRecord,
        Id jobId
    ) {
        this.templateId = templateId;
        this.recordId = recordId;
        this.jsonData = jsonData;
        this.outputFormatOverride = outputFormatOverride;
        this.documentTitle = documentTitle;
        this.saveToRecord = saveToRecord;
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        System.attachFinalizer(new DocGenJsonMergeQueueableFinalizer(this.jobId));
        try {
            update new DocGen_Job__c(Id = jobId, Status__c = 'Processing'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

            Object parsed = JSON.deserializeUntyped(jsonData);
            if (!(parsed instanceof Map<String, Object>)) {
                throw new DocGenException('JSON Data must deserialize to an object (Map), not an array or scalar.');
            }
            Map<String, Object> dataMap = (Map<String, Object>) parsed;

            // Mirrors DocGenFlowAction's sync branch exactly (issue #90 semantics):
            // recordId anchors title/merge context, fileAttachmentTarget controls
            // whether the source record's Files list gets the document.
            Id fileAttachmentTarget = (saveToRecord == true) ? recordId : null;
            Id docId = DocGenService.generateAndSaveFromData(
                templateId,
                recordId,
                dataMap,
                outputFormatOverride,
                documentTitle,
                fileAttachmentTarget
            );

            SObjectAccessDecision dec = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentDocumentLink>{
                    new ContentDocumentLink(
                        ContentDocumentId = docId,
                        LinkedEntityId = jobId,
                        ShareType = 'V',
                        Visibility = 'AllUsers'
                    )
                }
            );
            insert dec.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible

            update new DocGen_Job__c(Id = jobId, Status__c = 'Completed'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
        } catch (Exception e) {
            update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                Id = jobId,
                Status__c = 'Failed',
                Error_Log__c = ('Background generation failed: ' + e.getMessage()).abbreviate(32768)
            );
        }
    }

    public with sharing class DocGenJsonMergeQueueableFinalizer implements Finalizer {
        private Id jobId;

        public DocGenJsonMergeQueueableFinalizer(Id jobId) {
            this.jobId = jobId;
        }

        public void execute(FinalizerContext ctx) {
            if (ctx.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
                return;
            }
            // Heap/CPU LimitExceptions are uncatchable — execute()'s own try/catch
            // never runs for them, so this is the only place such a run can be
            // marked Failed instead of being left stuck at "Processing" forever.
            String reason = '';
            try {
                Exception e = ctx.getException();
                reason = (e == null) ? '' : String.valueOf(e.getMessage());
            } catch (Exception ignored) {
                reason = '';
            }
            try {
                DocGen_Job__c u = new DocGen_Job__c(Id = jobId, Status__c = 'Failed');
                u.Error_Log__c = describeFailure(reason);
                update u; // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }
    }

    /**
     * Turns an uncatchable-limit exception message into a job-owner-friendly
     * Error_Log__c line. On the outer class (inner classes cannot hold static
     * members) and @TestVisible — a FinalizerContext cannot be built in a test,
     * so this message logic is exercised directly instead. Mirrors
     * DocGenMergeJob.describeMergeFailure.
     */
    @TestVisible
    private static String describeFailure(String reason) {
        return String.isNotBlank(reason)
            ? ('Background generation ran out of resources: ' + reason).abbreviate(32768)
            : 'Background generation failed unexpectedly (no further detail available).';
    }
}

/** Renders the frozen selection in bounded scopes and commits each group with its exact File versions. */
public with sharing class DocGenBrowserPdfBatch implements Database.Batchable<SObject>, Database.Stateful {
    private final Id jobId;
    private Id templateId;
    private String baseObject;
    private String queryConfig;
    private Boolean hasChartTags;
    private Integer total;
    private Integer successes = 0;
    private Integer failures = 0;
    private static final Integer MAX_STAGED_BYTES = 1536000;

    public DocGenBrowserPdfBatch(Id jobId) {
        this.jobId = jobId;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        String batchId = String.valueOf(context.getJobId());
        Id userId = UserInfo.getUserId();
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jobs = [
            SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Query_Config__c, Total_Records__c
            FROM DocGen_Job__c
            WHERE
                Id = :jobId
                AND Browser_Merge__c = TRUE
                AND Browser_Batch_Id__c = :batchId
                AND Status__c = 'Processing'
                AND OwnerId = :userId
                AND CreatedById = :userId
            WITH SYSTEM_MODE
        ];
        if (jobs.isEmpty()) {
            throw new DocGenException('The frozen job is unavailable to the original owner.');
        }
        DocGen_Job__c job = jobs[0];
        templateId = job.Template__c;
        baseObject = job.Template__r.Base_Object_API__c;
        queryConfig = job.Template__r.Query_Config__c;
        total = DocGenBrowserPdf.count(job.Total_Records__c);
        successes = countSaved();
        try {
            hasChartTags = DocGenChartImageController.hasChartTags(templateId);
        } catch (Exception e) {
            hasChartTags = false;
        }
        /* code-analyzer-suppress ApexFlsViolation */
        return Database.getQueryLocator(
            [
                SELECT Id
                FROM DocGen_Browser_Pdf_Block__c
                WHERE Job__c = :jobId AND Complete__c = FALSE
                WITH SYSTEM_MODE
            ]
        );
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        for (SObject row : scope) {
            renderBlock(row.Id);
        }
        updateJob(new DocGen_Job__c(Id = jobId, Success_Count__c = successes, Error_Count__c = failures));
    }

    private void renderBlock(Id blockId) {
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Browser_Pdf_Block__c block = [
            SELECT Id, First_Ordinal__c, Source_Ids__c, Version_Ids__c, Success_Count__c, Complete__c
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Id = :blockId AND Job__c = :jobId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (block.Complete__c) {
            return;
        }
        List<Id> sources = (List<Id>) JSON.deserialize(block.Source_Ids__c, List<Id>.class);
        List<Id> pins = new List<Id>();
        if (String.isNotBlank(block.Version_Ids__c)) {
            pins = (List<Id>) JSON.deserialize(block.Version_Ids__c, List<Id>.class);
        } else {
            for (Id source : sources) {
                pins.add(null);
            }
        }
        if (pins.size() != sources.size() || sources.size() > DocGenBrowserPdf.MAX_BLOCK_SIZE) {
            throw new DocGenException('The frozen PDF source block is invalid.');
        }

        Set<Id> pendingSources = new Set<Id>();
        for (Integer index = 0; index < sources.size(); index++) {
            if (pins[index] == null) {
                pendingSources.add(sources[index]);
            }
        }
        Set<Id> readableIds = readableSourceIds(pendingSources);
        Map<Id, Map<String, Object>> prefetched = prefetch(readableIds);
        List<String> errors = new List<String>();
        List<ContentVersion> files = new List<ContentVersion>();
        List<Integer> indexes = new List<Integer>();
        Integer stagedBytes = 0;
        Integer firstOrdinal = block.First_Ordinal__c.intValue();

        for (Integer index = 0; index < sources.size(); index++) {
            if (pins[index] != null) {
                continue;
            }
            Id source = sources[index];
            if (!readableIds.contains(source)) {
                errors.add('Source ' + (firstOrdinal + index) + ': record access is unavailable.');
                continue;
            }
            if (!renderHeadroom()) {
                errors.add('Source ' + (firstOrdinal + index) + ': transaction capacity was reached.');
                continue;
            }
            try {
                ContentVersion file = renderFile(source, firstOrdinal + index, prefetched.get(source));
                if (file.VersionData.size() > DocGenBrowserPdf.MAX_SOURCE_BYTES) {
                    errors.add(
                        'Source ' +
                            (firstOrdinal + index) +
                            ': PDF exceeds the 1 MiB per-source limit for browser downloads.'
                    );
                    continue;
                }
                files.add(file);
                indexes.add(index);
                stagedBytes += file.VersionData.size();
                if (stagedBytes >= MAX_STAGED_BYTES) {
                    saveFiles(files, indexes, pins, firstOrdinal, errors);
                    stagedBytes = 0;
                }
            } catch (Exception e) {
                errors.add('Source ' + (firstOrdinal + index) + ': PDF rendering failed.');
            }
        }
        saveFiles(files, indexes, pins, firstOrdinal, errors);

        Integer completed = 0;
        for (Id pin : pins) {
            if (pin != null) {
                completed++;
            }
        }
        successes += completed - DocGenBrowserPdf.count(block.Success_Count__c);
        failures += sources.size() - completed;
        block.Success_Count__c = completed;
        block.Version_Ids__c = JSON.serialize(pins);
        block.Complete__c = completed == sources.size();
        block.Error_Log__c = String.join(errors, '\n').left(8192);
        // These block rows are internal. Access is tied to the verified batch, never to a client ID.
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(block, AccessLevel.SYSTEM_MODE);
    }

    private Set<Id> readableSourceIds(Set<Id> requested) {
        SObjectType sourceType = Schema.getGlobalDescribe().get(baseObject);
        if (sourceType == null || !sourceType.getDescribe().isAccessible()) {
            return new Set<Id>();
        }
        Set<Id> readable = new Set<Id>();
        String query = 'SELECT Id FROM ' + sourceType.getDescribe().getName() + ' WHERE Id IN :requested';
        for (SObject source : Database.query(query, AccessLevel.USER_MODE)) {
            readable.add(source.Id);
        }
        return readable;
    }

    private Map<Id, Map<String, Object>> prefetch(Set<Id> sources) {
        if (!sources.isEmpty() && DocGenDataRetriever.getConfigVersion(queryConfig) == 3) {
            try {
                Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig);
                Map<Id, Map<String, Object>> data = DocGenDataRetriever.getRecordDataV3Bulk(sources, config);
                for (Map<String, Object> recordData : data.values()) {
                    DocGenController.resolveRichTextImages(recordData);
                }
                return data;
            } catch (Exception e) {
                return new Map<Id, Map<String, Object>>();
            }
        }
        return new Map<Id, Map<String, Object>>();
    }

    private ContentVersion renderFile(Id recordId, Integer ordinal, Map<String, Object> recordData) {
        List<Id> chartIds;
        try {
            if (hasChartTags == true) {
                Map<String, String> chartImages = DocGenChartImageController.prepareChartImagesServerSide(
                    templateId,
                    recordId
                );
                if (!chartImages.isEmpty()) {
                    chartIds = DocGenChartImageController.chartCvIdsFrom(chartImages);
                    DocGenService.beginChartContext(chartImages);
                }
            }
            Map<String, Object> result = DocGenService.generatePdfBlobFromData(templateId, recordId, recordData);
            Blob pdf = (Blob) result.get('blob');
            if (pdf == null || pdf.size() == 0) {
                throw new DocGenException('The renderer returned an empty PDF.');
            }
            String title = 'Portwood bulk PDF ' + jobId + ' ' + String.valueOf(ordinal).leftPad(6, '0');
            return new ContentVersion(
                Title = title,
                PathOnClient = title + '.pdf',
                VersionData = pdf,
                SharingPrivacy = 'P',
                SharingOption = 'R',
                IsMajorVersion = true
            );
        } finally {
            DocGenService.lastRenderedHtml = null;
            DocGenService.endChartContext();
            if (chartIds != null && !chartIds.isEmpty()) {
                try {
                    DocGenChartImageController.deleteChartImages(chartIds);
                } catch (Exception e) {
                    // The chart reaper also removes transient render Files.
                    chartIds = null;
                }
            }
        }
    }

    private static Boolean renderHeadroom() {
        return Limits.getCpuTime() < Limits.getLimitCpuTime() - 4000 &&
            Limits.getHeapSize() < Limits.getLimitHeapSize() - 2300000 &&
            Limits.getQueries() < Limits.getLimitQueries() - 12 &&
            Limits.getDmlStatements() < Limits.getLimitDmlStatements() - 12;
    }

    private static void saveFiles(
        List<ContentVersion> files,
        List<Integer> indexes,
        List<Id> pins,
        Integer firstOrdinal,
        List<String> errors
    ) {
        if (files.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.insert(files, false, AccessLevel.USER_MODE);
        for (Integer index = 0; index < results.size(); index++) {
            Integer sourceIndex = indexes[index];
            Database.SaveResult result = results[index];
            if (result.isSuccess()) {
                pins[sourceIndex] = result.getId();
            } else {
                errors.add(
                    'Source ' +
                        (firstOrdinal + sourceIndex) +
                        ': File save failed (' +
                        result.getErrors()[0].getStatusCode() +
                        ').'
                );
            }
        }
        files.clear();
        indexes.clear();
    }

    public void finish(Database.BatchableContext context) {
        Integer saved = countSaved();
        Integer failed = total - saved;
        String status = saved > 0 && failed == 0 ? 'Completed' : (saved == 0 ? 'Failed' : 'Completed with Errors');
        String errorLog = failed > 0 ? collectErrors(failed) : null;
        updateJob(
            new DocGen_Job__c(
                Id = jobId,
                Status__c = status,
                Success_Count__c = saved,
                Error_Count__c = failed,
                Error_Log__c = errorLog
            )
        );
        if (status == 'Completed' && !Test.isRunningTest()) {
            // A separate transaction keeps optional notification delivery outside the committed result.
            System.enqueueJob(new ReadyNotification(jobId, total));
        }
    }

    private Integer countSaved() {
        // COUNT consumes a queried row per result. SUM consumes every matching block.
        // Excluding the one- and two-source blocks puts SUM below 34,000 rows at 100,000 sources.
        /* code-analyzer-suppress ApexFlsViolation */
        Integer single = [
            SELECT COUNT()
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId AND Success_Count__c = 1
            WITH SYSTEM_MODE
        ];
        /* code-analyzer-suppress ApexFlsViolation */
        Integer pairs = [
            SELECT COUNT()
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId AND Success_Count__c = 2
            WITH SYSTEM_MODE
        ];
        /* code-analyzer-suppress ApexFlsViolation */
        AggregateResult larger = [
            SELECT SUM(Success_Count__c) saved
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId AND Success_Count__c >= 3
            WITH SYSTEM_MODE
        ];
        return single + 2 * pairs + DocGenBrowserPdf.count((Decimal) larger.get('saved'));
    }

    private String collectErrors(Integer failed) {
        List<String> lines = new List<String>{
            failed + ' PDF source(s) could not be saved. Retry to render only the missing sources.'
        };
        /* code-analyzer-suppress ApexFlsViolation */
        for (DocGen_Browser_Pdf_Block__c row : [
            SELECT First_Ordinal__c, Last_Ordinal__c, Error_Log__c
            FROM DocGen_Browser_Pdf_Block__c
            WHERE Job__c = :jobId AND Complete__c = FALSE
            WITH SYSTEM_MODE
            ORDER BY First_Ordinal__c
            LIMIT 20
        ]) {
            lines.add(
                String.isBlank(row.Error_Log__c)
                    ? 'Sources ' + row.First_Ordinal__c + '–' + row.Last_Ordinal__c + ': batch transaction failed.'
                    : row.Error_Log__c
            );
        }
        return String.join(lines, '\n').left(32768);
    }

    private static void updateJob(DocGen_Job__c updateJob) {
        // Only an active job-bound Batch Apex attempt can reach these internal state updates.
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(updateJob, AccessLevel.SYSTEM_MODE);
    }

    private class ReadyNotification implements Queueable {
        private final Id jobId;
        private final Integer total;

        private ReadyNotification(Id jobId, Integer total) {
            this.jobId = jobId;
            this.total = total;
        }

        public void execute(QueueableContext context) {
            try {
                String url = DocGenBrowserPdf.downloadUrl(jobId);
                /* code-analyzer-suppress ApexFlsViolation */
                List<CustomNotificationType> types = [
                    SELECT Id
                    FROM CustomNotificationType
                    WHERE DeveloperName = 'DocGen_Job_Complete'
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!types.isEmpty()) {
                    Messaging.CustomNotification notification = new Messaging.CustomNotification();
                    notification.setNotificationTypeId(types[0].Id);
                    notification.setTargetPageRef(
                        JSON.serialize(
                            new Map<String, Object>{
                                'type' => 'standard__webPage',
                                'attributes' => new Map<String, String>{ 'url' => url }
                            }
                        )
                    );
                    notification.setTitle('Portwood: bulk PDF ready to download');
                    notification.setBody(total + ' documents are ready. Tap to open the combined PDF download.');
                    notification.send(new Set<String>{ UserInfo.getUserId() });
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Could not deliver the bulk PDF notification.');
            }
        }
    }
}

public with sharing class DocGenBatch implements Database.Batchable<SObject>, Database.Stateful, Database.AllowsCallouts {
    public Id jobId;
    public Id templateId;
    public String baseObject;
    public String condition;
    public String queryConfig;
    // Validated ORDER BY clause for the bulk query (see DocGenBulkController
    // .normalizeSortOrder). Null for the historical unordered behaviour.
    public String sortOrder;
    public Boolean mergeMode;
    public Boolean mergeOnly;

    public Integer successCount = 0;
    public Integer failCount = 0;

    // Per-record failure diagnostics (Stateful — accumulates across execute() chunks).
    // Previously failures were silently counted with no record Id or reason; this captures
    // both so a job's failures are actionable. Capped to keep heap + the field bounded.
    @TestVisible
    private List<String> errorLog = new List<String>();
    @TestVisible
    private Integer heapFailCount = 0;
    private static final Integer MAX_ERROR_LINES = 200;

    // #155 — IDs of records that failed with heap/oversize errors, captured so finish()
    // can enqueue a Queueable fallback that re-runs each through the giant-query path
    // (the bulk batch itself cannot launch a Batchable). Stateful — accumulates across
    // execute() chunks. Capped so a pathological filter can't grow this unbounded; the
    // overflow count is surfaced in the error log (never silently dropped).
    @TestVisible
    private List<Id> oversizedRecordIds = new List<Id>();
    @TestVisible
    private Integer oversizedOverflowCount = 0;
    @TestVisible
    private static final Integer MAX_FALLBACK_RECORDS = 100;

    // Bulk data cache — populated in start(), read in execute()
    public Id dataCacheCvId;
    public String cachedDataJson;

    // Merge mode: sequence counter for HTML snippet / PDF part ordering
    public Integer htmlSequence = 0;

    // Duplex padding (#382). When true the batch renders each record as its own
    // PDF part instead of an HTML snippet, and DocGenMergeJob stitches the parts
    // with DocGenPdfMerger — appending one blank page to any odd-length document
    // so it starts on a sheet front under duplex printing. False keeps the
    // historical HTML-concatenation merge unchanged.
    public Boolean duplexPadding = false;

    // Chart rasterization (Stateful — resolved once, reused across execute() chunks).
    //
    // {Chart:...} image charts need a chartCvMap, which the interactive runner builds
    // by rasterizing SVG in a browser <canvas>. A batch has no DOM, so bulk rendered
    // those tags as "[Chart: rel.field]" text placeholders. DocGenChartRasterizer is a
    // pure-Apex PNG renderer built for exactly this; prepareChartImagesServerSide wraps
    // it and returns the same map shape the merge pipeline already consumes.
    //
    // The has-charts probe is cached because prepareChartImagesServerSide loads the
    // active template body to look for chart tags — a per-record SOQL that would be
    // pure waste on the overwhelming majority of templates, which have no charts.
    //
    // {#ChartBucket:...} loops and HTML CSS-bar charts are NOT affected by any of this:
    // they resolve server-side inside processXml and have always worked in bulk.
    @TestVisible
    private Boolean templateHasChartTags = null;

    /**
     * Constructs a batch job in default (non-merge) mode.
     * @param jobId The DocGen_Job__c record ID
     */
    public DocGenBatch(Id jobId) {
        this(jobId, false, false);
    }

    /**
     * Constructs a batch job with optional merge mode.
     * @param jobId The DocGen_Job__c record ID
     * @param mergeMode Whether to merge all outputs into a single PDF
     */
    public DocGenBatch(Id jobId, Boolean mergeMode) {
        this(jobId, mergeMode, false);
    }

    /**
     * Constructs a batch job with merge mode and merge-only options.
     * @param jobId The DocGen_Job__c record ID
     * @param mergeMode Whether to merge all outputs into a single PDF
     * @param mergeOnly Whether to only generate merged PDF without individual files
     */
    public DocGenBatch(Id jobId, Boolean mergeMode, Boolean mergeOnly) {
        this.jobId = jobId;
        this.mergeMode = mergeMode || (mergeOnly == true);
        this.mergeOnly = (mergeOnly == true);
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{ 'Template__c', 'Query_Condition__c', 'Sort_Order__c', 'Duplex_Padding__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Job__c job = [
            SELECT
                Template__c,
                Template__r.Base_Object_API__c,
                Template__r.Query_Config__c,
                Query_Condition__c,
                Sort_Order__c,
                Duplex_Padding__c
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
        ];
        this.templateId = job.Template__c;
        this.baseObject = job.Template__r.Base_Object_API__c;
        this.condition = job.Query_Condition__c;
        this.queryConfig = job.Template__r.Query_Config__c;
        this.sortOrder = job.Sort_Order__c;
        this.duplexPadding = job.Duplex_Padding__c == true;
    }

    /**
     * Initializes the batch job: sets status, counts records, builds data cache, and returns query locator.
     * @param bc The batch context provided by the platform
     * @return QueryLocator for the records to process
     */
    /**
     * AND the template's Record_Filter__c onto the job's condition.
     *
     * Both fragments are parenthesised before joining: `A OR B` combined with
     * `C` as `A OR B AND C` would silently mean `A OR (B AND C)` and let
     * excluded records straight through — the exact bug this closes, reopened by
     * operator precedence.
     *
     * Passed through the same sanitizeCondition() as the job's own condition, so
     * the filter cannot widen what the query may reach.
     */
    // public, not @TestVisible private: the latter is unreachable from anonymous
    // Apex, which is where the e2e scripts verify behaviour. Still not global, so
    // it stays invisible to subscribers in the managed package.
    public String andTemplateFilter(String jobCondition) {
        String tf;
        try {
            List<DocGen_Template__c> ts = [
                SELECT Record_Filter__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            tf = ts.isEmpty() ? null : ts[0].Record_Filter__c;
        } catch (Exception e) {
            // A filter we cannot read must not silently become "no filter" —
            // but neither should it fail the whole job. Logged, and the job
            // proceeds on its own condition.
            DocGenErrorLogger.warn(
                'DocGenBatch',
                'Read template record filter',
                'Could not read Record_Filter__c; the bulk run may include records the template excludes: ' +
                e.getMessage(),
                templateId,
                null
            );
            DocGenErrorLogger.flush();
            return jobCondition;
        }
        if (String.isBlank(tf)) {
            return jobCondition;
        }
        String safeFilter = sanitizeCondition(tf);
        if (String.isBlank(safeFilter)) {
            return jobCondition;
        }
        if (String.isBlank(jobCondition)) {
            return '(' + safeFilter + ')';
        }
        return '(' + jobCondition + ') AND (' + safeFilter + ')';
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Update Status to Processing
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing'); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        // Validate object name against Schema to prevent injection
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw new DocGenException('Invalid object: ' + baseObject);
        }

        String sanitizedCondition = sanitizeCondition(condition);
        // THE TEMPLATE'S OWN AUDIENCE FILTER, applied to the bulk query.
        //
        // Record_Filter__c was evaluated only on the per-record path in
        // DocGenController, and the batch never consulted it — so a bulk run
        // generated documents for records the template explicitly excludes. It
        // failed silently and at scale: the documents look correct, they are
        // simply for the wrong records.
        //
        // Applied to the WHERE clause rather than per record because the field
        // already IS a SOQL fragment. Filtering at the source costs one query
        // instead of one describe-and-check per record, and — importantly — the
        // job's Total_Records__c count below then reflects what will actually be
        // produced, instead of promising a total the run never reaches.
        sanitizedCondition = andTemplateFilter(sanitizedCondition);
        String query = 'SELECT Id FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        query += ' WITH USER_MODE';

        // ORDER BY the parent records. Batch chunks are handed to execute() in
        // QueryLocator order, and merge mode stamps its sequence counter as it goes
        // (see buildMergeSnippet), so ordering the locator is the whole fix: the
        // merged PDF comes out in this order with no change to the merge pipeline.
        //
        // Re-validated here rather than trusted from the field: Sort_Order__c is
        // writable metadata, and this is the string that reaches the query.
        String safeSortOrder = DocGenBulkController.normalizeSortOrder(baseObject, sortOrder);
        if (String.isNotBlank(safeSortOrder)) {
            query += ' ORDER BY ' + safeSortOrder;
        }

        // Count total records for progress tracking
        String countQuery = 'SELECT Count() FROM ' + baseObject;
        if (String.isNotBlank(sanitizedCondition)) {
            countQuery += ' WHERE ' + sanitizedCondition;
        }
        Integer total = Database.countQuery(countQuery, AccessLevel.USER_MODE);
        update new DocGen_Job__c(Id = jobId, Status__c = 'Processing', Total_Records__c = total); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        // Bulk data pre-cache for V3 configs
        buildDataCache(query, sanitizedCondition);

        return Database.getQueryLocator(query);
    }

    /**
     * Bulk-queries all record data and saves as a JSON ContentVersion on the Job.
     * Only runs for V3 query configs. Gracefully falls back on any failure.
     */
    private void buildDataCache(String query, String sanitizedCondition) {
        try {
            Integer configVersion = DocGenDataRetriever.getConfigVersion(queryConfig);
            if (configVersion < 3) {
                return;
            }

            // Collect all record IDs
            String idQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
            if (String.isNotBlank(sanitizedCondition)) {
                idQuery += ' WHERE ' + sanitizedCondition;
            }
            idQuery += ' LIMIT 50000';

            Set<Id> recordIds = new Set<Id>();
            for (SObject rec : Database.query(idQuery, AccessLevel.USER_MODE)) {
                // NOPMD ApexSOQLInjection - baseObject validated by Schema.getGlobalDescribe() above; condition sanitized
                recordIds.add(rec.Id);
            }
            if (recordIds.isEmpty()) {
                return;
            }

            // Bulk query all record data in one pass
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig.trim());
            Map<Id, Map<String, Object>> bulkData = DocGenDataRetriever.getRecordDataV3Bulk(recordIds, config);

            // Resolve rich text images on each record's data
            for (Map<String, Object> recordData : bulkData.values()) {
                DocGenController.resolveRichTextImages(recordData);
            }

            // Convert to String-keyed map for JSON serialization
            Map<String, Object> serializableMap = new Map<String, Object>();
            for (Id recId : bulkData.keySet()) {
                serializableMap.put(String.valueOf(recId), bulkData.get(recId));
            }

            String jsonStr = JSON.serialize(serializableMap);

            // Heap guard: skip caching if JSON is too large
            if (jsonStr.length() > 4000000) {
                return;
            }

            // Save as ContentVersion linked to Job
            ContentVersion cv = new ContentVersion(
                Title = 'docgen_cache_' + jobId,
                PathOnClient = 'docgen_cache_' + jobId + '.json',
                VersionData = Blob.valueOf(jsonStr),
                IsMajorVersion = true,
                FirstPublishLocationId = jobId
            );
            SObjectAccessDecision cvDec = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentVersion>{ cv }
            );
            insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            cv.Id = cvDec.getRecords()[0].Id;

            // Store CV Id on Job and in Stateful memory
            dataCacheCvId = cv.Id;
            cachedDataJson = jsonStr;

            update new DocGen_Job__c(Id = jobId, Data_Cache_CV__c = cv.Id); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
        } catch (Exception e) {
            // Graceful fallback: continue without cache
            dataCacheCvId = null;
            cachedDataJson = null;
        }
    }

    /**
     * Basic sanitization of dynamic WHERE conditions to prevent SOQL injection.
     */
    private static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) {
            return condition;
        }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw new DocGenException('Invalid filter condition.');
        }
        String upper = condition.toUpperCase().trim();
        List<String> disallowed = new List<String>{
            'SELECT ',
            'INSERT ',
            'UPDATE ',
            'DELETE ',
            'MERGE ',
            'UNDELETE ',
            'WITH ',
            'GROUP BY ',
            'ORDER BY ',
            'LIMIT ',
            'OFFSET ',
            'FOR UPDATE',
            'HAVING ',
            'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (upper.contains(keyword)) {
                throw new DocGenException('Invalid filter condition.');
            }
        }
        return condition;
    }

    /**
     * Generates an individual document for a record, using cached data if available.
     * Also captures HTML snippet for merge mode.
     */
    private void generateIndividualDocument(Id recordId, Map<String, Object> recordData) {
        if (recordData != null) {
            DocGenService.generateDocumentFromData(templateId, recordId, recordData);
        } else {
            DocGenService.generateDocument(templateId, recordId);
        }

        // Merge mode (not merge-only): also capture HTML snippet for merged PDF.
        // Skipped under duplex padding — that path merges from per-record PDF
        // parts saved in execute(), so an HTML snippet here would just be an
        // orphaned ContentVersion the merge job never reads (#382).
        if (mergeMode && !duplexPadding && DocGenService.lastRenderedHtml != null) {
            saveHtmlSnippet(DocGenService.lastRenderedHtml);
            DocGenService.lastRenderedHtml = null;
        }
    }

    /**
     * Writes one HTML snippet as a tiny ContentVersion linked to the Job.
     * No reads — just write. The Queueable assembles them all at the end.
     */
    private void saveHtmlSnippet(String html) {
        String seq = String.valueOf(htmlSequence++).leftPad(5, '0');
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_merge_' + jobId + '_' + seq,
            PathOnClient = 'docgen_merge_' + jobId + '_' + seq + '.html',
            VersionData = Blob.valueOf(html),
            IsMajorVersion = false,
            FirstPublishLocationId = jobId
        );
        SObjectAccessDecision cvDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
    }

    /**
     * Writes one rendered PDF as a tiny ContentVersion linked to the Job, ordered
     * by the same sequence counter as saveHtmlSnippet. DocGenMergeJob reads these
     * by title prefix and hands them to DocGenPdfMerger. Duplex-padding path only.
     */
    private void savePdfPart(Blob pdf) {
        String seq = String.valueOf(htmlSequence++).leftPad(5, '0');
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_pdfpart_' + jobId + '_' + seq,
            PathOnClient = 'docgen_pdfpart_' + jobId + '_' + seq + '.pdf',
            VersionData = pdf,
            IsMajorVersion = false,
            FirstPublishLocationId = jobId
        );
        SObjectAccessDecision cvDec = Security.stripInaccessible(AccessType.CREATABLE, new List<ContentVersion>{ cv });
        insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
    }

    /**
     * Processes a batch of records: generates documents and optionally captures HTML snippets for merge.
     * @param bc The batch context provided by the platform
     * @param scope The list of records to process in this batch execution
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        // Lazy-load cache from ContentVersion if Stateful string was lost
        if (dataCacheCvId != null && cachedDataJson == null) {
            try {
                ContentVersion cv = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Id = :dataCacheCvId
                    WITH USER_MODE
                    LIMIT 1
                ];
                cachedDataJson = cv.VersionData.toString();
            } catch (Exception e) {
                // Intentionally swallowed: cached data CV not found or inaccessible — fall through to fresh query
                dataCacheCvId = null;
            }
        }

        // Deserialize cache once per execute
        Map<String, Object> dataCache = null;
        if (cachedDataJson != null) {
            try {
                dataCache = (Map<String, Object>) JSON.deserializeUntyped(cachedDataJson);
            } catch (Exception e) {
                // Intentionally swallowed: cached JSON deserialization failed (corrupted or schema mismatch) — fall through to fresh query
                dataCache = null;
            }
        }

        // Resolve once per job, not per record — see templateHasChartTags.
        if (templateHasChartTags == null) {
            try {
                templateHasChartTags = DocGenChartImageController.hasChartTags(templateId);
            } catch (Exception e) {
                // A failed probe must not sink the job; charts simply fall back to the
                // text placeholder they produced before this path existed.
                templateHasChartTags = false;
            }
        }

        for (SObject rec : scope) {
            List<Id> chartCvIds = null;
            try {
                Map<String, Object> recordData = null;
                if (dataCache != null) {
                    recordData = (Map<String, Object>) dataCache.get(String.valueOf(rec.Id));
                }

                // Charts are per-record: each record's buckets differ, so the PNGs have
                // to be rasterized inside this record's iteration, not once per job.
                if (templateHasChartTags == true) {
                    Map<String, String> chartCvMap = DocGenChartImageController.prepareChartImagesServerSide(
                        templateId,
                        rec.Id
                    );
                    if (!chartCvMap.isEmpty()) {
                        chartCvIds = DocGenChartImageController.chartCvIdsFrom(chartCvMap);
                        DocGenService.beginChartContext(chartCvMap);
                    }
                }

                if (duplexPadding) {
                    // Duplex padding (#382): render this record as its own PDF part.
                    // DocGenMergeJob stitches the parts and pads odd-length documents.
                    // In "Combined + Individual" mode the per-record file is still saved.
                    Map<String, Object> res = (recordData != null)
                        ? DocGenService.generatePdfBlobFromData(templateId, rec.Id, recordData)
                        : DocGenService.generatePdfBlob(templateId, rec.Id);
                    savePdfPart((Blob) res.get('blob'));
                    if (!mergeOnly) {
                        generateIndividualDocument(rec.Id, recordData);
                    }
                } else if (mergeOnly) {
                    // Merge-only: generate HTML, save snippet — no Blob.toPdf(), no individual file
                    String html = DocGenService.generateHtmlForRecord(templateId, rec.Id, recordData);
                    saveHtmlSnippet(html);
                } else {
                    // Normal: generate + save individual PDF per record
                    generateIndividualDocument(rec.Id, recordData);
                }

                successCount++;
            } catch (Exception e) {
                failCount++;
                recordFailure(rec.Id, e);
            } finally {
                // The chart CVs are transient render inputs and this batch owns them —
                // deleteChartImages is caller-owned and there is no reaper watching a
                // batch. Reap per record so a long job never accumulates: N records x
                // M charts of orphaned ContentVersions is a storage complaint waiting
                // to happen. In the finally so a failed record cleans up too.
                DocGenService.endChartContext();
                if (chartCvIds != null && !chartCvIds.isEmpty()) {
                    try {
                        DocGenChartImageController.deleteChartImages(chartCvIds);
                    } catch (Exception cleanupEx) {
                        // Cleanup is best-effort — DocGenChartCvReaper is the backstop.
                        // Deliberately swallowed: never let a reap failure convert a
                        // successful render into a failed record. (No control-flow
                        // statement here — a continue/return inside finally would
                        // discard the in-flight exception from the try block.)
                        chartCvIds = null;
                    }
                }
            }
        }

        // Update Job record incrementally for real-time progress tracking
        update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            Id = jobId,
            Success_Count__c = successCount,
            Error_Count__c = failCount,
            Error_Log__c = buildErrorLog()
        );
    }

    /**
     * Records a per-record failure with its reason instead of silently counting it.
     * Oversized records (the giant-query condition — too many related rows to render in
     * one transaction) are detected and flagged with actionable guidance, since the bulk
     * batch cannot itself launch the giant-query Batchable. Capped at MAX_ERROR_LINES.
     */
    @TestVisible
    private void recordFailure(Id recordId, Exception e) {
        String reason;
        if (e instanceof HeapPressureException || isHeapError(e)) {
            heapFailCount++;
            // #155 — capture the Id for the giant-query fallback (capped; overflow counted).
            if (oversizedRecordIds.size() < MAX_FALLBACK_RECORDS) {
                oversizedRecordIds.add(recordId);
            } else {
                oversizedOverflowCount++;
            }
            reason =
                'too large for standard bulk generation (too many related rows) — ' +
                'generate this record individually so it routes through the giant-query path';
        } else {
            reason = e.getTypeName() + ': ' + e.getMessage();
        }
        if (errorLog.size() < MAX_ERROR_LINES) {
            errorLog.add(String.valueOf(recordId) + ' — ' + reason);
        }
    }

    /**
     * Heap-pressure errors from Blob.toPdf() surface as generic exceptions (the platform
     * heap LimitException itself is uncatchable; what reaches here is the catchable
     * wrapper/secondary). Mirrors DocGenController.isHeapError, which is private there.
     */
    private static Boolean isHeapError(Exception e) {
        String msg = e.getMessage();
        return String.isNotBlank(msg) && msg.toLowerCase().contains('heap');
    }

    /**
     * Serializes the captured failures into the Error_Log__c field, prefixing an
     * oversized-record summary when present and appending a "+N more" note so a capped
     * log never reads as "these were the only failures".
     */
    @TestVisible
    private String buildErrorLog() {
        if (errorLog.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        if (heapFailCount > 0) {
            lines.add(
                heapFailCount +
                    ' record(s) were too large for standard bulk generation — these are being ' +
                    'queued automatically for individual giant-query generation (#155). Details below.'
            );
        }
        if (oversizedOverflowCount > 0) {
            // No silent caps: say plainly how many oversized records exceeded the
            // auto-recovery cap and still need a manual individual run.
            lines.add(
                'Note: only the first ' +
                    MAX_FALLBACK_RECORDS +
                    ' oversized record(s) were queued for automatic recovery; ' +
                    oversizedOverflowCount +
                    ' more must be generated individually by hand.'
            );
        }
        lines.addAll(errorLog);
        Integer extra = failCount - errorLog.size();
        if (extra > 0) {
            lines.add('… and ' + extra + ' more failure(s) not shown.');
        }
        String log = String.join(lines, '\n');
        // Hard cap to the field length (32,768) — trim from the end, keeping the summary.
        if (log.length() > 32000) {
            log = log.substring(0, 32000) + '\n… (log truncated)';
        }
        return log;
    }

    /**
     * Finalizes the batch job: updates status, chains merge Queueable if needed, sends notification.
     * @param bc The batch context provided by the platform
     */
    public void finish(Database.BatchableContext bc) {
        String status;
        if (successCount == 0 && failCount > 0) {
            status = 'Failed';
        } else if (failCount > 0) {
            status = 'Completed with Errors';
        } else {
            status = 'Completed';
        }

        // Merge mode: chain Queueable to assemble snippets + render one PDF
        if (mergeMode && htmlSequence > 0) {
            try {
                status = 'Merging';

                update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                    Id = jobId,
                    Status__c = status,
                    Success_Count__c = successCount,
                    Error_Count__c = failCount
                );

                // Chain the merge Queueable — it reads all snippets by title prefix
                System.enqueueJob(new DocGenMergeJob(jobId));
            } catch (Exception e) {
                status = 'Completed with Errors';
                update new DocGen_Job__c(
                    Id = jobId,
                    Status__c = status,
                    Success_Count__c = successCount,
                    Error_Count__c = failCount
                ); // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
            }
        } else if (!oversizedRecordIds.isEmpty()) {
            // #155 — some records were too large for standard bulk generation. A batch
            // can't launch a batch, but it can enqueue a Queueable that does: dispatch each
            // oversized record through the giant-query path. The parent stays 'Recovering'
            // until DocGenBulkGiantFallbackJob has dispatched them all, then it flips the
            // job to 'Completed with Errors'. (Merge-mode oversized records are out of
            // scope — they remain flagged in the log, as before.)
            status = 'Recovering';
            update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                Id = jobId,
                Status__c = status,
                Success_Count__c = successCount,
                Error_Count__c = failCount,
                Error_Log__c = buildErrorLog()
            );
            System.enqueueJob(new DocGenBulkGiantFallbackJob(jobId, templateId, oversizedRecordIds));
        } else {
            update new DocGen_Job__c( // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                Id = jobId,
                Status__c = status,
                Success_Count__c = successCount,
                Error_Count__c = failCount
            );
        }

        // Send notification for non-merge jobs (merge jobs notify from DocGenMergeJob)
        if (!mergeMode || htmlSequence == 0) {
            sendJobNotification(status);
        }

        // Clean up data cache ContentVersion
        if (dataCacheCvId != null) {
            try {
                Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :dataCacheCvId WITH USER_MODE]
                .ContentDocumentId;
                if (Schema.sObjectType.ContentDocument.isDeletable()) {
                    delete new ContentDocument(Id = docId); // NOPMD ApexCRUDViolation — CRUD checked above
                }
            } catch (Exception e) {
                // Intentionally swallowed — cleanup failure is non-fatal
                String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
            }
        }
    }

    private void sendJobNotification(String status) {
        try {
            DocGenFlsGuard.assertAccessible(CustomNotificationType.sObjectType, new Set<String>());
            /* code-analyzer-suppress ApexFlsViolation */
            List<CustomNotificationType> types = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = 'DocGen_Job_Complete'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (types.isEmpty()) {
                return;
            }

            DocGenFlsGuard.assertAccessible(
                DocGen_Job__c.sObjectType,
                new Set<String>{ 'CreatedById', 'Label__c', 'Name' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            DocGen_Job__c job = [
                SELECT CreatedById, Label__c, Name
                FROM DocGen_Job__c
                WHERE Id = :jobId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            String jobName = String.isNotBlank(job.Label__c) ? job.Label__c : job.Name;

            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setNotificationTypeId(types[0].Id);
            notification.setTargetId(jobId);
            notification.setTitle('Portwood: ' + jobName + ' — ' + status);
            notification.setBody(
                successCount +
                    ' documents generated' +
                    (failCount > 0 ? ', ' + failCount + ' failed' : '') +
                    (heapFailCount > 0
                        ? ' (' + heapFailCount + ' too large — generate individually for giant-query)'
                        : '') +
                    '. Tap to view.'
            );
            notification.send(new Set<String>{ job.CreatedById });
        } catch (Exception e) {
            // Intentionally swallowed — notification failure is non-fatal
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }
    }
}

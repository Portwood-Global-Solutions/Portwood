/** Freezes the ordered source IDs for a browser PDF job before any Files are rendered. */
public with sharing class DocGenBrowserPdfPlanner implements Queueable {
    private static final Integer MAX_SOURCES = 100000;
    private static final Integer MAX_FETCH = 2000;
    private static final Integer MAX_SOURCES_PER_TRANSACTION = 10000;
    private static final Integer MAX_BLOCKS_PER_TRANSACTION = 2000;

    private Id jobId;
    private String query;
    private Integer blockSize;
    private Integer position = 0;
    private Database.Cursor cursor;

    private DocGenBrowserPdfPlanner(Id jobId, String query, Integer blockSize) {
        this.jobId = jobId;
        this.query = query;
        this.blockSize = blockSize;
    }

    public static Id enqueue(Id jobId, String baseObject, String condition, String sortOrder, Integer blockSize) {
        if (blockSize == null || blockSize < 1 || blockSize > 40) {
            throw new DocGenException('Choose a browser PDF batch size from 1 to 40.');
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            throw new DocGenException('This transaction cannot start another browser PDF job.');
        }
        // The submission service validates the object, filters and sort clauses before planning.
        String query = 'SELECT Id FROM ' + baseObject;
        if (String.isNotBlank(condition)) {
            query += ' WHERE ' + condition;
        }
        query += ' ORDER BY ' + sortOrder + ' LIMIT ' + (MAX_SOURCES + 1);
        AsyncOptions options = new AsyncOptions();
        // A job with size-one render blocks uses at most 50 planning transactions.
        options.MaximumQueueableStackDepth = 51;
        return System.enqueueJob(new DocGenBrowserPdfPlanner(jobId, query, blockSize), options);
    }

    public void execute(QueueableContext context) {
        System.attachFinalizer(new PlanningFailure(jobId));
        if (cursor == null) {
            cursor = Database.getCursorWithBinds(query, new Map<String, Object>(), AccessLevel.USER_MODE);
            query = null;
        }
        Integer total = cursor.getNumRecords();
        if (total == 0) {
            fail(jobId, 'No records matched the browser PDF job filters.');
            return;
        }
        if (total > MAX_SOURCES) {
            fail(jobId, 'A browser PDF job can contain up to 100,000 source records. Narrow the record filter.');
            return;
        }

        List<DocGen_Browser_Pdf_Block__c> blocks = new List<DocGen_Browser_Pdf_Block__c>();
        Integer maxRows = Math.min(MAX_BLOCKS_PER_TRANSACTION, MAX_SOURCES_PER_TRANSACTION / blockSize) * blockSize;
        Integer fetchRows = (MAX_FETCH / blockSize) * blockSize;
        Integer transactionEnd = Math.min(total, position + maxRows);
        while (position < transactionEnd) {
            Integer requested = Math.min(fetchRows, transactionEnd - position);
            List<SObject> rows = cursor.fetch(position, requested);
            if (rows.size() != requested) {
                throw new DocGenException('The browser PDF source selection could not be read in full.');
            }
            for (Integer index = 0; index < rows.size(); index += blockSize) {
                List<Id> sourceIds = new List<Id>();
                Integer endIndex = Math.min(index + blockSize, rows.size());
                for (Integer member = index; member < endIndex; member++) {
                    sourceIds.add((Id) rows[member].get('Id'));
                }
                blocks.add(
                    new DocGen_Browser_Pdf_Block__c(
                        Job__c = jobId,
                        First_Ordinal__c = position + index + 1,
                        Last_Ordinal__c = position + endIndex,
                        Source_Ids__c = JSON.serialize(sourceIds),
                        Success_Count__c = 0,
                        Complete__c = false
                    )
                );
            }
            position += rows.size();
        }
        // Planning rows are package-owned metadata. The selector above enforces caller sharing and FLS.
        Database.insert(blocks, AccessLevel.SYSTEM_MODE);

        if (position < total) {
            System.enqueueJob(this);
        } else {
            Id batchId = Database.executeBatch(new DocGenBrowserPdfBatch(jobId), 1);
            Database.update(
                new DocGen_Job__c(
                    Id = jobId,
                    Total_Records__c = total,
                    Status__c = 'Processing',
                    Browser_Batch_Id__c = String.valueOf(batchId)
                ),
                AccessLevel.SYSTEM_MODE
            );
        }
    }

    private static void fail(Id jobId, String message) {
        Database.update(
            new DocGen_Job__c(Id = jobId, Status__c = 'Failed', Error_Log__c = message),
            AccessLevel.SYSTEM_MODE
        );
    }

    private class PlanningFailure implements Finalizer {
        private Id jobId;

        PlanningFailure(Id jobId) {
            this.jobId = jobId;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
                DocGenErrorLogger.log('DocGenBrowserPdfPlanner', context.getException());
                fail(
                    jobId,
                    'Portwood could not prepare the browser PDF job. Review the error log and submit a new job.'
                );
            }
        }
    }
}

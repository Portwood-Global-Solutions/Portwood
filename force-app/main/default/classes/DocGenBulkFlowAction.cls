/**
 * Invocable action for starting bulk document generation from a Flow.
 * Exposes the full bulk generation pipeline: filtering, batch size,
 * combined PDF, and individual file options.
 */
global with sharing class DocGenBulkFlowAction { // NOPMD AvoidGlobalModifier — global required for @InvocableMethod visibility in subscriber orgs
    global class Request {
        @InvocableVariable(
            label='Template ID'
            description='The Portwood Template record ID. Provide this OR Template API Name.'
        )
        global Id templateId;

        @InvocableVariable(
            label='Template API Name'
            description='The template\'s API Name field — a stable key that survives sandbox-to-production deploys, unlike a record Id. Provide this OR Template ID.'
        )
        global String templateApiName;

        @InvocableVariable(
            label='WHERE Condition'
            description='Optional SOQL WHERE clause to filter records (e.g. Industry = \'Technology\')'
        )
        global String queryCondition;

        @InvocableVariable(
            label='Record IDs'
            required=false
            description='Optional collection of record IDs to generate documents for. When supplied, the bulk job runs against just these records (Id IN clause). Combine with WHERE Condition to filter the set further. Skips the need to save a Query Filter when the calling Flow has already determined which records to target. Note: SOQL does not preserve the order of this collection — use Sort Order to control document order.'
        )
        global List<String> recordIds;

        @InvocableVariable(
            label='Sort Order'
            required=false
            description='Optional SOQL ORDER BY clause controlling the order records are processed — and therefore the page order of the combined PDF. Field API names only, ASC/DESC and NULLS FIRST/LAST supported, up to 3 fields. Relationship fields work (e.g. Account.Name DESC). Leave blank to keep the previous behaviour (record creation order).'
        )
        global String sortOrder;

        @InvocableVariable(label='Job Label' description='A friendly label for this job (shown in Job History)')
        global String jobLabel;

        @InvocableVariable(
            label='Combined PDF Only'
            description='Recommended. Produce one merged PDF with all records. Uses minimal heap. Default: true'
        )
        global Boolean combinedPdfOnly;

        @InvocableVariable(
            label='Also Keep Individual Files'
            description='Generate a separate PDF per record in addition to the combined PDF. Uses more heap.'
        )
        global Boolean keepIndividualFiles;

        @InvocableVariable(
            label='Duplex Padding'
            description='Combined PDF only. Append one blank page after any document with an odd page count so every document starts on the front of a sheet when printed double-sided. Page numbers count real pages only. Ignored for Individual Files. Default: false.'
        )
        global Boolean duplexPadding;

        @InvocableVariable(
            label='Batch Size'
            description='Records per batch transaction. Use 1 for complex templates, 10-50 for simple ones. Default: 1'
        )
        global Integer batchSize;
    }

    global class Response {
        @InvocableVariable(label='Job ID')
        global Id jobId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(
        label='Generate Bulk Documents'
        description='Starts a batch job to generate documents for multiple records. Supports combined PDF, individual files, batch sizing, WHERE filters, and sort order.'
    )
    global static List<Response> generateBulkDocuments(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            String effectiveCondition;
            try {
                // Allow addressing the template by its stable API Name, matching
                // DocGenFlowAction. Resolution happens inside the try so a bad API
                // name surfaces on the Error Message output instead of faulting
                // the interview.
                if (req.templateId == null) {
                    req.templateId = DocGenService.templateIdByApiName(req.templateApiName);
                }
                if (req.templateId == null) {
                    throw new DocGenException('Provide Template ID or Template API Name.');
                }

                // Default: combined PDF only (most efficient)
                Boolean mergeOnly = (req.combinedPdfOnly != false && req.keepIndividualFiles != true);
                Boolean mergePdf = mergeOnly || (req.keepIndividualFiles == true);
                Integer batchSize = (req.batchSize != null && req.batchSize > 0) ? req.batchSize : 1;

                // Build the effective WHERE clause. When the Flow supplies a
                // collection of IDs, fold them into an `Id IN (...)` clause so
                // the bulk pipeline runs only against those records. Combines
                // (AND) with any user-supplied queryCondition.
                effectiveCondition = buildEffectiveCondition(req.queryCondition, req.recordIds);

                // submitJobInternal, NOT submitJob: the @AuraEnabled entry point
                // raises AuraHandledException, which cannot be thrown outside an
                // Aura/VF request and instead produces an UNCATCHABLE
                // LimitException. Calling it from a Flow faulted the whole
                // interview and made these Success/Error Message outputs
                // unreachable for the commonest failure of all — a bad template Id.
                Id jobId = DocGenBulkController.submitJobInternal(
                    req.templateId,
                    effectiveCondition,
                    req.jobLabel,
                    mergePdf,
                    batchSize,
                    mergeOnly,
                    req.sortOrder,
                    req.duplexPadding
                );
                res.jobId = jobId;
                res.success = true;
            } catch (Exception e) {
                DocGenErrorLogger.logBulkFlowFailure(
                    e,
                    req == null ? null : req.templateId,
                    effectiveCondition,
                    req == null ? null : req.jobLabel
                );
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        return responses;
    }

    /**
     * Combines a user-supplied WHERE condition with an Id collection into a single
     * sanitized clause. Each ID is validated against Salesforce's 15/18-char
     * alphanumeric format before inclusion to defend against injection.
     */
    @TestVisible
    private static String buildEffectiveCondition(String userCondition, List<String> recordIds) {
        String idClause = null;
        if (recordIds != null && !recordIds.isEmpty()) {
            List<String> quoted = new List<String>();
            for (String raw : recordIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                String trimmed = raw.trim();
                // 15 or 18 char alphanumeric — Salesforce ID format. Reject anything else.
                if (!Pattern.matches('[a-zA-Z0-9]{15}|[a-zA-Z0-9]{18}', trimmed)) {
                    throw new DocGenException('Invalid record ID supplied: ' + trimmed);
                }
                quoted.add('\'' + trimmed + '\'');
            }
            if (!quoted.isEmpty()) {
                idClause = 'Id IN (' + String.join(quoted, ',') + ')';
            }
        }

        Boolean hasUser = String.isNotBlank(userCondition);
        if (hasUser && idClause != null) {
            return '(' + userCondition + ') AND ' + idClause;
        }
        if (idClause != null) {
            return idClause;
        }
        return userCondition;
    }
}

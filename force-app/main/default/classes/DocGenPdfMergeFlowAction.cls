/** Merge exact Salesforce File versions in the order supplied by Flow. */
global with sharing class DocGenPdfMergeFlowAction { // NOPMD AvoidGlobalModifier - managed Flow action
    global class Request {
        @InvocableVariable(
            label='Content Version IDs'
            description='An ordered Text collection of ContentVersion IDs (068). Supply either this collection or Content Version IDs (Text). Repeated IDs repeat that PDF. Supply at least two IDs.'
        )
        global List<String> contentVersionIds;

        @InvocableVariable(
            label='Content Version IDs (Text)'
            description='ContentVersion IDs (068) in a single Text value, separated by commas, semicolons, spaces, or newlines. Supply either this Text value or the Content Version IDs collection. Supply at least two IDs in merge order.'
        )
        global String contentVersionIdsText;

        @InvocableVariable(
            label='Document Title'
            description='Optional output title, with or without .pdf. Defaults to Merged Document.'
        )
        global String documentTitle;

        @InvocableVariable(
            label='Related Record ID'
            description='Optional. Attach the new PDF to this record. Leave blank to create a standalone Salesforce File.'
        )
        global Id relatedRecordId;

        @InvocableVariable(
            label='Pad Odd Documents'
            description='Optional. Add a blank page after every document with an odd page count for duplex printing. Defaults to false.'
        )
        global Boolean padOddDocuments;
    }

    global class Response {
        @InvocableVariable(label='Content Version ID')
        global Id contentVersionId;
        @InvocableVariable(label='Content Document ID')
        global Id contentDocumentId;
        @InvocableVariable(label='Success')
        global Boolean success;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    // Hex copies, decoded object dictionaries and output assembly all share Apex
    // heap. Check metadata before querying any blobs. Repeated files count again.
    @TestVisible
    private static final Integer SYNC_INPUT_LIMIT = 393216;
    @TestVisible
    private static final Integer ASYNC_INPUT_LIMIT = 786432;
    private static final Integer MAX_PARTS = 100;

    @InvocableMethod(
        label='Portwood: Merge PDFs'
        description='Merge uploaded PDFs entirely in Salesforce, in the supplied ContentVersion ID order. Creates a new PDF File and returns its IDs. Enforces file access and Apex size limits; encrypted, signed and XFA PDFs are rejected.'
        category='Document Generation'
    )
    global static List<Response> mergePdfs(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty())
            return responses;
        Set<Id> ids = new Set<Id>();
        List<List<Id>> idsByRequest = new List<List<Id>>();
        for (Request req : requests) {
            Response res = new Response();
            res.success = false;
            responses.add(res);
            idsByRequest.add(null);
            try {
                List<Id> normalized = validate(req);
                idsByRequest.set(idsByRequest.size() - 1, normalized);
                ids.addAll(normalized);
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
            }
        }
        Map<Id, ContentVersion> metadata;
        try {
            metadata = new Map<Id, ContentVersion>(
                [
                    SELECT Id, FileType, ContentSize, ContentLocation
                    FROM ContentVersion
                    WHERE Id IN :ids
                    WITH USER_MODE
                ]
            );
        } catch (Exception e) {
            for (Response res : responses)
                if (res.errorMessage == null)
                    res.errorMessage = e.getMessage();
            return responses;
        }
        List<ContentVersion> outputs = new List<ContentVersion>();
        List<Integer> outputIndexes = new List<Integer>();
        Integer remaining = isAsync() ? ASYNC_INPUT_LIMIT : SYNC_INPUT_LIMIT;
        for (Integer i = 0; i < requests.size(); i++) {
            if (responses[i].errorMessage != null)
                continue;
            Request req = requests[i];
            List<Id> sourceIds = idsByRequest[i];
            try {
                Integer total = 0;
                for (Id id : sourceIds) {
                    ContentVersion cv = metadata.get(id);
                    if (cv == null)
                        problem('A source ContentVersion is missing or inaccessible: ' + id + '.');
                    if (cv.FileType != 'PDF' || cv.ContentLocation != 'S')
                        problem('Every source must be a PDF stored in Salesforce Files: ' + id + '.');
                    total += cv.ContentSize;
                }
                if (total > remaining || total * 14 > Limits.getLimitHeapSize() - Limits.getHeapSize()) {
                    problem(
                        'PDF inputs exceed the native Apex merge size budget. The combined input limit per action is ' +
                            (isAsync() ? ASYNC_INPUT_LIMIT : SYNC_INPUT_LIMIT) +
                            ' bytes, and available heap can reduce it. Split the packet or reduce PDF sizes.'
                    );
                }
                if (Limits.getCpuTime() > Limits.getLimitCpuTime() - 2000)
                    problem(
                        'Insufficient Apex CPU time remains to merge another packet. Run it in a separate transaction.'
                    );
                Integer requiredQueries = (sourceIds.size() + 39) / 40;
                if (Limits.getQueries() + requiredQueries + 1 > Limits.getLimitQueries())
                    problem(
                        'Insufficient SOQL queries remain to merge another packet. Run it in a separate transaction.'
                    );
                if (Limits.getDmlStatements() >= Limits.getLimitDmlStatements())
                    problem('No DML statements remain to save the merged PDF. Run it in a separate transaction.');
                remaining -= total;
                Blob merged = DocGenPdfMerger.mergePdfCvs(sourceIds, req.padOddDocuments == true);
                String title = title(req.documentTitle);
                ContentVersion output = new ContentVersion(
                    Title = title,
                    PathOnClient = title + '.pdf',
                    VersionData = merged
                );
                if (req.relatedRecordId != null)
                    output.FirstPublishLocationId = req.relatedRecordId;
                outputs.add(output);
                outputIndexes.add(i);
            } catch (Exception e) {
                responses[i].errorMessage = e.getMessage();
            }
        }
        if (outputs.isEmpty())
            return responses;
        List<Database.SaveResult> saved;
        try {
            saved = Database.insert(outputs, false, AccessLevel.USER_MODE);
        } catch (Exception e) {
            for (Integer index : outputIndexes)
                responses[index].errorMessage = e.getMessage();
            return responses;
        }
        Set<Id> savedIds = new Set<Id>();
        for (Integer i = 0; i < saved.size(); i++) {
            Response res = responses[outputIndexes[i]];
            if (saved[i].isSuccess()) {
                res.contentVersionId = saved[i].getId();
                res.success = true;
                savedIds.add(res.contentVersionId);
            } else {
                res.errorMessage = saved[i].getErrors()[0].getMessage();
            }
        }
        Map<Id, ContentVersion> savedVersions = new Map<Id, ContentVersion>(
            [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :savedIds WITH USER_MODE]
        );
        for (Response res : responses) {
            if (res.success == true)
                res.contentDocumentId = savedVersions.get(res.contentVersionId).ContentDocumentId;
        }
        return responses;
    }

    private static Boolean isAsync() {
        return System.isBatch() || System.isFuture() || System.isQueueable() || Limits.getLimitHeapSize() >= 12000000;
    }

    private static List<Id> validate(Request req) {
        if (req == null)
            problem('A merge request is required.');
        Boolean hasCollection = req.contentVersionIds != null && !req.contentVersionIds.isEmpty();
        Boolean hasText = String.isNotBlank(req.contentVersionIdsText);
        if (hasCollection && hasText)
            problem('Set just one ID input: Content Version IDs or Content Version IDs (Text).');
        List<String> supplied = hasCollection
            ? req.contentVersionIds
            : hasText ? req.contentVersionIdsText.trim().split('[,;\\s]+') : new List<String>();
        if (supplied.size() < 2)
            problem('Supply at least two ContentVersion IDs in merge order.');
        if (supplied.size() > MAX_PARTS)
            problem('A packet can contain at most ' + MAX_PARTS + ' PDF versions.');
        List<Id> normalized = new List<Id>();
        for (String input : supplied) {
            if (String.isBlank(input))
                problem('Every ContentVersion ID must be a nonblank Text value.');
            Id id;
            try {
                id = (Id) input.trim();
            } catch (Exception e) {
                problem('Invalid ContentVersion ID: ' + input + '. Supply a 15- or 18-character Salesforce ID.');
            }
            if (id.getSObjectType() != ContentVersion.SObjectType)
                problem('Supply ContentVersion IDs (068), rather than ContentDocument IDs (069).');
            normalized.add(id);
        }
        title(req.documentTitle);
        return normalized;
    }

    private static String title(String input) {
        String value = String.isBlank(input) ? 'Merged Document' : input.trim();
        if (value.toLowerCase().endsWith('.pdf'))
            value = value.substring(0, value.length() - 4).trim();
        value = value.replaceAll('[\\\\/\\x00-\\x1f]', '_');
        if (String.isBlank(value))
            problem('Document Title must contain a file name.');
        if (value.length() > 255)
            problem('Document Title cannot exceed 255 characters.');
        return value;
    }

    private static void problem(String message) {
        throw new DocGenPdfMerger.DocGenPdfMergeException(message);
    }
}

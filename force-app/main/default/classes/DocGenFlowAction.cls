/**
 * Invocable action for generating a single document from a Flow.
 * Supports PDF, DOCX, PPTX, and XLSX output. Full merge tag support
 * including loops, conditionals, images, barcodes, and aggregates.
 */
global with sharing class DocGenFlowAction { // NOPMD AvoidGlobalModifier — global required for @InvocableMethod visibility in subscriber orgs
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
            label='Record ID'
            required=false
            description='The source record ID to merge data from. Required unless JSON Data is supplied.'
        )
        global Id recordId;

        @InvocableVariable(
            label='Save to Record'
            description='If true, attach the generated file to the source record (Files related list). If false (default), the file is inserted as a standalone ContentVersion and can still be downloaded via the returned Content Document ID / Content Version ID — the source record is not touched.'
        )
        global Boolean saveToRecord;

        @InvocableVariable(
            label='Document Title'
            description='Override the generated file name. Leave blank to use the template default.'
        )
        global String documentTitle;

        @InvocableVariable(
            label='Output Format Override'
            description='Optional. Override the template Output Format at runtime. Allowed: PDF, Word, PowerPoint. Word templates can render to PDF or DOCX. PowerPoint templates render only to PPTX. Leave blank to use the template default. Throws if the template has Lock Output Format = true.'
        )
        global String outputFormatOverride;

        @InvocableVariable(
            label='JSON Data'
            required=false
            description='Optional. Pre-built merge data as a JSON string — bypasses the SOQL data retrieval entirely. Use this when a Flow has assembled custom data from external APIs, computed values, or cross-object aggregations and wants to render directly without persisting to records first. Shape mirrors the merge engine: {"Name":"Acme","Amount":50000,"Items":{"records":[{"Product":"Widget","Qty":2}]}}. When supplied, this takes precedence over Record ID for data — but Record ID is still used as the file attachment target if Save to Record is true.'
        )
        global String jsonData;
    }

    global class Response {
        @InvocableVariable(label='Content Document ID')
        global Id contentDocumentId;

        @InvocableVariable(label='Content Version ID')
        global Id contentVersionId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;

        @InvocableVariable(
            label='Job ID'
            description='The Portwood Job record ID (background generation only — poll Status__c via Get Records; the finished file links to this Job record, and to the source record too if Save to Record was true). Null for a synchronous result.'
        )
        global Id jobId;

        @InvocableVariable(
            label='Is Async'
            description='True if this request was routed to background generation because the resulting Word document would be too large to build synchronously (#403). Poll Job ID for completion instead of expecting Content Document ID immediately.'
        )
        global Boolean isAsync;
    }

    @InvocableMethod(
        label='Generate Document'
        description='Generates a document (PDF, DOCX, PPTX, XLSX) from a Portwood template and record. Supports all merge tags including loops, images, barcodes, QR codes, and aggregates.'
    )
    global static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();

        // Phase 1: Generate all documents and collect results
        Map<Integer, Id> docIdsByIndex = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Response res = new Response();
            try {
                // PHD-9 — allow addressing the template by its stable API Name.
                if (req.templateId == null) {
                    req.templateId = DocGenService.templateIdByApiName(req.templateApiName);
                }
                if (req.templateId == null) {
                    throw new DocGenException('Provide Template ID or Template API Name.');
                }
                Boolean useDataMap = String.isNotBlank(req.jsonData);
                if (!useDataMap && req.recordId == null) {
                    throw new DocGenException('Either Record ID or JSON Data must be supplied.');
                }

                Id docId;
                if (useDataMap) {
                    // Parse the supplied JSON into the merge engine's expected Map shape.
                    // JSON.deserializeUntyped returns Map<String,Object> for objects, List<Object>
                    // for arrays — matches what DocGenDataRetriever's other paths produce.
                    Object parsed = JSON.deserializeUntyped(req.jsonData);
                    if (!(parsed instanceof Map<String, Object>)) {
                        throw new DocGenException(
                            'JSON Data must deserialize to an object (Map), not an array or scalar.'
                        );
                    }
                    Map<String, Object> dataMap = (Map<String, Object>) parsed;

                    if (req.recordId != null) {
                        // #403 — DOCX output's ZIP reassembly (assembleZip) can exceed the 6MB
                        // synchronous heap governor for a large enough template; that
                        // System.LimitException is uncatchable, so the decision must be made
                        // BEFORE generation starts, not recovered from after. PDF output is
                        // exempt (never reaches assembleZip for a Word->PDF render) and
                        // DocGenFlowHeapRouter.decide short-circuits it to SYNC.
                        String effectiveFormat = req.outputFormatOverride;
                        if (String.isBlank(effectiveFormat)) {
                            effectiveFormat = resolveTemplateOutputFormat(req.templateId);
                        }
                        Integer templateSizeBytes = DocGenTemplateManager.getTemplateFileSize(req.templateId);
                        DocGenFlowHeapRouter.Decision route = DocGenFlowHeapRouter.decide(
                            templateSizeBytes,
                            effectiveFormat
                        );

                        if (route.route == DocGenFlowHeapRouter.ROUTE_REJECT) {
                            throw new DocGenException(
                                'This document is too large to generate from custom JSON data. ' + route.reason
                            );
                        }

                        if (route.route == DocGenFlowHeapRouter.ROUTE_ASYNC) {
                            // Can't launch a new async job from inside one already running —
                            // mirrors DocGenGiantQueryFlowAction's identical guard.
                            if (System.isBatch() || System.isFuture() || System.isQueueable() || System.isScheduled()) {
                                throw new DocGenException(
                                    'This document needs background generation (' +
                                        route.reason +
                                        ') but the Flow is already running asynchronously, which cannot start a ' +
                                        'new background job. Run this Generate Document step from a screen or ' +
                                        'record-triggered (synchronous) Flow.'
                                );
                            }
                            DocGen_Job__c job = new DocGen_Job__c(
                                Status__c = 'Draft',
                                Template__c = req.templateId,
                                Label__c = 'Custom JSON Flow Document (background, #403)',
                                Parent_Record_Id__c = String.valueOf(req.recordId)
                            );
                            insert job; // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets
                            System.enqueueJob(
                                new DocGenJsonMergeQueueable(
                                    req.templateId,
                                    req.recordId,
                                    req.jsonData,
                                    req.outputFormatOverride,
                                    req.documentTitle,
                                    req.saveToRecord,
                                    job.Id
                                )
                            );
                            res.isAsync = true;
                            res.jobId = job.Id;
                            res.success = true;
                            responses.add(res);
                            continue;
                        }

                        // recordId is the title/context anchor. The actual attachment target is null
                        // when saveToRecord != true — produces a standalone ContentVersion the Flow
                        // can hand off via the returned ContentDocumentId (issue #90).
                        Id fileAttachmentTarget = (req.saveToRecord == true) ? req.recordId : null;
                        docId = DocGenService.generateAndSaveFromData(
                            req.templateId,
                            req.recordId,
                            dataMap,
                            req.outputFormatOverride,
                            req.documentTitle,
                            fileAttachmentTarget
                        );
                    } else {
                        // No record context — render PDF and insert as a standalone ContentVersion.
                        // Caller can pick it up via the returned ContentDocumentId / ContentVersionId.
                        Map<String, Object> result = DocGenService.generatePdfBlobFromData(req.templateId, dataMap);
                        Blob pdfBlob = (Blob) result.get('blob');
                        String title = String.isNotBlank(req.documentTitle)
                            ? req.documentTitle
                            : (String) result.get('title');
                        if (String.isBlank(title)) {
                            title = 'Generated_Document';
                        }
                        ContentVersion cv = new ContentVersion();
                        cv.Title = title;
                        cv.PathOnClient = title + '.pdf';
                        cv.VersionData = pdfBlob;
                        SObjectAccessDecision dec = Security.stripInaccessible(
                            AccessType.CREATABLE,
                            new List<ContentVersion>{ cv }
                        );
                        insert dec.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible
                        Id newCvId = ((ContentVersion) dec.getRecords()[0]).Id;
                        ContentVersion saved = [
                            SELECT Id, ContentDocumentId
                            FROM ContentVersion
                            WHERE Id = :newCvId
                            WITH USER_MODE
                            LIMIT 1
                        ];
                        docId = saved.ContentDocumentId;
                        res.contentVersionId = saved.Id;
                    }
                } else {
                    // attachmentRecordId is null when saveToRecord != true — keeps the file out of the
                    // record's Files related list while still using recordId for merge data (issue #90).
                    Id attachmentRecordId = (req.saveToRecord == true) ? req.recordId : null;
                    docId = DocGenService.generateDocument(
                        req.templateId,
                        req.recordId,
                        req.outputFormatOverride,
                        req.documentTitle,
                        attachmentRecordId
                    );
                }
                res.contentDocumentId = docId;
                res.success = true;
                docIdsByIndex.put(i, docId);
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        // Phase 2: Bulk query ContentVersion IDs for all generated documents
        Set<Id> allDocIds = new Set<Id>(docIdsByIndex.values());
        allDocIds.remove(null);
        if (!allDocIds.isEmpty()) {
            Map<Id, Id> cvIdByDocId = new Map<Id, Id>();
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :allDocIds
                WITH USER_MODE
            ]) {
                // Keep only the first CV per document (matching original LIMIT 1 behavior)
                if (!cvIdByDocId.containsKey(cv.ContentDocumentId)) {
                    cvIdByDocId.put(cv.ContentDocumentId, cv.Id);
                }
            }
            for (Integer i : docIdsByIndex.keySet()) {
                Id docId = docIdsByIndex.get(i);
                if (docId != null && cvIdByDocId.containsKey(docId)) {
                    responses[i].contentVersionId = cvIdByDocId.get(docId);
                }
            }
        }

        // Phase 3: Bulk link documents to source records where requested
        // First, collect which doc+record pairs need linking
        Set<Id> linkDocIds = new Set<Id>();
        Map<Integer, Id> saveToRecordByIndex = new Map<Integer, Id>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Id docId = docIdsByIndex.get(i);
            if (req.saveToRecord == true && docId != null && responses[i].success == true) {
                linkDocIds.add(docId);
                saveToRecordByIndex.put(i, req.recordId);
            }
        }

        if (!linkDocIds.isEmpty()) {
            // Bulk query existing links to avoid duplicates
            Set<String> existingLinkKeys = new Set<String>();
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId, LinkedEntityId
                FROM ContentDocumentLink
                WHERE ContentDocumentId IN :linkDocIds
                WITH USER_MODE
            ]) {
                existingLinkKeys.add(String.valueOf(cdl.ContentDocumentId) + ':' + String.valueOf(cdl.LinkedEntityId));
            }

            // Build list of new links needed
            List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
            for (Integer i : saveToRecordByIndex.keySet()) {
                Id docId = docIdsByIndex.get(i);
                Id recordId = saveToRecordByIndex.get(i);
                String linkKey = String.valueOf(docId) + ':' + String.valueOf(recordId);
                if (!existingLinkKeys.contains(linkKey)) {
                    linksToInsert.add(
                        new ContentDocumentLink(
                            ContentDocumentId = docId,
                            LinkedEntityId = recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        )
                    );
                }
            }

            if (!linksToInsert.isEmpty()) {
                SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, linksToInsert);
                insert decision.getRecords(); // NOPMD ApexCRUDViolation - FLS enforced via stripInaccessible
            }
        }

        return responses;
    }

    /**
     * Cheap Output_Format__c lookup for the #403 sync/async routing decision —
     * only reached when the caller didn't already supply outputFormatOverride.
     * Returns null (treated as non-PDF / DOCX-shaped by DocGenFlowHeapRouter)
     * if the template can't be resolved; the actual generation call below will
     * surface a proper error for that case either way.
     */
    private static String resolveTemplateOutputFormat(Id templateId) {
        if (templateId == null || !Schema.sObjectType.DocGen_Template__c.isAccessible()) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Output_Format__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Output_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return templates.isEmpty() ? null : templates[0].Output_Format__c;
    }
}

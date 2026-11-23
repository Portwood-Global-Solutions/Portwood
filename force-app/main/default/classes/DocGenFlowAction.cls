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

        // String, not Id: a malformed value must reach our own validation and come back as a
        // readable Error Message, rather than failing Flow's type conversion before we run.
        @InvocableVariable(
            label='Save as New Version Of'
            required=false
            description='Optional. The ID of an existing file (ContentDocument ID, starts with 069; a ContentVersion ID starting with 068 also works). When filled in, the generated document is saved as a new version of that file instead of a new file, and Content Version ID returns the new version. Leave blank to create a new file (default). The running user needs edit access to the file (owner or Collaborator).'
        )
        global String saveAsNewVersionOf;
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
                // #593 — validate before rendering so a bad ID fails fast and clearly.
                Id versionOfDocId = resolveVersionTarget(req.saveAsNewVersionOf);

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
                        // recordId is the title/context anchor. The actual attachment target is null
                        // when saveToRecord != true — produces a standalone ContentVersion the Flow
                        // can hand off via the returned ContentDocumentId (issue #90).
                        Id fileAttachmentTarget = (req.saveToRecord == true) ? req.recordId : null;
                        DocGenService.saveAsNewVersionOf = versionOfDocId;
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
                        if (versionOfDocId != null) {
                            res.contentVersionId = DocGenService.insertAsNewVersion(cv, versionOfDocId);
                            docId = versionOfDocId;
                        } else {
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
                    }
                } else {
                    // attachmentRecordId is null when saveToRecord != true — keeps the file out of the
                    // record's Files related list while still using recordId for merge data (issue #90).
                    Id attachmentRecordId = (req.saveToRecord == true) ? req.recordId : null;
                    DocGenService.saveAsNewVersionOf = versionOfDocId;
                    docId = DocGenService.generateDocument(
                        req.templateId,
                        req.recordId,
                        req.outputFormatOverride,
                        req.documentTitle,
                        attachmentRecordId
                    );
                }
                if (res.contentVersionId == null) {
                    // The exact version the service just wrote — not a re-query by document.
                    res.contentVersionId = DocGenService.lastSavedContentVersionId;
                }
                res.contentDocumentId = docId;
                res.success = true;
                docIdsByIndex.put(i, docId);
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            } finally {
                // One-shot settings: never let one request's state reach the next.
                DocGenService.saveAsNewVersionOf = null;
                DocGenService.lastSavedContentVersionId = null;
            }
            responses.add(res);
        }

        // Phase 2: Fallback for any response that didn't capture its version Id directly.
        // IsLatest = TRUE matters: for a file with several versions an unfiltered query can
        // return v1 instead of the version just created (#593).
        Set<Id> allDocIds = new Set<Id>();
        for (Integer i : docIdsByIndex.keySet()) {
            if (responses[i].contentVersionId == null && docIdsByIndex.get(i) != null) {
                allDocIds.add(docIdsByIndex.get(i));
            }
        }
        if (!allDocIds.isEmpty()) {
            Map<Id, Id> cvIdByDocId = new Map<Id, Id>();
            for (ContentVersion cv : [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE ContentDocumentId IN :allDocIds AND IsLatest = TRUE
                WITH USER_MODE
            ]) {
                cvIdByDocId.put(cv.ContentDocumentId, cv.Id);
            }
            for (Integer i : docIdsByIndex.keySet()) {
                Id docId = docIdsByIndex.get(i);
                if (responses[i].contentVersionId == null && docId != null && cvIdByDocId.containsKey(docId)) {
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
     * #593 — turns the "Save as New Version Of" input into the ContentDocument Id to version,
     * or null when blank (create a new file, the default). Accepts a ContentDocument Id (069)
     * or a ContentVersion Id (068, resolved to its document). Queries run in USER_MODE, so a
     * file the running user cannot see reports the same as a missing one — we never confirm
     * that a file the user has no access to exists. Edit permission is enforced at insert time
     * by DocGenService.insertAsNewVersion.
     */
    private static Id resolveVersionTarget(String rawId) {
        if (String.isBlank(rawId)) {
            return null;
        }
        String trimmed = rawId.trim();
        Id targetId;
        try {
            targetId = Id.valueOf(trimmed);
        } catch (StringException e) {
            throw new DocGenException(
                'Save as New Version Of: "' +
                    trimmed +
                    '" is not a valid file ID. Use the file\'s ContentDocument ID (18 characters, starts with 069).'
            );
        }

        Schema.SObjectType targetType = targetId.getSObjectType();
        if (targetType == ContentDocument.SObjectType) {
            List<ContentDocument> docs = [SELECT Id FROM ContentDocument WHERE Id = :targetId WITH USER_MODE LIMIT 1];
            if (!docs.isEmpty()) {
                return docs[0].Id;
            }
        } else if (targetType == ContentVersion.SObjectType) {
            List<ContentVersion> versions = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :targetId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!versions.isEmpty()) {
                return versions[0].ContentDocumentId;
            }
        } else {
            String typeName = targetType == null ? 'non-file' : targetType.getDescribe().getLabel();
            throw new DocGenException(
                'Save as New Version Of: ' +
                    trimmed +
                    ' is a ' +
                    typeName +
                    ' ID, not a file ID. Use the file\'s ContentDocument ID (starts with 069).'
            );
        }
        throw new DocGenException(
            'Save as New Version Of: no file found with ID ' +
                trimmed +
                '. It may have been deleted, or you may not have access to it.'
        );
    }
}

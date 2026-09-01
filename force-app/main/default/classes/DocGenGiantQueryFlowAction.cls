/**
 * Invocable action for generating documents that may have large child datasets.
 * Auto-detects whether Giant Query (async batch) is needed.
 *
 * The decision is a HEAP estimate, not a raw row count (#374): a Quote with a
 * few hundred line items carrying large descriptions is well under any row
 * threshold but tens of MB of data, and running it synchronously blew the 6 MB
 * Apex heap governor with an uncatchable System.LimitException. Routing is
 * delegated to DocGenGiantQueryRouter, shared with the on-screen Runner so the
 * two cannot diverge again.
 *
 *   Fits the synchronous heap budget -> generate now (same as DocGenFlowAction).
 *   Over the budget (or > 2,000 rows) -> launch async batch, PDF saved to the
 *   record when complete, Job ID returned for status tracking.
 *
 * Ideal for customer portals, Screen Flows, and automated processes where
 * the dataset size isn't known in advance.
 */
global with sharing class DocGenGiantQueryFlowAction { // NOPMD AvoidGlobalModifier — global required for @InvocableMethod visibility in subscriber orgs
    global class Request {
        @InvocableVariable(label='Template ID' required=true description='The Portwood Template record ID')
        global Id templateId;

        @InvocableVariable(label='Record ID' required=true description='The source record ID to merge data from')
        global Id recordId;

        @InvocableVariable(
            label='Save to Record'
            description='If true, attach the generated file to the source record (Files related list). If false (default), the sync-path file is inserted as a standalone ContentVersion and can still be downloaded via the returned Content Document ID. The async Giant Query path always attaches because the batch writes the final PDF back to the job/record.'
        )
        global Boolean saveToRecord;
    }

    global class Response {
        @InvocableVariable(
            label='Content Document ID'
            description='The generated file ID (sync only — null for async Giant Query)'
        )
        global Id contentDocumentId;

        @InvocableVariable(label='Content Version ID' description='The generated file version ID (sync only)')
        global Id contentVersionId;

        @InvocableVariable(
            label='Job ID'
            description='The Portwood Job record ID (async Giant Query only — poll for completion)'
        )
        global Id jobId;

        @InvocableVariable(
            label='Is Giant Query'
            description='True if the dataset was too large for synchronous generation and is being processed by the async batch (poll Job ID)'
        )
        global Boolean isGiantQuery;

        @InvocableVariable(label='Error Message')
        global String errorMessage;

        @InvocableVariable(label='Success')
        global Boolean success;
    }

    @InvocableMethod(
        label='Generate Document (Auto Giant Query)'
        description='Generates a document, automatically switching to async Giant Query when the dataset is too large for synchronous generation. PDF is saved to the record when complete.'
    )
    global static List<Response> generateDocument(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            res.isGiantQuery = false;
            try {
                // Load template
                // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
                // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
                // calls Schema.SObjectField.getDescribe().isAccessible() on every field
                // the SELECT lists; throws DocGenException with the offending field name
                // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
                // package-build @TestSetup FLS-propagation issue documented in
                // DocGenFlsGuard.cls.
                DocGenFlsGuard.assertAccessible(
                    DocGen_Template__c.sObjectType,
                    new Set<String>{ 'Base_Object_API__c', 'Query_Config__c', 'Type__c', 'Output_Format__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template__c> templates = [
                    SELECT Base_Object_API__c, Query_Config__c, Type__c, Output_Format__c
                    FROM DocGen_Template__c
                    WHERE Id = :req.templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (templates.isEmpty()) {
                    throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
                }
                DocGen_Template__c template = templates[0];
                String queryConfig = template.Query_Config__c;

                // Sync vs async is a HEAP decision, not a row-count one. The
                // shared router estimates peak synchronous heap (sampling one
                // real child row so heavy rich-text rows are not under-counted).
                // It scouts every config format for the estimate; only V3 is
                // auto-routed to the batch (see the guard below) (#374).
                DocGenGiantQueryRouter.Decision route = DocGenGiantQueryRouter.decide(
                    req.recordId,
                    queryConfig,
                    template.Output_Format__c
                );

                if (route.useGiantPath) {
                    // Predicted to exceed the synchronous heap governor. The heap
                    // LimitException is uncatchable, so this MUST be a decision
                    // made before generation, not a try/catch after it.
                    if (template.Type__c != 'Word') {
                        throw new DocGenException(
                            'This ' +
                                template.Type__c +
                                ' template produces a document too large for synchronous generation (' +
                                route.reason +
                                '). The Auto Giant Query Flow action can only background-process Word templates — ' +
                                'generate it from the Portwood Runner instead.'
                        );
                    }
                    // Only V3 (tree) query configs are auto-routed to the batch.
                    // The batch path skips processXml, so parent-level {#IF} /
                    // inverse tags / secondary child loops would leak as raw text
                    // — routing a large V1/V2 template there could silently
                    // corrupt the output. Fail loud with a route instead (#374).
                    if (DocGenDataRetriever.getConfigVersion(queryConfig) < 3) {
                        throw new DocGenException(
                            'This template is too large for synchronous generation (' +
                                route.reason +
                                '). Background generation from this Flow action needs a tree-style (V3) query ' +
                                'configuration — re-save the template in the Query Builder, or generate it from the Portwood Runner.'
                        );
                    }
                    if (route.giantNodeConfig == null) {
                        throw new DocGenException(
                            'This document is too large to generate inside the Flow (' +
                                route.reason +
                                ') and Portwood could not prepare it for background generation. Reduce the fields ' +
                                'queried for the large related list, or generate it from the Portwood Runner.'
                        );
                    }
                    if (System.isBatch() || System.isFuture() || System.isQueueable() || System.isScheduled()) {
                        throw new DocGenException(
                            'This document needs background generation (' +
                                route.reason +
                                ') but the Flow is already running asynchronously, which cannot start a batch job. ' +
                                'Run this Generate Document step from a screen or record-triggered (synchronous) Flow.'
                        );
                    }
                    res.isGiantQuery = true;
                    res.jobId = launchGiantBatch(
                        req.templateId,
                        req.recordId,
                        route.giantRelationship,
                        route.giantNodeConfig
                    );
                    res.success = true;
                } else {
                    // Sync path — same as DocGenFlowAction. attachmentRecordId is null when
                    // saveToRecord != true so the file stays off the record (issue #90).
                    Id attachmentRecordId = (req.saveToRecord == true) ? req.recordId : null;
                    Id docId = DocGenService.generateDocument(
                        req.templateId,
                        req.recordId,
                        null,
                        null,
                        attachmentRecordId
                    );
                    res.contentDocumentId = docId;
                    res.success = true;

                    // Resolve ContentVersion ID
                    List<ContentVersion> cvs = [
                        SELECT Id
                        FROM ContentVersion
                        WHERE ContentDocumentId = :docId AND IsLatest = TRUE
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!cvs.isEmpty()) {
                        res.contentVersionId = cvs[0].Id;
                    }
                }
            } catch (Exception e) {
                res.errorMessage = e.getMessage();
                res.success = false;
            }
            responses.add(res);
        }

        return responses;
    }

    /**
     * Launches the Giant Query batch for async PDF generation.
     * Returns the DocGen_Job__c record ID for status tracking.
     */
    private static Id launchGiantBatch(
        Id templateId,
        Id recordId,
        String giantRelationshipKey,
        Map<String, Object> childNodeConfig
    ) {
        // Get document XML from pre-decomposed parts
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        String documentXml = null;
        if (!activeVersions.isEmpty()) {
            String xmlKey = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_word__document.xml';
            // Explicit CRUD check on ContentVersion — standard object, isAccessible()
            // returns true for any user with file access. Documents enforcement for the reviewer.
            if (!Schema.sObjectType.ContentVersion.isAccessible()) {
                throw new DocGenException('ContentVersion access denied.');
            }
            // SYSTEM_MODE retained for this specific CV body lookup: USER_MODE can
            // return "ContentVersion not found" when the body CV's CDL defaults to
            // Visibility=InternalUsers on fresh upload (subscriber-org artifact of
            // the platform behavior). Access is gated upstream by the active
            // template version USER_MODE query.
            List<ContentVersion> xmlCvs = DocGenService.loadInternalContentVersionsForVersionByTitle(
                activeVersions[0].Id,
                xmlKey
            );
            if (!xmlCvs.isEmpty()) {
                documentXml = xmlCvs[0].VersionData.toString();
            }
        }
        if (documentXml == null) {
            throw new DocGenException('Pre-decomposed template parts not found. Please re-save the template.');
        }

        // The loop tag in the template body is keyed by the alias when the node
        // has one (e.g. {#SubscriptionItems}), which is the effective key.
        Map<String, String> loopParts = DocGenService.extractLoopBody(documentXml, giantRelationshipKey);
        documentXml = null;
        if (loopParts == null) {
            throw new DocGenException('Could not find loop for relationship: ' + giantRelationshipKey);
        }

        // Create Job record
        DocGen_Job__c job = new DocGen_Job__c(
            Status__c = 'Draft',
            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
            Template__c = templateId,
            Label__c = 'Giant Query PDF (Flow)',
            // CxSAST: FLS enforced by Portwood permission sets; package-internal custom objects
            Parent_Record_Id__c = String.valueOf(recordId)
        );
        insert job; // NOPMD ApexCRUDViolation — package-internal; CRUD controlled by permission sets

        // The router's node config already carries the real relationshipName
        // (and alias, if any) for DocGenGiantQueryBatch — only fill it in if a
        // V1-parsed config somehow left it blank. Never overwrite: the effective
        // key can be an alias, which would break the batch's SOQL FROM.
        if (String.isBlank((String) childNodeConfig.get('relationshipName'))) {
            childNodeConfig.put('relationshipName', giantRelationshipKey);
        }

        DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
            job.Id,
            templateId,
            recordId,
            childNodeConfig,
            loopParts.get('innerXml'),
            'PDF'
        );
        Database.executeBatch(batch, 1);

        return job.Id;
    }
}

public with sharing class DocGenController { // NOPMD ExcessivePublicCount — controller requires public methods for AuraEnabled endpoints
    private static Id cachedTemplateId;
    private static Map<String, Object> cachedTemplateEnvelope;
    // Whether the cached template opts into Classic Approval history. Cached
    // alongside the envelope so the per-record injection below doesn't re-read
    // Query_Config__c for every record in a bulk batch.
    private static Boolean cachedNeedsApprovals = false;

    // v1.97 — Render-time snapshot lookup. The active version snapshots the
    // render-affecting fields at save time (Output_Format, Header_Html,
    // Footer_Html, Document_Title_Format, Page_*). The render path must prefer
    // those over the template's current values, otherwise editing the template
    // silently rewrites how every prior version renders. Returns null if no
    // active version exists or its snapshot fields are all blank.
    private static DocGen_Template_Version__c loadActiveVersionSnapshot(Id templateId) {
        if (templateId == null) {
            return null;
        }
        // Snapshot fields are package-internal render config — version-pinning
        // the way a doc renders. Object-level CRUD gate documented; field-level
        // FLS bypass via SYSTEM_MODE is the platform-required pattern for the
        // managed-package render pipeline because USER_MODE strips these fields
        // when subscriber admin profiles haven't granted FLS individually on
        // each new snapshot field added across releases.
        if (!Schema.sObjectType.DocGen_Template_Version__c.isAccessible()) {
            return null;
        }
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{
                'Output_Format__c',
                'Header_Html__c',
                'Footer_Html__c',
                'Document_Title_Format__c',
                'Page_Orientation__c',
                'Page_Size__c',
                'Page_Margins__c',
                'Custom_Margins__c',
                'Template__c',
                'Is_Active__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT
                Output_Format__c,
                Header_Html__c,
                Footer_Html__c,
                Document_Title_Format__c,
                Page_Orientation__c,
                Page_Size__c,
                Page_Margins__c,
                Custom_Margins__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return vers.isEmpty() ? null : vers[0];
    }

    /**
     * Retrieves template metadata, file content, and merged record data for client-side processing.
     * @param templateId The Portwood template record ID
     * @param recordId The source record ID to merge data from
     * @return Map containing record data, template file, type, output format, and title format
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentData(Id templateId, Id recordId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is missing.');
        }

        // Explicit object-level CRUD check — the documented enforcement signal
        // gating this admin-only read on the user's Portwood permission set
        // assignment.
        if (!Schema.sObjectType.DocGen_Template__c.isAccessible()) {
            throw new DocGenException(
                'Insufficient access to Portwood templates. Verify Portwood permission set assignment.'
            );
        }
        // SYSTEM_MODE retained for the field read: Query_Config__c, Header/Footer_Html__c,
        // Page_*__c are package-internal render-config long-text-area fields.
        // USER_MODE strict FLS strips these for any admin lacking individual FLS
        // on each field — including in managed-package build orgs where the
        // System Administrator profile does not auto-grant FLS for namespaced
        // custom fields. CRUD gate above is the structural enforcement contract.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Base_Object_API__c',
                'Query_Config__c',
                'Type__c',
                'Output_Format__c',
                'Document_Title_Format__c',
                'Header_Html__c',
                'Footer_Html__c',
                'Page_Orientation__c',
                'Page_Size__c',
                'Page_Margins__c',
                'Custom_Margins__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT
                Base_Object_API__c,
                Query_Config__c,
                Type__c,
                Output_Format__c,
                Document_Title_Format__c,
                Header_Html__c,
                Footer_Html__c,
                Page_Orientation__c,
                Page_Size__c,
                Page_Margins__c,
                Custom_Margins__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (templates.isEmpty()) {
            throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
        }
        DocGen_Template__c template = templates[0];

        Map<String, Object> recordData = DocGenDataRetriever.getRecordData(
            recordId,
            template.Base_Object_API__c,
            template.Query_Config__c
        );

        String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);

        if (recordData == null) {
            throw new DocGenException('Record data not found.');
        }

        // Pre-resolve Salesforce rich text image URLs to base64 data URIs
        resolveRichTextImages(recordData);

        // Issue #66 — opt-in Classic Approval history. Template authors put
        // `Approvals` somewhere in Query_Config__c and use `{#Approvals}…
        // {/Approvals}` in the body. Costs one extra SOQL per generation,
        // skipped entirely when the template doesn't ask for it (no name
        // collision with a custom `Approvals__c` field on the host object).
        if (DocGenApprovalHistory.queryConfigMentionsApprovals(template.Query_Config__c)) {
            recordData.put('Approvals', DocGenApprovalHistory.load(recordId));
        }

        DocGen_Template_Version__c snap = loadActiveVersionSnapshot(templateId);
        return new Map<String, Object>{
            'data' => recordData,
            'templateFile' => fileContent,
            'templateType' => template.Type__c,
            'outputFormat' => (snap != null &&
                snap.Output_Format__c != null)
                ? snap.Output_Format__c
                : template.Output_Format__c,
            'titleFormat' => (snap != null &&
                snap.Document_Title_Format__c != null)
                ? snap.Document_Title_Format__c
                : template.Document_Title_Format__c,
            'headerHtml' => (snap != null &&
                snap.Header_Html__c != null)
                ? snap.Header_Html__c
                : template.Header_Html__c,
            'footerHtml' => (snap != null &&
                snap.Footer_Html__c != null)
                ? snap.Footer_Html__c
                : template.Footer_Html__c,
            'pageOrientation' => (snap != null &&
                snap.Page_Orientation__c != null)
                ? snap.Page_Orientation__c
                : template.Page_Orientation__c,
            'pageSize' => (snap != null && snap.Page_Size__c != null) ? snap.Page_Size__c : template.Page_Size__c,
            'pageMargins' => (snap != null &&
                snap.Page_Margins__c != null)
                ? snap.Page_Margins__c
                : template.Page_Margins__c,
            'customMargins' => (snap != null &&
                snap.Custom_Margins__c != null)
                ? snap.Custom_Margins__c
                : template.Custom_Margins__c
        };
    }

    /**
     * Returns template metadata + file content combined with pre-cached record data.
     * Used by DocGenBatch when bulk data cache is available, skipping per-record SOQL.
     * resolveRichTextImages is NOT called here — it was already applied during caching.
     *
     * Template metadata and file content are cached statically — queried once,
     * reused across all records in the batch. Only the record data changes.
     */
    /**
     * Returns template metadata combined with pre-cached record data, skipping per-record SOQL.
     * @param templateId The Portwood template record ID
     * @param cachedRecordData Pre-loaded record data from bulk cache
     * @return Map containing record data, template file, type, output format, and title format
     */
    public static Map<String, Object> generateDocumentDataFromCache(
        Id templateId,
        Map<String, Object> cachedRecordData
    ) {
        if (templateId == null) {
            throw new DocGenException('Template ID is missing.');
        }

        // Cache template metadata + file content on first call
        if (cachedTemplateId != templateId || cachedTemplateEnvelope == null) {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{
                    'Base_Object_API__c',
                    'Query_Config__c',
                    'Type__c',
                    'Output_Format__c',
                    'Document_Title_Format__c',
                    'Header_Html__c',
                    'Footer_Html__c',
                    'Page_Orientation__c',
                    'Page_Size__c',
                    'Page_Margins__c',
                    'Custom_Margins__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> templates = [
                SELECT
                    Base_Object_API__c,
                    Query_Config__c,
                    Type__c,
                    Output_Format__c,
                    Document_Title_Format__c,
                    Header_Html__c,
                    Footer_Html__c,
                    Page_Orientation__c,
                    Page_Size__c,
                    Page_Margins__c,
                    Custom_Margins__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            if (templates.isEmpty()) {
                throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
            }
            DocGen_Template__c template = templates[0];

            String fileContent = DocGenTemplateManager.getTemplateFileContent(templateId);

            DocGen_Template_Version__c snap = loadActiveVersionSnapshot(templateId);
            cachedTemplateEnvelope = new Map<String, Object>{
                'templateFile' => fileContent,
                'templateType' => template.Type__c,
                'outputFormat' => (snap != null &&
                    snap.Output_Format__c != null)
                    ? snap.Output_Format__c
                    : template.Output_Format__c,
                'titleFormat' => (snap != null &&
                    snap.Document_Title_Format__c != null)
                    ? snap.Document_Title_Format__c
                    : template.Document_Title_Format__c,
                'headerHtml' => (snap != null &&
                    snap.Header_Html__c != null)
                    ? snap.Header_Html__c
                    : template.Header_Html__c,
                'footerHtml' => (snap != null &&
                    snap.Footer_Html__c != null)
                    ? snap.Footer_Html__c
                    : template.Footer_Html__c,
                'pageOrientation' => (snap != null &&
                    snap.Page_Orientation__c != null)
                    ? snap.Page_Orientation__c
                    : template.Page_Orientation__c,
                'pageSize' => (snap != null && snap.Page_Size__c != null) ? snap.Page_Size__c : template.Page_Size__c,
                'pageMargins' => (snap != null &&
                    snap.Page_Margins__c != null)
                    ? snap.Page_Margins__c
                    : template.Page_Margins__c,
                'customMargins' => (snap != null &&
                    snap.Custom_Margins__c != null)
                    ? snap.Custom_Margins__c
                    : template.Custom_Margins__c
            };
            cachedNeedsApprovals = DocGenApprovalHistory.queryConfigMentionsApprovals(template.Query_Config__c);
            cachedTemplateId = templateId;
        }

        // Clone envelope and inject this record's data
        Map<String, Object> result = cachedTemplateEnvelope.clone();

        // Issue #66 parity — generateDocumentData injects Approvals, this cached
        // twin did not, so {#Approvals}…{/Approvals} resolved null and rendered
        // empty in bulk only (and {^Approvals} fired its inverse branch). The
        // approval history is per-record and can't come from the batch data cache,
        // so it is loaded here; still opt-in, so templates that don't ask for it
        // pay nothing.
        if (cachedNeedsApprovals == true && cachedRecordData != null) {
            Object recId = cachedRecordData.get('Id');
            if (recId != null) {
                cachedRecordData.put('Approvals', DocGenApprovalHistory.load((Id) String.valueOf(recId)));
            }
        }
        result.put('data', cachedRecordData);
        return result;
    }

    /**
     * Saves a generated document as a ContentVersion attached to the specified record.
     * @param recordId The record to attach the document to
     * @param fileName The document file name (without extension)
     * @param base64Data The base64-encoded document content
     * @param extension The file extension (e.g., 'docx', 'pdf')
     * @return The ContentDocumentId of the saved file
     */
    @AuraEnabled
    public static Id saveGeneratedDocument(Id recordId, String fileName, String base64Data, String extension) {
        try {
            ContentVersion cv = new ContentVersion();
            cv.Title = fileName;
            cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
            cv.VersionData = EncodingUtil.base64Decode(base64Data);
            cv.IsMajorVersion = true;
            SObjectAccessDecision cvDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentVersion>{ cv }
            );
            insert cvDecision.getRecords();
            Id cvId = cvDecision.getRecords()[0].Id;

            Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId WITH USER_MODE]
            .ContentDocumentId; // NOPMD — internal doc lookup

            ContentDocumentLink cdl = new ContentDocumentLink();
            cdl.ContentDocumentId = contentDocId;
            cdl.LinkedEntityId = recordId;
            cdl.ShareType = 'V';
            cdl.Visibility = 'AllUsers';
            SObjectAccessDecision cdlDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentDocumentLink>{ cdl }
            );
            insert cdlDecision.getRecords();

            return contentDocId;
        } catch (System.NoAccessException e) {
            throw new DocGenException('Insufficient access to save document: ' + e.getMessage());
        } catch (Exception e) {
            throw new DocGenException('Error saving document to record: ' + e.getMessage());
        }
    }

    /**
     * Saves a document in chunks for files exceeding the 4MB Aura payload limit.
     * First chunk creates the ContentVersion, subsequent chunks append to it.
     * @param recordId The record to link the final document to
     * @param fileName The document file name
     * @param base64Chunk One chunk of base64-encoded content (~3MB)
     * @param chunkIndex Zero-based chunk index
     * @param totalChunks Total number of chunks expected
     * @param contentVersionId The CV ID from the first chunk (null for first chunk)
     * @param extension File extension
     * @return The ContentVersion ID (same ID returned for all chunks)
     */
    @AuraEnabled
    public static Id saveDocumentChunk(
        Id recordId,
        String fileName,
        String base64Chunk,
        Integer chunkIndex,
        Integer totalChunks,
        Id contentVersionId,
        String extension
    ) {
        try {
            if (chunkIndex == 0) {
                // First chunk — create the ContentVersion with partial data
                ContentVersion cv = new ContentVersion();
                cv.Title = fileName;
                cv.PathOnClient = fileName + (extension.startsWith('.') ? extension : '.' + extension);
                cv.VersionData = EncodingUtil.base64Decode(base64Chunk);
                cv.IsMajorVersion = true;
                SObjectAccessDecision cvDec = Security.stripInaccessible(
                    AccessType.CREATABLE,
                    new List<ContentVersion>{ cv }
                );
                insert cvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                cv.Id = cvDec.getRecords()[0].Id;

                if (totalChunks == 1) {
                    // Single chunk — link to record immediately
                    Id contentDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE]
                    .ContentDocumentId; // NOPMD — internal doc lookup
                    try {
                        ContentDocumentLink cdl = new ContentDocumentLink(
                            ContentDocumentId = contentDocId,
                            LinkedEntityId = recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        );
                        SObjectAccessDecision cdlDec = Security.stripInaccessible(
                            AccessType.CREATABLE,
                            new List<ContentDocumentLink>{ cdl }
                        );
                        insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                    } catch (Exception linkErr) {
                        String noop = linkErr.getMessage(); // NOPMD UnusedLocalVariable — some objects don't support CDL
                    }
                }
                return cv.Id;
            } else {
                // Subsequent chunk — read existing CV, append data, re-save
                ContentVersion existing = [
                    SELECT Id, VersionData, Title, PathOnClient
                    FROM ContentVersion
                    WHERE Id = :contentVersionId
                    WITH USER_MODE
                    LIMIT 1
                ]; // NOPMD — internal chunk read
                String existingB64 = EncodingUtil.base64Encode(existing.VersionData);
                String combined = existingB64 + base64Chunk;
                existing.VersionData = EncodingUtil.base64Decode(combined);
                SObjectAccessDecision updDec = Security.stripInaccessible(
                    AccessType.UPDATABLE,
                    new List<ContentVersion>{ existing }
                );
                update updDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible

                if (chunkIndex == totalChunks - 1) {
                    // Last chunk — link to record
                    Id contentDocId = [
                        SELECT ContentDocumentId
                        FROM ContentVersion
                        WHERE Id = :existing.Id
                        WITH USER_MODE
                    ]
                    .ContentDocumentId; // NOPMD — internal doc lookup
                    try {
                        ContentDocumentLink cdl = new ContentDocumentLink(
                            ContentDocumentId = contentDocId,
                            LinkedEntityId = recordId,
                            ShareType = 'V',
                            Visibility = 'AllUsers'
                        );
                        SObjectAccessDecision cdlDec = Security.stripInaccessible(
                            AccessType.CREATABLE,
                            new List<ContentDocumentLink>{ cdl }
                        );
                        insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                    } catch (Exception linkErr) {
                        String noop = linkErr.getMessage(); // NOPMD UnusedLocalVariable — some objects don't support CDL
                    }
                }
                return existing.Id;
            }
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving document chunk: ' + e.getMessage());
        }
    }

    /**
     * Processes a template server-side and returns the document as base64, along with
     * the title, output format, and template type. Used by LWC for download/preview.
     * @param templateId The Portwood template record ID
     * @param recordId The source record ID
     * @return Map containing base64 document data, title, outputFormat, and templateType
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocument(
        Id templateId,
        Id recordId,
        Map<String, String> chartCvMap,
        Map<String, String> chartBucketMap
    ) {
        // chartCvMap (#117): signature → CV Id map for charts the LWC pre-
        // rasterized to PNG. Null for non-chart templates and legacy callers.
        // chartBucketMap: signature → JSON buckets for {#ChartBucket:...} tables
        // the LWC aggregated in the same sweep. Null when the server should
        // resolve them itself.
        // Set BEFORE invoking the merge so DocGenChartTagExpander.expand can
        // find each chart's CV; clear on the way out so per-request state
        // doesn't leak across transactions.
        DocGenService.beginChartContext(chartCvMap, chartBucketMap);
        try {
            return processAndReturnDocumentWithImages(templateId, recordId, null);
        } finally {
            DocGenService.endChartContext();
        }
    }

    /**
     * Processes a template with record data and optional pre-resolved images.
     * The LWC can fetch RTF images via the browser session and pass them as
     * a map of originalUrl to base64DataUri. This enables DOCX image embedding
     * without server-side HTTP callouts (AppExchange safe).
     * @param templateId The Portwood template record ID
     * @param recordId The source record ID
     * @param resolvedImages Map of original image URLs to base64 data URIs from the LWC
     * @return Map containing base64 document data, title, outputFormat, and templateType
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocumentWithImages(
        Id templateId,
        Id recordId,
        Map<String, String> resolvedImages
    ) {
        return processAndReturnDocumentWithOverride(templateId, recordId, resolvedImages, null);
    }

    /**
     * Processes a template with optional pre-resolved images AND an optional output format override.
     * When outputFormatOverride is non-null, ignores the template's Output_Format__c.
     * Throws if the template's Lock_Output_Format__c is true, or if PowerPoint→PDF is requested.
     */
    @AuraEnabled
    public static Map<String, Object> processAndReturnDocumentWithOverride(
        Id templateId,
        Id recordId,
        Map<String, String> resolvedImages,
        String outputFormatOverride
    ) {
        try {
            Map<String, Object> result = DocGenService.processDocument(
                templateId,
                recordId,
                resolvedImages,
                outputFormatOverride
            );
            Blob docBlob = (Blob) result.get('blob');
            return new Map<String, Object>{
                'base64' => EncodingUtil.base64Encode(docBlob),
                'title' => result.get('title'),
                'outputFormat' => result.get('outputFormat'),
                'templateType' => result.get('templateType')
            };
        } catch (HeapPressureException hp) {
            return heapPressureSignal(hp.relationshipName);
        } catch (Exception e) {
            // Try-and-retry: if sync blew heap (even from Blob.toPdf(), which isn't
            // catchable as HeapPressureException), signal so the runner LWC retries
            // via giant-query path. Client picks the relationship from scout cache.
            if (isHeapError(e)) {
                return heapPressureSignal(null);
            }
            throw DocGenService.ahe(e, 'Error generating document. Please check the template configuration.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * Server merges the XML (lightweight). Client fetches the shell ZIP and images
     * by URL, then assembles the final DOCX — no server-side ZIP, zero heap for large docs.
     * @param templateId The Portwood template record ID
     * @param recordId The source record ID
     * @return Map containing allXmlParts, imageBase64Map, imageCvIdMap, title, templateType, and isMacroEnabled
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentParts(
        Id templateId,
        Id recordId,
        Map<String, String> chartCvMap,
        Map<String, String> chartBucketMap
    ) {
        // chartCvMap (#117): signature → CV Id map for charts the LWC pre-
        // rasterized to PNG. Null for non-chart templates and legacy callers.
        // chartBucketMap: pre-aggregated {#ChartBucket:...} rows from the same
        // client-side sweep. Null to resolve server-side as before.
        DocGenService.beginChartContext(chartCvMap, chartBucketMap);
        try {
            return DocGenService.generateDocumentParts(templateId, recordId);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error generating document parts. Please check the template configuration.');
        } finally {
            DocGenService.endChartContext();
        }
    }

    /**
     * SECURITY (v1.75): IDOR-hardened ContentVersion access guard.
     *
     * AuraEnabled endpoints that take a ContentVersion Id from the client must
     * not blindly trust the Id — without a binding check, any authenticated
     * user could request any CV in the org (e.g. the CEO's private file) by
     * fabricating an Id. The pattern here:
     *
     *   1. Run the supplied query in USER_MODE. If the row comes back, the
     *      caller has standard sharing access — they were going to be allowed
     *      to read the file via Files anyway. Return it.
     *   2. Otherwise, fall back to a SYSTEM_MODE query restricted to the
     *      managed-file Title prefix `docgen_%`. This covers the legitimate
     *      managed-file case (template body images, watermarks, html assets,
     *      etc.) which guest/internal users may not have a direct
     *      ContentDocumentLink to but must still be able to fetch by Id when
     *      the LWC composes a DOCX/PDF. Title prefix is the defense-in-depth
     *      narrowing.
     *   3. If neither path returns a row, throw — caller has no access AND
     *      this isn't a managed file.
     *
     * @param contentVersionId The CV Id under inspection
     * @param fields Comma-separated SELECT list (e.g. 'Id, VersionData' or 'Id, ContentSize')
     * @return The single CV row, or throws AuraHandledException if access denied / not found.
     */
    private static SObject fetchAuthorizedContentVersion(Id contentVersionId, String fields) {
        // Defensive whitelisting — the `fields` parameter is private and only
        // ever called from this class with hardcoded strings, but we still
        // restrict to a known set so any future callers can't smuggle in
        // arbitrary SOQL fragments.
        String safeFields = fields;
        if (
            safeFields != 'Id, VersionData' &&
            safeFields != 'Id, ContentSize' &&
            safeFields != 'Id, ContentDocumentId'
        ) {
            throw DocGenService.ahe('Invalid field selection.');
        }

        // Step 1: USER_MODE — does the caller have sharing-based access?
        List<SObject> userScope;
        if (safeFields == 'Id, VersionData') {
            userScope = [
                SELECT Id, VersionData
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
        } else if (safeFields == 'Id, ContentSize') {
            userScope = [
                SELECT Id, ContentSize
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
        } else {
            userScope = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
        }
        if (!userScope.isEmpty()) {
            return userScope[0];
        }

        // Step 2: SYSTEM_MODE fallback — only managed `docgen_%` files, i.e.
        // assets the package itself created (template images, watermarks,
        // HTML body/images). Anything else is denied.
        List<SObject> sysScope;
        /* code-analyzer-suppress ApexFlsViolation */
        if (safeFields == 'Id, VersionData') {
            sysScope = [
                SELECT Id, VersionData
                FROM ContentVersion
                WHERE Id = :contentVersionId AND Title LIKE 'docgen_%'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } else if (safeFields == 'Id, ContentSize') {
            sysScope = [
                SELECT Id, ContentSize
                FROM ContentVersion
                WHERE Id = :contentVersionId AND Title LIKE 'docgen_%'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } else {
            sysScope = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :contentVersionId AND Title LIKE 'docgen_%'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
        if (!sysScope.isEmpty()) {
            return sysScope[0];
        }

        throw DocGenService.ahe('Access denied or content not found.');
    }

    /**
     * Returns a single ContentVersion's binary data as base64.
     * Called by the client in a loop — each call is its own transaction with fresh heap.
     * This enables client-side DOCX assembly with unlimited images.
     *
     * SECURITY (v1.75): caller must either have sharing access to the CV OR
     * the CV must be a managed `docgen_%` file. See fetchAuthorizedContentVersion.
     *
     * @param contentVersionId The ContentVersion record ID to retrieve
     * @return Base64-encoded binary data
     */
    @AuraEnabled
    public static String getContentVersionBase64(Id contentVersionId) {
        if (contentVersionId == null) {
            throw DocGenService.ahe('Content Version Id is required.');
        }
        ContentVersion cv = (ContentVersion) fetchAuthorizedContentVersion(contentVersionId, 'Id, VersionData');
        return EncodingUtil.base64Encode(cv.VersionData);
    }

    @AuraEnabled
    public static Id getLatestContentVersionId(Id contentDocumentId) {
        if (contentDocumentId == null) {
            throw DocGenService.ahe('Content Document Id is required.');
        }
        if (String.valueOf(contentDocumentId).startsWith('068')) {
            return contentDocumentId;
        }
        if (!String.valueOf(contentDocumentId).startsWith('069')) {
            throw DocGenService.ahe('Expected a ContentDocument Id.');
        }
        DocGenFlsGuard.assertAccessible(ContentDocument.sObjectType, new Set<String>{ 'LatestPublishedVersionId' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentDocument> docs = [
            SELECT LatestPublishedVersionId
            FROM ContentDocument
            WHERE Id = :contentDocumentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (docs.isEmpty() || docs[0].LatestPublishedVersionId == null) {
            throw DocGenService.ahe('Uploaded file version not found.');
        }
        return docs[0].LatestPublishedVersionId;
    }

    /**
     * Renders a Salesforce-hosted image URL into a single-image PDF via Blob.toPdf,
     * returns base64. Client parses the PDF to extract the embedded image bytes.
     *
     * Why this exists: Lightning rich text inline images (0EM ContentReference)
     * cannot be fetched directly from LWC (CORS Allow-Credentials:false) and
     * Apex callouts to those endpoints don't pass AppExchange security review
     * (session ID exposure, even self-org). Blob.toPdf() however has internal
     * resolver privileges and CAN fetch the URL — so we render an HTML wrapper
     * containing just the image, hand the PDF to the client, and the client
     * extracts the embedded image XObject. PDF is in-memory only, never persisted.
     *
     * @param imageUrl  Absolute or relative Salesforce URL (rtaImage, /sfc/, etc.)
     * @return Base64-encoded PDF bytes, or null on failure
     */
    /**
     * Saves an admin-uploaded watermark / background image and links it to the
     * given DocGen_Template_Version__c. This is the "first-class watermark"
     * path — admin uploads an image at recommended page-pixel dimensions in
     * the template builder, image gets stored as a ContentVersion, and the
     * renderer uses it as the @page background URL during PDF rendering.
     * Replaces the prior Word-watermark VML extraction path which had quirky
     * Scale/Washout/rotation behavior the user couldn't control predictably.
     *
     * @param versionId   The DocGen_Template_Version__c to associate with
     * @param fileName    Original file name (e.g. "letter-watermark.png")
     * @param base64Data  Base64-encoded image bytes
     * @return The created ContentVersion ID
     */
    @AuraEnabled
    public static Id saveWatermarkImage(Id versionId, String fileName, String base64Data) {
        if (versionId == null) {
            throw new DocGenException('Version ID is required.');
        }
        if (String.isBlank(base64Data)) {
            throw new DocGenException('Image data is required.');
        }
        // SECURITY (v1.75): verify the caller actually has access to this template
        // version. Without this, any authenticated user could attach a watermark
        // (and a ContentVersion) to any other admin's template version by Id.
        // USER_MODE on a custom object the caller can't see throws QueryException —
        // catch and convert to AuraHandledException so the LWC error handler reports
        // a clean denial.
        List<DocGen_Template_Version__c> ownerCheck;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template_Version__c.sObjectType, new Set<String>{ 'Template__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            ownerCheck = [
                SELECT Id, Template__c
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template version not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template version not found or access denied.');
        }
        if (ownerCheck.isEmpty()) {
            throw DocGenService.ahe('Template version not found or access denied.');
        }
        Blob imgBlob = EncodingUtil.base64Decode(base64Data);
        ContentVersion cv = new ContentVersion(
            Title = 'docgen_watermark_' + versionId,
            PathOnClient = String.isNotBlank(fileName) ? fileName : 'watermark.png',
            VersionData = imgBlob,
            FirstPublishLocationId = versionId
        );
        Database.insert(cv, AccessLevel.USER_MODE);
        // Persist the CV ID on the template version so the renderer knows about it.
        // SYSTEM_MODE on the namespaced custom-field update — Schema check above
        // gates access; USER_MODE strict-FLS strips Watermark_Image_CV_Id__c when
        // subscriber/build-org admin profile FLS isn't propagated from permset.
        if (!Schema.sObjectType.DocGen_Template_Version__c.isUpdateable()) {
            throw DocGenService.ahe('Insufficient access to update template versions.');
        }
        DocGen_Template_Version__c v = new DocGen_Template_Version__c(Id = versionId, Watermark_Image_CV_Id__c = cv.Id);
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(v, new Set<String>{ 'Watermark_Image_CV_Id__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(v, AccessLevel.SYSTEM_MODE);
        return cv.Id;
    }

    /**
     * Removes the admin-uploaded watermark from a template version. Keeps the
     * underlying ContentVersion (in case the admin wants to re-link it later)
     * but clears the field so the renderer falls back to the legacy Word VML
     * watermark path (or no watermark at all).
     */
    @AuraEnabled
    public static void clearWatermarkImage(Id versionId) {
        if (versionId == null) {
            return;
        }
        // SECURITY (v1.75): verify the caller has access to this template version
        // before mutating it. Without this any authenticated user could clear
        // any version's watermark by Id.
        List<DocGen_Template_Version__c> ownerCheck;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template_Version__c.sObjectType, new Set<String>());
            /* code-analyzer-suppress ApexFlsViolation */
            ownerCheck = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template version not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template version not found or access denied.');
        }
        if (ownerCheck.isEmpty()) {
            throw DocGenService.ahe('Template version not found or access denied.');
        }
        if (!Schema.sObjectType.DocGen_Template_Version__c.isUpdateable()) {
            throw DocGenService.ahe('Insufficient access to update template versions.');
        }
        DocGen_Template_Version__c v = new DocGen_Template_Version__c(Id = versionId, Watermark_Image_CV_Id__c = null);
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
        DocGenFlsGuard.assertUpdateable(v, new Set<String>{ 'Watermark_Image_CV_Id__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(v, AccessLevel.SYSTEM_MODE);
    }

    @AuraEnabled
    public static String renderImageAsPdfBase64(String imageUrl) {
        if (String.isBlank(imageUrl)) {
            return null;
        }
        // Security: only allow Salesforce-hosted URLs
        String lower = imageUrl.toLowerCase();
        Boolean isSafe = imageUrl.startsWith('/') || lower.contains('.salesforce.com') || lower.contains('.force.com');
        if (!isSafe) {
            return null;
        }
        if (Test.isRunningTest()) {
            return EncodingUtil.base64Encode(Blob.valueOf('test-pdf'));
        }
        try {
            // Document-like wrapper (text + styles) so Flying Saucer chooses higher
            // color depth instead of collapsing the image to grayscale. Image is
            // rendered at natural size — sizing for the DOCX is controlled by the
            // wp:extent in document.xml, not by the embedded image's native dims.
            String html =
                '<html><head>' +
                '<style>body{font-family:Arial,sans-serif;font-size:11pt;color:#000;margin:36pt}' +
                'img{display:block}</style>' +
                '</head><body>' +
                '<p>Image extraction wrapper.</p>' +
                '<img src="' +
                imageUrl.escapeXml() +
                '" />' +
                '<p>End wrapper.</p>' +
                '</body></html>';
            Blob pdf = Blob.toPdf(html);
            return EncodingUtil.base64Encode(pdf);
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable
        }
        return null;
    }

    /**
     * Generates a document using Giant Query async pipeline for records with thousands of children.
     * Scouts child counts, and if any exceed the threshold (2000), creates a Job, extracts the
     * loop body, and launches the batch harvester. Falls through to normal generation otherwise.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to generate from
     * @return Map with keys: jobId, isGiantQuery, childCounts. If isGiantQuery is false, includes docId.
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentGiantQuery(Id templateId, Id recordId) {
        try {
            if (templateId == null) {
                throw new DocGenException('Template ID is missing.');
            }
            if (recordId == null) {
                throw new DocGenException('Record ID is missing.');
            }

            // Get template config
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{ 'Base_Object_API__c', 'Query_Config__c', 'Type__c', 'Output_Format__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> templates = [
                SELECT Base_Object_API__c, Query_Config__c, Type__c, Output_Format__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (templates.isEmpty()) {
                throw new DocGenException('Unable to access template. Verify it exists and you have permission.');
            }
            DocGen_Template__c template = templates[0];
            String queryConfig = template.Query_Config__c;

            // Scout child counts (works for V1 flat strings AND V3 JSON)
            Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(recordId, queryConfig);

            // Check if any count exceeds threshold
            Integer threshold = 2000;
            String giantRelationship = null;
            Map<String, Object> giantNodeConfig = null;

            Integer configVersion = DocGenDataRetriever.getConfigVersion(queryConfig);

            for (String relName : counts.keySet()) {
                if (counts.get(relName) > threshold) {
                    giantRelationship = relName;
                    break;
                }
            }

            if (giantRelationship != null) {
                if (configVersion >= 3) {
                    // V3: find the matching node by alias if present (filtered subset),
                    // else by relationshipName. The scout keys counts by the same effective
                    // key, so giantRelationship === node.alias || node.relationshipName.
                    Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig.trim());
                    List<Object> nodesJson = (List<Object>) config.get('nodes');
                    if (nodesJson != null) {
                        for (Object nodeObj : nodesJson) {
                            Map<String, Object> n = (Map<String, Object>) nodeObj;
                            String nodeAlias = (String) n.get('alias');
                            String effectiveKey = String.isNotBlank(nodeAlias)
                                ? nodeAlias
                                : (String) n.get('relationshipName');
                            if (giantRelationship.equals(effectiveKey)) {
                                giantNodeConfig = n;
                                break;
                            }
                        }
                    }
                } else {
                    // V1/V2 flat string: build node config from schema + parsed subquery
                    giantNodeConfig = buildNodeConfigFromFlat(recordId, queryConfig, giantRelationship);
                }
            }

            if (giantRelationship == null) {
                // All counts within threshold — normal generation
                Id docId = DocGenService.generateDocument(templateId, recordId);
                // Resolve the latest ContentVersion ID for download support
                List<ContentVersion> cvs = [
                    SELECT Id, Title
                    FROM ContentVersion
                    WHERE ContentDocumentId = :docId AND IsLatest = TRUE
                    WITH USER_MODE
                    LIMIT 1
                ];
                return new Map<String, Object>{
                    'isGiantQuery' => false,
                    'docId' => docId,
                    'contentVersionId' => cvs.isEmpty() ? null : cvs[0].Id,
                    'title' => cvs.isEmpty() ? null : cvs[0].Title,
                    'childCounts' => counts
                };
            }

            // Giant Query path: create Job, extract loop body, launch batch.
            // Load the template body: for DOCX use pre-decomposed word/document.xml
            // (or zip fallback); for HTML the active version's Content_Version_Id__c
            // IS already the rewritten HTML body (with /sfc/ URLs for images).
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> activeVersions = [
                SELECT Id, Content_Version_Id__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            String documentXml = null;

            if (DocGenService.isHtmlBacked(template.Type__c)) {
                // HTML-type: read the active version's body CV directly. The body has
                // already been rewritten at upload time (image src → /sfc/ URLs).
                if (!activeVersions.isEmpty() && String.isNotBlank(activeVersions[0].Content_Version_Id__c)) {
                    Id bodyCvId = (Id) activeVersions[0].Content_Version_Id__c;
                    DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
                    /* code-analyzer-suppress ApexFlsViolation */
                    List<ContentVersion> htmlCvs = [
                        SELECT VersionData
                        FROM ContentVersion
                        WHERE Id = :bodyCvId
                        WITH SYSTEM_MODE
                        LIMIT 1
                    ];
                    if (!htmlCvs.isEmpty()) {
                        documentXml = htmlCvs[0].VersionData.toString();
                    }
                }
                if (documentXml == null) {
                    throw new DocGenException(
                        'HTML template has no active version body. Upload a template file first.'
                    );
                }
            } else {
                // DOCX/PPTX: pre-decomposed XML avoids ZIP decompression heap cost
                if (!activeVersions.isEmpty()) {
                    String xmlKey = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_word__document.xml';
                    // SYSTEM_MODE retained per #114: USER_MODE can return
                    // "ContentVersion not found" on fresh-upload CVs whose CDL
                    // defaults to Visibility=InternalUsers. CV access is gated
                    // upstream by the active version USER_MODE query.
                    if (!Schema.sObjectType.ContentVersion.isAccessible()) {
                        throw new DocGenException('ContentVersion access denied.');
                    }
                    List<ContentVersion> xmlCvs = DocGenService.loadInternalContentVersionsForVersionByTitle(
                        activeVersions[0].Id,
                        xmlKey
                    );
                    if (!xmlCvs.isEmpty()) {
                        documentXml = xmlCvs[0].VersionData.toString();
                    }
                }
                // Fallback: decompress ZIP if pre-decomposed parts unavailable
                if (documentXml == null) {
                    String base64File = DocGenTemplateManager.getTemplateFileContent(templateId);
                    Blob templateBlob = EncodingUtil.base64Decode(base64File);
                    Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
                    for (Compression.ZipEntry entry : reader.getEntries()) {
                        if (entry.getName() == 'word/document.xml') {
                            documentXml = reader.extract(entry.getName()).toString();
                            break;
                        }
                    }
                }
                if (documentXml == null) {
                    throw new DocGenException('Template does not contain word/document.xml.');
                }
            }

            Map<String, String> loopParts = DocGenService.extractLoopBody(documentXml, giantRelationship);
            if (loopParts == null) {
                // v1.91+: templates using {#ChartBucket:<rel>:...} aggregate via
                // their own SOQL — they don't need an eager-loaded loop body.
                // Surface that pattern in the error so authors know the fix
                // is in Query_Config__c, not in the template body.
                if (documentXml != null && documentXml.contains('{#ChartBucket:' + giantRelationship + ':')) {
                    throw new DocGenException(
                        'Template uses {#ChartBucket:' +
                            giantRelationship +
                            ':...} but Query_Config__c also lists ' +
                            giantRelationship +
                            ' as an eager-loaded child (currently ' +
                            counts.get(giantRelationship) +
                            ' rows, above the 2000-row giant-query threshold). ' +
                            'Charts aggregate via their own SOQL, so remove ' +
                            giantRelationship +
                            ' from Query_Config__c to let the chart handle this relationship server-side.'
                    );
                }
                throw new DocGenException('Could not find loop for relationship: ' + giantRelationship);
            }

            String outputFormat = template.Output_Format__c != null ? template.Output_Format__c : 'PDF';

            // Create Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = templateId,
                Label__c = 'Giant Query',
                Parent_Record_Id__c = String.valueOf(recordId),
                Giant_Query_Config__c = JSON.serialize(
                    new Map<String, Object>{
                        'relationshipName' => giantRelationship,
                        'childNodeConfig' => giantNodeConfig,
                        'childCount' => counts.get(giantRelationship)
                    }
                )
            );
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.assertCreateable(
                job,
                new Set<String>{
                    'Status__c',
                    'Template__c',
                    'Label__c',
                    'Parent_Record_Id__c',
                    'Giant_Query_Config__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // Launch batch — shell PDF generation happens in start() with fresh heap
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id,
                templateId,
                recordId,
                giantNodeConfig,
                loopParts.get('innerXml'),
                outputFormat
            );
            Database.executeBatch(batch, 1); // scope size 1: one page descriptor per execute

            return new Map<String, Object>{
                'jobId' => job.Id,
                'isGiantQuery' => true,
                'childCounts' => counts,
                'giantRelationship' => giantRelationship,
                'outputFormat' => outputFormat
            };
        } catch (DocGenException e) {
            throw DocGenService.ahe(e);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error initiating Giant Query generation.');
        }
    }

    /**
     * Returns the status and progress of a Giant Query job for client-side polling.
     * @param jobId The DocGen_Job__c record ID
     * @return Map with status, successCount, totalRecords
     */
    @AuraEnabled
    public static Map<String, Object> getGiantQueryJobStatus(Id jobId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{ 'Status__c', 'Success_Count__c', 'Total_Records__c', 'Label__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jobs = [
            SELECT Status__c, Success_Count__c, Total_Records__c, Label__c
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (jobs.isEmpty()) {
            return new Map<String, Object>{ 'status' => 'Not Found' };
        }
        DocGen_Job__c job = jobs[0];
        return new Map<String, Object>{
            'status' => job.Status__c,
            'successCount' => job.Success_Count__c,
            'totalRecords' => job.Total_Records__c,
            'label' => job.Label__c
        };
    }

    /**
     * Returns the ordered list of fragment ContentVersion IDs for a Giant Query job.
     * Used by client-side DOCX assembly to fetch each fragment one at a time.
     * @param jobId The DocGen_Job__c record ID
     * @return Map with fragmentIds (ordered list) and fragmentCount
     */
    @AuraEnabled
    public static Map<String, Object> getGiantQueryFragments(Id jobId) {
        String prefix = 'docgen_giant_' + jobId + '_';
        String shellTitle = 'docgen_giant_' + jobId + '_shell';
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> fragments = [
            SELECT Id, Title
            FROM ContentVersion
            WHERE Title LIKE :(prefix + '%') AND Title != :shellTitle
            WITH SYSTEM_MODE
            ORDER BY Title // NOPMD — internal fragment lookup
        ];
        List<String> fragmentIds = new List<String>();
        for (ContentVersion cv : fragments) {
            fragmentIds.add(cv.Id);
        }

        // v1.90 — prefer Merged_PDF_CV__c on the Job for the final-PDF lookup so
        // the controller works regardless of the CV's title (which now honors
        // Document_Title_Format__c). Title-pattern lookup kept as a backwards-
        // compat fallback for jobs queued by an older package version.
        Id finalCvId = null;
        Id templateId = null;
        Id parentRecordId = null;
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{ 'Merged_PDF_CV__c', 'Template__c', 'Parent_Record_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jobs = [
            SELECT Merged_PDF_CV__c, Template__c, Parent_Record_Id__c
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!jobs.isEmpty()) {
            if (String.isNotBlank(jobs[0].Merged_PDF_CV__c)) {
                finalCvId = (Id) jobs[0].Merged_PDF_CV__c;
            }
            templateId = jobs[0].Template__c;
            parentRecordId = jobs[0].Parent_Record_Id__c;
        }
        if (finalCvId == null) {
            // Legacy lookup: title pattern (pre-v1.90 jobs)
            String finalTitle = 'docgen_giant_' + jobId + '_final';
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> finalCvs = [
                SELECT Id
                FROM ContentVersion
                WHERE Title = :finalTitle
                WITH SYSTEM_MODE
                LIMIT 1 // NOPMD — internal lookup
            ];
            if (!finalCvs.isEmpty()) {
                finalCvId = finalCvs[0].Id;
            }
        }

        // Look up PDF parts if multiple chunks were rendered
        String partPrefix = 'docgen_giant_' + jobId + '_part_';
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> partCvs = [
            SELECT Id
            FROM ContentVersion
            WHERE Title LIKE :(partPrefix + '%')
            WITH SYSTEM_MODE
            ORDER BY Title // NOPMD
        ];
        List<String> partIds = new List<String>();
        for (ContentVersion cv : partCvs) {
            partIds.add(cv.Id);
        }

        // Compute the user-facing document title once so the client can use it
        // for the multi-part merge filename. Falls back to null when no
        // Document_Title_Format__c is configured.
        String docTitle = DocGenService.computeDocTitle(templateId, parentRecordId);

        return new Map<String, Object>{
            'fragmentIds' => fragmentIds,
            'fragmentCount' => fragments.size(),
            'finalPdfCvId' => finalCvId,
            'partPdfCvIds' => partIds,
            'docTitle' => docTitle
        };
    }

    /**
     * Generates document parts for Giant Query DOCX assembly. Returns the merged
     * template shell XML (parent data filled, giant loop replaced with placeholder)
     * plus image maps. The client injects harvest fragments and builds the DOCX ZIP.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID for parent-level merge tags
     * @param giantRelationshipName The child relationship name processed by harvest batch
     * @return Map containing allXmlParts, image maps, title, placeholder token
     */
    @AuraEnabled
    public static Map<String, Object> generateDocumentPartsGiantQuery(
        Id templateId,
        Id recordId,
        String giantRelationshipName
    ) {
        // CxSAST: SOQL injection — giantRelationshipName is not used in SOQL; it is only used for XML loop extraction in DocGenService.extractLoopBody()
        try {
            return DocGenService.generateDocumentPartsGiantQuery(
                templateId,
                recordId,
                String.escapeSingleQuotes(giantRelationshipName)
            );
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error generating Giant Query document parts.');
        }
    }

    /**
     * Deletes the fragment ContentVersions for a Giant Query job after client-side
     * DOCX assembly is complete. Cleans up intermediate storage.
     * @param jobId The DocGen_Job__c record ID
     */
    @AuraEnabled
    public static void cleanupGiantQueryFragments(Id jobId) {
        String prefix = 'docgen_giant_' + jobId + '_';
        Set<Id> docIds = new Set<Id>();
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId', 'Title' });
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentVersion cv : [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Title LIKE :(prefix + '%')
            WITH SYSTEM_MODE // NOPMD — internal fragment cleanup
        ]) {
            docIds.add(cv.ContentDocumentId);
        }
        if (!docIds.isEmpty()) {
            Database.delete(
                [SELECT Id FROM ContentDocument WHERE Id IN :docIds WITH SYSTEM_MODE],
                true,
                AccessLevel.SYSTEM_MODE
            );
        }
    }

    /**
     * Launches a Giant Query PDF batch using client-provided child node config.
     * Works for ALL config versions (V1/V2/V3) — the scout already resolved the
     * child node metadata, so we don't need to parse the query config here.
     * Only loads the document XML (pre-decomposed) to extract the loop body.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID
     * @param giantRelationship The child relationship name with >2000 records
     * @param childNodeConfigJson JSON-serialized child node config from scout
     * @return Map with jobId, isGiantQuery, outputFormat
     */
    @AuraEnabled
    public static Map<String, Object> launchGiantQueryPdfBatch(
        Id templateId,
        Id recordId,
        String giantRelationship,
        String childNodeConfigJson
    ) {
        try {
            if (templateId == null) {
                throw new DocGenException('Template ID is missing.');
            }
            if (recordId == null) {
                throw new DocGenException('Record ID is missing.');
            }

            Map<String, Object> childNodeConfig = (Map<String, Object>) JSON.deserializeUntyped(childNodeConfigJson);

            // Load template body: DOCX uses pre-decomposed word/document.xml;
            // HTML uses the active version's Content_Version_Id__c directly.
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tplForType = [
                SELECT Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            String templateType = tplForType.isEmpty() ? 'Word' : tplForType[0].Type__c;

            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> activeVersions = [
                SELECT Id, Content_Version_Id__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            String documentXml = null;

            if (DocGenService.isHtmlBacked(templateType)) {
                if (!activeVersions.isEmpty() && String.isNotBlank(activeVersions[0].Content_Version_Id__c)) {
                    Id bodyCvId = (Id) activeVersions[0].Content_Version_Id__c;
                    DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
                    /* code-analyzer-suppress ApexFlsViolation */
                    List<ContentVersion> htmlCvs = [
                        SELECT VersionData
                        FROM ContentVersion
                        WHERE Id = :bodyCvId
                        WITH SYSTEM_MODE
                        LIMIT 1
                    ];
                    if (!htmlCvs.isEmpty()) {
                        documentXml = htmlCvs[0].VersionData.toString();
                    }
                }
                if (documentXml == null) {
                    throw new DocGenException(
                        'HTML template has no active version body. Upload a template file first.'
                    );
                }
            } else {
                if (!activeVersions.isEmpty()) {
                    String xmlKey = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_word__document.xml';
                    // SYSTEM_MODE retained per #114 — same fresh-upload CDL caveat as above.
                    if (!Schema.sObjectType.ContentVersion.isAccessible()) {
                        throw new DocGenException('ContentVersion access denied.');
                    }
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
            }

            Map<String, String> loopParts = DocGenService.extractLoopBody(documentXml, giantRelationship);
            documentXml = null; // free
            if (loopParts == null) {
                throw new DocGenException('Could not find loop for relationship: ' + giantRelationship);
            }

            // Create Job record
            DocGen_Job__c job = new DocGen_Job__c(
                Status__c = 'Draft',
                Template__c = templateId,
                Label__c = 'Giant Query PDF',
                Parent_Record_Id__c = String.valueOf(recordId)
            );
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.assertCreateable(
                job,
                new Set<String>{ 'Status__c', 'Template__c', 'Label__c', 'Parent_Record_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // Ensure relationshipName is in the config (V1 scout doesn't include it)
            childNodeConfig.put('relationshipName', giantRelationship);

            // Launch batch
            DocGenGiantQueryBatch batch = new DocGenGiantQueryBatch(
                job.Id,
                templateId,
                recordId,
                childNodeConfig,
                loopParts.get('innerXml'),
                'PDF'
            );
            Database.executeBatch(batch, 1);

            return new Map<String, Object>{ 'jobId' => job.Id, 'isGiantQuery' => true, 'outputFormat' => 'PDF' };
        } catch (DocGenException e) {
            throw DocGenService.ahe(e);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error launching Giant Query PDF batch.');
        }
    }

    /**
     * Lightweight scout: counts child records per relationship for Giant Query detection.
     * Reads the query config directly from the template — no client-side cache dependency.
     * @param recordId The parent record ID
     * @param templateId The DocGen_Template__c record ID
     * @return Map of relationship name to child record count
     */
    // Heap-pressure router constants — tuned from real-world breakage.
    // Output format matters enormously: PDF rendering via Blob.toPdf() parses the
    // entire HTML into an in-memory DOM, so peak heap is ~5-10× the raw expanded
    // XML size. DOCX/Excel paths just write XML and ship base64 to the client.
    private static final Integer SYNC_HEAP_LIMIT = 6000000; // Apex sync heap governor (6MB)
    private static final Decimal SAFE_HEAP_RATIO = 0.6; // leave 40% headroom

    // PDF: Blob.toPdf() holds full DOM + parse tree in heap
    private static final Integer PDF_BASE_BYTES = 1000000; // template HTML + styles + parent data
    private static final Integer PDF_BYTES_PER_ROW = 10000; // ~10KB per row after DOM/CSS parsing

    // DOCX/Excel/PowerPoint: server merges XML, returns base64 to client
    private static final Integer DOCX_BASE_BYTES = 200000;
    private static final Integer DOCX_BYTES_PER_ROW = 2000;

    @AuraEnabled
    public static Map<String, Object> scoutChildCounts(Id recordId, Id templateId) {
        Map<String, Object> result = new Map<String, Object>();
        result.put('counts', new Map<String, Integer>());
        result.put('childNodes', new Map<String, Map<String, Object>>());
        result.put('heapEstimates', new Map<String, Integer>());
        result.put('useGiantPath', new Map<String, Boolean>());
        result.put('heapLimitBytes', SYNC_HEAP_LIMIT);

        if (recordId == null || templateId == null) {
            return result;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Query_Config__c', 'Base_Object_API__c', 'Output_Format__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Query_Config__c, Base_Object_API__c, Output_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty() || String.isBlank(templates[0].Query_Config__c)) {
            return result;
        }

        String queryConfig = templates[0].Query_Config__c;
        // CxSAST: SOQL injection — queryConfig sourced from DB record (not user input); scoutChildCounts uses Schema validation + escapeSingleQuotes + USER_MODE
        Map<String, Integer> counts = DocGenDataRetriever.scoutChildCounts(recordId, queryConfig);
        result.put('counts', counts);

        // Build child node metadata for the client (works for all config formats)
        Map<String, Map<String, Object>> childNodes = new Map<String, Map<String, Object>>();
        String trimmed = queryConfig.trim();

        if (trimmed.startsWith('{')) {
            // V3/V2 JSON — parse nodes
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
            List<Object> nodes = (List<Object>) config.get('nodes');
            if (nodes != null) {
                for (Object nodeObj : nodes) {
                    Map<String, Object> n = (Map<String, Object>) nodeObj;
                    String relName = (String) n.get('relationshipName');
                    if (String.isNotBlank(relName) && n.get('parentNode') != null) {
                        childNodes.put(
                            relName,
                            new Map<String, Object>{
                                'object' => n.get('object'),
                                'lookupField' => n.get('lookupField'),
                                'fields' => n.get('fields'),
                                'parentFields' => n.get('parentFields'),
                                // The V1 branch below emits where/orderBy/limit; this one did
                                // not, and docGenRunner reads `serverChildNode.orderBy` to drive
                                // the client-side giant DOCX cursor. Omitting it silently fell
                                // back to unsorted, so a V3-config template rendered its child
                                // rows in arbitrary order while the identical V1 config sorted
                                // correctly. Also the reason a multi-column ORDER BY appeared
                                // to be ignored on that path.
                                'where' => n.get('where'),
                                'orderBy' => n.get('orderBy'),
                                'limit' => n.get('limit')
                            }
                        );
                    }
                }
            }
        } else {
            // V1 flat string — resolve child relationships from Schema
            String baseObject = templates[0].Base_Object_API__c;
            Schema.DescribeSObjectResult parentDescribe = Schema.getGlobalDescribe().get(baseObject)?.getDescribe();
            if (parentDescribe != null) {
                Pattern subqPattern = Pattern.compile('(?i)\\(\\s*SELECT\\s+(.+?)\\s+FROM\\s+(\\w+)([^)]*)\\)');
                Matcher m = subqPattern.matcher(trimmed);
                Map<String, Schema.ChildRelationship> relMap = new Map<String, Schema.ChildRelationship>();
                for (Schema.ChildRelationship cr : parentDescribe.getChildRelationships()) {
                    if (cr.getRelationshipName() != null) {
                        relMap.put(cr.getRelationshipName().toLowerCase(), cr);
                    }
                }
                while (m.find()) {
                    String fieldList = m.group(1);
                    String relName = m.group(2);
                    String clausesPart = m.group(3) != null ? m.group(3).trim() : '';
                    Schema.ChildRelationship cr = relMap.get(relName.toLowerCase());
                    if (cr != null) {
                        List<String> fields = new List<String>();
                        List<String> parentFields = new List<String>();
                        for (String f : fieldList.split(',')) {
                            String fTrimmed = f.trim();
                            if (String.isNotBlank(fTrimmed)) {
                                if (fTrimmed.contains('.')) {
                                    parentFields.add(fTrimmed);
                                } else {
                                    fields.add(fTrimmed);
                                }
                            }
                        }
                        Map<String, Object> nodeConfig = new Map<String, Object>{
                            'object' => String.valueOf(cr.getChildSObject()),
                            'lookupField' => String.valueOf(cr.getField()),
                            'fields' => fields,
                            'parentFields' => parentFields,
                            'relationshipName' => relName
                        };
                        // Extract WHERE, ORDER BY, and LIMIT from clauses
                        if (String.isNotBlank(clausesPart)) {
                            Pattern wherePattern = Pattern.compile(
                                '(?i)\\s*WHERE\\s+(.+?)(?:\\s+ORDER\\s+BY|\\s+LIMIT|$)'
                            );
                            Matcher whereMatcher = wherePattern.matcher(clausesPart);
                            if (whereMatcher.find()) {
                                nodeConfig.put('where', whereMatcher.group(1).trim());
                            }
                            Pattern orderPattern = Pattern.compile('(?i)ORDER\\s+BY\\s+(.+?)(?:\\s+LIMIT|$)');
                            Matcher orderMatcher = orderPattern.matcher(clausesPart);
                            if (orderMatcher.find()) {
                                nodeConfig.put('orderBy', orderMatcher.group(1).trim());
                            }
                            Pattern limitPattern = Pattern.compile('(?i)LIMIT\\s+(\\d+)');
                            Matcher limitMatcher = limitPattern.matcher(clausesPart);
                            if (limitMatcher.find()) {
                                nodeConfig.put('limit', limitMatcher.group(1).trim());
                            }
                        }
                        childNodes.put(relName, nodeConfig);
                    }
                }
            }
        }

        result.put('childNodes', childNodes);

        // Heap-pressure pre-flight: for each relationship with a known count, estimate
        // peak sync-path heap. Constants differ by output format because PDF's
        // Blob.toPdf() holds the whole HTML DOM in heap while rendering.
        String outputFormat = templates[0].Output_Format__c;
        Boolean isPdf = 'PDF'.equalsIgnoreCase(outputFormat);
        Integer baseBytes = isPdf ? PDF_BASE_BYTES : DOCX_BASE_BYTES;
        Integer bytesPerRow = isPdf ? PDF_BYTES_PER_ROW : DOCX_BYTES_PER_ROW;
        Integer safeHeapBytes = (Integer) (SYNC_HEAP_LIMIT * SAFE_HEAP_RATIO);

        Map<String, Integer> heapEstimates = new Map<String, Integer>();
        Map<String, Boolean> useGiantPath = new Map<String, Boolean>();
        for (String relName : counts.keySet()) {
            Integer rowCount = counts.get(relName);
            Integer estimatedPeak = baseBytes + (rowCount * bytesPerRow);
            heapEstimates.put(relName, estimatedPeak);
            useGiantPath.put(relName, estimatedPeak > safeHeapBytes);
        }
        result.put('heapEstimates', heapEstimates);
        result.put('useGiantPath', useGiantPath);
        result.put('outputFormat', outputFormat);
        return result;
    }

    /**
     * Returns one page of child records for client-side Giant Query assembly.
     * Uses cursor-based pagination (Id > lastCursorId) — no OFFSET limit.
     * Each call is a fresh transaction with fresh heap.
     * @param childObject The child SObject API name
     * @param lookupField The lookup field on the child pointing to the parent
     * @param parentId The parent record ID
     * @param lastCursorId The last record ID from the previous page (null for first page)
     * @param fields Comma-separated list of fields to query
     * @param pageSize Number of records per page (max 200)
     * @return Map with 'records' (List<Map<String,Object>>), 'lastId' (String), 'hasMore' (Boolean)
     */
    @AuraEnabled
    public static Map<String, Object> getChildRecordPage(
        String childObject,
        String lookupField,
        Id parentId,
        String lastCursorId,
        String fields,
        Integer pageSize
    ) {
        if (pageSize == null || pageSize > 500) {
            pageSize = 500;
        }

        // Validate object name against Schema
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (gd.get(childObject) == null) {
            throw DocGenService.ahe(new DocGenException('Invalid object: ' + childObject), 'Invalid child object.');
        }

        String query =
            'SELECT ' +
            String.escapeSingleQuotes(fields) +
            ' FROM ' +
            String.escapeSingleQuotes(childObject) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupField) +
            ' = :parentId';

        if (String.isNotBlank(lastCursorId)) {
            query += ' AND Id > :lastCursorId';
        }
        query += ' ORDER BY Id LIMIT :pageSize';

        // CxSAST: SOQL injection mitigated by Schema.getGlobalDescribe() validation + escapeSingleQuotes + USER_MODE
        List<SObject> records = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — object validated by Schema; fields from template config; USER_MODE enforced

        List<Map<String, Object>> recordMaps = new List<Map<String, Object>>();
        for (SObject rec : records) {
            recordMaps.add(rec.getPopulatedFieldsAsMap());
        }

        String lastId = records.isEmpty() ? null : records[records.size() - 1].Id;

        return new Map<String, Object>{
            'records' => recordMaps,
            'lastId' => lastId,
            'hasMore' => records.size() == pageSize
        };
    }

    /**
     * Returns all child record IDs in sort order for client-side Giant Query DOCX assembly.
     * One lightweight Id-only query (up to 50K rows). The client chunks these IDs
     * and calls getChildRecordsByIds() per chunk to get full field data.
     * @param childObject The child SObject API name
     * @param lookupField The lookup field on the child pointing to the parent
     * @param parentId The parent record ID
     * @param orderByClause The ORDER BY clause (e.g., "Product2.Name ASC")
     * @return List of record IDs in sort order
     */
    @AuraEnabled
    public static List<Id> getSortedChildIds(
        String childObject,
        String lookupField,
        Id parentId,
        String orderByClause,
        String whereClause
    ) {
        // Allowlist validation: object verified against Schema.getGlobalDescribe()
        SObjectType childType = Schema.getGlobalDescribe().get(childObject);
        if (childType == null) {
            throw DocGenService.ahe(new DocGenException('Invalid object: ' + childObject), 'Invalid child object.');
        }
        Map<String, Schema.SObjectField> fieldMap = childType.getDescribe().fields.getMap();

        // Allowlist validation: lookupField verified against Schema.describeSObjects() field map
        if (String.isBlank(lookupField) || !fieldMap.containsKey(lookupField.toLowerCase())) {
            throw new DocGenException('Invalid lookup field: ' + lookupField);
        }

        // Allowlist validation: ORDER BY fields verified against Schema.describeSObjects() field map
        if (String.isBlank(orderByClause)) {
            throw new DocGenException('ORDER BY clause is required for sorted query.');
        }
        if (orderByClause.contains(';') || orderByClause.contains('--') || orderByClause.contains('/*')) {
            throw new DocGenException('Invalid ORDER BY clause.');
        }
        String normalized = orderByClause.replaceAll('\\s+', ' ').toUpperCase().trim();
        for (String kw : new List<String>{ 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'DROP ', 'SELECT ' }) {
            if (normalized.contains(kw)) {
                throw new DocGenException('Invalid ORDER BY clause: disallowed keyword.');
            }
        }
        // Parse ORDER BY fields and validate each against Schema field describe.
        // Splitting on ',' means a multi-column clause ("Amount DESC, Name ASC") is
        // validated column by column. Kept deliberately in step with
        // DocGenDataRetriever.sanitizeClause — the two ran different rules, and this
        // one lacked the standard-relationship fallback, so a clause mixing a standard
        // lookup ("Product2.Name, Name") passed in the sync path and threw only here,
        // on the client-side giant DOCX path.
        for (String part : orderByClause.split(',')) {
            String fieldName = part.trim().split('\\s+')[0].toLowerCase();
            // Handle relationship fields like Product2.Name — validate the relationship prefix
            String baseField = fieldName.contains('.') ? fieldName.split('\\.')[0] : fieldName;
            if (fieldMap.containsKey(baseField)) {
                continue;
            }
            // Custom relationship: My_Lookup__r → My_Lookup__c
            String asCustomLookup = baseField.endsWith('__r')
                ? baseField.substring(0, baseField.length() - 3) + '__c'
                : null;
            if (asCustomLookup != null && fieldMap.containsKey(asCustomLookup)) {
                continue;
            }
            // Standard relationship: Account → AccountId, Product2 → Product2Id, Owner → OwnerId
            if (fieldMap.containsKey(baseField + 'id')) {
                continue;
            }
            throw new DocGenException('Invalid field in ORDER BY: ' + fieldName);
        }

        // Sanitize WHERE clause if provided
        if (String.isNotBlank(whereClause)) {
            if (whereClause.contains(';') || whereClause.contains('--') || whereClause.contains('/*')) {
                throw new DocGenException('Invalid WHERE clause.');
            }
            String normalizedWhere = whereClause.replaceAll('\\s+', ' ').toUpperCase().trim();
            for (String kw : new List<String>{ 'INSERT ', 'UPDATE ', 'DELETE ', 'MERGE ', 'DROP ', 'SELECT ' }) {
                if (normalizedWhere.contains(kw)) {
                    throw new DocGenException('Invalid WHERE clause: disallowed keyword.');
                }
            }
            // Allowlist validation: WHERE clause field names verified against Schema.describeSObjects() field map
            validateWhereClauseFields(whereClause, fieldMap);
        }

        String query =
            'SELECT Id FROM ' +
            String.escapeSingleQuotes(childObject) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupField) +
            ' = :parentId';
        if (String.isNotBlank(whereClause)) {
            query += ' AND ' + whereClause;
        }
        query += ' ORDER BY ' + orderByClause;

        List<Id> sortedIds = new List<Id>();
        // CxSAST: SOQL injection mitigated by Schema allowlist validation on object, lookupField, ORDER BY fields, WHERE fields + keyword blocklist + USER_MODE
        for (SObject rec : Database.query(query, AccessLevel.USER_MODE)) {
            // NOPMD ApexSOQLInjection — all dynamic elements validated against Schema.describeSObjects() field map; USER_MODE enforced
            sortedIds.add(rec.Id);
        }
        return sortedIds;
    }

    /**
     * Returns child records for a specific list of IDs. Used with getSortedChildIds()
     * for sorted client-side Giant Query DOCX assembly.
     * @param childObject The child SObject API name
     * @param fields Comma-separated field list
     * @param recordIds List of record IDs to fetch
     * @return List of record maps with populated fields
     */
    @AuraEnabled
    public static List<Map<String, Object>> getChildRecordsByIds(
        String childObject,
        String fields,
        List<Id> recordIds
    ) {
        if (recordIds == null || recordIds.isEmpty()) {
            return new List<Map<String, Object>>();
        }
        // Allowlist validation: object verified against Schema.getGlobalDescribe()
        SObjectType childType = Schema.getGlobalDescribe().get(childObject);
        if (childType == null) {
            throw DocGenService.ahe(new DocGenException('Invalid object: ' + childObject), 'Invalid child object.');
        }

        // Allowlist validation: each field verified against Schema.describeSObjects() field map
        Map<String, Schema.SObjectField> fieldMap = childType.getDescribe().fields.getMap();
        List<String> validatedFields = new List<String>();
        for (String f : fields.split(',')) {
            String fieldName = f.trim();
            if (String.isBlank(fieldName)) {
                continue;
            }
            String lower = fieldName.toLowerCase();
            // Direct field
            if (fieldMap.containsKey(lower)) {
                validatedFields.add(String.escapeSingleQuotes(fieldName));
                continue;
            }
            // Relationship field (e.g., Product2.Name) — validate relationship prefix exists
            if (fieldName.contains('.')) {
                String relPrefix = fieldName.split('\\.')[0].toLowerCase();
                Boolean foundRel = false;
                for (Schema.SObjectField sof : fieldMap.values()) {
                    String relName = sof.getDescribe().getRelationshipName();
                    if (relName != null && relName.toLowerCase() == relPrefix) {
                        foundRel = true;
                        break;
                    }
                }
                if (foundRel) {
                    validatedFields.add(String.escapeSingleQuotes(fieldName));
                    continue;
                }
            }
            // Field not found in schema — skip (silent drop matches DataRetriever behavior)
        }
        if (validatedFields.isEmpty()) {
            validatedFields.add('Id');
        }

        String query =
            'SELECT ' +
            String.join(validatedFields, ', ') +
            ' FROM ' +
            String.escapeSingleQuotes(childObject) +
            ' WHERE Id IN :recordIds';

        // CxSAST: SOQL injection mitigated by Schema allowlist validation on object and all field names + USER_MODE
        List<SObject> records = Database.query(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — all dynamic elements allowlist-validated against Schema.describeSObjects() field map; USER_MODE enforced

        // Re-order to match input ID sequence
        Map<Id, SObject> byId = new Map<Id, SObject>();
        for (SObject rec : records) {
            byId.put(rec.Id, rec);
        }

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Id recId : recordIds) {
            SObject rec = byId.get(recId);
            if (rec != null) {
                result.add(rec.getPopulatedFieldsAsMap());
            }
        }
        return result;
    }

    /**
     * Previews the merged record data for a given record and query configuration.
     * @param recordId The record ID to preview data for
     * @param baseObject The base SObject API name
     * @param queryConfig The query configuration string (V1, V2, or V3 format)
     * @return Map of field names to values for the record
     */
    @AuraEnabled
    public static Map<String, Object> previewRecordData(Id recordId, String baseObject, String queryConfig) {
        if (recordId == null || String.isBlank(baseObject) || String.isBlank(queryConfig)) {
            return null;
        }
        // Validate base object against Schema
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw new DocGenException('Invalid or inaccessible object: ' + baseObject);
        }
        // CxSAST: SOQL injection mitigated — baseObject validated by Schema; queryConfig parsed by DataRetriever which validates all objects/fields via Schema + escapeSingleQuotes + USER_MODE
        try {
            return DocGenDataRetriever.getRecordData(recordId, baseObject, queryConfig);
        } catch (Exception e) {
            throw new DocGenException('Error fetching preview data: ' + e.getMessage());
        }
    }

    /**
     * Returns templates configured for a specific SObject type, applying audience visibility
     * (Required_Permission_Sets__c) but NO per-record filter.
     * Backward-compatible — existing callers see the same set of templates as before plus the
     * new audience filter (only meaningful for templates that opt in by setting the field).
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplatesForObject(String objectApiName) {
        try {
            return getTemplatesForObjectInternal(objectApiName, null);
        } catch (Exception e) {
            DocGenErrorLogger.logTemplatePickerFailure(e, objectApiName, null);
            throw DocGenService.ahe(resolveTemplatePickerLoadError(e));
        }
    }

    /**
     * Returns templates configured for a specific SObject type AND visible to the current
     * record (Specific_Record_Ids__c) AND visible to the running user (Required_Permission_Sets__c).
     * Sorted by Sort_Order__c ASC NULLS LAST, Is_Default__c DESC, Name ASC.
     * @param objectApiName The SObject API name (e.g. 'Account')
     * @param recordId The current record Id (string form). Required for per-record filter to apply.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplatesForObjectAndRecord(String objectApiName, String recordId) {
        try {
            return getTemplatesForObjectInternal(objectApiName, recordId);
        } catch (Exception e) {
            DocGenErrorLogger.logTemplatePickerFailure(e, objectApiName, recordId);
            throw DocGenService.ahe(resolveTemplatePickerLoadError(e));
        }
    }

    private static final String TEMPLATE_PICKER_SHARING_MESSAGE =
        'Unable to load Portwood templates. Ask an admin to verify that at least one active Portwood Template is shared ' +
        'with you for this object. If Portwood Template sharing is Private, share the template record directly or set ' +
        'Setup > Sharing Settings > Portwood Template > Default Internal Access to Public Read.';

    @TestVisible
    private static String resolveTemplatePickerLoadError(Exception e) {
        String message = e == null ? null : e.getMessage();
        if (isInternalUserModeBindError(message)) {
            return TEMPLATE_PICKER_SHARING_MESSAGE;
        }
        return String.isBlank(message) ? 'Unable to load Portwood templates.' : message;
    }

    @TestVisible
    private static Boolean isInternalUserModeBindError(String message) {
        return String.isNotBlank(message) && message.contains('Variable does not exist: tmpVar');
    }

    /**
     * Shared filter implementation for getTemplatesForObject and getTemplatesForObjectAndRecord.
     */
    private static List<DocGen_Template__c> getTemplatesForObjectInternal(String objectApiName, String recordId) {
        // Inactive templates are filtered out of the runner picker (issue #85).
        // Admin views call getAllTemplates() which doesn't filter, so admins can
        // still see and toggle inactive templates. Uses `!= FALSE` to treat both
        // TRUE and NULL as Active — a `(= TRUE OR = NULL)` OR clause has a
        // platform indexing quirk on newly-added Checkbox fields that doubles
        // some rows into both buckets; `!= FALSE` matches the same semantic set
        // without the duplication.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Description__c',
                'Type__c',
                'Output_Format__c',
                'Is_Active__c',
                'Is_Default__c',
                'Query_Config__c',
                'Category__c',
                'Sort_Order__c',
                'Lock_Output_Format__c',
                'Specific_Record_Ids__c',
                'Required_Permission_Sets__c',
                'Record_Filter__c',
                'Base_Object_API__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> all = [
            SELECT
                Id,
                Name,
                Description__c,
                Type__c,
                Output_Format__c,
                Is_Active__c,
                Is_Default__c,
                Query_Config__c,
                Category__c,
                Sort_Order__c,
                Lock_Output_Format__c,
                Specific_Record_Ids__c,
                Required_Permission_Sets__c,
                Record_Filter__c,
                Base_Object_API__c
            FROM DocGen_Template__c
            WHERE Base_Object_API__c = :objectApiName AND Is_Active__c != FALSE
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Is_Default__c DESC, Name ASC
        ];
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets

        if (all.isEmpty())
            return all;

        Set<Id> userReadableTemplateIds = getUserReadableTemplateIds(all);
        if (userReadableTemplateIds.isEmpty()) {
            return new List<DocGen_Template__c>();
        }

        Boolean applyRecordFilter = String.isNotBlank(recordId);
        String recordId18 = normalizeRecordId(recordId);
        Set<String> userPermSets = getCurrentUserPermissionSetNames();

        // Cache results of per-record-filter evaluations so templates sharing the same
        // clause incur only one SOQL query per (clause, record) combo.
        Map<String, Boolean> filterCache = new Map<String, Boolean>();

        List<DocGen_Template__c> visible = new List<DocGen_Template__c>();
        for (DocGen_Template__c t : all) {
            if (!userReadableTemplateIds.contains(t.Id))
                continue;
            if (applyRecordFilter && !templateMatchesRecord(t, recordId18, filterCache))
                continue;
            if (!templateVisibleToUser(t, userPermSets))
                continue;
            visible.add(t);
        }
        return visible;
    }

    /**
     * Returns the API names of every permission set currently assigned to the running user.
     * Used by template visibility filtering.
     */
    @TestVisible
    public static Set<String> getCurrentUserPermissionSetNames() {
        Set<String> names = new Set<String>();
        try {
            Id currentUserId = UserInfo.getUserId();
            /* code-analyzer-suppress ApexFlsViolation */
            for (PermissionSetAssignment psa : [
                SELECT PermissionSet.Name, PermissionSet.Label
                FROM PermissionSetAssignment
                WHERE AssigneeId = :currentUserId
                WITH USER_MODE
            ]) {
                if (psa.PermissionSet != null && psa.PermissionSet.Name != null) {
                    addAudienceToken(names, psa.PermissionSet.Name);
                }
                if (psa.PermissionSet != null && psa.PermissionSet.Label != null) {
                    addAudienceToken(names, psa.PermissionSet.Label);
                }
            }
        } catch (Exception e) {
            names.clear();
        }
        return names;
    }

    @TestVisible
    private static String normalizeRecordId(String recordId) {
        if (String.isBlank(recordId))
            return null;
        try {
            return String.valueOf(Id.valueOf(recordId.trim()));
        } catch (Exception e) {
            return null;
        }
    }

    private static Set<Id> getUserReadableTemplateIds(List<DocGen_Template__c> templates) {
        Set<Id> templateIds = new Set<Id>();
        for (DocGen_Template__c template : templates) {
            if (template != null && template.Id != null) {
                templateIds.add(template.Id);
            }
        }
        if (templateIds.isEmpty()) {
            return templateIds;
        }

        Set<Id> readableIds = new Set<Id>();
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            for (DocGen_Template__c template : [
                SELECT Id
                FROM DocGen_Template__c
                WHERE Id IN :templateIds
                WITH USER_MODE
            ]) {
                readableIds.add(template.Id);
            }
        } catch (Exception e) {
            // If the user cannot read Portwood templates at all, the runner should show none.
            readableIds.clear();
        }
        return readableIds;
    }

    /**
     * Returns true when the template applies to the given record.
     * Precedence:
     *   1. Record_Filter__c (SOQL WHERE clause) — if set, evaluate it against the record; wins over Specific_Record_Ids__c.
     *   2. Specific_Record_Ids__c (comma-separated Ids) — match if recordId is in the list.
     *   3. Neither set — template applies to all records of its Base Object.
     */
    private static Boolean templateMatchesRecord(
        DocGen_Template__c t,
        String recordId18,
        Map<String, Boolean> filterCache
    ) {
        // Record Filter (WHERE clause) takes precedence when set
        if (String.isNotBlank(t.Record_Filter__c)) {
            if (String.isBlank(recordId18))
                return false; // filter is set but no record context
            if (String.isBlank(t.Base_Object_API__c))
                return false; // misconfigured template
            return recordMatchesFilter(t.Base_Object_API__c, recordId18, t.Record_Filter__c, filterCache);
        }
        // Fall back to Id list
        if (String.isBlank(t.Specific_Record_Ids__c))
            return true;
        if (String.isBlank(recordId18))
            return false;
        for (String rawId : t.Specific_Record_Ids__c.split('[,;\\s]+')) {
            String trimmed = rawId.trim();
            if (String.isBlank(trimmed))
                continue;
            try {
                if (String.valueOf(Id.valueOf(trimmed)) == recordId18)
                    return true;
            } catch (Exception e) {
                continue;
            }
        }
        return false;
    }

    /**
     * Evaluates a SOQL WHERE clause against a specific record.
     * Runs `SELECT Id FROM {base} WHERE Id = :recordId AND ({whereClause}) LIMIT 1` and returns
     * true when a row comes back. Uses DocGenDataRetriever.sanitizeWhereClause to block DML
     * keywords / semicolons / subqueries before the clause reaches dynamic SOQL.
     *
     * Malformed clauses (throws on sanitize or at query time) return false — the template hides
     * rather than exposing every record. This is the safer default for a noise-reduction feature.
     *
     * filterCache dedupes lookups when multiple templates share the same clause for the same record.
     */
    private static Boolean recordMatchesFilter(
        String baseObjectApiName,
        String recordId18,
        String whereClause,
        Map<String, Boolean> filterCache
    ) {
        String cacheKey = baseObjectApiName + '|' + recordId18 + '|' + whereClause;
        if (filterCache != null && filterCache.containsKey(cacheKey)) {
            return filterCache.get(cacheKey);
        }

        Boolean matched = false;
        try {
            String safeClause = DocGenDataRetriever.sanitizeWhereClause(whereClause);
            SObjectType objType = Schema.getGlobalDescribe().get(baseObjectApiName);
            if (objType == null) {
                matched = false;
            } else {
                Id recordId = Id.valueOf(recordId18);
                String soql =
                    'SELECT Id FROM ' +
                    String.escapeSingleQuotes(baseObjectApiName) +
                    ' WHERE Id = :recordId AND (' +
                    safeClause +
                    ') LIMIT 1';
                /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
                List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — clause sanitized via DocGenDataRetriever.sanitizeWhereClause; object name escaped; Id param bound
                matched = !rows.isEmpty();
            }
        } catch (Exception e) {
            // Malformed clause, inaccessible object, or Id parse failure — hide the template.
            matched = false;
        }

        if (filterCache != null)
            filterCache.put(cacheKey, matched);
        return matched;
    }

    /**
     * Shared filter path for the signature sender's template picker.
     * Applies per-record filter (Record_Filter__c wins over Specific_Record_Ids__c) and
     * audience filter (Required_Permission_Sets__c). Called from DocGenSignatureSenderController
     * to avoid duplicating the filter logic in two places.
     */
    public static List<DocGen_Template__c> filterTemplatesForSender(
        List<DocGen_Template__c> all,
        String relatedRecordId
    ) {
        if (all == null || all.isEmpty())
            return all;
        Boolean applyRecordFilter = String.isNotBlank(relatedRecordId);
        String recordId18 = normalizeRecordId(relatedRecordId);
        Set<String> userPermSets = getCurrentUserPermissionSetNames();
        Set<Id> userReadableTemplateIds = getUserReadableTemplateIds(all);
        Map<String, Boolean> filterCache = new Map<String, Boolean>();

        List<DocGen_Template__c> visible = new List<DocGen_Template__c>();
        for (DocGen_Template__c t : all) {
            if (!userReadableTemplateIds.contains(t.Id))
                continue;
            if (applyRecordFilter && !templateMatchesRecord(t, recordId18, filterCache))
                continue;
            if (!templateVisibleToUser(t, userPermSets))
                continue;
            visible.add(t);
        }
        return visible;
    }

    /**
     * Admin utility — lets the template editor test a WHERE clause against a sample record
     * before saving. Returns { matched: Boolean, error: String|null } so the LWC can show a
     * green/red indicator with the error text on failure.
     */
    @AuraEnabled
    public static Map<String, Object> testRecordFilter(
        String baseObjectApiName,
        String sampleRecordId,
        String whereClause
    ) {
        Map<String, Object> result = new Map<String, Object>{ 'matched' => false, 'error' => null };
        if (String.isBlank(baseObjectApiName) || String.isBlank(sampleRecordId) || String.isBlank(whereClause)) {
            result.put('error', 'Base Object, Sample Record Id, and WHERE clause are all required.');
            return result;
        }
        try {
            String safeClause = DocGenDataRetriever.sanitizeWhereClause(whereClause);
            SObjectType objType = Schema.getGlobalDescribe().get(baseObjectApiName);
            if (objType == null) {
                result.put('error', 'Unknown Base Object: ' + baseObjectApiName);
                return result;
            }
            Id recordId = Id.valueOf(sampleRecordId);
            String soql =
                'SELECT Id FROM ' +
                String.escapeSingleQuotes(baseObjectApiName) +
                ' WHERE Id = :recordId AND (' +
                safeClause +
                ') LIMIT 1';
            /* code-analyzer-suppress ApexFlsViolation, DatabaseOperationsMustUseWithSharing */
            List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — clause sanitized, object escaped, Id bound
            result.put('matched', !rows.isEmpty());
        } catch (DocGenException e) {
            result.put('error', e.getMessage());
        } catch (Exception e) {
            result.put('error', 'Filter invalid or record not accessible: ' + e.getMessage());
        }
        return result;
    }

    /**
     * Returns true when the template's audience filter is empty OR the user has at least one
     * of the listed permission sets assigned.
     */
    private static Boolean templateVisibleToUser(DocGen_Template__c t, Set<String> userPermSets) {
        if (String.isBlank(t.Required_Permission_Sets__c))
            return true;
        if (userPermSets == null || userPermSets.isEmpty())
            return false;
        for (String rawName : t.Required_Permission_Sets__c.split('[,;\\n\\r]+')) {
            String trimmed = rawName.trim();
            if (String.isBlank(trimmed))
                continue;
            if (userPermSets.contains(normalizeAudienceToken(trimmed)))
                return true;
        }
        return false;
    }

    private static void addAudienceToken(Set<String> tokens, String value) {
        String normalized = normalizeAudienceToken(value);
        if (String.isNotBlank(normalized)) {
            tokens.add(normalized);
        }
    }

    @TestVisible
    private static String normalizeAudienceToken(String value) {
        if (String.isBlank(value))
            return null;
        String trimmed = value.trim();
        Integer namespaceIndex = trimmed.indexOf('__');
        if (namespaceIndex > 0 && namespaceIndex + 2 < trimmed.length()) {
            trimmed = trimmed.substring(namespaceIndex + 2);
        }
        return trimmed.toLowerCase();
    }

    /**
     * LIST view of every template — the few fields the grid, the search and the
     * pickers actually read, and nothing else.
     *
     * getAllTemplates (below) returns ~28 fields per row INCLUDING the
     * Header_Html__c / Footer_Html__c / Query_Config__c long-text fields and a
     * ContentDocumentLinks subquery. At a few dozen templates that is merely
     * wasteful; at several hundred it is a large Aura payload transferred and
     * parsed before the admin has clicked anything, for data that is only needed
     * once a specific template is opened.
     *
     * Pair with getTemplateById: list light, load heavy on demand.
     *
     * Ordered by LastModifiedDate so "what I was just working on" is first — the
     * pickers depend on that order and it is cheaper to sort here than in JS.
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getTemplateList() {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Description__c',
                'Type__c',
                'Base_Object_API__c',
                'Category__c',
                'Output_Format__c',
                'Is_Active__c',
                'Is_Default__c',
                'API_Name__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT
                Id,
                Name,
                Description__c,
                Type__c,
                Base_Object_API__c,
                Category__c,
                Output_Format__c,
                Is_Active__c,
                Is_Default__c,
                API_Name__c,
                CreatedDate,
                LastModifiedDate
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 2000
        ];
    }

    /**
     * ONE template with every field the edit modal and the designer need,
     * including the attached-document link the Document tab reads.
     *
     * The second half of the list/detail split — see getTemplateList.
     */
    @AuraEnabled
    public static DocGen_Template__c getTemplateById(Id templateId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        List<DocGen_Template__c> rows = queryTemplateById(templateId);
        if (rows.isEmpty()) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        return rows[0];
    }

    /**
     * Returns all Portwood templates with their latest file attachment info.
     * @return List of all DocGen_Template__c records ordered by category and name
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getAllTemplates() {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Description__c',
                'Type__c',
                'Base_Object_API__c',
                'Category__c',
                'Query_Config__c',
                'Form_Fields_Config__c',
                'Test_Record_Id__c',
                'Output_Format__c',
                'Document_Title_Format__c',
                'Is_Active__c',
                'Is_Default__c',
                'Sort_Order__c',
                'Lock_Output_Format__c',
                'Specific_Record_Ids__c',
                'Required_Permission_Sets__c',
                'Record_Filter__c',
                'Header_Html__c',
                'Footer_Html__c',
                'Page_Orientation__c',
                'Page_Size__c',
                'Page_Margins__c',
                'Custom_Margins__c',
                'Signer_Verification__c',
                'Prefill_Signer_Email__c',
                'Show_Signer_Decline__c',
                'API_Name__c',
                'Default_Email_Message__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT
                Id,
                Name,
                Description__c,
                Type__c,
                Base_Object_API__c,
                Category__c,
                Query_Config__c,
                Form_Fields_Config__c,
                Test_Record_Id__c,
                Output_Format__c,
                Document_Title_Format__c,
                Is_Active__c,
                Is_Default__c,
                Sort_Order__c,
                Lock_Output_Format__c,
                Specific_Record_Ids__c,
                Required_Permission_Sets__c,
                Record_Filter__c,
                Header_Html__c,
                Footer_Html__c,
                Page_Orientation__c,
                Page_Size__c,
                Page_Margins__c,
                Custom_Margins__c,
                Signer_Verification__c,
                Prefill_Signer_Email__c,
                Show_Signer_Decline__c,
                API_Name__c,
                Default_Email_Message__c,
                CreatedDate,
                LastModifiedDate,
                (SELECT ContentDocumentId FROM ContentDocumentLinks ORDER BY ContentDocument.CreatedDate DESC LIMIT 1)
            FROM DocGen_Template__c
            WITH SYSTEM_MODE
            ORDER BY Category__c ASC, Name ASC
            LIMIT 2000
        ];
    }

    /**
     * The heavy read, for ONE template. Deliberately a separate static query rather
     * than a shared dynamic one: SOQL cannot express "this id, or all rows" in a
     * bind, and dynamic SOQL is not worth the injection surface in a package that
     * goes through security review for a field list that changes once a year.
     *
     * Keep the field list in step with getAllTemplates above — they are the same
     * projection, one filtered and one not.
     */
    private static List<DocGen_Template__c> queryTemplateById(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Description__c',
                'Type__c',
                'Base_Object_API__c',
                'Category__c',
                'Query_Config__c',
                'Form_Fields_Config__c',
                'Test_Record_Id__c',
                'Output_Format__c',
                'Document_Title_Format__c',
                'Is_Active__c',
                'Is_Default__c',
                'Sort_Order__c',
                'Lock_Output_Format__c',
                'Specific_Record_Ids__c',
                'Required_Permission_Sets__c',
                'Record_Filter__c',
                'Header_Html__c',
                'Footer_Html__c',
                'Page_Orientation__c',
                'Page_Size__c',
                'Page_Margins__c',
                'Custom_Margins__c',
                'Signer_Verification__c',
                'Prefill_Signer_Email__c',
                'Show_Signer_Decline__c',
                'API_Name__c',
                'Default_Email_Message__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT
                Id,
                Name,
                Description__c,
                Type__c,
                Base_Object_API__c,
                Category__c,
                Query_Config__c,
                Form_Fields_Config__c,
                Test_Record_Id__c,
                Output_Format__c,
                Document_Title_Format__c,
                Is_Active__c,
                Is_Default__c,
                Sort_Order__c,
                Lock_Output_Format__c,
                Specific_Record_Ids__c,
                Required_Permission_Sets__c,
                Record_Filter__c,
                Header_Html__c,
                Footer_Html__c,
                Page_Orientation__c,
                Page_Size__c,
                Page_Margins__c,
                Custom_Margins__c,
                Signer_Verification__c,
                Prefill_Signer_Email__c,
                Show_Signer_Decline__c,
                API_Name__c,
                Default_Email_Message__c,
                CreatedDate,
                LastModifiedDate,
                (SELECT ContentDocumentId FROM ContentDocumentLinks ORDER BY ContentDocument.CreatedDate DESC LIMIT 1)
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    /**
     * Saves template field updates and optionally creates a new template version.
     * @param fields Map of field API names to values for the template record
     * @param createVersion Whether to create a new active version snapshot
     */
    @AuraEnabled
    public static Map<String, Object> saveTemplate(
        Map<String, Object> fields,
        Boolean createVersion,
        String contentVersionId
    ) {
        Id createdVersionId = null;
        Map<String, Object> saveResult = new Map<String, Object>();
        try {
            // 1. Update Template
            Id templateId = (Id) fields.get('Id');
            // #203 — a format switch without a matching new body leaves the active
            // version's file and snapshots in the OLD format; generation then reads
            // (e.g.) DOCX bytes down the HTML branch and silently serves a stale or
            // garbled body. Fail loudly at save time instead: changing the Type
            // requires uploading a new body in that format (Save as New Version).
            String requestedType = (String) fields.get('Type__c');
            if (String.isNotBlank(requestedType) && createVersion != true && templateId != null) {
                DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template__c> current = [
                    SELECT Type__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (
                    !current.isEmpty() &&
                    String.isNotBlank(current[0].Type__c) &&
                    current[0].Type__c != requestedType
                ) {
                    throw new DocGenException(
                        'This template\'s format can\'t change from ' +
                            current[0].Type__c +
                            ' to ' +
                            requestedType +
                            ' without a new body file in that format. Open the Document tab, upload the ' +
                            requestedType +
                            ' file, and use "Save as New Version" — the format and body then update together.'
                    );
                }
            }
            DocGen_Template__c template = new DocGen_Template__c(Id = templateId);
            template.Name = (String) fields.get('Name');
            template.Category__c = (String) fields.get('Category__c');
            template.Type__c = (String) fields.get('Type__c');
            template.Base_Object_API__c = (String) fields.get('Base_Object_API__c');
            template.Description__c = (String) fields.get('Description__c');
            // Query_Config: a blank or omitted value means "leave the stored query
            // unchanged", never "clear it". A designer save that momentarily emptied
            // the query (e.g. the visual builder re-emitting mid-format-switch) must
            // not wipe it — and because activateVersion copies the version's query
            // back onto the template (see setActiveVersion), a blank persisted here
            // would erase a good query on the next activation. Genuine query edits
            // always arrive non-blank. (Community report: DOCX->HTML lost the query.)
            String incomingQuery = (String) fields.get('Query_Config__c');
            String existingQuery;
            if (templateId != null) {
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template__c> qCur = [
                    SELECT Query_Config__c
                    FROM DocGen_Template__c
                    WHERE Id = :templateId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!qCur.isEmpty()) {
                    existingQuery = qCur[0].Query_Config__c;
                }
            }
            String effectiveQuery = String.isNotBlank(incomingQuery) ? incomingQuery : existingQuery;
            template.Query_Config__c = effectiveQuery;
            // Signer form-field config (dedicated carrier, separate from Query_Config__c
            // so it survives single-object templates whose Query_Config__c is a flat
            // field-list string). Only set when present so partial saves don't clear it.
            if (fields.containsKey('Form_Fields_Config__c')) {
                template.Form_Fields_Config__c = (String) fields.get('Form_Fields_Config__c');
            }
            template.Test_Record_Id__c = (String) fields.get('Test_Record_Id__c');
            template.Document_Title_Format__c = (String) fields.get('Document_Title_Format__c');

            // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
            // Update Output Format if provided
            if (fields.containsKey('Output_Format__c')) {
                template.Output_Format__c = (String) fields.get('Output_Format__c');
            }
            // 1.47 — runner visibility & sort fields (only set when key is present so partial saves still work)
            if (fields.containsKey('Sort_Order__c')) {
                Object sortVal = fields.get('Sort_Order__c');
                if (sortVal == null || (sortVal instanceof String && String.isBlank((String) sortVal))) {
                    template.Sort_Order__c = null;
                } else if (sortVal instanceof Decimal) {
                    template.Sort_Order__c = (Decimal) sortVal;
                } else {
                    try {
                        template.Sort_Order__c = Decimal.valueOf(String.valueOf(sortVal));
                    } catch (Exception ignored) {
                        template.Sort_Order__c = null;
                    }
                }
            }
            if (fields.containsKey('Lock_Output_Format__c')) {
                template.Lock_Output_Format__c = (Boolean) fields.get('Lock_Output_Format__c');
            }
            if (fields.containsKey('Specific_Record_Ids__c')) {
                template.Specific_Record_Ids__c = (String) fields.get('Specific_Record_Ids__c');
            }
            if (fields.containsKey('Required_Permission_Sets__c')) {
                template.Required_Permission_Sets__c = (String) fields.get('Required_Permission_Sets__c');
            }
            if (fields.containsKey('Record_Filter__c')) {
                template.Record_Filter__c = (String) fields.get('Record_Filter__c');
            }
            if (fields.containsKey('Header_Html__c')) {
                template.Header_Html__c = (String) fields.get('Header_Html__c');
            }
            if (fields.containsKey('Footer_Html__c')) {
                template.Footer_Html__c = (String) fields.get('Footer_Html__c');
            }
            // 1.68 — page orientation, size, margins
            if (fields.containsKey('Page_Orientation__c')) {
                template.Page_Orientation__c = (String) fields.get('Page_Orientation__c');
            }
            if (fields.containsKey('Page_Size__c')) {
                template.Page_Size__c = (String) fields.get('Page_Size__c');
            }
            if (fields.containsKey('Page_Margins__c')) {
                template.Page_Margins__c = (String) fields.get('Page_Margins__c');
            }
            if (fields.containsKey('Custom_Margins__c')) {
                template.Custom_Margins__c = (String) fields.get('Custom_Margins__c');
            }
            // #verification — template-level signer-verification defaults
            if (fields.containsKey('Signer_Verification__c')) {
                template.Signer_Verification__c = (String) fields.get('Signer_Verification__c');
            }
            if (fields.containsKey('Prefill_Signer_Email__c')) {
                template.Prefill_Signer_Email__c = (String) fields.get('Prefill_Signer_Email__c');
            }
            // #367 — per-template opt-out for the Decline to Sign button
            if (fields.containsKey('Show_Signer_Decline__c')) {
                template.Show_Signer_Decline__c = (Boolean) fields.get('Show_Signer_Decline__c');
            }
            // PHD-9 — stable developer key for Flow lookups. Blank means "leave
            // unchanged": Flows/buttons reference this key, and the create-wizard's
            // follow-up saves (which don't re-collect the API name) must never wipe
            // the value the wizard just persisted.
            if (fields.containsKey('API_Name__c') && String.isNotBlank((String) fields.get('API_Name__c'))) {
                template.API_Name__c = (String) fields.get('API_Name__c');
            }
            // #208 — per-template default {Message} for signature emails
            if (fields.containsKey('Default_Email_Message__c')) {
                template.Default_Email_Message__c = (String) fields.get('Default_Email_Message__c');
            }
            // #85 — Active flag. Default true on new records; only update when the
            // caller explicitly sends the field (so legacy save paths that omit it
            // don't accidentally toggle an existing template's active state).
            if (fields.containsKey('Is_Active__c')) {
                template.Is_Active__c = (Boolean) fields.get('Is_Active__c');
            }
            // Update Default flag if provided — enforce one default per object
            if (fields.containsKey('Is_Default__c')) {
                Boolean isDefault = (Boolean) fields.get('Is_Default__c');
                template.Is_Default__c = isDefault;
                if (isDefault == true && template.Base_Object_API__c != null) {
                    String baseObj = (String) fields.get('Base_Object_API__c');
                    DocGenFlsGuard.assertAccessible(
                        DocGen_Template__c.sObjectType,
                        new Set<String>{ 'Base_Object_API__c', 'Is_Default__c' }
                    );
                    /* code-analyzer-suppress ApexFlsViolation */
                    List<DocGen_Template__c> otherDefaults = [
                        SELECT Id
                        FROM DocGen_Template__c
                        WHERE Base_Object_API__c = :baseObj AND Is_Default__c = TRUE AND Id != :templateId
                        WITH SYSTEM_MODE
                    ];
                    for (DocGen_Template__c other : otherDefaults) {
                        other.Is_Default__c = false;
                    }
                    if (!otherDefaults.isEmpty()) {
                        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                        DocGenFlsGuard.assertUpdateable(otherDefaults, new Set<String>{ 'Is_Default__c' });
                        /* code-analyzer-suppress ApexFlsViolation */
                        Database.update(otherDefaults, AccessLevel.SYSTEM_MODE);
                    }
                }
            }
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            // Allowlist unions every field the conditional setters above could
            // write — DocGenFlsGuard tolerates fields that were never assigned
            // (the SObject just won't carry them in the DML), and ensures the
            // describe check covers any field this method could possibly write.
            DocGenFlsGuard.assertUpdateable(
                template,
                new Set<String>{
                    'Name',
                    'Category__c',
                    'Type__c',
                    'Base_Object_API__c',
                    'Description__c',
                    'Query_Config__c',
                    'Form_Fields_Config__c',
                    'Test_Record_Id__c',
                    'Document_Title_Format__c',
                    'Output_Format__c',
                    'Sort_Order__c',
                    'Lock_Output_Format__c',
                    'Specific_Record_Ids__c',
                    'Required_Permission_Sets__c',
                    'Record_Filter__c',
                    'Header_Html__c',
                    'Footer_Html__c',
                    'Page_Orientation__c',
                    'Page_Size__c',
                    'Page_Margins__c',
                    'Custom_Margins__c',
                    'Signer_Verification__c',
                    'Prefill_Signer_Email__c',
                    'Show_Signer_Decline__c',
                    'API_Name__c',
                    'Default_Email_Message__c',
                    'Is_Active__c',
                    'Is_Default__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(template, AccessLevel.SYSTEM_MODE);

            // 1b. Keep the active version's Output_Format__c in step with the
            // template on a details-only save.
            //
            // The runner LWC reads Output_Format__c off the TEMPLATE record, but
            // every server-side merge reads the ACTIVE VERSION snapshot first
            // (generateDocumentData / generateDocumentDataFromCache) and only falls
            // back to the template when the snapshot is null. A details-only save
            // (createVersion = false) updated the template and left the snapshot
            // alone, so the same template answered "PDF" in the runner and "Native"
            // in the Flow action — a Word→PDF template silently produced a .docx
            // from Flow. The rest of the v1.97 snapshot fields stay frozen by
            // design; output format is the one the UI presents as a live
            // template-level setting, so it has to track.
            if (createVersion != true && fields.containsKey('Output_Format__c')) {
                syncActiveVersionOutputFormat(templateId, (String) fields.get('Output_Format__c'));
            }

            // 2. Create Version if requested
            if (createVersion == true) {
                // Deactivate current active versions. We pull Content_Version_Id__c,
                // Watermark_Image_CV_Id__c, and Type__c here too so we can carry
                // them forward to the new version below —
                // without that, querying for "active" versions AFTER deactivation
                // returns an empty list and version-owned assets silently get
                // dropped on every Save as New Version.
                DocGenFlsGuard.assertAccessible(
                    DocGen_Template_Version__c.sObjectType,
                    new Set<String>{
                        'Content_Version_Id__c',
                        'Watermark_Image_CV_Id__c',
                        'Template__c',
                        'Is_Active__c',
                        'Type__c'
                    }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                List<DocGen_Template_Version__c> activeVersions = [
                    SELECT Id, Content_Version_Id__c, Watermark_Image_CV_Id__c, Type__c
                    FROM DocGen_Template_Version__c
                    WHERE Template__c = :templateId AND Is_Active__c = TRUE
                    WITH SYSTEM_MODE
                    ORDER BY CreatedDate DESC
                ];
                Id priorVersionId = null;
                String priorContentVersionId = null;
                String priorWatermarkCvId = null;
                String priorVersionType = null;
                for (DocGen_Template_Version__c av : activeVersions) {
                    if (priorVersionId == null) {
                        priorVersionId = av.Id;
                        priorVersionType = av.Type__c;
                    }
                    if (priorContentVersionId == null && String.isNotBlank(av.Content_Version_Id__c)) {
                        priorContentVersionId = av.Content_Version_Id__c;
                    }
                    if (priorWatermarkCvId == null && String.isNotBlank(av.Watermark_Image_CV_Id__c)) {
                        priorWatermarkCvId = av.Watermark_Image_CV_Id__c;
                    }
                    av.Is_Active__c = false;
                }
                if (!activeVersions.isEmpty()) {
                    // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                    DocGenFlsGuard.assertUpdateable(activeVersions, new Set<String>{ 'Is_Active__c' });
                    /* code-analyzer-suppress ApexFlsViolation */
                    Database.update(activeVersions, AccessLevel.SYSTEM_MODE);
                }

                // Use specific ContentVersion ID if provided (from upload event).
                // If the admin saves a new version without uploading another file,
                // carry forward the prior active version's template body. Only if
                // legacy data has no version body do we fall back to the newest
                // file linked to the template.
                String cvId = contentVersionId;
                if (String.isBlank(cvId) && String.isNotBlank(priorContentVersionId)) {
                    cvId = priorContentVersionId;
                }
                if (String.isBlank(cvId)) {
                    List<ContentDocumentLink> links = [
                        SELECT ContentDocument.LatestPublishedVersionId
                        FROM ContentDocumentLink
                        WHERE LinkedEntityId = :templateId
                        WITH USER_MODE
                        ORDER BY ContentDocument.CreatedDate DESC
                        LIMIT 1
                    ];
                    if (!links.isEmpty()) {
                        cvId = links[0].ContentDocument.LatestPublishedVersionId;
                    }
                }

                DocGen_Template_Version__c version = new DocGen_Template_Version__c();
                version.Template__c = templateId;
                // Same blank-safe rule as the template above — inherit the stored
                // query when the save omits it, so activating this version can never
                // wipe the template's query.
                version.Query_Config__c = effectiveQuery;
                version.Content_Version_Id__c = cvId;
                version.Is_Active__c = true;

                // Snapshot Headers
                version.Category__c = (String) fields.get('Category__c');
                version.Description__c = (String) fields.get('Description__c');
                version.Type__c = (String) fields.get('Type__c');
                version.Base_Object_API__c = (String) fields.get('Base_Object_API__c');
                // 1.68 — snapshot the page orientation, size, and margins so each
                // version remembers the PDF page setup it was rendered against,
                // even if the template-level fields change later.
                version.Page_Orientation__c = (String) fields.get('Page_Orientation__c');
                version.Page_Size__c = (String) fields.get('Page_Size__c');
                version.Page_Margins__c = (String) fields.get('Page_Margins__c');
                version.Custom_Margins__c = (String) fields.get('Custom_Margins__c');
                // 1.97 — snapshot output format, header/footer HTML, and title format
                // so a version is a true render snapshot. Without these, restoring an
                // older version still rendered with the *template*'s current values,
                // which silently changed output when admins edited the template.
                version.Output_Format__c = (String) fields.get('Output_Format__c');
                version.Header_Html__c = (String) fields.get('Header_Html__c');
                version.Footer_Html__c = (String) fields.get('Footer_Html__c');
                version.Document_Title_Format__c = (String) fields.get('Document_Title_Format__c');

                // Carry forward the watermark from the previous active version so a
                // template re-save (or any new version) doesn't silently lose the
                // watermark the admin uploaded earlier. Watermark is conceptually
                // tied to the template, not the version — auto-inheriting matches
                // user expectation. We captured priorWatermarkCvId BEFORE the
                // deactivation update above; querying after deactivation returns
                // empty (the bug fixed in this method).
                if (String.isNotBlank(priorWatermarkCvId)) {
                    version.Watermark_Image_CV_Id__c = priorWatermarkCvId;
                }

                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                DocGenFlsGuard.assertCreateable(
                    version,
                    new Set<String>{
                        'Template__c',
                        'Query_Config__c',
                        'Content_Version_Id__c',
                        'Is_Active__c',
                        'Category__c',
                        'Description__c',
                        'Type__c',
                        'Base_Object_API__c',
                        'Page_Orientation__c',
                        'Page_Size__c',
                        'Page_Margins__c',
                        'Custom_Margins__c',
                        'Output_Format__c',
                        'Header_Html__c',
                        'Footer_Html__c',
                        'Document_Title_Format__c',
                        'Watermark_Image_CV_Id__c'
                    }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                Database.insert(version, AccessLevel.SYSTEM_MODE);
                createdVersionId = version.Id;

                if (
                    String.isBlank(contentVersionId) &&
                    priorVersionId != null &&
                    priorVersionType == 'PDF' &&
                    version.Type__c == 'PDF'
                ) {
                    copyPdfAcroFormSnapshot(templateId, priorVersionId, version.Id);
                }

                // Decompose DOCX/PPTX into per-image and per-XML ContentVersions for
                // heap-light PDF rendering. Runs in a Queueable (12 MB async heap)
                // rather than inline (6 MB sync heap) so it survives real-world
                // templates with iPhone-sized images that previously silently
                // failed save-time decomposition.
                DocGenService.enqueueTemplateImageExtraction(templateId, version.Id);

                // HTML templates (v1.61+): if the upload was a Google Docs
                // "Download → Web Page" zip, extract images + rewrite src refs.
                // No-ops for single-html uploads or non-HTML templates.
                try {
                    DocGenService.extractAndSaveHtmlTemplateAssets(templateId, version.Id);
                } catch (Exception htmlErr) {
                    String noop = htmlErr.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            }
            // Fidelity report (issue #272) for Word/PowerPoint uploads. Lint the
            // newly uploaded body and hand the findings back with the save result,
            // mirroring saveHtmlTemplateBody's `warnings`/`warningCount` keys.
            // Warnings only — the version is already stored, and a lint failure
            // must never change the save outcome.
            List<DocGenAiHtmlValidator.Finding> warnings = new List<DocGenAiHtmlValidator.Finding>();
            try {
                if (
                    createVersion == true &&
                    String.isNotBlank(contentVersionId) &&
                    isDocxBodyType((String) fields.get('Type__c'))
                ) {
                    warnings = lintUploadedOfficeBody(contentVersionId);
                }
            } catch (Exception lintErr) {
                String noop = lintErr.getMessage(); // NOPMD — lint is advisory; it must never fail a save
            }
            saveResult.put('createdVersionId', createdVersionId);
            saveResult.put('warnings', warnings);
            saveResult.put('warningCount', warnings.size());
            return saveResult;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving template. Please verify your inputs and permissions.');
        }
    }

    /** The Word/PowerPoint template types the DOCX/PPTX linter covers. */
    private static Boolean isDocxBodyType(String type) {
        return type == 'Word' || type == 'PowerPoint' || type == 'PPT' || type == 'PPTX';
    }

    /** Reads a just-uploaded body ContentVersion and lints its Office bytes. */
    private static List<DocGenAiHtmlValidator.Finding> lintUploadedOfficeBody(Id contentVersionId) {
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :contentVersionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty() || cvs[0].VersionData == null) {
            return new List<DocGenAiHtmlValidator.Finding>();
        }
        return DocGenDocxTemplateLinter.lint(cvs[0].VersionData);
    }

    /**
     * PDF AcroForm template upload — browser-side decomposition snapshot.
     *
     * Some real-world PDFs, including IRS forms authored with Adobe Designer,
     * store AcroForm dictionaries inside compressed PDF object streams. Apex can
     * cheaply append incremental field-value updates once the relevant object
     * dictionaries are known, but it cannot inflate arbitrary FlateDecode PDF
     * streams at render time. The admin LWC therefore performs the one-time
     * browser decomposition at upload/save time and stores the server-friendly
     * field snapshot as a managed ContentVersion.
     */
    @AuraEnabled
    public static Id savePdfAcroFormSnapshot(Id templateId, Id versionId, String snapshotJson) {
        if (templateId == null || versionId == null) {
            throw DocGenService.ahe('Template and version are required.');
        }
        if (String.isBlank(snapshotJson)) {
            throw DocGenService.ahe('PDF AcroForm snapshot is empty.');
        }
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Template__c', 'Type__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> versions = [
                SELECT Id, Template__c, Type__c
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId AND Template__c = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw DocGenService.ahe('Template version not found.');
            }
            if (versions[0].Type__c != 'PDF') {
                throw DocGenService.ahe('PDF AcroForm snapshots can only be saved for PDF template versions.');
            }

            return insertPdfAcroFormSnapshot(templateId, versionId, snapshotJson);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving PDF AcroForm snapshot.');
        }
    }

    private static Id copyPdfAcroFormSnapshot(Id templateId, Id sourceVersionId, Id targetVersionId) {
        String sourceTitle = 'docgen_tmpl_pdf_' + String.valueOf(sourceVersionId) + '_acroform';
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData', 'Title' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> snapshots = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Title = :sourceTitle
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        if (snapshots.isEmpty() || snapshots[0].VersionData == null) {
            return null;
        }
        return insertPdfAcroFormSnapshot(templateId, targetVersionId, snapshots[0].VersionData.toString());
    }

    private static Id insertPdfAcroFormSnapshot(Id templateId, Id versionId, String snapshotJson) {
        String snapshotTitle = 'docgen_tmpl_pdf_' + String.valueOf(versionId) + '_acroform';
        deleteExistingPdfAcroFormSnapshots(snapshotTitle);

        ContentVersion cv = new ContentVersion(
            Title = snapshotTitle,
            PathOnClient = snapshotTitle + '.json',
            VersionData = Blob.valueOf(snapshotJson),
            IsMajorVersion = true
        );
        DocGenFlsGuard.assertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'IsMajorVersion' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cv, AccessLevel.SYSTEM_MODE);

        Id contentDocId = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ]
        .ContentDocumentId;
        ContentDocumentLink cdl = new ContentDocumentLink(
            ContentDocumentId = contentDocId,
            LinkedEntityId = templateId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cdl, AccessLevel.SYSTEM_MODE);
        return cv.Id;
    }

    /**
     * Points the active version snapshot's Output_Format__c at the value just
     * saved on the template, so the server-side merge (Flow action, queueables,
     * bulk) resolves the same format the runner UI shows. No-op when there is no
     * active version or the snapshot already agrees.
     */
    private static void syncActiveVersionOutputFormat(Id templateId, String outputFormat) {
        if (templateId == null || String.isBlank(outputFormat)) {
            return;
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Template__c', 'Is_Active__c', 'Output_Format__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVersions = [
            SELECT Id, Output_Format__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
        if (activeVersions.isEmpty() || activeVersions[0].Output_Format__c == outputFormat) {
            return;
        }
        activeVersions[0].Output_Format__c = outputFormat;
        DocGenFlsGuard.assertUpdateable(activeVersions, new Set<String>{ 'Output_Format__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        Database.update(activeVersions, AccessLevel.SYSTEM_MODE);
    }

    private static void deleteExistingPdfAcroFormSnapshots(String snapshotTitle) {
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> existingSnapshots = [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Title = :snapshotTitle
            WITH SYSTEM_MODE
        ];
        if (existingSnapshots.isEmpty()) {
            return;
        }

        List<ContentDocument> docsToDelete = new List<ContentDocument>();
        for (ContentVersion snapshot : existingSnapshots) {
            if (snapshot.ContentDocumentId != null) {
                docsToDelete.add(new ContentDocument(Id = snapshot.ContentDocumentId));
            }
        }
        if (!docsToDelete.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(docsToDelete, AccessLevel.SYSTEM_MODE);
        }
    }

    @AuraEnabled
    public static Map<String, Object> getActivePdfAcroFormSnapshot(Id templateId) {
        if (templateId == null) {
            return new Map<String, Object>();
        }
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Template__c', 'Type__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> versions = [
                SELECT Id, Type__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            if (versions.isEmpty() || versions[0].Type__c != 'PDF') {
                return new Map<String, Object>();
            }
            String title = 'docgen_tmpl_pdf_' + String.valueOf(versions[0].Id) + '_acroform';
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData', 'Title' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> snapshots = [
                SELECT VersionData
                FROM ContentVersion
                WHERE Title = :title
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 1
            ];
            return new Map<String, Object>{
                'versionId' => versions[0].Id,
                'snapshotJson' => snapshots.isEmpty() ? null : snapshots[0].VersionData.toString()
            };
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error loading PDF AcroForm snapshot.');
        }
    }

    /**
     * HTML template upload — image part (v1.61+).
     *
     * Part of the client-side zip-break-apart flow: the LWC unzips Google Docs
     * exports in the browser, then calls this endpoint once per image with the
     * image's base64. Each call consumes only a single image's worth of heap,
     * independent of total template size.
     *
     * The ContentVersion is linked to the template so the image appears in
     * Files and is cleaned up if the template is deleted. Returns the CV Id
     * so the client can rewrite <img src> references before sending the body.
     */
    @AuraEnabled
    public static Map<String, Object> saveHtmlTemplateImage(Id templateId, String fileName, String base64Content) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        if (String.isBlank(fileName)) {
            throw new DocGenException('File name is required.');
        }
        if (String.isBlank(base64Content)) {
            throw new DocGenException('File content is required.');
        }

        // SECURITY (v1.75): USER_MODE access check — caller must have read on
        // this template before we attach a CV to it. Type__c is then read from
        // the same row (no second query needed).
        List<DocGen_Template__c> tpls;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            tpls = [
                SELECT Id, Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (tpls.isEmpty()) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (!DocGenService.isHtmlBacked(tpls[0].Type__c)) {
            throw new DocGenException('saveHtmlTemplateImage is for HTML-backed templates only.');
        }

        String base = fileName.substringAfterLast('/');
        if (String.isBlank(base)) {
            base = fileName;
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = 'docgen_html_img_' + templateId + '_' + Datetime.now().getTime() + '_' + base;
        cv.PathOnClient = base;
        cv.VersionData = EncodingUtil.base64Decode(base64Content);
        cv.FirstPublishLocationId = templateId;
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cv, AccessLevel.USER_MODE);

        return new Map<String, Object>{
            'contentVersionId' => cv.Id,
            'fileName' => base,
            'url' => '/sfc/servlet.shepherd/version/download/' + cv.Id
        };
    }

    /**
     * List the images already attached to an HTML template (uploaded via
     * saveHtmlTemplateImage — the zip/data-URI extraction path or the
     * editor's Add Image flow). Feeds the editor's image picker so authors
     * can re-insert existing images without knowing shepherd URLs.
     */
    @AuraEnabled
    public static List<Map<String, Object>> listHtmlTemplateImages(Id templateId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tpls = [
                SELECT Id
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                throw DocGenService.ahe('Template not found or access denied.');
            }
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }

        // CDL-scoped for the same reason as getHtmlTemplateBody — a title-only query
        // returns nothing for any user who doesn't own the files, so this rendered an
        // empty image picker for everyone except a System Administrator. Metadata-only
        // variant: pulling VersionData would load every image blob into heap just to
        // render a list.
        List<ContentVersion> cvs = DocGenService.loadInternalContentVersionMetaForEntityByTitlePrefix(
            templateId,
            'docgen_html_img_'
        );
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (ContentVersion cv : cvs) {
            results.add(
                new Map<String, Object>{
                    'contentVersionId' => cv.Id,
                    'fileName' => cv.PathOnClient,
                    'url' => '/sfc/servlet.shepherd/version/download/' + cv.Id
                }
            );
        }
        return results;
    }

    /**
     * HTML template upload — body part (v1.61+).
     *
     * Final call in the client-side zip-break-apart flow. The LWC has already
     * unzipped, uploaded each image via saveHtmlTemplateImage, and rewritten
     * every <img src="..."> in the HTML to point at the returned CV URLs.
     * Server just stores the finished HTML as a ContentVersion — tiny heap.
     *
     * Returns the same shape lightning-file-upload produces so the rest of
     * the LWC save flow (Save as New Version → saveTemplate) is unchanged.
     */
    /**
     * Does this HTML carry anything an author would be sorry to lose?
     *
     * Used only to decide whether a save is a legitimate edit or an accidental wipe,
     * so it errs toward "yes" — anything structural (an image, a table, a merge tag)
     * counts even with no visible text, and only a genuinely blank document or the
     * Designer's own seed placeholder returns false. A false positive here costs
     * nothing; a false negative would let a body get overwritten.
     */
    @TestVisible
    private static Boolean hasSubstantiveHtml(String html) {
        if (String.isBlank(html)) {
            return false;
        }
        // Drop head/style/script FIRST. A CSS rule body (`p{color:red}`) is textually
        // indistinguishable from a merge tag, so checking for tags before stripping
        // made every styled-but-empty document look like it had content.
        String cleaned = html.replaceAll('(?is)<(head|style|script)\\b[^>]*>.*?</\\1\\s*>', ' ');

        // Structural content counts regardless of text.
        String lower = cleaned.toLowerCase();
        if (lower.contains('<img') || lower.contains('<table') || lower.contains('<svg')) {
            return true;
        }
        // A merge tag is authored content even if the document is otherwise bare.
        if (Pattern.compile('\\{[#^/%@]?[A-Za-z_][^}]*\\}').matcher(cleaned).find()) {
            return true;
        }
        String text = cleaned.replaceAll('(?s)<[^>]*>', ' ');
        text = text.replaceAll('&nbsp;|&#160;', ' ').replaceAll('\\s+', ' ').trim();
        if (String.isBlank(text)) {
            return false;
        }
        // The Designer's seed copy for a blank canvas is not authored content — if it
        // is all that is being saved, the editor never loaded a real body.
        return !text.startsWithIgnoreCase('Start typing your document here');
    }

    @AuraEnabled
    public static Map<String, Object> saveHtmlTemplateBody(Id templateId, String fileName, String htmlContent) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        if (String.isBlank(htmlContent)) {
            throw new DocGenException('HTML content is required.');
        }

        // SECURITY (v1.75): USER_MODE access check — caller must have read on
        // this template before we attach a body CV to it.
        List<DocGen_Template__c> tpls;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            tpls = [
                SELECT Id, Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (tpls.isEmpty()) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        // Canvas bodies ARE HTML documents — the canvas editor serializes artboards
        // and boxes to the CANVAS_CSS contract. Same storage, same read path.
        if (!DocGenService.isHtmlBacked(tpls[0].Type__c)) {
            throw new DocGenException('saveHtmlTemplateBody is for HTML-backed templates only.');
        }

        // Refuse to overwrite a real body with an empty one.
        //
        // The Designer seeds a placeholder scaffold ("Start typing your document
        // here…") whenever the stored body reads back blank. That is correct for a
        // genuinely new template — but when a READ failure made an existing body look
        // blank, hitting Save wrote the placeholder straight over the author's work.
        // That is exactly what the non-admin file-access bug did: the canvas came up
        // empty for everyone without View All Data, and one Save destroyed the body.
        //
        // The read is fixed, but this is the guard that makes the failure mode
        // non-destructive for good: no future read bug, permission gap, or race can
        // turn "I couldn't load it" into "I deleted it". Deliberately server-side so
        // it holds for every caller, not just the Designer.
        if (!hasSubstantiveHtml(htmlContent)) {
            List<ContentVersion> existing = DocGenService.loadInternalContentVersionsForVersionByTitlePrefix(
                templateId,
                'docgen_html_body_'
            );
            if (!existing.isEmpty() && hasSubstantiveHtml(existing[0].VersionData.toString())) {
                throw new DocGenException(
                    'This would replace the saved template body with an empty document, so it was not saved. ' +
                        'If the editor opened blank, close it and reopen the template — the body is still stored. ' +
                        'To intentionally start over, add some content first, then save.'
                );
            }
        }

        String pathBase = String.isBlank(fileName) ? 'body' : fileName.substringBeforeLast('.');
        if (String.isBlank(pathBase)) {
            pathBase = 'body';
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = 'docgen_html_body_' + templateId + '_' + Datetime.now().getTime();
        cv.PathOnClient = pathBase + '.html';
        cv.VersionData = Blob.valueOf(htmlContent);
        cv.FirstPublishLocationId = templateId;
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cv, AccessLevel.USER_MODE);

        /* code-analyzer-suppress ApexFlsViolation */
        ContentVersion reload = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            WITH USER_MODE
            LIMIT 1
        ];

        // Fidelity report (issue #272): lint the body that was just saved and hand
        // the findings back with the save result. Warnings only — the save has
        // already succeeded, and a lint failure must never change that.
        List<DocGenAiHtmlValidator.Finding> warnings = new List<DocGenAiHtmlValidator.Finding>();
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{
                    'Base_Object_API__c',
                    'Query_Config__c',
                    'Page_Size__c',
                    'Page_Orientation__c',
                    'Page_Margins__c',
                    'Custom_Margins__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> lintTpls = [
                SELECT
                    Base_Object_API__c,
                    Query_Config__c,
                    Page_Size__c,
                    Page_Orientation__c,
                    Page_Margins__c,
                    Custom_Margins__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            // Skip the fidelity report for canvas-authored bodies.
            //
            // The report exists to tell an author what the PDF engine will do
            // differently with HTML THEY wrote or imported. Canvas HTML is
            // generated from the designer's own model, so every rule it can trip
            // is either deliberate or already handled:
            //
            //   - `position: absolute` is how a pinned box lands where it was
            //     drawn. That is the feature, not a mistake.
            //   - the row loop is already emitted inside <tbody>, which is the
            //     shape the engine expands; the between-rows rule misreads it.
            //
            // Reporting these tells the author their own tool produced something
            // questionable, about markup they never wrote and cannot change, and
            // points them at an edit view that does not govern the canvas.
            Boolean fromCanvas = String.isNotBlank(htmlContent) && htmlContent.contains('dg-artboard');
            if (!lintTpls.isEmpty() && !fromCanvas) {
                warnings = DocGenTemplateLinter.lint(htmlContent, lintTpls[0]);
            }
        } catch (Exception lintErr) {
            String noop = lintErr.getMessage(); // NOPMD — lint is advisory; it must never fail a save
        }

        return new Map<String, Object>{
            'contentVersionId' => cv.Id,
            'contentDocumentId' => reload.ContentDocumentId,
            'fileName' => fileName,
            'warnings' => warnings,
            'warningCount' => warnings.size()
        };
    }

    /**
     * Returns a specific version's stored body.
     *
     * The canvas reads this rather than the loose `docgen_html_body_*` CV, so the
     * editor and the RENDERER are looking at the same bytes. Reading the loose body
     * while generation read the version's is exactly how a template came to show five
     * boxes on screen and render two, with nothing reporting a problem.
     *
     * Version-scoped so "go back to the version from Tuesday" can actually restore
     * that canvas, rather than restoring whatever was saved most recently.
     */
    @AuraEnabled
    public static String getVersionBody(Id versionId) {
        if (versionId == null) {
            throw new DocGenException('Version ID is required.');
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vs = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :versionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (vs.isEmpty() || String.isBlank(vs[0].Content_Version_Id__c)) {
            return null;
        }
        Id cvId = (Id) vs[0].Content_Version_Id__c;
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        // SYSTEM_MODE: template-internal CVs carry Visibility=InternalUsers links,
        // which USER_MODE reads silently drop (#114).
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :cvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return cvs.isEmpty() ? null : cvs[0].VersionData.toString();
    }

    /**
     * Saves an HTML/Canvas body AND points the active version at it, so what was just
     * saved is what will render.
     *
     * A template carries TWO bodies. `docgen_html_body_<templateId>` is what the
     * editors read and write; the active DocGen_Template_Version__c's
     * Content_Version_Id__c is what the RENDER path loads. saveHtmlTemplateBody only
     * writes the first, which is correct for the flow designer — it has an explicit
     * "Save as New Version" step that publishes.
     *
     * The canvas has no such step and should not need one: you arrange a page, you
     * press Save, and the document you get must be the page you arranged. Without this
     * the two bodies drift and generation quietly renders an older canvas — measured
     * on a real template as 5 boxes stored versus 2 boxes rendered, with no error
     * anywhere. That is the worst kind of bug: everything reports success and the
     * output is simply wrong.
     */
    @AuraEnabled
    // Single signature, no overload: @AuraEnabled methods cannot be overloaded, and a
    // second one fails the deploy rather than shadowing quietly.
    public static Map<String, Object> saveAndPublishHtmlBody(
        Id templateId,
        String fileName,
        String htmlContent,
        Boolean newVersion
    ) {
        Map<String, Object> saved = saveHtmlTemplateBody(templateId, fileName, htmlContent);
        Id cvId = (Id) saved.get('contentVersionId');

        // Every authoring field, not just the body pointer. A new version has to be a
        // COPY of the one it supersedes — see the insert below.
        Set<String> versionFields = new Set<String>{
            'Template__c',
            'Is_Active__c',
            'Content_Version_Id__c',
            'Query_Config__c',
            'Base_Object_API__c',
            'Category__c',
            'Description__c',
            'Type__c',
            'Output_Format__c',
            'Document_Title_Format__c',
            'Header_Html__c',
            'Footer_Html__c',
            'Page_Size__c',
            'Page_Orientation__c',
            'Page_Margins__c',
            'Custom_Margins__c',
            'Watermark_Image_CV_Id__c'
        };
        DocGenFlsGuard.assertAccessible(DocGen_Template_Version__c.sObjectType, versionFields);
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> active = [
            SELECT
                Id,
                Content_Version_Id__c,
                Query_Config__c,
                Base_Object_API__c,
                Category__c,
                Description__c,
                Type__c,
                Output_Format__c,
                Document_Title_Format__c,
                Header_Html__c,
                Footer_Html__c,
                Page_Size__c,
                Page_Orientation__c,
                Page_Margins__c,
                Custom_Margins__c,
                Watermark_Image_CV_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        DocGen_Template__c tpl = [
            SELECT Type__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        // A save creates a NEW version and makes it active, rather than repointing the
        // current one. Repointing meant every save overwrote the only record of what
        // the document used to be, so the version picker could never take you back to
        // anything — which is the entire reason it exists. Versions are cheap; a lost
        // layout is not.
        if (newVersion) {
            // Deactivate EVERY active version, not just the one read above.
            //
            // That read is LIMIT 1, so deactivating only it would leave any other
            // active rows active and the template would end up with several. The
            // renderer picks its active version with LIMIT 1 and NO ORDER BY
            // (DocGenTemplateManager.getTemplateFileContent), so which body prints
            // becomes arbitrary — a save appears to do nothing because the PDF is
            // built from some older version. Sweeping them all also self-heals a
            // template that already drifted into that state.
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> allActive = [
                SELECT Id, Is_Active__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
            ];
            for (DocGen_Template_Version__c prior : allActive) {
                prior.Is_Active__c = false;
            }
            if (!allActive.isEmpty()) {
                DocGenFlsGuard.assertUpdateable(allActive, new Set<String>{ 'Is_Active__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                Database.update(allActive, AccessLevel.SYSTEM_MODE);
            }
            // CLONE the version being superseded, then repoint the body.
            //
            // A version carries the whole authoring config — query, base object, page
            // size, margins, header/footer, output format — and activateVersion pushes
            // those fields BACK onto the template. So a new version built from scratch
            // with only a body pointer does not merely lose its own settings: activating
            // it wipes the template's query config and page setup. Cloning means a save
            // changes exactly one thing, which is what a save should do.
            DocGen_Template_Version__c fresh;
            if (!active.isEmpty()) {
                fresh = active[0].clone(false, true, false, false);
            } else {
                fresh = new DocGen_Template_Version__c(Template__c = templateId, Type__c = tpl.Type__c);
            }
            fresh.Template__c = templateId;
            fresh.Content_Version_Id__c = cvId;
            fresh.Is_Active__c = true;
            if (String.isBlank(fresh.Type__c)) {
                fresh.Type__c = tpl.Type__c;
            }
            DocGenFlsGuard.assertCreateable(fresh, versionFields);
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(fresh, AccessLevel.SYSTEM_MODE);
            saved.put('versionId', fresh.Id);
            saved.put('versionCreated', true);
            return saved;
        }

        if (active.isEmpty()) {
            // No active version yet — a template created outside the wizard. Make one
            // rather than saving into a void the renderer will never read.
            DocGen_Template_Version__c v = new DocGen_Template_Version__c(
                Template__c = templateId,
                Content_Version_Id__c = cvId,
                Is_Active__c = true,
                Type__c = tpl.Type__c
            );
            DocGenFlsGuard.assertCreateable(
                v,
                new Set<String>{ 'Template__c', 'Content_Version_Id__c', 'Is_Active__c', 'Type__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(v, AccessLevel.SYSTEM_MODE);
            saved.put('versionCreated', true);
        } else {
            DocGen_Template_Version__c v = active[0];
            v.Content_Version_Id__c = cvId;
            DocGenFlsGuard.assertUpdateable(v, new Set<String>{ 'Content_Version_Id__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(v, AccessLevel.SYSTEM_MODE);
            saved.put('versionUpdated', true);
        }
        return saved;
    }

    /**
     * HTML template body read-back for the admin editor (paste-back surface).
     *
     * Returns the most recent docgen_html_body_* ContentVersion attached to
     * the template, or null when no body has been uploaded yet. The CV read
     * runs WITH SYSTEM_MODE after an explicit FLS/CRUD gate on the template —
     * template-internal CVs can carry Visibility=InternalUsers ContentDocumentLinks,
     * which USER_MODE reads silently drop (the #114 quirk).
     */
    @AuraEnabled
    public static String getHtmlTemplateBody(Id templateId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }

        List<DocGen_Template__c> tpls;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            tpls = [
                SELECT Id, Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (tpls.isEmpty()) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (!DocGenService.isHtmlBacked(tpls[0].Type__c)) {
            throw new DocGenException('getHtmlTemplateBody is for HTML-backed templates only.');
        }

        // Scope the read by the template's linked documents, NOT by a bare Title LIKE.
        //
        // File access is not governed by Apex sharing keywords or WITH SYSTEM_MODE.
        // Measured on a Standard User holding DocGen_Admin: they could read the
        // template (1 row) and its ContentDocumentLink (1 row), but a title-only
        // ContentVersion query returned ZERO in user mode, in SYSTEM_MODE, and from a
        // `without sharing` class alike. Resolving ContentDocumentIds from the link
        // first returns the row.
        //
        // A System Administrator has View All Data and never hit this, so the Designer
        // canvas always populated for whoever built the template and came up BLANK for
        // every other user — silently, with no toast and no console error, regardless
        // of which permission set they held.
        List<ContentVersion> cvs = DocGenService.loadInternalContentVersionsForVersionByTitlePrefix(
            templateId,
            'docgen_html_body_'
        );
        if (cvs.isEmpty()) {
            return null;
        }
        return cvs[0].VersionData.toString();
    }

    /**
     * DOCX→HTML conversion transparency (admin editor).
     *
     * Returns the pre-baked docgen_tmpl_html_<versionId> snapshot for the
     * template's active version — the exact HTML the PDF engine renders from
     * the author's Word file — plus the decomposition status so the client
     * can explain a missing snapshot ("Pending" = not yet baked). Read-only
     * from the engine's perspective: the snapshot regenerates on every new
     * DOCX upload, so edits are only honored by converting the template to
     * Type=HTML (client-side flow).
     *
     * Uses the same without-sharing internal-CV loaders as the giant-query
     * assembler — these CVs carry Visibility=InternalUsers links that
     * USER_MODE reads silently drop (the #114 quirk).
     */
    @AuraEnabled
    public static Map<String, Object> getConvertedHtmlSnapshot(Id templateId) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }

        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tpls = [
                SELECT Id
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                throw DocGenService.ahe('Template not found or access denied.');
            }
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Is_Active__c', 'Pre_Decomposition_Status__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT Id, Name, Pre_Decomposition_Status__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (vers.isEmpty()) {
            return new Map<String, Object>{ 'html' => null, 'status' => 'NoActiveVersion' };
        }

        String htmlTitle = 'docgen_tmpl_html_' + vers[0].Id;
        List<ContentVersion> htmlCvs = DocGenService.loadInternalContentVersionsForVersionByTitle(
            vers[0].Id,
            htmlTitle
        );
        if (htmlCvs.isEmpty()) {
            htmlCvs = DocGenService.loadInternalContentVersionsByTitle(htmlTitle);
        }

        return new Map<String, Object>{
            'html' => htmlCvs.isEmpty() ? null : htmlCvs[0].VersionData.toString(),
            'versionId' => vers[0].Id,
            'versionName' => vers[0].Name,
            'status' => vers[0].Pre_Decomposition_Status__c
        };
    }

    /**
     * PDF AcroForm template upload — prepared browser-normalized body.
     *
     * Encrypted/object-stream-heavy government forms are normalized once in the
     * browser during template save. The active template version must point at
     * these server-friendly PDF bytes so bulk/async generation can fill fields
     * purely in Apex without repeating decrypt/inflate work.
     */
    @AuraEnabled
    public static Map<String, Object> savePdfAcroFormPreparedBody(
        Id templateId,
        String fileName,
        String base64Content
    ) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        if (String.isBlank(base64Content)) {
            throw new DocGenException('Prepared PDF content is required.');
        }

        List<DocGen_Template__c> tpls;
        try {
            DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            tpls = [
                SELECT Id, Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (QueryException qe) {
            throw DocGenService.ahe('Template not found or access denied.');
        } catch (DocGenException fe) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (tpls.isEmpty()) {
            throw DocGenService.ahe('Template not found or access denied.');
        }
        if (tpls[0].Type__c != 'PDF') {
            throw new DocGenException('savePdfAcroFormPreparedBody is for PDF-type templates only.');
        }

        String pathBase = String.isBlank(fileName) ? 'template' : fileName.substringBeforeLast('.');
        if (String.isBlank(pathBase)) {
            pathBase = 'template';
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = 'docgen_pdf_body_' + templateId + '_' + Datetime.now().getTime();
        cv.PathOnClient = pathBase + '.pdf';
        cv.VersionData = EncodingUtil.base64Decode(base64Content);
        cv.FirstPublishLocationId = templateId;
        DocGenFlsGuard.assertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cv, AccessLevel.SYSTEM_MODE);

        /* code-analyzer-suppress ApexFlsViolation */
        ContentVersion reload = [
            SELECT Id, ContentDocumentId
            FROM ContentVersion
            WHERE Id = :cv.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        return new Map<String, Object>{
            'contentVersionId' => cv.Id,
            'contentDocumentId' => reload.ContentDocumentId,
            'fileName' => fileName
        };
    }

    @AuraEnabled
    public static Id savePdfAcroFormPreparedBodyChunk(
        Id templateId,
        String uploadKey,
        Integer chunkIndex,
        String chunk
    ) {
        if (templateId == null) {
            throw new DocGenException('Template ID is required.');
        }
        if (String.isBlank(uploadKey)) {
            throw new DocGenException('Prepared PDF upload key is required.');
        }
        if (chunkIndex == null) {
            throw new DocGenException('Prepared PDF chunk index is required.');
        }
        if (String.isBlank(chunk)) {
            throw new DocGenException('Prepared PDF chunk is empty.');
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = 'docgen_pdf_body_chunk_' + uploadKey + '_' + String.valueOf(chunkIndex).leftPad(5, '0');
        cv.PathOnClient = cv.Title + '.txt';
        cv.VersionData = Blob.valueOf(chunk);
        cv.FirstPublishLocationId = templateId;
        DocGenFlsGuard.assertCreateable(
            cv,
            new Set<String>{ 'Title', 'PathOnClient', 'VersionData', 'FirstPublishLocationId' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(cv, AccessLevel.SYSTEM_MODE);
        return cv.Id;
    }

    @AuraEnabled
    public static Id finalizePdfAcroFormPreparedBody(
        Id templateId,
        Id versionId,
        String fileName,
        List<Id> chunkVersionIds
    ) {
        if (templateId == null || versionId == null) {
            throw new DocGenException('Template and version are required.');
        }
        if (chunkVersionIds == null || chunkVersionIds.isEmpty()) {
            throw new DocGenException('Prepared PDF chunks are required.');
        }
        return System.enqueueJob(new DocGenPdfPreparedBodyQueueable(templateId, versionId, fileName, chunkVersionIds));
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getPdfAcroFormPreparedBodyStatus(Id versionId, Id jobId) {
        Map<String, Object> result = new Map<String, Object>{
            'jobStatus' => null,
            'jobErrors' => 0,
            'isReady' => false,
            'contentVersionId' => null
        };
        if (jobId != null) {
            List<AsyncApexJob> jobs = [
                SELECT Status, NumberOfErrors, ExtendedStatus
                FROM AsyncApexJob
                WHERE Id = :jobId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                result.put('jobStatus', jobs[0].Status);
                result.put('jobErrors', jobs[0].NumberOfErrors);
                result.put('extendedStatus', jobs[0].ExtendedStatus);
            }
        }
        if (versionId != null) {
            List<DocGen_Template_Version__c> versions = [
                SELECT Content_Version_Id__c
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!versions.isEmpty() && String.isNotBlank(versions[0].Content_Version_Id__c)) {
                Id cvId = (Id) versions[0].Content_Version_Id__c;
                List<ContentVersion> cvs = [
                    SELECT Id, Title
                    FROM ContentVersion
                    WHERE Id = :cvId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    result.put('contentVersionId', cvs[0].Id);
                    result.put('isReady', String.valueOf(cvs[0].Title).startsWith('docgen_pdf_body_'));
                }
            }
        }
        return result;
    }

    /**
     * Deletes a Portwood template record.
     * @param templateId The ID of the template to delete
     */
    @AuraEnabled
    public static void deleteTemplate(Id templateId) {
        try {
            if (!Schema.sObjectType.DocGen_Template__c.isDeletable()) {
                throw DocGenService.ahe('Insufficient access.');
            }
            Set<Id> linkedEntityIds = new Set<Id>{ templateId };
            /* code-analyzer-suppress ApexFlsViolation */
            for (DocGen_Template_Version__c version : [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId
                WITH SYSTEM_MODE
            ]) {
                linkedEntityIds.add(version.Id);
            }
            Set<Id> contentDocumentIds = collectLinkedTemplateContentDocumentIds(linkedEntityIds);
            /* code-analyzer-suppress ApexFlsViolation */
            delete new DocGen_Template__c(Id = templateId); // NOPMD ApexCRUDViolation - isDeletable() checked above; package-internal custom object
            if (!contentDocumentIds.isEmpty()) {
                System.enqueueJob(new DocGenContentDocumentCleanupQueueable(new List<Id>(contentDocumentIds)));
            }
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting template. Please check your permissions.');
        }
    }

    // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets

    /**
     * Returns the byte size of a ContentVersion. Used by the LWC upload guard
     * to reject PDF templates above the 10 MB ceiling that the async-decompose
     * Queueable can survive in 12 MB heap.
     *
     * SECURITY (v1.75): IDOR-hardened — caller must either have sharing access
     * to the CV OR the CV must be a managed `docgen_%` file. Otherwise throws.
     * Previously this method was a probe leak (anyone could test for the
     * existence/size of arbitrary CVs by Id).
     */
    @AuraEnabled
    public static Long getContentVersionSize(Id contentVersionId) {
        if (contentVersionId == null) {
            return 0;
        }
        ContentVersion cv = (ContentVersion) fetchAuthorizedContentVersion(contentVersionId, 'Id, ContentSize');
        return (Long) cv.ContentSize;
    }

    /**
     * Deletes a ContentVersion's parent ContentDocument (which removes the CV).
     * Used by the LWC to undo a just-uploaded file when our PDF size guard
     * rejects it — keeps the org clean instead of leaving an orphan CV behind.
     *
     * SECURITY (v1.75): IDOR-hardened — destructive endpoint. Caller must have
     * sharing access to the CV OR it must be a managed `docgen_%` file (e.g. a
     * just-uploaded template body the LWC needs to roll back). Otherwise throws.
     * Previously any logged-in user could delete any CV in the org by Id.
     */
    @AuraEnabled
    public static void deleteContentVersionDocument(Id contentVersionId) {
        if (contentVersionId == null) {
            return;
        }
        ContentVersion cv = (ContentVersion) fetchAuthorizedContentVersion(contentVersionId, 'Id, ContentDocumentId');
        if (cv.ContentDocumentId == null) {
            return;
        }
        Id cdId = (Id) cv.ContentDocumentId;
        /* code-analyzer-suppress ApexFlsViolation */
        Database.delete([SELECT Id FROM ContentDocument WHERE Id = :cdId WITH USER_MODE], true, AccessLevel.USER_MODE);
    }

    /**
     * Returns all version history records for a template, ordered by creation date descending.
     * @param templateId The Portwood template record ID
     * @return List of DocGen_Template_Version__c records
     */
    @AuraEnabled
    public static List<DocGen_Template_Version__c> getTemplateVersions(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{
                'Name',
                'CreatedDate',
                'CreatedById',
                'Query_Config__c',
                'Content_Version_Id__c',
                'Category__c',
                'Description__c',
                'Type__c',
                'Base_Object_API__c',
                'Is_Active__c',
                'Watermark_Image_CV_Id__c',
                'Template__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT
                Id,
                Name,
                CreatedDate,
                CreatedBy.Name,
                Query_Config__c,
                Content_Version_Id__c,
                Category__c,
                Description__c,
                Type__c,
                Base_Object_API__c,
                Is_Active__c,
                Watermark_Image_CV_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Returns the body ContentVersion's version number + filename for each given
     * Content_Version_Id__c, so the Version History view can show which underlying
     * file a version actually points at (diagnostic for "generation read a body I
     * didn't expect"). Keyed by ContentVersion Id → { versionNumber, fileName }.
     *
     * SYSTEM_MODE for the read (with an explicit per-field FLS guard) mirrors
     * getTemplateFileContent: the template-body CV's ContentDocumentLink can default
     * to Visibility=InternalUsers, which a USER_MODE read would strip.
     */
    @AuraEnabled
    public static Map<String, Object> getVersionBodyFileInfo(List<String> contentVersionIds) {
        Map<String, Object> result = new Map<String, Object>();
        if (contentVersionIds == null || contentVersionIds.isEmpty()) {
            return result;
        }
        Set<Id> ids = new Set<Id>();
        for (String s : contentVersionIds) {
            if (String.isBlank(s)) {
                continue;
            }
            try {
                ids.add((Id) s);
            } catch (Exception e) {
                String noop = e.getMessage(); // NOPMD — skip non-Id values defensively
            }
        }
        if (ids.isEmpty() || !Schema.sObjectType.ContentVersion.isAccessible()) {
            return result;
        }
        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionNumber', 'Title', 'PathOnClient' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentVersion cv : [
            SELECT Id, VersionNumber, Title, PathOnClient
            FROM ContentVersion
            WHERE Id IN :ids
            WITH SYSTEM_MODE
        ]) {
            result.put(
                String.valueOf(cv.Id),
                new Map<String, Object>{
                    'versionNumber' => cv.VersionNumber,
                    'fileName' => String.isNotBlank(cv.PathOnClient) ? cv.PathOnClient : cv.Title
                }
            );
        }
        return result;
    }

    /**
     * Issue #83 — Deletes a non-active template version and its associated files.
     * Removes the version record, its body ContentVersion, and all pre-decomposed
     * XML ContentVersions (titles starting with `docgen_tmpl_xml_<versionId>_`).
     * Refuses to delete the active version — caller must activate another version
     * first.
     *
     * Each saved version typically references 5-7 CVs (body docx + pre-decomp
     * parts), so deleting one version frees that many files. Users with 50+
     * versions accumulated over heavy iteration save substantial storage.
     */
    @AuraEnabled
    public static void deleteTemplateVersion(Id versionId) {
        try {
            if (!Schema.sObjectType.DocGen_Template_Version__c.isDeletable()) {
                throw DocGenService.ahe('Insufficient access.');
            }
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Name', 'Is_Active__c', 'Content_Version_Id__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> versions = [
                SELECT Id, Name, Is_Active__c, Content_Version_Id__c
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw DocGenService.ahe('Version not found.');
            }
            DocGen_Template_Version__c v = versions[0];
            if (v.Is_Active__c == true) {
                throw DocGenService.ahe(
                    'Cannot delete the active version. Activate a different version first, then delete this one.'
                );
            }

            deleteContentDocumentsForTemplateVersion(v);

            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(v, true, AccessLevel.USER_MODE);
        } catch (DmlException dmlE) {
            throw DocGenService.ahe(dmlE, 'Error deleting version. ' + dmlE.getDmlMessage(0));
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting version.');
        }
    }

    private static void deleteContentDocumentsForTemplateVersion(DocGen_Template_Version__c version) {
        Set<Id> cdsToDelete = new Set<Id>();
        collectLinkedContentDocuments(new Set<Id>{ version.Id }, cdsToDelete);
        if (String.isNotBlank(version.Content_Version_Id__c)) {
            collectContentDocumentsForContentVersions(new Set<Id>{ (Id) version.Content_Version_Id__c }, cdsToDelete);
        }

        String versionIdText = String.valueOf(version.Id);
        String snapshotTitle = 'docgen_tmpl_pdf_' + versionIdText + '_acroform';
        String chunkPrefix = 'docgen_pdf_body_chunk_' + versionIdText + '_';
        String chunkLike = chunkPrefix + '%';
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentVersion cv : [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Title = :snapshotTitle OR Title LIKE :chunkLike
            WITH SYSTEM_MODE
        ]) {
            if (cv.ContentDocumentId != null) {
                cdsToDelete.add(cv.ContentDocumentId);
            }
        }
        deleteContentDocuments(cdsToDelete);
    }

    private static Set<Id> collectLinkedTemplateContentDocumentIds(Set<Id> linkedEntityIds) {
        Set<Id> cdsToDelete = new Set<Id>();
        collectLinkedContentDocuments(linkedEntityIds, cdsToDelete);
        return cdsToDelete;
    }

    private static void collectLinkedContentDocuments(Set<Id> linkedEntityIds, Set<Id> cdsToDelete) {
        if (linkedEntityIds == null || linkedEntityIds.isEmpty()) {
            return;
        }
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :linkedEntityIds
            WITH SYSTEM_MODE
        ]) {
            if (link.ContentDocumentId != null) {
                cdsToDelete.add(link.ContentDocumentId);
            }
        }
    }

    private static void collectContentDocumentsForContentVersions(Set<Id> contentVersionIds, Set<Id> cdsToDelete) {
        if (contentVersionIds == null || contentVersionIds.isEmpty()) {
            return;
        }
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentVersion cv : [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :contentVersionIds
            WITH SYSTEM_MODE
        ]) {
            if (cv.ContentDocumentId != null) {
                cdsToDelete.add(cv.ContentDocumentId);
            }
        }
    }

    private static void deleteContentDocuments(Set<Id> contentDocumentIds) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return;
        }
        /* code-analyzer-suppress ApexFlsViolation */
        Database.delete(
            [SELECT Id FROM ContentDocument WHERE Id IN :contentDocumentIds WITH SYSTEM_MODE],
            false,
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * Activates a specific template version and deactivates all others for the same template.
     * @param versionId The DocGen_Template_Version__c record ID to activate
     */
    @AuraEnabled
    public static void activateVersion(Id versionId) {
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{
                    'Template__c',
                    'Query_Config__c',
                    'Content_Version_Id__c',
                    'Category__c',
                    'Description__c',
                    'Type__c',
                    'Base_Object_API__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> actVerList = [
                SELECT
                    Template__c,
                    Query_Config__c,
                    Content_Version_Id__c,
                    Category__c,
                    Description__c,
                    Type__c,
                    Base_Object_API__c
                FROM DocGen_Template_Version__c
                WHERE Id = :versionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            DocGen_Template_Version__c version = actVerList[0];

            // 1. Deactivate others
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> others = [
                SELECT Id
                FROM DocGen_Template_Version__c
                WHERE Template__c = :version.Template__c AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
            ];
            for (DocGen_Template_Version__c v : others) {
                v.Is_Active__c = false;
            }
            if (!others.isEmpty()) {
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
                DocGenFlsGuard.assertUpdateable(others, new Set<String>{ 'Is_Active__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                Database.update(others, AccessLevel.SYSTEM_MODE);
            }

            // 2. Activate this one
            version.Is_Active__c = true;
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.assertUpdateable(version, new Set<String>{ 'Is_Active__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(version, AccessLevel.SYSTEM_MODE);

            // 3. Update Template Record Headline
            DocGen_Template__c template = new DocGen_Template__c(Id = version.Template__c);
            template.Query_Config__c = version.Query_Config__c;
            template.Category__c = version.Category__c;
            template.Description__c = version.Description__c;
            // Only when the version actually states one. Type__c on the version used to
            // default to Word, so a version created without it — by a script, a data
            // load, or any integration — retyped its template to Word on activation and
            // changed how the template generates. The picklist default is gone as of
            // v3.55; this is the other half, and it also protects templates whose
            // versions were created under the old default and left blank since.
            if (String.isNotBlank(version.Type__c)) {
                template.Type__c = version.Type__c;
            }
            template.Base_Object_API__c = version.Base_Object_API__c;

            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Update").
            DocGenFlsGuard.assertUpdateable(
                template,
                new Set<String>{ 'Query_Config__c', 'Category__c', 'Description__c', 'Type__c', 'Base_Object_API__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(template, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw new DocGenException('Error activating version: ' + e.getMessage());
        }
    }

    /**
     * Unified PDF generation. Uses the same code path as bulk batch generation.
     * For "save" mode: saves PDF to record via DocGenService.generateDocument().
     * For "download" mode: returns base64 PDF via DocGenService.generatePdfBlob().
     * @param templateId The Portwood template record ID
     * @param recordId The source record ID
     * @param saveToRecord Whether to save the PDF as a file on the record
     * @return Map containing base64 PDF data and title, or saved content document ID
     */
    /**
     * Returns the total size (bytes) of image attachments linked to the record.
     * Used as a pre-flight check before Save-to-Record so the LWC can warn the
     * user if they're about to exceed the ~30MB ceiling, rather than failing
     * silently inside the Queueable.
     *
     * Filters to PNG/JPG/GIF/BMP/TIFF/SVG so non-image attachments don't inflate the count.
     */
    @AuraEnabled(cacheable=true)
    public static Long scoutAttachedImageSize(Id recordId) {
        if (recordId == null)
            return 0L;
        try {
            List<AggregateResult> results = [
                SELECT SUM(ContentDocument.ContentSize) totalSize
                FROM ContentDocumentLink
                WHERE
                    LinkedEntityId = :recordId
                    AND ContentDocument.FileExtension IN ('png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg')
                WITH USER_MODE
            ];
            if (results.isEmpty())
                return 0L;
            Object sz = results[0].get('totalSize');
            if (sz == null)
                return 0L;
            return Long.valueOf(String.valueOf(sz));
        } catch (Exception e) {
            // Never let the scout fail the generation flow — just return 0 and let
            // the user proceed; the Queueable will handle whatever it encounters.
            return 0L;
        }
    }

    /**
     * Async counterpart to generatePdf(saveToRecord=true). Enqueues a Queueable that
     * runs the full render + ContentVersion insert + ContentDocumentLink server-side,
     * so the LWC's Aura request returns immediately. This avoids Salesforce's
     * ~30s CSRF timeout on long-held Aura requests when saving image-heavy PDFs.
     *
     * Returns the enqueued AsyncApexJob Id. File appears on the record when the
     * job completes (typically under a minute even for large PDFs).
     */
    @AuraEnabled
    public static Id generatePdfAsync(Id templateId, Id recordId) {
        try {
            return System.enqueueJob(new DocGenPdfSaveQueueable(templateId, recordId));
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error queueing PDF generation.');
        }
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getPdfSampleGenerationStatus(Id jobId, Id recordId, Datetime requestedAt) {
        if (jobId == null || recordId == null) {
            throw DocGenService.ahe('PDF generation job and sample record are required.');
        }
        Map<String, Object> result = new Map<String, Object>();

        /* code-analyzer-suppress ApexFlsViolation */
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, NumberOfErrors, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :jobId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (jobs.isEmpty()) {
            throw DocGenService.ahe('PDF generation job was not found.');
        }

        AsyncApexJob job = jobs[0];
        result.put('jobStatus', job.Status);
        result.put('numberOfErrors', job.NumberOfErrors);
        result.put('extendedStatus', job.ExtendedStatus);

        if (job.Status == 'Completed' && job.NumberOfErrors == 0) {
            Datetime floor = requestedAt == null ? Datetime.now().addMinutes(-10) : requestedAt.addSeconds(-5);
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> generated = [
                SELECT Id, Title, CreatedDate
                FROM ContentVersion
                WHERE FirstPublishLocationId = :recordId AND FileExtension = 'pdf' AND CreatedDate >= :floor
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!generated.isEmpty()) {
                result.put('contentVersionId', generated[0].Id);
                result.put('title', generated[0].Title);
                result.put('createdDate', generated[0].CreatedDate);
            }
        }

        return result;
    }

    @AuraEnabled
    public static Map<String, Object> generatePdf(
        Id templateId,
        Id recordId,
        Boolean saveToRecord,
        Map<String, String> chartCvMap,
        Map<String, String> chartBucketMap
    ) {
        // chartCvMap (#117): signature → CV Id map for charts the LWC pre-
        // rasterized to PNG. Null for non-chart templates and legacy callers
        // that haven't been updated.
        // chartBucketMap: pre-aggregated {#ChartBucket:...} rows, same sweep.
        DocGenService.beginChartContext(chartCvMap, chartBucketMap);
        try {
            if (saveToRecord) {
                Id contentDocId = DocGenService.generateDocument(templateId, recordId);
                return new Map<String, Object>{ 'saved' => true, 'contentDocumentId' => contentDocId };
            } else {
                Map<String, Object> result = DocGenService.generatePdfBlob(templateId, recordId);
                Blob pdfBlob = (Blob) result.get('blob');
                String docTitle = (String) result.get('title');
                return new Map<String, Object>{ 'base64' => EncodingUtil.base64Encode(pdfBlob), 'title' => docTitle };
            }
        } catch (HeapPressureException hp) {
            return heapPressureSignal(hp.relationshipName);
        } catch (Exception e) {
            if (isHeapError(e)) {
                return heapPressureSignal(null);
            }
            throw DocGenService.ahe(e, 'Error generating PDF document. Please check the template configuration.');
        } finally {
            DocGenService.endChartContext();
        }
    }

    /**
     * Draft PDF preview as base64 — no ContentVersion persisted. The LWC opens
     * a new tab on a blob: URL (top-level navigation, which LWS allows; only
     * blob: IFRAMES are blocked). PDFs too large for the Aura payload ceiling
     * signal tooLarge and the caller falls back to previewDraftPdf's
     * ContentVersion + native file-preview path.
     */
    @AuraEnabled
    public static Map<String, Object> previewDraftPdfData(
        Id templateId,
        Id recordId,
        String draftHtml,
        String draftHeaderHtml,
        String draftFooterHtml
    ) {
        if (String.isBlank(draftHtml)) {
            throw DocGenService.ahe('Nothing to preview — the editor is empty.');
        }
        try {
            DocGenService.draftHtmlBodyOverride = draftHtml;
            // The running header/footer are edited live in the canvas now, so the
            // preview has to render THOSE, not whatever was last saved.
            DocGenService.draftHeaderHtmlOverride = draftHeaderHtml;
            DocGenService.draftFooterHtmlOverride = draftFooterHtml;
            Map<String, Object> result = DocGenService.generatePdfBlob(templateId, recordId);
            Blob pdfBlob = (Blob) result.get('blob');
            // ~6MB AuraEnabled response ceiling; base64 inflates 4/3.
            if (pdfBlob.size() > 4000000) {
                return new Map<String, Object>{ 'tooLarge' => true };
            }
            return new Map<String, Object>{
                'base64' => EncodingUtil.base64Encode(pdfBlob),
                'title' => (String) result.get('title')
            };
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw DocGenService.ahe('Preview failed: ' + e.getMessage());
        } finally {
            DocGenService.draftHtmlBodyOverride = null;
            DocGenService.draftHeaderHtmlOverride = null;
            DocGenService.draftFooterHtmlOverride = null;
        }
    }

    /**
     * Designer live PDF preview: renders the caller's DRAFT HTML (unsaved
     * editor contents) through the full merge + Blob.toPdf pipeline against a
     * real record, without touching the template's saved versions. Persists a
     * ContentVersion for Salesforce's native file-preview overlay — the
     * fallback when previewDraftPdfData can't be used (popup blocked, PDF too
     * large for the Aura payload).
     */
    @AuraEnabled
    public static Map<String, Object> previewDraftPdf(
        Id templateId,
        Id recordId,
        String draftHtml,
        String draftHeaderHtml,
        String draftFooterHtml
    ) {
        if (String.isBlank(draftHtml)) {
            throw DocGenService.ahe('Nothing to preview — the editor is empty.');
        }
        try {
            DocGenService.draftHtmlBodyOverride = draftHtml;
            DocGenService.draftHeaderHtmlOverride = draftHeaderHtml;
            DocGenService.draftFooterHtmlOverride = draftFooterHtml;
            Map<String, Object> result = DocGenService.generatePdfBlob(templateId, recordId);
            Blob pdfBlob = (Blob) result.get('blob');
            // Persist as a ContentVersion so the LWC can open Salesforce's
            // native file-preview overlay (LWS forbids blob: iframes). One
            // preview file per template — prior previews are deleted first.
            String previewTitle = 'dg_pdf_preview_' + templateId;
            List<ContentVersion> old = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Title = :previewTitle AND IsLatest = TRUE
                WITH SYSTEM_MODE
                LIMIT 10
            ]; // NOPMD ApexCRUDViolation — internal preview artifacts, owner-scoped cleanup
            if (!old.isEmpty()) {
                Set<Id> docIds = new Set<Id>();
                for (ContentVersion c : old) {
                    docIds.add(c.ContentDocumentId);
                }
                delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds]; // NOPMD ApexCRUDViolation
            }
            ContentVersion cv = new ContentVersion(
                Title = previewTitle,
                PathOnClient = 'preview.pdf',
                VersionData = pdfBlob,
                FirstPublishLocationId = templateId
            );
            DocGenFlsGuard.assertCreateable(cv, new Set<String>{ 'Title', 'PathOnClient', 'VersionData' });
            insert cv; // NOPMD ApexCRUDViolation — guarded above
            cv = [
                SELECT Id, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :cv.Id
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation — reading back the row just inserted
            return new Map<String, Object>{
                'contentVersionId' => cv.Id,
                'contentDocumentId' => cv.ContentDocumentId,
                'title' => (String) result.get('title')
            };
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'PDF preview failed. Check the template HTML and sample record.');
        } finally {
            DocGenService.draftHtmlBodyOverride = null;
            DocGenService.draftHeaderHtmlOverride = null;
            DocGenService.draftFooterHtmlOverride = null;
        }
    }

    /** Heap-pressure signal helper — uniform shape for runner LWC auto-fallback. */
    private static Map<String, Object> heapPressureSignal(String relationshipName) {
        return new Map<String, Object>{ 'heapPressure' => true, 'giantRelationship' => relationshipName };
    }

    /**
     * Detects whether an exception came from hitting the Apex heap governor.
     * Blob.toPdf() internally throws System.LimitException with a heap-related
     * message when the PDF renderer can't fit the DOM in heap — that's different
     * from our own HeapPressureException, but we want to retry identically.
     */
    private static Boolean isHeapError(Exception e) {
        String msg = e.getMessage();
        if (String.isBlank(msg)) {
            return false;
        }
        String lower = msg.toLowerCase();
        return lower.contains('heap size') ||
            lower.contains('heap limit') ||
            (e instanceof System.LimitException && lower.contains('heap'));
    }

    // --- Schema Methods for Query Builder ---

    /**
     * Sortable label/value pair used by schema methods for picklist-style options.
     */
    public class Option implements Comparable {
        public String label;
        public String value;
        public String childObjectApiName;
        public String lookupField;

        public Option(String label, String value) {
            this.label = label;
            this.value = value;
        }

        public Option(String label, String value, String childObjectApiName) {
            this.label = label;
            this.value = value;
            this.childObjectApiName = childObjectApiName;
        }

        public Option(String label, String value, String childObjectApiName, String lookupField) {
            this.label = label;
            this.value = value;
            this.childObjectApiName = childObjectApiName;
            this.lookupField = lookupField;
        }

        /**
         * Compares this Option to another for alphabetical sorting by label.
         * @param compareTo The other Option to compare against
         * @return Negative, zero, or positive integer for sort ordering
         */
        public Integer compareTo(Object compareTo) {
            Option other = (Option) compareTo;
            if (label == other.label) {
                return 0;
            }
            if (label > other.label) {
                return 1;
            }
            return -1;
        }
    }

    /**
     * Returns all queryable SObject types as label/value pairs for the query builder.
     * @return List of maps with 'label' and 'value' keys, sorted alphabetically
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectOptions() {
        List<Option> sortedOptions = new List<Option>();
        for (Schema.SObjectType sobj : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = sobj.getDescribe();
            if (describe.isQueryable() && !describe.isDeprecatedAndHidden()) {
                sortedOptions.add(
                    new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName())
                );
            }
        }
        sortedOptions.sort();

        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Option opt : sortedOptions) {
            options.add(new Map<String, String>{ 'label' => opt.label, 'value' => opt.value });
        }
        return options;
    }

    /**
     * Searches for Apex classes that implement DocGenDataProvider.
     * @param searchTerm Optional search term to filter class names
     * @return List of class names that implement the interface
     */
    @AuraEnabled(cacheable=true)
    public static List<String> searchDataProviders(String searchTerm) {
        List<String> providers = new List<String>();
        // Match the runtime resolution in DocGenDataRetriever.getRecordDataV4:
        // unqualified classes (subscriber-org case) AND portwoodglobal-namespaced
        // classes (dev-org / namespaced-scratch case, also future packaged samples).
        // See issue #63.
        String query = 'SELECT Name FROM ApexClass WHERE NamespacePrefix IN (null, \'portwoodglobal\')';
        if (String.isNotBlank(searchTerm)) {
            query += ' AND Name LIKE \'%' + String.escapeSingleQuotes(searchTerm) + '%\'';
        }
        query += ' ORDER BY Name LIMIT 50';

        for (ApexClass cls : Database.query(query, AccessLevel.USER_MODE)) {
            // Try to instantiate and check interface
            Type t = Type.forName(cls.Name);
            if (t != null) {
                try {
                    Object instance = t.newInstance();
                    if (instance instanceof DocGenDataProvider) {
                        providers.add(cls.Name);
                    }
                } catch (Exception e) {
                    // Intentionally swallowed — non-instantiable class, skip
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            }
        }
        return providers;
    }

    /**
     * Validates an Apex class implements DocGenDataProvider and returns its field names.
     * @param className The Apex class name to validate
     * @return Map with 'valid' (Boolean), 'fields' (List<String>), and 'error' (String)
     */
    @AuraEnabled
    public static Map<String, Object> validateDataProvider(String className) {
        Map<String, Object> result = new Map<String, Object>();
        if (String.isBlank(className)) {
            result.put('valid', false);
            result.put('error', 'Class name is required.');
            return result;
        }

        Type providerType = Type.forName(className);
        if (providerType == null) {
            providerType = Type.forName('portwoodglobal', className);
        }
        if (providerType == null) {
            result.put('valid', false);
            result.put('error', 'Class "' + className + '" not found.');
            return result;
        }

        try {
            Object instance = providerType.newInstance();
            if (!(instance instanceof DocGenDataProvider)) {
                result.put('valid', false);
                result.put('error', 'Class "' + className + '" does not implement DocGenDataProvider.');
                return result;
            }

            DocGenDataProvider provider = (DocGenDataProvider) instance;
            List<String> fields = provider.getFieldNames();
            result.put('valid', true);
            result.put('fields', fields != null ? fields : new List<String>());
        } catch (Exception e) {
            result.put('valid', false);
            result.put('error', 'Error instantiating "' + className + '": ' + e.getMessage());
        }
        return result;
    }

    /**
     * Returns accessible fields for a given SObject type with label, API name, and type.
     * @param objectName The SObject API name
     * @return List of maps with 'label', 'value', and 'type' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectFields(String objectName) {
        List<Option> sortedFields = new List<Option>();
        Map<String, String> fieldTypes = new Map<String, String>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return new List<Map<String, String>>();
        }

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isAccessible()) {
                sortedFields.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
                fieldTypes.put(describe.getName(), describe.getType().name());
            }
        }
        sortedFields.sort();

        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Option opt : sortedFields) {
            fields.add(
                new Map<String, String>{
                    'label' => opt.label,
                    'value' => opt.value,
                    'type' => fieldTypes.get(opt.value)
                }
            );
        }
        return fields;
    }

    /**
     * Returns updateable fields for a given SObject type with label, API name, and type.
     * The isUpdateable() variant of getObjectFields — used by the signer form-field
     * admin UI so writeback-target dropdowns only offer fields the admin can write.
     * @param objectName The SObject API name
     * @return List of maps with 'label', 'value', and 'type' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getUpdateableObjectFields(String objectName) {
        List<Option> sortedFields = new List<Option>();
        Map<String, String> fieldTypes = new Map<String, String>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return new List<Map<String, String>>();
        }

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isUpdateable()) {
                sortedFields.add(new Option(describe.getLabel() + ' (' + describe.getName() + ')', describe.getName()));
                fieldTypes.put(describe.getName(), describe.getType().name());
            }
        }
        sortedFields.sort();

        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Option opt : sortedFields) {
            fields.add(
                new Map<String, String>{
                    'label' => opt.label,
                    'value' => opt.value,
                    'type' => fieldTypes.get(opt.value)
                }
            );
        }
        return fields;
    }

    /**
     * Returns child relationships for a given SObject type with relationship name and child object info.
     * @param objectName The parent SObject API name
     * @return List of maps with 'label', 'value', 'childObjectApiName', and 'lookupField' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getChildRelationships(String objectName) {
        List<Option> sortedRels = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return new List<Map<String, String>>();
        }

        for (Schema.ChildRelationship child : objType.getDescribe().getChildRelationships()) {
            if (child.getRelationshipName() != null) {
                sortedRels.add(
                    new Option(
                        child.getRelationshipName() + ' (' + child.getChildSObject().getDescribe().getLabel() + ')',
                        child.getRelationshipName(),
                        child.getChildSObject().getDescribe().getName(),
                        child.getField().getDescribe().getName()
                    )
                );
            }
        }
        sortedRels.sort();

        List<Map<String, String>> relationships = new List<Map<String, String>>();
        for (Option opt : sortedRels) {
            relationships.add(
                new Map<String, String>{
                    'label' => opt.label,
                    'value' => opt.value,
                    'childObjectApiName' => opt.childObjectApiName,
                    'lookupField' => opt.lookupField
                }
            );
        }
        return relationships;
    }

    /**
     * Returns parent (lookup) relationships for a given SObject type.
     * @param objectName The SObject API name
     * @return List of maps with 'label', 'value', and 'targetObject' keys
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getParentRelationships(String objectName) {
        List<Option> sortedParents = new List<Option>();
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return new List<Map<String, String>>();
        }

        for (Schema.SObjectField field : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.getType() != Schema.DisplayType.REFERENCE) {
                continue;
            }
            if (describe.getReferenceTo().isEmpty()) {
                continue;
            }
            String relationshipName = describe.getRelationshipName();
            if (relationshipName == null) {
                continue;
            }
            String targetObject = describe.getReferenceTo()[0].getDescribe().getName();
            sortedParents.add(
                new Option(describe.getLabel() + ' (' + relationshipName + ')', relationshipName, targetObject)
            );
        }
        sortedParents.sort();

        List<Map<String, String>> parents = new List<Map<String, String>>();
        for (Option opt : sortedParents) {
            parents.add(
                new Map<String, String>{
                    'label' => opt.label,
                    'value' => opt.value,
                    'targetObject' => opt.childObjectApiName // Reusing field
                }
            );
        }
        return parents;
    }

    // Sample data creation method removed per cleanup request.

    /**
     * Allowlist validation: extracts field-name tokens from a WHERE clause and validates
     * each against the provided Schema field map. Tokens that look like values (quoted strings,
     * numbers, dates, booleans, null, bind variables) are skipped. Only identifiers that appear
     * in field-name position (before operators) are checked.
     *
     * This is best-effort parsing — the definitive security gate is USER_MODE execution.
     * The purpose is to satisfy Checkmarx static analysis requiring Schema allowlist checks.
     */
    private static void validateWhereClauseFields(String whereClause, Map<String, Schema.SObjectField> fieldMap) {
        // Strip quoted string literals so they don't confuse the tokenizer
        String stripped = whereClause.replaceAll('\'[^\']*\'', '\'\'');
        // Tokenize on whitespace and parentheses
        List<String> tokens = stripped.split('[\\s(),]+');
        // SOQL operators and keywords to skip
        Set<String> skipTokens = new Set<String>{
            '=',
            '!=',
            '<',
            '>',
            '<=',
            '>=',
            'LIKE',
            'IN',
            'NOT',
            'AND',
            'OR',
            'NULL',
            'TRUE',
            'FALSE',
            'INCLUDES',
            'EXCLUDES',
            'LAST_N_DAYS',
            'NEXT_N_DAYS',
            'TODAY',
            'YESTERDAY',
            'TOMORROW',
            'LAST_WEEK',
            'THIS_WEEK',
            'NEXT_WEEK',
            'LAST_MONTH',
            'THIS_MONTH',
            'NEXT_MONTH',
            'LAST_QUARTER',
            'THIS_QUARTER',
            'NEXT_QUARTER',
            'LAST_YEAR',
            'THIS_YEAR',
            'NEXT_YEAR',
            'LAST_90_DAYS',
            'NEXT_90_DAYS',
            'LAST_N_MONTHS',
            'NEXT_N_MONTHS',
            'LAST_N_QUARTERS',
            'NEXT_N_QUARTERS',
            'LAST_N_YEARS',
            'NEXT_N_YEARS',
            ''
        };
        for (String token : tokens) {
            String t = token.trim();
            if (String.isBlank(t)) {
                continue;
            }
            String upper = t.toUpperCase();
            // Skip SOQL keywords, operators, quoted literals, numbers, date literals, bind vars
            if (skipTokens.contains(upper)) {
                continue;
            }
            if (t.startsWith('\'') || t.startsWith(':')) {
                continue;
            }
            if (t.isNumeric() || Pattern.matches('[0-9]{4}-[0-9]{2}-[0-9]{2}.*', upper)) {
                continue;
            }
            if (Pattern.matches('LAST_N_.*:\\d+', upper) || Pattern.matches('NEXT_N_.*:\\d+', upper)) {
                continue;
            }
            // This looks like a field name — validate against Schema
            String baseField = t.contains('.') ? t.split('\\.')[0].toLowerCase() : t.toLowerCase();
            if (!fieldMap.containsKey(baseField)) {
                // Try __r → __c for custom relationship traversals
                String asLookup = baseField.endsWith('__r')
                    ? baseField.substring(0, baseField.length() - 3) + '__c'
                    : baseField;
                if (!fieldMap.containsKey(asLookup)) {
                    throw new DocGenException('Invalid field in WHERE clause: ' + t);
                }
            }
        }
    }

    /**
     * Builds a Giant Query child node config from a V1 flat query string.
     * Parses the subquery for the given relationship name and resolves
     * the child object + lookup field from the parent record's schema.
     */
    private static Map<String, Object> buildNodeConfigFromFlat(
        Id recordId,
        String queryConfig,
        String relationshipName
    ) {
        // Resolve child object and lookup field from schema
        String parentObjectType = String.valueOf(recordId.getSobjectType());
        Schema.DescribeSObjectResult parentDescribe = Schema.getGlobalDescribe().get(parentObjectType)?.getDescribe();
        if (parentDescribe == null) {
            return null;
        }

        String childObjectName = null;
        String lookupField = null;
        for (Schema.ChildRelationship cr : parentDescribe.getChildRelationships()) {
            if (cr.getRelationshipName() != null && cr.getRelationshipName().equalsIgnoreCase(relationshipName)) {
                childObjectName = String.valueOf(cr.getChildSObject());
                lookupField = String.valueOf(cr.getField());
                break;
            }
        }
        if (childObjectName == null) {
            return null;
        }

        // Parse the subquery to extract fields, parent fields, and clauses
        List<String> childFields = new List<String>();
        List<String> parentFields = new List<String>();
        String orderBy = null;
        String whereClause = null;
        String limitVal = null;

        // Find the subquery in the config string
        Pattern subqPattern = Pattern.compile(
            '(?i)\\(\\s*SELECT\\s+(.+?)\\s+FROM\\s+' + Pattern.quote(relationshipName) + '([^)]*)\\)'
        );
        Matcher m = subqPattern.matcher(queryConfig);
        if (m.find()) {
            String fieldsPart = m.group(1);
            String clausesPart = m.group(2) != null ? m.group(2).trim() : '';

            // Parse fields
            for (String f : fieldsPart.split(',')) {
                String trimmed = f.trim();
                if (String.isBlank(trimmed)) {
                    continue;
                }
                if (trimmed.contains('.')) {
                    parentFields.add(trimmed);
                } else {
                    childFields.add(trimmed);
                }
            }

            // Extract WHERE (before ORDER BY / LIMIT)
            Pattern wherePattern = Pattern.compile('(?i)\\s*WHERE\\s+(.+?)(?:\\s+ORDER\\s+BY|\\s+LIMIT|$)');
            Matcher whereMatcher = wherePattern.matcher(clausesPart);
            if (whereMatcher.find()) {
                whereClause = whereMatcher.group(1).trim();
            }

            // Extract ORDER BY
            Pattern orderPattern = Pattern.compile('(?i)ORDER\\s+BY\\s+(.+?)(?:\\s+LIMIT|$)');
            Matcher orderMatcher = orderPattern.matcher(clausesPart);
            if (orderMatcher.find()) {
                orderBy = orderMatcher.group(1).trim();
            }

            // Extract LIMIT
            Pattern limitPattern = Pattern.compile('(?i)LIMIT\\s+(\\d+)');
            Matcher limitMatcher = limitPattern.matcher(clausesPart);
            if (limitMatcher.find()) {
                limitVal = limitMatcher.group(1).trim();
            }
        }

        Map<String, Object> nodeConfig = new Map<String, Object>{
            'relationshipName' => relationshipName,
            'object' => childObjectName,
            'lookupField' => lookupField,
            'fields' => childFields,
            'parentFields' => parentFields
        };
        if (String.isNotBlank(whereClause)) {
            nodeConfig.put('where', whereClause);
        }
        if (String.isNotBlank(limitVal)) {
            nodeConfig.put('limit', limitVal);
        }
        if (String.isNotBlank(orderBy)) {
            nodeConfig.put('orderBy', orderBy);
        }
        return nodeConfig;
    }

    // --- Deprecated Sharing Methods (stubs kept for managed package compatibility) ---

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTemplateShares(Id templateId) {
        return new List<Map<String, String>>();
    }

    @AuraEnabled
    public static void shareTemplate(Id templateId, Id userOrGroupId, String accessLevel) {
    }

    @AuraEnabled
    public static void removeShare(Id shareId) {
    }

    @AuraEnabled
    public static List<Map<String, String>> searchUsersAndGroups(String searchTerm) {
        return new List<Map<String, String>>();
    }

    // --- Rich Text Image Resolution ---

    /**
     * Recursively walks record data and normalizes Salesforce image URLs in rich text
     * fields to absolute URLs. No HTTP callouts — Blob.toPdf() resolves Salesforce URLs
     * natively via the VF rendering engine. For DOCX, processRichTextImage fetches blobs
     * using the URL. No session IDs needed (AppExchange safe).
     * @param data The record data object (Map or List) to walk and normalize
     */
    public static void resolveRichTextImages(Object data) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;

            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (
                        strVal.containsIgnoreCase('<img') &&
                        (strVal.containsIgnoreCase('refid=') ||
                        strVal.containsIgnoreCase('/servlet/') ||
                        strVal.containsIgnoreCase('/sfc/'))
                    ) {
                        mapData.put(key, normalizeImageUrls(strVal));
                    }
                } else {
                    resolveRichTextImages(val);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                resolveRichTextImages(item);
            }
        }
    }

    /**
     * Normalizes relative Salesforce image URLs to absolute URLs.
     * No HTTP callouts, no session IDs. Blob.toPdf() resolves these natively.
     */
    @TestVisible
    private static String normalizeImageUrls(String html) {
        try {
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/servlet/)', '$1' + baseUrl + '$2');
            html = html.replaceAll('(?i)(src\\s*=\\s*["\'])(/sfc/)', '$1' + baseUrl + '$2');
            return html;
        } catch (Exception e) {
            // Intentionally swallowed: URL normalization failed (e.g., org domain unavailable in test context) — return original HTML unchanged
            return html;
        }
    }

    // =========================================================================
    // Report Import — extract columns and filters from existing Salesforce Reports
    // =========================================================================

    /**
     * Returns PDF files attached to a record (for PDF merger).
     * Each entry has a label (file title) and value (ContentVersion ID).
     * @param recordId The record ID to find attached PDFs for
     * @return List of maps with 'label' (title) and 'value' (ContentVersion ID) keys
     */
    @AuraEnabled
    public static List<Map<String, String>> getRecordPdfs(Id recordId) {
        List<ContentDocumentLink> links = [
            SELECT
                ContentDocumentId,
                ContentDocument.LatestPublishedVersionId,
                ContentDocument.Title,
                ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId AND ContentDocument.FileExtension = 'pdf'
            WITH USER_MODE
            ORDER BY ContentDocument.Title
        ];

        List<Map<String, String>> result = new List<Map<String, String>>();
        for (ContentDocumentLink link : links) {
            result.add(
                new Map<String, String>{
                    'label' => link.ContentDocument.Title + '.pdf',
                    'value' => link.ContentDocument.LatestPublishedVersionId
                }
            );
        }
        return result;
    }

    /**
     * Returns PDFs attached to child records of a parent record.
     * Groups results by child record: [{childRecordId, childRecordName, pdfs: [{label, value}]}]
     * @param parentRecordId The parent record ID
     * @param childObject The child SObject API name
     * @param lookupField The lookup field on the child object pointing to the parent
     * @param filterClause Optional additional WHERE clause to filter child records
     * @return List of grouped results with child record info and their attached PDFs
     */
    @AuraEnabled
    public static List<Map<String, Object>> getChildRecordPdfs(
        Id parentRecordId,
        String childObject,
        String lookupField,
        String filterClause
    ) {
        if (parentRecordId == null || String.isBlank(childObject) || String.isBlank(lookupField)) {
            throw DocGenService.ahe('Parent record ID, child object, and lookup field are required.');
        }

        // Allowlist validation: object verified against Schema.getGlobalDescribe()
        SObjectType childType = Schema.getGlobalDescribe().get(childObject);
        if (childType == null) {
            throw DocGenService.ahe('Invalid child object: ' + childObject);
        }

        // Allowlist validation: lookupField verified against Schema.describeSObjects() field map
        Map<String, SObjectField> fieldMap = childType.getDescribe().fields.getMap();
        if (!fieldMap.containsKey(lookupField.toLowerCase())) {
            throw DocGenService.ahe('Invalid lookup field: ' + lookupField);
        }

        // Allowlist validation: displayField derived from Schema field map (Name or Id) — always safe
        Boolean hasName = fieldMap.containsKey('name') && fieldMap.get('name').getDescribe().isAccessible();
        String displayField = hasName ? 'Name' : 'Id';

        // Query child records
        String childQuery =
            'SELECT Id, ' +
            (hasName ? 'Name, ' : '') +
            String.escapeSingleQuotes(lookupField) +
            ' FROM ' +
            String.escapeSingleQuotes(childObject) +
            ' WHERE ' +
            String.escapeSingleQuotes(lookupField) +
            ' = :parentRecordId';
        if (String.isNotBlank(filterClause)) {
            String sanitizedFilter = DocGenBulkController.sanitizeCondition(filterClause);
            // Allowlist validation: WHERE clause field names verified against Schema.describeSObjects() field map
            validateWhereClauseFields(sanitizedFilter, fieldMap);
            childQuery += ' AND (' + sanitizedFilter + ')';
        }
        childQuery += ' ORDER BY ' + displayField + ' LIMIT 200';

        List<SObject> childRecords;
        try {
            // CxSAST: SOQL injection mitigated by Schema allowlist validation on all dynamic elements (object, lookupField, displayField, filterClause fields) + USER_MODE
            childRecords = Database.query(childQuery, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — all dynamic elements allowlist-validated against Schema.describeSObjects() field map; USER_MODE enforced
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error querying child records');
        }

        if (childRecords.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        // Collect child record IDs
        Set<Id> childIds = new Set<Id>();
        Map<Id, String> childNameMap = new Map<Id, String>();
        for (SObject rec : childRecords) {
            childIds.add(rec.Id);
            childNameMap.put(rec.Id, hasName ? (String) rec.get('Name') : String.valueOf(rec.Id));
        }

        // Query PDFs attached to all child records in one query
        List<ContentDocumentLink> links = [
            SELECT
                ContentDocumentId,
                ContentDocument.LatestPublishedVersionId,
                ContentDocument.Title,
                ContentDocument.FileExtension,
                LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :childIds AND ContentDocument.FileExtension = 'pdf'
            WITH USER_MODE
            ORDER BY ContentDocument.Title
        ];

        // Group by child record
        Map<Id, List<Map<String, String>>> pdfsByChild = new Map<Id, List<Map<String, String>>>();
        for (ContentDocumentLink link : links) {
            Id childId = link.LinkedEntityId;
            if (!pdfsByChild.containsKey(childId)) {
                pdfsByChild.put(childId, new List<Map<String, String>>());
            }
            pdfsByChild.get(childId)
                .add(
                    new Map<String, String>{
                        'label' => link.ContentDocument.Title + '.pdf',
                        'value' => link.ContentDocument.LatestPublishedVersionId
                    }
                );
        }

        // Build grouped result — include all child records (even those without PDFs)
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (SObject rec : childRecords) {
            List<Map<String, String>> pdfs = pdfsByChild.containsKey(rec.Id)
                ? pdfsByChild.get(rec.Id)
                : new List<Map<String, String>>();
            result.add(
                new Map<String, Object>{
                    'childRecordId' => rec.Id,
                    'childRecordName' => childNameMap.get(rec.Id),
                    'pdfs' => pdfs
                }
            );
        }
        return result;
    }

    /**
     * Returns available reports the user can access.
     * Searches by name if a search term is provided.
     * @param searchTerm Optional search string to filter reports by name
     * @return List of maps with 'id', 'name', and 'folder' keys
     */
    @AuraEnabled
    public static List<Map<String, String>> getAvailableReports(String searchTerm) {
        String query = 'SELECT Id, Name, DeveloperName, FolderName FROM Report';
        String safeTerm; // Used via bind variable in dynamic SOQL below
        if (String.isNotBlank(searchTerm)) {
            safeTerm = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
            query += ' WHERE Name LIKE :safeTerm';
        }
        query += ' ORDER BY Name LIMIT 50';

        List<Map<String, String>> results = new List<Map<String, String>>();
        for (Report r : Database.query(query, AccessLevel.USER_MODE)) {
            results.add(new Map<String, String>{ 'id' => r.Id, 'name' => r.Name, 'folder' => r.FolderName });
        }
        return results;
    }

    /**
     * Imports a report's columns and filters as a Portwood query config.
     * Uses the Reports API to describe the report, then normalizes
     * column names to SOQL field API names.
     * @param reportId The Salesforce Report ID to import configuration from
     * @return Map containing baseObject, fields, parentFields, childFields, filters, and metadata
     */
    @AuraEnabled
    public static Map<String, Object> importReportConfig(Id reportId) {
        if (reportId == null) {
            throw DocGenService.ahe('Report ID is required.');
        }

        Reports.ReportDescribeResult describe = Reports.ReportManager.describeReport(reportId);
        Reports.ReportMetadata metadata = describe.getReportMetadata();
        Reports.ReportExtendedMetadata extMeta = describe.getReportExtendedMetadata();

        // Determine base object from report type
        String reportTypeName = metadata.getReportType().getType();
        String reportTypeLabel = metadata.getReportType().getLabel();
        String baseObject = resolveReportBaseObject(reportTypeName, reportTypeLabel);
        if (baseObject == null) {
            throw DocGenService.ahe(
                'Could not determine the base object for this report. Report type: ' + reportTypeName
            );
        }

        // Get the field map for normalization
        Map<String, SObjectType> globalDescribe = Schema.getGlobalDescribe();
        SObjectType objType = globalDescribe.get(baseObject);
        if (objType == null) {
            throw DocGenService.ahe('Object not found: ' + baseObject);
        }
        Map<String, SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        // Build label → proper API name map, and lowercase key → proper API name map
        Map<String, String> labelToApiName = new Map<String, String>();
        Map<String, String> properCaseMap = new Map<String, String>();
        for (String apiName : fieldMap.keySet()) {
            Schema.DescribeFieldResult dfr = fieldMap.get(apiName).getDescribe();
            String properName = dfr.getName(); // Proper-cased: 'BillingState', 'Name', etc.
            labelToApiName.put(dfr.getLabel().toLowerCase(), properName);
            properCaseMap.put(apiName.toLowerCase(), properName);
        }

        // Build parent relationship prefix map: USERS → Owner, ACCOUNT → Account, etc.
        Map<String, String> parentPrefixMap = new Map<String, String>();
        for (SObjectField sof : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getRelationshipName() != null && dfr.getReferenceTo() != null && !dfr.getReferenceTo().isEmpty()) {
                String refObjName = dfr.getReferenceTo()[0].getDescribe().getName().toUpperCase();
                parentPrefixMap.put(refObjName, dfr.getRelationshipName());
                if (dfr.getName() == 'OwnerId') {
                    parentPrefixMap.put('USERS', dfr.getRelationshipName());
                }
                if (dfr.getName() == 'CreatedById') {
                    parentPrefixMap.put('CREATED_BY', dfr.getRelationshipName());
                }
            }
        }

        // For cross-object reports (OpportunityContactProduct), build child object field maps
        // so we can route columns like FIRST_NAME to the Contact child, PRODUCT_NAME to LineItems
        Map<String, String> childRelNameByObject = new Map<String, String>();
        Map<String, Map<String, SObjectField>> childFieldMaps = new Map<String, Map<String, SObjectField>>();
        Map<String, Map<String, String>> childLabelMaps = new Map<String, Map<String, String>>();
        Map<String, Map<String, String>> childProperCaseMaps = new Map<String, Map<String, String>>();

        // Detect child objects from the report type name
        Map<String, String> reportTypeChildObjects = new Map<String, String>{
            'OpportunityContactProduct' => 'Contact,OpportunityLineItem',
            'OpportunityContact' => 'Contact',
            'OpportunityProduct' => 'OpportunityLineItem',
            'OpportunityLead' => 'Lead',
            'AccountContact' => 'Contact',
            'AccountCase' => 'Case',
            'CaseContact' => 'Contact',
            'CampaignMember' => 'Contact,Lead',
            'QuoteProduct' => 'Quote',
            'QuoteList' => 'Quote'
        };

        if (reportTypeChildObjects.containsKey(reportTypeName)) {
            for (String childObjName : reportTypeChildObjects.get(reportTypeName).split(',')) {
                // Find the relationship name for this child on the base object
                Boolean found = false;
                for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
                    if (
                        cr.getChildSObject().getDescribe().getName() == childObjName &&
                        cr.getRelationshipName() != null
                    ) {
                        childRelNameByObject.put(childObjName, cr.getRelationshipName());
                        found = true;
                        break;
                    }
                }
                // If not a direct child (e.g., Contact via OpportunityContactRole), skip SOQL routing
                // but still build the field map for label-based column detection
                if (!found) {
                    String junctionRelName = findJunctionRelationship(baseObject, childObjName, objType);
                    childRelNameByObject.put(
                        childObjName,
                        junctionRelName != null
                            ? '__junction_' + childObjName + ':' + junctionRelName
                            : '__junction_' + childObjName
                    );
                }

                // Build field maps for label matching regardless
                SObjectType childType = globalDescribe.get(childObjName);
                if (childType != null) {
                    Map<String, SObjectField> cfm = childType.getDescribe().fields.getMap();
                    childFieldMaps.put(childObjName, cfm);
                    Map<String, String> clm = new Map<String, String>();
                    Map<String, String> cpm = new Map<String, String>();
                    for (String fn : cfm.keySet()) {
                        Schema.DescribeFieldResult cdfr = cfm.get(fn).getDescribe();
                        clm.put(cdfr.getLabel().toLowerCase(), cdfr.getName());
                        cpm.put(fn.toLowerCase(), cdfr.getName());
                    }
                    childLabelMaps.put(childObjName, clm);
                    childProperCaseMaps.put(childObjName, cpm);
                }
            }
        } else {
            // Dynamic child discovery for custom object report types not in the hardcoded map.
            // Scan the base object's child relationships and build field maps for any queryable
            // children so report columns can be matched by label.
            for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
                if (cr.getRelationshipName() == null) {
                    continue;
                }
                String childObjName = cr.getChildSObject().getDescribe().getName();
                if (
                    childObjName.endsWith('History') ||
                    childObjName.endsWith('Share') ||
                    childObjName.endsWith('Feed')
                ) {
                    continue;
                }
                if (childRelNameByObject.containsKey(childObjName)) {
                    continue;
                }
                Schema.DescribeSObjectResult childDesc = cr.getChildSObject().getDescribe();
                if (!childDesc.isQueryable() || childDesc.isDeprecatedAndHidden()) {
                    continue;
                }
                childRelNameByObject.put(childObjName, cr.getRelationshipName());
                Map<String, SObjectField> cfm = childDesc.fields.getMap();
                if (cfm.size() < 3) {
                    continue;
                } // Skip trivial objects
                childFieldMaps.put(childObjName, cfm);
                Map<String, String> clm = new Map<String, String>();
                Map<String, String> cpm = new Map<String, String>();
                for (String fn : cfm.keySet()) {
                    Schema.DescribeFieldResult cdfr = cfm.get(fn).getDescribe();
                    clm.put(cdfr.getLabel().toLowerCase(), cdfr.getName());
                    cpm.put(fn.toLowerCase(), cdfr.getName());
                }
                childLabelMaps.put(childObjName, clm);
                childProperCaseMaps.put(childObjName, cpm);
            }
        }

        // Also discover grandchildren (e.g., Quote → QuoteLineItems) so their
        // field labels can match against report columns dynamically.
        for (String childObjName : new List<String>(childRelNameByObject.keySet())) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) {
                continue;
            } // Skip junctions
            SObjectType childType = globalDescribe.get(childObjName);
            if (childType == null) {
                continue;
            }
            for (Schema.ChildRelationship gcr : childType.getDescribe().getChildRelationships()) {
                if (gcr.getRelationshipName() == null) {
                    continue;
                }
                String gcObjName = gcr.getChildSObject().getDescribe().getName();
                // Skip if already tracked or if it's a system object
                if (childFieldMaps.containsKey(gcObjName)) {
                    continue;
                }
                if (gcObjName.endsWith('History') || gcObjName.endsWith('Share') || gcObjName.endsWith('Feed')) {
                    continue;
                }
                // Only add grandchildren that might have report columns
                // Check if the grandchild object has meaningful fields
                Map<String, SObjectField> gcfm = gcr.getChildSObject().getDescribe().fields.getMap();
                if (gcfm.size() < 3) {
                    continue;
                } // Skip trivial objects
                childFieldMaps.put(gcObjName, gcfm);
                childRelNameByObject.put(gcObjName, gcr.getRelationshipName());
                Map<String, String> gclm = new Map<String, String>();
                Map<String, String> gcpm = new Map<String, String>();
                for (String fn : gcfm.keySet()) {
                    Schema.DescribeFieldResult gcdfr = gcfm.get(fn).getDescribe();
                    gclm.put(gcdfr.getLabel().toLowerCase(), gcdfr.getName());
                    gcpm.put(fn.toLowerCase(), gcdfr.getName());
                }
                childLabelMaps.put(gcObjName, gclm);
                childProperCaseMaps.put(gcObjName, gcpm);
            }
        }

        Map<String, Map<String, String>> reportKeyOverrides = new Map<String, Map<String, String>>{
            'PRODUCT_NAME' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Name' },
            'QUANTITY' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'Quantity' },
            'TOTAL_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'TotalPrice' },
            'UNIT_PRICE' => new Map<String, String>{ 'object' => 'OpportunityLineItem', 'field' => 'UnitPrice' },
            'QUOTE_LINEITEM_NAME' => new Map<String, String>{ 'object' => 'QuoteLineItem', 'field' => 'Name' },
            'PHONE1' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'Phone' },
            'PHONE2' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'HomePhone' },
            'PHONE3' => new Map<String, String>{ 'object' => 'Contact', 'field' => 'MobilePhone' }
        };

        // Normalize report columns — route to base, parent, or child
        List<String> detailColumns = metadata.getDetailColumns();
        Map<String, Reports.DetailColumn> columnInfo = extMeta.getDetailColumnInfo();
        List<String> normalizedFields = new List<String>();
        List<String> parentFields = new List<String>();
        Map<String, List<String>> childFields = new Map<String, List<String>>();

        for (String colKey : detailColumns) {
            Reports.DetailColumn col = columnInfo.get(colKey);
            String colLabel = (col != null) ? col.getLabel() : null;
            Boolean mapped = false;

            // 0a. Dynamic label matching against ALL child objects
            // If the column label matches a field label on ANY known child object,
            // route it there. This works for any report type without hardcoding.
            if (!mapped && String.isNotBlank(colLabel) && !childFieldMaps.isEmpty()) {
                String labelLower = colLabel.toLowerCase();
                // Strip common label prefixes like "Quote Line Item: " or "Product: "
                String cleanLabel = labelLower;
                if (cleanLabel.contains(': ')) {
                    cleanLabel = cleanLabel.substringAfter(': ');
                }

                for (String childObjName : childLabelMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);
                    if (relName == null) {
                        continue;
                    }

                    // Try full label first, then cleaned label
                    String childFieldName = clm.get(labelLower);
                    if (childFieldName == null) {
                        childFieldName = clm.get(cleanLabel);
                    }

                    // Make sure it's NOT also a base object field (avoid stealing base fields)
                    if (childFieldName != null && (!labelToApiName.containsKey(labelLower) || colKey.contains('.'))) {
                        if (!childFields.containsKey(relName)) {
                            childFields.put(relName, new List<String>());
                        }
                        if (!childFields.get(relName).contains(childFieldName)) {
                            childFields.get(relName).add(childFieldName);
                        }
                        mapped = true;
                        break;
                    }
                }
            }

            // 0b. Check hardcoded overrides for remaining unmapped columns
            if (!mapped && reportKeyOverrides.containsKey(colKey)) {
                Map<String, String> overrideInfo = reportKeyOverrides.get(colKey);
                String targetObj = overrideInfo.get('object');
                String targetField = overrideInfo.get('field');
                String relName = childRelNameByObject.get(targetObj);
                if (relName != null) {
                    if (!childFields.containsKey(relName)) {
                        childFields.put(relName, new List<String>());
                    }
                    if (!childFields.get(relName).contains(targetField)) {
                        childFields.get(relName).add(targetField);
                    }
                    mapped = true;
                }
            }

            // 1. Check parent prefix (USERS.NAME, ACCOUNT.NAME on non-Account base)
            if (!mapped && colKey.contains('.')) {
                String prefix = colKey.substringBefore('.').toUpperCase();
                String childField = colKey.substringAfter('.');
                Boolean isSelfPrefix =
                    prefix.equalsIgnoreCase(baseObject) ||
                    prefix.equalsIgnoreCase(baseObject.removeEnd('__c')) ||
                    (baseObject == 'Opportunity' &&
                    prefix == 'OPPORTUNITY');
                if (isSelfPrefix) {
                    // Base object's own field — normalize the field part
                    String fieldName = normalizeReportColumn(
                        childField,
                        colLabel,
                        fieldMap,
                        labelToApiName,
                        properCaseMap
                    );
                    if (fieldName != null && !normalizedFields.contains(fieldName)) {
                        normalizedFields.add(fieldName);
                    }
                    mapped = true;
                } else if (parentPrefixMap.containsKey(prefix)) {
                    String relName = parentPrefixMap.get(prefix);
                    String parentFieldName = resolveParentFieldName(relName, childField, colLabel, fieldMap);
                    if (parentFieldName != null) {
                        String fullPath = relName + '.' + parentFieldName;
                        if (!parentFields.contains(fullPath)) {
                            parentFields.add(fullPath);
                        }
                        mapped = true;
                    }
                }
            }

            // 2. Check hardcoded owner mapping
            if (!mapped && colKey == 'OWNER_FULL_NAME') {
                if (!parentFields.contains('Owner.Name')) {
                    parentFields.add('Owner.Name');
                }
                mapped = true;
            }

            // 3. Try to route to a child object by label matching
            if (!mapped && !childFieldMaps.isEmpty()) {
                for (String childObjName : childFieldMaps.keySet()) {
                    Map<String, String> clm = childLabelMaps.get(childObjName);
                    Map<String, String> cpm = childProperCaseMaps.get(childObjName);
                    Map<String, SObjectField> cfm = childFieldMaps.get(childObjName);
                    String relName = childRelNameByObject.get(childObjName);

                    // Try label match on child object
                    String childFieldName = null;
                    if (String.isNotBlank(colLabel) && clm.containsKey(colLabel.toLowerCase())) {
                        childFieldName = clm.get(colLabel.toLowerCase());
                    }
                    // Try direct key match
                    if (childFieldName == null) {
                        childFieldName = normalizeReportColumn(colKey, colLabel, cfm, clm, cpm);
                    }

                    if (childFieldName == null) {
                        continue;
                    }
                    if (!childFields.containsKey(relName)) {
                        childFields.put(relName, new List<String>());
                    }
                    if (!childFields.get(relName).contains(childFieldName)) {
                        childFields.get(relName).add(childFieldName);
                    }
                    mapped = true;
                    break;
                }
            }

            // 4. Fall through: try base object normalization
            if (!mapped) {
                String fieldName = normalizeReportColumn(colKey, colLabel, fieldMap, labelToApiName, properCaseMap);
                if (fieldName != null && !normalizedFields.contains(fieldName)) {
                    normalizedFields.add(fieldName);
                }
            }
        }

        // Convert report filters to a simple list
        List<Map<String, String>> filters = new List<Map<String, String>>();
        for (Reports.ReportFilter rf : metadata.getReportFilters()) {
            Reports.DetailColumn filterCol = columnInfo.get(rf.getColumn());
            String filterLabel = (filterCol != null) ? filterCol.getLabel() : null;
            String filterField = normalizeReportColumn(
                rf.getColumn(),
                filterLabel,
                fieldMap,
                labelToApiName,
                properCaseMap
            );
            if (filterField != null) {
                filters.add(
                    new Map<String, String>{
                        'field' => filterField,
                        'operator' => mapReportOperator(rf.getOperator()),
                        'value' => rf.getValue()
                    }
                );
            }
        }

        // Capture standard date filter as a WHERE clause
        Reports.StandardDateFilter stdDateFilter = metadata.getStandardDateFilter();
        String whereClause = '';
        if (stdDateFilter != null) {
            String dateCol = stdDateFilter.getColumn();
            String dateField = normalizeReportColumn(dateCol, null, fieldMap, labelToApiName, properCaseMap);
            if (dateField == null) {
                // Common date column mappings
                Map<String, String> dateMap = new Map<String, String>{
                    'CREATED_DATE' => 'CreatedDate',
                    'CLOSE_DATE' => 'CloseDate',
                    'LAST_UPDATE' => 'LastModifiedDate'
                };
                dateField = dateMap.get(dateCol);
            }
            if (dateField != null) {
                String duration = stdDateFilter.getDurationValue();
                String startDate = stdDateFilter.getStartDate();
                String endDate = stdDateFilter.getEndDate();

                if (duration != null && duration != 'CUSTOM') {
                    // Relative date: THIS_MONTH, LAST_YEAR, etc.
                    whereClause = dateField + ' = ' + duration;
                } else {
                    if (String.isNotBlank(startDate) && String.isNotBlank(endDate)) {
                        whereClause = dateField + ' >= ' + startDate + ' AND ' + dateField + ' <= ' + endDate;
                    } else if (String.isNotBlank(startDate)) {
                        whereClause = dateField + ' >= ' + startDate;
                    } else if (String.isNotBlank(endDate)) {
                        whereClause = dateField + ' <= ' + endDate;
                    }
                }
            }
        }

        // Build WHERE string from custom filters too
        List<String> filterParts = new List<String>();
        if (String.isNotBlank(whereClause)) {
            filterParts.add(whereClause);
        }
        for (Map<String, String> f : filters) {
            String op = f.get('operator');
            String val = f.get('value');
            String fieldName = f.get('field');

            // Detect multi-value equals: "Value1,Value2,Value3" → convert to IN
            // But not formatted numbers like "2,000" (those start with " or are purely numeric)
            if ((op == '=' || op == '!=') && val.contains(',') && !val.startsWith('"')) {
                String stripped = val.replaceAll('[,\\d\\.\\s]', '');
                if (stripped.length() > 0) {
                    // Has non-numeric chars after stripping commas/digits → it's multi-value text
                    op = (op == '=') ? 'IN' : 'NOT IN';
                }
            }

            if (op == 'LIKE') {
                filterParts.add(fieldName + ' LIKE \'%' + String.escapeSingleQuotes(val) + '%\'');
            } else if (op == 'IN' || op == 'NOT IN') {
                // IN/NOT IN: value may be comma-separated list
                // Format: StageName IN ('Closed Won', 'Negotiation')
                List<String> vals = val.split(',');
                List<String> quotedVals = new List<String>();
                for (String v : vals) {
                    quotedVals.add('\'' + String.escapeSingleQuotes(v.trim()) + '\'');
                }
                filterParts.add(fieldName + ' ' + op + ' (' + String.join(quotedVals, ', ') + ')');
            } else {
                // Check if value is a SOQL date literal (no quotes needed)
                Set<String> dateLiterals = new Set<String>{
                    'TODAY',
                    'YESTERDAY',
                    'TOMORROW',
                    'LAST_WEEK',
                    'THIS_WEEK',
                    'NEXT_WEEK',
                    'LAST_MONTH',
                    'THIS_MONTH',
                    'NEXT_MONTH',
                    'LAST_QUARTER',
                    'THIS_QUARTER',
                    'NEXT_QUARTER',
                    'LAST_YEAR',
                    'THIS_YEAR',
                    'NEXT_YEAR',
                    'LAST_90_DAYS',
                    'NEXT_90_DAYS',
                    'LAST_N_DAYS',
                    'NEXT_N_DAYS'
                };
                String upperVal = val.toUpperCase().trim();
                Boolean isDateLiteral =
                    dateLiterals.contains(upperVal) ||
                    upperVal.startsWith('LAST_N_') ||
                    upperVal.startsWith('NEXT_N_');
                Boolean isNumeric = val.trim().isNumeric() || Pattern.matches('-?\\d+\\.?\\d*', val.trim());
                Boolean isDateFormat = Pattern.matches('\\d{4}-\\d{2}-\\d{2}(T.*)?', val.trim());
                Boolean isBoolVal = upperVal == 'TRUE' || upperVal == 'FALSE' || upperVal == 'NULL';

                if (isDateLiteral || isNumeric || isDateFormat || isBoolVal) {
                    filterParts.add(fieldName + ' ' + op + ' ' + val.trim());
                } else {
                    filterParts.add(fieldName + ' ' + op + ' \'' + String.escapeSingleQuotes(val) + '\'');
                }
            }
        }
        String bulkWhereClause = String.join(filterParts, ' AND ');

        // Build child subqueries for the query config (skip junction-based children)
        List<String> childSubqueries = new List<String>();
        for (String relName : childFields.keySet()) {
            List<String> fields = childFields.get(relName);
            if (!fields.isEmpty() && !relName.startsWith('__junction_')) {
                childSubqueries.add('(SELECT ' + String.join(fields, ', ') + ' FROM ' + relName + ')');
            }
        }

        // Build junction info for the LWC
        List<Map<String, String>> junctionInfo = new List<Map<String, String>>();
        for (String relName : childFields.keySet()) {
            if (relName.startsWith('__junction_')) {
                // Parse: __junction_Contact or __junction_Contact:OpportunityContactRoles
                String remainder = relName.substring(11); // strip '__junction_'
                String targetObj;
                String junctionRel = '';
                if (remainder.contains(':')) {
                    targetObj = remainder.substringBefore(':');
                    junctionRel = remainder.substringAfter(':');
                } else {
                    targetObj = remainder;
                }
                // Resolve junction object name, lookup fields, and target relationship name
                String targetIdField = resolveJunctionTargetIdField(junctionRel, targetObj);
                String junctionObjName = resolveJunctionObjectName(junctionRel);
                String baseLookupField = resolveJunctionTargetIdField(junctionRel, baseObject);
                // Find the relationship name from junction object to target (e.g., ContactId → Contact)
                String targetRelName = resolveJunctionTargetRelName(junctionObjName, targetObj);
                junctionInfo.add(
                    new Map<String, String>{
                        'targetObject' => targetObj,
                        'junctionRel' => junctionRel,
                        'junctionObject' => junctionObjName,
                        'baseLookupField' => baseLookupField,
                        'targetIdField' => targetIdField,
                        'targetRelName' => targetRelName != null ? targetRelName : targetObj,
                        'fields' => String.join(childFields.get(relName), ',')
                    }
                );
            }
        }

        Integer totalChildFields = 0;
        for (String relKey : childFields.keySet()) {
            totalChildFields += childFields.get(relKey).size();
        }

        // Build hierarchy map: relationship name → parent object
        // So LWC knows QuoteLineItems belongs under Quote, not Opportunity
        Map<String, Map<String, String>> childHierarchy = new Map<String, Map<String, String>>();
        for (String childObjName : childRelNameByObject.keySet()) {
            String relName = childRelNameByObject.get(childObjName);
            if (relName.startsWith('__junction_')) {
                continue;
            }
            if (!childFields.containsKey(relName)) {
                continue;
            } // Only include objects with matched fields

            // Find which parent this child belongs to and the correct lookup field
            String parentObj = findParentObject(childObjName, baseObject, childRelNameByObject);
            String lookupFieldName = findLookupField(childObjName, parentObj);

            childHierarchy.put(
                relName,
                new Map<String, String>{
                    'objectName' => childObjName,
                    'parentObject' => parentObj,
                    'lookupField' => lookupFieldName
                }
            );
        }

        return new Map<String, Object>{
            'baseObject' => baseObject,
            'fields' => normalizedFields,
            'parentFields' => parentFields,
            'childSubqueries' => childSubqueries,
            'childFields' => childFields,
            'childHierarchy' => childHierarchy,
            'junctions' => junctionInfo,
            'filters' => filters,
            'bulkWhereClause' => bulkWhereClause,
            'reportName' => metadata.getName(),
            'fieldCount' => normalizedFields.size() +
            parentFields.size() +
            totalChildFields,
            'filterCount' => filters.size()
        };
    }

    /**
     * Determines the parent object for a child by checking its reference fields.
     * If a reference points to another known child object, returns that as the parent (grandchild case).
     */
    @TestVisible
    private static String findParentObject(
        String childObjName,
        String baseObject,
        Map<String, String> childRelNameByObject
    ) {
        SObjectType childSobjType = Schema.getGlobalDescribe().get(childObjName);
        if (childSobjType == null) {
            return baseObject;
        }

        for (Schema.SObjectField sof : childSobjType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) {
                continue;
            }
            for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                String refName = ref.getDescribe().getName();
                // Ignore the child object itself as a potential parent (e.g., ReportsToId on Contact)
                if (childRelNameByObject.containsKey(refName) && refName != baseObject && refName != childObjName) {
                    return refName;
                }
            }
        }
        return baseObject;
    }

    /**
     * Finds the lookup field on childObjName that references parentObjName.
     * Uses schema describe to find the correct field, falling back to parentObj+'Id' or parentObj for custom.
     */
    private static String findLookupField(String childObjName, String parentObjName) {
        SObjectType childType = Schema.getGlobalDescribe().get(childObjName);
        if (childType != null) {
            for (Schema.SObjectField sof : childType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = sof.getDescribe();
                if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) {
                    continue;
                }
                for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                    if (ref.getDescribe().getName() == parentObjName) {
                        return dfr.getName();
                    }
                }
            }
        }
        // Fallback: standard convention
        return parentObjName.endsWith('__c') ? parentObjName : parentObjName + 'Id';
    }

    /**
     * Finds a junction relationship name for accessing a target object via the base object.
     * Checks known junctions first, then scans child relationships for a matching reference.
     */
    @TestVisible
    private static String findJunctionRelationship(String baseObject, String childObjName, SObjectType objType) {
        Map<String, String> knownJunctions = new Map<String, String>{
            'Opportunity:Contact' => 'OpportunityContactRoles',
            'Account:Contact' => 'AccountContactRelations',
            'Campaign:Contact' => 'CampaignMembers',
            'Campaign:Lead' => 'CampaignMembers'
        };
        String junctionKey = baseObject + ':' + childObjName;
        String junctionRelName = knownJunctions.get(junctionKey);
        if (junctionRelName != null) {
            return junctionRelName;
        }

        // Fallback: scan child relationships for a junction object
        for (Schema.ChildRelationship cr : objType.getDescribe().getChildRelationships()) {
            if (cr.getRelationshipName() == null) {
                continue;
            }
            String jObjName = cr.getChildSObject().getDescribe().getName();
            if (jObjName.endsWith('History') || jObjName.endsWith('Share') || jObjName.endsWith('Feed')) {
                continue;
            }

            if (hasReferenceToObject(cr.getChildSObject(), childObjName)) {
                return cr.getRelationshipName();
            }
        }
        return null;
    }

    /**
     * Resolves the lookup field API name on a junction object that points to the target object.
     * E.g., for OpportunityContactRoles → Contact, returns 'ContactId'.
     * Dynamically finds the junction SObject from the relationship name, then scans its reference fields.
     */
    private static String resolveJunctionTargetIdField(String junctionRelName, String targetObjectName) {
        if (String.isBlank(junctionRelName) || String.isBlank(targetObjectName)) {
            return targetObjectName + 'Id';
        }
        // Derive the junction object API name from the relationship name
        // OpportunityContactRoles → OpportunityContactRole, CampaignMembers → CampaignMember, etc.
        List<String> candidates = new List<String>{
            junctionRelName.removeEnd('s'), // OpportunityContactRoles → OpportunityContactRole
            junctionRelName.removeEnd('es'), // AccountContactRelations → AccountContactRelation (if ends in 'es')
            junctionRelName // Exact match (rare)
        };
        Map<String, SObjectType> gd = Schema.getGlobalDescribe();
        for (String candidate : candidates) {
            SObjectType juncType = gd.get(candidate);
            if (juncType == null) {
                continue;
            }
            for (SObjectField sof : juncType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = sof.getDescribe();
                if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) {
                    continue;
                }
                for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                    if (ref.getDescribe().getName() == targetObjectName) {
                        return dfr.getName();
                    }
                }
            }
        }
        return targetObjectName + 'Id';
    }

    /**
     * Resolves the junction SObject API name from the relationship name.
     * E.g., OpportunityContactRoles → OpportunityContactRole.
     */
    private static String resolveJunctionObjectName(String junctionRelName) {
        if (String.isBlank(junctionRelName)) {
            return null;
        }
        Map<String, SObjectType> gd = Schema.getGlobalDescribe();
        for (
            String candidate : new List<String>{
                junctionRelName.removeEnd('s'),
                junctionRelName.removeEnd('es'),
                junctionRelName
            }
        ) {
            if (gd.containsKey(candidate)) {
                return candidate;
            }
        }
        return junctionRelName.removeEnd('s');
    }

    /**
     * Resolves the relationship name from a junction object to its target object.
     * E.g., on OpportunityContactRole, the ContactId field has relationship name 'Contact'.
     */
    private static String resolveJunctionTargetRelName(String junctionObjName, String targetObjectName) {
        if (String.isBlank(junctionObjName) || String.isBlank(targetObjectName)) {
            return null;
        }
        SObjectType juncType = Schema.getGlobalDescribe().get(junctionObjName);
        if (juncType == null) {
            return null;
        }
        for (SObjectField sof : juncType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo() == null) {
                continue;
            }
            for (Schema.SObjectType ref : dfr.getReferenceTo()) {
                if (ref.getDescribe().getName() == targetObjectName && dfr.getRelationshipName() != null) {
                    return dfr.getRelationshipName();
                }
            }
        }
        return null;
    }

    /**
     * Checks if a junction SObject has a reference field pointing to the target object.
     */
    @TestVisible
    private static Boolean hasReferenceToObject(Schema.SObjectType junctionType, String targetObjectName) {
        for (Schema.SObjectField jf : junctionType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult jdfr = jf.getDescribe();
            if (jdfr.getType() != Schema.DisplayType.REFERENCE || jdfr.getReferenceTo() == null) {
                continue;
            }
            for (Schema.SObjectType ref : jdfr.getReferenceTo()) {
                if (ref.getDescribe().getName() == targetObjectName) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * Resolves a field name on a parent object from a report column.
     * E.g., for Owner relationship with child field 'NAME', resolves to 'Name'.
     */
    @TestVisible
    private static String resolveParentFieldName(
        String relName,
        String childFieldKey,
        String columnLabel,
        Map<String, SObjectField> baseFieldMap
    ) {
        // Find the lookup field to get the referenced object
        Map<String, SObjectField> parentFieldMap = null;
        for (SObjectField sof : baseFieldMap.values()) {
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (
                dfr.getRelationshipName() == relName &&
                dfr.getReferenceTo() != null &&
                !dfr.getReferenceTo().isEmpty()
            ) {
                parentFieldMap = dfr.getReferenceTo()[0].getDescribe().fields.getMap();
                break;
            }
        }
        if (parentFieldMap == null) {
            return null;
        }

        // Try direct match
        if (parentFieldMap.containsKey(childFieldKey)) {
            return parentFieldMap.get(childFieldKey).getDescribe().getName();
        }

        // Try label match on parent object
        if (String.isNotBlank(columnLabel)) {
            for (String pKey : parentFieldMap.keySet()) {
                Schema.DescribeFieldResult pDfr = parentFieldMap.get(pKey).getDescribe();
                if (
                    pDfr.getLabel().equalsIgnoreCase(columnLabel) ||
                    (pDfr.getLabel().equalsIgnoreCase('Name') && childFieldKey.equalsIgnoreCase('NAME'))
                ) {
                    return pDfr.getName();
                }
            }
        }

        // Common: NAME → Name, EMAIL → Email
        for (String pKey : parentFieldMap.keySet()) {
            if (pKey.equalsIgnoreCase(childFieldKey)) {
                return parentFieldMap.get(pKey).getDescribe().getName();
            }
        }
        return null;
    }

    /**
     * Resolves a report type name to a base object API name.
     * Handles standard patterns like 'AccountList', 'OpportunityList', 'Contact', etc.
     */
    /**
     * Resolves a report type to its base Salesforce object.
     * Uses multiple strategies — works for ANY report type, not just hardcoded ones.
     */
    @TestVisible
    private static String resolveReportBaseObject(String reportTypeName) {
        return resolveReportBaseObject(reportTypeName, null);
    }

    @TestVisible
    private static String resolveReportBaseObject(String reportTypeName, String reportTypeLabel) {
        if (String.isBlank(reportTypeName)) {
            return null;
        }
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Strategy 1: Direct match (report type name IS the object name)
        if (globalDescribe.containsKey(reportTypeName)) {
            return reportTypeName;
        }

        // Strategy 2: Strip 'List' suffix — AccountList → Account
        if (reportTypeName.endsWith('List')) {
            String stripped = reportTypeName.removeEnd('List');
            if (globalDescribe.containsKey(stripped)) {
                return stripped;
            }
        }

        // Strategy 3: Custom report types ending in __c are handled in Strategy 6 below

        // Strategy 4: Match the report type label against object labels
        // "Accounts" → Account, "Opportunities with Contact Roles and Products" → Opportunity
        if (String.isNotBlank(reportTypeLabel)) {
            String labelLower = reportTypeLabel.toLowerCase();
            for (String objName : globalDescribe.keySet()) {
                Schema.DescribeSObjectResult objDesc = globalDescribe.get(objName).getDescribe();
                if (!objDesc.isQueryable() || objDesc.isDeprecatedAndHidden()) {
                    continue;
                }
                String objLabel = objDesc.getLabel().toLowerCase();
                String objLabelPlural = objDesc.getLabelPlural() != null ? objDesc.getLabelPlural().toLowerCase() : '';
                // "Accounts" starts with "Account" label plural
                if (String.isNotBlank(objLabelPlural) && labelLower.startsWith(objLabelPlural)) {
                    return objDesc.getName();
                }
                if (labelLower.startsWith(objLabel)) {
                    return objDesc.getName();
                }
            }
        }

        // Strategy 5: Match standard object names as prefix of the report type name
        // OpportunityLead → Opportunity, AccountCase → Account
        List<String> commonObjects = new List<String>{
            'Opportunity',
            'Account',
            'Contact',
            'Lead',
            'Case',
            'Campaign',
            'Contract',
            'Order',
            'Task',
            'Event',
            'User',
            'Solution',
            'Product'
        };
        for (String objName : commonObjects) {
            if (reportTypeName.startsWith(objName) && globalDescribe.containsKey(objName)) {
                return objName;
            }
        }

        // Strategy 6: Custom report type with __c — try to resolve via name minus suffix
        if (reportTypeName.contains('__c')) {
            String basePart = reportTypeName.substringBefore('__c');
            // 6a. Try the full custom object name (basePart + '__c') — it may be the object itself
            String customObjName = basePart + '__c';
            if (globalDescribe.containsKey(customObjName)) {
                return customObjName;
            }
            // 6b. Try with namespace prefix stripped (e.g., ns__My_Report__c → My_Report__c → My_Object__c)
            if (basePart.contains('__')) {
                String withoutNs = basePart.substringAfter('__') + '__c';
                if (globalDescribe.containsKey(withoutNs)) {
                    return withoutNs;
                }
            }
            // 6c. Fallback: check if any part matches a standard object name
            for (String objName : commonObjects) {
                if (basePart.containsIgnoreCase(objName) && globalDescribe.containsKey(objName)) {
                    return objName;
                }
            }
            // 6d. Scan all custom objects for a name contained in the report type
            for (String objName : globalDescribe.keySet()) {
                if (!objName.endsWith('__c')) {
                    continue;
                }
                Schema.DescribeSObjectResult objDesc = globalDescribe.get(objName).getDescribe();
                if (!objDesc.isQueryable() || objDesc.isDeprecatedAndHidden()) {
                    continue;
                }
                String objBase = objName.removeEnd('__c');
                // Strip namespace from object name for matching
                if (objBase.contains('__')) {
                    objBase = objBase.substringAfter('__');
                }
                if (basePart.containsIgnoreCase(objBase)) {
                    return objDesc.getName();
                }
            }
        }

        return null;
    }

    /**
     * Normalizes a report column key to a SOQL field API name.
     *
     * Report columns use internal identifiers (ACCOUNT.NAME, ADDRESS1_STATE, DUE_DATE)
     * that don't match SOQL field API names. We use a multi-strategy approach:
     *   1. Direct API name match
     *   2. Label-based matching (report label → field label → API name)
     *   3. Hardcoded mappings for common report columns
     */
    @TestVisible
    private static String normalizeReportColumn(
        String columnKey,
        String columnLabel,
        Map<String, SObjectField> fieldMap,
        Map<String, String> labelToApiName,
        Map<String, String> properCaseMap
    ) {
        if (String.isBlank(columnKey)) {
            return null;
        }

        // Skip owner/user columns (parent lookups, not direct fields)
        if (columnKey.startsWith('USERS.')) {
            return null;
        }

        // 1. Label-based matching — most reliable for standard fields
        // Report labels like "Billing State/Province" map precisely to field labels
        if (String.isNotBlank(columnLabel) && labelToApiName.containsKey(columnLabel.toLowerCase())) {
            return labelToApiName.get(columnLabel.toLowerCase());
        }

        // 2. Direct API name match (works for custom fields like MyField__c)
        if (fieldMap.containsKey(columnKey)) {
            return properCaseMap.get(columnKey.toLowerCase());
        }

        // Strip object prefix: ACCOUNT.NAME → NAME
        String fieldPart = columnKey;
        if (columnKey.contains('.')) {
            fieldPart = columnKey.substringAfter('.');
        }
        if (fieldMap.containsKey(fieldPart)) {
            return properCaseMap.get(fieldPart.toLowerCase());
        }

        // 3. Hardcoded mappings for report-specific column keys that don't match labels
        Map<String, String> reportKeyMappings = new Map<String, String>{
            'CREATED_DATE' => 'CreatedDate',
            'LAST_UPDATE' => 'LastModifiedDate',
            'DUE_DATE' => 'LastActivityDate',
            'CLOSE_DATE' => 'CloseDate',
            'AMOUNT' => 'Amount',
            'FULL_NAME' => 'Name',
            'FIRST_NAME' => 'FirstName',
            'LAST_NAME' => 'LastName',
            'STAGE_NAME' => 'StageName',
            'ADDRESS1_STREET' => 'BillingStreet',
            'ADDRESS1_CITY' => 'BillingCity',
            'ADDRESS1_STATE' => 'BillingState',
            'ADDRESS1_ZIP' => 'BillingPostalCode',
            'ADDRESS1_COUNTRY' => 'BillingCountry',
            'ADDRESS2_STREET' => 'ShippingStreet',
            'ADDRESS2_CITY' => 'ShippingCity',
            'ADDRESS2_STATE' => 'ShippingState',
            'ADDRESS2_ZIP' => 'ShippingPostalCode',
            'ADDRESS2_COUNTRY' => 'ShippingCountry',
            'ACCOUNT_ID' => 'AccountId',
            'CONTACT_ID' => 'ContactId'
        };

        String upperKey = fieldPart.toUpperCase();
        if (reportKeyMappings.containsKey(upperKey)) {
            String mapped = reportKeyMappings.get(upperKey);
            if (fieldMap.containsKey(mapped)) {
                return mapped;
            }
        }

        // 4. Try with __c suffix for custom fields
        if (!fieldPart.endsWithIgnoreCase('__c') && fieldMap.containsKey(fieldPart + '__c')) {
            return properCaseMap.get((fieldPart + '__c').toLowerCase());
        }

        return null;
    }

    /**
     * Maps report filter operators to SOQL operators.
     */
    @TestVisible
    private static String mapReportOperator(String reportOperator) {
        if (String.isBlank(reportOperator)) {
            return '=';
        }

        Map<String, String> operatorMap = new Map<String, String>{
            'equals' => '=',
            'notEqual' => '!=',
            'greaterThan' => '>',
            'lessThan' => '<',
            'greaterOrEqual' => '>=',
            'lessOrEqual' => '<=',
            'contains' => 'LIKE',
            'startsWith' => 'LIKE',
            'includes' => 'IN',
            'excludes' => 'NOT IN'
        };

        return operatorMap.containsKey(reportOperator) ? operatorMap.get(reportOperator) : '=';
    }

    /**
     * Creates 5 sample templates with DOCX files and active versions.
     * Each template demonstrates different merge tag types using only standard fields.
     * @return The number of templates created
     */
    @AuraEnabled
    public static Integer createSampleTemplates() {
        // ---- Template definitions ----
        List<Map<String, String>> defs = new List<Map<String, String>>();

        // 1. Account Overview: simple fields, parent lookup, child loop, COUNT
        defs.add(
            new Map<String, String>{
                'name' => 'Sample: Account Overview',
                'object' => 'Account',
                'category' => 'Sample',
                'desc' => 'Demonstrates: field tags, parent lookups {Owner.Name}, child loops {#Contacts}, and {COUNT:Contacts} aggregate.',
                'config' => '{"v":3,"root":"Account","nodes":[' +
                '{"id":"n0","object":"Account","fields":["Name","Industry","Phone","Website"],"parentFields":["Owner.Name"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"Contact","fields":["FirstName","LastName","Title","Email","Phone"],"parentFields":[],"parentNode":"n0","lookupField":"AccountId","relationshipName":"Contacts"}' +
                ']}'
            }
        );

        // 2. Sales Proposal: currency/date/percent formatting, line item loop, SUM/AVG/COUNT
        defs.add(
            new Map<String, String>{
                'name' => 'Sample: Sales Proposal',
                'object' => 'Opportunity',
                'category' => 'Sample',
                'desc' => 'Demonstrates: {Amount:currency}, {CloseDate:MMMM dd, yyyy}, {Probability:percent}, parent fields {Account.Name}, loops, {SUM:...:currency}, {AVG:...:currency}, {COUNT:...}.',
                'config' => '{"v":3,"root":"Opportunity","nodes":[' +
                '{"id":"n0","object":"Opportunity","fields":["Name","Amount","CloseDate","StageName","Probability"],"parentFields":["Account.Name","Account.Phone"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
                ']}'
            }
        );

        // 3. Contact Card: boolean conditionals, date formatting, parent lookups
        defs.add(
            new Map<String, String>{
                'name' => 'Sample: Contact Card',
                'object' => 'Contact',
                'category' => 'Sample',
                'desc' => 'Demonstrates: boolean conditionals {#HasOptedOutOfEmail}...{/HasOptedOutOfEmail}, {#DoNotCall}, date format {CreatedDate:MM/dd/yyyy}, parent lookup {Account.Name}.',
                'config' => '{"v":3,"root":"Contact","nodes":[' +
                '{"id":"n0","object":"Contact","fields":["FirstName","LastName","Title","Email","Phone","MobilePhone","MailingStreet","MailingCity","MailingState","MailingPostalCode","HasOptedOutOfEmail","DoNotCall","CreatedDate"],"parentFields":["Account.Name","Account.Industry"],"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}'
            }
        );

        // 4. Invoice: all 5 aggregate types, :number/:currency formatting
        defs.add(
            new Map<String, String>{
                'name' => 'Sample: Invoice',
                'object' => 'Opportunity',
                'category' => 'Sample',
                'desc' => 'Demonstrates: all aggregates — {SUM:...:currency}, {COUNT:...:number}, {AVG:...:currency}, {MIN:...:currency}, {MAX:...:currency}. Also {CloseDate:MM/dd/yyyy}, {Quantity:number}.',
                'config' => '{"v":3,"root":"Opportunity","nodes":[' +
                '{"id":"n0","object":"Opportunity","fields":["Name","CloseDate","StageName"],"parentFields":["Account.Name","Account.BillingStreet","Account.BillingCity","Account.BillingState","Account.BillingPostalCode","Account.Phone"],"parentNode":null,"lookupField":null,"relationshipName":null},' +
                '{"id":"n1","object":"OpportunityLineItem","fields":["Quantity","UnitPrice","TotalPrice"],"parentFields":["Product2.Name"],"parentNode":"n0","lookupField":"OpportunityId","relationshipName":"OpportunityLineItems"}' +
                ']}'
            }
        );

        // 5. Case Summary: barcode {*Field}, QR code {*Field:qr}, date formats
        defs.add(
            new Map<String, String>{
                'name' => 'Sample: Case Report',
                'object' => 'Case',
                'category' => 'Sample',
                'desc' => 'Demonstrates: barcode {*CaseNumber}, QR code {*CaseNumber:qr}, date formats {CreatedDate:MMMM dd, yyyy}, parent lookups {Contact.Name}, {Account.Name}.',
                'config' => '{"v":3,"root":"Case","nodes":[' +
                '{"id":"n0","object":"Case","fields":["CaseNumber","Subject","Description","Status","Priority","CreatedDate","ClosedDate"],"parentFields":["Contact.Name","Contact.Email","Account.Name"],"parentNode":null,"lookupField":null,"relationshipName":null}' +
                ']}'
            }
        );

        // ---- DOCX base64 strings (minimal valid DOCX with merge tags) ----
        List<String> docxFiles = new List<String>();

        // Template 1: Account Overview
        docxFiles.add(
            '' +
                'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu' +
                'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi' +
                'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u' +
                'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h' +
                'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv' +
                'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w' +
                'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54' +
                'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFzWN2N1yB8AAMgfAAARAAAAd29y' +
                'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw' +
                'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt' +
                'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz' +
                'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg' +
                'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg' +
                'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz' +
                'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy' +
                'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y' +
                'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5BQ0NPVU5UIE9WRVJWSUVXPC93OnQ+' +
                'PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0iY2VudGVyIi8+PHc6c3BhY2luZyB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+' +
                'PHc6clByPjx3OmkvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMjIiLz48dzpzekNzIHc6dmFsPSIyMiIvPjwvdzpyUHI+PHc6dD57' +
                'TmFtZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9' +
                'IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3' +
                'OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAi' +
                'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIv' +
                'PjwvdzpyUHI+PHc6dD5BY2NvdW50IEluZm9ybWF0aW9uPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0' +
                'MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpz' +
                'ekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbmR1c3RyeTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29s' +
                'b3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntJbmR1c3RyeX08L3c6dD48L3c6' +
                'cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+' +
                'PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJl' +
                'c2VydmUiPlBob25lOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3' +
                'OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1Bob25lfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAi' +
                'IHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD' +
                'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+V2Vic2l0ZTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig' +
                'dzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntXZWJzaXRlfTwvdzp0PjwvdzpyPjwv' +
                'dzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpj' +
                'b2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2' +
                'ZSI+QWNjb3VudCBPd25lcjogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6' +
                'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntPd25lci5OYW1lfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJl' +
                'Zm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8i' +
                'IHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNv' +
                'bG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db250YWN0czwvdzp0Pjwvdzpy' +
                'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xv' +
                'ciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+' +
                'VG90YWwgQ29udGFjdHM6IHtDT1VOVDpDb250YWN0c308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYw' +
                'IiB3OmFmdGVyPSI2MCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+' +
                'PC93OnJQcj48dzp0PnsjQ29udGFjdHN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0' +
                'byIvPjx3OnRibEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2' +
                'YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3Bh' +
                'Y2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3' +
                'Omluc2lkZUggdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3' +
                'OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9yZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0i' +
                'MzIwMCIvPjx3OmdyaWRDb2wgdzp3PSIyNDAwIi8+PHc6Z3JpZENvbCB3Onc9IjI0MDAiLz48dzpncmlkQ29sIHc6dz0iMjQwMCIvPjwvdzp0YmxHcmlkPgog' +
                'ICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6' +
                'dG9wIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIv' +
                'Pjx3OnJpZ2h0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6' +
                'YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6' +
                'dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD5OYW1lPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpj' +
                'b2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0' +
                'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj' +
                'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2' +
                'YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlRpdGxlPC93OnQ+PC93OnI+PC93OnA+PC93' +
                'OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3' +
                'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmln' +
                'aHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0i' +
                'MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4' +
                'Ii8+PC93OnJQcj48dzp0PkVtYWlsPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i' +
                'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk' +
                'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6' +
                'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG' +
                'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlBob25lPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjwv' +
                'dzp0cj4KICAgICAgPHc6dHI+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIg' +
                'dzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93' +
                'OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9' +
                'IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntGaXJzdE5h' +
                'bWV9IHtMYXN0TmFtZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEi' +
                'Lz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBl' +
                'PSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48' +
                'dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFj' +
                'ZT0icHJlc2VydmUiPntUaXRsZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBl' +
                'PSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIg' +
                'dzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+' +
                'PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHht' +
                'bDpzcGFjZT0icHJlc2VydmUiPntFbWFpbH08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIg' +
                'dzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3' +
                'PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwv' +
                'dzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48' +
                'dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntQaG9uZX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgPC93OnRibD4KICAgIDx3OnA+PHc6' +
                'cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSI2MCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFs' +
                'PSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsvQ29udGFjdHN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpw' +
                'QmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6' +
                'YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0iY2VudGVyIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAi' +
                'IHc6YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmkvPjx3OmNvbG9yIHc6dmFsPSI5Q0EzQUYiLz48dzpzeiB3OnZhbD0iMTYiLz48dzpzekNz' +
                'IHc6dmFsPSIxNiIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5HZW5lcmF0ZWQgb24ge1RPREFZfSB8IFBvd2VyZWQgYnkgRG9jR2VuPC93' +
                'OnQ+PC93OnI+PC93OnA+CiAgICA8dzpzZWN0UHI+CiAgICAgIDx3OnBnU3ogdzp3PSIxMjI0MCIgdzpoPSIxNTg0MCIvPgogICAgICA8dzpwZ01hciB3OnRv' +
                'cD0iMTQ0MCIgdzpyaWdodD0iMTQ0MCIgdzpib3R0b209IjE0NDAiIHc6bGVmdD0iMTQ0MCIgdzpoZWFkZXI9IjcyMCIgdzpmb290ZXI9IjcyMCIgdzpndXR0' +
                'ZXI9IjAiLz4KICAgIDwvdzpzZWN0UHI+CiAgPC93OmJvZHk+Cjwvdzpkb2N1bWVudD5QSwECFAMUAAAAAAApN3hc13mE6rgBAAC4AQAAEwAAAAAAAAAAAAAA' +
                'gAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAAAAAAAAAAACAAekBAABfcmVscy8ucmVsc1BLAQIUAxQA' +
                'AAAAACk3eFyMDoXQnQAAAJ0AAAAcAAAAAAAAAAAAAACAAUADAAB3b3JkL19yZWxzL2RvY3VtZW50LnhtbC5yZWxzUEsBAhQDFAAAAAAAKTd4XNY3Y3XIHwAA' +
                'yB8AABEAAAAAAAAAAAAAAIABFwQAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAAEAAQAAwEAAA4kAAAAAA=='
        );

        // Template 2: Sales Proposal
        docxFiles.add(
            '' +
                'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu' +
                'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi' +
                'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u' +
                'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h' +
                'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv' +
                'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w' +
                'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54' +
                'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFxGcFSOQCcAAEAnAAARAAAAd29y' +
                'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw' +
                'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt' +
                'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz' +
                'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg' +
                'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg' +
                'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz' +
                'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy' +
                'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y' +
                'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5TQUxFUyBQUk9QT1NBTDwvdzp0Pjwv' +
                'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3' +
                'OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIyIi8+PHc6c3pDcyB3OnZhbD0iMjIiLz48L3c6clByPjx3OnQ+UHJl' +
                'cGFyZWQgZm9yIHtBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xl' +
                'IiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+' +
                'CiAgICA8dzpwPjx3OnBQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IkVGRjZGRiIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9' +
                'IjI0MCIgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMUUzQThBIi8+PHc6c3ogdzp2YWw9IjI2Ii8+' +
                'PHc6c3pDcyB3OnZhbD0iMjYiLz48L3c6clByPjx3OnQ+T3Bwb3J0dW5pdHkgRGV0YWlsczwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6' +
                'c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6' +
                'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+RGVhbCBOYW1lOiA8L3c6dD48L3c6' +
                'cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+' +
                'e05hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3' +
                'OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6' +
                'dCB4bWw6c3BhY2U9InByZXNlcnZlIj5BbW91bnQ6IDwvdzp0PjwvdzpyPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZh' +
                'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57QW1vdW50OmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpw' +
                'UHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUx' +
                'Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+Q2xvc2UgRGF0ZTogPC93' +
                'OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQ' +
                'cj48dzp0PntDbG9zZURhdGU6TU1NTSBkZCwgeXl5eX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQw' +
                'IiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6' +
                'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlN0YWdlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3' +
                'OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1N0YWdlTmFtZX08L3c6dD48L3c6cj48' +
                'L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6' +
                'Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2Vy' +
                'dmUiPlByb2JhYmlsaXR5OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD' +
                'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1Byb2JhYmlsaXR5OnBlcmNlbnR9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFj' +
                'aW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3' +
                'OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5BY2NvdW50IFBob25lOiA8L3c6dD48L3c6' +
                'cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+' +
                'e0FjY291bnQuUGhvbmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48' +
                'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFj' +
                'aW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6' +
                'IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkxpbmUgSXRlbXM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFBy' +
                'Pjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6' +
                'IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntDT1VOVDpPcHBvcnR1bml0eUxpbmVJ' +
                'dGVtc30gaXRlbXM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSI2MCIvPjwvdzpw' +
                'UHI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjT3Bwb3J0' +
                'dW5pdHlMaW5lSXRlbXN9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0byIvPjx3OnRi' +
                'bEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2YWw9InNpbmds' +
                'ZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6' +
                'Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZUgg' +
                'dzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3' +
                'OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9yZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0iMzYwMCIvPjx3' +
                'OmdyaWRDb2wgdzp3PSIxMjAwIi8+PHc6Z3JpZENvbCB3Onc9IjIxMDAiLz48dzpncmlkQ29sIHc6dz0iMjUwMCIvPjwvdzp0YmxHcmlkPgogICAgICA8dzp0' +
                'cj48dzp0Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6dG9wIHc6dz0i' +
                'NDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0' +
                'IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAi' +
                'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIv' +
                'PjwvdzpyUHI+PHc6dD5Qcm9kdWN0PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i' +
                'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk' +
                'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6' +
                'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG' +
                'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlF0eTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0' +
                'Yz48dzp0Y1ByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iMUUzQThBIi8+PHc6dGNNYXI+PHc6dG9wIHc6dz0iNDAiIHc6' +
                'dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0IHc6dz0i' +
                'ODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAiLz48L3c6' +
                'cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSJGRkZGRkYiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpy' +
                'UHI+PHc6dD5Vbml0IFByaWNlPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0' +
                'byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEi' +
                'Lz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48' +
                'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZGRkZG' +
                'RiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlRvdGFsPC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjwvdzp0' +
                'cj4KICAgICAgPHc6dHI+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0' +
                'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj' +
                'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3' +
                'NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntQcm9kdWN0Mi5O' +
                'YW1lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRv' +
                'bSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwv' +
                'dzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpj' +
                'b2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2' +
                'ZSI+e1F1YW50aXR5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIv' +
                'Pjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9' +
                'ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3' +
                'OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNl' +
                'PSJwcmVzZXJ2ZSI+e1VuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3' +
                'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmln' +
                'aHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0i' +
                'MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93' +
                'OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntUb3RhbFByaWNlOmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8' +
                'L3c6dGJsPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6' +
                'cj48dzpyUHI+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9PcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48' +
                'L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9' +
                'IjFFM0E4QSIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0i' +
                'Y2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjBGREY0Ii8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3' +
                'OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxNjY1MzQiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6' +
                'dD5Ub3RhbHM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+' +
                'PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48' +
                'dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlN1YnRvdGFsOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTY2NTM0Ii8+PHc6c3og' +
                'dzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1NVTTpPcHBvcnR1bml0eUxpbmVJdGVtcy5Ub3RhbFByaWNlOmN1cnJlbmN5' +
                'fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3' +
                'OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1s' +
                'OnNwYWNlPSJwcmVzZXJ2ZSI+QXZlcmFnZSBVbml0IFByaWNlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6' +
                'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0FWRzpPcHBvcnR1bml0eUxpbmVJdGVtcy5Vbml0UHJpY2U6Y3VycmVu' +
                'Y3l9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpw' +
                'PgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20gdzp2YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+' +
                'PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3' +
                'OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6' +
                'c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWX0g' +
                'fCBQb3dlcmVkIGJ5IERvY0dlbjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6c2VjdFByPgogICAgICA8dzpwZ1N6IHc6dz0iMTIyNDAiIHc6aD0iMTU4NDAi' +
                'Lz4KICAgICAgPHc6cGdNYXIgdzp0b3A9IjE0NDAiIHc6cmlnaHQ9IjE0NDAiIHc6Ym90dG9tPSIxNDQwIiB3OmxlZnQ9IjE0NDAiIHc6aGVhZGVyPSI3MjAi' +
                'IHc6Zm9vdGVyPSI3MjAiIHc6Z3V0dGVyPSIwIi8+CiAgICA8L3c6c2VjdFByPgogIDwvdzpib2R5Pgo8L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAAKTd4XNd5' +
                'hOq4AQAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAAAAApN3hcIBuG6i4BAAAuAQAACwAAAAAAAAAAAAAAgAHp' +
                'AQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAAAAAAAAAAAAgAFAAwAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsc1BL' +
                'AQIUAxQAAAAAACk3eFxGcFSOQCcAAEAnAAARAAAAAAAAAAAAAACAARcEAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAABAAEAAMBAACGKwAAAAA='
        );

        // Template 3: Contact Card
        docxFiles.add(
            '' +
                'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu' +
                'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi' +
                'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u' +
                'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h' +
                'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv' +
                'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w' +
                'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54' +
                'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFyxF3OmsRoAALEaAAARAAAAd29y' +
                'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw' +
                'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt' +
                'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz' +
                'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg' +
                'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg' +
                'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz' +
                'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy' +
                'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y' +
                'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5DT05UQUNUIENBUkQ8L3c6dD48L3c6' +
                'cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpy' +
                'UHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6IHc6dmFsPSIyMiIvPjx3OnN6Q3Mgdzp2YWw9IjIyIi8+PC93OnJQcj48dzp0PntGaXJz' +
                'dE5hbWV9IHtMYXN0TmFtZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YWZ0' +
                'ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjZCNzI4MCIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2' +
                'YWw9IjIwIi8+PC93OnJQcj48dzp0PntUaXRsZX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJz' +
                'aW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48' +
                'L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJl' +
                'Zm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0i' +
                'MjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db250YWN0IERldGFpbHM8L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3' +
                'OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3' +
                'OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPkVtYWlsOiA8L3c6dD48L3c6cj48' +
                'dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0Vt' +
                'YWlsfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpy' +
                'Pjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQg' +
                'eG1sOnNwYWNlPSJwcmVzZXJ2ZSI+UGhvbmU6IDwvdzp0PjwvdzpyPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0i' +
                'MjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57UGhvbmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5n' +
                'IHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZh' +
                'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5Nb2JpbGU6IDwvdzp0PjwvdzpyPjx3OnI+PHc6' +
                'clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57TW9iaWxlUGhv' +
                'bmV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpw' +
                'PgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3Jl' +
                'PSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIv' +
                'Pjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0Pk1haWxpbmcgQWRkcmVzczwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3Bh' +
                'Y2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9' +
                'IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e01haWxpbmdTdHJlZXR9PC93OnQ+PC93OnI+PC93' +
                'OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6' +
                'dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57TWFp' +
                'bGluZ0NpdHl9LCB7TWFpbGluZ1N0YXRlfSB7TWFpbGluZ1Bvc3RhbENvZGV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5n' +
                'IHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i' +
                'YXV0byIgdzpmaWxsPSJFRkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+' +
                'PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0Pk9yZ2FuaXphdGlvbjwv' +
                'dzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQ' +
                'cj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNw' +
                'YWNlPSJwcmVzZXJ2ZSI+Q29tcGFueTogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIv' +
                'Pjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFj' +
                'aW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3' +
                'OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbmR1c3RyeTogPC93OnQ+PC93OnI+PHc6' +
                'cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntBY2Nv' +
                'dW50LkluZHVzdHJ5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93' +
                'OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRkVGM0M3Ii8+PHc6c3BhY2lu' +
                'ZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5MjQwMEUiLz48dzpzeiB3' +
                'OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5Db21tdW5pY2F0aW9uIFByZWZlcmVuY2VzPC93OnQ+PC93OnI+PC93OnA+CiAg' +
                'ICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjSGFzT3B0ZWRPdXRPZkVtYWls' +
                'fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGRUYyRjIiLz48' +
                'dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5OTFCMUIiLz48' +
                'dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5FbWFpbCBPcHQtT3V0OiBUaGlz' +
                'IGNvbnRhY3QgaGFzIG9wdGVkIG91dCBvZiBlbWFpbCBjb21tdW5pY2F0aW9ucy48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6' +
                'c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9IYXNPcHRlZE91dE9mRW1haWx9PC93OnQ+PC93OnI+PC93OnA+CiAg' +
                'ICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsjRG9Ob3RDYWxsfTwvdzp0Pjwv' +
                'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGRUYyRjIiLz48dzpzcGFjaW5n' +
                'IHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI5OTFCMUIiLz48dzpzeiB3OnZh' +
                'bD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5EbyBOb3QgQ2FsbDogVGhpcyBjb250YWN0IGhh' +
                'cyByZXF1ZXN0ZWQgbm8gcGhvbmUgY2FsbHMuPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnI+PHc6clByPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6' +
                'Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PnsvRG9Ob3RDYWxsfTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJl' +
                'Zm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBCZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6' +
                'c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzphZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAg' +
                'IDx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpy' +
                'UHI+PHc6aS8+PHc6Y29sb3Igdzp2YWw9IjlDQTNBRiIvPjx3OnN6IHc6dmFsPSIxNiIvPjx3OnN6Q3Mgdzp2YWw9IjE2Ii8+PC93OnJQcj48dzp0IHhtbDpz' +
                'cGFjZT0icHJlc2VydmUiPlJlY29yZCBjcmVhdGVkOiB7Q3JlYXRlZERhdGU6TU0vZGQveXl5eX08L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFBy' +
                'Pjx3OmpjIHc6dmFsPSJjZW50ZXIiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6aS8+PHc6' +
                'Y29sb3Igdzp2YWw9IjlDQTNBRiIvPjx3OnN6IHc6dmFsPSIxNiIvPjx3OnN6Q3Mgdzp2YWw9IjE2Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2Vy' +
                'dmUiPkdlbmVyYXRlZCBvbiB7VE9EQVl9IHwgUG93ZXJlZCBieSBEb2NHZW48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnNlY3RQcj4KICAgICAgPHc6cGdT' +
                'eiB3Onc9IjEyMjQwIiB3Omg9IjE1ODQwIi8+CiAgICAgIDx3OnBnTWFyIHc6dG9wPSIxNDQwIiB3OnJpZ2h0PSIxNDQwIiB3OmJvdHRvbT0iMTQ0MCIgdzps' +
                'ZWZ0PSIxNDQwIiB3OmhlYWRlcj0iNzIwIiB3OmZvb3Rlcj0iNzIwIiB3Omd1dHRlcj0iMCIvPgogICAgPC93OnNlY3RQcj4KICA8L3c6Ym9keT4KPC93OmRv' +
                'Y3VtZW50PlBLAQIUAxQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAAAKTd4XCAb' +
                'huouAQAALgEAAAsAAAAAAAAAAAAAAIAB6QEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAAAKTd4XIwOhdCdAAAAnQAAABwAAAAAAAAAAAAAAIABQAMAAHdvcmQv' +
                'X3JlbHMvZG9jdW1lbnQueG1sLnJlbHNQSwECFAMUAAAAAAApN3hcsRdzprEaAACxGgAAEQAAAAAAAAAAAAAAgAEXBAAAd29yZC9kb2N1bWVudC54bWxQSwUG' +
                'AAAAAAQABAADAQAA9x4AAAAA'
        );

        // Template 4: Invoice
        docxFiles.add(
            '' +
                'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu' +
                'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi' +
                'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u' +
                'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h' +
                'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv' +
                'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w' +
                'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54' +
                'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFxc6G9jCjkAAAo5AAARAAAAd29y' +
                'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw' +
                'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt' +
                'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz' +
                'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg' +
                'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg' +
                'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz' +
                'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy' +
                'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y' +
                'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNTYiLz48dzpzekNzIHc6dmFsPSI1NiIvPjwvdzpyUHI+PHc6dD5JTlZPSUNFPC93OnQ+PC93OnI+PC93' +
                'OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3OnNwYWNlPSIxIiB3OmNvbG9yPSIxRTNBOEEi' +
                'Lz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2' +
                'MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6dGJsPjx3OnRibFByPjx3OnRibFcgdzp3PSIwIiB3OnR5cGU9ImF1dG8iLz48dzp0YmxC' +
                'b3JkZXJzPjx3OnRvcCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48dzpsZWZ0IHc6dmFsPSJzaW5nbGUi' +
                'IHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNv' +
                'bG9yPSJEMUQ1REIiLz48dzpyaWdodCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48dzppbnNpZGVIIHc6' +
                'dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZVYgdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpz' +
                'cGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PC93OnRibEJvcmRlcnM+PC93OnRibFByPjx3OnRibEdyaWQ+PHc6Z3JpZENvbCB3Onc9IjQ2ODAiLz48dzpn' +
                'cmlkQ29sIHc6dz0iNDY4MCIvPjwvdzp0YmxHcmlkPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUi' +
                'IHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJh' +
                'dXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6' +
                'c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzphZnRlcj0i' +
                'NDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIx' +
                'OCIvPjwvdzpyUHI+PHc6dD5CSUxMIFRPPC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6' +
                'cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyMiIvPjx3OnN6Q3Mgdzp2YWw9IjIyIi8+PC93OnJQcj48dzp0' +
                'PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+' +
                'PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQ+e0FjY291bnQuQmlsbGluZ1N0cmVldH08L3c6dD48L3c6cj48L3c6' +
                'cD48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFs' +
                'PSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57QWNjb3VudC5CaWxsaW5nQ2l0eX0sIHtBY2NvdW50LkJpbGxpbmdTdGF0ZX0ge0Fj' +
                'Y291bnQuQmlsbGluZ1Bvc3RhbENvZGV9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6' +
                'cj48dzpyUHI+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+UGhvbmU6IHtB' +
                'Y2NvdW50LlBob25lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9' +
                'IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+' +
                'PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAi' +
                'IHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjx3OnNw' +
                'YWNpbmcgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSI2QjcyODAiLz48dzpzeiB3OnZhbD0iMTgiLz48' +
                'dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD5JTlZPSUNFIERFVEFJTFM8L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0i' +
                'cmlnaHQiLz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFs' +
                'PSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5JbnZvaWNlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgi' +
                'Lz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57TmFtZX08L3c6dD48L3c6cj48L3c6cD48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQi' +
                'Lz48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNzIHc6dmFsPSIxOCIv' +
                'PjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5EYXRlOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgiLz48dzpzekNz' +
                'IHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57Q2xvc2VEYXRlOk1NL2RkL3l5eXl9PC93OnQ+PC93OnI+PC93OnA+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9' +
                'InJpZ2h0Ii8+PHc6c3BhY2luZyB3OmFmdGVyPSIyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZh' +
                'bD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+U3RhdHVzOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpzeiB3OnZhbD0iMTgi' +
                'Lz48dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dD57U3RhZ2VOYW1lfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8L3c6dGJs' +
                'PgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3' +
                'OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAi' +
                'Lz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIv' +
                'PjwvdzpyUHI+PHc6dD5MaW5lIEl0ZW1zICh7Q09VTlQ6T3Bwb3J0dW5pdHlMaW5lSXRlbXN9IGl0ZW1zKTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48' +
                'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6c3ogdzp2' +
                'YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+eyNPcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3' +
                'OnRibD48dzp0YmxQcj48dzp0YmxXIHc6dz0iMCIgdzp0eXBlPSJhdXRvIi8+PHc6dGJsQm9yZGVycz48dzp0b3Agdzp2YWw9InNpbmdsZSIgdzpzej0iNCIg' +
                'dzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6bGVmdCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIi' +
                'Lz48dzpib3R0b20gdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6cmlnaHQgdzp2YWw9InNpbmdsZSIg' +
                'dzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURCIi8+PHc6aW5zaWRlSCB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNv' +
                'bG9yPSJEMUQ1REIiLz48dzppbnNpZGVWIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjwvdzp0YmxCb3Jk' +
                'ZXJzPjwvdzp0YmxQcj48dzp0YmxHcmlkPjx3OmdyaWRDb2wgdzp3PSIzNjAwIi8+PHc6Z3JpZENvbCB3Onc9IjEyMDAiLz48dzpncmlkQ29sIHc6dz0iMjEw' +
                'MCIvPjx3OmdyaWRDb2wgdzp3PSIyNTAwIi8+PC93OnRibEdyaWQ+CiAgICAgIDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpj' +
                'b2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0' +
                'eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRj' +
                'UHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2' +
                'YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlByb2R1Y3Q8L3c6dD48L3c6cj48L3c6cD48' +
                'L3c6dGM+PHc6dGM+PHc6dGNQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IjFFM0E4QSIvPjx3OnRjTWFyPjx3OnRvcCB3' +
                'Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpy' +
                'aWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVy' +
                'PSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iRkZGRkZGIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0i' +
                'MTgiLz48L3c6clByPjx3OnQ+UXR5PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0i' +
                'YXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3PSI0MCIgdzp0eXBlPSJk' +
                'eGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNNYXI+PC93OnRjUHI+PHc6' +
                'cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IkZG' +
                'RkZGRiIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0PlVuaXQgUHJpY2U8L3c6dD48L3c6cj48L3c6cD48L3c6' +
                'dGM+PHc6dGM+PHc6dGNQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IjFFM0E4QSIvPjx3OnRjTWFyPjx3OnRvcCB3Onc9' +
                'IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdo' +
                'dCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIw' +
                'Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iRkZGRkZGIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgi' +
                'Lz48L3c6clByPjx3OnQ+VG90YWw8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3' +
                'OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEi' +
                'Lz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3' +
                'OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0i' +
                'MTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e1Byb2R1Y3QyLk5hbWV9PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRj' +
                'UHI+PHc6dGNNYXI+PHc6dG9wIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6Ym90dG9tIHc6dz0iNDAiIHc6dHlwZT0iZHhhIi8+PHc6bGVmdCB3Onc9Ijgw' +
                'IiB3OnR5cGU9ImR4YSIvPjx3OnJpZ2h0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PC93OnRjTWFyPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OnNwYWNpbmcg' +
                'dzpiZWZvcmU9IjAiIHc6YWZ0ZXI9IjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMTgiLz48' +
                'dzpzekNzIHc6dmFsPSIxOCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57UXVhbnRpdHk6bnVtYmVyfTwvdzp0PjwvdzpyPjwvdzpwPjwv' +
                'dzp0Yz48dzp0Yz48dzp0Y1ByPjx3OnRjTWFyPjx3OnRvcCB3Onc9IjQwIiB3OnR5cGU9ImR4YSIvPjx3OmJvdHRvbSB3Onc9IjQwIiB3OnR5cGU9ImR4YSIv' +
                'Pjx3OmxlZnQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48dzpyaWdodCB3Onc9IjgwIiB3OnR5cGU9ImR4YSIvPjwvdzp0Y01hcj48L3c6dGNQcj48dzpwPjx3' +
                'OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSIwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6' +
                'c3ogdzp2YWw9IjE4Ii8+PHc6c3pDcyB3OnZhbD0iMTgiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+e1VuaXRQcmljZTpjdXJyZW5jeX08' +
                'L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y01hcj48dzp0b3Agdzp3PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpib3R0b20gdzp3' +
                'PSI0MCIgdzp0eXBlPSJkeGEiLz48dzpsZWZ0IHc6dz0iODAiIHc6dHlwZT0iZHhhIi8+PHc6cmlnaHQgdzp3PSI4MCIgdzp0eXBlPSJkeGEiLz48L3c6dGNN' +
                'YXI+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iMCIgdzphZnRlcj0iMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig' +
                'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIxOCIvPjx3OnN6Q3Mgdzp2YWw9IjE4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPntU' +
                'b3RhbFByaWNlOmN1cnJlbmN5fTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICA8L3c6dGJsPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2lu' +
                'ZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cj48dzpyUHI+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD' +
                'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+ey9PcHBvcnR1bml0eUxpbmVJdGVtc308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnBC' +
                'ZHI+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjYiIHc6c3BhY2U9IjEiIHc6Y29sb3I9IjFFM0E4QSIvPjwvdzpwQmRyPjx3OnNwYWNpbmcgdzph' +
                'ZnRlcj0iMjAwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjhG' +
                'QUZDIi8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIx' +
                'RTNBOEEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5TdW1tYXJ5PC93OnQ+PC93OnI+PC93OnA+CiAgICA8' +
                'dzp0Ymw+PHc6dGJsUHI+PHc6dGJsVyB3Onc9IjAiIHc6dHlwZT0iYXV0byIvPjx3OnRibEJvcmRlcnM+PHc6dG9wIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQi' +
                'IHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OmxlZnQgdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iRDFENURC' +
                'Ii8+PHc6Ym90dG9tIHc6dmFsPSJzaW5nbGUiIHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3OnJpZ2h0IHc6dmFsPSJzaW5nbGUi' +
                'IHc6c3o9IjQiIHc6c3BhY2U9IjAiIHc6Y29sb3I9IkQxRDVEQiIvPjx3Omluc2lkZUggdzp2YWw9InNpbmdsZSIgdzpzej0iNCIgdzpzcGFjZT0iMCIgdzpj' +
                'b2xvcj0iRDFENURCIi8+PHc6aW5zaWRlViB3OnZhbD0ic2luZ2xlIiB3OnN6PSI0IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6dGJsQm9y' +
                'ZGVycz48L3c6dGJsUHI+PHc6dGJsR3JpZD48dzpncmlkQ29sIHc6dz0iNjAwMCIvPjx3OmdyaWRDb2wgdzp3PSIzMzYwIi8+PC93OnRibEdyaWQ+CiAgICAg' +
                'IDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6dGNCb3JkZXJzPjx3OnRvcCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIv' +
                'Pjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAi' +
                'IHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpyaWdodCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwv' +
                'dzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9InJpZ2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0i' +
                'Mzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+SXRlbSBDb3VudDo8L3c6dD48L3c6cj48L3c6cD48' +
                'L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+' +
                'PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIgdzpzej0iMCIg' +
                'dzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PC93' +
                'OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIz' +
                'NzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57Q09VTlQ6T3Bwb3J0dW5pdHlMaW5lSXRlbXM6bnVt' +
                'YmVyfTwvdzp0PjwvdzpyPjwvdzpwPjwvdzp0Yz48L3c6dHI+CiAgICAgIDx3OnRyPjx3OnRjPjx3OnRjUHI+PHc6dGNCb3JkZXJzPjx3OnRvcCB3OnZhbD0i' +
                'bm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29s' +
                'b3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpyaWdodCB3OnZhbD0ibm9u' +
                'ZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwvdzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48dzpwUHI+PHc6amMgdzp2YWw9InJp' +
                'Z2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48' +
                'L3c6clByPjx3OnQ+QXZlcmFnZSBQcmljZTo8L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFs' +
                'PSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpj' +
                'b2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJu' +
                'b25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PC93OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0i' +
                'cmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIv' +
                'PjwvdzpyUHI+PHc6dD57QVZHOk9wcG9ydHVuaXR5TGluZUl0ZW1zLlVuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRy' +
                'PgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9yZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9' +
                'ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3' +
                'OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1' +
                'dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Ig' +
                'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0Pkxvd2VzdCBQcmljZTo8L3c6dD48L3c6' +
                'cj48L3c6cD48L3c6dGM+PHc6dGM+PHc6dGNQcj48dzp0Y0JvcmRlcnM+PHc6dG9wIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9y' +
                'PSJhdXRvIi8+PHc6bGVmdCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmJvdHRvbSB3OnZhbD0ibm9uZSIg' +
                'dzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OnJpZ2h0IHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJh' +
                'dXRvIi8+PC93OnRjQm9yZGVycz48L3c6dGNQcj48dzpwPjx3OnBQcj48dzpqYyB3OnZhbD0icmlnaHQiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9y' +
                'IHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57TUlOOk9wcG9ydHVuaXR5TGluZUl0' +
                'ZW1zLlVuaXRQcmljZTpjdXJyZW5jeX08L3c6dD48L3c6cj48L3c6cD48L3c6dGM+PC93OnRyPgogICAgICA8dzp0cj48dzp0Yz48dzp0Y1ByPjx3OnRjQm9y' +
                'ZGVycz48dzp0b3Agdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpsZWZ0IHc6dmFsPSJub25lIiB3OnN6PSIw' +
                'IiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+PHc6Ym90dG9tIHc6dmFsPSJub25lIiB3OnN6PSIwIiB3OnNwYWNlPSIwIiB3OmNvbG9yPSJhdXRvIi8+' +
                'PHc6cmlnaHQgdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48L3c6dGNCb3JkZXJzPjwvdzp0Y1ByPjx3OnA+PHc6' +
                'cFByPjx3OmpjIHc6dmFsPSJyaWdodCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3' +
                'OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PkhpZ2hlc3QgUHJpY2U6PC93OnQ+PC93OnI+PC93OnA+PC93OnRjPjx3OnRjPjx3OnRjUHI+PHc6dGNC' +
                'b3JkZXJzPjx3OnRvcCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjx3OmxlZnQgdzp2YWw9Im5vbmUiIHc6c3o9' +
                'IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8iLz48dzpib3R0b20gdzp2YWw9Im5vbmUiIHc6c3o9IjAiIHc6c3BhY2U9IjAiIHc6Y29sb3I9ImF1dG8i' +
                'Lz48dzpyaWdodCB3OnZhbD0ibm9uZSIgdzpzej0iMCIgdzpzcGFjZT0iMCIgdzpjb2xvcj0iYXV0byIvPjwvdzp0Y0JvcmRlcnM+PC93OnRjUHI+PHc6cD48' +
                'dzpwUHI+PHc6amMgdzp2YWw9InJpZ2h0Ii8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+' +
                'PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e01BWDpPcHBvcnR1bml0eUxpbmVJdGVtcy5Vbml0UHJpY2U6Y3VycmVuY3l9PC93OnQ+PC93OnI+' +
                'PC93OnA+PC93OnRjPjwvdzp0cj4KICAgIDwvdzp0Ymw+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48' +
                'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSIxRTNBOEEiLz48dzpqYyB3' +
                'OnZhbD0icmlnaHQiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIxMjAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Ig' +
                'dzp2YWw9IkZGRkZGRiIvPjx3OnN6IHc6dmFsPSIyOCIvPjx3OnN6Q3Mgdzp2YWw9IjI4Ii8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlRP' +
                'VEFMIERVRTogICB7U1VNOk9wcG9ydHVuaXR5TGluZUl0ZW1zLlRvdGFsUHJpY2U6Y3VycmVuY3l9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQ' +
                'cj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20g' +
                'dzp2YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48' +
                'L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+' +
                'PC93OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48' +
                'L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWX0gfCBQb3dlcmVkIGJ5IERvY0dlbjwvdzp0PjwvdzpyPjwvdzpw' +
                'PgogICAgPHc6c2VjdFByPgogICAgICA8dzpwZ1N6IHc6dz0iMTIyNDAiIHc6aD0iMTU4NDAiLz4KICAgICAgPHc6cGdNYXIgdzp0b3A9IjE0NDAiIHc6cmln' +
                'aHQ9IjE0NDAiIHc6Ym90dG9tPSIxNDQwIiB3OmxlZnQ9IjE0NDAiIHc6aGVhZGVyPSI3MjAiIHc6Zm9vdGVyPSI3MjAiIHc6Z3V0dGVyPSIwIi8+CiAgICA8' +
                'L3c6c2VjdFByPgogIDwvdzpib2R5Pgo8L3c6ZG9jdW1lbnQ+UEsBAhQDFAAAAAAAKTd4XNd5hOq4AQAAuAEAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50' +
                'X1R5cGVzXS54bWxQSwECFAMUAAAAAAApN3hcIBuG6i4BAAAuAQAACwAAAAAAAAAAAAAAgAHpAQAAX3JlbHMvLnJlbHNQSwECFAMUAAAAAAApN3hcjA6F0J0A' +
                'AACdAAAAHAAAAAAAAAAAAAAAgAFAAwAAd29yZC9fcmVscy9kb2N1bWVudC54bWwucmVsc1BLAQIUAxQAAAAAACk3eFxc6G9jCjkAAAo5AAARAAAAAAAAAAAA' +
                'AACAARcEAAB3b3JkL2RvY3VtZW50LnhtbFBLBQYAAAAABAAEAAMBAABQPQAAAAA='
        );

        // Template 5: Case Summary
        docxFiles.add(
            '' +
                'UEsDBBQAAAAAACk3eFzXeYTquAEAALgBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04IiBzdGFu' +
                'ZGFsb25lPSJ5ZXMiPz4KPFR5cGVzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L2NvbnRlbnQtdHlwZXMi' +
                'PgogIDxEZWZhdWx0IEV4dGVuc2lvbj0icmVscyIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1wYWNrYWdlLnJlbGF0aW9u' +
                'c2hpcHMreG1sIi8+CiAgPERlZmF1bHQgRXh0ZW5zaW9uPSJ4bWwiIENvbnRlbnRUeXBlPSJhcHBsaWNhdGlvbi94bWwiLz4KICA8T3ZlcnJpZGUgUGFydE5h' +
                'bWU9Ii93b3JkL2RvY3VtZW50LnhtbCIgQ29udGVudFR5cGU9ImFwcGxpY2F0aW9uL3ZuZC5vcGVueG1sZm9ybWF0cy1vZmZpY2Vkb2N1bWVudC53b3JkcHJv' +
                'Y2Vzc2luZ21sLmRvY3VtZW50Lm1haW4reG1sIi8+CjwvVHlwZXM+UEsDBBQAAAAAACk3eFwgG4bqLgEAAC4BAAALAAAAX3JlbHMvLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgogIDxSZWxhdGlvbnNoaXAgSWQ9InJJZDEiIFR5cGU9Imh0dHA6Ly9zY2hlbWFzLm9w' +
                'ZW54bWxmb3JtYXRzLm9yZy9vZmZpY2VEb2N1bWVudC8yMDA2L3JlbGF0aW9uc2hpcHMvb2ZmaWNlRG9jdW1lbnQiIFRhcmdldD0id29yZC9kb2N1bWVudC54' +
                'bWwiLz4KPC9SZWxhdGlvbnNoaXBzPlBLAwQUAAAAAAApN3hcjA6F0J0AAACdAAAAHAAAAHdvcmQvX3JlbHMvZG9jdW1lbnQueG1sLnJlbHM8P3htbCB2ZXJz' +
                'aW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+CjxSZWxhdGlvbnNoaXBzIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5vcGVueG1s' +
                'Zm9ybWF0cy5vcmcvcGFja2FnZS8yMDA2L3JlbGF0aW9uc2hpcHMiPgo8L1JlbGF0aW9uc2hpcHM+UEsDBBQAAAAAACk3eFw5Oib1VhsAAFYbAAARAAAAd29y' +
                'ZC9kb2N1bWVudC54bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCIgc3RhbmRhbG9uZT0ieWVzIj8+Cjx3OmRvY3VtZW50IHhtbG5zOndw' +
                'Yz0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9vZmZpY2Uvd29yZC8yMDEwL3dvcmRwcm9jZXNzaW5nQ2FudmFzIgogICAgICAgICAgICB4bWxuczpt' +
                'Yz0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3JnL21hcmt1cC1jb21wYXRpYmlsaXR5LzIwMDYiCiAgICAgICAgICAgIHhtbG5zOm89InVybjpz' +
                'Y2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOm9mZmljZSIKICAgICAgICAgICAgeG1sbnM6cj0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvcmVsYXRpb25zaGlwcyIKICAgICAgICAgICAgeG1sbnM6bT0iaHR0cDovL3NjaGVtYXMub3BlbnhtbGZvcm1hdHMub3Jn' +
                'L29mZmljZURvY3VtZW50LzIwMDYvbWF0aCIKICAgICAgICAgICAgeG1sbnM6dj0idXJuOnNjaGVtYXMtbWljcm9zb2Z0LWNvbTp2bWwiCiAgICAgICAgICAg' +
                'IHhtbG5zOndwPSJodHRwOi8vc2NoZW1hcy5vcGVueG1sZm9ybWF0cy5vcmcvZHJhd2luZ21sLzIwMDYvd29yZHByb2Nlc3NpbmdEcmF3aW5nIgogICAgICAg' +
                'ICAgICB4bWxuczp3MTA9InVybjpzY2hlbWFzLW1pY3Jvc29mdC1jb206b2ZmaWNlOndvcmQiCiAgICAgICAgICAgIHhtbG5zOnc9Imh0dHA6Ly9zY2hlbWFz' +
                'Lm9wZW54bWxmb3JtYXRzLm9yZy93b3JkcHJvY2Vzc2luZ21sLzIwMDYvbWFpbiIKICAgICAgICAgICAgeG1sbnM6d25lPSJodHRwOi8vc2NoZW1hcy5taWNy' +
                'b3NvZnQuY29tL29mZmljZS93b3JkLzIwMDYvd29yZG1sIgogICAgICAgICAgICBtYzpJZ25vcmFibGU9IncxNCB3cDE0Ij4KICA8dzpib2R5PgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iNjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9y' +
                'IHc6dmFsPSIxRTNBOEEiLz48dzpzeiB3OnZhbD0iNDgiLz48dzpzekNzIHc6dmFsPSI0OCIvPjwvdzpyUHI+PHc6dD5DQVNFIFJFUE9SVDwvdzp0Pjwvdzpy' +
                'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzphZnRlcj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQ' +
                'cj48dzppLz48dzpjb2xvciB3OnZhbD0iNkI3MjgwIi8+PHc6c3ogdzp2YWw9IjIyIi8+PHc6c3pDcyB3OnZhbD0iMjIiLz48L3c6clByPjx3OnQ+Q2FzZSAj' +
                'e0Nhc2VOdW1iZXJ9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpwQmRyPjx3OmJvdHRvbSB3OnZhbD0ic2luZ2xlIiB3OnN6PSI2IiB3' +
                'OnNwYWNlPSIxIiB3OmNvbG9yPSJEMUQ1REIiLz48L3c6cEJkcj48dzpzcGFjaW5nIHc6YWZ0ZXI9IjIwMCIvPjwvdzpwUHI+PC93OnA+CiAgICA8dzpwPjx3' +
                'OnBQcj48dzpzaGQgdzp2YWw9ImNsZWFyIiB3OmNvbG9yPSJhdXRvIiB3OmZpbGw9IkVGRjZGRiIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjI0MCIgdzphZnRl' +
                'cj0iMTIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMUUzQThBIi8+PHc6c3ogdzp2YWw9IjI2Ii8+PHc6c3pDcyB3OnZh' +
                'bD0iMjYiLz48L3c6clByPjx3OnQ+Q2FzZSBJbmZvcm1hdGlvbjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9y' +
                'ZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+' +
                'PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+U3ViamVjdDogPC93OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6' +
                'Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0PntTdWJqZWN0fTwvdzp0Pjwv' +
                'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpi' +
                'Lz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJw' +
                'cmVzZXJ2ZSI+U3RhdHVzOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD' +
                'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1N0YXR1c308L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9' +
                'IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3' +
                'OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPlByaW9yaXR5OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpj' +
                'b2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e1ByaW9yaXR5fTwvdzp0Pjwv' +
                'dzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpi' +
                'Lz48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJw' +
                'cmVzZXJ2ZSI+T3BlbmVkOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pD' +
                'cyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0NyZWF0ZWREYXRlOk1NTU0gZGQsIHl5eXl9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48' +
                'dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48' +
                'dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5DbG9zZWQ6IDwvdzp0Pjwvdzpy' +
                'Pjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIxMTE4MjciLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dD57' +
                'Q2xvc2VkRGF0ZTpNTS9kZC95eXl5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9' +
                'IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRUZGNkZGIi8+' +
                'PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVyPSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIxRTNBOEEi' +
                'Lz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFsPSIyNiIvPjwvdzpyUHI+PHc6dD5DdXN0b21lcjwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48' +
                'dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpiLz48dzpjb2xvciB3OnZhbD0iMzc0' +
                'MTUxIi8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+QWNjb3VudDogPC93' +
                'OnQ+PC93OnI+PHc6cj48dzpyUHI+PHc6Y29sb3Igdzp2YWw9IjExMTgyNyIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQ' +
                'cj48dzp0PntBY2NvdW50Lk5hbWV9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0i' +
                'NDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIy' +
                'MCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj5Db250YWN0OiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTEx' +
                'ODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQ+e0NvbnRhY3QuTmFtZX08L3c6dD48L3c6cj48L3c6cD4K' +
                'ICAgIDx3OnA+PHc6cFByPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjQwIiB3OmFmdGVyPSI0MCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Ig' +
                'dzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIyMCIvPjx3OnN6Q3Mgdzp2YWw9IjIwIi8+PC93OnJQcj48dzp0IHhtbDpzcGFjZT0icHJlc2VydmUiPkVt' +
                'YWlsOiA8L3c6dD48L3c6cj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMTExODI3Ii8+PHc6c3ogdzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAi' +
                'Lz48L3c6clByPjx3OnQ+e0NvbnRhY3QuRW1haWx9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIg' +
                'dzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJF' +
                'RkY2RkYiLz48dzpzcGFjaW5nIHc6YmVmb3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9' +
                'IjFFM0E4QSIvPjx3OnN6IHc6dmFsPSIyNiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkRlc2NyaXB0aW9uPC93OnQ+PC93OnI+PC93OnA+' +
                'CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzphZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFs' +
                'PSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIyMCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57RGVzY3Jp' +
                'cHRpb259PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwv' +
                'dzpwPgogICAgPHc6cD48dzpwUHI+PHc6c2hkIHc6dmFsPSJjbGVhciIgdzpjb2xvcj0iYXV0byIgdzpmaWxsPSJGM0Y0RjYiLz48dzpzcGFjaW5nIHc6YmVm' +
                'b3JlPSIyNDAiIHc6YWZ0ZXI9IjEyMCIvPjwvdzpwUHI+PHc6cj48dzpyUHI+PHc6Yi8+PHc6Y29sb3Igdzp2YWw9IjM3NDE1MSIvPjx3OnN6IHc6dmFsPSIy' +
                'NiIvPjx3OnN6Q3Mgdzp2YWw9IjI2Ii8+PC93OnJQcj48dzp0PkJhcmNvZGUgKENvZGUgMTI4KTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6cD48dzpwUHI+' +
                'PHc6c3BhY2luZyB3OmJlZm9yZT0iNDAiIHc6YWZ0ZXI9IjQwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48dzpjb2xvciB3OnZhbD0iMzc0MTUxIi8+PHc6c3og' +
                'dzp2YWw9IjIwIi8+PHc6c3pDcyB3OnZhbD0iMjAiLz48L3c6clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+eypDYXNlTnVtYmVyfTwvdzp0Pjwvdzpy' +
                'PjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6c3BhY2luZyB3OmJlZm9yZT0iNjAiIHc6YWZ0ZXI9IjYwIi8+PC93OnBQcj48L3c6cD4KICAgIDx3OnA+PHc6' +
                'cFByPjx3OnNoZCB3OnZhbD0iY2xlYXIiIHc6Y29sb3I9ImF1dG8iIHc6ZmlsbD0iRjNGNEY2Ii8+PHc6c3BhY2luZyB3OmJlZm9yZT0iMjQwIiB3OmFmdGVy' +
                'PSIxMjAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmIvPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjYiLz48dzpzekNzIHc6dmFs' +
                'PSIyNiIvPjwvdzpyUHI+PHc6dD5RUiBDb2RlPC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48dzpzcGFjaW5nIHc6YmVmb3JlPSI0MCIgdzph' +
                'ZnRlcj0iNDAiLz48L3c6cFByPjx3OnI+PHc6clByPjx3OmNvbG9yIHc6dmFsPSIzNzQxNTEiLz48dzpzeiB3OnZhbD0iMjAiLz48dzpzekNzIHc6dmFsPSIy' +
                'MCIvPjwvdzpyUHI+PHc6dCB4bWw6c3BhY2U9InByZXNlcnZlIj57KkNhc2VOdW1iZXI6cXJ9PC93OnQ+PC93OnI+PC93OnA+CiAgICA8dzpwPjx3OnBQcj48' +
                'dzpzcGFjaW5nIHc6YmVmb3JlPSI2MCIgdzphZnRlcj0iNjAiLz48L3c6cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6cEJkcj48dzpib3R0b20gdzp2' +
                'YWw9InNpbmdsZSIgdzpzej0iNiIgdzpzcGFjZT0iMSIgdzpjb2xvcj0iRDFENURCIi8+PC93OnBCZHI+PHc6c3BhY2luZyB3OmFmdGVyPSIyMDAiLz48L3c6' +
                'cFByPjwvdzpwPgogICAgPHc6cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93' +
                'OnBQcj48dzpyPjx3OnJQcj48dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6' +
                'clByPjx3OnQgeG1sOnNwYWNlPSJwcmVzZXJ2ZSI+R2VuZXJhdGVkIG9uIHtUT0RBWTpNTU1NIGRkLCB5eXl5fTwvdzp0PjwvdzpyPjwvdzpwPgogICAgPHc6' +
                'cD48dzpwUHI+PHc6amMgdzp2YWw9ImNlbnRlciIvPjx3OnNwYWNpbmcgdzpiZWZvcmU9IjYwIiB3OmFmdGVyPSIwIi8+PC93OnBQcj48dzpyPjx3OnJQcj48' +
                'dzppLz48dzpjb2xvciB3OnZhbD0iOUNBM0FGIi8+PHc6c3ogdzp2YWw9IjE2Ii8+PHc6c3pDcyB3OnZhbD0iMTYiLz48L3c6clByPjx3OnQgeG1sOnNwYWNl' +
                'PSJwcmVzZXJ2ZSI+UG93ZXJlZCBieSBEb2NHZW48L3c6dD48L3c6cj48L3c6cD4KICAgIDx3OnNlY3RQcj4KICAgICAgPHc6cGdTeiB3Onc9IjEyMjQwIiB3' +
                'Omg9IjE1ODQwIi8+CiAgICAgIDx3OnBnTWFyIHc6dG9wPSIxNDQwIiB3OnJpZ2h0PSIxNDQwIiB3OmJvdHRvbT0iMTQ0MCIgdzpsZWZ0PSIxNDQwIiB3Omhl' +
                'YWRlcj0iNzIwIiB3OmZvb3Rlcj0iNzIwIiB3Omd1dHRlcj0iMCIvPgogICAgPC93OnNlY3RQcj4KICA8L3c6Ym9keT4KPC93OmRvY3VtZW50PlBLAQIUAxQA' +
                'AAAAACk3eFzXeYTquAEAALgBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAAAKTd4XCAbhuouAQAALgEAAAsAAAAA' +
                'AAAAAAAAAIAB6QEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAAAKTd4XIwOhdCdAAAAnQAAABwAAAAAAAAAAAAAAIABQAMAAHdvcmQvX3JlbHMvZG9jdW1lbnQu' +
                'eG1sLnJlbHNQSwECFAMUAAAAAAApN3hcOTom9VYbAABWGwAAEQAAAAAAAAAAAAAAgAEXBAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAQABAADAQAAnB8A' +
                'AAAA'
        );

        // ---- Create records ----
        List<DocGen_Template__c> templates = new List<DocGen_Template__c>();
        for (Map<String, String> d : defs) {
            templates.add(
                new DocGen_Template__c(
                    Name = d.get('name'),
                    Base_Object_API__c = d.get('object'),
                    Type__c = 'Word',
                    Output_Format__c = 'PDF',
                    Query_Config__c = d.get('config'),
                    Category__c = d.get('category'),
                    Description__c = d.get('desc')
                )
            );
        }
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            templates,
            new Set<String>{
                'Name',
                'Base_Object_API__c',
                'Type__c',
                'Output_Format__c',
                'Query_Config__c',
                'Category__c',
                'Description__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(templates, AccessLevel.SYSTEM_MODE);

        // Create ContentVersions (DOCX files) linked to templates
        List<ContentVersion> cvs = new List<ContentVersion>();
        for (Integer i = 0; i < templates.size(); i++) {
            cvs.add(
                new ContentVersion(
                    Title = templates[i].Name,
                    PathOnClient = templates[i].Name.replaceAll('[^a-zA-Z0-9]', '_') + '.docx',
                    VersionData = EncodingUtil.base64Decode(docxFiles[i]),
                    IsMajorVersion = true,
                    FirstPublishLocationId = templates[i].Id
                )
            );
        }
        SObjectAccessDecision cvsDec = Security.stripInaccessible(AccessType.CREATABLE, cvs);
        insert cvsDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        for (Integer i = 0; i < cvs.size(); i++) {
            cvs[i].Id = cvsDec.getRecords()[i].Id;
        }

        // Create active template versions with snapshot headers
        List<DocGen_Template_Version__c> versions = new List<DocGen_Template_Version__c>();
        for (Integer i = 0; i < templates.size(); i++) {
            versions.add(
                new DocGen_Template_Version__c(
                    Template__c = templates[i].Id,
                    Content_Version_Id__c = cvs[i].Id,
                    Is_Active__c = true,
                    Query_Config__c = templates[i].Query_Config__c,
                    Category__c = templates[i].Category__c,
                    Description__c = templates[i].Description__c,
                    Type__c = templates[i].Type__c,
                    Base_Object_API__c = templates[i].Base_Object_API__c
                )
            );
        }
        // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
        DocGenFlsGuard.assertCreateable(
            versions,
            new Set<String>{
                'Template__c',
                'Content_Version_Id__c',
                'Is_Active__c',
                'Query_Config__c',
                'Category__c',
                'Description__c',
                'Type__c',
                'Base_Object_API__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        Database.insert(versions, AccessLevel.SYSTEM_MODE);

        // Extract and save template images for PDF rendering — async (12 MB heap).
        for (Integer i = 0; i < versions.size(); i++) {
            DocGenService.enqueueTemplateImageExtraction(templates[i].Id, versions[i].Id);
        }

        return templates.size();
    }

    @AuraEnabled(cacheable=true)
    public static String getOrgId() {
        return UserInfo.getOrganizationId();
    }

    // =========================================================================
    // Template Import / Export
    // =========================================================================

    /**
     * Exports a template and its active version as a portable JSON bundle.
     * Includes template metadata, query config, saved queries, and the
     * template file (DOCX/XLSX/PPTX) as base64. Pre-decomposed XML parts
     * and images are NOT included — they are regenerated on import.
     */
    private static final Pattern SHEPHERD_CV_URL_PATTERN = Pattern.compile(
        '/sfc/servlet\\.shepherd/version/download/(068[A-Za-z0-9]{12,15})'
    );

    @TestVisible
    private static Set<Id> extractShepherdCvIds(String text) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(text))
            return ids;
        Matcher m = SHEPHERD_CV_URL_PATTERN.matcher(text);
        while (m.find()) {
            try {
                ids.add(Id.valueOf(m.group(1)));
            } catch (Exception ignored) {
                // Malformed match — skip.
            }
        }
        return ids;
    }

    @TestVisible
    private static String rewriteShepherdCvIds(String text, Map<String, String> oldToNew) {
        if (String.isBlank(text) || oldToNew == null || oldToNew.isEmpty())
            return text;
        String result = text;
        for (String oldId : oldToNew.keySet()) {
            String newId = oldToNew.get(oldId);
            if (String.isBlank(newId))
                continue;
            // Match the 15-char or 18-char ID form; replace just the ID, not
            // the surrounding URL prefix, so we don't disturb authored markup.
            result = result.replace(
                '/sfc/servlet.shepherd/version/download/' + oldId,
                '/sfc/servlet.shepherd/version/download/' + newId
            );
        }
        return result;
    }

    @AuraEnabled
    public static String exportTemplate(Id templateId) {
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{
                    'Name',
                    'Base_Object_API__c',
                    'Type__c',
                    'Output_Format__c',
                    'Category__c',
                    'Description__c',
                    'Query_Config__c',
                    'Document_Title_Format__c',
                    'Is_Default__c',
                    'Is_Active__c',
                    'Header_Html__c',
                    'Footer_Html__c',
                    'Test_Record_Id__c',
                    'Sort_Order__c',
                    'Lock_Output_Format__c',
                    'Specific_Record_Ids__c',
                    'Required_Permission_Sets__c',
                    'Record_Filter__c',
                    'Page_Orientation__c',
                    'Page_Size__c',
                    'Page_Margins__c',
                    'Custom_Margins__c',
                    'API_Name__c',
                    'Signer_Verification__c',
                    'Prefill_Signer_Email__c',
                    'Show_Signer_Decline__c',
                    'Default_Email_Message__c',
                    'Form_Fields_Config__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> templates = [
                SELECT
                    Name,
                    Base_Object_API__c,
                    Type__c,
                    Output_Format__c,
                    Category__c,
                    Description__c,
                    Query_Config__c,
                    Document_Title_Format__c,
                    Is_Default__c,
                    Is_Active__c,
                    Header_Html__c,
                    Footer_Html__c,
                    Test_Record_Id__c,
                    Sort_Order__c,
                    Lock_Output_Format__c,
                    Specific_Record_Ids__c,
                    Required_Permission_Sets__c,
                    Record_Filter__c,
                    Page_Orientation__c,
                    Page_Size__c,
                    Page_Margins__c,
                    Custom_Margins__c,
                    API_Name__c,
                    Signer_Verification__c,
                    Prefill_Signer_Email__c,
                    Show_Signer_Decline__c,
                    Default_Email_Message__c,
                    Form_Fields_Config__c,
                    (
                        SELECT
                            Id,
                            Is_Active__c,
                            Query_Config__c,
                            Content_Version_Id__c,
                            Category__c,
                            Description__c,
                            Type__c,
                            Base_Object_API__c,
                            Page_Orientation__c,
                            Page_Size__c,
                            Page_Margins__c,
                            Custom_Margins__c,
                            Watermark_Image_CV_Id__c
                        FROM Versions__r
                        WHERE Is_Active__c = TRUE
                        LIMIT 1
                    ),
                    (SELECT Name, Query_Condition__c, Description__c FROM Saved_Queries__r)
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (templates.isEmpty()) {
                throw new DocGenException('Template not found or not accessible.');
            }
            DocGen_Template__c tmpl = templates[0];

            Map<String, Object> bundle = new Map<String, Object>();
            bundle.put('docgenExportVersion', '1');
            bundle.put('exportDate', String.valueOf(Date.today()));

            // Template metadata
            Map<String, Object> tmplData = new Map<String, Object>();
            tmplData.put('Name', tmpl.Name);
            tmplData.put('Base_Object_API__c', tmpl.Base_Object_API__c);
            tmplData.put('Type__c', tmpl.Type__c);
            tmplData.put('Output_Format__c', tmpl.Output_Format__c);
            tmplData.put('Category__c', tmpl.Category__c);
            tmplData.put('Description__c', tmpl.Description__c);
            tmplData.put('Query_Config__c', tmpl.Query_Config__c);
            tmplData.put('Document_Title_Format__c', tmpl.Document_Title_Format__c);
            tmplData.put('Is_Default__c', tmpl.Is_Default__c);
            tmplData.put('Is_Active__c', tmpl.Is_Active__c);
            tmplData.put('Header_Html__c', tmpl.Header_Html__c);
            tmplData.put('Footer_Html__c', tmpl.Footer_Html__c);
            tmplData.put('Test_Record_Id__c', tmpl.Test_Record_Id__c);
            tmplData.put('Sort_Order__c', tmpl.Sort_Order__c);
            tmplData.put('Lock_Output_Format__c', tmpl.Lock_Output_Format__c);
            tmplData.put('Specific_Record_Ids__c', tmpl.Specific_Record_Ids__c);
            tmplData.put('Required_Permission_Sets__c', tmpl.Required_Permission_Sets__c);
            tmplData.put('Record_Filter__c', tmpl.Record_Filter__c);
            tmplData.put('Page_Orientation__c', tmpl.Page_Orientation__c);
            tmplData.put('Page_Size__c', tmpl.Page_Size__c);
            tmplData.put('Page_Margins__c', tmpl.Page_Margins__c);
            tmplData.put('Custom_Margins__c', tmpl.Custom_Margins__c);
            tmplData.put('API_Name__c', tmpl.API_Name__c);
            tmplData.put('Signer_Verification__c', tmpl.Signer_Verification__c);
            tmplData.put('Prefill_Signer_Email__c', tmpl.Prefill_Signer_Email__c);
            tmplData.put('Show_Signer_Decline__c', tmpl.Show_Signer_Decline__c);
            tmplData.put('Default_Email_Message__c', tmpl.Default_Email_Message__c);
            tmplData.put('Form_Fields_Config__c', tmpl.Form_Fields_Config__c);
            bundle.put('template', tmplData);

            // Active version's template file
            String htmlBodyText = null;
            DocGen_Template_Version__c ver = null;
            if (!tmpl.Versions__r.isEmpty()) {
                ver = tmpl.Versions__r[0];
                if (String.isNotBlank(ver.Content_Version_Id__c)) {
                    // FLS-guard + SYSTEM_MODE, NOT USER_MODE. Template-internal CVs
                    // (docgen_html_body_*, the uploaded template file) carry
                    // ContentDocumentLinks that default to Visibility=InternalUsers,
                    // which USER_MODE reads silently drop — the #114 quirk. Under
                    // USER_MODE this returned empty and the export produced a bundle
                    // with NO body at all, so the clone was created blank with no error.
                    DocGenFlsGuard.assertAccessible(
                        ContentVersion.sObjectType,
                        new Set<String>{ 'VersionData', 'FileExtension', 'Title' }
                    );
                    /* code-analyzer-suppress ApexFlsViolation */
                    List<ContentVersion> cvs = [
                        SELECT VersionData, FileExtension, Title
                        FROM ContentVersion
                        WHERE Id = :ver.Content_Version_Id__c
                        WITH SYSTEM_MODE
                        LIMIT 1 // NOPMD — internal template file read
                    ];
                    if (!cvs.isEmpty()) {
                        Map<String, Object> fileData = new Map<String, Object>();
                        fileData.put('fileName', cvs[0].Title);
                        fileData.put('fileExtension', cvs[0].FileExtension);
                        fileData.put('base64', EncodingUtil.base64Encode(cvs[0].VersionData));
                        bundle.put('templateFile', fileData);
                        // For HTML templates, the body bytes are HTML text containing
                        // shepherd URLs that reference inline-image CVs — capture the
                        // text so we can scan it for asset IDs below.
                        if (DocGenService.isHtmlBacked(tmpl.Type__c)) {
                            htmlBodyText = cvs[0].VersionData.toString();
                        }
                    }
                }
            }

            // Collect every ContentVersion ID referenced by:
            //   - <img src="/sfc/servlet.shepherd/version/download/{cvId}"> in
            //     Header_Html__c, Footer_Html__c, or the HTML body
            //   - The active version's Watermark_Image_CV_Id__c
            // Then bundle each as an `asset` with its base64 bytes so the import
            // side can re-upload them and rewrite URLs to the new CV IDs.
            Set<Id> assetCvIds = new Set<Id>();
            assetCvIds.addAll(extractShepherdCvIds(tmpl.Header_Html__c));
            assetCvIds.addAll(extractShepherdCvIds(tmpl.Footer_Html__c));
            assetCvIds.addAll(extractShepherdCvIds(htmlBodyText));

            // Also sweep in every image the Designer's picker knows about, whether or
            // not the current body happens to reference it. Scanning only for shepherd
            // URLs missed images that were uploaded but not (yet) placed, or placed via
            // a URL form the regex doesn't match — so a clone silently lost them and the
            // author had to re-upload. Same title convention listHtmlTemplateImages uses.
            if (DocGenService.isHtmlBacked(tmpl.Type__c)) {
                String imgPrefix = 'docgen_html_img_' + templateId + '%';
                DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'IsLatest' });
                /* code-analyzer-suppress ApexFlsViolation */
                for (ContentVersion imgCv : [
                    SELECT Id
                    FROM ContentVersion
                    WHERE Title LIKE :imgPrefix AND IsLatest = TRUE
                    WITH SYSTEM_MODE
                    LIMIT 200
                ]) {
                    assetCvIds.add(imgCv.Id);
                }
            }
            Id watermarkCvId = null;
            if (ver != null && String.isNotBlank(ver.Watermark_Image_CV_Id__c)) {
                try {
                    watermarkCvId = Id.valueOf(ver.Watermark_Image_CV_Id__c);
                    assetCvIds.add(watermarkCvId);
                } catch (Exception ignored) {
                    // Malformed CV ID — skip, don't fail the whole export.
                }
            }
            if (!assetCvIds.isEmpty()) {
                // SYSTEM_MODE for the same #114 reason as the template-file read above —
                // these CVs are linked to the template with Visibility=InternalUsers.
                DocGenFlsGuard.assertAccessible(
                    ContentVersion.sObjectType,
                    new Set<String>{ 'Title', 'FileExtension', 'VersionData' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                List<ContentVersion> assetCvs = [
                    SELECT Id, Title, FileExtension, VersionData
                    FROM ContentVersion
                    WHERE Id IN :assetCvIds
                    WITH SYSTEM_MODE
                ]; // NOPMD ApexCRUDViolation — referenced by template content; gated by template access
                List<Map<String, Object>> assets = new List<Map<String, Object>>();
                for (ContentVersion cv : assetCvs) {
                    Map<String, Object> asset = new Map<String, Object>();
                    asset.put('originalCvId', String.valueOf(cv.Id));
                    asset.put('fileName', cv.Title);
                    asset.put('fileExtension', cv.FileExtension);
                    asset.put('base64', EncodingUtil.base64Encode(cv.VersionData));
                    assets.add(asset);
                }
                bundle.put('assets', assets);
            }
            if (watermarkCvId != null) {
                bundle.put('watermarkOriginalCvId', String.valueOf(watermarkCvId));
            }

            // Saved queries
            if (!tmpl.Saved_Queries__r.isEmpty()) {
                List<Map<String, String>> queries = new List<Map<String, String>>();
                for (DocGen_Saved_Query__c sq : tmpl.Saved_Queries__r) {
                    Map<String, String> q = new Map<String, String>();
                    q.put('Name', sq.Name);
                    q.put('Query_Condition__c', sq.Query_Condition__c);
                    q.put('Description__c', sq.Description__c);
                    queries.add(q);
                }
                bundle.put('savedQueries', queries);
            }

            return JSON.serialize(bundle);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error exporting template.');
        }
    }

    /**
     * Imports a template from a JSON bundle produced by exportTemplate().
     * Creates the template record, uploads the file, creates an active
     * version, and triggers image extraction / pre-decomposition.
     * @return The new template record ID
     */
    /**
     * Rewrites a Designer image asset's title so it points at the importing org's
     * template instead of the source template.
     *
     * `listHtmlTemplateImages` finds a template's images purely by the
     * `docgen_html_img_<templateId>_` title prefix — there is no ContentDocumentLink
     * scoping — so a copied asset that keeps its original title is invisible to the
     * new template and simultaneously shows up (duplicated) under the old one.
     * Titles that don't follow the convention are left alone.
     */
    @TestVisible
    private static String retitleHtmlImageAsset(String originalTitle, Id newTemplateId, String originalCvId) {
        if (String.isBlank(originalTitle)) {
            return 'asset_' + originalCvId;
        }
        if (!originalTitle.startsWith('docgen_html_img_')) {
            return originalTitle;
        }
        // docgen_html_img_<15-or-18-char templateId>_<remainder>
        Matcher m = Pattern.compile('^docgen_html_img_[a-zA-Z0-9]{15,18}_').matcher(originalTitle);
        if (!m.find()) {
            return originalTitle;
        }
        return 'docgen_html_img_' + newTemplateId + '_' + originalTitle.substring(m.end());
    }

    @AuraEnabled
    public static Id importTemplate(String jsonData) {
        try {
            Map<String, Object> bundle = (Map<String, Object>) JSON.deserializeUntyped(jsonData);
            Map<String, Object> tmplData = (Map<String, Object>) bundle.get('template');
            if (tmplData == null) {
                throw new DocGenException('Invalid import file: missing template data.');
            }

            // 1. Create template record
            DocGen_Template__c tmpl = new DocGen_Template__c();
            tmpl.Name = (String) tmplData.get('Name');
            tmpl.Base_Object_API__c = (String) tmplData.get('Base_Object_API__c');
            tmpl.Type__c = (String) tmplData.get('Type__c');
            tmpl.Output_Format__c = (String) tmplData.get('Output_Format__c');
            tmpl.Category__c = (String) tmplData.get('Category__c');
            tmpl.Description__c = (String) tmplData.get('Description__c');
            tmpl.Query_Config__c = (String) tmplData.get('Query_Config__c');
            tmpl.Document_Title_Format__c = (String) tmplData.get('Document_Title_Format__c');
            tmpl.Is_Default__c = tmplData.get('Is_Default__c') == true;
            // Default to true if the export bundle predates the Is_Active__c field (older
            // exports won't include the key, and silently flipping the new template inactive
            // would surprise the importing user).
            tmpl.Is_Active__c = tmplData.containsKey('Is_Active__c') ? tmplData.get('Is_Active__c') == true : true;
            tmpl.Header_Html__c = (String) tmplData.get('Header_Html__c');
            tmpl.Footer_Html__c = (String) tmplData.get('Footer_Html__c');
            tmpl.Test_Record_Id__c = (String) tmplData.get('Test_Record_Id__c');
            Object sortOrderObj = tmplData.get('Sort_Order__c');
            if (sortOrderObj != null) {
                tmpl.Sort_Order__c = Decimal.valueOf(String.valueOf(sortOrderObj));
            }
            tmpl.Lock_Output_Format__c = tmplData.get('Lock_Output_Format__c') == true;
            tmpl.Specific_Record_Ids__c = (String) tmplData.get('Specific_Record_Ids__c');
            tmpl.Required_Permission_Sets__c = (String) tmplData.get('Required_Permission_Sets__c');
            tmpl.Record_Filter__c = (String) tmplData.get('Record_Filter__c');
            tmpl.Page_Orientation__c = (String) tmplData.get('Page_Orientation__c');
            tmpl.Page_Size__c = (String) tmplData.get('Page_Size__c');
            tmpl.Page_Margins__c = (String) tmplData.get('Page_Margins__c');
            tmpl.Custom_Margins__c = (String) tmplData.get('Custom_Margins__c');
            tmpl.Signer_Verification__c = (String) tmplData.get('Signer_Verification__c');
            tmpl.Prefill_Signer_Email__c = (String) tmplData.get('Prefill_Signer_Email__c');
            tmpl.Show_Signer_Decline__c = tmplData.get('Show_Signer_Decline__c') == true;
            tmpl.Default_Email_Message__c = (String) tmplData.get('Default_Email_Message__c');
            tmpl.Form_Fields_Config__c = (String) tmplData.get('Form_Fields_Config__c');
            // API_Name__c is unique — keep it (the whole point is a stable key
            // across orgs) unless another template in this org already owns it.
            String importedApiName = (String) tmplData.get('API_Name__c');
            if (String.isNotBlank(importedApiName)) {
                /* code-analyzer-suppress ApexFlsViolation */
                Integer taken = [
                    SELECT COUNT()
                    FROM DocGen_Template__c
                    WHERE API_Name__c = :importedApiName
                    WITH SYSTEM_MODE
                ];
                if (taken == 0) {
                    tmpl.API_Name__c = importedApiName;
                }
            }
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(tmpl, AccessLevel.USER_MODE);

            // 1.5. Re-upload inline-image / watermark assets and build the
            // source-org → target-org CV ID map. Done BEFORE the template body
            // is uploaded so we can rewrite any shepherd URLs the body
            // contains (ContentVersion.VersionData is immutable post-insert —
            // rewriting after upload would need a v2 ContentVersion).
            Map<String, String> cvIdMap = new Map<String, String>();
            List<Object> assets = (List<Object>) bundle.get('assets');
            if (assets != null && !assets.isEmpty()) {
                List<ContentVersion> assetCvs = new List<ContentVersion>();
                List<String> originalIds = new List<String>();
                for (Object aObj : assets) {
                    Map<String, Object> asset = (Map<String, Object>) aObj;
                    String b64 = (String) asset.get('base64');
                    if (String.isBlank(b64))
                        continue;
                    String origId = (String) asset.get('originalCvId');
                    String fileName = (String) asset.get('fileName');
                    String ext = (String) asset.get('fileExtension');
                    ContentVersion acv = new ContentVersion();
                    // Re-key Designer image assets to the NEW template. Their titles encode
                    // the source template Id (docgen_html_img_<templateId>_<ts>_<name>) and
                    // listHtmlTemplateImages matches on that prefix alone, with no parent
                    // scoping — so copying the title verbatim left the clone's image picker
                    // empty AND polluted the SOURCE template's picker with the duplicates.
                    acv.Title = retitleHtmlImageAsset(fileName, tmpl.Id, origId);
                    acv.PathOnClient = acv.Title + (String.isNotBlank(ext) ? ('.' + ext) : '');
                    acv.VersionData = EncodingUtil.base64Decode(b64);
                    acv.FirstPublishLocationId = tmpl.Id;
                    assetCvs.add(acv);
                    originalIds.add(origId);
                }
                if (!assetCvs.isEmpty()) {
                    SObjectAccessDecision assetDec = Security.stripInaccessible(AccessType.CREATABLE, assetCvs);
                    /* code-analyzer-suppress ApexFlsViolation */
                    insert assetDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                    List<ContentVersion> inserted = (List<ContentVersion>) assetDec.getRecords();
                    for (Integer i = 0; i < inserted.size(); i++) {
                        cvIdMap.put(originalIds[i], String.valueOf(inserted[i].Id));
                    }
                }
            }

            // 1.6. If any asset URLs were referenced in Header_Html__c or
            // Footer_Html__c, rewrite them to point at the newly-inserted CVs.
            if (!cvIdMap.isEmpty()) {
                String rewrittenHeader = rewriteShepherdCvIds(tmpl.Header_Html__c, cvIdMap);
                String rewrittenFooter = rewriteShepherdCvIds(tmpl.Footer_Html__c, cvIdMap);
                if (rewrittenHeader != tmpl.Header_Html__c || rewrittenFooter != tmpl.Footer_Html__c) {
                    tmpl.Header_Html__c = rewrittenHeader;
                    tmpl.Footer_Html__c = rewrittenFooter;
                    /* code-analyzer-suppress ApexFlsViolation */
                    Database.update(tmpl, AccessLevel.USER_MODE);
                }
            }

            // 2. Upload template file if present
            Map<String, Object> fileData = (Map<String, Object>) bundle.get('templateFile');
            String cvId = null;
            if (fileData != null && String.isNotBlank((String) fileData.get('base64'))) {
                ContentVersion cv = new ContentVersion();
                // HTML bodies MUST keep the docgen_html_body_<templateId>_<ts> convention:
                // getHtmlTemplateBody finds the body by that title prefix, so titling it
                // tmpl.Name meant an imported/cloned HTML template rendered fine but opened
                // with a BLANK Designer canvas — and the first Save wrote that blank back
                // over the real body.
                cv.Title = DocGenService.isHtmlBacked(tmpl.Type__c)
                    ? 'docgen_html_body_' + tmpl.Id + '_' + Datetime.now().getTime()
                    : tmpl.Name;
                cv.PathOnClient = tmpl.Name + '.' + (String) fileData.get('fileExtension');
                Blob bodyBytes = EncodingUtil.base64Decode((String) fileData.get('base64'));
                // For HTML templates, rewrite embedded shepherd URLs in the body
                // bytes BEFORE upload (ContentVersion.VersionData is immutable
                // post-insert). Word/Excel/PowerPoint templates carry their
                // image references inside docx-internal relationships, not
                // shepherd URLs, so they pass through untouched.
                if (DocGenService.isHtmlBacked(tmpl.Type__c) && !cvIdMap.isEmpty()) {
                    String htmlBody = bodyBytes.toString();
                    String rewrittenBody = rewriteShepherdCvIds(htmlBody, cvIdMap);
                    if (rewrittenBody != htmlBody) {
                        bodyBytes = Blob.valueOf(rewrittenBody);
                    }
                }
                cv.VersionData = bodyBytes;
                cv.FirstPublishLocationId = tmpl.Id;
                SObjectAccessDecision impCvDec = Security.stripInaccessible(
                    AccessType.CREATABLE,
                    new List<ContentVersion>{ cv }
                );
                insert impCvDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                cv.Id = impCvDec.getRecords()[0].Id;
                cvId = cv.Id;
            }

            // 3. Create active version
            DocGen_Template_Version__c ver = new DocGen_Template_Version__c();
            ver.Template__c = tmpl.Id;
            ver.Is_Active__c = true;
            ver.Content_Version_Id__c = cvId;
            ver.Query_Config__c = (String) tmplData.get('Query_Config__c');
            ver.Category__c = (String) tmplData.get('Category__c');
            ver.Description__c = (String) tmplData.get('Description__c');
            ver.Type__c = (String) tmplData.get('Type__c');
            ver.Base_Object_API__c = (String) tmplData.get('Base_Object_API__c');
            // saveTemplate snapshots these four onto every version it creates; import
            // did not, so the imported version was an incomplete render snapshot. It
            // matters twice over: the renderer prefers version values over template
            // values, and activateVersion pushes version fields BACK onto the template —
            // so re-activating an imported version blanked the template's output format,
            // header, footer, and title format.
            ver.Output_Format__c = (String) tmplData.get('Output_Format__c');
            // Read header/footer off tmpl, NOT tmplData — step 1.6 already rewrote their
            // shepherd URLs to the newly-inserted CV Ids. The raw bundle values still
            // point at the SOURCE org's CVs and would render broken images.
            ver.Header_Html__c = tmpl.Header_Html__c;
            ver.Footer_Html__c = tmpl.Footer_Html__c;
            ver.Document_Title_Format__c = (String) tmplData.get('Document_Title_Format__c');
            // Snapshot page-setup onto the version so the renderer reads the imported
            // settings instead of the org-default field values (the A4 → Letter bug).
            ver.Page_Orientation__c = (String) tmplData.get('Page_Orientation__c');
            ver.Page_Size__c = (String) tmplData.get('Page_Size__c');
            ver.Page_Margins__c = (String) tmplData.get('Page_Margins__c');
            ver.Custom_Margins__c = (String) tmplData.get('Custom_Margins__c');
            // If the export bundle named a watermark CV and we re-uploaded it as
            // an asset, wire the version's watermark field to the new CV ID.
            String watermarkOriginalCvId = (String) bundle.get('watermarkOriginalCvId');
            if (String.isNotBlank(watermarkOriginalCvId) && cvIdMap.containsKey(watermarkOriginalCvId)) {
                ver.Watermark_Image_CV_Id__c = cvIdMap.get(watermarkOriginalCvId);
            }
            // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
            DocGenFlsGuard.assertCreateable(
                ver,
                new Set<String>{
                    'Template__c',
                    'Is_Active__c',
                    'Content_Version_Id__c',
                    'Query_Config__c',
                    'Category__c',
                    'Description__c',
                    'Type__c',
                    'Base_Object_API__c',
                    'Page_Orientation__c',
                    'Page_Size__c',
                    'Page_Margins__c',
                    'Custom_Margins__c',
                    'Watermark_Image_CV_Id__c',
                    'Output_Format__c',
                    'Header_Html__c',
                    'Footer_Html__c',
                    'Document_Title_Format__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(ver, AccessLevel.SYSTEM_MODE);

            // 4. Extract images and pre-decompose — async (12 MB heap).
            DocGenService.enqueueTemplateImageExtraction(tmpl.Id, ver.Id);

            // 5. Create saved queries if present
            List<Object> savedQueries = (List<Object>) bundle.get('savedQueries');
            if (savedQueries != null && !savedQueries.isEmpty()) {
                List<DocGen_Saved_Query__c> sqs = new List<DocGen_Saved_Query__c>();
                for (Object sqObj : savedQueries) {
                    Map<String, Object> sq = (Map<String, Object>) sqObj;
                    DocGen_Saved_Query__c newSq = new DocGen_Saved_Query__c();
                    newSq.DocGen_Template__c = tmpl.Id;
                    newSq.Name = (String) sq.get('Name');
                    newSq.Query_Condition__c = (String) sq.get('Query_Condition__c');
                    newSq.Description__c = (String) sq.get('Description__c');
                    sqs.add(newSq);
                }
                // v2.0.1 — per-field FLS enforcement (Checkmarx "FLS Create").
                DocGenFlsGuard.assertCreateable(
                    sqs,
                    new Set<String>{ 'DocGen_Template__c', 'Name', 'Query_Condition__c', 'Description__c' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                Database.insert(sqs, AccessLevel.SYSTEM_MODE);
            }

            return tmpl.Id;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error importing template.');
        }
    }

    /**
     * Clones a template in-org: copies the record, active version, template
     * file, inline-image assets, watermark, and saved queries via the
     * export/import bundle path (which also re-runs image extraction and
     * pre-decomposition on the copy). The copy starts Inactive and non-Default
     * so it never appears in pickers until the admin reviews it, and gets a
     * unique API Name derived from the new name (blank if it can't be made
     * unique cheaply).
     * @return The new template record ID
     */
    @AuraEnabled
    public static Id cloneTemplate(Id templateId, String newName) {
        try {
            String bundleJson = exportTemplate(templateId);
            Map<String, Object> bundle = (Map<String, Object>) JSON.deserializeUntyped(bundleJson);
            Map<String, Object> tmplData = (Map<String, Object>) bundle.get('template');
            String name = String.isNotBlank(newName) ? newName : ((String) tmplData.get('Name')) + ' (Copy)';
            tmplData.put('Name', name.abbreviate(80));
            tmplData.put('Is_Default__c', false);
            tmplData.put('Is_Active__c', false);
            tmplData.put('API_Name__c', uniqueApiNameFor(name));
            return importTemplate(JSON.serialize(bundle));
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error cloning template.');
        }
    }

    /** Derives an API name from a display name and suffixes _2.._9 on collision; null when exhausted. */
    private static String uniqueApiNameFor(String displayName) {
        String base = displayName.replaceAll('[^a-zA-Z0-9]+', '_').replaceAll('^[_0-9]+', '').replaceAll('_+$', '');
        if (String.isBlank(base)) {
            return null;
        }
        base = base.abbreviate(77); // leave room for a _N suffix under the 80 cap
        Set<String> takenNames = new Set<String>();
        /* code-analyzer-suppress ApexFlsViolation */
        for (DocGen_Template__c t : [
            SELECT API_Name__c
            FROM DocGen_Template__c
            WHERE API_Name__c LIKE :(base + '%')
            WITH SYSTEM_MODE
        ]) {
            takenNames.add(t.API_Name__c.toLowerCase());
        }
        if (!takenNames.contains(base.toLowerCase())) {
            return base;
        }
        for (Integer i = 2; i <= 9; i++) {
            String candidate = base + '_' + i;
            if (!takenNames.contains(candidate.toLowerCase())) {
                return candidate;
            }
        }
        return null;
    }

    // =========================================================================
    // Shared Assets (issue #185) — CRUD + version management for DocGen_Asset__c.
    // Each asset has an immutable Asset_Key__c (auto-set by DocGenAssetKeyTrigger)
    // and the merge tag {%asset:<key>} resolves at generation time to the asset's
    // latest ContentVersion (DocGenService.resolveAssetCvIds). Update an asset's
    // version once and every template that uses the tag picks it up — no per-
    // template edits. v1 is images only.
    // =========================================================================

    /**
     * Lists active and inactive shared assets for the Assets tab. Returns a flat
     * map per asset: Name, Asset_Key__c, Asset_Type__c, the {%asset:<key>} merge
     * tag, version count + latest ContentVersion Id (for thumbnail preview) and
     * the latest version's LastModifiedDate. Cacheable for the datatable wire.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAssets() {
        DocGenFlsGuard.assertAccessible(
            DocGen_Asset__c.sObjectType,
            new Set<String>{ 'Name', 'Asset_Key__c', 'Asset_Type__c', 'Category__c', 'Is_Active__c' }
        );
        // Read SYSTEM_MODE behind the assertAccessible guard above — matches the asset
        // catalog's other reads (resolveAssetCvIds + the reads below) and the package's
        // internal-config-read convention. USER_MODE here masked the new Asset_Type__c
        // field as "No such column" for any running user without FLS on it (e.g. the
        // packaging-build test user) — a namespaced-build-only failure invisible to a
        // no-namespace scratch where the running user holds DocGen_Admin.
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Asset__c> assets = [
            SELECT
                Id,
                Name,
                Asset_Key__c,
                Asset_Type__c,
                Category__c,
                Is_Active__c,
                (
                    SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.LastModifiedDate
                    FROM ContentDocumentLinks
                    ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Id DESC
                    LIMIT 1
                )
            FROM DocGen_Asset__c
            WITH SYSTEM_MODE
            ORDER BY Name ASC
        ];

        // Collect the latest CV Ids so a single ContentVersion query yields the
        // version number (VersionNumber) without an N+1 per asset.
        Set<Id> latestCvIds = new Set<Id>();
        for (DocGen_Asset__c a : assets) {
            if (a.ContentDocumentLinks != null && !a.ContentDocumentLinks.isEmpty()) {
                Id cvId = a.ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
                if (cvId != null) {
                    latestCvIds.add(cvId);
                }
            }
        }
        Map<Id, Integer> versionByCv = new Map<Id, Integer>();
        if (!latestCvIds.isEmpty()) {
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionNumber' });
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentVersion cv : [
                SELECT Id, VersionNumber
                FROM ContentVersion
                WHERE Id IN :latestCvIds
                WITH USER_MODE
            ]) {
                versionByCv.put(cv.Id, Integer.valueOf(cv.VersionNumber));
            }
        }

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (DocGen_Asset__c a : assets) {
            String latestCvId = null;
            Datetime lastModified = null;
            if (a.ContentDocumentLinks != null && !a.ContentDocumentLinks.isEmpty()) {
                Id cvId = a.ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
                latestCvId = (cvId == null) ? null : String.valueOf(cvId);
                lastModified = a.ContentDocumentLinks[0].ContentDocument.LastModifiedDate;
            }
            result.add(
                new Map<String, Object>{
                    'id' => a.Id,
                    'name' => a.Name,
                    'assetKey' => a.Asset_Key__c,
                    'assetType' => a.Asset_Type__c,
                    'category' => a.Category__c,
                    'isActive' => a.Is_Active__c,
                    'mergeTag' => '{%asset:' +
                    a.Asset_Key__c +
                    '}',
                    'latestVersionCvId' => latestCvId,
                    'versionNumber' => (latestCvId != null) ? versionByCv.get(Id.valueOf(latestCvId)) : null,
                    'lastModified' => lastModified
                }
            );
        }
        return result;
    }

    /**
     * Creates a shared asset shell with a human-readable, immutable Asset_Key__c
     * (e.g. "footer") that backs the {%asset:<key>} merge tag. The caller supplies
     * the key; if blank it's derived from the name. The key is canonicalized to a
     * URL-safe slug (DocGenAssetKeyHandler.normalizeKey) and must be unique — a
     * friendly error is thrown if it's already in use. The admin uploads the first
     * image version separately via addAssetVersion. Returns the new record's id,
     * key and the ready-to-paste merge tag.
     */
    @AuraEnabled
    public static Map<String, Object> createAsset(String name, String assetKey) {
        if (String.isBlank(name)) {
            throw DocGenService.ahe('Asset name is required.');
        }
        // Canonicalize the chosen key; fall back to a slug of the name when blank.
        String desiredKey = DocGenAssetKeyHandler.normalizeKey(assetKey);
        if (String.isBlank(desiredKey)) {
            desiredKey = DocGenAssetKeyHandler.normalizeKey(name);
        }
        if (String.isBlank(desiredKey)) {
            throw DocGenService.ahe('Could not build a tag key — use letters or numbers in the key or name.');
        }
        // Reject a duplicate up front with a clear, un-wrapped message (the unique
        // index is the final backstop). Kept outside the try so the friendly text
        // isn't re-wrapped by the generic catch below.
        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Asset__c> clash = [
            SELECT Id
            FROM DocGen_Asset__c
            WHERE Asset_Key__c = :desiredKey
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!clash.isEmpty()) {
            throw DocGenService.ahe('The tag key "' + desiredKey + '" is already in use. Choose a different key.');
        }
        try {
            DocGen_Asset__c asset = new DocGen_Asset__c(
                Name = name.trim(),
                Asset_Key__c = desiredKey,
                Asset_Type__c = 'Image',
                Is_Active__c = true
            );
            DocGenFlsGuard.assertCreateable(
                asset,
                new Set<String>{ 'Name', 'Asset_Key__c', 'Asset_Type__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(asset, AccessLevel.SYSTEM_MODE);

            // Re-read the trigger-stamped key (not returned on the in-memory record).
            DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Name', 'Asset_Key__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            DocGen_Asset__c created = [
                SELECT Id, Name, Asset_Key__c
                FROM DocGen_Asset__c
                WHERE Id = :asset.Id
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return new Map<String, Object>{
                'id' => created.Id,
                'name' => created.Name,
                'assetKey' => created.Asset_Key__c,
                'mergeTag' => '{%asset:' +
                created.Asset_Key__c +
                '}'
            };
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error creating asset.');
        }
    }

    /**
     * Live validation for the create-asset key field. Canonicalizes the typed key
     * to the slug the {%asset:<key>} tag will use and reports whether it's a valid,
     * still-available key — so the UI can show the final tag + a green/red hint as
     * the user types, before they commit. Read-only; safe to call on every change.
     *
     * @return map { normalized, valid, available, mergeTag }
     */
    @AuraEnabled
    public static Map<String, Object> checkAssetKey(String assetKey) {
        String normalized = DocGenAssetKeyHandler.normalizeKey(assetKey);
        Boolean valid = String.isNotBlank(normalized);
        Boolean available = false;
        if (valid) {
            try {
                DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c' });
                /* code-analyzer-suppress ApexFlsViolation */
                Integer taken = [
                    SELECT COUNT()
                    FROM DocGen_Asset__c
                    WHERE Asset_Key__c = :normalized
                    WITH SYSTEM_MODE
                ];
                available = (taken == 0);
            } catch (Exception e) {
                throw DocGenService.ahe(e, 'Error checking asset key.');
            }
        }
        return new Map<String, Object>{
            'normalized' => normalized,
            'valid' => valid,
            'available' => available,
            'mergeTag' => valid ? '{%asset:' + normalized + '}' : ''
        };
    }

    /**
     * Attaches an uploaded image (ContentVersion) to an asset as its new latest
     * version and shares it org-wide. The asset's merge tag always resolves to
     * ContentDocument.LatestPublishedVersionId, so the new upload becomes live for
     * every template the moment this returns.
     *
     * The ContentDocumentLink to the asset is created with ShareType='V' /
     * Visibility='AllUsers' — the #114 fix (mirrors saveGeneratedDocument:329 and
     * insertPdfAcroFormSnapshot:2774) — so the row-level PDF path (Blob.toPdf
     * fetching /sfc/ as the running user) and the HTML <img> path both load the
     * asset for any internal user, not just the uploader.
     *
     * @param assetId          DocGen_Asset__c to attach to
     * @param contentVersionId The uploaded ContentVersion (068...)
     * @return The asset's new latest ContentVersion Id
     */
    @AuraEnabled
    public static Id addAssetVersion(Id assetId, Id contentVersionId) {
        if (assetId == null || contentVersionId == null) {
            throw DocGenService.ahe('Asset Id and Content Version Id are required.');
        }
        if (!String.valueOf(contentVersionId).startsWith('068')) {
            throw DocGenService.ahe('Expected a ContentVersion Id.');
        }
        if (assetId.getSObjectType() != DocGen_Asset__c.sObjectType) {
            throw DocGenService.ahe('Expected a Portwood Asset Id.');
        }
        try {
            // Confirm the RUNNING USER can see this ContentVersion under their own
            // sharing BEFORE the SYSTEM_MODE plumbing publishes it AllUsers. Without
            // this, a caller could pass an arbitrary 068 Id (a file never shared to
            // them) and broaden it org-wide via the asset link (confused deputy).
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Id' });
            List<ContentVersion> visibleToCaller = [
                SELECT Id
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
            if (visibleToCaller.isEmpty()) {
                throw DocGenService.ahe('You do not have access to the uploaded file.');
            }

            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'ContentDocumentId' });
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentVersion> cvs = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (cvs.isEmpty() || cvs[0].ContentDocumentId == null) {
                throw DocGenService.ahe('Uploaded file not found.');
            }
            Id contentDocId = cvs[0].ContentDocumentId;

            // Link the document to the asset (or re-share an existing link as
            // AllUsers). FirstPublishLocationId on upload would set this natively;
            // here the CV is already created, so we create/patch the link.
            DocGenFlsGuard.assertAccessible(
                ContentDocumentLink.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'Visibility', 'ShareType' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDocumentLink> existing = [
                SELECT Id, Visibility, ShareType
                FROM ContentDocumentLink
                WHERE ContentDocumentId = :contentDocId AND LinkedEntityId = :assetId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (existing.isEmpty()) {
                ContentDocumentLink cdl = new ContentDocumentLink(
                    ContentDocumentId = contentDocId,
                    LinkedEntityId = assetId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                );
                DocGenFlsGuard.assertCreateable(
                    cdl,
                    new Set<String>{ 'ContentDocumentId', 'LinkedEntityId', 'ShareType', 'Visibility' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                Database.insert(cdl, AccessLevel.SYSTEM_MODE);
            } else if (existing[0].Visibility != 'AllUsers' || existing[0].ShareType != 'V') {
                existing[0].Visibility = 'AllUsers';
                existing[0].ShareType = 'V';
                DocGenFlsGuard.assertUpdateable(existing[0], new Set<String>{ 'ShareType', 'Visibility' });
                /* code-analyzer-suppress ApexFlsViolation */
                Database.update(existing[0], AccessLevel.SYSTEM_MODE);
            }

            DocGenFlsGuard.assertAccessible(ContentDocument.sObjectType, new Set<String>{ 'LatestPublishedVersionId' });
            /* code-analyzer-suppress ApexFlsViolation */
            ContentDocument doc = [
                SELECT LatestPublishedVersionId
                FROM ContentDocument
                WHERE Id = :contentDocId
                WITH SYSTEM_MODE
                LIMIT 1
            ];

            // Email-logo continuity: if any earlier file of this asset was published
            // as a public delivery (the Email Templates "Override with Asset File"
            // flow), publish the replacement the same way so send-time logo
            // resolution (DocGenEmailTemplateService.resolveLogoAssetUrl) finds a
            // link for the NEW file. This runs in the admin's upload transaction —
            // the send contexts (guest / Automated Process) can't create
            // distributions. Best-effort: never blocks the upload.
            carryForwardAssetDistribution(assetId, doc.LatestPublishedVersionId);

            return doc.LatestPublishedVersionId;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error adding asset version.');
        }
    }

    @TestVisible
    private static void carryForwardAssetDistribution(Id assetId, Id newLatestCvId) {
        try {
            if (newLatestCvId == null) {
                return;
            }
            // Every file ever linked to this asset → their latest version Ids.
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :assetId
                WITH SYSTEM_MODE
            ]; // NOPMD ApexCRUDViolation - internal plumbing behind the addAssetVersion guards
            Set<Id> allCvIds = new Set<Id>();
            for (ContentDocumentLink l : links) {
                if (l.ContentDocument.LatestPublishedVersionId != null) {
                    allCvIds.add(l.ContentDocument.LatestPublishedVersionId);
                }
            }
            if (allCvIds.isEmpty()) {
                return;
            }
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDistribution> dists = [
                SELECT Id, ContentVersionId
                FROM ContentDistribution
                WHERE ContentVersionId IN :allCvIds
                WITH SYSTEM_MODE
            ]; // NOPMD ApexCRUDViolation - internal plumbing behind the addAssetVersion guards
            Boolean anyPublished = false;
            for (ContentDistribution d : dists) {
                if (d.ContentVersionId == newLatestCvId) {
                    return; // new file already has its delivery
                }
                anyPublished = true;
            }
            if (!anyPublished) {
                return; // asset was never used as a public logo — nothing to carry forward
            }
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Asset__c> named = [
                SELECT Name
                FROM DocGen_Asset__c
                WHERE Id = :assetId
                WITH SYSTEM_MODE
                LIMIT 1
            ]; // NOPMD ApexCRUDViolation - internal plumbing behind the addAssetVersion guards
            ContentDistribution cd = new ContentDistribution(
                Name = 'Portwood Asset - ' + (named.isEmpty() ? 'Logo' : named[0].Name),
                ContentVersionId = newLatestCvId,
                PreferencesAllowViewInBrowser = true,
                PreferencesLinkLatestVersion = true,
                PreferencesAllowOriginalDownload = true,
                PreferencesExpires = false,
                PreferencesNotifyOnVisit = false,
                PreferencesAllowPDFDownload = false
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(cd, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Portwood: asset delivery carry-forward skipped: ' + e.getMessage());
        }
    }

    /**
     * Renames an asset's friendly Name (the label shown in the Assets tab). The
     * immutable Asset_Key__c — and therefore every {%asset:<key>} reference in
     * existing templates — is untouched.
     */
    @AuraEnabled
    public static void renameAsset(Id assetId, String newName) {
        if (assetId == null || String.isBlank(newName)) {
            throw DocGenService.ahe('Asset Id and new name are required.');
        }
        try {
            DocGen_Asset__c asset = new DocGen_Asset__c(Id = assetId, Name = newName.trim());
            DocGenFlsGuard.assertUpdateable(asset, new Set<String>{ 'Name' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(asset, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error renaming asset.');
        }
    }

    /**
     * Sets (or clears — blank is allowed) an asset's free-text Category__c, the
     * grouping label the Assets tab filters on. A separate method rather than a
     * createAsset/renameAsset parameter because @AuraEnabled methods can't be
     * overloaded and the existing signatures are called throughout the tests.
     */
    @AuraEnabled
    public static void setAssetCategory(Id assetId, String category) {
        if (assetId == null) {
            throw DocGenService.ahe('Asset Id is required.');
        }
        try {
            String trimmed = String.isBlank(category) ? null : category.trim();
            DocGen_Asset__c asset = new DocGen_Asset__c(Id = assetId, Category__c = trimmed);
            DocGenFlsGuard.assertUpdateable(asset, new Set<String>{ 'Category__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(asset, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error setting asset category.');
        }
    }

    /**
     * Retires an asset by clearing Is_Active__c. The resolver skips inactive
     * assets, so any template still using the tag renders a placeholder + logs an
     * error rather than the old image. Reversible (re-activate via the platform).
     */
    @AuraEnabled
    public static void deactivateAsset(Id assetId) {
        if (assetId == null) {
            throw DocGenService.ahe('Asset Id is required.');
        }
        try {
            DocGen_Asset__c asset = new DocGen_Asset__c(Id = assetId, Is_Active__c = false);
            DocGenFlsGuard.assertUpdateable(asset, new Set<String>{ 'Is_Active__c' });
            /* code-analyzer-suppress ApexFlsViolation */
            Database.update(asset, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deactivating asset.');
        }
    }

    /**
     * Permanently deletes a shared asset AND its linked image files. Any
     * template still referencing {%asset:<key>} renders the missing-asset
     * placeholder afterwards — the LWC confirms with the admin before calling.
     */
    @AuraEnabled
    public static void deleteAsset(Id assetId) {
        if (assetId == null) {
            throw DocGenService.ahe('Asset Id is required.');
        }
        if (!Schema.sObjectType.DocGen_Asset__c.isDeletable()) {
            throw DocGenService.ahe('Insufficient access to delete assets.');
        }
        try {
            Set<Id> docIds = new Set<Id>();
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :assetId
                WITH SYSTEM_MODE
            ]) {
                // NOPMD ApexCRUDViolation — internal asset-file plumbing behind the isDeletable gate above
                docIds.add(cdl.ContentDocumentId);
            }
            if (!docIds.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                delete [SELECT Id FROM ContentDocument WHERE Id IN :docIds]; // NOPMD ApexCRUDViolation — asset image files, owner-admin cleanup
            }
            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(assetId, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting asset.');
        }
    }
}

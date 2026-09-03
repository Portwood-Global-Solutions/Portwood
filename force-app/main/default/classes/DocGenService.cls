global with sharing class DocGenService { // NOPMD AvoidGlobalModifier — global required so subscriber Apex can call generateDocument*/generatePdfBlob* in installed orgs
    // Collector for images to inject after XML processing
    private static List<Map<String, Object>> pendingImages = new List<Map<String, Object>>();
    private static Integer imageCounter = 0;
    private static String currentTemplateType = 'Word'; // Set before processXml calls
    // PPTX/XLSX image embedding (#117): tracks which slide / worksheet processXml
    // is currently walking. Pendings tagged with this slidePath so the post-process
    // can update the correct ppt/slides/_rels/slideN.xml.rels file. Null for Word
    // (Word puts every image in word/_rels/document.xml.rels regardless of source).
    private static String currentEntryName;
    @TestVisible
    private static String currentOutputFormat = 'Native'; // Set before processXml — PDF skips blob loading for images
    // Designer live PDF preview: when set, HTML-template merges render this
    // draft body instead of the saved one. See mergeTemplate().
    public static String draftHtmlBodyOverride;
    // Designer live preview: the UNSAVED running header/footer. Without these the
    // preview rendered the header/footer from the SAVED record, so header edits never
    // appeared in the PDF the author was checking them against. Null means "use the
    // saved values"; empty string is a deliberate "the author cleared it".
    public static String draftHeaderHtmlOverride;
    public static String draftFooterHtmlOverride;
    // Signer form fields ({?key} tags): preserved verbatim during the send-time
    // merge / snapshot freeze (so the placeholder survives into the signed-doc
    // template), then resolved when the signature finalize re-render flips this
    // flag true and injects collected values under data['__formFields']. Mirrors
    // the {@Signature_*} preserve-then-stamp lifecycle.
    @TestVisible
    public static Boolean resolveFormFields = false;
    // Signature placement tags {@Signature_*}: preserved verbatim through the merge
    // ONLY during a signature send/finalize (set true by mergeTemplateForSignature) so
    // the signature service can convert them to @@SIG-n@@ sentinels / stamp them after
    // merge. In normal document generation this stays false and processXml STRIPS the
    // tags, so a signature template generated as a regular document never leaks raw
    // "{@Signature_…}" text into the output.
    @TestVisible
    public static Boolean preserveSignatureTags = false;
    // Reserved merge-data keys injected into the record data map for the
    // duration of one mergeTemplate call (cleared after use). The signature
    // finalizer uses this to surface collected signer form-field values under
    // '__formFields' on the live-merge path, mirroring the snapshot path's
    // snap.put('__formFields', …). Resolved by the {?key} branch above.
    @TestVisible
    public static Map<String, Object> reservedMergeData;

    /**
     * Sets the admin-uploaded watermark override on the renderer (if one exists
     * on the active version of the given template). When set, the renderer uses
     * this CV as the @page background-image, ignoring any Word-embedded VML
     * watermark in the headers. Call this before every convertToHtml().
     */
    public static void applyWatermarkOverride(Id templateId) {
        DocGenHtmlRenderer.overrideWatermarkCvId = null;
        if (templateId == null) {
            return;
        }
        try {
            // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
            // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
            // calls Schema.SObjectField.getDescribe().isAccessible() on every field
            // the SELECT lists; throws DocGenException with the offending field name
            // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
            // package-build @TestSetup FLS-propagation issue documented in
            // DocGenFlsGuard.cls.
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Watermark_Image_CV_Id__c', 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> vs = [
                SELECT Watermark_Image_CV_Id__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!vs.isEmpty() && String.isNotBlank(vs[0].Watermark_Image_CV_Id__c)) {
                DocGenHtmlRenderer.overrideWatermarkCvId = vs[0].Watermark_Image_CV_Id__c;
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable
        }
    }

    // Per-transaction cache of record Id → ordered list of attached image CV IDs.
    // Populated by prefetchImagesForIds() before loops that contain {%Image:N} tags,
    // so in-loop image resolution is O(1) instead of one SOQL per iteration.
    @TestVisible
    private static Map<Id, List<String>> imageCvCache;

    // Per-transaction cache of shared-asset key -> latest ContentVersion Id (or
    // null when the asset is missing/inactive), mirroring imageCvCache. Seeded by
    // resolveAssetCvIds so a template that reuses the same {%asset:<key>} many
    // times (e.g. a footer logo per loop row) costs at most one SOQL.
    @TestVisible
    private static Map<String, String> assetCvCache;

    // Thread-local storage for pre-loaded record data. When set, mergeTemplate
    // skips DocGenController.generateDocumentData() and uses this data instead. Cleared after each use.
    private static Map<String, Object> preloadedRecordDataOverride;

    // Chart pipeline (#117): signature → ContentVersion Id for charts the LWC
    // pre-rasterized to PNG before calling generate(). DocGenChartTagExpander
    // reads this in processXml to substitute {Chart:...} with a CV-referencing
    // image tag for Word templates. Empty for non-chart templates and for
    // server-side flows that have no LWC to rasterize.
    @TestVisible
    private static Map<String, String> currentChartCvMap;

    // Client-supplied {#ChartBucket:...} data: signature → JSON array of bucket
    // maps. Set alongside currentChartCvMap; see beginChartContext(map, map).
    @TestVisible
    private static Map<String, String> currentChartBucketMap;

    /**
     * Controller-facing setter for the chart CV map. Called by DocGenController
     * generate entry points before invoking the merge; paired with `endChartContext`
     * in a `finally` so per-request state doesn't leak across transactions.
     */
    public static void beginChartContext(Map<String, String> chartCvMap) {
        beginChartContext(chartCvMap, null);
    }

    /**
     * Overload carrying pre-aggregated {#ChartBucket:...} rows alongside the
     * chart images.
     *
     * `chartBucketMap` is signature → JSON array of bucket maps, computed by the
     * runner LWC in the same paging sweep that feeds Chart.js. It exists because
     * the image map alone only rescues the CHARTS at scale: a `{#ChartBucket}`
     * table still asks the resolver for rows, which means either the whole child
     * set in heap or a SOQL GROUP BY the field may not support. Supplying the
     * buckets lets the table render from the counts the browser already has, so
     * a chart and the table beside it stay consistent and neither needs the rows
     * server-side.
     *
     * Null/absent entries fall through to the normal resolution path, so
     * headless callers and small templates are unaffected.
     */
    public static void beginChartContext(Map<String, String> chartCvMap, Map<String, String> chartBucketMap) {
        currentChartCvMap = chartCvMap;
        currentChartBucketMap = chartBucketMap;
    }

    public static void endChartContext() {
        currentChartCvMap = null;
        currentChartBucketMap = null;
    }

    /**
     * Read by DocGenChartBucketResolver.preprocessInline. Null when no client
     * supplied buckets for this transaction.
     */
    public static Map<String, String> getChartBucketMap() {
        return currentChartBucketMap;
    }

    // Static cache for pre-decomposed XML parts — same template, queried once, reused across batch
    private static Id cachedPreDecompTemplateId;
    private static Map<String, String> cachedXmlParts; // key (e.g. 'rels', 'word__document.xml') → raw XML
    private static Boolean cachedPreDecompAvailable;

    // Captured HTML from the last renderPdf() call. Used by bulk batch merge mode
    // to accumulate HTML without re-merging the template. Cleared after reading.
    public static String lastRenderedHtml;

    /**
     * without-sharing helper for loading package-internal pre-decomposed XML ContentVersions.
     * Required because the signature PDF queueable runs as Automated Process user, which
     * can't see ContentVersion records under `with sharing` — no ContentDocumentLink rows
     * associate it with the files. The CVs are internal package metadata (not user data),
     * so bypassing sharing is safe. Template access is still gated by DocGen_Admin/User
     * permsets at the upstream entry points. (#28)
     */
    public static List<ContentVersion> loadInternalContentVersionsByTitle(String title) {
        return new PreDecompXmlLoader().loadByTitles(new Set<String>{ title });
    }

    public static List<ContentVersion> loadInternalContentVersionsByTitles(Set<String> titles) {
        return new PreDecompXmlLoader().loadByTitles(titles);
    }

    public static List<ContentVersion> loadInternalContentVersionsByTitlePrefix(String titlePrefix) {
        return new PreDecompXmlLoader().loadByTitlePrefix(titlePrefix);
    }

    public static List<ContentVersion> loadInternalContentVersionsForVersionByTitle(Id versionId, String title) {
        return new PreDecompXmlLoader().loadForLinkedEntityByTitles(versionId, new Set<String>{ title });
    }

    public static List<ContentVersion> loadInternalContentVersionsForVersionByTitles(Id versionId, Set<String> titles) {
        return new PreDecompXmlLoader().loadForLinkedEntityByTitles(versionId, titles);
    }

    public static List<ContentVersion> loadInternalContentVersionsForVersionByTitlePrefix(
        Id versionId,
        String titlePrefix
    ) {
        return new PreDecompXmlLoader().loadForLinkedEntityByTitlePrefix(versionId, titlePrefix);
    }

    /**
     * Metadata-only, CDL-scoped file listing — no VersionData.
     *
     * For listing a template's files (the Designer's image picker) rather than reading
     * one. Pulling VersionData for every image would load every blob into heap just to
     * render a list of links.
     *
     * MUST be scoped by ContentDocumentId, not by a bare Title LIKE. Measured on a
     * Standard User holding DocGen_Admin: the user could read the template (1 row) and
     * its ContentDocumentLink (1 row), but a title-only ContentVersion query returned
     * ZERO in user mode, in SYSTEM_MODE, and from a `without sharing` class alike —
     * file access is not governed by Apex sharing keywords. Resolving the document Ids
     * from the link first returns the rows. See loadForLinkedEntityByTitlePrefix.
     */
    public static List<ContentVersion> loadInternalContentVersionMetaForEntityByTitlePrefix(
        Id linkedEntityId,
        String titlePrefix
    ) {
        return new PreDecompXmlLoader().loadMetaForLinkedEntityByTitlePrefix(linkedEntityId, titlePrefix);
    }

    private without sharing class PreDecompXmlLoader {
        /** Id / Title / PathOnClient only, scoped to one record's linked documents. */
        public List<ContentVersion> loadMetaForLinkedEntityByTitlePrefix(Id linkedEntityId, String titlePrefix) {
            Set<Id> docIds = getLinkedContentDocumentIds(linkedEntityId);
            if (docIds.isEmpty()) {
                return new List<ContentVersion>();
            }
            String likePattern = titlePrefix + '%';
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'Title', 'PathOnClient', 'IsLatest' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, Title, PathOnClient
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND Title LIKE :likePattern AND IsLatest = TRUE
                WITH SYSTEM_MODE // NOPMD — package-internal template assets
                // Id DESC breaks same-second CreatedDate ties — see the sibling
                // loadForLinkedEntityByTitlePrefix query.
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT 50
            ];
        }

        public List<ContentVersion> loadByTitlePrefix(String titlePrefix) {
            String likePattern = titlePrefix + '%';
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'Title', 'VersionData', 'IsLatest' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, Title, VersionData
                FROM ContentVersion
                WHERE Title LIKE :likePattern AND IsLatest = TRUE
                WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts
                ORDER BY CreatedDate DESC // newest snapshot wins if duplicates exist (#203)
            ];
        }

        public List<ContentVersion> loadByTitles(Set<String> titles) {
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'Title', 'VersionData', 'IsLatest' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, Title, VersionData
                FROM ContentVersion
                WHERE Title IN :titles AND IsLatest = TRUE
                WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts
                ORDER BY CreatedDate DESC // newest snapshot wins if duplicates exist (#203)
            ];
        }

        public List<ContentVersion> loadForLinkedEntityByTitlePrefix(Id linkedEntityId, String titlePrefix) {
            Set<Id> docIds = getLinkedContentDocumentIds(linkedEntityId);
            if (docIds.isEmpty()) {
                return new List<ContentVersion>();
            }
            String likePattern = titlePrefix + '%';
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'Title', 'VersionData', 'IsLatest' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, ContentDocumentId, Title, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND Title LIKE :likePattern AND IsLatest = TRUE
                WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts linked to template version
                // Newest snapshot wins if duplicates exist (#203). Id DESC breaks the
                // tie: CreatedDate has one-second granularity, so two versions saved
                // in the same second — an edit saved twice, or both writes inside one
                // transaction — order arbitrarily, and "newest wins" silently returned
                // whichever row the optimizer felt like. That reads back an OLD body
                // into the Designer with no error. Ids are assigned in insert order,
                // so the higher Id is the later write.
                ORDER BY CreatedDate DESC, Id DESC
            ];
        }

        public List<ContentVersion> loadForLinkedEntityByTitles(Id linkedEntityId, Set<String> titles) {
            Set<Id> docIds = getLinkedContentDocumentIds(linkedEntityId);
            if (docIds.isEmpty()) {
                return new List<ContentVersion>();
            }
            DocGenFlsGuard.assertAccessible(
                ContentVersion.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'Title', 'VersionData', 'IsLatest' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            return [
                SELECT Id, ContentDocumentId, Title, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND Title IN :titles AND IsLatest = TRUE
                WITH SYSTEM_MODE // NOPMD — package-internal pre-decomposed parts linked to template version
                ORDER BY CreatedDate DESC // newest snapshot wins if duplicates exist (#203)
            ];
        }

        private Set<Id> getLinkedContentDocumentIds(Id linkedEntityId) {
            DocGenFlsGuard.assertAccessible(
                ContentDocumentLink.sObjectType,
                new Set<String>{ 'LinkedEntityId', 'ContentDocumentId' }
            );
            Set<Id> docIds = new Set<Id>();
            /* code-analyzer-suppress ApexFlsViolation */
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :linkedEntityId
                WITH SYSTEM_MODE // NOPMD — package-internal files linked to template version
            ]) {
                docIds.add(link.ContentDocumentId);
            }
            return docIds;
        }
    }

    private static final Set<String> AGGREGATE_FUNCTIONS = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };

    // Heap-pressure routing: check every N loop iterations during sync merge; if
    // we're past HEAP_PRESSURE_RATIO of the limit, throw HeapPressureException so
    // the controller can signal the runner LWC to auto-fallback to the giant path.
    // 60% leaves ~2.4MB for the still-pending HTML conversion + Blob.toPdf()
    // (Flying Saucer DOM parse typically 2-3× the HTML string size).
    @TestVisible
    private static Integer HEAP_CHECK_EVERY_N_ITERS = 50;
    @TestVisible
    private static Decimal HEAP_PRESSURE_RATIO = 0.60;
    // @TestVisible hook — tests set this to force checkHeapPressure into the pressure branch
    @TestVisible
    private static Boolean forceHeapPressureForTest = false;

    private static final Set<String> NUMERIC_FORMATS = new Set<String>{ 'currency', 'percent', 'number' };

    // Currency ISO code → display symbol (top ~35 world currencies)
    private static final Map<String, String> CURRENCY_SYMBOLS = new Map<String, String>{
        'USD' => '$',
        'EUR' => '\u20AC',
        'GBP' => '\u00A3',
        'JPY' => '\u00A5',
        'CNY' => '\u00A5',
        'CHF' => 'CHF ',
        'CAD' => 'C$',
        'AUD' => 'A$',
        'INR' => '\u20B9',
        'KRW' => '\u20A9',
        'BRL' => 'R$',
        'MXN' => 'MX$',
        'SEK' => 'kr ',
        'NOK' => 'kr ',
        'DKK' => 'kr ',
        'PLN' => 'z\u0142',
        'CZK' => 'K\u010D',
        'HUF' => 'Ft ',
        'TRY' => '\u20BA',
        'ZAR' => 'R ',
        'SGD' => 'S$',
        'HKD' => 'HK$',
        'NZD' => 'NZ$',
        'THB' => '\u0E3F',
        'MYR' => 'RM ',
        'PHP' => '\u20B1',
        'IDR' => 'Rp ',
        'TWD' => 'NT$',
        'ILS' => '\u20AA',
        'RUB' => '\u20BD',
        'NGN' => '\u20A6',
        'KES' => 'KSh ',
        'AED' => 'AED ',
        'SAR' => 'SAR ',
        'COP' => 'COL$',
        'CLP' => 'CLP$',
        'PEN' => 'S/',
        'ARS' => 'ARS$',
        'EGP' => 'E\u00A3',
        'GHS' => 'GH\u20B5'
    };

    // Currencies that use 0 decimal places
    private static final Set<String> ZERO_DECIMAL_CURRENCIES = new Set<String>{
        'JPY',
        'KRW',
        'CLP',
        'VND',
        'HUF',
        'ISK',
        'TWD'
    };

    // {RunningUser.X} — standard "prepared by" tags. Allowlist of safe User fields
    // that resolve from the executing user's record, queried once per transaction.
    private static final List<String> RUNNING_USER_FIELDS = new List<String>{
        'Id',
        'Name',
        'FirstName',
        'LastName',
        'Email',
        'Username',
        'Alias',
        'Title',
        'Department',
        'CompanyName',
        'EmployeeNumber',
        'Phone',
        'MobilePhone',
        'Extension',
        'Fax',
        'Street',
        'City',
        'State',
        'PostalCode',
        'Country',
        'TimeZoneSidKey',
        'LocaleSidKey',
        'LanguageLocaleKey'
    };

    @TestVisible
    private static Map<String, Object> runningUserContext;

    /**
     * Creates an AuraHandledException with a user-facing message.
     * Centralizes exception creation for consistent error handling.
     */
    public static AuraHandledException ahe(String message) {
        AuraHandledException ex = new AuraHandledException(message);
        ex.setMessage(message);
        return ex;
    }

    /**
     * Creates an AuraHandledException that includes the original exception details
     * for debugging while showing a user-friendly message.
     */
    public static AuraHandledException ahe(Exception cause, String message) {
        String fullMessage = message + ' (' + cause.getMessage() + ')';
        AuraHandledException ex = new AuraHandledException(fullMessage);
        ex.setMessage(fullMessage);
        return ex;
    }

    /**
     * Creates an AuraHandledException from an existing exception, preserving its message.
     */
    public static AuraHandledException ahe(Exception cause) {
        AuraHandledException ex = new AuraHandledException(cause.getMessage());
        ex.setMessage(cause.getMessage());
        return ex;
    }

    /**
     * Converts a DmlException from a settings/config save into a user-friendly
     * AuraHandledException. STRING_TOO_LONG gets a field-specific "too long, max N
     * characters" message (the raw DmlException surfaces as "[object Object]" in LWC).
     */
    public static AuraHandledException dmlAhe(DmlException e, Schema.SObjectType sObjType) {
        if (e.getNumDml() > 0 && e.getDmlType(0) == StatusCode.STRING_TOO_LONG) {
            List<String> fieldNames = e.getDmlFieldNames(0);
            Schema.DescribeFieldResult dfr = describeDmlField(sObjType, fieldNames);
            if (dfr != null) {
                return ahe(
                    dfr.getLabel() + ' is too long (max ' + dfr.getLength() + ' characters) — use a shorter value.'
                );
            }
            return ahe('A value is too long: ' + e.getDmlMessage(0));
        }
        return ahe('Could not save: ' + (e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage()));
    }

    /**
     * Resolves a field name from DmlException.getDmlFieldNames against the object's
     * field map. Falls back to an endsWith match because DML field names may or may
     * not carry the namespace prefix depending on context.
     */
    private static Schema.DescribeFieldResult describeDmlField(Schema.SObjectType sObjType, List<String> fieldNames) {
        if (fieldNames == null || fieldNames.isEmpty() || sObjType == null) {
            return null;
        }
        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();
        String wanted = fieldNames[0].toLowerCase();
        if (fieldMap.containsKey(wanted)) {
            return fieldMap.get(wanted).getDescribe();
        }
        for (String key : fieldMap.keySet()) {
            if (key.endsWith(wanted)) {
                return fieldMap.get(key).getDescribe();
            }
        }
        return null;
    }

    /**
     * Public wrapper for processXml — used by e2e tests to validate tag processing.
     * @param xml The XML string containing merge tags
     * @param data The record data map to resolve tags against
     * @return The processed XML with tags replaced by data values
     */
    public static String processXmlForTest(String xml, Map<String, Object> data) {
        return processXml(xml, data);
    }

    @TestVisible
    private static Map<String, Object> addPicklistLabelForTest(
        Map<String, Object> data,
        String fieldName,
        String labelValue
    ) {
        if (data == null) {
            data = new Map<String, Object>();
        }
        Map<String, String> labels = data.containsKey('__docgenPicklistLabels')
            ? (Map<String, String>) data.get('__docgenPicklistLabels')
            : new Map<String, String>();
        labels.put(fieldName, labelValue);
        data.put('__docgenPicklistLabels', labels);
        return data;
    }

    /**
     * Overload that flips currentTemplateType for the duration of the call.
     * Used by HTML-template tests that need to exercise the rich-text and
     * multi-line branches without spinning up a full template + ContentVersion.
     */
    @TestVisible
    private static String processXmlForTest(String xml, Map<String, Object> data, String templateType) {
        String saved = currentTemplateType;
        currentTemplateType = templateType;
        try {
            return processXml(xml, data);
        } finally {
            currentTemplateType = saved;
        }
    }

    /**
     * Resolve {RunningUser.X} subfield against the cached running-user context.
     * Lazy-loads on first access per transaction by querying the executing user's
     * row for the allowlist fields. Returns null for unknown subfields.
     */
    private static Object resolveRunningUserField(String subfield) {
        if (runningUserContext == null) {
            Map<String, Object> ctx = new Map<String, Object>();
            Id uid = UserInfo.getUserId();
            // Static SOQL — fields are hardcoded to keep the analyzer happy and prove
            // at compile time that no untrusted input flows into the query. The
            // RUNNING_USER_FIELDS constant still gates which fields ship to templates.
            List<User> rows = [
                SELECT
                    Id,
                    Name,
                    FirstName,
                    LastName,
                    Email,
                    Username,
                    Alias,
                    Title,
                    Department,
                    CompanyName,
                    EmployeeNumber,
                    Phone,
                    MobilePhone,
                    Extension,
                    Fax,
                    Street,
                    City,
                    State,
                    PostalCode,
                    Country,
                    TimeZoneSidKey,
                    LocaleSidKey,
                    LanguageLocaleKey
                FROM User
                WHERE Id = :uid
                WITH USER_MODE
                LIMIT 1
            ];
            if (!rows.isEmpty()) {
                User u = rows[0];
                for (String f : RUNNING_USER_FIELDS) {
                    ctx.put(f, u.get(f));
                }
            }
            runningUserContext = ctx;
        }
        for (String key : runningUserContext.keySet()) {
            if (key.equalsIgnoreCase(subfield)) {
                return runningUserContext.get(key);
            }
        }
        return null;
    }

    /**
     * Intermediate merge result containing processed XML, images, and passthrough ZIP entries.
     */
    private class MergeResult { // NOPMD TooManyFields — data transfer object requires all fields
        String documentXml; // Processed word/document.xml
        Map<String, String> processedXmlEntries; // All processed XML entries (name → xml)
        Map<String, Blob> passthroughEntries; // Non-XML ZIP entries passed through as-is
        String contentTypesXml; // [Content_Types].xml
        String relsXml; // word/_rels/document.xml.rels
        String relsPath; // Path to rels file
        String mediaPath; // Path prefix for media files
        Map<String, String> imageBase64ByRelId; // relId → base64 image data (for DOCX and fallback)
        Map<String, String> imageUrlByRelId; // relId → absolute URL (for PDF rendering via Blob.toPdf)
        String templateType;
        String outputFormat;
        String docTitle;
        String pageOrientation; // 'Landscape' routes through DocGenPdfRenderer VF page; otherwise Blob.toPdf portrait
        String pageSize; // 1.68 — Letter / Legal / A4
        String pageMargins; // 1.68 — Default / Narrow / Normal / Wide / Custom
        String customMargins; // 1.68 — "T,R,B,L" inches when pageMargins == Custom
        Blob pdfBlob; // AcroForm PDF template output, already final bytes

        MergeResult() {
            processedXmlEntries = new Map<String, String>();
            passthroughEntries = new Map<String, Blob>();
            imageBase64ByRelId = new Map<String, String>();
            imageUrlByRelId = new Map<String, String>();
        }
    }

    /**
     * Core merge logic: processes template tags in DOCX/PPTX XML and collects results.
     * Returns structured intermediate data without assembling into a final format.
     */
    private static MergeResult mergeTemplate(Id templateId, Id recordId) {
        return mergeTemplate(templateId, recordId, null, null);
    }

    private static MergeResult mergeTemplate(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        return mergeTemplate(templateId, recordId, resolvedImages, null);
    }

    private static MergeResult mergeTemplate(
        Id templateId,
        Id recordId,
        Map<String, String> resolvedImages,
        String outputFormatOverride
    ) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;
        currentEntryName = null;

        Map<String, Object> dataMap;
        try {
            if (preloadedRecordDataOverride != null) {
                // Use pre-cached data from bulk batch — skips per-record SOQL
                dataMap = DocGenController.generateDocumentDataFromCache(templateId, preloadedRecordDataOverride);
                preloadedRecordDataOverride = null; // Clear after use
            } else {
                dataMap = DocGenController.generateDocumentData(templateId, recordId);
            }
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        // Apply LWC-resolved images: replace Salesforce URLs with data URIs in record data.
        // This enables DOCX image embedding without server-side HTTP callouts.
        if (resolvedImages != null && !resolvedImages.isEmpty()) {
            applyResolvedImages(dataMap.get('data'), resolvedImages);
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String outputFormat = (String) dataMap.get('outputFormat');
        String templateType = (String) dataMap.get('templateType');

        // A Canvas template's body IS an HTML document — the canvas editor is an
        // authoring surface that serializes to absolutely-positioned boxes inside
        // position:relative artboards. Normalising here rather than adding `||
        // 'Canvas'` to the twelve downstream `templateType == 'HTML'` branches is
        // deliberate: one of those twelve WOULD get missed, and the failure mode is a
        // Canvas template silently taking the DOCX path and rendering as garbage.
        if (templateType == 'Canvas') {
            templateType = 'HTML';
        }

        // Allow callers to force PDF output format
        if (outputFormatOverride != null) {
            outputFormat = outputFormatOverride;
        }

        // Designer live-preview: render caller-supplied draft HTML in place of
        // the saved body (HTML templates only). One-shot — cleared by the
        // controller in a finally block so it never leaks into a later merge.
        if (draftHtmlBodyOverride != null && templateType == 'HTML') {
            base64File = EncodingUtil.base64Encode(Blob.valueOf(draftHtmlBodyOverride));
        }

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject) dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        // Inject any caller-reserved merge keys (e.g. '__formFields' from the
        // signature finalizer) so they resolve as siblings of the record fields.
        // One-shot: cleared after copy so it never leaks into a later merge.
        if (reservedMergeData != null) {
            for (String reservedKey : reservedMergeData.keySet()) {
                recordDataMap.put(reservedKey, reservedMergeData.get(reservedKey));
            }
            reservedMergeData = null;
        }

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = outputFormat;
        mr.pageOrientation = (String) dataMap.get('pageOrientation');
        mr.pageSize = (String) dataMap.get('pageSize');
        mr.pageMargins = (String) dataMap.get('pageMargins');
        mr.customMargins = (String) dataMap.get('customMargins');

        // PDF template type: fill an existing AcroForm PDF directly. This path
        // does not render HTML and does not unzip/repack Office documents.
        if (templateType == 'PDF') {
            currentTemplateType = 'PDF';
            currentOutputFormat = 'PDF';
            mr.outputFormat = 'PDF';
            mr.pdfBlob = DocGenAcroFormService.fillPdfTemplate(
                EncodingUtil.base64Decode(base64File),
                recordDataMap,
                templateId
            );
            mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
            if (mr.docTitle == null) {
                mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
            }
            return mr;
        }

        // HTML template type (v1.61+): no ZIP, no DOCX XML — raw HTML body with
        // merge-tag substitution + header/footer fields wrapped via @page CSS
        // running elements. Output is always PDF via Blob.toPdf().
        if (templateType == 'HTML') {
            currentTemplateType = 'HTML';
            currentOutputFormat = 'PDF';
            return mergeHtmlTemplate(
                mr,
                base64File,
                recordDataMap,
                draftHeaderHtmlOverride != null ? draftHeaderHtmlOverride : (String) dataMap.get('headerHtml'),
                draftFooterHtmlOverride != null ? draftFooterHtmlOverride : (String) dataMap.get('footerHtml'),
                (String) dataMap.get('titleFormat')
            );
        }

        // Determine rels path based on template type
        if (templateType == 'PowerPoint') {
            mr.relsPath = 'ppt/_rels/presentation.xml.rels';
            mr.mediaPath = 'ppt/media/';
        } else if (templateType == 'Excel') {
            mr.relsPath = 'xl/_rels/workbook.xml.rels';
            mr.mediaPath = 'xl/media/';
        } else {
            mr.relsPath = 'word/_rels/document.xml.rels';
            mr.mediaPath = 'word/media/';
        }

        // For PDF output, try the heap-efficient path: use pre-decomposed XML parts
        // saved as ContentVersions during template version save, skipping full ZIP decompression.
        // Saves ~1.5-2MB heap by avoiding base64 decode + ZIP reader + passthrough extraction.
        if (outputFormat == 'PDF' && templateType == 'Word') {
            currentOutputFormat = 'PDF';
            MergeResult pdfResult = tryMergeFromPreDecomposed(templateId, recordDataMap, mr);
            if (pdfResult != null) {
                mr = pdfResult;
                mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
                if (mr.docTitle == null) {
                    mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
                }
                return mr;
            }
        }

        // Full ZIP decompression path — used for DOCX/PPTX/XLSX output or when pre-decomposed parts are unavailable
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Excel two-pass: worksheets collected here, processed after shared strings are read
        Map<String, String> pendingExcelSheets = new Map<String, String>();
        String excelSharedStringsXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean isTargetXml = false;
            if (templateType == 'Word') {
                isTargetXml =
                    name == 'word/document.xml' ||
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'));
            } else if (templateType == 'PowerPoint') {
                isTargetXml = name.startsWith('ppt/slides/slide') && name.endsWith('.xml');
            } else if (templateType == 'Excel') {
                isTargetXml =
                    (name.startsWith('xl/worksheets/sheet') && name.endsWith('.xml')) || name == 'xl/sharedStrings.xml';
            }

            // Excel: collect worksheets for second pass (shared strings must be read first)
            if (templateType == 'Excel' && isTargetXml && name != 'xl/sharedStrings.xml') {
                pendingExcelSheets.put(name, reader.extract(name).toString());
                continue;
            }

            if (isTargetXml) {
                Blob content = reader.extract(name);
                String xml = content.toString();
                currentTemplateType = templateType;
                currentEntryName = name;

                // Excel: capture shared strings table (not merged, just stored)
                if (templateType == 'Excel' && name == 'xl/sharedStrings.xml') {
                    excelSharedStringsXml = xml;
                    mr.passthroughEntries.put(name, content); // keep original in ZIP
                    continue;
                }

                // De-fragment merge tags split across runs. mergeRunsInTagsCore already
                // matches both <w:t> and <a:t>, but this gate was Word-only, so PowerPoint
                // never got the pass: PowerPoint splits a run on any character-formatting
                // boundary (a spell-check squiggle alone yields err="1" on the middle run),
                // so {UnitPrice:currency} authored as {|UnitPrice:currency|} across three
                // <a:r> elements reached processXml as an unresolvable tag spanning markup
                // and rendered blank. PowerPoint takes this branch for every render —
                // tryMergeFromPreDecomposed (which does call mergeRunsInTags) is gated to
                // Word→PDF. Excel is excluded by design: its text lives in <t>, which
                // mergeRunsInTagsCore does not match, and shared strings are inlined later.
                if (templateType == 'Word' || templateType == 'PowerPoint') {
                    xml = mergeRunsInTags(xml);
                }
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(name, xml);
                if (name == 'word/document.xml') {
                    mr.documentXml = xml;
                }
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                mr.passthroughEntries.put(name, reader.extract(name));
            }
        }

        // Excel second pass: inline shared strings into worksheets, then merge tags
        if (templateType == 'Excel' && !pendingExcelSheets.isEmpty()) {
            currentTemplateType = 'Excel';
            List<String> sharedStrings = parseSharedStrings(excelSharedStringsXml);
            for (String sheetName : pendingExcelSheets.keySet()) {
                String xml = pendingExcelSheets.get(sheetName);
                xml = inlineSharedStrings(xml, sharedStrings);
                currentEntryName = sheetName;
                xml = processXml(xml, recordDataMap);
                // Loop expansion clones <row> elements with duplicate indices/refs;
                // reassign them so Excel doesn't flag the sheet as corrupt.
                xml = renumberExcelRows(xml);
                mr.processedXmlEntries.put(sheetName, xml);
            }
            // Cells are now inline, but workbook.xml.rels and [Content_Types].xml
            // still reference the sharedStrings part — removing it outright leaves a
            // dangling reference that strict readers (openpyxl, POI) reject and Excel
            // silently repairs. Ship an empty table instead so every reference stays valid.
            mr.passthroughEntries.put(
                'xl/sharedStrings.xml',
                Blob.valueOf(
                    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>'
                )
            );
        }

        // PowerPoint post-process: convert {%}-emitted DGPIC markers into real
        // <p:pic> shapes on each slide, and inject the per-slide image
        // relationships into ppt/slides/_rels/slideN.xml.rels.
        if (templateType == 'PowerPoint') {
            postProcessPowerPointSlides(mr);
            normalizePowerPointSlideXml(mr);
            stripPowerPointRevisionParts(mr);
        }

        // Collect existing template images into imageBase64ByRelId for HTML rendering.
        // Parse rels XML to map relId → media filename, then look up in passthroughEntries.
        if (mr.relsXml != null) {
            Integer relCursor = 0;
            while (relCursor < mr.relsXml.length()) {
                Integer relStart = mr.relsXml.indexOf('<Relationship ', relCursor);
                if (relStart == -1) {
                    break;
                }
                Integer relSelfClose = mr.relsXml.indexOf('/>', relStart);
                Integer relClose = mr.relsXml.indexOf('>', relStart);
                if (relClose == -1) {
                    break;
                }
                Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                String relTag = mr.relsXml.substring(relStart, relEnd);
                String relType = extractXmlAttrValue(relTag, 'Type');
                if (relType != null && relType.contains('/image')) {
                    String relId = extractXmlAttrValue(relTag, 'Id');
                    String target = extractXmlAttrValue(relTag, 'Target');
                    if (relId != null && target != null && target.startsWith('media/')) {
                        String fullPath = mr.mediaPath + target.substringAfter('media/');
                        Blob imgBlob = mr.passthroughEntries.get(fullPath);
                        if (imgBlob != null && !mr.imageBase64ByRelId.containsKey(relId)) {
                            mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                        }
                    }
                }
                relCursor = relEnd;
            }
        }

        // Process pending images: update content types, rels, and collect base64 for HTML
        applyPendingImages(mr, true);

        // Generate document title
        mr.docTitle = generateDocTitle((String) dataMap.get('titleFormat'), recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        return mr;
    }

    /**
     * Recursively walks record data and replaces Salesforce image URLs with
     * base64 data URIs from the LWC-resolved image map. This enables DOCX
     * image embedding without server-side callouts.
     */
    private static void applyResolvedImages(Object data, Map<String, String> resolvedImages) {
        if (data instanceof Map<String, Object>) {
            Map<String, Object> mapData = (Map<String, Object>) data;
            for (String key : new List<String>(mapData.keySet())) {
                Object val = mapData.get(key);
                if (val instanceof String) {
                    String strVal = (String) val;
                    if (strVal.containsIgnoreCase('<img')) {
                        for (String originalUrl : resolvedImages.keySet()) {
                            if (strVal.contains(originalUrl)) {
                                strVal = strVal.replace(originalUrl, resolvedImages.get(originalUrl));
                            }
                            // Also handle &amp; encoded version
                            String encodedUrl = originalUrl.replace('&', '&amp;');
                            if (strVal.contains(encodedUrl)) {
                                strVal = strVal.replace(encodedUrl, resolvedImages.get(originalUrl));
                            }
                        }
                        mapData.put(key, strVal);
                    }
                } else {
                    applyResolvedImages(val, resolvedImages);
                }
            }
        } else if (data instanceof List<Object>) {
            for (Object item : (List<Object>) data) {
                applyResolvedImages(item, resolvedImages);
            }
        }
    }

    /**
     * Attempts to build a MergeResult from pre-decomposed XML parts stored as ContentVersions.
     * Skips full ZIP decompression — saves ~1.5-2MB heap for PDF generation.
     * Returns null if pre-decomposed parts are not available (older templates).
     */
    private static MergeResult tryMergeFromPreDecomposed(
        Id templateId,
        Map<String, Object> recordDataMap,
        MergeResult mr
    ) {
        // Cache the template version + XML CV query — identical for every record
        if (cachedPreDecompTemplateId != templateId || cachedXmlParts == null) {
            cachedPreDecompTemplateId = templateId;
            cachedXmlParts = new Map<String, String>();
            cachedPreDecompAvailable = false;

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
            if (activeVersions.isEmpty()) {
                return null;
            }

            String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
            // Use `without sharing` helper: in async contexts (Automated Process user from
            // platform-event-triggered queueable), `with sharing` + SYSTEM_MODE combined
            // still can't see these ContentVersions due to Salesforce's ContentVersion
            // sharing quirk — the user has no ContentDocumentLink rows. Bypass sharing
            // for this internal package-metadata read. (#28)
            List<ContentVersion> xmlCvs = new PreDecompXmlLoader()
                .loadForLinkedEntityByTitlePrefix(activeVersions[0].Id, xmlPrefix);

            if (xmlCvs.isEmpty()) {
                return null;
            }

            for (ContentVersion cv : xmlCvs) {
                String key = cv.Title.substring(xmlPrefix.length());
                cachedXmlParts.put(key, cv.VersionData.toString());
            }
            cachedPreDecompAvailable = true;
        }

        if (!cachedPreDecompAvailable || cachedXmlParts.isEmpty()) {
            return null;
        }

        // Process cached XML parts with this record's data
        for (String key : cachedXmlParts.keySet()) {
            String rawXml = cachedXmlParts.get(key);
            if (key == 'rels') {
                mr.relsXml = rawXml;
            } else if (key == 'word__styles.xml') {
                // Store styles.xml for table style resolution (not merged with record data)
                mr.processedXmlEntries.put('word/styles.xml', rawXml);
            } else if (key == 'word__numbering.xml') {
                // Store numbering.xml for numbered vs bullet list detection
                mr.passthroughEntries.put('word/numbering.xml', Blob.valueOf(rawXml));
            } else {
                // Restore original path: word__document.xml → word/document.xml
                String originalPath = key.replace('__', '/');
                currentTemplateType = mr.templateType;
                String xml = mergeRunsInTags(rawXml);
                xml = processXml(xml, recordDataMap);
                mr.processedXmlEntries.put(originalPath, xml);
                if (originalPath == 'word/document.xml') {
                    mr.documentXml = xml;
                }
                // Headers and footers are already in processedXmlEntries via the put() above
            }
        }

        if (mr.documentXml == null) {
            return null;
        }

        // Process pending images from merge field processing (RTF images, {%Field} images)
        applyPendingImages(mr, true);

        return mr;
    }

    /**
     * Applies pendingImages to the MergeResult:
     *  - Adds PNG/JPEG declarations to [Content_Types].xml (idempotent).
     *  - Adds a <Relationship> entry for each pending image in the rels XML.
     *  - If collectRenderMaps is true, also populates imageBase64ByRelId / imageUrlByRelId
     *    so the HTML renderer and PDF path can resolve each relId.
     *
     * Callers: mergeTemplate (full ZIP path, collectRenderMaps=true),
     *          tryMergeFromPreDecomposed (collectRenderMaps=true),
     *          generateDocumentPartsGiantQuery (collectRenderMaps=false — URL-only, client assembles).
     */
    private static void applyPendingImages(MergeResult mr, Boolean collectRenderMaps) {
        if (pendingImages.isEmpty())
            return;

        if (mr.contentTypesXml != null) {
            if (!mr.contentTypesXml.contains('Extension="png"')) {
                mr.contentTypesXml = mr.contentTypesXml.replace(
                    '</Types>',
                    '<Default Extension="png" ContentType="image/png"/></Types>'
                );
            }
            if (!mr.contentTypesXml.contains('Extension="jpeg"') && !mr.contentTypesXml.contains('Extension="jpg"')) {
                mr.contentTypesXml = mr.contentTypesXml.replace(
                    '</Types>',
                    '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>'
                );
            }
        }

        if (mr.relsXml != null) {
            for (Map<String, Object> img : pendingImages) {
                // PowerPoint images live in ppt/slides/_rels/slideN.xml.rels,
                // not the presentation-level rels — postProcessPowerPointSlides
                // owns that wiring. Skip them here.
                if (img.get('pptHandled') == true) {
                    continue;
                }
                String relId = (String) img.get('relId');
                String fName = (String) img.get('fileName');
                String newRel =
                    '<Relationship Id="' +
                    relId +
                    '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' +
                    fName +
                    '"/>';
                mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
            }
        }

        if (collectRenderMaps) {
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    Blob imgBlob = (Blob) img.get('blob');
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode(imgBlob));
                }
                if (img.containsKey('url')) {
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                    if (!img.containsKey('blob')) {
                        mr.imageBase64ByRelId.put(relId, (String) img.get('url'));
                    }
                }
            }
        }
    }

    /**
     * Assembles a MergeResult into a DOCX/PPTX ZIP Blob.
     */
    private static Blob assembleZip(MergeResult mr) {
        Compression.ZipWriter writer = new Compression.ZipWriter();

        // Keep the OPC package manifest first and package relationships early.
        // PowerPoint is stricter than Word/LibreOffice about generated packages;
        // deterministic ordering avoids repair prompts from brittle readers.
        if (mr.contentTypesXml != null) {
            mr.contentTypesXml = normalizeOpenXmlContentTypes(mr.contentTypesXml);
            writer.addEntry('[Content_Types].xml', Blob.valueOf(mr.contentTypesXml));
        }
        addPassthroughEntryIfPresent(writer, mr, '_rels/.rels');

        // Add processed XML entries in deterministic path order.
        List<String> processedNames = new List<String>(mr.processedXmlEntries.keySet());
        processedNames.sort();
        for (String name : processedNames) {
            writer.addEntry(name, Blob.valueOf(mr.processedXmlEntries.get(name)));
        }

        // Add passthrough entries in deterministic path order, skipping entries
        // already written explicitly above.
        List<String> passthroughNames = new List<String>(mr.passthroughEntries.keySet());
        passthroughNames.sort();
        for (String name : passthroughNames) {
            if (name == '_rels/.rels') {
                continue;
            }
            writer.addEntry(name, mr.passthroughEntries.get(name));
        }

        // Add image blobs (skip URL-only images which are for PDF rendering only)
        for (Map<String, Object> img : pendingImages) {
            if (img.containsKey('blob')) {
                String fName = (String) img.get('fileName');
                Blob imageBlob = (Blob) img.get('blob');
                writer.addEntry(mr.mediaPath + fName, imageBlob);
            }
        }

        if (mr.relsXml != null) {
            writer.addEntry(mr.relsPath, Blob.valueOf(mr.relsXml));
        }

        return writer.getArchive();
    }

    private static void addPassthroughEntryIfPresent(Compression.ZipWriter writer, MergeResult mr, String name) {
        Blob entry = mr.passthroughEntries.get(name);
        if (entry != null) {
            writer.addEntry(name, entry);
        }
    }

    private static String normalizeOpenXmlContentTypes(String contentTypesXml) {
        if (String.isBlank(contentTypesXml)) {
            return contentTypesXml;
        }
        return contentTypesXml.replace('ContentType="image/jpg"', 'ContentType="image/jpeg"');
    }

    private static void stripPowerPointRevisionParts(MergeResult mr) {
        if (mr == null || mr.passthroughEntries == null) {
            return;
        }

        List<String> removeNames = new List<String>();
        for (String name : mr.passthroughEntries.keySet()) {
            if (name == 'ppt/revisionInfo.xml' || name.startsWith('ppt/changesInfos/') || name.startsWith('[trash]/')) {
                removeNames.add(name);
            }
        }
        for (String name : removeNames) {
            mr.passthroughEntries.remove(name);
        }

        if (mr.relsXml != null) {
            mr.relsXml = mr.relsXml.replaceAll('<Relationship\\s+[^>]*(revisionInfo|changesInfo)[^>]*/>', '');
        }
        if (mr.contentTypesXml != null) {
            mr.contentTypesXml = mr.contentTypesXml
                .replaceAll('<Override\\s+PartName="/ppt/revisionInfo\\.xml"[^>]*/>', '')
                .replaceAll('<Override\\s+PartName="/ppt/changesInfos/[^"]+"[^>]*/>', '');
        }
    }

    private static void normalizePowerPointSlideXml(MergeResult mr) {
        if (mr == null || mr.processedXmlEntries == null) {
            return;
        }

        for (String name : new List<String>(mr.processedXmlEntries.keySet())) {
            if (!name.startsWith('ppt/slides/slide') || !name.endsWith('.xml')) {
                continue;
            }
            String slideXml = mr.processedXmlEntries.get(name);
            if (String.isBlank(slideXml)) {
                continue;
            }
            slideXml = slideXml
                .replace('<a:t></a:t>', '<a:t> </a:t>')
                .replace(
                    '<a:tableStyleId></a:tableStyleId>',
                    '<a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId>'
                );
            mr.processedXmlEntries.put(name, slideXml);
        }
    }

    /**
     * Processes a template with record data and returns the result as a Map containing
     * the document Blob, title, output format, and template type. Does NOT save to record.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId) {
        return processDocument(templateId, recordId, null);
    }

    /**
     * Processes a template with optional pre-resolved images from the LWC.
     * The resolvedImages map contains originalUrl → base64DataUri entries
     * fetched by the browser (which has session access to Salesforce URLs).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param resolvedImages Map of originalUrl to base64DataUri for LWC-resolved images
     * @return Map with keys: blob, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocument(Id templateId, Id recordId, Map<String, String> resolvedImages) {
        return processDocument(templateId, recordId, resolvedImages, null);
    }

    /**
     * Processes a template with optional pre-resolved images AND an optional output format override.
     * outputFormatOverride: 'PDF', 'Word', or 'PowerPoint'. Null = use template's Output_Format__c.
     * Throws DocGenException if the override is incompatible with the template type
     * (e.g. PowerPoint template + PDF override) or if the template has Lock_Output_Format__c = true.
     */
    public static Map<String, Object> processDocument(
        Id templateId,
        Id recordId,
        Map<String, String> resolvedImages,
        String outputFormatOverride
    ) {
        validateOutputFormatOverride(templateId, outputFormatOverride);
        MergeResult mr = mergeTemplate(templateId, recordId, resolvedImages, outputFormatOverride);

        Blob resultBlob;
        if (mr.outputFormat == 'PDF' && mr.templateType == 'PDF') {
            resultBlob = mr.pdfBlob;
        } else if (mr.outputFormat == 'PDF' && (mr.templateType == 'Word' || mr.templateType == 'HTML')) {
            resultBlob = renderPdf(mr, templateId, recordId);
        } else {
            resultBlob = assembleZip(mr);
        }

        // Persist anything the render degraded past. Buffered until here so a
        // 2,000-row document cannot spend the DML limit on diagnostics; a
        // successful generation that quietly dropped an image or emptied a chart
        // now leaves a Warning row behind instead of nothing.
        DocGenErrorLogger.flush();

        return new Map<String, Object>{
            'blob' => resultBlob,
            'title' => mr.docTitle,
            'outputFormat' => mr.outputFormat,
            'templateType' => mr.templateType
        };
    }

    /**
     * Validates that a runtime output-format override is allowed for a given template.
     * Rules:
     *   - If template has Lock_Output_Format__c = true, no override is permitted (must be null).
     *   - PowerPoint templates cannot render to PDF (Blob.toPdf only handles Word source).
     *   - Override values must be one of: 'PDF', 'Word', 'PowerPoint'.
     * Throws DocGenException on violation.
     */
    @TestVisible
    private static void validateOutputFormatOverride(Id templateId, String outputFormatOverride) {
        if (String.isBlank(outputFormatOverride))
            return;
        if (
            outputFormatOverride != 'PDF' &&
            outputFormatOverride != 'Word' &&
            outputFormatOverride != 'PowerPoint' &&
            outputFormatOverride != 'HTML'
        ) {
            throw new DocGenException(
                'Invalid output format override: ' + outputFormatOverride + '. Expected PDF, Word, PowerPoint, or HTML.'
            );
        }
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Lock_Output_Format__c', 'Type__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> tpls = [
            SELECT Lock_Output_Format__c, Type__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (tpls.isEmpty())
            return; // mergeTemplate will throw a clearer "template not found" error
        DocGen_Template__c t = tpls[0];
        if (t.Lock_Output_Format__c == true) {
            throw new DocGenException('This template locks its output format. Override not permitted.');
        }
        if (t.Type__c == 'PowerPoint' && outputFormatOverride == 'PDF') {
            throw new DocGenException('PowerPoint templates cannot render to PDF.');
        }
        if (t.Type__c == 'PDF' && outputFormatOverride != 'PDF') {
            throw new DocGenException('PDF AcroForm templates can only output PDF.');
        }
    }

    /**
     * Returns merged document parts for client-side DOCX assembly.
     * No ZIP assembly on server — just the merged XML, updated rels/content types,
     * shell CV ID, and pending image CV IDs. The browser fetches the shell ZIP and
     * images by URL, then assembles the final DOCX client-side (zero heap for ZIP).
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: allXmlParts, imageBase64Map, imageCvIdMap, title, templateType, isMacroEnabled
     */
    public static Map<String, Object> generateDocumentParts(Id templateId, Id recordId) {
        // Use PDF output format to skip image blob loading during merge.
        // Images are collected as CV URLs only — we deduplicate and load once below.
        currentOutputFormat = 'PDF';
        MergeResult mr = mergeTemplate(templateId, recordId);
        currentOutputFormat = 'Native';

        // Collect ALL XML parts for the client to build the ZIP from scratch.
        // Merged entries (document.xml, headers, footers) come from processXml.
        // Passthrough entries (styles, numbering, theme, etc.) come from the template.
        // All are returned as path→string maps — the client assembles the ZIP.
        Map<String, String> allXmlParts = new Map<String, String>(mr.processedXmlEntries);
        if (mr.contentTypesXml != null) {
            mr.contentTypesXml = normalizeOpenXmlContentTypes(mr.contentTypesXml);
            allXmlParts.put('[Content_Types].xml', mr.contentTypesXml);
        }
        if (mr.relsXml != null) {
            allXmlParts.put(mr.relsPath, mr.relsXml);
        }
        // Build the image map up front so the passthrough split below can
        // route non-UTF-8 binaries into it as fallback storage.
        Map<String, String> imageBase64Map = new Map<String, String>();

        // Split passthrough entries into XML (allXmlParts) and binary (imageBase64Map).
        //
        // Word can stamp a `docProps/thumbnail.jpeg` (and occasionally fonts /
        // OLE objects / printerSettings.bin) outside the `word/media/` prefix.
        // The pre-#117 code assumed "anything not under mediaPath is XML text"
        // and called .toString() unconditionally — which throws
        // `BLOB is not a valid UTF-8 string` on those binary entries and aborts
        // the whole generate. Detect-by-trying so XML stays in allXmlParts and
        // binary lands in the base64 image map (which the client-side ZIP
        // writer already handles as a passthrough mediaPath → bytes mapping).
        for (String path : mr.passthroughEntries.keySet()) {
            Blob entryBlob = mr.passthroughEntries.get(path);
            if (path.startsWith(mr.mediaPath)) {
                continue; // handled below in the media base64 loop
            }
            // Known-binary parts (xl/vbaProject.bin, printerSettings*.bin) go straight
            // to base64 — the detect-by-trying split below is probabilistic, and a
            // binary whose bytes happen to decode as valid UTF-8 would survive
            // .toString() and ship re-encoded (corrupt).
            if (path.endsWithIgnoreCase('.bin')) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(entryBlob));
                continue;
            }
            try {
                allXmlParts.put(path, entryBlob.toString());
            } catch (StringException stre) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(entryBlob));
            }
        }

        // Template-embedded media from passthrough (small, already in heap)
        for (String path : mr.passthroughEntries.keySet()) {
            if (path.startsWith(mr.mediaPath)) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(mr.passthroughEntries.get(path)));
            }
        }

        // Dynamic images: return mediaPath → CV ID mapping (not base64)
        // Client calls getContentVersionBase64() for each unique CV in separate transactions.
        // Server-fetched blobs (e.g., rta image callout for Lightning rich text inline
        // images, ContentReference / 0EM prefix) are inlined as base64 — bytes are
        // already in heap and we avoid a temp-CV + DML + cleanup round-trip.
        Map<String, String> imageCvIdMap = new Map<String, String>();
        Map<String, String> imageUrlMap = new Map<String, String>();
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = mr.mediaPath + fileName;
            if (img.containsKey('blob')) {
                imageBase64Map.put(mediaPath, EncodingUtil.base64Encode((Blob) img.get('blob')));
            } else if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                } else if (url.contains('/servlet/') || url.contains('/sfc/')) {
                    // Client checks each URL: rtaImage URLs (rich text inline images)
                    // route through PDF-extract; others are diagnostics-only.
                    imageUrlMap.put(mediaPath, url);
                }
            }
        }

        // Macro-enabled Excel (.xlsm) is detected at generation time from data already
        // in memory — no template schema change. The client derives the download
        // extension (.xlsm) and MIME from this flag.
        Boolean isMacroEnabled = isMacroEnabledWorkbook(mr);

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'imageUrlMap' => imageUrlMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType,
            'isMacroEnabled' => isMacroEnabled
        };
    }

    /**
     * Generates document parts for Giant Query DOCX assembly. Merges the template
     * with a placeholder where the giant child loop belongs. The client injects
     * pre-rendered XML fragments from the harvest batch into this placeholder,
     * then assembles the DOCX ZIP.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID for parent-level merge tags
     * @param giantRelationshipName The child relationship processed by the harvest batch
     * @return Map containing allXmlParts (with placeholder), image maps, title, and placeholder token
     */
    public static Map<String, Object> generateDocumentPartsGiantQuery(
        Id templateId,
        Id recordId,
        String giantRelationshipName
    ) {
        // Use PDF output format to skip image blob loading during merge
        currentOutputFormat = 'PDF';

        // Unique placeholder for the giant loop — client replaces with concatenated fragment XML
        String placeholder = '<!--DOCGEN_GIANT_LOOP_PLACEHOLDER-->';

        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String templateType = (String) dataMap.get('templateType');
        String titleFormat = (String) dataMap.get('titleFormat');

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject) dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        currentTemplateType = templateType;

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = 'Native';
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        String rawDocumentXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                rawDocumentXml = reader.extract(name).toString();
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                Boolean isProcessedXml =
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'));
                if (isProcessedXml) {
                    String xml = mergeRunsInTags(reader.extract(name).toString());
                    xml = processXml(xml, recordDataMap);
                    mr.processedXmlEntries.put(name, xml);
                } else {
                    mr.passthroughEntries.put(name, reader.extract(name));
                }
            }
        }

        if (rawDocumentXml == null) {
            throw new DocGenException('Template does not contain word/document.xml.');
        }

        // Merge runs first, then inject placeholder for the giant loop
        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        String giantLoopBodyXml = '';
        if (loopParts != null) {
            giantLoopBodyXml = loopParts.get('innerXml');
            rawDocumentXml = loopParts.get('beforeLoop') + placeholder + loopParts.get('afterLoop');
        }

        // Process remaining merge tags (parent-level fields, other loops)
        String processedXml = processXml(rawDocumentXml, recordDataMap);
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        mr.docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        // Handle pending images (rels entries needed for DOCX; URL-only for client assembly)
        applyPendingImages(mr, false);

        // Build return maps (same as generateDocumentParts)
        Map<String, String> allXmlParts = new Map<String, String>(mr.processedXmlEntries);
        if (mr.contentTypesXml != null) {
            allXmlParts.put('[Content_Types].xml', mr.contentTypesXml);
        }
        if (mr.relsXml != null) {
            allXmlParts.put(mr.relsPath, mr.relsXml);
        }
        for (String path : mr.passthroughEntries.keySet()) {
            Blob entryBlob = mr.passthroughEntries.get(path);
            if (!path.startsWith(mr.mediaPath)) {
                allXmlParts.put(path, entryBlob.toString());
            }
        }

        Map<String, String> imageBase64Map = new Map<String, String>();
        for (String path : mr.passthroughEntries.keySet()) {
            if (path.startsWith(mr.mediaPath)) {
                imageBase64Map.put(path, EncodingUtil.base64Encode(mr.passthroughEntries.get(path)));
            }
        }

        Map<String, String> imageCvIdMap = new Map<String, String>();
        for (Map<String, Object> img : pendingImages) {
            String fileName = (String) img.get('fileName');
            String mediaPath = 'word/media/' + fileName;
            if (img.containsKey('url')) {
                String url = (String) img.get('url');
                if (url.contains('/version/download/')) {
                    imageCvIdMap.put(mediaPath, url.substringAfterLast('/'));
                }
            }
        }

        currentOutputFormat = 'Native';

        return new Map<String, Object>{
            'allXmlParts' => allXmlParts,
            'imageBase64Map' => imageBase64Map,
            'imageCvIdMap' => imageCvIdMap,
            'title' => mr.docTitle,
            'templateType' => mr.templateType,
            'placeholder' => placeholder,
            'giantLoopBodyXml' => giantLoopBodyXml
        };
    }

    /**
     * Generates a shell PDF for Giant Query: parent data merged, giant loop removed,
     * rendered to PDF via Blob.toPdf(). Also extracts table properties and header row
     * from the template so fragment PDFs can match the table styling.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID for merge tag resolution
     * @param giantRelationshipName The child relationship being harvested
     * @param jobId The DocGen_Job__c record ID (for ContentVersion naming)
     * @return Map with shellCvId, tablePropertiesXml, headerRowXml
     */
    /**
     * Lightweight extraction of table properties, header row, and styles.xml from
     * the template for Giant Query PDF fragment rendering. No record data, no PDF
     * rendering — just reads pre-decomposed XML and extracts structural elements.
     * Shell PDF generation is deferred to a future enhancement.
     */
    public static Map<String, Object> extractGiantQueryFragmentConfig(Id templateId, String giantRelationshipName) {
        // Load only document.xml and styles.xml from pre-decomposed parts
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
        if (activeVersions.isEmpty()) {
            throw new DocGenException('No active template version found.');
        }

        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        String docKey = xmlPrefix + 'word__document.xml';
        String stylesKey = xmlPrefix + 'word__styles.xml';

        String rawDocumentXml = null;
        String capturedStylesXml = null;

        List<ContentVersion> xmlCvs = new PreDecompXmlLoader()
            .loadForLinkedEntityByTitles(activeVersions[0].Id, new Set<String>{ docKey, stylesKey });
        for (ContentVersion cv : xmlCvs) {
            if (cv.Title == docKey) {
                rawDocumentXml = cv.VersionData.toString();
            } else if (cv.Title == stylesKey) {
                capturedStylesXml = cv.VersionData.toString();
            }
        }
        xmlCvs = null;

        if (rawDocumentXml == null) {
            throw new DocGenException('Pre-decomposed template parts not found. Please re-save the template.');
        }

        // Extract <w:sectPr> for page dimensions before mergeRunsInTags modifies content
        String sectPrXml = '';
        Integer sectPrStart = rawDocumentXml.lastIndexOf('<w:sectPr');
        if (sectPrStart != -1) {
            Integer sectPrEnd = rawDocumentXml.indexOf('</w:sectPr>', sectPrStart);
            if (sectPrEnd != -1) {
                sectPrXml = rawDocumentXml.substring(sectPrStart, sectPrEnd + 11);
            }
        }

        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        rawDocumentXml = null;
        String tablePropertiesXml = '';
        String headerRowXml = '';

        if (loopParts != null) {
            String beforeLoop = loopParts.get('beforeLoop');

            // Extract <w:tblPr> for fragment table styling
            Integer tblPrStart = beforeLoop.lastIndexOf('<w:tblPr');
            if (tblPrStart != -1) {
                Integer tblPrEnd = beforeLoop.indexOf('</w:tblPr>', tblPrStart);
                if (tblPrEnd != -1) {
                    tablePropertiesXml = beforeLoop.substring(tblPrStart, tblPrEnd + 10);
                }
            }

            // Extract <w:tblGrid> for column widths
            Integer tblGridStart = beforeLoop.lastIndexOf('<w:tblGrid');
            if (tblGridStart != -1) {
                Integer tblGridEnd = beforeLoop.indexOf('</w:tblGrid>', tblGridStart);
                if (tblGridEnd != -1) {
                    tablePropertiesXml += beforeLoop.substring(tblGridStart, tblGridEnd + 12);
                }
            }

            // Extract last <w:tr> as header row (column labels)
            Integer lastTrStart = beforeLoop.lastIndexOf('<w:tr');
            if (lastTrStart != -1) {
                Integer trEnd = beforeLoop.indexOf('</w:tr>', lastTrStart);
                if (trEnd != -1) {
                    headerRowXml = beforeLoop.substring(lastTrStart, trEnd + 7);
                }
            }
        }

        // Extract per-column CSS from the loop row's formatting
        String columnCss = '';
        if (loopParts != null) {
            columnCss = DocGenGiantQueryBatch.extractColumnCss(loopParts.get('innerXml'));
        }

        return new Map<String, Object>{
            'tablePropertiesXml' => tablePropertiesXml,
            'headerRowXml' => headerRowXml,
            'stylesXml' => capturedStylesXml,
            'sectPrXml' => sectPrXml,
            'columnCss' => columnCss
        };
    }

    /**
     * Merges the full template with parent record data, removes the giant loop,
     * converts to HTML, and injects a placeholder where the table rows should go.
     * Called by DocGenGiantQueryAssembler (Queueable, 12MB heap) to produce
     * a complete HTML document with before/after content, headers, footers, images.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The parent record ID for merge tag resolution
     * @param giantRelationshipName The child relationship being harvested
     * @param placeholder String to inject where the giant loop table rows go
     * @return Complete HTML string with placeholder for table row injection
     */
    public static String mergeTemplateForGiantQueryPdf(
        Id templateId,
        Id recordId,
        String giantRelationshipName,
        String placeholder
    ) {
        currentOutputFormat = 'PDF';
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        // Get parent-only record data (strip all children from config)
        // CxSAST: USER_MODE not viable in managed package (namespace resolution breaks unqualified field names); CRUD/FLS enforced by permission sets
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{ 'Base_Object_API__c', 'Query_Config__c', 'Type__c', 'Document_Title_Format__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c, Query_Config__c, Type__c, Document_Title_Format__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new DocGenException('Template not found: ' + templateId);
        }
        DocGen_Template__c template = templates[0];

        String shellConfig = template.Query_Config__c;
        if (shellConfig != null && shellConfig.trim().startsWith('{')) {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(shellConfig.trim());
            List<Object> nodes = (List<Object>) configMap.get('nodes');
            if (nodes != null) {
                List<Object> rootOnly = new List<Object>();
                for (Object nodeObj : nodes) {
                    Map<String, Object> node = (Map<String, Object>) nodeObj;
                    if (node.get('parentNode') == null) {
                        rootOnly.add(node);
                    }
                }
                configMap.put('nodes', rootOnly);
                shellConfig = JSON.serialize(configMap);
            }
        } else if (shellConfig != null) {
            shellConfig = shellConfig.replaceAll('\\(\\s*SELECT\\s+[^)]+\\)', '');
            shellConfig = shellConfig.replaceAll(',\\s*,', ',').replaceAll(',\\s*$', '').trim();
        }

        Map<String, Object> recordDataMap = DocGenDataRetriever.getRecordData(
            recordId,
            template.Base_Object_API__c,
            shellConfig
        );
        shellConfig = null;

        currentTemplateType = template.Type__c;

        MergeResult mr = new MergeResult();
        mr.templateType = template.Type__c;
        mr.outputFormat = 'PDF';
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        // Load pre-decomposed XML parts
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
        String xmlPrefix = 'docgen_tmpl_xml_' + activeVersions[0].Id + '_';
        // SYSTEM_MODE is required: this runs in async contexts (signature PDF queueable
        // triggered by platform event → Automated Process user) that don't have FLS access
        // to the package-internal pre-decomposed XML ContentVersions. USER_MODE silently
        // returned empty in that context, which is why the signed PDF path lost table-style
        // borders for guest-triggered signatures (#28). Template access is already gated by
        // Portwood permission sets; reading the pre-decomposed artifacts in system mode is safe.
        List<ContentVersion> xmlCvs = new PreDecompXmlLoader()
            .loadForLinkedEntityByTitlePrefix(activeVersions[0].Id, xmlPrefix);

        String rawDocumentXml = null;
        for (ContentVersion cv : xmlCvs) {
            String key = cv.Title.substring(xmlPrefix.length());
            String rawXml = cv.VersionData.toString();
            if (key == 'rels') {
                mr.relsXml = rawXml;
            } else if (key == 'word__styles.xml') {
                mr.processedXmlEntries.put('word/styles.xml', rawXml);
            } else if (key == 'word__document.xml') {
                rawDocumentXml = rawXml;
            } else {
                String originalPath = key.replace('__', '/');
                if (originalPath.startsWith('word/header') || originalPath.startsWith('word/footer')) {
                    rawXml = mergeRunsInTags(rawXml);
                    rawXml = processXml(rawXml, recordDataMap);
                    mr.processedXmlEntries.put(originalPath, rawXml);
                }
            }
        }
        xmlCvs = null;

        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        // Replace giant loop with placeholder wrapped in a DOCX paragraph so it
        // survives the XML→HTML conversion (XML comments get stripped by the renderer)
        Map<String, String> loopParts = extractLoopBody(rawDocumentXml, giantRelationshipName);
        if (loopParts != null) {
            String xmlPlaceholder = '<w:p><w:r><w:t>' + placeholder + '</w:t></w:r></w:p>';
            rawDocumentXml = loopParts.get('beforeLoop') + xmlPlaceholder + loopParts.get('afterLoop');
        }
        loopParts = null;

        String processedXml = processXml(rawDocumentXml, recordDataMap);
        rawDocumentXml = null;
        recordDataMap = null;
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        // Handle images
        for (Map<String, Object> img : pendingImages) {
            String relId = (String) img.get('relId');
            if (img.containsKey('url')) {
                mr.imageUrlByRelId.put(relId, (String) img.get('url'));
            }
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
        if (mr.processedXmlEntries.containsKey('word/styles.xml')) {
            DocGenHtmlRenderer.stylesXml = mr.processedXmlEntries.get('word/styles.xml');
        }
        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
        mr = null;
        pdfImages = null;

        currentOutputFormat = 'Native';
        return html;
    }

    /**
     * Async wrapper around extractAndSaveTemplateImages — enqueues the heap-heavy
     * decompose-and-save in a Queueable so it runs in 12 MB async heap rather than
     * the 6 MB sync heap that silently broke pre-decomposition for templates above
     * ~3 MB binary. Use this from any AuraEnabled / Lightning-file-upload save flow
     * where the original DOCX may be too large for inline server-side decomposition.
     */
    public static void enqueueTemplateImageExtraction(Id templateId, Id versionId) {
        if (templateId == null || versionId == null) {
            return;
        }
        System.enqueueJob(new DocGenTemplateDecomposeQueueable(templateId, versionId));
    }

    public class DocGenTemplateDecomposeQueueable implements Queueable {
        private final Id templateId;
        private final Id versionId;

        public DocGenTemplateDecomposeQueueable(Id templateId, Id versionId) {
            this.templateId = templateId;
            this.versionId = versionId;
        }

        public void execute(QueueableContext ctx) {
            String status = 'Complete';
            try {
                extractAndSaveTemplateImages(templateId, versionId);
            } catch (Exception e) {
                status = 'Failed';
                System.debug(
                    LoggingLevel.ERROR,
                    'DocGenTemplateDecomposeQueueable failed for version ' +
                        versionId +
                        ': ' +
                        e.getMessage() +
                        '\n' +
                        e.getStackTraceString()
                );
            }
            try {
                DocGen_Template_Version__c v = new DocGen_Template_Version__c(
                    Id = versionId,
                    Pre_Decomposition_Status__c = status
                );
                /* code-analyzer-suppress ApexFlsViolation */
                update v; // NOPMD — package-internal custom object
            } catch (Exception updateErr) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Failed to update Pre_Decomposition_Status__c for ' + versionId + ': ' + updateErr.getMessage()
                );
            }
        }
    }

    /**
     * Returns the raw word/document.xml for a template's active version, read on-demand
     * straight from the template ContentVersion blob — NO pre-decomposed
     * docgen_tmpl_xml_* ContentVersions required.
     *
     * The signature placement parser (DocGenSignatureSenderController.extractTemplatePlainText)
     * normally reads its <w:t> text from those pre-decomposed CVs, which only exist once the
     * async decomposition (extractAndSaveTemplateImages) has run for the active version. A
     * template whose active version was never (re-)decomposed — e.g. a docx replaced/re-saved
     * during org build-out — has none, so the parser finds zero {@Signature_*} placements and
     * the send silently falls back to the synthetic "Signatures" block, leaking the authored
     * inline {@Signature_*:inline} tags as raw text (Sarah's SHWaiver bug). This getter lets
     * the parser self-heal by reading document.xml the same way the merge path already does.
     *
     * Returns null if there is no active version CV or the docx lacks word/document.xml.
     */
    public static String getActiveTemplateDocumentXml(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal custom object
        if (vers.isEmpty() || vers[0].Content_Version_Id__c == null) {
            return null;
        }
        Id cvId = (Id) vers[0].Content_Version_Id__c;
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :cvId
            WITH SYSTEM_MODE
            LIMIT 1
        ]; // NOPMD ApexCRUDViolation - package-internal CV read
        if (cvs.isEmpty() || cvs[0].VersionData == null) {
            return null;
        }
        Compression.ZipReader reader = new Compression.ZipReader(cvs[0].VersionData);
        for (Compression.ZipEntry entry : reader.getEntries()) {
            if (entry.getName() == 'word/document.xml') {
                return reader.extract(entry.getName()).toString();
            }
        }
        return null;
    }

    /**
     * Extracts images from a template DOCX/PPTX file and saves them as ContentVersion
     * records linked to the template version. These committed CVs provide stable URLs
     * for Blob.toPdf() which cannot render data URI images (Flying Saucer limitation).
     * Each version gets its own set of images — no duplicates or confusion.
     *
     * Heap-heavy on bigger templates (a 9 MB DOCX uses ~9 MB Blob + ZipReader state +
     * per-entry blobs simultaneously). Always invoke via enqueueTemplateImageExtraction
     * from AuraEnabled save paths so it runs in 12 MB async heap. Direct callers (tests,
     * scratch demos) are still allowed if they know the template fits in the current heap.
     *
     * @param templateId The DocGen_Template__c record ID
     * @param versionId The DocGen_Template_Version__c record ID to link images to
     */
    /**
     * #203 — removes a version's existing docgen_tmpl_* snapshot documents so a
     * re-decomposition can never leave duplicate-title snapshots behind. Scoped to
     * documents LINKED TO THIS VERSION whose titles carry this version's Id, so the
     * body CV, watermark, and other versions' snapshots are untouchable. Best-effort:
     * cleanup failure must never block the decomposition that follows.
     */
    private static void deleteSnapshotCvsForVersion(Id versionId) {
        try {
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :versionId
                WITH SYSTEM_MODE // NOPMD — package-internal snapshot cleanup
            ];
            if (links.isEmpty()) {
                return;
            }
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink l : links) {
                docIds.add(l.ContentDocumentId);
            }
            String vid = String.valueOf(versionId);
            String htmlTitle = 'docgen_tmpl_html_' + vid;
            String xmlPrefix = 'docgen_tmpl_xml_' + vid + '_%';
            String imgPrefix = 'docgen_tmpl_img_' + vid + '_%';
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDocument> stale = [
                SELECT Id
                FROM ContentDocument
                WHERE Id IN :docIds AND (Title = :htmlTitle OR Title LIKE :xmlPrefix OR Title LIKE :imgPrefix)
                WITH SYSTEM_MODE // NOPMD — package-internal snapshot cleanup
            ];
            if (!stale.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                Database.delete(stale, false, AccessLevel.SYSTEM_MODE);
            }
        } catch (Exception cleanupErr) {
            System.debug(
                LoggingLevel.WARN,
                'Portwood: snapshot cleanup before re-decompose failed (continuing): ' + cleanupErr.getMessage()
            );
        }
    }

    public static void extractAndSaveTemplateImages(Id templateId, Id versionId) {
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Type__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            return;
        }
        String templateType = templates[0].Type__c;

        // Word + PowerPoint files are zipped OOXML archives we can decompose.
        // HTML templates are plain text bodies and Excel templates aren't packaged
        // here either — neither path has a ZIP to extract media from. Short-circuit
        // before we hand the bytes to ZipReader, which otherwise throws
        // "Error on ZipFile unknown archive" on every HTML save.
        if (templateType != 'Word' && templateType != 'PowerPoint') {
            return;
        }

        // #203 — decomposition must be idempotent. A re-run for the same version
        // (on-demand decompose, queueable retry) used to ADD a second set of
        // identically-titled snapshot CVs; readers take the first match, so the
        // oldest duplicate silently shadowed the fresh snapshot forever. Clear
        // this version's prior docgen_tmpl_* artifacts before regenerating.
        deleteSnapshotCvsForVersion(versionId);

        // Read the template CV's VersionData directly as a Blob — bypasses the
        // base64 round-trip in getTemplateFileContent (which would put a ~12 MB
        // string in heap on top of the ~9 MB Blob, blowing past even the 12 MB
        // async heap on real-world templates).
        Id sourceCvId = null;
        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c', 'Template__c', 'Is_Active__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> activeVers = [
            SELECT Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!activeVers.isEmpty() && activeVers[0].Content_Version_Id__c != null) {
            sourceCvId = (Id) activeVers[0].Content_Version_Id__c;
        }
        if (sourceCvId == null) {
            DocGenFlsGuard.assertAccessible(
                ContentDocumentLink.sObjectType,
                new Set<String>{ 'ContentDocumentId', 'LinkedEntityId' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :templateId
                WITH SYSTEM_MODE
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT 1
            ];
            if (!links.isEmpty()) {
                sourceCvId = (Id) links[0].ContentDocument.LatestPublishedVersionId;
            }
        }
        if (sourceCvId == null) {
            return;
        }
        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'VersionData' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :sourceCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            return;
        }
        Blob templateBlob = cvs[0].VersionData;
        cvs = null; // release the SObject wrapper, keep just the Blob
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);

        // Determine paths based on template type
        String relsPath;
        String mediaPath;
        if (templateType == 'PowerPoint') {
            relsPath = 'ppt/_rels/presentation.xml.rels';
            mediaPath = 'ppt/media/';
        } else {
            relsPath = 'word/_rels/document.xml.rels';
            mediaPath = 'word/media/';
        }

        String relsXml = null;
        Map<String, String> additionalRelsXmls = new Map<String, String>(); // partPrefix → rels XML
        Map<String, Blob> mediaEntries = new Map<String, Blob>();
        Map<String, String> xmlEntries = new Map<String, String>();

        // Single-pass classification — extract each entry on demand and only
        // retain what we need (rels strings, merged XML strings, media blobs).
        // Earlier code held every entry's bytes in `allEntries` simultaneously
        // (~9 MB of redundant heap on a real-world template). Each iteration's
        // `entryBlob` falls out of scope as soon as the loop advances.
        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            Boolean wantBlob =
                name == relsPath ||
                (templateType == 'Word' &&
                name.startsWith('word/_rels/') &&
                (name.contains('header') || name.contains('footer')) &&
                name.endsWith('.rels')) ||
                name.startsWith(mediaPath) ||
                (templateType == 'Word' &&
                (name == 'word/document.xml' ||
                name == 'word/styles.xml' ||
                name == 'word/numbering.xml' ||
                (name.startsWith('word/header') && name.endsWith('.xml')) ||
                (name.startsWith('word/footer') && name.endsWith('.xml')))) ||
                (templateType == 'PowerPoint' &&
                name.startsWith('ppt/slides/slide') &&
                name.endsWith('.xml'));
            if (!wantBlob) {
                // Skip the extract entirely — saves heap on theme.xml, settings.xml,
                // fontTable.xml, webSettings.xml, etc., which we never use.
                continue;
            }

            Blob entryBlob = reader.extract(name);

            if (name == relsPath) {
                relsXml = entryBlob.toString();
            } else if (
                templateType == 'Word' &&
                name.startsWith('word/_rels/') &&
                (name.contains('header') || name.contains('footer')) &&
                name.endsWith('.rels')
            ) {
                // Header/footer relationship files contain image references
                String partPrefix = name.substringAfterLast('/').substringBefore('.xml.rels');
                additionalRelsXmls.put(partPrefix, entryBlob.toString());
            } else if (name.startsWith(mediaPath)) {
                mediaEntries.put(name, entryBlob);
            }

            // Identify XML parts that get merged/replaced at generation time
            if (templateType == 'Word') {
                if (
                    name == 'word/document.xml' ||
                    name == 'word/styles.xml' ||
                    name == 'word/numbering.xml' ||
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'))
                ) {
                    xmlEntries.put(name, entryBlob.toString());
                }
            } else if (templateType == 'PowerPoint') {
                if (name.startsWith('ppt/slides/slide') && name.endsWith('.xml')) {
                    xmlEntries.put(name, entryBlob.toString());
                }
            }
        }

        // Pre-flight image-overflow warning. Walks every wp:extent in document/header/footer
        // XML and warns when any image's display width exceeds the page content area.
        // Even with v1.80's HTML width/height attribute fix (#58), an image whose authored
        // wp:extent itself exceeds the page width will still overflow — that's an authoring
        // issue Word silently lets through and we can surface here for admins to fix.
        if (templateType == 'Word') {
            logImageOverflowWarnings(versionId, xmlEntries);
        }

        List<ContentVersion> newCvs = new List<ContentVersion>();

        // Save pre-decomposed XML parts as ContentVersions for heap-efficient PDF generation.
        // At render time, these are queried directly instead of decompressing the full ZIP.
        String xmlPrefix = 'docgen_tmpl_xml_' + versionId + '_';
        for (String xmlName : xmlEntries.keySet()) {
            // Use a safe filename: word/document.xml → word__document.xml
            String safeKey = xmlName.replace('/', '__');
            ContentVersion xmlCv = new ContentVersion();
            xmlCv.Title = xmlPrefix + safeKey;
            xmlCv.PathOnClient = xmlPrefix + safeKey;
            xmlCv.VersionData = Blob.valueOf(xmlEntries.get(xmlName));
            xmlCv.FirstPublishLocationId = versionId;
            newCvs.add(xmlCv);
        }

        // Save rels XML for image relId mapping during PDF generation
        // Combine document rels with header/footer rels so all image relIds are resolvable
        String combinedRels = relsXml != null ? relsXml : '';
        for (String hfRels : additionalRelsXmls.values()) {
            combinedRels += hfRels;
        }
        if (String.isNotBlank(combinedRels)) {
            ContentVersion relsCv = new ContentVersion();
            relsCv.Title = xmlPrefix + 'rels';
            relsCv.PathOnClient = xmlPrefix + 'rels.xml';
            relsCv.VersionData = Blob.valueOf(combinedRels);
            relsCv.FirstPublishLocationId = versionId;
            newCvs.add(relsCv);
        }

        // Parse rels (document + header/footer) and save each image as a ContentVersion
        if (!mediaEntries.isEmpty()) {
            String imgPrefix = 'docgen_tmpl_img_' + versionId + '_';
            Set<String> savedKeys = new Set<String>();

            // Build list of (partPrefix, relsXml) pairs: document gets empty prefix
            List<List<String>> allRelsPairs = new List<List<String>>();
            if (relsXml != null) {
                allRelsPairs.add(new List<String>{ '', relsXml });
            }
            for (String partPrefix : additionalRelsXmls.keySet()) {
                allRelsPairs.add(new List<String>{ partPrefix, additionalRelsXmls.get(partPrefix) });
            }

            for (List<String> pair : allRelsPairs) {
                String partPrefix = pair[0];
                String currentRels = pair[1];
                Integer relCursor = 0;
                while (relCursor < currentRels.length()) {
                    Integer relStart = currentRels.indexOf('<Relationship ', relCursor);
                    if (relStart == -1) {
                        break;
                    }
                    Integer relSelfClose = currentRels.indexOf('/>', relStart);
                    Integer relClose = currentRels.indexOf('>', relStart);
                    if (relClose == -1) {
                        break;
                    }
                    Integer relEnd = (relSelfClose != -1 && relSelfClose < relClose) ? relSelfClose + 2 : relClose + 1;

                    String relTag = currentRels.substring(relStart, relEnd);
                    String relType = extractXmlAttrValue(relTag, 'Type');
                    if (relType != null && relType.contains('/image')) {
                        String relId = extractXmlAttrValue(relTag, 'Id');
                        String target = extractXmlAttrValue(relTag, 'Target');
                        String saveKey = String.isNotBlank(partPrefix) ? partPrefix + '_' + relId : relId;
                        if (
                            relId != null &&
                            target != null &&
                            target.startsWith('media/') &&
                            !savedKeys.contains(saveKey)
                        ) {
                            String fullPath = mediaPath + target.substringAfter('media/');
                            Blob imgBlob = mediaEntries.get(fullPath);
                            if (imgBlob != null) {
                                String ext = target.substringAfterLast('.');
                                ContentVersion cv = new ContentVersion();
                                cv.Title = imgPrefix + saveKey;
                                cv.PathOnClient = imgPrefix + saveKey + '.' + ext;
                                cv.VersionData = imgBlob;
                                cv.FirstPublishLocationId = versionId;
                                newCvs.add(cv);
                                savedKeys.add(saveKey);
                            }
                        }
                    }
                    relCursor = relEnd;
                }
            }
        }

        // Insert image + XML CVs BEFORE building pre-baked HTML, so buildPdfImageMap
        // can find the image ContentVersions via SOQL.
        if (!newCvs.isEmpty()) {
            SObjectAccessDecision preDec = Security.stripInaccessible(AccessType.CREATABLE, newCvs);
            insert preDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            newCvs.clear();
        }

        // Pre-bake HTML version of the template for Giant Query PDF.
        // Loop tags ({#Rel}...{/Rel}) are preserved as HTML comments so the
        // assembler can find and replace them with rendered data at generation time.
        // This avoids all DOCX XML parsing at generation time — just string replace + Blob.toPdf().
        if (templateType == 'Word' && xmlEntries.containsKey('word/document.xml')) {
            try {
                String docXml = xmlEntries.get('word/document.xml');
                MergeResult htmlMr = new MergeResult();
                htmlMr.templateType = 'Word';
                htmlMr.outputFormat = 'PDF';
                htmlMr.relsPath = relsPath;
                htmlMr.mediaPath = mediaPath;
                htmlMr.relsXml = relsXml;

                // Add styles, headers, footers to the MergeResult
                for (String xmlName : xmlEntries.keySet()) {
                    if (xmlName == 'word/styles.xml') {
                        htmlMr.processedXmlEntries.put(xmlName, xmlEntries.get(xmlName));
                    } else if (xmlName.startsWith('word/header') || xmlName.startsWith('word/footer')) {
                        htmlMr.processedXmlEntries.put(xmlName, mergeRunsInTags(xmlEntries.get(xmlName)));
                    }
                }

                // Merge runs so tags are complete, but DON'T process merge fields —
                // leave {Field} tags intact for generation-time replacement
                docXml = mergeRunsInTags(docXml);
                htmlMr.documentXml = docXml;
                htmlMr.processedXmlEntries.put('word/document.xml', docXml);

                // Build image map — image CVs were inserted above so SOQL can find them
                Map<String, String> pdfImages = buildPdfImageMap(htmlMr, templateId);
                if (htmlMr.processedXmlEntries.containsKey('word/styles.xml')) {
                    DocGenHtmlRenderer.stylesXml = htmlMr.processedXmlEntries.get('word/styles.xml');
                }
                setNumberingXml(htmlMr);
                applyWatermarkOverride(templateId);

                String templateHtml = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(htmlMr), pdfImages);
                htmlMr = null;

                // Save pre-baked HTML as ContentVersion
                ContentVersion htmlCv = new ContentVersion();
                htmlCv.Title = 'docgen_tmpl_html_' + versionId;
                htmlCv.PathOnClient = 'docgen_tmpl_html_' + versionId + '.html';
                htmlCv.VersionData = Blob.valueOf(templateHtml);
                htmlCv.FirstPublishLocationId = versionId;
                newCvs.add(htmlCv);
            } catch (Exception htmlErr) {
                // Non-fatal — Giant Query will fall back to runtime conversion
                String noop = htmlErr.getMessage(); // NOPMD
            }
        }

        if (!newCvs.isEmpty()) {
            SObjectAccessDecision cvDecision = Security.stripInaccessible(AccessType.CREATABLE, newCvs);
            insert cvDecision.getRecords();
        }
    }

    /**
     * Builds a URL-based image map for PDF rendering via Blob.toPdf().
     * Looks up pre-committed template image ContentVersions (saved at version publish time)
     * and adds RTF/dynamic image URLs. Returns relId → absolute URL map.
     */
    private static Map<String, String> buildPdfImageMap(MergeResult mr, Id templateId) {
        Map<String, String> pdfImages = new Map<String, String>();

        // 1. Template-embedded images: committed CVs linked to active version
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
        if (!activeVersions.isEmpty()) {
            Id versionId = activeVersions[0].Id;
            String prefix = 'docgen_tmpl_img_' + versionId + '_';
            // Two-step lookup: a plain `Title LIKE …` query against ContentVersion silently
            // returns zero rows when run as the Automated Process user (e.g. platform-event
            // triggers like the signature PDF render), which would break image lookups by
            // emptying the image map. Direct Id-based and ContentDocumentId-IN queries
            // succeed under that user, so scope through the version's CDLs first to get the
            // file IDs the user can see, then apply the title-prefix filter.
            Set<Id> versionDocIds = new Set<Id>();
            for (ContentDocumentLink cdl : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :versionId
            ]) {
                versionDocIds.add(cdl.ContentDocumentId);
            }
            if (!versionDocIds.isEmpty()) {
                DocGenFlsGuard.assertAccessible(
                    ContentVersion.sObjectType,
                    new Set<String>{ 'Title', 'ContentDocumentId', 'IsLatest' }
                );
                /* code-analyzer-suppress ApexFlsViolation */
                List<ContentVersion> tmplCvs = [
                    SELECT Id, Title
                    FROM ContentVersion
                    WHERE ContentDocumentId IN :versionDocIds AND Title LIKE :(prefix + '%') AND IsLatest = TRUE
                    WITH SYSTEM_MODE
                ]; // NOPMD ApexCRUDViolation — package-internal decomposed CVs, see comment above
                for (ContentVersion cv : tmplCvs) {
                    String relId = cv.Title.substring(prefix.length());
                    pdfImages.put(relId, '/sfc/servlet.shepherd/version/download/' + cv.Id);
                }
            }
        }

        // 2. RTF/dynamic images: use relative Salesforce URLs for Blob.toPdf()
        for (String relId : mr.imageUrlByRelId.keySet()) {
            String url = mr.imageUrlByRelId.get(relId);
            // Strip domain if absolute — Blob.toPdf() only resolves relative paths
            if (url.startsWithIgnoreCase('http')) {
                Integer pathStart = url.indexOf('/sfc/');
                if (pathStart == -1) {
                    pathStart = url.indexOf('/servlet/');
                }
                if (pathStart != -1) {
                    url = url.substring(pathStart);
                }
            }
            pdfImages.put(relId, url);
        }

        return pdfImages;
    }

    /**
     * Blob.toPdf() fetches relative shepherd image URLs as the running user. Template
     * asset images can be linked only to Portwood's internal version records, so a
     * non-owner/non-admin user who can read the shared template may still see broken
     * images in the rendered PDF. Before calling Blob.toPdf(), link only referenced
     * template-owned image files to the source record so the running user can fetch
     * the existing /sfc/servlet.shepherd/version/download/<cvId> URL without loading
     * image blobs into heap.
     */
    public static void ensureTemplateAssetImageAccessForPdf(Id templateId, Id recordId, String html) {
        pendingRenderImageLinkIds.clear();
        if (templateId == null || recordId == null || String.isBlank(html) || !html.contains('/version/download/')) {
            return;
        }

        Set<Id> referencedCvIds = extractShepherdContentVersionIds(html);
        if (referencedCvIds.isEmpty()) {
            return;
        }

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
        if (activeVersions.isEmpty()) {
            return;
        }

        String versionId = String.valueOf(activeVersions[0].Id);
        String templateIdText = String.valueOf(templateId);
        List<String> assetPrefixes = new List<String>{
            'docgen_tmpl_img_' +
            versionId +
            '_',
            'docgen_html_img_' +
            versionId +
            '_',
            'docgen_html_img_' +
            templateIdText +
            '_',
            // Admin-uploaded watermark (docgen_watermark_<versionId>) — the CV
            // is published to the VERSION record, so without a record link the
            // PDF service's shepherd fetch fails and the watermark renders as
            // a broken (invisible) image.
            'docgen_watermark_'
        };

        DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>{ 'Title', 'ContentDocumentId' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> referenced = [
            SELECT Id, Title, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :referencedCvIds
            WITH SYSTEM_MODE
        ];

        Set<Id> assetDocIds = new Set<Id>();
        for (ContentVersion cv : referenced) {
            Boolean isTemplateAsset = false;
            for (String prefix : assetPrefixes) {
                if (cv.Title != null && cv.Title.startsWith(prefix)) {
                    isTemplateAsset = true;
                    break;
                }
            }
            if (isTemplateAsset && cv.ContentDocumentId != null) {
                assetDocIds.add(cv.ContentDocumentId);
            }
        }
        if (assetDocIds.isEmpty()) {
            // Body no longer references any template-owned images — still prune
            // links earlier generations left behind.
            pruneStaleTemplateImageLinks(templateId, recordId, versionId, assetDocIds);
            return;
        }

        Set<Id> alreadyLinked = new Set<Id>();
        /* code-analyzer-suppress ApexFlsViolation */
        for (ContentDocumentLink existing : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId AND ContentDocumentId IN :assetDocIds
            WITH SYSTEM_MODE
        ]) {
            alreadyLinked.add(existing.ContentDocumentId);
        }

        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Id docId : assetDocIds) {
            if (alreadyLinked.contains(docId)) {
                continue;
            }
            links.add(
                new ContentDocumentLink(
                    ContentDocumentId = docId,
                    LinkedEntityId = recordId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                )
            );
        }
        if (!links.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(links, false, AccessLevel.SYSTEM_MODE);
            // Remember what we linked so a repeat render of the same pair in one
            // transaction can clean up by Id without re-querying (see
            // removeTemplateImageLinksAfterRender).
            for (ContentDocumentLink link : links) {
                if (link.Id != null) {
                    pendingRenderImageLinkIds.add(link.Id);
                }
            }
        }

        pruneStaleTemplateImageLinks(templateId, recordId, versionId, assetDocIds);
    }

    /**
     * #202 follow-up: the links ensureTemplateAssetImageAccessForPdf creates are
     * only needed while Blob.toPdf() fetches the shepherd URLs inside the same
     * transaction — the rendered PDF embeds the image bytes. Once the render
     * completes, remove EVERY template-image link on the record (the current
     * body's set included) so generation never leaves image Files on the target
     * record — the prune-with-keep pass alone can never remove the current set,
     * which is why a first generation on a fresh record still stranded the full
     * image set. Null active version + empty keep-set make the prune treat the
     * whole title-scoped set as stale, which also sweeps links stranded on the
     * record by earlier package versions.
     */
    public static void removeTemplateImageLinksAfterRender(Id templateId, Id recordId, String renderedHtml) {
        if (templateId == null || recordId == null) {
            return;
        }
        // SOQL budget guard (the prune costs 2 queries): skip when the rendered
        // body references no CV images — nothing was linked this run, mirroring
        // ensureTemplateAssetImageAccessForPdf's own early return — and sweep a
        // given (template, record) pair at most once per transaction so bulk
        // loops don't repay the cost per document. Callers without the html in
        // scope (giant-query assembler frees it before this point) pass null and
        // always sweep. Unguarded, e2e-03's many generations in one anonymous
        // transaction blew the 101-SOQL governor.
        if (renderedHtml != null && !renderedHtml.contains('/version/download/')) {
            return;
        }
        String pairKey = String.valueOf(templateId) + ':' + String.valueOf(recordId);
        if (sweptImageLinkPairs.contains(pairKey)) {
            // Already fully swept this transaction — the only links that can have
            // come back are the ones this render's ensure call just inserted;
            // delete exactly those by Id (no queries).
            if (!pendingRenderImageLinkIds.isEmpty()) {
                /* code-analyzer-suppress ApexFlsViolation */
                Database.delete(new List<Id>(pendingRenderImageLinkIds), false, AccessLevel.SYSTEM_MODE);
                pendingRenderImageLinkIds.clear();
            }
            return;
        }
        sweptImageLinkPairs.add(pairKey);
        pendingRenderImageLinkIds.clear();
        pruneStaleTemplateImageLinks(templateId, recordId, null, new Set<Id>());
    }

    // (template, record) pairs already swept this transaction — see above.
    private static Set<String> sweptImageLinkPairs = new Set<String>();
    // CDL Ids the current render's ensure call inserted (cleared on each ensure).
    private static List<Id> pendingRenderImageLinkIds = new List<Id>();

    /**
     * Removes orphaned template-image ContentDocumentLinks that earlier
     * generations attached to this record. `ensureTemplateAssetImageAccessForPdf`
     * links the body's referenced images to the record so Blob.toPdf can read
     * them, but stale links pile up in the record's Files (the "hundreds of
     * images on the record" report) via two naming schemes:
     *
     *   1. Version-keyed (`docgen_(html|tmpl)_img_<versionId>_<name>`, server-side
     *      decomposition): every template re-save mints a new version with fresh
     *      image CVs; links for OLD versions of THIS template are stale.
     *   2. Template-keyed (`docgen_html_img_<templateId>_<epochMillis>_<name>`,
     *      DocGenController.saveHtmlTemplateImage — the LWC zip-upload flow):
     *      every body re-upload mints new timestamped CVs regardless of version
     *      rows, so staleness can't be determined from version membership at all.
     *      Any link with THIS template's id in the title that the current body no
     *      longer references is stale. (#202 — v3.26 only handled scheme 1, so
     *      LWC-uploaded images were never pruned.)
     *
     * Links whose docs the current body references (`keepDocIds`) are never
     * touched, so rendering is unaffected; other templates' images and
     * user-attached files never match either scheme's title scope.
     */
    private static void pruneStaleTemplateImageLinks(
        Id templateId,
        Id recordId,
        String activeVersionId,
        Set<Id> keepDocIds
    ) {
        // All version Ids for this template — scopes the prune to THIS template so
        // we never delete another template's (or a user's own) attached images.
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> templateVersions = [
            SELECT Id
            FROM DocGen_Template_Version__c
            WHERE Template__c = :templateId
            WITH SYSTEM_MODE
        ];
        Set<Id> templateVersionIds = new Map<Id, DocGen_Template_Version__c>(templateVersions).keySet();

        // 15-char id prefix matches both 15- and 18-char stored title forms, and
        // cannot collide with another record's 18-char id.
        String templateKeyedPrefix = 'docgen_html_img_' + String.valueOf(templateId).substring(0, 15);

        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentDocumentLink> recordImgLinks = [
            SELECT Id, ContentDocumentId, ContentDocument.Title
            FROM ContentDocumentLink
            WHERE
                LinkedEntityId = :recordId
                AND (ContentDocument.Title LIKE 'docgen_html_img_%'
                OR ContentDocument.Title LIKE 'docgen_tmpl_img_%'
                OR ContentDocument.Title LIKE 'docgen_watermark_%')
            WITH SYSTEM_MODE
        ];

        List<ContentDocumentLink> staleLinks = new List<ContentDocumentLink>();
        for (ContentDocumentLink link : recordImgLinks) {
            if (keepDocIds.contains(link.ContentDocumentId)) {
                continue; // referenced by the body being rendered — required
            }
            String title = link.ContentDocument.Title == null ? '' : link.ContentDocument.Title;
            // Scheme 2: LWC-uploaded image of THIS template, no longer referenced.
            if (title.startsWith(templateKeyedPrefix)) {
                staleLinks.add(link);
                continue;
            }
            // Watermark scheme: docgen_watermark_<versionId>. Version-keyed to
            // THIS template (carry-forward can key it to an older version, so
            // membership — not active-version equality — decides scope).
            if (title.startsWith('docgen_watermark_')) {
                String wmVersionId = title.substring('docgen_watermark_'.length());
                if (
                    (wmVersionId.length() == 15 || wmVersionId.length() == 18) &&
                    templateVersionIds.contains((Id) wmVersionId)
                ) {
                    staleLinks.add(link);
                }
                continue;
            }
            // Scheme 1 — title shape: docgen_(html|tmpl)_img_<versionId>_<...>
            List<String> parts = title.split('_');
            if (parts.size() < 5) {
                continue;
            }
            String titleVersionId = parts[3];
            if (
                titleVersionId != activeVersionId &&
                (titleVersionId.length() == 15 ||
                titleVersionId.length() == 18) &&
                templateVersionIds.contains((Id) titleVersionId)
            ) {
                staleLinks.add(link);
            }
        }
        if (!staleLinks.isEmpty()) {
            /* code-analyzer-suppress ApexFlsViolation */
            Database.delete(staleLinks, false, AccessLevel.SYSTEM_MODE);
        }
    }

    private static Set<Id> extractShepherdContentVersionIds(String html) {
        Set<Id> ids = new Set<Id>();
        if (String.isBlank(html)) {
            return ids;
        }
        Pattern p = Pattern.compile('/sfc/servlet\\.shepherd/version/download/([a-zA-Z0-9]{15,18})');
        Matcher m = p.matcher(html);
        while (m.find()) {
            try {
                Id cvId = Id.valueOf(m.group(1));
                if (String.valueOf(cvId).startsWith('068')) {
                    ids.add(cvId);
                }
            } catch (Exception ignored) {
                // Not a Salesforce Id; ignore.
            }
        }
        return ids;
    }

    /**
     * Generates a PDF Blob from a MergeResult using the unified image map.
     * Single entry point for all PDF rendering — used by generateDocument()
     * and generatePdfBlob().
     */
    private static Blob renderPdf(MergeResult mr, Id templateId, Id recordId) {
        if (Test.isRunningTest()) {
            lastRenderedHtml = (mr != null &&
                mr.templateType == 'HTML' &&
                String.isNotBlank(mr.documentXml))
                ? mr.documentXml
                : '<html><body><p>Test PDF</p></body></html>';
            return Blob.toPdf(lastRenderedHtml);
        }

        // Orientation override drives canonical letter dimensions in the
        // generated @page CSS — set BEFORE convertToHtml so parsePageDimensions
        // sees it. Cleared in finally to keep the static from leaking across
        // back-to-back renders. Blob.toPdf honors @page size when given
        // valid CSS (`size: 11in 8.5in` for landscape, `8.5in 11in` for portrait);
        // mixing dimensions with the `landscape` keyword is invalid CSS and
        // falls back to portrait letter.
        DocGenHtmlRenderer.orientationOverride = mr.pageOrientation;
        DocGenHtmlRenderer.pageSizeOverride = mr.pageSize;
        DocGenHtmlRenderer.marginsOverride = mr.pageMargins;
        DocGenHtmlRenderer.customMarginsOverride = mr.customMargins;
        try {
            // HTML template type: documentXml is a ready-to-render HTML document —
            // skip the DOCX→HTML conversion entirely.
            if (mr.templateType == 'HTML') {
                // Admin-uploaded watermarks are injected by convertToHtml on the
                // DOCX path — HTML templates skip that entirely, so inject here,
                // BEFORE the asset-access pass: the watermark CV needs the same
                // record link the asset images get or the PDF fetch fails.
                applyWatermarkOverride(templateId);
                String htmlDoc = DocGenHtmlRenderer.injectAdminWatermarkIntoHtml(mr.documentXml);
                ensureTemplateAssetImageAccessForPdf(templateId, recordId, htmlDoc);
                lastRenderedHtml = htmlDoc;
                Blob htmlPdf = Blob.toPdf(htmlDoc);
                removeTemplateImageLinksAfterRender(templateId, recordId, htmlDoc);
                return htmlPdf;
            }

            Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
            // Pass styles.xml to renderer for dynamic table style resolution
            if (mr.processedXmlEntries != null && mr.processedXmlEntries.containsKey('word/styles.xml')) {
                DocGenHtmlRenderer.stylesXml = mr.processedXmlEntries.get('word/styles.xml');
            }
            setNumberingXml(mr);
            applyWatermarkOverride(templateId);
            String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
            ensureTemplateAssetImageAccessForPdf(templateId, recordId, html);
            lastRenderedHtml = html;

            Blob docxPdf = Blob.toPdf(html);
            removeTemplateImageLinksAfterRender(templateId, recordId, html);
            return docxPdf;
        } finally {
            DocGenHtmlRenderer.orientationOverride = null;
            DocGenHtmlRenderer.pageSizeOverride = null;
            DocGenHtmlRenderer.marginsOverride = null;
            DocGenHtmlRenderer.customMarginsOverride = null;
        }
    }

    /**
     * Generates HTML for browser preview with data URI images.
     * Uses the same merge + image pipeline as the PDF generator (forced PDF mode,
     * pre-decomposed XML, buildPdfImageMap), then converts relative CV URLs
     * to base64 data URIs so guest users can view them without a Salesforce session.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Complete HTML string with embedded base64 data URI images
     */
    public static String renderPreviewHtml(Id templateId, Id recordId) {
        // Same merge path as PDF generation — forced PDF mode
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Preview is only supported for Word and HTML templates.');
        }

        // HTML templates: documentXml is already the full rendered HTML
        if (mr.templateType == 'HTML') {
            return mr.documentXml;
        }

        // Build the same image map the PDF generator uses
        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Convert relative CV URLs to data URIs for browser rendering
        Map<String, String> previewImages = new Map<String, String>();
        for (String relId : pdfImages.keySet()) {
            String url = pdfImages.get(relId);
            // Extract CV Id from /sfc/servlet.shepherd/version/download/{cvId}
            if (url != null && url.contains('/version/download/')) {
                String cvId = url.substringAfterLast('/');
                try {
                    ContentVersion cv = [
                        SELECT VersionData, FileExtension
                        FROM ContentVersion
                        WHERE Id = :cvId
                        WITH USER_MODE
                        LIMIT 1
                    ]; // NOPMD ApexCRUDViolation - ContentVersion read access required for PDF image preview; gated by template ownership
                    String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : 'png';
                    String mime = (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
                    previewImages.put(relId, 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(cv.VersionData));
                } catch (Exception e) {
                    // Intentionally swallowed — unresolvable image, skip
                    String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
            } else if (url != null) {
                previewImages.put(relId, url);
            }
        }

        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        return DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), previewImages);
    }

    /**
     * Generates a PDF Blob and title without saving to record.
     * Used by DocGenController for download mode.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return Map with keys: blob (PDF Blob), title (String)
     */
    global static Map<String, Object> generatePdfBlob(Id templateId, Id recordId) {
        // Force PDF output format so we get the heap-efficient path
        // (pre-decomposed XML, relative image URLs, no blob loading)
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PDF') {
            return new Map<String, Object>{ 'blob' => mr.pdfBlob, 'title' => mr.docTitle };
        }

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException(
                'Server-side PDF generation is only supported for Word, HTML, and PDF templates.'
            );
        }

        Blob pdfBlob = renderPdf(mr, templateId, recordId);

        return new Map<String, Object>{ 'blob' => pdfBlob, 'title' => mr.docTitle };
    }

    /**
     * Merges a template with record data and returns HTML using a custom image map.
     * Used by the batch PDF renderer to generate HTML with ContentVersion URLs
     * instead of data URIs, allowing Flying Saucer to render images in PDFs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param imageMap Map of relId to image URL for PDF rendering
     * @return Map with keys: html, title, outputFormat, templateType
     */
    public static Map<String, Object> processDocumentAsHtmlWithImageMap(
        Id templateId,
        Id recordId,
        Map<String, String> imageMap
    ) {
        MergeResult mr = mergeTemplate(templateId, recordId);

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Server-side PDF generation is only supported for Word templates.');
        }

        // Merge the provided URL map with any URL-only entries from the merge result
        // (e.g., Rich Text field images that are accessed by URL, not base64)
        Map<String, String> mergedMap = new Map<String, String>(imageMap);
        for (String relId : mr.imageBase64ByRelId.keySet()) {
            if (!mergedMap.containsKey(relId)) {
                mergedMap.put(relId, mr.imageBase64ByRelId.get(relId));
            }
        }

        setNumberingXml(mr);
        applyWatermarkOverride(templateId);
        String html = DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), mergedMap);

        return new Map<String, Object>{
            'html' => html,
            'title' => mr.docTitle,
            'outputFormat' => 'PDF',
            'templateType' => mr.templateType
        };
    }

    /**
     * Processes a template and saves the result as a ContentVersion attached to the record.
     * For PDF output, uses the unified renderPdf() path with pre-committed image URLs.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @return ContentDocumentId of the saved file
     */
    global static Id generateDocument(Id templateId, Id recordId) {
        return generateDocument(templateId, recordId, null, null);
    }

    /**
     * Same as generateDocument(templateId, recordId) but honors a runtime output-format override.
     * outputFormatOverride: 'PDF', 'Word', or 'PowerPoint'. Null = use template's Output_Format__c.
     * Throws DocGenException if Lock_Output_Format__c is true on the template, or if PowerPoint→PDF.
     */
    global static Id generateDocument(Id templateId, Id recordId, String outputFormatOverride) {
        return generateDocument(templateId, recordId, outputFormatOverride, null);
    }

    /**
     * Same as generateDocument(templateId, recordId, outputFormatOverride) but lets the caller
     * override the saved file's title. When documentTitle is non-blank it replaces the template's
     * resolved title format / record Name fallback. Used by Flow callers (Document Title input).
     */
    global static Id generateDocument(Id templateId, Id recordId, String outputFormatOverride, String documentTitle) {
        return generateDocument(templateId, recordId, outputFormatOverride, documentTitle, recordId);
    }

    /**
     * Same as the 4-arg overload but separates the merge-data record from the attachment target.
     * Pass attachmentRecordId = null to insert the ContentVersion as a standalone file (no
     * FirstPublishLocationId, no ContentDocumentLink) — the caller still gets the returned
     * ContentDocumentId so it can hand the user a `/sfc/servlet.shepherd/version/download/...`
     * URL without leaving an artifact on the source record. Used by Flow callers that opt out
     * of "Save to Record" (issue #90).
     */
    global static Id generateDocument(
        Id templateId,
        Id recordId,
        String outputFormatOverride,
        String documentTitle,
        Id attachmentRecordId
    ) {
        validateOutputFormatOverride(templateId, outputFormatOverride);
        MergeResult mr = mergeTemplate(templateId, recordId, null, outputFormatOverride);
        if (String.isNotBlank(documentTitle)) {
            mr.docTitle = documentTitle;
        }

        if (mr.outputFormat == 'PDF' && mr.templateType == 'PDF') {
            return savePdfFile(mr.pdfBlob, mr.docTitle, attachmentRecordId);
        }

        if (mr.outputFormat == 'PDF' && (mr.templateType == 'Word' || mr.templateType == 'HTML')) {
            Blob pdfBlob = renderPdf(mr, templateId, recordId);
            return savePdfFile(pdfBlob, mr.docTitle, attachmentRecordId);
        }

        // Native DOCX/PPTX path
        Blob resultBlob = assembleZip(mr);
        return saveFile(
            resultBlob,
            mr.docTitle,
            attachmentRecordId,
            mr.outputFormat,
            mr.templateType,
            isMacroEnabledWorkbook(mr)
        );
    }

    /**
     * Generates a document using pre-cached record data, bypassing data retrieval SOQL.
     * Sets the static override so mergeTemplate() uses cached data instead of querying.
     * Used by DocGenBatch when bulk data cache is available.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID (used for file attachment)
     * @param preloadedRecordData Pre-fetched record data map to use instead of querying
     * @return ContentDocumentId of the saved file
     */
    global static Id generateDocumentFromData(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        preloadedRecordDataOverride = preloadedRecordData;
        return generateDocument(templateId, recordId);
    }

    /**
     * Renders a PDF directly from a caller-supplied data map — no SOQL, no recordId required.
     * Lets Flows/Apex assemble custom data wrappers (external API responses, computed totals,
     * cross-object aggregations) and render them straight into a template without persisting
     * to records first or implementing the DocGenDataProvider interface.
     *
     * The dataMap follows the same shape Portwood merge expects:
     *   - Simple fields: 'Name' => 'Acme'
     *   - Parent lookups: 'Account' => Map<String,Object>{ 'Name' => 'Acme' }
     *   - Child loops: 'Items' => Map<String,Object>{ 'records' => List<Object>{ ... } }
     *
     * @param templateId The DocGen_Template__c record ID (must be a Word or HTML template producing PDF output)
     * @param dataMap The pre-built data map to merge — must not be null
     * @return Map with keys: blob (PDF Blob), title (String)
     */
    global static Map<String, Object> generatePdfBlobFromData(Id templateId, Map<String, Object> dataMap) {
        if (dataMap == null) {
            throw new DocGenException(
                'dataMap cannot be null. Use generatePdfBlob(templateId, recordId) for SOQL-based merge.'
            );
        }
        preloadedRecordDataOverride = dataMap;
        // recordId is null — safe because the override short-circuits SOQL data retrieval and
        // renderPdf() never dereferences recordId. The PDF blob is returned to the caller, who
        // decides what to do with it (attach to an arbitrary parent, return via Flow, etc.).
        return generatePdfBlob(templateId, null);
    }

    /**
     * Renders a document (PDF, DOCX, PPTX) from a caller-supplied data map and saves it as
     * a ContentVersion linked to attachmentRecordId. Unlike generatePdfBlobFromData, this
     * path performs the file-attachment step too — convenient for Flows that want a single
     * "build wrapper → render → attach" call.
     *
     * @param templateId The DocGen_Template__c record ID
     * @param attachmentRecordId Record to attach the generated file to (must be non-null)
     * @param dataMap The pre-built data map to merge — must not be null
     * @param outputFormatOverride 'PDF', 'Word', or 'PowerPoint'; null = template default
     * @return ContentDocumentId of the saved file
     */
    global static Id generateAndSaveFromData(
        Id templateId,
        Id attachmentRecordId,
        Map<String, Object> dataMap,
        String outputFormatOverride
    ) {
        return generateAndSaveFromData(templateId, attachmentRecordId, dataMap, outputFormatOverride, null);
    }

    /**
     * Same as generateAndSaveFromData(templateId, attachmentRecordId, dataMap, outputFormatOverride)
     * but lets the caller override the saved file's title. When documentTitle is non-blank it replaces
     * the template's resolved title format / record Name fallback.
     */
    global static Id generateAndSaveFromData(
        Id templateId,
        Id attachmentRecordId,
        Map<String, Object> dataMap,
        String outputFormatOverride,
        String documentTitle
    ) {
        return generateAndSaveFromData(
            templateId,
            attachmentRecordId,
            dataMap,
            outputFormatOverride,
            documentTitle,
            attachmentRecordId
        );
    }

    /**
     * Same as generateAndSaveFromData(templateId, attachmentRecordId, dataMap, outputFormatOverride,
     * documentTitle) but separates the data-source record from the attachment target. Pass
     * fileAttachmentTarget = null to insert a standalone ContentVersion (no FirstPublishLocationId,
     * no ContentDocumentLink). Used by the Flow action when saveToRecord=false and JSON Data is
     * supplied (issue #90).
     */
    global static Id generateAndSaveFromData(
        Id templateId,
        Id attachmentRecordId,
        Map<String, Object> dataMap,
        String outputFormatOverride,
        String documentTitle,
        Id fileAttachmentTarget
    ) {
        if (dataMap == null) {
            throw new DocGenException('dataMap cannot be null.');
        }
        if (attachmentRecordId == null) {
            throw new DocGenException(
                'attachmentRecordId is required for save-to-record. Use generatePdfBlobFromData if you only want the blob.'
            );
        }
        preloadedRecordDataOverride = dataMap;
        return generateDocument(
            templateId,
            attachmentRecordId,
            outputFormatOverride,
            documentTitle,
            fileAttachmentTarget
        );
    }

    /**
     * Combines document XML with header/footer XML from processedXmlEntries.
     * Headers are prepended and footers are appended so the HTML renderer
     * processes all template content (not just the main body).
     * Image relIds in header/footer XML are namespaced to prevent collisions.
     */
    /**
     * Sets DocGenHtmlRenderer.numberingXml from the template's word/numbering.xml
     * passthrough entry, enabling accurate numbered vs bullet list detection.
     */
    private static void setNumberingXml(MergeResult mr) {
        DocGenHtmlRenderer.numberingXml = null;
        if (mr.passthroughEntries != null && mr.passthroughEntries.containsKey('word/numbering.xml')) {
            DocGenHtmlRenderer.numberingXml = mr.passthroughEntries.get('word/numbering.xml').toString();
        }
    }

    private static String combineXmlWithHeadersFooters(MergeResult mr) {
        if (mr.processedXmlEntries == null) {
            return mr.documentXml;
        }

        // Map each header/footer file → its sectPr type (default/first/even).
        // This lets us emit separate first-page markers so the renderer can
        // wire up @page :first margin boxes for "Different First Page" docs.
        Map<String, String> partTypeByFile = mapHeaderFooterTypes(mr);

        String headersDefault = '';
        String headersFirst = '';
        String headersEven = '';
        String footersDefault = '';
        String footersFirst = '';
        String footersEven = '';
        List<String> keys = new List<String>(mr.processedXmlEntries.keySet());
        keys.sort();
        for (String key : keys) {
            if (key == 'word/styles.xml') {
                continue;
            }
            if (!key.startsWith('word/header') && !key.startsWith('word/footer')) {
                continue;
            }
            String partPrefix = key.substringAfterLast('/').substringBefore('.xml');
            String partXml = namespaceImageRelIds(mr.processedXmlEntries.get(key), partPrefix);
            // Default to "default" when unmapped (older templates without sectPr refs).
            String partType = partTypeByFile.containsKey(partPrefix) ? partTypeByFile.get(partPrefix) : 'default';
            Boolean isHeader = key.startsWith('word/header');
            // v1.97 — keep only the FIRST file per (header/footer, type) slot. When a
            // docx contains multiple sections that each reference the same default
            // header (or Word emits duplicate header files for sections with the same
            // content), concatenating them all produces stacked duplicate headers in
            // Flying Saucer's @top-center running element. Flying Saucer can only
            // surface one running element per page run anyway, so the first
            // declaration wins — matches Word's own "one header per page run" model.
            if (isHeader) {
                if (partType == 'first' && String.isBlank(headersFirst)) {
                    headersFirst = partXml;
                } else if (partType == 'even' && String.isBlank(headersEven)) {
                    headersEven = partXml;
                } else if (partType != 'first' && partType != 'even' && String.isBlank(headersDefault)) {
                    headersDefault = partXml;
                }
            } else {
                if (partType == 'first' && String.isBlank(footersFirst)) {
                    footersFirst = partXml;
                } else if (partType == 'even' && String.isBlank(footersEven)) {
                    footersEven = partXml;
                } else if (partType != 'first' && partType != 'even' && String.isBlank(footersDefault)) {
                    footersDefault = partXml;
                }
            }
        }

        // Inject markers for the renderer. The DEFAULT pair drives every page;
        // FIRST drives @page :first when the doc has <w:titlePg/>. Older templates
        // without first-page refs still use the legacy DOCGEN_HEADER_START marker
        // for backward compatibility — the renderer treats it as default.
        String combinedXml = '';
        if (String.isNotBlank(headersDefault)) {
            combinedXml += '<!-- DOCGEN_HEADER_START -->' + headersDefault + '<!-- DOCGEN_HEADER_END -->';
        }
        if (String.isNotBlank(headersFirst)) {
            combinedXml += '<!-- DOCGEN_HEADER_FIRST_START -->' + headersFirst + '<!-- DOCGEN_HEADER_FIRST_END -->';
        }
        if (String.isNotBlank(headersEven)) {
            combinedXml += '<!-- DOCGEN_HEADER_EVEN_START -->' + headersEven + '<!-- DOCGEN_HEADER_EVEN_END -->';
        }
        combinedXml += mr.documentXml;
        if (String.isNotBlank(footersDefault)) {
            combinedXml += '<!-- DOCGEN_FOOTER_START -->' + footersDefault + '<!-- DOCGEN_FOOTER_END -->';
        }
        if (String.isNotBlank(footersFirst)) {
            combinedXml += '<!-- DOCGEN_FOOTER_FIRST_START -->' + footersFirst + '<!-- DOCGEN_FOOTER_FIRST_END -->';
        }
        if (String.isNotBlank(footersEven)) {
            combinedXml += '<!-- DOCGEN_FOOTER_EVEN_START -->' + footersEven + '<!-- DOCGEN_FOOTER_EVEN_END -->';
        }
        return combinedXml;
    }

    /**
     * Builds a map of header/footer part name (e.g. "header2") → sectPr type
     * (default / first / even) by walking the document's sectPr references and
     * resolving them through the document rels.
     *
     * Returns an empty map when refs aren't present — older templates without
     * <w:headerReference> entries fall through to the "default" bucket so they
     * keep their pre-1.80 behavior.
     */
    @TestVisible
    private static Map<String, String> mapHeaderFooterTypes(MergeResult mr) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(mr.documentXml) || String.isBlank(mr.relsXml)) {
            return out;
        }

        // Build relId → target file (e.g. "rId4" → "header2")
        Map<String, String> relIdToFile = new Map<String, String>();
        Integer cursor = 0;
        while (cursor < mr.relsXml.length()) {
            Integer relStart = mr.relsXml.indexOf('<Relationship ', cursor);
            if (relStart == -1) {
                break;
            }
            Integer relEnd = mr.relsXml.indexOf('>', relStart);
            if (relEnd == -1) {
                break;
            }
            String relTag = mr.relsXml.substring(relStart, relEnd);
            String idVal = extractAttrValue(relTag, ' Id="');
            String targetVal = extractAttrValue(relTag, ' Target="');
            if (String.isNotBlank(idVal) && String.isNotBlank(targetVal)) {
                // Strip optional leading directory ("media/image1.png" → "image1.png",
                // "header1.xml" → "header1.xml") then drop ".xml" suffix.
                // Note: Apex's substringAfterLast returns "" when the separator is
                // missing, so we can't chain it blindly — that bug shipped briefly
                // in v1.80 and emptied every header/footer mapping.
                String fileName = targetVal.contains('/') ? targetVal.substringAfterLast('/') : targetVal;
                if (fileName.endsWith('.xml')) {
                    fileName = fileName.substring(0, fileName.length() - 4);
                }
                relIdToFile.put(idVal, fileName);
            }
            cursor = relEnd + 1;
        }

        // Walk every <w:headerReference .../> and <w:footerReference .../> in document.xml
        for (String tagPrefix : new List<String>{ '<w:headerReference ', '<w:footerReference ' }) {
            Integer refCursor = 0;
            while (refCursor < mr.documentXml.length()) {
                Integer refStart = mr.documentXml.indexOf(tagPrefix, refCursor);
                if (refStart == -1) {
                    break;
                }
                Integer refEnd = mr.documentXml.indexOf('>', refStart);
                if (refEnd == -1) {
                    break;
                }
                String refTag = mr.documentXml.substring(refStart, refEnd);
                String typeVal = extractAttrValue(refTag, 'w:type="');
                String relRef = extractAttrValue(refTag, 'r:id="');
                if (String.isBlank(relRef)) {
                    relRef = extractAttrValue(refTag, 'relationships:id="');
                }
                if (String.isNotBlank(typeVal) && String.isNotBlank(relRef) && relIdToFile.containsKey(relRef)) {
                    out.put(relIdToFile.get(relRef), typeVal);
                }
                refCursor = refEnd + 1;
            }
        }
        return out;
    }

    @TestVisible
    private static String extractAttrValue(String tag, String attrPrefix) {
        Integer idx = tag.indexOf(attrPrefix);
        if (idx == -1) {
            return null;
        }
        Integer valStart = idx + attrPrefix.length();
        Integer valEnd = tag.indexOf('"', valStart);
        if (valEnd == -1) {
            return null;
        }
        return tag.substring(valStart, valEnd);
    }

    /**
     * Rewrites image relationship IDs in header/footer XML so they don't collide
     * with document or other part relIds. Handles two reference patterns:
     *   - DrawingML:  <a:blip r:embed="rIdX"/>           → r:embed="prefix_rIdX"
     *   - VML (used by Word watermarks): <v:imagedata r:id="rIdX"/> → r:id="prefix_rIdX"
     * The VML rewrite is scoped to <v:imagedata ...> elements only — rewriting every
     * r:id would also touch hyperlinks and other non-image relationships.
     */
    /**
     * Walks every <wp:extent cx="..." cy="..."/> in document/header/footer XML and
     * emits a System.debug warning when an image's display width exceeds the page
     * content area. Page dimensions are read from the document's <w:sectPr><w:pgSz>
     * + <w:pgMar>. Falls back silently when no sectPr is found (older templates).
     *
     * EMU constants: 914400 EMU/inch (Word's wp:extent unit). 1440 twips/inch (sectPr
     * pgSz/pgMar unit).
     */
    @TestVisible
    private static void logImageOverflowWarnings(Id versionId, Map<String, String> xmlEntries) {
        if (xmlEntries == null || xmlEntries.isEmpty()) {
            return;
        }
        String docXml = xmlEntries.get('word/document.xml');
        if (String.isBlank(docXml)) {
            return;
        }

        // Parse content-area width from final sectPr. Default to letter portrait
        // (8.5" - 1" left - 1" right = 6.5") if we can't read the doc's settings.
        Decimal contentWidthInches = 6.5;
        Integer sectPrIdx = docXml.lastIndexOf('<w:sectPr');
        if (sectPrIdx != -1) {
            Integer sectPrEnd = docXml.indexOf('</w:sectPr>', sectPrIdx);
            if (sectPrEnd == -1) {
                sectPrEnd = docXml.length();
            }
            String sectPrXml = docXml.substring(sectPrIdx, sectPrEnd);
            Decimal pageW = parseTwipsAttr(sectPrXml, '<w:pgSz', 'w:w');
            Decimal marL = parseTwipsAttr(sectPrXml, '<w:pgMar', 'w:left');
            Decimal marR = parseTwipsAttr(sectPrXml, '<w:pgMar', 'w:right');
            if (pageW != null && pageW > 0) {
                Decimal computed = pageW - (marL != null ? marL : 0) - (marR != null ? marR : 0);
                if (computed > 0) {
                    contentWidthInches = computed / 1440;
                }
            }
        }

        // EMU max for content area
        Decimal contentWidthEmu = contentWidthInches * 914400;

        Integer overflowCount = 0;
        for (String partName : xmlEntries.keySet()) {
            if (
                partName != 'word/document.xml' &&
                !(partName.startsWith('word/header') || partName.startsWith('word/footer'))
            ) {
                continue;
            }
            String partXml = xmlEntries.get(partName);
            Integer cursor = 0;
            while (cursor < partXml.length()) {
                Integer extIdx = partXml.indexOf('<wp:extent ', cursor);
                if (extIdx == -1) {
                    break;
                }
                Integer extEnd = partXml.indexOf('/>', extIdx);
                if (extEnd == -1) {
                    extEnd = partXml.indexOf('>', extIdx);
                }
                if (extEnd == -1) {
                    break;
                }
                String extTag = partXml.substring(extIdx, extEnd);
                String cxStr = extractAttrValue(extTag, ' cx="');
                if (String.isNotBlank(cxStr) && cxStr.isNumeric()) {
                    Long cx = Long.valueOf(cxStr);
                    if (cx > contentWidthEmu) {
                        overflowCount++;
                        Decimal imgInches = (Decimal.valueOf(cx) / 914400).setScale(2);
                        System.debug(
                            LoggingLevel.WARN,
                            'Portwood image-overflow: template version ' +
                                versionId +
                                ' part ' +
                                partName +
                                ' has wp:extent ' +
                                imgInches +
                                '" wide vs ' +
                                contentWidthInches.setScale(2) +
                                '" content area — image will overflow page margins'
                        );
                    }
                }
                cursor = extEnd + 1;
            }
        }
        if (overflowCount > 0) {
            System.debug(
                LoggingLevel.WARN,
                'Portwood image-overflow summary: ' +
                    overflowCount +
                    ' oversized image(s) detected in template version ' +
                    versionId +
                    '. Authors: resize images so wp:extent ≤ ' +
                    contentWidthInches.setScale(2) +
                    '" (or widen page margins).'
            );
        }
    }

    private static Decimal parseTwipsAttr(String xml, String elementOpen, String attrName) {
        Integer idx = xml.indexOf(elementOpen);
        if (idx == -1) {
            return null;
        }
        Integer tagEnd = xml.indexOf('>', idx);
        if (tagEnd == -1) {
            return null;
        }
        String tag = xml.substring(idx, tagEnd);
        String val = extractAttrValue(tag, ' ' + attrName + '="');
        if (String.isBlank(val) || !val.isNumeric()) {
            return null;
        }
        return Decimal.valueOf(val);
    }

    private static String namespaceImageRelIds(String xml, String partPrefix) {
        String result = namespaceAttrInXml(xml, 'r:embed="', null, partPrefix);
        result = namespaceAttrInXml(result, 'r:id="', '<v:imagedata', partPrefix);
        return result;
    }

    /**
     * Rewrites occurrences of attrMarker (e.g. 'r:embed="') by prepending partPrefix +'_'
     * to the attribute value. If scopeTag is non-null, only rewrites occurrences whose
     * nearest preceding '<' starts with scopeTag (e.g. only inside <v:imagedata ...>).
     */
    private static String namespaceAttrInXml(String xml, String attrMarker, String scopeTag, String partPrefix) {
        String result = xml;
        Integer cursor = 0;
        while (cursor < result.length()) {
            Integer markerStart = result.indexOf(attrMarker, cursor);
            if (markerStart == -1) {
                break;
            }
            Integer valStart = markerStart + attrMarker.length();
            Integer valEnd = result.indexOf('"', valStart);
            if (valEnd == -1) {
                break;
            }

            Boolean inScope = true;
            if (scopeTag != null) {
                Integer tagOpen = result.lastIndexOf('<', markerStart);
                inScope = (tagOpen != -1 && result.substring(tagOpen).startsWith(scopeTag));
            }

            if (inScope) {
                String relId = result.substring(valStart, valEnd);
                String newRelId = partPrefix + '_' + relId;
                result = result.substring(0, valStart) + newRelId + result.substring(valEnd);
                cursor = valStart + newRelId.length() + 1;
            } else {
                cursor = valEnd + 1;
            }
        }
        return result;
    }

    /**
     * Generates the HTML for a single record without calling Blob.toPdf() or saving a file.
     * Used by bulk batch to accumulate HTML for all records, then render one merged PDF at the end.
     * Accepts optional pre-loaded record data to skip per-record SOQL.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID to merge data from
     * @param preloadedRecordData Optional pre-fetched record data map (null to query fresh)
     * @return HTML string ready for Blob.toPdf() rendering
     */
    public static String generateHtmlForRecord(Id templateId, Id recordId, Map<String, Object> preloadedRecordData) {
        if (preloadedRecordData != null) {
            preloadedRecordDataOverride = preloadedRecordData;
        }
        MergeResult mr = mergeTemplate(templateId, recordId, null, 'PDF');

        if (mr.templateType == 'PDF') {
            throw new DocGenException(
                'Merged bulk output is not supported for fillable PDF templates. Run the bulk job as Individual Files.'
            );
        }

        // PowerPoint and Excel have no DOCX→HTML conversion. Before this guard they
        // fell through to the Word branch below, which looks for word/document.xml,
        // found nothing, and returned empty HTML — so a combined-PDF bulk job over a
        // PPTX or XLSX template produced a PDF of blank pages with no error at all.
        // (generateDocument catches this via validateOutputFormatOverride, but that
        // runs on the individual-file path only; this method calls mergeTemplate with
        // a hardcoded 'PDF' and never passes through it.)
        if (mr.templateType == 'PowerPoint' || mr.templateType == 'Excel') {
            throw new DocGenException(
                mr.templateType +
                    ' templates cannot be combined into a single PDF. Run the bulk job as Individual Files to get one ' +
                    (mr.templateType == 'Excel' ? '.xlsx' : '.pptx') +
                    ' per record.'
            );
        }

        // HTML template type: mr.documentXml is already a ready-to-render HTML
        // document — skip the DOCX→HTML conversion (which would return empty
        // since there are no DOCX processedXmlEntries for HTML templates).
        if (mr.templateType == 'HTML') {
            return mr.documentXml == null ? '' : mr.documentXml;
        }

        // Mirror renderPdf's renderer setup. Without these, the Print-Ready
        // Packet (mergeOnly) path renders tables with no borders/padding when
        // the template uses a named <w:tblStyle> (resolveTableStyleBorder
        // returns empty if stylesXml is null), and ignores the template's
        // orientation/size/margins. Cleared in finally so per-record state
        // doesn't leak across the bulk loop.
        DocGenHtmlRenderer.orientationOverride = mr.pageOrientation;
        DocGenHtmlRenderer.pageSizeOverride = mr.pageSize;
        DocGenHtmlRenderer.marginsOverride = mr.pageMargins;
        DocGenHtmlRenderer.customMarginsOverride = mr.customMargins;
        try {
            Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);
            if (mr.processedXmlEntries != null && mr.processedXmlEntries.containsKey('word/styles.xml')) {
                DocGenHtmlRenderer.stylesXml = mr.processedXmlEntries.get('word/styles.xml');
            }
            setNumberingXml(mr);
            applyWatermarkOverride(templateId);
            return DocGenHtmlRenderer.convertToHtml(combineXmlWithHeadersFooters(mr), pdfImages);
        } finally {
            DocGenHtmlRenderer.orientationOverride = null;
            DocGenHtmlRenderer.pageSizeOverride = null;
            DocGenHtmlRenderer.marginsOverride = null;
            DocGenHtmlRenderer.customMarginsOverride = null;
        }
    }

    /**
     * Preprocesses DOCX XML to merge text runs where template tags {tag} are split
     * across multiple <w:r><w:t> elements by Word's formatting engine.
     * After merging, processXml can find complete tags like {#QuoteLineItems}.
     */
    @TestVisible
    public static String mergeRunsInTagsForTest(String xml) {
        return mergeRunsInTags(xml);
    }

    private static String mergeRunsInTags(String xml) {
        // De-fragment split merge tags first (so a {RepeatHeader} broken across runs is
        // contiguous), then apply the structural {RepeatHeader} → <w:tblHeader/> pass.
        // This wrapper runs at every merge call site, so all paths (single, bulk, giant
        // config, snapshot creation) honor the marker before processXml strips it.
        return applyRepeatHeaderMarkers(mergeRunsInTagsCore(xml));
    }

    private static String mergeRunsInTagsCore(String xml) {
        // 1. Find all <w:t...>text</w:t> and <a:t>text</a:t> elements (Word + PowerPoint)
        Pattern wtPattern = Pattern.compile('<[wa]:t(?:\\s[^>]*)?>([^<]*)</[wa]:t>');
        Matcher m = wtPattern.matcher(xml);

        List<Integer> contentStarts = new List<Integer>();
        List<Integer> contentEnds = new List<Integer>();
        List<String> contents = new List<String>();

        while (m.find()) {
            contentStarts.add(m.start(1));
            contentEnds.add(m.end(1));
            contents.add(m.group(1));
        }

        if (contents.isEmpty()) {
            return xml;
        }

        // 2. Build flat text (concatenation of all <w:t> text) and segment offsets
        Integer totalLen = 0;
        List<Integer> flatOffsets = new List<Integer>();
        for (String c : contents) {
            flatOffsets.add(totalLen);
            totalLen += c.length();
        }
        String flatText = String.join(contents, '');

        // 3. Find tags where { and } are in different segments
        Boolean modified = false;
        Integer pos = 0;

        while (pos < flatText.length()) {
            Integer openBrace = flatText.indexOf('{', pos);
            if (openBrace == -1) {
                break;
            }
            Integer closeBrace = flatText.indexOf('}', openBrace);
            if (closeBrace == -1) {
                break;
            }

            // Determine which segments contain the { and }
            Integer openSeg = -1;
            Integer closeSeg = -1;
            for (Integer i = 0; i < contents.size(); i++) {
                Integer segStart = flatOffsets.get(i);
                Integer segEnd = segStart + contents.get(i).length();
                if (openBrace >= segStart && openBrace < segEnd) {
                    openSeg = i;
                }
                if (closeBrace >= segStart && closeBrace < segEnd) {
                    closeSeg = i;
                }
            }

            if (openSeg != -1 && closeSeg != -1 && openSeg != closeSeg) {
                modified = true;
                // Merge all text from openSeg through closeSeg into openSeg
                String merged = '';
                for (Integer i = openSeg; i <= closeSeg; i++) {
                    merged += contents.get(i);
                }
                contents.set(openSeg, merged);
                for (Integer i = openSeg + 1; i <= closeSeg; i++) {
                    contents.set(i, '');
                }
                // Recalculate flat offsets after merge
                totalLen = 0;
                for (Integer i = 0; i < contents.size(); i++) {
                    flatOffsets.set(i, totalLen);
                    totalLen += contents.get(i).length();
                }
                flatText = String.join(contents, '');
            }

            pos = closeBrace + 1;
        }

        if (!modified) {
            return xml;
        }

        // 4. Reconstruct XML by replacing text content (work backwards to maintain positions)
        String result = xml;
        for (Integer i = contents.size() - 1; i >= 0; i--) {
            String original = result.substring(contentStarts.get(i), contentEnds.get(i));
            if (!contents.get(i).equals(original)) {
                result =
                    result.substring(0, contentStarts.get(i)) +
                    contents.get(i) +
                    result.substring(contentEnds.get(i));
            }
        }

        return result;
    }

    /**
     * {RepeatHeader} marker → Word's native repeat-header. For each table row whose text
     * contains the (case-insensitive) {RepeatHeader} marker, strips the marker and ensures
     * the row's <w:trPr> carries <w:tblHeader/>. Runs pre-merge — before processXml strips
     * unrecognized tags — at the single mergeRunsInTags chokepoint, so every render path
     * honors it. The renderer (DocGenHtmlRenderer.processTable) groups <w:tblHeader/> rows
     * into a <thead> that Flying Saucer reprints atop each page; the giant-query assembler
     * reprints it per chunk. Cheap guard: no-op when the marker is absent.
     */
    private static String applyRepeatHeaderMarkers(String xml) {
        if (String.isBlank(xml) || !Pattern.compile('(?i)\\{repeatheader\\}').matcher(xml).find()) {
            return xml;
        }

        // Collect the start of every <w:tr that directly encloses a marker. Match
        // '<w:tr>' / '<w:tr ' (not '<w:trPr') and require the marker to fall before the
        // row's first </w:tr> so a marker outside any row never mis-flags a prior row.
        String lower = xml.toLowerCase();
        Set<Integer> rowStarts = new Set<Integer>();
        Integer scan = 0;
        while (true) {
            Integer hit = lower.indexOf('{repeatheader}', scan);
            if (hit == -1) {
                break;
            }
            Integer trStart = Math.max(xml.lastIndexOf('<w:tr>', hit), xml.lastIndexOf('<w:tr ', hit));
            if (trStart != -1) {
                Integer rowClose = xml.indexOf('</w:tr>', trStart);
                if (rowClose != -1 && rowClose > hit) {
                    rowStarts.add(trStart);
                }
            }
            scan = hit + 14; // length of '{repeatheader}'
        }

        // Inject <w:tblHeader/> descending by position so earlier offsets stay valid.
        List<Integer> ordered = new List<Integer>(rowStarts);
        ordered.sort();
        for (Integer i = ordered.size() - 1; i >= 0; i--) {
            xml = injectTblHeader(xml, ordered[i]);
        }

        // Strip the marker text everywhere (any case).
        return Pattern.compile('(?i)\\{repeatheader\\}').matcher(xml).replaceAll('');
    }

    /**
     * Ensures the <w:tr> beginning at trStart carries <w:tblHeader/> in its own <w:trPr>,
     * without touching a nested row's properties (direct-child guard, issue #49).
     * Idempotent — a row that already repeats is left unchanged.
     */
    private static String injectTblHeader(String xml, Integer trStart) {
        Integer openEnd = xml.indexOf('>', trStart);
        if (openEnd == -1) {
            return xml;
        }
        Integer firstTc = xml.indexOf('<w:tc', openEnd);
        Integer trPrStart = xml.indexOf('<w:trPr', openEnd);
        Boolean hasOwnTrPr = (trPrStart != -1 && (firstTc == -1 || trPrStart < firstTc));
        if (!hasOwnTrPr) {
            // No direct <w:trPr> — insert a fresh one right after the <w:tr …> open tag.
            return xml.substring(0, openEnd + 1) + '<w:trPr><w:tblHeader/></w:trPr>' + xml.substring(openEnd + 1);
        }
        Integer trPrTagEnd = xml.indexOf('>', trPrStart);
        if (trPrTagEnd == -1) {
            return xml;
        }
        // Self-closing <w:trPr/> → expand it to carry the flag.
        if (xml.substring(trPrStart, trPrTagEnd + 1).endsWith('/>')) {
            return xml.substring(0, trPrStart) + '<w:trPr><w:tblHeader/></w:trPr>' + xml.substring(trPrTagEnd + 1);
        }
        // Open <w:trPr> … </w:trPr>: skip if it already repeats, else insert at the front.
        Integer trPrClose = xml.indexOf('</w:trPr>', trPrStart);
        if (trPrClose != -1 && xml.substring(trPrStart, trPrClose).contains('<w:tblHeader')) {
            return xml;
        }
        return xml.substring(0, trPrTagEnd + 1) + '<w:tblHeader/>' + xml.substring(trPrTagEnd + 1);
    }

    private static String processXml(String xml, Map<String, Object> data) {
        // Chart tag expansion: rewrites {Chart:rel:field:style:opts} into the
        // corresponding substitution. HTML templates get the CSS-bar snippet
        // (with embedded {#ChartBucket:...} loops, which feed through the
        // existing bucket resolver). Word templates with chartCvMap entries
        // get a {%__dgchart_<cvId>} image tag (resolved via the existing
        // image-tag scanner + buildImageXml case-4 path). Cheap contains()
        // guard keeps the no-chart hot path at zero overhead.
        if (xml != null && xml.contains('{Chart:')) {
            xml = DocGenChartTagExpander.expand(xml, currentTemplateType, data, currentChartCvMap);
        }

        // ChartBucket preprocessing: rewrites {#ChartBucket:rel:field}...{/ChartBucket}
        // into synthetic {#_cb_N}...{/_cb_N} loops with bucket data injected into
        // `data`. Runs at every recursion level so charts inside loop bodies resolve
        // against the iteration item, not the outer parent. Cheap `contains` guard
        // keeps the no-chart hot path at zero overhead.
        if (xml != null && xml.contains('{#ChartBucket:')) {
            xml = DocGenChartBucketResolver.preprocessInline(xml, data);
        }

        String output = '';
        Integer len = xml.length();
        Integer cursor = 0;

        while (cursor < len) {
            Integer nextTag = xml.indexOf('{', cursor);
            if (nextTag == -1) {
                output += xml.substring(cursor);
                break;
            }
            output += xml.substring(cursor, nextTag);
            cursor = nextTag;

            Integer tagClose = xml.indexOf('}', cursor);
            if (tagClose == -1) {
                String snippet = xml.substring(cursor, Math.min(cursor + 80, len));
                String lineInfo = currentTemplateType == 'HTML'
                    ? ' (line ' + (xml.substring(0, cursor).countMatches('\n') + 1) + ')'
                    : '';
                throw new DocGenException(
                    'Malformed merge tag: missing closing "}"' +
                        lineInfo +
                        ' near "' +
                        snippet +
                        '". Check for an unclosed tag in the template.'
                );
            }

            String rawTag = xml.substring(cursor + 1, tagClose);
            String tagContent = rawTag.trim();
            // Tag start offset, captured before any branch reassigns `cursor`,
            // so error enrichment can report the tag's location (issue #115).
            Integer tagStartPos = nextTag;

            // OOXML writes GUIDs in brace syntax that is textually indistinguishable
            // from a merge tag: <a:ext uri="{0D108BD9-…}">, <a:tableStyleId>{5C22544A-…}
            // </a:tableStyleId>, <a16:creationId id="{…}">, <w15:docId val="{…}"/>.
            // Resolving them as tags emitted '' and silently corrupted the markup —
            // every generated PPTX shipped with blanked <a:ext uri=""> on its column
            // ids, row ids, and creation ids, and an authored custom table style was
            // swapped for the hardcoded default by normalizePowerPointSlideXml's
            // empty-tableStyleId repair. Emit verbatim: no Salesforce field name or
            // supported tag syntax has this shape, so nothing legitimate is shadowed.
            if (isOoxmlGuidToken(tagContent)) {
                output += xml.substring(cursor, tagClose + 1);
                cursor = tagClose + 1;
                continue;
            }

            try {
                // {@Signature_*} signing tags. During a signature send/finalize
                // (preserveSignatureTags) keep them verbatim so the signature service
                // can sentinel-substitute / stamp them after merge. In normal document
                // generation, STRIP them so they never render as literal text (the
                // {@Signature} leak — a generated PDF must not show raw signing tags).
                if (tagContent.startsWith('@')) {
                    if (preserveSignatureTags) {
                        output += '{' + rawTag + '}';
                    }
                    cursor = tagClose + 1;
                    continue;
                }

                // Signer form-field tags {?key} (optional default {?key|fallback}).
                // Lifecycle mirrors {@Signature_*}: at send-time / snapshot freeze
                // (resolveFormFields == false) we emit the tag verbatim so it
                // survives into the signed-doc template; at finalize re-render
                // (resolveFormFields == true) the signature service injects the
                // collected values under '__formFields' and we resolve here using
                // the SAME output-format escaping the plain {Field} branch uses.
                if (tagContent.startsWith('?')) {
                    if (!resolveFormFields) {
                        // Preserve verbatim until the finalize re-render.
                        output += '{' + rawTag + '}';
                        cursor = tagClose + 1;
                        continue;
                    }
                    String formSpec = tagContent.substring(1).trim();
                    String formKey = formSpec;
                    String formFallback = '';
                    Integer pipePos = formSpec.indexOf('|');
                    if (pipePos != -1) {
                        formKey = formSpec.substring(0, pipePos).trim();
                        formFallback = formSpec.substring(pipePos + 1);
                    }
                    Object formVal = resolveValue(data, '__formFields.' + formKey);
                    String formStr = (formVal == null || String.isBlank(String.valueOf(formVal)))
                        ? formFallback
                        : String.valueOf(formVal);
                    // Same plain-text escaping as the {Field} substitution branch
                    // below (rich-text/HTML conversion is not needed — form-field
                    // values are scalar text/number/date/checkbox/picklist).
                    if (currentTemplateType == 'PowerPoint') {
                        output += formStr.escapeXml();
                    } else if (currentTemplateType == 'HTML') {
                        output += formStr.replace('\r\n', '\n').replace('\r', '\n').escapeXml().replace('\n', '<br/>');
                    } else {
                        String rPr = extractCurrentRunProperties(output);
                        output += convertMultilineToXml(formStr, rPr);
                    }
                    cursor = tagClose + 1;
                    continue;
                }

                // Preserve {PageNumber} and {TotalPages} — resolved by the HTML-to-PDF
                // wrap layer via @page CSS counter() rules. Flying Saucer can only
                // resolve counter(page)/counter(pages) inside @page context, so the
                // tokens have to survive processXml intact for wrapHtmlForPdf to see.
                if ('PageNumber'.equalsIgnoreCase(tagContent) || 'TotalPages'.equalsIgnoreCase(tagContent)) {
                    output += '{' + rawTag + '}';
                    cursor = tagClose + 1;
                    continue;
                }

                // Strip Salesforce-style {!Field} prefix — treat {!X} the same as {X}
                if (tagContent.startsWith('!')) {
                    tagContent = tagContent.substring(1).trim();
                }

                if (tagContent.startsWith('#')) {
                    String key = tagContent.substring(1).trim();
                    // For {#IF ...} and {#GroupBy ...} the closing tag is the bare
                    // keyword ({/IF} / {/GroupBy}), not the full opener expression.
                    String balanceKey = (key.startsWith('IF ') || key.startsWith('if '))
                        ? 'IF'
                        : (key.startsWithIgnoreCase('GroupBy ') ? 'GroupBy' : key);
                    Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, balanceKey);
                    if (sectionEnd == -1) {
                        String snippet = xml.substring(Math.max(0, tagStartPos - 40), Math.min(len, tagStartPos + 40));
                        String lineInfo = currentTemplateType == 'HTML'
                            ? ' (line ' + (xml.substring(0, tagStartPos).countMatches('\n') + 1) + ')'
                            : '';
                        throw new DocGenException(
                            'Malformed loop tag: missing closing "{/' +
                                balanceKey +
                                '}" for "{#' +
                                key +
                                '}"' +
                                lineInfo +
                                ' opened near "' +
                                snippet +
                                '".'
                        );
                    } else {
                        // Default: Content between tags
                        Integer contentStart = tagClose + 1;
                        Integer contentEnd = sectionEnd;
                        String innerXml = xml.substring(contentStart, contentEnd);

                        // Smart container expansion: repeat the nearest parent container when possible.
                        // Candidate containers:
                        // 1) Table row (<w:tr>...</w:tr>)
                        // 2) Numbered/bulleted paragraph (nearest <w:p> containing <w:numPr>)
                        //
                        // {#IF ...} is a conditional, NOT a loop — it must NEVER trigger container
                        // expansion. If we backtrack the output to drop the parent row's opening
                        // tags expecting to re-emit them, and then the IF evaluates false with no
                        // {:else}, we emit nothing while the closing </w:tr> downstream remains —
                        // producing unmatched markup that PDF silently truncates and Word refuses
                        // to open as a corrupted DOCX. (Issue #53)
                        Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                        Integer chosenContainerStart = -1;
                        Integer chosenContainerEnd = -1;
                        Boolean isIfConditional = key.startsWith('IF ') || key.startsWith('if ');
                        // {#GroupBy ...} repeats its ENTIRE block once per group, so it
                        // must never trigger single-row/list container auto-expansion —
                        // same reasoning as {#IF ...} (issue #53).
                        Boolean isGroupBy = key.startsWithIgnoreCase('GroupBy ');
                        Boolean skipContainerExpand = isIfConditional || isGroupBy;

                        // Candidate: row container (skipped for {#IF ...} conditionals — issue #53).
                        // Sibling guard: if the row already contains another section opener/closer
                        // *outside* this section's span, the current section is not the row's
                        // iteration driver — skip expansion. Without this, multiple sibling
                        // `{#A}…{/A} … {#B}…{/B}` sections inside one row would each grab the
                        // whole row, dropping the siblings' content (truthy path renders only
                        // the first section's trueBranch and advances past `</w:tr>`).
                        Integer rowContainerStart = skipContainerExpand ? -1 : lastIndexOfTagStart(xml, 'w:tr', cursor);
                        if (rowContainerStart != -1) {
                            Integer rowContainerEnd = xml.indexOf('</w:tr>', rowContainerStart);
                            Boolean rowClosedBeforeCursor = xml.substring(rowContainerStart, cursor)
                                .contains('</w:tr>');
                            if (!rowClosedBeforeCursor && rowContainerEnd != -1 && rowContainerEnd > closeTagEnd) {
                                Integer rowFullEnd = rowContainerEnd + 7; // </w:tr>
                                String rowBefore = xml.substring(rowContainerStart, cursor);
                                String rowAfter = xml.substring(closeTagEnd + 1, rowFullEnd);
                                Boolean rowHasSibling =
                                    rowBefore.contains('{#') ||
                                    rowBefore.contains('{^') ||
                                    rowBefore.contains('{/') ||
                                    rowAfter.contains('{#') ||
                                    rowAfter.contains('{^') ||
                                    rowAfter.contains('{/');
                                if (!rowHasSibling) {
                                    chosenContainerStart = rowContainerStart;
                                    chosenContainerEnd = rowFullEnd;
                                }
                            }
                        }

                        // Candidate: list paragraph container (w:p with w:numPr) — skipped for IF.
                        // Same sibling guard as rows: only expand when this section is the sole
                        // tagged region in the paragraph. Otherwise sibling sections sharing the
                        // paragraph (e.g. Ben's checkbox doc: `{#A}☒{:else}☐{/A} label {#B}…`)
                        // would each grab the whole paragraph and drop everything after their
                        // own `{/}` closing tag.
                        Integer numPropsStart = skipContainerExpand ? -1 : xml.lastIndexOf('<w:numPr', cursor);
                        if (numPropsStart != -1) {
                            Integer paragraphStart = lastIndexOfTagStart(xml, 'w:p', cursor);
                            if (paragraphStart != -1 && paragraphStart <= numPropsStart) {
                                Integer paragraphEndStart = xml.indexOf('</w:p>', paragraphStart);
                                Boolean paragraphClosedBeforeCursor = xml.substring(paragraphStart, cursor)
                                    .contains('</w:p>');
                                if (
                                    !paragraphClosedBeforeCursor &&
                                    paragraphEndStart != -1 &&
                                    paragraphEndStart > closeTagEnd &&
                                    numPropsStart < paragraphEndStart
                                ) {
                                    Integer paragraphContainerEnd = paragraphEndStart + 6; // </w:p>
                                    String paraBefore = xml.substring(paragraphStart, cursor);
                                    String paraAfter = xml.substring(closeTagEnd + 1, paragraphContainerEnd);
                                    Boolean paraHasSibling =
                                        paraBefore.contains('{#') ||
                                        paraBefore.contains('{^') ||
                                        paraBefore.contains('{/') ||
                                        paraAfter.contains('{#') ||
                                        paraAfter.contains('{^') ||
                                        paraAfter.contains('{/');
                                    if (!paraHasSibling) {
                                        // Prefer the closest valid parent.
                                        if (chosenContainerStart == -1 || paragraphStart > chosenContainerStart) {
                                            chosenContainerStart = paragraphStart;
                                            chosenContainerEnd = paragraphContainerEnd;
                                        }
                                    }
                                }
                            }
                        }

                        // HTML template type (v1.61+): mirror the DOCX auto-expand behavior
                        // for <tr> rows and <li> list items. Only considered when the merge
                        // engine is running in HTML context — leaves DOCX paths untouched.
                        if (currentTemplateType == 'HTML' && !skipContainerExpand) {
                            // Candidate: HTML <tr> row
                            Integer htmlTrStart = lastIndexOfTagStart(xml, 'tr', cursor);
                            if (htmlTrStart != -1) {
                                Integer htmlTrEnd = xml.indexOf('</tr>', htmlTrStart);
                                Boolean trClosedBeforeCursor = xml.substring(htmlTrStart, cursor).contains('</tr>');
                                if (!trClosedBeforeCursor && htmlTrEnd != -1 && htmlTrEnd > closeTagEnd) {
                                    if (chosenContainerStart == -1 || htmlTrStart > chosenContainerStart) {
                                        chosenContainerStart = htmlTrStart;
                                        chosenContainerEnd = htmlTrEnd + 5; // </tr>
                                    }
                                }
                            }

                            // Candidate: HTML <li> list item
                            Integer htmlLiStart = lastIndexOfTagStart(xml, 'li', cursor);
                            if (htmlLiStart != -1) {
                                Integer htmlLiEnd = xml.indexOf('</li>', htmlLiStart);
                                Boolean liClosedBeforeCursor = xml.substring(htmlLiStart, cursor).contains('</li>');
                                if (!liClosedBeforeCursor && htmlLiEnd != -1 && htmlLiEnd > closeTagEnd) {
                                    if (chosenContainerStart == -1 || htmlLiStart > chosenContainerStart) {
                                        chosenContainerStart = htmlLiStart;
                                        chosenContainerEnd = htmlLiEnd + 5; // </li>
                                    }
                                }
                            }
                        }

                        // Excel worksheet <row> container: mirror the DOCX <w:tr> auto-expand
                        // for spreadsheet rows so a loop spanning cells in one row
                        // ({#Contacts}{FirstName} in A1, {LastName}{/Contacts} in B1) clones
                        // the whole row per record. Gated on Excel — <row> only exists in
                        // spreadsheetml. Cloned rows carry duplicate r indices and cell refs
                        // (Excel treats duplicates as corruption); renumberExcelRows() rewrites
                        // them after the merge pass.
                        if (currentTemplateType == 'Excel' && !skipContainerExpand) {
                            Integer xlRowStart = lastIndexOfTagStart(xml, 'row', cursor);
                            if (xlRowStart != -1) {
                                Integer xlRowEnd = xml.indexOf('</row>', xlRowStart);
                                Boolean xlRowClosedBeforeCursor = xml.substring(xlRowStart, cursor).contains('</row>');
                                if (!xlRowClosedBeforeCursor && xlRowEnd != -1 && xlRowEnd > closeTagEnd) {
                                    Integer xlRowFullEnd = xlRowEnd + 6; // </row>
                                    // Same sibling guard as <w:tr>: only expand when this section
                                    // is the row's sole tagged region.
                                    String xlBefore = xml.substring(xlRowStart, cursor);
                                    String xlAfter = xml.substring(closeTagEnd + 1, xlRowFullEnd);
                                    Boolean xlHasSibling =
                                        xlBefore.contains('{#') ||
                                        xlBefore.contains('{^') ||
                                        xlBefore.contains('{/') ||
                                        xlAfter.contains('{#') ||
                                        xlAfter.contains('{^') ||
                                        xlAfter.contains('{/');
                                    if (!xlHasSibling) {
                                        if (chosenContainerStart == -1 || xlRowStart > chosenContainerStart) {
                                            chosenContainerStart = xlRowStart;
                                            chosenContainerEnd = xlRowFullEnd;
                                        }
                                    }
                                }
                            }
                        }

                        // PowerPoint DrawingML <a:tr> container: mirror the DOCX <w:tr>
                        // auto-expand for slide tables so a loop spanning cells in one row
                        // ({#OpportunityLineItems}{Name} in cell 1, {TotalPrice}{/…} in cell 4)
                        // clones the whole row per record. Gated on PowerPoint — <a:tr> only
                        // exists in DrawingML tables. Without this the fallback repeats the raw
                        // span between the tags, which includes the intervening </a:tc><a:tc>
                        // markup: N records produce one row with 4N <a:tc> against 4
                        // <a:gridCol>, so PowerPoint shows only the first record.
                        if (currentTemplateType == 'PowerPoint' && !skipContainerExpand) {
                            Integer pptRowStart = lastIndexOfTagStart(xml, 'a:tr', cursor);
                            if (pptRowStart != -1) {
                                Integer pptRowEnd = xml.indexOf('</a:tr>', pptRowStart);
                                Boolean pptRowClosedBeforeCursor = xml.substring(pptRowStart, cursor)
                                    .contains('</a:tr>');
                                if (!pptRowClosedBeforeCursor && pptRowEnd != -1 && pptRowEnd > closeTagEnd) {
                                    Integer pptRowFullEnd = pptRowEnd + 7; // </a:tr>
                                    // Same sibling guard as <w:tr>: only expand when this section
                                    // is the row's sole tagged region.
                                    String pptBefore = xml.substring(pptRowStart, cursor);
                                    String pptAfter = xml.substring(closeTagEnd + 1, pptRowFullEnd);
                                    Boolean pptHasSibling =
                                        pptBefore.contains('{#') ||
                                        pptBefore.contains('{^') ||
                                        pptBefore.contains('{/') ||
                                        pptAfter.contains('{#') ||
                                        pptAfter.contains('{^') ||
                                        pptAfter.contains('{/');
                                    if (!pptHasSibling) {
                                        if (chosenContainerStart == -1 || pptRowStart > chosenContainerStart) {
                                            chosenContainerStart = pptRowStart;
                                            chosenContainerEnd = pptRowFullEnd;
                                        }
                                    }
                                }
                            }
                        }

                        if (chosenContainerStart != -1 && chosenContainerEnd != -1) {
                            contentStart = chosenContainerStart;
                            contentEnd = chosenContainerEnd;
                            innerXml = xml.substring(contentStart, contentEnd);

                            // Cloned DrawingML rows would repeat the row's <a16:rowId>
                            // change-tracking extension. It is an optional Microsoft
                            // extension (unlike Excel's r indices, which are core spec and
                            // need renumberExcelRows()), so dropping it from every clone is
                            // both sufficient and safe.
                            if (currentTemplateType == 'PowerPoint') {
                                innerXml = stripDrawingMlRowIds(innerXml);
                            }

                            String startTagFull = '{' + rawTag + '}';
                            innerXml = innerXml.replace(startTagFull, '');

                            String endTagFull = xml.substring(sectionEnd, closeTagEnd + 1);
                            innerXml = innerXml.replace(endTagFull, '');

                            // Backtrack output to remove already-emitted prefix for chosen container.
                            Integer overlap = cursor - contentStart;
                            if (overlap > 0) {
                                Integer outputLength = output.length();
                                if (overlap > outputLength) {
                                    throw new DocGenException(
                                        'Template loop parsing error for "{#' +
                                            key +
                                            '}": internal overlap (' +
                                            overlap +
                                            ') exceeds output length (' +
                                            outputLength +
                                            '). ' +
                                            'This usually indicates malformed or mismatched loop tags (missing "{/' +
                                            key +
                                            '}").'
                                    );
                                }
                                output = output.substring(0, outputLength - overlap);
                            }
                            cursor = contentEnd;
                        } else {
                            // Fallback behavior: keep default content-only repetition.
                            cursor = closeTagEnd + 1;
                        }

                        // Split on {:else} if present. Issue #68: scan must
                        // ignore {:else} inside any nested section opener so
                        // an inner {#IF}{:else}{/IF} does not get split open
                        // by the outer scope.
                        String trueBranch = innerXml;
                        String elseBranch = null;
                        Integer elsePos = findElseAtDepthZero(innerXml);
                        if (elsePos != -1) {
                            trueBranch = innerXml.substring(0, elsePos);
                            elseBranch = innerXml.substring(elsePos + 7); // 7 = '{:else}'.length()
                        }

                        // Check for {#IF Field op Value} comparison conditional
                        if (key.startsWith('IF ') || key.startsWith('if ')) {
                            Boolean ifResult = evaluateIfExpression(key.substring(3).trim(), data);
                            if (ifResult) {
                                output += processXml(trueBranch, data);
                            } else if (elseBranch != null) {
                                output += processXml(elseBranch, data);
                            }
                            cursor = (closeTagEnd != -1 ? closeTagEnd + 1 : sectionEnd);
                            continue;
                        }

                        // {#GroupBy <Relationship> by <Field>} — repeat the block once
                        // per distinct value of Field among the relationship's records
                        // (Conga-style grouping). {GroupName} is the group value and the
                        // inner {#<Relationship>}…/{SUM:<Relationship>.…} are scoped to
                        // the current group's members.
                        if (key.startsWithIgnoreCase('GroupBy ')) {
                            output += renderGroupBy(key.substring(8).trim(), trueBranch, data);
                            cursor = (closeTagEnd != -1 ? closeTagEnd + 1 : sectionEnd);
                            continue;
                        }

                        // Process Data
                        Object val = resolveValue(data, key);
                        String sectionResult = '';
                        Boolean isTruthy = false;
                        if (val instanceof Boolean && (Boolean) val) {
                            isTruthy = true;
                            sectionResult = processXml(trueBranch, data);
                        } else if (val instanceof Map<String, Object>) {
                            isTruthy = true;
                            Map<String, Object> mapVal = (Map<String, Object>) val;
                            if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                                List<Object> records = (List<Object>) mapVal.get('records');
                                // Pre-fetch attached images for all iteration records if the loop body uses {%Image:N}
                                if (loopBodyHasImageTag(trueBranch) && !records.isEmpty()) {
                                    Set<Id> loopIds = new Set<Id>();
                                    for (Object item : records) {
                                        if (item instanceof Map<String, Object>) {
                                            Object idVal = ((Map<String, Object>) item).get('Id');
                                            if (idVal != null) {
                                                try {
                                                    loopIds.add(Id.valueOf(String.valueOf(idVal)));
                                                } catch (Exception e) {
                                                }
                                            }
                                        }
                                    }
                                    prefetchImagesForIds(loopIds);
                                }
                                Integer iterCount = 0;
                                Boolean wantsRowNumber = loopBodyHasRowNumberTag(trueBranch);
                                Integer rowNumber = 0;
                                for (Object item : records) {
                                    if (item instanceof Map<String, Object>) {
                                        rowNumber++;
                                        sectionResult += processXml(
                                            trueBranch,
                                            rowContext((Map<String, Object>) item, wantsRowNumber, rowNumber)
                                        );
                                    }
                                    iterCount++;
                                    if (Math.mod(iterCount, HEAP_CHECK_EVERY_N_ITERS) == 0) {
                                        checkHeapPressure(key);
                                    }
                                }
                            } else {
                                sectionResult = processXml(trueBranch, mapVal);
                            }
                        } else if (val instanceof List<Object>) {
                            List<Object> listVal = (List<Object>) val;
                            if (!listVal.isEmpty()) {
                                isTruthy = true;
                            }
                            // Pre-fetch attached images for all iteration records if the loop body uses {%Image:N}
                            if (loopBodyHasImageTag(trueBranch) && !listVal.isEmpty()) {
                                Set<Id> loopIds = new Set<Id>();
                                for (Object item : listVal) {
                                    if (item instanceof Map<String, Object>) {
                                        Object idVal = ((Map<String, Object>) item).get('Id');
                                        if (idVal != null) {
                                            try {
                                                loopIds.add(Id.valueOf(String.valueOf(idVal)));
                                            } catch (Exception e) {
                                            }
                                        }
                                    }
                                }
                                prefetchImagesForIds(loopIds);
                            }
                            Integer iterCount = 0;
                            Boolean wantsRowNumber = loopBodyHasRowNumberTag(trueBranch);
                            Integer rowNumber = 0;
                            for (Object item : listVal) {
                                if (item instanceof Map<String, Object>) {
                                    rowNumber++;
                                    sectionResult += processXml(
                                        trueBranch,
                                        rowContext((Map<String, Object>) item, wantsRowNumber, rowNumber)
                                    );
                                }
                                iterCount++;
                                if (Math.mod(iterCount, HEAP_CHECK_EVERY_N_ITERS) == 0) {
                                    checkHeapPressure(key);
                                }
                            }
                        } else if (val instanceof String) {
                            // Strings: blank/whitespace-only and "visually empty" rich text
                            // (e.g. <p><br></p>) are treated as falsy. Symmetric with the
                            // inverse-section path below (issue #48).
                            if (!isVisuallyBlankRichText((String) val)) {
                                isTruthy = true;
                                sectionResult = processXml(trueBranch, data);
                            }
                        } else if (val != null && !(val instanceof Boolean)) {
                            // Non-null, non-boolean, non-list, non-map, non-string value
                            isTruthy = true;
                            sectionResult = processXml(trueBranch, data);
                        }

                        if (!isTruthy && elseBranch != null) {
                            sectionResult = processXml(elseBranch, data);
                        }
                        output += sectionResult;
                    }
                } else if (tagContent.startsWith('^')) {
                    // Inverse conditional: {^BoolField}content{/BoolField}
                    // Shows content when field is false, null, blank, or empty list
                    String key = tagContent.substring(1).trim();
                    Integer sectionEnd = findBalancedEnd(xml, tagClose + 1, key);
                    if (sectionEnd == -1) {
                        String snippet = xml.substring(Math.max(0, tagStartPos - 40), Math.min(len, tagStartPos + 40));
                        String lineInfo = currentTemplateType == 'HTML'
                            ? ' (line ' + (xml.substring(0, tagStartPos).countMatches('\n') + 1) + ')'
                            : '';
                        throw new DocGenException(
                            'Malformed inverse tag: missing closing "{/' +
                                key +
                                '}" for "{^' +
                                key +
                                '}"' +
                                lineInfo +
                                ' opened near "' +
                                snippet +
                                '".'
                        );
                    } else {
                        Integer contentStart = tagClose + 1;
                        Integer contentEnd = sectionEnd;
                        String innerXml = xml.substring(contentStart, contentEnd);
                        Integer closeTagEnd = xml.indexOf('}', sectionEnd);
                        // Split on {:else} if present. Same depth-aware scan
                        // as the truthy path (issue #68).
                        String inverseTrueBranch = innerXml;
                        String inverseElseBranch = null;
                        Integer inverseElsePos = findElseAtDepthZero(innerXml);
                        if (inverseElsePos != -1) {
                            inverseTrueBranch = innerXml.substring(0, inverseElsePos);
                            inverseElseBranch = innerXml.substring(inverseElsePos + 7);
                        }

                        String sectionResult = '';
                        Object val = resolveValue(data, key);
                        Boolean isFalsy =
                            (val == null) ||
                            (val instanceof Boolean && !(Boolean) val) ||
                            (val instanceof String && isVisuallyBlankRichText((String) val)) ||
                            (val instanceof List<Object> && ((List<Object>) val).isEmpty());
                        if (isFalsy) {
                            sectionResult = processXml(inverseTrueBranch, data);
                        } else if (inverseElseBranch != null) {
                            sectionResult = processXml(inverseElseBranch, data);
                        }
                        output += sectionResult;
                        cursor = (closeTagEnd != -1 ? closeTagEnd + 1 : sectionEnd);
                    }
                } else if (tagContent.startsWith('/')) {
                    output += '{' + rawTag + '}';
                    cursor = tagClose + 1;
                } else if (tagContent.startsWith('%')) {
                    // Image tag: {%FieldName} or {%FieldName:WxH} or {%Image:N} or {%Image:N:SIZE}
                    String imageTagSpec = tagContent.substring(1).trim();

                    // Shared-asset image tag: {%asset:<key>} or {%asset:<key>:SIZE}.
                    // The key resolves at generation time to the asset's latest
                    // ContentVersion; the resolved CV Id then flows through the
                    // EXISTING image pipeline (dispatchImageXml) so every format +
                    // sizing token is reused with zero new render code. A missing or
                    // inactive asset degrades gracefully (placeholder, never a hard
                    // failure) inside resolveAssetTagSpec.
                    String assetTagHead = imageTagSpec.contains(':')
                        ? imageTagSpec.substringBefore(':').trim()
                        : imageTagSpec.trim();
                    if ('asset'.equalsIgnoreCase(assetTagHead)) {
                        // Authors naturally write <img src="{%asset:logo}"> in
                        // header/footer HTML. The tag normally expands to a FULL
                        // <img> element — nested inside src that produces broken
                        // markup, so in attribute context emit just the URL.
                        if (isInsideSrcAttribute(xml, tagStartPos)) {
                            String remainder = imageTagSpec.substringAfter(':').trim();
                            String aKey = remainder.contains(':') ? remainder.substringBefore(':').trim() : remainder;
                            aKey = aKey.toLowerCase();
                            String aCvId = resolveAssetCvIds(new Set<String>{ aKey }).get(aKey);
                            if (String.isNotBlank(aCvId)) {
                                output += '/sfc/servlet.shepherd/version/download/' + aCvId;
                            }
                            cursor = tagClose + 1;
                            continue;
                        }
                        String assetXml = resolveAssetTagSpec(imageTagSpec);
                        if (assetXml != null) {
                            output += assetXml;
                        }
                        cursor = tagClose + 1;
                        continue;
                    }

                    // Positional record-attached-image tag: {%Image:N} or {%Image:N:SIZE}
                    // Renders the Nth oldest image (PNG/JPG/GIF/BMP/TIFF/SVG) attached to the current record.
                    String imageTagHead = imageTagSpec.contains(':')
                        ? imageTagSpec.substringBefore(':').trim()
                        : imageTagSpec.trim();
                    if ('Image'.equalsIgnoreCase(imageTagHead)) {
                        ImageRenderSpec indexedSpec = resolveImageByIndexTag(imageTagSpec, data);
                        if (indexedSpec != null && String.isNotBlank(indexedSpec.fieldValue)) {
                            String imageXml = dispatchImageXml(indexedSpec);
                            if (imageXml != null) {
                                output += imageXml;
                            }
                        }
                        cursor = tagClose + 1;
                        continue;
                    }

                    ImageRenderSpec imageRenderSpec = parseImageTagSpec(imageTagSpec);
                    Object val = resolveValue(data, imageRenderSpec.imageField);
                    if (val != null) {
                        imageRenderSpec.fieldValue = String.valueOf(val);
                        String imageXml = dispatchImageXml(imageRenderSpec);
                        if (imageXml != null) {
                            output += imageXml;
                        }
                    }
                    cursor = tagClose + 1;
                } else if (tagContent.startsWith('*')) {
                    // Barcode/QR tag: {*Field}, {*Field:qr}, {*Field:qr:200}, {*Field:code128:300x80}
                    // Outputs a marker that DocGenHtmlRenderer renders as CSS for PDF
                    String barcodeSpec = tagContent.substring(1).trim();
                    List<String> bParts = barcodeSpec.split(':');
                    String barcodeField = bParts[0].trim();
                    String barcodeType = bParts.size() > 1 ? bParts[1].trim().toLowerCase() : 'code128';
                    String barcodeSize = bParts.size() > 2 ? bParts[2].trim() : '';
                    Object val = resolveValue(data, barcodeField);
                    if (val != null) {
                        String barcodeValue = String.valueOf(val).escapeXml();
                        // Marker format: ##BARCODE:type:size:VALUE##
                        output += '##BARCODE:' + barcodeType + ':' + barcodeSize + ':' + barcodeValue + '##';
                    }
                    cursor = tagClose + 1;
                } else if (tagContent.contains(':') && isAggregateTag(tagContent)) {
                    // Aggregate tag: {SUM:ChildList.Field}, {COUNT:ChildList}, {AVG:...}, {MIN:...}, {MAX:...}
                    String aggResult = resolveAggregate(tagContent, data);
                    if (aggResult != null) {
                        output += aggResult.escapeXml();
                    }
                    cursor = tagClose + 1;
                } else {
                    // Parse optional date format suffix: {FieldName:format}
                    String fieldName = tagContent;
                    String dateFormat = null;
                    if (tagContent.contains(':')) {
                        Integer colonIdx = tagContent.indexOf(':');
                        fieldName = tagContent.substring(0, colonIdx).trim();
                        dateFormat = tagContent.substring(colonIdx + 1).trim();
                    }

                    // {Today} and {Now} are built-in special tags — resolve before the
                    // data map so users don't need a formula field. Format suffixes
                    // (:MM/dd/yyyy, :date, :date:de_DE, etc.) work as with any field.
                    // For {Today} we construct the DateTime explicitly from year/month/day
                    // so downstream formatting lands on the same calendar day regardless
                    // of user timezone (DateTime.newInstance(Date, Time) can shift across
                    // midnight when user TZ differs from the scratch default).
                    Object val;
                    String upperField = fieldName.toUpperCase();
                    if (upperField == 'TODAY') {
                        Date td = Date.today();
                        val = DateTime.newInstance(td.year(), td.month(), td.day());
                    } else if (upperField == 'NOW') {
                        val = DateTime.now();
                    } else if (upperField.startsWith('RUNNINGUSER.')) {
                        // {RunningUser.X} — standard "prepared by" tag (v1.77+). Resolves
                        // from the executing user's User row. Allowlist enforced in helper.
                        val = resolveRunningUserField(fieldName.substring('RunningUser.'.length()));
                    } else {
                        val = resolveValue(data, fieldName);
                    }
                    if (val != null) {
                        // Snapshot/cache JSON round-trips turn Date/Datetime values into strings.
                        // Re-type them so format suffixes still apply (otherwise the raw string
                        // prints — the snapshot signed-PDF date bug):
                        //  - "yyyy-MM-dd" (DATE field): format by literal calendar day in GMT so
                        //    it never shifts by time zone (dateOnlyGmt).
                        //  - ISO datetime string (DATETIME field): parse and format in local time.
                        Boolean dateOnlyGmt = false;
                        if (val instanceof String) {
                            String dv = (String) val;
                            if (Pattern.matches('\\d{4}-\\d{2}-\\d{2}', dv)) {
                                val = DateTime.newInstanceGmt(
                                    Integer.valueOf(dv.substring(0, 4)),
                                    Integer.valueOf(dv.substring(5, 7)),
                                    Integer.valueOf(dv.substring(8, 10)),
                                    0,
                                    0,
                                    0
                                );
                                dateOnlyGmt = true;
                            } else if (
                                dv.length() >= 19 && Pattern.matches('\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}.*', dv)
                            ) {
                                try {
                                    val = (Datetime) JSON.deserialize('"' + dv + '"', Datetime.class);
                                } catch (Exception isoErr) {
                                    // Not a parseable datetime — leave the original string untouched.
                                }
                            }
                        }
                        String strVal;
                        // Apply formatting if a format specifier was provided
                        if (
                            dateFormat != null &&
                            dateFormat.toLowerCase().trim().startsWith('date') &&
                            (val instanceof DateTime || val instanceof Date)
                        ) {
                            // {Field:date} → user's locale default | {Field:date:locale} → explicit locale
                            String dateTrimmed = dateFormat.trim();
                            String dateLocale = dateTrimmed.contains(':')
                                ? dateTrimmed.substring(dateTrimmed.indexOf(':') + 1).trim()
                                : UserInfo.getLocale();
                            String pattern = getLocaleDatePattern(dateLocale);
                            DateTime dt = val instanceof DateTime
                                ? (DateTime) val
                                : DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                            strVal = dateOnlyGmt ? dt.formatGmt(pattern) : dt.format(pattern);
                        } else if (dateFormat != null && dateFormat.toLowerCase().trim() == 'label') {
                            strVal = resolvePicklistLabel(data, fieldName, val);
                        } else if (dateFormat != null && val instanceof DateTime) {
                            strVal = dateOnlyGmt
                                ? ((DateTime) val).formatGmt(dateFormat)
                                : ((DateTime) val).format(dateFormat);
                        } else if (dateFormat != null && val instanceof Date) {
                            DateTime dt = DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                            strVal = dt.format(dateFormat);
                        } else if (dateFormat != null && dateFormat.toLowerCase().trim() == 'checkbox') {
                            // {IsActive:checkbox} → [X] or [ ]
                            // Uses ASCII representation for universal font compatibility in PDF/DOCX
                            Boolean checked = val instanceof Boolean
                                ? (Boolean) val
                                : String.valueOf(val).equalsIgnoreCase('true');
                            strVal = checked ? '[X]' : '[ ]';
                        } else if (dateFormat != null && isNumericFormat(dateFormat)) {
                            strVal = formatNumber(val, dateFormat, data);
                        } else if (dateOnlyGmt) {
                            // No format suffix on a DATE field — show a clean locale date (GMT,
                            // no time component) rather than a Datetime's "00:00:00" tail.
                            strVal = ((DateTime) val).formatGmt(getLocaleDatePattern(UserInfo.getLocale()));
                        } else {
                            strVal = String.valueOf(val);
                        }
                        // Rich text HTML — convert to DOCX XML preserving formatting, images, and paragraphs
                        // PowerPoint: strip HTML tags and output plain text (Word XML corrupts PPTX)
                        if (
                            strVal.contains('<') &&
                            strVal.contains('>') &&
                            (strVal.containsIgnoreCase('<p') ||
                            strVal.containsIgnoreCase('<div') ||
                            strVal.containsIgnoreCase('<span') ||
                            strVal.containsIgnoreCase('<br') ||
                            strVal.containsIgnoreCase('<img') ||
                            strVal.containsIgnoreCase('<b>') ||
                            strVal.containsIgnoreCase('<i>') ||
                            strVal.containsIgnoreCase('<u>') ||
                            strVal.containsIgnoreCase('<strong') ||
                            strVal.containsIgnoreCase('<em') ||
                            strVal.containsIgnoreCase('<ul') ||
                            strVal.containsIgnoreCase('<ol') ||
                            strVal.containsIgnoreCase('<li'))
                        ) {
                            if (currentTemplateType == 'PowerPoint' || currentTemplateType == 'Excel') {
                                // Strip HTML tags for plain text in PPTX/XLSX — DrawingML/
                                // WordprocessingML rich-text runs don't exist in these parts
                                output += strVal.replaceAll('<[^>]+>', ' ').replaceAll('\\s+', ' ').trim().escapeXml();
                            } else if (currentTemplateType == 'HTML') {
                                // HTML templates: rich-text is already HTML — pass through and
                                // rewrite rtaImage URLs so Blob.toPdf can fetch the images.
                                output += convertRichTextToHtml(strVal);
                            } else {
                                // Carry forward run properties so rich-text values
                                // inherit the token run's formatting (#375, #32)
                                output += convertRichTextToDocxXml(
                                    strVal,
                                    extractCurrentRunProperties(output)
                                );
                            }
                        } else {
                            if (currentTemplateType == 'PowerPoint') {
                                output += strVal.escapeXml();
                            } else if (currentTemplateType == 'Excel') {
                                // Excel: literal newlines are valid inside <is><t> — never route
                                // through convertMultilineToXml, whose <w:r>/<w:br/> Word runs
                                // corrupt spreadsheetml (mismatched-tag repair on open).
                                output += strVal.replace('\r\n', '\n').replace('\r', '\n').escapeXml();
                            } else if (currentTemplateType == 'HTML') {
                                // HTML templates: escape XML, convert newlines to <br/> so
                                // textarea/long-text fields preserve line breaks in the PDF.
                                output += strVal
                                    .replace('\r\n', '\n')
                                    .replace('\r', '\n')
                                    .escapeXml()
                                    .replace('\n', '<br/>');
                            } else {
                                // Carry forward run properties (font, size, bold, etc.) so formatting
                                // is preserved across line breaks in textarea fields (#32)
                                String rPr = extractCurrentRunProperties(output);
                                output += convertMultilineToXml(strVal, rPr);
                            }
                        }
                    }
                    cursor = tagClose + 1;
                }
            } catch (HeapPressureException hpe) {
                // Control-flow signal, NOT an author error: checkHeapPressure throws
                // this from inside loop bodies to make DocGenController switch to the
                // giant-query path. Must propagate untouched — wrapping it as a
                // DocGenException would defeat the upstream catch (#115 guard).
                throw hpe;
            } catch (DocGenException dge) {
                // Already author-facing (and may be enriched by a nested processXml
                // frame) — rethrow unchanged so the most specific tag is reported.
                throw dge;
            } catch (Exception e) {
                // Any other failure resolving this tag (e.g. navigating a null
                // relationship like {Account.Owner.Name}) — name the tag, show a
                // snippet, and add an HTML line number so authors can find it (#115).
                String snippet = xml.substring(Math.max(0, tagStartPos - 40), Math.min(len, tagClose + 40));
                String lineInfo = currentTemplateType == 'HTML'
                    ? ' (line ' + (xml.substring(0, tagStartPos).countMatches('\n') + 1) + ')'
                    : '';
                throw new DocGenException(
                    'Error resolving tag "{' + rawTag + '}"' + lineInfo + ' near "' + snippet + '": ' + e.getMessage()
                );
            }
        }
        return output;
    }

    /**
     * Renders a {#GroupBy <Relationship> by <Field>} … {/GroupBy} block.
     *
     * Groups the relationship's already-retrieved child records by <Field>
     * (dot-paths like Product2.Family supported) and emits the block once per
     * distinct value, in FIRST-SEEN order — so the query's ORDER BY controls the
     * group order. Inside each rendered block:
     *   - {GroupName} resolves to the group's value (the header),
     *   - {#<Relationship>}…{/<Relationship>} loops only that group's members,
     *   - {SUM|COUNT|AVG|MIN|MAX:<Relationship>.Field} aggregate the group,
     * because the per-group context re-binds <Relationship> to just its members
     * (preserving the original value shape — plain list vs {records:…} map).
     * An empty/absent relationship renders nothing.
     */
    private static String renderGroupBy(String spec, String block, Map<String, Object> data) {
        Integer byIdx = spec.toLowerCase().indexOf(' by ');
        if (byIdx == -1) {
            throw new DocGenException(
                'Malformed {#GroupBy}: expected "{#GroupBy <Relationship> by <Field>}", got "{#GroupBy ' + spec + '}".'
            );
        }
        String relName = spec.substring(0, byIdx).trim();
        String groupField = spec.substring(byIdx + 4).trim();
        if (String.isBlank(relName) || String.isBlank(groupField)) {
            throw new DocGenException(
                'Malformed {#GroupBy}: a relationship and a field are both required, ' +
                'e.g. "{#GroupBy OpportunityLineItems by Product2.Family}".'
            );
        }
        Object originalVal = data.get(relName);
        List<Object> records = childRecordsOf(originalVal);
        if (records == null || records.isEmpty()) {
            return '';
        }
        List<String> order = new List<String>();
        Map<String, List<Object>> groups = new Map<String, List<Object>>();
        Map<String, Object> rawByKey = new Map<String, Object>();
        for (Object rec : records) {
            if (!(rec instanceof Map<String, Object>)) {
                continue;
            }
            Object gv = resolveValue((Map<String, Object>) rec, groupField);
            String gk = gv == null ? '' : String.valueOf(gv);
            if (!groups.containsKey(gk)) {
                groups.put(gk, new List<Object>());
                order.add(gk);
                rawByKey.put(gk, gv);
            }
            groups.get(gk).add(rec);
        }
        String out = '';
        for (String gk : order) {
            Map<String, Object> ctx = new Map<String, Object>(data);
            Object gv = rawByKey.get(gk);
            ctx.put('GroupName', gv == null ? '' : String.valueOf(gv));
            // Re-bind the relationship to this group's members, keeping the
            // original value shape so inner loops AND aggregates work unchanged.
            if (originalVal instanceof Map<String, Object>) {
                Map<String, Object> gm = new Map<String, Object>((Map<String, Object>) originalVal);
                gm.put('records', groups.get(gk));
                ctx.put(relName, gm);
            } else {
                ctx.put(relName, groups.get(gk));
            }
            out += processXml(block, ctx);
        }
        return out;
    }

    /** Extracts the record list from a relationship value that is either a plain
     *  List<Object> or a {records: List<Object>, …} map (aliased/subset form). */
    private static List<Object> childRecordsOf(Object v) {
        if (v instanceof List<Object>) {
            return (List<Object>) v;
        }
        if (v instanceof Map<String, Object>) {
            Object recs = ((Map<String, Object>) v).get('records');
            if (recs instanceof List<Object>) {
                return (List<Object>) recs;
            }
        }
        return null;
    }

    private static Integer findBalancedEnd(String xml, Integer startSearch, String key) {
        Integer depth = 1;
        Integer cursor = startSearch;
        while (cursor < xml.length()) {
            Integer nextStart = xml.indexOf('{', cursor);
            if (nextStart == -1) {
                return -1;
            }
            Integer nextClose = xml.indexOf('}', nextStart);
            if (nextClose == -1) {
                return -1;
            }
            String content = xml.substring(nextStart + 1, nextClose).trim();
            Boolean isOpener;
            Boolean isCloser;
            if (key == 'IF') {
                // IF openers carry an expression ("#IF Field > 0"), but the
                // close tag is bare "/IF". Match openers by prefix; the
                // closer remains exact-equals.
                isOpener =
                    content.equals('#IF') ||
                    content.startsWith('#IF ') ||
                    content.equals('^IF') ||
                    content.startsWith('^IF ');
                isCloser = content.equals('/IF');
            } else if (key == 'GroupBy') {
                // GroupBy openers carry a spec ("#GroupBy Rel by Field"); the
                // close tag is bare "/GroupBy". Same shape as IF above so nested
                // GroupBy blocks balance correctly.
                isOpener = content.equals('#GroupBy') || content.startsWith('#GroupBy ');
                isCloser = content.equals('/GroupBy');
            } else {
                isOpener = content.equals('#' + key) || content.equals('^' + key);
                isCloser = content.equals('/' + key);
            }
            if (isOpener) {
                depth++;
            } else if (isCloser) {
                depth--;
                if (depth == 0) {
                    return nextStart;
                }
            }
            cursor = nextClose + 1;
        }
        return -1;
    }

    // Find the {:else} that belongs to the *current* section, ignoring any
    // {:else} that belongs to a nested {#X}/{^X}/{#IF}/{^IF} block. Without
    // this, an outer loop body containing a nested {#IF}{:else}{/IF} would
    // mis-split on the inner {:else} (issue #68) — the engine would later
    // throw "Malformed loop tag" because the recursed trueBranch ended up
    // with an unclosed opener.
    private static Integer findElseAtDepthZero(String xml) {
        Integer depth = 0;
        Integer cursor = 0;
        while (cursor < xml.length()) {
            Integer nextOpen = xml.indexOf('{', cursor);
            if (nextOpen == -1) {
                return -1;
            }
            Integer nextClose = xml.indexOf('}', nextOpen);
            if (nextClose == -1) {
                return -1;
            }
            String content = xml.substring(nextOpen + 1, nextClose).trim();
            if (depth == 0 && content == ':else') {
                return nextOpen;
            }
            if (content.startsWith('#') || content.startsWith('^')) {
                depth++;
            } else if (content.startsWith('/')) {
                depth--;
            }
            cursor = nextClose + 1;
        }
        return -1;
    }

    /**
     * Evaluates an IF expression like "Amount > 10000" or "Stage = 'Closed Won'".
     * Supports operators: =, !=, >, <, >=, <=
     * Values can be numbers, quoted strings, or field references.
     * Credit: conditional logic approach inspired by @ssk42 (PR #15)
     */
    // 1.72 — boolean expression parser supporting AND/&&, OR/||, NOT/!,
    // and parens, with standard precedence (NOT > comparison > AND > OR).
    // Quoted-string contents are opaque (a literal "AND" inside 'big AND small'
    // is preserved). Single-comparison expressions go through unchanged.
    private class IfTok {
        String type; // 'AND' | 'OR' | 'NOT' | 'LPAREN' | 'RPAREN' | 'TERM'
        String text;
    }

    private class IfParseState {
        List<IfTok> toks;
        Integer pos;
        Map<String, Object> data;
    }

    private static Boolean evaluateIfExpression(String expression, Map<String, Object> data) {
        // Word/OOXML escapes >, <, &, ', " in text runs, so expressions arrive
        // here with &gt;/&lt;/&amp;/&apos;/&quot; instead of literal chars.
        // Without decoding, the operator parser matches the `=` inside `&gt;`
        // and produces a mangled (always-false) expression.
        if (expression != null) {
            expression = expression
                .replace('&gt;', '>')
                .replace('&lt;', '<')
                .replace('&apos;', '\'')
                .replace('&quot;', '"')
                .replace('&amp;', '&');
        }
        if (String.isBlank(expression)) {
            return false;
        }

        List<IfTok> toks = tokenizeIfExpr(expression);
        if (toks.isEmpty()) {
            return false;
        }

        IfParseState st = new IfParseState();
        st.toks = toks;
        st.pos = 0;
        st.data = data;
        return parseIfOr(st);
    }

    private static Boolean parseIfOr(IfParseState st) {
        Boolean left = parseIfAnd(st);
        while (st.pos < st.toks.size() && st.toks[st.pos].type == 'OR') {
            st.pos++;
            Boolean right = parseIfAnd(st);
            left = left || right;
        }
        return left;
    }

    private static Boolean parseIfAnd(IfParseState st) {
        Boolean left = parseIfNot(st);
        while (st.pos < st.toks.size() && st.toks[st.pos].type == 'AND') {
            st.pos++;
            Boolean right = parseIfNot(st);
            left = left && right;
        }
        return left;
    }

    private static Boolean parseIfNot(IfParseState st) {
        if (st.pos < st.toks.size() && st.toks[st.pos].type == 'NOT') {
            st.pos++;
            return !parseIfNot(st);
        }
        return parseIfPrimary(st);
    }

    private static Boolean parseIfPrimary(IfParseState st) {
        if (st.pos >= st.toks.size()) {
            return false;
        }
        IfTok t = st.toks[st.pos];
        if (t.type == 'LPAREN') {
            st.pos++;
            Boolean result = parseIfOr(st);
            if (st.pos < st.toks.size() && st.toks[st.pos].type == 'RPAREN') {
                st.pos++;
            }
            return result;
        }
        if (t.type == 'TERM') {
            st.pos++;
            return evaluateSingleComparison(t.text, st.data);
        }
        // Unexpected token (stray AND/OR/NOT/RPAREN) — skip and continue
        st.pos++;
        return false;
    }

    private static List<IfTok> tokenizeIfExpr(String expression) {
        // Normalize word-keyword AND/OR/NOT (case-insensitive, word-boundary,
        // outside quoted strings) to symbolic && / || / !.
        String norm = normalizeBoolOps(expression);
        List<IfTok> out = new List<IfTok>();
        Integer i = 0;
        Integer len = norm.length();
        String cur = '';
        Boolean inSingle = false;
        Boolean inDouble = false;
        while (i < len) {
            String c = norm.substring(i, i + 1);
            if (!inSingle && !inDouble) {
                if (c == '(' || c == ')') {
                    addIfTerm(out, cur);
                    cur = '';
                    IfTok pt = new IfTok();
                    pt.type = (c == '(') ? 'LPAREN' : 'RPAREN';
                    pt.text = c;
                    out.add(pt);
                    i++;
                    continue;
                }
                if (c == '&' && i + 1 < len && norm.substring(i + 1, i + 2) == '&') {
                    addIfTerm(out, cur);
                    cur = '';
                    IfTok at = new IfTok();
                    at.type = 'AND';
                    at.text = '&&';
                    out.add(at);
                    i += 2;
                    continue;
                }
                if (c == '|' && i + 1 < len && norm.substring(i + 1, i + 2) == '|') {
                    addIfTerm(out, cur);
                    cur = '';
                    IfTok ot = new IfTok();
                    ot.type = 'OR';
                    ot.text = '||';
                    out.add(ot);
                    i += 2;
                    continue;
                }
                // Standalone ! (NOT) — only when not part of !=
                if (c == '!' && (i + 1 >= len || norm.substring(i + 1, i + 2) != '=') && cur.trim().length() == 0) {
                    addIfTerm(out, cur);
                    cur = '';
                    IfTok nt = new IfTok();
                    nt.type = 'NOT';
                    nt.text = '!';
                    out.add(nt);
                    i++;
                    continue;
                }
            }
            if (c == '\'' && !inDouble) {
                inSingle = !inSingle;
            }
            if (c == '"' && !inSingle) {
                inDouble = !inDouble;
            }
            cur += c;
            i++;
        }
        addIfTerm(out, cur);
        return out;
    }

    private static void addIfTerm(List<IfTok> out, String s) {
        if (String.isBlank(s)) {
            return;
        }
        IfTok t = new IfTok();
        t.type = 'TERM';
        t.text = s.trim();
        out.add(t);
    }

    private static String normalizeBoolOps(String expr) {
        if (expr == null) {
            return null;
        }
        String r = '';
        Integer i = 0;
        Integer len = expr.length();
        Boolean inSingle = false;
        Boolean inDouble = false;
        while (i < len) {
            String c = expr.substring(i, i + 1);
            if (!inSingle && !inDouble) {
                String upper = expr.substring(i).toUpperCase();
                Boolean leftOk = (i == 0) || !isWordChar(expr.substring(i - 1, i));
                if (leftOk) {
                    if (upper.startsWith('AND') && (i + 3 == len || !isWordChar(expr.substring(i + 3, i + 4)))) {
                        r += '&&';
                        i += 3;
                        continue;
                    }
                    if (upper.startsWith('OR') && (i + 2 == len || !isWordChar(expr.substring(i + 2, i + 3)))) {
                        r += '||';
                        i += 2;
                        continue;
                    }
                    if (upper.startsWith('NOT') && (i + 3 == len || !isWordChar(expr.substring(i + 3, i + 4)))) {
                        r += '!';
                        i += 3;
                        continue;
                    }
                }
            }
            if (c == '\'' && !inDouble) {
                inSingle = !inSingle;
            }
            if (c == '"' && !inSingle) {
                inDouble = !inDouble;
            }
            r += c;
            i++;
        }
        return r;
    }

    private static Boolean isWordChar(String c) {
        if (String.isEmpty(c)) {
            return false;
        }
        if (c == '_') {
            return true;
        }
        return c.isAlphanumeric();
    }

    private static Boolean evaluateSingleComparison(String expression, Map<String, Object> data) {
        // Parse: "Field op Value" — find the operator. Two-char operators
        // must come before their single-char prefixes (==, >=, <= before =,
        // >, <) or indexOf would match the prefix inside the longer form.
        String[] operators = new List<String>{ '!=', '==', '>=', '<=', '=', '>', '<' };
        String op = null;
        String fieldPart = null;
        String valuePart = null;

        for (String testOp : operators) {
            Integer opIdx = expression.indexOf(testOp);
            if (opIdx > 0) {
                op = testOp;
                fieldPart = expression.substring(0, opIdx).trim();
                valuePart = expression.substring(opIdx + testOp.length()).trim();
                break;
            }
        }

        if (op == null || fieldPart == null || valuePart == null) {
            // No operator — treat the whole expression as a single field
            // reference and apply truthy semantics. Pre-1.72 this returned
            // false unconditionally, so {#IF BooleanField} and {#IF Rel}
            // never rendered their bodies.
            Object v = resolveValue(data, expression.trim());
            if (v == null) {
                return false;
            }
            if (v instanceof Boolean) {
                return (Boolean) v;
            }
            if (v instanceof List<Object>) {
                return !((List<Object>) v).isEmpty();
            }
            if (v instanceof Map<String, Object>) {
                Map<String, Object> mv = (Map<String, Object>) v;
                // {records:[…], totalSize:N} wrapper — truthy when non-empty
                if (mv.containsKey('records') && mv.get('records') instanceof List<Object>) {
                    return !((List<Object>) mv.get('records')).isEmpty();
                }
                return true;
            }
            String s = String.valueOf(v);
            if (String.isBlank(s)) {
                return false;
            }
            if (s.equalsIgnoreCase('false')) {
                return false;
            }
            if (s == '0') {
                return false;
            }
            return true;
        }

        // Resolve field value
        Object fieldVal = resolveValue(data, fieldPart);
        String fieldStr = fieldVal != null ? String.valueOf(fieldVal) : '';

        // Strip surrounding quotes from value literal — accept both single
        // and double quotes. Issue #69: double-quoted form silently failed
        // because only single quotes were stripped, so `"X"` was compared
        // against the unquoted field value verbatim and never matched.
        if (
            (valuePart.startsWith('\'') && valuePart.endsWith('\'')) ||
            (valuePart.startsWith('"') && valuePart.endsWith('"'))
        ) {
            valuePart = valuePart.substring(1, valuePart.length() - 1);
        }

        // Try numeric comparison first
        try {
            Decimal fieldNum = Decimal.valueOf(fieldStr);
            Decimal valueNum = Decimal.valueOf(valuePart);
            if (op == '=' || op == '==') {
                return fieldNum == valueNum;
            }
            if (op == '!=') {
                return fieldNum != valueNum;
            }
            if (op == '>') {
                return fieldNum > valueNum;
            }
            if (op == '<') {
                return fieldNum < valueNum;
            }
            if (op == '>=') {
                return fieldNum >= valueNum;
            }
            if (op == '<=') {
                return fieldNum <= valueNum;
            }
        } catch (Exception e) {
            // Not numeric — fall through to string comparison
        }

        // String comparison
        if (op == '=' || op == '==') {
            return fieldStr == valuePart;
        }
        if (op == '!=') {
            return fieldStr != valuePart;
        }
        if (op == '>') {
            return fieldStr > valuePart;
        }
        if (op == '<') {
            return fieldStr < valuePart;
        }
        if (op == '>=') {
            return fieldStr >= valuePart;
        }
        if (op == '<=') {
            return fieldStr <= valuePart;
        }

        return false;
    }

    /**
     * True when a brace token is an OOXML GUID rather than a merge tag —
     * canonical 8-4-4-4-12 hex with hyphens, e.g. {0D108BD9-81ED-4DB2-BD59-A6C34878D82A}.
     * Salesforce field names, relationship paths, and every supported tag prefix
     * ({#, {/, {^, {%, {@, {:) are excluded by shape, so this never shadows a real tag.
     */
    @TestVisible
    private static Boolean isOoxmlGuidToken(String tagContent) {
        if (String.isBlank(tagContent) || tagContent.length() != 36) {
            return false;
        }
        return Pattern.matches(
            '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}',
            tagContent
        );
    }

    /**
     * Removes every <a:extLst> block that carries an <a16:rowId> change-tracking
     * extension. Used when a {#Loop} clones a DrawingML table row: the authored
     * row's rowId would otherwise be duplicated across every clone. The extension
     * is optional (Microsoft drawing/2014), so dropping it is safe — unlike Excel's
     * <row r="…"> indices, which are core spec and must be renumbered instead.
     *
     * Scans for the enclosing extLst rather than regex-matching so a cell-level
     * extLst without a rowId is left untouched.
     */
    @TestVisible
    private static String stripDrawingMlRowIds(String rowXml) {
        if (String.isBlank(rowXml) || !rowXml.contains('a16:rowId')) {
            return rowXml;
        }
        String result = rowXml;
        while (true) {
            Integer rowIdAt = result.indexOf('a16:rowId');
            if (rowIdAt == -1) {
                break;
            }
            Integer blockStart = result.lastIndexOf('<a:extLst>', rowIdAt);
            Integer blockEnd = result.indexOf('</a:extLst>', rowIdAt);
            if (blockStart == -1 || blockEnd == -1) {
                // Malformed or unexpected shape — leave the markup alone rather
                // than risk cutting valid XML out of the row.
                break;
            }
            result = result.substring(0, blockStart) + result.substring(blockEnd + 11); // </a:extLst>
        }
        return result;
    }

    private static Integer lastIndexOfTagStart(String xml, String tagName, Integer fromIndex) {
        if (String.isBlank(xml) || String.isBlank(tagName) || fromIndex == null || fromIndex < 0) {
            return -1;
        }
        Integer searchIndex = Math.min(fromIndex, xml.length());
        Integer withAttributesIndex = xml.lastIndexOf('<' + tagName + ' ', searchIndex);
        Integer bareTagIndex = xml.lastIndexOf('<' + tagName + '>', searchIndex);
        return Math.max(withAttributesIndex, bareTagIndex);
    }

    /**
     * Converts a text value with newlines to Word XML with <w:br/> line breaks.
     * Properly closes and reopens <w:r> runs around each break for valid OOXML.
     * Carries forward run properties (rPr) so formatting is preserved across breaks.
     */
    private static String convertMultilineToXml(String inputText, String rPr) {
        if (inputText == null) {
            return '';
        }
        String normalized = inputText.replace('\r\n', '\n').replace('\r', '\n');
        if (!normalized.contains('\n')) {
            return normalized.escapeXml();
        }
        List<String> lines = normalized.split('\n');
        String result = '';
        String rPrXml = String.isNotBlank(rPr) ? rPr : '';
        String lineBreakXml =
            '</w:t></w:r><w:r>' +
            rPrXml +
            '<w:br/></w:r><w:r>' +
            rPrXml +
            '<w:t xml:space="preserve">';
        for (Integer i = 0; i < lines.size(); i++) {
            if (i > 0) {
                result += lineBreakXml;
            }
            result += lines[i].escapeXml();
        }
        return result;
    }

    /**
     * Extracts the <w:rPr>...</w:rPr> block from the current open <w:r> run in the output.
     * Returns empty string if no run properties found.
     */
    @TestVisible
    private static String extractCurrentRunProperties(String output) {
        if (String.isBlank(output)) {
            return '';
        }
        // Find the last <w:r> or <w:r > opening (start of current run)
        Integer lastRunOpen = output.lastIndexOf('<w:r>');
        Integer lastRunOpenAttr = output.lastIndexOf('<w:r ');
        Integer runStart = Math.max(
            lastRunOpen != null ? lastRunOpen : -1,
            lastRunOpenAttr != null ? lastRunOpenAttr : -1
        );
        if (runStart < 0) {
            return '';
        }
        // If there's a </w:r> after this opening, we're not inside an open run
        Integer lastRunClose = output.lastIndexOf('</w:r>');
        if (lastRunClose != null && lastRunClose > runStart) {
            return '';
        }
        // Find <w:rPr>...</w:rPr> within this run
        Integer rPrStart = output.indexOf('<w:rPr>', runStart);
        if (rPrStart < 0) {
            rPrStart = output.indexOf('<w:rPr ', runStart);
        }
        if (rPrStart < 0) {
            return '';
        }
        Integer rPrEnd = output.indexOf('</w:rPr>', rPrStart);
        if (rPrEnd < 0) {
            return '';
        }
        return output.substring(rPrStart, rPrEnd + 8);
    }

    private static Object resolveValue(Map<String, Object> data, String path) {
        if (data == null) {
            return null;
        }
        List<String> parts = path.split('\\.');
        Object current = data;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                if (currentMap.containsKey(part)) {
                    current = currentMap.get(part);
                } else {
                    // Try case-insensitive comparison
                    Boolean found = false;
                    for (String key : currentMap.keySet()) {
                        if (key.equalsIgnoreCase(part)) {
                            current = currentMap.get(key);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // If first segment doesn't match, it may be the base object name
                        // (e.g., "Contact" in {!Contact.FirstName}). Skip it and continue.
                        if (i == 0 && parts.size() > 1 && !part.endsWithIgnoreCase('__r')) {
                            continue;
                        }
                        return null;
                    }
                }
            } else if (current instanceof SObject) {
                SObject sobj = (SObject) current;
                try {
                    current = sobj.get(part);
                } catch (Exception e) {
                    return null;
                }
            } else {
                return null;
            }
            if (current == null) {
                return null;
            }
        }
        return current;
    }

    private static String resolvePicklistLabel(Map<String, Object> data, String path, Object rawValue) {
        String fallback = rawValue == null ? '' : String.valueOf(rawValue);
        Map<String, Object> parent = resolveParentMap(data, path);
        if (parent == null || !parent.containsKey('__docgenPicklistLabels')) {
            return fallback;
        }
        // Read as Map<String,Object>, NOT Map<String,String>. The bulk path serializes
        // the whole data map to JSON for the batch data cache (DocGenBatch.buildDataCache)
        // and re-hydrates it with JSON.deserializeUntyped, which reconstitutes every
        // nested map as Map<String,Object>. The stricter cast threw
        // "Invalid conversion from runtime type Map<String,ANY> to Map<String,String>"
        // for any template using {Field:label} — a hard failure in bulk only.
        // Map<String,Object> accepts both the live and the round-tripped shape.
        Map<String, Object> labels = (Map<String, Object>) parent.get('__docgenPicklistLabels');
        if (labels == null) {
            return fallback;
        }
        String leaf = path.contains('.') ? path.substringAfterLast('.') : path;
        if (labels.containsKey(leaf)) {
            return labels.get(leaf) == null ? fallback : String.valueOf(labels.get(leaf));
        }
        for (String key : labels.keySet()) {
            if (key.equalsIgnoreCase(leaf)) {
                return labels.get(key) == null ? fallback : String.valueOf(labels.get(key));
            }
        }
        return fallback;
    }

    private static Map<String, Object> resolveParentMap(Map<String, Object> data, String path) {
        if (data == null || String.isBlank(path) || !path.contains('.')) {
            return data;
        }
        List<String> parts = path.split('\\.');
        Object current = data;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (!(current instanceof Map<String, Object>)) {
                return null;
            }
            Map<String, Object> currentMap = (Map<String, Object>) current;
            if (currentMap.containsKey(parts[i])) {
                current = currentMap.get(parts[i]);
                continue;
            }
            Boolean found = false;
            for (String key : currentMap.keySet()) {
                if (key.equalsIgnoreCase(parts[i])) {
                    current = currentMap.get(key);
                    found = true;
                    break;
                }
            }
            if (!found) {
                return null;
            }
        }
        return current instanceof Map<String, Object> ? (Map<String, Object>) current : null;
    }

    // ---------------------------------------------------------------------------
    // Aggregate Tags: {SUM:List.Field}, {COUNT:List}, {AVG:...}, {MIN:...}, {MAX:...}
    // ---------------------------------------------------------------------------

    // ---------------------------------------------------------------------------
    // Excel Shared String Inlining
    // ---------------------------------------------------------------------------

    /**
     * Parses xl/sharedStrings.xml and returns an ordered list of string values.
     * Each <si> element at index N is the string referenced by <v>N</v> in cells.
     */
    private static List<String> parseSharedStrings(String xml) {
        List<String> strings = new List<String>();
        if (String.isBlank(xml)) {
            return strings;
        }

        Integer cursor = 0;
        while (cursor < xml.length()) {
            Integer siStart = xml.indexOf('<si>', cursor);
            if (siStart == -1) {
                siStart = xml.indexOf('<si ', cursor);
            }
            if (siStart == -1) {
                break;
            }

            Integer siEnd = xml.indexOf('</si>', siStart);
            if (siEnd == -1) {
                break;
            }

            // Extract all <t> content within this <si>
            String siContent = xml.substring(siStart, siEnd);
            String value = '';
            Integer tCursor = 0;
            while (tCursor < siContent.length()) {
                Integer tStart = siContent.indexOf('<t', tCursor);
                if (tStart == -1) {
                    break;
                }
                Integer tTagEnd = siContent.indexOf('>', tStart);
                if (tTagEnd == -1) {
                    break;
                }
                // Skip self-closing
                if (siContent.substring(tTagEnd - 1, tTagEnd) == '/') {
                    tCursor = tTagEnd + 1;
                    continue;
                }
                Integer tEnd = siContent.indexOf('</t>', tTagEnd);
                if (tEnd == -1) {
                    break;
                }
                value += siContent.substring(tTagEnd + 1, tEnd);
                tCursor = tEnd + 4;
            }
            strings.add(value);
            cursor = siEnd + 5;
        }
        return strings;
    }

    /**
     * Converts cells that reference shared strings (t="s") to inline strings (t="inlineStr").
     * This allows processXml() to find and resolve merge tags inside cell values.
     *
     * Before: <c r="A1" t="s"><v>3</v></c>  (index 3 in shared strings = "{Name}")
     * After:  <c r="A1" t="inlineStr"><is><t>{Name}</t></is></c>
     */
    private static String inlineSharedStrings(String xml, List<String> sharedStrings) {
        if (sharedStrings.isEmpty()) {
            return xml;
        }

        String result = '';
        Integer cursor = 0;

        while (cursor < xml.length()) {
            // Find next cell element
            Integer cStart = xml.indexOf('<c ', cursor);
            if (cStart == -1) {
                result += xml.substring(cursor);
                break;
            }

            // Output everything before this cell
            result += xml.substring(cursor, cStart);

            // Self-closing cell (<c r="B1" s="24"/> — empty styled cell): detect from the
            // cell's OWN tag close, not by the absence of a later </c>. Searching for the
            // next </c> anywhere in the sheet made the "cell" span swallow the following
            // row boundary and the next cell's opening tag whenever an empty cell preceded
            // a shared-string cell — corrupting every generated sheet (mismatched tags).
            Integer tagClose = xml.indexOf('>', cStart);
            if (tagClose == -1) {
                result += xml.substring(cStart);
                break;
            }
            if (xml.substring(tagClose - 1, tagClose) == '/') {
                result += xml.substring(cStart, tagClose + 1);
                cursor = tagClose + 1;
                continue;
            }

            // Find cell end
            Integer cEnd = xml.indexOf('</c>', cStart);
            if (cEnd == -1) {
                result += xml.substring(cStart);
                break;
            }

            String cellXml = xml.substring(cStart, cEnd + 4);

            // Check if this is a shared string cell: t="s"
            if (cellXml.contains('t="s"')) {
                // Extract the <v> index
                Integer vStart = cellXml.indexOf('<v>');
                Integer vEnd = cellXml.indexOf('</v>');
                if (vStart != -1 && vEnd != -1) {
                    String indexStr = cellXml.substring(vStart + 3, vEnd).trim();
                    if (indexStr.isNumeric()) {
                        Integer idx = Integer.valueOf(indexStr);
                        if (idx >= 0 && idx < sharedStrings.size()) {
                            String value = sharedStrings[idx];
                            // Rebuild cell as inline string
                            String cellTag = cellXml.substring(0, cellXml.indexOf('>'));
                            cellTag = cellTag.replace('t="s"', 't="inlineStr"');
                            result += cellTag + '><is><t>' + value + '</t></is></c>';
                            cursor = cEnd + 4;
                            continue;
                        }
                    }
                }
            }

            // Not a shared string cell — pass through
            result += cellXml;
            cursor = cEnd + 4;
        }

        return result;
    }

    /**
     * Post-merge row renumbering for Excel worksheets. Loop expansion clones
     * <row> elements verbatim, so an expanded sheet carries duplicate row
     * indices (three rows all declaring r="2") and duplicate cell refs
     * (r="A2" in each clone) — Excel flags duplicate refs as corruption.
     * Walks sheetData in document order reassigning row numbers: original
     * rows keep their position (authored gaps preserved), clones push every
     * subsequent row down. Cell refs inside each row are rewritten to
     * <column letters><new row number>, and the <dimension> end row is
     * extended to the last assigned row.
     */
    @TestVisible
    private static String renumberExcelRows(String xml) {
        Integer sheetDataStart = xml.indexOf('<sheetData');
        if (sheetDataStart == -1) {
            return xml;
        }
        String result = xml.substring(0, sheetDataStart);
        Integer cursor = sheetDataStart;
        Integer lastAssigned = 0;
        Integer delta = 0;
        Pattern rowRefPattern = Pattern.compile('(<row[^>]*\\br=")(\\d+)(")');
        Pattern cellRefPattern = Pattern.compile('(<c[^>]*\\br=")([A-Z]+)(\\d+)(")');

        while (cursor < xml.length()) {
            Integer rowStart = xml.indexOf('<row', cursor);
            if (rowStart == -1) {
                result += xml.substring(cursor);
                break;
            }
            Integer rowEnd = xml.indexOf('</row>', rowStart);
            Integer rowSelfClose = xml.indexOf('/>', rowStart);
            Integer rowOpenEnd = xml.indexOf('>', rowStart);
            Boolean isSelfClosing = rowSelfClose != -1 && rowSelfClose + 1 == rowOpenEnd;
            Integer rowFullEnd = isSelfClosing ? rowOpenEnd + 1 : (rowEnd == -1 ? -1 : rowEnd + 6);
            if (rowFullEnd == -1) {
                result += xml.substring(cursor);
                break;
            }
            result += xml.substring(cursor, rowStart);
            String rowXml = xml.substring(rowStart, rowFullEnd);

            // Declared row index (r attribute is optional per OOXML spec)
            Matcher rowMatcher = rowRefPattern.matcher(rowXml);
            Integer newRow;
            if (rowMatcher.find()) {
                Integer declaredRow = Integer.valueOf(rowMatcher.group(2));
                newRow = declaredRow + delta;
                if (newRow <= lastAssigned) {
                    // Duplicate/overlap from loop expansion — shift down
                    newRow = lastAssigned + 1;
                    delta = newRow - declaredRow;
                }
                rowXml =
                    rowXml.substring(0, rowMatcher.start()) +
                    rowMatcher.group(1) +
                    newRow +
                    rowMatcher.group(3) +
                    rowXml.substring(rowMatcher.end());
            } else {
                newRow = lastAssigned + 1;
            }
            lastAssigned = newRow;

            // Rewrite cell refs to the assigned row, preserving column letters
            Matcher cellMatcher = cellRefPattern.matcher(rowXml);
            String rebuilt = '';
            Integer rowCursor = 0;
            while (cellMatcher.find()) {
                rebuilt += rowXml.substring(rowCursor, cellMatcher.start());
                rebuilt += cellMatcher.group(1) + cellMatcher.group(2) + newRow + cellMatcher.group(4);
                rowCursor = cellMatcher.end();
            }
            rebuilt += rowXml.substring(rowCursor);

            result += rebuilt;
            cursor = rowFullEnd;
        }

        // Extend the <dimension> end row to the last assigned row so readers
        // that trust the hint see the expanded extent.
        if (lastAssigned > 0) {
            Pattern dimPattern = Pattern.compile('(<dimension ref="[A-Z]+\\d+:[A-Z]+)(\\d+)(")');
            Matcher dimMatcher = dimPattern.matcher(result);
            if (dimMatcher.find() && Integer.valueOf(dimMatcher.group(2)) < lastAssigned) {
                result =
                    result.substring(0, dimMatcher.start()) +
                    dimMatcher.group(1) +
                    lastAssigned +
                    dimMatcher.group(3) +
                    result.substring(dimMatcher.end());
            }
        }

        return result;
    }

    // ---------------------------------------------------------------------------
    // Number/Currency/Date Formatting with Locale Support
    // {Amount:currency} → $500,000.00  (backward compat)
    // {Amount:currency:EUR} → €500,000.00  (ISO code → symbol)
    // {Amount:currency:EUR:de_DE} → 500.000,00 €  (full locale override)
    // {Amount:number:de_DE} → 500.000  (locale separators)
    // {Rate:percent:de_DE} → 15,5%  (locale decimal)
    // {CloseDate:date} → user locale default date
    // {CloseDate:date:de_DE} → 17.04.2026
    // {Quantity:#,##0} → 1,234  (custom pattern, unchanged)
    // ---------------------------------------------------------------------------

    /** Returns the thousands grouping separator for a locale. */
    private static String getLocaleGroupSep(String locale) {
        if (locale == null) {
            return ',';
        }
        String loc = locale.toLowerCase();
        // Apostrophe-as-thousands: Swiss French/German/Italian (CLDR spec). Check
        // before the broader fr_/de_/it_ branches below since these are exceptions.
        if (loc == 'fr_ch' || loc == 'de_ch' || loc == 'it_ch') {
            return '\'';
        }
        // Space-as-thousands: French (Metropolitan, Belgian, Luxembourg, Canadian).
        // Issue #97 — previously bucketed with German/Spanish (dot-as-thousands),
        // which is wrong: fr_FR formats 1 234 (NBSP) where de_DE formats 1.234.
        // Other locales that CLDR specifies as space-as-thousands (pl_PL, ru_RU,
        // uk_UA, cs_CZ, hu_HU, sv_SE, nb_NO, nn_NO) are still in the dot branch
        // below — they will need their own fix once verified against reporter data.
        if (loc.startsWith('fr_')) {
            return ' ';
        }
        // Dot-as-thousands: German, Spanish, Italian, Portuguese, Dutch, Danish,
        // Turkish, Romanian, Greek, Indonesian, Vietnamese — plus a residual set
        // (sv/nb/nn/pl/cs/hu/ru/uk) that CLDR actually specifies as space; left
        // here pending verification rather than introducing untested regressions.
        if (
            loc.startsWith('de_') ||
            loc.startsWith('es_') ||
            loc.startsWith('it_') ||
            loc.startsWith('pt_') ||
            loc.startsWith('nl_') ||
            loc.startsWith('da_') ||
            loc.startsWith('sv_') ||
            loc.startsWith('nb_') ||
            loc.startsWith('nn_') ||
            loc.startsWith('pl_') ||
            loc.startsWith('cs_') ||
            loc.startsWith('hu_') ||
            loc.startsWith('tr_') ||
            loc.startsWith('ro_') ||
            loc.startsWith('el_') ||
            loc.startsWith('ru_') ||
            loc.startsWith('uk_') ||
            loc.startsWith('id_') ||
            loc.startsWith('vi_')
        ) {
            return '.';
        }
        // Comma-as-thousands: English, Japanese, Chinese, Korean, and default
        return ',';
    }

    /** Returns the decimal separator for a locale. */
    private static String getLocaleDecSep(String locale) {
        if (locale == null) {
            return '.';
        }
        String loc = locale.toLowerCase();
        // Comma-as-decimal: same set that uses dot-as-thousands
        if (
            loc.startsWith('de_') ||
            loc.startsWith('fr_') ||
            loc.startsWith('es_') ||
            loc.startsWith('it_') ||
            loc.startsWith('pt_') ||
            loc.startsWith('nl_') ||
            loc.startsWith('da_') ||
            loc.startsWith('sv_') ||
            loc.startsWith('nb_') ||
            loc.startsWith('nn_') ||
            loc.startsWith('pl_') ||
            loc.startsWith('cs_') ||
            loc.startsWith('hu_') ||
            loc.startsWith('tr_') ||
            loc.startsWith('ro_') ||
            loc.startsWith('el_') ||
            loc.startsWith('ru_') ||
            loc.startsWith('uk_') ||
            loc.startsWith('id_') ||
            loc.startsWith('vi_')
        ) {
            // Exception: Swiss locales use dot as decimal
            if (loc == 'fr_ch' || loc == 'de_ch' || loc == 'it_ch') {
                return '.';
            }
            return ',';
        }
        return '.';
    }

    /** Returns whether currency symbol goes after the number for a locale. */
    private static Boolean isCurrencyAfter(String locale) {
        if (locale == null) {
            return false;
        }
        String loc = locale.toLowerCase();
        return loc.startsWith('de_') ||
            loc.startsWith('fr_') ||
            loc.startsWith('es_') ||
            loc.startsWith('it_') ||
            loc.startsWith('pt_') ||
            loc.startsWith('nl_') ||
            loc.startsWith('da_') ||
            loc.startsWith('sv_') ||
            loc.startsWith('nb_') ||
            loc.startsWith('nn_') ||
            loc.startsWith('pl_') ||
            loc.startsWith('cs_') ||
            loc.startsWith('hu_') ||
            loc.startsWith('tr_') ||
            loc.startsWith('ro_') ||
            loc.startsWith('el_') ||
            loc.startsWith('ru_') ||
            loc.startsWith('uk_');
    }

    /** Returns the default date format pattern for a locale. */
    private static String getLocaleDatePattern(String locale) {
        if (locale == null) {
            return 'yyyy-MM-dd';
        }
        String loc = locale.toLowerCase();
        if (loc.startsWith('en_us')) {
            return 'MM/dd/yyyy';
        }
        if (
            loc.startsWith('en_gb') ||
            loc.startsWith('en_au') ||
            loc.startsWith('en_nz') ||
            loc.startsWith('en_ie') ||
            loc.startsWith('en_in')
        ) {
            return 'dd/MM/yyyy';
        }
        if (loc.startsWith('de_')) {
            return 'dd.MM.yyyy';
        }
        if (loc.startsWith('fr_')) {
            return 'dd/MM/yyyy';
        }
        if (loc.startsWith('es_')) {
            return 'dd/MM/yyyy';
        }
        if (loc.startsWith('it_')) {
            return 'dd/MM/yyyy';
        }
        if (loc.startsWith('pt_')) {
            return 'dd/MM/yyyy';
        }
        if (loc.startsWith('nl_')) {
            return 'dd-MM-yyyy';
        }
        if (loc.startsWith('ja_')) {
            return 'yyyy/MM/dd';
        }
        if (loc.startsWith('zh_')) {
            return 'yyyy-MM-dd';
        }
        if (loc.startsWith('ko_')) {
            return 'yyyy. MM. dd';
        }
        if (loc.startsWith('ru_')) {
            return 'dd.MM.yyyy';
        }
        if (loc.startsWith('pl_') || loc.startsWith('cs_') || loc.startsWith('hu_')) {
            return 'dd.MM.yyyy';
        }
        if (loc.startsWith('da_') || loc.startsWith('sv_') || loc.startsWith('nb_') || loc.startsWith('nn_')) {
            return 'yyyy-MM-dd';
        }
        if (loc.startsWith('tr_')) {
            return 'dd.MM.yyyy';
        }
        // ISO 8601 as safe default
        return 'yyyy-MM-dd';
    }

    /** Formats a number with locale-aware group and decimal separators. */
    private static String formatNumberLocale(Decimal num, String groupSep, String decSep) {
        Boolean negative = num < 0;
        String raw = (negative ? num.abs() : num).toPlainString();

        String intPart = raw;
        String decPart = '';
        if (raw.contains('.')) {
            intPart = raw.substringBefore('.');
            decPart = decSep + raw.substringAfter('.');
        }

        // Insert group separators every 3 digits from the right
        String result = '';
        Integer count = 0;
        for (Integer i = intPart.length() - 1; i >= 0; i--) {
            if (count > 0 && Math.mod(count, 3) == 0) {
                result = groupSep + result;
            }
            result = intPart.substring(i, i + 1) + result;
            count++;
        }

        return (negative ? '-' : '') + result + decPart;
    }

    /**
     * True for template types whose stored body is an HTML document.
     *
     * `Canvas` is an AUTHORING type, not a rendering one: the canvas editor serializes
     * its artboards and boxes to ordinary HTML (absolutely positioned boxes inside
     * position:relative artboards — see scripts/canvas-layout-model-probe.apex), so
     * every downstream concern that cares "is the body HTML?" must answer yes for it.
     * That covers body storage, clone image rewriting and the render fork.
     */
    public static Boolean isHtmlBacked(String templateType) {
        return templateType == 'HTML' || templateType == 'Canvas';
    }

    private static Boolean isNumericFormat(String fmt) {
        if (fmt == null) {
            return false;
        }
        String lower = fmt.toLowerCase().trim();
        // Check first segment before colon to match extended forms like currency:EUR:de_DE
        String base = lower.contains(':') ? lower.substringBefore(':') : lower;
        return NUMERIC_FORMATS.contains(base) || lower.startsWith('#') || lower.startsWith('0');
    }

    private static String formatNumber(Object val, String fmt) {
        return formatNumber(val, fmt, null);
    }

    // 3-arg overload: `data` is the record's field map, used only by the
    // {Field:currency:auto[=SourceField]} token to read the currency ISO code
    // from the record at merge time. Null `data` reproduces the legacy behavior.
    private static String formatNumber(Object val, String fmt, Map<String, Object> data) {
        Decimal num;
        try {
            num = Decimal.valueOf(String.valueOf(val));
        } catch (Exception e) {
            return String.valueOf(val); // Not a number — return as-is
        }

        // Split format into segments: currency:EUR:de_DE → ['currency', 'EUR', 'de_DE']
        List<String> segments = fmt.trim().split(':');
        String baseFormat = segments[0].toLowerCase().trim();

        if (baseFormat == 'currency') {
            return formatCurrency(num, segments, data);
        } else if (baseFormat == 'percent') {
            return formatPercent(num, segments);
        } else if (baseFormat == 'number') {
            return formatPlainNumber(num, segments);
        } else {
            // Custom pattern: #,##0 or #,##0.00 — unchanged behavior, always US separators
            Integer decimals = 0;
            String lower = fmt.toLowerCase().trim();
            if (lower.contains('.')) {
                decimals = lower.substringAfter('.').length();
            }
            return formatNumberLocale(num.setScale(decimals, RoundingMode.HALF_UP), ',', '.');
        }
    }

    /** {Amount:currency} | {Amount:currency:EUR} | {Amount:currency:EUR:de_DE} */
    private static String formatCurrency(Decimal num, List<String> segments) {
        return formatCurrency(num, segments, null);
    }

    /**
     * {Amount:currency}                          → backward-compat hardcoded $
     * {Amount:currency:EUR[:de_DE]}              → explicit ISO (+ optional locale)
     * {Amount:currency:auto[:locale]}            → ISO read from the record's CurrencyIsoCode
     * {Amount:currency:auto=Field__c[:locale]}   → ISO read from a named record field
     *
     * The auto forms need the record's field map (`data`); when it's null/missing the
     * source field, or the value isn't a known ISO code, we fall back to the safe `$`
     * output so the token never throws or renders raw text.
     */
    private static String formatCurrency(Decimal num, List<String> segments, Map<String, Object> data) {
        // Bare :currency → backward compat: hardcoded $ with US separators
        if (segments.size() == 1) {
            return formatCurrencyDollarFallback(num);
        }

        String spec = segments[1].trim();
        String lowerSpec = spec.toLowerCase();

        // :currency:auto[=SourceField] → resolve the ISO from the record at merge time
        if (lowerSpec == 'auto' || lowerSpec.startsWith('auto=')) {
            String sourceField = lowerSpec == 'auto' ? null : spec.substring(spec.indexOf('=') + 1).trim();
            String autoIso = resolveCurrencyIso(data, sourceField);
            // Missing / unknown ISO → safe $ fallback (never emit raw ISO text)
            if (autoIso == null || !CURRENCY_SYMBOLS.containsKey(autoIso)) {
                return formatCurrencyDollarFallback(num);
            }
            String autoLocale = segments.size() >= 3 ? segments[2].trim() : UserInfo.getLocale();
            return formatCurrencyWithIso(num, autoIso, autoLocale);
        }

        // :currency:ISO or :currency:ISO:locale
        String iso = spec.toUpperCase();
        String locale = segments.size() >= 3 ? segments[2].trim() : null;
        return formatCurrencyWithIso(num, iso, locale);
    }

    /** Backward-compat bare-:currency output: hardcoded $ with US separators. */
    private static String formatCurrencyDollarFallback(Decimal num) {
        return '$' + formatNumberLocale(num.setScale(2, RoundingMode.HALF_UP), ',', '.');
    }

    /** Formats `num` with the symbol for `iso` and the separators/placement for `locale`. */
    private static String formatCurrencyWithIso(Decimal num, String iso, String locale) {
        // Resolve symbol
        String symbol = CURRENCY_SYMBOLS.containsKey(iso) ? CURRENCY_SYMBOLS.get(iso) : iso + ' ';

        // Determine decimal places (0 for JPY, KRW, etc.)
        Integer scale = ZERO_DECIMAL_CURRENCIES.contains(iso) ? 0 : 2;
        Decimal scaled = num.setScale(scale, RoundingMode.HALF_UP);

        // Determine separators and placement from locale
        String groupSep = getLocaleGroupSep(locale);
        String decSep = getLocaleDecSep(locale);
        Boolean symbolAfter = locale != null && isCurrencyAfter(locale);

        String formatted = formatNumberLocale(scaled, groupSep, decSep);

        if (symbolAfter) {
            return formatted + ' ' + symbol.trim();
        }
        return symbol + formatted;
    }

    /**
     * Reads an ISO 4217 currency code from the record `data` map. `sourceField`
     * defaults to the standard `CurrencyIsoCode` when null/blank. Lookup is
     * case-insensitive (SOQL select-list casing isn't guaranteed). Returns the
     * trimmed, upper-cased value, or null when absent/blank.
     */
    private static String resolveCurrencyIso(Map<String, Object> data, String sourceField) {
        if (data == null) {
            return null;
        }
        String target = String.isBlank(sourceField) ? 'CurrencyIsoCode' : sourceField.trim();
        for (String k : data.keySet()) {
            if (k.equalsIgnoreCase(target)) {
                Object v = data.get(k);
                String iso = v == null ? null : String.valueOf(v).trim();
                return String.isBlank(iso) ? null : iso.toUpperCase();
            }
        }
        return null;
    }

    /** {Rate:percent} | {Rate:percent:de_DE} */
    private static String formatPercent(Decimal num, List<String> segments) {
        // Bare :percent → backward compat
        if (segments.size() == 1) {
            return num.stripTrailingZeros().toPlainString() + '%';
        }

        // :percent:locale
        String locale = segments[1].trim();
        String decSep = getLocaleDecSep(locale);
        String raw = num.stripTrailingZeros().toPlainString();
        if (decSep != '.') {
            raw = raw.replace('.', decSep);
        }
        return raw + '%';
    }

    /** {Qty:number} | {Qty:number:de_DE} */
    private static String formatPlainNumber(Decimal num, List<String> segments) {
        // Bare :number → backward compat: US commas, no decimals
        if (segments.size() == 1) {
            return formatNumberLocale(num.setScale(0, RoundingMode.HALF_UP), ',', '.');
        }

        // :number:locale
        String locale = segments[1].trim();
        return formatNumberLocale(
            num.setScale(0, RoundingMode.HALF_UP),
            getLocaleGroupSep(locale),
            getLocaleDecSep(locale)
        );
    }

    /** Legacy helper — kept for backward compat with any external callers. */
    private static String formatWithCommas(Decimal num) {
        return formatNumberLocale(num, ',', '.');
    }

    private static Boolean isAggregateTag(String tagContent) {
        Integer colonIdx = tagContent.indexOf(':');
        if (colonIdx <= 0) {
            return false;
        }
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        return AGGREGATE_FUNCTIONS.contains(fn);
    }

    /**
     * Throws HeapPressureException if the current Apex heap usage is past the
     * configured ratio (default 75% of the limit). Called from processXml's loop
     * expansion every HEAP_CHECK_EVERY_N_ITERS iterations — lets long child-loop
     * expansions bail early instead of failing with an untyped heap OOM, so the
     * controller can signal the runner LWC to auto-fallback to the giant path.
     */
    @TestVisible
    private static void checkHeapPressure(String relationshipName) {
        Integer heap = Limits.getHeapSize();
        Integer heapLimit = Limits.getLimitHeapSize();
        Boolean overThreshold =
            forceHeapPressureForTest || (heapLimit > 0 && heap >= (Integer) (heapLimit * HEAP_PRESSURE_RATIO));
        if (overThreshold) {
            HeapPressureException e = new HeapPressureException(
                'Heap pressure during sync merge (heap=' +
                    heap +
                    ' of ' +
                    heapLimit +
                    ') — ' +
                    'switching to giant-query path for relationship: ' +
                    relationshipName
            );
            e.relationshipName = relationshipName;
            throw e;
        }
    }

    /**
     * Public helper — applies the same numeric-format logic used by in-memory
     * aggregates to a pre-computed Decimal (e.g. from a SOQL aggregate query).
     * Used by DocGenGiantQueryAssembler to resolve grand-total tags.
     */
    public static String formatAggregateValue(Decimal value, String fmt) {
        return formatAggregateValue(value, fmt, null);
    }

    /**
     * Overload accepting an explicit currency ISO code for {…:currency:auto[=Field]}
     * grand-total tags on the giant-query path, where the parent record's field map
     * isn't otherwise in scope. `autoIso` is exposed to the formatter as a synthetic
     * one-key data map ({CurrencyIsoCode: autoIso}); null falls back to legacy behavior.
     */
    public static String formatAggregateValue(Decimal value, String fmt, String autoIso) {
        if (value == null) {
            return '0';
        }
        if (String.isNotBlank(fmt) && isNumericFormat(fmt)) {
            if (autoIso == null) {
                return formatNumber(value, fmt, null);
            }
            // The assembler already resolved the ISO from the parent's source field, so
            // collapse `currency:auto=Field` → `currency:auto` and feed the ISO through a
            // synthetic one-key map keyed by the default CurrencyIsoCode source.
            return formatNumber(
                value,
                collapseAutoSourceField(fmt),
                new Map<String, Object>{ 'CurrencyIsoCode' => autoIso }
            );
        }
        return String.valueOf(value);
    }

    /** currency:auto=Field[:locale] → currency:auto[:locale] (other formats unchanged). */
    private static String collapseAutoSourceField(String fmt) {
        List<String> segs = fmt.split(':');
        if (segs.size() >= 2 && segs[1].trim().toLowerCase().startsWith('auto=')) {
            segs[1] = 'auto';
        }
        return String.join(segs, ':');
    }

    /**
     * Resolves an aggregate tag like {SUM:QuoteLineItems.TotalPrice}.
     * Walks the data map to find the child list, extracts field values, computes.
     */
    private static String resolveAggregate(String tagContent, Map<String, Object> data) {
        Integer colonIdx = tagContent.indexOf(':');
        String fn = tagContent.substring(0, colonIdx).trim().toUpperCase();
        String path = tagContent.substring(colonIdx + 1).trim();

        // Strip optional format specifier: "List.Field:currency" → path="List.Field", fmt="currency"
        String numberFormat = null;
        Integer dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            // Check for format specifier after the field name: "List.Field:format"
            String afterDot = path.substring(dotIdx + 1);
            Integer fmtColon = afterDot.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = afterDot.substring(fmtColon + 1).trim();
                path = path.substring(0, dotIdx + 1 + fmtColon);
            }
        } else {
            // COUNT:List:format — format on a no-field aggregate
            Integer fmtColon = path.indexOf(':');
            if (fmtColon > 0) {
                numberFormat = path.substring(fmtColon + 1).trim();
                path = path.substring(0, fmtColon);
            }
        }

        // Split path into list name and optional field: "QuoteLineItems.TotalPrice" → ["QuoteLineItems", "TotalPrice"]
        String listName;
        String fieldName = null;
        dotIdx = path.indexOf('.');
        if (dotIdx > 0) {
            listName = path.substring(0, dotIdx);
            fieldName = path.substring(dotIdx + 1);
        } else {
            listName = path;
        }

        // COUNT doesn't require a field
        if (fn == 'COUNT' && fieldName == null) {
            List<Object> records = getChildRecords(data, listName);
            Integer countNum;
            if (records != null) {
                countNum = records.size();
            } else {
                // Relationship not pre-loaded — try SOQL COUNT() fallback (mirrors
                // ChartBucket's aggregation pattern so {COUNT:Rel} works when the
                // template intentionally omits Rel from Query_Config__c to let a
                // chart aggregate it server-side without heap pressure).
                Integer fallbackCount = DocGenChartBucketResolver.tryCountFallback(data, listName);
                countNum = fallbackCount >= 0 ? fallbackCount : 0;
            }
            String countResult = String.valueOf(countNum);
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat, data);
            }
            return countResult;
        }

        if (fieldName == null) {
            return null;
        }

        // Get child records and extract numeric values
        List<Object> records = getChildRecords(data, listName);
        if (records == null || records.isEmpty()) {
            return '0';
        }

        List<Decimal> values = new List<Decimal>();
        // Currency ISO of each contributing row, index-aligned with `values`. Only
        // populated for currency-formatted aggregates in multi-currency orgs — see
        // applyCurrencySemantics below.
        List<String> rowIsos = new List<String>();
        Boolean trackCurrency = DocGenCurrency.isCurrencyFormat(numberFormat) && DocGenCurrency.isMultiCurrency();
        String isoSourceField = trackCurrency ? currencyIsoSourceField(numberFormat) : null;

        for (Object item : records) {
            if (item instanceof Map<String, Object>) {
                Map<String, Object> row = (Map<String, Object>) item;
                Object fieldVal = resolveValue(row, fieldName);
                if (fieldVal != null) {
                    try {
                        values.add(Decimal.valueOf(String.valueOf(fieldVal)));
                        if (trackCurrency) {
                            rowIsos.add(DocGenCurrency.isoOfRow(row, isoSourceField));
                        }
                    } catch (Exception e) {
                        // Intentionally swallowed — non-numeric value, skip
                        String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                    }
                }
            }
        }

        // Reject (or convert) mixed-currency row sets BEFORE aggregating — summing across
        // currencies and stamping one symbol on the result is silently wrong output.
        if (trackCurrency) {
            values = applyCurrencySemantics(values, rowIsos, numberFormat, tagContent, data);
        }

        if (values.isEmpty()) {
            return '0';
        }

        Decimal result;
        if (fn == 'SUM') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
        } else if (fn == 'AVG') {
            result = 0;
            for (Decimal v : values) {
                result += v;
            }
            result = result.divide(values.size(), 2, RoundingMode.HALF_UP);
        } else if (fn == 'MIN') {
            result = values[0];
            for (Decimal v : values) {
                if (v < result) {
                    result = v;
                }
            }
        } else if (fn == 'MAX') {
            result = values[0];
            for (Decimal v : values) {
                if (v > result) {
                    result = v;
                }
            }
        } else if (fn == 'COUNT') {
            String countResult = String.valueOf(values.size());
            if (numberFormat != null && isNumericFormat(numberFormat)) {
                return formatNumber(Decimal.valueOf(countResult), numberFormat, data);
            }
            return countResult;
        } else {
            return null;
        }

        // Apply format specifier if provided, otherwise strip trailing zeros.
        // `:convert` is an aggregation-time instruction, already applied above — strip it
        // so the formatter sees the plain `currency:ISO[:locale]` grammar it understands.
        if (numberFormat != null && isNumericFormat(numberFormat)) {
            return formatNumber(result, DocGenCurrency.stripConvertSegment(numberFormat), data);
        }
        return result.stripTrailingZeros().toPlainString();
    }

    /**
     * The record field an aggregate's currency codes should be read from. Mirrors the
     * formatter's `{…:currency:auto=Field__c}` grammar so a template that names a custom
     * currency field for formatting uses that same field for the mixed-currency guard.
     * Null → the standard `CurrencyIsoCode`.
     */
    private static String currencyIsoSourceField(String fmt) {
        if (String.isBlank(fmt)) {
            return null;
        }
        List<String> segs = fmt.trim().split(':');
        if (segs.size() < 2) {
            return null;
        }
        String spec = segs[1].trim();
        return spec.toLowerCase().startsWith('auto=') ? spec.substring(spec.indexOf('=') + 1).trim() : null;
    }

    /**
     * Applies currency semantics to an aggregate's contributing values.
     *
     * With `:convert`, every row is converted from its own currency into the tag's target
     * currency, so the subsequent SUM/AVG/MIN/MAX operates on comparable numbers. Without
     * it, a row set spanning more than one currency throws rather than producing a total
     * that is arithmetically meaningless but looks authoritative.
     *
     * Rows with no ISO code (the field isn't in the Query Config) are left alone — we
     * can't know what they are, and guessing is how the original bug happened.
     */
    private static List<Decimal> applyCurrencySemantics(
        List<Decimal> values,
        List<String> rowIsos,
        String fmt,
        String tagContent,
        Map<String, Object> data
    ) {
        Set<String> distinct = new Set<String>();
        for (String iso : rowIsos) {
            if (String.isNotBlank(iso)) {
                distinct.add(iso);
            }
        }
        if (distinct.size() <= 1) {
            return values;
        }

        if (!DocGenCurrency.wantsConversion(fmt)) {
            // Names the tag and the offending codes — see DocGenCurrency.assertSingleCurrency.
            DocGenCurrency.assertSingleCurrency(distinct, tagContent);
        }

        // Target currency: the explicitly named ISO, or for the `auto` forms the code the
        // formatter will ultimately stamp on the result — read off the parent record.
        String targetIso = DocGenCurrency.explicitTargetIso(fmt);
        if (String.isBlank(targetIso)) {
            targetIso = resolveCurrencyIso(data, currencyIsoSourceField(fmt));
        }
        if (String.isBlank(targetIso)) {
            throw new DocGenException(
                'Cannot convert {' +
                    tagContent +
                    '}: no target currency. Name one explicitly (e.g. currency:EUR:convert) ' +
                    'or ensure the parent record has a currency field for the "auto" form.'
            );
        }

        List<Decimal> converted = new List<Decimal>();
        for (Integer i = 0; i < values.size(); i++) {
            String fromIso = i < rowIsos.size() ? rowIsos[i] : null;
            converted.add(String.isBlank(fromIso) ? values[i] : DocGenCurrency.convert(values[i], fromIso, targetIso));
        }
        return converted;
    }

    /** Extracts the child record list from the data map. */
    private static List<Object> getChildRecords(Map<String, Object> data, String listName) {
        Object val = resolveValue(data, listName);
        if (val instanceof Map<String, Object>) {
            Map<String, Object> mapVal = (Map<String, Object>) val;
            if (mapVal.containsKey('records') && mapVal.get('records') instanceof List<Object>) {
                return (List<Object>) mapVal.get('records');
            }
        } else if (val instanceof List<Object>) {
            return (List<Object>) val;
        }
        return null;
    }

    /**
     * Converts rich text HTML to DOCX XML without run context (no inheritance).
     */
    private static String convertRichTextToDocxXml(String html) {
        return convertRichTextToDocxXml(html, '');
    }

    /**
     * Converts rich text HTML to DOCX XML (w:p, w:r, w:t elements).
     * Preserves text, basic formatting (bold/italic/underline), multiple images, and paragraphs.
     * Returns DOCX XML that closes the current run/paragraph context and reopens it after.
     * When tokenRPr carries the merge tag run's <w:rPr> block, every emitted run
     * inherits it so values render in the token's formatting (#375, #32).
     */
    private static String convertRichTextToDocxXml(String html, String tokenRPr) {
        // Normalize: named entities first, then numeric character references.
        // The Lightning RTE stores apostrophes as &#39;, smart quotes as &#8217;
        // /&#8220;/&#8221;, em/en dashes as &#8212;/&#8211;, accented chars as
        // &#xE9; etc. Without decoding they render literally in DOCX (issue #51).
        // The renderer's decodeNumericEntities (v1.81.0) already handles every
        // numeric form for the PDF/HTML path; routing through it brings DOCX
        // to parity.
        html = html.replace('&nbsp;', ' ')
            .replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"');
        html = DocGenHtmlRenderer.decodeNumericEntities(html);

        // Split into paragraphs by <p>, <div>, and <br> tags
        // First, normalize paragraph boundaries: replace </p><p>, </div><div>, <br>, <br/> with a delimiter
        String delim = '\n__PARA__\n';
        String normalized = html;
        normalized = normalized.replaceAll('(?i)</p>\\s*<p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</div>\\s*<div[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)<br\\s*/?>', delim);
        normalized = normalized.replaceAll('(?i)</?p[^>]*>', delim);
        normalized = normalized.replaceAll('(?i)</?div[^>]*>', delim);

        List<String> paragraphs = normalized.split(delim);

        // Build DOCX XML: close current context, emit paragraphs, reopen context
        String result = '</w:t></w:r>'; // close current run
        String rPrXml = String.isNotBlank(tokenRPr) ? tokenRPr : '';

        Boolean firstPara = true;
        for (String para : paragraphs) {
            String trimmed = para.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }

            if (!firstPara) {
                result += '</w:p><w:p>'; // new paragraph
            } else {
                // Continue in the same paragraph as the merge tag
                firstPara = false;
            }

            // Process inline content within this paragraph
            result += processInlineHtml(trimmed, rPrXml);
        }

        // If we never output anything, just return empty text
        if (firstPara) {
            return '';
        }

        // Reopen run/text context for any content after the merge tag
        result += '<w:r>' + rPrXml + '<w:t xml:space="preserve">';
        return result;
    }

    /**
     * Processes inline HTML elements within a paragraph into DOCX w:r elements.
     * Handles <b>, <i>, <u>, <strong>, <em>, <span>, <img>, and plain text.
     */
    private static String processInlineHtml(String html, String tokenRPr) {
        String result = '';
        Integer cursor = 0;

        // Track formatting state
        Boolean isBold = false;
        Boolean isItalic = false;
        Boolean isUnderline = false;

        // Track list nesting: 'ul' or 'ol' per level. Counter parallel for ordered numbering.
        List<String> listStack = new List<String>();
        List<Integer> listCounters = new List<Integer>();

        while (cursor < html.length()) {
            Integer nextTag = html.indexOf('<', cursor);

            if (nextTag == -1) {
                // Remaining plain text
                String text = html.substring(cursor).trim();
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), tokenRPr, isBold, isItalic, isUnderline);
                }
                break;
            }

            // Text before the tag
            if (nextTag > cursor) {
                String text = html.substring(cursor, nextTag);
                if (String.isNotBlank(text)) {
                    result += buildRun(stripTags(text), tokenRPr, isBold, isItalic, isUnderline);
                }
            }

            // Find end of tag
            Integer tagEnd = html.indexOf('>', nextTag);
            if (tagEnd == -1) {
                break;
            }
            tagEnd++;

            String tag = html.substring(nextTag, tagEnd).toLowerCase();

            // Handle formatting tags
            if (tag.startsWith('<b>') || tag.startsWith('<b ') || tag.startsWith('<strong')) {
                isBold = true;
            } else if (tag.startsWith('</b>') || tag.startsWith('</strong')) {
                isBold = false;
            } else if (tag.startsWith('<i>') || tag.startsWith('<i ') || tag.startsWith('<em')) {
                isItalic = true;
            } else if (tag.startsWith('</i>') || tag.startsWith('</em')) {
                isItalic = false;
            } else if (tag.startsWith('<u>') || tag.startsWith('<u ')) {
                isUnderline = true;
            } else if (tag.startsWith('</u>')) {
                isUnderline = false;
            } else if (tag.startsWith('<a ') || tag.startsWith('<a>')) {
                // Extract href from anchor tag
                String anchorTag = html.substring(nextTag, tagEnd);
                String href = extractAttribute(anchorTag, 'href');
                // Find the closing </a> and get inner text
                Integer closeA = html.indexOfIgnoreCase('</a>', tagEnd);
                if (closeA != -1) {
                    String linkText = html.substring(tagEnd, closeA);
                    linkText = linkText.replaceAll('<[^>]+>', '').trim();
                    if (String.isBlank(linkText)) {
                        linkText = href;
                    }
                    if (String.isNotBlank(href)) {
                        // Build w:hyperlink with direct URL attribute for PDF rendering
                        result +=
                            '<w:hyperlink w:docgen-url="' +
                            href.escapeXml() +
                            '">' +
                            '<w:r><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>' +
                            '<w:t xml:space="preserve">' +
                            linkText.escapeXml() +
                            '</w:t></w:r>' +
                            '</w:hyperlink>';
                    } else {
                        result += buildRun(linkText, tokenRPr, isBold, isItalic, true);
                    }
                    cursor = closeA + 4; // skip past </a>
                    continue;
                }
            } else if (tag.startsWith('<img')) {
                // Extract image from <img> tag
                String imgTag = html.substring(nextTag, tagEnd);
                String imgResult = processRichTextImage(imgTag);
                if (imgResult != null) {
                    result += imgResult;
                }
            } else if (tag.startsWith('<ul>') || tag.startsWith('<ul ')) {
                listStack.add('ul');
                listCounters.add(0);
            } else if (tag.startsWith('<ol>') || tag.startsWith('<ol ')) {
                listStack.add('ol');
                listCounters.add(0);
            } else if (tag.startsWith('</ul>') || tag.startsWith('</ol>')) {
                if (!listStack.isEmpty()) {
                    listStack.remove(listStack.size() - 1);
                    listCounters.remove(listCounters.size() - 1);
                }
            } else if (tag.startsWith('<li>') || tag.startsWith('<li ')) {
                // Close current paragraph and open a new one prefixed with a bullet/number marker.
                String marker;
                Integer depth = listStack.isEmpty() ? 1 : listStack.size();
                String indent = '';
                for (Integer i = 1; i < depth; i++) {
                    indent += '    ';
                }
                if (!listStack.isEmpty() && listStack[listStack.size() - 1] == 'ol') {
                    Integer count = listCounters[listCounters.size() - 1] + 1;
                    listCounters[listCounters.size() - 1] = count;
                    marker = indent + count + '. ';
                } else {
                    marker = indent + '• ';
                }
                result += '</w:p><w:p><w:r>' + tokenRPr + '<w:t xml:space="preserve">' + marker + '</w:t></w:r>';
            } else if (tag.startsWith('</li>')) {
                // No-op; next <li> or list close handles boundaries.
            }
            // Closing </a> tags and other tags (spans, etc.) are skipped — just process their text content

            cursor = tagEnd;
        }

        return result;
    }

    /**
     * Builds a DOCX w:r (run) element with optional formatting.
     * When tokenRPr carries the merge tag run's <w:rPr> block, its properties
     * are reused so the run inherits the token's formatting; HTML-level
     * bold/italic/underline are added only when not already present (#375).
     */
    private static String buildRun(String text, Boolean bold, Boolean italic, Boolean underline) {
        return buildRun(text, '', bold, italic, underline);
    }

    private static String buildRun(
        String text,
        String tokenRPr,
        Boolean bold,
        Boolean italic,
        Boolean underline
    ) {
        if (String.isBlank(text)) {
            return '';
        }
        String rPrInner = '';
        if (String.isNotBlank(tokenRPr)) {
            Integer openEnd = tokenRPr.indexOf('>');
            Integer closeStart = tokenRPr.lastIndexOf('</w:rPr>');
            if (openEnd != -1 && closeStart > openEnd) {
                rPrInner = tokenRPr.substring(openEnd + 1, closeStart);
            }
        }
        if (bold && !rPrInner.contains('<w:b')) {
            rPrInner += '<w:b/>';
        }
        if (italic && !rPrInner.contains('<w:i')) {
            rPrInner += '<w:i/>';
        }
        if (underline && !rPrInner.contains('<w:u')) {
            rPrInner += '<w:u w:val="single"/>';
        }
        String rPr = String.isBlank(rPrInner) ? '' : '<w:rPr>' + rPrInner + '</w:rPr>';
        return '<w:r>' + rPr + '<w:t xml:space="preserve">' + text.escapeXml() + '</w:t></w:r>';
    }

    /**
     * Strips any remaining HTML tags from text content.
     */
    private static String stripTags(String text) {
        return text.replaceAll('<[^>]+>', '');
    }

    /**
     * Returns true if a String is null/blank or contains only HTML markup that
     * renders as nothing (e.g. Salesforce Lightning rich text "empty" values
     * stored as <p><br></p> or <div>&nbsp;</div>). Used by section-tag truthy/
     * inverse checks so {#Field} and {^Field} agree on what "empty" means and
     * both treat visually-empty rich text as falsy. Issue #48.
     */
    @TestVisible
    private static Boolean isVisuallyBlankRichText(String s) {
        if (String.isBlank(s)) {
            return true;
        }
        String stripped = s.replaceAll('(?i)<[^>]+>', '').replace('&nbsp;', '').replace('&#160;', '').trim();
        return String.isBlank(stripped);
    }

    /**
     * Extracts an attribute value from an HTML tag string.
     * e.g. extractAttribute('<a href="https://example.com">', 'href') => 'https://example.com'
     */
    private static String extractAttribute(String tag, String attrName) {
        Integer attrIdx = tag.indexOfIgnoreCase(attrName + '=');
        if (attrIdx == -1) {
            return null;
        }
        Integer valStart = attrIdx + attrName.length() + 1;
        if (valStart >= tag.length()) {
            return null;
        }
        String quote = tag.substring(valStart, valStart + 1);
        if (quote == '"' || quote == '\'') {
            valStart++;
            Integer valEnd = tag.indexOf(quote, valStart);
            if (valEnd != -1) {
                return tag.substring(valStart, valEnd).replace('&amp;', '&');
            }
        }
        // Unquoted attribute — read until space or >
        Integer valEnd = tag.indexOf(' ', valStart);
        Integer tagEnd = tag.indexOf('>', valStart);
        if (valEnd == -1 || (tagEnd != -1 && tagEnd < valEnd)) {
            valEnd = tagEnd;
        }
        if (valEnd != -1) {
            return tag.substring(valStart, valEnd).replace('&amp;', '&');
        }
        return null;
    }

    /**
     * Processes an <img> tag from rich text, fetches the image, and returns DrawingML XML.
     */
    private static String processRichTextImage(String imgTag) {
        // Extract src attribute
        Integer srcIdx = imgTag.indexOfIgnoreCase('src=');
        if (srcIdx == -1) {
            return null;
        }
        srcIdx += 4;
        while (srcIdx < imgTag.length() && imgTag.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }
        String quoteChar = imgTag.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++;
        Integer srcEnd = imgTag.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }
        String src = imgTag.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Extract optional width/height. Two storage forms exist in rich text HTML:
        //   1. width="200" height="150" attributes — set by older editors
        //   2. style="width: 200px; height: 150px;" — set by Lightning Rich Text
        //      Area when the user drags to resize (which is the common case).
        // Try attribute form first, then fall back to style form so drag-resized
        // images come through at the correct dimensions instead of the default.
        Integer widthPx = null;
        Integer heightPx = null;
        Integer wIdx = imgTag.indexOfIgnoreCase('width=');
        if (wIdx != -1) {
            String wVal = extractHtmlAttrValue(imgTag, wIdx + 6);
            if (wVal != null && wVal.replaceAll('[^0-9]', '').isNumeric()) {
                widthPx = Integer.valueOf(wVal.replaceAll('[^0-9]', ''));
            }
        }
        Integer hIdx = imgTag.indexOfIgnoreCase('height=');
        if (hIdx != -1) {
            String hVal = extractHtmlAttrValue(imgTag, hIdx + 7);
            if (hVal != null && hVal.replaceAll('[^0-9]', '').isNumeric()) {
                heightPx = Integer.valueOf(hVal.replaceAll('[^0-9]', ''));
            }
        }
        // Style fallback: parse `width:Npx` and `height:Npx` from the style attribute.
        if (widthPx == null || heightPx == null) {
            Integer styleIdx = imgTag.indexOfIgnoreCase('style=');
            if (styleIdx != -1) {
                String styleVal = extractHtmlAttrValue(imgTag, styleIdx + 6);
                if (String.isNotBlank(styleVal)) {
                    if (widthPx == null) {
                        widthPx = parseStylePx(styleVal, 'width');
                    }
                    if (heightPx == null) {
                        heightPx = parseStylePx(styleVal, 'height');
                    }
                }
            }
        }

        // Resolve image: decode data URIs to blobs, store Salesforce URLs for PDF rendering.
        // No HTTP callouts or session IDs — AppExchange safe.
        Blob imageBlob = null;
        String ext = 'png';
        try {
            if (src.startsWith('data:image/')) {
                // Data URI — decode to blob (for DOCX embedding)
                String base64Part = src.substringAfter(',');
                if (src.containsIgnoreCase('jpeg') || src.containsIgnoreCase('jpg')) {
                    ext = 'jpeg';
                }
                imageBlob = EncodingUtil.base64Decode(base64Part);
            }
            // For Salesforce URLs (servlet, sfc, https), store URL for PDF rendering.
            // Blob.toPdf() resolves Salesforce URLs natively via the VF engine.
            if (src.containsIgnoreCase('.jpg') || src.containsIgnoreCase('.jpeg')) {
                ext = 'jpeg';
            }
        } catch (Exception e) {
            // Intentionally swallowed — image source parsing failed, fall through to URL handling
            String noop = e.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
        }

        // Rich Text Field images come back as /servlet/rtaImage?...&refid=<id>.
        // The refid varies: ContentDocument ID (069...) for File-based RTAs, or
        // ContentVersion ID (068...) for some legacy/embedded forms. Try both.
        // Then rewrite src to the /sfc/servlet.shepherd/version/download/<cvId> form
        // that the existing image pipeline handles end-to-end. No HTTP callouts.
        if (
            imageBlob == null &&
            src != null &&
            src.containsIgnoreCase('rtaImage') &&
            src.containsIgnoreCase('refid=')
        ) {
            Integer refStart = src.toLowerCase().indexOf('refid=') + 6;
            Integer refEnd = src.indexOf('&', refStart);
            if (refEnd == -1) {
                refEnd = src.length();
            }
            String refid = src.substring(refStart, refEnd);
            if (String.isNotBlank(refid) && refid.length() >= 15) {
                Id resolvedId = null;
                try {
                    resolvedId = (Id) refid;
                } catch (Exception parseE) {
                    String noop = parseE.getMessage(); // NOPMD UnusedLocalVariable
                }
                if (resolvedId != null) {
                    String idPrefix = ((String) resolvedId).substring(0, 3);
                    // Server-side ZIP paths (preview generate, native PPTX) need the
                    // actual bytes for assembleZip(). Client-side parts (DOCX download/
                    // save) sets currentOutputFormat='PDF' as a heap-saving hint —
                    // we then skip VersionData and let the client fetch it via
                    // getContentVersionBase64. Same pattern as buildImageXml's
                    // {%ImageField} CV path (CLAUDE.md).
                    Boolean loadBytes = (currentOutputFormat != 'PDF');
                    List<ContentVersion> rtaCvs = new List<ContentVersion>();
                    try {
                        if (idPrefix == '068') {
                            // refid is already a ContentVersion ID
                            rtaCvs = loadBytes
                                ? [
                                      SELECT Id, FileExtension, VersionData
                                      FROM ContentVersion
                                      WHERE Id = :resolvedId
                                      WITH USER_MODE
                                      LIMIT 1
                                  ]
                                : [
                                      SELECT Id, FileExtension
                                      FROM ContentVersion
                                      WHERE Id = :resolvedId
                                      WITH USER_MODE
                                      LIMIT 1
                                  ];
                        } else {
                            // Treat as ContentDocument ID (069 prefix)
                            rtaCvs = loadBytes
                                ? [
                                      SELECT Id, FileExtension, VersionData
                                      FROM ContentVersion
                                      WHERE ContentDocumentId = :resolvedId AND IsLatest = TRUE
                                      WITH USER_MODE
                                      LIMIT 1
                                  ]
                                : [
                                      SELECT Id, FileExtension
                                      FROM ContentVersion
                                      WHERE ContentDocumentId = :resolvedId AND IsLatest = TRUE
                                      WITH USER_MODE
                                      LIMIT 1
                                  ];
                            // Some refid prefixes (like 0EM or 005 — embedded inline images)
                            // aren't ContentDocuments. If first lookup empty, try Id directly.
                            if (rtaCvs.isEmpty()) {
                                rtaCvs = loadBytes
                                    ? [
                                          SELECT Id, FileExtension, VersionData
                                          FROM ContentVersion
                                          WHERE Id = :resolvedId
                                          WITH USER_MODE
                                          LIMIT 1
                                      ]
                                    : [
                                          SELECT Id, FileExtension
                                          FROM ContentVersion
                                          WHERE Id = :resolvedId
                                          WITH USER_MODE
                                          LIMIT 1
                                      ];
                            }
                        }
                    } catch (Exception qE) {
                        String noop = qE.getMessage(); // NOPMD UnusedLocalVariable
                    }
                    if (!rtaCvs.isEmpty()) {
                        src = '/sfc/servlet.shepherd/version/download/' + rtaCvs[0].Id;
                        if (String.isNotBlank(rtaCvs[0].FileExtension)) {
                            String fext = rtaCvs[0].FileExtension.toLowerCase();
                            if (fext == 'jpg' || fext == 'jpeg') {
                                ext = 'jpeg';
                            } else if (fext == 'gif' || fext == 'png' || fext == 'bmp') {
                                ext = fext;
                            }
                        }
                        // Server-side ZIP needs the binary for assembleZip()
                        if (loadBytes && rtaCvs[0].VersionData != null) {
                            imageBlob = rtaCvs[0].VersionData;
                        }
                    }
                    // 0EM (Lightning ContentReference) inline rich text images keep
                    // their original rtaImage URL as src. PDF rendering uses it via
                    // Blob.toPdf's internal resolver. DOCX assembly detects the URL
                    // pattern client-side and routes through PDF-extract path
                    // (DocGenController.renderImageAsPdfBase64).
                }
            }
        }

        // Register image — store blob for DOCX and URL for PDF rendering.
        imageCounter++;
        String relId = 'rIdImg' + imageCounter;
        String fileName = 'docgen_image_' + imageCounter + '.' + ext;

        if (imageBlob != null) {
            Map<String, Object> imgData = new Map<String, Object>{
                'relId' => relId,
                'fileName' => fileName,
                'blob' => imageBlob
            };
            // Store source URL for PDF rendering (Blob.toPdf fetches images via URL)
            if (!src.startsWith('data:')) {
                imgData.put('url', src);
            }
            pendingImages.add(imgData);
        } else if (String.isNotBlank(src) && !src.startsWith('data:')) {
            pendingImages.add(new Map<String, Object>{ 'relId' => relId, 'fileName' => fileName, 'url' => src });
        } else {
            return null; // Can't resolve image at all
        }

        // Build DrawingML. processDrawing in the PDF renderer DEFAULTS to using
        // exact wp:extent dimensions (Word's authoritative size for both
        // template-embedded images and rich text with explicit user sizing).
        // When NEITHER width NOR height was found in the rich text (image
        // pasted with no size info), we mark the drawing with DOCGEN_AUTOSIZE
        // so processDrawing flips to max-width + width:auto — preserves the
        // image's natural aspect rather than stretching to the 4×3 default.
        Boolean noSizeInfo = (widthPx == null && heightPx == null);
        Integer widthEmu = (widthPx != null) ? (widthPx * 9525) : (288 * 12700);
        Integer heightEmu = (heightPx != null) ? (heightPx * 9525) : (216 * 12700);
        String docPrAttrs = 'id="' + imageCounter + '" name="DocGenImage' + imageCounter + '"';
        if (noSizeInfo) {
            docPrAttrs += ' descr="DOCGEN_AUTOSIZE"';
        }

        return '<w:r><w:drawing>' +
            '<wp:inline distT="0" distB="0" distL="0" distR="0" ' +
            'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
            '<wp:extent cx="' +
            widthEmu +
            '" cy="' +
            heightEmu +
            '"/>' +
            '<wp:docPr ' +
            docPrAttrs +
            '/>' +
            '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
            '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
            '<pic:nvPicPr>' +
            '<pic:cNvPr id="' +
            imageCounter +
            '" name="DocGenImage' +
            imageCounter +
            '"/>' +
            '<pic:cNvPicPr/>' +
            '</pic:nvPicPr>' +
            '<pic:blipFill>' +
            '<a:blip r:embed="' +
            relId +
            '" ' +
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>' +
            '<a:stretch><a:fillRect/></a:stretch>' +
            '</pic:blipFill>' +
            '<pic:spPr>' +
            '<a:xfrm>' +
            '<a:off x="0" y="0"/>' +
            '<a:ext cx="' +
            widthEmu +
            '" cy="' +
            heightEmu +
            '"/>' +
            '</a:xfrm>' +
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
            '</pic:spPr>' +
            '</pic:pic>' +
            '</a:graphicData>' +
            '</a:graphic>' +
            '</wp:inline>' +
            '</w:drawing></w:r>';
    }

    /**
     * Rich-text → HTML pass-through for HTML templates (Type__c = 'HTML').
     * The DOCX path (convertRichTextToDocxXml) emits DrawingML which Flying
     * Saucer can't parse, so HTML templates referencing a rich-text field
     * previously lost both text formatting and images entirely. Here the
     * rich-text HTML is already valid HTML — pass it through verbatim,
     * rewriting only `<img src="...rtaImage?...&refid=<id>">` URLs to the
     * relative `/sfc/servlet.shepherd/version/download/<cvId>` form that
     * Blob.toPdf can fetch. Data-URI images are dropped (Blob.toPdf rejects
     * them).
     */
    @TestVisible
    private static String convertRichTextToHtml(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String result = '';
        Integer cursor = 0;
        String lower = html.toLowerCase();
        while (cursor < html.length()) {
            Integer imgStart = lower.indexOf('<img', cursor);
            if (imgStart == -1) {
                result += html.substring(cursor);
                break;
            }
            Integer imgEnd = html.indexOf('>', imgStart);
            if (imgEnd == -1) {
                result += html.substring(cursor);
                break;
            }
            result += html.substring(cursor, imgStart);
            String imgTag = html.substring(imgStart, imgEnd + 1);
            String rewritten = rewriteRichTextImgForHtml(imgTag);
            if (rewritten != null) {
                result += rewritten;
            }
            cursor = imgEnd + 1;
        }
        return result;
    }

    /**
     * Returns the <img> tag with src rewritten for HTML-template output, or
     * empty string when the image can't be rendered (data URI, unresolvable).
     * Already-relative /sfc/ URLs and arbitrary http(s) URLs pass through
     * unchanged.
     */
    private static String rewriteRichTextImgForHtml(String imgTag) {
        Integer srcIdx = imgTag.indexOfIgnoreCase('src=');
        if (srcIdx == -1) {
            return imgTag;
        }
        Integer valStart = srcIdx + 4;
        while (valStart < imgTag.length() && imgTag.substring(valStart, valStart + 1) == ' ') {
            valStart++;
        }
        if (valStart >= imgTag.length()) {
            return imgTag;
        }
        String quote = imgTag.substring(valStart, valStart + 1);
        if (quote != '"' && quote != '\'') {
            return imgTag;
        }
        valStart++;
        Integer valEnd = imgTag.indexOf(quote, valStart);
        if (valEnd == -1) {
            return imgTag;
        }
        String src = imgTag.substring(valStart, valEnd).replace('&amp;', '&');

        if (src.startsWith('data:')) {
            return '';
        }
        if (src.toLowerCase().startsWith('/sfc/')) {
            return imgTag;
        }
        if (src.containsIgnoreCase('rtaImage') && src.containsIgnoreCase('refid=')) {
            Integer refStart = src.toLowerCase().indexOf('refid=') + 6;
            Integer refEnd = src.indexOf('&', refStart);
            if (refEnd == -1) {
                refEnd = src.length();
            }
            String refid = src.substring(refStart, refEnd);
            if (String.isNotBlank(refid) && refid.length() >= 15) {
                String resolvedUrl = resolveRtaRefidToShepherdUrl(refid);
                if (resolvedUrl != null) {
                    return imgTag.substring(0, valStart) + resolvedUrl + imgTag.substring(valEnd);
                }
            }
            // Refid couldn't be resolved (e.g. 0EM ContentReference for Lightning
            // inline images — not queryable as ContentVersion/ContentDocument).
            // Leave the absolute rtaImage URL; Blob.toPdf can fetch *.force.com
            // hosts from authenticated/Automated-Process context.
        }
        return imgTag;
    }

    /**
     * Resolves a Lightning rich-text rtaImage refid to a relative
     * `/sfc/servlet.shepherd/version/download/<cvId>` URL. Mirrors the
     * lookup in processRichTextImage (068 CV / 069 ContentDocument / 0EM
     * inline fallback) but returns only the URL — no blob, no relId
     * registration. Returns null when nothing resolves.
     */
    private static String resolveRtaRefidToShepherdUrl(String refid) {
        Id resolvedId = null;
        try {
            resolvedId = (Id) refid;
        } catch (Exception parseE) {
            String noop = parseE.getMessage(); // NOPMD UnusedLocalVariable
        }
        if (resolvedId == null) {
            return null;
        }
        String idPrefix = ((String) resolvedId).substring(0, 3);
        List<ContentVersion> rtaCvs = new List<ContentVersion>();
        try {
            if (idPrefix == '068') {
                rtaCvs = [SELECT Id FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1];
            } else {
                rtaCvs = [
                    SELECT Id
                    FROM ContentVersion
                    WHERE ContentDocumentId = :resolvedId AND IsLatest = TRUE
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (rtaCvs.isEmpty()) {
                    rtaCvs = [SELECT Id FROM ContentVersion WHERE Id = :resolvedId WITH USER_MODE LIMIT 1];
                }
            }
        } catch (Exception qE) {
            String noop = qE.getMessage(); // NOPMD UnusedLocalVariable
        }
        if (rtaCvs.isEmpty()) {
            return null;
        }
        return '/sfc/servlet.shepherd/version/download/' + rtaCvs[0].Id;
    }

    /**
     * Extracts an HTML attribute value starting at the given position (after 'attr=').
     */
    /**
     * Pulls a pixel value out of an inline style string for a given property.
     * Examples: parseStylePx('width: 200px; height: 150px', 'width') → 200.
     * Accepts 'px', 'pt' (converted to px @ 96/72), and bare numeric values.
     * Returns null if the property isn't present or value can't be parsed.
     */
    private static Integer parseStylePx(String styleVal, String propName) {
        if (String.isBlank(styleVal) || String.isBlank(propName)) {
            return null;
        }
        String lower = styleVal.toLowerCase();
        Integer pIdx = lower.indexOf(propName.toLowerCase() + ':');
        if (pIdx == -1) {
            return null;
        }
        Integer valStart = pIdx + propName.length() + 1;
        Integer valEnd = lower.indexOf(';', valStart);
        if (valEnd == -1) {
            valEnd = lower.length();
        }
        String raw = styleVal.substring(valStart, valEnd).trim();
        if (String.isBlank(raw)) {
            return null;
        }
        // Strip unit suffix and parse number
        Boolean isPt = raw.toLowerCase().endsWith('pt');
        String numStr = raw.replaceAll('[^0-9.]', '');
        if (String.isBlank(numStr)) {
            return null;
        }
        try {
            Decimal n = Decimal.valueOf(numStr);
            if (isPt) {
                n = n * 96 / 72;
            }
            return Math.round(n);
        } catch (Exception e) {
            return null;
        }
    }

    private static String extractHtmlAttrValue(String tag, Integer startAfterEquals) {
        Integer pos = startAfterEquals;
        while (pos < tag.length() && tag.substring(pos, pos + 1) == ' ') {
            pos++;
        }
        if (pos >= tag.length()) {
            return null;
        }
        String ch = tag.substring(pos, pos + 1);
        if (ch == '"' || ch == '\'') {
            Integer end2 = tag.indexOf(ch, pos + 1);
            return end2 != -1 ? tag.substring(pos + 1, end2) : null;
        }
        // Unquoted value
        Integer end2 = pos;
        while (end2 < tag.length() && tag.substring(end2, end2 + 1) != ' ' && tag.substring(end2, end2 + 1) != '>') {
            end2++;
        }
        return tag.substring(pos, end2);
    }

    private class ImageDimensionSpec {
        Boolean isMaxConstraint;
        Integer percentValue;
        Integer pixelValue;
    }

    private class ImageRenderSpec {
        String imageField;
        String fieldValue;
        String relationshipId;
        String fileName;
        String fileExtension;
        String sourceUrl;
        String contentVersionImageUrl;
        Blob imageBlobData;

        Integer widthPx;
        Integer heightPx;
        Integer widthPercent;
        Integer heightPercent;
        Integer maxWidthPx;
        Integer maxHeightPx;
        Integer maxWidthPercent;
        Integer maxHeightPercent;
    }

    private static String buildImageXml(String fieldValue) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.fieldValue = fieldValue;
        return buildImageXml(spec);
    }

    private static String buildImageXml(String fieldValue, Integer widthPx, Integer heightPx) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.fieldValue = fieldValue;
        spec.widthPx = widthPx;
        spec.heightPx = heightPx;
        return buildImageXml(spec);
    }

    /**
     * Routes an image-tag substitution to the appropriate template-type builder.
     * Word/HTML/PDF flow through buildImageXml (DrawingML or <img>); PowerPoint
     * emits a DGPIC marker that postProcessPowerPointSlides converts into a
     * <p:pic> shape; Excel currently strips the tag with a v2 TODO.
     */
    private static String dispatchImageXml(ImageRenderSpec spec) {
        if (currentTemplateType == 'PowerPoint') {
            return buildImageXmlForPowerPoint(spec);
        }
        if (currentTemplateType == 'Excel') {
            return buildImageXmlForExcel(spec);
        }
        return buildImageXml(spec);
    }

    private static String buildImageXml(ImageRenderSpec spec) {
        if (spec == null || String.isBlank(spec.fieldValue)) {
            return null;
        }

        String ext = 'png';

        try {
            // 1. Rich text HTML containing <img> tags
            if (spec.fieldValue.containsIgnoreCase('<img')) {
                spec.imageBlobData = extractImageFromHtml(spec.fieldValue);
            }
            // 2. Base64 data URI
            else if (spec.fieldValue.startsWith('data:image/')) {
                String base64Part = spec.fieldValue.substringAfter(',');
                if (spec.fieldValue.containsIgnoreCase('jpeg') || spec.fieldValue.containsIgnoreCase('jpg')) {
                    ext = 'jpeg';
                }
                spec.imageBlobData = EncodingUtil.base64Decode(base64Part);
            }
            // 3. Raw base64 (no data URI prefix)
            else if (
                spec.fieldValue.length() > 100 &&
                !spec.fieldValue.contains('/') &&
                !spec.fieldValue.contains(' ')
            ) {
                spec.imageBlobData = EncodingUtil.base64Decode(spec.fieldValue);
            }
            // 4. ContentVersion ID (starts with 068) — works for both DOCX (blob) and PDF (URL)
            else if (spec.fieldValue.startsWith('068') && spec.fieldValue.length() >= 15) {
                if (currentOutputFormat == 'PDF') {
                    // PDF path: only need the URL — Blob.toPdf() fetches images server-side.
                    // Skip loading the blob entirely to save heap.
                    List<ContentVersion> cvs = [
                        SELECT Id, FileExtension
                        FROM ContentVersion
                        WHERE Id = :spec.fieldValue
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!cvs.isEmpty()) {
                        if (cvs[0].FileExtension != null) {
                            ext = cvs[0].FileExtension.toLowerCase();
                        }
                        spec.contentVersionImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                } else {
                    // DOCX path: need the blob for ZIP embedding
                    List<ContentVersion> cvs = [
                        SELECT Id, VersionData, FileExtension
                        FROM ContentVersion
                        WHERE Id = :spec.fieldValue
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!cvs.isEmpty()) {
                        spec.imageBlobData = cvs[0].VersionData;
                        if (cvs[0].FileExtension != null) {
                            ext = cvs[0].FileExtension.toLowerCase();
                        }
                        spec.contentVersionImageUrl = '/sfc/servlet.shepherd/version/download/' + cvs[0].Id;
                    }
                }
            }
            // 5. Salesforce file URL containing refid (rich text image reference)
            else if (spec.fieldValue.containsIgnoreCase('refid=')) {
                String refId = spec.fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) {
                    refId = spec.fieldValue.substringAfterLast('refid=');
                }
                spec.imageBlobData = fetchSalesforceImage(refId);
            }
            // 6. Salesforce servlet/sfc URL
            else if (spec.fieldValue.containsIgnoreCase('/servlet/') || spec.fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = spec.fieldValue.substringAfterLast('/');
                if (docId.contains('?')) {
                    docId = docId.substringBefore('?');
                }
                spec.imageBlobData = fetchSalesforceImage(docId);
            }
            // 7. Generic HTTPS URL — can't fetch without session ID (AppExchange safe).
            // External URL images are skipped — cannot be fetched without session ID.

            // If no blob but we have a URL, store it for PDF rendering
            spec.sourceUrl = spec.contentVersionImageUrl;
            if (spec.imageBlobData == null && spec.sourceUrl == null) {
                if (spec.fieldValue.containsIgnoreCase('<img')) {
                    Integer sIdx = spec.fieldValue.indexOfIgnoreCase('src=');
                    if (sIdx != -1) {
                        sIdx += 4;
                        while (sIdx < spec.fieldValue.length() && spec.fieldValue.substring(sIdx, sIdx + 1) == ' ') {
                            sIdx++;
                        }
                        String qc = spec.fieldValue.substring(sIdx, sIdx + 1);
                        if (qc == '"' || qc == '\'') {
                            sIdx++;
                            Integer sEnd = spec.fieldValue.indexOf(qc, sIdx);
                            if (sEnd != -1) {
                                spec.sourceUrl = spec.fieldValue.substring(sIdx, sEnd).replace('&amp;', '&');
                            }
                        }
                    }
                } else if (spec.fieldValue.startsWithIgnoreCase('http') || spec.fieldValue.startsWith('/')) {
                    spec.sourceUrl = spec.fieldValue;
                }

                if (String.isBlank(spec.sourceUrl) || spec.sourceUrl.startsWith('data:')) {
                    return null;
                }
            }

            imageCounter++;
            spec.relationshipId = 'rIdImg' + imageCounter;
            spec.fileName = 'docgen_image_' + imageCounter + '.' + ext;
            spec.fileExtension = ext;

            // HTML template (v1.61+): emit an <img> tag with the resolved URL
            // instead of DOCX DrawingML. Blob.toPdf resolves /sfc/ relative URLs
            // natively. Data URIs can't be rendered by Blob.toPdf so blob-only
            // field values (without a resolvable URL) skip to avoid broken img.
            if (currentTemplateType == 'HTML') {
                String imgUrl = (spec.contentVersionImageUrl != null) ? spec.contentVersionImageUrl : spec.sourceUrl;
                if (String.isBlank(imgUrl) || imgUrl.startsWith('data:')) {
                    return '';
                }
                return buildHtmlImageMarkup(imgUrl, spec.widthPx, spec.heightPx, spec.maxWidthPx, spec.widthPercent);
            }

            // Register image — blob for DOCX, URL for PDF
            Map<String, Object> imgEntry = new Map<String, Object>{
                'relId' => spec.relationshipId,
                'fileName' => spec.fileName
            };
            if (spec.imageBlobData != null) {
                imgEntry.put('blob', spec.imageBlobData);
            }
            if (spec.contentVersionImageUrl != null) {
                imgEntry.put('url', spec.contentVersionImageUrl);
            } else if (spec.sourceUrl != null) {
                imgEntry.put('url', spec.sourceUrl);
            }
            pendingImages.add(imgEntry);

            // Compute image dimensions in EMU with intrinsic size detection and scaling.
            //
            // Intrinsic dim lookup requires reading the image's bytes (PNG IHDR or JPEG SOF
            // marker). On the PDF path we deliberately skip blob loading to save heap, so
            // imageBlobData is null and getImageDimensionsInEmu returns null. The pre-v1.80
            // fallback was a hardcoded 4:3 default (288×216 EMU = 4×3in) which then got
            // scaled to whatever max constraint was given. For `{%Image:N:240}` against a
            // portrait phone photo this produced a 240×180 rectangle — the source's natural
            // aspect was lost (#46).
            //
            // Fix: when we have no intrinsic dims AND no explicit fixed width/height on the
            // spec (so the user did NOT give us a definitive WxH), emit DOCGEN_AUTOSIZE on
            // the drawing's docPr/descr. The renderer's processDrawing flips to
            // `max-width:Xpx;max-height:Ypx;width:auto;height:auto;`, which lets Flying
            // Saucer compute aspect from the actual image bytes at render time. The cx/cy
            // we emit becomes the upper bound, not the forced size.
            List<Integer> intrinsicSizeEmu = getImageDimensionsInEmu(spec.imageBlobData, ext);
            Boolean hasIntrinsic = (intrinsicSizeEmu != null && intrinsicSizeEmu.size() == 2);
            Boolean hasExplicitFixed =
                (spec.widthPx != null && spec.heightPx != null) ||
                (spec.widthPercent != null &&
                spec.heightPercent != null);
            Boolean useAutoSize = !hasIntrinsic && !hasExplicitFixed;

            Integer baseWidthEmu = hasIntrinsic ? intrinsicSizeEmu[0] : (288 * 12700);
            Integer baseHeightEmu = hasIntrinsic ? intrinsicSizeEmu[1] : (216 * 12700);

            Integer widthEmu;
            Integer heightEmu;
            if (useAutoSize) {
                // No source aspect known. Resolve cx/cy from the spec's max constraint
                // (single-number tags like `{%Image:N:240}` set both maxWidthPx and
                // maxHeightPx). Defaults to page content area when no constraint given.
                Integer pageContentWidthEmu = 5943600; // 6.5in
                Integer pageContentHeightEmu = 8229600; // 9in
                Integer maxW = spec.maxWidthPx != null
                    ? (spec.maxWidthPx * 9525)
                    : (spec.maxWidthPercent != null ? (pageContentWidthEmu * spec.maxWidthPercent) / 100 : null);
                Integer maxH = spec.maxHeightPx != null
                    ? (spec.maxHeightPx * 9525)
                    : (spec.maxHeightPercent != null ? (pageContentHeightEmu * spec.maxHeightPercent) / 100 : null);
                widthEmu = (maxW != null && maxW > 0) ? maxW : pageContentWidthEmu;
                heightEmu = (maxH != null && maxH > 0) ? maxH : pageContentHeightEmu;
            } else {
                Integer[] scaledDims = scaleImageDimensionsEmu(baseWidthEmu, baseHeightEmu, spec);
                widthEmu = scaledDims[0];
                heightEmu = scaledDims[1];
            }

            String docPrAttrs =
                'id="' +
                imageCounter +
                '" name="DocGenImage' +
                imageCounter +
                '"' +
                (useAutoSize ? ' descr="DOCGEN_AUTOSIZE"' : '');

            return '</w:t></w:r>' +
                '<w:r><w:drawing>' +
                '<wp:inline distT="0" distB="0" distL="0" distR="0" ' +
                'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">' +
                '<wp:extent cx="' +
                widthEmu +
                '" cy="' +
                heightEmu +
                '"/>' +
                '<wp:docPr ' +
                docPrAttrs +
                '/>' +
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">' +
                '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">' +
                '<pic:nvPicPr>' +
                '<pic:cNvPr id="' +
                imageCounter +
                '" name="DocGenImage' +
                imageCounter +
                '"/>' +
                '<pic:cNvPicPr/>' +
                '</pic:nvPicPr>' +
                '<pic:blipFill>' +
                '<a:blip r:embed="' +
                spec.relationshipId +
                '" ' +
                'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/>' +
                '<a:stretch><a:fillRect/></a:stretch>' +
                '</pic:blipFill>' +
                '<pic:spPr>' +
                '<a:xfrm>' +
                '<a:off x="0" y="0"/>' +
                '<a:ext cx="' +
                widthEmu +
                '" cy="' +
                heightEmu +
                '"/>' +
                '</a:xfrm>' +
                '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
                '</pic:spPr>' +
                '</pic:pic>' +
                '</a:graphicData>' +
                '</a:graphic>' +
                '</wp:inline>' +
                '</w:drawing></w:r><w:r><w:t xml:space="preserve">';
        } catch (Exception e) {
            // Image injection failed (invalid CV ID, corrupt base64, etc.) — skip this image
            return null;
        }
    }

    /**
     * Builds the <img> markup for an HTML-template image ({%Field}, {%Image:N},
     * {%asset:key}) so Flying Saucer (Blob.toPdf) actually honors the requested
     * size.
     *
     * CRITICAL: for ContentVersion images resolved to a /sfc/servlet.shepherd/...
     * URL, Flying Saucer's image loader uses the source's NATURAL pixel
     * dimensions and ignores a bare inline `style="width:Npx"` on the <img> — so
     * every {%Field:WxH} token renders at the same fixed size (the in-thread
     * report behind this fix). The reliable shape, proven in
     * THE CACHE-BUST RULE (load-bearing) — established by controlled probe PDFs
     * measured with `pdfimages -list`:
     *
     *   Flying Saucer / Blob.toPdf computes the layout size of a replaced image
     *   ONCE PER UNIQUE URL and reuses it for every later <img> that points at the
     *   same URL. So when a template references the same /sfc/ ContentVersion at
     *   several sizes (the common case — one logo used big and small), they ALL
     *   collapse to the first occurrence's size. That is why {%Field:WxH} tokens
     *   appeared to be "ignored" — the CSS width WAS being honored, just computed
     *   once and shared.
     *
     *   Fix: give each distinct size its own URL by appending a size-keyed query
     *   param (`?dgsz=<key>`). The shepherd download endpoint ignores the extra
     *   param and still serves the image, but FS now treats each size as a
     *   separate replaced element and honors its CSS width/height EXACTLY:
     *     - {%Field:200x}  → width:200px;height:auto   → 200 CSS px, aspect kept
     *     - {%Field:340x97}→ width:340px;height:97px   → exact 340×97
     *   Same image at the SAME size shares a URL (laid out once, efficient);
     *   different sizes get different URLs. Units are CSS px (FS maps px→physical
     *   at 96 DPI per the R8 guide FAQ #8). With NO size token we emit a bare
     *   <img> at the image's intrinsic size (pixelWidth ÷ 96 in) — no cache-bust
     *   needed since unsized repeats are meant to be identical.
     *
     * Size tokens also remain meaningful for DOCX/Word output via the DrawingML
     * (`wp:extent`) path; this method is the HTML→PDF surface only.
     *
     * @param imgUrl   resolved (un-escaped) image URL — escaped here
     * @param widthPx  fixed width in px, or null
     * @param heightPx fixed height in px, or null
     * @param maxPx    single-number / m-prefixed max dimension in px, or null
     * @param widthPct fixed width as a percentage of the content area, or null
     */
    public static String buildHtmlImageMarkup(
        String imgUrl,
        Integer widthPx,
        Integer heightPx,
        Integer maxPx,
        Integer widthPct
    ) {
        if (String.isBlank(imgUrl)) {
            return '';
        }
        String orient = 'image-orientation:from-image;';

        String css;
        String sizeKey;
        if (widthPx != null && heightPx != null) {
            css = 'width:' + widthPx + 'px;height:' + heightPx + 'px;';
            sizeKey = 'w' + widthPx + 'h' + heightPx;
        } else if (widthPx != null) {
            css = 'width:' + widthPx + 'px;height:auto;';
            sizeKey = 'w' + widthPx;
        } else if (heightPx != null) {
            css = 'height:' + heightPx + 'px;width:auto;';
            sizeKey = 'h' + heightPx;
        } else if (widthPct != null) {
            css = 'width:' + widthPct + '%;height:auto;';
            sizeKey = 'p' + widthPct;
        } else if (maxPx != null) {
            // Single-number / m-prefixed token: render at that width, aspect kept.
            // (We can't read the image bytes on the PDF path to know orientation,
            // so treat the max dimension as the width — predictable and honored.)
            css = 'width:' + maxPx + 'px;height:auto;';
            sizeKey = 'm' + maxPx;
        } else {
            // No size token — intrinsic size (pixelWidth ÷ 96 in). No cache-bust
            // needed; unsized repeats of the same image are meant to be identical.
            return '<img src="' + imgUrl.escapeHtml4() + '" style="max-width:100%;' + orient + '"/>';
        }

        // Distinct URL per size so Flying Saucer honors each (see method doc).
        String bustedUrl = imgUrl + (imgUrl.contains('?') ? '&' : '?') + 'dgsz=' + sizeKey;
        return '<img src="' + bustedUrl.escapeHtml4() + '" style="' + css + orient + '"/>';
    }

    /**
     * PowerPoint image builder. Resolves an image to a binary blob using the
     * same case-1..7 logic as buildImageXml (rich-text, data URI, raw base64,
     * ContentVersion, refid, /sfc/), registers it in pendingImages with the
     * current slide path, and returns a `<!--DGPIC|relId|cx|cy-->` XML comment
     * marker. The marker is harmless inside any PPTX element (slides are valid
     * XML with comments allowed everywhere); postProcessPowerPointSlides walks
     * each slide after processXml, finds each marker's enclosing <p:sp>, and
     * replaces the shape with a <p:pic> referencing the rId.
     *
     * For the chart pipeline, this is exactly the path that {%__dgchart_<cvId>}
     * tags take after DocGenChartTagExpander rewrites a {Chart:...} tag — the
     * spec.fieldValue is the ContentVersion Id of the pre-rasterized PNG.
     *
     * Width/height in EMU: PowerPoint default canvas is 9144000×6858000 EMU
     * (10×7.5 in for legacy 4:3, or 12192000×6858000 for 16:9). For PPTX we
     * size charts to 4×3 in (3657600×2743200 EMU) by default — fits two
     * side-by-side on a 16:9 slide — and respect explicit widthPx/heightPx
     * from {%Field:WxH} when given (matches the runner LWC's sizeSuffix).
     */
    private static String buildImageXmlForPowerPoint(ImageRenderSpec spec) {
        if (spec == null || String.isBlank(spec.fieldValue)) {
            return null;
        }

        String ext = 'png';

        try {
            // Identical case-1..7 image resolution to buildImageXml. PPTX always
            // needs the blob (no zero-heap PDF path here — PPTX templates can't
            // render to PDF, see line 882).
            if (spec.fieldValue.containsIgnoreCase('<img')) {
                spec.imageBlobData = extractImageFromHtml(spec.fieldValue);
            } else if (spec.fieldValue.startsWith('data:image/')) {
                String base64Part = spec.fieldValue.substringAfter(',');
                if (spec.fieldValue.containsIgnoreCase('jpeg') || spec.fieldValue.containsIgnoreCase('jpg')) {
                    ext = 'jpeg';
                }
                spec.imageBlobData = EncodingUtil.base64Decode(base64Part);
            } else if (
                spec.fieldValue.length() > 100 &&
                !spec.fieldValue.contains('/') &&
                !spec.fieldValue.contains(' ')
            ) {
                spec.imageBlobData = EncodingUtil.base64Decode(spec.fieldValue);
            } else if (spec.fieldValue.startsWith('068') && spec.fieldValue.length() >= 15) {
                List<ContentVersion> cvs = [
                    SELECT Id, VersionData, FileExtension
                    FROM ContentVersion
                    WHERE Id = :spec.fieldValue
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    spec.imageBlobData = cvs[0].VersionData;
                    if (cvs[0].FileExtension != null) {
                        ext = cvs[0].FileExtension.toLowerCase();
                    }
                }
            } else if (spec.fieldValue.containsIgnoreCase('refid=')) {
                String refId = spec.fieldValue.substringAfterLast('refid=').substringBefore('&');
                if (String.isBlank(refId)) {
                    refId = spec.fieldValue.substringAfterLast('refid=');
                }
                spec.imageBlobData = fetchSalesforceImage(refId);
            } else if (spec.fieldValue.containsIgnoreCase('/servlet/') || spec.fieldValue.containsIgnoreCase('/sfc/')) {
                String docId = spec.fieldValue.substringAfterLast('/');
                if (docId.contains('?')) {
                    docId = docId.substringBefore('?');
                }
                spec.imageBlobData = fetchSalesforceImage(docId);
            }

            if (spec.imageBlobData == null) {
                return null;
            }

            imageCounter++;
            spec.relationshipId = 'rIdImg' + imageCounter;
            spec.fileName = 'docgen_image_' + imageCounter + '.' + ext;
            spec.fileExtension = ext;

            // Compute size in EMU. Prefer explicit WxH from the tag (e.g.
            // `{%cvId:600x450}` from the chart runner's sizeSuffix), then fall
            // back to intrinsic PNG/JPEG dimensions, then to a 4×3in default.
            Integer widthEmu;
            Integer heightEmu;
            if (spec.widthPx != null && spec.heightPx != null) {
                widthEmu = spec.widthPx * 9525;
                heightEmu = spec.heightPx * 9525;
            } else {
                List<Integer> intrinsicSizeEmu = getImageDimensionsInEmu(spec.imageBlobData, ext);
                if (intrinsicSizeEmu != null && intrinsicSizeEmu.size() == 2) {
                    // Intrinsic dims may be larger than the slide; cap at 8×6in
                    // (7315200×5486400 EMU) preserving aspect.
                    Integer maxW = 7315200;
                    Integer maxH = 5486400;
                    Integer w = intrinsicSizeEmu[0];
                    Integer h = intrinsicSizeEmu[1];
                    if (w > maxW || h > maxH) {
                        Double scaleW = (Double) maxW / w;
                        Double scaleH = (Double) maxH / h;
                        Double scale = Math.min(scaleW, scaleH);
                        w = (Integer) Math.floor(w * scale);
                        h = (Integer) Math.floor(h * scale);
                    }
                    widthEmu = w;
                    heightEmu = h;
                } else {
                    widthEmu = 3657600; // 4 in
                    heightEmu = 2743200; // 3 in
                }
            }

            // Register the image. `slidePath` lets postProcessPowerPointSlides
            // route it to the right slide rels file; `assembleZip` honors it
            // when writing the media entry. `pptHandled` flags this entry so
            // applyPendingImages doesn't also try to put it in the presentation
            // rels (PPTX images go in slide rels, not the top-level rels).
            Map<String, Object> imgEntry = new Map<String, Object>{
                'relId' => spec.relationshipId,
                'fileName' => spec.fileName,
                'blob' => spec.imageBlobData,
                'slidePath' => currentEntryName,
                'pptHandled' => true,
                'widthEmu' => widthEmu,
                'heightEmu' => heightEmu
            };
            pendingImages.add(imgEntry);

            // Marker that postProcessPowerPointSlides will swap for <p:pic>.
            // XML comment form is universally tolerated inside any element —
            // including <a:t>, <p:txBody>, anywhere in a <p:sp>. Pipe-delimited
            // payload survives ZIP roundtrip and grep cleanly.
            return '<!--DGPIC|' + spec.relationshipId + '|' + widthEmu + '|' + heightEmu + '|' + imageCounter + '-->';
        } catch (Exception e) {
            // Image resolution failed (invalid CV, corrupt base64). The document
            // still generates — it just has a hole where the logo or photo was
            // meant to be, which is the single most common "it looks wrong"
            // support report and previously left NOTHING to look at. Continuing
            // is right; doing so invisibly was not.
            DocGenErrorLogger.warn(
                'DocGenService',
                'Resolve image for output',
                'Image omitted from the document — could not be resolved: ' + e.getMessage()
            );
            return null;
        }
    }

    /**
     * Excel image builder — v1 stub. Excel embeds images via a separate
     * xl/drawings/drawingN.xml part with <xdr:twoCellAnchor>/<xdr:oneCellAnchor>
     * elements that anchor to cell coordinates, plus a relationship in
     * xl/drawings/_rels/drawingN.xml.rels and a <drawing r:id="..."/> reference
     * in the worksheet XML. Implementing this correctly requires:
     *   1. Parsing the worksheet cell that contains the {%} tag to recover its
     *      row/col coordinates (so the anchor lands in the right cell).
     *   2. Creating xl/drawings/drawing1.xml if absent, or appending to it.
     *   3. Writing xl/drawings/_rels/drawing1.xml.rels with the image
     *      relationship.
     *   4. Inserting <drawing r:id="rIdN"/> into the worksheet XML if missing.
     *   5. Adding a <Relationship Type=".../drawing"/> in the worksheet rels.
     *   6. Adding <Override> entries in [Content_Types].xml for the drawing.
     * For v1 (#117 PowerPoint slice) we strip the tag and emit nothing so the
     * cell text renders cleanly. Excel chart support is tracked as a follow-up
     * (file new issue, mirror this design sketch in the issue body).
     */
    private static String buildImageXmlForExcel(ImageRenderSpec spec) {
        // Strip the tag silently — produces an empty cell value instead of a
        // broken render. The PowerPoint-style marker approach won't work here
        // because Excel cell text lives inside <c><v>shared-string-idx</v></c>
        // or <c t="inlineStr"><is><t>...</t></is></c>; injecting an XML comment
        // into <t> would break the cell parser in Excel.
        return '';
    }

    /**
     * Walks every processed PPTX slide, converts <!--DGPIC|...--> markers into
     * real <p:pic> shapes, and injects per-slide image relationships into
     * ppt/slides/_rels/slideN.xml.rels. Each marker either:
     *   (a) sits inside a <p:sp> whose text body contained the original tag —
     *       we replace the whole <p:sp> with a <p:pic> at the shape's position
     *       and size (so authors can size+place the image by placing a placeholder
     *       shape).
     *   (b) sits outside any <p:sp> (or we can't find one) — we append a
     *       free-floating <p:pic> to <p:spTree> at the marker's location.
     * When no enclosing placeholder shape exists, the image renders at the size
     * computed when registering it (intrinsic for PNG/JPEG, fallback 4×3in for
     * ContentVersion blobs we can't size, override from the {%Field:WxH} suffix
     * when given).
     */
    private static void postProcessPowerPointSlides(MergeResult mr) {
        if (pendingImages.isEmpty()) {
            return;
        }
        // Bucket images by slidePath so we update each slide's rels file once.
        Map<String, List<Map<String, Object>>> imagesBySlide = new Map<String, List<Map<String, Object>>>();
        for (Map<String, Object> img : pendingImages) {
            if (img.get('pptHandled') != true) {
                continue;
            }
            String slidePath = (String) img.get('slidePath');
            if (String.isBlank(slidePath)) {
                continue;
            }
            if (!imagesBySlide.containsKey(slidePath)) {
                imagesBySlide.put(slidePath, new List<Map<String, Object>>());
            }
            imagesBySlide.get(slidePath).add(img);
        }
        if (imagesBySlide.isEmpty()) {
            return;
        }

        // Iterate every slide that had at least one image. Convert each marker
        // into a <p:pic> element + update the slide rels file in passthrough.
        for (String slidePath : imagesBySlide.keySet()) {
            String slideXml = mr.processedXmlEntries.get(slidePath);
            if (slideXml == null || !slideXml.contains('<!--DGPIC|')) {
                continue;
            }

            // Update the matching slide rels file (ppt/slides/_rels/slideN.xml.rels)
            String relsName = slidePath.replace('slides/', 'slides/_rels/') + '.rels';
            Blob existingRelsBlob = mr.passthroughEntries.get(relsName);
            String existingRelsXml;
            if (existingRelsBlob != null) {
                existingRelsXml = existingRelsBlob.toString();
            } else {
                // Slide had no prior rels (unusual but possible) — start a fresh file
                existingRelsXml =
                    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
                    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>';
            }

            Integer nextRelId = nextPowerPointRelationshipId(existingRelsXml);
            for (Map<String, Object> img : imagesBySlide.get(slidePath)) {
                String oldRelId = (String) img.get('relId');
                String newRelId = 'rId' + nextRelId;
                nextRelId++;
                img.put('relId', newRelId);
                slideXml = slideXml.replace('<!--DGPIC|' + oldRelId + '|', '<!--DGPIC|' + newRelId + '|');
            }

            slideXml = convertDgPicMarkersInSlide(slideXml, imagesBySlide.get(slidePath));
            mr.processedXmlEntries.put(slidePath, slideXml);

            String inserts = '';
            for (Map<String, Object> img : imagesBySlide.get(slidePath)) {
                String relId = (String) img.get('relId');
                String fileName = (String) img.get('fileName');
                inserts +=
                    '<Relationship Id="' +
                    relId +
                    '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/' +
                    fileName +
                    '"/>';
            }
            existingRelsXml = existingRelsXml.replace('</Relationships>', inserts + '</Relationships>');
            mr.passthroughEntries.put(relsName, Blob.valueOf(existingRelsXml));
        }
    }

    private static Integer nextPowerPointRelationshipId(String relsXml) {
        Integer maxId = 0;
        if (String.isBlank(relsXml)) {
            return 1;
        }

        Integer cursor = 0;
        while (cursor < relsXml.length()) {
            Integer tagStart = relsXml.indexOf('<Relationship', cursor);
            if (tagStart == -1) {
                break;
            }
            Integer tagEnd = relsXml.indexOf('>', tagStart);
            if (tagEnd == -1) {
                break;
            }
            String tag = relsXml.substring(tagStart, tagEnd);
            String idValue = extractXmlAttrValue(tag, 'Id');
            if (idValue != null && idValue.startsWith('rId')) {
                try {
                    Integer relNum = Integer.valueOf(idValue.substring(3));
                    if (relNum > maxId) {
                        maxId = relNum;
                    }
                } catch (Exception e) {
                    // Ignore non-numeric relationship ids from source packages.
                }
            }
            cursor = tagEnd + 1;
        }
        return maxId + 1;
    }

    /**
     * Per-slide DGPIC marker conversion. Walks the slide XML, replacing each
     * marker with a <p:pic> element. If the marker sits inside a <p:sp>, the
     * whole shape gets swapped (preserving the shape's <a:off>/<a:ext> so the
     * image lands where the author drew the placeholder). Otherwise the
     * <p:pic> is inserted in place with a default position near the top-left.
     */
    @TestVisible
    private static String convertDgPicMarkersInSlide(String slideXml, List<Map<String, Object>> images) {
        // Sort markers in order of appearance so position-preservation is stable.
        Integer searchFrom = 0;
        Integer nextPicId = nextPowerPointShapeId(slideXml);
        Boolean insertedPicture = false;
        while (true) {
            Integer markerStart = slideXml.indexOf('<!--DGPIC|', searchFrom);
            if (markerStart == -1) {
                break;
            }
            Integer markerEnd = slideXml.indexOf('-->', markerStart);
            if (markerEnd == -1) {
                // Malformed marker — strip and continue to avoid infinite loop.
                slideXml = slideXml.substring(0, markerStart) + slideXml.substring(markerStart + 10);
                continue;
            }
            String payload = slideXml.substring(markerStart + 10, markerEnd);
            // Marker payload: relId|widthEmu|heightEmu|picId (4 parts after stripping
            // the leading <!--DGPIC| and trailing -->). Apex String.split drops
            // trailing empty strings, so we require exactly 4.
            List<String> parts = payload.split('\\|');
            if (parts.size() < 4) {
                slideXml = slideXml.substring(0, markerStart) + slideXml.substring(markerEnd + 3);
                continue;
            }
            String relId = parts[0];
            Integer widthEmu = Integer.valueOf(parts[1]);
            Integer heightEmu = Integer.valueOf(parts[2]);
            Integer picId = nextPicId;
            nextPicId++;

            // Find enclosing <p:sp> (the shape that contains the marker). If
            // we find one, replace it; if not, fall back to in-place insert.
            Integer spOpenStart = findOpeningSpBefore(slideXml, markerStart);
            Integer spCloseEnd = -1;
            String offX = '914400';
            String offY = '914400';
            Integer renderWidthEmu = widthEmu;
            Integer renderHeightEmu = heightEmu;
            if (spOpenStart != -1) {
                spCloseEnd = findClosingSpAfter(slideXml, markerEnd);
                if (spCloseEnd != -1) {
                    // Capture the shape's transform so the picture replaces it
                    // at the same position and size. The <a:xfrm> sits in
                    // <p:spPr>; if absent (rare), we fall back to marker dimensions.
                    String shapeXml = slideXml.substring(spOpenStart, spCloseEnd);
                    Integer xfrmStart = findPowerPointLocalTagStart(shapeXml, 'xfrm', 0);
                    if (xfrmStart != -1) {
                        Integer offIdx = findPowerPointLocalTagStart(shapeXml, 'off', xfrmStart);
                        if (offIdx != -1) {
                            String offTag = shapeXml.substring(offIdx, shapeXml.indexOf('>', offIdx));
                            String xVal = extractXmlAttrValue(offTag, 'x');
                            String yVal = extractXmlAttrValue(offTag, 'y');
                            if (xVal != null) {
                                offX = xVal;
                            }
                            if (yVal != null) {
                                offY = yVal;
                            }
                        }
                        Integer extIdx = findPowerPointLocalTagStart(shapeXml, 'ext', xfrmStart);
                        if (extIdx != -1) {
                            String extTag = shapeXml.substring(extIdx, shapeXml.indexOf('>', extIdx));
                            String cxVal = extractXmlAttrValue(extTag, 'cx');
                            String cyVal = extractXmlAttrValue(extTag, 'cy');
                            if (cxVal != null && cyVal != null) {
                                try {
                                    Integer placeholderWidth = Integer.valueOf(cxVal);
                                    Integer placeholderHeight = Integer.valueOf(cyVal);
                                    if (placeholderWidth > 0 && placeholderHeight > 0) {
                                        renderWidthEmu = placeholderWidth;
                                        renderHeightEmu = placeholderHeight;
                                    }
                                } catch (Exception e) {
                                    // Keep marker dimensions if the source transform is malformed.
                                }
                            }
                        }
                    }
                }
            }

            String picXml = buildPicElement(picId, relId, offX, offY, renderWidthEmu, renderHeightEmu);

            if (spOpenStart != -1 && spCloseEnd != -1) {
                // Swap the entire <p:sp>...</p:sp> with the <p:pic>
                slideXml = slideXml.substring(0, spOpenStart) + picXml + slideXml.substring(spCloseEnd);
                searchFrom = spOpenStart + picXml.length();
                insertedPicture = true;
            } else {
                // No enclosing shape found — insert in place (will likely render
                // as a free-floating image which authors may not expect but
                // beats silent loss).
                slideXml = slideXml.substring(0, markerStart) + picXml + slideXml.substring(markerEnd + 3);
                searchFrom = markerStart + picXml.length();
                insertedPicture = true;
            }
        }
        if (insertedPicture) {
            slideXml = ensurePowerPointPictureNamespaces(slideXml);
        }
        return slideXml;
    }

    private static String ensurePowerPointPictureNamespaces(String slideXml) {
        if (String.isBlank(slideXml)) {
            return slideXml;
        }
        Integer rootStart = slideXml.indexOf('<p:sld');
        if (rootStart == -1) {
            rootStart = slideXml.indexOf('<ns0:sld');
        }
        if (rootStart == -1) {
            rootStart = slideXml.indexOf(':sld');
            if (rootStart != -1) {
                rootStart = slideXml.lastIndexOf('<', rootStart);
            }
        }
        if (rootStart == -1) {
            return slideXml;
        }
        Integer rootEnd = slideXml.indexOf('>', rootStart);
        if (rootEnd == -1) {
            return slideXml;
        }

        String rootTag = slideXml.substring(rootStart, rootEnd);
        String additions = '';
        if (!rootTag.contains('xmlns:p=')) {
            additions += ' xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"';
        }
        if (!rootTag.contains('xmlns:a=')) {
            additions += ' xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"';
        }
        if (!rootTag.contains('xmlns:r=')) {
            additions += ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
        }
        if (String.isBlank(additions)) {
            return slideXml;
        }
        return slideXml.substring(0, rootEnd) + additions + slideXml.substring(rootEnd);
    }

    private static Integer nextPowerPointShapeId(String slideXml) {
        Integer maxId = 0;
        for (Integer tagStart : findPowerPointLocalTagStarts(slideXml, 'cNvPr')) {
            Integer tagEnd = slideXml.indexOf('>', tagStart);
            if (tagEnd == -1) {
                continue;
            }
            String tag = slideXml.substring(tagStart, tagEnd);
            String idValue = extractXmlAttrValue(tag, 'id');
            if (idValue != null) {
                try {
                    Integer shapeId = Integer.valueOf(idValue);
                    if (shapeId > maxId) {
                        maxId = shapeId;
                    }
                } catch (Exception e) {
                    // Ignore non-numeric ids in malformed source parts.
                }
            }
        }
        return maxId + 1;
    }

    private static Integer findPowerPointLocalTagStart(String xml, String localName, Integer fromIndex) {
        if (String.isBlank(xml) || String.isBlank(localName)) {
            return -1;
        }
        Integer safeFrom = Math.max(0, fromIndex == null ? 0 : fromIndex);
        String suffix = xml.substring(Math.min(safeFrom, xml.length()));
        Matcher matcher = Pattern.compile('<[A-Za-z][A-Za-z0-9]*:' + localName + '(\\s|>|/)').matcher(suffix);
        if (!matcher.find()) {
            return -1;
        }
        return safeFrom + matcher.start();
    }

    private static List<Integer> findPowerPointLocalTagStarts(String xml, String localName) {
        List<Integer> starts = new List<Integer>();
        if (String.isBlank(xml) || String.isBlank(localName)) {
            return starts;
        }
        Matcher matcher = Pattern.compile('<[A-Za-z][A-Za-z0-9]*:' + localName + '(\\s|>|/)').matcher(xml);
        while (matcher.find()) {
            starts.add(matcher.start());
        }
        return starts;
    }

    /**
     * Finds the start of the <p:sp> opening tag that encloses `pos`. Returns
     * -1 if `pos` isn't inside a <p:sp> (e.g. marker is inside a <p:pic> or
     * floating in <p:spTree> outside any shape). Apex String.lastIndexOf has
     * no fromIndex form, so we substring up to `pos` and scan backwards. Skip
     * <p:spPr> / <p:spTree> false matches by requiring '<p:sp>' or '<p:sp '.
     *
     * Algorithm: list all `<p:sp ` / `<p:sp>` opens before pos and `</p:sp>`
     * closes before pos in order; walk them, tracking depth. Last unmatched
     * open is the enclosing shape.
     */
    private static Integer findOpeningSpBefore(String xml, Integer pos) {
        String prefix = xml.substring(0, pos);
        List<Integer> stack = new List<Integer>();
        Matcher matcher = Pattern.compile('</?[A-Za-z][A-Za-z0-9]*:sp(\\s|>)').matcher(prefix);
        while (matcher.find()) {
            String tagStart = prefix.substring(matcher.start(), matcher.end());
            if (tagStart.startsWith('</')) {
                if (!stack.isEmpty()) {
                    stack.remove(stack.size() - 1);
                }
            } else {
                stack.add(matcher.start());
            }
        }
        if (stack.isEmpty()) {
            return -1;
        }
        return stack[stack.size() - 1];
    }

    /**
     * Finds the end position (exclusive) of the matching </p:sp> after `pos`.
     * Returns -1 if no close found. Walks forward with depth tracking on the
     * same `<p:sp ` / `<p:sp>` open vs `</p:sp>` close events.
     */
    private static Integer findClosingSpAfter(String xml, Integer pos) {
        Integer depth = 0;
        String suffix = xml.substring(pos);
        Matcher matcher = Pattern.compile('</?[A-Za-z][A-Za-z0-9]*:sp(\\s|>)').matcher(suffix);
        while (matcher.find()) {
            String tagStart = suffix.substring(matcher.start(), matcher.end());
            if (!tagStart.startsWith('</')) {
                depth++;
            } else {
                if (depth == 0) {
                    Integer closeStart = pos + matcher.start();
                    Integer closeEnd = xml.indexOf('>', closeStart);
                    return closeEnd == -1 ? -1 : closeEnd + 1;
                }
                depth--;
            }
        }
        return -1;
    }

    /**
     * Emits a PowerPoint <p:pic> element. Namespaces `p:`, `a:`, `r:` are
     * already declared on the slide root (<p:sld xmlns:p="..." xmlns:a="..."
     * xmlns:r="..."/>), so we don't redeclare them here.
     */
    private static String buildPicElement(
        Integer picId,
        String relId,
        String offX,
        String offY,
        Integer widthEmu,
        Integer heightEmu
    ) {
        return '<p:pic>' +
            '<p:nvPicPr>' +
            '<p:cNvPr id="' +
            picId +
            '" name="DocGenPicture' +
            picId +
            '"/>' +
            '<p:cNvPicPr/>' +
            '<p:nvPr/>' +
            '</p:nvPicPr>' +
            '<p:blipFill>' +
            '<a:blip r:embed="' +
            relId +
            '"/>' +
            '<a:stretch><a:fillRect/></a:stretch>' +
            '</p:blipFill>' +
            '<p:spPr>' +
            '<a:xfrm>' +
            '<a:off x="' +
            offX +
            '" y="' +
            offY +
            '"/>' +
            '<a:ext cx="' +
            widthEmu +
            '" cy="' +
            heightEmu +
            '"/>' +
            '</a:xfrm>' +
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>' +
            '</p:spPr>' +
            '</p:pic>';
    }

    /**
     * Resolves a {%Image:N} or {%Image:N:SIZE} tag.
     * Queries ContentDocumentLink for images attached to the current record,
     * picks the Nth oldest, and returns an ImageRenderSpec ready for buildImageXml.
     * Returns null silently if the record has fewer than N images (empty render).
     *
     * Size grammar (SIZE segment, optional):
     *   "200"     → max dimension, preserves aspect
     *   "200x200" → explicit width × height
     *   "200x"    → width only, auto height
     *   "x200"    → auto width, height only
     */
    @TestVisible
    private static ImageRenderSpec resolveImageByIndexTag(String imageTagSpec, Map<String, Object> data) {
        if (String.isBlank(imageTagSpec))
            return null;
        List<String> parts = imageTagSpec.split(':');
        if (parts.size() < 2)
            return null;
        String indexToken = parts[1].trim();
        if (!indexToken.isNumeric())
            return null;
        Integer n = Integer.valueOf(indexToken);
        if (n < 1)
            return null;

        Object recordIdVal = data != null ? data.get('Id') : null;
        if (recordIdVal == null)
            return null;
        Id recordId;
        try {
            recordId = Id.valueOf(String.valueOf(recordIdVal));
        } catch (Exception e) {
            return null;
        }

        String cvId = resolveImageCvIdByIndex(n, recordId);
        if (String.isBlank(cvId))
            return null;

        ImageRenderSpec spec = new ImageRenderSpec();
        spec.imageField = 'Image:' + n;
        spec.fieldValue = cvId;

        if (parts.size() >= 3) {
            applyImageSizeToken(spec, parts[2].trim());
        }
        return spec;
    }

    /**
     * Resolves the Nth ContentVersion ID from the per-transaction cache,
     * or falls back to a single-record SOQL query if the record isn't cached.
     * Returns null if the record has fewer than N image attachments.
     */
    @TestVisible
    private static String resolveImageCvIdByIndex(Integer n, Id recordId) {
        if (n == null || n < 1 || recordId == null)
            return null;

        if (imageCvCache != null && imageCvCache.containsKey(recordId)) {
            List<String> cached = imageCvCache.get(recordId);
            if (cached == null || cached.size() < n)
                return null;
            return cached[n - 1];
        }

        Set<String> imageExts = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg' };
        List<ContentDocumentLink> cdls = [
            SELECT ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :recordId AND ContentDocument.FileExtension IN :imageExts
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
            LIMIT 50
        ];
        if (cdls.size() < n)
            return null;
        return String.valueOf(cdls[n - 1].ContentDocument.LatestPublishedVersionId);
    }

    /**
     * Bulk-fetches attached image CVs for a set of record Ids in ONE SOQL query
     * and caches the results keyed by LinkedEntityId. Called before a loop body
     * that contains {%Image:N} tags, so per-iteration resolution is O(1).
     *
     * ContentDocumentLink polymorphic-IN restriction: all IDs must be the same
     * sObject type. Callers enforce this by passing iteration IDs from a single
     * {#Relationship} loop, which always yields one type per loop.
     */
    @TestVisible
    private static void prefetchImagesForIds(Set<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty())
            return;
        if (imageCvCache == null)
            imageCvCache = new Map<Id, List<String>>();

        Set<Id> toFetch = new Set<Id>();
        for (Id rid : recordIds) {
            if (rid != null && !imageCvCache.containsKey(rid))
                toFetch.add(rid);
        }
        if (toFetch.isEmpty())
            return;

        // Seed cache with empty lists so records with zero images don't re-query on cache miss
        for (Id rid : toFetch) {
            imageCvCache.put(rid, new List<String>());
        }

        Set<String> imageExts = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg' };
        List<ContentDocumentLink> cdls = [
            SELECT LinkedEntityId, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :toFetch AND ContentDocument.FileExtension IN :imageExts
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate ASC, ContentDocument.Id ASC
        ];
        for (ContentDocumentLink cdl : cdls) {
            List<String> bucket = imageCvCache.get(cdl.LinkedEntityId);
            if (bucket != null) {
                bucket.add(String.valueOf(cdl.ContentDocument.LatestPublishedVersionId));
            }
        }
    }

    /**
     * Resolves a shared-asset image tag — the part after the leading '%', i.e.
     * "asset:<key>" or "asset:<key>:SIZE" — to rendered image XML.
     *
     * The asset key is mapped to its latest ContentVersion Id (resolveAssetCvIds,
     * cached per transaction), the optional WxH size token is parsed with the SAME
     * grammar the field-image path uses (parseImageTagSpec), and the result is
     * dispatched through the EXISTING image pipeline so DOCX/PDF/HTML/PowerPoint
     * + sizing all work with no new render code.
     *
     * Robustness: a missing/inactive asset (resolver returns null) is never a hard
     * mid-generation failure — it logs an error and emits a clear inline placeholder
     * so the author sees which tag didn't resolve.
     */
    @TestVisible
    private static String resolveAssetTagSpec(String imageTagSpec) {
        if (String.isBlank(imageTagSpec)) {
            return null;
        }

        // Strip the "asset:" head, leaving "<key>" or "<key>:SIZE".
        String remainder = imageTagSpec.substringAfter(':').trim();
        if (String.isBlank(remainder)) {
            return assetPlaceholder('(unknown)');
        }

        // Split key from the optional size token. Reuse parseImageTagSpec for the
        // WxH grammar by feeding it "<key>[:SIZE]" — its imageField becomes the key
        // (unused here) and the size constraints land on the spec we render with.
        String assetKey = remainder.contains(':') ? remainder.substringBefore(':').trim() : remainder.trim();
        if (String.isBlank(assetKey)) {
            return assetPlaceholder('(unknown)');
        }
        // Keys are stored lowercase (DocGenAssetKeyHandler.normalizeKey); lowercase
        // the tag's key so {%asset:Footer} resolves the same asset as {%asset:footer}.
        assetKey = assetKey.toLowerCase();

        String cvId = resolveAssetCvIds(new Set<String>{ assetKey }).get(assetKey);
        if (String.isBlank(cvId)) {
            // Missing or inactive asset, or an asset with no uploaded version yet.
            System.debug(
                LoggingLevel.ERROR,
                'Portwood: {%asset:' + assetKey + '} did not resolve (missing, inactive, or no version).'
            );
            return assetPlaceholder(assetKey);
        }

        ImageRenderSpec spec = parseImageTagSpec(remainder);
        spec.fieldValue = cvId;
        return dispatchImageXml(spec);
    }

    /**
     * True when the merge tag at tagStart sits inside an HTML src attribute
     * (the characters immediately before it are src=" or src='). Used to emit
     * a bare URL instead of full <img> markup in that context.
     */
    @TestVisible
    private static Boolean isInsideSrcAttribute(String xml, Integer tagStart) {
        if (tagStart == null || tagStart < 5) {
            return false;
        }
        String before = xml.substring(Math.max(0, tagStart - 8), tagStart).toLowerCase();
        return before.endsWith('src="') || before.endsWith('src=\'');
    }

    /**
     * Inline placeholder for an asset tag that couldn't resolve. Visible enough
     * that an author notices the missing asset, but it never aborts generation.
     */
    private static String assetPlaceholder(String assetKey) {
        return '[missing asset: ' + (assetKey == null ? '' : assetKey.escapeXml()) + ']';
    }

    /**
     * Maps shared-asset keys to their latest ContentVersion Id with a single SOQL,
     * cached per transaction (assetCvCache) like imageCvCache. Only ACTIVE assets
     * resolve; missing/inactive keys are cached as null so they neither re-query
     * nor crash the merge — callers treat null as "render a placeholder".
     *
     * The live pointer is ContentDocument.LatestPublishedVersionId on the document
     * linked to the asset (a version's FirstPublishLocationId = assetId natively
     * creates that ContentDocumentLink; see DocGenController.addAssetVersion). Read
     * WITH SYSTEM_MODE behind the per-field FLS guard, matching the package's
     * internal-CV-read convention (the asset catalog is package-internal config,
     * not user-owned data, and must resolve identically for every running user).
     */
    @TestVisible
    public static Map<String, String> resolveAssetCvIds(Set<String> keys) {
        if (assetCvCache == null) {
            assetCvCache = new Map<String, String>();
        }
        Map<String, String> result = new Map<String, String>();
        if (keys == null || keys.isEmpty()) {
            return result;
        }

        Set<String> toFetch = new Set<String>();
        for (String key : keys) {
            if (String.isBlank(key)) {
                continue;
            }
            if (assetCvCache.containsKey(key)) {
                result.put(key, assetCvCache.get(key));
            } else {
                toFetch.add(key);
            }
        }
        if (toFetch.isEmpty()) {
            return result;
        }

        // Seed cache misses as null so unknown/inactive keys don't re-query.
        for (String key : toFetch) {
            assetCvCache.put(key, null);
        }

        DocGenFlsGuard.assertAccessible(DocGen_Asset__c.sObjectType, new Set<String>{ 'Asset_Key__c', 'Is_Active__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Asset__c> assets = [
            SELECT
                Asset_Key__c,
                (
                    SELECT ContentDocument.LatestPublishedVersionId
                    FROM ContentDocumentLinks
                    ORDER BY ContentDocument.CreatedDate DESC, ContentDocument.Id DESC
                    LIMIT 1
                )
            FROM DocGen_Asset__c
            WHERE Asset_Key__c IN :toFetch AND Is_Active__c = TRUE
            WITH SYSTEM_MODE
        ];

        for (DocGen_Asset__c asset : assets) {
            String cvId = null;
            if (asset.ContentDocumentLinks != null && !asset.ContentDocumentLinks.isEmpty()) {
                Id latest = asset.ContentDocumentLinks[0].ContentDocument.LatestPublishedVersionId;
                cvId = (latest == null) ? null : String.valueOf(latest);
            }
            assetCvCache.put(asset.Asset_Key__c, cvId);
        }

        for (String key : toFetch) {
            result.put(key, assetCvCache.get(key));
        }
        return result;
    }

    /**
     * Returns true if the given XML contains a {%Image:...} tag — used to decide
     * whether to pre-fetch attachments for an upcoming loop body.
     */
    @TestVisible
    private static Boolean loopBodyHasImageTag(String innerXml) {
        if (String.isBlank(innerXml))
            return false;
        String lower = innerXml.toLowerCase();
        return lower.contains('{%image:');
    }

    /**
     * True when a loop body references {RowNumber} (bare or with a format suffix).
     *
     * Probed once per loop rather than assumed, because supplying the number means
     * COPYING each row's data map to add the key — cheap for one table, real heap on
     * a 30,000-row giant-query loop. Templates that don't ask for it pay nothing.
     */
    @TestVisible
    private static Boolean loopBodyHasRowNumberTag(String innerXml) {
        if (String.isBlank(innerXml)) {
            return false;
        }
        String lower = innerXml.toLowerCase();
        return lower.contains('{rownumber}') || lower.contains('{rownumber:');
    }

    /**
     * The per-row context for one loop iteration: the record's own map, plus
     * {RowNumber} when the body asks for it.
     *
     * The copy is deliberate — writing the key into the caller's map would leak the
     * counter into the record data itself, and a nested loop would then see its
     * parent's row number as a stale field.
     */
    private static Map<String, Object> rowContext(Map<String, Object> row, Boolean wantsRowNumber, Integer rowNumber) {
        if (!wantsRowNumber) {
            return row;
        }
        Map<String, Object> ctx = new Map<String, Object>(row);
        ctx.put('RowNumber', rowNumber);
        return ctx;
    }

    /**
     * Applies {%Image:N:SIZE} size token to an ImageRenderSpec.
     *   single number   → max dimension (preserves aspect)
     *   WxH             → explicit width × height
     *   Wx              → width only, auto height
     *   xH              → auto width, height only
     */
    @TestVisible
    private static void applyImageSizeToken(ImageRenderSpec spec, String sizeToken) {
        if (spec == null || String.isBlank(sizeToken))
            return;
        String t = sizeToken.trim().toLowerCase();
        if (!t.contains('x')) {
            if (t.isNumeric()) {
                Integer nVal = Integer.valueOf(t);
                spec.maxWidthPx = nVal;
                spec.maxHeightPx = nVal;
            }
            return;
        }
        Integer xIdx = t.indexOf('x');
        String w = t.substring(0, xIdx).trim();
        String h = t.substring(xIdx + 1).trim();
        if (!String.isBlank(w) && w.isNumeric()) {
            spec.widthPx = Integer.valueOf(w);
        }
        if (!String.isBlank(h) && h.isNumeric()) {
            spec.heightPx = Integer.valueOf(h);
        }
    }

    private static ImageRenderSpec parseImageTagSpec(String imageTagSpec) {
        ImageRenderSpec spec = new ImageRenderSpec();
        spec.imageField = imageTagSpec;
        if (String.isBlank(imageTagSpec) || !imageTagSpec.contains(':')) {
            return spec;
        }

        List<String> tagParts = imageTagSpec.split(':', 2);
        spec.imageField = tagParts[0].trim();
        String sizeToken = tagParts[1].trim().toLowerCase();
        if (!sizeToken.contains('x')) {
            return spec;
        }

        Integer separatorIndex = sizeToken.indexOf('x');
        if (separatorIndex < 0) {
            return spec;
        }
        String widthToken = sizeToken.substring(0, separatorIndex).trim();
        String heightToken = sizeToken.substring(separatorIndex + 1).trim();

        ImageDimensionSpec widthSpec = parseImageDimensionSpec(widthToken);
        ImageDimensionSpec heightSpec = parseImageDimensionSpec(heightToken);
        if (widthSpec != null) {
            if (widthSpec.isMaxConstraint) {
                spec.maxWidthPx = widthSpec.pixelValue;
                spec.maxWidthPercent = widthSpec.percentValue;
            } else {
                spec.widthPx = widthSpec.pixelValue;
                spec.widthPercent = widthSpec.percentValue;
            }
        }
        if (heightSpec != null) {
            if (heightSpec.isMaxConstraint) {
                spec.maxHeightPx = heightSpec.pixelValue;
                spec.maxHeightPercent = heightSpec.percentValue;
            } else {
                spec.heightPx = heightSpec.pixelValue;
                spec.heightPercent = heightSpec.percentValue;
            }
        }
        return spec;
    }

    private static ImageDimensionSpec parseImageDimensionSpec(String rawToken) {
        if (String.isBlank(rawToken)) {
            return null;
        }
        String token = rawToken.trim().toLowerCase();
        Boolean isMax = token.startsWith('m');
        if (isMax) {
            token = token.substring(1).trim();
        }
        if (String.isBlank(token)) {
            return null;
        }

        Integer percentValue = null;
        Integer pixelValue = null;
        if (token.endsWith('%')) {
            String num = token.substring(0, token.length() - 1).trim();
            if (num.isNumeric()) {
                percentValue = Integer.valueOf(num);
            }
        } else if (token.endsWith('px')) {
            String num = token.substring(0, token.length() - 2).trim();
            if (num.isNumeric()) {
                pixelValue = Integer.valueOf(num);
            }
        } else if (token.isNumeric()) {
            pixelValue = Integer.valueOf(token);
        }

        if (percentValue == null && pixelValue == null) {
            return null;
        }
        ImageDimensionSpec dimSpec = new ImageDimensionSpec();
        dimSpec.isMaxConstraint = isMax;
        dimSpec.percentValue = percentValue;
        dimSpec.pixelValue = pixelValue;
        return dimSpec;
    }

    private static Integer parseHexToInt(String hexStr) {
        if (String.isBlank(hexStr)) {
            return 0;
        }
        String hexChars = '0123456789ABCDEF';
        Integer result = 0;
        for (Integer i = 0; i < hexStr.length(); i++) {
            Integer digit = hexChars.indexOf(hexStr.substring(i, i + 1).toUpperCase());
            if (digit < 0) {
                return 0;
            }
            result = (result * 16) + digit;
        }
        return result;
    }

    private static List<Integer> getImageDimensionsInEmu(Blob imageBlob, String fileExtension) {
        if (imageBlob == null || imageBlob.size() < 24) {
            return null;
        }
        String hex = EncodingUtil.convertToHex(imageBlob);
        if (String.isBlank(hex) || hex.length() < 64) {
            return null;
        }
        String hexUpper = hex.toUpperCase();
        String extLower = fileExtension != null ? fileExtension.toLowerCase() : '';
        Integer widthPx = null;
        Integer heightPx = null;
        try {
            Boolean looksPng =
                extLower == 'png' || (hexUpper.length() >= 16 && hexUpper.substring(0, 16) == '89504E470D0A1A0A');
            if (looksPng) {
                Integer ihdrIdx = hexUpper.indexOf('49484452');
                if (ihdrIdx >= 0 && ihdrIdx + 24 <= hexUpper.length()) {
                    Integer w = parseHexToInt(hexUpper.substring(ihdrIdx + 8, ihdrIdx + 16));
                    Integer h = parseHexToInt(hexUpper.substring(ihdrIdx + 16, ihdrIdx + 24));
                    if (w > 0 && h > 0) {
                        widthPx = w;
                        heightPx = h;
                    }
                }
            }
            Boolean looksJpeg =
                extLower == 'jpg' ||
                extLower == 'jpeg' ||
                (hexUpper.length() >= 4 &&
                hexUpper.substring(0, 4) == 'FFD8');
            if ((widthPx == null || heightPx == null) && looksJpeg) {
                Integer sofIdx = hexUpper.indexOf('FFC0');
                if (sofIdx >= 0 && sofIdx + 18 <= hexUpper.length()) {
                    heightPx = parseHexToInt(hexUpper.substring(sofIdx + 10, sofIdx + 14));
                    widthPx = parseHexToInt(hexUpper.substring(sofIdx + 14, sofIdx + 18));
                }
            }
            if (widthPx == null || heightPx == null || widthPx <= 0 || heightPx <= 0) {
                return null;
            }
            Integer emuPerPx = 9525;
            return new List<Integer>{ widthPx * emuPerPx, heightPx * emuPerPx };
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer[] scaleImageDimensionsEmu(
        Integer baseWidthEmu,
        Integer baseHeightEmu,
        ImageRenderSpec spec
    ) {
        Integer pageContentWidthEmu = 5943600; // 6.5in
        Integer pageContentHeightEmu = 8229600; // 9in

        Integer resolvedW = baseWidthEmu;
        Integer resolvedH = baseHeightEmu;

        Integer fixedW = spec.widthPx != null ? (spec.widthPx * 9525) : null;
        if (fixedW == null && spec.widthPercent != null) {
            fixedW = (pageContentWidthEmu * spec.widthPercent) / 100;
        }
        Integer fixedH = spec.heightPx != null ? (spec.heightPx * 9525) : null;
        if (fixedH == null && spec.heightPercent != null) {
            fixedH = (pageContentHeightEmu * spec.heightPercent) / 100;
        }

        if (fixedW != null && fixedW > 0 && fixedH != null && fixedH > 0) {
            resolvedW = fixedW;
            resolvedH = fixedH;
        } else if (fixedW != null && fixedW > 0 && baseWidthEmu > 0) {
            Decimal scale = ((Decimal) fixedW) / ((Decimal) baseWidthEmu);
            resolvedW = fixedW;
            resolvedH = (((Decimal) baseHeightEmu) * scale).intValue();
        } else if (fixedH != null && fixedH > 0 && baseHeightEmu > 0) {
            Decimal scale = ((Decimal) fixedH) / ((Decimal) baseHeightEmu);
            resolvedH = fixedH;
            resolvedW = (((Decimal) baseWidthEmu) * scale).intValue();
        }

        Integer maxW = spec.maxWidthPx != null ? (spec.maxWidthPx * 9525) : null;
        if (maxW == null && spec.maxWidthPercent != null) {
            maxW = (pageContentWidthEmu * spec.maxWidthPercent) / 100;
        }
        Integer maxH = spec.maxHeightPx != null ? (spec.maxHeightPx * 9525) : null;
        if (maxH == null && spec.maxHeightPercent != null) {
            maxH = (pageContentHeightEmu * spec.maxHeightPercent) / 100;
        }

        Decimal maxScale = 1;
        if (maxW != null && maxW > 0 && resolvedW > maxW && resolvedW > 0) {
            Decimal ws = ((Decimal) maxW) / ((Decimal) resolvedW);
            if (ws < maxScale) {
                maxScale = ws;
            }
        }
        if (maxH != null && maxH > 0 && resolvedH > maxH && resolvedH > 0) {
            Decimal hs = ((Decimal) maxH) / ((Decimal) resolvedH);
            if (hs < maxScale) {
                maxScale = hs;
            }
        }
        if (maxScale < 1) {
            resolvedW = (((Decimal) resolvedW) * maxScale).intValue();
            resolvedH = (((Decimal) resolvedH) * maxScale).intValue();
        }

        if (resolvedW == null || resolvedW <= 0) {
            resolvedW = 288 * 12700;
        }
        if (resolvedH == null || resolvedH <= 0) {
            resolvedH = 216 * 12700;
        }
        return new List<Integer>{ resolvedW, resolvedH };
    }

    /**
     * Extracts the first image from rich text HTML.
     * Handles data URIs, Salesforce servlet URLs (via session-based auth), and refid references.
     */
    private static Blob extractImageFromHtml(String html) {
        // Use string parsing instead of regex to avoid "Regex too complicated" on large base64 data
        Integer imgIdx = html.indexOfIgnoreCase('<img');
        if (imgIdx == -1) {
            return null;
        }

        Integer srcIdx = html.indexOfIgnoreCase('src=', imgIdx);
        if (srcIdx == -1) {
            return null;
        }

        srcIdx += 4; // skip 'src='
        // Skip optional whitespace
        while (srcIdx < html.length() && html.substring(srcIdx, srcIdx + 1) == ' ') {
            srcIdx++;
        }

        // Determine quote character
        String quoteChar = html.substring(srcIdx, srcIdx + 1);
        if (quoteChar != '"' && quoteChar != '\'') {
            return null;
        }
        srcIdx++; // skip opening quote

        Integer srcEnd = html.indexOf(quoteChar, srcIdx);
        if (srcEnd == -1) {
            return null;
        }

        String src = html.substring(srcIdx, srcEnd).replace('&amp;', '&');

        // Data URI — decode to blob
        if (src.startsWith('data:image/')) {
            String base64Part = src.substringAfter(',');
            return EncodingUtil.base64Decode(base64Part);
        }

        // Salesforce URLs — can't fetch without session ID (AppExchange limitation).
        // For PDF, Blob.toPdf() resolves these URLs natively via the VF engine.
        // Return null here; the caller will use the URL path for PDF rendering.
        return null;
    }

    // No session-based HTTP fetch methods — AppExchange safe.
    // Blob.toPdf() resolves Salesforce URLs natively via the VF rendering engine.

    /**
     * Fetches image blob from a Salesforce file reference (ContentDocument ID or ContentVersion ID).
     */
    private static Blob fetchSalesforceImage(String fileRef) {
        if (String.isBlank(fileRef)) {
            return null;
        }
        try {
            // Try as ContentVersion ID first
            if (fileRef.startsWith('068')) {
                List<ContentVersion> cvs = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Id = :fileRef
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
            // Try as ContentDocument ID
            if (fileRef.startsWith('069')) {
                List<ContentDocument> docs = [
                    SELECT LatestPublishedVersionId
                    FROM ContentDocument
                    WHERE Id = :fileRef
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!docs.isEmpty() && docs[0].LatestPublishedVersionId != null) {
                    Id latestCvId = docs[0].LatestPublishedVersionId;
                    List<ContentVersion> cvs = [
                        SELECT VersionData
                        FROM ContentVersion
                        WHERE Id = :latestCvId
                        WITH USER_MODE
                        LIMIT 1
                    ];
                    if (!cvs.isEmpty()) {
                        return cvs[0].VersionData;
                    }
                }
            }
            // Try as a generic ID that could be linked
            if (fileRef.length() >= 15) {
                List<ContentVersion> cvs = [
                    SELECT VersionData
                    FROM ContentVersion
                    WHERE Id = :fileRef
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!cvs.isEmpty()) {
                    return cvs[0].VersionData;
                }
            }
        } catch (Exception e) {
            // Intentionally swallowed — image fetch failed (invalid ID, access
            // denied). Continuing is right; the document should not fail over
            // one image. But "access denied" in particular is invisible to the
            // author, who sees a hole and no reason for it, so it is recorded.
            DocGenErrorLogger.warn(
                'DocGenService',
                'Fetch image data',
                'Image omitted — could not be fetched (invalid Id or no access): ' + e.getMessage()
            );
        }
        return null;
    }

    /**
     * True when the merged workbook is macro-enabled (.xlsm). Detected from data
     * already in memory — the macroEnabled workbook content type is the primary
     * signal, the vbaProject.bin part the belt-and-braces backup — so templates
     * uploaded before this feature existed are recognized without a schema change.
     */
    private static Boolean isMacroEnabledWorkbook(MergeResult mr) {
        if (mr == null) {
            return false;
        }
        if (
            mr.contentTypesXml != null &&
            mr.contentTypesXml.contains('application/vnd.ms-excel.sheet.macroEnabled.main+xml')
        ) {
            return true;
        }
        return mr.passthroughEntries != null && mr.passthroughEntries.containsKey('xl/vbaProject.bin');
    }

    /**
     * Names the saved file after the TEMPLATE type, not the merge path. Excel was
     * missing from this map, so a server-side XLSX generation (Flow action, save-
     * to-record queueable, bulk) wrote a valid workbook under a .docx name and
     * every reader rejected it. The runner never showed this because the LWC
     * assembles Office files client-side and picks its own extension.
     * Macro-enabled workbooks must save as .xlsm — Excel refuses to load a VBA
     * project from a file named .xlsx.
     */
    private static Id saveFile(
        Blob fileBlob,
        String title,
        Id recordId,
        String format,
        String type,
        Boolean isMacroEnabled
    ) {
        String baseName = title != null ? title : 'Generated_Document';
        String ext = '.docx';
        if (type == 'PowerPoint') {
            ext = '.pptx';
        } else if (type == 'Excel') {
            ext = isMacroEnabled == true ? '.xlsm' : '.xlsx';
        }
        return saveContentVersion(fileBlob, baseName, baseName + ext, recordId);
    }

    /**
     * Saves a PDF Blob as a ContentVersion attached to the record.
     */
    private static Id savePdfFile(Blob pdfBlob, String title, Id recordId) {
        String baseName = title != null ? title : 'Generated_Document';
        return saveContentVersion(pdfBlob, baseName, baseName + '.pdf', recordId);
    }

    /**
     * Saves a Blob as a ContentVersion linked to the given record.
     * Some standard objects (e.g., Pricebook2) don't support FirstPublishLocationId.
     * In that case, insert without linking and create a ContentDocumentLink separately.
     */
    private static Id saveContentVersion(Blob fileBlob, String title, String fileName, Id recordId) {
        ContentVersion cv = new ContentVersion();
        cv.Title = title;
        cv.PathOnClient = fileName;
        cv.VersionData = fileBlob;
        cv.FirstPublishLocationId = recordId;

        Id savedCvId;
        try {
            SObjectAccessDecision cvDecision = Security.stripInaccessible(
                AccessType.CREATABLE,
                new List<ContentVersion>{ cv }
            );
            insert cvDecision.getRecords();
            savedCvId = cvDecision.getRecords()[0].Id;
        } catch (DmlException dml) {
            // FirstPublishLocationId rejected (e.g., Pricebook2) — insert without link, then create CDL
            if (
                dml.getMessage().contains('FIELD_INTEGRITY_EXCEPTION') &&
                dml.getMessage().containsIgnoreCase('FirstPublishLocationId')
            ) {
                cv.FirstPublishLocationId = null;
                SObjectAccessDecision cvDecision2 = Security.stripInaccessible(
                    AccessType.CREATABLE,
                    new List<ContentVersion>{ cv }
                );
                insert cvDecision2.getRecords();
                savedCvId = cvDecision2.getRecords()[0].Id;

                Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH USER_MODE]
                .ContentDocumentId;
                // Try to link the file to the source record — some objects (e.g. Pricebook2) don't support CDLs
                try {
                    ContentDocumentLink cdl = new ContentDocumentLink(
                        ContentDocumentId = docId,
                        LinkedEntityId = recordId,
                        ShareType = 'V',
                        Visibility = 'AllUsers'
                    );
                    SObjectAccessDecision cdlDec = Security.stripInaccessible(
                        AccessType.CREATABLE,
                        new List<ContentDocumentLink>{ cdl }
                    );
                    insert cdlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
                } catch (DmlException linkErr) {
                    // Intentionally swallowed — object may not support ContentDocumentLink
                    String noop = linkErr.getMessage(); // NOPMD UnusedLocalVariable — satisfies EmptyCatchBlock rule
                }
                return docId;
            }
            throw dml;
        }

        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :savedCvId WITH USER_MODE].ContentDocumentId;
    }
    /**
     * Extracts an attribute value from an XML tag string.
     * E.g., extractXmlAttrValue('<Relationship Id="rId1" Target="media/image1.png"/>', 'Id') returns 'rId1'
     */
    private static String extractXmlAttrValue(String tag, String attrName) {
        String search = attrName + '="';
        Integer start = tag.indexOf(search);
        if (start == -1) {
            return null;
        }
        start += search.length();
        Integer end2 = tag.indexOf('"', start);
        if (end2 == -1) {
            return null;
        }
        return tag.substring(start, end2);
    }

    /**
     * Loads a token-resolution map for a single record, suitable for feeding
     * into generateDocTitle. Walks any `{Field}` or `{Rel.Field}` tokens in the
     * supplied format string and queries only those columns — keeping the SOQL
     * narrow even when the user references a deep relationship like
     * `{Account.Owner.Email}`.
     *
     * Returns an empty map when the record can't be loaded or the format has
     * no tokens. Used by signature packet naming (issue #42).
     */
    public static Map<String, Object> loadRecordDataForTitle(Id recordId, String format) {
        Map<String, Object> out = new Map<String, Object>();
        if (recordId == null) {
            return out;
        }
        // Collect referenced field paths from the format string. If no tokens,
        // return an empty map — the caller will fall back to a static name.
        Set<String> fieldPaths = new Set<String>();
        if (String.isNotBlank(format)) {
            Pattern p = Pattern.compile('\\{([^}]+)\\}');
            Matcher m = p.matcher(format);
            while (m.find()) {
                String tok = m.group(1).trim();
                // Skip built-in special tokens — {Today}, {Now}, {Today: MM/DD/YYYY},
                // {Now: HH:mm} — which generateDocTitle resolves itself. They are NOT
                // SObject fields; querying them broke the dynamic SOQL (the ':' in a date
                // format threw "unexpected token: ':'", failing the whole load so {Name}
                // never resolved — Sarah's "Waiver - Signed" fallback).
                String head = (tok.contains(':') ? tok.substringBefore(':') : tok).trim();
                if (head.equalsIgnoreCase('Today') || head.equalsIgnoreCase('Now')) {
                    continue;
                }
                // Only real field paths (Name, Account.Name) are queryable.
                if (!Pattern.matches('(?i)[a-z_][a-z0-9_]*(\\.[a-z_][a-z0-9_]*)*', tok)) {
                    continue;
                }
                fieldPaths.add(tok);
            }
        }
        if (fieldPaths.isEmpty()) {
            return out;
        }
        try {
            String objType = String.valueOf(recordId.getSObjectType());
            String soql =
                'SELECT Id, ' +
                String.join(new List<String>(fieldPaths), ', ') +
                ' FROM ' +
                objType +
                ' WHERE Id = :recordId LIMIT 1';
            // Bypass sharing for the title field read. The signed-PDF finalize runs as
            // the GUEST signer, who can't see the related record under this class's
            // `with sharing`, so {Name}/{Field} title tokens resolved blank while {Today}
            // (no query) still worked — the file saved as "<base> - Signed" missing the
            // name (Sarah's #2). The document body is already merged in system context,
            // so titling from the same fields is not a new disclosure.
            List<SObject> rows = new TitleRecordReader().query(soql, recordId);
            if (rows.isEmpty()) {
                return out;
            }
            SObject row = rows[0];
            for (String path : fieldPaths) {
                Object val = walkRelationshipPath(row, path);
                if (val == null) {
                    continue;
                }
                // generateDocTitle → resolveValue walks dot-paths through nested
                // Maps. Flat "Account.Name" keys won't resolve. Build nested
                // structure so {Account.Name} traverses out["Account"]["Name"].
                List<String> parts = path.split('\\.');
                if (parts.size() == 1) {
                    out.put(parts[0], val);
                } else {
                    Map<String, Object> cursor = out;
                    for (Integer i = 0; i < parts.size() - 1; i++) {
                        Object child = cursor.get(parts[i]);
                        if (!(child instanceof Map<String, Object>)) {
                            child = new Map<String, Object>();
                            cursor.put(parts[i], child);
                        }
                        cursor = (Map<String, Object>) child;
                    }
                    cursor.put(parts[parts.size() - 1], val);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'loadRecordDataForTitle failed for ' + recordId + ': ' + e.getMessage());
        }
        return out;
    }

    /**
     * `without sharing` reader for document-title field resolution so the read runs
     * in system sharing context even when the caller (the guest signed-PDF finalize)
     * cannot see the record under this class's `with sharing`. Sharing is governed by
     * the class where the SOQL executes, so the read must live here, not in the caller.
     */
    private without sharing class TitleRecordReader {
        public List<SObject> query(String soql, Id recordId) {
            // recordId is bound via the :recordId reference inside soql.
            /* code-analyzer-suppress ApexFlsViolation */
            return Database.query(soql); // NOPMD — title field read, package-internal, sharing-bypassed by design
        }
    }

    /**
     * v1.90 — convenience wrapper: load template format + record data + return
     * formatted title. Used by the Giant Query path and the Giant Query fragment
     * lookup so the multi-part client merge and the saved-to-record CV use the
     * same Document_Title_Format__c evaluation as the standard render path.
     * Returns null if the format is blank or anything fails — callers fall back
     * to a default name in that case.
     */
    public static String computeDocTitle(Id templateId, Id recordId) {
        if (templateId == null || recordId == null) {
            return null;
        }
        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{ 'Document_Title_Format__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tpls = [
                SELECT Document_Title_Format__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (tpls.isEmpty()) {
                return null;
            }
            // v1.97 — prefer the active version's snapshot of Document_Title_Format__c
            // so restoring an older version restores its filename pattern too.
            String fmt = tpls[0].Document_Title_Format__c;
            DocGenFlsGuard.assertAccessible(
                DocGen_Template_Version__c.sObjectType,
                new Set<String>{ 'Document_Title_Format__c', 'Template__c', 'Is_Active__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template_Version__c> snap = [
                SELECT Document_Title_Format__c
                FROM DocGen_Template_Version__c
                WHERE Template__c = :templateId AND Is_Active__c = TRUE
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!snap.isEmpty() && snap[0].Document_Title_Format__c != null) {
                fmt = snap[0].Document_Title_Format__c;
            }
            if (String.isBlank(fmt)) {
                return null;
            }
            Map<String, Object> data = loadRecordDataForTitle(recordId, fmt);
            return generateDocTitle(fmt, data);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'computeDocTitle failed: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Convenience overload — pulls a small set of standard fields without
     * needing a format string up front. Intended for callers that resolve
     * tokens later.
     */
    public static Map<String, Object> loadRecordDataForTitle(Id recordId) {
        if (recordId == null) {
            return new Map<String, Object>();
        }
        // Default: pull Name + try common parent relationship fields. Best-effort.
        try {
            String objType = String.valueOf(recordId.getSObjectType());
            List<SObject> rows = Database.query('SELECT Id, Name FROM ' + objType + ' WHERE Id = :recordId LIMIT 1');
            Map<String, Object> out = new Map<String, Object>();
            if (!rows.isEmpty()) {
                out.put('Name', rows[0].get('Name'));
            }
            return out;
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static Object walkRelationshipPath(SObject row, String path) {
        if (row == null || String.isBlank(path)) {
            return null;
        }
        List<String> parts = path.split('\\.');
        SObject cursor = row;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            try {
                cursor = cursor.getSObject(parts[i]);
            } catch (Exception e) {
                return null;
            }
            if (cursor == null) {
                return null;
            }
        }
        try {
            return cursor.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Resolves a title format string by substituting `{Field}` and `{Rel.Field}`
     * tokens from a record-data map. Returns null when the format is blank.
     * Made @TestVisible public in v1.80 so the signature service can use it
     * to honor the optional Document_Title_Format__c on signature requests
     * (issue #42 — packet naming convention).
     */
    @TestVisible
    public static String generateDocTitle(String format, Map<String, Object> data) {
        if (String.isBlank(format)) {
            return null;
        }
        String result = format;
        Pattern p = Pattern.compile('\\{([^}]+)\\}');
        Matcher m = p.matcher(format);
        while (m.find()) {
            String key = m.group(1);

            // Parse optional format suffix: {Field:format} (e.g. {Today:MM-dd-yyyy}).
            String fieldName = key;
            String dateFormat = null;
            if (key.contains(':')) {
                Integer colonIdx = key.indexOf(':');
                fieldName = key.substring(0, colonIdx).trim();
                dateFormat = key.substring(colonIdx + 1).trim();
            }

            // Built-ins parity with processXml: {Today}, {Now}, {RunningUser.X}.
            // These aren't in the data map so plain resolveValue would return null
            // and the tag would render empty in document titles.
            Object val;
            String upperField = fieldName.toUpperCase();
            if (upperField == 'TODAY') {
                Date td = Date.today();
                val = DateTime.newInstance(td.year(), td.month(), td.day());
            } else if (upperField == 'NOW') {
                val = DateTime.now();
            } else if (upperField.startsWith('RUNNINGUSER.')) {
                val = resolveRunningUserField(fieldName.substring('RunningUser.'.length()));
            } else {
                val = resolveValue(data, fieldName);
            }

            String strVal = '';
            if (val != null) {
                if (dateFormat != null && dateFormat.toLowerCase().trim() == 'label') {
                    strVal = resolvePicklistLabel(data, fieldName, val);
                } else if (dateFormat != null && (val instanceof DateTime || val instanceof Date)) {
                    DateTime dt = val instanceof DateTime
                        ? (DateTime) val
                        : DateTime.newInstance((Date) val, Time.newInstance(0, 0, 0, 0));
                    if (dateFormat.toLowerCase().startsWith('date')) {
                        // {Field:date} or {Field:date:locale}
                        String dateLocale = dateFormat.contains(':')
                            ? dateFormat.substring(dateFormat.indexOf(':') + 1).trim()
                            : UserInfo.getLocale();
                        strVal = dt.format(getLocaleDatePattern(dateLocale));
                    } else {
                        // Forgive the common US-date convention: in Java SimpleDateFormat
                        // uppercase D = day-of-YEAR and uppercase Y = week-YEAR, so an
                        // author writing "MM/DD/YYYY" would otherwise get "06/164/2026".
                        // They almost always mean day-of-month + calendar year, so
                        // normalize D->d and Y->y (M stays uppercase — lowercase m = minutes).
                        String fmt = dateFormat.replace('YYYY', 'yyyy')
                            .replace('YY', 'yy')
                            .replace('DD', 'dd')
                            .replace('D', 'd');
                        strVal = dt.format(fmt);
                    }
                } else if (dateFormat != null && isNumericFormat(dateFormat)) {
                    strVal = formatNumber(val, dateFormat, data);
                } else {
                    strVal = String.valueOf(val);
                }
            }
            result = result.replace('{' + key + '}', strVal);
        }
        return result;
    }

    // =========================================================================
    // Backward-compatibility stubs for removed signature classes.
    // Old orgs may still have DocGenSignatureSenderController and
    // DocGenSignatureService which reference these methods. The stubs
    // exist solely so those old classes compile during package upgrade.
    // They do nothing — signatures have been removed from Portwood.
    // =========================================================================

    /**
     * Merges a template with record data and returns intermediate XML parts + image map.
     * Used by the signature flow to pre-compute merge data and render signed PDFs.
     */
    /**
     * PHD-9 — resolves a template's record Id from its API_Name__c so Flows can
     * reference templates by a stable developer key instead of an
     * environment-specific record Id (sandbox-to-production safe). FLS-guard +
     * SYSTEM_MODE: internal config read on a new packaged field (USER_MODE here
     * breaks the namespaced package build when the build user lacks the permset).
     */
    public static Id templateIdByApiName(String apiName) {
        if (String.isBlank(apiName)) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'API_Name__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> tpls = [
            SELECT Id
            FROM DocGen_Template__c
            WHERE API_Name__c = :apiName
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (tpls.isEmpty()) {
            throw new DocGenException(
                'No Portwood Template found with API Name \'' +
                    apiName +
                    '\'. Set the API Name field on the template, or pass Template ID instead.'
            );
        }
        return tpls[0].Id;
    }

    public static Map<String, Object> mergeTemplateForSignature(Id templateId, String recordIdStr) {
        // Keep {@Signature_*} tags through this merge so the signature service can
        // sentinel-substitute / stamp them; restore the prior value after (normal
        // generation strips them — see preserveSignatureTags / the {@Signature} leak).
        Boolean priorPreserve = preserveSignatureTags;
        preserveSignatureTags = true;
        MergeResult mr;
        try {
            mr = mergeTemplate(templateId, recordIdStr, null, 'PDF');
        } finally {
            preserveSignatureTags = priorPreserve;
        }

        if (mr.templateType == 'PowerPoint') {
            throw new DocGenException('Signature PDF generation is only supported for Word and HTML templates.');
        }

        Map<String, String> pdfImages = buildPdfImageMap(mr, templateId);

        // Prime the HTML renderer's static context so tables using Word "table styles"
        // (which reference styles.xml for borders) render with their borders, and numbered
        // lists render correctly. Side-effect priming covers sync callers that call
        // convertToHtml immediately after. Also return the XMLs in the map so async callers
        // (queueables) can re-prime right before their convertToHtml call — statics can
        // silently fail to survive intermediate calls in some async execution contexts.
        String stylesXml = null;
        String numberingXml = null;
        if (mr.processedXmlEntries != null && mr.processedXmlEntries.containsKey('word/styles.xml')) {
            stylesXml = mr.processedXmlEntries.get('word/styles.xml');
        }
        if (mr.passthroughEntries != null && mr.passthroughEntries.containsKey('word/numbering.xml')) {
            numberingXml = mr.passthroughEntries.get('word/numbering.xml').toString();
        }
        DocGenHtmlRenderer.stylesXml = stylesXml;
        DocGenHtmlRenderer.numberingXml = numberingXml;

        return new Map<String, Object>{
            'documentXml' => mr.documentXml,
            'combinedDocumentXml' => mr.templateType == 'HTML' ? mr.documentXml : combineXmlWithHeadersFooters(mr),
            'templateType' => mr.templateType,
            'relsXml' => mr.relsXml,
            'contentTypesXml' => mr.contentTypesXml,
            'pdfImageMap' => pdfImages,
            'docTitle' => mr.docTitle,
            'stylesXml' => stylesXml,
            'numberingXml' => numberingXml
        };
    }

    /**
     * Same as mergeTemplateForSignature but renders from a caller-supplied data
     * snapshot instead of querying the live record. Used by the M2 signature
     * finalizer so the signed PDF re-renders from the send-time snapshot (immune
     * to record edits between send and sign). Mirrors generatePdfBlobFromData's
     * preloadedRecordDataOverride pattern.
     */
    public static Map<String, Object> mergeTemplateForSignatureFromData(Id templateId, Map<String, Object> dataMap) {
        if (dataMap == null) {
            throw new DocGenException('dataMap cannot be null for snapshot signature render.');
        }
        preloadedRecordDataOverride = dataMap;
        // recordId is null — the override short-circuits SOQL retrieval (see line ~406).
        return mergeTemplateForSignature(templateId, null);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Giant Query helpers — extract, render, and inject pre-rendered loop content
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * Extracts the loop body XML from a template for a specific relationship.
     * Returns the XML between {#relationshipName} and {/relationshipName} tags,
     * plus the surrounding context (before/after the loop) for final assembly.
     * Uses the same loop detection logic as processXml but only extracts — does not render.
     * @param templateXml The raw template XML (e.g., word/document.xml)
     * @param relationshipName The loop tag key (e.g., "Contacts", "OpportunityLineItems")
     * @return Map with keys: 'innerXml', 'beforeLoop', 'afterLoop'
     */
    public static Map<String, String> extractLoopBody(String templateXml, String relationshipName) {
        Map<String, String> result = new Map<String, String>();

        // Merge runs first so we find complete tags
        String xml = mergeRunsInTags(templateXml);

        // Find the opening tag {#relationshipName}
        String openTag = '{#' + relationshipName + '}';
        Integer openIdx = xml.indexOf(openTag);
        if (openIdx == -1) {
            // Try with whitespace variations
            Pattern openPattern = Pattern.compile('\\{\\s*#\\s*' + Pattern.quote(relationshipName) + '\\s*\\}');
            Matcher openMatcher = openPattern.matcher(xml);
            if (openMatcher.find()) {
                openIdx = openMatcher.start();
                openTag = openMatcher.group();
            } else {
                return null;
            }
        }

        Integer contentStart = openIdx + openTag.length();
        Integer sectionEnd = findBalancedEnd(xml, contentStart, relationshipName);
        if (sectionEnd == -1) {
            return null;
        }

        Integer closeTagEnd = xml.indexOf('}', sectionEnd) + 1;

        // Determine container boundaries (same logic as processXml — expand to
        // the nearest valid row/list-item container if applicable). Checks both
        // DOCX <w:tr> and HTML <tr>/<li> containers; whichever is closer and
        // encloses the full {#Rel}...{/Rel} section wins. Safe for both
        // template types because DOCX XML doesn't contain literal <tr>/<li>
        // and HTML doesn't contain <w:tr>.
        Integer containerStart = openIdx;
        Integer containerEnd = closeTagEnd;

        // DOCX <w:tr>
        Integer wTrStart = lastIndexOfTagStart(xml, 'w:tr', openIdx);
        if (wTrStart != -1) {
            Integer wTrEnd = xml.indexOf('</w:tr>', wTrStart);
            Boolean closedBeforeOpen = xml.substring(wTrStart, openIdx).contains('</w:tr>');
            if (!closedBeforeOpen && wTrEnd != -1 && wTrEnd >= closeTagEnd) {
                containerStart = wTrStart;
                containerEnd = wTrEnd + 7; // </w:tr>
            }
        }

        // HTML <tr>
        Integer htmlTrStart = lastIndexOfTagStart(xml, 'tr', openIdx);
        if (htmlTrStart != -1) {
            Integer htmlTrEnd = xml.indexOf('</tr>', htmlTrStart);
            Boolean closedBeforeOpen = xml.substring(htmlTrStart, openIdx).contains('</tr>');
            if (!closedBeforeOpen && htmlTrEnd != -1 && htmlTrEnd >= closeTagEnd) {
                if (containerStart == openIdx || htmlTrStart > containerStart) {
                    containerStart = htmlTrStart;
                    containerEnd = htmlTrEnd + 5; // </tr>
                }
            }
        }

        // HTML <li>
        Integer htmlLiStart = lastIndexOfTagStart(xml, 'li', openIdx);
        if (htmlLiStart != -1) {
            Integer htmlLiEnd = xml.indexOf('</li>', htmlLiStart);
            Boolean closedBeforeOpen = xml.substring(htmlLiStart, openIdx).contains('</li>');
            if (!closedBeforeOpen && htmlLiEnd != -1 && htmlLiEnd >= closeTagEnd) {
                if (containerStart == openIdx || htmlLiStart > containerStart) {
                    containerStart = htmlLiStart;
                    containerEnd = htmlLiEnd + 5; // </li>
                }
            }
        }

        // Build inner XML (container content minus the open/close tags)
        String innerXml = xml.substring(containerStart, containerEnd);
        innerXml = innerXml.replace(openTag, '');
        String closeTag = xml.substring(sectionEnd, closeTagEnd);
        innerXml = innerXml.replace(closeTag, '');

        result.put('innerXml', innerXml);
        result.put('beforeLoop', xml.substring(0, containerStart));
        result.put('afterLoop', xml.substring(containerEnd));

        return result;
    }

    /**
     * Renders the loop body XML for a list of child records.
     * Each record gets its merge tags replaced via processXml, producing repeated content.
     * @param innerXml The loop body template XML (one iteration)
     * @param relationshipName The relationship name (used for context)
     * @param records List of SObject child records to render
     * @param fieldNames List of field API names to include in the data map
     * @return Concatenated rendered XML for all records
     */
    public static String renderLoopBodyForRecords(
        String innerXml,
        String relationshipName,
        List<SObject> records,
        List<String> fieldNames
    ) {
        return renderLoopBodyForRecords(innerXml, relationshipName, records, fieldNames, 0);
    }

    /**
     * As above, continuing {RowNumber} from a running offset.
     *
     * The giant-query path renders its loop in fragments of `batchSize` records per
     * execute(), so each call sees only its own slice. Without the offset every
     * fragment would restart at 1 and a 30,000-row table would count 1..200 over and
     * over — which looks plausible enough on page 1 to ship unnoticed.
     *
     * @param rowNumberOffset Rows already rendered by previous fragments (0 for the first)
     */
    public static String renderLoopBodyForRecords(
        String innerXml,
        String relationshipName,
        List<SObject> records,
        List<String> fieldNames,
        Integer rowNumberOffset
    ) {
        String rendered = '';
        Boolean wantsRowNumber = loopBodyHasRowNumberTag(innerXml);
        Integer rowNumber = (rowNumberOffset == null ? 0 : rowNumberOffset);
        for (SObject rec : records) {
            Map<String, Object> dataMap = new Map<String, Object>();
            for (String field : fieldNames) {
                try {
                    // Handle parent fields (e.g., Product2.Name) — store as nested map
                    // so resolveValue() can traverse: dataMap['Product2']['Name']
                    if (field.contains('.')) {
                        List<String> parts = field.split('\\.');
                        SObject current = rec;
                        for (Integer i = 0; i < parts.size() - 1; i++) {
                            current = current.getSObject(parts[i]);
                            if (current == null) {
                                break;
                            }
                        }
                        Object val = (current != null) ? current.get(parts[parts.size() - 1]) : null;
                        // Build nested map structure for resolveValue traversal
                        Map<String, Object> nested = dataMap;
                        for (Integer i = 0; i < parts.size() - 1; i++) {
                            if (!nested.containsKey(parts[i])) {
                                nested.put(parts[i], new Map<String, Object>());
                            }
                            nested = (Map<String, Object>) nested.get(parts[i]);
                        }
                        nested.put(parts[parts.size() - 1], val);
                    } else {
                        dataMap.put(field, rec.get(field));
                    }
                } catch (Exception e) {
                    dataMap.put(field, null);
                }
            }
            rowNumber++;
            if (wantsRowNumber) {
                // dataMap is built fresh per record here, so it can be written
                // directly — no copy needed as in the in-memory loop path.
                dataMap.put('RowNumber', rowNumber);
            }
            rendered += processXml(innerXml, dataMap);
        }
        return rendered;
    }

    /**
     * Merges a template but injects pre-rendered content for specified relationships
     * instead of processing the loop normally. The pre-rendered content replaces the
     * entire loop section (including container) for each specified relationship.
     * @param templateId The DocGen_Template__c record ID
     * @param recordId The source record ID for parent-level merge tags
     * @param preRenderedLoops Map of relationship name to pre-rendered XML content
     * @param outputFormat The desired output format ('PDF' or 'Native')
     * @return ContentDocumentId of the saved document
     */
    public static Id mergeTemplateWithPreRenderedLoops(
        Id templateId,
        Id recordId,
        Map<String, String> preRenderedLoops,
        String outputFormat
    ) {
        pendingImages = new List<Map<String, Object>>();
        imageCounter = 0;

        Map<String, Object> dataMap;
        try {
            dataMap = DocGenController.generateDocumentData(templateId, recordId);
        } catch (Exception e) {
            throw new DocGenException('Error retrieving template data: ' + e.getMessage());
        }

        String base64File = (String) dataMap.get('templateFile');
        Object dataObj = dataMap.get('data');
        String templateType = (String) dataMap.get('templateType');
        String titleFormat = (String) dataMap.get('titleFormat');

        if (base64File == null) {
            throw new DocGenException('Template file content is missing.');
        }

        Map<String, Object> recordDataMap;
        if (dataObj instanceof Map<String, Object>) {
            recordDataMap = (Map<String, Object>) dataObj;
        } else if (dataObj instanceof SObject) {
            recordDataMap = ((SObject) dataObj).getPopulatedFieldsAsMap();
        } else {
            throw new DocGenException('Invalid data format.');
        }

        // For PDF output, use pre-decomposed path if available
        currentOutputFormat = (outputFormat == 'PDF') ? 'PDF' : 'Native';
        currentTemplateType = templateType;

        MergeResult mr = new MergeResult();
        mr.templateType = templateType;
        mr.outputFormat = outputFormat;
        mr.pageOrientation = (String) dataMap.get('pageOrientation');
        mr.pageSize = (String) dataMap.get('pageSize');
        mr.pageMargins = (String) dataMap.get('pageMargins');
        mr.customMargins = (String) dataMap.get('customMargins');
        mr.relsPath = 'word/_rels/document.xml.rels';
        mr.mediaPath = 'word/media/';

        // Decode template ZIP to get the raw document XML
        Blob templateBlob = EncodingUtil.base64Decode(base64File);
        Compression.ZipReader reader = new Compression.ZipReader(templateBlob);
        String rawDocumentXml = null;

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            if (name == 'word/document.xml') {
                rawDocumentXml = reader.extract(name).toString();
            } else if (name == '[Content_Types].xml') {
                mr.contentTypesXml = reader.extract(name).toString();
            } else if (name == mr.relsPath) {
                mr.relsXml = reader.extract(name).toString();
            } else {
                Boolean isProcessedXml =
                    (name.startsWith('word/header') && name.endsWith('.xml')) ||
                    (name.startsWith('word/footer') && name.endsWith('.xml'));
                if (isProcessedXml) {
                    String xml = mergeRunsInTags(reader.extract(name).toString());
                    xml = processXml(xml, recordDataMap);
                    mr.processedXmlEntries.put(name, xml);
                } else {
                    mr.passthroughEntries.put(name, reader.extract(name));
                }
            }
        }

        if (rawDocumentXml == null) {
            throw new DocGenException('Template does not contain word/document.xml.');
        }

        // Merge runs first, then inject pre-rendered loops before processXml
        rawDocumentXml = mergeRunsInTags(rawDocumentXml);

        // For each pre-rendered relationship, replace the loop section with pre-rendered content
        for (String relName : preRenderedLoops.keySet()) {
            Map<String, String> loopParts = extractLoopBody(rawDocumentXml, relName);
            if (loopParts != null) {
                rawDocumentXml =
                    loopParts.get('beforeLoop') +
                    preRenderedLoops.get(relName) +
                    loopParts.get('afterLoop');
            }
        }

        // Now process remaining merge tags (parent-level fields, other loops)
        String processedXml = processXml(rawDocumentXml, recordDataMap);
        mr.documentXml = processedXml;
        mr.processedXmlEntries.put('word/document.xml', processedXml);

        // Generate document title
        mr.docTitle = generateDocTitle(titleFormat, recordDataMap);
        if (mr.docTitle == null) {
            mr.docTitle = (String) resolveValue(recordDataMap, 'Name');
        }

        // Handle pending images
        if (!pendingImages.isEmpty()) {
            if (mr.contentTypesXml != null) {
                if (!mr.contentTypesXml.contains('Extension="png"')) {
                    mr.contentTypesXml = mr.contentTypesXml.replace(
                        '</Types>',
                        '<Default Extension="png" ContentType="image/png"/></Types>'
                    );
                }
                if (
                    !mr.contentTypesXml.contains('Extension="jpeg"') && !mr.contentTypesXml.contains('Extension="jpg"')
                ) {
                    mr.contentTypesXml = mr.contentTypesXml.replace(
                        '</Types>',
                        '<Default Extension="jpeg" ContentType="image/jpeg"/></Types>'
                    );
                }
            }
            if (mr.relsXml != null) {
                for (Map<String, Object> img : pendingImages) {
                    String relId = (String) img.get('relId');
                    String fName = (String) img.get('fileName');
                    String newRel =
                        '<Relationship Id="' +
                        relId +
                        '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' +
                        fName +
                        '"/>';
                    mr.relsXml = mr.relsXml.replace('</Relationships>', newRel + '</Relationships>');
                }
            }
            for (Map<String, Object> img : pendingImages) {
                String relId = (String) img.get('relId');
                if (img.containsKey('blob')) {
                    mr.imageBase64ByRelId.put(relId, EncodingUtil.base64Encode((Blob) img.get('blob')));
                }
                if (img.containsKey('url')) {
                    mr.imageUrlByRelId.put(relId, (String) img.get('url'));
                }
            }
        }

        // Render to final format
        if (outputFormat == 'PDF' && templateType == 'Word') {
            Blob pdfBlob = renderPdf(mr, templateId, recordId);
            return savePdfFile(pdfBlob, mr.docTitle, recordId);
        }

        Blob resultBlob = assembleZip(mr);
        return saveFile(resultBlob, mr.docTitle, recordId, outputFormat, templateType, isMacroEnabledWorkbook(mr));
    }

    /**
     * HTML template asset extraction (v1.61+).
     * Runs after an HTML-type template version is created. If the uploaded file
     * is a zip (Google Docs "Download → Web Page" format), unpacks it:
     *   - Saves each image entry as a ContentVersion linked to the version
     *     (titled docgen_html_img_<versionId>_<basename>)
     *   - Rewrites <img src="..."> references in the HTML to point at the
     *     saved ContentVersions' /sfc/servlet.shepherd/... relative URLs
     *   - Saves the rewritten HTML as a new ContentVersion and repoints the
     *     version's Content_Version_Id__c at it
     * For single .html uploads there is nothing to extract — the method returns.
     */
    public static void extractAndSaveHtmlTemplateAssets(Id templateId, Id versionId) {
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Type__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty() || templates[0].Type__c != 'HTML') {
            return;
        }

        DocGenFlsGuard.assertAccessible(
            DocGen_Template_Version__c.sObjectType,
            new Set<String>{ 'Content_Version_Id__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template_Version__c> vers = [
            SELECT Id, Content_Version_Id__c
            FROM DocGen_Template_Version__c
            WHERE Id = :versionId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (vers.isEmpty() || String.isBlank(vers[0].Content_Version_Id__c)) {
            return;
        }
        Id sourceCvId = (Id) vers[0].Content_Version_Id__c;

        DocGenFlsGuard.assertAccessible(
            ContentVersion.sObjectType,
            new Set<String>{ 'VersionData', 'FileExtension', 'Title' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<ContentVersion> cvs = [
            SELECT VersionData, FileExtension, Title
            FROM ContentVersion
            WHERE Id = :sourceCvId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (cvs.isEmpty()) {
            return;
        }
        String ext = cvs[0].FileExtension == null ? '' : cvs[0].FileExtension.toLowerCase();
        if (ext != 'zip') {
            return;
        } // .html/.htm uploads have no assets to extract

        Compression.ZipReader reader = new Compression.ZipReader(cvs[0].VersionData);

        String htmlEntryName = null;
        String htmlContent = null;
        Map<String, Blob> imageEntries = new Map<String, Blob>();
        Set<String> imageExts = new Set<String>{ 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tif', 'tiff', 'svg' };

        for (Compression.ZipEntry entry : reader.getEntries()) {
            String name = entry.getName();
            String lower = name.toLowerCase();
            if ((lower.endsWith('.html') || lower.endsWith('.htm')) && htmlEntryName == null) {
                htmlEntryName = name;
                htmlContent = reader.extract(name).toString();
            } else {
                Integer dot = lower.lastIndexOf('.');
                if (dot > 0) {
                    String e = lower.substring(dot + 1);
                    if (imageExts.contains(e)) {
                        imageEntries.put(name, reader.extract(name));
                    }
                }
            }
        }

        if (String.isBlank(htmlContent)) {
            throw new DocGenException('HTML template zip has no .html file.');
        }

        // 1. Insert each image as a ContentVersion, collect originalPath → CV map
        List<ContentVersion> imageCvs = new List<ContentVersion>();
        Map<String, Integer> nameToIndex = new Map<String, Integer>();
        String imgPrefix = 'docgen_html_img_' + versionId + '_';
        Integer idx = 0;
        for (String name : imageEntries.keySet()) {
            String base = name.substringAfterLast('/');
            if (String.isBlank(base)) {
                base = name;
            }
            ContentVersion icv = new ContentVersion();
            icv.Title = imgPrefix + base;
            icv.PathOnClient = base;
            icv.VersionData = imageEntries.get(name);
            icv.FirstPublishLocationId = versionId;
            imageCvs.add(icv);
            nameToIndex.put(name, idx);
            idx++;
        }
        if (!imageCvs.isEmpty()) {
            SObjectAccessDecision imgDec = Security.stripInaccessible(AccessType.CREATABLE, imageCvs);
            insert imgDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
            // Update local list so subsequent ID reads in step 2 see the assigned IDs
            imageCvs = imgDec.getRecords();
        }

        // 2. Rewrite every referenced image path in the HTML to its CV URL
        String rewritten = htmlContent;
        if (!imageCvs.isEmpty()) {
            List<Id> reloadIds = new List<Id>();
            for (ContentVersion icv : imageCvs) {
                reloadIds.add(icv.Id);
            }
            DocGenFlsGuard.assertAccessible(ContentVersion.sObjectType, new Set<String>());
            /* code-analyzer-suppress ApexFlsViolation */
            Map<Id, ContentVersion> byId = new Map<Id, ContentVersion>(
                [SELECT Id FROM ContentVersion WHERE Id IN :reloadIds WITH SYSTEM_MODE]
            );
            for (String originalPath : imageEntries.keySet()) {
                Integer i = nameToIndex.get(originalPath);
                if (i == null) {
                    continue;
                }
                Id cvId = imageCvs[i].Id;
                if (cvId == null) {
                    continue;
                }
                String url = '/sfc/servlet.shepherd/version/download/' + cvId;
                String basePath = originalPath.substringAfterLast('/');
                // Google Docs most often writes src="images/foo.png". Replace
                // the full path first, then the bare basename as a fallback.
                rewritten = rewritten.replace('"' + originalPath + '"', '"' + url + '"');
                rewritten = rewritten.replace('\'' + originalPath + '\'', '\'' + url + '\'');
                if (String.isNotBlank(basePath) && basePath != originalPath) {
                    rewritten = rewritten.replace('"' + basePath + '"', '"' + url + '"');
                    rewritten = rewritten.replace('\'' + basePath + '\'', '\'' + url + '\'');
                }
            }
        }

        // 3. Save rewritten HTML as a new ContentVersion; repoint the version at it
        ContentVersion htmlCv = new ContentVersion();
        htmlCv.Title = 'docgen_html_body_' + versionId;
        htmlCv.PathOnClient = 'docgen_html_body_' + versionId + '.html';
        htmlCv.VersionData = Blob.valueOf(rewritten);
        htmlCv.FirstPublishLocationId = versionId;
        SObjectAccessDecision htmlDec = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<ContentVersion>{ htmlCv }
        );
        insert htmlDec.getRecords(); // NOPMD ApexCRUDViolation — FLS enforced by stripInaccessible
        Id htmlCvId = htmlDec.getRecords()[0].Id;

        // Package-internal custom object update — CRUD gated by DocGen_Admin permset on the
        // controller side. Direct update preserves the field write; stripInaccessible would
        // strip Content_Version_Id__c when run by a profile that doesn't have explicit FLS,
        // silently no-op'ing the repoint and leaving the version pointing at the zip.
        DocGen_Template_Version__c upd = new DocGen_Template_Version__c(
            Id = versionId,
            Content_Version_Id__c = htmlCvId
        );
        update upd; // NOPMD ApexCRUDViolation — package-internal custom object; CRUD via Portwood permsets
    }

    // =====================================================================
    // HTML Template Pipeline (v1.61+)
    //
    // HTML-type templates are raw .html files (exported from Google Docs,
    // Notion, etc.) with merge tags. Pipeline:
    //   1. Decode base64 ContentVersion → HTML string
    //   2. Extract <body> content + preserve <style> block
    //   3. Run processXml on body + Header_Html__c + Footer_Html__c fields
    //   4. Substitute {PageNumber}/{TotalPages} → CSS counter spans
    //   5. Wrap with @page margin boxes for Flying Saucer (Blob.toPdf engine)
    //   6. Return MergeResult with full HTML in documentXml; renderPdf() sees
    //      templateType='HTML' and passes documentXml straight to Blob.toPdf.
    // =====================================================================
    private static MergeResult mergeHtmlTemplate(
        MergeResult mr,
        String base64File,
        Map<String, Object> recordDataMap,
        String headerHtml,
        String footerHtml,
        String titleFormat
    ) {
        Blob htmlBlob = EncodingUtil.base64Decode(base64File);
        String rawHtml = htmlBlob.toString();

        String sourceStyles = extractHtmlStyleBlocks(rawHtml);
        String bodyContent = extractHtmlBodyContent(rawHtml);

        // A <style> block INSIDE <body> has to come out before the merge runs.
        //
        // extractHtmlStyleBlocks already copied it into sourceStyles, and
        // wrapHtmlForPdf re-emits that in <head>, so the CSS is not lost. What was
        // lost is everything between the braces: processXml treats every {...} pair as
        // a merge tag, so `body { font-family: Helvetica; }` resolves to nothing and
        // the selector is left behind as literal text. The document then prints a line
        // of bare selectors above its first heading —
        // "@page body h1 h2 ... .docgen-body-content .tab" — which is what a customer
        // reported and what this reproduces exactly.
        //
        // Google Docs and Notion exports put <style> in the body routinely, and so
        // does re-uploading a previously generated document, which is why the leaked
        // selectors in that report were Portwood's own docgen-* classes.
        //
        // Header and footer get the same treatment, and their styles are hoisted into
        // sourceStyles rather than dropped — stripping without hoisting would fix the
        // stray text by silently discarding the author's CSS.
        bodyContent = stripStyleAndScriptBlocks(bodyContent);

        String headerSrc = String.isBlank(headerHtml) ? null : decodeBraceEntities(headerHtml);
        String footerSrc = String.isBlank(footerHtml) ? null : decodeBraceEntities(footerHtml);
        if (String.isNotBlank(headerSrc)) {
            sourceStyles += '\n' + extractHtmlStyleBlocks(headerSrc);
            headerSrc = stripStyleAndScriptBlocks(headerSrc);
        }
        if (String.isNotBlank(footerSrc)) {
            sourceStyles += '\n' + extractHtmlStyleBlocks(footerSrc);
            footerSrc = stripStyleAndScriptBlocks(footerSrc);
        }

        String mergedBody = processXml(bodyContent, recordDataMap);
        String mergedHeader = headerSrc == null ? null : processXml(headerSrc, recordDataMap);
        String mergedFooter = footerSrc == null ? null : processXml(footerSrc, recordDataMap);

        // Convert {*Field:qr} / {*Field:code128} barcode markers (emitted by
        // processXml as ##BARCODE:...##) into inline CSS so they render in
        // HTML-template PDFs. The Word path does this per text-run; HTML bodies
        // are already HTML, so swap only the marker (no surrounding escaping).
        mergedBody = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(mergedBody);
        mergedHeader = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(mergedHeader);
        mergedFooter = DocGenHtmlRenderer.replaceBarcodeMarkersInHtml(mergedFooter);

        // 1.68 — set the renderer overrides BEFORE wrapping so wrapHtmlForPdf can
        // call computePageCss() and pick up the size/orientation/margins from
        // the merge result. Statics are cleared in renderPdf's finally block.
        DocGenHtmlRenderer.orientationOverride = mr.pageOrientation;
        DocGenHtmlRenderer.pageSizeOverride = mr.pageSize;
        DocGenHtmlRenderer.marginsOverride = mr.pageMargins;
        DocGenHtmlRenderer.customMarginsOverride = mr.customMargins;
        mr.documentXml = wrapHtmlForPdf(mergedBody, sourceStyles, mergedHeader, mergedFooter);

        String title = generateDocTitle(titleFormat, recordDataMap);
        if (String.isBlank(title)) {
            Object nameVal = resolveValue(recordDataMap, 'Name');
            title = (nameVal != null) ? String.valueOf(nameVal) : 'Document';
        }
        mr.docTitle = title;
        return mr;
    }

    /**
     * Removes <style> and <script> elements, contents and all.
     *
     * Their text is never document content. A <style> that reaches processXml has every
     * declaration eaten — `{...}` is merge-tag syntax — and prints its selectors on the
     * page; a <script> would print its source. Callers must hoist any CSS they still
     * want into the stylesheet BEFORE calling this, or it is gone.
     */
    @TestVisible
    private static String stripStyleAndScriptBlocks(String html) {
        if (String.isBlank(html)) {
            return html;
        }
        return html.replaceAll('(?is)<style[^>]*>.*?</style\\s*>', '')
            .replaceAll('(?is)<script[^>]*>.*?</script\\s*>', '');
    }

    /**
     * Extracts and concatenates the contents of all <style> blocks from HTML source.
     * Preserves Google Docs / Notion / Word HTML class-based styling in the PDF.
     */
    public static String extractHtmlStyleBlocks(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String result = '';
        Integer cursor = 0;
        String lower = html.toLowerCase();
        while (cursor < html.length()) {
            Integer start = lower.indexOf('<style', cursor);
            if (start == -1) {
                break;
            }
            Integer openEnd = html.indexOf('>', start);
            if (openEnd == -1) {
                break;
            }
            Integer closeStart = lower.indexOf('</style>', openEnd);
            if (closeStart == -1) {
                break;
            }
            result += html.substring(openEnd + 1, closeStart) + '\n';
            cursor = closeStart + 8;
        }
        return result;
    }

    /**
     * Returns content inside <body>...</body>, or the whole string if no body tag.
     * Handles common HTML export wrappers (<html>, <head>) from Google Docs, Notion, Word, etc.
     */
    public static String extractHtmlBodyContent(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String lower = html.toLowerCase();
        Integer bodyOpen = lower.indexOf('<body');
        if (bodyOpen == -1) {
            Integer htmlClose = lower.indexOf('</html>');
            Integer headClose = lower.indexOf('</head>');
            Integer start = (headClose != -1) ? (html.indexOf('>', headClose) + 1) : 0;
            Integer endPos = (htmlClose != -1) ? htmlClose : html.length();
            if (start >= endPos) {
                return html;
            }
            return html.substring(start, endPos);
        }
        Integer openEnd = html.indexOf('>', bodyOpen);
        if (openEnd == -1) {
            return html;
        }
        Integer bodyClose = lower.lastIndexOf('</body>');
        if (bodyClose == -1 || bodyClose <= openEnd) {
            return html.substring(openEnd + 1);
        }
        return html.substring(openEnd + 1, bodyClose);
    }

    /**
     * No-op — retained for backward compatibility. Page-counter tokens are now
     * preserved through processXml and resolved by wrapHtmlForPdf's @page CSS.
     */
    public static String substituteHtmlPageCounters(String html) {
        return html;
    }

    /**
     * Decodes HTML-entity-encoded curly braces back to literal `{` / `}`.
     * lightning-input-rich-text (and other WYSIWYG editors) sometimes emit
     * `&#123;` / `&#125;` / `&lbrace;` / `&rbrace;` around authored merge
     * tags; processXml only matches literal braces, so un-encode before merge.
     */
    public static String decodeBraceEntities(String html) {
        if (String.isBlank(html)) {
            return html;
        }
        return html
            .replace('&#123;', '{')
            .replace('&#x7B;', '{')
            .replace('&#x7b;', '{')
            .replace('&lbrace;', '{')
            .replace('&#125;', '}')
            .replace('&#x7D;', '}')
            .replace('&#x7d;', '}')
            .replace('&rbrace;', '}');
    }

    /**
     * Wraps merged body + header + footer into a full HTML document for
     * Flying Saucer PDF rendering.
     *
     * Page counters ({PageNumber} / {TotalPages}) are only resolvable inside
     * @page rules, so headers/footers containing those tokens get their text
     * rendered via @page margin box `content` property with counter(page) /
     * counter(pages) calls. Side effect: inline markup (images, tables,
     * formatting) in such a header/footer is flattened to plain text, which
     * is a Flying Saucer limitation.
     *
     * Headers/footers without page counters use the CSS running element
     * pattern (position: running(name) + @page { @top-center: element(name) })
     * which preserves arbitrary HTML.
     */
    public static String wrapHtmlForPdf(String body, String sourceStyles, String header, String footer) {
        Boolean headerHasCounters = hasPageCounterTokens(header);
        Boolean footerHasCounters = hasPageCounterTokens(footer);
        // v1.90 — when the source HTML already declares @page, suppress the engine's
        // size/margin so author CSS wins cleanly. Header/footer margin-box rules are
        // still emitted because the source @page can't supply them on its own.
        Boolean sourceHasPageRule = hasSourcePageRule(sourceStyles);

        // #243 — v1.90's "source always wins" was too broad. A Word template carries its
        // orientation in <w:sectPr>, NOT in markup, so admins set Page_Orientation__c on
        // the template record; after a Word→HTML conversion the converted HTML's own
        // @page then silently discarded that choice and every landscape template came out
        // portrait. Precedence is now: explicit record override → source @page → engine
        // default. "Explicit" means a NON-DEFAULT picklist value (Landscape / Legal / A4),
        // because Portrait+Letter are the field defaults and are indistinguishable from
        // "admin never touched this" — deferring on those preserves v1.90 (#60, #71).
        Boolean explicitPageOverride = hasExplicitPageOverride();
        // The engine's <style> is emitted BEFORE sourceStyles, so simply adding our @page
        // would lose the cascade to the author's. Strip the competing declaration instead
        // and leave everything else the author wrote intact.
        if (explicitPageOverride && sourceHasPageRule) {
            sourceStyles = stripSourcePageDecl(sourceStyles, 'size');
            if (hasExplicitMarginOverride()) {
                sourceStyles = stripSourcePageDecl(sourceStyles, 'margin');
            }
            sourceHasPageRule = false;
        }

        // 1.68 — when admin set Page_Size__c or Page_Orientation__c, emit explicit
        // inch dimensions. Otherwise fall back to "size: letter" (the v1.61–1.67
        // default) for backward compat. Never mix dimensions with the `landscape`
        // keyword — invalid CSS, Flying Saucer silently falls back to portrait.
        String sizeCss;
        String marginsCss;
        if (
            String.isNotBlank(DocGenHtmlRenderer.pageSizeOverride) ||
            String.isNotBlank(DocGenHtmlRenderer.orientationOverride)
        ) {
            String size = String.isNotBlank(DocGenHtmlRenderer.pageSizeOverride)
                ? DocGenHtmlRenderer.pageSizeOverride
                : 'Letter';
            Boolean isLandscape = 'Landscape'.equalsIgnoreCase(DocGenHtmlRenderer.orientationOverride);
            Decimal portraitW;
            Decimal portraitH;
            if ('Legal'.equalsIgnoreCase(size)) {
                portraitW = 8.5;
                portraitH = 14.0;
            } else if ('A4'.equalsIgnoreCase(size)) {
                portraitW = 8.27;
                portraitH = 11.69;
            } else {
                portraitW = 8.5;
                portraitH = 11.0;
            }
            Decimal pageW = isLandscape ? portraitH : portraitW;
            Decimal pageH = isLandscape ? portraitW : portraitH;
            sizeCss = pageW + 'in ' + pageH + 'in';
            marginsCss = resolveMarginsCss(size, isLandscape);
        } else {
            sizeCss = 'letter';
            marginsCss = 'margin: 1in';
        }

        String css = '';
        Boolean hasHeader = String.isNotBlank(header);
        Boolean hasFooter = String.isNotBlank(footer);
        // A running element lives in the @page margin box, and that box is exactly as
        // tall as the margin. Content taller than it overflows and paints over the
        // body — a logo or a multi-line address block in the header landed on top of
        // the document's first section. Word grows the header area and pushes the body
        // down; this is the equivalent.
        Boolean emitMarginsOverSourcePage = false;
        String growHeader = hasHeader && !headerHasCounters ? header : null;
        String growFooter = hasFooter && !footerHasCounters ? footer : null;
        if (!sourceHasPageRule) {
            marginsCss = growMarginsForRunningChrome(marginsCss, growHeader, growFooter);
        } else if (growHeader != null || growFooter != null) {
            // The author owns @page — but a running header that overflows its margin
            // box is a CORRECTNESS failure, not a style preference, and v1.90's
            // "source wins" was never meant to cover it. Read the author's own
            // margins, and only if the chrome genuinely does not fit, strip their
            // margin declaration and re-emit it with the top/bottom raised. Their
            // page size and left/right margins are preserved exactly.
            List<Decimal> src = parseSourcePageMargins(sourceStyles);
            if (src != null) {
                String grown = growMarginsForRunningChrome(
                    'margin: ' + src[0] + 'in ' + src[1] + 'in ' + src[2] + 'in ' + src[3] + 'in',
                    growHeader,
                    growFooter
                );
                if (grown.contains('margin-top:') || grown.contains('margin-bottom:')) {
                    sourceStyles = stripSourcePageDecl(sourceStyles, 'margin');
                    marginsCss = grown;
                    emitMarginsOverSourcePage = true;
                }
            }
        }
        if (!sourceHasPageRule || hasHeader || hasFooter) {
            css = '@page {';
            if (!sourceHasPageRule) {
                css += ' size: ' + sizeCss + '; ' + marginsCss + ';';
            } else if (emitMarginsOverSourcePage) {
                // Margins only — the author's `size` is untouched. Their own margin
                // declaration was stripped above, so this is the only one left and
                // there is no cascade to lose.
                css += ' ' + marginsCss + ';';
            }
            if (hasHeader) {
                if (headerHasCounters) {
                    css +=
                        ' @top-center { ' +
                        buildPageMarginContentCss(header) +
                        ' vertical-align: bottom; font-family: Arial, Helvetica, "Arial Unicode MS", sans-serif; font-size: 9pt; color: #444; }';
                } else {
                    css += ' @top-center { content: element(dgheader); vertical-align: bottom; }';
                }
            }
            if (hasFooter) {
                if (footerHasCounters) {
                    css +=
                        ' @bottom-center { ' +
                        buildPageMarginContentCss(footer) +
                        ' vertical-align: top; font-family: Arial, Helvetica, "Arial Unicode MS", sans-serif; font-size: 9pt; color: #444; }';
                } else {
                    css += ' @bottom-center { content: element(dgfooter); vertical-align: top; }';
                }
            }
            css += ' }';
        }
        if (String.isNotBlank(header) && !headerHasCounters) {
            css += ' .docgen-running-header { position: running(dgheader); }';
        }
        if (String.isNotBlank(footer) && !footerHasCounters) {
            css += ' .docgen-running-footer { position: running(dgfooter); }';
        }
        css += ' body { font-family: Arial, Helvetica, "Arial Unicode MS", sans-serif; font-size: 11pt; line-height: 1.4; color: #000; margin: 0; }';
        // v1.97 — no global max-width on images; inline width/height takes precedence.
        css += ' table { border-collapse: collapse; }';
        // #245 — an unbreakable token (URL, record Id, no-spaces reference code) otherwise
        // runs straight through the cell border. Emitted in the ENGINE stylesheet, ahead of
        // sourceStyles, so an author who wants the old behavior can still override it.
        css += ' td, th { word-wrap: break-word; overflow-wrap: break-word; }';

        String html = '<html><head><meta charset="utf-8"/>';
        html += '<style>' + css + '</style>';
        if (String.isNotBlank(sourceStyles)) {
            html += '<style>' + sourceStyles + '</style>';
        }
        html += '</head><body>';
        if (String.isNotBlank(header) && !headerHasCounters) {
            html += '<div class="docgen-running-header">' + clampRunningImages(header) + '</div>';
        }
        if (String.isNotBlank(footer) && !footerHasCounters) {
            html += '<div class="docgen-running-footer">' + clampRunningImages(footer) + '</div>';
        }
        html += wrapNonLatinGlyphs(body == null ? '' : body);
        html += '</body></html>';
        return html;
    }

    /** Height the clamp gives an unsized running image, in inches. */
    private static final Decimal RUNNING_IMG_CLAMP_IN = 0.45;
    /** Rough line box for chrome text at the 9–11pt sizes headers use, in inches. */
    private static final Decimal CHROME_LINE_IN = 0.17;
    /** Breathing room between the running element and the body text below it. */
    private static final Decimal CHROME_GUTTER_IN = 0.15;

    /**
     * Grow the top/bottom page margins so the running header/footer actually fits.
     *
     * The margin box is exactly as tall as the margin, so anything taller overflows
     * and paints over the body. Returns the margin shorthand with explicit
     * margin-top / margin-bottom appended — same rule, later declaration wins — and
     * only when the chrome needs more room than the author's margin already gives it.
     */
    @TestVisible
    private static String growMarginsForRunningChrome(String marginsCss, String header, String footer) {
        Decimal needTop = estimateChromeHeightIn(header);
        Decimal needBottom = estimateChromeHeightIn(footer);
        if (needTop <= 0 && needBottom <= 0) {
            return marginsCss;
        }
        List<Decimal> sides = parseMarginShorthandIn(marginsCss);
        String out = marginsCss;
        if (needTop > 0) {
            Decimal want = (needTop + CHROME_GUTTER_IN).setScale(2, System.RoundingMode.UP);
            if (want > sides[0]) {
                // Leading separator, no trailing one: the caller appends the ';'
                // that closes the whole declaration list. Getting this wrong emitted
                // `margin: 1in margin-top: 1.35in;;` — invalid CSS that Flying Saucer
                // drops silently, taking the page size with it.
                out += '; margin-top: ' + want + 'in';
            }
        }
        if (needBottom > 0) {
            Decimal want = (needBottom + CHROME_GUTTER_IN).setScale(2, System.RoundingMode.UP);
            if (want > sides[2]) {
                out += '; margin-bottom: ' + want + 'in';
            }
        }
        return out;
    }

    /**
     * [top, right, bottom, left] in inches from the SOURCE stylesheet's own @page
     * margin, or null when it declares none (in which case there is nothing to
     * preserve and nothing to compare the chrome against).
     *
     * Handles the units templates actually use. A margin in a unit we cannot read
     * returns null rather than a wrong number — better to leave the author's page
     * alone than to rewrite it from a bad measurement.
     */
    @TestVisible
    private static List<Decimal> parseSourcePageMargins(String styles) {
        if (String.isBlank(styles)) {
            return null;
        }
        Matcher block = Pattern.compile('(?is)@page[^\\{]*\\{([^\\}]*)\\}').matcher(styles);
        if (!block.find()) {
            return null;
        }
        Matcher decl = Pattern.compile('(?i)(?:^|;)\\s*margin\\s*:([^;\\}]*)').matcher(block.group(1));
        if (!decl.find()) {
            return null;
        }
        List<Decimal> vals = new List<Decimal>();
        Matcher num = Pattern.compile('(?i)([0-9]*\\.?[0-9]+)\\s*(in|pt|px|cm|mm)').matcher(decl.group(1));
        while (num.find()) {
            vals.add(toInches(Decimal.valueOf(num.group(1)), num.group(2).toLowerCase()));
        }
        if (vals.isEmpty()) {
            return null;
        }
        Decimal t = vals[0];
        Decimal r = vals.size() >= 2 ? vals[1] : t;
        Decimal b = vals.size() >= 3 ? vals[2] : t;
        Decimal l = vals.size() >= 4 ? vals[3] : r;
        return new List<Decimal>{ t, r, b, l };
    }

    /** [top, right, bottom, left] from a `margin: …in` shorthand, CSS expansion rules. */
    private static List<Decimal> parseMarginShorthandIn(String marginsCss) {
        List<Decimal> vals = new List<Decimal>();
        Matcher m = Pattern.compile('([0-9]*\\.?[0-9]+)\\s*in').matcher(marginsCss == null ? '' : marginsCss);
        while (m.find()) {
            vals.add(Decimal.valueOf(m.group(1)));
        }
        if (vals.isEmpty()) {
            return new List<Decimal>{ 1.0, 1.0, 1.0, 1.0 };
        }
        Decimal t = vals[0];
        Decimal r = vals.size() >= 2 ? vals[1] : t;
        Decimal b = vals.size() >= 3 ? vals[2] : t;
        Decimal l = vals.size() >= 4 ? vals[3] : r;
        return new List<Decimal>{ t, r, b, l };
    }

    /**
     * How tall a running header/footer will render, in inches.
     *
     * Apex cannot measure a layout, so this is an estimate — but a bounded one, and
     * far better than the previous assumption that chrome always fits whatever
     * margin the template happened to specify. Images and text in a header normally
     * sit SIDE BY SIDE (logo left, address right), so the height is the taller of
     * the two rather than their sum.
     */
    @TestVisible
    private static Decimal estimateChromeHeightIn(String chrome) {
        if (String.isBlank(chrome)) {
            return 0;
        }
        // A TABLE stacks: its rows sit one under another, so its height is the SUM
        // of its rows, not the tallest thing in it. Treating a table like a
        // paragraph is what let a multi-row header table overlap the body exactly
        // the way an oversized logo did.
        if (chrome.containsIgnoreCase('<tr')) {
            return estimateStackedRowsIn(chrome);
        }
        Decimal tallestImage = 0;
        Matcher im = Pattern.compile('(?i)<img\\b[^>]*>').matcher(chrome);
        while (im.find()) {
            Decimal h = imageHeightIn(im.group());
            if (h > tallestImage) {
                tallestImage = h;
            }
        }
        // Every block start is a new line; <br> likewise. Starts at one for the
        // text that precedes any markup.
        Integer lines = 1;
        Matcher bm = Pattern.compile('(?i)<(?:p|div|br|h[1-6])\\b').matcher(chrome);
        while (bm.find()) {
            lines++;
        }
        Decimal textHeight = lines * CHROME_LINE_IN;
        return tallestImage > textHeight ? tallestImage : textHeight;
    }

    /**
     * Height of chrome containing a table: the sum of its rows.
     *
     * Within one row, content sits side by side, so the row is as tall as its
     * tallest cell — the same "beside, not below" rule used for a logo next to
     * text. Anything outside the rows is added on top, since it stacks with them.
     */
    private static Decimal estimateStackedRowsIn(String chrome) {
        Decimal total = 0;
        Matcher rows = Pattern.compile('(?is)<tr\\b[^>]*>(.*?)</tr\\s*>').matcher(chrome);
        String outsideRows = chrome;
        while (rows.find()) {
            String row = rows.group(1);
            outsideRows = outsideRows.replace(rows.group(), '');
            Decimal tallest = CHROME_LINE_IN;
            Matcher im = Pattern.compile('(?i)<img\\b[^>]*>').matcher(row);
            while (im.find()) {
                Decimal h = imageHeightIn(im.group());
                if (h > tallest) {
                    tallest = h;
                }
            }
            // Cell padding and borders — a table row is never as tight as a bare
            // line of text.
            total += tallest + 0.06;
        }
        // Whatever sits outside the table (a title above it, a note below) stacks.
        String stripped = outsideRows.replaceAll('(?is)<table\\b[^>]*>|</table\\s*>', '');
        if (String.isNotBlank(stripped.replaceAll('(?is)<[^>]+>', '').trim())) {
            total += estimateChromeHeightIn(stripped);
        }
        return total;
    }

    /** An <img>'s effective height in inches — author sizing, else a safe floor. */
    private static Decimal imageHeightIn(String tag) {
        Matcher sm = Pattern.compile('(?i)(?:^|[;\\s"\'])height\\s*:\\s*([0-9]*\\.?[0-9]+)\\s*(in|pt|px|cm|mm)')
            .matcher(tag);
        if (sm.find()) {
            return toInches(Decimal.valueOf(sm.group(1)), sm.group(2).toLowerCase());
        }
        Matcher am = Pattern.compile('(?i)\\sheight\\s*=\\s*["\']?([0-9]*\\.?[0-9]+)').matcher(tag);
        if (am.find()) {
            return toInches(Decimal.valueOf(am.group(1)), 'px');
        }
        // Width set but height auto — the height lives in the image file and nothing
        // here can read it without loading the blob (which the zero-heap PDF path
        // exists to avoid). Assume SQUARE: it is a floor, not a guess, and it is
        // wrong only in the safe direction for anything wider than it is tall. The
        // Designer records the real height on insert/resize, so this is the fallback
        // for hand-authored templates, not the normal path.
        Matcher wm = Pattern.compile('(?i)(?:^|[;\\s"\'])width\\s*:\\s*([0-9]*\\.?[0-9]+)\\s*(in|pt|px|cm|mm)')
            .matcher(tag);
        if (wm.find()) {
            return toInches(Decimal.valueOf(wm.group(1)), wm.group(2).toLowerCase());
        }
        Matcher wa = Pattern.compile('(?i)\\swidth\\s*=\\s*["\']?([0-9]*\\.?[0-9]+)').matcher(tag);
        if (wa.find()) {
            return toInches(Decimal.valueOf(wa.group(1)), 'px');
        }
        // Fully unsized — clampRunningImages will give it this height.
        return RUNNING_IMG_CLAMP_IN;
    }

    private static Decimal toInches(Decimal v, String unit) {
        if (unit == 'in') {
            return v;
        }
        if (unit == 'pt') {
            return v / 72;
        }
        if (unit == 'cm') {
            return v / 2.54;
        }
        if (unit == 'mm') {
            return v / 25.4;
        }
        return v / 96; // px
    }

    /**
     * Running header/footer images with no author sizing render at intrinsic
     * size — a full-resolution logo overflows the margin box across the whole
     * page. Give unsized <img> tags an explicit height (Flying Saucer's
     * reliable sizing lever; width follows the aspect ratio). Author-sized
     * images (width/height attribute or style) are left untouched.
     */
    @TestVisible
    private static String clampRunningImages(String chrome) {
        if (String.isBlank(chrome) || !chrome.toLowerCase().contains('<img')) {
            return chrome;
        }
        Matcher m = Pattern.compile('(?i)<img\\b[^>]*>').matcher(chrome);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            out += chrome.substring(last, m.start());
            String tag = m.group();
            Boolean sizedAttr = Pattern.compile('(?i)\\s(width|height)\\s*=').matcher(tag).find();
            // The property must start at a declaration boundary. Without the boundary
            // this matched the `width:` INSIDE `max-width:` — and max-width is exactly
            // what the Designer puts on an asset image that the author never sized. The
            // image was therefore treated as author-sized, skipped the clamp, and
            // rendered at full intrinsic height: a logo that overflowed the top margin
            // box and collided with the body on every page.
            // The property must be a declaration START: either first in the style
            // attribute, or preceded by a `;` / whitespace. Matching it anywhere hit
            // the `width:` INSIDE `max-width:` — and max-width is exactly what the
            // Designer puts on an asset image the author never sized, so the image
            // was treated as author-sized, skipped the clamp, and rendered at full
            // intrinsic height: a logo that overflowed the top margin box and painted
            // over the body on every page.
            Boolean sizedStyle = Pattern.compile('(?i)style\\s*=\\s*["\'](?:[^"\']*[;\\s])?(width|height)\\s*:')
                .matcher(tag)
                .find();
            if (!sizedAttr && !sizedStyle) {
                if (Pattern.compile('(?i)style\\s*=\\s*["\']').matcher(tag).find()) {
                    tag = tag.replaceFirst('(?i)style\\s*=\\s*(["\'])', 'style=$1height:0.45in;');
                } else {
                    tag = tag.replaceFirst('(?i)<img\\b', '<img style="height:0.45in"');
                }
            }
            out += tag;
            last = m.end();
        }
        out += chrome.substring(last);
        return out;
    }

    // Flying Saucer's default fonts (Helvetica/Times/Courier) cover Latin-1 plus a
    // small allowlist of General Punctuation (smart quotes, dashes, bullet, ellipsis,
    // trademark, euro). Everything else — Greek, CJK, Hebrew, Arabic, math operators,
    // ₹ rupee, checkboxes — must be wrapped in an inline 'Arial Unicode MS' span.
    // Body-level font-family fallback is ignored by Flying Saucer; only inline spans work.
    @TestVisible
    private static String wrapNonLatinGlyphs(String s) {
        if (String.isBlank(s))
            return s;
        s = decodeHighCodepointEntities(s);
        Integer len = s.length();
        Boolean needsWrap = false;
        for (Integer i = 0; i < len; i++) {
            if (codepointNeedsUnicodeFont(s.charAt(i))) {
                needsWrap = true;
                break;
            }
        }
        if (!needsWrap)
            return s;

        String out = '';
        Integer i = 0;
        Boolean inTag = false;
        Integer runStart = -1;
        while (i < len) {
            Integer cp = s.charAt(i);
            if (cp == 60) {
                // '<' — entering markup; close any open run first
                if (runStart >= 0) {
                    out +=
                        '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                        s.substring(runStart, i) +
                        '</span>';
                    runStart = -1;
                }
                inTag = true;
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (cp == 62) {
                // '>'
                inTag = false;
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (inTag) {
                out += s.substring(i, i + 1);
                i++;
                continue;
            }
            if (codepointNeedsUnicodeFont(cp)) {
                if (runStart < 0)
                    runStart = i;
            } else {
                if (runStart >= 0) {
                    out +=
                        '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                        s.substring(runStart, i) +
                        '</span>';
                    runStart = -1;
                }
                out += s.substring(i, i + 1);
            }
            i++;
        }
        if (runStart >= 0) {
            out +=
                '<span style="font-family:\'Arial Unicode MS\', sans-serif;">' +
                s.substring(runStart, len) +
                '</span>';
        }
        return out;
    }

    private static Boolean codepointNeedsUnicodeFont(Integer cp) {
        if (cp <= 591)
            return false; // Latin-1 + Latin Extended-A/B
        if (cp == 8211 || cp == 8212)
            return false; // en/em dash
        if (cp == 8216 || cp == 8217)
            return false; // single smart quotes
        if (cp == 8220 || cp == 8221)
            return false; // double smart quotes
        if (cp == 8226 || cp == 8230)
            return false; // bullet, ellipsis
        if (cp == 8224 || cp == 8225)
            return false; // dagger, double dagger
        if (cp == 8482)
            return false; // trademark
        if (cp == 8364)
            return false; // euro
        return true;
    }

    // Decode HTML 4 named entities for high codepoints (Greek, math, dingbats) so the
    // wrap scan can detect them as needing the Arial Unicode MS span. escapeHtml4()
    // upstream converts literal Unicode chars into named entities; we reverse that for
    // glyphs Helvetica lacks.
    private static Map<String, Integer> highCodepointEntityMap;
    private static Map<String, Integer> getHighCodepointEntityMap() {
        if (highCodepointEntityMap != null)
            return highCodepointEntityMap;
        highCodepointEntityMap = new Map<String, Integer>{
            'alpha' => 945,
            'beta' => 946,
            'gamma' => 947,
            'delta' => 948,
            'epsilon' => 949,
            'zeta' => 950,
            'eta' => 951,
            'theta' => 952,
            'iota' => 953,
            'kappa' => 954,
            'lambda' => 955,
            'mu' => 956,
            'nu' => 957,
            'xi' => 958,
            'omicron' => 959,
            'pi' => 960,
            'rho' => 961,
            'sigmaf' => 962,
            'sigma' => 963,
            'tau' => 964,
            'upsilon' => 965,
            'phi' => 966,
            'chi' => 967,
            'psi' => 968,
            'omega' => 969,
            'thetasym' => 977,
            'upsih' => 978,
            'piv' => 982,
            'Alpha' => 913,
            'Beta' => 914,
            'Gamma' => 915,
            'Delta' => 916,
            'Epsilon' => 917,
            'Zeta' => 918,
            'Eta' => 919,
            'Theta' => 920,
            'Iota' => 921,
            'Kappa' => 922,
            'Lambda' => 923,
            'Mu' => 924,
            'Nu' => 925,
            'Xi' => 926,
            'Omicron' => 927,
            'Pi' => 928,
            'Rho' => 929,
            'Sigma' => 931,
            'Tau' => 932,
            'Upsilon' => 933,
            'Phi' => 934,
            'Chi' => 935,
            'Psi' => 936,
            'Omega' => 937,
            'forall' => 8704,
            'part' => 8706,
            'exist' => 8707,
            'empty' => 8709,
            'nabla' => 8711,
            'isin' => 8712,
            'notin' => 8713,
            'ni' => 8715,
            'prod' => 8719,
            'sum' => 8721,
            'minus' => 8722,
            'lowast' => 8727,
            'radic' => 8730,
            'prop' => 8733,
            'infin' => 8734,
            'ang' => 8736,
            'and' => 8743,
            'or' => 8744,
            'cap' => 8745,
            'cup' => 8746,
            'int' => 8747,
            'there4' => 8756,
            'sim' => 8764,
            'cong' => 8773,
            'asymp' => 8776,
            'ne' => 8800,
            'equiv' => 8801,
            'le' => 8804,
            'ge' => 8805,
            'sub' => 8834,
            'sup' => 8835,
            'nsub' => 8836,
            'sube' => 8838,
            'supe' => 8839,
            'oplus' => 8853,
            'otimes' => 8855,
            'perp' => 8869,
            'sdot' => 8901,
            'lceil' => 8968,
            'rceil' => 8969,
            'lfloor' => 8970,
            'rfloor' => 8971,
            'lang' => 9001,
            'rang' => 9002,
            'loz' => 9674,
            'spades' => 9824,
            'clubs' => 9827,
            'hearts' => 9829,
            'diams' => 9830,
            'larr' => 8592,
            'uarr' => 8593,
            'rarr' => 8594,
            'darr' => 8595,
            'harr' => 8596,
            'crarr' => 8629,
            'lArr' => 8656,
            'uArr' => 8657,
            'rArr' => 8658,
            'dArr' => 8659,
            'hArr' => 8660
        };
        return highCodepointEntityMap;
    }

    private static String decodeHighCodepointEntities(String s) {
        if (String.isBlank(s) || s.indexOf('&') == -1)
            return s;
        Map<String, Integer> entityMap = getHighCodepointEntityMap();
        for (String name : entityMap.keySet()) {
            String token = '&' + name + ';';
            if (s.contains(token)) {
                s = s.replace(token, String.fromCharArray(new List<Integer>{ entityMap.get(name) }));
            }
        }
        return s;
    }

    private static Boolean hasPageCounterTokens(String html) {
        if (String.isBlank(html)) {
            return false;
        }
        return html.contains('{PageNumber}') || html.contains('{TotalPages}');
    }

    // v1.90 — detect an author-declared @page rule in concatenated <style> blocks.
    // Case-insensitive substring is sufficient: false positives in CSS comments or
    // string literals are extremely rare in real template HTML, and the cost of a
    // false positive (engine drops its size/margin defaults) is acceptable —
    // Flying Saucer falls back to its own letter/1in defaults when @page omits them.
    @TestVisible
    private static Boolean hasSourcePageRule(String sourceStyles) {
        if (String.isBlank(sourceStyles)) {
            return false;
        }
        return sourceStyles.toLowerCase().contains('@page');
    }

    /**
     * #243 — true when the admin made a DELIBERATE page-setup choice on the template
     * record, i.e. picked a non-default picklist value. Page_Orientation__c defaults to
     * Portrait and Page_Size__c to Letter, so those two values cannot be distinguished
     * from "never touched" and must NOT override an author's @page — that would flip
     * every existing HTML template that declares its own page (the v1.90 fix for #60/#71).
     * Landscape / Legal / A4 can only have been chosen on purpose.
     */
    @TestVisible
    private static Boolean hasExplicitPageOverride() {
        String orient = DocGenHtmlRenderer.orientationOverride;
        String size = DocGenHtmlRenderer.pageSizeOverride;
        return 'Landscape'.equalsIgnoreCase(orient) || 'Legal'.equalsIgnoreCase(size) || 'A4'.equalsIgnoreCase(size);
    }

    /**
     * #243 — true when Page_Margins__c names a concrete preset. 'Default' is the field
     * default and 'FromSource' explicitly defers to the source document, so neither
     * justifies overwriting an author's @page margin.
     */
    @TestVisible
    private static Boolean hasExplicitMarginOverride() {
        String preset = DocGenHtmlRenderer.marginsOverride;
        return String.isNotBlank(preset) &&
            !'Default'.equalsIgnoreCase(preset) &&
            !'FromSource'.equalsIgnoreCase(preset);
    }

    /**
     * #243 — removes a single declaration (`size` or `margin`) from every `@page` block
     * in the source styles, leaving the rest of the author's CSS untouched.
     *
     * Needed because the engine's <style> is emitted BEFORE the source's, so an engine
     * `@page { size: ... }` loses the cascade to an author declaration of equal
     * specificity. Dropping the competing declaration lets the engine's value apply
     * without relocating or rewriting author CSS.
     *
     * The `(^|;)` anchor is what keeps this surgical: `size` cannot match `font-size`
     * and `margin` cannot match `margin-top`, because in both cases the character
     * following the property name is not `:`.
     */
    @TestVisible
    private static String stripSourcePageDecl(String styles, String prop) {
        if (String.isBlank(styles)) {
            return styles;
        }
        Matcher blocks = Pattern.compile('(?is)(@page[^\\{]*\\{)([^\\}]*)(\\})').matcher(styles);
        Pattern decl = Pattern.compile('(?i)(^|;)\\s*' + prop + '\\s*:[^;\\}]*(;|$)');
        String out = '';
        Integer last = 0;
        while (blocks.find()) {
            out += styles.substring(last, blocks.start());
            // Collapse the matched declaration to a bare ';' so neighbouring
            // declarations stay separated.
            String body = decl.matcher(blocks.group(2)).replaceAll('$1');
            out += blocks.group(1) + body + blocks.group(3);
            last = blocks.end();
        }
        out += styles.substring(last);
        return out;
    }

    /**
     * 1.68 — builds the `margin: ...` portion of the @page CSS rule based on
     * the renderer overrides (Page_Margins__c preset / Custom_Margins__c). Mirrors
     * DocGenHtmlRenderer.resolveMarginsForOverride but emits CSS instead of twips.
     */
    private static String resolveMarginsCss(String size, Boolean isLandscape) {
        String preset = String.isNotBlank(DocGenHtmlRenderer.marginsOverride)
            ? DocGenHtmlRenderer.marginsOverride
            : 'Default';
        if ('Narrow'.equalsIgnoreCase(preset))
            return 'margin: 0.5in';
        if ('Normal'.equalsIgnoreCase(preset))
            return 'margin: 1in';
        if ('Wide'.equalsIgnoreCase(preset))
            return 'margin: 1.5in';
        if ('Custom'.equalsIgnoreCase(preset)) {
            String custom = parseCustomMarginsCss(DocGenHtmlRenderer.customMarginsOverride);
            if (custom != null)
                return custom;
        }
        // 'FromSource' on HTML templates falls through to size-default since HTML
        // has no <w:pgMar>. DOCX-source FromSource is handled by the renderer's
        // parsePageDimensions path before this method is reached.
        Decimal m = isLandscape ? 0.5 : 1.0;
        return 'margin: ' + m + 'in';
    }

    private static String parseCustomMarginsCss(String raw) {
        if (String.isBlank(raw))
            return null;
        try {
            String cleaned = raw.replaceAll('\\s+', ' ').trim();
            List<String> parts;
            if (cleaned.contains(',')) {
                parts = cleaned.split('\\s*,\\s*');
            } else {
                parts = cleaned.split(' ');
            }
            if (parts.isEmpty())
                return null;
            Decimal t = clampMarginCss(Decimal.valueOf(parts[0].trim()));
            Decimal r = parts.size() >= 2 ? clampMarginCss(Decimal.valueOf(parts[1].trim())) : t;
            Decimal b = parts.size() >= 3 ? clampMarginCss(Decimal.valueOf(parts[2].trim())) : t;
            Decimal l = parts.size() >= 4 ? clampMarginCss(Decimal.valueOf(parts[3].trim())) : r;
            return 'margin: ' + t + 'in ' + r + 'in ' + b + 'in ' + l + 'in';
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal clampMarginCss(Decimal v) {
        if (v < 0.1)
            return 0.1;
        if (v > 3.0)
            return 3.0;
        return v;
    }

    /**
     * Converts a user-authored header/footer HTML fragment containing
     * {PageNumber} / {TotalPages} tokens into a Flying Saucer @page margin
     * box `content` property value.
     *
     * HTML tags are stripped (flattened to plain text) because @page content
     * only accepts strings + counter() functions. Tokens become counter(page)
     * / counter(pages) calls; surrounding text becomes CSS string literals.
     *
     * Example:
     *   "<div>Page {PageNumber} of {TotalPages}</div>"
     *     → content: "Page " counter(page) " of " counter(pages);
     */
    private static String buildPageMarginContentCss(String html) {
        String text = html == null ? '' : decodeBraceEntities(html).replaceAll('<[^>]+>', '');
        text = text.replace('&nbsp;', ' ')
            .replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"')
            .replace('&#39;', '\'');

        List<String> parts = new List<String>();
        Integer cursor = 0;
        while (cursor < text.length()) {
            Integer pnIdx = text.indexOf('{PageNumber}', cursor);
            Integer tpIdx = text.indexOf('{TotalPages}', cursor);

            Integer next = -1;
            String counterFn = null;
            if (pnIdx != -1 && (tpIdx == -1 || pnIdx < tpIdx)) {
                next = pnIdx;
                counterFn = 'counter(page)';
            } else if (tpIdx != -1) {
                next = tpIdx;
                counterFn = 'counter(pages)';
            }

            if (next == -1) {
                if (cursor < text.length()) {
                    parts.add('"' + escapeForCssString(text.substring(cursor)) + '"');
                }
                break;
            }
            if (next > cursor) {
                parts.add('"' + escapeForCssString(text.substring(cursor, next)) + '"');
            }
            parts.add(counterFn);
            cursor = next + 12; // both tokens are 12 chars ({PageNumber}, {TotalPages})
        }
        if (parts.isEmpty()) {
            parts.add('""');
        }
        return 'content: ' + String.join(parts, ' ') + ';';
    }

    private static String escapeForCssString(String s) {
        return s.replace('\\', '\\\\').replace('"', '\\"');
    }
}

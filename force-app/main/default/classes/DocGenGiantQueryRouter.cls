/**
 * Single source of truth for "generate this document now, or hand it to the
 * async Giant Query batch?".
 *
 * Both entry points that make this call — the on-screen Runner
 * (DocGenController.scoutChildCounts) and the "Generate Document (Auto Giant
 * Query)" Flow action (DocGenGiantQueryFlowAction) — route through here so the
 * two can never drift apart again. They did drift: the Runner estimated peak
 * heap and routed on that, while the Flow action only looked at a raw child
 * row count > 2,000. A Quote with a few hundred line items carrying large
 * rich-text descriptions is well under 2,000 rows but tens of MB of data, so
 * the Flow action ran it synchronously and blew the 6 MB Apex heap governor
 * with an uncatchable System.LimitException (issue #374).
 *
 * The estimate is heap-aware AND payload-aware: it samples one real child row
 * so a relationship whose rows carry a 30 KB text field is not costed as if
 * every row were 2 KB.
 */
public with sharing class DocGenGiantQueryRouter {
    // Apex synchronous heap governor, and the fraction of it we are willing to
    // spend before routing to the background batch (40 % headroom).
    public static final Integer SYNC_HEAP_LIMIT = 6000000;
    public static final Decimal SAFE_HEAP_RATIO = 0.6;

    // Peak-heap model, per output format. PDF renders through Blob.toPdf() which
    // holds the entire HTML DOM + parse tree in heap while rendering, so its
    // per-row cost is several times the raw expanded row; DOCX/Excel/PowerPoint
    // just write XML and ship base64 to the client.
    public static final Integer PDF_BASE_BYTES = 1000000; // template HTML + styles + parent data
    public static final Integer PDF_BYTES_PER_ROW = 10000; // ~10 KB per row after DOM/CSS parsing
    public static final Integer DOCX_BASE_BYTES = 200000;
    public static final Integer DOCX_BYTES_PER_ROW = 2000;

    // Multiplier applied to a *sampled* raw row size to approximate its peak
    // heap contribution during rendering.
    private static final Integer PDF_ROW_BLOWUP = 5;
    private static final Integer DOCX_ROW_BLOWUP = 2;

    // A hard backstop on top of the heap estimate: this many child rows always
    // routes async regardless of how skinny the rows look. Matches the
    // historical threshold so V3 templates behave exactly as before at scale.
    public static final Integer GIANT_ROW_CEILING = 2000;

    // Below this row count even fat rows cannot realistically blow the sync
    // heap, so skip the sampling SOQL.
    private static final Integer SAMPLE_MIN_ROWS = 25;
    private static final Integer MAX_LONG_TEXT_SAMPLE_CHARS = 600000;
    public static final Integer DEFAULT_PAGE_SIZE = 50;

    public class Settings {
        public final Integer rowThreshold;
        public final Integer pageSize;
        public final Boolean thresholdConfigured;
        public final Boolean pageSizeConfigured;

        public Settings(DocGen_Template__c template) {
            DocGen_Settings__c org = DocGen_Settings__c.getOrgDefaults();
            Decimal selectedThreshold = positive(
                template?.Giant_Query_Row_Threshold__c,
                org?.Giant_Query_Row_Threshold__c
            );
            Decimal selectedPageSize = positive(template?.Giant_Query_Page_Size__c, org?.Giant_Query_Page_Size__c);
            thresholdConfigured = selectedThreshold != null;
            pageSizeConfigured = selectedPageSize != null;
            rowThreshold = thresholdConfigured ? selectedThreshold.intValue() : GIANT_ROW_CEILING;
            pageSize = pageSizeConfigured
                ? Math.min(DEFAULT_PAGE_SIZE, selectedPageSize.intValue())
                : DEFAULT_PAGE_SIZE;
        }
    }

    public class Assessment {
        public Integer estimatedPeakHeapBytes;
        public Boolean useGiantPath;
        public Boolean largePayload;
        public Boolean exceedsRowThreshold;
        public Integer pageSize;
    }

    private static Decimal positive(Decimal preferred, Decimal fallback) {
        return preferred != null && preferred >= 1 ? preferred : (fallback != null && fallback >= 1 ? fallback : null);
    }

    public static Assessment assess(
        Id parentRecordId,
        Map<String, Object> node,
        Integer rows,
        String outputFormat,
        Settings settings,
        Boolean sampleOrdinaryRows
    ) {
        Integer effectiveRows = rows == null ? 0 : rows;
        Object configuredLimit = node?.get('limit');
        if (configuredLimit != null && String.valueOf(configuredLimit).isNumeric()) {
            try {
                effectiveRows = Math.min(effectiveRows, Integer.valueOf(String.valueOf(configuredLimit)));
            } catch (Exception oversizedLimit) {
                // A numeric LIMIT outside the Integer range cannot reduce the scouted count.
            }
        }
        Assessment a = new Assessment();
        a.exceedsRowThreshold = effectiveRows > settings.rowThreshold;
        Integer longBytes = effectiveRows == 0 ? 0 : sampleLongTextBytes(parentRecordId, node);
        Integer sample = longBytes;
        if (sample == 0 && sampleOrdinaryRows && !a.exceedsRowThreshold && effectiveRows >= SAMPLE_MIN_ROWS) {
            sample = sampleChildRowBytes(parentRecordId, node);
        }
        a.estimatedPeakHeapBytes = estimatePeakHeapBytes(effectiveRows, sample, outputFormat);
        a.largePayload = longBytes > 0 && a.estimatedPeakHeapBytes > safeHeapBytes();
        a.useGiantPath = effectiveRows > 0 && (a.exceedsRowThreshold || a.estimatedPeakHeapBytes > safeHeapBytes());
        a.pageSize = longBytes > 0 ? Math.min(settings.pageSize, Math.max(1, 450000 / longBytes)) : settings.pageSize;
        return a;
    }

    /**
     * Samples up to three of the newest rows when configured fields can contain long text.
     * Sampling is based on field capacity, including for lists with fewer than 25 records.
     * Only accessible fields are projected, with a bounded worst-case payload.
     */
    @TestVisible
    private static Integer sampleLongTextBytes(Id parentRecordId, Map<String, Object> node) {
        if (node == null || parentRecordId == null || Limits.getLimitQueries() - Limits.getQueries() < 8) {
            return 0;
        }
        try {
            Schema.SObjectType childType = Schema.getGlobalDescribe().get((String) node.get('object'));
            String lookup = (String) node.get('lookupField');
            List<Object> raw = (List<Object>) node.get('fields');
            if (childType == null || String.isBlank(lookup) || raw == null || raw.isEmpty()) {
                return 0;
            }
            Map<String, Schema.SObjectField> described = childType.getDescribe().fields.getMap();
            Schema.SObjectField parentField = described.get(lookup.toLowerCase());
            if (parentField == null || !parentField.getDescribe().isAccessible()) {
                return 0;
            }
            Set<String> selected = new Set<String>();
            Integer capacity = 0;
            for (Object fieldName : raw) {
                Schema.SObjectField field = described.get(String.valueOf(fieldName).toLowerCase());
                if (field == null)
                    continue;
                Schema.DescribeFieldResult d = field.getDescribe();
                Integer length = d.getLength();
                if (
                    d.isAccessible() &&
                    length >= 4000 &&
                    !selected.contains(d.getName()) &&
                    capacity + length <= MAX_LONG_TEXT_SAMPLE_CHARS
                ) {
                    selected.add(d.getName());
                    capacity += length;
                }
            }
            if (selected.isEmpty()) {
                return 0;
            }
            Integer sampleSize = Math.min(3, MAX_LONG_TEXT_SAMPLE_CHARS / capacity);
            String soql =
                'SELECT ' +
                String.join(new List<String>(selected), ', ') +
                ' FROM ' +
                childType.getDescribe().getName() +
                ' WHERE ' +
                parentField.getDescribe().getName() +
                ' = :parentRecordId';
            String whereClause = DocGenDataRetriever.sanitizeWhereClause((String) node.get('where'));
            if (String.isNotBlank(whereClause))
                soql += ' AND (' + whereClause + ')';
            soql += described.containsKey('createddate') ? ' ORDER BY CreatedDate DESC, Id DESC' : ' ORDER BY Id DESC';
            soql += ' LIMIT :sampleSize';
            Integer maximum = 0;
            for (SObject row : Database.query(DocGenSignatureIpContext.publicQuery(soql), AccessLevel.USER_MODE)) {
                Integer bytes = 0;
                for (String fieldName : selected) {
                    String value = (String) row.get(fieldName);
                    if (value != null)
                        bytes += Blob.valueOf(value).size();
                }
                maximum = Math.max(maximum, bytes);
            }
            return maximum;
        } catch (Exception unavailable) {
            // The estimate is best effort. The row and renderer limits still apply.
            return 0;
        }
    }

    /** The routing verdict for one parent record + template. */
    public class Decision {
        public Boolean useGiantPath = false;
        /** Effective relationship key (alias when the node has one, else relationshipName). */
        public String giantRelationship;
        /** Child node config for DocGenGiantQueryBatch — null if it could not be resolved. */
        public Map<String, Object> giantNodeConfig;
        /** Every scouted relationship → child row count. */
        public Map<String, Integer> counts = new Map<String, Integer>();
        /** Estimated peak sync heap for the chosen relationship (bytes). */
        public Integer estimatedPeakHeapBytes = 0;
        /** Human-readable explanation, surfaced in the Flow error / debug log. */
        public String reason = '';
        public Boolean useWordSnapshot = false;
        public Integer pageSize;
    }

    /** 60 % of the sync heap governor — the ceiling for a synchronous generation. */
    public static Integer safeHeapBytes() {
        return (Integer) (SYNC_HEAP_LIMIT * SAFE_HEAP_RATIO);
    }

    /**
     * Estimated peak synchronous heap (bytes) for expanding `rowCount` rows of a
     * child relationship into the merged document.
     *
     * @param sampleRowBytes measured size of one real child row (0 / null = not
     *        sampled → the per-format default per-row cost is used, which keeps
     *        this identical to the pre-#374 estimate).
     */
    public static Integer estimatePeakHeapBytes(Integer rowCount, Integer sampleRowBytes, String outputFormat) {
        Boolean isPdf = String.isBlank(outputFormat) || 'PDF'.equalsIgnoreCase(outputFormat);
        Long baseBytes = isPdf ? PDF_BASE_BYTES : DOCX_BASE_BYTES;
        Long perRow;
        if (sampleRowBytes != null && sampleRowBytes > 0) {
            // We measured a real child row — trust it (scaled by the format's
            // render blow-up), rather than ratcheting up to the pessimistic
            // per-format default. The default over-costs skinny rows: at
            // 10 KB/row a PDF crosses the heap ceiling near 260 rows even when
            // every row is a few hundred bytes, routing a template the async
            // batch can't process (it only takes Word) to a hard error. A small
            // floor covers per-row merge/parse overhead.
            Long sampled = (Long) sampleRowBytes * (isPdf ? PDF_ROW_BLOWUP : DOCX_ROW_BLOWUP);
            Long floorPerRow = isPdf ? 1200L : 400L;
            perRow = sampled > floorPerRow ? sampled : floorPerRow;
        } else {
            perRow = isPdf ? PDF_BYTES_PER_ROW : DOCX_BYTES_PER_ROW;
        }
        Long rows = rowCount == null ? 0 : rowCount;
        // Long math + clamp: rows * a sampled fat per-row cost overflows a
        // 32-bit Integer well before it stops being "definitely too big".
        Long total = baseBytes + (rows * perRow);
        return total > 2000000000L ? 2000000000 : (Integer) total;
    }

    /**
     * Decide sync vs Giant Query for a parent record + template query config.
     * Works for every config format (V1 flat string, V2/V3 JSON).
     */
    public static Decision decide(Id parentRecordId, String queryConfig, String outputFormat) {
        return decide(parentRecordId, queryConfig, outputFormat, new Settings(null));
    }

    public static Decision decide(Id parentRecordId, String queryConfig, String outputFormat, Settings settings) {
        Decision d = new Decision();
        if (parentRecordId == null || String.isBlank(queryConfig)) {
            d.reason = 'No record or query config to scout.';
            return d;
        }
        d.counts = DocGenDataRetriever.scoutChildCounts(parentRecordId, queryConfig);
        if (d.counts.isEmpty()) {
            d.reason = 'Template has no child relationships to scout.';
            return d;
        }
        Integer sampleBudget = 2;
        for (String relKey : d.counts.keySet()) {
            Integer rows = d.counts.get(relKey);
            if (rows == null || rows == 0)
                continue;
            Map<String, Object> node = resolveNodeConfig(parentRecordId, queryConfig, relKey);
            Boolean sampleOrdinary = sampleBudget > 0 && rows >= SAMPLE_MIN_ROWS && rows <= settings.rowThreshold;
            Assessment a = assess(parentRecordId, node, rows, outputFormat, settings, sampleOrdinary);
            if (sampleOrdinary)
                sampleBudget--;
            if (!a.useGiantPath || (d.useGiantPath && a.estimatedPeakHeapBytes <= d.estimatedPeakHeapBytes)) {
                continue;
            }
            d.useGiantPath = true;
            d.giantRelationship = relKey;
            d.giantNodeConfig = node;
            d.estimatedPeakHeapBytes = a.estimatedPeakHeapBytes;
            d.useWordSnapshot = a.largePayload || (settings.thresholdConfigured && a.exceedsRowThreshold);
            d.pageSize = a.pageSize;
            d.reason = a.exceedsRowThreshold
                ? rows + ' "' + relKey + '" rows exceed the ' + settings.rowThreshold + '-row synchronous ceiling.'
                : 'Estimated peak heap for ' + rows + ' "' + relKey + '" rows exceeds the safe synchronous limit.';
        }
        if (d.useGiantPath)
            return d;
        d.reason = 'All child datasets fit the synchronous heap budget.';
        return d;
    }

    /**
     * Child node config for DocGenGiantQueryBatch. V3: the node whose
     * alias||relationshipName matches the scout key. V1: parsed from the flat
     * subquery. V2 (children array) is not supported for the batch → null.
     */
    public static Map<String, Object> resolveNodeConfig(Id parentRecordId, String queryConfig, String relKey) {
        if (String.isBlank(queryConfig) || String.isBlank(relKey))
            return null;
        String trimmed = queryConfig.trim();
        if (trimmed.startsWith('{')) {
            try {
                Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
                List<Object> nodes = (List<Object>) config.get('nodes');
                if (nodes == null) {
                    return null; // V2 children-array form — no giant batch support
                }
                for (Object nodeObj : nodes) {
                    Map<String, Object> n = (Map<String, Object>) nodeObj;
                    String alias = (String) n.get('alias');
                    String rel = (String) n.get('relationshipName');
                    String effectiveKey = String.isNotBlank(alias) ? alias : rel;
                    if (relKey.equals(effectiveKey)) {
                        return n;
                    }
                }
                return null;
            } catch (Exception e) {
                return null;
            }
        }
        // V1 flat string
        return DocGenController.buildNodeConfigFromFlat(parentRecordId, queryConfig, relKey);
    }

    /**
     * Serialized size (bytes) of one real child row with the configured fields —
     * the payload signal the row-count-only router was missing. Best-effort: any
     * failure returns 0 and the caller falls back to the per-format constant.
     */
    @TestVisible
    private static Integer sampleChildRowBytes(Id parentRecordId, Map<String, Object> nodeConfig) {
        if (nodeConfig == null) {
            return 0;
        }
        try {
            String childObject = (String) nodeConfig.get('object');
            String lookupField = (String) nodeConfig.get('lookupField');
            List<Object> rawFields = (List<Object>) nodeConfig.get('fields');
            if (
                String.isBlank(childObject) ||
                String.isBlank(lookupField) ||
                rawFields == null ||
                rawFields.isEmpty()
            ) {
                return 0;
            }
            if (Schema.getGlobalDescribe().get(childObject) == null) {
                return 0;
            }
            List<String> fields = new List<String>();
            for (Object f : rawFields) {
                String fname = String.valueOf(f);
                if (String.isNotBlank(fname) && !fname.contains('.')) {
                    fields.add(String.escapeSingleQuotes(fname));
                }
            }
            if (fields.isEmpty()) {
                return 0;
            }
            String soql =
                'SELECT ' +
                String.join(fields, ',') +
                ' FROM ' +
                String.escapeSingleQuotes(childObject) +
                ' WHERE ' +
                String.escapeSingleQuotes(lookupField) +
                ' = :parentRecordId LIMIT 1';
            // CxSAST: object + fields validated against Schema / no dots; USER_MODE enforced.
            List<SObject> sampleRows = Database.query(
                DocGenSignatureIpContext.publicQuery(soql),
                AccessLevel.USER_MODE
            ); // NOPMD ApexSOQLInjection
            if (sampleRows.isEmpty()) {
                return 0;
            }
            return JSON.serialize(sampleRows[0].getPopulatedFieldsAsMap()).length();
        } catch (Exception e) {
            return 0;
        }
    }
}

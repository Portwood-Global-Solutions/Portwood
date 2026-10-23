/**
 * DocGenChartBucketResolver
 *
 * Implements the {#ChartBucket:relationship:field}...{/ChartBucket} template
 * tag. Given a child relationship on the current data context and a field on
 * the child records, computes a virtual collection of buckets (key, count,
 * percent, max_percent, color, index) and exposes them to the template body
 * via the existing section-tag loop machinery.
 *
 * Strategy: preprocessInline() rewrites each ChartBucket tag into a synthetic
 * {#_cb_N}...{/_cb_N} loop tag and injects the bucket list into the data map
 * under the synthetic key. The downstream processXml scanner then iterates
 * the buckets the same way it iterates any List<Object> — no parser changes
 * required. This reuses the existing container auto-expansion (<tr>/<li>),
 * {:else} branching, heap-pressure checks, and HTML escaping.
 *
 * Three resolution paths stay consistent (per CLAUDE.md):
 *  - Inline (DocGenService.processXml)              — preprocessInline()
 *  - Parent-level (DocGenGiantQueryAssembler tags)  — same routing via processXmlForTest
 *  - Giant-query (>2000 child rows)                 — computeBucketsFromAggregate()
 *    against a GROUP BY SOQL result, invoked from DocGenGiantQueryAssembler
 *    .resolveGiantChartBuckets().
 */
public with sharing class DocGenChartBucketResolver {
    /**
     * 8-color palette cycled by {color} field. Authors can ignore and use
     * their own — these are just convenient defaults for table-row bars.
     */
    private static final List<String> PALETTE = new List<String>{
        '#3b82f6',
        '#10b981',
        '#f59e0b',
        '#ef4444',
        '#8b5cf6',
        '#ec4899',
        '#06b6d4',
        '#84cc16'
    };

    private static final String OPEN_TAG_PREFIX = '{#ChartBucket:';
    private static final String CLOSE_TAG = '{/ChartBucket}';
    private static final String NULL_SENTINEL = '__null__';
    private static final String NOT_SPECIFIED_LABEL = 'Not Specified';

    /**
     * Per-transaction governor budget for SOQL-fallback aggregates. Apex statics
     * reset between requests, so each document-generation transaction starts at
     * 50. When exhausted, charts render a sentinel notice bucket instead of a
     * blank rendering — so authors get visible feedback rather than silently-
     * empty charts when a template stacks too many `{#ChartBucket}` tags.
     *
     * The cap is intentionally below Apex's 100-SOQL transaction ceiling to
     * leave headroom for other queries the merge engine and PDF assembly need.
     */
    @TestVisible
    private static Integer chartSoqlBudget = 50;

    /**
     * Per-transaction cache for child-relationship schema lookups. Walking
     * `parent.getDescribe().getChildRelationships()` is not free; caching keeps
     * 50 charts on one page from re-walking the same schema 50 times.
     * Key shape: `<parentApiName>|<relationshipName>` (lower-cased).
     */
    private static Map<String, ChildRelMeta> childRelCache = new Map<String, ChildRelMeta>();

    /**
     * Preprocesses an XML/HTML chunk: finds every top-level {#ChartBucket:...}
     * tag at the CURRENT recursion depth, computes its bucket list against the
     * passed-in data map, injects the bucket list under a synthetic key
     * (_cb_0, _cb_1, ...), and rewrites the tag to {#_cb_N}body{/_cb_N}.
     *
     * Charts nested inside other section tags ({#OtherRel}…{#ChartBucket}…)
     * are intentionally left untouched: they'll be processed by the inner
     * processXml() recursion when the outer loop expands, at which point the
     * iteration item carries the relationship the chart needs.
     *
     * Mutates the data map. Returns the rewritten XML. If the input contains
     * no chart tags, returns the input unchanged with no map mutation.
     */
    public static String preprocessInline(String xml, Map<String, Object> data) {
        if (String.isBlank(xml) || !xml.contains(OPEN_TAG_PREFIX) || data == null) {
            return xml;
        }

        Integer counter = 0;
        while (data.containsKey('_cb_' + counter)) {
            counter++;
        }

        ChunkBuffer out = new ChunkBuffer();
        Integer cursor = 0;
        Integer depth = 0;
        Integer len = xml.length();

        while (cursor < len) {
            Integer nextBrace = xml.indexOf('{', cursor);
            if (nextBrace == -1) {
                out.append(xml.substring(cursor));
                break;
            }
            out.append(xml.substring(cursor, nextBrace));
            cursor = nextBrace;

            // Classify the tag we just landed on.
            if (
                cursor + OPEN_TAG_PREFIX.length() <= len &&
                xml.substring(cursor, cursor + OPEN_TAG_PREFIX.length()) == OPEN_TAG_PREFIX
            ) {
                // Chart opener.
                if (depth == 0) {
                    Integer tagClose = xml.indexOf('}', cursor);
                    if (tagClose == -1) {
                        // Malformed — emit raw and bail (main scanner will surface error)
                        out.append(xml.substring(cursor));
                        return out.collect();
                    }
                    String relName;
                    String fieldApi;
                    String modifiers = null;
                    String tagInner = xml.substring(cursor + 2, tagClose); // strip "{#"
                    Integer firstColon = tagInner.indexOf(':');
                    Integer secondColon = (firstColon == -1) ? -1 : tagInner.indexOf(':', firstColon + 1);
                    Integer thirdColon = (secondColon == -1) ? -1 : tagInner.indexOf(':', secondColon + 1);
                    if (firstColon == -1 || secondColon == -1) {
                        // Malformed — pass through unchanged
                        out.append(xml.substring(cursor, tagClose + 1));
                        cursor = tagClose + 1;
                        continue;
                    }
                    relName = tagInner.substring(firstColon + 1, secondColon).trim();
                    if (thirdColon == -1) {
                        fieldApi = tagInner.substring(secondColon + 1).trim();
                    } else {
                        fieldApi = tagInner.substring(secondColon + 1, thirdColon).trim();
                        // Everything after the 3rd colon is the modifier string —
                        // a query-string-ish `colors=#aaa,#bbb&future=value` shape so
                        // we can layer in more options (sort, skip_null, ...) later
                        // without another breaking change.
                        modifiers = tagInner.substring(thirdColon + 1).trim();
                    }
                    if (String.isBlank(relName) || String.isBlank(fieldApi)) {
                        out.append(xml.substring(cursor, tagClose + 1));
                        cursor = tagClose + 1;
                        continue;
                    }

                    // Find balanced {/ChartBucket}, supporting accidental nesting safely.
                    Integer closerPos = findBalancedChartClose(xml, tagClose + 1);
                    if (closerPos == -1) {
                        // Unmatched — leave it; main scanner will raise a clear error
                        out.append(xml.substring(cursor, tagClose + 1));
                        cursor = tagClose + 1;
                        continue;
                    }
                    String body = xml.substring(tagClose + 1, closerPos);
                    Integer closerEnd = closerPos + CLOSE_TAG.length();

                    // Parse all modifiers once. Recognized v1.91 keys:
                    //   colors=#aaa,#bbb   — palette override
                    //   where=Field='Val'  — SOQL filter
                    //   split=;            — multi-select delimiter
                    //   groupBy=Field__c   — cross-tab pivot dimension
                    Map<String, String> mods = parseTagModifiers(modifiers);
                    String whereClause = mods.get('where');
                    String splitDelim = mods.get('split');
                    String groupByField = mods.get('groupby');
                    List<String> colOrder = parseColSortModifier(mods.get('colsort'));

                    // Bucket resolution strategy:
                    //  (a) Pivot (groupBy=) — always SOQL because the GROUP BY
                    //      row,col matrix is awkward to compute in-memory and
                    //      benefits from server-side aggregation.
                    //  (b) Filtered (where=) — always SOQL so the author's
                    //      filter executes against the full dataset, not a
                    //      pre-loaded subset that may have been retriever-capped.
                    //  (c) Pre-loaded relationship — in-memory bucket math.
                    //      Fast, no SOQL spend, supports split=.
                    //  (d) Anything else — SOQL fallback. Supports split=.
                    //  (0) Client-supplied — the runner LWC already swept these
                    //      rows page-by-page to build the chart image and handed
                    //      back the counts. Preferred whenever present: it is the
                    //      only option that survives a child set too large for
                    //      heap AND a field SOQL cannot GROUP BY, and it
                    //      guarantees the table agrees with the chart beside it.
                    List<Map<String, Object>> buckets = suppliedBuckets(relName, fieldApi, mods);

                    Boolean forceSoql = String.isNotBlank(groupByField) || String.isNotBlank(whereClause);
                    if (buckets == null) {
                        List<Object> records = forceSoql ? null : resolveRecords(data, relName);
                        if (records != null && !records.isEmpty()) {
                            buckets = computeBucketsWithSplit(records, fieldApi, splitDelim);
                        } else {
                            buckets = tryFallbackSoqlAggregateAdvanced(
                                data,
                                relName,
                                fieldApi,
                                groupByField,
                                whereClause,
                                splitDelim,
                                colOrder
                            );
                        }
                    }

                    // Apply optional palette override from the `colors=` modifier
                    // (3rd colon segment). When the author specifies a custom
                    // palette, each bucket's `color` is overwritten by cycling
                    // the supplied colors. Default palette stays in place for
                    // charts without the override.
                    List<String> customPalette = parsePaletteModifier(modifiers);
                    if (customPalette != null && !customPalette.isEmpty()) {
                        for (Integer bi = 0; bi < buckets.size(); bi++) {
                            buckets[bi].put('color', customPalette[Math.mod(bi, customPalette.size())]);
                        }
                    }

                    // Stored value MUST be typed as List<Object> exactly, because
                    // downstream processXml does `val instanceof List<Object>` and
                    // Apex generics are invariant at runtime (a List<Map<String,Object>>
                    // does NOT satisfy that check). Pack into a List<Object> to
                    // guarantee the loop branch fires.
                    List<Object> packedBuckets = new List<Object>();
                    for (Map<String, Object> b : buckets) {
                        packedBuckets.add(b);
                    }
                    String synKey = '_cb_' + counter;
                    counter++;
                    data.put(synKey, packedBuckets);

                    out.append('{#').append(synKey).append('}').append(body).append('{/').append(synKey).append('}');
                    cursor = closerEnd;
                    continue;
                } else {
                    // Chart opener nested inside another section — leave it; the inner
                    // recursion of processXml will re-run preprocessInline against the
                    // iteration item's data and resolve the relationship correctly.
                    Integer tagClose = xml.indexOf('}', cursor);
                    if (tagClose == -1) {
                        out.append(xml.substring(cursor));
                        return out.collect();
                    }
                    out.append(xml.substring(cursor, tagClose + 1));
                    cursor = tagClose + 1;
                    continue;
                }
            } else if (
                (cursor + 2 <= len && xml.substring(cursor, cursor + 2) == '{#') ||
                (cursor + 2 <= len &&
                xml.substring(cursor, cursor + 2) == '{~')
            ) {
                // Generic section opener — push depth so nested ChartBucket tags are deferred.
                // {~Label} (#439 root-anchor tag) counts too: a chart wrapped in one must
                // stay deferred until the TAG'S OWN recursion (processXml(job.innerXml,
                // rootDataContext) in DocGenService.drainRootTagJobs) resolves it against
                // root data — not get eagerly (and wrongly) resolved here against whatever
                // loop row this preprocessInline pass is currently running against. The
                // matching {/Label} closer needs no special case: the generic {/ branch
                // below pops depth for ANY {/word} closer, {~Label}'s included.
                Integer tagClose = xml.indexOf('}', cursor);
                if (tagClose == -1) {
                    out.append(xml.substring(cursor));
                    return out.collect();
                }
                depth++;
                out.append(xml.substring(cursor, tagClose + 1));
                cursor = tagClose + 1;
                continue;
            } else if (cursor + 2 <= len && xml.substring(cursor, cursor + 2) == '{/') {
                // Section closer.
                if (
                    cursor + CLOSE_TAG.length() <= len &&
                    xml.substring(cursor, cursor + CLOSE_TAG.length()) == CLOSE_TAG
                ) {
                    // ChartBucket closer at depth>0 (paired with an opener we skipped) —
                    // emit as-is; do not touch depth (we didn't push for the opener either).
                    out.append(CLOSE_TAG);
                    cursor += CLOSE_TAG.length();
                    continue;
                }
                Integer tagClose = xml.indexOf('}', cursor);
                if (tagClose == -1) {
                    out.append(xml.substring(cursor));
                    return out.collect();
                }
                if (depth > 0) {
                    depth--;
                }
                out.append(xml.substring(cursor, tagClose + 1));
                cursor = tagClose + 1;
                continue;
            } else {
                // Plain merge tag like {Field} — emit and continue.
                Integer tagClose = xml.indexOf('}', cursor);
                if (tagClose == -1) {
                    // Lone '{' with no closer — emit verbatim
                    out.append(xml.substring(cursor));
                    return out.collect();
                }
                out.append(xml.substring(cursor, tagClose + 1));
                cursor = tagClose + 1;
                continue;
            }
        }
        return out.collect();
    }

    /**
     * Public bucket-resolution helper, used by DocGenChartImageController to
     * compute buckets for the PNG-via-CV chart pipeline (#117) without
     * recursing through the full preprocessInline scanner.
     *
     * Mirrors the dispatch at preprocessInline:163-206:
     *   - Pivot (groupBy=) or filtered (where=) → SOQL fallback
     *   - Pre-loaded relationship on the data map → in-memory bucket math
     *   - Otherwise → SOQL fallback
     * Honors the same SOQL budget. Applies the `colors=` palette override.
     *
     * `modifiersRaw` is the same query-string-shape string the inline scanner
     * passes through (e.g. "colors=#aaa,#bbb&groupBy=Field__c&where=...").
     * Returns the bucket list directly (not wrapped in List<Object>) — the
     * controller doesn't need the runtime-type hack the inline scanner needs.
     */
    public static List<Map<String, Object>> resolveBucketsForTag(
        Map<String, Object> data,
        String relName,
        String fieldApi,
        String modifiersRaw
    ) {
        Map<String, String> mods = parseTagModifiers(modifiersRaw);
        String whereClause = mods.get('where');
        String splitDelim = mods.get('split');
        String groupByField = mods.get('groupby');
        List<String> colOrder = parseColSortModifier(mods.get('colsort'));

        List<Map<String, Object>> buckets;
        Boolean forceSoql = String.isNotBlank(groupByField) || String.isNotBlank(whereClause);
        List<Object> records = forceSoql ? null : resolveRecords(data, relName);
        if (records != null && !records.isEmpty()) {
            buckets = computeBucketsWithSplit(records, fieldApi, splitDelim);
        } else {
            buckets = tryFallbackSoqlAggregateAdvanced(
                data,
                relName,
                fieldApi,
                groupByField,
                whereClause,
                splitDelim,
                colOrder
            );
        }

        List<String> customPalette = parsePaletteModifier(modifiersRaw);
        if (customPalette != null && !customPalette.isEmpty()) {
            for (Integer bi = 0; bi < buckets.size(); bi++) {
                buckets[bi].put('color', customPalette[Math.mod(bi, customPalette.size())]);
            }
        }
        return buckets;
    }

    /**
     * Builds the bucket list from an in-memory child collection.
     *
     * Records may be `Map<String, Object>` (the shape produced by the
     * DocGenDataRetriever / template loop scope) or `SObject` (less common,
     * but supported for completeness). The grouping field is matched
     * case-insensitively to handle mixed-case API names from JSON parses.
     *
     * If `childType` is provided, picklist API values are mapped to their
     * display labels for `{key_label}`; otherwise label falls back to the
     * raw value. Null/blank values collapse into a single "Not Specified"
     * bucket so authors don't have to special-case missing data.
     *
     * Sorted descending by count, then alphabetically by key for stable
     * ties.
     */
    public static List<Map<String, Object>> computeBuckets(
        List<Object> records,
        String fieldApi,
        Schema.SObjectType childType
    ) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        if (records == null || records.isEmpty() || String.isBlank(fieldApi)) {
            return result;
        }

        Map<String, Integer> countByKey = new Map<String, Integer>();
        Map<String, String> originalKeys = new Map<String, String>();
        Integer total = 0;
        String lowerField = fieldApi.toLowerCase();

        for (Object rec : records) {
            Object rawVal = extractFieldValue(rec, fieldApi, lowerField);
            String key;
            if (rawVal == null || (rawVal instanceof String && String.isBlank((String) rawVal))) {
                key = NULL_SENTINEL;
            } else {
                key = String.valueOf(rawVal);
            }
            String mapKey = key.toLowerCase();
            Integer existing = countByKey.get(mapKey);
            countByKey.put(mapKey, (existing == null ? 0 : existing) + 1);
            if (!originalKeys.containsKey(mapKey)) {
                originalKeys.put(mapKey, key);
            }
            total++;
        }

        Map<String, String> picklistLabels = resolvePicklistLabels(childType, fieldApi);

        List<BucketSortable> sortable = new List<BucketSortable>();
        for (String mk : countByKey.keySet()) {
            sortable.add(new BucketSortable(originalKeys.get(mk), countByKey.get(mk)));
        }
        sortable.sort();

        Integer maxCount = 0;
        for (BucketSortable bs : sortable) {
            if (bs.count > maxCount) {
                maxCount = bs.count;
            }
        }

        Integer idx = 1;
        for (BucketSortable bs : sortable) {
            result.add(buildBucketMap(bs.rawKey, bs.count, total, maxCount, idx, picklistLabels));
            idx++;
        }
        return result;
    }

    /**
     * Builds the bucket list from a SOQL `GROUP BY` AggregateResult set.
     * Used by the giant-query path where in-memory iteration over millions
     * of child rows isn't viable.
     *
     * Each AggregateResult must expose the group value under the field's
     * API name and the count under the alias `cnt`. The SOQL must already
     * sort by COUNT(Id) DESC; this method preserves that ordering and only
     * supplements with the same shape (key/count/percent/...) the in-memory
     * path produces.
     */
    public static List<Map<String, Object>> computeBucketsFromAggregate(
        List<AggregateResult> rows,
        String fieldApi,
        Schema.SObjectType childType
    ) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        if (rows == null || rows.isEmpty() || String.isBlank(fieldApi)) {
            return result;
        }

        Map<String, String> picklistLabels = resolvePicklistLabels(childType, fieldApi);

        Integer total = 0;
        Integer maxCount = 0;
        List<Object> rawVals = new List<Object>();
        List<Integer> counts = new List<Integer>();
        for (AggregateResult ar : rows) {
            Object groupVal = ar.get(fieldApi);
            Object cntObj = ar.get('cnt');
            Integer cnt = (cntObj == null) ? 0 : Integer.valueOf(String.valueOf(cntObj));
            rawVals.add(groupVal);
            counts.add(cnt);
            total += cnt;
            if (cnt > maxCount) {
                maxCount = cnt;
            }
        }

        Integer idx = 1;
        for (Integer i = 0; i < rawVals.size(); i++) {
            Object rawVal = rawVals[i];
            String rawKey;
            if (rawVal == null || (rawVal instanceof String && String.isBlank((String) rawVal))) {
                rawKey = NULL_SENTINEL;
            } else {
                rawKey = String.valueOf(rawVal);
            }
            result.add(buildBucketMap(rawKey, counts[i], total, maxCount, idx, picklistLabels));
            idx++;
        }
        return result;
    }

    // ---------------------------------------------------------------------
    // Helpers (private)
    // ---------------------------------------------------------------------

    private static Map<String, Object> buildBucketMap(
        String rawKey,
        Integer count,
        Integer total,
        Integer maxCount,
        Integer idx,
        Map<String, String> picklistLabels
    ) {
        Boolean isNull = (rawKey == NULL_SENTINEL);
        String displayKey = isNull ? '' : rawKey;
        String labelLookup = rawKey.toLowerCase();
        String label;
        if (picklistLabels != null && picklistLabels.containsKey(labelLookup)) {
            label = picklistLabels.get(labelLookup);
        } else {
            label = isNull ? NOT_SPECIFIED_LABEL : rawKey;
        }

        Decimal percent = (total == 0)
            ? 0
            : (Decimal.valueOf(count) * 100 / total).setScale(1, System.RoundingMode.HALF_UP);
        Integer percentInt = (total == 0) ? 0 : percent.setScale(0, System.RoundingMode.HALF_UP).intValue();
        Decimal maxPercent = (maxCount == 0)
            ? 0
            : (Decimal.valueOf(count) * 100 / maxCount).setScale(1, System.RoundingMode.HALF_UP);
        String color = PALETTE[Math.mod(idx - 1, PALETTE.size())];

        Map<String, Object> bucket = new Map<String, Object>();
        bucket.put('key', displayKey);
        bucket.put('key_label', label);
        bucket.put('count', count);
        bucket.put('percent', percent);
        bucket.put('percent_int', percentInt);
        bucket.put('max_percent', maxPercent);
        bucket.put('index', idx);
        bucket.put('color', color);
        // color_hex: raw 6-char hex (no leading #), suitable for Word w:shd
        // w:fill attributes which reject the # prefix. HTML authors keep using
        // {color}; DOCX authors use {color_hex}.
        bucket.put('color_hex', color.startsWith('#') ? color.substring(1) : color);
        return bucket;
    }

    private static Object extractFieldValue(Object rec, String fieldApi, String lowerField) {
        if (rec == null) {
            return null;
        }
        if (rec instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) rec;
            if (m.containsKey(fieldApi)) {
                return m.get(fieldApi);
            }
            // Case-insensitive fallback — JSON-deserialized maps may differ in case.
            for (String k : m.keySet()) {
                if (k.toLowerCase() == lowerField) {
                    return m.get(k);
                }
            }
            return null;
        }
        if (rec instanceof SObject) {
            try {
                return ((SObject) rec).get(fieldApi);
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    /**
     * Stable key for a {#ChartBucket:...} tag, shared by the two sides of the
     * client-side handoff: `getChartTagsForTemplate` hands this to the LWC, the
     * LWC echoes it back as the key of `chartBucketMap`, and `preprocessInline`
     * recomputes it here to find the match. Reuses the chart-tag hash with a
     * fixed style token so a `{Chart:rel:field:bar}` and a
     * `{#ChartBucket:rel:field}` over the same data never collide.
     */
    /**
     * Whether SOQL will accept this field in a GROUP BY.
     *
     * This guard is not defensive tidiness — it prevents a hard failure. Asking
     * SOQL to group a Long Text Area throws
     *
     *     System.UnexpectedException: field 'X' can not be grouped in a query call
     *
     * and that exception is NOT catchable: a try/catch around the Database.query
     * does not stop it, so it takes down the whole document generation rather
     * than the one chart. Any long textarea qualifies — including the
     * VMR_Tracker Answer_N columns a commuter survey charts.
     *
     * Returning empty buckets instead degrades to an empty chart the author can
     * see and fix, which is the same outcome as every other unresolvable tag.
     */
    private static Boolean isGroupable(Map<String, Schema.SObjectField> childFieldMap, String fieldApi) {
        Schema.SObjectField f = childFieldMap.get(fieldApi.toLowerCase());
        if (f == null) {
            return false;
        }
        return f.getDescribe().isGroupable();
    }

    public static String bucketSignature(String relName, String fieldApi, Map<String, String> mods) {
        return DocGenChartImageController.tagSignature(relName, fieldApi, CHARTBUCKET_STYLE_TOKEN, mods);
    }

    private static final String CHARTBUCKET_STYLE_TOKEN = 'chartbucket';

    /**
     * Returns the client-supplied buckets for this tag, or null to fall through
     * to normal resolution.
     *
     * Deliberately forgiving: a malformed payload logs and returns null rather
     * than throwing, so a bad client build degrades to the server path instead
     * of failing the whole document.
     */
    private static List<Map<String, Object>> suppliedBuckets(
        String relName,
        String fieldApi,
        Map<String, String> mods
    ) {
        Map<String, String> supplied = DocGenService.getChartBucketMap();
        if (supplied == null || supplied.isEmpty()) {
            return null;
        }
        // NB: do not name this `json` — Apex identifiers are case-insensitive, so
        // a local `json` shadows the JSON class and breaks the call below.
        String payload = supplied.get(bucketSignature(relName, fieldApi, mods));
        if (String.isBlank(payload)) {
            return null;
        }
        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(payload);
            List<Map<String, Object>> out = new List<Map<String, Object>>();
            for (Object o : raw) {
                if (o instanceof Map<String, Object>) {
                    out.add((Map<String, Object>) o);
                }
            }
            return out.isEmpty() ? null : out;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'Portwood: unusable client bucket payload for ' + relName + '.' + fieldApi + ' — ' + e.getMessage()
            );
            return null;
        }
    }

    /**
     * One parsed top-level {#ChartBucket:...} tag.
     */
    public class BucketTagRef {
        @AuraEnabled
        public String relName;
        @AuraEnabled
        public String fieldApi;
        @AuraEnabled
        public String signature;
        @AuraEnabled
        public Map<String, String> mods;
    }

    /**
     * Lists the top-level {#ChartBucket:...} tags in `xml` so the client knows
     * which aggregations to compute.
     *
     * Only depth-0 tags are returned, matching `preprocessInline`: a bucket loop
     * nested inside another relationship loop is resolved per-iteration against
     * that iteration's record, which the client cannot precompute.
     */
    public static List<BucketTagRef> findTopLevelBucketTags(String xml) {
        List<BucketTagRef> out = new List<BucketTagRef>();
        if (String.isBlank(xml)) {
            return out;
        }
        Integer cursor = 0;
        while (true) {
            Integer start = xml.indexOf(OPEN_TAG_PREFIX, cursor);
            if (start == -1) {
                break;
            }
            Integer tagClose = xml.indexOf('}', start);
            if (tagClose == -1) {
                break;
            }
            // Skip the body wholesale so a bucket tag accidentally nested inside
            // another bucket body is not reported twice.
            Integer closerPos = findBalancedChartClose(xml, tagClose + 1);
            cursor = (closerPos == -1) ? tagClose + 1 : closerPos + CLOSE_TAG.length();

            String tagInner = xml.substring(start + 2, tagClose); // strip "{#"
            Integer firstColon = tagInner.indexOf(':');
            Integer secondColon = (firstColon == -1) ? -1 : tagInner.indexOf(':', firstColon + 1);
            Integer thirdColon = (secondColon == -1) ? -1 : tagInner.indexOf(':', secondColon + 1);
            if (firstColon == -1 || secondColon == -1) {
                continue;
            }
            String relName = tagInner.substring(firstColon + 1, secondColon).trim();
            String fieldApi;
            String modifiers = null;
            if (thirdColon == -1) {
                fieldApi = tagInner.substring(secondColon + 1).trim();
            } else {
                fieldApi = tagInner.substring(secondColon + 1, thirdColon).trim();
                modifiers = tagInner.substring(thirdColon + 1).trim();
            }
            if (String.isBlank(relName) || String.isBlank(fieldApi)) {
                continue;
            }
            BucketTagRef ref = new BucketTagRef();
            ref.relName = relName;
            ref.fieldApi = fieldApi;
            ref.mods = parseTagModifiers(modifiers);
            ref.signature = bucketSignature(relName, fieldApi, ref.mods);
            out.add(ref);
        }
        return out;
    }

    private static List<Object> resolveRecords(Map<String, Object> data, String relName) {
        if (data == null) {
            return null;
        }
        Object val = data.get(relName);
        if (val == null) {
            // Case-insensitive fallback
            for (String k : data.keySet()) {
                if (k.equalsIgnoreCase(relName)) {
                    val = data.get(k);
                    break;
                }
            }
        }
        if (val == null) {
            return null;
        }
        if (val instanceof List<Object>) {
            return (List<Object>) val;
        }
        if (val instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) val;
            Object recordsVal = m.get('records');
            if (recordsVal instanceof List<Object>) {
                return (List<Object>) recordsVal;
            }
        }
        return null;
    }

    private static Map<String, String> resolvePicklistLabels(Schema.SObjectType childType, String fieldApi) {
        Map<String, String> result = new Map<String, String>();
        if (childType == null || String.isBlank(fieldApi)) {
            return result;
        }
        try {
            Map<String, Schema.SObjectField> fmap = childType.getDescribe().fields.getMap();
            Schema.SObjectField sof = fmap.get(fieldApi.toLowerCase());
            if (sof == null) {
                return result;
            }
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            Schema.DisplayType dt = dfr.getType();
            if (dt == Schema.DisplayType.PICKLIST || dt == Schema.DisplayType.MULTIPICKLIST) {
                for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                    if (pe.isActive()) {
                        result.put(pe.getValue().toLowerCase(), pe.getLabel());
                    }
                }
            }
        } catch (Exception e) {
            // Schema lookup failed — fall back to raw values; never throw from a render helper.
            String noop = e.getMessage(); // NOPMD
        }
        return result;
    }

    /**
     * SOQL-fallback aggregate: when the relationship isn't pre-loaded on the
     * data map, issue a `SELECT field, COUNT(Id) GROUP BY field` against the
     * child object so the chart works regardless of child-record count.
     *
     * Requires `data['Id']` to be a valid Salesforce Id. Schema-discovers the
     * child SObjectType and FK field by walking the parent's child
     * relationships — zero template-author configuration needed for any
     * standard parent → child schema. Honors the per-transaction SOQL budget;
     * when exhausted, returns a single sentinel bucket with a visible
     * "[Chart limit reached]" notice so authors see when they've stacked too
     * many charts on one document.
     *
     * Returns an empty bucket list (chart renders nothing / falls through to
     * `{:else}`) when:
     *   - data lacks an `Id` field
     *   - the relationship name doesn't exist on the parent's schema
     *   - the field doesn't exist on the child object
     *   - the SOQL fails (FLS, sharing, etc.) — never throws to the renderer
     */
    private static List<Map<String, Object>> tryFallbackSoqlAggregate(
        Map<String, Object> data,
        String relName,
        String fieldApi
    ) {
        List<Map<String, Object>> empty = new List<Map<String, Object>>();
        Object idObj = data.get('Id');
        if (idObj == null) {
            return empty;
        }
        Id parentId;
        try {
            parentId = Id.valueOf(String.valueOf(idObj));
        } catch (Exception e) {
            return empty;
        }

        // SOQL budget check happens BEFORE schema lookup — if we're out of
        // budget there's no point describing schema we won't query.
        if (chartSoqlBudget <= 0) {
            return new List<Map<String, Object>>{
                buildSentinelBucket('[Chart limit reached — max 50 SOQL aggregates per document]')
            };
        }

        Schema.SObjectType parentType = parentId.getSObjectType();
        if (parentType == null) {
            return empty;
        }
        ChildRelMeta meta = findChildRelMeta(parentType, relName);
        if (meta == null) {
            return empty;
        }

        // Validate the group field exists on the child schema. The regex in
        // preprocessInline already restricts fieldApi to [A-Za-z_][A-Za-z0-9_]*
        // so SOQL injection is blocked at the syntax layer; this check is the
        // schema-existence second line of defense.
        Map<String, Schema.SObjectField> childFieldMap = meta.childType.getDescribe().fields.getMap();
        if (!childFieldMap.containsKey(fieldApi.toLowerCase())) {
            return empty;
        }
        if (!isGroupable(childFieldMap, fieldApi)) {
            return empty;
        }

        String soql =
            'SELECT ' +
            fieldApi +
            ', COUNT(Id) cnt FROM ' +
            meta.childObjectName +
            ' WHERE ' +
            meta.lookupFieldName +
            ' = :parentId GROUP BY ' +
            fieldApi +
            ' ORDER BY COUNT(Id) DESC';

        List<AggregateResult> rows;
        try {
            rows = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — identifier-only interpolation; child/field/lookup validated against Schema; parentId bound via :variable
            chartSoqlBudget--;
        } catch (Exception qErr) {
            // Same silent-empty-chart outcome as the advanced path below.
            DocGenErrorLogger.warn(
                'DocGenChartBucketResolver',
                'Chart aggregate query',
                'Chart rendered EMPTY — the aggregate query failed: ' + qErr.getMessage(),
                null,
                String.valueOf(parentId)
            );
            return empty;
        }

        return computeBucketsFromAggregate(rows, fieldApi, meta.childType);
    }

    /**
     * Parent-level COUNT SOQL fallback. Used by DocGenService.resolveAggregate
     * when `{COUNT:Rel}` references a child relationship that wasn't pre-loaded
     * by Query_Config — typically because that relationship is also aggregated
     * by a ChartBucket and we deliberately left it out of the retriever's
     * SELECT to avoid eager-loading 30K+ rows into Apex heap.
     *
     * Returns -1 when the fallback couldn't run (Id missing, relationship not
     * discoverable, query failed) so the caller can distinguish "fallback not
     * available, keep default behavior" from a legitimate zero count.
     *
     * Shares the per-transaction chart SOQL budget: a misconfigured template
     * stacking 50 chart aggregates + 50 COUNT fallbacks would hit governor
     * limits otherwise. When the budget is exhausted, returns -1 (caller
     * falls back to '0').
     */
    public static Integer tryCountFallback(Map<String, Object> data, String relName) {
        if (data == null || String.isBlank(relName)) {
            return -1;
        }
        Object idObj = data.get('Id');
        if (idObj == null) {
            return -1;
        }
        Id parentId;
        try {
            parentId = Id.valueOf(String.valueOf(idObj));
        } catch (Exception idErr) {
            String noop = idErr.getMessage(); // NOPMD UnusedLocalVariable — EmptyCatchBlock
            return -1;
        }

        if (chartSoqlBudget <= 0) {
            return -1;
        }

        Schema.SObjectType parentType = parentId.getSObjectType();
        if (parentType == null) {
            return -1;
        }
        ChildRelMeta meta = findChildRelMeta(parentType, relName);
        if (meta == null) {
            return -1;
        }

        String countSoql =
            'SELECT COUNT() FROM ' +
            meta.childObjectName +
            ' WHERE ' +
            meta.lookupFieldName +
            ' = :parentId';
        try {
            Integer n = Database.countQuery(countSoql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — childObjectName and lookupFieldName validated via Schema; parentId bound
            chartSoqlBudget--;
            return n;
        } catch (Exception qErr) {
            String noop = qErr.getMessage(); // NOPMD UnusedLocalVariable — EmptyCatchBlock
            return -1;
        }
    }

    /**
     * Public dispatcher used by the giant-query path (and any other external
     * caller) to build chart buckets from a `GROUP BY` aggregate result.
     * Handles every combination of v1.91 modifiers:
     *   - groupByField null + splitDelim null → single-dim, sorted desc by count
     *   - groupByField null + splitDelim set  → multi-select split + flat buckets
     *   - groupByField set  + splitDelim *    → pivot rows with cols sub-list
     */
    public static List<Map<String, Object>> buildBucketsFromAggregateRows(
        List<AggregateResult> rows,
        String fieldApi,
        String groupByField,
        Schema.SObjectType childType,
        String splitDelim
    ) {
        return buildBucketsFromAggregateRows(rows, fieldApi, groupByField, childType, splitDelim, null);
    }

    /**
     * Overload accepting an explicit column ordering for pivot output. The
     * `colOrder` list names column VALUES in the order the author wants them
     * to appear; columns not named in the list follow in alpha order; the
     * synthetic Total column always lands last. Pass null to use alpha-only.
     */
    public static List<Map<String, Object>> buildBucketsFromAggregateRows(
        List<AggregateResult> rows,
        String fieldApi,
        String groupByField,
        Schema.SObjectType childType,
        String splitDelim,
        List<String> colOrder
    ) {
        if (String.isNotBlank(groupByField)) {
            return buildPivotBucketsFromRows(rows, fieldApi, groupByField, childType, splitDelim, colOrder);
        }
        if (String.isNotBlank(splitDelim)) {
            return buildSingleDimBucketsFromAggregateWithSplit(rows, fieldApi, childType, splitDelim);
        }
        return computeBucketsFromAggregate(rows, fieldApi, childType);
    }

    /**
     * Parses the `colSort=val1,val2,...` modifier value into an ordered List
     * of column-key strings. Returns null when the input is blank or only
     * whitespace, so callers can pass it directly to buildBucketsFromAggregateRows.
     */
    public static List<String> parseColSortModifier(String modifierValue) {
        if (String.isBlank(modifierValue)) {
            return null;
        }
        List<String> result = new List<String>();
        for (String v : modifierValue.split(',')) {
            String trimmed = v.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result.isEmpty() ? null : result;
    }

    /**
     * Advanced SOQL fallback supporting all v1.91 modifiers in one pass:
     *   - whereClause   — sanitized SOQL fragment appended to WHERE
     *   - groupByField  — second GROUP BY dimension for cross-tab pivot
     *   - splitDelim    — multi-select delimiter (post-process aggregate rows)
     *
     * Returns appropriately-shaped buckets:
     *   - groupByField set      → pivot rows with `cols` sub-list + Total col
     *   - splitDelim set only   → flat buckets with multi-select math
     *     (totalRespondents = sum of combo counts; percent = picks / totalResp;
     *     sums >100% are normal for multi-pick fields)
     *   - neither set           → falls through to the basic SOQL aggregate
     */
    private static List<Map<String, Object>> tryFallbackSoqlAggregateAdvanced(
        Map<String, Object> data,
        String relName,
        String fieldApi,
        String groupByField,
        String whereClause,
        String splitDelim
    ) {
        return tryFallbackSoqlAggregateAdvanced(data, relName, fieldApi, groupByField, whereClause, splitDelim, null);
    }

    private static List<Map<String, Object>> tryFallbackSoqlAggregateAdvanced(
        Map<String, Object> data,
        String relName,
        String fieldApi,
        String groupByField,
        String whereClause,
        String splitDelim,
        List<String> colOrder
    ) {
        // Basic path with no modifiers: delegate to the simpler entry point so
        // existing tests keep covering the simple shape unchanged.
        if (String.isBlank(groupByField) && String.isBlank(whereClause) && String.isBlank(splitDelim)) {
            return tryFallbackSoqlAggregate(data, relName, fieldApi);
        }

        List<Map<String, Object>> empty = new List<Map<String, Object>>();
        Object idObj = data.get('Id');
        if (idObj == null) {
            return empty;
        }
        Id parentId;
        try {
            parentId = Id.valueOf(String.valueOf(idObj));
        } catch (Exception e) {
            return empty;
        }

        if (chartSoqlBudget <= 0) {
            return new List<Map<String, Object>>{
                buildSentinelBucket('[Chart limit reached — max 50 SOQL aggregates per document]')
            };
        }

        Schema.SObjectType parentType = parentId.getSObjectType();
        if (parentType == null) {
            return empty;
        }
        ChildRelMeta meta = findChildRelMeta(parentType, relName);
        if (meta == null) {
            return empty;
        }

        Map<String, Schema.SObjectField> childFieldMap = meta.childType.getDescribe().fields.getMap();
        if (!childFieldMap.containsKey(fieldApi.toLowerCase())) {
            return empty;
        }
        // groupByField must also exist on the child schema
        if (String.isNotBlank(groupByField) && !childFieldMap.containsKey(groupByField.toLowerCase())) {
            return empty;
        }
        if (!isGroupable(childFieldMap, fieldApi)) {
            return empty;
        }
        if (String.isNotBlank(groupByField) && !isGroupable(childFieldMap, groupByField)) {
            return empty;
        }

        // Sanitize the where clause. The shared sanitizer blocks `;`, `--`,
        // `/*`, and DML keywords (the same protections used by Query_Config
        // WHERE clauses). Anything that doesn't pass returns empty buckets
        // rather than running an unsafe SOQL.
        String safeWhere = null;
        if (String.isNotBlank(whereClause)) {
            try {
                safeWhere = DocGenDataRetriever.sanitizeWhereClause(whereClause);
            } catch (Exception sanitizeErr) {
                String noop = sanitizeErr.getMessage(); // NOPMD
                return empty;
            }
        }

        // Build SOQL. Identifier-only interpolation (regex restricts fieldApi
        // and groupByField to `[A-Za-z_][A-Za-z0-9_]*`); parent Id bound; the
        // where clause is the only user-shaped input and passes the sanitizer.
        String soql = 'SELECT ' + fieldApi;
        if (String.isNotBlank(groupByField)) {
            soql += ', ' + groupByField;
        }
        soql += ', COUNT(Id) cnt FROM ' + meta.childObjectName + ' WHERE ' + meta.lookupFieldName + ' = :parentId';
        if (safeWhere != null) {
            soql += ' AND (' + safeWhere + ')';
        }
        soql += ' GROUP BY ' + fieldApi;
        if (String.isNotBlank(groupByField)) {
            soql += ', ' + groupByField;
        } else {
            // Non-pivot path can let SOQL sort. Pivot path re-sorts in Apex.
            soql += ' ORDER BY COUNT(Id) DESC';
        }

        List<AggregateResult> rows;
        try {
            rows = Database.query(soql, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — identifier-only interpolation; lookup, group, and field validated against Schema; whereClause sanitized; parentId bound via :variable
            chartSoqlBudget--;
        } catch (Exception qErr) {
            // A failed aggregate renders an EMPTY chart, not an error — the
            // document generates and looks finished, with a blank where the
            // data should be. Recorded so that is diagnosable after the fact.
            DocGenErrorLogger.warn(
                'DocGenChartBucketResolver',
                'Chart aggregate query',
                'Chart rendered EMPTY — the aggregate query failed: ' + qErr.getMessage(),
                null,
                String.valueOf(parentId)
            );
            return empty;
        }

        if (String.isNotBlank(groupByField)) {
            return buildPivotBucketsFromRows(rows, fieldApi, groupByField, meta.childType, splitDelim, colOrder);
        }
        if (String.isNotBlank(splitDelim)) {
            return buildSingleDimBucketsFromAggregateWithSplit(rows, fieldApi, meta.childType, splitDelim);
        }
        return computeBucketsFromAggregate(rows, fieldApi, meta.childType);
    }

    /**
     * In-memory bucket math with optional multi-select splitting. When the
     * relationship is pre-loaded on the data map and the author hasn't asked
     * for `where=` or `groupBy=`, this is the fast path — no SOQL spent.
     *
     * `splitDelim` of null/blank reduces to the existing `computeBuckets`
     * single-pick behavior. When set, each record's value is split on the
     * delimiter and contributes one pick to each piece (deduplicated within
     * a single record so `"Yes;No;Yes"` counts "Yes" only once for that
     * respondent). Resulting percents are picks / totalRespondents.
     */
    private static List<Map<String, Object>> computeBucketsWithSplit(
        List<Object> records,
        String fieldApi,
        String splitDelim
    ) {
        if (String.isBlank(splitDelim)) {
            return computeBuckets(records, fieldApi, null);
        }
        if (records == null || records.isEmpty()) {
            return new List<Map<String, Object>>();
        }

        Map<String, Integer> pickCounts = new Map<String, Integer>();
        Map<String, String> originalKeys = new Map<String, String>();
        Integer totalRespondents = 0;
        String lowerField = fieldApi.toLowerCase();

        for (Object rec : records) {
            Object rawVal = extractFieldValue(rec, fieldApi, lowerField);
            totalRespondents++;
            // Dedupe within a single combo so `"A;B;A"` counts "A" once for
            // this respondent — matches spreadsheet semantics.
            Set<String> pieces = new Set<String>(splitMultiSelect(rawVal, splitDelim));
            for (String piece : pieces) {
                String mapKey = piece.toLowerCase();
                pickCounts.put(mapKey, (pickCounts.containsKey(mapKey) ? pickCounts.get(mapKey) : 0) + 1);
                if (!originalKeys.containsKey(mapKey)) {
                    originalKeys.put(mapKey, piece);
                }
            }
        }

        return finalizeBucketsFromCounts(pickCounts, originalKeys, totalRespondents, null);
    }

    /**
     * Aggregate-rows version of `computeBucketsWithSplit`. Combo rows from a
     * `GROUP BY` query (each carrying a `cnt`) get split into pieces, and
     * picks accumulate weighted by `cnt`. totalRespondents is the sum of
     * combo counts, not the sum of split pieces — so the percent denominator
     * matches the spreadsheet definition (% of respondents who picked this).
     */
    private static List<Map<String, Object>> buildSingleDimBucketsFromAggregateWithSplit(
        List<AggregateResult> rows,
        String fieldApi,
        Schema.SObjectType childType,
        String splitDelim
    ) {
        Map<String, Integer> pickCounts = new Map<String, Integer>();
        Map<String, String> originalKeys = new Map<String, String>();
        Integer totalRespondents = 0;

        for (AggregateResult ar : rows) {
            Object combo = ar.get(fieldApi);
            Integer cnt = parseCount(ar.get('cnt'));
            totalRespondents += cnt;

            Set<String> pieces = new Set<String>(splitMultiSelect(combo, splitDelim));
            for (String piece : pieces) {
                String mapKey = piece.toLowerCase();
                pickCounts.put(mapKey, (pickCounts.containsKey(mapKey) ? pickCounts.get(mapKey) : 0) + cnt);
                if (!originalKeys.containsKey(mapKey)) {
                    originalKeys.put(mapKey, piece);
                }
            }
        }

        return finalizeBucketsFromCounts(pickCounts, originalKeys, totalRespondents, childType, fieldApi);
    }

    /**
     * Pivot builder: takes rows from a `SELECT row, col, COUNT(Id) GROUP BY
     * row, col` query and produces one bucket per row, each with a `cols`
     * sub-list (one entry per distinct col value, alphabetically sorted, plus
     * a synthetic `Total` column appended last).
     *
     * Per-cell percentages are within-column (`cell / col_total`) — matches
     * the typical cross-tab semantics where each column shows "what % of
     * THIS column chose this row value." The synthetic Total column uses
     * grand_total as its denominator instead, giving an overall view across
     * all columns.
     *
     * `splitDelim` applies to the ROW field only (the field being charted).
     * Pivot + split combine: each row combo splits into pieces, each piece
     * contributes to (piece, col) cells weighted by the row's count.
     */
    private static List<Map<String, Object>> buildPivotBucketsFromRows(
        List<AggregateResult> rows,
        String rowField,
        String colField,
        Schema.SObjectType childType,
        String splitDelim
    ) {
        return buildPivotBucketsFromRows(rows, rowField, colField, childType, splitDelim, null);
    }

    private static List<Map<String, Object>> buildPivotBucketsFromRows(
        List<AggregateResult> rows,
        String rowField,
        String colField,
        Schema.SObjectType childType,
        String splitDelim,
        List<String> colOrder
    ) {
        // rowKey (lower) → { colKey (lower) → cellCount }
        Map<String, Map<String, Integer>> cells = new Map<String, Map<String, Integer>>();
        Map<String, String> rowOriginalKeys = new Map<String, String>();
        Map<String, String> colOriginalKeys = new Map<String, String>();
        Map<String, Integer> rowTotals = new Map<String, Integer>();
        Map<String, Integer> colTotals = new Map<String, Integer>();
        Integer grandTotal = 0;

        Boolean doSplit = String.isNotBlank(splitDelim);

        for (AggregateResult ar : rows) {
            Object rowVal = ar.get(rowField);
            Object colVal = ar.get(colField);
            Integer cnt = parseCount(ar.get('cnt'));

            String colDisplayKey = normalizeKey(colVal);
            String colMapKey = colDisplayKey.toLowerCase();
            if (!colOriginalKeys.containsKey(colMapKey)) {
                colOriginalKeys.put(colMapKey, colDisplayKey);
            }
            colTotals.put(colMapKey, (colTotals.containsKey(colMapKey) ? colTotals.get(colMapKey) : 0) + cnt);
            grandTotal += cnt;

            // Each combo (rowVal) splits into pieces if multi-select.
            // Dedupe within the combo so "A;B;A" → {A, B} for this combo.
            Set<String> pieces;
            if (doSplit) {
                pieces = new Set<String>(splitMultiSelect(rowVal, splitDelim));
            } else {
                pieces = new Set<String>{ normalizeKey(rowVal) };
            }

            for (String piece : pieces) {
                String rowMapKey = piece.toLowerCase();
                if (!rowOriginalKeys.containsKey(rowMapKey)) {
                    rowOriginalKeys.put(rowMapKey, piece);
                }
                if (!cells.containsKey(rowMapKey)) {
                    cells.put(rowMapKey, new Map<String, Integer>());
                }
                Map<String, Integer> rowCells = cells.get(rowMapKey);
                rowCells.put(colMapKey, (rowCells.containsKey(colMapKey) ? rowCells.get(colMapKey) : 0) + cnt);
                rowTotals.put(rowMapKey, (rowTotals.containsKey(rowMapKey) ? rowTotals.get(rowMapKey) : 0) + cnt);
            }
        }

        // Sort row buckets desc by row total
        List<BucketSortable> rowSortable = new List<BucketSortable>();
        for (String rk : rowTotals.keySet()) {
            rowSortable.add(new BucketSortable(rowOriginalKeys.get(rk), rowTotals.get(rk)));
        }
        rowSortable.sort();

        // Sort col keys: author-specified order first (from colSort=), then
        // remaining values alpha-sorted. Total column is appended separately
        // at the bottom of this method.
        List<String> sortedColMapKeys = new List<String>();
        Set<String> placedKeys = new Set<String>();
        if (colOrder != null) {
            for (String requested : colOrder) {
                String lowerReq = requested.trim().toLowerCase();
                if (colTotals.containsKey(lowerReq) && !placedKeys.contains(lowerReq)) {
                    sortedColMapKeys.add(lowerReq);
                    placedKeys.add(lowerReq);
                }
            }
        }
        List<String> remainingColKeys = new List<String>();
        for (String k : colTotals.keySet()) {
            if (!placedKeys.contains(k)) {
                remainingColKeys.add(k);
            }
        }
        remainingColKeys.sort();
        sortedColMapKeys.addAll(remainingColKeys);

        Integer maxRowTotal = 0;
        for (BucketSortable bs : rowSortable) {
            if (bs.count > maxRowTotal) {
                maxRowTotal = bs.count;
            }
        }

        Map<String, String> rowPicklistLabels = resolvePicklistLabels(childType, rowField);
        Map<String, String> colPicklistLabels = resolvePicklistLabels(childType, colField);

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        Integer rowIdx = 1;
        for (BucketSortable rowB : rowSortable) {
            // Row-level fields (same shape as single-dim chart row)
            Map<String, Object> rowMap = buildBucketMap(
                rowB.rawKey,
                rowB.count,
                grandTotal,
                maxRowTotal,
                rowIdx,
                rowPicklistLabels
            );
            // Pivot-specific row-level totals (grand-total denominator)
            Decimal totalPercent = (grandTotal == 0)
                ? (Decimal) 0
                : (Decimal.valueOf(rowB.count) * 100 / grandTotal).setScale(1, System.RoundingMode.HALF_UP);
            rowMap.put('total_count', rowB.count);
            rowMap.put('total_percent', totalPercent);

            // Build cols list — one entry per column key (alpha-sorted), then
            // a synthesized "Total" column. Cells absent in this row count as 0.
            List<Object> colsList = new List<Object>();
            Map<String, Integer> rowCells = cells.get(rowB.rawKey.toLowerCase());
            Integer colIdx = 1;
            for (String cmk : sortedColMapKeys) {
                Integer cellCount = (rowCells != null && rowCells.containsKey(cmk)) ? rowCells.get(cmk) : 0;
                Integer colTot = colTotals.get(cmk);
                Decimal colPercent = (colTot == 0)
                    ? (Decimal) 0
                    : (Decimal.valueOf(cellCount) * 100 / colTot).setScale(1, System.RoundingMode.HALF_UP);
                // percent_of_row: cell / row_total. Lets stacked bars render
                // a single bar per row split into colored segments whose
                // widths sum to 100% — natural CSS 2.1 stacked composition.
                Decimal rowPercent = (rowB.count == 0)
                    ? (Decimal) 0
                    : (Decimal.valueOf(cellCount) * 100 / rowB.count).setScale(1, System.RoundingMode.HALF_UP);
                String colDispKey = colOriginalKeys.get(cmk);
                String colLabel = colPicklistLabels.containsKey(cmk)
                    ? colPicklistLabels.get(cmk)
                    : ((colDispKey == NULL_SENTINEL) ? NOT_SPECIFIED_LABEL : colDispKey);
                Map<String, Object> colMap = new Map<String, Object>();
                colMap.put('key', (colDispKey == NULL_SENTINEL) ? '' : colDispKey);
                colMap.put('key_label', colLabel);
                colMap.put('count', cellCount);
                colMap.put('percent', colPercent);
                colMap.put('percent_int', colPercent.setScale(0, System.RoundingMode.HALF_UP).intValue());
                colMap.put('percent_of_row', rowPercent);
                colMap.put('percent_of_row_int', rowPercent.setScale(0, System.RoundingMode.HALF_UP).intValue());
                colMap.put('index', colIdx);
                String colColor = PALETTE[Math.mod(colIdx - 1, PALETTE.size())];
                colMap.put('color', colColor);
                colMap.put('color_hex', colColor.startsWith('#') ? colColor.substring(1) : colColor);
                colsList.add(colMap);
                colIdx++;
            }
            // Synthetic Total column — count is the row total; percent
            // denominator is grand_total so it represents "this row's share
            // across the whole dataset."
            Map<String, Object> totalCol = new Map<String, Object>();
            totalCol.put('key', 'Total');
            totalCol.put('key_label', 'Total');
            totalCol.put('count', rowB.count);
            totalCol.put('percent', totalPercent);
            totalCol.put('percent_int', totalPercent.setScale(0, System.RoundingMode.HALF_UP).intValue());
            totalCol.put('percent_of_row', (Decimal) 100);
            totalCol.put('percent_of_row_int', 100);
            totalCol.put('index', colIdx);
            String totalColColor = PALETTE[Math.mod(colIdx - 1, PALETTE.size())];
            totalCol.put('color', totalColColor);
            totalCol.put('color_hex', totalColColor.startsWith('#') ? totalColColor.substring(1) : totalColColor);
            colsList.add(totalCol);

            rowMap.put('cols', colsList);
            result.add(rowMap);
            rowIdx++;
        }
        return result;
    }

    /**
     * Splits a value on a delimiter. Handles null/blank values by returning
     * a one-element list containing the NULL sentinel (so the caller can
     * still count "not specified" as a bucket). Uses `\Q...\E` to ensure
     * delimiter chars that happen to be regex metachars (`|`, `.`, etc.)
     * split literally rather than as regex patterns.
     */
    @TestVisible
    private static List<String> splitMultiSelect(Object value, String delim) {
        List<String> result = new List<String>();
        if (value == null) {
            result.add(NULL_SENTINEL);
            return result;
        }
        String s = String.valueOf(value);
        if (String.isBlank(s)) {
            result.add(NULL_SENTINEL);
            return result;
        }
        if (String.isBlank(delim)) {
            result.add(s);
            return result;
        }
        // \Q...\E escapes delim as literal text within the regex
        String pattern = '\\Q' + delim + '\\E';
        for (String piece : s.split(pattern)) {
            String trimmed = piece.trim();
            if (!String.isBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        if (result.isEmpty()) {
            result.add(NULL_SENTINEL);
        }
        return result;
    }

    private static String normalizeKey(Object val) {
        if (val == null) {
            return NULL_SENTINEL;
        }
        String s = String.valueOf(val);
        return String.isBlank(s) ? NULL_SENTINEL : s;
    }

    private static Integer parseCount(Object countObj) {
        if (countObj == null) {
            return 0;
        }
        try {
            return Integer.valueOf(String.valueOf(countObj));
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * Shared bucket-list finalizer used by the multi-select aggregators.
     * Sorts buckets descending by pick count (alphabetic tie-break), computes
     * percents against `totalRespondents`, normalizes max_percent, and packs
     * `buildBucketMap` outputs into a List. Single-arg form leaves picklist
     * label resolution to the caller.
     */
    private static List<Map<String, Object>> finalizeBucketsFromCounts(
        Map<String, Integer> pickCounts,
        Map<String, String> originalKeys,
        Integer totalRespondents,
        Map<String, String> picklistLabels
    ) {
        List<BucketSortable> sortable = new List<BucketSortable>();
        for (String mk : pickCounts.keySet()) {
            sortable.add(new BucketSortable(originalKeys.get(mk), pickCounts.get(mk)));
        }
        sortable.sort();

        Integer maxCount = 0;
        for (BucketSortable bs : sortable) {
            if (bs.count > maxCount) {
                maxCount = bs.count;
            }
        }

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        Integer idx = 1;
        for (BucketSortable bs : sortable) {
            result.add(buildBucketMap(bs.rawKey, bs.count, totalRespondents, maxCount, idx, picklistLabels));
            idx++;
        }
        return result;
    }

    private static List<Map<String, Object>> finalizeBucketsFromCounts(
        Map<String, Integer> pickCounts,
        Map<String, String> originalKeys,
        Integer totalRespondents,
        Schema.SObjectType childType,
        String fieldApi
    ) {
        return finalizeBucketsFromCounts(
            pickCounts,
            originalKeys,
            totalRespondents,
            resolvePicklistLabels(childType, fieldApi)
        );
    }

    /**
     * Walks the parent's child relationships to find the one whose
     * `relationshipName` matches `relName` (case-insensitively), returning the
     * child SObjectType and the lookup field that links child → parent. Cached
     * per transaction since multiple charts on one document commonly target
     * the same relationship.
     */
    private static ChildRelMeta findChildRelMeta(Schema.SObjectType parentType, String relName) {
        String cacheKey = parentType.getDescribe().getName().toLowerCase() + '|' + relName.toLowerCase();
        if (childRelCache.containsKey(cacheKey)) {
            return childRelCache.get(cacheKey);
        }
        ChildRelMeta result = null;
        try {
            for (Schema.ChildRelationship cr : parentType.getDescribe().getChildRelationships()) {
                String crName = cr.getRelationshipName();
                if (String.isNotBlank(crName) && crName.equalsIgnoreCase(relName)) {
                    Schema.SObjectType childType = cr.getChildSObject();
                    Schema.SObjectField fkField = cr.getField();
                    if (childType != null && fkField != null) {
                        result = new ChildRelMeta();
                        result.childType = childType;
                        result.childObjectName = childType.getDescribe().getName();
                        result.lookupFieldName = fkField.getDescribe().getName();
                        break;
                    }
                }
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD
        }
        childRelCache.put(cacheKey, result); // negative results cached too — re-walking won't change them
        return result;
    }

    /**
     * Builds a single-bucket "notice" map used when the SOQL budget is
     * exhausted. Renders inline in the chart body so authors see the cap was
     * hit — preferable to silent empty rendering, which would look like a bug.
     */
    private static Map<String, Object> buildSentinelBucket(String label) {
        Map<String, Object> b = new Map<String, Object>();
        b.put('key', '');
        b.put('key_label', label);
        b.put('count', 0);
        b.put('percent', (Decimal) 0);
        b.put('percent_int', 0);
        b.put('max_percent', (Decimal) 0);
        b.put('index', 1);
        b.put('color', '#9ca3af'); // neutral gray — clearly a notice, not data
        return b;
    }

    private class ChildRelMeta {
        Schema.SObjectType childType;
        String childObjectName;
        String lookupFieldName;
    }

    /**
     * Parses the optional 3rd-colon modifier string into a key→value map.
     * Modifier shape: `key1=value1&key2=value2&...`. Unknown keys are kept in
     * the map (callers consult what they need).
     *
     * Returns an empty map when the input is blank or has no `=`-pairs. Never
     * throws — modifier parsing must never abort the render.
     *
     * Recognized v1.91 modifier keys (consumed downstream of this parser):
     *   - `colors=#aaa,#bbb,#ccc`   — palette override
     *   - `groupBy=Field__c`        — pivot dimension (cross-tab)
     *   - `where=Field__c='Value'`  — filter clause (SOQL where-fragment)
     *   - `split=;`                 — delimiter for multi-select fields
     */
    public static Map<String, String> parseTagModifiers(String modifier) {
        Map<String, String> result = new Map<String, String>();
        if (String.isBlank(modifier)) {
            return result;
        }
        for (String pair : modifier.split('&')) {
            Integer eq = pair.indexOf('=');
            if (eq == -1) {
                continue;
            }
            String key = pair.substring(0, eq).trim().toLowerCase();
            String value = pair.substring(eq + 1).trim();
            if (String.isNotBlank(key)) {
                result.put(key, value);
            }
        }
        return result;
    }

    /**
     * Reads the `colors=` modifier and returns the custom palette, or null if
     * not specified / invalid. Thin wrapper over parseTagModifiers for backward
     * compatibility with code that only needs the palette.
     */
    public static List<String> parsePaletteModifier(String modifier) {
        Map<String, String> mods = parseTagModifiers(modifier);
        String value = mods.get('colors');
        if (String.isBlank(value)) {
            return null;
        }
        List<String> colors = new List<String>();
        for (String c : value.split(',')) {
            String hex = c.trim();
            // Accept #abc, #aabbcc, #aabbccff (3/6/8 hex digits after `#`).
            // Reject anything that doesn't look like a CSS hex color —
            // silently, to avoid breaking the render on a typo.
            if (hex.startsWith('#') && hex.length() >= 4 && hex.length() <= 9) {
                colors.add(hex);
            }
        }
        return colors.isEmpty() ? null : colors;
    }

    /**
     * Scans forward from `startSearch` for the matching {/ChartBucket} closer,
     * counting nested {#ChartBucket:...} openers so accidental nesting doesn't
     * return an inner closer. Returns the index of the matching closer's '{',
     * or -1 if unmatched.
     */
    private static Integer findBalancedChartClose(String xml, Integer startSearch) {
        Integer depth = 1;
        Integer cursor = startSearch;
        Integer len = xml.length();
        while (cursor < len) {
            Integer nextOpen = xml.indexOf(OPEN_TAG_PREFIX, cursor);
            Integer nextClose = xml.indexOf(CLOSE_TAG, cursor);
            if (nextClose == -1) {
                return -1;
            }
            if (nextOpen != -1 && nextOpen < nextClose) {
                depth++;
                cursor = nextOpen + OPEN_TAG_PREFIX.length();
            } else {
                depth--;
                if (depth == 0) {
                    return nextClose;
                }
                cursor = nextClose + CLOSE_TAG.length();
            }
        }
        return -1;
    }

    @TestVisible
    private class BucketSortable implements Comparable {
        public String rawKey;
        public Integer count;
        public BucketSortable(String rawKey, Integer count) {
            this.rawKey = rawKey;
            this.count = count;
        }
        public Integer compareTo(Object other) {
            BucketSortable b = (BucketSortable) other;
            if (this.count != b.count) {
                // Descending by count
                return b.count - this.count;
            }
            // Ascending by key for stable ordering across ties
            return this.rawKey.compareTo(b.rawKey);
        }
    }

    /**
     * Wraps a List<String> with O(1) append and a single O(n) join at the end,
     * avoiding the quadratic cost of repeated String concatenation in the
     * preprocessor's scan loop. Not named "StringBuilder" because Apex's
     * System.Object.toString() isn't virtual; calling our collect() avoids
     * any inheritance ambiguity.
     */
    private class ChunkBuffer {
        private List<String> parts = new List<String>();
        public ChunkBuffer append(String s) {
            if (s != null && s.length() > 0) {
                parts.add(s);
            }
            return this;
        }
        public String collect() {
            return String.join(parts, '');
        }
    }
}

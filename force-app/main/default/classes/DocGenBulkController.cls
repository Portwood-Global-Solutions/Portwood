public with sharing class DocGenBulkController {
    /**
     * Returns all Portwood templates for the bulk generation UI.
     * @return List of DocGen_Template__c records ordered by name
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Template__c> getBulkTemplates() {
        // v2.0.1 — per-field FLS enforcement on SOQL reads (the "Apex SOQL
        // USER_MODE Missing" finding category). DocGenFlsGuard.assertAccessible
        // calls Schema.SObjectField.getDescribe().isAccessible() on every field
        // the SELECT lists; throws DocGenException with the offending field name
        // before any query runs. SYSTEM_MODE on the SOQL sidesteps the
        // package-build @TestSetup FLS-propagation issue documented in
        // DocGenFlsGuard.cls.
        DocGenFlsGuard.assertAccessible(
            DocGen_Template__c.sObjectType,
            new Set<String>{
                'Name',
                'Base_Object_API__c',
                'Description__c',
                'Output_Format__c',
                'Query_Config__c',
                'Test_Record_Id__c',
                'Category__c',
                'Sort_Order__c',
                'Lock_Output_Format__c',
                'Required_Permission_Sets__c',
                'Record_Filter__c'
            }
        );
        // Is_Active__c mirrors the single-record runner exactly
        // (getTemplatesForObjectInternal uses `!= FALSE`). Without it a
        // DEACTIVATED template stayed selectable here — and this is the bulk
        // screen, so the blast radius is a job across thousands of records rather
        // than one document.
        //
        // `!= FALSE`, NOT `= TRUE OR = NULL`. Is_Active__c is a CHECKBOX, and SOQL
        // treats `= NULL` on a Boolean as `= FALSE` — so the OR-NULL form matched
        // every row and filtered nothing. It looked right, deployed clean, and the
        // test kept failing until the predicate itself was checked against a
        // known-inactive record.
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> all = [
            SELECT
                Id,
                Name,
                Base_Object_API__c,
                Description__c,
                Output_Format__c,
                Query_Config__c,
                Test_Record_Id__c,
                Category__c,
                Sort_Order__c,
                Lock_Output_Format__c,
                Required_Permission_Sets__c,
                Record_Filter__c
            FROM DocGen_Template__c
            WHERE Is_Active__c != FALSE
            WITH SYSTEM_MODE
            ORDER BY Sort_Order__c ASC NULLS LAST, Name ASC
            LIMIT 2000
        ];

        // Bulk has no single record, so pass null to apply only sharing + audience filters.
        return DocGenController.filterTemplatesForSender(all, null);
    }

    /**
     * Validates a SOQL WHERE clause filter and returns the count of matching records.
     * @param objectName The SObject API name to query against
     * @param condition The WHERE clause condition to validate
     * @return The number of records matching the filter
     */
    @AuraEnabled
    public static Integer validateFilter(String objectName, String condition) {
        if (String.isBlank(objectName)) {
            return 0;
        }
        // Allowlist validation: object verified against Schema.getGlobalDescribe()
        SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw DocGenService.ahe('Invalid or inaccessible object.');
        }
        String sanitizedCondition = sanitizeCondition(condition);
        // Allowlist validation: WHERE clause field names verified against Schema.describeSObjects() field map
        if (String.isNotBlank(sanitizedCondition)) {
            Map<String, Schema.SObjectField> fieldMap = objType.getDescribe().fields.getMap();
            validateWhereClauseFields(sanitizedCondition, fieldMap);
        }
        String query = 'SELECT Count() FROM ' + String.escapeSingleQuotes(objectName);
        if (String.isNotBlank(sanitizedCondition)) {
            query += ' WHERE ' + sanitizedCondition;
        }
        // CxSAST: SOQL injection mitigated by Schema allowlist validation on object + WHERE field names verified against Schema.describeSObjects() field map + keyword blocklist + USER_MODE
        return Database.countQuery(query, AccessLevel.USER_MODE); // NOPMD ApexSOQLInjection — object allowlist-validated against Schema.getGlobalDescribe(); condition fields allowlist-validated against Schema field map; USER_MODE enforced
    }

    /**
     * Allowlist validation: extracts field-name tokens from a WHERE clause and validates
     * each against the provided Schema field map. Tokens that look like values (quoted strings,
     * numbers, dates, booleans, null, bind variables) are skipped.
     */
    @TestVisible
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
            // This looks like a field name — allowlist validate against Schema
            String baseField = t.contains('.') ? t.split('\\.')[0].toLowerCase() : t.toLowerCase();
            if (!fieldMap.containsKey(baseField)) {
                // Try __r -> __c for custom relationship traversals
                String asLookup = baseField.endsWith('__r')
                    ? baseField.substring(0, baseField.length() - 3) + '__c'
                    : baseField;
                if (!fieldMap.containsKey(asLookup)) {
                    throw DocGenService.ahe('Invalid field in filter condition: ' + t);
                }
            }
        }
    }

    /**
     * Sanitization of dynamic WHERE conditions to prevent SOQL injection.
     * Two layers: (1) keyword blocklist rejects structural SOQL/DML keywords,
     * (2) caller performs allowlist validation of field names against Schema describe.
     */
    public static String sanitizeCondition(String condition) {
        if (String.isBlank(condition)) {
            return condition;
        }
        // Reject dangerous characters (statement termination, comments)
        if (condition.contains(';') || condition.contains('--') || condition.contains('/*')) {
            throw DocGenService.ahe('Invalid filter condition.');
        }
        // Normalize whitespace for keyword matching (tabs, newlines, multiple spaces -> single space)
        String normalized = condition.replaceAll('\\s+', ' ').toUpperCase().trim();
        // Reject conditions containing SOQL/DML keywords that don't belong in a WHERE clause
        List<String> disallowed = new List<String>{
            'SELECT ',
            'INSERT ',
            'UPDATE ',
            'DELETE ',
            'MERGE ',
            'UNDELETE ',
            'WITH ',
            'GROUP BY ',
            'ORDER BY ',
            'LIMIT ',
            'OFFSET ',
            'FOR UPDATE',
            'HAVING ',
            'TYPEOF '
        };
        for (String keyword : disallowed) {
            if (normalized.contains(keyword)) {
                throw DocGenService.ahe('Invalid filter condition.');
            }
        }
        return condition;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Sort order (parent-level ORDER BY for the bulk query)
    //
    // The bulk query had no ORDER BY at all, so records were processed in
    // whatever order the QueryLocator returned them — effectively record Id, i.e.
    // creation order. That is invisible for individual files but decides page
    // order in a merged PDF: DocGenBatch stamps a zero-padded counter on each
    // HTML snippet as it processes records, and DocGenMergeJob assembles by that
    // title. Sorting the locator therefore sorts the packet, with no change to
    // the merge pipeline itself.
    // ─────────────────────────────────────────────────────────────────────────

    /** Relationship hops permitted in one sort field path (Account.Owner.Name = 2). */
    private static final Integer MAX_SORT_HOPS = 2;

    /** Sort terms permitted in one clause — bounded so the result fits Sort_Order__c (255). */
    private static final Integer MAX_SORT_TERMS = 3;

    /**
     * Validates a SOQL ORDER BY clause against the base object's schema and returns
     * it in canonical form (correct field casing, explicit direction and NULLS
     * handling on every term).
     *
     * Deliberately NOT DocGenDataRetriever.sanitizeClause(…, 'ORDER BY', …), which
     * validates the CHILD-relationship sort clauses stored in a Query Config. That
     * one keeps a free-text clause intact for an author editing raw SOQL; this one
     * backs a field picker, so it can canonicalize, verify the field is actually
     * sortable, and check what follows a relationship hop rather than only the
     * token before the dot.
     *
     * Injection defense is an ALLOWLIST OF CHARACTERS, not a keyword blocklist like
     * sanitizeCondition(). An ORDER BY clause needs only field paths, commas,
     * spaces and the ASC/DESC/NULLS/FIRST/LAST keywords — quotes, parentheses,
     * semicolons and comment markers have no legitimate use here, so rejecting
     * every character outside that alphabet leaves nothing to keep ahead of. Every
     * field path is then resolved through Schema describe, so an unknown field is
     * an error at submit time rather than a batch that dies in start().
     *
     * @param objectName The base SObject the bulk query runs against
     * @param sortOrder Author-supplied clause, with or without a leading "ORDER BY"
     * @return The canonical clause, or null when nothing was supplied
     */
    public static String normalizeSortOrder(String objectName, String sortOrder) {
        if (String.isBlank(sortOrder)) {
            return null;
        }
        SObjectType objType = String.isBlank(objectName) ? null : Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            throw new DocGenException('Invalid or inaccessible object: ' + objectName);
        }
        String clause = sortOrder.trim();
        // Authors paste the whole clause as readily as just the field list.
        if (clause.length() > 9 && clause.substring(0, 9).equalsIgnoreCase('ORDER BY ')) {
            clause = clause.substring(9).trim();
        }
        if (!Pattern.matches('[A-Za-z0-9_., ]+', clause)) {
            throw new DocGenException('Invalid characters in sort order: ' + sortOrder);
        }

        List<String> terms = new List<String>();
        Set<String> seenPaths = new Set<String>();
        for (String rawTerm : clause.split(',')) {
            String term = rawTerm.trim();
            if (String.isBlank(term)) {
                continue;
            }
            if (terms.size() >= MAX_SORT_TERMS) {
                throw new DocGenException('A sort order may combine at most ' + MAX_SORT_TERMS + ' fields.');
            }
            terms.add(normalizeSortTerm(objType, term, seenPaths));
        }
        if (terms.isEmpty()) {
            return null;
        }

        // Deterministic tie-break. Sorting 200 Opportunities by Account.Name leaves
        // every same-account group in arbitrary order, so two runs of the same job
        // can produce two different packets. Appending the base object's own name
        // field makes the order reproducible; skipped when the author already
        // supplied more than one term, or when that field is already in the clause.
        if (terms.size() == 1) {
            String tieBreak = nameFieldPath(objType);
            if (tieBreak != null && !seenPaths.contains(tieBreak.toLowerCase())) {
                terms.add(tieBreak + ' ASC NULLS LAST');
            }
        }

        String result = String.join(terms, ', ');
        if (result.length() > 255) {
            throw new DocGenException('Sort order is too long — use fewer or shorter fields.');
        }
        return result;
    }

    /**
     * Canonicalizes one `Field [ASC|DESC] [NULLS FIRST|LAST]` term.
     */
    private static String normalizeSortTerm(SObjectType objType, String term, Set<String> seenPaths) {
        List<String> tokens = term.split(' +');
        String path = validateSortFieldPath(objType, tokens[0]);
        if (!seenPaths.add(path.toLowerCase())) {
            throw new DocGenException('Duplicate sort field: ' + tokens[0]);
        }

        String direction = 'ASC';
        String nullsClause = null;
        Integer i = 1;
        if (i < tokens.size() && (tokens[i].equalsIgnoreCase('ASC') || tokens[i].equalsIgnoreCase('DESC'))) {
            direction = tokens[i].toUpperCase();
            i++;
        }
        if (i < tokens.size() && tokens[i].equalsIgnoreCase('NULLS')) {
            i++;
            if (i >= tokens.size() || !(tokens[i].equalsIgnoreCase('FIRST') || tokens[i].equalsIgnoreCase('LAST'))) {
                throw new DocGenException('NULLS must be followed by FIRST or LAST: ' + term);
            }
            nullsClause = ' NULLS ' + tokens[i].toUpperCase();
            i++;
        }
        if (i < tokens.size()) {
            throw new DocGenException('Unrecognized sort option: ' + tokens[i]);
        }
        // SOQL sorts blanks first on an ascending sort, which would open a merged
        // packet with the records that have nothing in the sort field. Default the
        // empties to the back unless the author asked for the opposite.
        if (nullsClause == null) {
            nullsClause = ' NULLS LAST';
        }
        return path + ' ' + direction + nullsClause;
    }

    /**
     * Resolves a (possibly relationship-traversing) sort field path against Schema
     * and returns it with the API's own casing. Throws for anything unknown,
     * unsortable, or beyond MAX_SORT_HOPS.
     *
     * Polymorphic lookups (OwnerId on Case, WhatId on Task) are carried as a LIST
     * of candidate types: SOQL only permits traversing one when the field being
     * reached exists on every type the lookup can point at, so that is exactly the
     * condition checked at each hop.
     */
    @TestVisible
    private static String validateSortFieldPath(SObjectType objType, String path) {
        List<String> parts = path.split('\\.');
        if (parts.size() > MAX_SORT_HOPS + 1) {
            throw new DocGenException('A sort field may traverse at most ' + MAX_SORT_HOPS + ' relationships: ' + path);
        }
        List<SObjectType> currentTypes = new List<SObjectType>{ objType };
        List<String> canonical = new List<String>();

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            if (String.isBlank(part)) {
                throw new DocGenException('Invalid sort field: ' + path);
            }
            Boolean isLast = (i == parts.size() - 1);

            if (isLast) {
                String resolvedName = null;
                for (SObjectType t : currentTypes) {
                    Schema.SObjectField f = t.getDescribe().fields.getMap().get(part.toLowerCase());
                    if (f == null) {
                        throw new DocGenException('Unknown sort field: ' + path);
                    }
                    Schema.DescribeFieldResult dfr = f.getDescribe();
                    if (!dfr.isSortable()) {
                        throw new DocGenException('This field cannot be sorted on: ' + path);
                    }
                    resolvedName = dfr.getName();
                }
                canonical.add(resolvedName);
            } else {
                List<SObjectType> nextTypes = new List<SObjectType>();
                String relationshipName = null;
                for (SObjectType t : currentTypes) {
                    Schema.DescribeFieldResult rel = findRelationshipField(t, part);
                    if (rel == null) {
                        throw new DocGenException('Unknown relationship in sort field: ' + part);
                    }
                    relationshipName = rel.getRelationshipName();
                    nextTypes.addAll(rel.getReferenceTo());
                }
                canonical.add(relationshipName);
                currentTypes = nextTypes;
            }
        }
        return String.join(canonical, '.');
    }

    /**
     * Finds the lookup field on objType whose relationship name matches relName
     * (`Account` -> AccountId, `Custom__r` -> Custom__c). Null when there is none.
     */
    private static Schema.DescribeFieldResult findRelationshipField(SObjectType objType, String relName) {
        for (Schema.SObjectField f : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (dfr.getType() != Schema.DisplayType.REFERENCE || dfr.getReferenceTo().isEmpty()) {
                continue;
            }
            if (relName.equalsIgnoreCase(dfr.getRelationshipName())) {
                return dfr;
            }
        }
        return null;
    }

    /** The object's sortable name field (`Name`, `CaseNumber`, …), or null when it has none. */
    private static String nameFieldPath(SObjectType objType) {
        for (Schema.SObjectField f : objType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (dfr.isNameField() && dfr.isSortable()) {
                return dfr.getName();
            }
        }
        return null;
    }

    /**
     * Field options for the bulk runner's Sort By picker: every sortable field on
     * the base object, plus the name field of each lookup's parent so the common
     * "order these Opportunities by Account name" case is one click rather than a
     * hand-typed relationship path.
     *
     * @param objectName The base SObject the bulk query runs against
     * @return Picklist-shaped options, ordered by label
     */
    @AuraEnabled(cacheable=true)
    public static List<SortFieldOption> getSortableFields(String objectName) {
        try {
            SObjectType objType = String.isBlank(objectName) ? null : Schema.getGlobalDescribe().get(objectName);
            if (objType == null) {
                return new List<SortFieldOption>();
            }
            List<SortFieldOption> options = new List<SortFieldOption>();
            List<Schema.DescribeFieldResult> lookups = new List<Schema.DescribeFieldResult>();

            for (Schema.SObjectField f : objType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult dfr = f.getDescribe();
                if (!dfr.isSortable() || !dfr.isAccessible()) {
                    continue;
                }
                options.add(new SortFieldOption(dfr.getLabel(), dfr.getName()));
                // Single-target lookups only: a polymorphic one needs the reached
                // field to exist on every candidate type, which is more than a
                // picker entry can promise.
                if (dfr.getType() == Schema.DisplayType.REFERENCE && dfr.getReferenceTo().size() == 1) {
                    lookups.add(dfr);
                }
            }

            for (Schema.DescribeFieldResult lookup : lookups) {
                if (String.isBlank(lookup.getRelationshipName())) {
                    continue;
                }
                SObjectType parent = lookup.getReferenceTo()[0];
                for (Schema.SObjectField pf : parent.getDescribe().fields.getMap().values()) {
                    Schema.DescribeFieldResult pdfr = pf.getDescribe();
                    if (!pdfr.isNameField() || !pdfr.isSortable() || !pdfr.isAccessible()) {
                        continue;
                    }
                    options.add(
                        new SortFieldOption(
                            lookup.getLabel() + ' > ' + pdfr.getLabel(),
                            lookup.getRelationshipName() + '.' + pdfr.getName()
                        )
                    );
                    break;
                }
            }

            options.sort();
            return options;
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error loading sortable fields.');
        }
    }

    /** One entry in the bulk runner's Sort By picker. */
    public class SortFieldOption implements Comparable {
        @AuraEnabled
        public String label { get; set; }
        @AuraEnabled
        public String value { get; set; }

        public SortFieldOption(String label, String value) {
            this.label = label;
            this.value = value;
        }

        public Integer compareTo(Object other) {
            SortFieldOption o = (SortFieldOption) other;
            Integer byLabel = this.label.compareTo(o.label);
            // Labels are not unique on a Salesforce object; fall back to the API
            // name so the picker order is stable rather than describe-order.
            return byLabel != 0 ? byLabel : this.value.compareTo(o.value);
        }
    }

    /**
     * Analyzes a bulk job for governor limit risks before execution.
     * Checks SOQL queries, DML statements, heap (merge mode), and record count.
     * @param templateId The Portwood template record ID
     * @param recordCount Total number of records to be processed
     * @param batchSize Records per batch execution
     * @param mergePdf Whether merge mode is enabled
     * @param duplexPadding Whether Combined-PDF duplex padding is on (#382) — its
     *        merge renders a PDF per record and stitches them, which has a much
     *        lower record ceiling than the HTML-concatenation merge.
     * @return JobAnalysis with per-check results and overall verdict
     */
    @AuraEnabled
    public static JobAnalysis analyzeJob(
        Id templateId,
        Integer recordCount,
        Integer batchSize,
        Boolean mergePdf,
        Boolean duplexPadding
    ) {
        // canProceed gates the Run button and is reserved for HARD blockers only —
        // conditions no batch size or record set can work around (unsupported
        // template/mode combination, or the platform's own QueryLocator ceiling).
        //
        // The SOQL / DML / heap items below are ESTIMATES computed in this
        // synchronous Aura request and are systematically pessimistic about the
        // async job they describe: they measure a 6MB-ceiling transaction against
        // the 12MB async ceiling, multiply DocGenBatch's once-per-execute() fixed
        // costs by batch size, and ignore both the shared dataCache (which drops
        // per-record SOQL to ~0) and DocGenBulkGiantFallbackJob (which already
        // re-runs heap-failed records one per Queueable). They stay visible as
        // 'error' items so the panel keeps its diagnostic value, but they must not
        // disable the button — the server enforces none of them, so the Flow
        // action happily runs the exact same job the UI was refusing.
        JobAnalysis analysis = new JobAnalysis();
        analysis.recordCount = recordCount;
        analysis.items = new List<AnalysisItem>();
        analysis.canProceed = true;

        if (templateId == null || recordCount == null || recordCount <= 0) {
            analysis.summary = 'No records to process.';
            return analysis;
        }

        Integer safeBatchSize = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
        Boolean isMerge = (mergePdf == true);

        try {
            DocGenFlsGuard.assertAccessible(
                DocGen_Template__c.sObjectType,
                new Set<String>{ 'Query_Config__c', 'Test_Record_Id__c', 'Output_Format__c', 'Type__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            List<DocGen_Template__c> tempList = [
                SELECT Query_Config__c, Test_Record_Id__c, Output_Format__c, Type__c
                FROM DocGen_Template__c
                WHERE Id = :templateId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            DocGen_Template__c temp = tempList[0];
            Boolean isFillablePdfTemplate = temp.Type__c == 'PDF';

            if (isMerge && isFillablePdfTemplate) {
                AnalysisItem formatItem = new AnalysisItem();
                formatItem.label = 'Template Format';
                formatItem.status = 'error';
                formatItem.message =
                    'Fillable PDF templates can be generated in bulk as Individual Files. ' +
                    'Merged PDF and Merge Only modes are not supported for fillable PDF templates.';
                analysis.items.add(formatItem);
                analysis.canProceed = false;
            }

            // PowerPoint / Excel have no DOCX→HTML conversion, so there is nothing to
            // merge into a combined PDF. A genuine hard blocker, not an estimate.
            if (isMerge && (temp.Type__c == 'PowerPoint' || temp.Type__c == 'Excel')) {
                AnalysisItem mergeItem = new AnalysisItem();
                mergeItem.label = 'Template Format';
                mergeItem.status = 'error';
                mergeItem.message =
                    temp.Type__c +
                    ' templates cannot be combined into a single PDF. ' +
                    'Switch to Individual Files to get one file per record.';
                analysis.items.add(mergeItem);
                analysis.canProceed = false;
            }

            // --- 1. SOQL Queries per batch execution ---
            Integer queriesPerRecord = countQueriesPerRecord(temp.Query_Config__c);
            // Overhead: template load (~3 queries first batch, cached after), job update (1)
            Integer overhead = 4;
            Integer soqlPerBatch = (queriesPerRecord * safeBatchSize) + overhead;
            Integer soqlLimit = 100; // async limit

            AnalysisItem soqlItem = new AnalysisItem();
            soqlItem.label = 'SOQL Queries';
            soqlItem.estimated = soqlPerBatch;
            soqlItem.limitVal = soqlLimit;
            if (soqlPerBatch > soqlLimit) {
                soqlItem.status = 'error';
                soqlItem.message =
                    soqlPerBatch +
                    ' / ' +
                    soqlLimit +
                    ' per batch — worst case exceeds the limit. This estimate assumes every record ' +
                    're-runs the full query tree; the batch job caches shared data and usually issues ' +
                    'far fewer. Reduce batch size to ' +
                    Math.max(1, Math.floor((soqlLimit - overhead) / queriesPerRecord)) +
                    ' or lower if the job fails.';
            } else if (soqlPerBatch >= 80) {
                soqlItem.status = 'warning';
                soqlItem.message =
                    soqlPerBatch +
                    ' / ' +
                    soqlLimit +
                    ' per batch — approaching limit. Consider reducing batch size.';
            } else {
                soqlItem.status = 'ok';
                soqlItem.message = soqlPerBatch + ' / ' + soqlLimit + ' per batch.';
            }
            analysis.items.add(soqlItem);

            // --- 2. DML Statements per batch execution ---
            // Each record: 1 CV insert. Merge mode: +1 HTML snippet CV per record. Job update: 1.
            Integer dmlPerRecord = isMerge ? 2 : 1;
            Integer dmlPerBatch = (dmlPerRecord * safeBatchSize) + 1;
            Integer dmlLimit = 150;

            AnalysisItem dmlItem = new AnalysisItem();
            dmlItem.label = 'DML Statements';
            dmlItem.estimated = dmlPerBatch;
            dmlItem.limitVal = dmlLimit;
            if (dmlPerBatch > dmlLimit) {
                dmlItem.status = 'error';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — exceeds the limit. Reduce batch size.';
            } else if (dmlPerBatch >= 120) {
                dmlItem.status = 'warning';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch — approaching limit.';
            } else {
                dmlItem.status = 'ok';
                dmlItem.message = dmlPerBatch + ' / ' + dmlLimit + ' per batch.';
            }
            analysis.items.add(dmlItem);

            // --- 3. Record Count ---
            AnalysisItem countItem = new AnalysisItem();
            countItem.label = 'Record Count';
            countItem.estimated = recordCount;
            countItem.limitVal = 50000;
            if (recordCount > 50000) {
                countItem.status = 'error';
                countItem.message = recordCount + ' records — exceeds 50,000 batch query locator limit.';
                analysis.canProceed = false;
            } else if (recordCount > 10000) {
                countItem.status = 'warning';
                countItem.message = recordCount + ' records — large job, may take a while.';
            } else {
                countItem.status = 'ok';
                countItem.message = recordCount + ' records.';
            }
            analysis.items.add(countItem);

            // --- 3b. Duplex packet ceiling (#382) ---
            // A duplex packet renders a PDF per record and assembles them ALL in
            // one Queueable (12 MB async heap). The real ceiling is driven by
            // output SIZE, not record count — a lightweight text document packs
            // ~400, a branded template with a logo and an embedded font
            // (~180 KB/doc) fails near 60. When the template has a Test Record we
            // render one and size the ceiling to it; otherwise we fall back to a
            // conservative record-count cap. This runs unconditionally — it must
            // NOT sit behind the Test_Record_Id__c gate below, or a template with
            // no test record gets no block at all.
            if (isMerge && duplexPadding == true) {
                AnalysisItem dItem = new AnalysisItem();
                dItem.label = 'Duplex Packet';
                dItem.estimated = recordCount;

                Integer maxDocs = 400; // count-based fallback / absolute cap
                Long perDocBytes = null;
                if (String.isNotBlank(temp.Test_Record_Id__c)) {
                    try {
                        // Estimate the per-document size from ONE HTML render — never a
                        // real Blob.toPdf here. analyzeJob is @AuraEnabled and runs
                        // synchronously in the panel request; Blob.toPdf is the heaviest,
                        // most OOM-prone step and its LimitException can be uncatchable,
                        // which would take the whole pre-flight panel down. The HTML
                        // output length is a safe over-estimate of the PDF byte size
                        // (base64 fonts/images inflate the HTML more than the PDF), and
                        // over-estimating only tightens the ceiling (#382).
                        String oneDocHtml = DocGenService.generateHtmlForRecord(
                            templateId,
                            temp.Test_Record_Id__c,
                            null
                        );
                        perDocBytes = (oneDocHtml == null) ? null : (Long) oneDocHtml.length();
                        oneDocHtml = null;
                        maxDocs = duplexPacketMaxDocs(perDocBytes);
                    } catch (Exception e) {
                        // A heap failure rendering ONE record is itself a signal the
                        // template is heavy — cap hard rather than fall back to 400.
                        String m = (e.getMessage() == null) ? '' : e.getMessage().toLowerCase();
                        maxDocs = m.contains('heap') ? 50 : 400;
                    }
                }
                Integer warnDocs = Math.max(1, (Integer) (maxDocs * 0.65));
                dItem.limitVal = maxDocs;
                String sizeNote = (perDocBytes != null)
                    ? ' (~' + ((Integer) (perDocBytes / 1024)) + ' KB per document)'
                    : '';

                if (recordCount > maxDocs) {
                    dItem.status = 'error';
                    dItem.message =
                        recordCount +
                        ' documents' +
                        sizeNote +
                        ' — a duplex packet is assembled in one job, and this template tops out near ' +
                        maxDocs +
                        '. Turn off Duplex Padding, switch to Individual Files, or narrow the filter.';
                    analysis.canProceed = false;
                } else if (recordCount > warnDocs) {
                    dItem.status = 'warning';
                    dItem.message =
                        recordCount +
                        ' documents' +
                        sizeNote +
                        ' — large duplex packet, near this template\'s ~' +
                        maxDocs +
                        ' ceiling. If assembly fails, run Individual Files or split the filter.';
                } else {
                    dItem.status = 'ok';
                    dItem.message =
                        recordCount +
                        ' documents' +
                        sizeNote +
                        ' — within the duplex packet limit (~' +
                        maxDocs +
                        ').';
                }
                analysis.items.add(dItem);
            }

            // --- 4. Heap estimation ---
            if (isMerge && isFillablePdfTemplate) {
                AnalysisItem heapItem = new AnalysisItem();
                heapItem.label = 'Heap Estimate';
                heapItem.status = 'error';
                heapItem.message = 'Merged bulk output is unavailable for fillable PDF templates.';
                analysis.items.add(heapItem);
            } else if (String.isNotBlank(temp.Test_Record_Id__c)) {
                try {
                    // Measure actual heap consumed by generation (queries + template + rendering)
                    Integer heapBefore = Limits.getHeapSize();
                    String html = DocGenService.generateHtmlForRecord(templateId, temp.Test_Record_Id__c, null);
                    Integer heapAfter = Limits.getHeapSize();
                    // Generation heap = full cost (queries + parsing + rendering) — used for batch estimate
                    Long generationBytes = Math.max(heapAfter - heapBefore, html.length() * 2);
                    // Snippet size = just the HTML output — used for merge estimate
                    // Merge Queueable only reads back saved HTML snippets, not full generation heap
                    Long snippetBytes = html.length() * 2; // UTF-16

                    if (isMerge && duplexPadding != true) {
                        // Merge heap: Queueable reads all HTML snippets + concatenates + Blob.toPdf()
                        // (Duplex packets are sized by the unconditional 3b check above.)
                        AnalysisItem heapItem = new AnalysisItem();
                        heapItem.label = 'Merge Heap';
                        heapItem.limitVal = 12;
                        // snippetBytes × records × 1.5 (overhead for string concat + PDF render)
                        Decimal totalMb = ((snippetBytes * recordCount) * 1.5) / (1024.0 * 1024.0);
                        heapItem.estimated = totalMb.setScale(2);

                        if (totalMb >= 10.0) {
                            heapItem.status = 'error';
                            heapItem.message =
                                totalMb.setScale(1) +
                                'MB / 12MB — high risk of heap failure. Records that run out of heap are ' +
                                'automatically retried one at a time, so the job can still finish. To lower the ' +
                                'risk, reduce record count or switch to Individual Files.';
                        } else if (totalMb >= 7.0) {
                            heapItem.status = 'warning';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — moderate usage, monitor job.';
                        } else {
                            heapItem.status = 'ok';
                            heapItem.message = totalMb.setScale(1) + 'MB / 12MB — safe.';
                        }
                        analysis.items.add(heapItem);
                    }

                    // Per-batch heap: measured heap × batch size (each execute() gets fresh 12MB)
                    AnalysisItem batchHeapItem = new AnalysisItem();
                    batchHeapItem.label = 'Batch Heap';
                    batchHeapItem.limitVal = 12;
                    Decimal batchMb = ((generationBytes * safeBatchSize) * 1.3) / (1024.0 * 1024.0);
                    batchHeapItem.estimated = batchMb.setScale(2);

                    if (batchMb >= 10.0) {
                        batchHeapItem.status = 'error';
                        // Suggesting a batch size the user is already at is a dead end —
                        // it reads as "do something" while offering nothing to do. When a
                        // single record alone trips the estimate, say so instead.
                        Integer suggestedBatch = Math.max(
                            1,
                            Integer.valueOf(Math.floor(9.0 / (batchMb / safeBatchSize)))
                        );
                        batchHeapItem.message =
                            batchMb.setScale(1) +
                            'MB / 12MB per batch — ' +
                            (suggestedBatch < safeBatchSize
                                ? 'reduce batch size to ' + suggestedBatch + ' or lower.'
                                : 'one record alone approaches the async heap ceiling. This figure is measured ' +
                                  'in a 6MB synchronous request and overstates the batch job, which gets a fresh ' +
                                  '12MB per execution; records that do run out of heap are retried individually.');
                    } else if (batchMb >= 7.0) {
                        batchHeapItem.status = 'warning';
                        batchHeapItem.message =
                            batchMb.setScale(1) + 'MB / 12MB per batch — consider reducing batch size.';
                    } else {
                        batchHeapItem.status = 'ok';
                        batchHeapItem.message = batchMb.setScale(1) + 'MB / 12MB per batch.';
                    }
                    analysis.items.add(batchHeapItem);
                } catch (Exception e) {
                    AnalysisItem heapItem = new AnalysisItem();
                    heapItem.label = 'Heap Estimate';
                    heapItem.status = 'warning';
                    heapItem.message = 'Could not estimate — test record may be inaccessible.';
                    analysis.items.add(heapItem);
                }
            } else {
                AnalysisItem heapItem = new AnalysisItem();
                heapItem.label = 'Heap Estimate';
                heapItem.status = 'warning';
                heapItem.message = 'No test record on template — heap estimate unavailable.';
                analysis.items.add(heapItem);
            }

            // --- Build summary ---
            Integer errors = 0;
            Integer warnings = 0;
            for (AnalysisItem item : analysis.items) {
                if (item.status == 'error') {
                    errors++;
                } else if (item.status == 'warning') {
                    warnings++;
                }
            }
            // "Cannot proceed" is now driven by canProceed (hard blockers only), not by
            // the error count — an over-limit ESTIMATE is a risk to flag, not a veto.
            if (!analysis.canProceed) {
                analysis.summary = 'Cannot proceed — see the blocking item(s) below.';
            } else if (errors > 0) {
                analysis.summary =
                    'You can run this, but ' +
                    errors +
                    ' estimate(s) exceed a limit — the job may need a smaller batch size to finish cleanly.';
            } else if (warnings > 0) {
                analysis.summary = 'Should work, but ' + warnings + ' item(s) need attention.';
            } else {
                analysis.summary = 'All checks passed. Safe to proceed.';
            }
        } catch (Exception e) {
            analysis.summary = 'Analysis error: ' + e.getMessage();
        }
        return analysis;
    }

    /**
     * The largest duplex packet this template can assemble in one Queueable,
     * from the size of one document (#382). The merge job holds the whole packet
     * as a hex string inside the 12 MB async heap; ~11 MB is the safe budget
     * after GC variance. The merged output is smaller than the sum of the parts
     * (font deduplication, structural overlap), so the peak works out near ~1.2x
     * a part per document.
     *
     * `perDocBytes` is the HTML-render length, not a real PDF size — analyzeJob
     * must not run Blob.toPdf synchronously (see caller). The HTML length is a
     * conservative over-estimate of the PDF (base64 fonts/images weigh more in
     * the HTML), so the ceiling errs toward blocking a borderline packet rather
     * than letting the batch OOM. Never returns above 400 (the count-based cap
     * that's been load-tested) or below 1.
     */
    @TestVisible
    private static Integer duplexPacketMaxDocs(Long perDocBytes) {
        if (perDocBytes == null || perDocBytes <= 0) {
            return 400;
        }
        Long budgetBytes = 11L * 1024 * 1024;
        Long peakPerDoc = (perDocBytes * 12) / 10;
        Integer bySize = (Integer) (budgetBytes / peakPerDoc);
        return Math.max(1, Math.min(400, bySize));
    }

    /**
     * Counts the number of SOQL queries needed per record based on the query config format.
     */
    private static Integer countQueriesPerRecord(String queryConfig) {
        if (String.isBlank(queryConfig)) {
            return 1;
        }
        if (!queryConfig.trim().startsWith('{')) {
            return 1;
        } // V1 flat string

        try {
            Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(queryConfig);
            Object versionObj = config.get('v');
            Integer version = (versionObj instanceof Integer)
                ? (Integer) versionObj
                : ((Decimal) versionObj).intValue();

            if (version == 2) {
                // V2: 1 base + children + junctions
                Integer count = 1;
                List<Object> children = (List<Object>) config.get('children');
                if (children != null) {
                    count += children.size();
                }
                List<Object> junctions = (List<Object>) config.get('junctions');
                if (junctions != null) {
                    count += junctions.size() * 2;
                } // junction query + target query
                return count;
            } else if (version == 3) {
                // V3: one query per node
                List<Object> nodes = (List<Object>) config.get('nodes');
                return (nodes != null) ? nodes.size() : 1;
            }
        } catch (Exception e) {
            // NOPMD EmptyCatchBlock — intentional fallback to 1 query for unparseable configs
        }
        return 1;
    }

    public class JobAnalysis {
        @AuraEnabled
        public Integer recordCount;
        @AuraEnabled
        public Boolean canProceed = true;
        @AuraEnabled
        public List<AnalysisItem> items;
        @AuraEnabled
        public String summary;
    }

    public class AnalysisItem {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String status; // 'ok', 'warning', 'error'
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Decimal estimated;
        @AuraEnabled
        public Decimal limitVal;
    }

    // Keep for backward compatibility — delegates to analyzeJob
    @AuraEnabled
    public static HeapEstimate estimateHeapUsage(Id templateId, Integer recordCount) {
        JobAnalysis analysis = analyzeJob(templateId, recordCount, 1, true, false);
        HeapEstimate estimate = new HeapEstimate();
        for (AnalysisItem item : analysis.items) {
            if (item.label == 'Merge Heap') {
                estimate.estimatedHeapMb = item.estimated;
                estimate.isRisk = (item.status == 'error');
                estimate.message = item.message;
                return estimate;
            }
        }
        estimate.message = analysis.summary;
        return estimate;
    }

    public class HeapEstimate {
        @AuraEnabled
        public Decimal estimatedHeapMb;
        @AuraEnabled
        public Boolean isRisk = false;
        @AuraEnabled
        public String message;
    }

    /**
     * Submits a bulk document generation job for async processing.
     * @param templateId The Portwood template record ID
     * @param condition Optional SOQL WHERE clause to filter records
     * @param jobLabel Optional human-readable label for the job
     * @param mergePdf Whether to merge all outputs into a single PDF
     * @param batchSize Number of records per batch execution (1-200)
     * @param mergeOnly Whether to only generate merged PDF without individual files
     * @param sortOrder Optional SOQL ORDER BY clause controlling processing (and merged page) order
     * @param duplexPadding Combined-PDF only (#382): when true, each odd-length document gets a
     *        blank page before the merge so it starts on the front of a sheet. Null = off.
     * @return The DocGen_Job__c record ID
     */
    @AuraEnabled
    public static Id submitJob(
        Id templateId,
        String condition,
        String jobLabel,
        Boolean mergePdf,
        Integer batchSize,
        Boolean mergeOnly,
        String sortOrder,
        Boolean duplexPadding
    ) {
        // The LWC boundary, and the ONLY place AuraHandledException may be raised.
        try {
            return submitJobInternal(
                templateId,
                condition,
                jobLabel,
                mergePdf,
                batchSize,
                mergeOnly,
                sortOrder,
                duplexPadding
            );
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error starting bulk generation job.');
        }
    }

    /**
     * The same work, throwing a CATCHABLE exception.
     *
     * AuraHandledException can only be THROWN from an Aura/VF request. Raising it
     * anywhere else — a Flow interview, a queueable, anonymous Apex — does not
     * produce that exception at all; it produces
     *
     *     System.LimitException: Can only throw this exception type from
     *     VisualForce or Aura context
     *
     * and a LimitException is UNCATCHABLE. So a Flow action calling the
     * @AuraEnabled entry point could not report a failure however carefully it
     * was written: its own catch(Exception) never ran and the whole interview
     * faulted. Passing a null or deleted Template Id — the commonest Flow-author
     * mistake — took the entire Flow down instead of setting Success = false.
     *
     * Non-Aura callers (Flow actions above all) MUST call this. Only submitJob
     * converts to AuraHandledException, because only it is answering an LWC.
     */
    public static Id submitJobInternal(
        Id templateId,
        String condition,
        String jobLabel,
        Boolean mergePdf,
        Integer batchSize,
        Boolean mergeOnly
    ) {
        return submitJobInternal(templateId, condition, jobLabel, mergePdf, batchSize, mergeOnly, null, null);
    }

    /**
     * As above, with an ORDER BY clause for the bulk query. Plain-Apex overload —
     * NOT @AuraEnabled, which permits only one method of a given name.
     */
    public static Id submitJobInternal(
        Id templateId,
        String condition,
        String jobLabel,
        Boolean mergePdf,
        Integer batchSize,
        Boolean mergeOnly,
        String sortOrder
    ) {
        return submitJobInternal(templateId, condition, jobLabel, mergePdf, batchSize, mergeOnly, sortOrder, null);
    }

    /**
     * As above, with Combined-PDF duplex padding (#382).
     */
    public static Id submitJobInternal(
        Id templateId,
        String condition,
        String jobLabel,
        Boolean mergePdf,
        Integer batchSize,
        Boolean mergeOnly,
        String sortOrder,
        Boolean duplexPadding
    ) {
        try {
            Boolean isMergeOnly = (mergeOnly == true);
            Boolean isMergeMode = (mergePdf == true) || isMergeOnly;
            if (isMergeMode && isFillablePdfTemplate(templateId)) {
                throw new DocGenException(
                    'Fillable PDF templates can be generated in bulk as Individual Files. ' +
                    'Turn off Merged PDF and Merge Only for this template.'
                );
            }
            // Fail up front rather than per-record. generateHtmlForRecord throws for
            // these too, but only once the batch is already running — which surfaces
            // as N failed records on a job that should never have started.
            String unmergeable = isMergeMode ? unmergeableTemplateType(templateId) : null;
            if (unmergeable != null) {
                throw new DocGenException(
                    unmergeable +
                        ' templates cannot be combined into a single PDF. ' +
                        'Turn off Merged PDF and Merge Only to get one file per record.'
                );
            }

            // Validate the sort clause HERE, where the caller still has somewhere to
            // put the error. DocGenBatch.start() re-validates it, but a throw there
            // aborts the batch after the job record already exists — the author sees
            // a job that never leaves Processing instead of "Unknown sort field".
            String safeSortOrder = String.isBlank(sortOrder)
                ? null
                : normalizeSortOrder(templateBaseObject(templateId), sortOrder);

            // Duplex padding (#382) only applies to a Combined PDF; it is
            // meaningless on an Individual-Files job, so it's dropped there
            // rather than errored.
            Boolean safeDuplex = isMergeMode && duplexPadding == true;

            // 1. Create Job Record
            DocGen_Job__c job = new DocGen_Job__c(
                Template__c = templateId,
                Query_Condition__c = condition,
                Status__c = 'Queued',
                Merge_Only__c = isMergeOnly,
                Sort_Order__c = safeSortOrder,
                Duplex_Padding__c = safeDuplex
            );
            if (String.isNotBlank(jobLabel)) {
                job.Label__c = jobLabel;
            }
            // v2.0.1 — per-field FLS enforcement (the "FLS Create" finding category
            // from the v1.56 Checkmarx review). DocGenFlsGuard.assertCreateable
            // calls Schema.SObjectField.getDescribe().isCreateable() on every
            // field the DML writes; throws DocGenException with the offending
            // field name before any DML is attempted. SYSTEM_MODE on the DML
            // sidesteps the package-build @TestSetup FLS-propagation issue
            // documented in DocGenFlsGuard.cls.
            DocGenFlsGuard.assertCreateable(
                job,
                new Set<String>{
                    'Template__c',
                    'Query_Condition__c',
                    'Status__c',
                    'Merge_Only__c',
                    'Label__c',
                    'Sort_Order__c',
                    'Duplex_Padding__c'
                }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(job, AccessLevel.SYSTEM_MODE);

            // 2. Run Batch — user-configurable batch size (default 1, max 200)
            Integer size = (batchSize != null && batchSize >= 1 && batchSize <= 200) ? batchSize : 1;
            DocGenBatch batch = new DocGenBatch(job.Id, isMergeMode, isMergeOnly);
            Database.executeBatch(batch, size);

            return job.Id;
        } catch (Exception e) {
            // Catchable by design — see the note above.
            throw new DocGenException('Error starting bulk generation job. (' + e.getMessage() + ')');
        }
    }

    /**
     * The SObject a template runs against — the schema a sort clause is validated
     * against. Queried only when a sort order was actually supplied, so the common
     * unsorted job pays nothing for it.
     */
    private static String templateBaseObject(Id templateId) {
        if (templateId == null) {
            return null;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Base_Object_API__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Base_Object_API__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new DocGenException('Template not found.');
        }
        return templates[0].Base_Object_API__c;
    }

    private static Boolean isFillablePdfTemplate(Id templateId) {
        if (templateId == null) {
            return false;
        }
        DocGenFlsGuard.assertAccessible(DocGen_Template__c.sObjectType, new Set<String>{ 'Type__c' });
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Template__c> templates = [
            SELECT Type__c
            FROM DocGen_Template__c
            WHERE Id = :templateId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return !templates.isEmpty() && templates[0].Type__c == 'PDF';
    }

    /**
     * Template types that cannot be combined into a single PDF, because they have no
     * DOCX→HTML conversion and the merge path is HTML-based. Returns the type name so
     * callers can name it in the error, or null when the template is mergeable.
     *
     * Without this, a PPTX/XLSX combined-PDF job produced a PDF of blank pages and
     * reported success — the merge path never ran the output-format validation that
     * the individual-file path does.
     */
    @TestVisible
    private static String unmergeableTemplateType(Id templateId) {
        if (templateId == null) {
            return null;
        }
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
            return null;
        }
        String t = templates[0].Type__c;
        return (t == 'PowerPoint' || t == 'Excel') ? t : null;
    }

    /**
     * Returns the current status and progress of a bulk generation job.
     * @param jobId The DocGen_Job__c record ID
     * @return The job record with status and count fields
     */
    @AuraEnabled
    public static DocGen_Job__c getJobStatus(Id jobId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{ 'Name', 'Status__c', 'Success_Count__c', 'Error_Count__c', 'Total_Records__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> jsRecords = [
            SELECT Id, Name, Status__c, Success_Count__c, Error_Count__c, Total_Records__c
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
        ];
        return jsRecords[0];
    }

    /**
     * Returns the 20 most recent bulk generation jobs ordered by creation date.
     * @return List of DocGen_Job__c records with status and template info
     */
    @AuraEnabled
    public static List<DocGen_Job__c> getRecentJobs() {
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{
                'Name',
                'Label__c',
                'Status__c',
                'Success_Count__c',
                'Error_Count__c',
                'Total_Records__c',
                'CreatedDate',
                'Template__c'
            }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT
                Id,
                Name,
                Label__c,
                Status__c,
                Success_Count__c,
                Error_Count__c,
                Total_Records__c,
                CreatedDate,
                Template__r.Name,
                Template__r.Output_Format__c
            FROM DocGen_Job__c
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
    }

    /**
     * Returns ContentVersion IDs for PDFs generated by a completed bulk job.
     * Queries the same records the job processed, finds PDFs created after the job started.
     * @param jobId The DocGen_Job__c record ID
     * @return List of maps with 'label' (file title) and 'value' (ContentVersion ID)
     */
    @AuraEnabled
    public static List<Map<String, String>> getJobGeneratedPdfs(Id jobId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Job__c.sObjectType,
            new Set<String>{ 'Template__c', 'Query_Condition__c', 'CreatedDate' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        List<DocGen_Job__c> gpRecords = [
            SELECT Template__c, Template__r.Base_Object_API__c, Template__r.Name, Query_Condition__c, CreatedDate
            FROM DocGen_Job__c
            WHERE Id = :jobId
            WITH SYSTEM_MODE
        ];
        DocGen_Job__c job = gpRecords[0];

        String baseObject = job.Template__r.Base_Object_API__c;
        if (Schema.getGlobalDescribe().get(baseObject) == null) {
            throw DocGenService.ahe('Invalid base object on job template.');
        }

        // Query the same records the batch processed
        String recQuery = 'SELECT Id FROM ' + String.escapeSingleQuotes(baseObject);
        String condition = sanitizeCondition(job.Query_Condition__c);
        if (String.isNotBlank(condition)) {
            recQuery += ' WHERE ' + condition;
        }
        recQuery += ' LIMIT 2000';

        Set<Id> recordIds = new Set<Id>();
        for (SObject rec : Database.query(recQuery, AccessLevel.USER_MODE)) {
            recordIds.add(rec.Id);
        }

        if (recordIds.isEmpty()) {
            return new List<Map<String, String>>();
        }

        // Find PDFs attached to those records created after the job was created
        Datetime jobStart = job.CreatedDate.addMinutes(-1);
        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId, ContentDocument.Title, LinkedEntityId
            FROM ContentDocumentLink
            WHERE
                LinkedEntityId IN :recordIds
                AND ContentDocument.FileExtension = 'pdf'
                AND ContentDocument.CreatedDate >= :jobStart
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

    // --- Saved Queries ---
    /**
     * Returns saved filter queries for a template, ordered by creation date descending.
     * @param templateId The Portwood template record ID
     * @return List of DocGen_Saved_Query__c records
     */
    @AuraEnabled(cacheable=true)
    public static List<DocGen_Saved_Query__c> getSavedQueries(Id templateId) {
        DocGenFlsGuard.assertAccessible(
            DocGen_Saved_Query__c.sObjectType,
            new Set<String>{ 'Name', 'Description__c', 'Query_Condition__c', 'DocGen_Template__c' }
        );
        /* code-analyzer-suppress ApexFlsViolation */
        return [
            SELECT Id, Name, Description__c, Query_Condition__c
            FROM DocGen_Saved_Query__c
            WHERE DocGen_Template__c = :templateId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
        ];
    }

    /**
     * Saves a named filter query for reuse with a template.
     * @param templateId The Portwood template record ID
     * @param label The display name for the saved query
     * @param description Optional description of the query
     * @param condition The SOQL WHERE clause condition
     */
    @AuraEnabled
    public static void saveQuery(Id templateId, String label, String description, String condition) {
        try {
            DocGen_Saved_Query__c sq = new DocGen_Saved_Query__c(
                DocGen_Template__c = templateId,
                Name = label,
                Description__c = description,
                Query_Condition__c = condition
            );
            DocGenFlsGuard.assertCreateable(
                sq,
                new Set<String>{ 'DocGen_Template__c', 'Name', 'Description__c', 'Query_Condition__c' }
            );
            /* code-analyzer-suppress ApexFlsViolation */
            Database.insert(sq, AccessLevel.SYSTEM_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error saving query.');
        }
    }

    /**
     * Deletes a saved filter query.
     * @param queryId The DocGen_Saved_Query__c record ID to delete
     */
    @AuraEnabled
    public static void deleteQuery(Id queryId) {
        try {
            Database.delete(new DocGen_Saved_Query__c(Id = queryId), true, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw DocGenService.ahe(e, 'Error deleting query.');
        }
    }
}

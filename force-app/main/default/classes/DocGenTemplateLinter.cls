/**
 * Upload-time fidelity report for HTML/Canvas templates (issue #272).
 *
 * DocGenAiHtmlValidator is built for the Agentforce flow: it REPAIRS the HTML
 * and reports what it changed. An author uploading or saving a body in the
 * Designer gets no such visibility — flex silently stacks, rgba() silently
 * renders invisible, a `table > tbody > tr > td` selector silently matches
 * nothing, and an unbalanced {#Lines} only surfaces as a generation-time
 * exception.
 *
 * This linter is the read-only counterpart. It runs the validator in report
 * mode (the rewritten HTML is discarded, the findings kept and reworded so
 * nothing implies the file was modified) and adds the checks the validator
 * does not have: @page-in-HTML vs the template's page-setup fields (the
 * #60/#71 conflict class — precedence is explicit-override per #243), tbody
 * selectors, loop pairing per DocGenService.findBalancedEnd, merge tags split
 * across formatting, and field references validated against the template's
 * Base_Object_API__c describe and Query_Config__c.
 *
 * Every check is advisory and individually guarded: lint() never throws and
 * never touches the author's bytes. A warning is a heads-up, not a blocker.
 */
public with sharing class DocGenTemplateLinter {
    // Tags that resolve without a field on the base object. GROUPNAME only
    // exists inside a {#GroupBy} block; skipping it globally is harmless
    // because it never describes-validates anyway.
    private static final Set<String> BUILTIN_TAGS = new Set<String>{
        'TODAY',
        'NOW',
        'PAGENUMBER',
        'TOTALPAGES',
        'ROWNUMBER',
        'GROUPNAME'
    };
    private static final Set<String> AGGREGATE_TAGS = new Set<String>{ 'SUM', 'COUNT', 'AVG', 'MIN', 'MAX' };

    /**
     * Bodies at or below this many characters are safe to lint. Above it, the
     * report is skipped entirely — see the block comment on lint().
     *
     * Measured on the 383,163-char customer template from the v3.56 reports:
     * the full lint() completes at 130,000 chars (300ms CPU) and throws
     * `System.LimitException: Regex too complicated` at 140,000. The ceiling is
     * content-dependent, not just length-dependent — a body dense in CSS-like
     * text does more per-position work — so this sits ~25% under the lowest
     * ceiling actually observed rather than at it.
     */
    @TestVisible
    private static Integer maxLintChars = 100000;

    // {Field}, {Parent.Field}, {Field:format} — the GiantQueryAssembler tag shape.
    private static final Pattern FIELD_TAG = Pattern.compile(
        '^([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)(?::(.+))?$'
    );

    /**
     * Lints an HTML/Canvas body against its template. Best-effort: returns
     * whatever warnings completed checks produced; a failing check costs its
     * own findings, never the whole report, and never the save.
     */
    public static List<DocGenAiHtmlValidator.Finding> lint(String html, DocGen_Template__c tmpl) {
        List<DocGenAiHtmlValidator.Finding> findings = new List<DocGenAiHtmlValidator.Finding>();
        if (String.isBlank(html)) {
            return findings;
        }
        // Size gate — this MUST be a pre-check, not a try/catch.
        //
        // Apex throws `System.LimitException: Regex too complicated` when one
        // Matcher exceeds its internal step budget, and LimitException is NOT
        // caught by `catch (Exception)`. Every caller of this method wraps it in
        // exactly that catch on the assumption that a lint failure can never
        // fail a save (DocGenController.saveHtmlTemplateBody), and that
        // assumption does not hold: the exception escapes the catch, the whole
        // transaction rolls back, and the author's template does not save. That
        // is the v3.55/v3.56 "Regex too complex" regression — reproduced against
        // the real 383,163-char customer body, where sanitize() and this class's
        // own line-190 <style>/<script> strip both throw.
        //
        // Nothing here can be made safe by rewriting patterns: the budget is
        // spent by input length, not by pattern authorship. A trivial
        // `font-weight:\s*([1-9]00)` throws on the same body. The only reliable
        // guard is to not start.
        if (html.length() > maxLintChars) {
            findings.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    'Template too large to check',
                    1,
                    'This body is ' +
                        html.length() +
                        ' characters, above the ' +
                        maxLintChars +
                        '-character limit for the fidelity report, so it was not checked. Your template saved normally and will render normally — this is the report opting out, not a problem with your file.'
                )
            );
            return findings;
        }
        runRendererCompatibilityCheck(html, findings);
        runPageSetupConflictCheck(html, tmpl, findings);
        runTbodySelectorCheck(html, findings);
        runMergeTagChecks(html, tmpl, findings);
        // Every check funnels through here (#318), so a rule can never sneak
        // back into the panel by being added to a different check.
        return quieten(findings);
    }

    // -----------------------------------------------------------------------
    // 1. Renderer compatibility, report mode. The validator's rule set is
    //    MEASURED against the Flying Saucer build we ship (see its header), so
    //    reuse it wholesale — but discard the rewritten HTML and reword every
    //    finding so nothing tells the author their file was changed. It wasn't.
    // -----------------------------------------------------------------------

    /**
     * Report-mode detail for the validator rules whose own detail describes a
     * REPAIR it performed. The validator is the Agentforce repair pass; those
     * sentences are true there. Here nothing is rewritten, so reusing them
     * produced findings that contradicted themselves in the same breath —
     * "your file was not modified. Mapped 600 and above to bold" — which is
     * what made the report read as untrustworthy. Rules whose detail is already
     * purely diagnostic (calc(), flex/grid, position, @import, <svg>, the two
     * un-repairable loop rules) are passed through unchanged.
     */
    private static final Map<String, String> REPORT_MODE_DETAIL = new Map<String, String>{
        'Markdown code fence' => 'This file starts or ends with a ``` fence, which prints as literal text. Delete the fence lines.',
        'CSS variable' => 'var(...) resolves to nothing in this engine, so the property it feeds is dropped. Write the literal value instead.',
        'Unresolved CSS variable' => 'A var(...) here has no definition and no fallback, so it reads as "inherit". Set a literal value.',
        'Custom property declaration' => 'The --name: value declarations are inert — this engine never reads them back out.',
        'rgba() colour' => 'rgba() does NOT fall back to a solid colour here — it resolves to nothing and the element renders invisible. Write a flat hex composited over white.',
        'hsla() colour' => 'Same failure mode as rgba(): it resolves to nothing and the element renders invisible. Write a flat hex instead.',
        'Gradient' => 'Gradients are discarded when the stylesheet is parsed, leaving no background at all. Use a solid fill.',
        'Numeric font-weight' => 'Only normal and bold exist in this engine. A numeric weight of 600 or above renders as bold and anything below renders as normal, so intermediate weights are lost.',
        'Dingbat font' => 'ZapfDingbats, Symbol, Wingdings and Webdings are NOT installed in the render engine — the character falls back to a serif face and prints a literal "l" or "m" where a shape was intended. Use Unicode glyphs (&#9679; filled, &#9675; hollow, &#8226; bullet) sized with font-size.',
        '@media query' => 'Media queries never match — the engine has no viewport — so any rule that only lives inside one never applies. Move it to the main stylesheet if you meant it.',
        'Loop tag placed between rows' => 'A {#Relationship} tag sitting between <tr> elements is foster-parented out of the table by the HTML parser, so the row never repeats. Put {#Rel} in the first cell and {/Rel} in the last cell of the same row.'
    };

    /**
     * Rules that are NOT worth telling an author about (#318).
     *
     * The report's job is to warn about things that will make the document
     * visibly wrong. A rule that fires on a correct template, or on something
     * the reader could never see, does not earn its line — it just makes an
     * author who did nothing wrong feel like they are making mistakes
     * constantly, and that is how a report stops being read at all.
     *
     * Each of these describes something INERT:
     *
     *  - Custom property declaration — `--name: value` lines are dead once the
     *    values are substituted. Nothing renders differently. The substitution
     *    is already reported separately as "CSS variable", so this is the same
     *    fact a second time.
     *  - Numeric font-weight — 600 renders as bold, which is what an author
     *    writing 600 wanted. Losing 600-vs-700 is not something anyone can see
     *    in a PDF, and this fires on essentially every modern stylesheet.
     *  - Flex/grid alignment properties — only ever appears alongside
     *    "display:flex / display:grid", which already tells the author the
     *    layout will not work and what to do. Reporting the companions is the
     *    same problem counted twice.
     *
     * Deliberately NOT here: anything that changes what the reader sees.
     * rgba() renders invisible, gradients vanish, calc() collapses an element,
     * a dingbat prints a literal letter, an unbalanced brace fails the merge.
     * Those stay loud.
     */
    private static final Set<String> SUPPRESSED_RULES = new Set<String>{
        'Custom property declaration',
        'Numeric font-weight',
        'Flex/grid alignment properties'
    };

    /**
     * The most findings worth showing at once (#318).
     *
     * A stylesheet with one bad class can produce dozens of hits, and a wall of
     * them reads as "this template is broken" when it is one thing to fix. Past
     * this the panel says how many more there are rather than listing them —
     * the author fixes the named ones and re-saves to see the rest.
     */
    @TestVisible
    private static Integer maxReportedFindings = 6;

    /**
     * CSS properties the engine ignores. ONE cause, ONE remedy — so one finding
     * (#318).
     *
     * These all say the same thing: this stylesheet was written for a browser,
     * and the renderer is CSS 2.1. Listing them separately turned a single fact
     * about the file into eight accusations, and a realistic modern stylesheet
     * trips most of them at once — a `:root` block with variables, a flex
     * header, an rgba() tint and a gradient is four findings before the author
     * has done anything unusual.
     *
     * Grouped, the author reads one line, sees exactly which properties are
     * affected, and fixes them together, which is how they would fix them
     * anyway.
     *
     * Rules with their OWN distinct remedy stay separate: an external
     * stylesheet, an @import, an <svg>, a dingbat font, a markdown fence, a
     * misplaced loop tag, an unbalanced brace. Those are not "rewrite your CSS",
     * they are each a different action.
     */
    private static final Set<String> CSS_COMPAT_RULES = new Set<String>{
        'CSS variable',
        'Unresolved CSS variable',
        'rgba() colour',
        'hsla() colour',
        'Gradient',
        'calc()',
        'display:flex / display:grid',
        'position: absolute/fixed/sticky',
        'border-radius',
        '@media query'
    };

    /**
     * Trims a raw finding list to what is worth an author's attention (#318).
     * Drops the inert rules, folds the CSS-compat family into one line, then
     * caps whatever is left rather than printing a wall.
     */
    private static List<DocGenAiHtmlValidator.Finding> quieten(List<DocGenAiHtmlValidator.Finding> raw) {
        List<DocGenAiHtmlValidator.Finding> kept = new List<DocGenAiHtmlValidator.Finding>();
        List<String> cssNames = new List<String>();
        Integer cssCount = 0;

        for (DocGenAiHtmlValidator.Finding f : raw) {
            if (SUPPRESSED_RULES.contains(f.rule)) {
                continue;
            }
            if (CSS_COMPAT_RULES.contains(f.rule)) {
                cssNames.add(f.rule);
                cssCount += (f.occurrences == null ? 1 : f.occurrences);
                continue;
            }
            kept.add(f);
        }

        if (!cssNames.isEmpty()) {
            // Front of the list: it is the one an author can act on in a single pass.
            List<DocGenAiHtmlValidator.Finding> withCss = new List<DocGenAiHtmlValidator.Finding>();
            withCss.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    'Modern CSS the PDF engine ignores',
                    cssCount,
                    'The renderer is CSS 2.1, so it drops these and lays the page out without them: ' +
                        String.join(cssNames, ', ') +
                        '. Rewrite those rules with table-based layout and literal values — everything else in the file is fine.'
                )
            );
            withCss.addAll(kept);
            kept = withCss;
        }

        if (kept.size() <= maxReportedFindings) {
            return kept;
        }
        List<DocGenAiHtmlValidator.Finding> capped = new List<DocGenAiHtmlValidator.Finding>();
        for (Integer i = 0; i < maxReportedFindings; i++) {
            capped.add(kept[i]);
        }
        Integer more = kept.size() - maxReportedFindings;
        capped.add(
            new DocGenAiHtmlValidator.Finding(
                'warning',
                more + ' more not shown',
                more,
                'Fix the items above and save again to see the rest. They are listed in the order they were found, not by severity.'
            )
        );
        return capped;
    }

    private static void runRendererCompatibilityCheck(String html, List<DocGenAiHtmlValidator.Finding> findings) {
        try {
            DocGenAiHtmlValidator.Result res = DocGenAiHtmlValidator.sanitize(html);
            for (DocGenAiHtmlValidator.Finding f : res.findings) {
                String detail = REPORT_MODE_DETAIL.containsKey(f.rule) ? REPORT_MODE_DETAIL.get(f.rule) : f.detail;
                findings.add(
                    new DocGenAiHtmlValidator.Finding(
                        'warning',
                        f.rule,
                        f.occurrences,
                        'The PDF engine ignores this at render time — your file was not modified. ' + detail
                    )
                );
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — lint is advisory; one dead check must not sink the report
        }
    }

    // -----------------------------------------------------------------------
    // 2. @page in the HTML vs page setup on the template record.
    //
    //    Render-time precedence (DocGenService #243): a DELIBERATE template
    //    choice wins and the author's competing @page declaration is stripped —
    //    Landscape, Legal, A4, or a margins preset other than Default/FromSource
    //    can only have been picked on purpose. Letter/Portrait/Default cannot be
    //    told apart from "never touched", so they do NOT conflict.
    // -----------------------------------------------------------------------

    private static void runPageSetupConflictCheck(
        String html,
        DocGen_Template__c tmpl,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        try {
            if (tmpl == null || !html.containsIgnoreCase('@page')) {
                return;
            }
            List<String> overrides = new List<String>();
            if ('Landscape'.equalsIgnoreCase(tmpl.Page_Orientation__c)) {
                overrides.add('Page Orientation = Landscape');
            }
            if ('Legal'.equalsIgnoreCase(tmpl.Page_Size__c) || 'A4'.equalsIgnoreCase(tmpl.Page_Size__c)) {
                overrides.add('Page Size = ' + tmpl.Page_Size__c);
            }
            if (
                String.isNotBlank(tmpl.Page_Margins__c) &&
                !'Default'.equalsIgnoreCase(tmpl.Page_Margins__c) &&
                !'FromSource'.equalsIgnoreCase(tmpl.Page_Margins__c)
            ) {
                overrides.add('Page Margins = ' + tmpl.Page_Margins__c);
            }
            if (overrides.isEmpty()) {
                return;
            }
            findings.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    '@page conflicts with template page setup',
                    1,
                    'This HTML declares @page, but the template record also sets ' +
                        String.join(overrides, ', ') +
                        '. The template wins: at render time those declarations are stripped from your @page rule, so the page you get is not the one the CSS asks for. Remove @page from the body, or set the template fields back to their defaults.'
                )
            );
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — advisory
        }
    }

    // -----------------------------------------------------------------------
    // 3. The tbody selector trap. The engine's HTML parser does not synthesize
    //    a <tbody> element, so a selector written the way browsers teach it —
    //    table > tbody > tr > td — silently matches nothing. <tbody> in the
    //    MARKUP is fine; only selectors are the trap, so only <style> blocks
    //    are scanned.
    // -----------------------------------------------------------------------

    private static void runTbodySelectorCheck(String html, List<DocGenAiHtmlValidator.Finding> findings) {
        try {
            Matcher styles = Pattern.compile('(?is)<style\\b[^>]*>(.*?)</style\\s*>').matcher(html);
            Integer n = 0;
            String example = null;
            while (styles.find()) {
                Matcher rules = Pattern.compile('([^{}]+)\\{').matcher(styles.group(1));
                while (rules.find()) {
                    String selector = rules.group(1).trim();
                    if (Pattern.compile('(?i)\\btbody\\b').matcher(selector).find()) {
                        n++;
                        if (example == null) {
                            example = selector;
                        }
                    }
                }
            }
            if (n > 0) {
                findings.add(
                    new DocGenAiHtmlValidator.Finding(
                        'warning',
                        'tbody in a CSS selector',
                        n,
                        'The PDF engine does not match <tbody> in selectors, so "' +
                            example +
                            '" silently selects nothing. Target the cells directly instead, e.g. table tr td.'
                    )
                );
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — advisory
        }
    }

    // -----------------------------------------------------------------------
    // 4. Merge-tag lint: pairing, split runs, and field resolution.
    // -----------------------------------------------------------------------

    private static void runMergeTagChecks(
        String html,
        DocGen_Template__c tmpl,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        try {
            // <style>/<script> bodies carry braces that are not merge tags, and
            // comments can carry commented-out tags. Both are stripped so the
            // tokenizer below only sees authored tags.
            String stripped = html.replaceAll('(?is)<(style|script)\\b[^>]*>.*?</\\1\\s*>', ' ')
                .replaceAll('(?s)<!--.*?-->', ' ');

            checkSplitRuns(stripped, findings);
            List<MergeToken> tokens = tokenize(stripped);
            checkLoopPairing(tokens, findings);
            checkFieldReferences(tokens, tmpl, findings);
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — advisory
        }
    }

    private class MergeToken {
        String raw; // full "{...}" text
        String content; // inner text, trimmed
        Boolean isOpen; // {#X} / {^X}
        Boolean isClose; // {/X}
        String key; // balance key per DocGenService.findBalancedEnd
    }

    /** Extracts well-formed {…} candidates in document order. */
    private static List<MergeToken> tokenize(String stripped) {
        List<MergeToken> tokens = new List<MergeToken>();
        Matcher m = Pattern.compile('\\{([^{}]*)\\}').matcher(stripped);
        while (m.find()) {
            String content = m.group(1).trim();
            if (String.isBlank(content) || content == ':else') {
                continue; // {:else} belongs to the enclosing block, not the balance count
            }
            MergeToken t = new MergeToken();
            t.raw = m.group(0);
            t.content = content;
            if (content.startsWith('#') || content.startsWith('^')) {
                t.isOpen = true;
                t.key = balanceKey(content.substring(1).trim());
            } else if (content.startsWith('/')) {
                t.isClose = true;
                t.key = content.substring(1).trim();
            }
            tokens.add(t);
        }
        return tokens;
    }

    /**
     * The balance key DocGenService.findBalancedEnd pairs on: {#IF expr} and
     * {#GroupBy rel by field} carry a spec but close on the bare keyword;
     * {#ChartBucket:…} is the same shape. Everything else pairs on its own name.
     */
    private static String balanceKey(String openerName) {
        String upper = openerName.toUpperCase();
        if (upper == 'IF' || upper.startsWith('IF ')) {
            return 'IF';
        }
        if (upper == 'GROUPBY' || upper.startsWith('GROUPBY ')) {
            return 'GroupBy';
        }
        if (upper == 'CHARTBUCKET' || upper.startsWith('CHARTBUCKET:')) {
            return 'ChartBucket';
        }
        return openerName;
    }

    /** Openers that rebind the field context — {Name} inside one is the CHILD's Name. */
    private static Boolean isRelationshipLoop(String key) {
        return key != 'IF' && key != 'GroupBy' && key != 'ChartBucket';
    }

    /**
     * Stack-based pairing mirroring findBalancedEnd semantics: an opener with no
     * matching close fails the whole merge at generation time; a stray closer is
     * dead text today and a parse error tomorrow.
     */
    private static void checkLoopPairing(List<MergeToken> tokens, List<DocGenAiHtmlValidator.Finding> findings) {
        List<MergeToken> stack = new List<MergeToken>();
        List<String> strayClosers = new List<String>();
        for (MergeToken t : tokens) {
            if (t.isOpen == true) {
                stack.add(t);
            } else if (t.isClose == true) {
                // Case-SENSITIVE equals, mirroring findBalancedEnd — {/lines}
                // does not close {#Lines} at generation time either.
                if (!stack.isEmpty() && stack[stack.size() - 1].key.equals(t.key)) {
                    stack.remove(stack.size() - 1);
                } else {
                    strayClosers.add(t.raw);
                }
            }
        }
        if (!stack.isEmpty()) {
            List<String> unclosed = new List<String>();
            for (Integer i = 0; i < stack.size() && i < 3; i++) {
                unclosed.add(stack[i].raw);
            }
            findings.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    'Unclosed loop tag',
                    stack.size(),
                    'Opened but never closed: ' +
                        String.join(unclosed, ', ') +
                        '. Generation fails the whole merge with "Malformed loop tag" — add the matching {/…} for each.'
                )
            );
        }
        if (!strayClosers.isEmpty()) {
            List<String> shown = new List<String>();
            for (Integer i = 0; i < strayClosers.size() && i < 3; i++) {
                shown.add(strayClosers[i]);
            }
            findings.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    'Unmatched closing tag',
                    strayClosers.size(),
                    'Closes nothing that is open: ' +
                        String.join(shown, ', ') +
                        '. Check the relationship name spelling and that the {#…} opener was not lost to formatting.'
                )
            );
        }
    }

    /**
     * A merge tag broken across an HTML tag boundary — {Na<b>me}</b> — reads as
     * one tag to a human and as two runs to the merger. Text tags are healed at
     * merge time; chart tags fall back to literal text (#130). Either way the
     * author should know the formatting split the tag.
     */
    private static void checkSplitRuns(String stripped, List<DocGenAiHtmlValidator.Finding> findings) {
        Matcher m = Pattern.compile('\\{[^{}]*<[^>]+>[^{}]*\\}').matcher(stripped);
        Integer n = 0;
        String example = null;
        while (m.find()) {
            n++;
            if (example == null) {
                example = m.group(0).replaceAll('<[^>]+>', '…');
            }
        }
        if (n > 0) {
            findings.add(
                new DocGenAiHtmlValidator.Finding(
                    'warning',
                    'Merge tag split by formatting',
                    n,
                    'A tag is broken across an HTML formatting boundary ("' +
                        example +
                        '"). Keep the whole tag in a single run of text — bold only part of it and the merger may not see it.'
                )
            );
        }
    }

    // -----------------------------------------------------------------------
    // 4c. Field resolution. Simple {Field} / {Parent.Field} tags OUTSIDE loop
    //     bodies are validated against the Base_Object_API__c describe (the
    //     DocGenGiantQueryAssembler pattern); tags inside a {#Rel} loop belong
    //     to the child object and are skipped. A described-valid field that is
    //     absent from Query_Config__c still merges — blank — so that is a
    //     separate, softer warning. Query Config parse failure skips silently.
    // -----------------------------------------------------------------------

    private static void checkFieldReferences(
        List<MergeToken> tokens,
        DocGen_Template__c tmpl,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        String baseObj = tmpl?.Base_Object_API__c;
        if (String.isBlank(baseObj)) {
            return; // nothing to validate against — single-object templates without a base skip silently
        }
        Map<String, Schema.SObjectField> fieldMap = Schema.getGlobalDescribe()
            .get(baseObj)
            ?.getDescribe()
            ?.fields
            ?.getMap();
        if (fieldMap == null) {
            return;
        }
        Set<String> relNames = relationshipNames(fieldMap);
        Set<String> queryFields = queryConfigFields(tmpl?.Query_Config__c);
        // Aliased loops: a V3 Query Config node can rename a relationship, and the
        // template loops on the ALIAS. Describe alone would condemn a valid tag.
        Set<String> loopNames = childRelationshipNames(baseObj);
        loopNames.addAll(queryConfigRelationshipNames(tmpl?.Query_Config__c));

        Set<String> unknownReported = new Set<String>();
        Set<String> notQueriedReported = new Set<String>();
        Set<String> loopReported = new Set<String>();
        Integer loopDepth = 0;
        List<MergeToken> stack = new List<MergeToken>();
        for (MergeToken t : tokens) {
            if (t.isOpen == true) {
                stack.add(t);
                if (isRelationshipLoop(t.key)) {
                    // Only the OUTERMOST loop resolves against the base object —
                    // a nested {#Rel} belongs to the child and is skipped.
                    if (loopDepth == 0 && !loopNames.contains(t.key.toLowerCase()) && !loopReported.contains(t.key)) {
                        loopReported.add(t.key);
                        findings.add(
                            new DocGenAiHtmlValidator.Finding(
                                'warning',
                                'Loop relationship not found',
                                1,
                                '{#' +
                                    t.key +
                                    '} — ' +
                                    t.key +
                                    ' is not a child relationship of ' +
                                    baseObj +
                                    ' and no Query Config node defines it. The loop will render nothing. Check the relationship name (e.g. OpportunityLineItems).'
                            )
                        );
                    }
                    loopDepth++;
                }
                continue;
            }
            if (t.isClose == true) {
                if (!stack.isEmpty() && stack[stack.size() - 1].key.equals(t.key)) {
                    MergeToken popped = stack.remove(stack.size() - 1);
                    if (isRelationshipLoop(popped.key)) {
                        loopDepth--;
                    }
                }
                continue;
            }
            if (loopDepth > 0) {
                continue;
            }
            Matcher fm = FIELD_TAG.matcher(t.content);
            if (!fm.matches()) {
                continue; // {%image}, {*}barcode, {@signature}, {?form} and friends — not field refs
            }
            String path = fm.group(1);
            String upper = path.toUpperCase();
            if (
                BUILTIN_TAGS.contains(upper) ||
                AGGREGATE_TAGS.contains(upper) ||
                upper.startsWith('RUNNINGUSER.') ||
                upper == 'CHART'
            ) {
                continue;
            }
            if (path.contains('.')) {
                // Same contract as GiantQueryAssembler: the relationship name
                // must exist on the base object; the far-side field is trusted.
                if (relNames.contains(path.substringBefore('.').toLowerCase())) {
                    noteNotQueried(path, queryFields, notQueriedReported, findings);
                } else if (!unknownReported.contains(path)) {
                    unknownReported.add(path);
                    findings.add(
                        new DocGenAiHtmlValidator.Finding(
                            'warning',
                            'Merge tag does not resolve',
                            1,
                            '{' +
                                path +
                                '} — ' +
                                path.substringBefore('.') +
                                ' is not a relationship on ' +
                                baseObj +
                                '. This tag will merge blank.'
                        )
                    );
                }
            } else if (fieldMap.containsKey(path.toLowerCase())) {
                noteNotQueried(path, queryFields, notQueriedReported, findings);
            } else if (!unknownReported.contains(path)) {
                unknownReported.add(path);
                findings.add(
                    new DocGenAiHtmlValidator.Finding(
                        'warning',
                        'Merge tag does not resolve',
                        1,
                        '{' + path + '} does not exist on ' + baseObj + ' — it will merge blank. Check the API name.'
                    )
                );
            }
        }
    }

    /** The field is real but the template's query will not return it — so it merges blank. */
    private static void noteNotQueried(
        String path,
        Set<String> queryFields,
        Set<String> reported,
        List<DocGenAiHtmlValidator.Finding> findings
    ) {
        if (queryFields == null || queryFields.contains(path.toLowerCase()) || reported.contains(path.toLowerCase())) {
            return;
        }
        reported.add(path.toLowerCase());
        findings.add(
            new DocGenAiHtmlValidator.Finding(
                'warning',
                'Field not in Query Config',
                1,
                '{' +
                    path +
                    '} exists on the object but is not in this template\'s Query Config, so the merge has no value for it — it will render blank. Add it to the Query Config.'
            )
        );
    }

    /** Lowercased relationship names of every lookup/master-detail on the object. */
    private static Set<String> relationshipNames(Map<String, Schema.SObjectField> fieldMap) {
        Set<String> names = new Set<String>();
        for (Schema.SObjectField sof : fieldMap.values()) {
            String rel = sof.getDescribe().getRelationshipName();
            if (rel != null) {
                names.add(rel.toLowerCase());
            }
        }
        return names;
    }

    /** Lowercased CHILD relationship names on the object — what {#Rel} loops pair with. */
    private static Set<String> childRelationshipNames(String baseObj) {
        Set<String> names = new Set<String>();
        Schema.SObjectType t = Schema.getGlobalDescribe().get(baseObj);
        if (t == null) {
            return names;
        }
        for (Schema.ChildRelationship cr : t.getDescribe().getChildRelationships()) {
            if (cr.getRelationshipName() != null) {
                names.add(cr.getRelationshipName().toLowerCase());
            }
        }
        return names;
    }

    /**
     * Relationship names and aliases declared by a V3 JSON Query Config — a node
     * can rename its relationship, and templates loop on the alias. Anything that
     * is not a parseable JSON graph yields an empty set, not an error.
     */
    private static Set<String> queryConfigRelationshipNames(String queryConfig) {
        Set<String> names = new Set<String>();
        if (String.isBlank(queryConfig) || !queryConfig.trim().startsWith('{')) {
            return names;
        }
        try {
            Map<String, Object> cfg = (Map<String, Object>) JSON.deserializeUntyped(queryConfig.trim());
            Object nodes = cfg.get('nodes');
            if (nodes instanceof List<Object>) {
                for (Object nodeObj : (List<Object>) nodes) {
                    if (nodeObj instanceof Map<String, Object>) {
                        Map<String, Object> node = (Map<String, Object>) nodeObj;
                        for (String key : new List<String>{ 'alias', 'relationshipName' }) {
                            Object v = node.get(key);
                            if (v instanceof String && String.isNotBlank((String) v)) {
                                names.add(((String) v).trim().toLowerCase());
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            String noop = e.getMessage(); // NOPMD — unparseable config just means no aliases
        }
        return names;
    }

    /**
     * Lowercased field paths out of Query_Config__c, or null when it cannot be
     * read as a field list. Two shapes exist in the wild: the V1 flat string
     * ("Name, Industry") and the V3 JSON graph ({"nodes":[{"fields":[…]}]}).
     * Anything else — parse failure, empty — returns null and the cross-check
     * is skipped rather than guessed at.
     */
    private static Set<String> queryConfigFields(String queryConfig) {
        if (String.isBlank(queryConfig)) {
            return null;
        }
        String trimmed = queryConfig.trim();
        Set<String> fields = new Set<String>();
        try {
            if (trimmed.startsWith('{')) {
                Map<String, Object> cfg = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
                collectJsonFields(cfg.get('fields'), fields);
                Object nodes = cfg.get('nodes');
                if (nodes instanceof List<Object>) {
                    for (Object nodeObj : (List<Object>) nodes) {
                        if (nodeObj instanceof Map<String, Object>) {
                            collectJsonFields(((Map<String, Object>) nodeObj).get('fields'), fields);
                        }
                    }
                }
            } else {
                for (String piece : trimmed.split(',')) {
                    if (String.isNotBlank(piece)) {
                        fields.add(piece.trim().toLowerCase());
                    }
                }
            }
        } catch (Exception e) {
            return null; // unparseable config — skip the cross-check silently
        }
        return fields.isEmpty() ? null : fields;
    }

    private static void collectJsonFields(Object raw, Set<String> fields) {
        if (!(raw instanceof List<Object>)) {
            return;
        }
        for (Object f : (List<Object>) raw) {
            if (f instanceof String && String.isNotBlank((String) f)) {
                fields.add(((String) f).trim().toLowerCase());
            }
        }
    }
}

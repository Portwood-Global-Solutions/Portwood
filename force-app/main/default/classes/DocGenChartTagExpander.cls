/**
 * DocGenChartTagExpander
 *
 * Author-friendly wrapper around {#ChartBucket:...} that lets a template
 * author drop one short tag into an HTML template and get a fully-styled
 * chart block in return.
 *
 *   {Chart:Survey_Responses__r:Selected_Answer__c}                       (default: bar)
 *   {Chart:Survey_Responses__r:Selected_Answer__c:bar:title=How satisfied?}
 *   {Chart:Survey_Responses__r:Selected_Answer__c:pivot:groupBy=Department__c&colSort=Eng,Sales}
 *
 * The expander runs as a preprocessing pass inside DocGenService.processXml
 * BEFORE DocGenChartBucketResolver.preprocessInline. It rewrites each
 * {Chart:...} tag into an HTML snippet that itself contains a
 * {#ChartBucket:...} loop — so all the existing bucket-resolution machinery
 * (in-memory / SOQL fallback / parent-level / giant-query) keeps working
 * unchanged. The tag composes; styles are inline so Flying Saucer renders
 * them in PDF without CSS-class lookups.
 *
 * Styles:
 *   bar       horizontal bar per bucket (CSS-bar default, or SVG via htmlRender=svg)
 *   column    vertical bar chart — HTML opt-in via htmlRender=svg (SVG only)
 *   pie       pie chart with right-side legend — HTML opt-in via htmlRender=svg
 *   donut     pie with center hole — HTML opt-in via htmlRender=svg
 *   pivot     cross-tab: rows = answers, cols = groupBy values (% per cell)
 *   clustered vertical clustered bar chart: column per answer, bar per groupBy
 *   stacked   horizontal stacked bar: one row per answer, segments per groupBy
 *
 * SVG vs CSS-bar (HTML output): the htmlRender=svg modifier routes through
 * DocGenSvgChartSerializer.emit, sharing a single per-style implementation
 * with the Word/PDF/PPT/Excel PNG-via-CV pipeline. Default stays CSS-bar
 * for zero regression on shipped templates. Inline <svg> renders in the
 * browser but Flying Saucer drops it from Blob.toPdf — HTML→PDF authors who
 * need the chart visible in PDF must use the default cssbar.
 *
 * Cross-tab styles require groupBy=Field__c AND colSort=Val1,Val2,... — the
 * colSort drives header generation since column labels can't be known
 * without enumerating the groupBy values up front.
 *
 * Bad tags render an inline error block in HTML output so the author sees
 * the problem in their generated PDF rather than chasing a silent miss.
 * In Word templates (#117 PNG-via-CV pipeline), bad tags emit a `[Chart error: ...]`
 * text placeholder instead — keeping the document well-formed even when a
 * template author writes a malformed tag.
 */
public with sharing class DocGenChartTagExpander {
    private static final String OPEN_PREFIX = '{Chart:';
    private static final Set<String> ALLOWED_STYLES = new Set<String>{
        'bar',
        'column',
        'pie',
        'donut',
        'pivot',
        'clustered',
        'stacked',
        'line',
        'area'
    };
    // Cross-tab styles require groupBy + colSort to produce a sensible pivot.
    // `line`/`area` accept groupBy but don't REQUIRE it (single-series mode is
    // a valid use), so they're NOT in this set.
    private static final Set<String> CROSS_TAB_STYLES = new Set<String>{ 'pivot', 'clustered', 'stacked' };
    // Styles the SVG serializer can render natively. When an HTML template
    // author opts in with `htmlRender=svg`, the expander resolves buckets
    // eagerly and inlines an <svg>...</svg> string instead of emitting the
    // CSS-bar table + {#ChartBucket:...} loop. Path C unification: single
    // bucket-data resolution (DocGenChartBucketResolver.resolveBucketsForTag)
    // feeds both this HTML-inline-SVG path AND the PNG-via-CV path used by
    // Word/PPTX/PDF — adding a new chart style means writing it ONCE in
    // DocGenSvgChartSerializer (browser HTML preview) and once in
    // DocGenChartRasterizer (server PNG for Flying Saucer / OOXML).
    //
    // Cross-tab styles stay on the CSS-bar+{#cols} path because the SVG
    // serializer doesn't yet support them and their {#cols} body is the
    // mechanism that gives authors per-cell customization. When cross-tab
    // PNG/SVG emitters land they'll switch over automatically.
    //
    // IMPORTANT: this path emits inline <svg>, which the spike memory
    // project_117_chart_pipeline_state.md confirms Flying Saucer SILENTLY
    // DROPS in `Blob.toPdf`. Inline SVG therefore only renders correctly
    // in browser-rendered HTML preview (Lightning admin preview, Experience
    // Cloud, raw HTML download). HTML→PDF authors who need the chart in the
    // PDF must keep the default `htmlRender=cssbar` path until Flying Saucer
    // SVG support arrives (banked as a separate sub-issue).
    private static final Set<String> HTML_INLINE_SVG_STYLES = new Set<String>{
        'bar',
        'column',
        'pie',
        'donut',
        'stacked',
        'clustered',
        'line',
        'area'
    };

    /**
     * Legacy two-arg entry point. Routes to the chart-CV-aware overload with
     * no map / no data so existing callers (and tests that exercised the
     * HTML-only behavior) keep their shape.
     */
    public static String expand(String xml, String templateType) {
        return expand(xml, templateType, null, null);
    }

    /**
     * Top-level entry point with chart-CV awareness (#117) and SVG-render
     * opt-in (Path C unification).
     *
     * For HTML templates (default): emits the legacy CSS-bar table per chart,
     * with an embedded {#ChartBucket:...} loop that the existing bucket
     * resolver feeds at merge time. Unchanged from pre-unification behavior
     * — zero regression for shipped templates.
     *
     * For HTML templates with `htmlRender=svg` modifier AND a SVG-supported
     * style (bar/column/pie/donut): resolves buckets eagerly via
     * DocGenChartBucketResolver.resolveBucketsForTag and inlines the SVG
     * fragment produced by DocGenSvgChartSerializer.emit. Single per-style
     * implementation in the serializer also serves the Word/PDF/PPT/Excel
     * pipeline (via the rasterizer + PNG-via-CV path) — adding a new chart
     * style means writing it ONCE per renderer (SVG + rasterizer) instead of
     * three times. Note: inline <svg> is browser-render-only — Flying Saucer's
     * Blob.toPdf silently drops it. HTML→PDF authors stay on the default
     * CSS-bar path until Flying Saucer SVG support arrives.
     *
     * For Word templates with `chartCvMap` populated: each chart tag whose
     * signature matches a CV in the map is substituted with `{%__dgchart_<cvId>}`,
     * and the data map is seeded with `__dgchart_<cvId> → cvId` so the existing
     * image-tag scanner at DocGenService:3079 resolves the synthetic field to
     * the CV Id. From there `buildImageXml` case-4 handles DOCX (blob embed)
     * vs PDF (relative CV URL) automatically.
     *
     * For Word templates with no matching CV (server-side flow with no LWC
     * to rasterize, or a chart added to the template after preflight): emits
     * a text placeholder `[Chart: rel.field]` rather than corrupting the
     * document with an unresolved image tag.
     */
    public static String expand(
        String xml,
        String templateType,
        Map<String, Object> data,
        Map<String, String> chartCvMap
    ) {
        if (xml == null || !xml.contains(OPEN_PREFIX)) {
            return xml;
        }

        List<String> out = new List<String>();
        Integer cursor = 0;
        Integer len = xml.length();
        Boolean isHtml = DocGenService.isHtmlBacked(templateType);

        while (cursor < len) {
            Integer next = xml.indexOf(OPEN_PREFIX, cursor);
            if (next == -1) {
                out.add(xml.substring(cursor));
                break;
            }
            out.add(xml.substring(cursor, next));
            Integer close = xml.indexOf('}', next);
            if (close == -1) {
                out.add(
                    renderError(
                        isHtml,
                        'Unterminated {Chart:...} tag — no closing brace.',
                        xml.substring(next, Math.min(next + 60, len))
                    )
                );
                break;
            }
            String tagBody = decodeEntities(xml.substring(next + OPEN_PREFIX.length(), close));
            String fullTag = xml.substring(next, close + 1);
            try {
                out.add(buildSnippet(tagBody, isHtml, templateType, data, chartCvMap));
            } catch (ChartTagException e) {
                out.add(renderError(isHtml, e.getMessage(), fullTag));
            }
            cursor = close + 1;
        }

        return String.join(out, '');
    }

    /**
     * Parses one tag body (everything between "{Chart:" and "}") and returns
     * the corresponding substitution snippet. Throws ChartTagException with a
     * human-readable reason on any validation failure — caller renders it as
     * an inline error block (HTML) or escalates (non-HTML).
     *
     * For non-HTML templates (Word): looks up the tag's signature in
     * `chartCvMap`; if found, emits `{%__dgchart_<cvId>}` and seeds `data`
     * with the synthetic key. If not found, emits a `[Chart: rel.field]`
     * text placeholder — documented v1 fallback for server-side flows.
     *
     * For HTML templates: behavior unchanged from pre-#117 — emits the
     * existing CSS-bar / pivot / clustered / stacked table.
     */
    private static String buildSnippet(
        String tagBody,
        Boolean isHtml,
        String templateType,
        Map<String, Object> data,
        Map<String, String> chartCvMap
    ) {
        // Tag form: REL:FIELD[:STYLE[:k=v&k=v...]]
        // We split on ':' up to 3 times so option values can contain ':'.
        List<String> parts = splitLimit(tagBody, ':', 4);
        if (parts.size() < 2) {
            throw new ChartTagException(
                'Need at least a relationship and a field, e.g. {Chart:Survey_Responses__r:Selected_Answer__c}.'
            );
        }
        String relationship = parts[0].trim();
        String field = parts[1].trim();
        String style = parts.size() >= 3 && String.isNotBlank(parts[2]) ? parts[2].trim().toLowerCase() : 'bar';
        String rawOpts = parts.size() >= 4 ? parts[3] : '';

        if (String.isBlank(relationship) || String.isBlank(field)) {
            throw new ChartTagException('Relationship and field are required.');
        }
        if (!ALLOWED_STYLES.contains(style)) {
            throw new ChartTagException(
                'Unknown style "' +
                    style +
                    '". Allowed: bar, column, pie, donut, pivot, clustered, stacked, line, area.'
            );
        }

        Map<String, String> opts = parseOptions(rawOpts);
        // Compute the chart signature BEFORE removing `title` from opts —
        // DocGenChartImageController.prepareChartImages hashes the full options
        // map (including title) when assigning a CV. If we strip title first
        // and then hash, expander signature ≠ controller signature, the CV
        // lookup misses, and every titled chart falls back to text. Must
        // mirror the controller's input exactly. Signature is computed for
        // every template type so HTML can route through PNG-via-CV when
        // chartCvMap is populated (task #23 unification).
        String signature = DocGenChartImageController.tagSignature(relationship, field, style, opts);
        String title = opts.remove('title');

        if (CROSS_TAB_STYLES.contains(style)) {
            if (String.isBlank(opts.get('groupBy'))) {
                throw new ChartTagException('Style "' + style + '" requires groupBy=YourField__c.');
            }
            if (String.isBlank(opts.get('colSort'))) {
                throw new ChartTagException(
                    'Style "' + style + '" requires colSort=Val1,Val2,... so column headers can be generated.'
                );
            }
        }

        // Non-HTML templates (Word/PPT/Excel for #117): route to the PNG-via-CV
        // pipeline. The LWC has already rasterized each chart's SVG to a PNG and
        // uploaded it as a ContentVersion; `chartCvMap[signature]` is the CV Id.
        // Server-side flows (Flow / batch / async) hit this path with an empty
        // map and get a text placeholder — documented v1 limitation.
        if (!isHtml) {
            // `signature` was precomputed above against the options map that
            // still included title — matches what the controller hashed.
            //
            // Map value shape: either "<cvId>" (legacy) or "<cvId>|WxH" — the
            // runner LWC packs nominal SVG dimensions into the value so the
            // image-tag scanner sizes the embedded PNG via {%FieldName:WxH}.
            // Without WxH, Word renders the 4x-rasterized PNG at its full
            // pixel size and the chart fills the page.
            String entry = (chartCvMap == null) ? null : chartCvMap.get(signature);
            if (String.isNotBlank(entry)) {
                String cvId = entry;
                String sizeSuffix = '';
                Integer pipeAt = entry.indexOf('|');
                if (pipeAt > 0) {
                    cvId = entry.substring(0, pipeAt);
                    sizeSuffix = ':' + entry.substring(pipeAt + 1);
                }
                if (data != null) {
                    // Synthetic key seeding mirrors how DocGenChartBucketResolver.
                    // preprocessInline injects _cb_N for bucket lists.
                    data.put('__dgchart_' + cvId, cvId);
                }
                return '{%__dgchart_' + cvId + sizeSuffix + '}';
            }
            String labelText = String.isNotBlank(title) ? title : (relationship + '.' + field);
            return '[Chart: ' + labelText + ']';
        }

        // HTML PNG-via-CV (task #23 — true one-maintenance-place): when an
        // upstream caller has rasterized the chart and populated chartCvMap,
        // emit an <img> referencing the CV's relative URL. This is the
        // PRIMARY HTML chart path going forward — Flying Saucer fetches the
        // PNG server-side, the browser fetches it client-side, and every new
        // chart style only has to land in DocGenChartRasterizer once.
        //
        // Server-side flows without chart prep (raw Flow / batch / async)
        // fall through to the CSS-bar / SVG-opt-in branches below — zero
        // regression for existing HTML templates that haven't gone through
        // the PNG prep step.
        if (chartCvMap != null && chartCvMap.containsKey(signature)) {
            String entry = chartCvMap.get(signature);
            String cvId = entry;
            String widthAttr = '';
            String heightAttr = '';
            Integer pipeAt = entry.indexOf('|');
            if (pipeAt > 0) {
                cvId = entry.substring(0, pipeAt);
                String size = entry.substring(pipeAt + 1);
                Integer xAt = size.indexOf('x');
                if (xAt > 0) {
                    widthAttr = ' width="' + size.substring(0, xAt) + '"';
                    heightAttr = ' height="' + size.substring(xAt + 1) + '"';
                }
            }
            String alt = String.isNotBlank(title) ? title : (relationship + '.' + field);
            return '<img src="/sfc/servlet.shepherd/version/download/' +
                cvId +
                '"' +
                widthAttr +
                heightAttr +
                ' alt="' +
                alt.replace('"', '&quot;') +
                '"/>';
        }

        // HTML SVG opt-in (Path C unification): when the author writes
        // `htmlRender=svg` AND the style is one the SVG serializer can emit,
        // resolve buckets here and inline the same SVG that the rasterizer
        // would draw — same data model, same per-style code, no duplicate
        // implementation. Falls through to CSS-bar default when not set.
        // Inline SVG is browser-render-only and drops in Flying Saucer PDF
        // output; for PDF the PNG-via-CV path above is what works.
        String htmlRender = opts.remove('htmlRender');
        if (htmlRender != null) {
            htmlRender = htmlRender.toLowerCase();
        }
        if (htmlRender == 'svg' && HTML_INLINE_SVG_STYLES.contains(style)) {
            return renderViaSvgSerializer(title, style, relationship, field, opts, data);
        }

        String chartBucketTag = buildChartBucketTag(relationship, field, opts);

        if (style == 'bar') {
            return renderBar(title, chartBucketTag, opts);
        } else if (style == 'pivot') {
            return renderPivot(title, chartBucketTag, opts.get('colSort'), opts);
        } else if (style == 'clustered') {
            return renderClustered(title, chartBucketTag, opts.get('colSort'), opts);
        } else if (style == 'stacked') {
            return renderStacked(title, chartBucketTag, opts.get('colSort'), opts);
        }
        // DEGRADE, never error (#306).
        //
        // `column`, `pie`, `donut`, `line` and `area` have no CSS-bar renderer.
        // In a browser that is moot — the chart is rasterized and chartCvMap is
        // populated, so any style works. Headless (Flow action, batch, scheduled
        // job) there is no browser, chartCvMap is empty, and this branch is
        // reached. It used to throw, and the caller printed the exception into
        // the document — putting the raw merge tag in the middle of a
        // client-facing PDF:
        //
        //   Chart error: Style "column" is supported in HTML output only via
        //   `htmlRender=svg` ... at {Chart:Survey_Answers__r:Answer_8__c:column:...}
        //
        // Measured on a real headless run: seven charts, a 7-page PDF, ZERO
        // embedded images and seven error blocks. Everything non-chart was
        // correct.
        //
        // The advice that message gave was a dead end anyway: `htmlRender=svg`
        // emits inline <svg>, which Flying Saucer silently drops, so it cannot
        // help a PDF.
        //
        // A `column` drawn as CSS bars is the same data in the same order, read
        // sideways. That is a far better document than an error block, and the
        // author still gets their intended shape everywhere a browser is
        // involved. `pie`/`donut` lose the part-of-whole framing, which is why
        // the percentage stays on every bar.
        return renderBar(title, chartBucketTag, opts);
    }

    /**
     * Path-C unification helper: resolves chart buckets eagerly via the same
     * resolver the rasterizer uses, then emits the same SVG the rasterizer
     * would draw — but inlined into the HTML stream instead of rasterized to
     * a PNG-via-CV. One per-style implementation in DocGenSvgChartSerializer
     * serves both this browser-HTML path AND (after rasterization) the
     * Word/PDF/PPT/Excel path.
     *
     * `data` is the merge data map the runtime hands to processXml. When the
     * relationship is pre-loaded there, buckets resolve in-memory (zero
     * SOQL). When it isn't AND the data carries a parent record Id, the
     * resolver issues a single GROUP BY against the 50-chart SOQL budget.
     * When the data is null (e.g. processXmlForTest with no live record),
     * buckets come back empty and the SVG serializer renders its "No data"
     * placeholder — never throws, never silently disappears.
     */
    private static String renderViaSvgSerializer(
        String title,
        String style,
        String relationship,
        String field,
        Map<String, String> opts,
        Map<String, Object> data
    ) {
        // Reassemble the modifier string the resolver expects. `opts` is the
        // post-title-removal map (title was already lifted into the caller's
        // local `title` parameter so it doesn't double-render).
        List<String> kvs = new List<String>();
        for (String key : opts.keySet()) {
            kvs.add(key + '=' + opts.get(key));
        }
        String modifiersRaw = String.join(kvs, '&');

        // resolveBucketsForTag's SOQL fallback NPEs on null data — it
        // dereferences `data.get('Id')` to discover the parent record's Id
        // for the GROUP BY aggregate. Short-circuit to empty when data is
        // null (processXmlForTest paths, ad-hoc unit calls) so the SVG
        // serializer renders the "No data" placeholder instead of throwing.
        List<Map<String, Object>> buckets;
        if (data == null) {
            buckets = new List<Map<String, Object>>();
        } else {
            buckets = DocGenChartBucketResolver.resolveBucketsForTag(data, relationship, field, modifiersRaw);
        }

        // The SVG serializer dispatches on options.style. Pass the rest of
        // the modifier surface (width, height, colors, title) through. Title
        // is re-attached here so the serializer renders its own heading line
        // inside the SVG — keeps the embedded chart visually self-contained
        // without an HTML <h2> outside it.
        Map<String, String> svgOpts = new Map<String, String>();
        for (String k : opts.keySet()) {
            svgOpts.put(k, opts.get(k));
        }
        svgOpts.put('style', style);
        if (String.isNotBlank(title)) {
            svgOpts.put('title', title);
        }

        return DocGenSvgChartSerializer.emit(buckets, svgOpts);
    }

    /**
     * Reassembles the inner {#ChartBucket:rel:field:opts} tag from the options
     * map (sans title, which is consumed by the expander).
     */
    private static String buildChartBucketTag(String relationship, String field, Map<String, String> opts) {
        String tag = '{#ChartBucket:' + relationship + ':' + field;
        if (!opts.isEmpty()) {
            List<String> kvs = new List<String>();
            for (String key : opts.keySet()) {
                kvs.add(key + '=' + opts.get(key));
            }
            tag += ':' + String.join(kvs, '&');
        }
        return tag + '}';
    }

    // ─── style renderers ─────────────────────────────────────────────────

    /**
     * A point size scaled by the tag's `fontSize=`, if it set one.
     *
     * THE THIRD RENDERER. Charts are drawn three ways — Chart.js in the browser,
     * DocGenSvgChartSerializer for Word and PowerPoint, and these HTML/CSS bars for
     * HTML-to-PDF. fontSize= was added to the first, then the second, and each time the
     * feature looked finished until someone generated through the path that had been
     * missed. Two byte-identical PDFs at fontSize=10 and fontSize=26 is what finally
     * showed this one.
     *
     * `fontSize=` is stated in PIXELS, as it is everywhere else, and the default of 12px
     * is exactly the 9pt this path already used — so an unset option changes nothing.
     * Everything else keeps its ratio to that 9pt, which is why a heading stays a
     * heading.
     *
     * Not applied to the 1px rules: those give a zero-height bar its line box and are
     * layout, not text. Scaling them would push every bar out of shape.
     */
    /**
     * A `font-size:` declaration for a cell that normally inherits the document font —
     * emitted ONLY when the tag asked for a size.
     *
     * The category-label cells never carried a size; they took the document's. So
     * fontSize= moved the value labels and left the categories behind, which measured as
     * "3 (50.0%)" growing from 7.8pt to 23.4pt while "Sales" stayed at 10.3.
     *
     * Conditional rather than always-on, deliberately. Giving these cells a fixed base
     * would change how every existing chart looks in templates that set their own body
     * font — a silent restyle of documents nobody asked to change. With no fontSize= the
     * output is byte-for-byte what it was.
     */
    /**
     * A Decimal as a CSS length, which rules out scientific notation.
     *
     * `stripTrailingZeros()` renders any multiple of ten as `1E+1`, `2E+1`, `4E+1`. That
     * is not a valid CSS length: the engine discards the declaration and the element
     * silently falls back to the inherited size. It bites unevenly — at fontSize=12 the
     * 10pt cell broke, at fontSize=30 the 16pt title broke, and at 24 nothing did, which
     * is exactly the value the first tests happened to use.
     *
     * Trailing ".0" is trimmed by hand instead, so 10.0 prints as "10" and 10.5 stays
     * "10.5".
     */
    private static String css(Decimal v) {
        String out = String.valueOf(v.setScale(1, System.RoundingMode.HALF_UP));
        return out.endsWith('.0') ? out.removeEnd('.0') : out;
    }

    private static String fsPtIfSet(Decimal basePt, Map<String, String> opts) {
        if (opts == null || String.isBlank(opts.get('fontSize'))) {
            return '';
        }
        return ' font-size:' + fsPt(basePt, opts) + 'pt;';
    }

    private static String fsPt(Decimal basePt, Map<String, String> opts) {
        if (opts == null || String.isBlank(opts.get('fontSize'))) {
            return css(basePt);
        }
        Decimal requestedPx;
        try {
            requestedPx = Decimal.valueOf(opts.get('fontSize').trim());
        } catch (Exception e) {
            return css(basePt);
        }
        if (requestedPx <= 0) {
            return css(basePt);
        }
        // Clamped to the same 6-48px the Canvas control offers.
        Decimal clamped = Math.min(Math.max(requestedPx, 6), 48);
        return css(basePt * clamped / LABEL_BASE_PX);
    }

    /** The pixel size `fontSize=` names. 12px is the 9pt this path already drew. */
    private static final Decimal LABEL_BASE_PX = 12;

    /**
     * The HTML a chart style renders to, for tests.
     *
     * Public because the e2e scripts and the QA harness run as anonymous Apex, where a
     * @TestVisible private is unreachable. Not global, so it stays invisible to
     * subscribers.
     */
    @TestVisible
    public static String renderForTest(String title, String chartBucketTag, Map<String, String> opts) {
        String style = opts == null ? 'bar' : opts.get('style');
        if (style == 'pivot') {
            return renderPivot(title, chartBucketTag, opts.get('colSort'), opts);
        }
        if (style == 'clustered') {
            return renderClustered(title, chartBucketTag, opts.get('colSort'), opts);
        }
        if (style == 'stacked') {
            return renderStacked(title, chartBucketTag, opts.get('colSort'), opts);
        }
        return renderBar(title, chartBucketTag, opts);
    }

    private static String renderBar(String title, String chartBucketTag, Map<String, String> opts) {
        String h = String.isBlank(title)
            ? ''
            : '<h2 style="margin:18px 0 10px 0; color:#1e3a8a; font-size:' +
              fsPt(16, opts) +
              'pt; font-weight:bold; line-height:1.25;">' +
              escape(title) +
              '</h2>';
        return h +
            '<table style="width:100%; border-collapse:collapse; margin:6px 0 18px 0;">' +
            chartBucketTag +
            '<tr>' +
            '<td style="padding:7px 6px; vertical-align:middle; border-bottom:1px solid #e5e7eb; font-weight:bold; color:#1f2937; padding-right:14px; width:28%;' +
            fsPtIfSet(10, opts) +
            '">{key_label}</td>' +
            '<td style="padding:7px 6px; vertical-align:middle; border-bottom:1px solid #e5e7eb; width:55%;">' +
            '<div style="width:100%; background-color:#f3f4f6; height:18px; border:1px solid #e5e7eb;">' +
            '<div style="height:18px; line-height:18px; font-size:1px; width:{percent}%; background-color:{color};">&nbsp;</div>' +
            '</div>' +
            '</td>' +
            '<td style="padding:7px 6px; vertical-align:middle; border-bottom:1px solid #e5e7eb; width:17%; text-align:right; color:#6b7280; font-size:' +
            fsPt(10, opts) +
            'pt; padding-left:14px; white-space:nowrap;">{count} ({percent}%)</td>' +
            '</tr>' +
            '{:else}' +
            '<tr><td colspan="3" style="padding:14px; background-color:#fef3c7; border-left:4px solid #fbbf24; color:#92400e; font-style:italic;">No data available for this chart.</td></tr>' +
            '{/ChartBucket}' +
            '</table>';
    }

    private static String renderPivot(String title, String chartBucketTag, String colSort, Map<String, String> opts) {
        String h = String.isBlank(title)
            ? ''
            : '<h2 style="margin:18px 0 10px 0; color:#1e3a8a; font-size:' +
              fsPt(16, opts) +
              'pt; font-weight:bold; line-height:1.25;">' +
              escape(title) +
              '</h2>';

        List<String> headerCells = new List<String>();
        headerCells.add(
            '<div style="display:table-cell; padding:8px 10px; background-color:#1e3a8a; color:#fff; font-weight:bold; font-size:' +
                fsPt(9, opts) +
                'pt; letter-spacing:1px; text-transform:uppercase; border-bottom:2px solid #fbbf24; text-align:left;">Answer</div>'
        );
        for (String col : colSort.split(',')) {
            headerCells.add(
                '<div style="display:table-cell; padding:8px 10px; background-color:#1e3a8a; color:#fff; font-weight:bold; font-size:' +
                    fsPt(9, opts) +
                    'pt; letter-spacing:1px; text-transform:uppercase; border-bottom:2px solid #fbbf24; text-align:right;">' +
                    escape(col.trim()) +
                    '</div>'
            );
        }
        headerCells.add(
            '<div style="display:table-cell; padding:8px 10px; background-color:#fbbf24; color:#1f2937; font-weight:bold; font-size:' +
                fsPt(9, opts) +
                'pt; letter-spacing:1px; text-transform:uppercase; border-bottom:2px solid #fbbf24; text-align:right;">Total</div>'
        );

        return h +
            '<div style="display:table; width:100%; border-collapse:collapse; margin:6px 0 18px 0;">' +
            '<div style="display:table-row;">' +
            String.join(headerCells, '') +
            '</div>' +
            chartBucketTag +
            '<div style="display:table-row;">' +
            '<div style="display:table-cell; padding:7px 10px; border-bottom:1px solid #e5e7eb; font-weight:bold; color:#1e3a8a;' +
            fsPtIfSet(9, opts) +
            '">{key_label}</div>' +
            '{#cols}' +
            '<div style="display:table-cell; padding:7px 10px; border-bottom:1px solid #e5e7eb; text-align:right; color:#1f2937;">{percent}%</div>' +
            '{/cols}' +
            '</div>' +
            '{:else}' +
            '<div style="display:table-row;"><div style="display:table-cell; padding:14px; background-color:#fef3c7; color:#92400e; font-style:italic;">No data available for this chart.</div></div>' +
            '{/ChartBucket}' +
            '</div>';
    }

    private static String renderClustered(
        String title,
        String chartBucketTag,
        String colSort,
        Map<String, String> opts
    ) {
        String h = String.isBlank(title)
            ? ''
            : '<h2 style="margin:18px 0 10px 0; color:#1e3a8a; font-size:' +
              fsPt(16, opts) +
              'pt; font-weight:bold; line-height:1.25;">' +
              escape(title) +
              '</h2>';

        // Legend: one swatch per colSort value, palette-cycled.
        List<String> swatches = new List<String>();
        Integer i = 0;
        for (String col : colSort.split(',')) {
            String color = paletteColor(i++);
            swatches.add(
                '<td style="padding:4px 14px 4px 0; font-size:' +
                    fsPt(9, opts) +
                    'pt; color:#374151; vertical-align:middle;">' +
                    '<span style="display:inline-block; width:14px; height:10px; margin-right:6px; vertical-align:middle; border:1px solid #d1d5db; background-color:' +
                    color +
                    ';">&nbsp;</span>' +
                    escape(col.trim()) +
                    '</td>'
            );
        }

        return h +
            '<table style="margin:6px auto 12px auto; border-collapse:collapse;"><tr>' +
            String.join(swatches, '') +
            '</tr></table>' +
            '<div style="display:table; width:100%; margin:8px 0 12px 0;">' +
            chartBucketTag +
            '<div style="display:table-cell; vertical-align:bottom; text-align:center; padding:0 4px; border-bottom:2px solid #1e3a8a;">' +
            '<div style="display:table; margin:0 auto; border-collapse:separate; border-spacing:1px 0;">' +
            '{#cols}' +
            '<div style="display:table-cell; vertical-align:bottom; width:22px; padding:0;">' +
            '<div style="font-size:' +
            fsPt(7, opts) +
            'pt; color:#6b7280; text-align:center; line-height:1.1; margin-bottom:1px; white-space:nowrap;">{percent_int}%</div>' +
            '<div style="width:22px; min-height:1px; height:{percent_int}px; background-color:{color};">&nbsp;</div>' +
            '</div>' +
            '{/cols}' +
            '</div>' +
            '<div style="padding-top:8px; font-size:' +
            fsPt(9, opts) +
            'pt; font-weight:bold; color:#1e3a8a; line-height:1.2;">{key_label}</div>' +
            '</div>' +
            '{:else}' +
            '<div style="padding:14px; background-color:#fef3c7; color:#92400e; font-style:italic;">No data available for this chart.</div>' +
            '{/ChartBucket}' +
            '</div>';
    }

    private static String renderStacked(String title, String chartBucketTag, String colSort, Map<String, String> opts) {
        String h = String.isBlank(title)
            ? ''
            : '<h2 style="margin:18px 0 10px 0; color:#1e3a8a; font-size:' +
              fsPt(16, opts) +
              'pt; font-weight:bold; line-height:1.25;">' +
              escape(title) +
              '</h2>';

        // Legend mirrors clustered.
        List<String> swatches = new List<String>();
        Integer i = 0;
        for (String col : colSort.split(',')) {
            String color = paletteColor(i++);
            swatches.add(
                '<td style="padding:4px 14px 4px 0; font-size:' +
                    fsPt(9, opts) +
                    'pt; color:#374151; vertical-align:middle;">' +
                    '<span style="display:inline-block; width:14px; height:10px; margin-right:6px; vertical-align:middle; border:1px solid #d1d5db; background-color:' +
                    color +
                    ';">&nbsp;</span>' +
                    escape(col.trim()) +
                    '</td>'
            );
        }

        return h +
            '<table style="margin:0 0 14px 0; border-collapse:collapse;"><tr>' +
            String.join(swatches, '') +
            '</tr></table>' +
            '<div style="display:table; width:100%; border-collapse:collapse; margin:0 0 18px 0;">' +
            chartBucketTag +
            '<div style="display:table-row;">' +
            '<div style="display:table-cell; padding:9px 8px; vertical-align:middle; border-bottom:1px solid #e5e7eb; width:30%; font-weight:bold; color:#1f2937;' +
            fsPtIfSet(9, opts) +
            '">{key_label}</div>' +
            '<div style="display:table-cell; padding:9px 8px; vertical-align:middle; border-bottom:1px solid #e5e7eb; width:55%;">' +
            '<div style="display:table; width:100%; height:18px; border:1px solid #d1d5db;">' +
            '{#cols}' +
            '<div style="display:table-cell; font-size:1px; line-height:1px; vertical-align:middle; background-color:{color}; width:{percent_of_row}%;">&nbsp;</div>' +
            '{/cols}' +
            '</div>' +
            '</div>' +
            '<div style="display:table-cell; padding:9px 8px; vertical-align:middle; border-bottom:1px solid #e5e7eb; width:15%; text-align:right; color:#6b7280; font-size:' +
            fsPt(10, opts) +
            'pt; white-space:nowrap;">{count} total</div>' +
            '</div>' +
            '{:else}' +
            '<div style="display:table-row;"><div style="display:table-cell; padding:14px; background-color:#fef3c7; color:#92400e; font-style:italic;">No data available for this chart.</div></div>' +
            '{/ChartBucket}' +
            '</div>';
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    /**
     * Renders a visually obvious error in HTML output, or a plain-text
     * placeholder in Word/PPT/Excel where injecting HTML into OOXML would
     * corrupt the document. Pre-#117 this threw for non-HTML — that gate is
     * gone now that Word supports charts via the PNG-via-CV pipeline; a
     * malformed tag should never halt the whole document, just flag itself
     * inline so the author sees it.
     */
    private static String renderError(Boolean isHtml, String reason, String snippet) {
        if (!isHtml) {
            return '[Chart error: ' + escapeForDisplay(reason) + ']';
        }
        // escapeForDisplay turns the original tag's curly braces into HTML
        // entities so the rendered error block can't be re-parsed as a tag on
        // a subsequent processXml pass — which would otherwise produce a
        // confusing chain of nested error blocks or, worse, fail with the
        // wrong templateType on the second pass.
        return '<div style="margin:12px 0; padding:12px 16px; background-color:#fef2f2; border-left:4px solid #ef4444; color:#991b1b; font-family:monospace; font-size:10pt;">' +
            '<strong>Chart error:</strong> ' +
            escapeForDisplay(reason) +
            '<br/><span style="color:#7f1d1d; font-size:9pt;">at ' +
            escapeForDisplay(snippet) +
            '</span></div>';
    }

    private static String escapeForDisplay(String s) {
        if (s == null) {
            return '';
        }
        return s.escapeXml().replace('{', '&#123;').replace('}', '&#125;');
    }

    /**
     * Decode the small set of XML entities that survive a docx/HTML round-trip
     * (Google Docs "Save as Web Page" escapes & → &amp;, ' → &apos;, etc.).
     * Without this, tags authored in Docs lose their & option separators —
     * the parser would split on the literal & inside &amp; and mangle every
     * cross-tab option string. Apply once on the tag body before parsing.
     * Numeric character refs like &#38; cover ampersands typed by hand or
     * emitted by some HTML pipelines.
     */
    private static String decodeEntities(String s) {
        if (s == null || s.indexOf('&') == -1) {
            return s;
        }
        return s.replace('&amp;', '&')
            .replace('&lt;', '<')
            .replace('&gt;', '>')
            .replace('&quot;', '"')
            .replace('&apos;', '\'')
            .replace('&#39;', '\'')
            .replace('&#34;', '"')
            .replace('&#38;', '&');
    }

    /**
     * Parses "k=v&k=v" into a Map. Preserves insertion order via LinkedHashMap-
     * equivalent (Apex Map<String,String> doesn't guarantee order, so we build
     * the rebuilt tag from the map keys regardless — order doesn't matter for
     * ChartBucket parsing).
     */
    private static Map<String, String> parseOptions(String raw) {
        Map<String, String> out = new Map<String, String>();
        if (String.isBlank(raw)) {
            return out;
        }
        for (String chunk : raw.split('&')) {
            Integer eq = chunk.indexOf('=');
            if (eq <= 0) {
                continue;
            }
            String k = chunk.substring(0, eq).trim();
            String v = chunk.substring(eq + 1).trim();
            if (String.isNotBlank(k)) {
                out.put(k, v);
            }
        }
        return out;
    }

    /**
     * Apex String.split takes a regex; for fixed delimiters this is overkill
     * and brittle when the delimiter is a regex metachar. We split on ':' with
     * a hard limit so option values can contain ':' (e.g. URLs in titles).
     */
    private static List<String> splitLimit(String s, String delim, Integer maxParts) {
        List<String> out = new List<String>();
        if (s == null) {
            return out;
        }
        Integer cursor = 0;
        Integer len = s.length();
        while (out.size() < maxParts - 1) {
            Integer at = s.indexOf(delim, cursor);
            if (at == -1) {
                break;
            }
            out.add(s.substring(cursor, at));
            cursor = at + delim.length();
        }
        out.add(s.substring(cursor, len));
        return out;
    }

    /**
     * Cycle through the same palette DocGenChartBucketResolver uses for {color}.
     * Kept private rather than referencing the resolver's PALETTE to avoid a
     * test-time circular dependency.
     */
    private static String paletteColor(Integer index) {
        List<String> palette = new List<String>{
            '#3b82f6',
            '#10b981',
            '#f59e0b',
            '#ef4444',
            '#8b5cf6',
            '#ec4899',
            '#06b6d4',
            '#84cc16'
        };
        Integer n = palette.size();
        return palette[Math.mod(index, n)];
    }

    private static String escape(String s) {
        return s == null ? '' : s.escapeXml();
    }

    public class ChartTagException extends Exception {
    }
}

/**
 * Emits chart SVG fragments from DocGenChartBucketResolver bucket data.
 *
 * Single dispatch entry point (`emit`) routes by `style` option to a
 * per-style emitter method. v1 ships `bar` only; subsequent PRs add `column`,
 * `line`, `pie`, `donut`, `stacked`, `clustered`, etc. — each emitter is a
 * self-contained method, free to use the shared helpers (color cycling, text
 * escaping, value formatting).
 *
 * Buckets are the same Map<String,Object> shape DocGenChartBucketResolver
 * already produces (`key`, `key_label`, `count`, `percent`, `max_percent`,
 * `color`, `index`). Cross-tab styles consume the same map plus its `cols`
 * sub-list.
 *
 * SVG strings are deterministic — pure function of (buckets, options). No DML,
 * no SOQL, no callouts. The output is suitable for client-side rasterization
 * in the LWC layer (#117 v1) or external rasterization service (v2).
 *
 * See #117 for the pipeline: Apex emits SVG → LWC <canvas>.drawImage → PNG →
 * saved as ContentVersion on the source record → existing image substitution
 * embeds it in every output format.
 */
public with sharing class DocGenSvgChartSerializer {
    // Same 8-color palette DocGenChartBucketResolver cycles when no
    // `colors=` modifier is supplied. Keeping the same default keeps charts
    // visually consistent whether they render via HTML+CSS bars or SVG→PNG.
    private static final List<String> DEFAULT_PALETTE = new List<String>{
        '#3b82f6',
        '#10b981',
        '#f59e0b',
        '#ef4444',
        '#8b5cf6',
        '#ec4899',
        '#06b6d4',
        '#84cc16'
    };

    private static final Set<String> KNOWN_STYLES = new Set<String>{
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
     * Top-level entry point. Dispatches by `options.style` (default `bar`).
     * Unknown style throws — caller is responsible for vocabulary validation
     * via DocGenChartTagExpander before reaching this emitter.
     */
    /**
     * A font size scaled by the tag's `fontSize=`, if it set one.
     *
     * The sizes below were chosen against each other — 14 for a title, 11 for an axis
     * label, 9 for a dense one — so an override has to move all of them together or the
     * hierarchy collapses. `fontSize=` states the AXIS LABEL size, the same thing it
     * means on the client, and everything else keeps its ratio to that.
     *
     * Why this exists: fontSize= was added to the browser renderer first, and this path
     * ignored it. A Flow or a batch job then produced a chart with different label sizes
     * from the same template rendered in the runner — the modifier documented as working
     * quietly doing nothing on the half of generation that has no browser.
     *
     * Clamped 6-48 to match the Canvas control, so a stray value cannot produce an
     * unreadable or absurd chart.
     */
    private static Integer fs(Integer base, Map<String, String> opts) {
        if (opts == null || String.isBlank(opts.get('fontSize'))) {
            return base;
        }
        Decimal requested;
        try {
            requested = Decimal.valueOf(opts.get('fontSize').trim());
        } catch (Exception e) {
            return base;
        }
        if (requested <= 0) {
            return base;
        }
        Decimal clamped = Math.min(Math.max(requested, 6), 48);
        // AXIS_LABEL_BASE is what fontSize= names; the rest scale against it.
        Integer scaled = (Integer) (Decimal.valueOf(base) * clamped / AXIS_LABEL_BASE).round();
        return Math.max(scaled, 1);
    }

    /**
     * The size `fontSize=` refers to. Every other literal is a ratio of this.
     *
     * 12, matching DocGenChartTagExpander.LABEL_BASE_PX (#304). It was 11, so the
     * same `fontSize=` produced 2.45x the defaults here and 2.25x on the CSS-bar
     * path — a template tuned on one renderer was wrong on the other, and there
     * was no value correct on both.
     */
    private static final Decimal AXIS_LABEL_BASE = 12;

    public static String emit(List<Map<String, Object>> buckets, Map<String, String> options) {
        if (buckets == null || buckets.isEmpty()) {
            return emitEmpty(options);
        }
        Map<String, String> opts = options == null ? new Map<String, String>() : options;
        String style = opts.containsKey('style') ? opts.get('style').toLowerCase() : 'bar';
        if (!KNOWN_STYLES.contains(style)) {
            throw new DocGenException(
                'Unknown chart style "' + style + '". Supported: ' + String.join(new List<String>(KNOWN_STYLES), ', ')
            );
        }
        if (style == 'bar') {
            return emitBar(buckets, opts);
        }
        if (style == 'column') {
            return emitColumn(buckets, opts);
        }
        if (style == 'pie') {
            return emitPie(buckets, opts, false);
        }
        if (style == 'donut') {
            return emitPie(buckets, opts, true);
        }
        if (style == 'stacked') {
            return emitStacked(buckets, opts);
        }
        if (style == 'clustered') {
            return emitClustered(buckets, opts);
        }
        if (style == 'line') {
            return emitLine(buckets, opts, false);
        }
        if (style == 'area') {
            return emitLine(buckets, opts, true);
        }
        throw new DocGenException('Style "' + style + '" not yet implemented.');
    }

    // =====================================================================
    // Bar — horizontal bar chart, one row per bucket.
    //
    // Layout: [label] [bar (width ∝ percent / max_percent)] [count(percent%)]
    // Visual matches the existing HTML+CSS bar style so PDF / DOCX / etc.
    // look the same whether rendered via HTML+CSS bars (HTML / PDF outputs)
    // or via this SVG → PNG path (OOXML outputs).
    // =====================================================================
    private static String emitBar(List<Map<String, Object>> buckets, Map<String, String> opts) {
        Integer width = optInt(opts, 'width', 500);
        Integer barHeight = 18;
        Integer barGap = 6;
        Integer labelWidth = optInt(opts, 'labelWidth', 140);
        Integer valueWidth = optInt(opts, 'valueWidth', 80);
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 28 : 0;
        Integer height = optInt(opts, 'height', titleHeight + (buckets.size() * (barHeight + barGap)) + barGap);

        List<String> palette = parsePalette(opts);
        Decimal maxPct = decimalOf(buckets[0].get('max_percent'));
        if (maxPct == null || maxPct <= 0) {
            // Fallback when max_percent isn't populated (shouldn't happen with
            // current resolver output but defensive): derive from this batch.
            maxPct = 0;
            for (Map<String, Object> b : buckets) {
                Decimal p = decimalOf(b.get('percent'));
                if (p != null && p > maxPct) {
                    maxPct = p;
                }
            }
            if (maxPct <= 0) {
                maxPct = 100;
            }
        }
        Integer barArea = Math.max(1, width - labelWidth - valueWidth - 10);

        List<String> parts = new List<String>();
        parts.add(
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="' +
                width +
                '" height="' +
                height +
                '" viewBox="0 0 ' +
                width +
                ' ' +
                height +
                '">'
        );
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="20" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }

        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            String label = stringOf(b.get('key_label'));
            if (String.isBlank(label)) {
                label = stringOf(b.get('key'));
            }
            if (label == null) {
                label = '';
            }
            Decimal count = decimalOf(b.get('count'));
            Decimal pct = decimalOf(b.get('percent'));
            if (count == null) {
                count = 0;
            }
            if (pct == null) {
                pct = 0;
            }
            String color = stringOf(b.get('color'));
            if (String.isBlank(color)) {
                color = palette[Math.mod(i, palette.size())];
            }
            Integer rowY = titleHeight + barGap + i * (barHeight + barGap);
            Integer barWidth = maxPct > 0 ? (Integer) ((pct / maxPct) * barArea) : 0;
            if (barWidth < 1 && pct > 0) {
                barWidth = 1; // visible sliver for non-zero buckets
            }
            Integer textY = rowY + barHeight - 4;

            parts.add(
                '<text x="0" y="' +
                    textY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(11, opts) +
                    '" fill="#374151">' +
                    escapeXml(label) +
                    '</text>'
            );
            parts.add(
                '<rect x="' +
                    labelWidth +
                    '" y="' +
                    rowY +
                    '" width="' +
                    barWidth +
                    '" height="' +
                    barHeight +
                    '" rx="2" fill="' +
                    escapeXmlAttr(color) +
                    '"/>'
            );
            String valueLabel = countAndPercent(count, pct);
            Integer valueX = Math.min(labelWidth + barWidth + 6, Math.max(labelWidth + 6, width - valueWidth + 4));
            parts.add(
                '<text x="' +
                    valueX +
                    '" y="' +
                    textY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(11, opts) +
                    '" fill="#111827">' +
                    escapeXml(valueLabel) +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    // =====================================================================
    // Column — vertical bar chart, one column per bucket.
    //
    // Layout: bars rise from a shared baseline, labels rotated below, value
    // labels above each bar. Same data model as `bar`; the rotation suits
    // category lists where short labels read better horizontally and the
    // value magnitude reads better vertically.
    // =====================================================================
    private static String emitColumn(List<Map<String, Object>> buckets, Map<String, String> opts) {
        Integer width = optInt(opts, 'width', 500);
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 28 : 0;
        Integer labelArea = 60; // bottom space for rotated category labels
        Integer plotPaddingTop = 18; // headroom for value labels above bars
        Integer plotPaddingLeft = 28; // y-axis breathing room
        Integer height = optInt(opts, 'height', titleHeight + plotPaddingTop + 200 + labelArea);
        Integer plotTop = titleHeight + plotPaddingTop;
        Integer plotBottom = height - labelArea;
        Integer plotHeight = plotBottom - plotTop;
        Integer plotLeft = plotPaddingLeft;
        Integer plotRight = width - 10;
        Integer plotWidth = plotRight - plotLeft;

        List<String> palette = parsePalette(opts);
        Decimal maxPct = decimalOf(buckets[0].get('max_percent'));
        Decimal maxCount = 0;
        for (Map<String, Object> b : buckets) {
            Decimal c = decimalOf(b.get('count'));
            if (c != null && c > maxCount) {
                maxCount = c;
            }
        }
        if (maxCount <= 0) {
            maxCount = 1;
        }

        Integer slotCount = buckets.size();
        Integer slotWidth = plotWidth / slotCount;
        Integer barWidth = Math.max(8, Math.min(48, (Integer) (slotWidth * 0.6)));

        List<String> parts = new List<String>();
        parts.add(
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="' +
                width +
                '" height="' +
                height +
                '" viewBox="0 0 ' +
                width +
                ' ' +
                height +
                '">'
        );
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="20" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }
        // Baseline + simple y-axis line
        parts.add(
            '<line x1="' +
                plotLeft +
                '" y1="' +
                plotBottom +
                '" x2="' +
                plotRight +
                '" y2="' +
                plotBottom +
                '" stroke="#d1d5db" stroke-width="1"/>'
        );

        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            String label = stringOf(b.get('key_label'));
            if (String.isBlank(label)) {
                label = stringOf(b.get('key'));
            }
            if (label == null) {
                label = '';
            }
            Decimal count = decimalOf(b.get('count'));
            Decimal pct = decimalOf(b.get('percent'));
            if (count == null) {
                count = 0;
            }
            if (pct == null) {
                pct = 0;
            }
            String color = stringOf(b.get('color'));
            if (String.isBlank(color)) {
                color = palette[Math.mod(i, palette.size())];
            }

            Integer slotCenter = plotLeft + (i * slotWidth) + (slotWidth / 2);
            Integer barX = slotCenter - (barWidth / 2);
            Integer barHeight = maxCount > 0 ? (Integer) ((count / maxCount) * plotHeight) : 0;
            if (barHeight < 1 && count > 0) {
                barHeight = 1;
            }
            Integer barY = plotBottom - barHeight;

            // Bar
            parts.add(
                '<rect x="' +
                    barX +
                    '" y="' +
                    barY +
                    '" width="' +
                    barWidth +
                    '" height="' +
                    barHeight +
                    '" rx="2" fill="' +
                    escapeXmlAttr(color) +
                    '"/>'
            );
            // Value label above the bar
            String valueLabel = countAndPercent(count, pct);
            parts.add(
                '<text x="' +
                    slotCenter +
                    '" y="' +
                    (barY - 6) +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(10, opts) +
                    '" fill="#111827" text-anchor="middle">' +
                    escapeXml(valueLabel) +
                    '</text>'
            );
            // Category label below baseline, rotated 30° for legibility on
            // long answer text without consuming horizontal slot.
            Integer labelY = plotBottom + 14;
            parts.add(
                '<text x="' +
                    slotCenter +
                    '" y="' +
                    labelY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(10, opts) +
                    '" fill="#374151" text-anchor="end" transform="rotate(-30 ' +
                    slotCenter +
                    ' ' +
                    labelY +
                    ')">' +
                    escapeXml(label) +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    // =====================================================================
    // Pie / Donut — circular slices, one per bucket.
    //
    // `donut` is `pie` with an inner hole (innerR = 0.55 * outerR by default;
    // override via opts.innerRadius). The math is identical: slice angle
    // proportional to count/total. Donut renders annular sector paths using
    // outer arc + inner reverse arc.
    //
    // Layout: pie left-of-center, legend on the right (one row per bucket
    // showing color swatch + label + count + percent).
    // =====================================================================
    private static String emitPie(List<Map<String, Object>> buckets, Map<String, String> opts, Boolean donut) {
        Integer width = optInt(opts, 'width', 540);
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 28 : 0;
        Integer rowHeight = 22;
        Integer legendHeight = buckets.size() * rowHeight + 10;
        Integer minHeight = Math.max(legendHeight, 220);
        Integer height = optInt(opts, 'height', titleHeight + minHeight + 10);

        Integer legendWidth = optInt(opts, 'legendWidth', 240);
        Integer chartArea = Math.max(120, width - legendWidth - 10);
        Integer chartHeight = height - titleHeight - 20;

        Integer cx = chartArea / 2;
        Integer cy = titleHeight + (chartHeight / 2) + 10;
        Integer radius = Math.max(40, Math.min(chartArea, chartHeight) / 2 - 10);
        Decimal innerRatio = 0.55;
        if (opts.containsKey('innerRadius')) {
            try {
                Decimal v = Decimal.valueOf(opts.get('innerRadius'));
                if (v > 0 && v < 1) {
                    innerRatio = v;
                }
            } catch (Exception e) {
                // ignore, keep default
            }
        }
        Integer innerR = donut ? (Integer) (radius * innerRatio) : 0;

        Decimal total = 0;
        for (Map<String, Object> b : buckets) {
            Decimal c = decimalOf(b.get('count'));
            if (c != null) {
                total += c;
            }
        }
        if (total <= 0) {
            return emitEmpty(opts);
        }

        List<String> palette = parsePalette(opts);
        List<String> parts = new List<String>();
        parts.add(
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="' +
                width +
                '" height="' +
                height +
                '" viewBox="0 0 ' +
                width +
                ' ' +
                height +
                '">'
        );
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="20" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }

        // Start at the top of the circle (12 o'clock, angle = -π/2).
        Double startAngle = -Math.PI / 2;

        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            Decimal count = decimalOf(b.get('count'));
            if (count == null || count <= 0) {
                continue;
            }
            Double sliceAngle = (count.doubleValue() / total.doubleValue()) * 2.0 * Math.PI;
            Double endAngle = startAngle + sliceAngle;

            String color = stringOf(b.get('color'));
            if (String.isBlank(color)) {
                color = palette[Math.mod(i, palette.size())];
            }

            Double sxOuter = cx + radius * Math.cos(startAngle);
            Double syOuter = cy + radius * Math.sin(startAngle);
            Double exOuter = cx + radius * Math.cos(endAngle);
            Double eyOuter = cy + radius * Math.sin(endAngle);
            Integer largeArc = (sliceAngle > Math.PI) ? 1 : 0;

            String path;
            if (donut) {
                Double sxInner = cx + innerR * Math.cos(startAngle);
                Double syInner = cy + innerR * Math.sin(startAngle);
                Double exInner = cx + innerR * Math.cos(endAngle);
                Double eyInner = cy + innerR * Math.sin(endAngle);
                path =
                    'M ' +
                    fmtNum(sxOuter) +
                    ',' +
                    fmtNum(syOuter) +
                    ' A ' +
                    radius +
                    ',' +
                    radius +
                    ' 0 ' +
                    largeArc +
                    ' 1 ' +
                    fmtNum(exOuter) +
                    ',' +
                    fmtNum(eyOuter) +
                    ' L ' +
                    fmtNum(exInner) +
                    ',' +
                    fmtNum(eyInner) +
                    ' A ' +
                    innerR +
                    ',' +
                    innerR +
                    ' 0 ' +
                    largeArc +
                    ' 0 ' +
                    fmtNum(sxInner) +
                    ',' +
                    fmtNum(syInner) +
                    ' Z';
            } else {
                path =
                    'M ' +
                    cx +
                    ',' +
                    cy +
                    ' L ' +
                    fmtNum(sxOuter) +
                    ',' +
                    fmtNum(syOuter) +
                    ' A ' +
                    radius +
                    ',' +
                    radius +
                    ' 0 ' +
                    largeArc +
                    ' 1 ' +
                    fmtNum(exOuter) +
                    ',' +
                    fmtNum(eyOuter) +
                    ' Z';
            }
            parts.add('<path d="' + path + '" fill="' + escapeXmlAttr(color) + '" stroke="#ffffff" stroke-width="1"/>');

            startAngle = endAngle;
        }

        // Legend column on the right
        Integer legendX = chartArea + 10;
        Integer legendY = titleHeight + 10;
        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            String label = stringOf(b.get('key_label'));
            if (String.isBlank(label)) {
                label = stringOf(b.get('key'));
            }
            if (label == null) {
                label = '';
            }
            Decimal count = decimalOf(b.get('count'));
            Decimal pct = decimalOf(b.get('percent'));
            if (count == null) {
                count = 0;
            }
            if (pct == null) {
                pct = 0;
            }
            String color = stringOf(b.get('color'));
            if (String.isBlank(color)) {
                color = palette[Math.mod(i, palette.size())];
            }

            Integer swatchY = legendY + (i * rowHeight);
            parts.add(
                '<rect x="' +
                    legendX +
                    '" y="' +
                    swatchY +
                    '" width="14" height="14" rx="2" fill="' +
                    escapeXmlAttr(color) +
                    '"/>'
            );
            String valueLabel = countAndPercent(count, pct);
            Integer legendTextX = legendX + 22;
            Integer legendTextMaxWidth = Math.max(20, width - legendTextX - 4);
            String legendLabel = fitLegendLabel(label, valueLabel, legendTextMaxWidth, 11);
            parts.add(
                '<text x="' +
                    legendTextX +
                    '" y="' +
                    (swatchY + 11) +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(11, opts) +
                    '" fill="#374151">' +
                    escapeXml(legendLabel) +
                    ' — ' +
                    escapeXml(valueLabel) +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    /**
     * Formats a Double as a string with no decimal point for whole numbers,
     * one decimal otherwise. Used inside SVG path `d=` attributes where
     * shorter strings keep the rendered output readable in debug dumps.
     */
    private static String fmtNum(Double v) {
        if (v == null) {
            return '0';
        }
        Decimal d = Decimal.valueOf(v);
        if (d == d.setScale(0)) {
            return String.valueOf(d.intValue());
        }
        return String.valueOf(d.setScale(2));
    }

    // =====================================================================
    // Stacked — horizontal stacked bar chart, one bar per top-level bucket.
    //
    // Each bar is segmented by `cols` (the cross-tab grouped dimension), with
    // each segment's width proportional to `percent_of_row`. The synthetic
    // Total column the resolver appends is excluded from the segments (its
    // 100% would consume the whole bar); the row count + percent of grand
    // total render as a right-side annotation instead.
    //
    // Layout: [legend swatches across top]
    //         [row label] [stacked bar (260px)] [count total]
    // =====================================================================
    private static String emitStacked(List<Map<String, Object>> buckets, Map<String, String> opts) {
        Integer width = optInt(opts, 'width', 540);
        Integer barHeight = 22;
        Integer barGap = 8;
        Integer labelWidth = 150;
        Integer valueWidth = 90;
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 26 : 0;

        List<String> palette = parsePalette(opts);
        List<Map<String, Object>> legendCols = collectLegendCols(buckets, opts, palette, true);
        Integer legendHeight = legendCols.isEmpty() ? 0 : 22;

        Integer height = optInt(
            opts,
            'height',
            titleHeight + legendHeight + (buckets.size() * (barHeight + barGap)) + barGap + 4
        );
        Integer barAreaX = labelWidth;
        Integer barAreaWidth = width - labelWidth - valueWidth;

        List<String> parts = new List<String>();
        parts.add(svgOpen(width, height));
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="18" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }
        appendLegendRow(parts, legendCols, 0, titleHeight, width, fs(10, opts));

        Integer rowsTop = titleHeight + legendHeight;
        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            String label = bucketLabel(b);
            Decimal rowTotal = decimalOf(b.get('count'));
            if (rowTotal == null) {
                rowTotal = 0;
            }
            Integer rowY = rowsTop + barGap + i * (barHeight + barGap);
            Integer textY = rowY + barHeight - 6;

            parts.add(
                '<text x="0" y="' +
                    textY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(11, opts) +
                    '" fill="#374151">' +
                    escapeXml(label) +
                    '</text>'
            );
            // Outline the stacked bar even when empty so blank rows still
            // show a visible bar slot.
            parts.add(
                '<rect x="' +
                    barAreaX +
                    '" y="' +
                    rowY +
                    '" width="' +
                    barAreaWidth +
                    '" height="' +
                    barHeight +
                    '" fill="#f3f4f6" stroke="#d1d5db" stroke-width="1"/>'
            );

            List<Object> cols = (List<Object>) b.get('cols');
            if (cols != null && !cols.isEmpty()) {
                Double offset = 0.0;
                Integer segIdx = 0;
                for (Object co : cols) {
                    Map<String, Object> col = (Map<String, Object>) co;
                    if (isTotalCol(col)) {
                        continue;
                    }
                    Decimal pct = decimalOf(col.get('percent_of_row'));
                    if (pct == null) {
                        pct = 0;
                    }
                    Double segW = (pct.doubleValue() / 100.0) * barAreaWidth;
                    if (segW > 0) {
                        String color = colorFor(col, palette, segIdx);
                        parts.add(
                            '<rect x="' +
                                fmtNum(barAreaX + offset) +
                                '" y="' +
                                rowY +
                                '" width="' +
                                fmtNum(segW) +
                                '" height="' +
                                barHeight +
                                '" fill="' +
                                escapeXmlAttr(color) +
                                '"/>'
                        );
                    }
                    offset += segW;
                    segIdx++;
                }
            }

            parts.add(
                '<text x="' +
                    (barAreaX +
                    barAreaWidth +
                    6) +
                    '" y="' +
                    textY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(11, opts) +
                    '" fill="#111827">' +
                    escapeXml(formatNumber(rowTotal) + ' total') +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    // =====================================================================
    // Clustered — vertical clustered bar chart, one cluster per top-level
    // bucket. Each cluster contains a mini-bar per `cols` entry (the grouped
    // dimension). Bar heights scale to `percent_int` against the tallest
    // observed cell so the visual range fills the plot area even when raw
    // percentages cluster low.
    //
    // Layout: [legend swatches across top]
    //         [plot area — clusters of vertical bars, baseline x-axis]
    //         [bucket key_label below each cluster, rotated -25°]
    //
    // Synthetic Total column excluded from clusters; including it produces a
    // dominant 100% bar that compresses the real values.
    // =====================================================================
    private static String emitClustered(List<Map<String, Object>> buckets, Map<String, String> opts) {
        Integer width = optInt(opts, 'width', 540);
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 26 : 0;

        List<String> palette = parsePalette(opts);
        List<Map<String, Object>> legendCols = collectLegendCols(buckets, opts, palette, true);
        Integer legendHeight = legendCols.isEmpty() ? 0 : 22;

        Integer labelArea = 64; // headroom for rotated cluster labels
        Integer plotPaddingTop = 14;
        Integer plotPaddingLeft = 30;
        Integer height = optInt(opts, 'height', titleHeight + legendHeight + plotPaddingTop + 200 + labelArea);
        Integer plotTop = titleHeight + legendHeight + plotPaddingTop;
        Integer plotBottom = height - labelArea;
        Integer plotHeight = plotBottom - plotTop;
        Integer plotLeft = plotPaddingLeft;
        Integer plotRight = width - 10;
        Integer plotWidth = plotRight - plotLeft;

        // Find peak percent across all visible cols (excludes Total) so the
        // tallest bar fills the plot, matching the HTML clustered renderer's
        // "bar height = percent_int px" with a sensible auto-scale.
        Decimal peakPct = 0;
        for (Map<String, Object> b : buckets) {
            List<Object> cols = (List<Object>) b.get('cols');
            if (cols == null) {
                continue;
            }
            for (Object co : cols) {
                Map<String, Object> col = (Map<String, Object>) co;
                if (isTotalCol(col)) {
                    continue;
                }
                Decimal pct = decimalOf(col.get('percent_int'));
                if (pct == null) {
                    pct = decimalOf(col.get('percent'));
                }
                if (pct != null && pct > peakPct) {
                    peakPct = pct;
                }
            }
        }
        if (peakPct <= 0) {
            peakPct = 100;
        }

        Integer slotCount = Math.max(1, buckets.size());
        Integer slotWidth = plotWidth / slotCount;
        Integer visibleColCount = legendCols.size();
        Integer barSlotWidth = Math.max(4, (Integer) (slotWidth * 0.72));
        Integer perBarWidth = visibleColCount > 0 ? Math.max(3, barSlotWidth / visibleColCount) : barSlotWidth;

        List<String> parts = new List<String>();
        parts.add(svgOpen(width, height));
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="18" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }
        appendLegendRow(parts, legendCols, 0, titleHeight, width, fs(10, opts));

        // Baseline
        parts.add(
            '<line x1="' +
                plotLeft +
                '" y1="' +
                plotBottom +
                '" x2="' +
                plotRight +
                '" y2="' +
                plotBottom +
                '" stroke="#d1d5db" stroke-width="1"/>'
        );

        for (Integer i = 0; i < buckets.size(); i++) {
            Map<String, Object> b = buckets[i];
            String label = bucketLabel(b);
            Integer slotCenter = plotLeft + (i * slotWidth) + (slotWidth / 2);
            List<Object> cols = (List<Object>) b.get('cols');

            // Filter to visible (non-Total) cols for placement math.
            List<Map<String, Object>> visible = new List<Map<String, Object>>();
            if (cols != null) {
                for (Object co : cols) {
                    Map<String, Object> col = (Map<String, Object>) co;
                    if (!isTotalCol(col)) {
                        visible.add(col);
                    }
                }
            }
            Integer clusterWidth = perBarWidth * visible.size();
            Integer clusterX = slotCenter - (clusterWidth / 2);

            for (Integer j = 0; j < visible.size(); j++) {
                Map<String, Object> col = visible[j];
                Decimal pct = decimalOf(col.get('percent_int'));
                if (pct == null) {
                    pct = decimalOf(col.get('percent'));
                }
                if (pct == null) {
                    pct = 0;
                }
                Integer barH = ((pct * plotHeight) / peakPct).intValue();
                if (barH < 1 && pct > 0) {
                    barH = 1;
                }
                Integer barX = clusterX + (j * perBarWidth);
                Integer barY = plotBottom - barH;
                String color = colorFor(col, palette, j);

                parts.add(
                    '<rect x="' +
                        barX +
                        '" y="' +
                        barY +
                        '" width="' +
                        Math.max(1, perBarWidth - 1) +
                        '" height="' +
                        barH +
                        '" fill="' +
                        escapeXmlAttr(color) +
                        '"/>'
                );
            }

            Integer labelY = plotBottom + 14;
            parts.add(
                '<text x="' +
                    slotCenter +
                    '" y="' +
                    labelY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(10, opts) +
                    '" fill="#374151" text-anchor="end" transform="rotate(-25 ' +
                    slotCenter +
                    ' ' +
                    labelY +
                    ')">' +
                    escapeXml(label) +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    // =====================================================================
    // Line / Area — sequential line chart, one polyline through (x=bucket
    // index, y=count). When `cols` is populated (groupBy=), draws one
    // polyline per visible col (Total excluded) so multi-series cross-tab
    // data charts naturally.
    //
    // Layout: [legend swatches if multi-series]
    //         [y-axis tick label "max"]
    //         [plot area — polyline(s) + optional area fill]
    //         [x-axis labels per bucket, rotated -25°]
    //
    // `area=true` adds a semi-transparent polygon below each polyline.
    // =====================================================================
    private static String emitLine(List<Map<String, Object>> buckets, Map<String, String> opts, Boolean filled) {
        Integer width = optInt(opts, 'width', 500);
        String title = opts.get('title');
        Integer titleHeight = String.isNotBlank(title) ? 26 : 0;

        List<String> palette = parsePalette(opts);
        Boolean multiSeries = hasCols(buckets);
        List<Map<String, Object>> legendCols = multiSeries
            ? collectLegendCols(buckets, opts, palette, true)
            : new List<Map<String, Object>>();
        Integer legendHeight = legendCols.isEmpty() ? 0 : 22;

        Integer labelArea = 60;
        Integer plotPaddingTop = 14;
        // Leave room on the left for both the y-axis tick + the leftmost
        // rotated category label (rotated -25° anchored at end → extends ~30px
        // back from its anchor point for typical 10-char labels).
        Integer plotPaddingLeft = 60;
        Integer height = optInt(opts, 'height', titleHeight + legendHeight + plotPaddingTop + 200 + labelArea);
        Integer plotTop = titleHeight + legendHeight + plotPaddingTop;
        Integer plotBottom = height - labelArea;
        Integer plotHeight = plotBottom - plotTop;
        Integer plotLeft = plotPaddingLeft;
        Integer plotRight = width - 14;
        Integer plotWidth = plotRight - plotLeft;

        // Y scale: peak count across whichever series are in scope.
        Decimal peakCount = 0;
        if (multiSeries) {
            for (Map<String, Object> b : buckets) {
                List<Object> cols = (List<Object>) b.get('cols');
                if (cols == null) {
                    continue;
                }
                for (Object co : cols) {
                    Map<String, Object> col = (Map<String, Object>) co;
                    if (isTotalCol(col)) {
                        continue;
                    }
                    Decimal c = decimalOf(col.get('count'));
                    if (c != null && c > peakCount) {
                        peakCount = c;
                    }
                }
            }
        } else {
            for (Map<String, Object> b : buckets) {
                Decimal c = decimalOf(b.get('count'));
                if (c != null && c > peakCount) {
                    peakCount = c;
                }
            }
        }
        if (peakCount <= 0) {
            peakCount = 1;
        }

        List<String> parts = new List<String>();
        parts.add(svgOpen(width, height));
        parts.add('<rect x="0" y="0" width="' + width + '" height="' + height + '" fill="#ffffff"/>');
        if (String.isNotBlank(title)) {
            parts.add(
                '<text x="0" y="18" font-family="Arial, sans-serif" font-size="' +
                    fs(14, opts) +
                    '" font-weight="bold" fill="#111827">' +
                    escapeXml(title) +
                    '</text>'
            );
        }
        appendLegendRow(parts, legendCols, 0, titleHeight, width, fs(10, opts));

        // Axes
        parts.add(
            '<line x1="' +
                plotLeft +
                '" y1="' +
                plotTop +
                '" x2="' +
                plotLeft +
                '" y2="' +
                plotBottom +
                '" stroke="#d1d5db" stroke-width="1"/>'
        );
        parts.add(
            '<line x1="' +
                plotLeft +
                '" y1="' +
                plotBottom +
                '" x2="' +
                plotRight +
                '" y2="' +
                plotBottom +
                '" stroke="#d1d5db" stroke-width="1"/>'
        );
        // Y axis peak tick
        parts.add(
            '<text x="' +
                (plotLeft - 4) +
                '" y="' +
                (plotTop + 4) +
                '" font-family="Arial, sans-serif" font-size="' +
                fs(9, opts) +
                '" fill="#6b7280" text-anchor="end">' +
                escapeXml(formatNumber(peakCount)) +
                '</text>'
        );
        parts.add(
            '<text x="' +
                (plotLeft - 4) +
                '" y="' +
                (plotBottom + 3) +
                '" font-family="Arial, sans-serif" font-size="' +
                fs(9, opts) +
                '" fill="#6b7280" text-anchor="end">0</text>'
        );

        Integer n = buckets.size();
        // X positions per bucket. Distribute evenly; if only one point, center it.
        List<Double> xs = new List<Double>();
        if (n == 1) {
            xs.add(plotLeft + plotWidth / 2.0);
        } else {
            Double step = plotWidth / Double.valueOf(n - 1);
            for (Integer i = 0; i < n; i++) {
                xs.add(plotLeft + i * step);
            }
        }

        // Render each series.
        if (multiSeries) {
            Integer seriesCount = legendCols.size();
            for (Integer s = 0; s < seriesCount; s++) {
                Map<String, Object> seriesLegend = legendCols[s];
                String seriesKeyLower = ((String) seriesLegend.get('_keyLower'));
                String color = colorFor(seriesLegend, palette, s);
                emitSeries(parts, buckets, xs, plotBottom, plotHeight, peakCount, color, seriesKeyLower, filled);
            }
        } else {
            String color = palette[0];
            emitSeries(parts, buckets, xs, plotBottom, plotHeight, peakCount, color, null, filled);
        }

        // X axis category labels (use top-level bucket keys).
        Integer labelY = plotBottom + 14;
        for (Integer i = 0; i < n; i++) {
            String label = bucketLabel(buckets[i]);
            Integer cx = (Integer) Math.round(xs[i]);
            parts.add(
                '<text x="' +
                    cx +
                    '" y="' +
                    labelY +
                    '" font-family="Arial, sans-serif" font-size="' +
                    fs(10, opts) +
                    '" fill="#374151" text-anchor="end" transform="rotate(-25 ' +
                    cx +
                    ' ' +
                    labelY +
                    ')">' +
                    escapeXml(label) +
                    '</text>'
            );
        }

        parts.add('</svg>');
        return String.join(parts, '');
    }

    /**
     * Renders a single series (polyline + optional area fill + point dots)
     * onto the provided parts buffer. Used by both line and area emitters.
     *
     * When `seriesKeyLower` is null, the series is sourced from each bucket's
     * top-level `count` (single-series mode). Otherwise the series pulls
     * `count` from the matching entry in each bucket's `cols` list (matched
     * by key, case-insensitive).
     */
    private static void emitSeries(
        List<String> parts,
        List<Map<String, Object>> buckets,
        List<Double> xs,
        Integer plotBottom,
        Integer plotHeight,
        Decimal peakCount,
        String color,
        String seriesKeyLower,
        Boolean filled
    ) {
        Integer n = buckets.size();
        List<Double> ys = new List<Double>();
        for (Integer i = 0; i < n; i++) {
            Decimal c = null;
            if (seriesKeyLower == null) {
                c = decimalOf(buckets[i].get('count'));
            } else {
                List<Object> cols = (List<Object>) buckets[i].get('cols');
                if (cols != null) {
                    for (Object co : cols) {
                        Map<String, Object> col = (Map<String, Object>) co;
                        String k = stringOf(col.get('key'));
                        if (k != null && k.toLowerCase() == seriesKeyLower) {
                            c = decimalOf(col.get('count'));
                            break;
                        }
                    }
                }
            }
            if (c == null) {
                c = 0;
            }
            Double y = plotBottom - (c.doubleValue() / peakCount.doubleValue()) * plotHeight;
            ys.add(y);
        }

        // Polyline points string.
        List<String> pts = new List<String>();
        for (Integer i = 0; i < n; i++) {
            pts.add(fmtNum(xs[i]) + ',' + fmtNum(ys[i]));
        }
        String ptsStr = String.join(pts, ' ');

        // Area fill below polyline, drawn first so the line overdraws.
        if (filled && n > 0) {
            List<String> areaPts = new List<String>();
            areaPts.add(fmtNum(xs[0]) + ',' + fmtNum(Double.valueOf(plotBottom)));
            for (Integer i = 0; i < n; i++) {
                areaPts.add(fmtNum(xs[i]) + ',' + fmtNum(ys[i]));
            }
            areaPts.add(fmtNum(xs[n - 1]) + ',' + fmtNum(Double.valueOf(plotBottom)));
            parts.add(
                '<polygon points="' +
                    String.join(areaPts, ' ') +
                    '" fill="' +
                    escapeXmlAttr(color) +
                    '" fill-opacity="0.25" stroke="none"/>'
            );
        }
        parts.add(
            '<polyline points="' +
                ptsStr +
                '" fill="none" stroke="' +
                escapeXmlAttr(color) +
                '" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
        );
        // Point markers.
        for (Integer i = 0; i < n; i++) {
            parts.add(
                '<circle cx="' +
                    fmtNum(xs[i]) +
                    '" cy="' +
                    fmtNum(ys[i]) +
                    '" r="2.5" fill="' +
                    escapeXmlAttr(color) +
                    '"/>'
            );
        }
    }

    // =====================================================================
    // Cross-tab helpers
    // =====================================================================

    /**
     * Builds the legend column list for cross-tab styles. Walks the first
     * bucket that has `cols` populated and (optionally) excludes the
     * synthetic Total entry. Falls back to options.colSort when no bucket
     * has cols (defensive — shouldn't happen with a valid resolver run).
     *
     * Each returned map includes the original col map fields plus a
     * `_keyLower` field so callers can do case-insensitive series-key
     * matching against the buckets' `cols` lists.
     */
    private static List<Map<String, Object>> collectLegendCols(
        List<Map<String, Object>> buckets,
        Map<String, String> opts,
        List<String> palette,
        Boolean excludeTotal
    ) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Map<String, Object> b : buckets) {
            List<Object> cols = (List<Object>) b.get('cols');
            if (cols == null || cols.isEmpty()) {
                continue;
            }
            Integer idx = 0;
            for (Object co : cols) {
                Map<String, Object> col = (Map<String, Object>) co;
                if (excludeTotal && isTotalCol(col)) {
                    continue;
                }
                Map<String, Object> entry = new Map<String, Object>(col);
                if (String.isBlank(stringOf(entry.get('color')))) {
                    entry.put('color', palette[Math.mod(idx, palette.size())]);
                }
                String k = stringOf(entry.get('key'));
                entry.put('_keyLower', k == null ? '' : k.toLowerCase());
                out.add(entry);
                idx++;
            }
            return out;
        }
        // Fallback: derive from opts.colSort.
        if (opts != null && String.isNotBlank(opts.get('colSort'))) {
            Integer idx = 0;
            for (String name : opts.get('colSort').split(',')) {
                String trimmed = name.trim();
                if (String.isBlank(trimmed)) {
                    continue;
                }
                Map<String, Object> entry = new Map<String, Object>();
                entry.put('key', trimmed);
                entry.put('key_label', trimmed);
                entry.put('color', palette[Math.mod(idx, palette.size())]);
                entry.put('_keyLower', trimmed.toLowerCase());
                out.add(entry);
                idx++;
            }
        }
        return out;
    }

    /**
     * Detects the synthetic "Total" column the resolver appends to every
     * cross-tab row. Matched by key (case-insensitive) since `key` and
     * `key_label` are both literal "Total" in the resolver output.
     */
    private static Boolean isTotalCol(Map<String, Object> col) {
        if (col == null) {
            return false;
        }
        String k = stringOf(col.get('key'));
        return k != null && k.equalsIgnoreCase('Total');
    }

    /**
     * True when any bucket carries a non-empty `cols` sub-list, indicating
     * cross-tab data from the `groupBy=` modifier.
     */
    private static Boolean hasCols(List<Map<String, Object>> buckets) {
        for (Map<String, Object> b : buckets) {
            List<Object> cols = (List<Object>) b.get('cols');
            if (cols != null && !cols.isEmpty()) {
                return true;
            }
        }
        return false;
    }

    /**
     * Color resolution: bucket-supplied `color` field wins; otherwise the
     * palette cycles by `index` (1-based) or the fallback ordinal.
     */
    private static String colorFor(Map<String, Object> bucket, List<String> palette, Integer fallbackIdx) {
        String color = stringOf(bucket.get('color'));
        if (String.isNotBlank(color)) {
            return color;
        }
        return palette[Math.mod(fallbackIdx, palette.size())];
    }

    private static String bucketLabel(Map<String, Object> b) {
        String label = stringOf(b.get('key_label'));
        if (String.isBlank(label)) {
            label = stringOf(b.get('key'));
        }
        return label == null ? '' : label;
    }

    /**
     * Appends a single legend row of swatch + label entries below the title
     * (or at y=0 if no title). Returns silently when the col list is empty.
     * Layout: each entry takes ~110px; entries wrap by width.
     */
    // labelPx rather than opts: this helper is shared by three emitters and only needs
    // the resolved size, not the whole option map.
    private static void appendLegendRow(
        List<String> parts,
        List<Map<String, Object>> legendCols,
        Integer startX,
        Integer startY,
        Integer maxWidth,
        Integer labelPx
    ) {
        if (legendCols == null || legendCols.isEmpty()) {
            return;
        }
        Integer y = startY + 4;
        Integer x = startX;
        Integer entryWidth = 110;
        Integer swatchH = 10;
        for (Integer i = 0; i < legendCols.size(); i++) {
            Map<String, Object> col = legendCols[i];
            String label = stringOf(col.get('key_label'));
            if (String.isBlank(label)) {
                label = stringOf(col.get('key'));
            }
            if (label == null) {
                label = '';
            }
            if (label.length() > 14) {
                label = label.substring(0, 13) + '…';
            }
            String color = stringOf(col.get('color'));
            if (String.isBlank(color)) {
                color = '#9ca3af';
            }
            // Wrap to next row when out of horizontal room.
            if (x + entryWidth > maxWidth) {
                x = startX;
                y += 16;
            }
            parts.add(
                '<rect x="' +
                    x +
                    '" y="' +
                    y +
                    '" width="14" height="' +
                    swatchH +
                    '" fill="' +
                    escapeXmlAttr(color) +
                    '" stroke="#d1d5db" stroke-width="1"/>'
            );
            parts.add(
                '<text x="' +
                    (x + 20) +
                    '" y="' +
                    (y +
                    swatchH -
                    1) +
                    '" font-family="Arial, sans-serif" font-size="' +
                    labelPx +
                    '" fill="#374151">' +
                    escapeXml(label) +
                    '</text>'
            );
            x += entryWidth;
        }
    }

    /**
     * Common SVG open tag. Centralized so width/height/viewBox stay in sync
     * across emitters and a future change (e.g. preserveAspectRatio) lands
     * in one place.
     */
    private static String svgOpen(Integer width, Integer height) {
        return '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="' +
            width +
            '" height="' +
            height +
            '" viewBox="0 0 ' +
            width +
            ' ' +
            height +
            '">';
    }

    // =====================================================================
    // Empty-state — bucket list is empty (no data to chart). Render a
    // placeholder SVG with a "No data" label so the embedded image still
    // exists rather than the chart tag silently producing nothing.
    // =====================================================================
    private static String emitEmpty(Map<String, String> options) {
        Integer width = options != null && options.containsKey('width') ? Integer.valueOf(options.get('width')) : 500;
        Integer height = options != null && options.containsKey('height') ? Integer.valueOf(options.get('height')) : 80;
        return '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="' +
            width +
            '" height="' +
            height +
            '" viewBox="0 0 ' +
            width +
            ' ' +
            height +
            '">' +
            '<rect x="0" y="0" width="' +
            width +
            '" height="' +
            height +
            '" fill="#f3f4f6" stroke="#d1d5db"/>' +
            '<text x="' +
            (width / 2) +
            '" y="' +
            (height / 2 + 5) +
            '" font-family="Arial, sans-serif" font-size="' +
            fs(13, options) +
            '" fill="#9ca3af" text-anchor="middle">No data</text>' +
            '</svg>';
    }

    // =====================================================================
    // Shared helpers
    // =====================================================================

    @TestVisible
    private static List<String> parsePalette(Map<String, String> opts) {
        if (opts == null || !opts.containsKey('colors')) {
            return DEFAULT_PALETTE;
        }
        String raw = opts.get('colors');
        if (String.isBlank(raw)) {
            return DEFAULT_PALETTE;
        }
        List<String> out = new List<String>();
        for (String c : raw.split(',')) {
            String trimmed = c.trim();
            if (String.isNotBlank(trimmed)) {
                out.add(trimmed);
            }
        }
        return out.isEmpty() ? DEFAULT_PALETTE : out;
    }

    @TestVisible
    private static String countAndPercent(Decimal count, Decimal pct) {
        // Matches the existing HTML+CSS bar value-label format: "42 (80%)"
        // Drops decimals when whole; one decimal when fractional.
        String c = formatNumber(count);
        String p = formatNumber(pct);
        return c + ' (' + p + '%)';
    }

    private static String formatNumber(Decimal n) {
        if (n == null) {
            return '0';
        }
        if (n == n.setScale(0)) {
            return String.valueOf(n.intValue());
        }
        return String.valueOf(n.setScale(1));
    }

    private static String escapeXml(String s) {
        if (s == null) {
            return '';
        }
        return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;');
    }

    private static String escapeXmlAttr(String s) {
        if (s == null) {
            return '';
        }
        return s.replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;');
    }

    private static String fitLegendLabel(String label, String valueLabel, Integer maxWidthPx, Integer fontSizePx) {
        if (label == null) {
            label = '';
        }
        Integer reserved = ((valueLabel == null ? 0 : valueLabel.length()) + 3) * 7;
        Integer available = Math.max(14, maxWidthPx - reserved);
        Integer approxCharWidth = Math.max(4, (fontSizePx * 6) / 10);
        Integer maxChars = Math.max(1, available / approxCharWidth);
        if (label.length() <= maxChars) {
            return label;
        }
        if (maxChars <= 1) {
            return '…';
        }
        return label.substring(0, maxChars - 1) + '…';
    }

    private static Integer optInt(Map<String, String> opts, String key, Integer fallback) {
        if (opts == null || !opts.containsKey(key)) {
            return fallback;
        }
        try {
            return Integer.valueOf(opts.get(key));
        } catch (Exception e) {
            return fallback;
        }
    }

    private static Decimal decimalOf(Object v) {
        if (v == null) {
            return null;
        }
        if (v instanceof Decimal) {
            return (Decimal) v;
        }
        if (v instanceof Integer) {
            return Decimal.valueOf((Integer) v);
        }
        if (v instanceof Long) {
            return Decimal.valueOf((Long) v);
        }
        if (v instanceof Double) {
            return Decimal.valueOf((Double) v);
        }
        try {
            return Decimal.valueOf(String.valueOf(v));
        } catch (Exception e) {
            return null;
        }
    }

    private static String stringOf(Object v) {
        return v == null ? null : String.valueOf(v);
    }
}

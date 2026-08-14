/**
 * docGenChartJsRenderer
 *
 * Client-side chart pipeline: page child rows -> bucket them in JS -> rasterize
 * with Chart.js -> PNG. Pairs with DocGenChartImageController.getChartTagsForTemplate.
 *
 * WHY THIS EXISTS
 * ---------------
 * The Apex path (`prepareChartImages` / `prepareChartImagesServerSide`) has to
 * resolve buckets one of two ways, and both have a ceiling:
 *
 *   1. In-memory  — needs every child row in the merge data map. The scout's
 *      `base + rows * 2000` estimate against 6 MB * 0.6 caps this near ~1,800
 *      rows, after which PowerPoint/Excel generation is refused outright.
 *   2. SOQL GROUP BY — constant cost, but only works on a groupable field. Long
 *      textareas (e.g. VMR_Tracker__Answer_8__c, 2,000 chars) are not groupable,
 *      not filterable, not sortable, so this path is simply unavailable for them.
 *
 * Bucketing in the browser sidesteps both: rows arrive 500 at a time through
 * `getChildRecordPage`, get folded into counts, and are then discarded. Peak
 * memory is O(distinct values), not O(rows), and Apex heap is untouched.
 *
 * Bucket shape and ordering deliberately mirror DocGenChartBucketResolver so the
 * two renderers stay interchangeable — same keys, same sort, same
 * "Not Specified" handling, same percent rounding.
 */

import getChartTagsForTemplate from '@salesforce/apex/DocGenChartImageController.getChartTagsForTemplate';
import getChildRecordPage from '@salesforce/apex/DocGenController.getChildRecordPage';
import uploadChartImage from '@salesforce/apex/DocGenChartImageController.uploadChartImage';

// Mirrors DocGenChartBucketResolver.PALETTE.
const PALETTE = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6', '#ec4899', '#14b8a6', '#f97316'];

const NOT_SPECIFIED_LABEL = 'Not Specified';

const FONT_STACK = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';

// Chart.js styles we can render natively. Cross-tab styles still belong to the
// Apex path — they need a groupBy matrix the browser doesn't assemble yet.
const SUPPORTED_STYLES = new Set(['bar', 'column', 'pie', 'donut', 'line', 'area']);

export function isStyleSupported(style) {
    return SUPPORTED_STYLES.has((style || 'bar').toLowerCase());
}

/**
 * Rounds half-up to 1 decimal. JS `toFixed` rounds half-to-even on some values,
 * which would drift from Apex's HALF_UP and make the chart disagree with the
 * {#ChartBucket} table rendered beside it.
 */
function round1(value) {
    return Math.round((value + Number.EPSILON) * 10) / 10;
}

function splitMultiSelect(raw, delim) {
    if (raw === null || raw === undefined) {
        return [''];
    }
    const str = String(raw);
    if (!delim) {
        return [str];
    }
    return str
        .split(delim)
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
}

/**
 * Folds a page of records into an accumulator. Called once per page so raw rows
 * can be released immediately — this is what keeps memory flat at 3.5k+ rows.
 *
 * @param {Object} acc      - accumulator from newBucketAccumulator()
 * @param {Array}  records  - page of records (plain objects from Apex)
 * @param {String} fieldApi - field to bucket on
 * @param {String} splitDelim - optional multi-select delimiter
 */
export function accumulatePage(acc, records, fieldApi, splitDelim) {
    if (!records || !records.length) {
        return acc;
    }
    for (const rec of records) {
        const rawVal = rec ? rec[fieldApi] : null;
        acc.total++;

        if (splitDelim) {
            // Dedupe within one respondent so "A;B;A" counts A once — matches
            // Apex's Set<String> semantics.
            const pieces = new Set(splitMultiSelect(rawVal, splitDelim));
            for (const piece of pieces) {
                bump(acc, piece);
            }
        } else {
            const val = rawVal === null || rawVal === undefined ? '' : String(rawVal);
            bump(acc, val);
        }
    }
    return acc;
}

function bump(acc, rawKey) {
    const mapKey = rawKey.toLowerCase();
    acc.counts.set(mapKey, (acc.counts.get(mapKey) || 0) + 1);
    if (!acc.originals.has(mapKey)) {
        acc.originals.set(mapKey, rawKey);
    }
}

export function newBucketAccumulator() {
    return { counts: new Map(), originals: new Map(), total: 0 };
}

/**
 * Finalizes an accumulator into the bucket list. Sort order matches Apex:
 * count descending, then key ascending for ties.
 */
export function finalizeBuckets(acc, paletteOverride) {
    const palette = paletteOverride && paletteOverride.length ? paletteOverride : PALETTE;
    const rows = [];
    for (const [mapKey, count] of acc.counts.entries()) {
        rows.push({ rawKey: acc.originals.get(mapKey), count });
    }
    rows.sort((a, b) => b.count - a.count || a.rawKey.localeCompare(b.rawKey));

    let maxCount = 0;
    for (const r of rows) {
        if (r.count > maxCount) {
            maxCount = r.count;
        }
    }

    return rows.map((r, i) => {
        const isBlank = r.rawKey === '';
        const percent = acc.total === 0 ? 0 : round1((r.count * 100) / acc.total);
        return {
            key: isBlank ? '' : r.rawKey,
            key_label: isBlank ? NOT_SPECIFIED_LABEL : r.rawKey,
            count: r.count,
            percent,
            percent_int: acc.total === 0 ? 0 : Math.round((r.count * 100) / acc.total),
            max_percent: maxCount === 0 ? 0 : round1((r.count * 100) / maxCount),
            index: i + 1,
            color: palette[i % palette.length]
        };
    });
}

/**
 * Draws "N (P%)" beside each bar / above each column, matching what the Apex
 * rasterizer emits. Chart.js core has no datalabels plugin and we are not
 * shipping another dependency for one string per bar.
 */
function valueLabelPlugin(style, buckets, fontPx) {
    return {
        id: 'docgenValueLabels',
        afterDatasetsDraw(chart) {
            const { ctx } = chart;
            const meta = chart.getDatasetMeta(0);
            if (!meta || !meta.data) {
                return;
            }
            ctx.save();
            ctx.fillStyle = '#334155';
            // Scaled like every other label; a hardcoded size here would be the one
            // piece of text that still shrank as the chart grew.
            ctx.font = `500 ${fontPx || 12}px ${FONT_STACK}`;
            meta.data.forEach((element, i) => {
                const b = buckets[i];
                if (!b) {
                    return;
                }
                const label = `${b.count} (${b.percent}%)`;
                const pos = element.tooltipPosition();
                if (style === 'bar') {
                    ctx.textAlign = 'left';
                    ctx.textBaseline = 'middle';
                    ctx.fillText(label, element.x + 6, pos.y);
                } else {
                    ctx.textAlign = 'center';
                    ctx.textBaseline = 'bottom';
                    ctx.fillText(label, pos.x, element.y - 6);
                }
            });
            ctx.restore();
        }
    };
}

/** Tick, legend and value-label size, in canvas pixels. */
const BASE_TICK_PX = 12;

/** Title size, in canvas pixels. */
const BASE_TITLE_PX = 16;

/**
 * The tick, legend and value-label size for these options.
 *
 * ABSOLUTE, deliberately, and it took a wrong turn to be sure of it.
 *
 * The first attempt scaled these with `width=`, reasoning that Chart.js sizes text in
 * canvas pixels and PowerPoint then stretches the PNG to whatever its shape is — so a
 * fixed pixel size does not survive that trip, and raising `width=` to sharpen a chart
 * actually shrinks its labels.
 *
 * All true for PowerPoint. False for the Canvas designer, where chartToHtml emits
 * `width=inToCssPx(box.w)` — the tag's width IS the block's physical width, and the
 * image is placed at exactly that size. There, 12px has always meant a steady ~9pt at
 * any box size, and scaling it would have made a 3-inch chart render ~5pt labels.
 *
 * One rule cannot be right for both, because `width=` means different things on each
 * path. So the default stays absolute — no regression to the case that was already
 * correct — and `fontSize=` is the explicit knob for the case that is not. The Canvas
 * chart properties expose it directly; a hand-written tag can set it too.
 *
 * A function rather than a value stashed on the config: `common` is spread into
 * `options`, so anything hung on it lands at `config.options.*` and a reader looking
 * for `config.*` finds undefined. The chart and the value-label plugin both ask here,
 * so they cannot disagree.
 */
function resolveTickPx(opts) {
    const requested = Number((opts || {}).fontSize);
    return requested > 0 ? Math.round(requested) : BASE_TICK_PX;
}

/** Title size — proportional to the ticks, so one override moves both. */
function resolveTitlePx(opts) {
    const requested = Number((opts || {}).fontSize);
    return requested > 0 ? Math.round(requested * 1.34) : BASE_TITLE_PX;
}

function buildConfig(style, buckets, opts) {
    const labels = buckets.map((b) => b.key_label);
    const data = buckets.map((b) => b.count);
    const colors = buckets.map((b) => b.color);
    const title = opts.title || '';

    // fontSize= is the author's override, in points at the baseline width; it scales
    // with the canvas like the defaults do, so it means the same thing at any width.
    const tickPx = resolveTickPx(opts);
    const titlePx = resolveTitlePx(opts);

    const common = {
        responsive: false,
        animation: false,
        // Overridden to `scale` by renderChartPng so the type supersamples with
        // the canvas (#304). 1 is right for the on-screen path, which draws at
        // logical size.
        devicePixelRatio: 1,
        plugins: {
            legend: { display: false },
            title: title
                ? {
                      display: true,
                      text: title,
                      align: 'start',
                      color: '#0f172a',
                      font: { family: FONT_STACK, size: titlePx, weight: '600' },
                      padding: { top: 0, bottom: 16 }
                  }
                : { display: false }
        }
    };

    const gridColor = '#e2e8f0';
    const tickFont = { family: FONT_STACK, size: tickPx };

    if (style === 'pie' || style === 'donut') {
        return {
            type: 'doughnut',
            data: {
                labels,
                datasets: [{ data, backgroundColor: colors, borderColor: '#ffffff', borderWidth: 2 }]
            },
            options: {
                ...common,
                cutout: style === 'donut' ? '55%' : 0,
                plugins: {
                    ...common.plugins,
                    legend: {
                        display: true,
                        position: 'right',
                        labels: {
                            color: '#334155',
                            font: tickFont,
                            boxWidth: 14,
                            padding: 12,
                            generateLabels: () =>
                                buckets.map((b, i) => ({
                                    text: `${b.key_label} — ${b.count} (${b.percent}%)`,
                                    fillStyle: b.color,
                                    strokeStyle: b.color,
                                    index: i
                                }))
                        }
                    }
                }
            }
        };
    }

    if (style === 'line' || style === 'area') {
        return {
            type: 'line',
            data: {
                labels,
                datasets: [
                    {
                        data,
                        borderColor: colors[0],
                        backgroundColor: style === 'area' ? `${colors[0]}33` : 'transparent',
                        fill: style === 'area',
                        tension: 0.3,
                        pointRadius: 3,
                        pointBackgroundColor: colors[0]
                    }
                ]
            },
            options: {
                ...common,
                scales: {
                    x: { grid: { display: false }, ticks: { color: '#475569', font: tickFont } },
                    y: {
                        beginAtZero: true,
                        grid: { color: gridColor },
                        ticks: { color: '#475569', font: tickFont, precision: 0 }
                    }
                }
            }
        };
    }

    // bar (horizontal) / column (vertical)
    const horizontal = style === 'bar';
    return {
        type: 'bar',
        data: {
            labels,
            datasets: [{ data, backgroundColor: colors, borderWidth: 0, borderRadius: 3 }]
        },
        options: {
            ...common,
            indexAxis: horizontal ? 'y' : 'x',
            // Leave room for the value labels the plugin draws past the bar end.
            layout: { padding: horizontal ? { right: 72 } : { top: 24 } },
            scales: horizontal
                ? {
                      x: {
                          beginAtZero: true,
                          grid: { color: gridColor },
                          ticks: { color: '#475569', font: tickFont, precision: 0 }
                      },
                      y: { grid: { display: false }, ticks: { color: '#334155', font: tickFont } }
                  }
                : {
                      x: { grid: { display: false }, ticks: { color: '#334155', font: tickFont } },
                      y: {
                          beginAtZero: true,
                          grid: { color: gridColor },
                          ticks: { color: '#475569', font: tickFont, precision: 0 }
                      }
                  }
        }
    };
}

/**
 * Rasterizes buckets to a base64 PNG (no data: prefix — `uploadChartImage`
 * expects raw base64, same as the existing SVG->canvas path).
 *
 * @param {Function} ChartCtor - window.Chart, loaded from the DocGenChartJs static resource
 * @param {Array}  buckets
 * @param {Object} opts - { style, title, width, height, scale }
 * @returns {{ base64: String, width: Number, height: Number }}
 */
/**
 * Representative buckets for the canvas designer's live preview.
 *
 * The designer is a layout tool: an author is choosing shape, colours and
 * proportions, not reading numbers. Rendering real aggregates would mean paging
 * the child list on every keystroke, and a sample record usually holds too few
 * rows to show what the chart will actually look like. Four uneven buckets read
 * as a real chart at any size.
 */
export const SAMPLE_CHART_BUCKETS = [
    { key_label: 'Category A', count: 42, percent: 42, color: PALETTE[0] },
    { key_label: 'Category B', count: 28, percent: 28, color: PALETTE[1] },
    { key_label: 'Category C', count: 19, percent: 19, color: PALETTE[2] },
    { key_label: 'Category D', count: 11, percent: 11, color: PALETTE[3] }
];

/**
 * Renders buckets into an EXISTING canvas and returns the Chart instance.
 *
 * The runner rasterizes to a detached canvas it throws away; the designer needs
 * the chart to stay on a canvas that is already in the DOM, and needs the
 * instance back so it can destroy it before repainting. Same config builder
 * feeds both, so a preview and the finished document cannot drift apart.
 *
 * Cross-tab styles have no client-side implementation yet, so they preview as a
 * bar — honest about the data shape without pretending to a layout the browser
 * cannot produce.
 */
export function renderChartToCanvas(ChartCtor, canvas, buckets, opts) {
    const requested = (opts.style || 'bar').toLowerCase();
    const style = isStyleSupported(requested) ? requested : 'bar';
    const config = buildConfig(style, buckets, opts || {});
    config.plugins = [valueLabelPlugin(style, buckets, resolveTickPx(opts))];
    return new ChartCtor(canvas.getContext('2d'), config);
}

export function renderChartPng(ChartCtor, buckets, opts) {
    const style = (opts.style || 'bar').toLowerCase();
    const logicalWidth = Number(opts.width) || 540;
    const logicalHeight = Number(opts.height) || 320;
    // Supersample for a crisp PNG once PowerPoint scales it into the shape.
    // 2x is the sweet spot: 4x quadruples bytes for no visible gain at these sizes.
    const scale = Math.min(Math.max(Number(opts.scale) || 2, 1), 4);

    // Leave the canvas at LOGICAL size and let Chart.js do the supersampling via
    // devicePixelRatio (#304).
    //
    // Sizing the canvas by hand and setting devicePixelRatio: 1 grew the pixel
    // count but not the drawing transform — Chart.js resets the context
    // transform, so type stayed at `fontSize` DEVICE pixels and shrank relative
    // to the chart as `scale` rose. Measured on a 700x250 canvas at fontSize 12,
    // category-label ink height divided by scale:
    //
    //   scale 1  ->  11 px          (both ways)
    //   scale 2  ->   5.5 px  vs  11 px with devicePixelRatio
    //   scale 3  ->   3.7 px  vs  11.3 px
    //
    // Same backing-store resolution either way, so the PNG is exactly as crisp —
    // the type just stops shrinking. That is what made `fontSize` mean three
    // different things across the three renderers, and why every shipped
    // template carries a compensating value (fontSize=34/42/45 in the OneCommute
    // deck, 27 for 10pt in the HTML report) that only makes sense against the bug.
    const canvas = document.createElement('canvas');
    canvas.width = logicalWidth;
    canvas.height = logicalHeight;
    const ctx = canvas.getContext('2d');

    const config = buildConfig(style, buckets, opts);
    // Retina-scales the backing store AND the drawing transform together, so
    // type, padding, tick marks and grid lines all grow with `scale`.
    config.options.devicePixelRatio = scale;
    config.plugins = [valueLabelPlugin(style, buckets, resolveTickPx(opts))];

    const chart = new ChartCtor(ctx, config);
    try {
        chart.update('none');
        // Opaque white ground, painted AFTER the chart (#307).
        //
        // PowerPoint composites the PNG over the slide, and a transparent chart
        // picks up whatever shape sits behind it. Painting the ground first
        // could never work: assigning canvas.width/height CLEARS the canvas, and
        // Chart.js assigns both when it applies devicePixelRatio — so the fill
        // was wiped before a single bar was drawn and every PNG shipped with an
        // alpha mask. 'destination-over' puts the white behind the pixels that
        // are already there, which is the same result the original code was
        // reaching for.
        ctx.save();
        ctx.setTransform(1, 0, 0, 1, 0, 0); // ground is painted in device pixels
        ctx.globalCompositeOperation = 'destination-over';
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.restore();
        const dataUrl = canvas.toDataURL('image/png');
        return {
            base64: dataUrl.substring(dataUrl.indexOf(',') + 1),
            width: logicalWidth,
            height: logicalHeight
        };
    } finally {
        // Chart.js keeps a registry entry per canvas; leaking these across a
        // multi-chart deck slows every subsequent render.
        chart.destroy();
    }
}

/**
 * Discovers a template's chart tags, aggregates the child rows in the browser,
 * rasterizes with Chart.js and uploads each PNG.
 *
 * Lives here rather than in the runner because the canvas designer needs the
 * exact same thing: it was passing chartCvMap: null, so every chart fell
 * through to the HTML CSS-bar path and any style outside
 * bar/pivot/clustered/stacked came back as a "supported ... only via
 * htmlRender=svg" error block. One implementation, both surfaces.
 *
 * Returns {map, cvIds, bucketMap}, or null to fall back to the Apex renderer.
 */
export async function prepareChartsClientSide({ templateId, recordId, ChartCtor, onProgress }) {
    let tags;
    try {
        tags = await getChartTagsForTemplate({ templateId });
    } catch (e) {
        console.warn('Portwood: getChartTagsForTemplate failed; using Apex chart path', e);
        return null;
    }
    if (!Array.isArray(tags) || tags.length === 0) {
        return { map: {}, cvIds: [] };
    }

    // Every tag must be servable here, or we hand the whole deck back.
    // 'bucket' tags only need counts, so the style restriction is a
    // chart-only concern — a {#ChartBucket} table has no style at all.
    const renderable = tags.every(
        (t) => t.childObject && t.lookupField && t.fieldApi && (t.kind === 'bucket' || isStyleSupported(t.style))
    );
    if (!renderable) {
        // Silence here cost real debugging time: the caller fell back to Apex and
        // nothing anywhere said why. Name the tag that disqualified the deck.
        const bad = tags.find(
            (t) => !(t.childObject && t.lookupField && t.fieldApi && (t.kind === 'bucket' || isStyleSupported(t.style)))
        );
        console.warn(
            'Portwood: client-side charts skipped — ' +
                `tag ${bad ? bad.relName + '.' + bad.fieldApi + ' (' + bad.style + ')' : 'unknown'} ` +
                'is unsupported or has no resolvable child relationship. Using the Apex chart path.'
        );
        return null;
    }

    // Group by relationship so N charts over the same child cost ONE paging
    // pass. Our commuter deck has 8 charts on one relationship — this is the
    // difference between 8 sweeps of 3,553 rows and a single sweep.
    const byRel = new Map();
    for (const tag of tags) {
        const key = `${tag.childObject}|${tag.lookupField}`;
        if (!byRel.has(key)) {
            byRel.set(key, {
                childObject: tag.childObject,
                lookupField: tag.lookupField,
                tags: []
            });
        }
        byRel.get(key).tags.push(tag);
    }

    const map = {};
    const cvIds = [];
    const bucketMap = {};

    for (const group of byRel.values()) {
        const fields = Array.from(new Set(['Id', ...group.tags.map((t) => t.fieldApi)])).join(', ');
        const accs = group.tags.map(() => newBucketAccumulator());

        let cursor = null;
        let hasMore = true;
        let swept = 0;
        while (hasMore) {
            // eslint-disable-next-line no-await-in-loop
            const page = await getChildRecordPage({
                childObject: group.childObject,
                lookupField: group.lookupField,
                parentId: recordId,
                lastCursorId: cursor,
                fields,
                pageSize: 500
            });
            const records = (page && page.records) || [];
            group.tags.forEach((tag, i) => {
                accumulatePage(accs[i], records, tag.fieldApi, tag.options && tag.options.split);
            });
            swept += records.length;
            cursor = page ? page.lastId : null;
            hasMore = Boolean(page && page.hasMore && records.length);
            if (onProgress) onProgress(swept);
        }

        for (let i = 0; i < group.tags.length; i++) {
            const tag = group.tags[i];
            const opts = tag.options || {};
            const palette = opts.colors
                ? opts.colors
                      .split(',')
                      .map((c) => c.trim())
                      .filter(Boolean)
                : null;
            const buckets = finalizeBuckets(accs[i], palette);
            if (!buckets.length) {
                continue;
            }

            // A {#ChartBucket:...} table wants the counts, not a picture.
            // Same accumulator either way, so the table and the chart beside
            // it can never disagree.
            if (tag.kind === 'bucket') {
                bucketMap[tag.signature] = JSON.stringify(buckets);
                continue;
            }

            try {
                // Spread the tag's own modifiers rather than naming five of them.
                // Listing them by hand is how fontSize= reached the artboard preview and
                // not the rendered PNG: the preview passes the chart config straight
                // through, this call rebuilt a subset, and a modifier added later was
                // silently dropped on the way to the only output that matters.
                const png = renderChartPng(ChartCtor, buckets, {
                    ...opts,
                    style: tag.style
                });
                // eslint-disable-next-line no-await-in-loop
                const cvId = await uploadChartImage({
                    recordId,
                    signature: tag.signature,
                    base64Png: png.base64
                });
                if (cvId) {
                    map[tag.signature] = `${cvId}|${png.width}x${png.height}`;
                    cvIds.push(cvId);
                }
            } catch (chartErr) {
                const errMsg =
                    (chartErr && (chartErr.body ? chartErr.body.message : chartErr.message)) || String(chartErr);
                console.warn(`Portwood: Chart.js render failed for ${tag.signature} — ${errMsg}`, chartErr);
            }
        }
    }

    return { map, cvIds, bucketMap };
}

/**
 * The assembled Chart.js config, for tests.
 *
 * Label sizing is derived from `width=` and `fontSize=` and then used in three places
 * — ticks, title, and the value-label plugin. That arithmetic is worth pinning down,
 * and reading it off the real config is the only way to check it without a browser
 * canvas. scripts/qa/chart-font-scale-check.mjs is the caller.
 */
export function buildChartConfigForTest(style, buckets, opts) {
    return buildConfig(style, buckets, opts || {});
}

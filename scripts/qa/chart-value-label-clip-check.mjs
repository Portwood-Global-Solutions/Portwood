/**
 * valueLabelPlugin — the count/percent label must never be clipped.
 *
 *   node scripts/qa/chart-value-label-clip-check.mjs
 *
 * Issue #305. The plugin draws "N (P%)" with ctx.fillText in afterDatasetsDraw
 * and contributes nothing to layout, so Chart.js reserves no room for it:
 *
 *   - horizontal `bar`   — drawn at element.x + 6; when the longest bar reaches
 *                          the axis max the value runs off the right edge and
 *                          "2 (66.7%)" renders as "2 (66".
 *   - vertical `column`  — drawn at element.y - 6; when the tallest bar equals
 *                          the axis max there is nothing above it and the label
 *                          is clipped at the top.
 *
 * `layout.padding` was already set (right: 72 / top: 24) but as FIXED canvas
 * pixels, while `fontSize=` goes up to 48 — so the reserve was simply too small
 * once an author sized the labels up.
 *
 * Small integer data reproduces it reliably: Chart.js picks the data max as the
 * top tick, so 2 responses gives a top tick of exactly 2 and the bar touches the
 * ceiling. Larger data usually escapes — 3,528 rounds up to a 4,000 tick and the
 * label lands in the gap — which is why this looks intermittent in the field.
 *
 * Measures real pixels from the real bundled Chart.js. Skips if Playwright's
 * browser is unavailable.
 */

import { readFileSync } from 'node:fs';

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

let chromium;
try {
    ({ chromium } = await import('playwright'));
} catch (e) {
    console.log('  SKIP  playwright not installed');
    process.exit(0);
}

const chartJs = readFileSync(
    new URL('../../force-app/main/default/staticresources/DocGenChartJs.js', import.meta.url),
    'utf8'
);
const rendererSrc = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenChartJs/docGenChartJs.js', import.meta.url),
    'utf8'
);

let browser;
try {
    browser = await chromium.launch();
} catch (e) {
    console.log('  SKIP  chromium not available');
    process.exit(0);
}
const page = await browser.newPage();
await page.addScriptTag({ content: chartJs });
// Load the SHIPPED renderer, with its LWC-only imports stubbed out.
await page.addScriptTag({
    content:
        'window.DG = (function(){' +
        rendererSrc
            .replace(/^import .*$/gm, '')
            .replace(/^export /gm, '') +
        '; return { buildConfig: typeof buildConfig === "function" ? buildConfig : null, valueLabelPlugin: typeof valueLabelPlugin === "function" ? valueLabelPlugin : null, resolveTickPx: typeof resolveTickPx === "function" ? resolveTickPx : null };})();'
});

const hasRenderer = await page.evaluate(() => Boolean(window.DG && window.DG.buildConfig));
if (!hasRenderer) {
    console.log('  SKIP  could not load the shipped renderer in-page');
    await browser.close();
    process.exit(0);
}

/**
 * Renders through the SHIPPED buildConfig + valueLabelPlugin and reports whether
 * any label ink touches the canvas edge.
 */
const probe = (style, fontSize, counts) =>
    page.evaluate(
        ({ style, fontSize, counts }) => {
            const total = counts.reduce((a, b) => a + b, 0);
            const buckets = counts.map((c, i) => ({
                key: 'K' + i,
                key_label: 'Bucket ' + i,
                count: c,
                percent: Math.round((c * 1000) / total) / 10,
                max_percent: Math.round((c * 1000) / Math.max(...counts)) / 10,
                index: i + 1,
                color: '#3b82f6'
            }));
            const opts = { style, width: 700, height: 250, fontSize: String(fontSize) };
            const canvas = document.createElement('canvas');
            canvas.width = 700;
            canvas.height = 250;
            const ctx = canvas.getContext('2d');
            const config = window.DG.buildConfig(style, buckets, opts);
            config.options.devicePixelRatio = 1;
            config.plugins = [window.DG.valueLabelPlugin(style, buckets, window.DG.resolveTickPx(opts))];
            const chart = new window.Chart(ctx, config);
            chart.update('none');

            const w = canvas.width;
            const h = canvas.height;
            const img = ctx.getImageData(0, 0, w, h).data;
            const isInk = (x, y) => {
                const i = (y * w + x) * 4;
                return img[i + 3] > 40 && img[i] < 160 && img[i + 1] < 160 && img[i + 2] < 160;
            };
            let topEdge = false;
            let rightEdge = false;
            for (let x = 0; x < w; x++) {
                if (isInk(x, 0)) topEdge = true;
            }
            for (let y = 0; y < h; y++) {
                if (isInk(w - 1, y)) rightEdge = true;
            }
            chart.destroy();
            return { topEdge, rightEdge };
        },
        { style, fontSize, counts }
    );

// The reported shape: the largest bucket IS the axis max, so the bar touches the ceiling.
const TIGHT = [2, 1];
const LARGE = [3528, 1200];

console.log('\nhorizontal bar — label must not run off the right edge');
for (const fs of [12, 27, 48]) {
    const r = await probe('bar', fs, TIGHT);
    ok(!r.rightEdge, `fontSize ${fs}: no ink on the right edge with the top bar at the axis max`);
}
{
    const r = await probe('bar', 27, LARGE);
    ok(!r.rightEdge, 'fontSize 27: still clean when the data rounds up to a higher tick');
}

console.log('\nvertical column — label must not clip at the top');
for (const fs of [12, 27, 48]) {
    const r = await probe('column', fs, TIGHT);
    ok(!r.topEdge, `fontSize ${fs}: no ink on the top edge with the tallest bar at the axis max`);
}
{
    const r = await probe('column', 27, LARGE);
    ok(!r.topEdge, 'fontSize 27: still clean when the data rounds up to a higher tick');
}

console.log('\nand a title is no longer required to buy the room');
{
    // The current field workaround is `title=`, which forces a visible heading the
    // author may not want and rasterizes it into the PNG. Without one must be fine.
    const r = await probe('column', 27, TIGHT);
    ok(!r.topEdge, 'a chart with no title= still reserves room for its value labels');
}

await browser.close();
console.log(fail ? `\n${fail} FAILED` : '\nvalue-label clipping OK');
process.exit(fail ? 1 : 0);

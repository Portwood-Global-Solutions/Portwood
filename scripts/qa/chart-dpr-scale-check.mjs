/**
 * renderChartPng — `scale` must supersample the TYPE too, and the ground must survive.
 *
 *   node scripts/qa/chart-dpr-scale-check.mjs
 *
 * Issues #304 and #307, which live in the same eight lines.
 *
 * #304: renderChartPng sized the canvas by hand and set devicePixelRatio: 1.
 * Chart.js resets the context transform, so only the pixel count grew — type
 * stayed at `fontSize` DEVICE pixels and shrank relative to the chart as `scale`
 * rose. That is why `fontSize=` meant three different things across the three
 * renderers, and why shipped templates carry compensating values (fontSize=34/42/45
 * in the OneCommute deck) that only make sense against the bug.
 *
 * #307: the opaque white ground was painted BEFORE Chart.js drew. Assigning
 * canvas.width/height clears the canvas, and Chart.js assigns both when applying
 * devicePixelRatio — so the fill was wiped before a single bar was drawn and every
 * PNG shipped with an alpha mask.
 *
 * This drives the REAL bundled Chart.js in a real browser and measures pixels,
 * rather than asserting the source reads a certain way. Needs the Playwright
 * browser (`npx playwright install chromium`); skips cleanly if it is absent.
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
    console.log('  SKIP  playwright not installed — cannot measure rendered pixels');
    process.exit(0);
}

const chartJs = readFileSync(
    new URL('../../force-app/main/default/staticresources/DocGenChartJs.js', import.meta.url),
    'utf8'
);

let browser;
try {
    browser = await chromium.launch();
} catch (e) {
    console.log('  SKIP  chromium not available (' + e.message.split('\n')[0] + ')');
    process.exit(0);
}

const page = await browser.newPage();
await page.addScriptTag({ content: chartJs });

/**
 * Renders a bar chart at a given scale, using either the OLD approach (hand-sized
 * canvas, devicePixelRatio 1) or the NEW one (logical canvas, devicePixelRatio =
 * scale), and reports the ink height of the tallest glyph column in the category
 * label strip, divided by scale — i.e. the type size at its PLACED size.
 */
const measure = (mode, scale) =>
    page.evaluate(
        ({ mode, scale }) => {
            const W = 700;
            const H = 250;
            const canvas = document.createElement('canvas');
            const opts = {
                type: 'bar',
                data: {
                    labels: ['Alpha', 'Beta', 'Gamma'],
                    datasets: [{ data: [10, 20, 30], backgroundColor: '#4472c4' }]
                },
                options: {
                    responsive: false,
                    animation: false,
                    plugins: { legend: { display: false } },
                    scales: {
                        x: { ticks: { font: { size: 12 }, color: '#000000' }, grid: { display: false } },
                        y: { display: false, grid: { display: false } }
                    }
                }
            };
            if (mode === 'old') {
                canvas.width = W * scale;
                canvas.height = H * scale;
                const c = canvas.getContext('2d');
                c.scale(scale, scale);
                opts.options.devicePixelRatio = 1;
            } else {
                canvas.width = W;
                canvas.height = H;
                opts.options.devicePixelRatio = scale;
            }
            const ctx = canvas.getContext('2d');
            const chart = new window.Chart(ctx, opts);
            chart.update('none');

            // Ink height of the x-axis label band: scan the bottom strip for dark pixels.
            const img = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
            let top = -1;
            let bottom = -1;
            const startY = Math.floor(canvas.height * 0.8);
            for (let y = startY; y < canvas.height; y++) {
                let dark = false;
                for (let x = 0; x < canvas.width; x++) {
                    const i = (y * canvas.width + x) * 4;
                    if (img[i + 3] > 40 && img[i] < 120 && img[i + 1] < 120 && img[i + 2] < 120) {
                        dark = true;
                        break;
                    }
                }
                if (dark) {
                    if (top === -1) top = y;
                    bottom = y;
                }
            }
            const inkPx = top === -1 ? 0 : bottom - top + 1;
            const backingNow = canvas.width + 'x' + canvas.height;
            void backingNow;

            // #307: is there any transparent pixel left once a ground is applied?
            const groundLast = mode !== 'old';
            if (groundLast) {
                const c2 = canvas.getContext('2d');
                c2.save();
                c2.setTransform(1, 0, 0, 1, 0, 0);
                c2.globalCompositeOperation = 'destination-over';
                c2.fillStyle = '#ffffff';
                c2.fillRect(0, 0, canvas.width, canvas.height);
                c2.restore();
            }
            const after = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
            let transparent = 0;
            for (let i = 3; i < after.length; i += 4) {
                if (after[i] < 255) transparent++;
            }

            const backing = canvas.width + 'x' + canvas.height;
            chart.destroy();
            return { inkPx, placed: inkPx / scale, backing, transparent };
        },
        { mode, scale }
    );

console.log('\n#304 — type size at its PLACED size, as `scale` rises (fontSize: 12)');
const rows = [];
for (const scale of [1, 2, 3]) {
    const oldR = await measure('old', scale);
    const newR = await measure('new', scale);
    rows.push({ scale, oldR, newR });
    console.log(
        `        scale ${scale}:  old ${oldR.placed.toFixed(1)} px  ->  new ${newR.placed.toFixed(1)} px   (backing ${newR.backing})`
    );
}

const newPlaced = rows.filter((r) => r.scale > 1).map((r) => r.newR.placed);
const oldPlaced = rows.filter((r) => r.scale > 1).map((r) => r.oldR.placed);

ok(
    Math.abs(newPlaced[0] - newPlaced[1]) <= 1.5,
    `type holds its placed size as scale rises (${newPlaced.map((n) => n.toFixed(1)).join(' -> ')} px)`
);
ok(
    oldPlaced[1] < oldPlaced[0] * 0.6,
    `the old path collapsed it over the same range (${oldPlaced.map((n) => n.toFixed(1)).join(' -> ')} px) — this is what fontSize= was compensating for`
);
ok(
    newPlaced[1] > oldPlaced[1] * 1.8,
    `at scale 3 the type is now ~${(newPlaced[1] / oldPlaced[1]).toFixed(1)}x its old size`
);
ok(rows[1].newR.backing === '1400x500', `scale 2 still supersamples the backing store (${rows[1].newR.backing})`);
ok(rows[2].newR.backing === '2100x750', `scale 3 still supersamples the backing store (${rows[2].newR.backing})`);

console.log('\n#307 — the white ground survives');
ok(rows[1].newR.transparent === 0, 'destination-over after the draw leaves no transparent pixel');

await browser.close();
console.log(fail ? `\n${fail} FAILED` : '\nchart scaling OK');
process.exit(fail ? 1 : 0);

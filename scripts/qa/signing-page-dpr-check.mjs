/**
 * Signing page — device-resolution page canvases (#413).
 *
 *   node scripts/qa/signing-page-dpr-check.mjs
 *
 * The guided signing viewer used to size each page canvas in CSS pixels, so on any
 * HiDPI screen (every phone) the PDF was drawn at a fraction of the screen's
 * resolution and upscaled — soft text, and pinch-zoom only magnified the blur. Pages
 * are now backed at devicePixelRatio, bounded by per-canvas and whole-document pixel
 * caps so a long document can't exhaust a phone's canvas memory.
 *
 * Unlike a mirrored copy, this lifts backingRatio() and its constants straight out
 * of DocGenSignaturePdf.page, so the check can't drift from the shipped code. It also
 * asserts the invariant that keeps sign-spots in place: anchor lookup and
 * hitToPdfRect read the CSS-pixel viewport stored per page, never the canvas size.
 */
import { readFileSync } from 'node:fs';

const PAGE = new URL('../../force-app/main/default/pages/DocGenSignaturePdf.page', import.meta.url);
const src = readFileSync(PAGE, 'utf8');

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

// ── lift the implementation out of the page ─────────────────────────────────
function extractFunction(name) {
    const start = src.indexOf('function ' + name + '(');
    if (start < 0) return null;
    let depth = 0;
    for (let i = src.indexOf('{', start); i < src.length; i++) {
        if (src[i] === '{') depth++;
        else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
    }
    return null;
}
const constant = (name) => (src.match(new RegExp('var ' + name + ' = ([0-9.]+);')) || [])[1];

const fnSrc = extractFunction('backingRatio');
const consts = ['MAX_DEVICE_RATIO', 'MAX_CANVAS_PIXELS', 'DOC_PIXEL_BUDGET'].map((n) => [n, constant(n)]);
ok(!!fnSrc, 'backingRatio() found in DocGenSignaturePdf.page');
ok(
    consts.every(([, v]) => v !== undefined),
    'MAX_DEVICE_RATIO / MAX_CANVAS_PIXELS / DOC_PIXEL_BUDGET found'
);
if (!fnSrc || consts.some(([, v]) => v === undefined)) {
    console.log(`\n${fail} FAILED`);
    process.exit(1);
}
const [MAX_RATIO, MAX_PX, BUDGET] = consts.map(([, v]) => Number(v));
const build = new Function(
    'window',
    consts.map(([n, v]) => `var ${n} = ${v};`).join('\n') + '\n' + fnSrc + '\nreturn backingRatio;'
);
const ratioAt = (dpr, cssW, cssH, numPages = 1) =>
    build({ devicePixelRatio: dpr })({ width: cssW, height: cssH }, numPages);

// ── behaviour ────────────────────────────────────────────────────────────────
// A letter page fitted to a 375px phone viewer (what the real page draws: 320 x 414).
const PHONE = [320, 414];
ok(ratioAt(1, ...PHONE) === 1, 'DPR 1 → backed 1:1 (desktop unchanged)');
ok(ratioAt(2, ...PHONE) === 2, 'DPR 2 → backed 2:1 (was 1:1 — the #413 blur)');
ok(ratioAt(3, ...PHONE) === 3, 'DPR 3 → backed 3:1');
ok(ratioAt(4, ...PHONE) === MAX_RATIO, `DPR 4 → clamped to ${MAX_RATIO}`);
ok(ratioAt(0.75, ...PHONE) === 1, 'DPR below 1 (zoomed-out desktop) → never below 1');
ok(ratioAt(undefined, ...PHONE) === 1, 'no devicePixelRatio → 1');

// Per-canvas cap: a huge page must not exceed MAX_CANVAS_PIXELS (iOS rejects larger).
const big = [3000, 2000];
const rBig = ratioAt(3, ...big);
ok(
    big[0] * big[1] * rBig * rBig <= MAX_PX + 1,
    `a 3000x2000 page at DPR 3 stays within ${MAX_PX} px (ratio ${rBig.toFixed(2)})`
);
ok(rBig >= 1, '…and never drops below 1');
ok(ratioAt(3, 5000, 5000) === 1, 'a page already over the cap at 1:1 renders 1:1 (no worse than before)');

// Document budget: every page canvas stays live, so the total must stay bounded.
for (const pages of [1, 10, 50, 200]) {
    const r = ratioAt(3, ...PHONE, pages);
    const total = PHONE[0] * PHONE[1] * r * r * pages;
    ok(
        total <= Math.max(BUDGET, PHONE[0] * PHONE[1] * pages) + pages,
        `${pages}-page document at DPR 3: ${(total / 1e6).toFixed(1)} MP ≤ budget (ratio ${r.toFixed(2)})`
    );
}

// ── the invariants that keep sign-spots and stamps where they were ───────────
const render = extractFunction('renderOnePage') || '';
ok(
    /canvas\.width\s*=\s*Math\.floor\(renderViewport\.width\)/.test(render),
    'canvas backing store sized from the device-resolution viewport'
);
ok(/canvas\.style\.width\s*=\s*viewport\.width/.test(render), 'canvas displayed at the CSS-pixel viewport size');
ok(/viewport:\s*renderViewport/.test(render), 'PDF.js renders with the device-resolution viewport');
ok(
    /pages\.push\(\{[\s\S]*?viewport:\s*viewport,/.test(render),
    'pages[] keeps the CSS-pixel viewport (anchors + hitToPdfRect read it)'
);
ok(!/canvas\.(width|height)/.test(extractFunction('itemDeviceBox') || ''), 'anchor boxes never read canvas dimensions');
ok(
    /hitToPdfRect: function[\s\S]*?var vp = pages\[i\]\.viewport;/.test(src),
    'hitToPdfRect maps stamps through the stored CSS-pixel viewport'
);

console.log(fail ? `\n${fail} FAILED` : '\ndevice-resolution rendering OK');
process.exit(fail ? 1 : 0);

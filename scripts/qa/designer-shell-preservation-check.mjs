/**
 * Designer staging — the author's document shell and stylesheet survive a save.
 *
 *   node scripts/qa/designer-shell-preservation-check.mjs
 *
 * Issue #319. klugo reported that saving a template in the old designer "removes
 * all the CSS. Basically removes the full <style>". The damage takes TWO saves,
 * which is why it read as intermittent and why some templates were fine:
 *
 *   1. _sanitizeStagedHtml parses the body into a <template> fragment. A full
 *      document loses <!DOCTYPE>, <html>, <head> and <body> there — they are
 *      ignored tokens in that insertion mode. The author's <style> survives, so
 *      nothing looks wrong yet.
 *   2. On the next save the canvas wraps that shell-less body in its .dg-pv
 *      preview div. The old code tested for a <body> to splice into, found none,
 *      and fell through to a HARDCODED shell carrying
 *      `@page { size: Letter portrait }` — replacing the author's entire
 *      stylesheet and resetting a Landscape template to Portrait.
 *
 * The sanitizer only engages at all when the body carries `data-dg-tag`,
 * `dg-pv` or `dg-drop-marker`, so tag pills leaking into the source (#322) are
 * what arm it. That is modelled here too — a clean body must pass through
 * untouched.
 *
 * This mirrors _sanitizeStagedHtml from docGenAdmin.js. Keep the two in step: if
 * the component changes, change the model here and the assertions will tell you
 * whether the behaviour still holds.
 */

import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
global.document = dom.window.document;

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

/** Mirrors docGenAdmin._sanitizeStagedHtml. */
function sanitizeStagedHtml(html) {
    if (
        !html ||
        (html.indexOf('data-dg-tag') === -1 &&
            html.indexOf('dg-pv') === -1 &&
            html.indexOf('dg-drop-marker') === -1)
    ) {
        return html;
    }
    try {
        const bodyRe = /(<body\b[^>]*>)([\s\S]*?)(<\/body\s*>)/i;
        const bodyMatch = html.match(bodyRe);
        const target = bodyMatch ? bodyMatch[2] : html;
        const tpl = document.createElement('template');
        tpl.innerHTML = target;
        const root = tpl.content;
        for (const marker of root.querySelectorAll('.dg-drop-marker')) {
            marker.remove();
        }
        const pv = root.querySelector('div.dg-pv');
        if (pv) {
            for (const styleEl of pv.querySelectorAll(':scope > style')) {
                styleEl.remove();
            }
            while (pv.firstChild) {
                pv.parentNode.insertBefore(pv.firstChild, pv);
            }
            pv.remove();
        }
        const container = document.createElement('div');
        container.appendChild(root);
        const cleaned = container.innerHTML.trim();
        if (bodyMatch) {
            return html.replace(bodyRe, (m, open, inner, close) => open + '\n' + cleaned + '\n' + close);
        }
        return cleaned;
    } catch (e) {
        return html;
    }
}

/** What the canvas does to a stored body before the next save stages it. */
const wrapInPreview = (doc) =>
    doc.replace(
        /(<body\b[^>]*>)([\s\S]*?)(<\/body\s*>)/i,
        (m, open, inner, close) => `${open}<div class="dg-pv"><style>.dg-pv{padding:1in}</style>${inner}</div>${close}`
    );

// klugo's template: Landscape Letter, author stylesheet in <head>, a tag pill in
// the body because the visual editor has been used.
const AUTHOR_DOC = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8" />
<title>EC Project Closure - Landscape Letter</title>
<style>
@page { size: Letter landscape; margin: 0.75in; }
body { font-family: Helvetica, Arial, sans-serif; color: #2C2C2C; }
.fixed-page { width: 100%; height: 6.82in; position: relative; }
</style>
</head>
<body>
<div class="fixed-page"><span data-dg-tag="Name">{Name}</span></div>
</body>
</html>`;

const survives = (out, label) => {
    ok(/<html/i.test(out) && /<head/i.test(out) && /<body/i.test(out), `${label}: document shell intact`);
    ok(out.includes('Letter landscape'), `${label}: author's @page landscape kept`);
    ok(out.includes('.fixed-page'), `${label}: author's stylesheet kept`);
    ok(!out.includes('Letter portrait'), `${label}: no fabricated portrait shell`);
    ok(out.includes('{Name}'), `${label}: merge tag kept`);
};

console.log('\nthe two-save chain that destroyed the stylesheet (#319)');
const save1 = sanitizeStagedHtml(AUTHOR_DOC);
survives(save1, 'save 1');

const save2 = sanitizeStagedHtml(wrapInPreview(save1));
survives(save2, 'save 2');

const save3 = sanitizeStagedHtml(wrapInPreview(save2));
survives(save3, 'save 3');
ok(save3 === save2, 'save 3 is byte-identical to save 2 (staging is idempotent)');

console.log('\nrecovery from a body already flattened by the old code');
// No shell at all — what an affected org already has stored. The stylesheet must
// still be carried through rather than replaced, and no shell may be invented.
const flattened = `<meta charset="UTF-8">
<title>EC Project Closure - Landscape Letter</title>
<style>@page { size: Letter landscape; } .fixed-page { width: 100%; }</style>
<div class="dg-pv"><style>.dg-pv{padding:1in}</style><div class="fixed-page"><span data-dg-tag="Name">{Name}</span></div></div>`;
const recovered = sanitizeStagedHtml(flattened);
ok(recovered.includes('Letter landscape'), 'flattened body: author @page still carried');
ok(recovered.includes('.fixed-page'), 'flattened body: author stylesheet still carried');
ok(!recovered.includes('Letter portrait'), 'flattened body: no fabricated portrait shell');
ok(!recovered.includes('dg-pv'), 'flattened body: preview wrapper unwrapped, not left behind');

console.log('\nthe editor artifacts it exists to strip');
const withArtifacts = AUTHOR_DOC.replace(
    '<div class="fixed-page">',
    '<div class="dg-drop-marker"></div><div class="fixed-page">'
);
const stripped = sanitizeStagedHtml(withArtifacts);
ok(!stripped.includes('dg-drop-marker'), 'drop markers removed');
ok(stripped.includes('.fixed-page'), 'and the stylesheet is still not collateral');

const previewOnly = `<html><head><style>.keep{color:red}</style></head><body><div class="dg-pv"><style>.dg-pv{padding:1in}</style><p data-dg-tag="X">{X}</p></div></body></html>`;
const unwrapped = sanitizeStagedHtml(previewOnly);
ok(!unwrapped.includes('.dg-pv{'), "the preview's own scoped stylesheet is removed");
ok(unwrapped.includes('.keep'), "the author's stylesheet beside it is not");

console.log('\na clean body must not be touched at all');
const clean = '<html><head><style>p{color:blue}</style></head><body><p>{Name}</p></body></html>';
ok(sanitizeStagedHtml(clean) === clean, 'no pills, no markers, no preview wrapper — passes through byte-identical');

console.log(fail ? `\n${fail} FAILED` : '\nshell preservation OK');
process.exit(fail ? 1 : 0);

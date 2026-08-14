/**
 * Designer — the editor layer is subtracted by ownership, not by element type.
 *
 *   node scripts/qa/editor-layer-ownership-check.mjs
 *
 * Issue #322. The old designer decorates the author's document IN PLACE: it
 * injects a scoped preview stylesheet, drop markers and tag pills into the same
 * contenteditable DOM the author is editing. Every save then has to subtract
 * those again, and correctness depended on every exit path remembering how.
 *
 * `querySelectorAll('style')` on the way out removed EVERY stylesheet, because
 * there was no way to tell the editor's injected sheet from the author's. A
 * <style> written inside <body> was therefore destroyed on every visual round
 * trip — silently, with the save reporting success. Only <head> styles survived,
 * and only because _currentDraftHtml splices the body back into the original
 * document rather than rebuilding it.
 *
 * The fix marks what the editor owns (`data-dg-editor`) and parks the author's
 * own stylesheets inert (`data-dg-authored`, with a non-CSS `type` so the
 * browser never applies an unscoped rule to the Lightning page). Removal is then
 * by ownership, and the author's bytes are handed back unchanged.
 *
 * This asserts the round trip through the SHIPPED scopeHtmlForInlinePreview and
 * a faithful model of _stripEditorLayer.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
global.document = dom.window.document;

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

// Load the shipped scoper. Its one LWC import is unrelated to this path.
const kitSrc = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', import.meta.url),
    'utf8'
).replace(/^import .*from 'c\/docGenUtils';$/m, 'const parseSOQLFields = () => [];');
const kitPath = '/tmp/docGenAuthoringKit.check.' + Date.now() + '.mjs';
writeFileSync(kitPath, kitSrc, 'utf8');
const kit = await import(kitPath);

/** Mirrors docGenAdmin._stripEditorLayer. */
function stripEditorLayer(root) {
    for (const el of root.querySelectorAll('style[data-dg-editor]')) {
        el.remove();
    }
    for (const marker of root.querySelectorAll('.dg-drop-marker')) {
        marker.remove();
    }
    for (const parked of root.querySelectorAll('style[data-dg-authored]')) {
        const restored = document.createElement('style');
        restored.textContent = parked.textContent;
        parked.parentNode.replaceChild(restored, parked);
    }
}

/** The canvas round trip: scope for preview, then serialize back out. */
function roundTrip(authored) {
    const scoped = kit.scopeHtmlForInlinePreview(authored);
    const tpl = document.createElement('template');
    tpl.innerHTML = scoped;
    const pv = tpl.content.querySelector('.dg-pv');
    stripEditorLayer(tpl.content);
    return { scoped, out: pv.innerHTML.trim() };
}

console.log("\nan author's <style> inside <body> survives the round trip");
{
    const authored = `<!DOCTYPE html><html><head><style>@page{size:Letter landscape}</style></head>
<body>
<style>.invoice-total{font-weight:bold;border-top:2px solid #000}</style>
<div class="invoice-total">{Amount__c}</div>
</body></html>`;
    const { scoped, out } = roundTrip(authored);
    ok(out.includes('.invoice-total{font-weight:bold'), "the author's body stylesheet comes back verbatim");
    ok(out.includes('<div class="invoice-total">{Amount__c}</div>'), 'and the markup it styles is still there');
    ok(!out.includes('data-dg-authored'), 'with the inert parking attribute removed');
    ok(!out.includes('data-dg-editor'), "and the editor's own sheet gone");
    ok(!out.includes('max-width: 850px'), 'no editor chrome leaks into the saved body');

    // While it is ON the canvas it must not be applied, or an unscoped
    // `body { … }` rule would repaint the Lightning page around the editor.
    ok(
        /<style data-dg-authored="1" type="text\/dg-css">/.test(scoped),
        'on the canvas the parked copy carries a non-CSS type so it never applies'
    );
    ok(scoped.includes('data-dg-editor="preview"'), "and the editor's sheet is marked as editor-owned");
}

console.log('\nthe editor sheet still renders the preview');
{
    const authored = '<html><head><style>.k{color:#c00}</style></head><body><p class="k">{Name}</p></body></html>';
    const { scoped } = roundTrip(authored);
    ok(scoped.includes('.dg-pv .k'), "the author's head CSS is still scoped into the preview sheet");
    ok(scoped.includes('.dg-pv { background: #fff'), 'and the baseline paper-sheet styling is still there');
}

console.log('\ndrop markers and multiple stylesheets');
{
    const authored = `<html><head><style>.a{color:red}</style></head><body>
<style>.b{color:green}</style>
<div class="dg-drop-marker"></div>
<style>.c{color:blue}</style>
<p>{Name}</p></body></html>`;
    const { out } = roundTrip(authored);
    ok(out.includes('.b{color:green}'), 'first body stylesheet survives');
    ok(out.includes('.c{color:blue}'), 'second body stylesheet survives');
    ok(!out.includes('dg-drop-marker'), 'drop markers are still stripped');
    ok(!out.includes('.a{color:red}'), 'a head stylesheet does not get duplicated into the body');
}

console.log('\nnothing to strip is a no-op');
{
    const authored = '<html><body><p>{Name}</p></body></html>';
    const { out } = roundTrip(authored);
    ok(out === '<p>{Name}</p>', 'a body with no styles round-trips byte-identical, got: ' + JSON.stringify(out));
}

console.log('\nregression guard: removal must not be by element type');
{
    // The precise shape the old code destroyed. If anyone reintroduces
    // querySelectorAll('style'), this is the assertion that fails.
    const authored = '<html><body><style>.only{margin:0}</style><p>{Name}</p></body></html>';
    const { out } = roundTrip(authored);
    ok(out.includes('.only{margin:0}'), 'a body whose ONLY styling is an inline <style> keeps it');
}

console.log(fail ? `\n${fail} FAILED` : '\neditor-layer ownership OK');
process.exit(fail ? 1 : 0);

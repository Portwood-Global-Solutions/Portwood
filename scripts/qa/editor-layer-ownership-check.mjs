/**
 * Legacy Designer: author CSS survives Visual/Source while editor chrome does not.
 *
 *   node scripts/qa/editor-layer-ownership-check.mjs
 *
 * Regression coverage for #464 using the shipped preview scoper and a faithful
 * model of docGenAdmin._stripEditorLayer/_unpillifyTags.
 */

import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
global.document = dom.window.document;

let fail = 0;
const ok = (condition, message) => {
    console.log((condition ? '  ok  ' : ' FAIL ') + message);
    if (!condition) fail++;
};

const kitSrc = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', import.meta.url),
    'utf8'
).replace(/^import .*from 'c\/docGenUtils';$/m, 'const parseSOQLFields = () => [];');
const kitPath = join(tmpdir(), 'docGenAuthoringKit.check.' + Date.now() + '.mjs');
writeFileSync(kitPath, kitSrc, 'utf8');
const kit = await import(pathToFileURL(kitPath).href);
unlinkSync(kitPath);

function stripEditorLayer(root) {
    for (const el of root.querySelectorAll('style[data-dg-editor]')) {
        el.remove();
    }
    for (const pv of root.querySelectorAll('div.dg-pv')) {
        const first = pv.firstElementChild;
        if (
            first &&
            first.tagName === 'STYLE' &&
            !first.hasAttribute('data-dg-authored') &&
            /(^|})\s*\.dg-pv\b/.test(first.textContent || '')
        ) {
            first.remove();
        }
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

function unpillifyTags(root) {
    for (const pill of root.querySelectorAll('[data-dg-tag]')) {
        pill.parentNode.replaceChild(document.createTextNode(pill.textContent || ''), pill);
    }
}

function roundTrip(authored) {
    const scoped = kit.scopeHtmlForInlinePreview(authored);
    const tpl = document.createElement('template');
    tpl.innerHTML = scoped;
    const pv = tpl.content.querySelector('.dg-pv');
    stripEditorLayer(tpl.content);
    unpillifyTags(tpl.content);
    return { scoped, out: pv.innerHTML.trim() };
}

console.log('\nauthor stylesheet ownership');
{
    const authored = `<style>
@page { size: Letter; margin: 0.75in; }
body { font-family: Georgia, serif; font-size: 14pt; }
.format-check { color: #b42318; text-align: right; }
</style>
<div class="format-check">FORMAT CHECK</div>`;
    const { scoped, out } = roundTrip(authored);
    ok(out.includes('@page { size: Letter; margin: 0.75in; }'), '@page survives the Visual/Source round trip');
    ok(out.includes('font-family: Georgia, serif'), 'body font survives the Visual/Source round trip');
    ok(out.includes('.format-check { color: #b42318'), 'class styles survive the Visual/Source round trip');
    ok(out.includes('<div class="format-check">FORMAT CHECK</div>'), 'body markup survives the round trip');
    ok(!out.includes('data-dg-authored'), 'author parking marker is removed from source');
    ok(!out.includes('data-dg-editor'), 'editor stylesheet is removed from source');
    ok(!out.includes('max-width: 850px'), 'editor page chrome does not reach source or PDF input');
    ok(scoped.includes('data-dg-editor="preview"'), 'preview stylesheet is explicitly editor-owned');
    ok(
        scoped.includes('<style data-dg-authored="1" type="text/dg-css">'),
        'author stylesheet is parked inert while Visual mode is open'
    );
}

console.log('\nconditional pill ownership');
{
    const authored = `{#IF Name != ''}<p>{Name}</p>{:else}<p>Empty</p>{/IF}`;
    const scoped = kit.scopeHtmlForInlinePreview(authored);
    const tpl = document.createElement('template');
    tpl.innerHTML = scoped;
    const pv = tpl.content.querySelector('.dg-pv');
    for (const text of ["{#IF Name != ''}", '{:else}', '{/IF}']) {
        const pill = document.createElement('span');
        pill.setAttribute('data-dg-tag', 'true');
        pill.setAttribute('contenteditable', 'false');
        pill.setAttribute('style', 'background:#e3f5e9;border:1px solid #9fd6b1;border-radius:9px;padding:0 6px');
        pill.textContent = text;
        const walker = document.createTreeWalker(pv, dom.window.NodeFilter.SHOW_TEXT);
        let node;
        while (walker.nextNode()) {
            if (walker.currentNode.nodeValue === text) {
                node = walker.currentNode;
                break;
            }
        }
        node.parentNode.replaceChild(pill, node);
    }
    stripEditorLayer(tpl.content);
    unpillifyTags(tpl.content);
    const out = pv.innerHTML.trim();
    ok(out.includes("{#IF Name != ''}"), 'conditional opener returns as plain template text');
    ok(out.includes('{:else}') && out.includes('{/IF}'), 'else and closing tags return as plain template text');
    ok(!out.includes('data-dg-tag'), 'conditional pill wrappers do not reach source or PDF input');
    ok(!out.includes('#e3f5e9') && !out.includes('#9fd6b1'), 'green pill styling does not reach PDF input');
}

console.log(fail ? `\n${fail} FAILED` : '\neditor-layer ownership OK');
process.exit(fail ? 1 : 0);

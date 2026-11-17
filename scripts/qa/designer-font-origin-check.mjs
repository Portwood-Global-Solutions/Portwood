import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { JSDOM } from 'jsdom';

const lwc = new URL('../../force-app/main/default/lwc/', import.meta.url);
const asModule = (source) => 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
const utils = asModule(await readFile(new URL('docGenUtils/docGenUtils.js', lwc), 'utf8'));
const kit = (await readFile(new URL('docGenAuthoringKit/docGenAuthoringKit.js', lwc), 'utf8')).replace(
    'c/docGenUtils',
    utils
);
const { scopeHtmlForInlinePreview } = await import(asModule(kit));
const dom = new JSDOM('', { url: 'https://example--qa.sandbox.lightning.force.com' });
globalThis.window = dom.window;
const fontRule =
    '@font-face{font-family:Quote;src:url("https://example--qa.sandbox.my.salesforce.com/resource/123/fonts/a.ttf?v=1"),' +
    'url("https://other.my.salesforce.com/resource/123/fonts/a.ttf"),url("//example.test/resource/a.ttf")}';
const source = '<style>' + fontRule + '</style><p>Quote</p>';
const template = dom.window.document.createElement('template');
template.innerHTML = scopeHtmlForInlinePreview(source);
const preview = template.content.querySelector('[data-dg-editor]').textContent;
assert(preview.includes('url("/resource/123/fonts/a.ttf?v=1")'));
assert(!preview.includes('other.my.salesforce.com'));
assert(!preview.includes('example.test'));
assert.equal(template.content.querySelector('[data-dg-authored]').textContent, fontRule);
console.log('Designer font origin checks passed');

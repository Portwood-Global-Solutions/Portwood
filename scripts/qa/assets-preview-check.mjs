import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<main><div class="preview"><div class="content"></div></div></main>', {
    pretendToBeVisual: true
});
const document = window.document;
const source = (name) =>
    readFileSync(`force-app/main/default/lwc/${name}/${name}.js`, 'utf8')
        .replace(/^import .*;\n/gm, '')
        .replace(/@api\b/g, '')
        .replace('export default class', 'return class');
const observers = [];
class Observer {
    constructor(callback) {
        this.callback = callback;
        this.disconnected = false;
        observers.push(this);
    }
    observe() {}
    unobserve() {}
    disconnect() {
        this.disconnected = true;
    }
}
const requests = [];
const Preview = new Function(
    'LightningElement',
    'getSnippetLibraryPreview',
    'IntersectionObserver',
    'document',
    source('docGenSnippetPreview')
)(class {}, (args) => new Promise((resolve, reject) => requests.push({ args, resolve, reject })), Observer, document);
const preview = new Preview();
preview.template = document.querySelector('main');
preview.assetId = 'one';
preview.imageUrls = { logo: '/logo.png' };
preview.connectedCallback();
preview.renderedCallback();
assert.equal(requests.length, 0, 'Offscreen snippet results do not fetch their files.');
observers.at(-1).callback([{ isIntersecting: true }]);
assert.equal(requests.length, 1);
preview.renderedCallback();
assert.equal(requests.length, 1, 'Rendering a pending preview cannot duplicate its request.');
requests[0].resolve('<h2>Terms</h2><p>Pay within <strong>30 days</strong>.</p><img src="{%asset:logo}" />');
await Promise.resolve();
preview.renderedCallback();
assert.equal(preview.state, 'ready');
assert.equal(document.querySelector('strong').textContent, '30 days');
assert.equal(document.querySelector('img').getAttribute('src'), '/logo.png');
assert(
    document.querySelector('.content').hasAttribute('inert'),
    'Preview links and images cannot take focus from the result button.'
);
preview.revision = 1;
preview.renderedCallback();
observers.at(-1).callback([{ isIntersecting: true }]);
preview.revision = 2;
preview.renderedCallback();
observers.at(-1).callback([{ isIntersecting: true }]);
requests[2].resolve('<p>Latest wording</p>');
await Promise.resolve();
requests[1].resolve('<p>Outdated wording</p>');
await Promise.resolve();
preview.renderedCallback();
assert.equal(
    document.querySelector('.content').textContent,
    'Latest wording',
    'Late requests cannot overwrite a saved revision.'
);
preview.revision = 3;
preview.renderedCallback();
observers.at(-1).callback([{ isIntersecting: true }]);
requests[3].reject(new Error('The private file is not available.'));
await Promise.resolve();
assert(preview.failed);
assert.equal(preview.error, 'The private file is not available.');
preview.disconnectedCallback();
assert(observers.at(-1).disconnected);
console.log(
    'PASS snippet result previews: lazy private-file loading, formatted HTML, asset images, inert content, deduplication, saved-revision invalidation, stale-response protection and failure state.'
);

document.querySelector('main').innerHTML =
    '<nav class="faces"><button class="face" data-key="script"></button><button class="face" data-key="bold"></button></nav>';
const loaded = [];
const FontLibrary = new Function(
    'LightningElement',
    'CAN_MANAGE',
    'loadFontFace',
    'IntersectionObserver',
    source('docGenFontAssets')
)(
    class {},
    true,
    async (face) => {
        loaded.push(face);
        if (face.key === 'bold') throw new Error('Download unavailable');
    },
    Observer
);
const library = new FontLibrary();
library._connected = true;
library.template = document.querySelector('main');
library.faces = [
    {
        key: 'script',
        label: 'Script',
        family: 'Script',
        previewFamily: 'PW_script',
        previewUrl: '/script.ttf',
        weight: 400,
        style: 'italic',
        status: 'Verified'
    },
    {
        key: 'bold',
        label: 'Bold',
        family: 'Sans',
        previewFamily: 'PW_bold',
        previewUrl: '/bold.ttf',
        weight: 700,
        style: 'normal',
        status: 'Published'
    }
];
assert.match(library.rows[0].previewStyle, /PW_script.*font-weight:400.*font-style:italic/);
assert.match(library.rows[1].previewStyle, /PW_bold.*font-weight:700.*font-style:normal/);
library.renderedCallback();
assert.equal(loaded.length, 0);
observers.at(-1).callback([{ isIntersecting: true, target: document.querySelector('[data-key="script"]') }]);
await library.loadPreview(library.faces[0]);
assert.equal(loaded.length, 1, 'The selected and result preview share one exact-face font load.');
assert(library.loaded.has('script'));
assert.equal(library.loaded.has('bold'), false, 'Offscreen fonts remain unloaded.');
await library.loadPreview(library.faces[1]);
assert.equal(library.rows[1].canPreview, false);
assert.equal(library.faces[1].status, 'Published', 'Browser preview failures never change approval status.');
library.searchTerm = 'Script';
await library.filterChanged();
assert.equal(library.rows.length, 1);
assert.equal(library.selectedKey, 'script');
library.disconnectedCallback();
assert(observers.at(-1).disconnected);
console.log(
    'PASS font search previews: real revision aliases, exact weight/italic styles, visible-only font loading, shared requests, search selection, failure fallback and unchanged approval status.'
);

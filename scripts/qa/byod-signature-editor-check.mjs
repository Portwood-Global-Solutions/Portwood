/** PDF preparation state transitions without a browser or org. Actual vendored pdf-lib,
 * mocked canvas/remoting only. Server ownership/revision/order checks live in Apex tests.
 * Run: node scripts/qa/byod-signature-editor-check.mjs
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { JSDOM } from 'jsdom';
const require = createRequire(import.meta.url);
const PDFLib = require('../../force-app/main/default/staticresources/pdflib/pdf-lib.min.js');
const root = new URL('../../force-app/main/default/', import.meta.url);
const source = readFileSync(new URL('staticresources/DocGenSignaturePrepare.resource', root), 'utf8');
const vf = readFileSync(new URL('pages/DocGenSignaturePrepare.page', root), 'utf8');
assert.match(
    vf,
    /<script src="\{!URLFOR\(\$Resource.DocGenSignaturePrepare\)\}">/,
    'Editor must execute after its environment config; apex:includeScript hoists it too early'
);
const pdf = await PDFLib.PDFDocument.create();
pdf.addPage([612, 792]);
pdf.addPage([612, 792]).setRotation(PDFLib.degrees(90));
const bytes = await pdf.save();
const base64 = Buffer.from(bytes).toString('base64');
let saved,
    revision = 0,
    failSave = false,
    sent = 0;
const dom = new JSDOM(vf, { runScripts: 'outside-only', url: 'https://scratch.example.test/apex/prepare' });
const { window } = dom;
window.PDFLib = PDFLib;
window.Uint8Array = Uint8Array;
window.ResizeObserver = class {
    observe() {}
};
window.HTMLCanvasElement.prototype.getContext = () => ({});
window.PortwoodPreparation = {
    recordId: '001000000000000AAA',
    source: 'upload',
    parentOrigin: 'https://example.lightning.force.com',
    nonce: 'test',
    moduleUrl: 'mock-pdfjs',
    workerUrl: 'mock-worker',
    actions: Object.fromEntries(['context', 'upload', 'select', 'load', 'save', 'send', 'contacts'].map((s) => [s, s]))
};
const result = () => ({ draftId: 'draft', documentId: 'original', revision, title: 'QA PDF', base64, config: saved });
const handlers = {
    context: () => ({ files: [], drafts: [], publicSite: false, verificationDefault: false }),
    upload: (_recordId, name, encoded) => {
        assert.equal(name, 'sample.pdf');
        assert.equal(encoded, base64);
        return result();
    },
    load: () => result(),
    contacts: () => [],
    save: (_recordId, _draftId, expected, json) => {
        assert.equal(expected, revision);
        if (failSave) throw new Error('This draft changed in another window.');
        saved = json;
        return ++revision;
    },
    send: (_recordId, _draftId, expected, json) => {
        assert.equal(expected, revision);
        const config = JSON.parse(json);
        assert.equal(config.delivery, 'preview');
        assert.equal(config.pages[1].rotation, 90);
        assert.equal(config.fields.length, 2);
        sent++;
        return { title: config.title, delivery: 'preview', signers: [] };
    }
};
window.Visualforce = {
    remoting: {
        Manager: {
            invokeAction(action, ...args) {
                const callback = args.at(-2);
                queueMicrotask(() => {
                    try {
                        callback(handlers[action](...args.slice(0, -2)), { status: true });
                    } catch (e) {
                        callback(null, { status: false, message: e.message });
                    }
                });
            }
        }
    }
};
window.pdfjsFixture = {
    GlobalWorkerOptions: {},
    getDocument: () => ({
        promise: Promise.resolve({
            numPages: 2,
            destroy: async () => {},
            getPage: async () => ({
                getViewport: ({ scale }) => ({
                    width: 612 * scale,
                    height: 792 * scale,
                    convertToPdfPoint: (x, y) => [x / scale, 792 - y / scale],
                    convertToViewportRectangle: ([x, y, right, top]) => [
                        x * scale,
                        (792 - y) * scale,
                        right * scale,
                        (792 - top) * scale
                    ]
                }),
                render: () => ({ promise: Promise.resolve(), cancel() {} })
            })
        })
    })
};
window.eval(source.replace('import(env.moduleUrl)', 'Promise.resolve(window.pdfjsFixture)'));
const settle = async () => {
    for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
};
const $ = (id) => window.document.getElementById(id);
const input = (id, value) => {
    $(id).value = value;
    $(id).dispatchEvent(new window.Event('input'));
};
await settle();
assert.equal(window.document.querySelector('[data-source]'), null, 'The PDF editor must not repeat the source chooser');
assert.equal($('templates'), null, 'Templates are chosen only in the parent request');
assert.equal($('next').disabled, true);
const upload = $('upload');
Object.defineProperty(upload, 'files', {
    value: [
        {
            name: 'sample.pdf',
            size: bytes.length,
            arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
        }
    ]
});
upload.dispatchEvent(new window.Event('change'));
await settle();
assert.equal($('next').disabled, false);
assert.equal($('page-label').textContent, 'Page 1 of 2');
$('next').click();
input('name-0', 'One');
input('email-0', 'one@example.invalid');
$('add-person').click();
input('name-1', 'Two');
input('email-1', 'two@example.invalid');
$('next').click();
assert.equal($('next').disabled, true, 'Every recipient needs a signature');
window.document.querySelector('[data-tool="Full"]').click();
$('overlay').dispatchEvent(new window.MouseEvent('click', { bubbles: true, clientX: 30, clientY: 50 }));
assert.equal($('next').disabled, true);
const owner = $('field-owner');
owner.value = owner.options[1].value;
owner.dispatchEvent(new window.Event('change'));
window.document.querySelector('[data-tool="Full"]').click();
$('overlay').dispatchEvent(new window.MouseEvent('click', { bubbles: true, clientX: 30, clientY: 120 }));
assert.equal($('next').disabled, false);
assert.ok($('field-width'), 'A selected field exposes sizing controls');
$('next-page').click();
await settle();
assert.equal($('page-label').textContent, 'Page 2 of 2');
assert.equal($('field-width'), null, 'Changing pages clears stale field sizing controls');
$('previous-page').click();
await settle();
const switchSource = (value, nonce = 'test') =>
    window.dispatchEvent(
        new window.MessageEvent('message', {
            source: window.parent,
            origin: 'https://example.lightning.force.com',
            data: { channel: 'portwood-signatures', nonce, action: 'source', value }
        })
    );
switchSource('files', 'wrong');
assert.ok($('field-owner'), 'Untrusted navigation must not change the active step');
switchSource('files');
assert.match($('controls').textContent, /Files on this record/);
switchSource('upload');
window.document.querySelector('[data-step="1"]').click();
assert.equal($('name-0').value, 'One');
assert.equal($('name-1').value, 'Two');
window.document.querySelector('[data-step="2"]').click();
assert.equal(
    window.document.querySelectorAll('[data-field]').length,
    2,
    'Switching document sources must preserve recipient fields'
);
$('save').click();
await settle();
assert.equal(JSON.parse(saved).fields.length, 2);
assert.equal($('status').textContent, 'Draft saved');
failSave = true;
$('save').click();
await settle();
assert.match($('error').textContent, /another window/);
failSave = false;
$('next').click();
assert.equal($('delivery').value, 'preview');
$('next').click();
await settle();
assert.equal(sent, 1);
assert.match(window.document.body.textContent, /Your signing preview is ready/);
assert.equal($('busy').hidden, true, 'Final busy cleanup survives shell replacement');
dom.window.close();
console.log(
    'PASS: PDF upload, recipient gating, field ownership, rotation metadata, revision save, stale-save feedback, preview completion.'
);

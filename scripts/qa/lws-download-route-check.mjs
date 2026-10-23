/** Issue #454: test real source with data: URLs blocked. Run: node scripts/qa/lws-download-route-check.mjs */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = (path) => readFileSync(new URL('../../force-app/main/default/lwc/' + path, import.meta.url), 'utf8');
const utils = source('docGenUtils/docGenUtils.js');
const admin = source('docGenAdmin/docGenAdmin.js');
const canvas = source('docGenCanvas/docGenCanvas.js');

function environment({ strict = false, refuseAll = false, clickFails = false } = {}) {
    const blobs = new Map(),
        downloads = [],
        revoked = [],
        timers = [],
        children = new Set();
    const context = vm.createContext({
        Blob,
        Uint8Array,
        atob,
        encodeURIComponent,
        setTimeout(callback) {
            timers.push(callback);
        },
        URL: {
            createObjectURL(blob) {
                if (refuseAll || (strict && !['application/pdf', 'image/png', 'text/plain'].includes(blob.type))) {
                    throw new Error('Lightning Web Security: Cannot createObjectURL');
                }
                const url = 'blob:mock/' + blobs.size;
                blobs.set(url, blob);
                return url;
            },
            revokeObjectURL(url) {
                assert.ok(blobs.has(url), 'only an existing object URL is revoked');
                revoked.push(url);
            }
        },
        document: {
            createElement(tag) {
                assert.equal(tag, 'a');
                return {
                    set href(value) {
                        if (value.startsWith('data:'))
                            throw new Error('Lightning Web Security: HTMLAnchorElement href does not support data:');
                        this.url = value;
                    },
                    click() {
                        assert.ok(children.has(this), 'anchor is attached before clicking');
                        if (clickFails) throw new Error('Click failed');
                        downloads.push({ fileName: this.download, blob: blobs.get(this.url) });
                    }
                };
            },
            body: {
                appendChild(anchor) {
                    children.add(anchor);
                    anchor.parentNode = this;
                },
                removeChild(anchor) {
                    assert.ok(children.delete(anchor), 'anchor is removed once');
                    anchor.parentNode = null;
                }
            }
        }
    });
    // Execute the actual helper, not a copy of its routing logic.
    vm.runInContext(utils.replace(/^export /gm, ''), context);
    return {
        context,
        downloads,
        verifyCleanup() {
            assert.equal(children.size, 0, 'temporary anchor is removed');
            assert.equal(revoked.length, 0, 'URL remains available until the download can start');
            timers.forEach((callback) => callback());
            assert.equal(revoked.length, blobs.size, 'all created URLs are eventually revoked');
        }
    };
}

function handler(sourceText, signature) {
    const start = sourceText.indexOf(signature);
    assert.notEqual(start, -1);
    const end = sourceText.indexOf('\n    }', start) + '\n    }'.length;
    return sourceText.slice(start, end).trim();
}
let checks = 0;
async function check(name, run) {
    await run();
    checks++;
    console.log('  ok  ' + name);
}
const bytes = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00, 0x80, 0xff, 0xc3, 0xa9]);
for (const strict of [false, true]) {
    for (const [extension, mime] of [
        ['pdf', 'application/pdf'],
        ['png', 'image/png'],
        ['txt', 'text/plain'],
        ['docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
        ['pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
        ['xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
        ['xlsm', 'application/vnd.ms-excel.sheet.macroEnabled.12'],
        ['bin', 'application/octet-stream'],
        ['json', 'application/json'],
        ['html', 'text/html'],
        ['bin', undefined]
    ]) {
        await check(`${extension}, MIME ${mime}, strict=${strict}: preserves bytes and filename`, async () => {
            const env = environment({ strict });
            env.context.downloadBase64(bytes.toString('base64'), 'export.' + extension, mime);
            assert.equal(env.downloads.length, 1);
            const download = env.downloads[0];
            assert.equal(download.fileName, 'export.' + extension);
            assert.deepEqual(Buffer.from(await download.blob.arrayBuffer()), bytes);
            if (['application/pdf', 'image/png', 'text/plain'].includes(mime)) assert.equal(download.blob.type, mime);
            env.verifyCleanup();
        });
    }
}
await check('template export: Unicode JSON downloads with a success toast', async () => {
    const env = environment({ strict: true });
    const json = JSON.stringify({ name: 'Résumé — 東京', template: { active: true } });
    env.context.exportTemplate = async ({ templateId }) => {
        assert.equal(templateId, 'existing-template');
        return json;
    };
    const component = vm.runInContext('({' + handler(admin, 'async handleExportTemplate(row) {') + '})', env.context);
    const toasts = [];
    component.showToast = (...args) => toasts.push(args);
    await component.handleExportTemplate({ Id: 'existing-template', Name: 'Résumé / Demo' });
    assert.equal(env.downloads.length, 1);
    assert.equal(env.downloads[0].fileName, 'R_sum____Demo.docgen.json');
    assert.equal(await env.downloads[0].blob.text(), json);
    assert.equal(toasts.at(-1)[0], 'Exported');
    assert.equal(toasts.at(-1)[2], 'success');
    env.verifyCleanup();
});
await check('template export: server failure still shows Export Error without a download', async () => {
    const env = environment();
    env.context.exportTemplate = async () => {
        throw { body: { message: 'Template export failed' } };
    };
    const component = vm.runInContext('({' + handler(admin, 'async handleExportTemplate(row) {') + '})', env.context);
    const toasts = [];
    component.showToast = (...args) => toasts.push(args);
    await component.handleExportTemplate({ Id: 'existing-template', Name: 'Demo' });
    assert.equal(env.downloads.length, 0);
    assert.equal(toasts.at(-1)[0], 'Export Error');
    assert.equal(toasts.at(-1)[1], 'Template export failed');
});
await check('Canvas HTML export preserves Unicode and markup without sanitization', async () => {
    const env = environment({ strict: true });
    const html = '<html><body>Résumé — 東京 {Name}<script>example()</script></body></html>';
    env.context.serialize = () => html;
    const component = vm.runInContext('({' + handler(canvas, 'handleExportHtml() {') + '})', env.context);
    component.exportFileName = 'portwood-account-canvas.html';
    component.handleExportHtml();
    assert.equal(env.downloads.length, 1);
    assert.equal(env.downloads[0].fileName, component.exportFileName);
    assert.equal(await env.downloads[0].blob.text(), html);
    assert.equal(component.statusText, 'Exported ' + component.exportFileName);
    env.verifyCleanup();
});
await check('a refused PDF Blob retries with a permitted download MIME', () => {
    const env = environment();
    const create = env.context.URL.createObjectURL;
    env.context.URL.createObjectURL = (blob) => {
        if (blob.type === 'application/pdf') throw new Error('Blob rejected');
        return create(blob);
    };
    env.context.downloadBase64(bytes.toString('base64'), 'export.pdf', 'application/pdf');
    assert.equal(env.downloads.length, 1);
    env.verifyCleanup();
});
await check('all Blob types refused: propagate error without attempting a data: URL', () => {
    const env = environment({ refuseAll: true });
    assert.throws(
        () => env.context.downloadBase64(bytes.toString('base64'), 'export.docx', 'application/octet-stream'),
        /Cannot createObjectURL/
    );
    assert.equal(env.downloads.length, 0);
    env.verifyCleanup();
});
await check('a failed click still releases the anchor and object URL', () => {
    const env = environment({ clickFails: true });
    assert.throws(
        () => env.context.downloadBase64(bytes.toString('base64'), 'export.pdf', 'application/pdf'),
        /Click failed/
    );
    env.verifyCleanup();
});
console.log(`\n${checks} download/export checks passed`);

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(repo + '/package.json');
const { chromium } = require('playwright');
const { PDFDocument, StandardFonts } = require(repo + '/force-app/main/default/staticresources/pdflib/pdf-lib.min.js');
const fixture = await Promise.all(
    Array.from({ length: 22 }, async (_, i) => {
        const pdf = await PDFDocument.create();
        const font = await pdf.embedFont(StandardFonts.Helvetica);
        for (let k = 0; k <= (i === 18 ? 1 : 0); k++) {
            pdf.addPage().drawText(`Source ${i + 1} page ${k + 1}`, { x: 40, y: 650, font });
        }
        // An unused stream makes four sources large enough to exercise the byte cap.
        if (i >= 16 && i < 20) pdf.context.register(pdf.context.stream('x'.repeat(400 * 1024)));
        const bytes = Buffer.from(await pdf.save({ useObjectStreams: false }));
        const versionId = `068${String(i + 1).padStart(15, '0')}`;
        return {
            ordinal: i + 1,
            bytes,
            versionId,
            checksum: createHash('md5').update(bytes).digest('hex'),
            url: `/sfc/servlet.shepherd/version/download/${versionId}`
        };
    })
);
const vf = await readFile(repo + '/force-app/main/default/pages/DocGenBulkPdfDownload.page', 'utf8');
const path = repo + '/force-app/main/default/staticresources/DocGenBulkPdfDownloadApp';
const assets = new Map();
for (const name of ['download.js', 'merge-worker.js', 'merge-core.js', 'md5.js', 'download.css'])
    assets.set(`/asset/${name}`, await readFile(`${path}/${name}`));
assets.set(
    '/asset/pdf-lib.min.js',
    await readFile(repo + '/force-app/main/default/staticresources/pdflib/pdf-lib.min.js')
);
const jobId = 'a00000000000000001';
const html = vf
    .replace(/<apex:page[\s\S]*?>/, '<!doctype html>')
    .replace('</apex:page>', '')
    .replaceAll(/\{!URLFOR\(\$Resource.\w+, '([^']+)'\)\}/g, '/asset/$1')
    .replaceAll(/\{!\$RemoteAction.DocGenBulkPdfDownloadController.(\w+)\}/g, '$1')
    .replace('{!$User.Id}', '005000000000000001')
    .replace(
        '<script src="/asset/download.js"></script>',
        `<script>
        window.Visualforce = { remoting: { Manager: { invokeAction(action, ...args) {
            const callback = args.at(-2);
            fetch('/remote/' + action, { method: 'POST', body: JSON.stringify(args.slice(0, -2)) }).then(response => response.json()).then(
                result => callback(result, {status: true}), () => callback(null, {status: false}));
        }}} };
    </script><script src="/asset/download.js"></script>`
    );
let stage = 0;
const access = { native: [], batches: [], pages: [] };
const requestServer = createServer(async (request, response) => {
    const url = request.url.split('?')[0];
    if (url === '/') {
        response.setHeader('content-type', 'text/html');
        return response.end(html);
    }
    if (assets.has(url)) {
        response.setHeader('content-type', url.endsWith('.css') ? 'text/css' : 'text/javascript');
        return response.end(assets.get(url));
    }
    if (url.startsWith('/remote/')) {
        const body = [];
        for await (const chunk of request) body.push(chunk);
        const args = JSON.parse(Buffer.concat(body).toString());
        const name = url.split('/').pop();
        let result;
        if (name === 'describe')
            result = {
                ready: true,
                revisionKey: stage === 2 ? 'version-corrupt' : 'version-a',
                totalSources: fixture.length,
                filename: 'fixture.pdf'
            };
        if (name === 'getManifestPage') {
            const after = args[2];
            access.pages.push([stage, after]);
            const sources = fixture.slice(after, after + 3).map((f) => ({ ...f, bytes: f.bytes.length }));
            const nextAfterOrdinal = after + sources.length;
            result = { sources, nextAfterOrdinal, done: nextAfterOrdinal === fixture.length };
        }
        if (name === 'getSources') {
            const ordinals = args[2];
            access.batches.push([stage, ordinals]);
            assert.ok(ordinals.length >= 1 && ordinals.length <= 16);
            const documents = ordinals.map((ordinal) => fixture[ordinal - 1].bytes);
            assert.ok(documents.reduce((total, bytes) => total + bytes.length, 0) <= 1024 * 1024);
            if (stage === 0 && ordinals[0] > 16) return;
            if (stage === 2 && ordinals[0] === 1) {
                documents[0] = Buffer.from(documents[0]);
                documents[0][30] ^= 1;
            }
            result = documents.map((bytes) => bytes.toString('base64'));
        }
        response.setHeader('content-type', 'application/json');
        return response.end(JSON.stringify(result));
    }
    if (url.startsWith('/sfc/')) access.native.push(url);
    response.statusCode = 404;
    return response.end();
});
await new Promise((resolve) => requestServer.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const temp = await mkdtemp(join(tmpdir(), 'portwood-merge-541-smoke-'));
try {
    const ctx = await browser.newContext({ acceptDownloads: true });
    async function start() {
        const page = await ctx.newPage();
        await page.goto(`http://127.0.0.1:${requestServer.address().port}/?jobId=${jobId}`);
        await page.locator('#start').click({ timeout: 10000 });
        return page;
    }
    let page = await start();
    await page.waitForFunction(() => document.getElementById('downloadPage').dataset.sourcesCommitted === '16', null, {
        timeout: 10000
    });
    assert.deepEqual(access.batches[0], [0, Array.from({ length: 16 }, (_, index) => index + 1)]);
    await page.close();
    stage = 1;
    page = await start();
    await page.locator('#download').waitFor({ timeout: 10000 });
    const dataset = await page.locator('#downloadPage').evaluate((node) => ({ ...node.dataset }));
    assert.equal(dataset.sourcesResumed, '16');
    assert.equal(dataset.sourcesCommitted, '22');
    assert.equal(dataset.networkInputs, '6');
    assert.equal(dataset.remotingBatches, '2');
    assert.deepEqual(
        access.pages.filter(([phase]) => phase === 1).map(([, ordinal]) => ordinal),
        [0, 3, 6, 9, 12, 15, 18, 21]
    );
    assert.deepEqual(
        access.batches.filter(([phase]) => phase === 1).map(([, ordinals]) => ordinals),
        [
            [17, 18],
            [19, 20, 21, 22]
        ]
    );
    const eventual = page.waitForEvent('download');
    await page.locator('#download').click();
    const result = join(temp, 'output.pdf');
    await (await eventual).saveAs(result);
    const text = execFileSync('pdftotext', [result, '-'], { encoding: 'utf8' });
    const pages = text.match(/Source \d+ page \d+/g);
    assert.deepEqual(
        pages,
        Array.from({ length: 22 }, (_, index) =>
            index === 18 ? ['Source 19 page 1', 'Source 19 page 2'] : [`Source ${index + 1} page 1`]
        ).flat()
    );
    await page.close();
    stage = 2;
    page = await start();
    await page.waitForFunction(() => document.getElementById('downloadPage').dataset.stage === 'error');
    assert.match(await page.locator('#status').textContent(), /Source 1 does not match its pinned checksum/);
    assert.deepEqual(access.native, []);
    console.log(
        'Chrome smoke passed the remoting count and byte limits, abrupt resume, 23 ordered pages, and checksum rejection.'
    );
} finally {
    await browser.close();
    requestServer.closeAllConnections();
    requestServer.close();
    await rm(temp, { recursive: true, force: true });
}

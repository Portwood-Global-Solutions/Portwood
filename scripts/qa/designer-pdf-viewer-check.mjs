import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { chromium } from 'playwright';

const root = new URL('../../', import.meta.url);
const resource = new URL('force-app/main/default/staticresources/DocGenPdfPreview/', root);
const component = (
    await readFile(
        new URL('force-app/main/default/lwc/docGenDesignerPdfPreview/docGenDesignerPdfPreview.js', root),
        'utf8'
    )
)
    .replace(/^import .+;\n/gm, '')
    .replace('@api ', '')
    .replace('export default class', 'window.Preview = class');
function pdf(label) {
    const stream = (text) => '<< /Length ' + text.length + ' >>\nstream\n' + text + '\nendstream';
    const objects = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>',
        stream('BT /F1 14 Tf 20 100 Td (' + label + ' first page) Tj ET'),
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>',
        stream('BT /F1 14 Tf 20 100 Td (' + label + ' second page) Tj ET'),
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    ];
    let result = '%PDF-1.4\n';
    const offsets = [0];
    objects.forEach((object, i) => {
        offsets.push(result.length);
        result += `${i + 1} 0 obj\n${object}\nendobj\n`;
    });
    const start = result.length;
    result +=
        'xref\n0 8\n0000000000 65535 f \n' +
        offsets
            .slice(1)
            .map((offset) => String(offset).padStart(10, '0') + ' 00000 n \n')
            .join('');
    return Buffer.from(result + `trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n${start}\n%%EOF`).toString('base64');
}
const server = http.createServer(async (request, response) => {
    try {
        const path = new URL(request.url, 'http://local.invalid').pathname;
        if (path === '/') {
            response.setHeader('Content-Type', 'text/html');
            response.end('<!doctype html><iframe title="PDF"></iframe><script src="/harness.js"></script>');
        } else if (path === '/harness.js') {
            response.setHeader('Content-Type', 'text/javascript');
            response.end(`const PDFJS='/viewer'; class LightningElement { constructor() {this.template=document;} }
                async function getContentVersionBase64({contentVersionId}) {if(contentVersionId==='denied')throw Error('File unavailable');return contentVersionId==='second'?${JSON.stringify(pdf('Updated'))}:${JSON.stringify(pdf('Original'))};}
                ${component}
                window.preview=new Preview();preview.connectedCallback();document.querySelector('iframe').src=preview.viewerUrl;`);
        } else if (/^\/viewer\/[\w.-]+$/.test(path)) {
            response.setHeader(
                'Content-Type',
                path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html'
            );
            response.end(await readFile(new URL(path.slice('/viewer/'.length), resource)));
        } else {
            response.statusCode = 404;
            response.end();
        }
    } catch {
        response.statusCode = 500;
        response.end();
    }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const origin = 'http://127.0.0.1:' + server.address().port;
const browser = await chromium.launch({ headless: true });
try {
    const page = await browser.newPage();
    const external = [];
    page.on('request', (request) => {
        if (!request.url().startsWith(origin)) external.push(request.url());
    });
    await page.goto(origin);
    await page.waitForFunction(() => window.preview?._ready);
    const frame = page.frameLocator('iframe');
    await page.evaluate(
        (base64) =>
            document
                .querySelector('iframe')
                .contentWindow.postMessage(
                    { type: 'docgen-pdf-render', session: 'wrong', request: 1, base64 },
                    location.origin
                ),
        pdf('Untrusted')
    );
    await page.evaluate(() => {
        preview.contentVersionId = 'first';
        preview.renderedCallback();
    });
    await page.waitForFunction(() => preview.pageCount === 2 && !preview.loading);
    assert.deepEqual(await frame.locator('.pdf-text').allTextContents(), [
        'Original first page',
        'Original second page'
    ]);
    assert.equal(await frame.locator('canvas').count(), 2);
    assert(
        await frame
            .locator('canvas')
            .first()
            .evaluate((canvas) =>
                canvas
                    .getContext('2d')
                    .getImageData(0, 0, canvas.width, canvas.height)
                    .data.some((v, i, pixels) => i % 4 === 0 && pixels[i + 3] > 0 && v < 128)
            ),
        'PDF text must actually paint on the canvas'
    );
    await page.evaluate(() => {
        for (const change of [{ origin: 'https://unrelated.invalid' }, { source: window }, { session: 'wrong' }])
            window.dispatchEvent(
                new MessageEvent('message', {
                    origin: change.origin || location.origin,
                    source: change.source || document.querySelector('iframe').contentWindow,
                    data: {
                        type: 'docgen-pdf-complete',
                        session: change.session || preview._session,
                        request: preview._request,
                        pageCount: 99
                    }
                })
            );
    });
    assert.equal(await page.evaluate(() => preview.pageCount), 2);
    await page.evaluate(() => {
        preview.contentVersionId = 'second';
        preview.renderedCallback();
    });
    await page.waitForFunction(() => preview._requested === 'second' && !preview.loading);
    assert.deepEqual(await frame.locator('.pdf-text').allTextContents(), ['Updated first page', 'Updated second page']);
    await page.evaluate(() => {
        preview.contentVersionId = 'denied';
        preview.renderedCallback();
    });
    await page.waitForFunction(() => !preview.loading && preview.error === 'File unavailable');
    assert.deepEqual(external, []);
    console.log(
        'PASS: native PDF painting, accessible text, replacement, denied File reads, message boundaries and Salesforce-only resources.'
    );
} finally {
    await browser.close();
    await new Promise((resolve) => server.close(resolve));
}

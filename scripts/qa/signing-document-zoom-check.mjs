// Real PDF.js, PDF-lib coordinate mapping, and Chrome touch dispatch.
// Run with dependencies installed and Google Chrome available.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { chromium } from 'playwright';

const repo = new URL('../../', import.meta.url);
const source = (path) => new URL('force-app/main/default/' + path, repo);
const require = createRequire(import.meta.url);
const { PDFDocument } = require(source('staticresources/pdflib/pdf-lib.min.js').pathname);
const fixture = await PDFDocument.create();
for (let i = 0; i < 3; i++) {
    const page = fixture.addPage([612, 792]);
    page.drawText('Signature: @@SIG-0@@', { x: 180, y: 600, size: 14 });
}

const raw = await readFile(source('pages/DocGenSignaturePdf.page'), 'utf8');
const start = raw.indexOf('var DocGenPdfViewer = (function');
const viewer = raw
    .slice(start, raw.indexOf('</script>', start))
    .replaceAll(/\{!URLFOR\(\$Resource\.pdfjs4, '([^']+)'\)\}/g, '/$1');
const css = raw.slice(raw.indexOf('<style>'), raw.indexOf('</style>') + '</style>'.length);
const markup = raw
    .slice(raw.indexOf('<div id="state-pdf"'), raw.indexOf('<!-- STATE: Processing -->'))
    .replace(' style="display: none"', '');

const browser = await chromium.launch({ channel: 'chrome' });
try {
    const page = await browser.newPage({
        viewport: { width: 390, height: 740 },
        deviceScaleFactor: 2,
        isMobile: true,
        hasTouch: true
    });
    await page.route('http://signing.test/**', async (route) => {
        const path = new URL(route.request().url()).pathname;
        if (path.endsWith('.js')) {
            return route.fulfill({
                contentType: 'text/javascript',
                body: await readFile(source('staticresources/pdfjs4' + path))
            });
        }
        return route.fulfill({
            contentType: 'text/html',
            body:
                '<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">' +
                css +
                markup +
                '<script>' +
                viewer +
                '</script>'
        });
    });
    await page.goto('http://signing.test/');
    const original = await page.evaluate(
        async (pdf) => {
            await DocGenPdfViewer.render(pdf, document.querySelector('#pdf-viewer-container'));
            const hit = DocGenPdfViewer.locateAnchors(['@@SIG-0@@'])[0];
            const chip = DocGenPdfViewer.addChip(hit, 'Sign here');
            chip.id = 'qa-chip';
            chip.addEventListener('click', () => (chip.dataset.clicked = 'yes'));
            return DocGenPdfViewer.hitToPdfRect(hit);
        },
        Buffer.from(await fixture.save()).toString('base64')
    );
    const bar = page.locator('.pdf-action-bar');
    const boxBefore = await bar.boundingBox();
    const canvas = page.locator('canvas').first();
    const originalWidth = await canvas.evaluate((c) => c.width);
    const originalDisplay = (await canvas.boundingBox()).width;

    const session = await page.context().newCDPSession(page);
    const area = await page.locator('#pdf-viewer-container').boundingBox();
    const cy = area.y + 105;
    await session.send('Input.dispatchTouchEvent', {
        type: 'touchStart',
        touchPoints: [
            { x: 155, y: cy, id: 1 },
            { x: 235, y: cy, id: 2 }
        ]
    });
    for (const spread of [100, 120, 160]) {
        await session.send('Input.dispatchTouchEvent', {
            type: 'touchMove',
            touchPoints: [
                { x: 195 - spread / 2, y: cy, id: 1 },
                { x: 195 + spread / 2, y: cy, id: 2 }
            ]
        });
    }
    await session.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await page.waitForFunction((width) => document.querySelector('canvas').width >= width * 1.85, originalWidth);
    assert.equal(await page.evaluate(() => visualViewport.scale), 1);
    assert.deepEqual(await bar.boundingBox(), boxBefore);
    assert((await canvas.boundingBox()).width >= originalDisplay * 1.9);
    assert.deepEqual(
        await page.evaluate(() => DocGenPdfViewer.hitToPdfRect(DocGenPdfViewer.locateAnchors(['@@SIG-0@@'])[0])),
        original
    );
    const chip = page.locator('#qa-chip');
    await chip.tap();
    assert.equal(await chip.getAttribute('data-clicked'), 'yes');
    await page.getByRole('button', { name: 'Fit width' }).click();
    await page.waitForFunction((width) => document.querySelector('canvas').width === width, originalWidth);
    assert.equal(await page.locator('#pdf-zoom-level').textContent(), '100%');
    assert.equal((await canvas.boundingBox()).width, originalDisplay);
    await page.locator('#pdf-viewer-container').focus();
    await page.keyboard.press('+');
    assert.equal(await page.locator('#pdf-zoom-level').textContent(), '125%');
    await page.keyboard.press('0');
    assert.equal(await page.locator('#pdf-zoom-level').textContent(), '100%');
    await page.setViewportSize({ width: 740, height: 390 });
    const landscapeBar = await bar.boundingBox();
    assert(landscapeBar.y + landscapeBar.height <= 390);
    await page.locator('#pdf-viewer-container').evaluate((viewer) => (viewer.scrollTop = viewer.scrollHeight));
    assert.deepEqual(await bar.boundingBox(), landscapeBar);
    assert.equal(await page.evaluate(() => window.scrollY), 0);
    console.log('Signing document pinch, sharpness, fixed actions, chip coordinates, and reset passed.');
} finally {
    await browser.close();
}

import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const resources = '../..' + '/force-app/main/default/staticresources';
const pdfLib = require(resources + '/pdflib/pdf-lib.min.js');
const fontRoot = resources + '/DocGenKoreanSigningFont';
const fontkit = require(fontRoot + '/fontkit.umd.min.js');
const fontBytes = await readFile(new URL(fontRoot + '/NanumGothic-Regular.ttf', import.meta.url));
const page = await readFile(new URL('../../force-app/main/default/pages/DocGenSignaturePdf.page', import.meta.url), 'utf8');
assert.match(page, /<apex:includeScript\s+value="\{!URLFOR\(\$Resource\.DocGenKoreanSigningFont, 'fontkit\.umd\.min\.js'\)\}"\s*\/>/);
const start = page.indexOf('var koreanSigningFontPromise;');
const end = page.indexOf('                    // Composite ALL captured fields', start);
assert.ok(start !== -1 && end > start);
const browserWindow = {};
let fontRequests = 0;
let fontAvailable = false;
const functions = new Function(
    'PDFLib',
    'window',
    'fetch',
    page.slice(start, end) + 'return { shortSigningDate, needsKoreanSigningFont, signingPdfFonts };'
)(pdfLib, browserWindow, async (url) => {
    assert.equal(url, "{!URLFOR($Resource.DocGenKoreanSigningFont, 'NanumGothic-Regular.ttf')}");
    fontRequests++;
    return { ok: fontAvailable, arrayBuffer: async () => fontBytes };
});

const date = new Date(2026, 9, 28, 12);
const koreanDate = functions.shortSigningDate(date, 'ko-KR');
assert.match(koreanDate, /2026년/);
assert.equal(functions.shortSigningDate(date, 'en-US'), 'Oct 28, 2026');
assert.equal(functions.shortSigningDate(date, 'ja-JP'), 'Oct 28, 2026');
assert.equal(functions.needsKoreanSigningFont('홍길동'), true);
assert.equal(functions.needsKoreanSigningFont('Oct 28, 2026'), false);

const doc = await pdfLib.PDFDocument.create();
await functions.signingPdfFonts(doc, false);
await assert.rejects(functions.signingPdfFonts(doc, true), /font library did not load/);
assert.equal(fontRequests, 0);
browserWindow.fontkit = fontkit;
await assert.rejects(functions.signingPdfFonts(doc, true), /font did not load/);
fontAvailable = true;
const [ink, regular, bold] = await functions.signingPdfFonts(doc, true);
await functions.signingPdfFonts(await pdfLib.PDFDocument.create(), true);
assert.equal(fontRequests, 2, 'Retry the failed font request once and reuse the successful download');
const sheet = doc.addPage();
sheet.drawText('홍길동', { font: ink, x: 50, y: 700 });
sheet.drawText(koreanDate, { font: regular, x: 50, y: 670 });
sheet.drawText('서명 확인', { font: bold, x: 50, y: 640 });
const bytes = await doc.save();
assert.ok(bytes.length < 65_536, 'Embed only the glyphs used');
assert.equal((await pdfLib.PDFDocument.load(bytes)).getPageCount(), 1);
if (process.argv[2]) await writeFile(process.argv[2], bytes);
console.log('Korean signing date, signer text and certificate text saved with subset font.');

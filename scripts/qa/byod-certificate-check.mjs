/** Exercise the actual shared certificate renderer with vendored pdf-lib.
 * Run: node scripts/qa/byod-certificate-check.mjs [optional-preview.pdf]
 * Apex preparation tests cover sending, verification tokens, and final-file hashes.
 */
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const PDFLib = require('../../force-app/main/default/staticresources/pdflib/pdf-lib.min.js');
const source = readFileSync(
    new URL('../../force-app/main/default/pages/DocGenSignaturePdf.page', import.meta.url),
    'utf8'
);
const start = source.indexOf('var CERT_LEFT =');
const end = source.indexOf('// Composite ALL captured fields', start);
assert.ok(start > 0 && end > start, 'Load the shared production certificate renderer');
const { addCertificatePage, drawWrappedText } = new Function(
    'PDFLib',
    'signerData',
    'capturedIp',
    'navigator',
    'collectedFormFieldJson',
    source.slice(start, end) + '\nreturn { addCertificatePage, drawWrappedText };'
)(PDFLib, { formFields: [] }, '192.0.2.2', { userAgent: 'QA browser' }, '{}');

const verifyUrl =
    'https://certificate-verification.example.my.salesforce-sites.com/apex/DocGenVerify?token=' + 'a'.repeat(64);
const doc = await PDFLib.PDFDocument.create();
doc.addPage([612, 792]);
const font = await doc.embedFont(PDFLib.StandardFonts.Helvetica);
const bold = await doc.embedFont(PDFLib.StandardFonts.HelveticaBold);
const lines = [];
drawWrappedText({ drawText: (text) => lines.push(text) }, verifyUrl, {
    font,
    size: 7.5,
    x: 54,
    y: 200,
    maxWidth: 504,
    lineHeight: 10
});
assert.ok(lines.length > 1, 'Exercise a verification URL that wraps');
assert.equal(lines.join(''), verifyUrl, 'Wrapping must preserve every destination character');
assert.ok(lines.every((line) => font.widthOfTextAtSize(line, 7.5) <= 504));

const certificate = {
    documentTitle: 'Prepared Agreement',
    requestId: 'BYOD verification preview',
    verifyUrl,
    signers: [
        {
            name: 'First Signer',
            role: 'Signer 1',
            email: 'first@example.invalid',
            signedAt: 'October 19, 2026 3:00 PM EDT',
            ip: '192.0.2.1',
            consent: true,
            verified: true,
            userAgent: 'QA browser'
        },
        { name: 'Second Signer', role: 'Signer 2', email: 'second@example.invalid', isMe: true, verified: true }
    ]
};
addCertificatePage(doc, font, bold, certificate, 'October 19, 2026 3:01 PM EDT');
assert.equal(doc.getPageCount(), 2, 'Append the certificate without replacing the uploaded document');
const bytes = await doc.save();
const saved = await PDFLib.PDFDocument.load(bytes);
const page = saved.getPage(1);
const annots = page.node.Annots();
assert.equal(annots.size(), 1, 'The completed PDF must contain a real clickable link');
const link = saved.context.lookup(annots.get(0));
const name = PDFLib.PDFName.of;
assert.equal(link.get(name('Subtype')).toString(), '/Link');
const action = link.lookup(name('A'));
assert.equal(action.get(name('S')).toString(), '/URI');
assert.equal(action.get(name('URI')).decodeText(), verifyUrl, 'The saved annotation must contain the complete URL');
const rect = link
    .lookup(name('Rect'))
    .asArray()
    .map((value) => value.asNumber());
assert.equal(rect[0], 54);
assert.equal(rect[2], 558);
assert.ok(rect[3] - rect[1] >= lines.length * 10, 'Every wrapped line must remain clickable');
assert.ok(rect[1] > 0 && rect[3] < 792, 'The verify link stays on the certificate page');

const noSite = await PDFLib.PDFDocument.create();
const noSiteFont = await noSite.embedFont(PDFLib.StandardFonts.Helvetica);
addCertificatePage(noSite, noSiteFont, noSiteFont, { ...certificate, verifyUrl: null }, 'October 19, 2026');
assert.equal(noSite.getPage(0).node.Annots()?.size() || 0, 0, 'No broken annotation when a public site is unavailable');
if (process.argv[2]) writeFileSync(process.argv[2], bytes);
console.log(
    'PASS: shared BYOD/template certificate preserves the PDF and embeds a clickable, complete, wrapped verify URL.'
);

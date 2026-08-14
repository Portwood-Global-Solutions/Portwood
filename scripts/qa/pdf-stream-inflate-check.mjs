/**
 * PDF AcroForm decomposer — inflating FlateDecode streams without the browser API.
 *
 *   node scripts/qa/pdf-stream-inflate-check.mjs
 *
 * Issue #329. goravkseth, on a hardened corporate laptop:
 *
 *   "Testing a pdf template and receiving 'This browser cannot decompress pdf
 *    streams' error after uploading the pdf ... note that this computer is a
 *    corporate laptop and very much locked down"
 *
 * Same class as #320 — a browser API called with no feature detection and no
 * fallback — but a DIFFERENT file and a different format, so #320's fix does not
 * reach it:
 *
 *   docGenZipReader          DecompressionStream('deflate-raw')   RFC 1951, no container
 *   docGenPdfAcroFormDecomposer  DecompressionStream('deflate')   RFC 1950, zlib-wrapped
 *
 * A fillable PDF's object streams are Flate-compressed, so there was nothing to
 * fall back on and the upload dead-ended.
 *
 * The fallback reuses the inline decoder from #320 after stripping the 2-byte
 * zlib header, so there is one implementation rather than two copies of the same
 * 150 lines. That sharing is what this check is really guarding: it asserts the
 * zlib unwrapping is right, because a decoder that is subtly wrong would hand
 * the form parser corrupted object streams rather than failing loudly.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { deflateSync, inflateSync } from 'node:zlib';

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

const zipSrc = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAdmin/docGenZipReader.js', import.meta.url),
    'utf8'
);
const zipPath = '/tmp/docGenZipReader.pdf.' + Date.now() + '.mjs';
writeFileSync(zipPath, zipSrc, 'utf8');
const { inflateRawJs } = await import(zipPath);

// Mirrors the shipped stripZlibHeader.
function stripZlibHeader(bytes) {
    if (bytes.length >= 2 && (bytes[0] & 0x0f) === 8 && ((bytes[0] << 8) | bytes[1]) % 31 === 0) {
        return bytes.subarray(2);
    }
    return bytes;
}

const enc = new TextEncoder();
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

// Payload shapes a real fillable PDF's object streams actually contain.
const cases = [
    ['a tiny object stream', enc.encode('<< /Type /XObject >>')],
    [
        'a form field dictionary',
        enc.encode(
            '<< /T (Account_Name__c) /FT /Tx /Ff 0 /V () /Rect [ 100 700 300 720 ] >>'.repeat(40)
        )
    ],
    ['a content stream with operators', enc.encode('BT /F1 12 Tf 72 720 Td (Hello) Tj ET\n'.repeat(500))],
    ['a long repeated run', enc.encode('0'.repeat(60000))],
    ['binary-ish bytes', new Uint8Array(Array.from({ length: 20000 }, (_, i) => (i * 37) & 0xff))],
    ['empty', new Uint8Array(0)]
];

console.log('\nzlib-wrapped streams decode byte-for-byte, as the platform would');
for (const [name, original] of cases) {
    const zlibBytes = new Uint8Array(deflateSync(Buffer.from(original))); // RFC 1950, like a PDF
    let mine;
    try {
        mine = inflateRawJs(stripZlibHeader(zlibBytes));
    } catch (e) {
        ok(false, `${name} — threw: ${e.message}`);
        continue;
    }
    const theirs = new Uint8Array(inflateSync(Buffer.from(zlibBytes)));
    ok(eq(mine, original), `${name} (${original.length}B) round-trips to the original`);
    ok(eq(mine, theirs), `${name} matches the platform decoder exactly`);
}

console.log('\nthe zlib header is detected, not assumed');
{
    const payload = enc.encode('/Type /Page');
    const wrapped = new Uint8Array(deflateSync(Buffer.from(payload)));
    ok((wrapped[0] & 0x0f) === 8, 'the fixture really is zlib-wrapped (CM=8)');
    ok(((wrapped[0] << 8) | wrapped[1]) % 31 === 0, 'and its header checksum is valid');
    ok(stripZlibHeader(wrapped).length === wrapped.length - 2, 'a wrapped stream loses exactly 2 bytes');

    // A raw stream must pass through untouched, or we would eat two bytes of data.
    const raw = new Uint8Array([0x01, 0x02, 0x03, 0x04]);
    ok(stripZlibHeader(raw).length === raw.length, 'a stream with no zlib header is left alone');
}

console.log('\ncorrupt input throws rather than returning partial output');
{
    const good = new Uint8Array(deflateSync(Buffer.from(enc.encode('x'.repeat(5000)))));
    const truncated = stripZlibHeader(good).subarray(0, 12);
    let threw = false;
    try {
        inflateRawJs(truncated);
    } catch (e) {
        threw = true;
    }
    ok(threw, 'a truncated object stream is an error, not silent garbage');
}

console.log(fail ? `\n${fail} FAILED` : '\npdf stream inflate OK');
process.exit(fail ? 1 : 0);

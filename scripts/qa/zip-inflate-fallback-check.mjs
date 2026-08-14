/**
 * docGenZipReader — the inline DEFLATE fallback.
 *
 *   node scripts/qa/zip-inflate-fallback-check.mjs
 *
 * `new DecompressionStream('deflate-raw')` is a browser API, and browser APIs are
 * not uniformly available to managed-package code: uploading a zip template
 * failed with a decompress error in SOME orgs and not others (#320). A zip whose
 * only member is an HTML file is deflated, so there was nothing to fall back on
 * and the upload dead-ended.
 *
 * The fix feature-detects the native API and falls back to an inline RFC 1951
 * decoder. This asserts that decoder byte-for-byte against the platform's own,
 * across the block types and payload shapes a real template zip produces —
 * because a decompressor that is subtly wrong is far worse than one that is
 * missing: it would hand the merge engine corrupted HTML.
 *
 * Sibling of lws-download-route-check.mjs and locker-preview-route-check.mjs,
 * which cover the same class of org-dependent sandbox failure elsewhere.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { deflateRawSync, inflateRawSync } from 'node:zlib';

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

// Load the shipped reader as a module. It is an LWC file, so copy it out first.
const src = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAdmin/docGenZipReader.js', import.meta.url),
    'utf8'
);
// Expose the internals this check needs without changing the component's API.
const probe = src + '\nexport const __test = { inflateRawJs, hasNativeInflate, inflateRaw };\n';
const tmp = '/tmp/docGenZipReader.check.' + Date.now() + '.mjs';
writeFileSync(tmp, probe, 'utf8');
const mod = await import(tmp);
const { inflateRawJs } = mod.__test;

const enc = new TextEncoder();
const eq = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

// --- payload shapes a real template zip actually contains ---------------------
const cases = [];

cases.push(['empty payload', new Uint8Array(0)]);
cases.push(['one byte', enc.encode('x')]);
cases.push(['short ascii', enc.encode('<html><body>{Name}</body></html>')]);

// Highly compressible: long runs exercise LZ77 back-references heavily.
cases.push(['long repeated run', enc.encode('A'.repeat(70000))]);

// A realistic template body — dynamic Huffman, mixed literals and matches.
const tpl =
    '<!DOCTYPE html><html><head><style>@page{size:Letter}body{font-family:Arial}' +
    'table{border-collapse:collapse;width:100%}td{border:1px solid #ccc;padding:4pt}</style></head><body>' +
    '<table>' +
    '<tr><td>{Name}</td><td>{Amount__c}</td></tr>'.repeat(2000) +
    '</table></body></html>';
cases.push(['realistic html template', enc.encode(tpl)]);

// Incompressible: deflate emits STORED blocks for this, which is a separate branch.
const random = new Uint8Array(50000);
let seed = 12345;
for (let i = 0; i < random.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    random[i] = seed & 0xff;
}
cases.push(['incompressible bytes (stored blocks)', random]);

// Large enough to span multiple deflate blocks.
cases.push(['multi-block payload', enc.encode(tpl.repeat(3))]);

// Non-ASCII, so a byte-level bug shows up as mojibake rather than silence.
cases.push(['utf-8 multibyte', enc.encode('Grüße — 日本語 — {Client__r.Naïve} — €1 234,56'.repeat(500))]);

console.log('\ninline decoder vs the platform decoder, byte for byte');
for (const [name, original] of cases) {
    const compressed = new Uint8Array(deflateRawSync(Buffer.from(original)));
    let mine;
    try {
        mine = inflateRawJs(compressed);
    } catch (e) {
        ok(false, `${name} — threw: ${e.message}`);
        continue;
    }
    const theirs = new Uint8Array(inflateRawSync(Buffer.from(compressed)));
    ok(eq(mine, original), `${name} (${original.length}B) round-trips to the original`);
    ok(eq(mine, theirs), `${name} matches the platform decoder exactly`);
}

console.log('\ncompression levels — each picks different block types');
for (const level of [0, 1, 6, 9]) {
    const original = enc.encode(tpl);
    const compressed = new Uint8Array(deflateRawSync(Buffer.from(original), { level }));
    let mine;
    try {
        mine = inflateRawJs(compressed);
        ok(eq(mine, original), `level ${level} decodes correctly (${compressed.length}B compressed)`);
    } catch (e) {
        ok(false, `level ${level} threw: ${e.message}`);
    }
}

console.log('\nreal .docx parts — what an Office template upload actually carries');
try {
    const docx = readFileSync(
        new URL('../../docs/appexchange/Portwood_DocGen_Solution_Architecture_and_Usage_Guide.docx', import.meta.url)
    );
    const entries = await mod.readZip(new Uint8Array(docx));
    ok(entries.length > 0, `readZip returned ${entries.length} entries end to end`);
    const doc = entries.find((e) => e.name === 'word/document.xml');
    ok(Boolean(doc), 'word/document.xml is present');
    const text = new TextDecoder().decode(doc.data);
    ok(text.startsWith('<?xml'), 'and decodes to well-formed XML');
    ok(text.includes('</w:document>'), 'with its closing tag intact (nothing truncated)');
} catch (e) {
    ok(false, 'end-to-end readZip on a real .docx: ' + e.message);
}

console.log('\nthe actual #320 scenario — the sandbox refuses DecompressionStream');
// Everything above proves the decoder is correct. This proves the ROUTING: with
// the native API unavailable, a real .docx must still read, via the same public
// entry point the upload handler calls.
{
    const savedCtor = globalThis.DecompressionStream;
    let nativeCallsAttempted = 0;
    globalThis.DecompressionStream = function () {
        nativeCallsAttempted++;
        throw new Error("Cannot construct 'DecompressionStream': blocked by the browser sandbox");
    };
    try {
        // Fresh module instance so the cached feature-detect re-runs.
        const tmp2 = '/tmp/docGenZipReader.blocked.' + Date.now() + '.mjs';
        writeFileSync(tmp2, probe, 'utf8');
        const blocked = await import(tmp2);
        ok(blocked.__test.hasNativeInflate() === false, 'the feature detect reports the API unavailable');

        const docx = readFileSync(
            new URL('../../docs/appexchange/Portwood_DocGen_Solution_Architecture_and_Usage_Guide.docx', import.meta.url)
        );
        const entries = await blocked.readZip(new Uint8Array(docx));
        ok(entries.length > 0, `readZip still returns ${entries.length} entries with no native API`);
        const doc = entries.find((e) => e.name === 'word/document.xml');
        const text = new TextDecoder().decode(doc.data);
        ok(text.startsWith('<?xml') && text.includes('</w:document>'), 'and document.xml is intact');
        ok(nativeCallsAttempted > 0, 'the native path was genuinely attempted and refused');

        // An image-less zip — the shape Dave reported, where there is nothing
        // stored to fall back on because the single HTML member is deflated.
        const htmlOnly = new Uint8Array(
            execSync('cd /tmp && rm -rf dgz && mkdir dgz && printf %s ' + JSON.stringify(tpl.slice(0, 4000)) +
                ' > dgz/template.html && cd dgz && zip -q -X - template.html', { maxBuffer: 1 << 26, encoding: 'buffer' })
        );
        const htmlEntries = await blocked.readZip(htmlOnly);
        ok(htmlEntries.length === 1 && htmlEntries[0].name === 'template.html', 'an image-less zip reads too');
        ok(
            new TextDecoder().decode(htmlEntries[0].data) === tpl.slice(0, 4000),
            'and its HTML comes back byte-identical'
        );
    } finally {
        globalThis.DecompressionStream = savedCtor;
    }
}

console.log('\ncorrupt input must throw, never return silent garbage');
const bad = [
    ['truncated stream', new Uint8Array(deflateRawSync(Buffer.from(enc.encode(tpl)))).subarray(0, 40)],
    ['reserved block type', Uint8Array.from([0x07, 0x00, 0x00, 0x00])],
    ['empty input', new Uint8Array(0)]
];
for (const [name, bytes] of bad) {
    let threw = false;
    try {
        inflateRawJs(bytes);
    } catch (e) {
        threw = true;
    }
    ok(threw, `${name} throws rather than returning partial output`);
}

console.log(fail ? `\n${fail} FAILED` : '\ninflate fallback OK');
process.exit(fail ? 1 : 0);

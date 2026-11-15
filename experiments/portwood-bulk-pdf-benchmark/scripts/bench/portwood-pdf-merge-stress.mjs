import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { receiptPdf } from './portwood-receipt-fixtures.mjs';

import { chromium } from 'playwright-core';
const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    'input-dir': { type: 'string' }, 'receipt-id-prefix': { type: 'string' },
    uninterrupted: { type: 'boolean', default: false },
    'output-dir': { type: 'string', default: 'output/pdf' },
    'artifacts-dir': { type: 'string', default: 'artifacts' },
} });
assert.ok(positionals.length <= 1, 'Usage: portwood-pdf-merge-stress.mjs [count] [--input-dir DIR] [--uninterrupted]');
const sourceFiles = values['input-dir'] ? await numberedReceipts(resolve(values['input-dir'])) : null;
const count = Number(positionals[0] ?? sourceFiles?.size ?? 10000);
const uninterrupted = values.uninterrupted;
const outputDir = values['output-dir'];
const artifactsDir = values['artifacts-dir'];
const receiptIdPrefix = values['receipt-id-prefix'];
assert.ok(Number.isSafeInteger(count) && count >= 2 && count <= 100000, 'Specify 2 to 100000 receipts.');
assert.ok(!receiptIdPrefix || (sourceFiles && /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(receiptIdPrefix)), 'Invalid optional receipt ID prefix.');
const timeout = 600000;
const htmlPath = '/scripts/bench/portwood-pdf-merge-browser.html';
const frontendFiles = new Map([
    [htmlPath, 'text/html; charset=utf-8'],
    ['/scripts/bench/portwood-pdf-merge-browser.mjs', 'text/javascript; charset=utf-8'],
    ['/scripts/bench/portwood-pdf-merge-browser.worker.mjs', 'text/javascript; charset=utf-8'],
    ['/scripts/lib/portwood-browser-pdf-merge.mjs', 'text/javascript; charset=utf-8'],
    ['/node_modules/pdf-lib/dist/pdf-lib.esm.min.js', 'text/javascript; charset=utf-8'],
]);
const frontend = new Map(await Promise.all(Array.from(frontendFiles, async ([path, contentType]) => [
    path, {contentType, bytes: await readFile(new URL('../..' + path, import.meta.url))},
])));
const prepareStarted = performance.now();
const source = await buildManifest();
const inputManifestMs = Math.round(performance.now() - prepareStarted);
const manifest = Buffer.from(JSON.stringify(source));
const requests = {
    initial: {count: 0, bytes: 0, min: count + 1, max: 0},
    resumed: {count: 0, bytes: 0, min: count + 1, max: 0},
};
const served = new Uint8Array(count + 1);
let phase = 'initial';
const contentPolicy = "default-src 'self'; script-src 'self'; worker-src 'self'; connect-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'";

function respond(response, contentType, bytes, checksum) {
    response.writeHead(200, {
        'Content-Type': contentType, 'Content-Length': bytes.length, 'Cache-Control': 'no-store',
        'Content-Security-Policy': contentPolicy,
        ...(checksum ? { 'X-Receipt-Sha256': checksum } : {}),
    });
    response.end(bytes);
}
const server = createServer(async (request, response) => {
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path === '/' || frontend.has(path)) {
        const asset = frontend.get(path === '/' ? htmlPath : path);
        return respond(response, asset.contentType, asset.bytes);
    }
    if (path === '/manifest.json') return respond(response, 'application/json', manifest);
    const match = /^\/receipts\/([1-9]\d*)\.pdf$/.exec(path);
    const ordinal = match && Number(match[1]);
    if (Number.isSafeInteger(ordinal) && ordinal <= count) {
        const stats = requests[phase];
        try {
            const input = sourceFiles?.get(ordinal);
            const bytes = input ? await readFile(input.path) : receiptPdf(ordinal);
            stats.count += 1;
            stats.bytes += bytes.length;
            stats.min = Math.min(ordinal, stats.min);
            stats.max = Math.max(ordinal, stats.max);
            served[ordinal] = 1;
            return respond(response, 'application/pdf', bytes, input?.sha256);
        } catch {
            response.writeHead(500);
            response.end();
            return;
        }
    }
    response.writeHead(path === '/favicon.ico' ? 204 : 404);
    response.end();
});
await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
});
const origin = new URL('http://127.0.0.1:' + server.address().port);
const url = new URL(htmlPath, origin);
if (sourceFiles && !uninterrupted) url.searchParams.set('pauseAfter', Math.floor(count / 2));
const errors = [];
let browser;

async function readStatus(page) {
    return page.evaluate(() => {
        const node = document.querySelector('[data-sources-committed]') ?? document.documentElement;
        return {...node.dataset};
    });
}
async function openBenchmark(context) {
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(url.href, {waitUntil: 'domcontentloaded'});
    return page;
}
async function waitForCheckpoint(page, threshold) {
    await page.waitForFunction(limit => {
        const status = document.querySelector('[data-sources-committed]')?.dataset;
        if (status?.stage === 'error') throw new Error(document.body.innerText);
        return Number(status?.sourcesCommitted) >= limit;
    }, threshold, {timeout});
}
async function sha256(path) {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(path)) hash.update(chunk);
    return hash.digest('hex');
}

async function numberedReceipts(directory) {
    const files = new Map();
    for (const entry of await readdir(directory, {withFileTypes: true})) {
        const match = /^(\d+)\.pdf$/i.exec(entry.name);
        if (!entry.isFile() || !match) continue;
        const ordinal = Number(match[1]);
        assert.ok(Number.isSafeInteger(ordinal) && ordinal >= 1, `Invalid receipt filename ${entry.name}.`);
        assert.ok(!files.has(ordinal), `Duplicate input receipt ${ordinal}.`);
        files.set(ordinal, { path: join(directory, entry.name) });
    }
    return files;
}

async function buildManifest() {
    if (!sourceFiles) return {id: 'portwood-year-end-v1-' + count, count, byteLengthEstimate: receiptPdf(1).length * count};
    const corpus = createHash('sha256');
    const lanes = Math.min(count, 16);
    await Promise.all(Array.from({length: lanes}, async (_, index) => {
        for (let ordinal = index + 1; ordinal <= count; ordinal += lanes) {
            const input = sourceFiles.get(ordinal);
            assert.ok(input, `No PDF file for receipt ${ordinal}.`);
            const { size } = await stat(input.path);
            assert.ok(size > 0 && size <= 16 * 1024 * 1024, `Receipt ${ordinal} exceeds the reader size limit.`);
            input.size = size;
            input.sha256 = size > 1024 * 1024 ? await sha256(input.path) :
                createHash('sha256').update(await readFile(input.path)).digest('hex');
        }
    }));
    let byteLengthEstimate = 0;
    for (let ordinal = 1; ordinal <= count; ordinal++) {
        const { size, sha256: digest } = sourceFiles.get(ordinal);
        corpus.update(digest);
        byteLengthEstimate += size;
    }
    return { id: 'portwood-salesforce-receipts-v1', count, byteLengthEstimate, sha256: corpus.digest('hex') };
}

async function* pageText(path) {
    const process = spawn('pdftotext', ['-enc', 'UTF-8', path, '-'], {stdio: ['ignore', 'pipe', 'pipe']});
    let failure;
    const terminated = new Promise(resolve => {
        process.once('close', resolve);
        process.once('error', error => { failure = error; });
    });
    let diagnostic = '';
    process.stderr.setEncoding('utf8').on('data', chunk => {
        if (diagnostic.length < 8192) diagnostic += chunk.slice(0, 8192 - diagnostic.length);
    });
    let pending = '';
    try {
        for await (const chunk of process.stdout.setEncoding('utf8')) {
            const pages = (pending + chunk).split('\f');
            pending = pages.pop();
            for (const page of pages) yield page.replace(/\s+/gu, ' ').trim();
        }
        const code = await terminated;
        if (failure) throw failure;
        assert.equal(code, 0, diagnostic.trim() || 'PDF text extraction failed.');
        assert.equal(pending.trim(), '', 'Expected a PDF page boundary for every page.');
    } finally {
        if (process.exitCode === null) process.kill();
        await terminated;
    }
}

async function verifyInputPageOrder(path) {
    const outputPages = pageText(path);
    const seenText = new Set();
    const foldedPrefix = receiptIdPrefix?.replace(/-/g, '');
    const idPattern = foldedPrefix ? new RegExp(`${foldedPrefix}([0-9]{5,6})(?![0-9])`, 'g') : null;
    const temp = await mkdtemp(join(tmpdir(), 'portwood-pdf-verify-'));
    const batchPath = join(temp, 'source-pages.pdf');
    const batchSize = 500;
    let verified = 0;
    try {
        for (let start = 1; start <= count; start += batchSize) {
            const size = Math.min(batchSize, count - start + 1);
            const paths = Array.from({length: size}, (_, index) => sourceFiles.get(start + index).path);
            if (paths.length > 1) execFileSync('pdfunite', [...paths, batchPath], {timeout: 180000});
            const inputPages = pageText(paths.length === 1 ? paths[0] : batchPath);
            for await (const input of inputPages) {
                const ordinal = ++verified;
                const digest = createHash('sha256').update(input).digest('base64');
                assert.ok(input && !seenText.has(digest), `Missing or duplicate source text at receipt ${ordinal}.`);
                seenText.add(digest);
                const output = await outputPages.next();
                assert.ok(!output.done && output.value === input, `Merged page text differs from receipt ${ordinal}.`);
                if (idPattern) {
                    const identifiers = new Set(Array.from(input.replace(/[-\s]/gu, '').matchAll(idPattern), match => Number(match[1])));
                    assert.ok(identifiers.size === 1 && identifiers.has(ordinal), `Receipt ${ordinal} is missing its expected ID.`);
                }
            }
            assert.equal(verified, start + size - 1, 'Each receipt in the source batch must have one page.');
            if (paths.length > 1) await rm(batchPath);
        }
        assert.ok((await outputPages.next()).done, 'The merged file must contain one page per receipt.');
    } finally {
        await outputPages.return();
        await rm(temp, {recursive: true, force: true});
    }
}

async function verifyRenderedPages(path, ordinals) {
    const temp = await mkdtemp(join(tmpdir(), 'portwood-receipt-render-'));
    try {
        for (const ordinal of ordinals) {
            const input = sourceFiles?.get(ordinal).path ?? join(temp, 'receipt.pdf');
            if (!sourceFiles) await writeFile(input, receiptPdf(ordinal));
            function render(file, page) {
                return execFileSync('pdftoppm', [
                    '-f', String(page), '-l', String(page), '-scale-to', '480', '-singlefile', file,
                ]);
            }
            assert.ok(render(input, 1).equals(render(path, ordinal)), 'Page rendering differs at receipt ' + ordinal);
        }
        return ordinals;
    } finally {
        await rm(temp, {recursive: true, force: true});
    }
}
try {
    browser = await chromium.launch({channel: 'chrome', headless: true});
    const context = await browser.newContext({acceptDownloads: true});
    context.on('request', request => {
        const destination = new URL(request.url());
        if (destination.origin !== origin.origin) {
            errors.push('Unexpected browser request to ' + destination.origin);
        }
    });
    const version = browser.version();
    let page = await openBenchmark(context);
    const start = performance.now();
    await page.locator('#start').click({timeout: 30000});
    let checkpoint = null;
    let interruptedAt = null;
    if (!uninterrupted) {
        await waitForCheckpoint(page, Math.floor(count / 2));
        checkpoint = Number((await readStatus(page)).sourcesCommitted);
        assert.ok(checkpoint < count, 'The tab must close before merge completion.');
        interruptedAt = performance.now() - start;
        await page.close();
        phase = 'resumed';
        page = await openBenchmark(context);
        await page.locator('#start').click({timeout: 30000});
        console.log('Reopened at checkpoint ' + checkpoint + ' of ' + count + '.');
    }
    await page.waitForFunction(() => {
        const status = document.querySelector('[data-sources-committed]')?.dataset;
        if (status?.stage === 'error') throw new Error(document.body.innerText);
        const button = document.querySelector('#download');
        return button && !button.hidden && !button.disabled;
    }, null, {timeout});
    const readyAt = performance.now() - start;
    const final = await readStatus(page);
    assert.equal(Number(final.sourcesCommitted), count, 'Every source must be committed.');
    const resumedFrom = Number(final.sourcesResumed ?? 0);
    if (!uninterrupted) {
        assert.ok(resumedFrom >= checkpoint && resumedFrom < count);
        assert.equal(requests.resumed.min, resumedFrom + 1);
    }
    assert.equal(served.reduce((total, value) => total + value, 0), count);
    await mkdir(outputDir, {recursive: true});
    const name = 'portwood-' + (sourceFiles ? 'salesforce' : 'year-end') + '-receipts-' + count;
    const suffix = uninterrupted ? '-uninterrupted' : '';
    const output = join(outputDir, name + suffix + '.pdf');
    const path = resolve(output);
    const downloadStart = performance.now();
    const downloadPromise = page.waitForEvent('download', {timeout: 90000});
    await page.locator('#download').click();
    const download = await downloadPromise;
    await download.saveAs(path);
    assert.equal(await download.failure(), null);
    const downloadedAt = performance.now() - start;
    const browserSaveMs = Math.round(performance.now() - downloadStart);
    const bytes = (await stat(path)).size;
    if (final.outputBytes) assert.equal(bytes, Number(final.outputBytes));
    const digest = await sha256(path);
    const verifyStarted = performance.now();
    if (sourceFiles) await verifyInputPageOrder(path);
    else execFileSync(process.execPath, ['scripts/bench/portwood-receipt-fixtures.mjs', 'verify', path, String(count)], {stdio: 'inherit'});
    const pixelMatchedPages = await verifyRenderedPages(path, [...new Set([1, Math.floor(count / 2), count])]);
    assert.deepEqual(errors, []);
    const result = {
        fixture: sourceFiles ? 'Numbered receipt PDFs supplied from disk' : 'Individually generated synthetic receipt PDFs served over localhost',
        ...(sourceFiles ? { transport: 'Anonymous localhost HTTP replay of pre-rendered PDFs', inputCorpusSha256: source.sha256,
            verifiedPageTexts: count, verifiedOrdinalReceiptIds: receiptIdPrefix ? count : null } : {}),
        sourceCount: count, verifiedReceiptOrder: true, pixelMatchedPages, browser: 'Chrome ' + version,
        checkpointBeforeTabClosed: checkpoint, resumedFrom, requests,
        timingMs: {interruptedAt: interruptedAt == null ? null : Math.round(interruptedAt),
            inputManifest: inputManifestMs, ready: Math.round(readyAt), downloaded: Math.round(downloadedAt),
            browserSave: browserSaveMs, verify: Math.round(performance.now() - verifyStarted) },
        bytes, sha256: digest, output,
    };
    await mkdir(artifactsDir, {recursive: true});
    await writeFile(join(artifactsDir, name + suffix + '.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result, null, 2));
} catch (error) {
    console.error(error.message);
    if (errors.length) console.error(errors);
    process.exitCode = 1;
} finally {
    await browser?.close();
    server.closeAllConnections();
    server.close();
}

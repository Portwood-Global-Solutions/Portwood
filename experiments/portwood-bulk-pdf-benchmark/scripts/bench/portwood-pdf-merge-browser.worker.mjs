import * as pdfLib from '/node_modules/pdf-lib/dist/pdf-lib.esm.min.js';
import { createIncrementalPdfMerger } from '/scripts/lib/portwood-browser-pdf-merge.mjs';

const outputName = 'merged.pdf';
const checkpointName = 'checkpoint.json';
const schemaVersion = 1;
const bufferBytes = 1024 * 1024;
const maxReceiptBytes = 16 * 1024 * 1024;
const maxCheckpointBytes = 128 * 1024 * 1024;
const shaPattern = /^[a-f0-9]{64}$/;
const encoder = new TextEncoder();
let busy = false;
let pauseRequested = false;

function require(condition, message) {
    if (!condition) throw new Error(message);
}

async function sha256(bytes) {
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return Array.from(new Uint8Array(digest), n => n.toString(16).padStart(2, '0')).join('');
}

function bufferedSink(handle, start) {
    const buffer = new Uint8Array(bufferBytes);
    let offset = start;
    let used = 0;

    function drain() {
        let written = 0;
        while (written < used) {
            const count = handle.write(buffer.subarray(written, used), { at: offset + written });
            require(count > 0, 'Browser disk did not accept PDF bytes.');
            written += count;
        }
        offset += used;
        used = 0;
    }

    return {
        write(bytes) {
            let cursor = 0;
            while (cursor < bytes.length) {
                const count = Math.min(buffer.length - used, bytes.length - cursor);
                buffer.set(bytes.subarray(cursor, cursor + count), used);
                used += count;
                cursor += count;
                if (used === buffer.length) drain();
            }
        },
        durableOffset() {
            drain();
            handle.flush();
            return offset;
        },
    };
}

function readBlock(handle, buffer, offset, size) {
    let consumed = 0;
    while (consumed < size) {
        const count = handle.read(buffer.subarray(consumed, size), { at: offset + consumed });
        require(count > 0, 'The saved PDF prefix is shorter than its checkpoint.');
        consumed += count;
    }
    return buffer.subarray(0, size);
}

async function trustedCheckpoint(directory, handle, identity, count) {
    try {
        const entry = await directory.getFileHandle(checkpointName);
        const file = await entry.getFile();
        if (file.size === 0 || file.size > maxCheckpointBytes) return null;
        const envelope = JSON.parse(await file.text());
        if (typeof envelope.body !== 'string' || await sha256(encoder.encode(envelope.body)) !== envelope.sha256) return null;
        const state = JSON.parse(envelope.body);
        if (state.identity !== identity || state.schemaVersion !== schemaVersion ||
            !Number.isSafeInteger(state.sources) || state.sources < 0 || state.sources > count ||
            !Number.isSafeInteger(state.pages) || state.pages < state.sources ||
            !Number.isSafeInteger(state.offset) || state.offset < 0 || state.offset > handle.getSize() ||
            !Array.isArray(state.blocks) || (!state.complete && state.offset !== state.merge?.offset) ||
            (state.complete && state.sources !== count)) return null;

        const buffer = new Uint8Array(bufferBytes);
        let offset = 0;
        for (const [size, digest] of state.blocks) {
            if (!Number.isSafeInteger(size) || size < 1 || size > buffer.length || size > state.offset - offset ||
                !shaPattern.test(digest) || await sha256(readBlock(handle, buffer, offset, size)) !== digest) return null;
            offset += size;
        }
        return offset === state.offset ? state : null;
    } catch {
        return null;
    }
}

async function saveCheckpoint(directory, handle, identity, state, previousOffset, integrityBuffer) {
    let offset = previousOffset;
    while (offset < state.offset) {
        const size = Math.min(integrityBuffer.length, state.offset - offset);
        state.blocks.push([size, await sha256(readBlock(handle, integrityBuffer, offset, size))]);
        offset += size;
    }
    const body = JSON.stringify({ identity, schemaVersion, ...state });
    const envelope = JSON.stringify({ body, sha256: await sha256(encoder.encode(body)) });
    const entry = await directory.getFileHandle(checkpointName, { create: true });
    const writable = await entry.createWritable();
    try {
        await writable.write(envelope);
        await writable.close();
    } catch (error) {
        await writable.abort().catch(() => {});
        throw error;
    }
}

async function fetchReceipt(ordinal, signal, statistics) {
    const response = await fetch(`/receipts/${ordinal}.pdf`, { cache: 'no-store', signal });
    require(response.ok, `Receipt ${ordinal} returned HTTP ${response.status}.`);
    const lengthHeader = response.headers.get('Content-Length');
    const declaredLength = lengthHeader === null ? null : Number(lengthHeader);
    require(declaredLength === null || (Number.isSafeInteger(declaredLength) && declaredLength > 0 &&
        declaredLength <= maxReceiptBytes), `Receipt ${ordinal} declared an invalid PDF size.`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    require(bytes.length > 0 && bytes.length <= maxReceiptBytes && (declaredLength === null ||
        bytes.length === declaredLength), `Receipt ${ordinal} did not match its declared size.`);
    const checksum = response.headers.get('X-Receipt-Sha256');
    if (checksum !== null) require(await sha256(bytes) === checksum.toLowerCase(), `Receipt ${ordinal} failed SHA-256 verification.`);
    statistics.networkInputs += 1;
    statistics.networkBytes += bytes.length;
    return bytes;
}

function send(stage, statistics, extra = {}) {
    postMessage({ stage, statistics, ...extra });
}

async function merge({ manifest, concurrency, checkpointEvery, pauseAfter }) {
    const statistics = {
        sourcesAppended: 0, sourcesCommitted: 0, sourcesResumed: 0, pages: 0,
        networkInputs: 0, networkBytes: 0, outputBytes: 0, verifiedOutputBytes: 0,
    };
    const controller = new AbortController();
    let handle;
    let output;
    let terminal = 'complete';
    let error;

    try {
        const root = await navigator.storage.getDirectory();
        const identity = await sha256(encoder.encode(JSON.stringify([manifest.id, manifest.count, manifest.sha256 ?? null])));
        const directoryName = `portwood-merge-v${schemaVersion}-${identity}`;
        const directory = await root.getDirectoryHandle(directoryName, { create: true });
        const outputFile = await directory.getFileHandle(outputName, { create: true });
        handle = await outputFile.createSyncAccessHandle();
        const saved = await trustedCheckpoint(directory, handle, identity, manifest.count);
        statistics.sourcesResumed = saved?.sources ?? 0;
        statistics.sourcesCommitted = statistics.sourcesResumed;
        statistics.sourcesAppended = statistics.sourcesResumed;
        statistics.pages = saved?.pages ?? 0;
        statistics.verifiedOutputBytes = saved?.offset ?? 0;
        statistics.outputBytes = statistics.verifiedOutputBytes;
        handle.truncate(statistics.outputBytes);

        output = { directory: directoryName, name: outputName, bytes: statistics.outputBytes };
        if (!saved?.complete) {
            send('running', statistics);
            const integrityBuffer = new Uint8Array(bufferBytes);
            const blocks = saved?.blocks ?? [];
            const sink = bufferedSink(handle, statistics.outputBytes);
            const merger = createIncrementalPdfMerger({ pdfLib, sink, checkpoint: saved?.merge });

            async function commit(mergeState, offset, complete) {
                require(sink.durableOffset() === offset, 'The browser disk offset differs from the PDF checkpoint.');
                await saveCheckpoint(directory, handle, identity, {
                    merge: mergeState, offset, complete, blocks, pages: statistics.pages, sources: statistics.sourcesAppended,
                }, statistics.outputBytes, integrityBuffer);
                statistics.outputBytes = offset;
                statistics.sourcesCommitted = statistics.sourcesAppended;
                send('running', statistics);
            }

            const pending = [];
            const limit = pauseAfter && pauseAfter > statistics.sourcesResumed ? pauseAfter : manifest.count;
            let cursor = statistics.sourcesResumed + 1;
            function queueNext() {
                if (cursor > limit || pauseRequested) return;
                const result = fetchReceipt(cursor, controller.signal, statistics).then(bytes => ({ bytes }), cause => ({ cause }));
                pending.push(result);
                cursor += 1;
            }

            for (let slot = 0; slot < concurrency; slot += 1) queueNext();
            while (pending.length > 0 && !pauseRequested) {
                const { bytes, cause } = await pending.shift();
                if (pauseRequested) break;
                if (cause) throw cause;
                statistics.pages += await merger.append(bytes);
                statistics.sourcesAppended += 1;
                if (statistics.sourcesAppended - statistics.sourcesCommitted >= checkpointEvery) {
                    const snapshot = merger.snapshot();
                    await commit(snapshot, snapshot.offset, false);
                } else if (statistics.sourcesAppended % 100 === 0) {
                    send('running', statistics);
                }
                queueNext();
            }

            if (statistics.sourcesAppended < manifest.count) {
                if (statistics.sourcesAppended > statistics.sourcesCommitted) {
                    const snapshot = merger.snapshot();
                    await commit(snapshot, snapshot.offset, false);
                }
                terminal = 'paused';
            } else {
                const ready = await merger.finish();
                require(ready.pages === statistics.pages, 'The finalized PDF page count differs from the merged sources.');
                await commit(null, ready.bytes, true);
                output.bytes = ready.bytes;
            }
        }
    } catch (cause) {
        terminal = 'error';
        error = cause;
    } finally {
        controller.abort();
        handle?.close();
    }
    send(terminal, statistics, terminal === 'error' ? { message: error.message } : { output });
}

self.addEventListener('message', ({ data }) => {
    if (data.type === 'pause') pauseRequested = true;
    if (data.type === 'start' && !busy) {
        busy = true;
        merge(data).catch(error => send('error', undefined, { message: error.message }));
    }
});

'use strict';

const outputName = 'merged.pdf';
const checkpointName = 'checkpoint.json';
const schemaVersion = 1;
const bufferBytes = 1024 * 1024;
const maxBatchBytes = 1024 * 1024;
const maxBatchSources = 16;
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

let nextRequestId = 0;
const requests = new Map();

function requestPage(action, fields) {
    return new Promise((resolve, reject) => {
        const id = ++nextRequestId;
        requests.set(id, { resolve, reject });
        postMessage({ type: 'request', id, action, ...fields });
    });
}

function orderedSources(total) {
    let queue = [];
    let cursor = 0;
    let done = false;
    return async function next() {
        if (queue.length === 0) {
            if (done) return null;
            const page = await requestPage('manifest', { after: cursor });
            require(page && Array.isArray(page.sources) && page.sources.length > 0 &&
                typeof page.done === 'boolean', 'The pinned source manifest is unavailable.');
            for (const source of page.sources) {
                require(source.ordinal === cursor + 1 && source.ordinal <= total,
                    'The pinned source manifest is missing or out of order.');
                cursor = source.ordinal;
            }
            require(page.done ? cursor === total : page.nextAfterOrdinal === cursor && cursor < total,
                'The pinned source manifest ended at the wrong position.');
            done = page.done;
            queue = page.sources;
        }
        return queue.shift();
    };
}

function sourceBatches(next) {
    let pending;
    return async function nextBatch() {
        const entries = [];
        let total = 0;
        while (entries.length < maxBatchSources) {
            const entry = pending ?? await next();
            pending = undefined;
            if (!entry) break;
            require(Number.isSafeInteger(entry.bytes) && entry.bytes > 0 && entry.bytes <= maxBatchBytes,
                `Source ${entry.ordinal} exceeds the 1 MiB file limit.`);
            if (total + entry.bytes > maxBatchBytes) {
                pending = entry;
                break;
            }
            entries.push(entry);
            total += entry.bytes;
        }
        return entries;
    };
}

async function fetchSources(entries, statistics) {
    const result = await requestPage('sources', { entries });
    require(Array.isArray(result) && result.length === entries.length, 'Salesforce returned the wrong number of source PDFs.');
    for (let index = 0; index < entries.length; index++) {
        const entry = entries[index];
        const bytes = result[index];
        require(bytes instanceof Uint8Array && bytes.length === entry.bytes &&
            self.portwoodMd5(bytes) === entry.checksum.toLowerCase(), `Source ${entry.ordinal} does not match its pinned checksum.`);
    }
    statistics.networkInputs += entries.length;
    statistics.networkBytes += result.reduce((size, bytes) => size + bytes.length, 0);
    statistics.remotingBatches += 1;
    return result;
}

function send(stage, statistics, extra = {}) {
    postMessage({ type: 'status', stage, statistics, ...extra });
}

async function merge({ revision, libraryUrl, owner, jobId }) {
    const count = revision.totalSources;
    const checkpointEvery = Math.min(250, Math.max(1, Math.floor(count / 10)));
    const concurrency = 6;
    const statistics = {
        sourcesAppended: 0, sourcesCommitted: 0, sourcesResumed: 0, pages: 0,
        networkInputs: 0, networkBytes: 0, remotingBatches: 0, outputBytes: 0, verifiedOutputBytes: 0,
    };
    let handle;
    let output;
    let terminal = 'complete';
    let error;

    try {
        require(new URL(libraryUrl).origin === self.location.origin, 'The PDF library URL is unavailable.');
        importScripts(libraryUrl, 'merge-core.js', 'md5.js');
        const root = await navigator.storage.getDirectory();
        const identityParts = [owner, jobId, revision.revisionKey, count];
        if (revision.duplexPadding === true) identityParts.push('duplex');
        const identity = await sha256(encoder.encode(JSON.stringify(identityParts)));
        const directoryName = `portwood-merge-v${schemaVersion}-${identity}`;
        const directory = await root.getDirectoryHandle(directoryName, { create: true });
        const outputFile = await directory.getFileHandle(outputName, { create: true });
        handle = await outputFile.createSyncAccessHandle();
        const saved = await trustedCheckpoint(directory, handle, identity, count);
        const next = orderedSources(count);
        for (let index = 0; index < (saved?.sources ?? 0); index++) {
            require(await next(), 'Salesforce could not verify access to the saved source manifest.');
        }
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
            const merger = self.createPortwoodIncrementalPdfMerger({ pdfLib: self.PDFLib, sink, padOddDocuments: revision.duplexPadding === true, checkpoint: saved?.merge });

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
            const nextBatch = sourceBatches(next);
            async function queueNext() {
                if (pauseRequested) return;
                const entries = await nextBatch();
                if (entries.length === 0 || pauseRequested) return;
                pending.push(fetchSources(entries, statistics).then(batch => ({ batch }), cause => ({ cause })));
            }

            for (let slot = 0; slot < concurrency; slot += 1) await queueNext();
            while (pending.length > 0 && !pauseRequested) {
                const { batch, cause } = await pending.shift();
                if (pauseRequested) break;
                if (cause) throw cause;
                for (const bytes of batch) {
                    if (pauseRequested) break;
                    statistics.pages += await merger.append(bytes);
                    statistics.sourcesAppended += 1;
                    if (statistics.sourcesAppended - statistics.sourcesCommitted >= checkpointEvery) {
                        const snapshot = merger.snapshot();
                        await commit(snapshot, snapshot.offset, false);
                    } else if (statistics.sourcesAppended % 100 === 0) {
                        send('running', statistics);
                    }
                }
                await queueNext();
            }

            if (statistics.sourcesAppended < count) {
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
        handle?.close();
    }
    send(terminal, statistics, terminal === 'error' ? { message: error.message } : { output });
}

self.addEventListener('message', ({ data }) => {
    if (data.type === 'response') {
        const request = requests.get(data.id);
        if (!request) return;
        requests.delete(data.id);
        if (data.error) request.reject(new Error(data.error));
        else request.resolve(data.result);
    }
    if (data.type === 'pause') pauseRequested = true;
    if (data.type === 'start' && !busy) {
        busy = true;
        merge(data).catch(error => send('error', undefined, { message: error.message }));
    }
});

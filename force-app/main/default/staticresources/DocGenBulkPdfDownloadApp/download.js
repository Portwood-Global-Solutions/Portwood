/* global Visualforce */
(() => {
    'use strict';

    const page = document.getElementById('downloadPage');
    const details = document.getElementById('details');
    const status = document.getElementById('status');
    const progress = document.getElementById('progress');
    const start = document.getElementById('start');
    const pause = document.getElementById('pause');
    const download = document.getElementById('download');
    const retry = document.getElementById('retry');
    const newTab = document.getElementById('newTab');
    const jobId = new URLSearchParams(window.location.search).get('jobId');
    const idPattern = /^[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?$/;
    const versionPattern = /^068[A-Za-z0-9]{15}$/;
    const number = new Intl.NumberFormat();
    const maxSourceBytes = 1024 * 1024;
    const maxBatchSources = 16;
    let worker;
    let revision;
    let finishedFile;

    function call(action, ...args) {
        return new Promise((resolve, reject) => {
            Visualforce.remoting.Manager.invokeAction(action, ...args, (result, event) => {
                if (event.status) resolve(result);
                else reject(new Error('Salesforce could not verify access to this bulk PDF.'));
            }, { buffer: false, escape: false, timeout: 30000 });
        });
    }

    function update(stage, message) {
        page.dataset.stage = stage;
        status.textContent = message;
        start.hidden = !['ready', 'paused'].includes(stage);
        pause.hidden = stage !== 'working';
        pause.disabled = false;
        retry.hidden = stage !== 'error';
        download.hidden = stage !== 'complete';
    }

    async function checkDetails() {
        update('checking', 'Checking the bulk job…');
        try {
            const result = await call(page.dataset.describe, jobId);
            if (!result || !result.ready || typeof result.revisionKey !== 'string' || !result.revisionKey ||
                !Number.isSafeInteger(result.totalSources) || result.totalSources < 1) {
                throw new Error('This bulk job does not have a completed combined PDF to prepare.');
            }
            revision = result;
            page.dataset.totalSources = result.totalSources;
            progress.max = result.totalSources;
            details.textContent = `${number.format(result.totalSources)} source PDFs`;
            details.hidden = false;
            if (window.self !== window.top) {
                const target = new URL(window.location.pathname, window.location.origin);
                target.searchParams.set('jobId', jobId);
                newTab.href = target.href;
                newTab.hidden = false;
                update('unsupported', 'Open this page in its own tab to prepare the combined PDF.');
                return;
            }
            if (typeof navigator.storage?.getDirectory !== 'function' || typeof Worker !== 'function' || !crypto.subtle) {
                update('unsupported', 'Use an up-to-date desktop Chrome or Edge browser to prepare this PDF.');
                return;
            }
            if (!idPattern.test(page.dataset.owner)) throw new Error('The Salesforce user could not be verified.');
            update('ready', 'Ready to prepare your combined PDF.');
        } catch (error) {
            update('error', error.message);
        }
    }

    function decodeBase64(data) {
        if (typeof Uint8Array.fromBase64 === 'function') return Uint8Array.fromBase64(data);
        const raw = window.atob(data);
        const bytes = new Uint8Array(raw.length);
        for (let index = 0; index < bytes.length; index++) bytes[index] = raw.charCodeAt(index);
        return bytes;
    }

    function validFile(entry) {
        return entry && versionPattern.test(entry.versionId) && Number.isSafeInteger(entry.ordinal) &&
            Number.isSafeInteger(entry.bytes) && entry.bytes > 0 && entry.bytes <= maxSourceBytes &&
            /^[a-f0-9]{32}$/i.test(entry.checksum);
    }

    async function readSources(entries) {
        if (!Array.isArray(entries) || entries.length === 0 || entries.length > maxBatchSources ||
            entries.some(entry => !validFile(entry)) || entries.reduce((size, entry) => size + entry.bytes, 0) > maxSourceBytes) {
            throw new Error('A source batch has an invalid File version, size, or checksum.');
        }
        const ordinals = entries.map(entry => entry.ordinal);
        const data = await call(page.dataset.sources, jobId, revision.revisionKey, ordinals);
        if (!Array.isArray(data) || data.length !== entries.length) {
            throw new Error('Salesforce returned the wrong number of source PDFs.');
        }
        return entries.map((entry, index) => {
            const encoded = data[index];
            if (typeof encoded !== 'string' || encoded.length !== Math.ceil(entry.bytes / 3) * 4) {
                throw new Error(`Source ${entry.ordinal} is unavailable or changed.`);
            }
            const bytes = decodeBase64(encoded);
            if (bytes.length !== entry.bytes) throw new Error(`Source ${entry.ordinal} has the wrong file size.`);
            return bytes;
        });
    }

    async function answerRequest(client, message) {
        try {
            if (message.action === 'manifest') {
                const result = await call(page.dataset.manifest, jobId, revision.revisionKey, message.after);
                if (worker === client) client.postMessage({ type: 'response', id: message.id, result });
            } else if (message.action === 'sources') {
                const result = await readSources(message.entries);
                if (worker === client) client.postMessage({ type: 'response', id: message.id, result }, result.map(bytes => bytes.buffer));
            }
        } catch (error) {
            if (worker === client) client.postMessage({ type: 'response', id: message.id, error: error.message });
        }
    }

    function endWorker(client) {
        if (worker !== client) return;
        client.terminate();
        worker = undefined;
    }

    function workerMessage(client, message) {
        if (message.type === 'request') {
            answerRequest(client, message);
            return;
        }
        if (worker !== client) return;
        const stats = message.statistics;
        if (stats) {
            progress.value = stats.sourcesAppended;
            for (const [key, value] of Object.entries(stats)) page.dataset[key] = value;
        }
        if (message.stage === 'running') {
            update('working', `Prepared ${number.format(stats.sourcesAppended)} of ${number.format(revision.totalSources)} source PDFs.`);
        } else if (message.stage === 'paused') {
            start.textContent = 'Resume';
            update('paused', `Paused after ${number.format(stats.sourcesCommitted)} source PDFs.`);
            endWorker(client);
        } else if (message.stage === 'complete') {
            finishedFile = message.output;
            update('complete', `Ready to download ${number.format(stats.pages)} pages.`);
            endWorker(client);
        } else if (message.stage === 'error') {
            update('error', message.message || 'The combined PDF could not be prepared.');
            endWorker(client);
        }
    }

    function prepare() {
        update('working', 'Checking saved progress…');
        progress.hidden = false;
        const workerUrl = new URL(page.dataset.worker, window.location.href);
        const libraryUrl = new URL(page.dataset.library, window.location.href);
        if (workerUrl.origin !== window.location.origin || libraryUrl.origin !== window.location.origin) {
            update('error', 'Salesforce PDF resources are unavailable on this page.');
            return;
        }
        let client;
        try {
            client = new Worker(workerUrl);
        } catch (error) {
            update('error', 'The browser could not start the PDF processor.');
            return;
        }
        worker = client;
        client.addEventListener('message', event => workerMessage(client, event.data));
        client.addEventListener('error', () => {
            if (worker !== client) return;
            update('error', 'The browser could not load the PDF processor.');
            endWorker(client);
        });
        client.postMessage({ type: 'start', revision, libraryUrl: libraryUrl.href, owner: page.dataset.owner, jobId });
    }

    async function savePdf() {
        download.disabled = true;
        try {
            const checked = await call(page.dataset.describe, jobId);
            if (!checked?.ready || checked.revisionKey !== revision.revisionKey) throw new Error('This bulk PDF revision is unavailable.');
            const root = await navigator.storage.getDirectory();
            const directory = await root.getDirectoryHandle(finishedFile.directory);
            const handle = await directory.getFileHandle(finishedFile.name);
            const file = await handle.getFile();
            if (file.size !== finishedFile.bytes) throw new Error('The saved PDF does not match the finished revision.');
            const name = String(checked.filename || 'Portwood combined PDF').replace(/[\\/:*?"<>|\u0000-\u001f]/g, '_');
            const url = URL.createObjectURL(file);
            const anchor = document.createElement('a');
            anchor.href = url;
            anchor.download = name.toLowerCase().endsWith('.pdf') ? name : name + '.pdf';
            document.body.appendChild(anchor);
            anchor.click();
            anchor.remove();
            window.setTimeout(() => URL.revokeObjectURL(url), 120000);
            status.textContent = 'PDF sent to Downloads.';
        } catch (error) {
            status.textContent = error.message;
        } finally {
            download.disabled = false;
        }
    }

    start.addEventListener('click', prepare);
    retry.addEventListener('click', checkDetails);
    pause.addEventListener('click', () => {
        if (!worker) return;
        pause.disabled = true;
        status.textContent = 'Saving a checkpoint…';
        worker.postMessage({ type: 'pause' });
    });
    download.addEventListener('click', savePdf);
    if (idPattern.test(jobId)) checkDetails();
    else update('invalid', 'This bulk PDF link is invalid.');
})();

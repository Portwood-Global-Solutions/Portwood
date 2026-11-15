const benchmark = document.getElementById('benchmark');
const status = document.getElementById('status');
const progress = document.getElementById('progress');
const start = document.getElementById('start');
const pause = document.getElementById('pause');
const download = document.getElementById('download');
const options = new URLSearchParams(location.search);
const formatter = new Intl.NumberFormat();
let manifest;
let worker;
let ready;

function integerOption(name, fallback, maximum) {
    const candidate = Number(options.get(name));
    return Number.isSafeInteger(candidate) && candidate > 0 && candidate <= maximum ? candidate : fallback;
}

function update(stage, message, statistics = {}) {
    benchmark.dataset.stage = stage;
    for (const [key, value] of Object.entries(statistics)) benchmark.dataset[key] = value;
    status.textContent = message;
    start.disabled = !['ready', 'paused', 'error'].includes(stage) || !manifest;
    pause.disabled = stage !== 'running';
    download.disabled = stage !== 'complete';
    if (stage === 'error') benchmark.dataset.error = message;
}

function onWorkerMessage({ data: event }) {
    const stats = event.statistics;
    if (stats) progress.value = stats.sourcesAppended;
    switch (event.stage) {
        case 'running':
            update('running', `Merged ${formatter.format(stats.sourcesAppended)} of ${formatter.format(manifest.count)} receipts.`, stats);
            break;
        case 'paused':
            update('paused', `Paused at ${formatter.format(stats.sourcesCommitted)} receipts.`, stats);
            start.textContent = 'Resume merge';
            worker.terminate();
            break;
        case 'complete':
            ready = event.output;
            update('complete', `Ready to download ${formatter.format(stats.pages)} pages.`, stats);
            worker.terminate();
            break;
        case 'error':
            update('error', event.message, stats);
            worker.terminate();
            break;
    }
}

start.addEventListener('click', () => {
    delete benchmark.dataset.error;
    ready = undefined;
    update('running', 'Checking saved merge progress…');
    worker = new Worker(new URL('./portwood-pdf-merge-browser.worker.mjs', import.meta.url), { type: 'module' });
    worker.addEventListener('message', onWorkerMessage);
    worker.addEventListener('error', event => {
        update('error', event.message || 'Browser merge worker failed to load.');
        worker.terminate();
    });
    worker.postMessage({
        type: 'start', manifest,
        concurrency: integerOption('concurrency', 12, 32),
        checkpointEvery: integerOption('checkpoint', Math.max(1, Math.min(500, Math.floor(manifest.count / 10))), 10000),
        pauseAfter: integerOption('pauseAfter', null, manifest.count),
    });
});

pause.addEventListener('click', () => {
    pause.disabled = true;
    worker.postMessage({ type: 'pause' });
});

download.addEventListener('click', async () => {
    try {
        const root = await navigator.storage.getDirectory();
        const directory = await root.getDirectoryHandle(ready.directory);
        const handle = await directory.getFileHandle(ready.name);
        const file = await handle.getFile();
        if (file.size !== ready.bytes) throw new Error('The merged file size differs from the checkpoint.');
        const objectUrl = URL.createObjectURL(file);
        const anchor = document.createElement('a');
        anchor.href = objectUrl;
        anchor.download = `portwood-${manifest.count}-receipts.pdf`;
        document.body.appendChild(anchor);
        anchor.click();
        anchor.remove();
        setTimeout(() => URL.revokeObjectURL(objectUrl), 120000);
    } catch (error) {
        update('error', error.message);
    }
});

try {
    if (typeof navigator.storage?.getDirectory !== 'function') throw new Error('Browser disk storage is unavailable.');
    const response = await fetch('/manifest.json', { cache: 'no-store' });
    if (!response.ok) throw new Error(`Could not load receipt manifest (${response.status}).`);
    const info = await response.json();
    if (typeof info.id !== 'string' || !info.id || info.id.length > 512 ||
        !Number.isSafeInteger(info.count) || info.count < 1 || info.count > 100000) {
        throw new Error('Invalid receipt manifest.');
    }
    manifest = info;
    progress.max = manifest.count;
    update('ready', `${formatter.format(manifest.count)} receipts ready to merge.`, { sourcesTotal: manifest.count });
} catch (error) {
    update('error', error.message);
}

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenNativeWord/docGenNativeWord.js', import.meta.url),
    'utf8'
)
    .replace(
        /import prepareNativeWordDocument[^;]+;/,
        'const prepareNativeWordDocument = (...args) => globalThis.nativeWordTest.prepare(...args);'
    )
    .replace(
        /import getNativeWordDocumentStatus[^;]+;/,
        'const getNativeWordDocumentStatus = (...args) => globalThis.nativeWordTest.status(...args);'
    );
const { generateStaticWord } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const originalTimeout = globalThis.setTimeout;
const originalFetch = globalThis.fetch;
globalThis.setTimeout = (callback) => {
    callback();
    return 0;
};
globalThis.fetch = () => {
    throw new Error('Native Word must never fetch the file through JavaScript.');
};
let checks = 0;
try {
    let calls = 0;
    globalThis.nativeWordTest = {
        prepare: async (args) => {
            assert.deepEqual(args, { templateId: 'template', recordId: 'record', saveToRecord: true });
            return 'job';
        },
        status: async ({ jobId }) => {
            assert.equal(jobId, 'job');
            return ++calls === 1
                ? { status: 'Processing' }
                : { status: 'Completed', requiresMerge: false, contentVersionId: 'file', title: 'Quote' };
        }
    };
    assert.deepEqual(await generateStaticWord('template', 'record', true), {
        status: 'Completed',
        requiresMerge: false,
        contentVersionId: 'file',
        title: 'Quote'
    });
    assert.equal(calls, 2);
    checks += 2;
    globalThis.nativeWordTest.prepare = async () => 'job';
    globalThis.nativeWordTest.status = async () => ({ status: 'Completed', requiresMerge: true });
    assert.equal(await generateStaticWord('template', 'record'), null);
    checks++;
    for (const status of ['Failed', 'Aborted']) {
        globalThis.nativeWordTest.status = async () => ({ status, error: 'Cannot process this document' });
        await assert.rejects(generateStaticWord('template', 'record'), /Cannot process this document/);
        checks++;
    }
    globalThis.nativeWordTest.prepare = async () => null;
    globalThis.nativeWordTest.status = async () => {
        throw new Error('Non-Word templates should not poll.');
    };
    assert.equal(await generateStaticWord('template', 'record'), null);
    checks++;
    globalThis.nativeWordTest.prepare = async () => 'job';
    globalThis.nativeWordTest.status = async () => ({ status: 'Processing' });
    await assert.rejects(generateStaticWord('template', 'record'), /still running/);
    checks++;
} finally {
    globalThis.setTimeout = originalTimeout;
    globalThis.fetch = originalFetch;
    delete globalThis.nativeWordTest;
}
console.log(`PASS: ${checks} native Word job, delivery and no-browser-fetch checks.`);

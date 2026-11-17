import assert from 'node:assert/strict';
import { test } from 'node:test';
import { validateFile } from './files.mjs';

const fixture = {
    id: '068000000000000AAA',
    extension: 'docx',
    size: 2472100,
    checksum: 'e58634ef7d00000fa2f09f879000034e'
};

test('accepts a file larger than the JSON transfer cap through native Files', () => {
    assert.doesNotThrow(() => validateFile(fixture));
    assert.throws(() => validateFile({ ...fixture, size: 10000001 }), /unsupported file size/);
    assert.throws(() => validateFile({ ...fixture, size: 9000001 }, 9000000), /unsupported file size/);
});

test('rejects version paths, invalid checksums and unsafe multipart extensions', () => {
    assert.throws(() => validateFile({ ...fixture, id: '../VersionData' }), /Invalid Salesforce File/);
    assert.throws(() => validateFile({ ...fixture, checksum: null }), /Invalid Salesforce File/);
    assert.throws(() => validateFile({ ...fixture, extension: 'ttf\r\n' }), /Invalid Salesforce File/);
});

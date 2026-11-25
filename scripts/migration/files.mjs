import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const maxFileSize = 10000000;

function pathFor(connection, tail) {
    const origin = new URL(connection.instanceUrl);
    if (origin.protocol !== 'https:' || origin.username || origin.password) {
        throw new Error('The authenticated Salesforce connection must use HTTPS.');
    }
    return new URL('/services/data/v' + connection.version + '/sobjects/ContentVersion' + tail, origin);
}

async function fetchFile(connection, tail, options = {}) {
    const response = await fetch(pathFor(connection, tail), {
        ...options,
        headers: { ...options.headers, Authorization: 'Bearer ' + connection.accessToken },
        redirect: 'error',
        signal: AbortSignal.timeout(180000)
    });
    if (!response.ok) {
        await response.body?.cancel();
        throw new Error(
            'Salesforce Files ' + (options.method || 'GET') + ' failed with status ' + response.status + '.'
        );
    }
    return response;
}

export function validateFile(file, limit = maxFileSize) {
    if (
        !/^068[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/.test(file?.id || '') ||
        !/^[a-z0-9]{1,10}$/i.test(file.extension || '') ||
        !Number.isInteger(file.size) ||
        file.size < 1 ||
        file.size > limit ||
        !/^[a-f0-9]{32}$/i.test(file.checksum || '')
    ) {
        throw new Error('Invalid Salesforce File descriptor or unsupported file size.');
    }
}

async function download(connection, file, localPath) {
    const response = await fetchFile(connection, '/' + file.id + '/VersionData');
    const hash = createHash('md5');
    let size = 0;
    await pipeline(
        Readable.fromWeb(response.body),
        new Transform({
            transform(chunk, _encoding, callback) {
                size += chunk.length;
                if (size > file.size) {
                    callback(new Error('Salesforce File exceeded its declared length.'));
                    return;
                }
                hash.update(chunk);
                callback(null, chunk);
            }
        }),
        createWriteStream(localPath, { mode: 0o600, flags: 'wx' })
    );
    if (size !== file.size || hash.digest('hex') !== file.checksum.toLowerCase()) {
        throw new Error('Downloaded file differs from its source size or checksum.');
    }
}

export async function transferFile(source, target, file, limit = maxFileSize) {
    validateFile(file, limit);
    const temporary = await mkdtemp(join(tmpdir(), 'portwood-migration-'));
    const localPath = join(temporary, 'source');
    try {
        await download(source, file, localPath);
        return await uploadStage(target, file, localPath);
    } finally {
        await rm(temporary, { recursive: true, force: true });
    }
}

export async function uploadStage(target, file, localPath) {
    const stagingTitle = 'Portwood Migration Staging ' + randomUUID();
    const boundary = 'Portwood-' + randomUUID();
    const fileName = 'migration.' + file.extension.toLowerCase();
    const metadata = JSON.stringify({ Title: stagingTitle, PathOnClient: fileName });
    const header = Buffer.from(
        '--' +
            boundary +
            '\r\nContent-Disposition: form-data; name="entity_content"\r\nContent-Type: application/json\r\n\r\n' +
            metadata +
            '\r\n--' +
            boundary +
            '\r\nContent-Disposition: form-data; name="VersionData"; filename="' +
            fileName +
            '"\r\nContent-Type: application/octet-stream\r\n\r\n'
    );
    const footer = Buffer.from('\r\n--' + boundary + '--\r\n');
    async function* multipart() {
        yield header;
        yield* createReadStream(localPath);
        yield footer;
    }
    const result = await fetchFile(target, '', {
        method: 'POST',
        headers: {
            'Content-Type': 'multipart/form-data; boundary=' + boundary,
            'Content-Length': String(header.length + file.size + footer.length)
        },
        body: multipart(),
        duplex: 'half'
    });
    const staged = await result.json();
    if (!staged.success || !/^068[A-Za-z0-9]{12}(?:[A-Za-z0-9]{3})?$/.test(staged.id || '')) {
        throw new Error('Salesforce did not return the staged version ID.');
    }
    return { ...file, id: staged.id, stagingTitle };
}

/**
 * ZIP reader and writer for client-side Office assembly.
 * No external dependencies. Produces valid DOCX/ZIP archives.
 *
 * Public API:
 *   buildDocxFromShell(shellArrayBuffer, xmlOverrides, mediaEntries) → Uint8Array
 *
 * Takes a shell ZIP (template without document XML), adds merged XML entries
 * and images, and produces a final DOCX. Used for client-side DOCX assembly
 * to avoid Apex heap limits on the server.
 */

// ---------------------------------------------------------------------------
// CRC-32 Table (standard polynomial 0xEDB88320)
// ---------------------------------------------------------------------------
const CRC_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let j = 0; j < 8; j++) {
            c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        }
        table[i] = c;
    }
    return table;
})();

function crc32(bytes) {
    let crc = 0xffffffff;
    for (let i = 0; i < bytes.length; i++) {
        crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8);
    }
    return (crc ^ 0xffffffff) >>> 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function utf8Bytes(str) {
    return new TextEncoder().encode(str);
}

function readUint16LE(view, offset) {
    return view.getUint16(offset, true);
}

function readUint32LE(view, offset) {
    return view.getUint32(offset, true);
}

function writeUint16LE(view, offset, value) {
    view.setUint16(offset, value, true);
}

function writeUint32LE(view, offset, value) {
    view.setUint32(offset, value, true);
}

const ZIP_VERSION_NEEDED = 20;
const ZIP_VERSION_MADE_BY_UNIX = 0x0314;
const ZIP_DOS_TIME_MIDNIGHT = 0;
const ZIP_DOS_DATE_1980_01_01 = 33;
const ZIP_EXTERNAL_ATTR_REGULAR_FILE = 0x81a40000;

function concat(arrays) {
    const totalLength = arrays.reduce((sum, a) => sum + a.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const arr of arrays) {
        result.set(arr, offset);
        offset += arr.length;
    }
    return result;
}

// ---------------------------------------------------------------------------
// ZIP Reader — extract entries from an existing ZIP (shell)
// ---------------------------------------------------------------------------

/**
 * Parses a ZIP file and returns a Map of path → Uint8Array (file data).
 * Only handles store-mode (uncompressed) entries. DOCX files use store mode.
 */
function readZipEntries(arrayBuffer) {
    const view = new DataView(arrayBuffer);
    const entries = new Map();
    let offset = 0;

    while (offset < arrayBuffer.byteLength - 4) {
        const sig = readUint32LE(view, offset);
        if (sig !== 0x04034b50) break; // Not a local file header

        const compressedSize = readUint32LE(view, offset + 18);
        const nameLength = readUint16LE(view, offset + 26);
        const extraLength = readUint16LE(view, offset + 28);
        const dataStart = offset + 30 + nameLength + extraLength;

        const nameBytes = new Uint8Array(arrayBuffer, offset + 30, nameLength);
        const name = new TextDecoder().decode(nameBytes);
        const fileData = new Uint8Array(arrayBuffer, dataStart, compressedSize);

        entries.set(name, fileData);
        offset = dataStart + compressedSize;
    }

    return entries;
}

// ---------------------------------------------------------------------------
// ZIP Writer — build a new ZIP from entries
// ---------------------------------------------------------------------------

function buildLocalEntry(nameBytes, fileBytes, compressedBytes) {
    const crc = crc32(fileBytes);
    const size = fileBytes.length;
    const payload = compressedBytes || fileBytes;
    const method = compressedBytes ? 8 : 0;
    const header = new Uint8Array(30 + nameBytes.length);
    const view = new DataView(header.buffer);

    writeUint32LE(view, 0, 0x04034b50);
    writeUint16LE(view, 4, ZIP_VERSION_NEEDED);
    writeUint16LE(view, 6, 0);
    writeUint16LE(view, 8, method);
    writeUint16LE(view, 10, ZIP_DOS_TIME_MIDNIGHT);
    writeUint16LE(view, 12, ZIP_DOS_DATE_1980_01_01);
    writeUint32LE(view, 14, crc);
    writeUint32LE(view, 18, payload.length);
    writeUint32LE(view, 22, size);
    writeUint16LE(view, 26, nameBytes.length);
    writeUint16LE(view, 28, 0);
    header.set(nameBytes, 30);

    return { bytes: concat([header, payload]), crc, size, compressedSize: payload.length, method };
}

function buildCentralEntry(nameBytes, { crc, size, compressedSize, method }, localOffset) {
    const entry = new Uint8Array(46 + nameBytes.length);
    const view = new DataView(entry.buffer);

    writeUint32LE(view, 0, 0x02014b50);
    writeUint16LE(view, 4, ZIP_VERSION_MADE_BY_UNIX);
    writeUint16LE(view, 6, ZIP_VERSION_NEEDED);
    writeUint16LE(view, 8, 0);
    writeUint16LE(view, 10, method);
    writeUint16LE(view, 12, ZIP_DOS_TIME_MIDNIGHT);
    writeUint16LE(view, 14, ZIP_DOS_DATE_1980_01_01);
    writeUint32LE(view, 16, crc);
    writeUint32LE(view, 20, compressedSize);
    writeUint32LE(view, 24, size);
    writeUint16LE(view, 28, nameBytes.length);
    writeUint16LE(view, 30, 0);
    writeUint16LE(view, 32, 0);
    writeUint16LE(view, 34, 0);
    writeUint16LE(view, 36, 0);
    writeUint32LE(view, 38, ZIP_EXTERNAL_ATTR_REGULAR_FILE);
    writeUint32LE(view, 42, localOffset);
    entry.set(nameBytes, 46);

    return entry;
}

function buildEOCD(entryCount, cdSize, cdOffset) {
    const eocd = new Uint8Array(22);
    const view = new DataView(eocd.buffer);

    writeUint32LE(view, 0, 0x06054b50);
    writeUint16LE(view, 4, 0);
    writeUint16LE(view, 6, 0);
    writeUint16LE(view, 8, entryCount);
    writeUint16LE(view, 10, entryCount);
    writeUint32LE(view, 12, cdSize);
    writeUint32LE(view, 16, cdOffset);
    writeUint16LE(view, 20, 0);

    return eocd;
}

function zipPathPriority(path) {
    if (path === '[Content_Types].xml') return '0000';
    if (path === '_rels/.rels') return '0001';
    if (path.startsWith('docProps/')) return '0010' + path;
    if (path.startsWith('customXml/')) return '0020' + path;
    if (path.startsWith('ppt/')) return '0030' + path;
    if (path.startsWith('word/')) return '0030' + path;
    if (path.startsWith('xl/')) return '0030' + path;
    if (path.startsWith('_rels/')) return '0040' + path;
    return '9999' + path;
}

function orderedZipEntries(entries) {
    const orderedFiles = [...entries.keys()]
        .filter((path) => !path.endsWith('/'))
        .sort((a, b) => zipPathPriority(a).localeCompare(zipPathPriority(b)));
    const result = [];
    const emittedFiles = new Set();

    for (const path of orderedFiles) {
        if (emittedFiles.has(path)) {
            continue;
        }
        emittedFiles.add(path);
        result.push([path, entries.get(path)]);
    }

    return result;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Builds a DOCX by merging a shell ZIP with server-merged XML entries and images.
 *
 * @param {ArrayBuffer} shellArrayBuffer - The shell ZIP (template without document XML)
 * @param {Object} xmlOverrides - { 'word/document.xml': '<merged xml>', '[Content_Types].xml': '...', ... }
 * @param {Object} mediaEntries - { 'word/media/img.png': Uint8Array, ... } (fetched image blobs)
 * @returns {Uint8Array} Final DOCX ZIP bytes
 */
/**
 * Assembles a DOCX ZIP from XML string parts and base64-encoded media files.
 * No shell ZIP needed — builds entirely from scratch.
 *
 * @param {Object} xmlParts   - { 'word/document.xml': '<xml string>', ... }
 * @param {Object} mediaParts - { 'word/media/img.png': '<base64 string>', ... }
 * @returns {Uint8Array} ZIP archive bytes
 */
export function buildDocx(xmlParts, mediaParts) {
    return writeZip(officeEntries(xmlParts, mediaParts));
}

/** Compress the very large document part of a giant query before download. */
export async function buildCompressedDocx(xmlParts, mediaParts) {
    const entries = officeEntries(xmlParts, mediaParts);
    const documentBytes = entries.get('word/document.xml');
    if (!documentBytes || typeof CompressionStream !== 'function') {
        return writeZip(entries);
    }

    const input = new Blob([documentBytes], { type: 'text/plain' });
    const stream = input.stream().pipeThrough(new CompressionStream('deflate'));
    const wrapped = new Uint8Array(await new Response(stream).arrayBuffer());
    // ZIP requires raw DEFLATE. The web API's zlib format adds a two-byte
    // header and a four-byte Adler-32 checksum around the DEFLATE bytes.
    const deflated = wrapped.subarray(2, wrapped.length - 4);
    return writeZip(entries, deflated.length < documentBytes.length ? deflated : null);
}

function officeEntries(xmlParts, mediaParts) {
    const allEntries = new Map();

    // XML files (text → UTF-8 bytes)
    for (const [path, content] of Object.entries(xmlParts)) {
        allEntries.set(path, utf8Bytes(content));
    }

    // Media files (base64 → binary bytes)
    for (const [path, b64] of Object.entries(mediaParts)) {
        const binaryStr = atob(b64);
        const fileBytes = new Uint8Array(binaryStr.length);
        for (let i = 0; i < binaryStr.length; i++) {
            fileBytes[i] = binaryStr.charCodeAt(i);
        }
        allEntries.set(path, fileBytes);
    }
    return allEntries;
}

function writeZip(entries, deflatedDocument) {
    const localEntries = [];
    const centralEntries = [];
    let offset = 0;
    for (const [path, fileBytes] of orderedZipEntries(entries)) {
        const nameBytes = utf8Bytes(path);
        const local = buildLocalEntry(nameBytes, fileBytes, path === 'word/document.xml' ? deflatedDocument : null);
        centralEntries.push(buildCentralEntry(nameBytes, local, offset));
        localEntries.push(local.bytes);
        offset += local.bytes.length;
    }

    const centralDir = concat(centralEntries);
    const eocd = buildEOCD(localEntries.length, centralDir.length, offset);
    return concat([...localEntries, centralDir, eocd]);
}

export function buildDocxFromShell(shellArrayBuffer, xmlOverrides, mediaEntries) {
    // 1. Read all entries from the shell ZIP
    const shellEntries = readZipEntries(shellArrayBuffer);

    // 2. Build combined entry map: shell entries + overrides + media
    const allEntries = new Map();

    // Shell entries first (styles, numbering, theme, etc.)
    for (const [path, data] of shellEntries) {
        allEntries.set(path, data);
    }

    // XML overrides (merged document.xml, updated rels, updated content types)
    for (const [path, content] of Object.entries(xmlOverrides)) {
        allEntries.set(path, utf8Bytes(content));
    }

    // Media entries (images fetched by URL)
    for (const [path, data] of Object.entries(mediaEntries)) {
        if (data instanceof Uint8Array) {
            allEntries.set(path, data);
        }
    }

    return writeZip(allEntries);
}

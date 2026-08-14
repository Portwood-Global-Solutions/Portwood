import { inflateRawJs } from './docGenZipReader';

function base64ToBytes(base64) {
    const binary = atob((base64 || '').replace(/\s+/g, ''));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i) & 0xff;
    }
    return bytes;
}

function bytesToLatin1(bytes) {
    const chunkSize = 0x8000;
    let out = '';
    for (let i = 0; i < bytes.length; i += chunkSize) {
        out += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return out;
}

function latin1ToBytes(text) {
    const bytes = new Uint8Array((text || '').length);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = text.charCodeAt(i) & 0xff;
    }
    return bytes;
}

/**
 * Strips the 2-byte zlib header (RFC 1950) so the raw DEFLATE decoder can read
 * the body. PDF `FlateDecode` streams are zlib-wrapped — which is why this path
 * asks for `'deflate'` while the zip reader asks for `'deflate-raw'`.
 *
 * The trailing 4-byte Adler-32 is simply not read: the decoder stops at the
 * final block, so it never reaches the checksum.
 */
function stripZlibHeader(bytes) {
    // CMF/FLG: low nibble of CMF is the compression method, 8 = deflate, and
    // (CMF<<8 | FLG) must be a multiple of 31. Anything else is already raw.
    if (bytes.length >= 2 && (bytes[0] & 0x0f) === 8 && ((bytes[0] << 8) | bytes[1]) % 31 === 0) {
        return bytes.subarray(2);
    }
    return bytes;
}

async function inflatePdfStream(bytes) {
    // Native first, inline decoder when the sandbox will not give it to us (#329).
    //
    // This is the same class of failure as #320 — a browser API called with no
    // feature detection and no fallback — but a DIFFERENT file and a different
    // format, so #320's fix does not reach it. goravkseth hit it on a hardened
    // corporate laptop:
    //
    //   "receiving 'This browser cannot decompress pdf streams' error after
    //    uploading the pdf ... note that this computer is a corporate laptop and
    //    very much locked down"
    //
    // A fillable PDF's object streams are Flate-compressed, so there was nothing
    // to fall back on and the upload dead-ended with a message that told the
    // user their browser was at fault and offered no next step.
    try {
        if (typeof DecompressionStream !== 'undefined') {
            const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
            const buffer = await new Response(stream).arrayBuffer();
            return new Uint8Array(buffer);
        }
    } catch (e) {
        // Constructor missing, 'deflate' refused, or the stream failed mid-way.
        // The inline decoder needs no platform support, so try that rather than
        // failing the upload.
    }
    return inflateRawJs(stripZlibHeader(bytes));
}

function concatBytes(parts) {
    const total = parts.reduce((sum, part) => sum + part.length, 0);
    const out = new Uint8Array(total);
    let offset = 0;
    parts.forEach((part) => {
        out.set(part, offset);
        offset += part.length;
    });
    return out;
}

function bytesToBase64Local(bytes) {
    const chunkSize = 0x8000;
    let binary = '';
    for (let i = 0; i < bytes.length; i += chunkSize) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
}

function md5Bytes(input) {
    const bytes = input instanceof Uint8Array ? input : latin1ToBytes(input);
    const words = [];
    for (let i = 0; i < bytes.length; i++) {
        words[i >> 2] = (words[i >> 2] || 0) | (bytes[i] << ((i % 4) * 8));
    }
    const bitLen = bytes.length * 8;
    words[bytes.length >> 2] = (words[bytes.length >> 2] || 0) | (0x80 << ((bytes.length % 4) * 8));
    words[(((bytes.length + 8) >> 6) + 1) * 16 - 2] = bitLen & 0xffffffff;
    words[(((bytes.length + 8) >> 6) + 1) * 16 - 1] = Math.floor(bitLen / 0x100000000);

    let a = 0x67452301;
    let b = 0xefcdab89;
    let c = 0x98badcfe;
    let d = 0x10325476;
    const shifts = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14,
        20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6,
        10, 15, 21
    ];
    const table = [];
    for (let i = 0; i < 64; i++) {
        table[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) | 0;
    }

    const add = (x, y) => (x + y) | 0;
    const rotate = (x, n) => (x << n) | (x >>> (32 - n));
    for (let i = 0; i < words.length; i += 16) {
        let aa = a;
        let bb = b;
        let cc = c;
        let dd = d;
        for (let j = 0; j < 64; j++) {
            let f;
            let g;
            if (j < 16) {
                f = (bb & cc) | (~bb & dd);
                g = j;
            } else if (j < 32) {
                f = (dd & bb) | (~dd & cc);
                g = (5 * j + 1) % 16;
            } else if (j < 48) {
                f = bb ^ cc ^ dd;
                g = (3 * j + 5) % 16;
            } else {
                f = cc ^ (bb | ~dd);
                g = (7 * j) % 16;
            }
            const temp = dd;
            dd = cc;
            cc = bb;
            bb = add(bb, rotate(add(add(aa, f), add(words[i + g] || 0, table[j])), shifts[j]));
            aa = temp;
        }
        a = add(a, aa);
        b = add(b, bb);
        c = add(c, cc);
        d = add(d, dd);
    }

    const out = new Uint8Array(16);
    [a, b, c, d].forEach((word, i) => {
        out[i * 4] = word & 0xff;
        out[i * 4 + 1] = (word >>> 8) & 0xff;
        out[i * 4 + 2] = (word >>> 16) & 0xff;
        out[i * 4 + 3] = (word >>> 24) & 0xff;
    });
    return out;
}

function parsePdfLiteralBytes(text, openIdx) {
    let escaped = false;
    let depth = 1;
    const out = [];
    for (let i = openIdx + 1; i < text.length; i++) {
        const code = text.charCodeAt(i) & 0xff;
        if (escaped) {
            if (code >= 48 && code <= 55) {
                let octal = String.fromCharCode(code);
                let j = i + 1;
                while (j < text.length && octal.length < 3) {
                    const next = text.charCodeAt(j) & 0xff;
                    if (next < 48 || next > 55) break;
                    octal += String.fromCharCode(next);
                    j++;
                }
                out.push(parseInt(octal, 8) & 0xff);
                i = j - 1;
            } else if (code === 110) out.push(10);
            else if (code === 114) out.push(13);
            else if (code === 116) out.push(9);
            else if (code === 98) out.push(8);
            else if (code === 102) out.push(12);
            else if (code === 10 || code === 13) {
                if (code === 13 && text.charCodeAt(i + 1) === 10) i++;
            } else out.push(code);
            escaped = false;
        } else if (code === 92) {
            escaped = true;
        } else if (code === 40) {
            depth++;
            out.push(code);
        } else if (code === 41) {
            depth--;
            if (depth === 0) {
                return new Uint8Array(out);
            }
            out.push(code);
        } else {
            out.push(code);
        }
    }
    return null;
}

function parsePdfHexBytes(hex) {
    const clean = (hex || '').replace(/\s+/g, '');
    const out = new Uint8Array(Math.ceil(clean.length / 2));
    for (let i = 0; i < out.length; i++) {
        out[i] = parseInt(clean.substring(i * 2, i * 2 + 2).padEnd(2, '0'), 16);
    }
    return out;
}

function extractPdfStringBytes(body, key) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    const openIdx = body.indexOf('(', keyIdx);
    const hexIdx = body.indexOf('<', keyIdx);
    if (hexIdx > -1 && (openIdx < 0 || hexIdx < openIdx) && body.substring(hexIdx, hexIdx + 2) !== '<<') {
        const closeIdx = body.indexOf('>', hexIdx);
        return closeIdx > -1 ? parsePdfHexBytes(body.substring(hexIdx + 1, closeIdx)) : null;
    }
    return openIdx > -1 ? parsePdfLiteralBytes(body, openIdx) : null;
}

function deriveStandardAesV2Key(encryptBody, fileIdBytes) {
    const revision = numFrom('/R\\s+(\\d+)', encryptBody);
    const version = numFrom('/V\\s+(\\d+)', encryptBody);
    const lengthValues = Array.from(encryptBody.matchAll(/\/Length\s+(\d+)/g)).map((match) => Number(match[1]));
    const supportsAes128 = lengthValues.includes(128) || lengthValues.includes(16);
    const permissions = numFrom('/P\\s+(-?\\d+)', encryptBody);
    if (revision !== 4 || version !== 4 || !supportsAes128 || permissions == null) {
        throw new Error('Encrypted PDF field scanning currently supports Standard R4/AESV2 forms only.');
    }
    if (!/\/CFM\s*\/AESV2/.test(encryptBody)) {
        throw new Error('Encrypted PDF field scanning currently supports AESV2 forms only.');
    }
    const owner = extractPdfStringBytes(encryptBody, '/O');
    if (!owner || !fileIdBytes) {
        throw new Error('Encrypted PDF security dictionary could not be read.');
    }
    const padding = parsePdfHexBytes('28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A');
    const permissionBytes = new Uint8Array(4);
    new DataView(permissionBytes.buffer).setInt32(0, permissions, true);
    let digest = md5Bytes(concatBytes([padding, owner, permissionBytes, fileIdBytes]));
    for (let i = 0; i < 50; i++) {
        digest = md5Bytes(digest.subarray(0, 16));
    }
    return digest.subarray(0, 16);
}

function parseEncryptionContext(text, objects) {
    const encryptRef = /\/Encrypt\s+(\d+)\s+0\s+R/.exec(text);
    if (!encryptRef) {
        return null;
    }
    const encryptObject = objects.get(Number(encryptRef[1]));
    const fileIdMatch = /\/ID\s*\[\s*<([0-9A-Fa-f\s]+)>/.exec(text);
    if (!encryptObject || !fileIdMatch) {
        throw new Error('Encrypted PDF security dictionary could not be read.');
    }
    return {
        encryptObjectNumber: Number(encryptRef[1]),
        fileKey: deriveStandardAesV2Key(encryptObject.body, parsePdfHexBytes(fileIdMatch[1]))
    };
}

async function decryptPdfStreamBytes(encryption, objectNumber, generationNumber, bytes) {
    if (!encryption) {
        return bytes;
    }
    if (!window.crypto || !window.crypto.subtle) {
        throw new Error('This browser cannot decrypt encrypted PDF object streams.');
    }
    const objectKeySeed = new Uint8Array([
        objectNumber & 0xff,
        (objectNumber >> 8) & 0xff,
        (objectNumber >> 16) & 0xff,
        generationNumber & 0xff,
        (generationNumber >> 8) & 0xff
    ]);
    const salt = latin1ToBytes('sAlT');
    const objectKey = md5Bytes(concatBytes([encryption.fileKey, objectKeySeed, salt])).subarray(0, 16);
    const iv = bytes.subarray(0, 16);
    const cipherText = bytes.subarray(16);
    const key = await window.crypto.subtle.importKey('raw', objectKey, { name: 'AES-CBC' }, false, ['decrypt']);
    const decrypted = new Uint8Array(await window.crypto.subtle.decrypt({ name: 'AES-CBC', iv }, key, cipherText));
    return decrypted;
}

async function decryptPdfStringBytes(encryption, objectNumber, generationNumber, bytes) {
    if (!encryption) {
        return bytes;
    }
    if (!bytes || bytes.length <= 16) {
        return bytes;
    }
    try {
        return await decryptPdfStreamBytes(encryption, objectNumber, generationNumber, bytes);
    } catch (e) {
        return bytes;
    }
}

function streamBounds(text, bodyStart, bodyEnd) {
    const body = text.substring(bodyStart, bodyEnd);
    const streamRel = body.indexOf('stream');
    if (streamRel < 0) {
        return null;
    }
    let start = bodyStart + streamRel + 'stream'.length;
    if (text.substring(start, start + 2) === '\r\n') {
        start += 2;
    } else if (text.substring(start, start + 1) === '\n' || text.substring(start, start + 1) === '\r') {
        start += 1;
    }
    let end = bodyStart + body.lastIndexOf('endstream');
    while (end > start && (text.charCodeAt(end - 1) === 10 || text.charCodeAt(end - 1) === 13)) {
        end--;
    }
    return { start, end };
}

function parseClassicXrefOffsets(text) {
    const startMatch = /startxref\s+(\d+)\s*%%EOF\s*$/.exec(text);
    if (!startMatch) {
        return new Set();
    }
    const xrefStart = Number(startMatch[1]);
    if (!Number.isFinite(xrefStart) || text.substring(xrefStart, xrefStart + 4) !== 'xref') {
        return new Set();
    }
    const trailerIdx = text.indexOf('trailer', xrefStart);
    if (trailerIdx < 0) {
        return new Set();
    }
    const offsets = new Set();
    const lines = text.substring(xrefStart, trailerIdx).split(/\r?\n/);
    let i = 1;
    while (i < lines.length) {
        const header = /^(\d+)\s+(\d+)$/.exec((lines[i] || '').trim());
        i++;
        if (!header) {
            continue;
        }
        const count = Number(header[2]);
        for (let j = 0; j < count && i < lines.length; j++, i++) {
            const entry = /^(\d{10})\s+\d{5}\s+n/.exec((lines[i] || '').trim());
            if (entry) {
                offsets.add(Number(entry[1]));
            }
        }
    }
    return offsets;
}

function parseDirectObjects(text, bytes) {
    const objects = new Map();
    const xrefOffsets = parseClassicXrefOffsets(text);
    const re = /(\d+)\s+0\s+obj\b/g;
    let match;
    while ((match = re.exec(text)) !== null) {
        if (xrefOffsets.size && !xrefOffsets.has(match.index)) {
            continue;
        }
        const objectNumber = Number(match[1]);
        const bodyStart = match.index + match[0].length;
        const firstEndObj = text.indexOf('endobj', bodyStart);
        const streamIdx = text.indexOf('stream', bodyStart);
        let end;
        if (streamIdx > -1 && firstEndObj > -1 && streamIdx < firstEndObj) {
            const endStreamIdx = text.indexOf('endstream', streamIdx);
            end = endStreamIdx > -1 ? text.indexOf('endobj', endStreamIdx) : -1;
        } else {
            end = firstEndObj;
        }
        if (end < 0) {
            continue;
        }
        const body = text.substring(bodyStart, end);
        const bounds = streamBounds(text, bodyStart, end);
        objects.set(objectNumber, {
            objectNumber,
            body,
            streamBytes: bounds ? bytes.subarray(bounds.start, bounds.end) : null
        });
        re.lastIndex = end + 'endobj'.length;
    }
    return objects;
}

function numFrom(pattern, text, fallback = null) {
    let value = fallback;
    const re = new RegExp(pattern, 'g');
    let match;
    while ((match = re.exec(text)) !== null) {
        value = Number(match[1]);
    }
    return value;
}

function extractArray(body, key) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    let openIdx = keyIdx + key.length;
    while (openIdx < body.length && /\s/.test(body[openIdx])) {
        openIdx++;
    }
    if (body[openIdx] !== '[') return null;
    let depth = 0;
    let inLiteral = false;
    let escaped = false;
    for (let i = openIdx; i < body.length; i++) {
        const ch = body[i];
        if (inLiteral) {
            if (escaped) escaped = false;
            else if (ch === '\\') escaped = true;
            else if (ch === ')') inLiteral = false;
            continue;
        }
        if (ch === '(') inLiteral = true;
        else if (ch === '[') depth++;
        else if (ch === ']') {
            depth--;
            if (depth === 0) return body.substring(openIdx + 1, i);
        }
    }
    return null;
}

function extractRef(body, key) {
    const match = new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s+(\\d+)\\s+0\\s+R').exec(body);
    return match ? Number(match[1]) : null;
}

function refsIn(text) {
    const refs = [];
    const re = /(\d+)\s+0\s+R/g;
    let match;
    while ((match = re.exec(text || '')) !== null) {
        refs.push(Number(match[1]));
    }
    return refs;
}

function numsIn(text) {
    const nums = [];
    const re = /-?\d+(?:\.\d+)?/g;
    let match;
    while ((match = re.exec(text || '')) !== null) {
        nums.push(Number(match[0]));
    }
    return nums;
}

function directName(body, key) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    const match = /^\s*\/([A-Za-z0-9_.-]+)/.exec(body.substring(keyIdx + key.length));
    return match ? match[1] : null;
}

function pageMediaBox(pageBody) {
    const values = numsIn(extractArray(pageBody, '/MediaBox'));
    return mediaBoxFromValues(values);
}

function mediaBoxFromValues(values) {
    if (values.length >= 4) {
        return {
            left: values[0],
            bottom: values[1],
            right: values[2],
            top: values[3],
            width: Math.abs(values[2] - values[0]),
            height: Math.abs(values[3] - values[1])
        };
    }
    return { left: 0, bottom: 0, right: 612, top: 792, width: 612, height: 792 };
}

function pageMediaBoxValues(pageBody) {
    return numsIn(extractArray(pageBody, '/MediaBox')).slice(0, 4);
}

function fieldLocationLabel(rect, mediaBox) {
    if (!rect || rect.length < 4 || !mediaBox) {
        return '';
    }
    const centerX = (rect[0] + rect[2]) / 2;
    const centerY = (rect[1] + rect[3]) / 2;
    const xRatio = mediaBox.width ? (centerX - mediaBox.left) / mediaBox.width : 0.5;
    const yRatio = mediaBox.height ? (mediaBox.top - centerY) / mediaBox.height : 0.5;
    const vertical = yRatio < 0.33 ? 'Top' : yRatio < 0.66 ? 'Middle' : 'Bottom';
    const horizontal = xRatio < 0.33 ? 'left' : xRatio < 0.66 ? 'center' : 'right';
    return vertical + ' ' + horizontal;
}

function rectFromBody(body) {
    const rect = numsIn(extractArray(body, '/Rect')).slice(0, 4);
    return rect.length >= 4 ? rect : null;
}

function estimatedPageNumberFromFieldName(name) {
    const match = /#subform\[(\d+)\]/.exec(name || '');
    return match ? Number(match[1]) + 1 : null;
}

function collectPageNumbers(objects, pageObjectNumber, pages, inheritedMediaBoxValues = null) {
    const page = objects.get(pageObjectNumber);
    if (!page) {
        return;
    }
    const ownMediaBoxValues = pageMediaBoxValues(page.body);
    const mediaBoxValues = ownMediaBoxValues.length >= 4 ? ownMediaBoxValues : inheritedMediaBoxValues;
    const typeName = directName(page.body, '/Type');
    if (typeName === 'Page') {
        pages.push({
            objectNumber: pageObjectNumber,
            mediaBox: mediaBoxFromValues(mediaBoxValues || [])
        });
        return;
    }
    const kids = refsIn(extractArray(page.body, '/Kids'));
    kids.forEach((kid) => collectPageNumbers(objects, kid, pages, mediaBoxValues));
}

function pageAnnotationRefs(objects, pageBody) {
    const inlineAnnots = extractArray(pageBody, '/Annots');
    if (inlineAnnots) {
        return refsIn(inlineAnnots);
    }
    const annotArrayRef = extractRef(pageBody, '/Annots');
    const annotArray = annotArrayRef == null ? null : objects.get(annotArrayRef);
    return annotArray ? refsIn(annotArray.body) : [];
}

function collectAnnotationLocations(objects, rootBody) {
    const locations = new Map();
    const pagesRoot = extractRef(rootBody, '/Pages');
    const pageNumbers = [];
    collectPageNumbers(objects, pagesRoot, pageNumbers);
    const pageIndexByObject = new Map();
    pageNumbers.forEach((pageInfo, pageIndex) => {
        pageIndexByObject.set(pageInfo.objectNumber, {
            pageNumber: pageIndex + 1,
            mediaBox: pageInfo.mediaBox || pageMediaBox('')
        });
    });
    pageNumbers.forEach((pageInfo, pageIndex) => {
        const page = objects.get(pageInfo.objectNumber);
        if (!page) {
            return;
        }
        const mediaBox = pageInfo.mediaBox || pageMediaBox(page.body);
        const annots = pageAnnotationRefs(objects, page.body);
        annots.forEach((annotNumber) => {
            const annot = objects.get(annotNumber);
            if (!annot) {
                return;
            }
            const rect = rectFromBody(annot.body);
            if (!rect) {
                return;
            }
            const location = {
                pageNumber: pageIndex + 1,
                rect,
                mediaBox,
                locationLabel: fieldLocationLabel(rect, mediaBox)
            };
            locations.set(annotNumber, location);
            const parent = extractRef(annot.body, '/Parent');
            if (parent != null && !locations.has(parent)) {
                locations.set(parent, location);
            }
        });
    });
    objects.forEach((obj, objectNumber) => {
        if (!obj || locations.has(objectNumber) || directName(obj.body, '/Subtype') !== 'Widget') {
            return;
        }
        const pageRef = extractRef(obj.body, '/P');
        const pageInfo = pageIndexByObject.get(pageRef);
        const rect = rectFromBody(obj.body);
        if (!pageInfo || !rect) {
            return;
        }
        const location = {
            pageNumber: pageInfo.pageNumber,
            rect,
            mediaBox: pageInfo.mediaBox,
            locationLabel: fieldLocationLabel(rect, pageInfo.mediaBox)
        };
        locations.set(objectNumber, location);
        const parent = extractRef(obj.body, '/Parent');
        if (parent != null && !locations.has(parent)) {
            locations.set(parent, location);
        }
    });
    return locations;
}

async function extractXfaPackets(objects, acroFormBody, encryption) {
    const xfaArray = extractArray(acroFormBody, '/XFA');
    if (!xfaArray) {
        return [];
    }
    const packets = [];
    const re = /\(([^)]*)\)\s*(\d+)\s+0\s+R/g;
    let match;
    while ((match = re.exec(xfaArray)) !== null) {
        const objectNumber = Number(match[2]);
        const obj = objects.get(objectNumber);
        if (!obj) {
            continue;
        }
        const decodedStream = obj.streamBytes
            ? bytesToLatin1(
                  await inflatePdfStream(await decryptPdfStreamBytes(encryption, objectNumber, 0, obj.streamBytes))
              )
            : null;
        packets.push({
            name: match[1],
            objectNumber,
            body: obj.body,
            decodedStream
        });
    }
    return packets;
}

async function literalValue(body, key, encryption, objectNumber) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    const openIdx = body.indexOf('(', keyIdx);
    const hexIdx = body.indexOf('<', keyIdx);
    let bytes = null;
    if (hexIdx > -1 && (openIdx < 0 || hexIdx < openIdx) && body.substring(hexIdx, hexIdx + 2) !== '<<') {
        const closeIdx = body.indexOf('>', hexIdx);
        if (closeIdx < 0) return null;
        bytes = parsePdfHexBytes(body.substring(hexIdx + 1, closeIdx));
    } else if (openIdx > -1) {
        bytes = parsePdfLiteralBytes(body, openIdx);
    }
    if (!bytes) return null;
    return decodePdfStringBytes(await decryptPdfStringBytes(encryption, objectNumber, 0, bytes));
}

function findPdfKey(body, key, fromIndex = 0) {
    const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp(escaped + '(?=[\\s(<\\[/])', 'g');
    re.lastIndex = fromIndex;
    const match = re.exec(body || '');
    return match ? match.index : -1;
}

function decodePdfHexString(hex) {
    return decodePdfStringBytes(parsePdfHexBytes(hex));
}

function decodePdfStringBytes(bytes) {
    if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
        let out = '';
        for (let i = 2; i + 1 < bytes.length; i += 2) {
            out += String.fromCharCode((bytes[i] << 8) | bytes[i + 1]);
        }
        return out;
    }
    return String.fromCharCode.apply(null, bytes);
}

function escapePdfString(value) {
    return String(value ?? '')
        .replace(/\\/g, '\\\\')
        .replace(/\(/g, '\\(')
        .replace(/\)/g, '\\)')
        .replace(/\r/g, '\\r')
        .replace(/\n/g, '\\n');
}

async function normalizeEncryptedPdfStrings(body, encryption, objectNumber) {
    if (!encryption || !body) {
        return body;
    }
    let out = '';
    let i = 0;
    while (i < body.length) {
        const ch = body[i];
        const pair = body.substring(i, i + 2);
        if (pair === '<<' || pair === '>>') {
            out += pair;
            i += 2;
        } else if (ch === '(') {
            const closeIdx = findLiteralClose(body, i);
            if (closeIdx < 0) {
                out += ch;
                i++;
                continue;
            }
            const encryptedBytes = parsePdfLiteralBytes(body, i);
            const plainBytes = await decryptPdfStringBytes(encryption, objectNumber, 0, encryptedBytes);
            out += '(' + escapePdfString(decodePdfStringBytes(plainBytes)) + ')';
            i = closeIdx + 1;
        } else if (ch === '<' && body[i + 1] !== '<') {
            const closeIdx = body.indexOf('>', i + 1);
            if (closeIdx < 0) {
                out += ch;
                i++;
                continue;
            }
            const encryptedBytes = parsePdfHexBytes(body.substring(i + 1, closeIdx));
            const plainBytes = await decryptPdfStringBytes(encryption, objectNumber, 0, encryptedBytes);
            out += '(' + escapePdfString(decodePdfStringBytes(plainBytes)) + ')';
            i = closeIdx + 1;
        } else {
            out += ch;
            i++;
        }
    }
    return out;
}

function escapePdfName(value) {
    const safe = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-';
    const textValue = String(value || 'Off');
    let out = '';
    for (let i = 0; i < textValue.length; i++) {
        const ch = textValue[i];
        out += safe.includes(ch) ? ch : '#' + textValue.charCodeAt(i).toString(16).toUpperCase().padStart(2, '0');
    }
    return out || 'Off';
}

function findLiteralClose(text, openIdx) {
    let depth = 1;
    let escaped = false;
    for (let i = openIdx + 1; i < text.length; i++) {
        const ch = text[i];
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === '(') depth++;
        else if (ch === ')') {
            depth--;
            if (depth === 0) return i;
        }
    }
    return -1;
}

function findDictionaryClose(text, openIdx) {
    let depth = 0;
    let inLiteral = false;
    let escaped = false;
    for (let i = openIdx; i < text.length - 1; i++) {
        const ch = text[i];
        if (inLiteral) {
            if (escaped) escaped = false;
            else if (ch === '\\') escaped = true;
            else if (ch === ')') inLiteral = false;
            continue;
        }
        if (ch === '(') {
            inLiteral = true;
            continue;
        }
        const pair = text.substring(i, i + 2);
        if (pair === '<<') {
            depth++;
            i++;
        } else if (pair === '>>') {
            depth--;
            i++;
            if (depth === 0) {
                return i + 1;
            }
        }
    }
    return -1;
}

function findArrayClose(text, openIdx) {
    let depth = 0;
    let dictDepth = 0;
    let inLiteral = false;
    let escaped = false;
    for (let i = openIdx; i < text.length; i++) {
        const ch = text[i];
        if (inLiteral) {
            if (escaped) escaped = false;
            else if (ch === '\\') escaped = true;
            else if (ch === ')') inLiteral = false;
            continue;
        }
        const pair = text.substring(i, i + 2);
        if (ch === '(') {
            inLiteral = true;
        } else if (pair === '<<') {
            dictDepth++;
            i++;
        } else if (pair === '>>') {
            dictDepth = Math.max(0, dictDepth - 1);
            i++;
        } else if (!dictDepth && ch === '[') {
            depth++;
        } else if (!dictDepth && ch === ']') {
            depth--;
            if (depth === 0) {
                return i + 1;
            }
        }
    }
    return -1;
}

function replaceLiteralValue(body, key, literal) {
    const keyIdx = body.indexOf(key);
    if (keyIdx < 0) return body;
    const openIdx = body.indexOf('(', keyIdx);
    if (openIdx < 0) return body;
    const closeIdx = findLiteralClose(body, openIdx);
    return closeIdx < 0 ? body : body.substring(0, openIdx) + literal + body.substring(closeIdx + 1);
}

function replaceNameValue(body, key, nameValue) {
    return (body || '').replace(
        new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*/[A-Za-z0-9_.-]+'),
        key + ' ' + nameValue
    );
}

function withNeedAppearances(body) {
    if ((body || '').includes('/NeedAppearances')) {
        return body.replace(/\/NeedAppearances\s+(true|false)/, '/NeedAppearances true');
    }
    const idx = (body || '').lastIndexOf('>>');
    return idx < 0 ? body : body.substring(0, idx) + ' /NeedAppearances true ' + body.substring(idx);
}

function withButtonValue(body, value) {
    let nameValue = value ? String(value) : 'Off';
    if (!nameValue.startsWith('/')) {
        nameValue = '/' + escapePdfName(nameValue);
    }
    let updated = removePdfKeyValue(
        removePdfKeyValue(removePdfKeyValue(removePdfKeyValue(body, '/V'), '/DV'), '/AS'),
        '/AP'
    );
    let idx = updated.lastIndexOf('>>');
    if (idx < 0) return updated;
    return updated.substring(0, idx) + ' /V ' + nameValue + ' /AS ' + nameValue + ' ' + updated.substring(idx);
}

function withFieldValue(body, value, fieldType) {
    if (fieldType === 'Btn') {
        return withButtonValue(body, value);
    }
    const literal = '(' + escapePdfString(value) + ')';
    const updated = removePdfKeyValue(removePdfKeyValue(removePdfKeyValue(body, '/V'), '/DV'), '/AP');
    const idx = (updated || '').lastIndexOf('>>');
    return idx < 0 ? updated : updated.substring(0, idx) + ' /V ' + literal + ' ' + updated.substring(idx);
}

function withoutCatalogPerms(body) {
    return (body || '').replace(/\/Perms\s+\d+\s+0\s+R/g, '');
}

function withoutCatalogBaggage(body) {
    let out = withoutCatalogPerms(body || '');
    ['/Metadata', '/Outlines', '/StructTreeRoot', '/MarkInfo'].forEach((key) => {
        out = removePdfKeyValue(out, key);
    });
    return out;
}

function skipPdfWhitespace(body, index) {
    let i = index;
    while (i < body.length && /\s/.test(body[i])) {
        i++;
    }
    return i;
}

function findPdfValueEnd(body, valueStart) {
    const i = skipPdfWhitespace(body, valueStart);
    const ch = body[i];
    if (!ch) {
        return i;
    }
    if (ch === '(') {
        const closeIdx = findLiteralClose(body, i);
        return closeIdx < 0 ? i + 1 : closeIdx + 1;
    }
    if (ch === '<' && body[i + 1] !== '<') {
        const closeIdx = body.indexOf('>', i + 1);
        return closeIdx < 0 ? i + 1 : closeIdx + 1;
    }
    if (ch === '<' && body[i + 1] === '<') {
        const closeIdx = findDictionaryClose(body, i);
        return closeIdx < 0 ? i + 2 : closeIdx;
    }
    if (ch === '[') {
        const closeIdx = findArrayClose(body, i);
        return closeIdx < 0 ? i + 1 : closeIdx;
    }
    if (ch === '/') {
        const match = /^\/[^\s<>\[\]()\/]+/.exec(body.substring(i));
        return i + (match ? match[0].length : 1);
    }
    const refMatch = /^\d+\s+\d+\s+R\b/.exec(body.substring(i));
    if (refMatch) {
        return i + refMatch[0].length;
    }
    const scalarMatch = /^[^\s<>\[\]()\/]+/.exec(body.substring(i));
    return i + (scalarMatch ? scalarMatch[0].length : 1);
}

function removePdfKeyValue(body, key) {
    let out = body || '';
    let keyIdx = findPdfKey(out, key);
    while (keyIdx >= 0) {
        const valueEnd = findPdfValueEnd(out, keyIdx + key.length);
        out = out.substring(0, keyIdx) + out.substring(valueEnd);
        keyIdx = findPdfKey(out, key, keyIdx);
    }
    return out;
}

function stripPdfFieldValueEntries(body) {
    return stripPdfAppearanceEntries(removePdfKeyValue(removePdfKeyValue(body, '/V'), '/DV'));
}

function stripPdfAppearanceEntries(body) {
    return removePdfKeyValue(body, '/AP');
}

function withWidgetAppearanceState(body, value) {
    let nameValue = value ? String(value) : 'Off';
    if (!nameValue.startsWith('/')) {
        nameValue = '/' + escapePdfName(nameValue);
    }
    const updated = removePdfKeyValue(removePdfKeyValue(body, '/AS'), '/AP');
    const idx = (updated || '').lastIndexOf('>>');
    return idx < 0 ? updated : updated.substring(0, idx) + ' /AS ' + nameValue + ' ' + updated.substring(idx);
}

function extractLiteralString(body, key) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    const openIdx = body.indexOf('(', keyIdx);
    if (openIdx < 0) return null;
    const closeIdx = findLiteralClose(body, openIdx);
    return closeIdx < 0 ? null : body.substring(openIdx + 1, closeIdx);
}

function decimalToPdf(value) {
    let out = Number(value || 0).toFixed(3);
    while (out.includes('.') && out.endsWith('0')) {
        out = out.slice(0, -1);
    }
    return out.endsWith('.') ? out.slice(0, -1) : out;
}

function buildTextAppearanceBody(fieldBody, value, acroFormBody) {
    if (!fieldBody || value == null) return null;
    const rect = numsIn(extractArray(fieldBody, '/Rect')).slice(0, 4);
    if (rect.length !== 4) return null;
    const width = rect[2] - rect[0];
    const height = rect[3] - rect[1];
    if (width <= 0 || height <= 0) return null;
    const da = extractLiteralString(fieldBody, '/DA') || extractLiteralString(acroFormBody || '', '/DA') || '';
    const fontMatch = /\/[A-Za-z0-9_.-]+\s+[0-9.]+\s+Tf/.exec(da);
    const fontParts = fontMatch ? fontMatch[0].split(/\s+/) : ['/Helv', '9', 'Tf'];
    const fontName = fontParts[0] || '/Helv';
    const fontSize = Number(fontParts[1] || 9);
    const fontResources = extractDictionary(acroFormBody || '', '/Font');
    const resources = fontResources ? '/Resources<</Font<<' + fontResources + '>>>>' : '';
    const textY = Math.max(1, (height - fontSize) / 2 + 1);
    const content =
        'q BT ' +
        fontName +
        ' ' +
        fontSize +
        ' Tf 0 g 2 ' +
        decimalToPdf(textY) +
        ' Td (' +
        escapePdfString(String(value)) +
        ') Tj ET Q';
    return (
        '<</Type/XObject/Subtype/Form/FormType 1/BBox[0 0 ' +
        decimalToPdf(width) +
        ' ' +
        decimalToPdf(height) +
        ']/Matrix[1 0 0 1 0 0]' +
        resources +
        '/Length ' +
        latin1ToBytes(content).length +
        '>>stream\n' +
        content +
        '\nendstream'
    );
}

function withNormalAppearance(body, appearanceObjectNumber) {
    const updated = removePdfKeyValue(body, '/AP');
    const idx = (updated || '').lastIndexOf('>>');
    return idx < 0
        ? updated
        : updated.substring(0, idx) + ' /AP <</N ' + appearanceObjectNumber + ' 0 R>> ' + updated.substring(idx);
}

function resolveValue(data, path) {
    if (!data || !path) return null;
    let current = data;
    for (const segment of String(path).split('.')) {
        if (current == null || typeof current !== 'object') return null;
        const key = Object.keys(current).find((candidate) => candidate.toLowerCase() === segment.toLowerCase());
        current = key ? current[key] : null;
    }
    return current;
}

function isTruthy(value) {
    if (value === true) return true;
    if (typeof value === 'number') return value !== 0;
    return ['true', 'yes', 'y', '1', 'on'].includes(
        String(value ?? '')
            .trim()
            .toLowerCase()
    );
}

function formatPdfValue(value, fieldType, buttonOnValue) {
    if (fieldType === 'Btn') {
        return isTruthy(value) ? buttonOnValue || 'Yes' : 'Off';
    }
    return value == null ? '' : String(value);
}

function fixedWidthHex(value, byteCount) {
    let remaining = value || 0;
    const bytes = [];
    for (let i = 0; i < byteCount; i++) {
        bytes.unshift(remaining & 0xff);
        remaining = Math.floor(remaining / 256);
    }
    return bytes;
}

function buildXrefIndex(nums) {
    let index = '';
    let i = 0;
    while (i < nums.length) {
        const start = nums[i];
        let count = 1;
        i++;
        while (i < nums.length && nums[i] === start + count) {
            count++;
            i++;
        }
        index += (index ? ' ' : '') + start + ' ' + count;
    }
    return index;
}

function parsePreviousStartXref(text) {
    const idx = text.lastIndexOf('startxref');
    if (idx < 0) throw new Error('PDF startxref marker not found.');
    const match = /startxref\s+(\d+)/.exec(text.substring(idx));
    if (!match) throw new Error('PDF startxref offset not found.');
    return Number(match[1]);
}

function serializeClassicXref(originalBytes, appendText, offsets, updatedNums, rootNum, size, prevStartXref) {
    const appendBytes = latin1ToBytes(appendText);
    const xrefStart = originalBytes.length + appendBytes.length;

    let xref = 'xref\n';
    let i = 0;
    while (i < updatedNums.length) {
        const start = updatedNums[i];
        const run = [start];
        i++;
        while (i < updatedNums.length && updatedNums[i] === run[run.length - 1] + 1) {
            run.push(updatedNums[i]);
            i++;
        }
        xref += start + ' ' + run.length + '\n';
        run.forEach((num) => {
            xref += String(offsets.get(num)).padStart(10, '0') + ' 00000 n \n';
        });
    }
    xref +=
        'trailer\n<< /Size ' +
        size +
        ' /Root ' +
        rootNum +
        ' 0 R /Prev ' +
        prevStartXref +
        ' >>\nstartxref\n' +
        xrefStart +
        '\n%%EOF\n';
    return concatBytes([originalBytes, appendBytes, latin1ToBytes(xref)]);
}

function serializeXrefStream(originalBytes, appendText, offsets, updatedNums, rootNum, size, prevStartXref) {
    const appendBytes = latin1ToBytes(appendText);
    const xrefStart = originalBytes.length + appendBytes.length;
    const xrefObjNum = size;
    offsets.set(xrefObjNum, xrefStart);
    const xrefNums = Array.from(new Set([...updatedNums, xrefObjNum])).sort((a, b) => a - b);
    const streamBytes = [];
    xrefNums.forEach((num) => {
        streamBytes.push(1, ...fixedWidthHex(offsets.get(num), 4), 0, 0);
    });
    const header =
        xrefObjNum +
        ' 0 obj\n<< /Type /XRef /Size ' +
        (size + 1) +
        ' /Root ' +
        rootNum +
        ' 0 R /Prev ' +
        prevStartXref +
        ' /W [1 4 2] /Index [' +
        buildXrefIndex(xrefNums) +
        '] /Length ' +
        streamBytes.length +
        ' >>\nstream\n';
    const footer = '\nendstream\nendobj\nstartxref\n' + xrefStart + '\n%%EOF\n';
    return concatBytes([
        originalBytes,
        appendBytes,
        latin1ToBytes(header),
        new Uint8Array(streamBytes),
        latin1ToBytes(footer)
    ]);
}

function replacePdfLength(dict, length) {
    if (/\/Length\s+\d+/.test(dict || '')) {
        return dict.replace(/\/Length\s+\d+/, '/Length ' + length);
    }
    const idx = (dict || '').lastIndexOf('>>');
    return idx < 0 ? dict : dict.substring(0, idx) + ' /Length ' + length + ' ' + dict.substring(idx);
}

function isSkippableNormalizedObject(obj, encryption) {
    if (!obj) return true;
    if (encryption && obj.objectNumber === encryption.encryptObjectNumber) return true;
    const body = obj.body || '';
    return body.includes('/ObjStm') || body.includes('/Type /XRef') || body.includes('/Type/XRef');
}

function collectReachableObjectNumbers(objects, rootObjectNumber, bodyOverrides = new Map()) {
    const reachable = new Set();
    const stack = [rootObjectNumber];
    while (stack.length) {
        const objectNumber = stack.pop();
        if (reachable.has(objectNumber)) {
            continue;
        }
        const obj = objects.get(objectNumber);
        if (!obj) {
            continue;
        }
        reachable.add(objectNumber);
        refsIn(bodyOverrides.has(objectNumber) ? bodyOverrides.get(objectNumber) : obj.body).forEach((ref) => {
            if (!reachable.has(ref)) {
                stack.push(ref);
            }
        });
    }
    return reachable;
}

async function normalizePdfBytes(objects, encryption, rootObjectNumber, fieldObjectNumbers = new Set()) {
    const rootObject = objects.get(rootObjectNumber);
    const rootBody = withoutCatalogBaggage(rootObject ? rootObject.body || '' : '');
    const bodyOverrides = new Map([[rootObjectNumber, rootBody]]);
    fieldObjectNumbers.forEach((objectNumber) => {
        const obj = objects.get(objectNumber);
        if (obj && obj.body) {
            bodyOverrides.set(objectNumber, stripPdfFieldValueEntries(obj.body));
        }
    });
    const reachableObjects = collectReachableObjectNumbers(objects, rootObjectNumber, bodyOverrides);
    const objectNumbers = Array.from(reachableObjects)
        .filter((num) => !isSkippableNormalizedObject(objects.get(num), encryption))
        .sort((a, b) => a - b);
    const size = Math.max(...objectNumbers, rootObjectNumber) + 1;
    const offsets = new Map();
    const parts = [latin1ToBytes('%PDF-1.7\n')];
    let offset = parts[0].length;

    for (const objectNumber of objectNumbers) {
        const obj = objects.get(objectNumber);
        offsets.set(objectNumber, offset);
        let body = objectNumber === rootObjectNumber ? rootBody : obj.body || '';
        if (encryption && !obj.fromObjectStream) {
            body = await normalizeEncryptedPdfStrings(body, encryption, objectNumber);
        }
        if (fieldObjectNumbers.has(objectNumber)) {
            body = stripPdfFieldValueEntries(body);
        }
        let objectBytes;
        if (obj.streamBytes) {
            const streamIdx = body.indexOf('stream');
            const dict = replacePdfLength((streamIdx > -1 ? body.substring(0, streamIdx) : body).trim(), 0);
            let streamBytes = obj.streamBytes;
            try {
                streamBytes = await decryptPdfStreamBytes(encryption, objectNumber, 0, obj.streamBytes);
            } catch (e) {
                streamBytes = obj.streamBytes;
            }
            const updatedDict = replacePdfLength(dict, streamBytes.length);
            objectBytes = concatBytes([
                latin1ToBytes(objectNumber + ' 0 obj\n' + updatedDict + '\nstream\n'),
                streamBytes,
                latin1ToBytes('\nendstream\nendobj\n')
            ]);
        } else {
            objectBytes = latin1ToBytes(objectNumber + ' 0 obj\n' + body.trim() + '\nendobj\n');
        }
        parts.push(objectBytes);
        offset += objectBytes.length;
    }

    const xrefOffset = offset;
    let xref = 'xref\n0 ' + size + '\n0000000000 65535 f \n';
    for (let i = 1; i < size; i++) {
        const objOffset = offsets.get(i);
        xref += objOffset == null ? '0000000000 65535 f \n' : String(objOffset).padStart(10, '0') + ' 00000 n \n';
    }
    xref +=
        'trailer\n<< /Size ' + size + ' /Root ' + rootObjectNumber + ' 0 R >>\nstartxref\n' + xrefOffset + '\n%%EOF\n';
    parts.push(latin1ToBytes(xref));
    return concatBytes(parts);
}

async function decodeObjectStreams(objects, encryption) {
    for (const obj of Array.from(objects.values())) {
        if (!obj.body.includes('/ObjStm') || !obj.streamBytes) {
            continue;
        }
        const first = numFrom('/First\\s+(\\d+)', obj.body);
        const count = numFrom('/N\\s+(\\d+)', obj.body);
        if (first == null || count == null) {
            continue;
        }
        const streamBytes = await decryptPdfStreamBytes(encryption, obj.objectNumber, 0, obj.streamBytes);
        const decoded = bytesToLatin1(await inflatePdfStream(streamBytes));
        const header = decoded.substring(0, first).trim();
        const parts = header.split(/\s+/).map((part) => Number(part));
        for (let i = 0; i < count; i++) {
            const objectNumber = parts[i * 2];
            const offset = parts[i * 2 + 1];
            const nextOffset = i + 1 < count ? parts[(i + 1) * 2 + 1] : decoded.length - first;
            if (!Number.isFinite(objectNumber) || !Number.isFinite(offset)) {
                continue;
            }
            const existing = objects.get(objectNumber);
            if (existing && !existing.fromObjectStream) {
                continue;
            }
            objects.set(objectNumber, {
                objectNumber,
                body: '\n' + decoded.substring(first + offset, first + nextOffset).trim() + '\n',
                streamBytes: null,
                fromObjectStream: obj.objectNumber
            });
        }
    }
}

function directPdfNameValue(body, key) {
    return (body.match(new RegExp(key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*/([A-Za-z]+)')) || [])[1] || '';
}

function mergeFieldBodies(parentBody, childBody) {
    const child = childBody || '';
    const parent = parentBody || '';
    const insertIdx = child.lastIndexOf('>>');
    if (!parent || insertIdx < 0) {
        return child || parent;
    }
    const inherited = [];
    ['/FT', '/Ff', '/TU', '/Q', '/DA', '/DR'].forEach((key) => {
        if (findPdfKey(child, key) < 0 && findPdfKey(parent, key) >= 0) {
            const keyIdx = findPdfKey(parent, key);
            const valueEnd = findPdfValueEnd(parent, keyIdx + key.length);
            inherited.push(parent.substring(keyIdx, valueEnd));
        }
    });
    return inherited.length
        ? child.substring(0, insertIdx) + ' ' + inherited.join(' ') + ' ' + child.substring(insertIdx)
        : child;
}

function buildCollectedField({
    fieldNumber,
    widgetObjectNumber,
    valueObjectNumber,
    name,
    partialName,
    fieldType,
    normalizedBody,
    valueBody,
    objects,
    locations
}) {
    const buttonValues =
        fieldType === 'Btn' ? extractButtonOnValuesFromObjects(normalizedBody || valueBody, objects) : [];
    const fallbackRect = rectFromBody(normalizedBody || valueBody);
    const location = locations.get(widgetObjectNumber) ||
        locations.get(fieldNumber) || {
            rect: fallbackRect,
            mediaBox: pageMediaBox(''),
            locationLabel: fallbackRect ? fieldLocationLabel(fallbackRect, pageMediaBox('')) : ''
        };
    const estimatedPageNumber = estimatedPageNumberFromFieldName(name);
    const pageNumber = location.pageNumber || estimatedPageNumber || null;
    return {
        objectNumber: fieldNumber,
        widgetObjectNumber,
        valueObjectNumber,
        name,
        partialName: partialName || name,
        fieldType,
        buttonOnValue: buttonValues[0] || 'Yes',
        buttonOnValues: buttonValues,
        widgets: [
            {
                objectNumber: widgetObjectNumber,
                body: normalizedBody,
                exportValue: buttonValues[0] || 'Yes',
                pageNumber,
                rect: location.rect || null,
                mediaBox: location.mediaBox || null,
                locationLabel: location.locationLabel || ''
            }
        ],
        pageNumber,
        estimatedPageNumber: location.pageNumber ? null : estimatedPageNumber,
        rect: location.rect || null,
        mediaBox: location.mediaBox || null,
        locationLabel: location.locationLabel || '',
        body: valueBody,
        widgetBody: normalizedBody
    };
}

async function collectFields(objects, fieldNumber, parentName, visited, fields, encryption, locations, inherited = {}) {
    if (visited.has(fieldNumber)) return;
    visited.add(fieldNumber);
    const obj = objects.get(fieldNumber);
    if (!obj) return;
    const partial = await literalValue(obj.body, '/T', obj.fromObjectStream ? null : encryption, fieldNumber);
    const name = partial ? (parentName ? parentName + '.' + partial : partial) : parentName;
    const directFieldType = directPdfNameValue(obj.body, '/FT');
    const fieldType = directFieldType || inherited.fieldType || '';
    const normalizedBody = obj.fromObjectStream
        ? obj.body
        : await normalizeEncryptedPdfStrings(obj.body, encryption, fieldNumber);
    const inheritedBody = mergeFieldBodies(inherited.body, normalizedBody);
    const valueObjectNumber = directFieldType ? fieldNumber : inherited.valueObjectNumber || fieldNumber;
    const valueBody = directFieldType ? normalizedBody : inherited.valueBody || normalizedBody;
    const kids = refsIn(extractArray(obj.body, '/Kids'));
    if (kids.length) {
        for (const kid of kids) {
            await collectFields(objects, kid, name, visited, fields, encryption, locations, {
                fieldType,
                body: inheritedBody,
                valueObjectNumber,
                valueBody
            });
        }
        return;
    }
    if (!name) return;
    fields.push(
        buildCollectedField({
            fieldNumber,
            widgetObjectNumber: fieldNumber,
            valueObjectNumber,
            name,
            partialName: partial || name,
            fieldType,
            normalizedBody,
            valueBody,
            objects,
            locations
        })
    );
}

async function collectStandaloneWidgetFields(objects, fields, encryption, locations) {
    const existingWidgetNumbers = new Set(
        fields.map((field) => Number(field.widgetObjectNumber || field.objectNumber))
    );
    for (const [objectNumber, obj] of objects.entries()) {
        if (!obj || existingWidgetNumbers.has(objectNumber) || directName(obj.body, '/Subtype') !== 'Widget') {
            continue;
        }
        const partial = await literalValue(obj.body, '/T', obj.fromObjectStream ? null : encryption, objectNumber);
        const fieldType = directPdfNameValue(obj.body, '/FT');
        if (!partial || !fieldType) {
            continue;
        }
        const normalizedBody = obj.fromObjectStream
            ? obj.body
            : await normalizeEncryptedPdfStrings(obj.body, encryption, objectNumber);
        fields.push(
            buildCollectedField({
                fieldNumber: objectNumber,
                widgetObjectNumber: objectNumber,
                valueObjectNumber: objectNumber,
                name: partial,
                partialName: partial,
                fieldType,
                normalizedBody,
                valueBody: normalizedBody,
                objects,
                locations
            })
        );
        existingWidgetNumbers.add(objectNumber);
    }
}

function fieldDedupeKey(field) {
    const rect = (field && field.rect) || [];
    const rectKey = rect.length >= 4 ? rect.map((value) => Number(value || 0).toFixed(3)).join(',') : '';
    return [field.fieldType || '', field.name || '', field.pageNumber || '', rectKey].join('|');
}

function dedupePdfFields(fields) {
    const byKey = new Map();
    (fields || []).forEach((field) => {
        const key = fieldDedupeKey(field);
        const existing = byKey.get(key);
        if (!existing) {
            byKey.set(key, field);
            return;
        }
        const existingObject = Number(existing.widgetObjectNumber || existing.objectNumber || 0);
        const candidateObject = Number(field.widgetObjectNumber || field.objectNumber || 0);
        if (candidateObject && (!existingObject || candidateObject < existingObject)) {
            byKey.set(key, field);
        }
    });
    return Array.from(byKey.values());
}

function decodePdfNameToken(value) {
    return String(value || '').replace(/#([0-9A-Fa-f]{2})/g, (_match, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function extractButtonOnValuesFromObjects(body, objects) {
    const sources = [];
    const apRef = extractRef(body, '/AP');
    const apObj = apRef == null ? null : objects.get(apRef);
    if (apObj) {
        const normalRef = extractRef(apObj.body, '/N');
        const normalObj = normalRef == null ? null : objects.get(normalRef);
        if (normalObj) {
            sources.push(normalObj.body);
        }
        const normalDictionary = extractDictionary(apObj.body, '/N');
        if (normalDictionary) {
            sources.push(normalDictionary);
        }
    }
    if (!sources.length) {
        sources.push(extractDictionary(body, '/N') || body);
    }
    return extractButtonOnValues(sources.join('\n'));
}

function extractButtonOnValues(body) {
    const values = [];
    const re = /\/([A-Za-z0-9_.#-]+)\b/g;
    let match;
    while ((match = re.exec(body || '')) !== null) {
        const value = match[1];
        if (value === 'Off' || value === 'AP' || value === 'N' || value === 'D' || value === 'R') {
            continue;
        }
        const decoded = decodePdfNameToken(value);
        if (!values.includes(decoded)) {
            values.push(decoded);
        }
    }
    return values;
}

function extractDictionary(body, key) {
    const keyIdx = findPdfKey(body, key);
    if (keyIdx < 0) return null;
    const openIdx = body.indexOf('<<', keyIdx);
    if (openIdx < 0) return null;
    let depth = 0;
    for (let i = openIdx; i < body.length - 1; i++) {
        const pair = body.substring(i, i + 2);
        if (pair === '<<') {
            depth++;
            i++;
        } else if (pair === '>>') {
            depth--;
            i++;
            if (depth === 0) {
                return body.substring(openIdx + 2, i - 1);
            }
        }
    }
    return null;
}

export async function decomposePdfAcroFormBase64(base64) {
    const bytes = base64ToBytes(base64);
    const text = bytesToLatin1(bytes);
    if (!text.startsWith('%PDF-')) {
        throw new Error('The uploaded file is not a PDF.');
    }
    const objects = parseDirectObjects(text, bytes);
    const encryption = parseEncryptionContext(text, objects);
    await decodeObjectStreams(objects, encryption);

    const rootObjectNumber = numFrom('/Root\\s+(\\d+)\\s+0\\s+R', text);
    const root = objects.get(rootObjectNumber);
    if (!root) {
        throw new Error('PDF root catalog could not be read.');
    }
    const acroFormObjectNumber = extractRef(root.body, '/AcroForm');
    const acroForm = objects.get(acroFormObjectNumber);
    if (!acroForm) {
        throw new Error('PDF AcroForm dictionary could not be read.');
    }
    const topFields = refsIn(extractArray(acroForm.body, '/Fields'));
    const locations = collectAnnotationLocations(objects, root.body);
    const fields = [];
    for (const fieldNumber of topFields) {
        await collectFields(objects, fieldNumber, '', new Set(), fields, encryption, locations);
    }
    await collectStandaloneWidgetFields(objects, fields, encryption, locations);
    const dedupedFields = dedupePdfFields(fields);
    dedupedFields.sort((a, b) => a.name.localeCompare(b.name));
    const fieldObjectNumbers = new Set();
    dedupedFields.forEach((field) => {
        [field.objectNumber, field.valueObjectNumber, field.widgetObjectNumber].forEach((fieldNumber) => {
            const parsed = Number(fieldNumber);
            if (Number.isFinite(parsed)) {
                fieldObjectNumbers.add(parsed);
            }
        });
    });

    const xfaPackets = await extractXfaPackets(objects, acroForm.body, encryption);
    const hasObjectStreamFields = Array.from(fieldObjectNumbers).some((fieldNumber) => {
        const obj = objects.get(fieldNumber);
        return obj && obj.fromObjectStream;
    });
    const shouldNormalizePdf = Boolean(encryption) || hasObjectStreamFields;
    const normalizedPdfBase64 = shouldNormalizePdf
        ? bytesToBase64Local(await normalizePdfBytes(objects, encryption, rootObjectNumber, fieldObjectNumbers))
        : null;

    return {
        version: 1,
        normalizedPdfBase64,
        requiresNormalizedPdf: shouldNormalizePdf,
        rootObjectNumber,
        rootBody: root.body,
        acroFormObjectNumber,
        acroFormBody: acroForm.body,
        size: Math.max(numFrom('/Size\\s+(\\d+)', text, 0), Math.max(...Array.from(objects.keys())) + 1),
        hasXfa: acroForm.body.includes('/XFA'),
        xfaPackets,
        fields: dedupedFields
    };
}

export function fillPdfAcroFormBase64(base64, snapshot, data) {
    const originalBytes = base64ToBytes(base64);
    const text = bytesToLatin1(originalBytes);
    const fields = (snapshot && snapshot.fields) || [];
    const fieldValues = new Map();
    const fieldBodies = new Map();
    const fieldTypes = new Map();
    const widgetUpdates = new Map();

    fields.forEach((field) => {
        const objectNumber = Number(field.valueObjectNumber || field.objectNumber);
        if (!objectNumber || !field.body) return;
        fieldBodies.set(objectNumber, field.body);
        fieldTypes.set(objectNumber, field.fieldType || '');
        const mappedPath = field.mappedPath;
        if (!mappedPath) {
            return;
        }
        const value = resolveValue(data, mappedPath);
        if (value != null) {
            const formattedValue = formatPdfValue(value, field.fieldType || '', field.buttonOnValue || 'Yes');
            fieldValues.set(objectNumber, formattedValue);
            const widgetObjectNumber = Number(field.widgetObjectNumber || field.objectNumber);
            if (
                field.fieldType !== 'Btn' &&
                widgetObjectNumber &&
                widgetObjectNumber !== objectNumber &&
                field.widgetBody
            ) {
                widgetUpdates.set(widgetObjectNumber, {
                    body: field.widgetBody,
                    fieldType: field.fieldType || '',
                    value: formattedValue
                });
            }
            if (field.fieldType === 'Btn') {
                const widgets = Array.isArray(field.widgets) && field.widgets.length ? field.widgets : [];
                if (!widgets.length && widgetObjectNumber && field.widgetBody) {
                    widgets.push({
                        objectNumber: widgetObjectNumber,
                        body: field.widgetBody,
                        exportValue: field.buttonOnValue || 'Yes'
                    });
                }
                widgets.forEach((widget) => {
                    const widgetNum = Number(widget.objectNumber);
                    if (!widgetNum || !widget.body) return;
                    const exportValue = widget.exportValue || field.buttonOnValue || 'Yes';
                    widgetUpdates.set(widgetNum, {
                        body: widget.body,
                        fieldType: 'Btn',
                        value: formattedValue === 'Off' || formattedValue !== exportValue ? 'Off' : exportValue
                    });
                });
            }
        }
    });

    if (!fieldValues.size) {
        return base64;
    }

    const acroFormNum = Number(snapshot.acroFormObjectNumber);
    const rootNum = Number(snapshot.rootObjectNumber);
    const size = Math.max(
        Number(snapshot.size || 0),
        Math.max(...Array.from(new Set([...fieldBodies.keys(), ...widgetUpdates.keys()])), acroFormNum, rootNum) + 2
    );
    const prevStartXref = parsePreviousStartXref(text);
    const appearanceRefs = new Map();
    const appearanceBodies = new Map();
    let nextAppearanceObjectNumber = size;
    fieldValues.forEach((value, objNum) => {
        if (fieldTypes.get(objNum) === 'Btn' || widgetUpdates.has(objNum)) return;
        const appearanceBody = buildTextAppearanceBody(fieldBodies.get(objNum), value, snapshot.acroFormBody || '');
        if (!appearanceBody) return;
        appearanceRefs.set(objNum, nextAppearanceObjectNumber);
        appearanceBodies.set(nextAppearanceObjectNumber, appearanceBody);
        nextAppearanceObjectNumber += 1;
    });
    widgetUpdates.forEach((update, objNum) => {
        if (update.fieldType === 'Btn') return;
        const appearanceBody = buildTextAppearanceBody(update.body, update.value, snapshot.acroFormBody || '');
        if (!appearanceBody) return;
        appearanceRefs.set(objNum, nextAppearanceObjectNumber);
        appearanceBodies.set(nextAppearanceObjectNumber, appearanceBody);
        nextAppearanceObjectNumber += 1;
    });
    const updatedNumSet = new Set([
        ...fieldValues.keys(),
        ...widgetUpdates.keys(),
        ...appearanceBodies.keys(),
        acroFormNum
    ]);
    const updatedRootBody = withoutCatalogPerms(snapshot.rootBody || '');
    if (updatedRootBody && updatedRootBody !== snapshot.rootBody) {
        updatedNumSet.add(rootNum);
    }
    const updatedNums = Array.from(updatedNumSet).sort((a, b) => a - b);
    const updatedSize = Math.max(size, ...updatedNums) + 1;

    let appendText = '\n';
    let offset = originalBytes.length + latin1ToBytes(appendText).length;
    const offsets = new Map();
    updatedNums.forEach((objNum) => {
        offsets.set(objNum, offset);
        let body;
        if (objNum === rootNum) {
            body = updatedRootBody;
        } else if (objNum === acroFormNum) {
            body = withNeedAppearances(snapshot.acroFormBody || '');
        } else if (appearanceBodies.has(objNum)) {
            body = appearanceBodies.get(objNum);
        } else if (widgetUpdates.has(objNum)) {
            const update = widgetUpdates.get(objNum);
            body = update.body;
            if (fieldValues.has(objNum)) {
                body = withFieldValue(body, fieldValues.get(objNum), fieldTypes.get(objNum));
            }
            body =
                update.fieldType === 'Btn'
                    ? withWidgetAppearanceState(body, update.value)
                    : stripPdfAppearanceEntries(body);
            if (appearanceRefs.has(objNum)) {
                body = withNormalAppearance(body, appearanceRefs.get(objNum));
            }
        } else {
            body = withFieldValue(fieldBodies.get(objNum), fieldValues.get(objNum), fieldTypes.get(objNum));
            if (appearanceRefs.has(objNum)) {
                body = withNormalAppearance(body, appearanceRefs.get(objNum));
            }
        }
        const serialized = objNum + ' 0 obj\n' + body + '\nendobj\n';
        appendText += serialized;
        offset += latin1ToBytes(serialized).length;
    });

    return bytesToBase64Local(
        text.includes('/Type/XRef') || text.includes('/Type /XRef')
            ? serializeXrefStream(originalBytes, appendText, offsets, updatedNums, rootNum, updatedSize, prevStartXref)
            : serializeClassicXref(originalBytes, appendText, offsets, updatedNums, rootNum, updatedSize, prevStartXref)
    );
}

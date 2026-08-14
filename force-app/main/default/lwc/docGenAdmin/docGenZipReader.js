/**
 * Pure JavaScript ZIP reader.
 *
 * Zero external dependencies. Reads classic ZIPs (store + deflate) produced by
 * Google Docs, Notion, macOS, Windows, etc. Returns [{ name, data: Uint8Array }, ...].
 *
 * Deflate is decoded by the browser's native DecompressionStream where it is
 * available, and by the inline RFC 1951 decoder below where it is not (#320).
 */

/**
 * Native path. Fast, and what every modern browser will actually use.
 */
async function inflateRawNative(compressed) {
    const cs = new DecompressionStream('deflate-raw');
    const writer = cs.writable.getWriter();
    writer.write(compressed);
    writer.close();
    const reader = cs.readable.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) {
            break;
        }
        chunks.push(value);
        total += value.length;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
        out.set(chunk, offset);
        offset += chunk.length;
    }
    return out;
}

// --- Inline DEFLATE (RFC 1951) ------------------------------------------------
//
// `new DecompressionStream('deflate-raw')` is a browser API, and browser APIs are
// not uniformly available to managed-package code: uploading a zip template
// failed with a decompress error in SOME orgs and not others (#320). A zip whose
// only member is an HTML file is deflated, so there was nothing to fall back on
// and the upload dead-ended.
//
// This is the classic canonical-Huffman decoder (the algorithm zlib's `puff`
// reference implementation uses), kept deliberately small and allocation-light.
// It is only reached when the native API is missing or refuses, so it never
// costs a modern browser anything.

const LENGTH_BASE = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
];
const LENGTH_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
const DIST_BASE = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
    8193, 12289, 16385, 24577
];
const DIST_EXTRA = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
const CODE_LENGTH_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
const MAX_BITS = 15;

/** Canonical Huffman table: symbol counts per code length, plus symbols in code order. */
function buildHuffman(lengths) {
    const count = new Array(MAX_BITS + 1).fill(0);
    for (const len of lengths) {
        if (len) {
            count[len]++;
        }
    }
    const offsets = new Array(MAX_BITS + 2).fill(0);
    for (let len = 1; len <= MAX_BITS; len++) {
        offsets[len + 1] = offsets[len] + count[len];
    }
    const symbols = new Array(lengths.length).fill(0);
    for (let sym = 0; sym < lengths.length; sym++) {
        if (lengths[sym]) {
            symbols[offsets[lengths[sym]]++] = sym;
        }
    }
    return { count, symbols };
}

/**
 * Raw DEFLATE (RFC 1951), no container. Exported so the PDF AcroForm decomposer
 * can reuse it rather than carry a second copy of the same 150 lines (#329).
 */
export function inflateRawJs(compressed) {
    const src = compressed;
    let pos = 0;
    let bitBuf = 0;
    let bitCount = 0;

    const bits = (need) => {
        let val = bitBuf;
        while (bitCount < need) {
            if (pos >= src.length) {
                throw new Error('Truncated deflate stream.');
            }
            val |= src[pos++] << bitCount;
            bitCount += 8;
        }
        bitBuf = val >>> need;
        bitCount -= need;
        return val & ((1 << need) - 1);
    };

    const decodeSymbol = (table) => {
        let code = 0;
        let first = 0;
        let index = 0;
        for (let len = 1; len <= MAX_BITS; len++) {
            code |= bits(1);
            const n = table.count[len];
            if (code - first < n) {
                return table.symbols[index + (code - first)];
            }
            index += n;
            first = (first + n) << 1;
            code <<= 1;
        }
        throw new Error('Invalid Huffman code in deflate stream.');
    };

    let out = new Uint8Array(Math.max(1024, src.length * 4));
    let outLen = 0;
    const push = (byte) => {
        if (outLen === out.length) {
            const grown = new Uint8Array(out.length * 2);
            grown.set(out);
            out = grown;
        }
        out[outLen++] = byte;
    };

    let fixedLit = null;
    let fixedDist = null;
    const fixedTables = () => {
        if (!fixedLit) {
            const litLengths = new Array(288);
            for (let i = 0; i < 288; i++) {
                litLengths[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
            }
            fixedLit = buildHuffman(litLengths);
            fixedDist = buildHuffman(new Array(30).fill(5));
        }
        return [fixedLit, fixedDist];
    };

    for (;;) {
        const isFinal = bits(1);
        const type = bits(2);

        if (type === 0) {
            // Stored: discard the partial byte, then LEN/NLEN and raw bytes.
            bitBuf = 0;
            bitCount = 0;
            if (pos + 4 > src.length) {
                throw new Error('Truncated stored block in deflate stream.');
            }
            const len = src[pos] | (src[pos + 1] << 8);
            pos += 4; // LEN then its one's complement, which we do not need to verify
            if (pos + len > src.length) {
                throw new Error('Truncated stored block in deflate stream.');
            }
            for (let i = 0; i < len; i++) {
                push(src[pos++]);
            }
        } else if (type === 1 || type === 2) {
            let litTable;
            let distTable;
            if (type === 1) {
                [litTable, distTable] = fixedTables();
            } else {
                const hlit = bits(5) + 257;
                const hdist = bits(5) + 1;
                const hclen = bits(4) + 4;
                const clLengths = new Array(19).fill(0);
                for (let i = 0; i < hclen; i++) {
                    clLengths[CODE_LENGTH_ORDER[i]] = bits(3);
                }
                const clTable = buildHuffman(clLengths);
                const lengths = new Array(hlit + hdist).fill(0);
                let i = 0;
                while (i < lengths.length) {
                    const sym = decodeSymbol(clTable);
                    if (sym < 16) {
                        lengths[i++] = sym;
                    } else if (sym === 16) {
                        if (i === 0) {
                            throw new Error('Invalid code-length repeat in deflate stream.');
                        }
                        const prev = lengths[i - 1];
                        let repeat = 3 + bits(2);
                        while (repeat-- > 0 && i < lengths.length) {
                            lengths[i++] = prev;
                        }
                    } else if (sym === 17) {
                        let repeat = 3 + bits(3);
                        while (repeat-- > 0 && i < lengths.length) {
                            lengths[i++] = 0;
                        }
                    } else {
                        let repeat = 11 + bits(7);
                        while (repeat-- > 0 && i < lengths.length) {
                            lengths[i++] = 0;
                        }
                    }
                }
                litTable = buildHuffman(lengths.slice(0, hlit));
                distTable = buildHuffman(lengths.slice(hlit));
            }

            for (;;) {
                const sym = decodeSymbol(litTable);
                if (sym < 256) {
                    push(sym);
                } else if (sym === 256) {
                    break;
                } else {
                    const li = sym - 257;
                    if (li >= LENGTH_BASE.length) {
                        throw new Error('Invalid length symbol in deflate stream.');
                    }
                    const length = LENGTH_BASE[li] + bits(LENGTH_EXTRA[li]);
                    const di = decodeSymbol(distTable);
                    if (di >= DIST_BASE.length) {
                        throw new Error('Invalid distance symbol in deflate stream.');
                    }
                    const distance = DIST_BASE[di] + bits(DIST_EXTRA[di]);
                    if (distance > outLen) {
                        throw new Error('Distance beyond output start in deflate stream.');
                    }
                    let from = outLen - distance;
                    for (let i = 0; i < length; i++) {
                        push(out[from++]);
                    }
                }
            }
        } else {
            throw new Error('Reserved deflate block type.');
        }

        if (isFinal) {
            break;
        }
    }
    return out.subarray(0, outLen);
}

/** Cached because the answer cannot change within a page. */
let nativeInflateAvailable = null;
function hasNativeInflate() {
    if (nativeInflateAvailable === null) {
        try {
            // Constructing it is the only reliable probe: the constructor may
            // exist but reject 'deflate-raw', and under a sandbox the global may
            // not be exposed at all (a ReferenceError, which this also catches).
            const probe = new DecompressionStream('deflate-raw');
            nativeInflateAvailable = Boolean(probe);
        } catch (e) {
            nativeInflateAvailable = false;
        }
    }
    return nativeInflateAvailable;
}

async function inflateRaw(compressed) {
    if (hasNativeInflate()) {
        try {
            return await inflateRawNative(compressed);
        } catch (e) {
            // The probe passed but the stream still failed. Rather than fail the
            // upload, fall through — the inline decoder needs no platform support.
            nativeInflateAvailable = false;
        }
    }
    return inflateRawJs(compressed);
}

function u16(bytes, offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
}

function u32(bytes, offset) {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function findEocd(bytes) {
    const minSize = 22;
    const maxCommentLen = 65535;
    const scanFrom = Math.max(0, bytes.length - minSize - maxCommentLen);
    for (let i = bytes.length - minSize; i >= scanFrom; i--) {
        if (bytes[i] === 0x50 && bytes[i + 1] === 0x4b && bytes[i + 2] === 0x05 && bytes[i + 3] === 0x06) {
            return i;
        }
    }
    throw new Error('Not a valid ZIP file (end-of-central-directory marker not found).');
}

export async function readZip(input) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    const eocd = findEocd(bytes);
    const totalEntries = u16(bytes, eocd + 10);
    const cdOffset = u32(bytes, eocd + 16);

    const entries = [];
    let cursor = cdOffset;
    for (let i = 0; i < totalEntries; i++) {
        if (u32(bytes, cursor) !== 0x02014b50) {
            throw new Error('Invalid central directory entry at offset ' + cursor);
        }
        const method = u16(bytes, cursor + 10);
        const compressedSize = u32(bytes, cursor + 20);
        const nameLen = u16(bytes, cursor + 28);
        const extraLen = u16(bytes, cursor + 30);
        const commentLen = u16(bytes, cursor + 32);
        const localHeaderOffset = u32(bytes, cursor + 42);
        const decoder = new TextDecoder('utf-8');
        const name = decoder.decode(bytes.subarray(cursor + 46, cursor + 46 + nameLen));
        cursor += 46 + nameLen + extraLen + commentLen;

        if (name.endsWith('/')) {
            continue;
        }

        if (u32(bytes, localHeaderOffset) !== 0x04034b50) {
            throw new Error('Invalid local header at offset ' + localHeaderOffset);
        }
        const lhNameLen = u16(bytes, localHeaderOffset + 26);
        const lhExtraLen = u16(bytes, localHeaderOffset + 28);
        const dataStart = localHeaderOffset + 30 + lhNameLen + lhExtraLen;
        const compressed = bytes.subarray(dataStart, dataStart + compressedSize);

        let data;
        if (method === 0) {
            data = new Uint8Array(compressed);
        } else if (method === 8) {
            // eslint-disable-next-line no-await-in-loop
            data = await inflateRaw(compressed);
        } else {
            throw new Error('Unsupported compression method ' + method + ' for entry ' + name);
        }

        entries.push({ name, data });
    }
    return entries;
}

export function bytesToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        const slice = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
        binary += String.fromCharCode.apply(null, slice);
    }
    return btoa(binary);
}

/* Compares bytes with Salesforce ContentVersion.Checksum (MD5). SHA-256 covers durable checkpoints. */
(() => {
    'use strict';
    const shifts = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
    const constants = Array.from({ length: 64 }, (_, index) => Math.floor(2 ** 32 * Math.abs(Math.sin(index + 1))));

    self.portwoodMd5 = function md5(bytes) {
        const state = new Int32Array([0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]);

        function update(view, offset) {
            let [a, b, c, d] = state;
            for (let index = 0; index < 64; index++) {
                const round = index >>> 4;
                let mix;
                let word;
                switch (round) {
                    case 0: mix = (b & c) | (~b & d); word = index; break;
                    case 1: mix = (b & d) | (c & ~d); word = (5 * index + 1) & 15; break;
                    case 2: mix = b ^ c ^ d; word = (3 * index + 5) & 15; break;
                    default: mix = c ^ (b | ~d); word = (7 * index) & 15;
                }
                const sum = (a + mix + constants[index] + view.getInt32(offset + 4 * word, true)) | 0;
                const shift = shifts[round * 4 + index % 4];
                const rotated = (sum << shift) | (sum >>> (32 - shift));
                [a, b, c, d] = [d, (b + rotated) | 0, b, c];
            }
            state[0] += a;
            state[1] += b;
            state[2] += c;
            state[3] += d;
        }

        const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
        const aligned = bytes.length - bytes.length % 64;
        for (let offset = 0; offset < aligned; offset += 64) update(view, offset);
        const remaining = bytes.length - aligned;
        const tail = new Uint8Array(remaining < 56 ? 64 : 128);
        tail.set(bytes.subarray(aligned));
        tail[remaining] = 0x80;
        const tailView = new DataView(tail.buffer);
        tailView.setUint32(tail.length - 8, bytes.length * 8, true);
        for (let offset = 0; offset < tail.length; offset += 64) update(tailView, offset);
        return Array.from(state, word => [0, 8, 16, 24].map(shift => ((word >>> shift) & 255).toString(16).padStart(2, '0')).join('')).join('');
    };
})();

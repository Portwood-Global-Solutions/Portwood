#!/usr/bin/env node
/**
 * Build the classic-script copy of the vendored PDF.js (static resource `pdfjs4classic`).
 *
 * WHY THIS EXISTS
 * ---------------
 * `pdfjs4` is PDF.js's ES-module build (an `export{...}` at the end of each file). The
 * guided signing Visualforce page loads it with `import(url)`. A Lightning web component
 * cannot:
 *   - the LWC compiler rejects `import(url)` when the URL is computed (LWC1121), and a
 *     static resource URL is only known at runtime;
 *   - `loadScript` loads a classic <script>, and a classic script containing `export`
 *     fails to parse yet still fires `load`, so the promise resolves with nothing defined.
 *
 * So the Flow signing component loads a classic-script copy. The ONLY change made to the
 * upstream code is mechanical: each file is wrapped in a function scope (two classic
 * scripts share one global lexical scope, and both files declare the same top-level
 * class names) and its trailing `export{a as X, ...}` becomes a global assignment:
 *
 *   pdf.classic.js         -> globalThis.__portwoodPdfjs       = { getDocument, ... }
 *   pdf.worker.classic.js  -> globalThis.pdfjsWorker           = { WorkerMessageHandler }
 *
 * `globalThis.pdfjsWorker` is PDF.js's own documented hook for running the worker on the
 * main thread; the component needs it because a real Web Worker and PDF.js's fake-worker
 * `import()` fallback are both blocked under Lightning Web Security.
 *
 * The upstream license header (Apache-2.0) is preserved because the file content is
 * unchanged apart from the wrapper and the export statement. Disclosure: see
 * THIRD-PARTY-NOTICES.md.
 *
 * USAGE
 *   node scripts/build-pdfjs-classic.mjs          # (re)generate the resource
 *   node scripts/build-pdfjs-classic.mjs --check  # exit 1 if the committed copy is stale
 *
 * Run it again whenever `pdfjs4` is upgraded.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RES = path.join(ROOT, 'force-app/main/default/staticresources');
const SRC = path.join(RES, 'pdfjs4');
const OUT = path.join(RES, 'pdfjs4classic');

const FILES = [
    { from: 'pdf.min.js', to: 'pdf.classic.js', global: '__portwoodPdfjs' },
    { from: 'pdf.worker.min.js', to: 'pdf.worker.classic.js', global: 'pdfjsWorker' }
];

const META = `<?xml version="1.0" encoding="UTF-8"?>
<StaticResource xmlns="http://soap.sforce.com/2006/04/metadata">
    <cacheControl>Public</cacheControl>
    <contentType>application/zip</contentType>
    <description>PDF.js 4.7.76 as classic scripts for Lightning web components (generated from pdfjs4 by scripts/build-pdfjs-classic.mjs: function-scoped, trailing export made a global). No callout. See THIRD-PARTY-NOTICES.md.</description>
</StaticResource>
`;

/** Convert one ES-module file into a wrapped classic script. Throws if the shape is unexpected. */
export function toClassic(source, globalName) {
    const idx = source.lastIndexOf('export{');
    if (idx < 0) throw new Error('no trailing export{...} found');
    const tail = source.slice(idx);
    const m = tail.match(/^export\{([^}]*)\}\s*;?\s*(\/\/#[^\n]*)?\s*$/);
    if (!m) throw new Error('trailing export is not the expected form: ' + tail.slice(0, 80));
    const pairs = m[1]
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => {
            const p = s.split(/\s+as\s+/);
            return (p[1] || p[0]) + ':' + p[0];
        });
    if (!pairs.length) throw new Error('export list is empty');
    // Guard the assumptions the wrapper relies on: a classic script cannot use these.
    const body = source.slice(0, idx);
    if (/\bimport\.meta\b/.test(body)) throw new Error('import.meta found; cannot be a classic script');
    return '(function(){\n' + body + '\nglobalThis.' + globalName + '={' + pairs.join(',') + '};\n})();\n';
}

function build() {
    const out = {};
    for (const f of FILES) {
        const src = fs.readFileSync(path.join(SRC, f.from), 'utf8');
        out[f.to] = toClassic(src, f.global);
    }
    out['../pdfjs4classic.resource-meta.xml'] = META;
    return out;
}

function main() {
    const check = process.argv.includes('--check');
    const built = build();
    let stale = 0;
    for (const [name, content] of Object.entries(built)) {
        const target = path.join(OUT, name);
        const current = fs.existsSync(target) ? fs.readFileSync(target, 'utf8') : null;
        if (check) {
            if (current !== content) {
                console.error('STALE: ' + path.relative(ROOT, target));
                stale++;
            }
        } else {
            fs.mkdirSync(path.dirname(target), { recursive: true });
            fs.writeFileSync(target, content);
            console.log('wrote ' + path.relative(ROOT, target) + ' (' + content.length + ' bytes)');
        }
    }
    if (check) {
        if (stale) {
            console.error('pdfjs4classic is out of date. Run: node scripts/build-pdfjs-classic.mjs');
            process.exit(1);
        }
        console.log('pdfjs4classic is up to date.');
    }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main();

import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

// Keep the Lightning adapter on the exact, already-vendored PDF.js release.
const root = new URL('../force-app/main/default/staticresources/', import.meta.url);
const files = [
    ['pdf.min.js', 'pdf.js', 'e0215a6a1063bb912cbbfd3ffac76438c328b99a3b826d6bdb3cde9cf874c2a3'],
    ['pdf.worker.min.js', 'worker.js', 'efc53d106e184e188f1fef679b178f988bf97df2541d34c4f38e15681534de72']
];
for (const [source, target, hash] of files) {
    const original = readFileSync(new URL('pdfjs4/' + source, root), 'utf8');
    if (createHash('sha256').update(original).digest('hex') !== hash)
        throw new Error('Review the PDF.js release pin before rebuilding ' + source);
    if ([...original.matchAll(/\bexport\s*\{/g)].length !== 1) throw new Error('Unexpected PDF.js module structure.');
    const body = original.replace(/export\{[^}]+\};?\s*$/, '');
    if (body === original) throw new Error('Final module export was not found.');
    const output =
        '// PDF.js 4.7.76, derived from the existing pdfjs4 resource. Apache-2.0.\n// Classic-script adapter: remove the final ESM export and isolate webpack locals.\n(function(){\n' +
        body +
        '\n})();\n';
    const path = new URL('DocGenPdfPreview/' + target, root);
    if (process.argv.includes('--check')) {
        if (readFileSync(path, 'utf8') !== output) throw new Error('Rebuild the PDF.js adapter: ' + target);
    } else writeFileSync(path, output);
    console.log('Verified pinned PDF.js adapter: ' + target);
}

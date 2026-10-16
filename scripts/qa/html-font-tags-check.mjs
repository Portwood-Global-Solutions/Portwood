// Validate the runnable HTML example against the real vendored face revisions.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const root = new URL('../../', import.meta.url);
const faces = JSON.parse(readFileSync(new URL('scripts/fonts/demo-manifest.json', root), 'utf8'));
const html = readFileSync(new URL('docs/examples/HtmlFontTagsShowcase.html', root), 'utf8');
const tags = [...html.matchAll(/\{%font:([a-z0-9-]+):([a-f0-9]+)\}/g)];
assert(tags.length >= 5, 'The demo must exercise all five font faces');
const selected = new Set();
for (const [, asset, prefix] of tags) {
    assert.equal(prefix.length, 16, 'Examples should use the canonical prefix copied from Assets');
    const matches = faces.filter((face) => face.fontKey === asset && face.key.startsWith(prefix));
    assert.equal(matches.length, 1, `Unresolved or ambiguous demo font: ${asset}:${prefix}`);
    selected.add(matches[0].key);
}
assert.equal(selected.size, 5, 'All five faces must appear in the HTML demo');
assert(html.includes('<body style="{%font:'), 'Exercise body-level font inheritance');
assert(html.includes('{Name}'), 'Exercise live Salesforce record merging');
console.log(`PASS HTML font-tag demo: ${tags.length} directives resolve to all five real face revisions`);

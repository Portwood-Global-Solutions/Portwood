import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const file = new URL('../../force-app/main/default/lwc/docGenSnippetAssets/docGenSnippetAssets.js', import.meta.url);
const source = (await readFile(file, 'utf8'))
    .replace(/^import .*;\n/gm, '')
    .replace(/@wire\([^)]+\)\s*/g, '')
    .replace(
        'export default class DocGenSnippetAssets extends LightningElement',
        'return class DocGenSnippetAssets extends LightningElement'
    );
let savedArgs;
let failure = false;
let published;
const Component = new Function(
    'LightningElement',
    'refreshApex',
    'LightningConfirm',
    'getSnippets',
    'getSnippet',
    'saveSnippet',
    'getReadiness',
    'navigator',
    source
)(
    class {},
    async () => {},
    { open: async () => true },
    async () => [],
    async () => ({}),
    async (args) => {
        savedArgs = args;
        if (failure) throw { body: { message: 'Someone saved a newer revision.' } };
        return published;
    },
    async () => ({}),
    { clipboard: { writeText: async () => {} } }
);
let passed = 0;
const test = async (name, fn) => {
    await fn();
    passed++;
    console.log('PASS ' + name);
};
await test('a new section gets a stable usable tag without asking the user to write syntax', async () => {
    const c = new Component();
    c.canCreate = true;
    await c.handleNew();
    c.handleField({ target: { dataset: { field: 'name' }, value: 'Payment & Delivery Terms' } });
    assert.equal(c.tag, '{%snippet:payment-delivery-terms}');
    assert(c.dirty && c.editing && !c.saveDisabled);
});
await test('catalog filtering keeps inactive content visible to its author and separate from insertion choices', async () => {
    const c = new Component();
    c.items = [{ id: 'one', name: 'Payment', assetKey: 'terms', category: 'Legal', isActive: false }];
    c.search = 'legal';
    assert.equal(c.rows.length, 1);
    assert.equal(c.rows[0].state, 'Inactive');
    c.search = 'no match';
    assert.equal(c.rows.length, 0);
});
await test('a failed or stale save preserves the exact draft and lets the user recover it', async () => {
    const c = new Component();
    c.canEdit = true;
    c.draft = {
        id: 'one',
        name: 'Terms',
        assetKey: 'terms',
        html: '<p>Unsaved exact wording</p>',
        currentVersionId: 'current',
        isActive: true
    };
    c.dirty = true;
    failure = true;
    await c.handleSave();
    assert.equal(c.draft.html, '<p>Unsaved exact wording</p>');
    assert(c.dirty && !c.busy);
    assert.match(c.error, /newer revision/);
    failure = false;
});
await test('restoring history checks against the latest revision and creates a new revision', async () => {
    const c = new Component();
    c.canEdit = true;
    c.draft = {
        id: 'one',
        name: 'Terms',
        assetKey: 'terms',
        html: '<p>Earlier wording</p>',
        versionId: 'old',
        currentVersionId: 'current',
        isActive: true
    };
    assert(c.isOldRevision);
    c.handleRestore();
    assert(c.dirty);
    published = { ...c.draft, versionId: 'new', currentVersionId: 'new', versionNumber: '3' };
    await c.handleSave();
    assert.equal(savedArgs.expectedVersionId, 'current');
    assert.equal(savedArgs.html, '<p>Earlier wording</p>');
    assert(!c.dirty && !c.isOldRevision);
});
await test('readers and pending saves cannot edit or publish', async () => {
    const c = new Component();
    c.draft = { id: 'one', name: 'Terms', html: '<p>Terms</p>' };
    c.dirty = true;
    assert(c.readOnly && c.saveDisabled);
    c.canEdit = true;
    assert(!c.readOnly && !c.saveDisabled);
    c.busy = true;
    assert(c.readOnly && c.saveDisabled && c.canNew);
});
console.log(`${passed} shared-content authoring scenarios passed.`);

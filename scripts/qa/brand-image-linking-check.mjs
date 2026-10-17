import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenBrands/docGenBrands.js', import.meta.url),
    'utf8'
)
    .replace(/^import .*;\n/gm, '')
    .replace(/@(?:api|track)\s+/g, '')
    .replace(/@wire\([^)]*\)\s*/g, '')
    .replace('export default class DocGenBrands', 'class DocGenBrands');
const responses = [];
const context = vm.createContext({
    LightningElement: class {},
    resolveAssetPublicUrl: () => new Promise((resolve) => responses.push(resolve))
});
vm.runInContext(source + '\nglobalThis.Brands = DocGenBrands;', context);
const editor = new context.Brands();
editor.logoAssets = [
    { id: 'one', assetKey: 'one' },
    { id: 'two', assetKey: 'two' }
];
const event = (value) => ({ target: { dataset: { image: 'banner' } }, detail: { value } });
const first = editor.handlePageAssetChange(event('one'));
assert.equal(editor.saveDisabled, true, 'Do not save an image before its public URL is ready');
assert.equal(editor.saveLabel, 'Linking image…');
const second = editor.handlePageAssetChange(event('two'));
responses[1]('https://example.com/two.png');
await second;
responses[0]('https://example.com/one.png');
await first;
assert.equal(
    editor.page.bannerUrl,
    'https://example.com/two.png',
    'An older response cannot replace the latest choice'
);
assert.equal(editor.saveDisabled, false);
const third = editor.handlePageAssetChange(event('one'));
editor.handleConfigChange({ target: { dataset: { config: 'bannerUrl' }, value: 'https://example.com/manual.png' } });
responses[2]('https://example.com/one.png');
await third;
assert.equal(editor.page.bannerUrl, 'https://example.com/manual.png', 'Typing a URL cancels a pending asset selection');
assert.equal(editor.page.bannerAssetKey, '');
const fourth = editor.handlePageAssetChange(event('one'));
editor.handleAddNew();
responses[3]('https://example.com/one.png');
await fourth;
assert.equal(editor.page.bannerUrl, '', 'A response for another brand cannot change the newly opened form');
assert.equal(editor.pendingImageCount, 0);
console.log('PASS: image-link save readiness, stale responses, URL overrides, and form switching.');

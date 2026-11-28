// Exercise the actual Copy Prompt handlers and prompt builder with Salesforce catalog fixtures.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import { build } from 'esbuild';

const lwc = (name) => fileURLToPath(new URL(`../../force-app/main/default/lwc/${name}/${name}.js`, import.meta.url));
const bundleComponent = (name) =>
    build({
        entryPoints: [lwc(name)],
        alias: { 'c/docGenUtils': lwc('docGenUtils'), 'c/docGenAuthoringKit': lwc('docGenAuthoringKit') },
        bundle: true,
        logLevel: 'error',
        packages: 'external',
        platform: 'browser',
        format: 'cjs',
        loader: { '.js': 'ts' },
        tsconfigRaw: { compilerOptions: { experimentalDecorators: true } },
        write: false
    });

const image = {
    id: 'dark',
    name: 'Wordmark',
    category: 'Brand',
    description: 'White horizontal lettering for dark headers.',
    isActive: true,
    latestVersionCvId: 'private-file-id',
    versionNumber: 1,
    mergeTag: '{%asset:wordmark}'
};
const images = [
    image,
    { ...image, id: 'old', name: 'Discontinued logo', isActive: false },
    { ...image, id: 'empty', name: 'Pending upload', versionNumber: null },
    { ...image, id: 'seal', name: 'Seal', description: '', mergeTag: '{%asset:seal}' }
];
const face = {
    family: 'Example Sans',
    weight: 700,
    style: 'italic',
    selectable: true,
    mergeTag: '{%font:example-bold-italic}'
};
const snippets = [
    { name: 'Terms', isActive: true, mergeTag: '{%snippet:terms}' },
    { name: 'Withdrawn clause', isActive: false, mergeTag: '{%snippet:withdrawn}' }
];

let fontsAvailable = true;
let copied;
let createdAsset;
let updatedFields;
const noop = () => {};
const api = {
    getAuthoringFonts: async () => {
        if (!fontsAvailable) throw Error('unavailable');
        return [face];
    },
    getAssets: async () => images,
    createImageAsset: async (input) => {
        createdAsset = input;
        return { id: image.id };
    },
    getSnippets: async () => snippets
};
const sandbox = {
    module: { exports: {} },
    console,
    navigator: {
        clipboard: {
            writeText: async (value) => {
                copied = value;
            }
        }
    },
    require(id) {
        if (id === '@salesforce/apex') return { refreshApex: noop };
        if (id === 'lightning/uiRecordApi')
            return {
                updateRecord: async ({ fields }) => {
                    updatedFields = fields;
                }
            };
        if (id === 'lwc') return { LightningElement: class {}, api: noop, track: noop, wire: () => noop };
        if (id === 'lightning/navigation') return { NavigationMixin: (base) => base };
        if (id.startsWith('@salesforce/schema/')) return { fieldApiName: id.split('.').at(-1) };
        return api[id.split('.').at(-1)] || {};
    }
};
async function component(name) {
    const bundle = await bundleComponent(name);
    runInNewContext(bundle.outputFiles[0].text, sandbox);
    const instance = new sandbox.module.exports.default();
    instance.showToast = (title, message, variant) => {
        if (variant === 'error') throw Error(title + ': ' + message);
    };
    return instance;
}
const admin = await component('docGenAdmin');
admin.template = { querySelector: () => null };
const query = JSON.stringify({
    v: 3,
    nodes: [
        { id: 'root', fields: ['Name'] },
        { id: 'children', parentNode: 'root', alias: 'Lines', fields: ['Quantity'] },
        { id: 'parts', parentNode: 'children', alias: 'Components', fields: ['Price'] }
    ]
});
admin.editTemplateQuery = admin.newTemplateQuery = query;
admin.editTemplateObject = admin.newTemplateObject = 'Account';
await admin.handleCopyEditAiPrompt();
assert.ok(copied.endsWith('Describe your document:\n\n'));
assert.match(copied, /Wordmark \[Brand\].*\{%asset:wordmark\}.*White horizontal lettering for dark headers\./);
assert.match(copied, /Seal .*\{%asset:seal\}.*No description provided/);
assert.match(copied, /using none is fine/);
assert.match(copied, /Example Sans \(700, italic\).*\{%font:example-bold-italic\}/);
assert.match(copied, /style="\{%font:example-bold-italic\}; font-size:12pt"/);
assert.match(copied, /\{%snippet:terms\}/);
assert.match(copied, /\{#Components\} .* inside \{#Lines\}/);
assert.match(copied, /<tr><td>\{#Lines\}\{Quantity\}\{\/Lines\}<\/td><\/tr>/);
assert.match(copied, /PDF, screenshot, scan or Word document is attached/);
assert.doesNotMatch(copied, /private-file-id|servlet\.shepherd|Withdrawn clause|Discontinued logo|Pending upload/);

admin.aiSelectedAssetIds = [];
await admin.handleCopyAiPrompt();
assert.doesNotMatch(copied, /\{%asset:(wordmark|seal)\}/);
assert.match(copied, /No shared images are listed/);
admin.aiSelectedAssetIds = ['dark'];
admin.aiDocDescription = 'A landscape invoice with a dark header.';
await admin.handleCopyAiPrompt();
assert.ok(copied.endsWith('Describe your document:\nA landscape invoice with a dark header.\n'));
assert.match(copied, /White horizontal lettering/);
assert.doesNotMatch(copied, /\{%asset:seal\}/);

const edit = admin._buildDesignerAiPrompt({
    mode: 'edit',
    currentBody: '<p>{Name}</p>',
    docDescription: 'Move the name'
});
assert.match(edit, /BEGIN CURRENT TEMPLATE\n<p>\{Name\}<\/p>/);
assert.ok(edit.endsWith('Describe your changes:\nMove the name\n'));
assert.match(edit, /White horizontal lettering/);
fontsAvailable = false;
await admin._loadAiResources();
await admin.handleCopyEditAiPrompt();
assert.match(copied, /Use a built-in PDF font/);
assert.doesNotMatch(copied, /example-bold-italic/);
assert.match(copied, /White horizontal lettering/);
console.log(
    'Designer and wizard clipboard checks passed for fonts, optional images, descriptions, snippets and nested data.'
);

const library = await component('docGenAssets');
Object.assign(library, {
    createName: image.name,
    createKey: 'wordmark',
    createDescription: image.description,
    createCategory: image.category,
    keyValid: true,
    keyAvailable: true
});
await library.handleCreateAsset();
assert.equal(createdAsset.description, image.description);
assert.equal(library.createdAssetId, image.id);
await library.handleRowAction({ detail: { action: { name: 'rename' }, row: image } });
assert.equal(library.renameDescription, image.description);
library.renameDescription = 'Blue wordmark for white paper.';
await library.handleRenameSave();
assert.equal(updatedFields.Description__c, library.renameDescription);
library.renameDescription = '';
await library.handleRenameSave();
assert.equal(updatedFields.Description__c, null);
console.log('Asset library create, edit and clear checks passed.');

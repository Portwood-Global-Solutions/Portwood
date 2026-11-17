import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(
    new URL(
        '../../force-app/main/default/lwc/docGenTemplateSignatureSender/docGenTemplateSignatureSender.js',
        import.meta.url
    ),
    'utf8'
);
const plainSource = source
    .replace(/^import .*;\r?\n/gm, '')
    .replace(/^\s*@wire\([^\n]*\)\r?\n/gm, '\n')
    .replace(/@(api|track)\s+/g, '')
    .replace('export default class', 'class');
let payload;
const Sender = vm.runInNewContext(plainSource + '\nDocGenTemplateSignatureSender', {
    LightningElement: class {
        dispatchEvent() {}
    },
    NavigationMixin: (base) => base,
    CustomEvent: class {},
    getTemplateSignaturePlacements: async () => [],
    createGuidedPdfSignatureRequest: async (request) => {
        payload = request;
        return [];
    }
});
const sender = new Sender();
sender._checkInitialLoad = () => {};
sender._refreshAggregatedPlacements = () => {};
sender.showToast = () => {};
sender.showPreviousRequests = false;
sender.recordId = 'record';
sender.wiredDocGenTemplates({
    data: [
        {
            Id: 'configured',
            Name: 'Configured',
            portwoodglobal__Default_Signing_Order__c: 'Sequential',
            portwoodglobal__Default_Signed_Title__c: '{Name} Agreement',
            portwoodglobal__Default_Signature_Expiry_Days__c: 14
        },
        { Id: 'legacy', Name: 'Legacy' }
    ]
});
const select = (value) => sender.handleTemplateSelected({ detail: { value } });
const remove = (index) => sender.handleRemoveTemplate({ currentTarget: { dataset: { index } } });
const defaults = () => [sender.signingOrder, sender.documentTitleFormat, sender.expirationDays];

await select('configured');
assert.deepEqual(defaults(), ['Sequential', '{Name} Agreement', 14]);
await sender.handleGenerate();
assert.equal(payload.signingOrder, 'Sequential');
assert.equal(payload.documentTitleFormat, '{Name} Agreement');
assert.equal(payload.expirationDays, 14);

await select('legacy');
assert.deepEqual(defaults(), ['Parallel', '', null], 'packet does not inherit one template’s defaults');
remove(1);
assert.deepEqual(defaults(), ['Sequential', '{Name} Agreement', 14]);

sender.handleSigningOrderChange({ detail: { value: 'Parallel' } });
sender.handleDocumentTitleChange({ detail: { value: '' } });
sender.handleExpirationDaysChange({ detail: { value: '' } });
await select('legacy');
remove(1);
assert.deepEqual(defaults(), ['Parallel', '', ''], 'manual edits and deliberate clears survive selection changes');
await sender.handleGenerate();
assert.equal(payload.signingOrder, 'Parallel');
assert.equal(payload.documentTitleFormat, null);
assert.equal(payload.expirationDays, null);

remove(0);
await select('legacy');
assert.deepEqual(defaults(), ['Parallel', '', '']);
console.log('PASS: signer defaults, packet behavior, overrides and legacy fallback');

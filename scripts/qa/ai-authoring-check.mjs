import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source = fs.readFileSync('force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', 'utf8');
const kit = vm.runInNewContext(
    source.replace(/^import .*;$/gm, '').replace(/^export /gm, '') + '\n({buildAiPrompt,extractQueryShape});'
);
const { buildAiPrompt, extractQueryShape } = kit;
const shape = extractQueryShape(
    JSON.stringify({
        v: 3,
        root: 'Quote',
        nodes: [
            { id: 'n0', object: 'Quote', fields: ['Name', 'GrandTotal'], parentFields: [] },
            {
                id: 'n1',
                object: 'QuoteLineItem',
                fields: ['Quantity', 'Discount', 'TotalPrice'],
                parentFields: ['Product2.Name'],
                parentNode: 'n0',
                lookupField: 'QuoteId',
                relationshipName: 'QuoteLineItems'
            }
        ]
    }),
    'Quote'
);
const brief = 'Keep the example wording. Use teal headings and the approved brand font.';
const font = {
    label: 'Brand Regular',
    family: 'Brand',
    weight: 400,
    style: 'normal',
    selectable: true,
    status: 'Verified',
    mergeTag: '{%font:brand:0123456789abcdef}'
};
const prompt = buildAiPrompt(shape, {
    docDescription: brief,
    fonts: [font, { ...font, status: 'Staged', mergeTag: 'DO_NOT_USE' }],
    reference: { name: 'Example.docx', format: 'docx', html: '<html><body><h1>Reference heading</h1></body></html>' }
});
assert.ok(prompt.endsWith(brief), 'The user brief is the final prompt section');
assert.ok(prompt.includes(font.mergeTag));
assert.ok(!prompt.includes('DO_NOT_USE'), 'Unapproved font faces never reach generation');
assert.ok(prompt.includes('Reference heading'));
assert.ok(prompt.indexOf('END REFERENCE HTML') < prompt.lastIndexOf(brief));
assert.match(prompt, /untrusted document data/);
assert.match(prompt, /quoted inline style/);
assert.match(prompt, /EVERY custom font tag MUST be in an element/);
assert.ok(!prompt.includes('all CSS inline in a single'), 'Shared CSS cannot require font tags in stylesheets');
assert.match(prompt, /separately approved face/);
assert.match(prompt, /QuoteLineItems/);
assert.match(prompt, /GrandTotal/);
assert.match(prompt, /CRITICAL ARRAY RULE/);
assert.match(prompt, /Canonical related-list table/);
const edit = buildAiPrompt(shape, {
    mode: 'edit',
    currentBody: '<html><body>{Name}</body></html>',
    docDescription: brief,
    fonts: [font]
});
assert.ok(edit.endsWith(brief), 'Edit instructions also finish the prompt');
assert.ok(edit.includes('>>>BEGIN CURRENT TEMPLATE'));
const fallback = buildAiPrompt(shape, { docDescription: brief });
assert.match(fallback, /No approved custom fonts were selected/);
assert.ok(!fallback.includes('No web fonts — stick to'), 'The old blanket font prohibition is gone');
const admin = fs.readFileSync('force-app/main/default/lwc/docGenAdmin/docGenAdmin.js', 'utf8');
function method(name) {
    const start = admin.indexOf('    ' + name);
    assert.ok(start >= 0, name);
    const end = admin.indexOf('\n    }', start) + 6;
    return admin.slice(start, end);
}
const methods = [
    'get isAuthoringScratch()',
    'get isAuthoringCanvas()',
    'get isDesignAuthoring()',
    'get authoringCards()',
    'handleAuthoringModeSelect(event)'
]
    .map(method)
    .join('\n');
const Flow = vm.runInNewContext('class Flow {newAuthoringMode="canvas";designEditor="canvas";' + methods + '};Flow;');
const flow = new Flow();
assert.equal(flow.authoringCards.length, 3);
assert.equal(flow.authoringCards.filter((c) => c.selected).length, 1);
flow.handleAuthoringModeSelect({ currentTarget: { dataset: { mode: 'ai' } } });
assert.equal(flow.newTemplateType, 'HTML');
flow.designEditor = 'scratch';
flow.handleAuthoringModeSelect({ currentTarget: { dataset: { mode: 'design' } } });
assert.equal(flow.newAuthoringMode, 'scratch');
assert.equal(flow.newTemplateType, 'HTML');
flow.designEditor = 'canvas';
flow.handleAuthoringModeSelect({ currentTarget: { dataset: { mode: 'design' } } });
assert.equal(flow.newTemplateType, 'Canvas', 'Canvas remains a separate template product');
console.log(
    'PASS: three creation routes, separate editors, font approval, reference grounding, and final user briefs in create/edit prompts.'
);

// Schema-driven defaults must bind customers and commercial values, including line-item product names.
const schema = {
    Quote: ['Name', 'QuoteNumber', 'Subtotal', 'TotalPrice', 'Tax', 'ShippingHandling', 'GrandTotal'],
    Account: ['Name', 'BillingCity', 'BillingState'],
    Contact: ['Name'],
    User: ['Name'],
    QuoteLineItem: ['Quantity', 'UnitPrice', 'TotalPrice', 'Discount', 'Description']
};
const QueryFlow = vm.runInNewContext(
    'class QueryFlow {' + method('async _buildDefaultQueryConfig(objectApiName, rich)') + '};QueryFlow;',
    {
        getObjectFields: async ({ objectName }) =>
            (schema[objectName] || []).map((value) => ({ value, type: 'STRING' })),
        getParentRelationships: async () => [
            { value: 'Account', targetObject: 'Account' },
            { value: 'Contact', targetObject: 'Contact' },
            { value: 'Owner', targetObject: 'User' }
        ],
        getChildRelationships: async () => [
            { value: 'QuoteLineItems', childObjectApiName: 'QuoteLineItem' },
            { value: 'ApprovalSubmissions', childObjectApiName: 'ApprovalSubmission' }
        ]
    }
);
const query = await new QueryFlow()._buildDefaultQueryConfig('Quote', true);
assert.match(query, /Account\.Name/);
assert.match(query, /GrandTotal/);
assert.match(query, /Product2\.Name/);
assert.match(query, /Discount/);
assert.match(query, /FROM QuoteLineItems/);
assert.ok(!query.includes('ApprovalSubmissions'), 'Quote defaults do not add unrelated platform lists');
const DraftFlow = vm.runInNewContext(
    'class DraftFlow {' +
        ['get hasGeneratedAiBody()', 'get aiResultStale()', 'get aiCreateDisabled()'].map(method).join('\n') +
        '};DraftFlow;'
);
const draft = new DraftFlow();
draft.aiReferenceBusy = draft.isWizardAgentforceGenerating = draft.isAutoCreating = false;
draft._aiPastedHtml = '<html><body>Draft</body></html>';
draft._aiGeneratedPrompt = draft.aiAuthoringPrompt = 'original';
assert.equal(draft.aiCreateDisabled, false);
draft.isRecordDataSource = true;
draft.aiPlanReady = false;
assert.equal(draft.aiCreateDisabled, true, 'A record document needs a validated conversational plan.');
draft.aiPlanReady = true;
assert.equal(draft.aiCreateDisabled, false);
draft.aiAuthoringPrompt = 'changed brief or font';
assert.equal(draft.aiCreateDisabled, true);
console.log('PASS: Quote customer/product/total bindings and stale draft protection.');

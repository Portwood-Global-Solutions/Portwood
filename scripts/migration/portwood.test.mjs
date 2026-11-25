import assert from 'node:assert/strict';
import { test } from 'node:test';
import { plan } from './portwood.mjs';

test('compares identities without comparing source and target Salesforce IDs', () => {
    const input = {
        orgId: 'source',
        records: {
            brands: [{ id: 's1', name: 'Retail', OWA_Id: 's2' }],
            emailTemplates: [{ id: 's3', Type: 'Verify', Brand: 's1', Logo_Asset_Key: 'Missing' }],
            assets: [{ id: 's4', Asset_Key: 'Terms', Asset_Type: 'HTMLSnippet' }],
            fonts: [{ id: 's5', API_Name: 'FontMedium', Asset: 's6' }],
            templates: [{ id: 's7', API_Name: 'Quote', Test_Record_Id: 's8' }],
            settings: [{ id: 's9', Experience_Site_Url: 'https://scratch.example' }]
        }
    };
    const output = {
        orgId: 'target',
        unavailableFields: { brands: ['OWA_Id'] },
        records: {
            brands: [{ id: 't1', name: 'Retail' }],
            emailTemplates: [{ id: 't2', Type: 'Verify', Brand: 't1' }],
            fonts: null,
            templates: [
                { id: 't3', API_Name: 'quote' },
                { id: 't4', API_Name: 'Quote' }
            ]
        }
    };
    const result = plan(input, output);
    const byId = Object.fromEntries(result.items.map((item) => [item.sourceId, item]));
    assert.equal(byId.s1.status, 'conflict');
    assert.equal(byId.s1.warnings.length, 1);
    assert.equal(byId.s3.status, 'conflict');
    assert.deepEqual(byId.s3.targetIds, ['t2']);
    assert.equal(byId.s3.warnings.length, 1);
    assert.equal(byId.s4.kind, 'snippets');
    assert.equal(byId.s4.status, 'target-resource-unavailable');
    assert.equal(byId.s5.status, 'target-resource-unavailable');
    assert.equal(byId.s5.warnings.length, 1);
    assert.equal(byId.s7.status, 'ambiguous-key');
    assert.equal(byId.s7.warnings.length, 2);
    assert.equal(byId.s9.status, 'manual-mapping');
    assert.equal(byId.s9.warnings.length, 1);
    assert.deepEqual(result.unavailableFields.target.brands, ['OWA_Id']);
});

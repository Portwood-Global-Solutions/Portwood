import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';

const examples = JSON.parse(
    fs.readFileSync('force-app/main/default/staticresources/DocGenStarterExamples.resource', 'utf8')
);
for (const [key, example] of Object.entries(examples)) {
    const dom = new JSDOM(example.html);
    const parsed = dom.window.document;
    const expected = example.html.match(/\{[#/^][^}]+\}/g) || [];
    const actual = parsed.body.innerHTML.match(/\{[#/^][^}]+\}/g) || [];
    assert.deepEqual(actual, expected, `${key}: browser parsing must retain tag order`);
    const query = JSON.parse(example.query);
    for (const node of query.nodes.filter((n) => n.parentNode)) {
        const marker = `{#${node.relationshipName}}`;
        const cells = [...parsed.querySelectorAll('td')];
        const start = cells.find((cell) => cell.textContent.includes(marker));
        const end = cells.find((cell) => cell.textContent.includes(`{/${node.relationshipName}}`));
        assert.ok(start, `${key}: repeating data starts inside a table cell`);
        assert.equal(start.closest('tr'), end?.closest('tr'), `${key}: loop stays in one row through visual editing`);
    }
    assert.doesNotMatch(
        example.html,
        /display\s*:\s*(flex|grid)|linear-gradient|calc\(|var\(--/i,
        `${key}: native PDF layout uses supported CSS`
    );
}
const accountQuery = JSON.parse(examples.account.query);
const quote = examples.quote.sample;
const quoteQuery = JSON.parse(examples.quote.query);
assert.equal(quoteQuery.root, 'Quote');
assert.equal(quoteQuery.nodes[1].lookupField, 'QuoteId');
assert.equal(
    quote.Subtotal,
    quote.QuoteLineItems.records.reduce((sum, row) => sum + row.Quantity * row.UnitPrice, 0)
);
assert.equal(
    quote.TotalPrice,
    quote.QuoteLineItems.records.reduce((sum, row) => sum + row.Quantity * row.UnitPrice * (1 - row.Discount / 100), 0)
);
assert.equal(quote.GrandTotal, quote.TotalPrice + quote.Tax + quote.ShippingHandling);
assert.match(
    examples.quote.html,
    /\{GrandTotal:currency\}/,
    'Use the saved quote total instead of adding charges in the template'
);

const journeySource = fs
    .readFileSync('force-app/main/default/lwc/docGenGettingStarted/docGenGettingStarted.js', 'utf8')
    .replace(/^import .*;\n/gm, '')
    .replace(/@api /g, '')
    .replace(/\s*@wire\(getReadiness\)/g, '')
    .replace('export default class', 'class');
const Journey = vm.runInNewContext(journeySource + '\nDocGenGettingStarted;', {
    LightningElement: class {},
    NavigationMixin: (Base) => Base
});
const journey = new Journey();
journey.readiness({ data: { canCreate: true, quoteAvailable: true } });
assert.equal(journey.salesExampleKey, 'quote');
assert.equal(journey.salesExample.action, 'Start with a quote');
journey.choose({ currentTarget: { dataset: { key: journey.salesExampleKey } } });
assert.equal(journey.example.object, 'Quote', 'The record picker follows the selected example');
journey.back();
journey.readiness({ data: { canCreate: true, quoteAvailable: false } });
assert.equal(journey.salesExampleKey, 'opportunity');
journey.choose({ currentTarget: { dataset: { key: journey.salesExampleKey } } });
assert.equal(journey.example.object, 'Opportunity', 'Orgs without Quotes retain the complete proposal flow');
assert.equal(accountQuery.nodes.find((n) => n.object === 'Case').where, 'IsClosed = false');
assert.equal(accountQuery.nodes.find((n) => n.object === 'Opportunity').where, 'IsClosed = false');
assert.equal(
    examples.opportunity.sample.OpportunityLineItems.records.reduce((sum, row) => sum + row.TotalPrice, 0),
    24500
);

const fontSource = fs
    .readFileSync('force-app/main/default/lwc/docGenFontAssets/docGenFontAssets.js', 'utf8')
    .replace(/^import .*;\n/gm, '')
    .replace('export default class', 'class');
const context = vm.createContext({
    LightningElement: class {},
    CAN_MANAGE: true,
    loadFontFace: async () => {},
    navigator: {},
    clearTimeout
});
const FontLibrary = vm.runInContext(fontSource + '\nDocGenFontAssets;', context);
const library = new FontLibrary();
library.template = { querySelector: () => ({ scrollTo: () => {} }) };
library.faces = Array.from({ length: 139 }, (_, i) => ({
    key: String(i),
    label: `Family ${i}`,
    filename: `Family-${i}.ttf`,
    weight: 400,
    style: 'normal',
    status: i < 131 ? 'Verified' : 'Staged'
}));
assert.equal(library.rows.length, 24, 'A large catalog has a bounded DOM');
assert.equal(library.filteredFaces.length, 139, 'Paging does not discard catalog entries');
await library.nextPage();
assert.equal(library.rows[0].key, '24');
library.reviewed = true;
library.searchTerm = 'Family-138';
await library.filterChanged();
assert.equal(library.filteredFaces.length, 1, 'Search includes file names beyond the first page');
assert.equal(library.selectedKey, '138');
assert.equal(library.reviewed, false, 'Changing the selected font must reset PDF-review confirmation');
library.statusFilter = 'Verified';
await library.filterChanged();
assert.equal(library.rows.length, 0, 'Combined filters explain no matches');
assert.equal(library.nextDisabled, true);
console.log(
    'PASS: Quote availability/fallback and totals, starter browser round trips, native PDF CSS, live-data filters, and 139-face library paging/search.'
);

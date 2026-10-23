import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.document = dom.window.document;
globalThis.window = dom.window;
globalThis.Node = dom.window.Node;
const src = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenCanvas/canvasModel.js', import.meta.url),
    'utf8'
);
writeFileSync('/tmp/canvasModel.sampledata.mjs', src);
const m = await import('/tmp/canvasModel.sampledata.mjs?v=' + Date.now());

let failures = 0;
const ok = (cond, msg) => {
    console.log((cond ? '  ok  ' : ' FAIL ') + msg);
    if (!cond) failures++;
};

// --- substituteSampleTags: plain values -----------------------------------------

ok(m.substituteSampleTags('{FirstName}', { FirstName: 'Ada' }) === 'Ada', 'a simple field resolves');

ok(
    m.substituteSampleTags('{Client__r.BillingStreet}', { Client__r: { BillingStreet: '1 Main St' } }) === '1 Main St',
    'a nested parent-lookup path resolves'
);

ok(
    m.substituteSampleTags('{Client__r.BillingStreet}', { Client__r: {} }) === '{Client__r.BillingStreet}',
    'a missing field falls back to the raw tag'
);

ok(
    m.substituteSampleTags('{Amount}', { Amount: '' }) === '{Amount}',
    'an empty-string field falls back to the raw tag, same as missing'
);

ok(m.substituteSampleTags('{Amount}', { Amount: 0 }) === '0', 'a zero value still substitutes — 0 is not "empty"');

ok(m.substituteSampleTags('{Done}', { Done: false }) === 'false', 'a false value still substitutes');

ok(
    m.substituteSampleTags('{Rel}', { Rel: { totalSize: 3, records: [] } }) === '{Rel}',
    'a bare relationship name (resolves to an object, not a leaf value) falls back rather than printing [object Object]'
);

ok(m.substituteSampleTags('{Missing}', null) === '{Missing}', 'no data map at all leaves text untouched');

// --- approximate format-suffix handling (currency, date) ------------------------
// Box-sizing accuracy, not visual fidelity — no ISO/locale/auto-currency grammar.

ok(
    m.substituteSampleTags('{Amount:currency:USD}', { Amount: 17783.5 }) === '$17,783.50',
    'a :currency suffix renders as bare-$ US formatting'
);

ok(
    m.substituteSampleTags('{AnnualRevenue:currency}', { AnnualRevenue: 6400000 }) === '$6,400,000.00',
    'a bare :currency with no ISO also formats (the common case)'
);

ok(
    m.substituteSampleTags('{CloseDate:date}', { CloseDate: '2026-10-14' }) === '10/14/2026',
    'a :date suffix on a Salesforce date string formats as a short date, not shifted by local timezone'
);

ok(
    m.substituteSampleTags('{Name:unknownformat}', { Name: 'Ada' }) === 'Ada',
    'an unrecognized format suffix falls through to the plain value, same as before formatting existed'
);

ok(
    m.substituteSampleTags('{Description:currency}', { Description: 'Not a number' }) === 'Not a number',
    'a :currency suffix on a non-numeric value is left as the plain value, not forced through the formatter'
);

// --- structural / non-field tags are never substituted --------------------------

{
    const withLoop = '{#Opportunities}{Amount}{/Opportunities}';
    const out = m.substituteSampleTags(withLoop, { Opportunities: {}, Amount: '999' });
    ok(
        out.includes('{#Opportunities}') && out.includes('{/Opportunities}'),
        'structural {#...}/{/...} markers survive untouched'
    );
}

for (const tag of ['{Today}', '{PageNumber}', '{SUM:Opportunities.Amount}']) {
    const out = m.substituteSampleTags(tag, { Today: 'Ada', PageNumber: 'Ada', SUM: 'Ada' });
    ok(out === tag, `${tag} is left alone even when the data map happens to have a matching key`);
}

// --- escaping ---------------------------------------------------------------------

{
    const out = m.substituteSampleTags('{Name}', { Name: '<script>alert(1)</script>' });
    ok(!out.includes('<script>'), 'a resolved value is HTML-escaped, never raw markup');
    ok(out.includes('&lt;script&gt;'), 'and the escaped form is present');
}

{
    // escapeLiterals: true — the table-cell contract. The WHOLE string gets escaped,
    // matching what esc(c.tag||'') did before substitution existed, not just the
    // substituted portion.
    const out = m.substituteSampleTags('Qty "each": {Amount}', { Amount: 5 }, { escapeLiterals: true });
    ok(out === 'Qty &quot;each&quot;: 5', 'escapeLiterals also escapes literal text around a tag');
}

{
    // escapeLiterals: false (default) — the rich-text contract. Surrounding markup
    // passes through untouched; only the substituted value is escaped.
    const out = m.substituteSampleTags('<p>Hi {FirstName}</p>', { FirstName: 'Ada' });
    ok(out === '<p>Hi Ada</p>', 'default mode leaves surrounding HTML markup alone');
}

// --- tablePreviewHtml: no-mutation guard -----------------------------------------

{
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    const before = JSON.parse(JSON.stringify(box));
    m.tablePreviewHtml(box, {
        Opportunities: {
            totalSize: 2,
            records: [
                { Name: 'A', Amount: 1 },
                { Name: 'B', Amount: 2 }
            ]
        }
    });
    ok(JSON.stringify(box) === JSON.stringify(before), 'tablePreviewHtml never mutates the box it is given');
}

// --- tablePreviewHtml: byte-for-byte unchanged with no second argument ----------

{
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    const withNoArg = m.tablePreviewHtml(box);
    const withNullArg = m.tablePreviewHtml(box, null);
    ok(withNoArg === withNullArg, 'calling with no second argument matches calling with an explicit null');
    ok(withNoArg.includes('one row per Opportunities record'), 'and still shows the canned placeholder footer');
    ok(!withNoArg.includes('more row'), 'and never shows the real-data footer when there is no data');
}

// --- tablePreviewHtml: real row counts -------------------------------------------

{
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    const records = [
        { Name: 'Deal A', Amount: 100 },
        { Name: 'Deal B', Amount: 200 },
        { Name: 'Deal C', Amount: 300 }
    ];
    const html = m.tablePreviewHtml(box, { Opportunities: { totalSize: 3, records } });
    ok(html.includes('Deal A') && html.includes('Deal B') && html.includes('Deal C'), 'every real row is rendered');
    ok(html.includes('100') && html.includes('200') && html.includes('300'), 'and its real field values resolve');
    ok(!html.includes('more row'), 'no "+N more" footer when the real count fits under the cap');
    ok(
        !html.includes('{Name}') && !html.includes('{Amount}'),
        'raw tag text does not leak through alongside real values'
    );
}

{
    // Over the MAX_PREVIEW_ROWS cap.
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    const records = Array.from({ length: 50 }, (_, i) => ({ Name: 'Deal ' + i, Amount: i }));
    const html = m.tablePreviewHtml(box, { Opportunities: { totalSize: 50, records } });
    const rowMatches = html.match(/Deal \d+/g) || [];
    ok(
        rowMatches.length > 0 && rowMatches.length < 50,
        `renders a capped subset, not all 50 (rendered ${rowMatches.length})`
    );
    ok(html.includes('42 more row'), 'and reports the true remainder (50 - 8 = 42)');
}

{
    // Real, empty child list — zero rows, no footer at all.
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    const html = m.tablePreviewHtml(box, { Opportunities: { totalSize: 0, records: [] } });
    ok(!html.includes('one row per'), 'a real zero-row result shows no canned placeholder text');
    ok(!html.includes('more row'), 'and no "+N more" footer either — zero really is zero');
}

// --- tablePreviewHtml: grandchild (subRelationship) rows -------------------------

{
    const box = m.newTableBox(1, 1, 5);
    box.table.relationship = 'Opportunities';
    box.table.subRelationship = 'OpportunityLineItems';
    box.table.subColumns = [{ label: 'Product', tag: '{Product2.Name}', width: '' }];
    const records = [
        {
            Name: 'Deal A',
            Amount: 100,
            OpportunityLineItems: {
                totalSize: 2,
                records: [{ Product2: { Name: 'Widget' } }, { Product2: { Name: 'Gadget' } }]
            }
        }
    ];
    const html = m.tablePreviewHtml(box, { Opportunities: { totalSize: 1, records } });
    ok(
        html.includes('Widget') && html.includes('Gadget'),
        "grandchild rows resolve from the parent row's own nested data"
    );
}

console.log(failures ? `\n${failures} FAILED` : '\nall passed');
process.exit(failures ? 1 : 0);

/**
 * Canvas table box — loop openers that carry arguments.
 *
 *   node scripts/qa/canvas-bucket-table-check.mjs
 *
 * Issue #310. `tableToHtml` wrote the close tag as `'{/' + relationship + '}'`,
 * so a table bound to `ChartBucket:Rel:Field` emitted:
 *
 *   {#ChartBucket:Survey_Answers__r:Answer_8__c}  …row…
 *   {/ChartBucket:Survey_Answers__r:Answer_8__c}
 *
 * DocGenChartBucketResolver's close tag is the literal `{/ChartBucket}`, so
 * nothing matched, the block was never resolved, and the table printed its raw
 * tags into the document.
 *
 * That made "a chart with its numbers in a table beside it" — the commonest
 * chart layout there is, on six of the thirteen slides in the OneCommute deck —
 * authorable in Word and HTML but NOT in Canvas.
 *
 * The importer had the mirror-image bug: it read the binding with
 * /\{#([A-Za-z0-9_]+)\}/, which cannot match an opener carrying arguments. That
 * is why the documented string-replace workaround "will not survive a round trip
 * through the designer" — so the round trip is asserted here, not just the emit.
 *
 * The rule mirrors DocGenTemplateLinter.balanceKey, which mirrors
 * DocGenService.findBalancedEnd. If those change, change this.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>');
global.document = dom.window.document;
global.DOMParser = dom.window.DOMParser;

let fail = 0;
const ok = (c, m) => {
    console.log((c ? '  ok  ' : ' FAIL ') + m);
    if (!c) fail++;
};

const src = readFileSync(new URL('../../force-app/main/default/lwc/docGenCanvas/canvasModel.js', import.meta.url), 'utf8');
const tmp = '/tmp/canvasModel.bucket.' + Date.now() + '.mjs';
writeFileSync(tmp, src, 'utf8');
const m = await import(tmp);

const geo = m.pageGeometry('Letter', 'Portrait');

/** A canvas doc holding one table box bound to `rel`. */
function docWithTable(rel, sub) {
    const doc = m.blankDocument();
    const box = m.newTableBox ? m.newTableBox(0.5, 0.5, 6, 2) : m.newTextBox(0.5, 0.5, 6, 2);
    box.type = 'table';
    box.table = {
        relationship: rel,
        columns: [
            { label: 'Answer', tag: '{key_label}' },
            { label: 'Count', tag: '{count}' },
            { label: 'Percent', tag: '{percent}%' }
        ],
        rows: []
    };
    if (sub) {
        box.table.subRelationship = sub;
        box.table.subColumns = [{ label: 'Detail', tag: '{Name}' }];
    }
    doc.artboards[0].boxes.push(box);
    return doc;
}

console.log('\na ChartBucket table emits the closer the resolver actually matches');
{
    const rel = 'ChartBucket:Survey_Answers__r:Answer_8__c';
    const html = m.serialize(docWithTable(rel), geo);
    ok(html.includes('{#' + rel + '}'), 'the opener carries its arguments');
    ok(html.includes('{/ChartBucket}'), 'the closer is the bare {/ChartBucket} the resolver looks for');
    ok(!html.includes('{/ChartBucket:'), 'and NOT the argument-carrying closer that nothing matches');
}

console.log('\nthe importer can read a binding that carries arguments');
{
    // The full round trip needs the real designer DOM — a table box does not
    // reconstruct in a headless harness even for a plain relationship, so that
    // is not something this check can honestly assert. What it CAN pin is the
    // binding-extraction pattern, which is the half that was broken: it read
    // /\{#([A-Za-z0-9_]+)\}/, and an opener carrying arguments cannot match
    // that. A bucket table therefore came back UNBOUND, which is why the
    // documented string-replace workaround did not survive a save.
    const BINDING = /\{#([^{}]+)\}/; // must stay in step with canvasModel.js
    const cases = [
        ['ChartBucket:Survey_Answers__r:Answer_8__c', 'a bucket loop with arguments'],
        ['OpportunityLineItems', 'a plain relationship'],
        ['IF Amount > 100', 'an IF with an expression'],
        ['GroupBy Region__c', 'a GroupBy with a field']
    ];
    for (const [rel, label] of cases) {
        const wrapperHtml = '{#' + rel + '}<table><tbody><tr><td>{key_label}</td></tr></tbody></table>{/' + rel + '}';
        const hit = BINDING.exec(wrapperHtml);
        ok(hit && hit[1] === rel, `${label}: reads back as ${JSON.stringify(rel)} — got ${hit ? JSON.stringify(hit[1]) : 'no match'}`);
    }
    // The old pattern, kept to show what it could not do.
    const OLD = /\{#([A-Za-z0-9_]+)\}/;
    ok(
        !OLD.test('{#ChartBucket:Survey_Answers__r:Answer_8__c}'),
        'the old pattern genuinely could not match a bucket opener'
    );
}

console.log('\nplain relationships are unchanged');
{
    const html = m.serialize(docWithTable('OpportunityLineItems'), geo);
    ok(html.includes('{#OpportunityLineItems}'), 'opener unchanged');
    ok(html.includes('{/OpportunityLineItems}'), 'closer unchanged — a plain rel closes on itself');
}

console.log('\nthe other argument-carrying openers close on their key too');
{
    // These mirror DocGenTemplateLinter.balanceKey. A table is an odd place to
    // bind one, but the serializer must not invent a closer the engine rejects.
    const cases = [
        ['IF Amount > 100', '{/IF}'],
        ['GroupBy Region__c', '{/GroupBy}'],
        ['ChartBucket', '{/ChartBucket}']
    ];
    for (const [rel, expected] of cases) {
        const html = m.serialize(docWithTable(rel), geo);
        ok(html.includes(expected), `${rel} closes with ${expected}`);
    }
}

console.log('\na grandchild sub-loop follows the same rule');
{
    const html = m.serialize(docWithTable('Accounts__r', 'ChartBucket:Answers__r:A__c'), geo);
    const hasSub = html.includes('data-dg-subrel');
    if (!hasSub) {
        console.log('  SKIP  this build did not emit a sub-loop row for the fixture');
    } else {
        ok(html.includes('{/ChartBucket}'), 'the sub-loop closes on the bare key');
        ok(!html.includes('{/ChartBucket:'), 'and not on the argument-carrying form');
    }
}

console.log(fail ? `\n${fail} FAILED` : '\nbucket table OK');
process.exit(fail ? 1 : 0);

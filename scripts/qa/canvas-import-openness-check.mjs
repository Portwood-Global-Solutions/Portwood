// Guards issue #301: importing a canvas-exported HTML file must OPEN it (every box,
// condition, name and coordinate intact), not run it through htmlToCanvas() — the
// converter meant for arbitrary foreign HTML, which groups consecutive blocks into a
// single box. handleImportFile() mirrors loadBody()'s deserialize-first logic; this
// checks that logic directly against canvasModel.js, headlessly.
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
writeFileSync('/tmp/cm.import-openness.mjs', src);
const m = await import('/tmp/cm.import-openness.mjs?v=' + Date.now());

let fail = 0;
const ok = (c, msg) => {
    console.log((c ? '  ok  ' : ' FAIL ') + msg);
    if (!c) fail++;
};

/** The exact branch handleImportFile() takes: deserialize first, htmlToCanvas as fallback. */
function importOpenly(html) {
    const parsed = m.deserialize(html);
    if (parsed) {
        const boxes = parsed.artboards.reduce((n, b) => n + (b.boxes || []).length, 0);
        return { doc: parsed, boxes, opened: true };
    }
    const { doc, report } = m.htmlToCanvas(html);
    return { doc, boxes: report.boxes, opened: false };
}

// --- a canvas-exported document, with conditions and names on several boxes -------
const geo = m.pageGeometry('Letter', 'Portrait');
const doc = m.blankDocument();

const a = m.newTextBox(0, 0, 8.5, 1.1);
a.mode = 'pinned';
a.name = 'header';
a.text = 'Header';

const b = m.newTextBox(0.6, 1.5, 4, 0.5);
b.mode = 'pinned';
b.name = 'conditionOne';
b.condition = "Rating = 'Hot'";
b.text = 'Hot lead note';

const c = m.newTextBox(0.6, 2.2, 4, 0.5);
c.mode = 'pinned';
c.name = 'conditionTwo';
c.condition = 'Amount__c > 0';
c.text = 'Has amount';

const tb = m.newTableBox(0.6, 3.5, 7.3);
tb.table.relationship = 'Opportunities';
tb.table.columns = [{ label: 'Name', tag: '{Name}', width: '100%' }];

doc.artboards[0].boxes.push(a, b, c, tb);

const exported = m.serialize(doc, geo);
const result = importOpenly(exported);

ok(result.opened, 'an exported canvas document is opened, not converted');
ok(result.boxes === 4, `every box survives (${result.boxes} of 4)`);
const conditions = result.doc.artboards[0].boxes.filter((x) => x.condition);
ok(conditions.length === 2, `per-box conditions survive (${conditions.length} of 2)`);
const names = result.doc.artboards[0].boxes.map((x) => x.name).filter(Boolean);
ok(names.join(',') === 'header,conditionOne,conditionTwo', 'block names survive in order (' + names.join(',') + ')');
ok(
    result.doc.artboards[0].boxes.some((x) => x.kind === 'table'),
    'the table is still a table'
);

const reexported = m.serialize(result.doc, geo);
ok(exported === reexported, 'export -> import -> export is byte-identical');

// --- an ordinary, non-canvas HTML document must still go through htmlToCanvas -----
const foreign = '<html><body><p>Plain paragraph</p><table><tr><td>1</td></tr></table></body></html>';
const foreignResult = importOpenly(foreign);
ok(!foreignResult.opened, 'an ordinary html document is still converted');
ok(foreignResult.boxes > 0, `and produces boxes (${foreignResult.boxes})`);

console.log(fail ? `\n${fail} FAILED` : '\ncanvas import openness OK');
process.exit(fail ? 1 : 0);

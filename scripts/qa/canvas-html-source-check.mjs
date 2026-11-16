// Issue #495: independent elements without rewriting the template's layout.
// Run with node scripts/qa/canvas-html-source-check.mjs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import { chromium } from 'playwright';

const modelSource = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenCanvas/canvasModel.js', import.meta.url),
    'utf8'
);
const kitSource = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenAuthoringKit/docGenAuthoringKit.js', import.meta.url),
    'utf8'
);
const componentSource = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenCanvas/docGenCanvas.js', import.meta.url),
    'utf8'
);
const dom = new JSDOM();
globalThis.document = dom.window.document;
globalThis.window = dom.window;
const m = await import('data:text/javascript;base64,' + Buffer.from(modelSource).toString('base64'));
const geo = m.pageGeometry('Letter', 'Portrait');
const source = `<!DOCTYPE html><html><head><style>
@page { size: Letter; margin: 0; }
body { margin: 0; font: 12pt Georgia; }
.letter { padding: 24px; border: 2px solid navy; }
.letter > p { margin: 12px 0; color: rgb(12,34,56); }
table { border-collapse: collapse; width: 100%; }
td, th { border: 1px solid black; padding: 8px; }
.next { break-before: page; }
</style></head><body><section class="letter"><h1>{Name}</h1><p>First paragraph</p><p>Second paragraph</p><table class="details"><thead><tr><th colspan="2">Details</th></tr></thead><tbody>{#Contacts}<tr><td rowspan="2">{Name}</td><td>{Email}</td></tr><tr><td>Second row</td></tr>{/Contacts}</tbody></table><p class="next">Page two</p></section></body></html>`;
const imported = m.htmlToCanvas(source);
const boxes = imported.doc.artboards.flatMap((b) => b.boxes);
assert.equal(boxes.filter((b) => b.kind === 'text').length, 4);
assert.equal(boxes.filter((b) => b.kind === 'table').length, 1);
assert.equal(m.importedHtml(imported.doc), source, 'untouched source is byte-identical');
const output = m.serialize(imported.doc, geo);
assert.equal(
    output.slice(0, output.indexOf('\n<!--dg-import-v1:')).replace(/<!--dg-import-(?:start|end):[\w-]+-->/g, ''),
    source
);
assert.equal(m.serialize(m.deserialize(output), geo), output, 'save/reopen is stable');
assert.deepEqual([...m.collectUsedFields(imported.doc).children.Contacts], ['Name', 'Email']);
const first = boxes.find((b) => b.html.includes('First paragraph'));
first.html = '<p>Edited paragraph</p>';
assert(m.importedHtml(imported.doc).includes('<p>Edited paragraph</p>'));
assert(m.importedHtml(imported.doc).includes('<table class="details">'), 'table markup is unaffected by text edits');
assert(m.importedHtml(imported.doc).includes('{#Contacts}<tr>'), 'table loops never pass through DOM serialization');
const table = boxes.find((b) => b.importedTable);
table.html = table.html.replace('{Email}', '{Phone}');
assert(m.importedHtml(imported.doc).includes('{Phone}'), 'table content is editable');
assert(m.importedHtml(imported.doc).includes('{#Contacts}<tr>'), 'editing a table keeps its loop opener inside tbody');
assert(
    m.importedHtml(imported.doc).includes('{/Contacts}</tbody>'),
    'editing a table keeps its loop closer inside tbody'
);
const phoneCell = m.importedTableCells(table).find((cell) => cell.value === '{Phone}');
assert(phoneCell, 'each authored cell is independently editable');
assert.equal(m.importedTableCells(table)[0].value, 'Details', 'merged header cells are retained');
assert(
    m
        .deserialize(m.serialize(imported.doc, geo))
        .artboards.flatMap((b) => b.boxes)
        .some((b) => b.html.includes('{Phone}'))
);
const rewritten = output.replace('First paragraph', 'A longer server-rewritten paragraph');
const reloaded = m.deserialize(rewritten);
assert(reloaded.artboards.flatMap((b) => b.boxes).some((b) => b.html === '<p>A longer server-rewritten paragraph</p>'));
assert(
    m.importedHtml(reloaded).includes('<table class="details">'),
    'server rewrites do not invalidate later source ranges'
);
const metric = m.htmlToCanvas('<style>@page { size:210mm 297mm; margin: 36pt 24px 12mm; }</style><p>Metric</p>');
assert.equal(metric.page.margins.top, 0.5);
assert.equal(metric.page.margins.left, 0.25);
assert.equal(metric.page.size, 'Custom');
const moved = m.htmlToCanvas('<p>Move me</p>');
moved.doc.artboards[0].boxes[0].importOffset = { x: 0.5, y: 0.25 };
const movedOutput = m.serialize(moved.doc, geo);
assert(movedOutput.includes('left:0.5in;top:0.25in;'));
assert.equal(m.serialize(m.deserialize(movedOutput), geo), movedOutput, 'moves are not applied twice after reopening');
const extended = m.htmlToCanvas('<p>Original</p>');
extended.doc.artboards[0].boxes.push(m.newTextBox(1, 2, 3, 0.5));
const extendedOutput = m.serialize(extended.doc, geo);
assert.equal(
    m.serialize(m.deserialize(extendedOutput), geo),
    extendedOutput,
    'new canvas boxes survive reopening without duplication'
);

assert(
    m.cloneArtboard(imported.doc.artboards[0]).boxes.every((b) => !b.importRange),
    'copies have independent source ranges'
);

const scopeStart = kitSource.indexOf('export function scopeHtmlForInlinePreview');
const scopeEnd = kitSource.indexOf(
    '\n// ---------------------------------------------------------------------------',
    scopeStart
);
const scopeSource = kitSource.slice(scopeStart, scopeEnd).replace('export ', '');
const paintStart = componentSource.indexOf('    renderImportedPages() {');
const paintEnd = componentSource.indexOf('\n    /**', paintStart);
const paintSource = componentSource.slice(paintStart, paintEnd);
const browser = await chromium.launch({ headless: true });
try {
    const page = await browser.newPage();
    await page.setContent('<div id="canvas"><div class="dg-import-page"></div></div>');
    const result = await page.evaluate(
        ({ modelSource, scopeSource, paintSource, source }) => {
            const factory = new Function(
                modelSource.replace(/export /g, '') +
                    '\n' +
                    scopeSource +
                    '\nreturn { htmlToCanvas, importedHtml, newArtboard, pageGeometry, scopeHtmlForInlinePreview, Painter: class {' +
                    paintSource +
                    '} };'
            );
            const api = factory();
            const painter = new api.Painter();
            painter.doc = api.htmlToCanvas(source).doc;
            painter.geo = api.pageGeometry('Letter', 'Portrait');
            painter.zoom = 1;
            painter.template = document.querySelector('#canvas');
            painter.renderImportedPages();
            const first = painter.doc.artboards[0].boxes;
            const result = {
                pages: painter.doc.artboards.length,
                boxes: painter.doc.artboards.flatMap((b) => b.boxes).length,
                paragraphColor: getComputedStyle(document.querySelector('.dg-pv p')).color,
                tableWidth: first.find((b) => b.kind === 'table').w,
                pageTwoText: painter.doc.artboards[1]?.boxes.map((b) => b.html).join(''),
                html: api.importedHtml(painter.doc)
            };
            painter.zoom = 1.5;
            painter.renderImportedPages();
            const zoomWidth = painter.doc.artboards[0].boxes.find((b) => b.kind === 'table').w;
            if (Math.abs(zoomWidth - result.tableWidth) > 0.002) throw new Error('Zoom changed source layout');
            painter.doc = api.htmlToCanvas(
                '<style>body{margin:0}.spacer{height:2400px}</style><div class="spacer"></div><p>Overflow page</p>'
            ).doc;
            painter.zoom = 1;
            painter.renderImportedPages();
            if (painter.doc.artboards.length < 3) throw new Error('Natural overflow did not create pages');
            return result;
        },
        { modelSource, scopeSource, paintSource, source }
    );
    assert.equal(result.pages, 2, 'class-based page break creates a canvas page');
    assert.equal(result.boxes, 5);
    assert.equal(result.paragraphColor, 'rgb(12, 34, 56)', 'source CSS applies without per-box wrappers');
    assert(result.tableWidth > 7 && result.tableWidth < 8.5, 'table uses the source container width');
    assert(result.pageTwoText.includes('Page two'));
    assert.equal(result.html, source, 'measuring canvas pages cannot rewrite preview HTML');
    console.log('Canvas HTML source, editing, round trip, CSS and page-break checks passed.');
} finally {
    await browser.close();
}

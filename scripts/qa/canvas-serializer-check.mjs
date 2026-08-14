// Canvas serializer check — asserts the SHIPPED canvasModel emits the layout contract// that was measured to work (scripts/canvas-layout-model-probe.apex).
// Pure Node, no org needed:  node scripts/qa/canvas-serializer-check.mjs
//
// Guards the rules that are counter-intuitive and would otherwise be "tidied" away:
// a pinned box must NOT emit height (it has to grow with merged content), a flow box
// uses margin rather than left/top, page-break lives on the artboard AFTER the first,
// the artboard uses min-height, the table loop wraps the <tr> inside <tbody>, and
// merge tags survive escaping.
import { readFileSync, writeFileSync } from 'node:fs';

const src = readFileSync(
    new URL('../../force-app/main/default/lwc/docGenCanvas/canvasModel.js', import.meta.url),
    'utf8'
);
writeFileSync('/tmp/canvasModel.check.mjs', src);
const m = await import('/tmp/canvasModel.check.mjs?v=' + Date.now());

const geo = m.pageGeometry('Letter', 'Portrait');
const doc = m.blankDocument();

const pin = m.newTextBox(2.4, 3.1, 2.5, 0.4);
pin.text = '{Name}\nIndustry: {Industry}';
doc.artboards[0].boxes.push(pin);

const marks = m.newTextBox(0.5, 3.6, 3, 0.4);
marks.text = 'Terms: **Net/30** //rush// __signed__ ~~void~~ {Name} 5 < 10';
doc.artboards[0].boxes.push(marks);

// #282 regression: two merge tags carrying double underscores (the __r / __c every
// relationship and custom field has). The underline mark `__` must not pair the
// underscores across the two tags into a <u> span inside {…}.
const relBox = m.newTextBox(0.5, 3.9, 3, 0.4);
relBox.text = '{Client__r.Name} / {Amount__c}';
doc.artboards[0].boxes.push(relBox);

// A mark SPANNING a tag must still expand — the fix keeps tags atomic without cutting
// the string into slices, so **Total: {Amount__c}** prints bold, not literal asterisks.
const spanBox = m.newTextBox(0.5, 4.05, 3, 0.4);
spanBox.text = '**Total: {Amount__c}**';
doc.artboards[0].boxes.push(spanBox);

const cond = m.newTextBox(0.5, 4.2, 3, 0.4);
cond.text = '{#IF Amount > 100000}Large deal{/IF}';
doc.artboards[0].boxes.push(cond);

const tbl = m.newTableBox(0.3, 5.0, 6.9);
tbl.table.relationship = 'Opportunities';
tbl.table.columns = [
    { label: 'Opportunity', tag: '{Name}', width: '45%' },
    { label: 'Amount', tag: '{Amount:currency:USD}', width: '55%' }
];
doc.artboards[0].boxes.push(tbl);

// Static rows + a totals row, plus what the totals suggester proposes.
tbl.table.rows = [['Note', '']];
const suggested = m.suggestTotals(tbl.table);
tbl.table.totals = { enabled: true, cells: suggested };

doc.artboards.push(m.newArtboard());
const p2 = m.newTextBox(1.0, 0.5, 3.0, 0.4);
p2.text = 'Page two';
doc.artboards[1].boxes.push(p2);

// A second FLOW box below the table, to pin down the stacking maths.
const below = m.newTextBox(0.5, 7.5, 4, 0.4);
below.mode = 'flow';
below.text = 'Below the table';
doc.artboards[0].boxes.push(below);

// --- fixtures for rich text, images, shapes and page setup ------------------
const rich = m.newTextBox(0.5, 5.2, 3, 0.4);
rich.html = '<p><b>Rich</b> text with {Owner.Name} and a &#123;braced&#125; entity</p>';
doc.artboards[0].boxes.push(rich);

const logo = m.newImageBox(0.5, 0.2, 1.5, 0.75);
logo.image.src = '/sfc/servlet.shepherd/version/download/068000000000001';
logo.image.keepRatio = true;
doc.artboards[0].boxes.push(logo);

const assetLogo = m.newImageBox(3, 0.2, 1.5, 0.75);
assetLogo.image.assetKey = 'company-logo';
assetLogo.image.keepRatio = true;
doc.artboards[0].boxes.push(assetLogo);

const fieldImg = m.newImageBox(5, 0.2, 1, 1);
fieldImg.image.tag = '{%Logo__c}';
doc.artboards[0].boxes.push(fieldImg);

const rect = m.newShapeBox(0.5, 6, 2, 0.5);
doc.artboards[0].boxes.push(rect);

const rule = m.newShapeBox(0.5, 6.8, 6, 0.02);
rule.shape.type = 'hline';
doc.artboards[0].boxes.push(rule);

const qr = m.newCodeBox(4.5, 6);
qr.code = { field: 'Name', type: 'qr', size: 192, height: 80 };
doc.artboards[0].boxes.push(qr);

const bar = m.newCodeBox(0.5, 7.6);
bar.code = { field: 'AccountNumber', type: 'code128', size: 288, height: 96 };
doc.artboards[0].boxes.push(bar);

// A bordered, padded box dragged to the right edge of the page. In CSS 2.1 the border
// and padding sit OUTSIDE the declared width and box-sizing is ignored by this engine,
// so emitting the authored width would push the box off the paper and clip it.
const edge = m.newTextBox(0.5, 8.5, 8, 0.4);
edge.style = { ...edge.style, borderWidth: 3, padding: 6 };
edge.text = 'edge to edge';
doc.artboards[0].boxes.push(edge);

const a4Geo = m.pageGeometry('A4', 'Landscape', { top: 1, right: 0.75, bottom: 1, left: 0.75 });
const a4Html = m.serialize(doc, a4Geo);

// A custom size emits two lengths, and the default zero margin makes the artboard the
// whole page so a box at 0,0 is at the paper corner.
const customGeo = m.pageGeometry('Custom', 'Portrait', undefined, { w: 5.5, h: 8.5 });
const customHtml = m.serialize(doc, customGeo);

const html = m.serialize(doc, geo);

// --- derived query: loops inside text boxes -------------------------------
// A hand-written loop in a text box is the only way to express a grandchild list, and
// the derived query has to follow that nesting. Getting it wrong produced a flat
// SELECT that RUNS and returns a row while every child tag renders blank.
const qDoc = m.blankDocument();
const qBox = m.newTextBox(0.5, 2, 7, 1);
qBox.mode = 'flow';
qBox.html =
    '<p>{AccountNumber}{#Opportunities}{Name} {Amount}' +
    '{#OpportunityLineItems}{Name} {Quantity}{/OpportunityLineItems}{/Opportunities}</p>';
qDoc.artboards[0].boxes.push(qBox);
const condBox = m.newTextBox(0, 0, 2, 0.4);
condBox.html = '{#IF Amount > 100}{Rating}{/IF}';
qDoc.artboards[0].boxes.push(condBox);
const derived = m.buildQueryConfig(qDoc);

// --- nested table rows (grandchildren) -------------------------------------
const nestDoc = m.blankDocument();
const nestTable = m.newTableBox(0.5, 2, 7);
nestTable.table.relationship = 'Opportunities';
nestTable.table.columns = [
    { label: 'Opportunity', tag: '{Name}', width: '' },
    { label: 'Stage', tag: '{StageName}', width: '' },
    { label: 'Amount', tag: '{Amount}', width: '' }
];
nestTable.table.subRelationship = 'OpportunityLineItems';
nestTable.table.subColumns = [
    { label: 'Product', tag: '{Name}', width: '' },
    { label: 'Qty', tag: '{Quantity}', width: '' }
];
nestDoc.artboards[0].boxes.push(nestTable);
const nestHtml = m.serialize(nestDoc, geo);

// The reverse shape: ONE parent column above TWO nested ones.
const widerDoc = m.blankDocument();
const widerTable = m.newTableBox(0.5, 2, 7);
widerTable.table.relationship = 'Opportunities';
widerTable.table.columns = [{ label: 'Opportunity', tag: '{Name}', width: '' }];
widerTable.table.subRelationship = 'OpportunityLineItems';
widerTable.table.subColumns = [
    { label: 'Product', tag: '{Product2.Name}', width: '' },
    { label: 'Qty', tag: '{Quantity}', width: '' }
];
widerDoc.artboards[0].boxes.push(widerTable);
const widerNestHtml = m.serialize(widerDoc, geo);

// --- signature placements --------------------------------------------------
// Its OWN document: adding boxes to the shared one after it was serialized broke the
// box-count check, which compares that html against the doc it came from.
const sigDoc = m.blankDocument();
const sigA = m.newSignatureBox(1, 9);
sigA.signature = { role: 'Account Manager', order: 2, type: 'Full', inline: false };
const sigB = m.newSignatureBox(4.5, 9);
sigB.signature = { role: 'Customer', order: 1, type: 'Date', inline: true };
sigDoc.artboards[0].boxes.push(sigA, sigB);
const sigHtml = m.serialize(sigDoc, geo);

// --- #281: Arial Unicode MS has no bold face in the PDF engine -----------------
// Blob.toPdf embeds Arial Unicode MS WITHOUT a bold variant, so font-weight:bold on
// it silently prints regular — the canvas promised a weight the PDF cannot deliver.
// The serializer must NOT emit that no-op bold, while the generic families (which
// resolve to Helvetica-Bold / Times-Bold / Courier-Bold) must still serialize bold.
const UNICODE = m.UNICODE_FONT;
const boldChecks = [
    ['canRenderBold: Arial Unicode MS (quoted) has no bold', m.canRenderBold(UNICODE) === false],
    ['canRenderBold: Arial Unicode MS (unquoted) has no bold', m.canRenderBold('Arial Unicode MS') === false],
    ['canRenderBold: generic sans-serif supports bold', m.canRenderBold('sans-serif') === true],
    ['canRenderBold: generic serif supports bold', m.canRenderBold('serif') === true],
    ['canRenderBold: no font supports bold', m.canRenderBold(undefined) === true]
];

// A generic-font bold box must still serialize font-weight:bold (renders Helvetica-Bold).
const boldGenericDoc = m.blankDocument();
const boldGenericBox = m.newTextBox(1, 1, 4, 0.5);
boldGenericBox.style = { ...boldGenericBox.style, bold: true, font: 'sans-serif' };
boldGenericBox.text = 'Generic bold';
boldGenericDoc.artboards[0].boxes.push(boldGenericBox);
const boldGenericHtml = m.serialize(boldGenericDoc, geo);

// An Arial-Unicode bold box must NOT serialize a no-op bold.
const boldUnicodeDoc = m.blankDocument();
const boldUnicodeBox = m.newTextBox(1, 1, 4, 0.5);
boldUnicodeBox.style = { ...boldUnicodeBox.style, bold: true, font: UNICODE };
boldUnicodeBox.text = 'Unicode bold';
boldUnicodeDoc.artboards[0].boxes.push(boldUnicodeBox);
const boldUnicodeHtml = m.serialize(boldUnicodeDoc, geo);

// The same for table bands (header/totals) under Arial Unicode MS.
const boldUnicodeTblDoc = m.blankDocument();
const boldUnicodeTbl = m.newTableBox(1, 3, 5);
boldUnicodeTbl.style = { ...boldUnicodeTbl.style, font: UNICODE };
boldUnicodeTbl.table.rows = [['Item', '1']];
boldUnicodeTbl.table.totals = { enabled: true, cells: ['Subtotal', '{Total}'] };
boldUnicodeTbl.table.headerText = { ...boldUnicodeTbl.table.headerText, font: UNICODE, bold: true };
boldUnicodeTbl.table.totalsText = { ...boldUnicodeTbl.table.totalsText, font: UNICODE, bold: true };
boldUnicodeTblDoc.artboards[0].boxes.push(boldUnicodeTbl);
const boldUnicodeTblHtml = m.serialize(boldUnicodeTblDoc, geo);

boldChecks.push(
    ['generic-font bold box still serializes bold', boldGenericHtml.includes('font-weight: bold;')],
    ['ArialUnicode bold box does not serialize a no-op bold', !boldUnicodeHtml.includes('font-weight: bold;')],
    [
        'ArialUnicode table header/totals bold suppressed',
        !boldUnicodeTblHtml.includes('font-weight: bold;') && boldUnicodeTblHtml.includes('font-weight: normal;')
    ]
);

const checks = [
    ...boldChecks,
    // 2.5in authored is the OUTER width. The default 2pt padding sits inside it, so the
    // emitted content width is 2.5 - 2x2pt = 2.444in and the box still measures 2.5in
    // edge to edge — which is what the author dragged and what the canvas draws.
    ['pinned box uses left/top in inches', html.includes('left: 2.4in; top: 3.1in; width: 2.444in;')],
    ['pinned box omits height (so it can grow)', !/class="dg-pin"[^>]*[^-]height:/.test(html)],
    ['flow box uses margin, not left/top', html.includes('margin: 5in 0 0 0.3in;')],
    ['second artboard carries the break class', html.includes('dg-artboard dg-artboard_break')],
    ['first artboard does NOT carry it', /<div class="dg-artboard" data-dg-artboard="1"/.test(html)],
    // min-height, never height: a pinned height is OVERRUN by growing merge content
    // instead of growing with it. 11in because margins now default to zero, so the
    // artboard IS the paper — that is what makes canvas coordinates page coordinates.
    [
        'artboard uses min-height not height',
        html.includes('min-height: 11in') && !/\.dg-artboard \{[^}]*[^-]height: 11in/.test(html)
    ],
    ['newlines become <br>', html.includes('{Name}<br />Industry: {Industry}')],
    ['merge tags survive escaping', html.includes('{Amount:currency:USD}') && html.includes('{Industry}')],
    // The engine un-escapes these itself (Word escapes the same characters), so a
    // conditional written with > still evaluates.
    ['conditional angle bracket is escaped, not dropped', html.includes('{#IF Amount &gt; 100000}')],
    ['table loop wraps the row inside tbody', /<tbody>\{#Opportunities\}<tr data-dg-row="loop">/.test(html)],
    // Roles are explicit so a round-trip cannot mistake one row for another and
    // duplicate it — the bug that made rows multiply on every open.
    ['every body row declares its role', !/<tbody>[\s\S]*?<tr(?![^>]*data-dg-row)/.test(html)],
    ['table loop closes right after the row', /<\/tr>\{\/Opportunities\}/.test(html)],
    ['table head repeats on continuation pages', html.includes('display: table-header-group')],
    ['table paginates', html.includes('-fs-table-paginate: paginate')],
    ['table is a FLOW box so it can grow', /class="dg-flow"[^>]*>\s*<table/.test(html)],
    ['literal rows land after the repeating row', html.indexOf('Note') > html.indexOf('{/Opportunities}')],
    // <tfoot> is a table-footer-group: it would repeat on EVERY page, and a grand
    // total on every page of a long invoice is wrong.
    ['totals row is NOT in tfoot', !html.includes('<tfoot')],
    // Both learned from reading the suggester's own output rather than trusting it.
    ['totals carry the column format through', suggested[1] === '{SUM:Opportunities.Amount:currency:USD}'],
    ['no aggregate suggested for a non-numeric field', suggested[0] === ''],
    // Inline marks live in the plain text and expand on serialize. This is what lets
    // the box stay a <textarea> — a contenteditable would hand Lightning's "/" hotkey
    // the chance to steal focus mid-typing, which was measured, not feared.
    ['bold mark expands', html.includes('<b>Net/30</b>')],
    ['italic mark expands', html.includes('<i>rush</i>')],
    ['underline mark expands', html.includes('<u>signed</u>')],
    ['strike mark expands', html.includes('<s>void</s>')],
    ['a slash inside a mark survives', html.includes('<b>Net/30</b>')],
    ['merge tag beside marks is untouched', html.includes('{Name}')],
    // #282: the __r / __c double underscores must not be absorbed by the underline
    // mark, or the pair of tags collapses into one <u> span and both print raw.
    ['a __r merge tag survives intact', html.includes('{Client__r.Name}')],
    ['a __c merge tag survives intact', html.includes('{Amount__c}')],
    ['no underline mark opens inside a merge tag', !html.includes('{Client<u>r.Name}')],
    ['no underline spans across two merge tags', !html.includes('<u>r.Name} / {Amount</u>')],
    // A mark that SPANS a tag must still expand — baking the slice split in would
    // resurrect literal ** in the PDF for every bolded merge tag.
    ['a mark spanning a merge tag still expands', html.includes('<b>Total: {Amount__c}</b>')],
    ['no literal ** survives into the output', !html.includes('**')],
    ['a literal < stays escaped, not turned into markup', html.includes('5 &lt; 10')],
    // A flow box's margin is the GAP from the previous flow box, never its absolute y.
    // Emitting y put a box authored at 7.5in seven and a half inches BELOW the table
    // instead of that far down the page, and the error compounded per box. Getting
    // this right is what makes a growing table push what is under it down.
    ['flow boxes stack by gap, not by absolute y', !/class="dg-flow"[^>]*margin: 7.5in/.test(html)],
    ['pinned boxes are emitted before flow ones', html.indexOf('dg-pin') < html.indexOf('dg-flow')],
    // The CSS is a rendering instruction, not a record of what the author did — a flow
    // box's margin is the GAP from the previous one, not its position. Reading the
    // margin back as y collapsed flow boxes toward the top on every reload, and with
    // height unstored the next save recomputed gaps from wrong heights and compounded.
    ['authoring coordinates are stored explicitly', /data-dg-x="0.5" data-dg-y="7.5"/.test(html)],
    [
        'every box records its mode',
        (html.match(/data-dg-mode="/g) || []).length === doc.artboards.reduce((n, b) => n + b.boxes.length, 0)
    ],
    ['height is stored, not just implied', /data-dg-h="/.test(html)],

    // --- Rich text ---------------------------------------------------------
    // A text box edited in the rich-text editor carries `html`. Serializing `text`
    // instead silently dropped every bold, bullet and MERGE TAG the author typed, while
    // the canvas went on showing them — the editor stopped being WYSIWYG and nothing
    // reported it.
    ['rich-text html is what gets serialized', html.includes('<b>Rich</b>')],
    ['merge tags typed in rich text survive', html.includes('{Owner.Name}')],
    // Escaped braces stay escaped: the starters use `&#123;…&#125;` as documentation
    // showing what a format suffix looks like, and decoding it would turn the example
    // into a live merge tag that prints the record's data.
    ['escaped braces are NOT turned into live tags', /&#123;braced&#125;|&amp;#123;/.test(html)],

    // --- Images ------------------------------------------------------------
    // Flying Saucer computes a replaced element's size ONCE PER URL, so the same image
    // at two sizes collapses to the first one's size unless each size gets its own URL.
    ['images carry the size-keyed cache-bust', /dgsz=w144/.test(html)],
    ['keep-ratio images size by width and let height follow', /width: 144px; height: auto/.test(html)],
    ['a field-bound image emits the engine token, not styled markup', html.includes('{%Logo__c:')],
    // An asset is referenced by KEY. Baking the ContentVersion Id in would pin the
    // document to whichever version was current the day it was authored, and replacing
    // the asset would silently not reach it.
    // The size token must carry an 'x'. parseImageTagSpec applies NO size when it does
    // not, so a bare number is silently ignored and the image renders at its intrinsic
    // size no matter how the box was sized on the canvas.
    ['a Portwood asset emits {%asset:key} with the box size', html.includes('{%asset:company-logo:144x}')],
    ['every image size token carries an x', !/\{%(?:asset:[a-z0-9_-]+|[A-Za-z0-9_.]+):\d+\}/.test(html)],
    ['no asset image is serialized as a raw shepherd URL', !/<img[^>]*company-logo/.test(html)],

    // --- Shapes ------------------------------------------------------------
    ['shapes are marked so they read back as shapes', /data-dg-shape="rect"/.test(html)],
    ['a horizontal line is one border side', /data-dg-shape="hline"[^>]*border-top:/.test(html)],
    // rgba() renders NOTHING in this engine rather than degrading to a solid colour.
    ['no rgba anywhere in the output', !/rgba?\(/.test(html)],

    // --- Page setup --------------------------------------------------------
    ['margins reach the @page rule', /@page \{ size: A4 landscape; margin: 1in 0.75in 1in 0.75in; \}/.test(a4Html)],
    // The artboard is the CONTENT area, so a pinned coordinate is measured inside the
    // margins. A4 landscape is 11.69 x 8.27in of paper.
    ['the artboard is paper minus margins', a4Geo.w === 10.19 && a4Geo.h === 6.27],
    ['page setup round-trips through the saved @page', /size: A4 landscape/.test(a4Html)],
    // --- QR / barcode ------------------------------------------------------
    // The engine replaces the whole tag with the drawn symbol, so a code box emits the
    // tag and nothing else — markup wrapped around it would describe a box that no
    // longer exists.
    ['a QR box emits the engine tag with its size', html.includes('{*Name:qr:192}')],
    ['a 1D barcode emits width x height', html.includes('{*AccountNumber:code128:288x96}')],
    // The tag alone cannot be read back into a type and a size, so the authoring
    // settings ride along as data attributes the engine ignores.
    ['code settings round-trip as data attributes', /data-dg-code-type="qr"[^>]*data-dg-code-field="Name"/.test(html)],
    ['a QR box is square at the requested pixel size', m.codeBoxSize({ type: 'qr', size: 192 }).w === 2],

    // 8in authored, minus 2x(3pt border + 6pt padding) = 18pt = 0.25in -> 7.75in.
    ['border and padding come OUT of the emitted width', html.includes('width: 7.75in')],
    ['the authored outer width is still what round-trips', html.includes('data-dg-w="8"')],

    // Both surfaces must state the SAME list contract, or a list looks one way while
    // authoring and another in the PDF. Measured: 1. / 2. / a. / i. / 3.
    ['nested lists get per-level markers', /ol ol \{ list-style: lower-alpha/.test(html)],
    ['lists declare an explicit indent', /ol \{ list-style: decimal outside; margin: 0 0 0 1.5em/.test(html)],

    [
        'a nested loop derives a NESTED subquery',
        derived.includes('(SELECT Name, Amount, (SELECT Name, Quantity FROM OpportunityLineItems) FROM Opportunities)')
    ],
    // {#IF …} opens a block, not a child collection. Treating it as one filed the
    // fields inside under a relationship that does not exist.
    ['a conditional does not become a relationship', derived.includes('Rating') && !derived.includes('FROM IF')],

    // The sub loop must sit INSIDE the parent loop. Outside it, every grandchild piles
    // up once at the end under whichever parent happened to be last.
    [
        'the nested loop sits inside the parent loop',
        /\{#Opportunities\}[\s\S]*\{#OpportunityLineItems\}[\s\S]*\{\/OpportunityLineItems\}[\s\S]*\{\/Opportunities\}/.test(
            nestHtml
        )
    ],
    // The table is as wide as its WIDEST row and every shorter row's last cell
    // stretches — in BOTH directions. A nested list with MORE columns than its parent
    // ("Opportunity Name" over "Product · Quantity") is the ordinary case, and handling
    // only the parent-wider one left the parent's single cell in a narrow column with
    // the rest of its row empty beside it.
    ['a short nested row spans the remaining columns', nestHtml.includes('colspan="2"')],
    ['a parent row stretches when the nested row is wider', widerNestHtml.includes('colspan="2"')],
    [
        'every row ends up the same width',
        (() => {
            const body = widerNestHtml.slice(widerNestHtml.indexOf('<tbody>'), widerNestHtml.indexOf('</tbody>'));
            const widths = [...body.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)].map((r) =>
                [...r[1].matchAll(/<td([^>]*)>/g)].reduce((a, c) => {
                    const sp = /colspan="(\d+)"/.exec(c[1]);
                    return a + (sp ? parseInt(sp[1], 10) : 1);
                }, 0)
            );
            return widths.length > 1 && new Set(widths).size === 1;
        })()
    ],
    ['the nested relationship round-trips as an attribute', nestHtml.includes('data-dg-subrel="OpportunityLineItems"')],
    [
        'grandchild fields nest in the derived query',
        m
            .buildQueryConfig(nestDoc)
            .includes(
                '(SELECT Name, StageName, Amount, (SELECT Name, Quantity FROM OpportunityLineItems) FROM Opportunities)'
            )
    ],

    // The signing parser turns underscores back into spaces, so a multi-word role must
    // travel underscored or it terminates at the first space.
    ['a multi-word signer role is underscored', sigHtml.includes('{@Signature_Account_Manager:2:Full}')],
    ['the inline flag rides after the type', sigHtml.includes('{@Signature_Customer:1:Date:inline}')],
    ['signature settings round-trip as attributes', sigHtml.includes('data-dg-sig-role="Account Manager"')],

    ['a custom size emits two lengths', /@page \{ size: 5.5in 8.5in;/.test(customHtml)],
    // Zero margins are what make the canvas and the page share an origin.
    ['margins default to zero', /margin: 0in 0in 0in 0in/.test(customHtml)],
    ['with no margin the artboard is the whole page', customGeo.w === 5.5 && customGeo.h === 8.5]
];

let bad = 0;

for (const [name, ok] of checks) {
    if (!ok) bad++;
    process.stdout.write((ok ? '  PASS  ' : '  FAIL  ') + name + '\n');
}
process.stdout.write(bad ? `\n${bad} FAILED\n` : '\nserializer OK\n');
process.exit(bad ? 1 : 0);

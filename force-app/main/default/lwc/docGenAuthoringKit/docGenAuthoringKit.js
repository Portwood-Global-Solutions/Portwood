/**
 * Authoring kit for the HTML-first template creation wizard.
 *
 * Three exports drive the "Start from a Design" and "Generate with AI" paths:
 *  - extractQueryShape(queryConfig, baseObject) — normalizes V1 SOQL strings,
 *    V3 node trees, and V4 provider configs into one { object, baseFields,
 *    parentFields, children } shape the builders consume.
 *  - buildStarterHtml(starterKey, shape) — renders a complete, CSS 2.1-safe
 *    HTML template body with the author's real merge fields injected, ready
 *    to save as v1 and generate on first click.
 *  - buildAiPrompt(shape, options) — assembles a copy-paste LLM prompt with
 *    the full Portwood tag cheat sheet, the Flying Saucer rendering constraints,
 *    and the template's actual schema.
 *
 * Every starter obeys the Flying Saucer envelope: CSS 2.1 only (no flex/grid/
 * calc/variables/gradients), table-based layout, solid colors, @page in the
 * source so the engine defers to it.
 */
import { parseSOQLFields } from 'c/docGenUtils';

/** 'Total_Amount__c' → 'Total Amount'; 'Owner.Name' → 'Owner Name'; 'FirstName' → 'First Name' */
export function humanizeField(apiName) {
    return (apiName || '')
        .replace(/__c$/i, '')
        .replace(/__r\./gi, ' ')
        .replace(/\./g, ' ')
        .replace(/_/g, ' ')
        .replace(/([a-z])([A-Z])/g, '$1 $2')
        .replace(/\s+/g, ' ')
        .trim();
}

/** Money-shaped field name → render with :currency and right-align. */
export function isMoneyField(apiName) {
    return /amount|total|price|cost|revenue|budget/i.test(apiName || '');
}

/** Quantity-shaped field name → summable, but no currency symbol. */
export function isQuantityField(apiName) {
    return /qty|quantity|hours|units|weight|points|score|seats|licenses/i.test(apiName || '');
}

/**
 * Normalize any Query_Config__c flavor into one simple shape.
 * Never throws — falls back to a Name-only shape so the starter/prompt
 * builders always have something render-worthy.
 */
export function extractQueryShape(queryConfig, baseObject) {
    const shape = {
        object: baseObject || 'Record',
        baseFields: [],
        parentFields: [],
        children: [],
        provider: null
    };
    const q = (queryConfig || '').trim();
    if (!q) {
        shape.baseFields = ['Name'];
        return shape;
    }
    try {
        if (q.startsWith('{')) {
            const cfg = JSON.parse(q);
            if (cfg.v === 4 && cfg.provider) {
                shape.provider = cfg.provider;
                shape.baseFields = ['Name'];
                return shape;
            }
            if (cfg.v === 3 && Array.isArray(cfg.nodes)) {
                const root = cfg.nodes.find((n) => !n.parentNode) || {};
                shape.baseFields = [...(root.fields || [])];
                shape.parentFields = [...(root.parentFields || [])];
                const collectKids = (parentId) => {
                    for (const k of cfg.nodes.filter((n) => n.parentNode === parentId)) {
                        shape.children.push({
                            relationshipName: k.alias || k.relationshipName,
                            fields: [...(k.fields || []), ...(k.parentFields || [])]
                        });
                        // Grandchildren flatten into the list too — starters render
                        // top-level child sections only, but the AI prompt lists all.
                        collectKids(k.id);
                    }
                };
                collectKids(root.id);
            }
        } else {
            const parsed = parseSOQLFields(q);
            shape.baseFields = parsed.baseFields || [];
            shape.parentFields = parsed.parentFields || [];
            const flatten = (subs) => {
                for (const sq of subs || []) {
                    shape.children.push({ relationshipName: sq.relationshipName, fields: sq.fields || [] });
                    flatten(sq.children);
                }
            };
            flatten(parsed.subqueries);
        }
    } catch (e) {
        // eslint-disable-line no-unused-vars
        // Unparseable config — keep going with a minimal shape.
    }
    if (shape.baseFields.length === 0 && shape.parentFields.length === 0) {
        shape.baseFields = ['Name'];
    }
    return shape;
}

// ---------------------------------------------------------------------------
// Shared HTML fragments
// ---------------------------------------------------------------------------

const BASE_CSS = `
        @page { size: Letter portrait; margin: 0.75in; }
        body { font-family: Helvetica, Arial, sans-serif; font-size: 10.5pt; color: #1a1a1a; margin: 0; }
        h1 { font-size: 20pt; margin: 0 0 2pt 0; color: #1f3a5f; }
        h2 { font-size: 13pt; margin: 18pt 0 6pt 0; color: #1f3a5f; border-bottom: 2pt solid #1f3a5f; padding-bottom: 3pt; }
        table { width: 100%; border-collapse: collapse; border-spacing: 0; }
        tr { page-break-inside: avoid; }
        td, th { padding: 5pt 7pt; vertical-align: top; }
        .meta { color: #666666; font-size: 9pt; }
        .label-cell { width: 35%; font-weight: bold; color: #444444; background: #f2f4f7; border-bottom: 1pt solid #ffffff; }
        .value-cell { border-bottom: 1pt solid #eeeeee; }
        .data-table th { background: #1f3a5f; color: #ffffff; text-align: left; font-size: 9.5pt; }
        .data-table td { border-bottom: 0.75pt solid #dddddd; }
        .footer-note { margin-top: 24pt; padding-top: 6pt; border-top: 1pt solid #cccccc; color: #888888; font-size: 8.5pt; }`;

function detailRows(fields) {
    return fields
        .map((f) => {
            const tag = isMoneyField(f) ? `{${f}:currency}` : `{${f}}`;
            return `            <tr>\n                <td class="label-cell">${humanizeField(f)}</td>\n                <td class="value-cell">${tag}</td>\n            </tr>`;
        })
        .join('\n');
}

// Loop tags must open in the first cell and close in the last so container
// auto-expansion repeats the whole <tr> per child row.
export function childLoopTable(child) {
    const rel = child.relationshipName;
    const fields = child.fields.length ? child.fields : ['Name'];
    const headCells = fields
        .map((f) => {
            const align = isMoneyField(f) ? ' style="text-align: right"' : '';
            return `                    <th${align}>${humanizeField(f)}</th>`;
        })
        .join('\n');
    const cells = fields
        .map((f, i) => {
            const money = isMoneyField(f);
            let inner = money ? `{${f}:currency}` : `{${f}}`;
            if (i === 0) inner = `{#${rel}}` + inner;
            if (i === fields.length - 1) inner = inner + `{/${rel}}`;
            const align = money ? ' style="text-align: right"' : '';
            return `                    <td${align}>${inner}</td>`;
        })
        .join('\n');
    return `        <table class="data-table">
            <thead>
                <tr>
${headCells}
                </tr>
            </thead>
            <tbody>
                <tr style="page-break-inside: avoid">
${cells}
                </tr>
            </tbody>
        </table>`;
}

function docShell(title, bodyInner, extraCss) {
    return `<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>${title}</title>
    <style>${BASE_CSS}${extraCss || ''}
    </style>
</head>
<body>
${bodyInner}
</body>
</html>
`;
}

// ---------------------------------------------------------------------------
// Starters
// ---------------------------------------------------------------------------

function buildReport(shape) {
    const detailFields = [...shape.baseFields, ...shape.parentFields];
    const sections = shape.children
        .map((c) => `\n    <h2>${humanizeField(c.relationshipName)}</h2>\n${childLoopTable(c)}`)
        .join('\n');
    const inner = `    <table>
        <tr>
            <td style="width: 120pt; vertical-align: middle">{%asset:logo:144x}</td>
            <td>
                <h1>{Name}</h1>
                <div class="meta">${humanizeField(shape.object)} Report</div>
            </td>
            <td style="text-align: right" class="meta">
                Prepared by {RunningUser.Name}<br />
                {Today:MMMM d, yyyy}
            </td>
        </tr>
    </table>

    <h2>Details</h2>
    <table>
${detailRows(detailFields)}
    </table>
${sections}

    <div class="footer-note">Generated with Portwood &#8226; {Today:MM/dd/yyyy}</div>`;
    return docShell('Record Report', inner);
}

function buildLetter(shape) {
    const inner = `    <table>
        <tr>
            <td style="width: 110pt; vertical-align: middle">{%asset:logo:144x}</td>
            <td>
                <h1 style="font-size: 14pt">Your Company Name</h1>
                <div class="meta">123 Your Street &#8226; Your City, ST 00000 &#8226; (555) 555-0100</div>
            </td>
            <td style="text-align: right" class="meta">{Today:MMMM d, yyyy}</td>
        </tr>
    </table>

    <p style="margin-top: 28pt">{Name}</p>

    <p style="margin-top: 18pt">Dear {Name},</p>

    <p>
        Replace this paragraph with your letter body. Any field from your Query Config drops in with a merge
        tag &#8212; for example, this record is {Name}. Format dates and money with suffixes like
        &#123;CloseDate:MMMM d, yyyy&#125; and &#123;Amount:currency&#125;.
    </p>

    <p>
        A second paragraph of your letter. Conditional blocks let you include text only when a field has a
        value, and loops repeat a block for every child record.
    </p>

    <p style="margin-top: 30pt">
        Sincerely,<br /><br /><br />
        {RunningUser.Name}<br />
        <span class="meta">{RunningUser.Title}</span>
    </p>`;
    return docShell('Business Letter', inner);
}

function buildInvoice(shape) {
    const child = shape.children[0];
    const rel = child ? child.relationshipName : null;
    const sumField = child ? child.fields.find(isMoneyField) : null;
    const lineTable = child
        ? childLoopTable(child)
        : `        <table class="data-table">
            <thead>
                <tr>
                    <th>Description</th>
                    <th style="text-align: right">Amount</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>Add a child relationship in your Query Config to loop line items here.</td>
                    <td style="text-align: right">&#8212;</td>
                </tr>
            </tbody>
        </table>`;
    const totalRow =
        rel && sumField
            ? `\n    <table style="margin-top: 8pt">
        <tr>
            <td style="width: 70%"></td>
            <td class="label-cell" style="text-align: right">Total</td>
            <td class="value-cell" style="text-align: right; font-weight: bold">{SUM:${rel}.${sumField}:currency}</td>
        </tr>
    </table>`
            : '';
    const inner = `    <table>
        <tr>
            <td style="width: 110pt; vertical-align: middle">{%asset:logo:144x}</td>
            <td>
                <h1>INVOICE</h1>
                <div class="meta">Your Company Name</div>
            </td>
            <td style="text-align: right" class="meta">
                Date: {Today:MM/dd/yyyy}<br />
                Reference: {Name}
            </td>
        </tr>
    </table>

    <h2>Billed To</h2>
    <table>
${detailRows([...shape.baseFields, ...shape.parentFields])}
    </table>

    <h2>Line Items</h2>
${lineTable}${totalRow}

    <div class="footer-note">Payment due within 30 days &#8226; Generated {Today:MMMM d, yyyy} by {RunningUser.Name}</div>`;
    return docShell('Invoice', inner);
}

function buildAgreement(shape) {
    const inner = `    <h1 style="text-align: center">Agreement</h1>
    <p class="meta" style="text-align: center">Effective {Today:MMMM d, yyyy}</p>

    <p style="margin-top: 20pt">
        This Agreement is entered into between <strong>Your Company Name</strong> ("Company") and
        <strong>{Name}</strong> ("Customer").
    </p>

    <h2>1. Scope</h2>
    <p>Describe the goods or services covered by this agreement. Merge any field from your Query Config, e.g. {Name}.</p>

    <h2>2. Term</h2>
    <p>This agreement begins on {Today:MMMM d, yyyy} and continues until terminated by either party.</p>

    <h2>3. Signatures</h2>
    <p>Signed and agreed by the parties below.</p>

    <table style="margin-top: 30pt">
        <tr>
            <td style="width: 48%">
                {@Signature_Customer:1:Full}
                <div style="border-top: 1pt solid #333333; margin-top: 4pt; padding-top: 3pt" class="meta">
                    Customer &#8226; Date: {@Signature_Customer:1:Date}
                </div>
            </td>
            <td style="width: 4%"></td>
            <td style="width: 48%">
                {@Signature_Company_Representative:2:Full}
                <div style="border-top: 1pt solid #333333; margin-top: 4pt; padding-top: 3pt" class="meta">
                    Company Representative &#8226; Date: {@Signature_Company_Representative:2:Date}
                </div>
            </td>
        </tr>
    </table>`;
    return docShell('Agreement', inner);
}

function buildCertificate(shape) {
    const inner = `    <div style="border: 3pt solid #1f3a5f; padding: 6pt; min-height: 516pt">
        <div style="border: 1pt solid #c9a227; padding: 34pt 44pt; text-align: center; min-height: 446pt">
            <div class="meta" style="letter-spacing: 4pt; font-size: 9pt; color: #1f3a5f">
                YOUR ORGANIZATION &#8226; REPLACE WITH YOUR NAME
            </div>
            <h1
                style="font-family: Georgia, 'Times New Roman', serif; font-size: 30pt; margin: 16pt 0 6pt 0; color: #1f3a5f"
            >
                Certificate of Achievement
            </h1>
            <table style="width: 180pt; margin: 0 auto">
                <tr>
                    <td style="border-bottom: 2pt solid #c9a227; padding: 0">&nbsp;</td>
                </tr>
            </table>
            <p style="margin-top: 20pt; font-style: italic; font-size: 12pt">This certifies that</p>
            <p
                style="font-family: Georgia, 'Times New Roman', serif; font-size: 24pt; margin: 6pt 0; color: #1f3a5f"
            >
                {Name}
            </p>
            <p style="font-size: 11pt; margin: 12pt 50pt 0 50pt">
                has successfully completed the requirements &#8212; replace this line with what the certificate
                recognizes. Merge any field from your Query Config; today's date is always available as
                &#123;Today:MMMM d, yyyy&#125;.
            </p>
            <table style="margin-top: 36pt">
                <tr style="page-break-inside: avoid">
                    <td style="width: 33%; text-align: center; vertical-align: bottom">
                        <div style="border-top: 1pt solid #333333; margin: 0 16pt; padding-top: 4pt" class="meta">
                            Date &#8226; {Today:MMMM d, yyyy}
                        </div>
                    </td>
                    <td style="width: 34%; text-align: center; vertical-align: middle">{%asset:logo:120x}</td>
                    <td style="width: 33%; text-align: center; vertical-align: bottom">
                        <div style="border-top: 1pt solid #333333; margin: 0 16pt; padding-top: 4pt" class="meta">
                            {RunningUser.Name}<br />Authorized Signature
                        </div>
                    </td>
                </tr>
            </table>
        </div>
    </div>`;
    // Replace the base @page instead of appending a second rule — the PDF
    // engine cascades to the last rule, but pickers/canvas read the doc's
    // page rule, so there must be exactly one.
    return docShell('Certificate', inner).replace(
        '@page { size: Letter portrait; margin: 0.75in; }',
        '@page { size: Letter landscape; margin: 0.5in; }'
    );
}

export const STARTERS = [
    {
        key: 'report',
        label: 'Record Report',
        icon: 'utility:summarydetail',
        description:
            'Title band, a details table of your fields, and a table per child relationship. The safe default for any object.'
    },
    {
        key: 'invoice',
        label: 'Invoice / Line Items',
        icon: 'utility:money',
        description:
            'Billed-to block plus a line-item loop table from your first child relationship, with an automatic total row.'
    },
    {
        key: 'letter',
        label: 'Business Letter',
        icon: 'utility:email',
        description: 'Letterhead, date, salutation, and body copy with merge fields — signed by the running user.'
    },
    {
        key: 'agreement',
        label: 'Agreement (Signature-ready)',
        icon: 'utility:signature',
        description: 'Numbered terms with a two-party e-signature block wired to Portwood signature tags.'
    },
    {
        key: 'certificate',
        label: 'Certificate / Award',
        icon: 'utility:favorite',
        description:
            'Landscape certificate with a double frame, centered recipient name, and a date + seal + signature row. Add your logo as the seal.',
        page: { orientation: 'Landscape', size: 'Letter', margins: 'Narrow' }
    }
];

const BUILDERS = {
    report: buildReport,
    invoice: buildInvoice,
    letter: buildLetter,
    agreement: buildAgreement,
    certificate: buildCertificate
};

export function buildStarterHtml(starterKey, shape) {
    const builder = BUILDERS[starterKey] || buildReport;
    return builder(shape);
}

// ---------------------------------------------------------------------------
// AI prompt
// ---------------------------------------------------------------------------

/**
 * #248 — annotate a field in the prompt's data-shape listing with its Salesforce type
 * and the format suffix that type usually wants.
 *
 * Without the type the model emits bare {Amount} / {CloseDate} tags and the author has
 * to go back and add formatting by hand. With it, the model picks sensible suffixes
 * itself. `type` is the Schema.DisplayType name returned by
 * DocGenController.getObjectFields (STRING, CURRENCY, DATE, …); when it is missing the
 * annotation is simply omitted.
 */
function describeFieldForPrompt(fieldName, type) {
    if (!type) {
        return '';
    }
    const t = String(type).toUpperCase();
    const hint = {
        CURRENCY: ' — format as {' + fieldName + ':currency}',
        DOUBLE: ' — format as {' + fieldName + ':#,##0.00}',
        INTEGER: ' — format as {' + fieldName + ':number}',
        LONG: ' — format as {' + fieldName + ':number}',
        PERCENT: ' — format as {' + fieldName + ':percent}',
        DATE: ' — format as {' + fieldName + ':MMMM d, yyyy}',
        DATETIME: ' — format as {' + fieldName + ':MMMM d, yyyy h:mm a}',
        BOOLEAN: ' — render as {' + fieldName + ':checkbox} for an [X]/[ ] box',
        PICKLIST: ' — use {' + fieldName + ':label} to print the label rather than the API value',
        MULTIPICKLIST: ' — semicolon-delimited values',
        REFERENCE: ' — a lookup Id; dot through it for readable text, e.g. {' + fieldName + '.Name}',
        TEXTAREA: ' — may contain line breaks',
        EMAIL: '',
        PHONE: '',
        URL: '',
        ID: ''
    }[t];
    return ` (${t}${hint === undefined ? '' : hint})`;
}

/**
 * Assemble a self-contained LLM prompt: rendering constraints + tag syntax +
 * this template's actual schema. Works pasted into any assistant.
 */
export function buildAiPrompt(shape, options) {
    const opts = options || {};
    const lines = [];
    lines.push(
        'You are writing an HTML document template for Portwood, a native Salesforce document-generation package. The template is a single self-contained HTML file. Portwood replaces {merge tags} with Salesforce record data, then renders the HTML to PDF with the Flying Saucer engine.'
    );
    lines.push('');
    lines.push('HARD RENDERING CONSTRAINTS (Flying Saucer = CSS 2.1 plus a small CSS 3 subset):');
    lines.push('- Layout with <table>/<tr>/<td>, or <div> with display:table / table-row / table-cell.');
    lines.push(
        '- NEVER use: flexbox, grid, gap, calc(), CSS variables, linear-gradient or any gradient, position:sticky, transforms. They are silently ignored and the layout collapses.'
    );
    lines.push('- Solid colors only. No web fonts — stick to Helvetica/Arial/Times/Georgia/Courier.');
    lines.push(
        "- No <svg> and no JavaScript — they are dropped. Images must be <img> with regular src URLs; don't invent image URLs."
    );
    lines.push(
        '- Avoid child selectors involving tbody (e.g. table > tbody > tr) — they silently fail. Use classes on cells instead.'
    );
    lines.push(
        '- Declare the page setup with an @page rule in a <style> block, e.g. @page { size: Letter portrait; margin: 0.75in; }'
    );
    lines.push(
        '- Every {...} pair is treated as a merge tag: unknown names render as empty text, and an unclosed { fails the merge. For literal braces use &#123; and &#125;.'
    );
    lines.push('');
    lines.push('PORTWOOD MERGE TAG SYNTAX:');
    lines.push(
        '- Field: {FieldName} — e.g. {Name}, {Status__c}. Parent lookups dot through: {Account.Name}, {Owner.Profile.Name}. Null renders as empty string.'
    );
    lines.push(
        '- Format suffixes: {CloseDate:MMMM d, yyyy} (Java SimpleDateFormat), {CloseDate:date} (user locale), {Amount:currency}, {Amount:currency:EUR}, {Qty:number}, {Qty:#,##0.00}, {Rate:percent}, {IsActive:checkbox} ([X]/[ ]), {Status__c:label} (picklist label).'
    );
    lines.push(
        '- Child loop: {#RelationshipName} ... {/RelationshipName} repeats the block per child record; child fields are bare inside the loop. If the tags sit inside a table row, the whole <tr> repeats — put {#Rel} in the first cell and {/Rel} in the last cell of the data row. Use a real <thead> for column headers. Nested loops are supported. An empty child list renders nothing — no error.'
    );
    lines.push(
        '- Row numbering: {RowNumber} inside any loop is that row’s 1-based position — use it for a "#" column. It counts the rows actually rendered, keeps counting through very large tables, restarts at 1 for each nested loop and for each {#GroupBy} group, and resolves to nothing outside a loop. Accepts format suffixes ({RowNumber:number}).'
    );
    lines.push(
        '- Group into separate tables/sections by a field value: {#GroupBy RelationshipName by GroupField} ... {/GroupBy} repeats its whole block once per DISTINCT value of GroupField among the child records (first-seen order; dot-paths like Product2.Family allowed). Inside the block, {GroupName} is that group’s value (use it as the header), the inner {#RelationshipName}...{/RelationshipName} loops only that group’s members, {RowNumber} restarts at 1, and {SUM|COUNT|AVG|MIN|MAX:RelationshipName.Field} aggregate just that group. Ideal when the user wants "a table per <type/category>" without knowing the values in advance — 50 distinct values produce 50 tables, with no need to know them up front. Give each group its own <table> WITH its own <thead>, and put the whole table inside the {#GroupBy} block.'
    );
    lines.push(
        '- Group-block example: {#GroupBy Lines by Product2.Family}<h3>{GroupName}</h3><table><thead><tr><th>#</th><th>Product</th><th>Amount</th></tr></thead><tbody><tr><td>{#Lines}{RowNumber}</td><td>{Product2.Name}</td><td>{TotalPrice:currency}{/Lines}</td></tr><tr><td colspan="2">Subtotal</td><td>{SUM:Lines.TotalPrice:currency}</td></tr></tbody></table>{/GroupBy}'
    );
    lines.push('- Conditional: {#SomeField} shown when truthy {:else} otherwise {/SomeField}.');
    lines.push('- Inverse conditional: {^SomeField} shown when the field is FALSY {:else} otherwise {/SomeField}.');
    lines.push(
        "- Comparison conditional: {#IF Amount > 100000} ... {:else} ... {/IF}. Operators > < >= <= = (or ==) != against a field, a number, or a quoted string (case-sensitive). Combine with AND / OR / NOT (or && || !) and parentheses: {#IF (Amount > 1000 AND StageName = 'Closed Won') OR Type = 'Renewal'}. Nest {#IF} blocks freely. To render a section only when a child list has rows, use {#IF RelationshipName.totalSize != 0} — totalSize is 0, never null, on an empty relationship."
    );
    lines.push(
        '- Aggregates (grand totals across a child list, place OUTSIDE the loop): {SUM:Rel.Field}, {AVG:Rel.Field}, {MIN:Rel.Field}, {MAX:Rel.Field}, {COUNT:Rel} or {COUNT:Rel.Field}. All accept format suffixes: {SUM:Lines.Amount:currency}, {SUM:Lines.Amount:currency:EUR:de_DE} (ISO + locale), {SUM:Lines.Amount:currency:auto} (record currency), {COUNT:Lines:number}. The aggregated field must be in the Query Config, but does NOT need to be a rendered column.'
    );
    lines.push(
        '- Built-ins: {Today:MMMM d, yyyy}, {Now:yyyy-MM-dd HH:mm}, and running-user tags {RunningUser.Name}, {RunningUser.Email}, {RunningUser.Title}.'
    );
    lines.push(
        '- Barcodes & QR codes (rendered server-side — no fonts, no external services, no <img> of your own): {*FieldName} = Code 128 barcode of the field value; {*FieldName:code128:300x80} = Code 128 sized 300x80px; {*FieldName:qr} = QR code; {*FieldName:qr:200} = QR at 200px. ONLY code128 and qr are supported — any other type renders nothing, silently. QR handles URLs and long text and survives low print quality best; Code 128 suits short IDs and serials. Place the tag alone in its own cell/block with white space around it — do not shrink below the default or scanners will struggle. Any queried field works, e.g. {*Id}, {*Name}, {*Tracking_Number__c}.'
    );
    lines.push(
        '- Charts — ONE-LINE TAG, this is the path to use: {Chart:RelationshipName:FieldToGroupBy:style:opt=value&opt=value}, on its own line as a block-level element. Portwood aggregates the child records server-side and renders it as a real image, so you do NOT style it — no wrapper markup, no CSS bars. Styles: bar (horizontal, best for long labels), column (vertical), pie, donut, line, area, and the cross-tab styles stacked, clustered, pivot (these three REQUIRE groupBy=). Default style is bar. Modifiers, joined with &: title=Text (header drawn above the chart), width=420, height=240, colors=#1e40af,#b91c1c (6-char hex, cycles), groupBy=SecondField__c (second dimension), colSort=A,B,C (column order), where=SOQL fragment, split=; (multi-select field). Examples: {Chart:Survey_Responses__r:Answer__c:bar:title=Responses by Answer} and {Chart:Survey_Responses__r:Answer__c:stacked:groupBy=Location__c&title=Answer by Location}. Inside a {#Rel} loop the chart’s relationship resolves against the record being iterated, giving one chart per row.'
    );
    lines.push(
        '- Charts — hand-authored fallback, use ONLY when the one-line tag cannot produce the layout asked for: {#ChartBucket:Rel:Field} {key} {count} {percent} {/ChartBucket} groups child records by Field and repeats the body per bucket, so you style it yourself as CSS bars (a <div> whose width uses {percent}). Keep it CSS-only; no SVG or canvas.'
    );
    lines.push(
        '- Record images: {%FieldName} renders the image stored in a file/ContentVersion field, {%Image:1} renders the Nth file attached to the record. Size them INSIDE the tag — {%FieldName:160x} (160px wide), {%Image:1:x80} (80px tall), {%FieldName:200x80} (exact) — CSS width/height on the tag does NOT size the image in the PDF.'
    );
    lines.push(
        '- Rich text / long text fields pass their formatting through automatically (paragraphs, bold, italic, links, line breaks). Do not wrap them in <pre> or escape them.'
    );
    lines.push(
        '- Page numbers: {PageNumber} and {TotalPages} work ONLY in the template’s Header HTML / Footer HTML fields, never in the body — do not put them in the document you write; mention them to the user instead if they ask for page numbering.'
    );
    lines.push(
        '- E-signature placeholders (only if asked for a signable document): {@Signature_RoleName:1:Full}, {@Signature_RoleName:1:Initials}, {@Signature_RoleName:1:Date}, {@Signature_RoleName:1:DatePick}. Role is any string (underscores become spaces), then the signing order, then the type. Add :inline as a final suffix for a compact in-place mark instead of a stamp card. When the number of signers varies, use the {#Signatures} ... {/Signatures} loop instead of fixed role tags.'
    );
    lines.push('');
    lines.push('DATA SHAPE — use ONLY these fields (any other tag renders empty):');
    if (opts.dataSourceMode === 'flow') {
        lines.push(
            '- Data arrives at runtime as JSON from a Salesforce Flow. Describe your JSON keys to me here, then use them as {key} tags. Lists loop with {#listKey}...{/listKey}.'
        );
    } else if (shape.provider) {
        lines.push(`- Data comes from the Apex provider class ${shape.provider}. Fields available:`);
        for (const f of opts.providerFields || []) {
            lines.push(`  - {${f}}`);
        }
        if (!(opts.providerFields || []).length) {
            lines.push('  - (list your provider field names here before pasting)');
        }
    } else {
        const types = opts.fieldTypes || {};
        lines.push(`- Base object: ${shape.object}`);
        for (const f of [...shape.baseFields, ...shape.parentFields]) {
            const note = describeFieldForPrompt(f, types[f]);
            lines.push(`  - {${f}}${note}${f.includes('.') ? ' (parent lookup)' : ''}`);
        }
        for (const c of shape.children) {
            lines.push(`- Child relationship: {#${c.relationshipName}} ... {/${c.relationshipName}}`);
            lines.push('  Fields (write them BARE inside the loop, with no relationship prefix):');
            for (const f of c.fields) {
                lines.push(`    - {${f}}${describeFieldForPrompt(f, types[c.relationshipName + '.' + f])}`);
            }
        }
        lines.push('');
        // #248 — the single most common thing an LLM gets wrong when generating a
        // Portwood template: it puts the loop tags on their own lines wrapping the
        // <table>, which repeats the whole table instead of the row.
        lines.push('REPEATING TABLES — READ THIS TWICE, IT IS THE MOST COMMON MISTAKE:');
        lines.push(
            '- Loop tags for a repeating table go INLINE, INSIDE the row that repeats: the opening {#Rel} in the FIRST cell of the data <tr>, and the closing {/Rel} in the LAST cell of that same <tr>.'
        );
        lines.push(
            '- Do NOT put {#Rel} on its own line above <table> and {/Rel} below it. That repeats the ENTIRE TABLE — headers and all — once per child record, which is never what is wanted.'
        );
        lines.push('- Column headers belong in a real <thead>, OUTSIDE the loop, so they render once.');
        if (shape.children && shape.children.length) {
            const c = shape.children[0];
            const cols = (c.fields || []).slice(0, 3);
            if (cols.length) {
                lines.push('- Correct shape, using this template’s own data:');
                lines.push('  <table>');
                lines.push('    <thead>');
                lines.push(`      <tr>${cols.map((f) => `<th>${f}</th>`).join('')}</tr>`);
                lines.push('    </thead>');
                lines.push('    <tbody>');
                lines.push(
                    `      <tr><td>{#${c.relationshipName}}{${cols[0]}}</td>` +
                        cols
                            .slice(1, -1)
                            .map((f) => `<td>{${f}}</td>`)
                            .join('') +
                        (cols.length > 1
                            ? `<td>{${cols[cols.length - 1]}}{/${c.relationshipName}}</td>`
                            : `<td>{/${c.relationshipName}}</td>`) +
                        '</tr>'
                );
                lines.push('    </tbody>');
                lines.push('  </table>');
            }
        }
    }
    const assets = opts.assets || [];
    if (assets.length) {
        lines.push('');
        lines.push('SHARED IMAGE ASSETS (already stored in Salesforce — reference by tag, do NOT invent image URLs):');
        for (const a of assets) {
            const sizedExample = a.mergeTag.replace(/\}$/, ':160x}');
            lines.push(
                `  - ${a.mergeTag} — ${a.name}. Example placement: <td style="width:170pt">${sizedExample}</td>.`
            );
        }
        lines.push('  IMAGE SIZING (critical — an unsized image renders at full resolution and can swallow the page):');
        lines.push(
            '  ALWAYS put a size token INSIDE the tag: {%asset:key:160x} = 160px wide (height auto), {%asset:key:x80} = 80px tall, {%asset:key:200x80} = exact 200x80px. Pick px sizes for print: ~96px per inch (a 1.5in logo = 144x).'
        );
        lines.push(
            '  Do NOT rely on CSS width/height on the tag or a wrapper to size these images — the size token is what the PDF engine honors. CSS on the surrounding cell only reserves layout space.'
        );
    }
    lines.push('');
    // EDIT MODE — revising a template that already exists. Same constraints and
    // same data shape as above; only the task and the output contract differ.
    // Kept in this one builder so the create and edit paths cannot drift apart,
    // which is also why "Copy AI Prompt" and the in-org button share it.
    if (opts.mode === 'edit' && opts.currentBody && opts.currentBody.trim()) {
        lines.push('YOUR TASK — EDIT AN EXISTING TEMPLATE, DO NOT WRITE A NEW ONE:');
        lines.push(
            'Below is the template as it stands today. Apply the requested change to it and return the result. This is a revision, not a fresh start.'
        );
        lines.push('');
        lines.push('CURRENT TEMPLATE (between the >>> markers, which are NOT part of the document):');
        lines.push('>>>BEGIN CURRENT TEMPLATE');
        lines.push(opts.currentBody.trim());
        lines.push('>>>END CURRENT TEMPLATE');
        lines.push('');
        lines.push('WHAT TO CHANGE:');
        lines.push(
            opts.docDescription && opts.docDescription.trim()
                ? opts.docDescription.trim()
                : '<<DESCRIBE THE CHANGE YOU WANT, e.g. "make the header band dark green", "add a totals row under the line items", "move the date to the top right".>>'
        );
        lines.push('');
        lines.push('EDIT RULES — these matter more than anything else here:');
        // Rule 0 is the one that measurably moved the needle. A first attempt
        // without it applied only the first of two requested changes and
        // reworded the text it did add. With it, five discrete edits in one
        // sentence landed 5/5 across repeated runs. Extra prose structure
        // beyond this (numbered step-by-step scaffolding, delimiter styling)
        // did NOT measurably improve on it at that difficulty — so the
        // instruction is what counts, not the packaging around it.
        lines.push(
            '0. Apply EVERY change asked for above, not just the first one. Break the request into discrete edits first — one sentence often contains several. If you cannot find the element or rule an edit refers to, ADD it rather than skipping it, then re-read your list before returning and confirm every item is present in your output. Use the exact wording given for any text to add, and the exact colour named — if a colour is named without a hex value, pick a specific hex for it and actually change the rule that sets it.'
        );
        lines.push(
            '1. Return the COMPLETE modified HTML document (<!DOCTYPE html> ... </html>). Not a fragment, not a diff, not only the part you changed, no commentary, no markdown fences.'
        );
        lines.push(
            '2. Change ONLY what was asked. Every other element, style rule, table, and piece of text must come back byte-for-byte as it went in.'
        );
        lines.push(
            '3. NEVER drop, rename or reword a merge tag — anything in {curly braces} is a live data binding, and losing one silently blanks that value in every generated document. Keep them all unless the change explicitly asks you to remove one.'
        );
        lines.push(
            '4. Keep the existing @page rule, page size and margins unless the change is specifically about page setup.'
        );
        lines.push(
            '5. Obey every rendering constraint listed above — the edited file still has to survive Flying Saucer.'
        );
        lines.push('');
        lines.push(
            'QUESTIONS? The full Portwood UserGuide covers every merge tag, format suffix, and PDF rendering rule — look it up if anything here is unclear: https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md'
        );
        return lines.join('\n');
    }

    lines.push('WHAT I WANT THIS DOCUMENT TO BE:');
    if (opts.docDescription && opts.docDescription.trim()) {
        lines.push(opts.docDescription.trim());
    } else {
        lines.push(
            '<<DESCRIBE YOUR DOCUMENT HERE: purpose, sections, tone, branding colors. Example: "A two-page account summary: header with account name and logo placeholder, key details table, then a table of open opportunities with a total row.">>'
        );
    }
    lines.push('');
    lines.push('OUTPUT REQUIREMENTS:');
    lines.push(
        '1. Return ONE complete self-contained HTML file (<!DOCTYPE html> ... </html>) with all CSS inline in a single <style> block. No commentary, no markdown fences.'
    );
    lines.push('2. Professional print-ready design within the CSS 2.1 constraints above.');
    lines.push(
        '3. Only bind to field names listed in DATA SHAPE. On top of those you may use any tag from PORTWOOD MERGE TAG SYNTAX above — {RowNumber}, {#GroupBy}/{GroupName}, {#IF}, aggregates, {Chart:...}, {Today}/{Now}, {RunningUser.*} — since those are built into the engine and need no field of their own.'
    );
    lines.push('');
    lines.push(
        'QUESTIONS? The full Portwood UserGuide covers every merge tag, format suffix, and PDF rendering rule — look it up if anything here is unclear: https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md'
    );
    return lines.join('\n');
}

// ---------------------------------------------------------------------------
// HTML pretty-printer (Format Code button)
// ---------------------------------------------------------------------------

const VOID_TAGS = /^(area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/i;

/**
 * Conservative HTML formatter for the template editors. Only inserts
 * whitespace BETWEEN adjacent tags (never inside text runs), so merge tags
 * and inline text spacing are untouched. <style>/<script>/<pre>/<textarea>
 * blocks pass through verbatim.
 */
export function prettyPrintHtml(html) {
    if (!html || typeof html !== 'string') {
        return html;
    }
    const protectedBlocks = [];
    let work = html.replace(/<(style|script|pre|textarea)\b[\s\S]*?<\/\1\s*>/gi, (m) => {
        protectedBlocks.push(m);
        return '@@DGBLK' + (protectedBlocks.length - 1) + '@@';
    });
    // Break only where two tags touch (optionally separated by pure whitespace),
    // and around protected-block placeholders so they land on their own line.
    work = work
        .replace(/>\s*</g, '>\n<')
        .replace(/(@@DGBLK\d+@@)\s*</g, '$1\n<')
        .replace(/>\s*(@@DGBLK\d+@@)/g, '>\n$1');
    const lines = work.split('\n');
    const out = [];
    let depth = 0;
    for (const raw of lines) {
        const line = raw.trim();
        if (!line) {
            continue;
        }
        const isClosing = /^<\//.test(line);
        if (isClosing) {
            depth = Math.max(0, depth - 1);
        }
        out.push('    '.repeat(depth) + line);
        const openMatch = line.match(/^<([a-zA-Z][\w-]*)/);
        if (openMatch && !isClosing) {
            const tag = openMatch[1];
            const selfClosed = /\/>\s*$/.test(line) || VOID_TAGS.test(tag);
            const closedSameLine = new RegExp('</' + tag + '\\s*>\\s*$', 'i').test(line);
            if (!selfClosed && !closedSameLine) {
                depth++;
            }
        }
    }
    return out.join('\n').replace(/@@DGBLK(\d+)@@/g, (m, i) => protectedBlocks[Number(i)]);
}

// ---------------------------------------------------------------------------
// Inline preview (Code ⇄ Preview toggle)
// ---------------------------------------------------------------------------

/**
 * Prepare template HTML for INLINE rendering inside the admin UI.
 *
 * Lightning Web Security blocks iframe srcdoc/document.write, so the preview
 * renders straight into a lwc:dom="manual" div. To keep the template's CSS
 * from leaking into the admin page, every selector is prefixed with the
 * .dg-pv scope class (html/body selectors are remapped to the scope itself),
 * @page rules are dropped (meaningless inline), and scripts/event handlers
 * are stripped. Merge tags render as-is — this is a layout preview, not a
 * data merge.
 */
export function scopeHtmlForInlinePreview(html) {
    let work = (html || '').replace(/<script\b[\s\S]*?<\/script\s*>/gi, '').replace(/<link\b[^>]*>/gi, '');
    const styles = [];
    work = work.replace(/<style\b[^>]*>([\s\S]*?)<\/style\s*>/gi, (m, css) => {
        styles.push(css);
        // Leave an INERT copy where the author put it, rather than deleting it
        // (#322). The scoped sheet below is what actually renders the preview;
        // this copy exists so the serializer can hand the author's own CSS back
        // unchanged. `type` is deliberately not text/css, so the browser parses
        // it as an unknown data block and never applies it — otherwise an
        // unscoped `body { … }` rule would leak into the Lightning page.
        //
        // A copy in the <head> is discarded with the rest of the head below; one
        // in the <body> survives into the canvas and back out again. That second
        // case is the bug: `querySelectorAll('style')` on the way out could not
        // tell the editor's injected sheet from the author's, removed both, and
        // silently destroyed a stylesheet the author had written inside <body>.
        return '<style data-dg-authored="1" type="text/dg-css">' + css + '</style>';
    });
    const bodyMatch = work.match(/<body\b[^>]*>([\s\S]*?)<\/body\s*>/i);
    let content = bodyMatch ? bodyMatch[1] : work.replace(/<\/?(?:!DOCTYPE|html|head|body|meta|title)\b[^>]*>/gi, '');
    // Strip inline event handlers (on*="...") — static preview only.
    content = content.replace(/\son\w+\s*=\s*(["'])[\s\S]*?\1/gi, '');

    let css = styles.join('\n').replace(/@page\b[^{]*{[^}]*}/gi, '');
    // Prefix every selector with the scope class. Handles the flat CSS 2.1
    // rules templates use; at-rule headers (@media etc.) pass through and
    // their inner rules get scoped by the same pass.
    css = css.replace(/(^|})([^{}@]+){/g, (m, brace, selectors) => {
        const scoped = selectors
            .split(',')
            .map((s) => {
                const sel = s.trim();
                if (!sel) {
                    return sel;
                }
                if (/^(html|body)$/i.test(sel)) {
                    return '.dg-pv';
                }
                return '.dg-pv ' + sel.replace(/^(html|body)\s+/i, '');
            })
            .join(', ');
        return brace + '\n' + scoped + ' {';
    });

    // Baseline "paper sheet" look, injected with the content because
    // component CSS can't reach lwc:dom="manual" children. Declared first so
    // the template's own (scoped) rules win any conflicts. Page-break
    // elements render as a visible Word-style page seam — editor-only
    // styling that lives in this injected sheet and never touches saved HTML.
    const baseline =
        '.dg-pv { background: #fff; max-width: 850px; margin: 0 auto; padding: 48px 56px; ' +
        'box-shadow: 0 2px 12px rgba(0, 0, 0, 0.18); font-family: Helvetica, Arial, sans-serif; ' +
        'font-size: 10.5pt; color: #1a1a1a; min-height: 380px; box-sizing: border-box; }\n' +
        ".dg-pv [style*='page-break-before'], .dg-pv [style*='page-break-after'] { display: block; " +
        'height: 30px !important; font-size: 0 !important; margin: 18px 0; background: #e8eaed; ' +
        'border-top: 2px dashed #a9b2c0; border-bottom: 2px dashed #a9b2c0; position: relative; }\n' +
        ".dg-pv [style*='page-break-before']::after, .dg-pv [style*='page-break-after']::after { " +
        "content: 'PAGE BREAK — new page starts here'; position: absolute; left: 0; right: 0; top: 8px; " +
        'text-align: center; font-size: 10px; letter-spacing: 2px; color: #7a8598; }\n' +
        // SLDS globally resets list-style to none — restore real bullets and
        // numbers inside the page (matches how the PDF engine renders them).
        '.dg-pv ul { list-style: disc outside !important; padding-left: 18pt; }\n' +
        '.dg-pv ol { list-style: decimal outside !important; padding-left: 18pt; }\n' +
        '.dg-pv li { list-style: inherit !important; }\n' +
        // Converted DOCX tables often carry absolute widths wider than the
        // page (extra loop-tag cells, twips math) — keep them ON the sheet so
        // their edges stay reachable for column drag-resize.
        '.dg-pv table { max-width: 100% !important; }\n' +
        '.dg-pv td, .dg-pv th { overflow-wrap: break-word; }';
    // data-dg-editor marks this sheet as EDITOR-OWNED (#322). Every serializer
    // strips the editor layer by that attribute rather than by element type, so
    // an author's own <style> can never be collateral.
    return '<div class="dg-pv"><style data-dg-editor="preview">' + baseline + css + '</style>' + content + '</div>';
}

// ---------------------------------------------------------------------------
// Tag palette (Insert Tags panel)
// ---------------------------------------------------------------------------

/**
 * Build the click-to-insert tag palette from the template's actual Query
 * Config shape: its record fields, its child relationships (with a
 * ready-made loop table), plus the universal built-ins, signature tags,
 * conditionals, and aggregates.
 */
/**
 * Ready-made layout blocks for the visual builder. Every snippet is
 * self-contained (inline styles only — no dependence on the template's CSS)
 * and Flying Saucer-safe: table-based columns, solid colors, CSS 2.1 only.
 */
export function buildBlockPalette(shape) {
    const td = 'vertical-align: top; padding: 0 8pt 0 0';
    const cell = 'padding: 5pt 7pt; border-bottom: 0.75pt solid #dddddd';
    const th = 'background: #1f3a5f; color: #ffffff; text-align: left; padding: 5pt 7pt; font-size: 9.5pt';

    const sections = [
        {
            key: 'blk_layout',
            label: 'Layout',
            hint: 'Table-based — the only layout the PDF engine renders reliably.',
            items: [
                {
                    key: 'blk_2col',
                    label: 'Two columns',
                    snippet:
                        '\n<table style="width: 100%; border-collapse: collapse"><tr>' +
                        '<td style="width: 50%; ' +
                        td +
                        '"><p>Left column</p></td>' +
                        '<td style="width: 50%; vertical-align: top; padding: 0 0 0 8pt"><p>Right column</p></td>' +
                        '</tr></table>\n',
                    title: '50/50 side-by-side content'
                },
                {
                    key: 'blk_3col',
                    label: 'Three columns',
                    snippet:
                        '\n<table style="width: 100%; border-collapse: collapse"><tr>' +
                        '<td style="width: 33%; ' +
                        td +
                        '"><p>First</p></td>' +
                        '<td style="width: 34%; ' +
                        td +
                        '"><p>Second</p></td>' +
                        '<td style="width: 33%; vertical-align: top"><p>Third</p></td>' +
                        '</tr></table>\n',
                    title: 'Three equal columns'
                },
                {
                    key: 'blk_table',
                    label: 'Data table',
                    snippet:
                        '\n<table style="width: 100%; border-collapse: collapse">' +
                        '<thead><tr>' +
                        '<th style="' +
                        th +
                        '">Column 1</th><th style="' +
                        th +
                        '">Column 2</th><th style="' +
                        th +
                        '">Column 3</th>' +
                        '</tr></thead><tbody>' +
                        '<tr><td style="' +
                        cell +
                        '">&nbsp;</td><td style="' +
                        cell +
                        '">&nbsp;</td><td style="' +
                        cell +
                        '">&nbsp;</td></tr>' +
                        '<tr><td style="' +
                        cell +
                        '">&nbsp;</td><td style="' +
                        cell +
                        '">&nbsp;</td><td style="' +
                        cell +
                        '">&nbsp;</td></tr>' +
                        '</tbody></table>\n',
                    title: 'Styled 3-column table shell — add your own rows and fields'
                },
                {
                    key: 'blk_divider',
                    label: 'Divider line',
                    snippet:
                        '\n<div style="border-top: 1pt solid #cccccc; margin: 14pt 0; font-size: 0">&nbsp;</div>\n',
                    title: 'Horizontal rule'
                },
                {
                    key: 'blk_spacer',
                    label: 'Spacer',
                    snippet: '\n<div style="height: 18pt; font-size: 0">&nbsp;</div>\n',
                    title: 'Vertical breathing room'
                },
                {
                    key: 'blk_pagebreak',
                    label: 'Page break',
                    snippet: '\n<div style="page-break-before: always; font-size: 0">&nbsp;</div>\n',
                    title: 'Starts a new PDF page here (invisible in the editor)'
                }
            ]
        },
        {
            key: 'blk_content',
            label: 'Content',
            hint: 'Drop in, then click the text to rewrite it.',
            items: [
                {
                    key: 'blk_band',
                    label: 'Header band',
                    snippet:
                        '\n<table style="width: 100%; border-collapse: collapse; background: #1f3a5f"><tr>' +
                        '<td style="padding: 14pt 16pt">' +
                        '<span style="color: #ffffff; font-size: 20pt">Document Title</span><br />' +
                        '<span style="color: #9fb8cf; font-size: 9pt">Subtitle — drop fields from Insert Tags here</span>' +
                        '</td></tr></table>\n',
                    title: 'Navy title banner'
                },
                {
                    key: 'blk_heading',
                    label: 'Section heading',
                    snippet:
                        '\n<h2 style="font-size: 13pt; color: #1f3a5f; border-bottom: 2pt solid #1f3a5f; padding-bottom: 3pt; margin: 18pt 0 6pt 0">Section Title</h2>\n',
                    title: 'Underlined section header'
                },
                {
                    key: 'blk_para',
                    label: 'Paragraph',
                    snippet:
                        '\n<p style="margin: 6pt 0">Your text here — mix in fields from Insert Tags anywhere.</p>\n',
                    title: 'Plain text block'
                },
                {
                    key: 'blk_ul',
                    label: 'Bulleted list',
                    snippet:
                        '\n<ul style="margin: 6pt 0 6pt 18pt"><li>First item</li><li>Second item</li><li>Third item</li></ul>\n',
                    title: 'Bullet points — Enter adds items while editing'
                },
                {
                    key: 'blk_ol',
                    label: 'Numbered list',
                    snippet:
                        '\n<ol style="margin: 6pt 0 6pt 18pt"><li>First step</li><li>Second step</li><li>Third step</li></ol>\n',
                    title: 'Numbered steps'
                },
                {
                    key: 'blk_quote',
                    label: 'Indented quote',
                    snippet:
                        '\n<div style="margin: 8pt 0 8pt 18pt; padding-left: 10pt; border-left: 3pt solid #cccccc; color: #555555; font-style: italic">Quoted or emphasized text.</div>\n',
                    title: 'Left-ruled italic block for quotes and emphasis'
                },
                {
                    key: 'blk_panel',
                    label: 'Tinted panel',
                    snippet:
                        '\n<div style="background: #f2f6fc; padding: 10pt 12pt; margin: 8pt 0"><p style="margin: 0">Panel text — a soft background block for callouts, summaries, or sidebars.</p></div>\n',
                    title: 'Light background panel — recolor it with the Cell/Fill swatches'
                },
                {
                    key: 'blk_darkpanel',
                    label: 'Dark panel',
                    snippet:
                        '\n<div style="background: #1f3a5f; color: #ffffff; padding: 10pt 12pt; margin: 8pt 0"><p style="margin: 0; color: #ffffff">Bold statement text on a navy panel.</p></div>\n',
                    title: 'Navy background block with white text'
                },
                {
                    key: 'blk_callout',
                    label: 'Callout box',
                    snippet:
                        '\n<table style="width: 100%; border-collapse: collapse"><tr>' +
                        '<td style="background: #f2f6fc; border-left: 4pt solid #1f3a5f; padding: 8pt 12pt">Callout — great for notes, terms, or highlights.</td>' +
                        '</tr></table>\n',
                    title: 'Accented highlight box'
                },
                {
                    key: 'blk_footer',
                    label: 'Footer note',
                    snippet:
                        '\n<div style="margin-top: 24pt; padding-top: 6pt; border-top: 1pt solid #cccccc; color: #888888; font-size: 8.5pt">Generated {Today:MM/dd/yyyy} by {RunningUser.Name}</div>\n',
                    title: 'Small gray footer line'
                }
            ]
        }
    ];

    // Ready-made pieces built from THIS template's query.
    const readyItems = [];
    const detailFields = [...(shape.baseFields || []), ...(shape.parentFields || [])];
    if (detailFields.length) {
        const rows = detailFields
            .map((f) => {
                const tag = isMoneyField(f) ? '{' + f + ':currency}' : '{' + f + '}';
                return (
                    '<tr><td style="width: 35%; font-weight: bold; color: #444444; background: #f2f4f7; padding: 5pt 7pt">' +
                    humanizeField(f) +
                    '</td><td style="border-bottom: 1pt solid #eeeeee; padding: 5pt 7pt">' +
                    tag +
                    '</td></tr>'
                );
            })
            .join('');
        readyItems.push({
            key: 'blk_details',
            label: 'Details table (your fields)',
            snippet: '\n<table style="width: 100%; border-collapse: collapse">' + rows + '</table>\n',
            title: 'Label/value rows for every field in your Query Config'
        });
    }
    readyItems.push({
        key: 'blk_sig',
        label: 'Signature block (two-party)',
        snippet:
            '\n<table style="width: 100%; border-collapse: collapse; margin-top: 24pt"><tr>' +
            '<td style="width: 48%; vertical-align: bottom">{@Signature_Customer:1:Full}' +
            '<div style="border-top: 1pt solid #333333; margin-top: 4pt; padding-top: 3pt; color: #666666; font-size: 9pt">Customer &#8226; Date: {@Signature_Customer:1:Date}</div></td>' +
            '<td style="width: 4%">&nbsp;</td>' +
            '<td style="width: 48%; vertical-align: bottom">{@Signature_Company_Representative:2:Full}' +
            '<div style="border-top: 1pt solid #333333; margin-top: 4pt; padding-top: 3pt; color: #666666; font-size: 9pt">Company &#8226; Date: {@Signature_Company_Representative:2:Date}</div></td>' +
            '</tr></table>\n',
        title: 'E-signature areas for both parties, wired to Portwood signing'
    });
    // Special characters — the UserGuide set, all covered by the PDF
    // engine's Arial Unicode fallback. Text glyphs only: color emoji
    // (\u2705 etc.) are dropped by Flying Saucer.
    const CHARS = [
        ['\u2713', 'Check mark', 'check tick yes done'],
        ['\u2717', 'Cross mark', 'cross x no fail reject'],
        ['\u2611', 'Checked box', 'checkbox checked ballot done'],
        ['\u2610', 'Empty box', 'checkbox unchecked ballot todo'],
        ['\u2612', 'X-ed box', 'checkbox rejected ballot'],
        ['\u2022', 'Bullet', 'bullet dot point'],
        ['\u25aa', 'Small square', 'bullet square marker'],
        ['\u2013', 'En dash', 'dash range en'],
        ['\u2014', 'Em dash', 'dash em break'],
        ['\u2026', 'Ellipsis', 'ellipsis dots more'],
        ['\u2192', 'Arrow right', 'arrow right next'],
        ['\u2190', 'Arrow left', 'arrow left back'],
        ['\u2191', 'Arrow up', 'arrow up'],
        ['\u2193', 'Arrow down', 'arrow down'],
        ['\u2194', 'Arrow both', 'arrow both leftright'],
        ['\u00a7', 'Section sign', 'section legal paragraph law'],
        ['\u00b6', 'Pilcrow', 'paragraph pilcrow'],
        ['\u00a9', 'Copyright', 'copyright legal'],
        ['\u00ae', 'Registered', 'registered trademark legal'],
        ['\u2122', 'Trademark', 'trademark tm legal'],
        ['\u2020', 'Dagger', 'dagger footnote'],
        ['\u00b0', 'Degree', 'degree temperature angle'],
        ['\u00d7', 'Multiply', 'multiply times x math'],
        ['\u00f7', 'Divide', 'divide math'],
        ['\u00b1', 'Plus-minus', 'plus minus tolerance math'],
        ['\u2264', 'Less or equal', 'less equal math'],
        ['\u2265', 'Greater or equal', 'greater equal math'],
        ['\u2248', 'Approximately', 'approx math tilde'],
        ['\u00bd', 'One half', 'half fraction'],
        ['\u00bc', 'One quarter', 'quarter fraction'],
        ['\u00be', 'Three quarters', 'fraction'],
        ['\u20ac', 'Euro sign', 'euro currency money'],
        ['\u00a3', 'Pound sign', 'pound sterling currency money'],
        ['\u00a5', 'Yen sign', 'yen yuan currency money'],
        ['\u00a2', 'Cent sign', 'cent currency money'],
        ['\u20b9', 'Rupee sign', 'rupee currency money'],
        ['\u2605', 'Star filled', 'star rating'],
        ['\u2606', 'Star outline', 'star rating empty'],
        ['\u25b6', 'Triangle right', 'triangle play pointer'],
        ['\u00ab', 'Left guillemet', 'quote guillemet french'],
        ['\u00bb', 'Right guillemet', 'quote guillemet french']
    ];
    sections.push({
        key: 'chars',
        label: 'Special characters',
        hint: 'Unicode-safe in PDF output. Click to insert at your cursor.',
        items: CHARS.map((c) => ({
            key: 'ch_' + c[0].charCodeAt(0),
            label: c[0] + '  ' + c[1],
            snippet: c[0],
            title: c[1] + ' — ' + c[2]
        }))
    });

    sections.push({
        key: 'blk_ready',
        label: 'Ready-made',
        hint: 'Built from this template’s own Query Config.',
        items: readyItems
    });

    return sections;
}

export function buildTagPalette(shape) {
    const sections = [];
    const tagFor = (f) => (isMoneyField(f) ? '{' + f + ':currency}' : '{' + f + '}');

    const fieldItems = [...(shape.baseFields || []), ...(shape.parentFields || [])].map((f) => ({
        key: 'f_' + f,
        label: humanizeField(f),
        snippet: tagFor(f),
        title: 'Insert ' + tagFor(f)
    }));
    if (fieldItems.length) {
        sections.push({
            key: 'fields',
            label: 'Record Fields',
            hint: 'From this template’s Query Config — click to insert at your cursor.',
            items: fieldItems
        });
    }

    for (const child of shape.children || []) {
        const rel = child.relationshipName;
        // Aggregates generated from the loop's OWN fields — no placeholder
        // editing. Money fields get SUM/AVG with :currency, quantity-shaped
        // fields plain SUM, and every loop gets a record count.
        const aggregateItems = [];
        for (const f of child.fields || []) {
            if (isMoneyField(f)) {
                aggregateItems.push(
                    {
                        key: rel + '_sum_' + f,
                        label: 'Total ' + humanizeField(f),
                        snippet: '{SUM:' + rel + '.' + f + ':currency}',
                        title:
                            'Sum of ' +
                            humanizeField(f) +
                            ' across all ' +
                            humanizeField(rel) +
                            ' — goes OUTSIDE the loop'
                    },
                    {
                        key: rel + '_avg_' + f,
                        label: 'Average ' + humanizeField(f),
                        snippet: '{AVG:' + rel + '.' + f + ':currency}',
                        title: 'Average ' + humanizeField(f) + ' — goes OUTSIDE the loop'
                    }
                );
            } else if (isQuantityField(f)) {
                aggregateItems.push({
                    key: rel + '_sum_' + f,
                    label: 'Total ' + humanizeField(f),
                    snippet: '{SUM:' + rel + '.' + f + '}',
                    title:
                        'Sum of ' + humanizeField(f) + ' across all ' + humanizeField(rel) + ' — goes OUTSIDE the loop'
                });
            }
        }
        // Charts: one click per bucketable field — {Chart:...} renders a
        // pure-Apex PNG in PDF output; swap :bar for column/pie/donut/
        // stacked/clustered/line/area.
        for (const f of child.fields || []) {
            if (f !== 'Id' && !f.includes('.')) {
                aggregateItems.push({
                    key: rel + '_chart_' + f,
                    label: 'Chart: ' + humanizeField(f),
                    snippet:
                        '{Chart:' +
                        rel +
                        ':' +
                        f +
                        ':bar:title=' +
                        humanizeField(rel) +
                        ' by ' +
                        humanizeField(f) +
                        '}',
                    title:
                        'Bar chart of ' +
                        humanizeField(rel) +
                        ' bucketed by ' +
                        humanizeField(f) +
                        ' — change :bar to column, pie, donut, stacked, clustered, line, or area. Goes OUTSIDE the loop.'
                });
            }
        }
        aggregateItems.push({
            key: rel + '_count',
            label: 'Count of ' + humanizeField(rel),
            snippet: '{COUNT:' + rel + '}',
            title: 'Number of ' + humanizeField(rel) + ' records — goes OUTSIDE the loop'
        });
        sections.push({
            key: 'rel_' + rel,
            label: humanizeField(rel) + ' — child loop',
            hint:
                'Child fields only resolve inside the {#' + rel + '}…{/' + rel + '} loop. Totals/counts go outside it.',
            items: [
                {
                    key: rel + '_table',
                    label: 'Loop table (all fields)',
                    snippet: '\n' + childLoopTable(child) + '\n',
                    title: 'A table that repeats one row per ' + rel + ' record'
                },
                {
                    key: rel + '_loop',
                    label: 'Inline loop block',
                    snippet: '{#' + rel + '} … {/' + rel + '}',
                    title: 'Repeats its contents once per ' + rel + ' record'
                },
                ...(child.fields || []).map((f) => ({
                    key: rel + '_' + f,
                    label: humanizeField(f),
                    snippet: tagFor(f),
                    title: tagFor(f) + ' — place inside the {#' + rel + '} loop'
                })),
                ...aggregateItems
            ]
        });
    }

    // Chart gallery: all nine engine styles, wired to the first child
    // relationship's first bucketable field — pills are editable, so authors
    // retarget by double-clicking. SVG-only styles carry htmlRender=svg.
    const chartRel = (shape.children || [])[0];
    const chartField = chartRel ? (chartRel.fields || []).find((f) => f !== 'Id' && !f.includes('.')) : null;
    if (chartRel && chartField) {
        const cr = chartRel.relationshipName;
        const mkChart = (style, svg) =>
            '{Chart:' +
            cr +
            ':' +
            chartField +
            ':' +
            style +
            ':title=' +
            humanizeField(cr) +
            ' by ' +
            humanizeField(chartField) +
            (svg ? '&htmlRender=svg' : '') +
            '}';
        sections.push({
            key: 'chartstyles',
            label: 'Chart gallery',
            hint: 'Nine styles. SVG styles (pie, donut, column, line, area) render in HTML output; for PDFs prefer bar/stacked/clustered/pivot. Double-click the pill to retarget.',
            items: [
                {
                    key: 'ch_bar',
                    label: 'Bar chart',
                    snippet: mkChart('bar', false),
                    title: 'Horizontal bars — PDF-safe'
                },
                {
                    key: 'ch_stacked',
                    label: 'Stacked bar',
                    snippet: mkChart('stacked', false),
                    title: 'Needs groupBy= and colSort= options — PDF-safe'
                },
                {
                    key: 'ch_clustered',
                    label: 'Clustered bars',
                    snippet: mkChart('clustered', false),
                    title: 'Needs groupBy= and colSort= — PDF-safe'
                },
                {
                    key: 'ch_pivot',
                    label: 'Pivot table',
                    snippet: mkChart('pivot', false),
                    title: 'Cross-tab counts — needs groupBy= and colSort= — PDF-safe'
                },
                {
                    key: 'ch_column',
                    label: 'Column chart (SVG)',
                    snippet: mkChart('column', true),
                    title: 'Vertical columns — HTML output'
                },
                { key: 'ch_pie', label: 'Pie chart (SVG)', snippet: mkChart('pie', true), title: 'HTML output' },
                {
                    key: 'ch_donut',
                    label: 'Donut chart (SVG)',
                    snippet: mkChart('donut', true),
                    title: 'HTML output — innerRadius= tunes the hole'
                },
                { key: 'ch_line', label: 'Line chart (SVG)', snippet: mkChart('line', true), title: 'HTML output' },
                { key: 'ch_area', label: 'Area chart (SVG)', snippet: mkChart('area', true), title: 'HTML output' }
            ]
        });
    }

    sections.push({
        key: 'builtins',
        label: 'Built-ins',
        hint: 'Work on every template, no configuration.',
        items: [
            { key: 'today_long', label: 'Today (long)', snippet: '{Today:MMMM d, yyyy}', title: 'April 17, 2026' },
            { key: 'today_num', label: 'Today (numeric)', snippet: '{Today:MM/dd/yyyy}', title: '04/17/2026' },
            { key: 'now', label: 'Now (timestamp)', snippet: '{Now:yyyy-MM-dd HH:mm}', title: 'Current date-time' },
            {
                key: 'ru_name',
                label: 'Running user',
                snippet: '{RunningUser.Name}',
                title: 'Whoever generates the document'
            },
            {
                key: 'ru_title',
                label: 'Running user title',
                snippet: '{RunningUser.Title}',
                title: '{RunningUser.Title}'
            },
            {
                key: 'ru_email',
                label: 'Running user email',
                snippet: '{RunningUser.Email}',
                title: '{RunningUser.Email}'
            },
            {
                key: 'ru_phone',
                label: 'Running user phone',
                snippet: '{RunningUser.Phone}',
                title: '{RunningUser.Phone} — also: MobilePhone, Fax, Extension'
            },
            {
                key: 'ru_dept',
                label: 'Running user department',
                snippet: '{RunningUser.Department}',
                title: '{RunningUser.Department} — also: CompanyName, EmployeeNumber, Alias'
            },
            {
                key: 'ru_company',
                label: 'Running user company',
                snippet: '{RunningUser.CompanyName}',
                title: '{RunningUser.CompanyName} — address fields too: Street, City, State, PostalCode, Country'
            },
            {
                key: 'pagenum',
                label: 'Page number',
                snippet: '{PageNumber}',
                title: 'Current page — ONLY works in the template Header/Footer, not the body'
            },
            {
                key: 'pagetotal',
                label: 'Total pages',
                snippet: '{TotalPages}',
                title: 'Page count — ONLY works in the template Header/Footer, not the body'
            }
        ]
    });

    sections.push({
        key: 'sig',
        label: 'E-Signature',
        hint: 'Role + order + type. Roles are free-form — Buyer, Seller, Witness…',
        items: [
            {
                key: 'sig_full',
                label: 'Signature (Customer)',
                snippet: '{@Signature_Customer:1:Full}',
                title: 'Full signature stamp'
            },
            {
                key: 'sig_date',
                label: 'Signed date (Customer)',
                snippet: '{@Signature_Customer:1:Date}',
                title: 'Auto-filled when signed'
            },
            {
                key: 'sig_init',
                label: 'Initials (Customer)',
                snippet: '{@Signature_Customer:1:Initials}',
                title: 'Initials stamp'
            },
            {
                key: 'sig_rep',
                label: 'Signature (Company rep)',
                snippet: '{@Signature_Company_Representative:2:Full}',
                title: 'Second signer, order 2'
            },
            {
                key: 'sig_datepick',
                label: 'Date picker (signer chooses)',
                snippet: '{@Signature_Customer:1:DatePick}',
                title: 'Signer picks a date instead of auto-fill'
            },
            {
                key: 'sig_inline',
                label: 'Inline signature (compact)',
                snippet: '{@Signature_Customer:1:Full:inline}',
                title: 'Compact in-place mark — sits inside a sentence instead of a block'
            }
        ]
    });

    // Barcodes & QR — {*Field:qr} / {*Field:code128}, the only two types.
    const codeishFields = [...(shape.baseFields || [])].filter(
        (f) => /(number|code|sku|url|website)$/i.test(f) || /^name$/i.test(f)
    );
    sections.push({
        key: 'barcodes',
        label: 'Barcodes & QR',
        hint: 'QR, Code 128, and Code 39. Keep QR values under ~120 characters for 1-inch prints.',
        items: [
            ...codeishFields.map((f) => ({
                key: 'qr_' + f,
                label: 'QR: ' + humanizeField(f),
                snippet: '{*' + f + ':qr:200}',
                title: '200px QR code of ' + humanizeField(f)
            })),
            {
                key: 'qr_any',
                label: 'QR code (any field)',
                snippet: '{*FieldName:qr:200}',
                title: 'Swap FieldName for one of your fields'
            },
            {
                key: 'bc_any',
                label: 'Barcode (Code 128)',
                snippet: '{*FieldName:code128:300x80}',
                title: 'Swap FieldName; renders a 300×80px Code 128 barcode'
            },
            {
                key: 'bc39_any',
                label: 'Barcode (Code 39)',
                snippet: '{*FieldName:code39:300x80}',
                title: 'Swap FieldName; Code 39 — uppercase letters, digits, and -. $/+% only'
            }
        ]
    });

    // Image tags — record image fields and org-wide shared assets.
    sections.push({
        key: 'imgtags',
        label: 'Image Tags',
        hint: 'Record images and shared assets (see the Assets tab).',
        items: [
            {
                key: 'img_field',
                label: 'Record image field',
                snippet: '{%ImageFieldName}',
                title: 'Renders the image stored in a field — swap ImageFieldName for your image field'
            },
            {
                key: 'img_asset',
                label: 'Shared asset (logo)',
                snippet: '{%asset:logo:144x}',
                title: 'Org-wide shared asset by key — great for logos reused across templates. The :144x sizes it to ~1.5in wide (edit or drop the token to taste).'
            }
        ]
    });

    // Real aggregates live in each relationship's own section, built from its
    // actual fields. Generic placeholders only appear as a fallback when the
    // Query Config has no child relationships to build from.
    const logicItems = [
        {
            key: 'ifelse',
            label: 'If / else block',
            snippet: '{#FieldName}shown when set{:else}shown when empty{/FieldName}',
            title: 'Conditional content — swap FieldName for one of yours'
        },
        {
            key: 'inverse',
            label: 'Show when EMPTY (inverse)',
            snippet: '{^FieldName}shown only when FieldName is blank{/FieldName}',
            title: 'Renders only when the field is null, false, or an empty list'
        },
        {
            key: 'if_compare',
            label: 'If — number comparison',
            snippet: '{#IF Amount >= 100000}big deal content{:else}standard content{/IF}',
            title: 'Operators: == != > < >= <= — close with {/IF}'
        },
        {
            key: 'if_text',
            label: 'If — text equals',
            snippet: "{#IF StageName == 'Closed Won'}congratulations{/IF}",
            title: "Quote text values: {#IF Status == 'Active'}"
        },
        {
            key: 'if_logic',
            label: 'If — AND / OR / NOT',
            snippet: "{#IF (Amount > 1000 AND StageName == 'Closed Won') OR Type == 'Renewal'}...{/IF}",
            title: 'Combine with AND, OR, NOT and parentheses'
        },
        {
            key: 'groupby',
            label: 'Group into tables (by field)',
            snippet:
                '{#GroupBy ChildRelationship by GroupField}\n<h3>{GroupName}</h3>\n<table>{#ChildRelationship}<tr><td>{Field}</td></tr>{/ChildRelationship}</table>\nSubtotal: {SUM:ChildRelationship.Field}\n{/GroupBy}',
            title: 'One table per distinct value of GroupField — {GroupName} is the group header; the inner {#ChildRelationship} loops that group and {SUM:...} totals it. Great for "a table per type".'
        },
        {
            key: 'checkbox',
            label: 'Checkbox render',
            snippet: '{FieldName:checkbox}',
            title: '[X] when true, [ ] when false'
        }
    ];
    if (!(shape.children || []).length) {
        logicItems.push(
            {
                key: 'sum',
                label: 'SUM of child field',
                snippet: '{SUM:Relationship.Field:currency}',
                title: 'Total across child records — add a child relationship to your Query Config for ready-made totals'
            },
            {
                key: 'count',
                label: 'COUNT of children',
                snippet: '{COUNT:Relationship}',
                title: 'Number of child records'
            }
        );
    }
    sections.push({
        key: 'logic',
        label: 'Conditionals',
        hint: 'Swap FieldName for one of your fields.',
        items: logicItems
    });

    return sections;
}

// ===== Regions: one source document (DESIGNER_PLAN_V2 step 2) ================
//
// A template used to have three sources of truth: the body lived in a
// ContentVersion, the running header in Header_Html__c and the running footer in
// Footer_Html__c. Nothing tied them together, so "View Source" showed only part of
// the document, a Word import had nowhere to put <w:hdr>, and every new feature
// had to be plumbed through each surface separately.
//
// Regions give the AUTHOR one source document:
//
//   <body>
//     <div data-dg-region="header">…running header…</div>
//     <div data-dg-region="body">…the document…</div>
//     <div data-dg-region="footer">…running footer…</div>
//   </body>
//
// The RENDER ENGINE never sees it. splitRegions() peels the chrome back off on the
// way to saving and the three fields are written exactly as they are today, so
// wrapHtmlForPdf keeps its current contract and nothing about PDF output changes.
// That is what keeps this from being a risky change.
//
// Templates saved before this existed carry no markers: splitRegions reports
// hadRegions === false and hands the document back untouched, so they load, edit
// and save exactly as before. No migration.

export const DG_REGION_ATTR = 'data-dg-region';

const BODY_TAGS_RE = /(<body\b[^>]*>)([\s\S]*?)(<\/body\s*>)/i;

/** The document's <body> contents, plus a function to put new contents back. */
function bodySlice(html) {
    const doc = html || '';
    const m = doc.match(BODY_TAGS_RE);
    if (m) {
        return {
            inner: m[2],
            rebuild: (next) => doc.replace(BODY_TAGS_RE, (full, open, mid, close) => open + '\n' + next + '\n' + close)
        };
    }
    // Body-fragment template (no <body> wrapper): the content IS the document.
    return { inner: doc, rebuild: (next) => next };
}

function parseFragment(html) {
    const tpl = document.createElement('template');
    // eslint-disable-next-line @lwc/lwc/no-inner-html -- string round-trip into an inert <template>; never attached to the page
    tpl.innerHTML = html || '';
    return tpl;
}

function serializeChildren(node) {
    const box = document.createElement('div');
    while (node.firstChild) {
        box.appendChild(node.firstChild);
    }
    // eslint-disable-next-line @lwc/lwc/no-inner-html -- serializing an inert fragment back to a string
    return box.innerHTML.trim();
}

/**
 * Peel a region-marked document into its three surfaces.
 *
 * Returns { header, body, footer, hadRegions }. `body` is the FULL document with
 * the body region's contents spliced back between the <body> tags, so <head>,
 * <style> and @page survive untouched — the same discipline _exitVisualMode uses.
 *
 * A document with no markers comes back verbatim as `body` with null chrome and
 * hadRegions === false. That is the backwards-compatibility guarantee: callers
 * must check hadRegions before overwriting Header_Html__c / Footer_Html__c, or a
 * legacy template would have its header blanked the first time it was opened.
 */
export function splitRegions(html) {
    const out = { header: null, body: html || '', footer: null, hadRegions: false };
    if (!html || html.indexOf(DG_REGION_ATTR) === -1) {
        return out;
    }
    const slice = bodySlice(html);
    const tpl = parseFragment(slice.inner);
    const regions = tpl.content.querySelectorAll('[' + DG_REGION_ATTR + ']');
    if (!regions.length) {
        return out;
    }
    out.hadRegions = true;
    let bodyRegion = null;
    for (const el of regions) {
        // Only TOP-LEVEL regions count. A nested marker is content that happens to
        // carry the attribute (a pasted fragment, a copied block) and unwrapping it
        // would silently promote it to running chrome.
        if (el.parentNode !== tpl.content) {
            continue;
        }
        const kind = (el.getAttribute(DG_REGION_ATTR) || '').toLowerCase();
        if (kind === 'header') {
            out.header = serializeChildren(el);
            el.remove();
        } else if (kind === 'footer') {
            out.footer = serializeChildren(el);
            el.remove();
        } else if (kind === 'body' && !bodyRegion) {
            bodyRegion = el;
        }
    }
    let bodyInner;
    if (bodyRegion) {
        bodyInner = serializeChildren(bodyRegion);
    } else {
        // Header/footer marked but no explicit body region: whatever is left after
        // removing them IS the body.
        // eslint-disable-next-line @lwc/lwc/no-inner-html -- serializing an inert fragment back to a string
        bodyInner = serializeChildren(tpl.content);
    }
    out.body = stripRegionMarkers(slice.rebuild(bodyInner));
    return out;
}

/**
 * Compose one source document from the three surfaces.
 *
 * When there is no header and no footer the document is returned UNCHANGED —
 * a plain template never grows markers it does not need, so nothing about the
 * common case differs from before.
 */
export function joinRegions(bodyDocHtml, headerHtml, footerHtml) {
    const header = (headerHtml || '').trim();
    const footer = (footerHtml || '').trim();
    if (!header && !footer) {
        return bodyDocHtml || '';
    }
    const slice = bodySlice(bodyDocHtml || '');
    const parts = [];
    if (header) {
        parts.push('<div ' + DG_REGION_ATTR + '="header">\n' + header + '\n</div>');
    }
    parts.push('<div ' + DG_REGION_ATTR + '="body">\n' + slice.inner.trim() + '\n</div>');
    if (footer) {
        parts.push('<div ' + DG_REGION_ATTR + '="footer">\n' + footer + '\n</div>');
    }
    return slice.rebuild(parts.join('\n'));
}

/**
 * Unwrap every region marker, keeping its children.
 *
 * The last line of defence: a marker must never reach the renderer, the same
 * discipline already applied to .dg-drop-marker and data-dg-paint. Called on
 * everything bound for a ContentVersion even when the caller believes it has
 * already split, because "believes" is how the drop-marker bug happened.
 */
export function stripRegionMarkers(html) {
    if (!html || html.indexOf(DG_REGION_ATTR) === -1) {
        return html || '';
    }
    const slice = bodySlice(html);
    const tpl = parseFragment(slice.inner);
    let marked = tpl.content.querySelectorAll('[' + DG_REGION_ATTR + ']');
    let guard = 0;
    while (marked.length && guard++ < 50) {
        for (const el of marked) {
            const parent = el.parentNode;
            if (!parent) {
                continue;
            }
            while (el.firstChild) {
                parent.insertBefore(el.firstChild, el);
            }
            parent.removeChild(el);
        }
        marked = tpl.content.querySelectorAll('[' + DG_REGION_ATTR + ']');
    }
    return slice.rebuild(serializeChildren(tpl.content));
}

// ---------------------------------------------------------------------------
// Canvas template type
// ---------------------------------------------------------------------------

/**
 * The canonical CSS contract for a Canvas template.
 *
 * Every rule here was measured against a real Blob.toPdf render rather than
 * assumed — see scripts/canvas-layout-model-probe.apex and the four rendered pages
 * in docs/canvas-layout-model-p*.png. Flying Saucer is CSS 2.1 plus an
 * idiosyncratic subset, so "should work" is not a basis for a layout engine.
 *
 *   .dg-artboard        one artboard = one page. position:relative and in NORMAL
 *                       flow, which is what makes it the containing block for its
 *                       pinned children AND lets a flow region paginate out of it.
 *                       min-height, never height: a pinned height gets overrun by
 *                       growing content instead of growing with it.
 *   .dg-artboard_break  page-break-BEFORE on every artboard after the first. Not
 *                       page-break-after on the previous one — measured, that gets
 *                       swallowed when a flow region spills, and the next artboard
 *                       paints its pinned boxes on top of the overflow.
 *   .dg-pin             absolutely positioned box. Lands at its declared inch
 *                       offsets, exactly. Does NOT repeat on continuation pages.
 *   .dg-flow            normal-flow box. Paginates like any block, so this is where
 *                       a {#Loop} that grows to 60 rows goes.
 *
 * Chrome that must appear on continuation pages belongs in @page margin boxes, not
 * in a pinned box — a pin belongs to its artboard, and an artboard is one page.
 */
export const CANVAS_CSS =
    '@page { size: {{SIZE}}; margin: {{MARGIN}}; }\n' +
    'body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; color: #1a1a1a; margin: 0; }\n' +
    '.dg-artboard { position: relative; width: {{WIDTH}}; min-height: {{HEIGHT}}; }\n' +
    '.dg-artboard_break { page-break-before: always; }\n' +
    '.dg-pin { position: absolute; }\n' +
    '.dg-flow { position: relative; }\n' +
    'table { border-collapse: collapse; width: 100%; -fs-table-paginate: paginate; }\n' +
    'thead { display: table-header-group; }\n' +
    'td, th { border: 0.5pt solid #999; padding: 2pt 4pt; }\n';

/** Page geometry per size/orientation, in inches, minus default 0.5in margins. */
const CANVAS_PAGES = {
    'Letter portrait': { size: 'Letter portrait', w: '7.5in', h: '10in' },
    'Letter landscape': { size: 'Letter landscape', w: '10in', h: '7.5in' },
    'A4 portrait': { size: 'A4 portrait', w: '7.27in', h: '10.69in' },
    'A4 landscape': { size: 'A4 landscape', w: '10.69in', h: '7.27in' }
};

export function canvasPageGeometry(pageSize, orientation) {
    const key = (pageSize || 'Letter') + ' ' + (orientation || 'portrait').toLowerCase();
    return CANVAS_PAGES[key] || CANVAS_PAGES['Letter portrait'];
}

/** A Canvas document with one empty artboard — what the editor opens on. */
export function buildBlankCanvasBody(pageSize, orientation) {
    const geo = canvasPageGeometry(pageSize, orientation);
    const css = CANVAS_CSS.replace('{{SIZE}}', geo.size)
        .replace('{{MARGIN}}', '0.5in')
        .replace('{{WIDTH}}', geo.w)
        .replace('{{HEIGHT}}', geo.h);
    return (
        '<!DOCTYPE html>\n<html>\n<head>\n<meta charset="utf-8" />\n<style>\n' +
        css +
        '</style>\n</head>\n<body>\n' +
        '<div class="dg-artboard" data-dg-artboard="1"></div>\n' +
        '</body>\n</html>\n'
    );
}

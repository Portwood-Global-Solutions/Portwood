# HTML and Word layout reference

This advanced reference accompanies the [task-based knowledgebase](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md). Retained from the existing guide and reviewed against the 3.60.0 source. Use the task articles for current installation and user workflows.

#### 5.7.3 CSS rules — what works, what doesn't, and an LLM prompt

PDF rendering goes through Salesforce's `Blob.toPdf()`, which is a Flying Saucer engine under the hood. **Flying Saucer is essentially a CSS 2.1 renderer with a small CSS 3 subset.** Modern layout primitives are silently ignored — the page still renders, but your layout collapses to default block flow. The result is a PDF that "looks wrong" without any error message.

This section gives you the rules and a paste-ready prompt for ChatGPT / Claude / Gemini so you can have an LLM produce templates that render correctly the first time.

##### Quick reference

| Use                                      | Don't use                                          | Replacement                                           |
| ---------------------------------------- | -------------------------------------------------- | ----------------------------------------------------- |
| `<table>` for side-by-side layout        | `display: flex`, `display: grid`                   | One `<table>` with one `<tr>`, columns become `<td>`s |
| Solid `background-color`                 | `linear-gradient(...)`, `radial-gradient(...)`     | Pick the dominant color, drop the gradient            |
| `padding`, `margin`                      | `gap` (CSS 3 grid/flex gap)                        | `padding` on cells, `margin` on blocks                |
| Fixed `width`/`height` in `pt`/`in`/`px` | `calc(...)`, CSS variables (`--foo`, `var(--foo)`) | Compute the literal value in your template            |
| `font-size` in `pt`                      | `rem`, `em` based on a non-default root            | Pt is most predictable for print                      |
| `border` — incl. `dashed` and `dotted`   | `border-radius`, `box-shadow`, `text-shadow`       | Corners stay square; see "Rounded corners" below      |
| Hex colours (`#eaf2fb`)                  | `rgba(...)`, `hsla(...)`                           | Pre-compute the tint as a flat hex                    |
| Full-strength colour                     | `opacity`                                          | Pick a lighter hex instead                            |
| `:nth-child(even)` for zebra striping    | `:has(...)`, `:is(...)`, container queries         | nth-child + nth-of-type are supported                 |
| `<table>`-based two/three-column layouts | `column-count`, `columns`                          | Tables work everywhere                                |
| `text-align`, `vertical-align` on `<td>` | `place-items`, `align-self`                        | Old-school alignment on cells                         |

##### Rounded corners, shadows and tints — the honest answer

**There are no rounded corners.** `border-radius` is ignored in _every_ form: on a
`<div>`, on a `<td>`, on a `<table>` with `border-collapse: separate`, in the
four-value corner shorthand, and via the engine's own `-fs-border-radius`. Boxes
render square. This is measured, not inferred — `scripts/css-capability-probe.apex`
renders a labelled swatch per property and compares each against a control, and
the rendered proof is in `docs/css-capability-probe.png`.

An earlier version of this table listed "`border-radius` (basic)" as supported.
It is not, and a template built on that advice renders square with no warning.

What you can use for visual interest, all CSS 2.1 and all confirmed working:

- **`border: 2pt dashed #2b6cb0`** and **`border: 2pt dotted #b02b2b`** — these
  genuinely render. They are the only border decoration available.
- Solid fills, contrasting borders, and `:nth-child(even)` zebra striping.
- A background **image** if you truly need a rounded shape — draw it once and
  reference it; the engine will place it faithfully.

Two failure modes that look similar and are not:

- **`linear-gradient(...)` is discarded when the stylesheet is parsed.** The
  cascade then falls back to any solid `background` set earlier, so the element
  keeps a sensible colour. Harmless.
- **`rgba(...)` is not.** It parses, resolves to nothing, and the background
  disappears entirely — so a tinted panel renders **invisible** rather than
  falling back to a colour. This is the one that quietly ruins a layout. Compute
  the tint yourself and write it as a flat hex.

`opacity`, `box-shadow`, `transform`, `calc()` and `outline` are all ignored too.

##### Long values overflow a table cell — and no CSS fixes it

A value with no spaces in it (an external id, a URL, a base64 fragment, a long
product code) will **run straight through the cell border**. This is not a
styling mistake; the engine cannot break an unbroken run of characters at all.
Measured across every candidate:

| Technique                   | Result                                                                   |
| --------------------------- | ------------------------------------------------------------------------ |
| `word-wrap: break-word`     | **ignored** — the engine injects this on every cell and it does nothing  |
| `overflow-wrap: break-word` | **ignored**                                                              |
| `word-break: break-all`     | **ignored**                                                              |
| `table-layout: fixed`       | the column stops growing, so the text overflows the border instead       |
| `&#8203;` zero-width space  | **ignored**                                                              |
| `&shy;` soft hyphen         | breaks, but prints VISIBLE hyphens into the value — it corrupts the data |
| **`<wbr/>`**                | **works** — breaks cleanly, and the text is unchanged                    |

So the only correct fix is a `<wbr/>` at each allowed break point:

```html
<!-- overflows the cell -->
<td>{External_Reference__c}</td>

<!-- wraps, value unchanged -->
<td>ORD-2026<wbr />-000148<wbr />-REV3<wbr />-APPROVED</td>
```

For merged values you cannot pre-break by hand, keep the column wide enough for
the longest value you expect, or split the value into its own row beneath the
label rather than beside it. Do **not** reach for `&shy;` — a hyphen that was
never in the data is worse than a column that is too narrow.

##### How to draw a circle (bullets, status dots, timeline markers)

Since `border-radius` does nothing, a circle has to be a **character**, not a box.
Unicode circle glyphs render correctly and scale with `font-size`, so you can size
one anywhere from a bullet to a display graphic:

| Want              | Use                           | Character |
| ----------------- | ----------------------------- | --------- |
| Small filled dot  | `&#8226;` (U+2022 bullet)     | •         |
| Filled circle     | `&#9679;` (U+25CF)            | ●         |
| Hollow circle     | `&#9675;` (U+25CB)            | ○         |
| Large hollow ring | `&#9711;` (U+25EF)            | ◯         |
| Small hollow ring | `&#176;` (U+00B0 degree sign) | °         |

```html
<!-- A 14pt status dot in brand colour -->
<span style="font-size: 14pt; color: #184d47;">&#9679;</span> Delivered

<!-- A display-size disc — the same glyph at 80pt -->
<span style="font-size: 80pt; color: #184d47; line-height: 1;">&#8226;</span>
```

Colour comes from `color`, size from `font-size`, and a light glyph on a dark
filled table cell reverses cleanly (white `&#8226;` on a solid background).

**Never use ZapfDingbats or Symbol for this.** Those fonts are not present in the
rendering engine, so `font-family: ZapfDingbats` with the letter `l` or `m` — the
usual trick for a filled/hollow circle — falls back to a serif face and prints a
literal **"l"** or **"m"** into the document. That is worse than an unsupported
property, because nothing fails: a wrong character is silently typeset where a
circle was intended. Stick to the Unicode glyphs above, which need no particular
font.

##### Paste-ready LLM prompt

Copy this verbatim into ChatGPT / Claude / Gemini. Replace the bracketed sections with what you want:

```
Generate a single self-contained HTML file for Portwood.

Audience: rendered to PDF by Flying Saucer (CSS 2.1 + small CSS 3 subset). Modern CSS layout features are silently ignored.

HARD RULES — never use these (Flying Saucer drops them):
- display: flex, display: grid, gap
- linear-gradient(...), radial-gradient(...), conic-gradient(...)
- calc(...), CSS variables (--name, var(--name))
- transform, transition, animation, @keyframes
- box-shadow, text-shadow, outline
- border-radius — in EVERY form, including on a <td>, on a <table> with
  border-collapse: separate, and the -fs-border-radius variant. There are no
  rounded corners. Every box is square. Do not attempt a workaround.
- rgba(...) and hsla(...) — these do not fall back to a solid colour, the
  background disappears completely. Write a pre-computed flat hex instead.

POSITIONING — measured 2026-08-05, not assumed. `position: absolute`, `relative`,
`fixed` and `float` all WORK and are pixel-exact against declared inches. Two
limits that matter more than the support itself:
- An absolutely positioned box with **no explicit height GROWS** to fit merged
  content, background and border following it. Pin a height and the content
  overflows the box instead — visible, not clipped, but the chrome stays put.
- Nothing beyond **page 1** renders. A box at `top: 10.5in` on Letter is dropped
  entirely. Absolute layout is single-page; use one artboard per page.
- opacity — pick a lighter hex colour instead.
- :has(), :is(), :where(), container queries

USE INSTEAD:
- <table> for any side-by-side layout. One <tr>, columns are <td>s with explicit widths.
- Solid background-color as a HEX value (no gradients, no rgba).
- padding/margin in pt or in. gap is not a thing.
- font-size in pt. Standard fonts: Helvetica, Arial, "Times New Roman", Courier.
- text-align / vertical-align on <td> for alignment.
- Fixed width/height in pt or in.
- For visual interest use solid fills, contrasting borders, and :nth-child(even)
  zebra striping. border: dashed and border: dotted DO work and are the only
  border decoration available.
- CIRCLES (bullets, status dots, markers) must be CHARACTERS, never CSS boxes,
  because border-radius does nothing. Use these and size them with font-size,
  colour them with color:
    &#8226;  small filled dot (U+2022)      &#9679;  filled circle (U+25CF)
    &#9675;  hollow circle (U+25CB)         &#9711;  large hollow ring (U+25EF)
    &#176;   small hollow ring (U+00B0)
  e.g. <span style="font-size:14pt;color:#184D47;">&#9679;</span> Delivered
  NEVER use font-family: ZapfDingbats or Symbol to make a circle. Those fonts are
  absent, so the letter falls back to a serif face and prints a literal "l" or
  "m" in the document instead of a shape.

PAGE SETUP — put a single <style> in <head> with:
  @page { size: 8.5in 11in; margin: 0.6in; }    /* US Letter portrait */
  /* or @page { size: 8.27in 11.69in; margin: 1.5cm; }   for A4 */
  body { font-family: Helvetica, Arial, sans-serif; font-size: 11pt; color: #333; }
Do NOT include @media queries — Flying Saucer ignores them.

DOCGEN MERGE TAGS — use these as plain text:
- Field merge:        {FieldApiName}              e.g. {Name}, {Account.Name}, {Amount}
- Built-ins:          {Today}, {Now}, {RunningUser.Name}, {RunningUser.Email}
- Format suffixes:    {Amount:currency}, {CloseDate:MM/dd/yyyy}, {Quantity:#,##0}
- Loop:               {#RelationshipName} ... {/RelationshipName}
- Loop IN A TABLE:    put the tags INSIDE the cells — open in the first cell of the
                      repeating row, close in the last. The engine expands the whole <tr>.
                        <tr><th>First Name</th><th>Last Name</th><th>Title</th></tr>
                        <tr><td>{#Contacts}{FirstName}</td><td>{LastName}</td><td>{Title}{/Contacts}</td></tr>
                      Do NOT wrap the row from outside ({#Rel}<tr>...</tr>{/Rel}) and never
                      put a loop tag on its own line between rows — text placed directly
                      inside <table> is foster-parented out of the table by the HTML parser.
                      This is the same pattern Word (<w:tr>) and Excel (<row>) use.
- Conditional:        {#IF Field = "Value"} ... {:else} ... {/IF}
                      Use double quotes around string literals; numeric needs no quotes.
- Page counters:      {PageNumber}, {TotalPages}   (only inside header/footer fields, not body)

OUTPUT: a single .html file. No external CSS, no <script>, no web fonts, no <link rel="stylesheet">.
Inline everything. The file uploads as one piece.

Now generate a [PURCHASE ORDER / QUOTE / INVOICE / etc.] template for the [Opportunity / Account / Order]
record, with these sections: [list your sections, e.g. header with logo + date, customer info, line items
table, totals, notes, signature]. Use the merge tag syntax above.
```

##### Skeleton template (copy + adapt)

A minimal CSS 2.1-clean starting point. Side-by-side header, two-column "for/from" block, line-item loop, totals, signature row, footer. Drop in your fields and adjust colors/typography:

```html
<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="UTF-8" />
        <title>Document</title>
        <style>
            @page {
                size: 8.5in 11in;
                margin: 0.6in;
            }
            body {
                font-family: Helvetica, Arial, sans-serif;
                color: #08163a;
                font-size: 11pt;
            }
            table {
                width: 100%;
                border-collapse: collapse;
            }
            td {
                vertical-align: top;
            }

            .hdr {
                border-bottom: 3px solid #004693;
                padding-bottom: 8px;
            }
            .hdr-logo {
                font-size: 22pt;
                font-weight: bold;
                color: #004693;
            }
            .hdr-meta {
                font-size: 9pt;
                text-align: right;
            }
            .accent-bar {
                height: 4px;
                background-color: #35c6f4;
                margin: 8px 0 18px 0;
            }

            .section-title {
                font-size: 10pt;
                font-weight: bold;
                color: #004693;
                text-transform: uppercase;
                letter-spacing: 1px;
                border-bottom: 1px solid #e6ecf4;
                padding-bottom: 3px;
                margin-bottom: 6px;
            }

            .grid-table td {
                width: 50%;
                padding-right: 18px;
            }
            .grid-table td.r {
                padding-right: 0;
                padding-left: 18px;
            }

            .items th {
                background-color: #004693;
                color: #ffffff;
                font-size: 10pt;
                padding: 6px 8px;
                text-align: left;
            }
            .items th.r,
            .items td.r {
                text-align: right;
            }
            .items td {
                font-size: 10pt;
                padding: 6px 8px;
                border-bottom: 1px solid #edf1f7;
            }

            .totals tr.final td {
                font-size: 13pt;
                font-weight: bold;
                padding-top: 8px;
            }

            .sig-line {
                border-bottom: 1px solid #8899b5;
                height: 30px;
                margin-top: 4px;
            }
            .footer {
                margin-top: 36px;
                border-top: 1px solid #d9e2ef;
                padding-top: 8px;
                font-size: 8pt;
                color: #8899b5;
            }
        </style>
    </head>
    <body>
        <table class="hdr">
            <tr>
                <td>
                    <div class="hdr-logo">{Account.Name}</div>
                </td>
                <td class="hdr-meta">
                    Quote #: {Name}<br />
                    Date: {Today}
                </td>
            </tr>
        </table>
        <div class="accent-bar"></div>

        <table class="grid-table">
            <tr>
                <td>
                    <div class="section-title">Prepared For</div>
                    <strong>{Account.Name}</strong><br />
                    {Account.ShippingAddress}
                </td>
                <td class="r">
                    <div class="section-title">Prepared By</div>
                    {RunningUser.Name}<br />
                    {RunningUser.Email}
                </td>
            </tr>
        </table>

        <div class="section-title" style="margin-top: 18px;">Line Items</div>
        <table class="items">
            <thead>
                <tr>
                    <th>Product</th>
                    <th class="r">Qty</th>
                    <th class="r">Price</th>
                    <th class="r">Total</th>
                </tr>
            </thead>
            <tbody>
                {#OpportunityLineItems}
                <tr>
                    <td>{Product2.Name}</td>
                    <td class="r">{Quantity}</td>
                    <td class="r">{UnitPrice:currency}</td>
                    <td class="r">{TotalPrice:currency}</td>
                </tr>
                {/OpportunityLineItems}
            </tbody>
        </table>

        <table class="totals" style="margin-top: 8px;">
            <tr class="final">
                <td></td>
                <td class="r">Total</td>
                <td class="r">{Amount:currency}</td>
            </tr>
        </table>

        <table style="margin-top: 36px;">
            <tr>
                <td style="width: 50%; padding-right: 24px;">
                    Customer Signature
                    <div class="sig-line">{@Signature_Buyer}</div>
                </td>
                <td style="width: 50%; padding-left: 24px;">
                    Date
                    <div class="sig-line">{@Signature_Buyer:1:Date}</div>
                </td>
            </tr>
        </table>

        <table class="footer">
            <tr>
                <td>{Account.Name} &bull; {Account.BillingCity}, {Account.BillingState}</td>
                <td style="text-align: right;">{Account.Website}</td>
            </tr>
        </table>
    </body>
</html>
```

##### Common conversion patterns

When an LLM (or a designer) hands you a template using modern CSS, here are the mechanical rewrites:

**Flex header → table header**

```html
<!-- BEFORE: ignored by Flying Saucer -->
<div style="display: flex; justify-content: space-between;">
    <div class="logo">ACME</div>
    <div class="meta">Date: {Today}</div>
</div>

<!-- AFTER: works -->
<table style="width: 100%;">
    <tr>
        <td>ACME</td>
        <td style="text-align: right;">Date: {Today}</td>
    </tr>
</table>
```

**Grid columns → table columns**

```html
<!-- BEFORE -->
<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 24px;">
    <div>Left content</div>
    <div>Right content</div>
</div>

<!-- AFTER -->
<table style="width: 100%;">
    <tr>
        <td style="width: 50%; padding-right: 12px;">Left content</td>
        <td style="width: 50%; padding-left: 12px;">Right content</td>
    </tr>
</table>
```

**Gradient → solid color**

```css
/* BEFORE */
.accent-bar {
    background: linear-gradient(to right, #004693, #35c6f4);
}

/* AFTER */
.accent-bar {
    background-color: #35c6f4;
}
```

**`gap` between rows → margin**

```css
/* BEFORE */
.stack {
    display: flex;
    flex-direction: column;
    gap: 12px;
}

/* AFTER */
.stack > * {
    margin-bottom: 12px;
}
```

##### `@page` rules — don't double-declare

Two ways to control the page size, margins, and orientation:

1. **Template fields** — `Page_Size__c`, `Page_Orientation__c`, `Page_Margins__c`, `Custom_Margins__c` on the Portwood Template record. Portwood wraps the template's HTML with an engine `<style>` block declaring `@page` from these fields.
2. **Source CSS** — your HTML's own `<style>` declares `@page { size: ... }`.

Pick one. If both are set, you get **two `<style>` blocks each declaring `@page`**, the cascade is non-deterministic, and dimensions can come out wrong. Recommended: leave the template fields blank when your source HTML already specifies `@page`. If you author in Google Docs (which sometimes injects an `@page` block on export) and then set `Page_Size__c` to "Legal", the conflict will silently produce a Letter document because the source CSS wins.

#### 5.7.4 Header / Footer fields

Two optional fields on a dedicated **Header / Footer** tab in the template edit modal (the tab shows for HTML templates, and the fields apply to **any** template type's PDF output — a Word→PDF template with Header/Footer HTML set gets them too):

- `Header_Html__c` — rendered in the top page margin of every PDF page
- `Footer_Html__c` — rendered in the bottom page margin of every PDF page

Each field has a WYSIWYG rich-text editor with a **Show HTML** / **Show Editor** toggle that flips to a monospace textarea showing the raw HTML (for image widths, inline styles, or any markup the rich editor can't expose). Every merge tag that works in the body works in these fields.

#### 5.7.5 Page numbers

Put `{PageNumber}` and `{TotalPages}` in the Header HTML or Footer HTML field. These compile to Flying Saucer CSS page counters inside the PDF's `@page` margin boxes — "Page 3 of 17" renders correctly on every page automatically.

Example footer HTML:

```html
<div style="text-align:center; font-size:9pt; color:#888;">Page {PageNumber} of {TotalPages}</div>
```

**Flying Saucer limitation:** page counters only resolve inside `@page` rules, not on DOM elements. When a header/footer contains counter tokens, Portwood renders that margin as plain text (no inline images or rich formatting). A header _without_ counters stays rich HTML via CSS running elements. Practical workaround: logo in the header (no counters), page count in the footer (counters only). Both fields can be populated simultaneously.

#### 5.7.6 Images

Three ways to get images into an HTML template:

1. **Google Docs zip** — images inserted in the Google Doc are bundled into the `.zip` and extracted automatically on upload.
2. **Inline data URIs** — `<img src="data:image/png;base64,...">` in the HTML (Notion / ChatGPT / pasted rich text) is scanned on save — upload, template-bundle import, or Generate-with-AI alike — and each is saved as its own ContentVersion with the `src` rewritten (v3.57+ extends this beyond the upload path).
3. **`{%Image:N}` / `{%FieldName}` merge tags** — same syntax as Word templates. Renders the Nth record-attached image, or a ContentVersion ID stored in a field. Emits `<img src="/sfc/...">` at merge time.

#### 5.7.7 Loops in tables

Loop auto-expansion works the same as Word. Either pattern produces one repeated row per record:

```html
<table>
    <thead>
        <tr>
            <th>Product</th>
            <th>Amount</th>
        </tr>
    </thead>
    <tbody>
        <!-- Pattern A: loop wraps the row -->
        {#OpportunityLineItems}
        <tr>
            <td>{Product2.Name}</td>
            <td>{TotalPrice:currency}</td>
        </tr>
        {/OpportunityLineItems}

        <!-- Pattern B: loop inside the row (Portwood expands to the <tr>) -->
        <tr>
            {#OpportunityLineItems}
            <td>{Product2.Name}</td>
            {/OpportunityLineItems}
        </tr>
    </tbody>
</table>
```

`<li>` list items auto-expand the same way.

#### 5.7.8 Bulk generation + Giant Query

HTML templates work with every generation path: single-record, bulk (individual PDFs or merged), and Giant Query (60K+ row child relationships via batched rendering). Same 12 MB Queueable heap envelope, same 50,000-row batch ceiling, same Flow action.

> **Giant-query limitation (HTML templates):** outside the giant loop itself — the title block, summary text, headers — only these tag families resolve: plain field/parent tags with format suffixes, `{Today}`/`{Now}`, `{RunningUser.X}`, aggregates, `{#ChartBucket}`, `{%Image:N}`, and `{%asset:…}`. Conditionals (`{#IF}`, `{^…}`), secondary child loops, barcodes, `{%FieldName}` image-field tags, and signature/form-field tags **print as raw text at the parent level** on this path. Keep the parent shell of a 2,000+-row HTML template to the supported tags. Word templates don't have this restriction — their parent content runs the full engine.

#### 5.7.9 Known limitations

- **Barcodes / QR codes** — `{*Field:qr}` / `{*Field:code128}` render in both Word **and** HTML templates (HTML support added in v3.15). They render as crisp CSS in the PDF — no external services.
- **DOCX output** — not applicable. HTML templates are PDF-only.
- **Signatures** — fully supported on HTML templates (as well as Word). `{@Signature_Role:Order:Type}` tags, guided field-to-field signing, draw-or-type, multi-signer, and the Certificate of Completion all work on HTML; HTML is in fact the recommended format for signature templates because the stamp-card layout has the most room to breathe.
- **Page counters + rich header/footer content** — see §5.7.5. Flying Saucer flattens the margin to text when counters are present.

#### 5.7.10 Troubleshooting

- **"Your company doesn't support the following file types: .zip"** — Portwood's LWC extracts the zip client-side and never uploads the zip itself, so this org-level File Upload Security error shouldn't appear in normal use. If you see it, hard-refresh the page (Cmd+Shift+R / Ctrl+Shift+R) to clear any cached LWC bundle.
- **Images show as broken squares in the PDF** — `Blob.toPdf` can only fetch images via relative `/sfc/` URLs; it can't reach arbitrary HTTPS URLs (no session ID). Make sure the image source is in the zip, a data URI in the HTML, a `{%Image:N}` tag, or a `{%FieldName}` pointing at a real ContentVersion.
- **Page numbers appearing without a configured header/footer** — your template's source HTML already has `@page { @bottom-center { content: counter(page) ... } }`. Google Docs' Web Page export sometimes includes this automatically. Either remove the `@page` block from the HTML body before upload, or accept it (many users actually want page numbers).
- **Merge tag shows up literally in the PDF (e.g. the text "{Name}")** — the tag didn't resolve. Check the field name is correct and in your Query Config, and that the WYSIWYG editor didn't HTML-encode the braces (Portwood decodes `&#123;` and `&#125;` automatically, but non-standard editors could still trip this).

### 5.8 Word template authoring tips

Word templates are the most common Portwood authoring path, and 95% of issues come from one of three quirks below. Worth a five-minute read before debugging a "but it looks fine in Word" rendering bug.

#### 5.8.1 Aligning columns across multiple tables — the "phantom width" trap

**Symptom.** Two or three tables that look identical in Word render with subtly different column widths in the PDF. Common variation: the middle columns of tables 2/3 collapse and the right-side columns push outward. Tables that look the same in Word do _not_ render the same.

**Why.** A `.docx` file describes table column widths in two places that must agree:

- `<w:tblGrid>` on each table — the column-grid definition (`<w:gridCol w:w="N"/>` per column, in twips; 1440 twips = 1 inch).
- `<w:tcW>` per `<w:tc>` (table cell) — a per-cell width override.

Word's display engine reconciles disagreements at render time and shows you a clean layout. **Flying Saucer (the Salesforce PDF engine) reads the XML literally** — small numeric differences become visible column-width differences. Common ways the two specs drift apart:

- A column boundary was dragged with the mouse, even briefly. Word may update some `<w:tcW>` values but not the `<w:tblGrid>`.
- AutoFit to Contents was on. Word recalculates column widths from cell content every time the table is touched — and any row with empty/sparse cells will collapse those columns toward minimum width.
- Cells were copy/pasted between tables. The cell brings its own `<w:tcW>` with it, which may not match the destination table's grid.

**Fix — in priority order.**

1. **Click in the table → Table Layout → AutoFit → Fixed Column Width.** This stops Word from recalculating widths on every save. Do this for _every_ table that needs to line up, not just the first one.
2. **Table Properties → Table tab → Preferred width = exact inches (or cm).** Not "Auto", not percentage. A literal measurement.
3. **Select each column → Table Properties → Column tab → Preferred width = exact inches.** Repeat for every column in every table.
4. **Build one table first, copy it to make the others.** After step 1–3 on Table 1, delete Tables 2 and 3 entirely, then paste-copy Table 1 below itself to create them. Edit only the cell _contents_ — never the column boundaries.

**If steps 1–4 don't fix it.** The `.docx` is a ZIP. Unzip it, open `word/document.xml` in a text editor, find each `<w:tbl>` block, and compare the `<w:tblGrid>` and `<w:tcW>` values. They should be byte-for-byte identical across the tables that need to align. If they're not, paste the values from your "good" table over the bad ones. Re-zip with the same compression and rename to `.docx`.

**Architectural alternative.** When in doubt, use **one big table** with borderless divider rows between sections instead of three separate tables. One grid means guaranteed alignment, with no Word arithmetic to fight.

#### 5.8.2 AutoFit settings — what each option does to the PDF

Word's Layout → AutoFit menu has three modes. They behave very differently when rendered to PDF.

| Mode                   | What Word does                                                          | What the PDF renderer sees                                                                                                        |
| ---------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **AutoFit Contents**   | Recalculates column widths from cell content on every save.             | Widths read from the recalculated `<w:tcW>` — empty cells collapse, full cells expand. _Avoid for multi-table layouts._           |
| **AutoFit Window**     | Tables expand to the page width, columns scale proportionally.          | Widths are percentages of page width — usually renders correctly _if_ the template doesn't fight with `@page` margins.            |
| **Fixed Column Width** | Locks widths to whatever you set in Table Properties. No recalculation. | Widths read exactly as written — predictable, reproducible. **Recommended for any table that has to line up with anything else.** |

#### 5.8.3 Inspecting a problematic `.docx`

Sometimes you just want to confirm what the XML actually says. A `.docx` is a ZIP file — change the extension to `.zip`, unzip it, and inspect `word/document.xml`. The structure that matters for table issues:

```xml
<w:tbl>
  <w:tblPr> ... </w:tblPr>
  <w:tblGrid>
    <w:gridCol w:w="1440" />   <!-- column 1: 1 inch -->
    <w:gridCol w:w="2880" />   <!-- column 2: 2 inches -->
    ...
  </w:tblGrid>
  <w:tr>
    <w:tc>
      <w:tcPr>
        <w:tcW w:w="1440" w:type="dxa" />   <!-- must match grid col 1 -->
      </w:tcPr>
      ...
    </w:tc>
    ...
  </w:tr>
</w:tbl>
```

For tables to align across the document, the `<w:tblGrid>` blocks of those tables must contain the same `<w:gridCol w:w="N"/>` values in the same order, and every `<w:tcW>` in column N must match `<w:gridCol>` N.

#### 5.8.4 Other Word authoring gotchas worth remembering

- **Track Changes.** Save with Track Changes off and all suggestions accepted/rejected. Tracked changes are stored in `<w:ins>` / `<w:del>` markup and the renderer treats them as live content.
- **Comments.** Same as above — `<w:commentRangeStart/>` markup can leave artifacts.
- **Embedded objects (Excel, drawings).** Native Word handles these; the PDF renderer treats them as static images and the result is hit-or-miss. Replace with screenshots if pixel-perfect output matters.
- **Section breaks with different page sizes.** Each section emits its own `@page` rule. Mixing portrait + landscape sections works in DOCX output but is fragile in PDF output (Flying Saucer applies the first section's page size to the whole document in some configurations).
- **Wingdings / custom symbol fonts.** See §14.2 — Flying Saucer ships with Helvetica, Times, Courier, Arial Unicode MS only. Wingdings checkboxes are auto-translated; other Wingdings glyphs render as empty boxes.
- **Image compression.** A 20MB Word template with uncompressed images will fail upload (10MB cap). Right-click any image → Compress Pictures → Email (96 ppi) or Web (150 ppi). A 20MB template typically drops to 1–2 MB with no visible quality loss.

---

# Portwood — Free Document Generation for Salesforce

Generate PDF, Word, Excel, and PowerPoint documents from any Salesforce record. Merge PDFs, add barcodes and QR codes, compute totals — 100% native: no external services, no callouts, your data never leaves Salesforce. 100% free forever. All features, all users, no paid tiers.

[Join the Community Channel](https://portwood.dev/community) | [Website](https://portwood.dev) | [Roadmap](https://portwood.dev/roadmap)

[![Version](https://img.shields.io/badge/version-3.56.0-blue.svg)](#install)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Salesforce-00A1E0.svg)](https://www.salesforce.com)
[![Namespace](https://img.shields.io/badge/namespace-portwoodglobal-purple.svg)](#install)
[![Apex Tests](https://img.shields.io/badge/Apex_Tests-1905_passing-brightgreen)](#security)
[![Coverage](https://img.shields.io/badge/Coverage-78%25-brightgreen)](#security)
[![Security](https://img.shields.io/badge/Code_Analyzer-0%2F0%2F0-brightgreen)](#security)
[![Website](https://img.shields.io/badge/website-portwood.dev-blue)](https://portwood.dev)

---

## Install

```bash
sf package install --package 04tVx0000010fnNIAQ --wait 10 --target-org <your-org>
```

[Install in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tVx0000010fnNIAQ) | [Install in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tVx0000010fnNIAQ)

**Then:** Assign **Portwood Admin** permission set | Enable **Blob.toPdf() Release Update** | Open the **Portwood** app

### Optional — AI template authoring

**Portwood Agentforce Extension** `04tVx000000zxUbIAI` adds _Generate with
Agentforce_: describe a document and Portwood writes the template, or ask for a
change in plain English and it revises the one you have. Requires Portwood 3.46+
and Einstein/Prompt Builder. **Free, and no installation key** as of v1.1.0.

[Install extension in Production](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tVx000000zxUbIAI) | [Install extension in Sandbox](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tVx000000zxUbIAI)

It ships separately because a package containing `ConnectApi.EinsteinLLM` or a
`GenAiPromptTemplate` is refused at install in any org without Einstein. Keeping
it optional is what lets Portwood install everywhere. See
[UserGuide § 5.7.11](UserGuide.md#5711-generate-the-template-with-agentforce-v346).

---

## Quick Start

1. **Create a template** — design one in the browser with the **Canvas designer**, or bring a Word, Excel, PowerPoint, or HTML file you already have. Choose your Salesforce object.
2. **Select your fields** — use the visual query builder, or paste a full SOQL statement for complex nested relationships.
3. **Add tags** — type `{Name}` where you want data. If you brought a file, upload it (or a Google Docs "Download → Web Page" zip for HTML templates).
4. **Generate** — from any record page, in bulk, or from a Flow.

Download example templates from [portwood.dev](https://portwood.dev).

---

## What You Can Do

### Template Formats

| Format                   | Template                | Output Options | Best For                                                   |
| ------------------------ | ----------------------- | -------------- | ---------------------------------------------------------- |
| **Canvas** _(beta)_      | designed in-browser     | PDF            | Laying a page out yourself — no Word, no HTML              |
| **Word**                 | `.docx`                 | PDF or DOCX    | Contracts, proposals, invoices, letters                    |
| **HTML** (v1.61+)        | `.html`, `.htm`, `.zip` | PDF            | Google Docs, Notion, ChatGPT, Apple Pages, any HTML source |
| **PDF** (v3.03+)         | `.pdf`                  | PDF            | Fillable PDF forms / AcroForm field mapping                |
| **Excel** _(alpha)_      | `.xlsx`                 | XLSX           | Data exports, reports, financial summaries                 |
| **PowerPoint** _(alpha)_ | `.pptx`                 | PPTX           | Presentations, slide decks                                 |

Word and HTML are the fully supported authoring formats — both handle images, rich text, headers/footers, barcodes, charts, and PDF output. **Excel and PowerPoint are alpha:** core merge mechanics work (fields, parent lookups, loops including PowerPoint slide-table rows, format suffixes), but expect rough edges — PowerPoint→PDF isn't supported by the Salesforce platform, and complex Excel formulas may not survive merging. For mission-critical decks and spreadsheets today, render to PDF or DOCX. See [UserGuide § 2](UserGuide.md#2-what-portwood-does).

**HTML templates** accept Google Docs "Download → Web Page" zips directly — the admin UI unzips client-side, extracts each image into a ContentVersion, and rewrites the HTML to reference them. Inline `data:image/...` URIs from Notion / ChatGPT / rich-text paste are handled the same way. Optional `Header HTML` / `Footer HTML` fields with a WYSIWYG editor (and a **Show HTML** toggle for raw-source edits) support merge tags including `{PageNumber}` and `{TotalPages}`.

### Canvas Designer (v3.54+, Beta)

**Design a document in the browser.** Pick **Start from a blank canvas** in the template wizard and you get an artboard the size of your page: drag a box where you want it, and that is where it prints. No Word, no HTML, nothing to upload.

- **Boxes go where you put them** — position and size in inches, pinned to the page or flowing with the content
- **Text, tables, images, shapes, QR codes and barcodes, signature placements** — with a rich-text editor inside any text box
- **Tables that grow with your data** — a row per related record, a nested list underneath each row (an opportunity's products under each opportunity), and totals that add themselves up
- **Images from your Asset Library** — the same shared images the rest of Portwood uses
- **Show a box only when it applies** — attach a condition and it appears only for the records that meet it
- **Import an existing HTML template** and keep editing it as boxes
- Undo/redo, layering, duplicate page, custom page sizes

Canvas templates always produce a PDF. **Marked Beta** — it is in customers' hands and working, and we are still adding to it (running headers and footers, multi-select, keyboard nudge). Existing templates are unaffected.

### Template Designer (v3.34+)

You don't have to leave Salesforce to author a template. The **Visual Designer** edits an HTML template on a real page canvas — WYSIWYG or raw source, switchable at any time:

- **Insert panel** — blocks, tables, charts, barcodes, special characters (or press `` ` `` anywhere on the page)
- **Tags panel** — your query's merge fields as clickable chips, styled inline like ordinary text
- **Images** — shared Asset Library, drag to place, corner-resize, align, double-click to edit the tag
- **Query panel** — the same click-to-build query tree used everywhere else, editable without leaving the designer
- **Versions, Header/Footer, and Watermark panels** — including background watermarks with baked-in opacity so canvas and PDF match
- **PDF Preview** — opens your unsaved draft in the native viewer, with nothing written to Files

**Generate with Agentforce (v3.46+)** — describe the document and Portwood writes the template; ask for a change in plain English and it revises what's on the canvas. Everything the model produces is validated against the PDF engine first (invisible `rgba()` tints flattened to hex, ignored `border-radius`/`box-shadow` stripped, stranded loop tags moved into cells), and any merge tag that went missing on an edit is reported by name. Reached through `ConnectApi`, not an HTTP callout. Requires the optional [Agentforce Extension](#optional--ai-template-authoring); **Copy AI Prompt** gives you the same brief for your own assistant without it.

### Merge Tags

| Tag                                     | What It Does                                | Example                                                      |
| --------------------------------------- | ------------------------------------------- | ------------------------------------------------------------ |
| `{FieldName}`                           | Insert a field value                        | `{Name}`, `{Email}`, `{Phone}`                               |
| `{Parent.Field}`                        | Pull from a related record                  | `{Account.Name}`, `{Owner.Email}`                            |
| `{#ChildList}...{/ChildList}`           | Repeat for each child record                | `{#Contacts}{FirstName}{/Contacts}`                          |
| `{#GroupBy List by Field}...{/GroupBy}` | One block/table per distinct value (v3.42+) | `{#GroupBy Lines by Product2.Family}{GroupName}…{/GroupBy}`  |
| `{#BoolField}...{/BoolField}`           | Show/hide based on checkbox                 | `{#IsActive}Active member{/IsActive}`                        |
| `{#Field}...{:else}...{/Field}`         | Show/hide with fallback                     | `{#Industry}Sector: {Industry}{:else}No industry{/Industry}` |
| `{^Field}...{/Field}`                   | Show when field is false/blank              | `{^HasDiscount}No discount applied{/HasDiscount}`            |
| `{#IF Field op Value}...{/IF}`          | Compare field against value                 | `{#IF Amount > 50000}Premium{:else}Standard{/IF}`            |
| `{RichTextField}`                       | Rich text with formatting and images        | `{Description}` renders bold, italic, lists                  |
| `{RowNumber}` (v3.49+)                  | 1-based row counter inside any loop         | `{#Contacts}{RowNumber}. {Name}{/Contacts}`                  |
| `{Today}` / `{Now}`                     | Generation date / date-time                 | `{Today:MMMM d, yyyy}`                                       |
| `{RunningUser.Field}`                   | Who generated the document                  | `Prepared by {RunningUser.Name}`                             |
| `{#Approvals}...{/Approvals}` (v1.92+)  | Classic approval history related list       | `{#Approvals}{StepStatus} — {ActorName}{/Approvals}`         |

`{RowNumber}` restarts per nested loop and per `{#GroupBy}` group, and counts straight through on giant-query tables. Full reference in [UserGuide § 7](UserGuide.md#7-merge-tag-reference).

### Formatting

| Tag                      | Output                     |
| ------------------------ | -------------------------- |
| `{CloseDate:MM/dd/yyyy}` | 03/18/2026                 |
| `{Amount:currency}`      | $500,000.00                |
| `{Rate:percent}`         | 15.5%                      |
| `{Quantity:number}`      | 1,234                      |
| `{IsActive:checkbox}`    | [X] or [ ]                 |
| `{StageName:label}`      | User-facing picklist label |

### Aggregates

Place these **outside** the loop to compute totals from child records:

| Tag                                     | Example                                |
| --------------------------------------- | -------------------------------------- |
| `{SUM:List.Field}`                      | `{SUM:QuoteLineItems.TotalPrice}`      |
| `{COUNT:List}`                          | `{COUNT:Contacts}`                     |
| `{AVG:List.Field}`                      | `{AVG:OpportunityLineItems.UnitPrice}` |
| `{MIN:List.Field}` / `{MAX:List.Field}` | `{MIN:QuoteLineItems.Quantity}`        |

### Images

Store a ContentVersion ID (starts with `068`) in a text field, then use `{%FieldName}` in your template:

| Tag                     | What It Does                                   |
| ----------------------- | ---------------------------------------------- |
| `{%Logo__c}`            | Insert image at original size                  |
| `{%Logo__c:200x60}`     | Fixed size: 200px wide, 60px tall              |
| `{%Logo__c:100%x}`      | Full page width, keep aspect ratio             |
| `{%Logo__c:m100%xm50%}` | Shrink to fit within page width and 50% height |

Images work in both **PDF** and **DOCX** output. You can also embed images directly in your Word template — they render in PDFs automatically.

### Rich Text Fields

Rich text fields render with full formatting (bold, italic, lists, images) in PDF output. Images inside rich text fields work in PDFs. For DOCX output, use `{%FieldName}` image tags instead of rich text images.

### Barcodes & QR Codes

Word **and** HTML templates (HTML support added in v3.15), across PDF and DOCX output. Generated natively in Apex — no external services required.

| Tag                             | What You Get                     |
| ------------------------------- | -------------------------------- |
| `{*ProductCode}`                | Code 128 barcode                 |
| `{*ProductCode:code128:300x80}` | Barcode at 300px wide, 80px tall |
| `{*Website:qr}`                 | QR code (150px default)          |
| `{*TrackingUrl:qr:200}`         | QR code at 200px square          |

QR codes use Level Q error correction and support values up to 600 characters. For printed or mailed documents, short URLs or tokens under 120 characters scan most reliably at 1 inch square. **Only `code128` and `qr` are supported** — an unsupported type (e.g. `code39`) renders nothing, silently.

### Charts (v1.99+)

Nine chart styles, one tag, every output format. Pure-Apex PNG rasterization — no `<canvas>`, no external services, no JavaScript libraries. Works in HTML→PDF (Flying Saucer), Word DOCX, Word→PDF, PowerPoint PPTX, and server-side Flow / batch / Queueable contexts.

```
{Chart:Survey_Responses__r:Selected_Answer__c}                                                            ← bar (default)
{Chart:Survey_Responses__r:Department__c:pie:title=Department Share}
{Chart:Survey_Responses__r:Selected_Answer__c:stacked:groupBy=Department__c&colSort=Eng,Sales,Marketing}
{Chart:Survey_Responses__r:Selected_Answer__c:line:groupBy=Department__c&colSort=Eng,Sales,Marketing}
```

| Style       | Visual                                               | Best for                                      |
| ----------- | ---------------------------------------------------- | --------------------------------------------- |
| `bar`       | Horizontal bars, label + count + percent             | One dimension, long labels                    |
| `column`    | Vertical bars                                        | One dimension, short labels                   |
| `pie`       | Pie + right-side legend                              | Share of total, ≤8 slices                     |
| `donut`     | Pie with center hole                                 | Pie, lighter visual                           |
| `pivot`     | Cross-tab table with Total column                    | Numeric matrix readout                        |
| `stacked`   | Horizontal stacked bar segmented by `groupBy`        | "How does each row split across dimension 2?" |
| `clustered` | Vertical clustered bars, mini-bar per col            | Side-by-side comparison                       |
| `line`      | Polyline through (bucket index, count), multi-series | Trend / ordering matters                      |
| `area`      | Line + semi-transparent fill below each series       | Trend + accumulated volume                    |

Composable modifiers: `title=`, `width=`, `height=`, `where=` (SOQL fragment), `groupBy=`, `colSort=`, `colors=` (hex palette), `split=` (multi-select delimiter), `scale=`, `htmlRender=svg`. Aggregates via SOQL `GROUP BY` — constant cost regardless of row count (verified end-to-end at 30,000 child rows). Full reference + LLM authoring prompt in `UserGuide.md` §7.6; reference templates ship in `docs/ChartEngineShowcase.{html,docx}`.

### Repeating Tables

To repeat rows inside a table (not the whole table), put the loop tags in the data row:

| Name                                | Title     | Email                |
| ----------------------------------- | --------- | -------------------- |
| `{#Contacts}{FirstName} {LastName}` | `{Title}` | `{Email}{/Contacts}` |

The `{#Contacts}` goes in the first cell and `{/Contacts}` goes in the last cell of the same row. The header row stays fixed, and the data row repeats for each record.

### Cover Pages & Section Breaks

- **Title pages** — If your Word template has "Different First Page" enabled, the PDF will suppress headers and footers on page 1. Your cover page stays clean.
- **Section breaks** — Section breaks in your Word template create proper page breaks in the PDF.

### Page Breaks in Loops

Put a page break inside a loop to give each child record its own page:

```
{#Opportunities}
Customer: {Account.Name}
Amount:   {Amount:currency}
                              ← page break here (Insert → Page Break in Word)
{/Opportunities}
```

### PDF Merger

Five ways to combine PDFs:

| Mode                  | What It Does                                                               |
| --------------------- | -------------------------------------------------------------------------- |
| **Generate & Merge**  | Generate a doc, then append existing PDFs from the record                  |
| **Document Packets**  | Generate from multiple templates, merge into one PDF                       |
| **Merge Only**        | Combine existing PDFs on the record with drag-and-drop ordering            |
| **Child Record PDFs** | Pull PDFs from child records (e.g., all Opportunity PDFs under an Account) |
| **Bulk Merge**        | After bulk generation, merge all generated PDFs into one download          |

### Giant Query Engine

Records with **2,000 to 50,000+ child records** are detected automatically. Same template, same button — the engine handles pagination and async processing behind the scenes.

### E-Signatures

Collect legally valid electronic signatures directly from Portwood — no third-party tools required. Built-in Simple Electronic Signature (SES) support that's valid under the US ESIGN Act and UETA. Guided field-to-field signing **on the actual PDF** — **draw or type** signatures and initials — date stamps, document packets, parallel / sequential / single multi-signer flows, decline flow, sender **and signer** completion notifications, and a **Certificate of Completion** (signed timestamps, IP, consent, document hash) — all 100% native. Send from the **Signature Sender** UI or trigger from a **Flow / platform event** — both take the same guided experience. Signed documents follow your template's **Document Title Format** naming, and each signature lands as a clean, professional signature stamp card.

**Signature tag syntax:** `{@Signature_Role:Order:Type}`

| Type       | What It Does                       | Example                         |
| ---------- | ---------------------------------- | ------------------------------- |
| `Full`     | Signer types their full legal name | `{@Signature_Buyer:1:Full}`     |
| `Initials` | Signer types their initials        | `{@Signature_Buyer:2:Initials}` |
| `Date`     | Auto-filled server timestamp       | `{@Signature_Buyer:3:Date}`     |
| `DatePick` | Signer selects a date              | `{@Signature_Buyer:4:DatePick}` |

Backward compatible: `{@Signature_Buyer}` still works (treated as `:1:Full`).

**How it works:**

1. Add signature tags to your Word template — Portwood auto-detects roles and placement types
2. Select template(s) from the Send For Signature tab — preview the merged document before sending
3. Each signer receives a branded email with a secure link
4. Signers verify their email with a 6-digit PIN, then walk through each placement step by step — an arrow points to where they need to sign, initial, or add a date
5. The document updates live as each placement is confirmed — signers can leave and resume later
6. After all signers complete, Portwood generates a signed PDF with an Electronic Signature Certificate

**Key features:**

- **Guided signing** — step-by-step walk-through with live document updates and arrow indicators
- **Document packets** — send multiple templates as one signing session (e.g., NDA + Contract + Addendum)
- **Sequential signing** — signers go one at a time in order (next signer notified after previous completes)
- **Decline flow** — signers can decline with a reason; sender is notified immediately
- **Sender notifications** — email alerts when each signer completes, when all are done, or when someone declines
- **Sender preview** — see the fully merged document with highlighted signature placements before sending
- **Resume support** — per-placement persistence; signers pick up exactly where they left off
- **Signer form fields** — collect input during signing (text, picklist, checkbox, date) and write the answers back to the related record automatically
- **In-person signing** — bypass the email PIN for signing on the spot, on freshly-created or previously-sent requests
- **Automated reminders** — configurable reminder emails for signers who haven't responded
- **Setup validation** — automated checklist verifies site, permissions, OWA, and email deliverability

**What's captured for every signature:**

| Data Point         | How                                                                    |
| ------------------ | ---------------------------------------------------------------------- |
| Signer identity    | Email PIN verification (SHA-256 hashed, 10-min expiry, 3 attempts max) |
| Consent            | Explicit checkbox — timestamp recorded                                 |
| IP address         | Server-side capture via request headers, shown on PDF certificate      |
| User agent         | Browser fingerprint                                                    |
| Document integrity | SHA-256 hash of the final PDF                                          |
| Tamper evidence    | Field history tracking on all audit fields                             |

**Verification:** Every signed PDF includes a certificate page with signer details (name, role, email, IP address, timestamps) and a verification URL. The verify page lets anyone upload a PDF to check its hash against the audit record — the file never leaves the browser.

**Admin setup:** Configure a Salesforce Site, assign the Guest Signature permission set, set an Org-Wide Email Address, and customize email branding — all from the Signatures tab in the Command Hub. An automated setup checklist shows green/red status for each requirement. See the Learning Center for step-by-step instructions.

### Query Builder

The query builder accepts full SOQL statements with unlimited nesting depth. Paste a query like:

```sql
SELECT Name, Industry,
    (SELECT FirstName, LastName, Account.Name FROM Contacts),
    (SELECT Name, Amount,
        (SELECT Quantity, Product2.Name FROM OpportunityLineItems)
    FROM Opportunities WHERE StageName = 'Closed Won')
FROM Account
```

The builder parses the query, displays the field tree with parent lookups highlighted, and generates copy-paste merge tags for your template. Outer `SELECT` / `FROM` clauses are stripped automatically — Portwood always runs against a specific record.

**Tips:**

- Test your query in Developer Console or tools like [Salesforce Inspector](https://chromewebstore.google.com/detail/salesforce-inspector-reloaded/hpijlohoihegkfehhibggnkbjhoemldh) before pasting.
- Use AI to help build complex queries — Agentforce, ChatGPT, Gemini, and Claude can all generate valid SOQL with nested relationships.
- Subqueries support WHERE, ORDER BY, and LIMIT clauses.
- Parent lookups (e.g., `Account.Name`, `Product2.Family`) work at every nesting level.

### Automation

Six Flow invocable actions ship with the package:

| Flow Action                          | Class                          | Use In                                                      |
| ------------------------------------ | ------------------------------ | ----------------------------------------------------------- |
| Generate Document                    | `DocGenFlowAction`             | Record-Triggered Flows, Screen Flows                        |
| Generate Bulk Documents              | `DocGenBulkFlowAction`         | Scheduled Flows, bulk processing (sort order, WHERE filter) |
| Generate Document (Auto Giant Query) | `DocGenGiantQueryFlowAction`   | Records whose child-row count is unpredictable              |
| Create Signature Request             | `DocGenSignatureFlowAction`    | Guided signing from a Flow — returns signing URLs           |
| Write Back Signer Form Fields        | `DocGenFieldWritebackService`  | Retry/custom flows (writeback is automatic)                 |
| Send Existing Document for Signature | `DocGenSignaturePdfFlowAction` | **Deprecated** — use Create Signature Request               |

Templates can be addressed by **API Name** instead of Id (v3.28+), so a Flow survives a template rebuild. Three further helpers (`DocGenSignatureValidator`, `DocGenSignatureSubmitter`, `DocGenSignatureFinalizer`) support custom signing UIs. Full signatures and worked recipes in [UserGuide § 11](UserGuide.md#11-flow-automation-cookbook) and [§ 12.4](UserGuide.md#124-flow-invocable-actions-full-signatures).

You can also call `DocGenService.generateDocument` directly from Apex, or feed a template from your own class through the [`DocGenDataProvider` interface](UserGuide.md#125-docgendataprovider-interface--custom-data-source) — computed values or external data, no query builder involved.

### Generating & Bulk Generation

From a record page, choose **Save to Record**, **Download**, or **Save & Download** (v3.49+) — the last generates once and does both, with no size limit on either half.

Bulk generation runs the same templates across thousands of records: enter a filter condition, pick a **sort order** (any field, including a field on a related record), and submit. Real-time progress tracking in the app, and generated PDFs can be merged into a single combined download.

---

## What Works in PDF vs DOCX

| Feature                                        | PDF                          | DOCX                           |
| ---------------------------------------------- | ---------------------------- | ------------------------------ |
| All merge tags and formatting                  | Yes                          | Yes                            |
| Bold, italic, underline, colors, font sizes    | Yes                          | Yes                            |
| Tables with borders, shading, column widths    | Yes                          | Yes                            |
| Template-embedded images                       | Yes                          | Yes                            |
| Dynamic images from record fields (`{%Field}`) | Yes                          | Yes                            |
| Rich text field formatting                     | Yes                          | Yes                            |
| Rich text images                               | Yes                          | No — use `{%Field}` image tags |
| Barcodes and QR codes                          | Yes                          | Yes                            |
| Charts (`{Chart:…}`)                           | Yes                          | Yes                            |
| Clickable hyperlinks                           | Yes (v1.1.3+)                | Yes                            |
| Page numbers in headers/footers                | Yes                          | N/A (Word handles natively)    |
| Cover page (no header on page 1)               | Yes                          | N/A (Word handles natively)    |
| Custom fonts (Calibri, branded, etc.)          | No — falls back to Helvetica | Yes — preserves original fonts |

---

## PDF Font Support

Salesforce's PDF engine supports these fonts:

| Font                 | CSS Name             | When It's Used                                                |
| -------------------- | -------------------- | ------------------------------------------------------------- |
| **Helvetica**        | `sans-serif`         | Default for all text                                          |
| **Times**            | `serif`              | If explicitly set in template                                 |
| **Courier**          | `monospace`          | Fixed-width text                                              |
| **Arial Unicode MS** | `'Arial Unicode MS'` | Symbols, checkmarks, and CJK / Greek / Cyrillic / Hebrew text |

Custom fonts from your Word template (Calibri, Cambria, branded typefaces) **fall back to Helvetica** in PDF output. If custom fonts matter, generate as DOCX — Word preserves the original fonts.

### Symbols and non-Latin text need Arial Unicode MS — by name

This one is worth knowing before it costs you an afternoon. Characters like ✓ ✔ ☑ ☐ ✗ ● ★ → √ ≤ ≥, and any Chinese, Japanese, Korean, Greek, Cyrillic or Hebrew text, render as **nothing at all** under the default fonts — no glyph, no empty box, no warning. The paragraph simply comes out short.

Set the font explicitly and they draw correctly, in regular, bold and italic:

```css
font-family: 'Arial Unicode MS';
```

The Canvas designer's **Symbols** control inserts them with the font already attached, so this is handled for you there. Wingdings and other symbol fonts are still not available at all.

---

## What PDF Can't Do

These are Salesforce platform limitations, not Portwood bugs:

| Not Supported            | Why                                                                                                  | Workaround                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Custom fonts             | `Blob.toPdf()` only has 4 built-in fonts                                                             | Generate as DOCX                                                            |
| `@font-face` CSS         | Not supported by the PDF renderer                                                                    | Generate as DOCX                                                            |
| Text boxes and shapes    | Word drawing objects aren't converted to HTML                                                        | Use tables for layout                                                       |
| SmartArt, Word charts    | Word's own graphics aren't rendered in the HTML conversion                                           | Use Portwood's `{Chart:…}` tag, or insert as an image                       |
| Wingdings / symbol fonts | Not among the engine's fonts — glyphs render as empty boxes                                          | Checkbox glyphs auto-translate; use Unicode symbols in `'Arial Unicode MS'` |
| CSS Grid / Flexbox       | The PDF renderer supports CSS 2.1 only                                                               | Use tables                                                                  |
| JavaScript               | Ignored by the renderer                                                                              | N/A                                                                         |
| Even/odd page headers    | Not currently supported                                                                              | Same header on all pages                                                    |
| Multiple section headers | One header/footer set per document                                                                   | Use page breaks, not section-specific headers                               |
| Multi-column layouts     | CSS columns not supported by the PDF engine                                                          | Use tables for column layouts                                               |
| PowerPoint → PDF         | The platform can't convert `.pptx` to PDF                                                            | Render PPTX natively, or author the deck in Word/HTML                       |
| E-signatures (QES)       | SES signatures are built-in; Qualified Electronic Signatures (EU eIDAS) require a certified provider | Use built-in SES for most use cases                                         |

---

## Governor Limits

| Limit                     | Details                    | How Portwood Handles It                                           |
| ------------------------- | -------------------------- | ----------------------------------------------------------------- |
| **6 MB heap (sync)**      | Single document generation | DOCX uses client-side assembly; PDF uses zero-heap image pipeline |
| **12 MB heap (async)**    | Bulk batch generation      | Batch size 1 = fresh heap per record                              |
| **~3 MB PDF save**        | Saving PDF to a record     | Download has no size limit                                        |
| **4 MB Aura payload**     | Saving DOCX to a record    | Download works for any size                                       |
| **100 SOQL queries**      | Per transaction            | Multi-level queries use 1 SOQL per relationship depth             |
| **50,000+ child records** | Giant datasets             | Auto-detected, processed async with cursor pagination             |

---

## Architecture

```
Template (.docx/.xlsx/.pptx)
    ↓
Decompress → Merge XML tags → Recompress
    ↓                              ↓
  DOCX/XLSX/PPTX              PDF path:
  (client-side ZIP)     DocGenHtmlRenderer → Blob.toPdf()
```

| Class                         | Role                                                                 |
| ----------------------------- | -------------------------------------------------------------------- |
| `DocGenService`               | Core merge engine — tags, loops, images, aggregates, barcodes        |
| `DocGenHtmlRenderer`          | DOCX XML → HTML for PDF rendering                                    |
| `DocGenDataRetriever`         | Multi-level SOQL with query tree stitching                           |
| `BarcodeGenerator`            | Code 128 + QR code generation (pure Apex)                            |
| `DocGenController`            | LWC controller — template CRUD, generation endpoints                 |
| `DocGenBatch`                 | Batch Apex for bulk document generation                              |
| `DocGenGiantQueryAssembler`   | 2,000+ child-row path — chunked assembly, parent-tag resolution      |
| `DocGenChartBucketResolver`   | Chart aggregation — in-memory and SOQL `GROUP BY` fallback           |
| `DocGenSignatureController`   | Signing page — token validation, PIN verification, signature capture |
| `DocGenSignatureService`      | Typed-name stamping, PDF generation, verification certificate        |
| `DocGenSignatureEmailService` | Branded signature request and PIN emails with OWA support            |
| `docGenPdfMerger.js`          | Client-side PDF merge engine (pure JS)                               |
| `docGenZipWriter.js`          | Client-side DOCX/XLSX assembly (pure JS)                             |

---

## Releases

Portwood ships on a **biweekly release cycle**.

| Version     | Headline                                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **v3.56.0** | Set the label size on a chart; bold on Arial Unicode MS no longer silently does nothing                                         |
| **v3.55.0** | Elements that travel together on the Canvas, named blocks, and charts on datasets that used to be too big                       |
| **v3.54.0** | **Canvas designer (Beta)** — design a document in the browser, no Word or HTML needed                                           |
| **v3.53.0** | Excel documents save as `.xlsx`, and a template set to PDF now produces a PDF from Flows too                                    |
| **v3.52.0** | Runner on any Lightning page with built-in record search; **Show Save & Download** is now its own App Builder checkbox          |
| **v3.51.0** | Smarter AI template authoring — the prompt now covers `{RowNumber}`, `{#GroupBy}`, `{#IF}`, charts, images, and signature types |
| **v3.50.0** | Renamed to Portwood — display names only; every API name is unchanged, nothing you built needs updating                         |
| **v3.49.0** | Bulk sort order, `{RowNumber}`, and **Save & Download** in a single generation                                                  |
| **v3.48.0** | Bulk generation gets conditionals, charts, multi-column sorting; Template Designer opens for non-admins                         |
| **v3.47.0** | PowerPoint table loops, GUID preservation, split-run merge tags                                                                 |
| **v3.46.0** | AI template authoring with Agentforce — validated against the PDF engine before it reaches your canvas                          |
| **v3.45.0** | Visual Designer editing overhaul, running-header fixes, silent-degradation logging to the Error Log                             |
| **v3.34.0** | The HTML-first template wizard and the visual Template Designer (Beta)                                                          |

<details>
<summary>Longer narrative of recent releases</summary>

**v3.56.0 — set the label size on a chart**: chart labels are drawn at a fixed size, so a chart placed in a small frame came out with text too small to read and there was no way to change it. A **Label size** box on the Canvas chart, or `fontSize=` on a chart tag, now sets it — and the title and other text scale with it so the chart keeps its proportions. Also fixed: **Bold** on text set to Arial Unicode MS looked switched on and printed regular, because that font has no bold face in the PDF engine; the control is now disabled for it, so what you see is what prints. Before that: **v3.55.0 — elements that travel together, named blocks, and charts on big datasets**: on the Canvas, a block can now be told to **follow another one**. Put a summary, a note or a signature panel under a table and it stays under it — however many rows the merge produces, and onto whatever page the table ends on, instead of being printed straight through. Links chain, so a whole set moves as one, and any block can be kept from splitting across a page break. Blocks can also be **named**: give one a name and that is what the properties panel, the element list and every other block's Follows picker call it, which is the difference between a usable document and six boxes all labelled with the same first few words. **Charts** are now a Canvas element with a live preview while you design. Separately, PowerPoint and Excel documents now assemble in the browser the way Word always has, so the 6 MB limit that used to refuse a template over a few thousand child records is no longer the ceiling — tested to 30,000 — and charts on that path render with Chart.js. Three fixes worth calling out: a `<style>` block inside `<body>` had its CSS eaten by the merge engine and printed a line of bare selectors at the top of the document; `.docx`, `.pptx` and `.xlsx` downloads failed in orgs with Lightning Web Security enabled; and a Flow validating signature tokens in bulk hit a governor limit and lost the whole batch rather than the part it could not finish. Before that: **v3.54.0 — the Canvas designer (Beta)**: design a document in the browser. Choose **Start from a blank canvas** and you get an artboard the size of your page — drag a box where you want it and that is where it prints. Text with a proper rich-text editor, tables, images from your Asset Library, shapes, QR codes and barcodes, and signature placements, all placed by hand rather than fought into position through Word styles or HTML. Tables grow with your data, including a nested list under each row — an opportunity's products beneath each opportunity — with totals that add themselves up. Any box can be given a condition so it appears only for the records it applies to. There is an importer for an existing HTML template if you would rather start from one, plus undo/redo, layering, duplicate page, and custom page sizes. Canvas templates always produce a PDF. It ships marked **Beta**: it is in customers' hands and working, and running headers/footers, multi-select and keyboard nudge are still to come. Nothing about existing Word, HTML, Excel, PowerPoint or PDF templates changes. One thing worth knowing across all PDF output: symbols like ✓ ✔ ★ and any CJK, Greek, Cyrillic or Hebrew text only draw if you set `font-family: 'Arial Unicode MS'` — under the default fonts they render as nothing at all, silently. The Canvas Symbols control does this for you. Before that: **v3.53.0 — Excel files open again, and a PDF template makes a PDF everywhere**: two fixes for documents generated outside the runner — from a Flow, from a bulk job, or saved to a record in the background. Excel templates were producing a workbook named `.docx`, which neither Word nor Excel will open; they now come out as `.xlsx`. And a template whose Output Format reads **PDF** was still producing a Word file when a Flow generated it, because the running document was reading the format saved with the template's active version rather than the format shown on the template itself. Those two now agree. **One step for existing templates:** if a template has been generating the wrong format, open it in Template Manager and click **Save** once — that re-points it, and it stays fixed. Templates that were already producing the right format need nothing. Before that: **v3.52.0 — the runner goes anywhere, and Save & Download is yours to switch off**: the document runner no longer needs a record page. Put it on a Lightning app page or its own tab, tell it which object to search, and users find the record they want right inside the runner — useful for a "generate a document" landing page that is not tied to browsing to a record first. A fixed record Id works too, for a page that always produces the same document. Screen flows get the same search option for the case where no record Id is passed in. Separately, **Save & Download** — the option that files a copy on the record and downloads one in a single generation — now has its own checkbox in the Lightning App Builder, so you can offer Download and Save to Record without it. Existing record-page placements are untouched; both changes are opt-in configuration. Before that: **v3.51.0 — smarter AI template authoring**: the built-in AI template writer now knows Portwood's full tag vocabulary. Ask it for numbered rows, a separate table for each product family, a chart, or a section that only appears when there is something to put in it, and you get a template that works the first time instead of a near miss — because the AI is told about those capabilities up front rather than left to guess at them. This applies whether you write templates inside Salesforce with Agentforce or copy the prompt out to your own assistant. Separately, the **Agentforce Extension** is now free and installs with **no installation key**. Before that: **v3.50.0 — renamed to Portwood**: "DocGen" is gone from the interface — the app, its tabs, its objects, and its permission sets now read Portwood. No functional change and no action required; every API name is unchanged, so nothing you have built on top of the package needs updating. Before that: **v3.49.0 — bulk sort order, row numbering, and Save & Download**: bulk jobs can now be sorted by any field — including a field on a related record, like the Account name — so a combined PDF comes out in the order you expect instead of the order records happened to be created; the same control is available to Flows. Table rows can number themselves with a new `{RowNumber}` tag, which counts straight through even on very large tables. Generating a document no longer forces a choice between keeping a copy and filing it: a new **Save & Download** option does both from a single generation, with no size limit on either half. Also fixed: the Template Designer could silently load an older version of a template body when two versions were saved in the same second. Before that: **v3.48.0 — bulk generation: conditionals, charts, sorting, and Designer access**: conditional sections and filtered related lists now behave in bulk exactly as they do for a single record — a tag that only shows for certain records, or a related list limited to its first few rows, produced the wrong output in bulk jobs and reported success while doing it. Charts render in bulk jobs for the first time. Related lists can be sorted by more than one column, with a proper picker instead of typing a clause. Cloning a template now brings every file with it, including images and the HTML body. PowerPoint and Excel templates are no longer offered a combined-PDF mode they cannot produce — run them as individual files and you get one native file per record. **Template Designer access:** users who are not System Administrators could open a template and see an empty page; the Designer now loads correctly for anyone with the Portwood Admin permission set, and a template body can no longer be replaced by an empty document if the editor fails to load it. Before that: **v3.47.0 — PowerPoint table loops, GUID preservation, split-run merge tags**: PowerPoint templates now work with related lists — put merge tags in a slide table row and that row repeats once per related record, so an opportunity's products or a project's tasks fill the table automatically, the same way they already do in Word. Two further PowerPoint fixes land with it: a merge tag broken up by formatting (a stray spell-check underline was enough) now resolves instead of coming out blank, and slide tables keep the exact style you designed rather than falling back to a default. Word, HTML, Excel, and PDF output are unchanged. Before that: **v3.46.0 — AI template authoring with Agentforce**: describe the document you want and Portwood writes the template, right inside Salesforce; ask for a change in plain English and it revises what is on the canvas rather than starting over. Everything the model produces is checked against the PDF engine first — `rgba()` tints that would render invisible are converted to flat hex, `border-radius` and `box-shadow` are stripped because the engine ignores them, and loop tags stranded between table rows are moved into the cells — and you are told exactly what changed and why. On an edit, any merge tag that went missing is reported by name, because a lost tag renders as nothing and looks fine on screen. Reached through `ConnectApi`, not an HTTP callout, so nothing leaves the platform. Requires the optional **Agentforce Extension** package; without it nothing changes. Before that: **v3.45.0 — Visual Designer editing overhaul, running-header fixes, silent-degradation logging**: the visual Designer got a large quality pass — edit a merge tag straight from its menu, format a whole block of table cells at once, set table border thickness and colour, and see a preview of what you are dragging before you drop it; table controls are easier to find and stay put long enough to click. Documents with a running header keep it clear of the page content. Generation problems that used to pass silently — a logo that could not be loaded, a chart that came back empty — are now recorded in the Portwood Error Log. **Note for existing bulk jobs:** bulk generation now honours the template's Record Filter, so a job that relied on the old behaviour will produce fewer documents, because it was previously generating for records the template excludes. Before that: **v3.44.0 — e-signature certificate unification, multi-signer verify fix, Designer panel close fix**: the Certificate of Completion is now identical on both signing paths (same ESIGN/UETA attestation and verify-page link); uploading a completed multi-signer PDF to the verify page returns **every** signer, not just the last (the token link already did); and the Designer's slide-in panels — Insert, Tags, Images, Query, Versions, Header/Footer, Watermark — no longer hide behind the Salesforce tab bar in console / NPSP navigation, keeping a reachable close button and closing with Escape. Before that: **v3.43.0 — button-builder access hardening**: managing record-page document buttons is now a deliberately-assigned, least-privilege capability — a standalone **Portwood Button Manager** permission set (separate from Portwood Admin), and the builder tab appears only for admins who also hold Salesforce's metadata-customization permission (which the package never grants). Before that: **v3.42.0 — group-by tables, button builder, historical PIN bypass**: a new `{#GroupBy}` tag renders one table per category automatically (50 categories → 50 tables, no manual setup); a point-and-click **Buttons** tab in the Command Hub builds record-page document buttons — pick the object, template, and which record types show them — with no Setup navigation; and admins can bypass the email PIN on previously-sent signature requests, not just freshly-created ones. Before that: **v3.41.0 — designer save reliability**: new paragraphs and blocks you add in the visual designer's Visual mode now save reliably (a managed-package-only Lightning security sandbox dropped browser-added content when serializing the canvas back to HTML), and the starter templates size your logo correctly out of the box. Before that: **v3.40.0 — designer canvas stability**: backspacing at the page's top-left corner can no longer make the white canvas disappear — the caret is steered onto real content before any edit runs, and the page's styling self-heals if an editing quirk ever removes it. Before that: **v3.39.0 — designer reliability fix for installed orgs**: resolves designer freezes, Visual/Source switching losing changes, and silently dropped edits in orgs whose Lightning security sandbox lacks a modern DOM method; saves now stage by comparing actual content. Before that: **v3.38.0 — instant PDF previews**: the designer's PDF Preview opens your draft in a new tab in the native viewer with nothing saved to Files, the AI prompt now teaches image sizing, barcodes/QR, and charts (and points assistants at the full UserGuide), and barcode tags show at true printed size on the canvas. Before that: **v3.37.0 — one visual query builder everywhere**: the click-to-build query tree now powers the designer's Query panel and the Generate-with-AI step (parent lookups at any depth, filtered related lists, live-updating AI prompt), and designer images are first-class — drag to place, corner-resize, align, double-click to edit the tag. Recent releases: **v3.36.0** made merge tags style like text with a Google-Docs-style point-size box; **v3.35.0** brought Excel-level table editing, watermarks on HTML-template PDFs, scan-verified barcodes, and a landscape Certificate starter; **v3.34.0** introduced the HTML-first template wizard and the visual Template Designer (Beta).

</details>

See the [GitHub Releases](https://github.com/Portwood-Global-Solutions/Portwood/releases) page for every tagged release, or [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Community

Portwood is 100% free, open source, and community-driven. Built and published by [Portwood Global Solutions](https://portwood.dev).

| Channel                                                                       | What It's For                                      |
| ----------------------------------------------------------------------------- | -------------------------------------------------- |
| [Community Channel](https://portwood.dev/community)                           | Real-time help, feature requests, template sharing |
| [GitHub Issues](https://github.com/Portwood-Global-Solutions/Portwood/issues) | Bug reports and tracked feature requests           |
| [Changelog](https://portwood.dev/changelog)                                   | What's shipped, release by release                 |
| [Roadmap](https://portwood.dev/roadmap)                                       | What's coming next                                 |
| [Website](https://portwood.dev)                                               | Install links, feature overview                    |

Need dedicated support? Contact us at [hello@portwood.dev](mailto:hello@portwood.dev).

## Contributing

We welcome contributions — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions.

## Security

### Code Analyzer Results

We run the [Salesforce Code Analyzer](https://developer.salesforce.com/docs/platform/salesforce-code-analyzer/guide/engine-sfge.html) with **Security + AppExchange** rule selectors on every release.

| Severity     | Count | Status |
| ------------ | ----- | ------ |
| **Critical** | 0     | Clean  |
| **High**     | 0     | Clean  |
| **Moderate** | 0     | Clean  |
| **Low**      | 0     | Clean  |

Three PMD rules are disabled in [`code-analyzer.yml`](code-analyzer.yml). Each emits only name-pattern false positives on this codebase, on metadata that cannot carry an inline suppression:

- `ProtectSensitiveData` (29) — flags field _names_ containing "Token", "Signature", "Signer", "Email", "Hash", "PIN". Every hit is a legitimate signature/audit/branding field, protected structurally by permission sets, ControlledByParent sharing, field history tracking, and SHA-256 hashing at rest for the genuinely secret ones (`Secure_Token__c`, `PIN_Hash__c`).
- `AvoidHardcodedCredentialsInFieldDecls` (39) — flags `TYPE_TOKENS` in `DocGenEmailTemplateController`, a map of merge-token _chip labels_ shown in the Email Templates editor. UI strings, not credentials.
- `AvoidLwcBubblesComposedTrue` (9) — `composed: true` is required in the recursive `docGenTreeNode` LWC so tree events reach the tree builder outside the shadow boundary. The events carry node ids and field selections only.

Each disable is documented in `code-analyzer.yml` with the conditions under which it must be re-enabled. One `eslint:@lwc/lwc/no-inner-html` finding is suppressed **inline at its single call site** (the admin-authored email preview behind `lwc:dom="manual"`) rather than engine-wide, so every other component still enforces the rule.

### How Access Is Enforced

| Layer                      | Mechanism                                                                                                                             |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Object CRUD**            | `DocGen_Admin` / `DocGen_User` permission sets — labeled **Portwood Admin** / **Portwood User** (platform-enforced)                   |
| **Field-level security**   | Same permission sets (platform-enforced)                                                                                              |
| **Record sharing**         | Admin-context classes use `with sharing`; signature classes use `without sharing` with access gated by cryptographic token validation |
| **Standard objects**       | `USER_MODE` + `Security.stripInaccessible()` (code-enforced)                                                                          |
| **Signature guest access** | `SYSTEM_MODE` with 64-char SHA-256 token + email PIN verification                                                                     |

No user can access Portwood data without an explicitly assigned permission set. Signature guest users can only access records matching their validated cryptographic token.

### E-Signature Security

| Control            | Implementation                                                                       |
| ------------------ | ------------------------------------------------------------------------------------ |
| Token generation   | `Crypto.generateAesKey(256)` + SHA-256 hash (64-char hex)                            |
| Token expiry       | 48 hours from creation                                                               |
| PIN verification   | 6-digit code, SHA-256 hashed (plaintext never stored), 10-min expiry, 3 attempts max |
| Consent            | Explicit checkbox with audit trail entry                                             |
| Document integrity | SHA-256 hash of final PDF stored on audit record                                     |
| Tamper evidence    | Field history tracking on all audit fields                                           |
| IP capture         | Server-side via `X-Forwarded-For` / `True-Client-IP` headers                         |

Found a vulnerability? See [SECURITY.md](SECURITY.md).

## Version History

The optional **Portwood Agentforce Extension** versions independently: **v1.1.0** `04tVx000000zxUbIAI` (latest, free, no installation key), v1.0.0 `04tVx000000s80bIAA`.

| Version | Channel                                 | Package ID           |
| ------- | --------------------------------------- | -------------------- |
| v3.56.0 | **Latest (Released)**                   | `04tVx0000010fnNIAQ` |
| v3.55.0 | Released                                | `04tVx0000010fXFIAY` |
| v3.54.0 | Released                                | `04tVx0000010Y4LIAU` |
| v3.53.0 | Released                                | `04tVx0000010BvlIAE` |
| v3.52.0 | Released                                | `04tVx000000zz6bIAA` |
| v3.51.0 | Released                                | `04tVx000000zxWDIAY` |
| v3.50.0 | Released                                | `04tVx000000zxCrIAI` |
| v3.49.0 | Released                                | `04tVx000000zvz3IAA` |
| v3.48.0 | Released                                | `04tVx000000zgS9IAI` |
| v3.47.0 | Released                                | `04tVx000000zMTRIA2` |
| v3.46.0 | Released                                | `04tVx000000s7yzIAA` |
| v3.45.0 | Released                                | `04tVx000000s7pJIAQ` |
| v3.44.0 | Released                                | `04tVx000000rlATIAY` |
| v3.43.0 | Released                                | `04tVx000000rkeDIAQ` |
| v3.42.0 | Released                                | `04tVx000000rj5RIAQ` |
| v3.41.0 | Released                                | `04tVx000000rfD7IAI` |
| v3.40.0 | Released                                | `04tVx000000rWrNIAU` |
| v3.39.0 | Released                                | `04tVx000000rGkzIAE` |
| v3.38.0 | Released                                | `04tVx000000rEmPIAU` |
| v3.37.0 | Released                                | `04tVx000000rEknIAE` |
| v3.36.0 | Released                                | `04tVx000000rEPpIAM` |
| v3.35.0 | Released                                | `04tVx000000rEODIA2` |
| v3.34.0 | Released                                | `04tVx000000rEKzIAM` |
| v3.33.0 | Released                                | `04tVx000000qjDxIAI` |
| v3.32.0 | Released                                | `04tVx000000qZxlIAE` |
| v3.31.0 | Released                                | `04tVx000000qZuXIAU` |
| v3.30.0 | Released                                | `04tVx000000qERtIAM` |
| v3.29.0 | Previous                                | `04tVx000000pe3RIAQ` |
| v3.28.0 | Previous                                | `04tVx000000paUTIAY` |
| v3.27.0 | Previous                                | `04tVx000000oiyjIAA` |
| v3.26.0 | Previous                                | `04tVx000000ohhhIAA` |
| v3.25.0 | Previous                                | `04tVx000000oCvdIAE` |
| v3.24.0 | Previous                                | `04tVx000000oAnNIAU` |
| v3.23.0 | Previous                                | `04tVx000000o8wsIAA` |
| v3.22.0 | Previous                                | `04tVx000000o2eXIAQ` |
| v3.21.0 | Previous                                | `04tVx000000npXdIAI` |
| v3.20.0 | Previous                                | `04tVx000000nij3IAA` |
| v3.19.0 | Previous                                | `04tVx000000ncSLIAY` |
| v3.18.0 | Previous                                | `04tVx000000nbBJIAY` |
| v3.17.0 | Previous                                | `04tVx000000nZJBIA2` |
| v3.16.0 | Previous                                | `04tVx000000nZ4fIAE` |
| v3.15.0 | Previous                                | `04tVx000000nZ33IAE` |
| v3.14.0 | Previous                                | `04tVx000000nYgTIAU` |
| v3.13.0 | Previous                                | `04tVx000000nYdFIAU` |
| v3.12.0 | Previous                                | `04tVx000000nYTZIA2` |
| v3.11.0 | Previous                                | `04tVx000000nPGbIAM` |
| v3.10.0 | Previous                                | `04tVx000000nOh7IAE` |
| v3.09.0 | Previous                                | `04tVx000000nOdtIAE` |
| v3.08.0 | Previous                                | `04tVx000000nOFhIAM` |
| v3.07.0 | Previous                                | `04tVx000000nLOHIA2` |
| v3.06.0 | Previous                                | `04tVx000000nIv4IAE` |
| v3.05.0 | Previous                                | `04tVx000000nI5RIAU` |
| v3.04.0 | Previous                                | `04tVx000000nGZtIAM` |
| v3.03.0 | Previous                                | `04tVx000000nEHxIAM` |
| v3.02.0 | Previous                                | `04tVx000000muJFIAY` |
| v3.01.0 | Previous                                | `04tVx000000hWJBIA2` |
| v3.0.0  | Previous                                | `04tVx000000a8blIAA` |
| v2.9.0  | Previous                                | `04tVx000000a7fhIAA` |
| v2.8.0  | Previous                                | `04tVx000000a7e5IAA` |
| v2.7.0  | Previous                                | `04tVx000000a1IXIAY` |
| v2.6.0  | Previous                                | `04tVx000000a037IAA` |
| v2.5.0  | Previous                                | `04tVx000000ZyyzIAC` |
| v2.4.0  | Previous                                | `04tVx000000ZyanIAC` |
| v2.3.0  | Previous                                | `04tVx000000ZxDJIA0` |
| v2.2.0  | Previous                                | `04tVx000000ZxBhIAK` |
| v2.1.0  | Previous                                | `04tVx000000Zw5xIAC` |
| v2.0.0  | Previous                                | `04tVx000000ZqBpIAK` |
| v1.99.0 | Previous                                | `04tVx000000ZVFRIA4` |
| v1.98.0 | Previous                                | `04tVx000000Si9NIAS` |
| v1.97.0 | Previous                                | `04tVx000000SFovIAG` |
| v1.96.0 | Previous                                | `04tVx000000SFH3IAO` |
| v1.95.0 | Previous                                | `04tVx000000SFDpIAO` |
| v1.94.0 | Previous                                | `04tVx000000SExhIAG` |
| v1.93.0 | Previous                                | `04tVx000000SDOvIAO` |
| v1.92.0 | Previous                                | `04tVx000000S9I5IAK` |
| v1.91.0 | Previous                                | `04tVx000000RvbhIAC` |
| v1.90.0 | Previous                                | `04tVx000000R8cbIAC` |
| v1.89.0 | Previous                                | `04tVx000000Qu1lIAC` |
| v1.88.0 | Previous                                | `04tVx000000Qu09IAC` |
| v1.87.0 | Previous                                | `04tVx000000QtqTIAS` |
| v1.86.0 | Previous                                | `04tVx000000QtorIAC` |
| v1.85.0 | Previous                                | `04tVx000000QlePIAS` |
| v1.84.0 | Previous                                | `04tVx000000QL2PIAW` |
| v1.83.0 | Previous                                | `04tVx000000QKRJIA4` |
| v1.82.0 | Previous                                | `04tal000006rKBdAAM` |
| v1.81.0 | Previous                                | `04tal000006rKA1AAM` |
| v1.80.0 | Previous                                | `04tal000006rJkDAAU` |
| v1.79.0 | Previous                                | `04tal000006rD8XAAU` |
| v1.77.0 | Previous                                | `04tal000006rCxFAAU` |
| v1.76.0 | Previous                                | `04tal000006rCu1AAE` |
| v1.75.0 | Previous                                | `04tal000006rCZ3AAM` |
| v1.74.0 | Previous                                | `04tal000006rBTJAA2` |
| v1.73.0 | Previous                                | `04tal000006rAYrAAM` |
| v1.72.0 | Previous                                | `04tal000006r0xiAAA` |
| v1.71.0 | Previous                                | `04tal000006r0jBAAQ` |
| v1.70.0 | Previous                                | `04tal000006qyhNAAQ` |
| v1.69.0 | Previous                                | `04tal000006qyB7AAI` |
| v1.68.0 | Previous                                | `04tal000006qt1lAAA` |
| v1.67.0 | Previous                                | `04tal000006qqOrAAI` |
| v1.66.0 | Previous                                | `04tal000006qiUXAAY` |
| v1.65.0 | Previous                                | `04tal000006qiG1AAI` |
| v1.64.0 | Previous                                | `04tal000006qhYTAAY` |
| v1.63.0 | Previous                                | `04tal000006qZmEAAU` |
| v1.62.0 | Previous                                | `04tal000006q929AAA` |
| v1.61.0 | Previous                                | `04tal000006pzu1AAA` |
| v1.60.0 | Previous                                | `04tal000006lrGjAAI` |
| v1.59.0 | Previous                                | `04tal000006lrDVAAY` |
| v1.58.0 | Previous                                | `04tal000006lpoPAAQ` |
| v1.57.0 | Superseded (install validator rejected) | `04tal000006lplBAAQ` |
| v1.56.0 | Previous                                | `04tal000006i1rNAAQ` |
| v1.55.0 | Previous                                | `04tal000006i0thAAA` |
| v1.54.0 | Previous                                | `04tal000006i0qTAAQ` |
| v1.53.0 | Previous                                | `04tal000006hyYXAAY` |
| v1.52.0 | Previous                                | `04tal000006hyVJAAY` |
| v1.51.0 | Previous                                | `04tal000006hyThAAI` |
| v1.50.0 | Previous                                | `04tal000006hyNFAAY` |
| v1.49.0 | Previous                                | `04tal000006hlZhAAI` |
| v1.48.0 | Previous                                | `04tal000006hhhNAAQ` |
| v1.47.0 | Previous                                | `04tal000006hQwfAAE` |
| v1.46.0 | Previous                                | `04tal000006hQ73AAE` |
| v1.45.0 | Previous (tester rollout)               | `04tal000006hOZtAAM` |
| v1.43.0 | Previous                                | `04tal000006hLTxAAM` |
| v1.42.0 | Previous                                | `04tal000006UkpxAAC` |
| v1.41.0 | Previous                                | `04tal000006UiubAAC` |

See [CHANGELOG.md](CHANGELOG.md) for full release notes.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE).

---

Built by [Portwood Global Solutions](https://portwood.dev)

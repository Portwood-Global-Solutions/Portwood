# Merge tag reference

This advanced reference accompanies the [task-based knowledgebase](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md). Retained from the existing guide and reviewed against the 3.60.0 source. Use the task articles for current installation and user workflows.

Every tag Portwood recognizes. Tags are case-insensitive for functions (`{SUM:...}` == `{sum:...}` in processXml; the giant-query assembler's aggregate regex is case-sensitive — use uppercase to be safe).

### 7.1 Field merge

```
{FieldName}
{!FieldName}              Salesforce-style prefix — treated identically to {FieldName}
{Account.Name}            Parent lookup
{Owner.Profile.Name}      Multi-level lookup (any depth)
```

Null/missing fields render as empty string — no error, no placeholder.

Tag names are case-sensitive, and there's **no escape or comment syntax** — any `{…}` pair is treated as a tag (an unknown name resolves to empty string, so `{like this}` silently disappears), and an unclosed `{` fails the merge with a "Malformed merge tag" error. If a document needs literal braces: in HTML templates use the entities `&#123;` and `&#125;`; in Word templates avoid brace-wrapped prose.

### 7.2 Format specifiers

Append `:format` to a field tag.

#### Date formatting

```
{CloseDate:MM/dd/yyyy}          Java SimpleDateFormat pattern
{CloseDate:MMMM d, yyyy}        April 17, 2026
{CloseDate:date}                User's locale default
{CloseDate:date:de_DE}          17.04.2026 (German)
{CloseDate:date:ja_JP}          2026/04/17 (Japanese)
{CloseDate:date:en_GB}          17/04/2026 (British)
```

Locale defaults: `en_US` → `MM/dd/yyyy`; `en_GB/AU/NZ/IE/IN` → `dd/MM/yyyy`; `de_*`, `ru_*`, `pl_*`, `cs_*`, `hu_*`, `tr_*` → `dd.MM.yyyy`; `fr_*`, `es_*`, `it_*`, `pt_*` → `dd/MM/yyyy`; `nl_*` → `dd-MM-yyyy`; `ja_*` → `yyyy/MM/dd`; `zh_*` and Nordic → `yyyy-MM-dd`; `ko_*` → `yyyy. MM. dd`.

#### Currency formatting

```
{Amount:currency}               $500,000.00 (US default)
{Amount:currency:EUR}           €500,000.00
{Amount:currency:EUR:de_DE}     500.000,00 € (German formatting)
{Amount:currency:JPY}           ¥500000 (no decimals)
{Amount:currency:GBP}           £500,000.00
```

Supported currencies: USD, EUR, GBP, JPY, CNY, CHF, CAD, AUD, INR, KRW, BRL, MXN, SEK, NOK, DKK, PLN, CZK, HUF, TRY, ZAR, SGD, HKD, NZD, THB, MYR, PHP, IDR, TWD, ILS, RUB, NGN, KES, AED, SAR, COP, CLP, PEN, ARS, EGP, GHS, ISK, VND.

Zero-decimal currencies (JPY, KRW, CLP, VND, HUF, ISK, TWD) format without decimals automatically.

##### Auto-detecting the currency from the record

Use `:currency:auto` when the symbol should follow the **record's own currency** rather than a fixed ISO code — ideal for multi-currency orgs.

```
{Amount:currency:auto}                       Reads the standard CurrencyIsoCode field
{Amount:currency:auto=CustomerCurrency__c}   Reads a named currency field (e.g. an ERP field)
{Amount:currency:auto:en_GB}                 auto + an explicit locale for separators/placement
{Amount:currency:auto=CustomerCurrency__c:de_DE}
```

How it works and what to know:

- **The source field must hold an ISO 4217 code** (`GBP`, `USD`, `EUR`, …) — its value is matched against the supported-currency list above.
- **List the source field in your template's Query Config.** Portwood builds its query from the Query Config (it does not scan the template body), so a field referenced only inside `:currency:auto=...` must be added to the Query Config like any other merge field. The standard `CurrencyIsoCode` is added automatically in multi-currency orgs, so bare `:currency:auto` works without listing it.
- **Safe fallback:** if the source field is missing, blank, or not a recognized ISO code, the tag falls back to the default `$` format — it never errors or prints a raw code.
- **Bare `:currency` is unchanged** — it always emits `$`. Auto-detection is strictly opt-in via `:auto`.
- **Aggregates** support it too: `{SUM:Lines.Amount:currency:auto=CustomerCurrency__c}` uses the **parent** record's currency for the symbol.

##### Totalling across currencies

In a multi-currency org, the rows behind an aggregate can each carry their own currency. Adding them together and stamping one symbol on the result produces a number that looks authoritative and is meaningless — so Portwood won't do it silently.

```
{SUM:Lines.Amount:currency:EUR}            Mixed-currency rows → generation fails with a clear error
{SUM:Lines.Amount:currency:EUR:convert}    Every row converted to EUR first, then summed
{SUM:Lines.Amount:currency:auto:convert}   Converts into the parent record's own currency
{SUM:Lines.Amount:currency:EUR:de_DE:convert}   convert always goes last, after any locale
```

What to know:

- **The guard only fires when there's a real conflict** — two or more different currency codes among the rows being aggregated. One currency, or rows with no currency code at all, behave exactly as they always have.
- **Append `:convert` to any aggregate** (`SUM`, `AVG`, `MIN`, `MAX`) to convert first. `MIN`/`MAX` compare converted amounts, so the smallest _number_ isn't mistaken for the smallest _amount_.
- **Rates come from Setup → Manage Currencies** (`CurrencyType`), pivoting through your corporate currency. If a rate is missing, the tag fails with an actionable message rather than quietly returning an unconverted number.
- **Advanced Currency Management dated rates are not used** — conversion applies your current static rate. See issue #273.
- **Single-currency orgs are entirely unaffected.** None of this engages.
- **Without `:convert`, nothing converts.** `{SUM:Lines.Amount:currency:EUR}` over EUR-only rows formats them as euros; it does not translate other currencies into euros.
- **Beyond aggregates: `:convert` works on a plain currency field too (v3.57+).** `{Amount:currency:EUR:convert}` converts the record's own amount from its `CurrencyIsoCode` into the target ISO before formatting, and composes with locale (`:EUR:de_DE:convert`) and `auto`. A record with no source currency passes through unconverted; a missing rate raises the same "add it under Manage Currencies" error as above.

#### Number formatting

```
{Quantity:number}               1,234 (US separators)
{Quantity:number:de_DE}         1.234 (German — dot-as-thousands)
{Quantity:number:fr_FR}         1 234 (French — space-as-thousands)
{Quantity:#,##0}                Custom pattern — always US separators
{Quantity:#,##0.00}             1,234.56
{Quantity:0,000}                Custom pattern with leading zeros
```

#### Percent formatting

```
{Rate:percent}                  15.5%
{Rate:percent:de_DE}            15,5 %
```

#### Checkbox formatting

```
{IsActive:checkbox}             [X] when true, [ ] when false
```

Uses ASCII box-drawing characters — works in any font.

#### Picklist label formatting

```
{Status__c}                     Stored API value
{Status__c:label}               User-facing picklist label
```

Use `:label` when a picklist stores integration-friendly API codes but the document should show the label users see in Salesforce.

### 7.3 Loops

Repeat a block for each child record.

```
{#Contacts}
  {FirstName} {LastName} — {Email}
{/Contacts}
```

**Container auto-expansion.** If the loop tags sit inside a table row or a bulleted/numbered list paragraph, Portwood detects it and repeats the **entire row/paragraph** instead of just the inner content. This is how invoice line-item tables work — drop `{#OpportunityLineItems}` and `{/OpportunityLineItems}` anywhere inside the row and every line item gets its own row automatically.

**Repeating the column header (`{RepeatHeader}`).** Add the text `{RepeatHeader}` anywhere inside the header row (the row with your column labels) to mark it as a repeating header. Portwood strips the marker and groups that row as the table's `<thead>`, which reprints at the top of the table and at each section break in very large (giant-query) documents. Place it once, in the header row only:

```
| {RepeatHeader}Short Code | Cost to send | Cost to receive |
| {#ShortCodes} {Code} | {Send} | {Receive} {/ShortCodes} |
```

This works in **Word (`.docx`) templates**; **HTML templates** use a native `<thead>…</thead>`. _(For large datasets that use the giant-query path, re-save the template once after adding `{RepeatHeader}` so the change is captured.)_

> **Note on per-page repetition.** The PDF engine (Flying Saucer) does not reliably reprint a header on _every_ page of a large bordered table — so on multi-page tables the header repeats per section, not strictly per page. (Portwood previously attempted true per-page repeat via the engine's `-fs-table-paginate`, but that caused severe mis-pagination on real templates with running headers/footers and was removed.)

Nested loops are supported:

```
{#Opportunities}
  Opp: {Name}
  {#OpportunityLineItems}
    · {Product2.Name} × {Quantity}
  {/OpportunityLineItems}
{/Opportunities}
```

Empty loops (null or empty child list) render nothing — no error.

**Numbering the rows — `{RowNumber}`.** Inside any loop, `{RowNumber}` is the row's position, starting at **1**:

```
| # | Product | Qty |
| {#OpportunityLineItems}{RowNumber} | {Product2.Name} | {Quantity}{/OpportunityLineItems} |
```

- **Counts rendered rows**, so it reflects whatever the Query Config's `WHERE`/`ORDER BY`/`LIMIT` actually returned — not the record's position in the database.
- **Nested loops each count their own rows.** An inner `{RowNumber}` restarts at 1 for every parent row, and the outer number is intact again after the inner loop closes.
- **Counts continuously through very large tables.** A 30,000-row giant-query table numbers 1…30,000 straight through, not per page or per batch.
- **Restarts per group** inside a `{#GroupBy}` block — each group's table numbers from 1.
- Verified in Word and HTML templates across single, bulk and giant-query generation. PowerPoint and Excel loops run through the same engine and should behave identically, but that combination hasn't been exercised end-to-end.
- Outside a loop it isn't a tag and resolves to nothing.
- If a record happens to have a field literally named `RowNumber`, the counter wins inside the loop body.

**Group into a table (or block) per value — `{#GroupBy}` (v3.42+).** When you want one table per _type_ / _category_ / _status_ — and you don't want to hand-write a separate loop for every value — group a child relationship by a field and repeat the block once per distinct value:

```
{#GroupBy OpportunityLineItems by Product2.Family}
  <h3>{GroupName}</h3>
  <table>
    {#OpportunityLineItems}
      <tr><td>{Product2.Name}</td><td>{TotalPrice:currency}</td></tr>
    {/OpportunityLineItems}
    <tr><td>Subtotal</td><td>{SUM:OpportunityLineItems.TotalPrice:currency}</td></tr>
  </table>
{/GroupBy}
```

- `{#GroupBy <Relationship> by <Field>}` repeats its whole block once per **distinct value** of `<Field>` among the relationship's records. 50 distinct values → 50 tables, automatically — no need to know the values in advance.
- Groups render in **first-seen order**, so add `ORDER BY <Field>` to that relationship in the Query Config to control (e.g. alphabetize) group order.
- `<Field>` may be a **dot-path** on the child (e.g. `Product2.Family`, `Owner.Name`).
- Inside the block: **`{GroupName}`** is the group's value (use it as the header); the inner **`{#<Relationship>}…{/<Relationship>}`** loops only that group's members; and **`{SUM|COUNT|AVG|MIN|MAX:<Relationship>.Field}`** aggregate just that group.
- Works identically in Word and HTML templates. An empty/absent relationship renders nothing.

**Reaching parent-level data from inside a loop — `{~Label}`.** A tag inside a loop normally only sees the current row's own data — a merge tag or `{#ChartBucket}` that depends on a **different**, sibling relationship on the parent record resolves to nothing. Wrap that content in `{~Label}…{/Label}` to resolve it against the top-level record instead, no matter how deeply nested the tag itself is:

```
{#Contacts}
  {LastName}:
  {~Pipeline}{#ChartBucket:Opportunities:StageName}{key_label} {percent}%{/ChartBucket}{/Pipeline}
{/Contacts}
```

- `Label` is a free-form match key, not a relationship name — it only pairs the tag with its closing `{/Label}`. Pick one that's unique across the whole template; a `{~Offices}` and an unrelated `{#Offices}` sharing the same label text can miscount each other's nesting depth.
- Works at any nesting depth, including inside another `{~Label}` block.
- Composes with `{#ChartBucket}` — a chart wrapped in `{~Label}` resolves against the parent record even when the whole block sits inside an unrelated loop.
- **Not supported inside a giant-query loop** (a relationship over the 2,000-row threshold) — using it there fails generation immediately with a clear error instead of silently rendering blank.

### 7.4 Conditionals

#### Boolean conditional

```
{#IsActive}
  Account is active.
{/IsActive}

{#IsActive}
  Active.
{:else}
  Inactive.
{/IsActive}
```

Truthy values: Boolean `true`, non-empty lists, any non-null non-false non-empty-string value.

#### Inverse conditional

Show when falsy. Opposite of `{#Field}`.

```
{^Closed__c}
  Still open.
{/Closed__c}

{^IsActive}
  Inactive.
{:else}
  Active.
{/IsActive}
```

#### IF comparison expressions

Supports `>`, `<`, `>=`, `<=`, `=` (or `==`), `!=`. Values can be field refs, quoted strings, or numbers.

```
{#IF Amount > 100000}
  Large deal — requires approval.
{/IF}

{#IF StageName = 'Closed Won'}
  Congratulations!
{:else}
  Keep pushing.
{/IF}

{#IF Priority != 'Low'}
  Escalate this case.
{/IF}
```

String comparisons are case-sensitive.

#### AND / OR / NOT

Combine comparisons with boolean operators. Both word-form (`AND`, `OR`, `NOT` — case-insensitive) and symbolic form (`&&`, `||`, `!`) work. Parentheses control precedence.

```
{#IF Amount > 100000 AND Stage = 'Negotiation/Review'}
  Large deal in negotiation — escalate.
{/IF}

{#IF Stage = 'Closed Won' OR Stage = 'Closed - Pending Funding'}
  Pipeline closed.
{/IF}

{#IF NOT IsPrivate__c}
  Public record.
{/IF}
```

Default precedence (highest first): `NOT` → comparisons → `AND` → `OR`. Use parens to override:

```
{#IF (Amount > 100000 OR Strategic__c) AND IsClosed = false}
  Large or strategic, still open.
{/IF}
```

Arbitrarily long chains and grouping work:

```
{#IF (Region = 'NA') OR (Region = 'EU' AND Tier__c = 'Gold') OR (Strategic__c)}
  Eligible for premium support.
{/IF}
```

Quoted strings are opaque — `AND` / `OR` inside quotes is treated as part of the string, not as an operator.

#### Live example — Project Status Showcase

Repository ships a complete worked example exercising every IF feature. Three files:

- `dev-only-deploy/main/default/classes/ProjectStatusDemoProvider.cls` — a V4 Apex Data Provider that returns synthetic project data (no SOQL — works without test data setup).
- `scripts/template-project-status.html` — the full HTML template body. Demonstrates nested IF, AND/OR/NOT, parens, comparison, bare-boolean IF, empty-rel `totalSize=0`, inverse loops with `{:else}`.
- `scripts/demo-project-status-template.apex` — anonymous Apex script that creates the Portwood template, links the provider, and renders one PDF attached to a record.

To run it:

```bash
# 1. Deploy the provider class
sf project deploy start --source-dir dev-only-deploy/main/default/classes/ProjectStatusDemoProvider.cls --target-org <your-org>

# 2. Create the template + render a sample PDF
sf apex run --target-org <your-org> -f scripts/demo-project-status-template.apex
```

The script logs a Salesforce URL where the rendered PDF is attached. Open it to see all the IF features rendering against real data — including the empty-rel sections that correctly suppress.

#### Nested IF blocks

`{#IF}…{/IF}` blocks can be nested arbitrarily deep. Common pattern: an outer IF gates a whole section, inner IFs gate sub-sections within it.

```
{#IF Work_Tasks__r.totalSize != 0}
  WORK TASKS
  …table with Work Tasks loop…
  {#IF Work_Task_Step_Count__c != 0}
    …Steps table with Steps loop…
  {/IF}
{/IF}
```

`Rel.totalSize` returns 0 (not null) when the child relationship is empty, so `{#IF Rel.totalSize != 0}` is the canonical "render this section if there are rows" check.

### 7.5 Aggregates

Grand totals across a child relationship. Works in sync and giant-query paths.

```
{COUNT:OpportunityLineItems}                          1000
{COUNT:OpportunityLineItems:number}                   1,000
{SUM:OpportunityLineItems.TotalPrice}                 50000
{SUM:OpportunityLineItems.TotalPrice:currency}        $50,000.00
{SUM:Lines.Amount:currency:EUR:de_DE}                 50.000,00 €
{AVG:OrderItems.UnitPrice:currency}                   $127.50
{MIN:Quotes.Amount:currency}                          $100.00
{MAX:Deals.Amount:currency:GBP}                       £999,999.00
{SUM:Lines.Amount:currency:auto=CustomerCurrency__c}  uses the parent record's currency
```

All five functions support any format suffix (`currency`, `number`, `percent`, custom patterns), including `currency:auto` (see [Auto-detecting the currency from the record](#auto-detecting-the-currency-from-the-record)).

**Aggregate fields don't need to be rendered columns** — you can aggregate `UnitPrice` even if your loop table only shows `Product2.Name` and `Quantity`. The resolver validates field names against the child object's schema.

### 7.6 Charts

Render **nine chart styles** inline in your generated documents — bar, column, pie, donut, pivot, stacked, clustered, line, and area. Charts use a prepared PNG image on supported paths, with browser rendering for interactive work and an Apex rasterizer for server work. HTML can also use CSS chart blocks or opt-in browser-only SVG. Excel output does not embed chart-tag images. Test the exact entry point you intend to use:

| Output             | How charts get there                                                  |
| ------------------ | --------------------------------------------------------------------- |
| HTML → browser     | `<img src="/sfc/servlet.shepherd/version/download/CV_ID">`            |
| HTML → PDF         | Same `<img>` — Flying Saucer (`Blob.toPdf`) fetches it server-side    |
| Word `.docx`       | `<w:drawing>` referencing a PNG embedded in `word/media/`             |
| Word → PDF         | Word → HTML → PDF chain; the embedded PNG flows through transparently |
| PowerPoint `.pptx` | `<p:pic>` referencing a PNG in `ppt/media/`                           |
| Excel `.xlsx`      | (Coming in a follow-up release)                                       |

**Zero external callouts.** The chart engine is 100% native Apex — same constraint that makes Portwood suitable for AppExchange security review and managed-package customers. Charts work in Flow actions, batch jobs, Queueables, and Apex tests as well as the runner LWC.

**Two authoring paths:**

1. **`{Chart:relationship:field:style:opts}`** — one-line tag. The engine resolves bucket data via SOQL aggregate (constant cost regardless of row count), rasterizes to PNG, embeds the image. Works on supported Word, HTML/PDF, Canvas, and PowerPoint paths; Excel image embedding is not supported. **This is the canonical path — use it for 95% of cases.**
2. **`{#ChartBucket:relationship:field}…{/ChartBucket}`** — hand-authored loop. You write the chart HTML body yourself with `{key}` / `{count}` / `{percent}` placeholders. Use only when you need a custom layout the engine doesn't ship (e.g., embedded sparklines inside a table cell).

#### 7.6.0 One-line `{Chart:...}` blocks

A single tag that expands into a complete chart image at render time. **Tag syntax:**

```
{Chart:RELATIONSHIP:FIELD:STYLE:OPTS}
```

| Position       | Required | Meaning                                                |
| -------------- | -------- | ------------------------------------------------------ |
| `RELATIONSHIP` | yes      | Child relationship name on the parent record (one-hop) |
| `FIELD`        | yes      | Field on the child to group by                         |
| `STYLE`        | no       | One of nine styles (default: `bar`)                    |
| `OPTS`         | no       | `key=value&key=value` modifiers                        |

**All nine styles:**

| Style       | Visual                                                                       | Cross-tab? | Best for                                                 |
| ----------- | ---------------------------------------------------------------------------- | ---------- | -------------------------------------------------------- |
| `bar`       | Horizontal bar per bucket, label left, count+% right                         | no         | One question, one dimension. Long category labels.       |
| `column`    | Vertical bar per bucket, labels under, % above                               | no         | One question, one dimension. Short labels.               |
| `pie`       | Pie chart with right-side legend showing count + %                           | no         | "Share of total" framing, ≤8 slices                      |
| `donut`     | Pie with a center hole, same legend                                          | no         | Same as pie, lighter visual weight                       |
| `pivot`     | Cross-tab table — rows = buckets, cols = `groupBy` values + Total            | required   | Numeric matrix readout. CSS-bar path (HTML-friendly).    |
| `stacked`   | Horizontal stacked bar — one row per bucket, segments by `groupBy`           | required   | "How does each row break down across the 2nd dimension?" |
| `clustered` | Vertical clustered bars — one cluster per bucket, mini-bar per col           | required   | Side-by-side comparison across the 2nd dimension         |
| `line`      | Polyline through (bucket index, count). Multi-series when `groupBy` present. | optional   | Trend / ordering matters. Single or multi-series.        |
| `area`      | Line chart with semi-transparent fill below each series                      | optional   | Trend + accumulated volume                               |

**Worked examples** (against the canonical Commute Survey Demo — 425 responses, 6 modes, 2 locations):

```
{Chart:Survey_Responses__r:Selected_Answer__c:bar:title=Commute Mode Distribution}
{Chart:Survey_Responses__r:Selected_Answer__c:column:title=Commute Mode (Vertical)}
{Chart:Survey_Responses__r:Selected_Answer__c:pie:title=Commute Mode Share}
{Chart:Survey_Responses__r:Selected_Answer__c:donut:title=Commute Mode Share (Donut)}
{Chart:Survey_Responses__r:Selected_Answer__c:stacked:groupBy=Location__c&colSort=8000 Marina,3260 Bayshore&title=Location Mix per Mode}
{Chart:Survey_Responses__r:Selected_Answer__c:clustered:groupBy=Location__c&colSort=8000 Marina,3260 Bayshore&title=Mode by Location Comparison}
{Chart:Survey_Responses__r:Selected_Answer__c:line:groupBy=Location__c&colSort=8000 Marina,3260 Bayshore&title=Commute Trend by Location}
{Chart:Survey_Responses__r:Selected_Answer__c:area:groupBy=Location__c&colSort=8000 Marina,3260 Bayshore&title=Commute Volume by Location}
{Chart:Survey_Responses__r:Selected_Answer__c:pivot:groupBy=Location__c&colSort=8000 Marina,3260 Bayshore&title=Mode by Location (Table)}
```

#### 7.6.1 Complete modifier reference

Modifiers come after the style, joined with `&`. **Order doesn't matter.** Values containing `&` or `=` are not supported (use `where=` for SOQL with operators — see below).

| Modifier      | Applies to                        | Example                                                  | What it does                                                                                                                                                                                                                                                                                                           |
| ------------- | --------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `title=`      | all styles                        | `title=How satisfied are you with your role?`            | Chart header text drawn above the chart. Becomes the `<img alt="…">` attribute on the HTML side.                                                                                                                                                                                                                       |
| `width=`      | all styles                        | `width=420`                                              | Logical-pixel width of the chart. Defaults: 540 (stacked/clustered), 500 (bar/column/line/area), 360 (pie/donut). Word/PDF downsample bigger PNGs for free AA.                                                                                                                                                         |
| `height=`     | all styles                        | `height=240`                                             | Logical-pixel height. Defaults vary per style (see source); bar auto-grows by bucket count.                                                                                                                                                                                                                            |
| `fontSize=`   | all styles                        | `fontSize=16`                                            | Axis-label size in pixels. Default 12; titles and other text scale with it, keeping their proportions. Raise it when the chart lands in a small frame. On a Canvas chart use the **Label size** box rather than writing the tag. Honoured by all three renderers — browser, Word/PowerPoint, and HTML-to-PDF. (v3.56+) |
| `where=`      | all styles                        | `where=Survey_Question__r.Display_Order__c=1`            | SOQL fragment appended to the chart's `WHERE`. Identifier-only, sanitized through the same keyword blocklist as Query Builder. Forces server-side aggregation.                                                                                                                                                         |
| `groupBy=`    | stacked/clustered/pivot/line/area | `groupBy=Department__c`                                  | Cross-tab dimension. **Required** for `stacked`/`clustered`/`pivot`; **optional** for `line`/`area` (omit → single-series). Field on the same child object as `FIELD`.                                                                                                                                                 |
| `colSort=`    | stacked/clustered/pivot/line/area | `colSort=Engineering,Sales,Marketing,Support,Operations` | Author-controlled column ordering. Named values appear first in this order; remaining values alpha-sorted; synthetic `Total` always last (pivot path only).                                                                                                                                                            |
| `colors=`     | all styles                        | `colors=#1e40af,#b91c1c,#16a34a`                         | Override the default 8-color palette. Cycles by row/series index. Each color is `#hex` (6 chars).                                                                                                                                                                                                                      |
| `split=`      | all (bucket-shape only)           | `split=;`                                                | Multi-select delimiter. Each respondent's pick contributes to every value they selected. Percentages sum to >100% by design.                                                                                                                                                                                           |
| `scale=`      | all (raster path only)            | `scale=2`                                                | Supersample multiplier. Default 1 for stacked/clustered/line/area, 2 for bar/column/pie/donut. Larger = sharper PNG but slower; 4 is the practical ceiling.                                                                                                                                                            |
| `htmlRender=` | HTML browser preview              | `htmlRender=svg`                                         | (HTML only, opt-in.) Inline `<svg>` instead of `<img>`. **Browser-only — Flying Saucer drops SVG**. Prepared PNG images work in browser and PDF; without image preparation, supported CSS chart styles are the fallback.                                                                                               |

**Composability:** every modifier composes with every other modifier where it makes sense:

```
{Chart:Survey_Responses__r:Mode__c:stacked:groupBy=Location__c&colSort=Marina,Bayshore&colors=#1e40af,#b91c1c&where=CreatedDate=THIS_YEAR&title=Modes by Office, 2026}
```

**Inside a relationship loop**, the chart's relationship resolves against the iterating record:

```html
{#Survey_Questions__r}
<h2>Q{Display_Order__c}: {Question_Text__c}</h2>
{Chart:Survey_Responses__r:Selected_Answer__c:bar} {/Survey_Questions__r}
```

Here `Survey_Question__c.Survey_Responses__r` is the child relationship from Question (not from the outer Survey). One chart per question, no `where=` needed.

> **If chart labels come out too small, raise `fontSize=`.** Label sizes are in canvas
> pixels, so how big they look in the finished document depends on how far the image is
> scaled to fit its frame.
>
> On a **Canvas** template that is straightforward: the chart block renders at its own
> size, so the 12px default prints at about 9pt whatever size the block is. Set **Label
> size** in the chart properties to change it.
>
> On a **PowerPoint or Word** template the image is stretched to fit the shape you drew,
> and `width=` does not change that — a chart squeezed into a 3-inch shape has small
> labels however many pixels it was rendered at. Raising `width=` sharpens the picture
> while making the text smaller relative to the frame, which is the opposite of what
> most people expect. `fontSize=` is the knob: adjust it until it reads well at the size
> the shape actually is.

**Error handling.** Malformed tags render an inline error block in HTML output (red border, monospace tag dump) and a `[Chart error: …]` text placeholder in Word — you see the problem at first preview rather than chasing a silent miss. Errors include the original tag verbatim so you can diff it against a working sample.

#### 7.6.2 Output-format matrix — what flows where

The chart engine can emit prepared PNGs, HTML CSS chart blocks, or opt-in browser-only inline SVG. The result depends on the calling path and whether chart images were prepared. The runner LWC, Flow actions, batch jobs, and the Apex `generate*` entry points all orchestrate chart preparation automatically — **you do not call `prepareChartImages` in your template; just write the tags.**

| Template Type | Output           | Image format                                  | Engine path                                                                                   |
| ------------- | ---------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------- |
| HTML          | HTML download    | `<img>` referencing CV URL                    | Browser fetches the CV via lightning subdomain                                                |
| HTML          | PDF              | `<img>` referencing CV URL                    | Flying Saucer's `Blob.toPdf` fetches the CV server-side (relative URL — managed-package safe) |
| HTML          | Browser preview  | `<img>` (default) OR inline `<svg>` (opt-in)  | Lightning UI / Experience Cloud render natively                                               |
| Word          | DOCX             | PNG embedded in `word/media/`                 | LWC orchestrates: SVG → canvas → PNG → CV → client-side ZIP assembly fetches CV bytes         |
| Word          | PDF              | PNG embedded in `word/media/`, then converted | Same DOCX assembly, then DocGenHtmlRenderer → `Blob.toPdf`                                    |
| Word          | Sample PDF       | PNG embedded                                  | Same path                                                                                     |
| PowerPoint    | PPTX             | PNG in `ppt/media/` via `<p:pic>`             | Server-side OOXML embed, or client-side Chart.js on the giant-query path (below)              |
| Excel         | XLSX             | Chart-tag image embedding is not supported    | Use a supported Word/PDF or PowerPoint output when chart images are required                  |
| Canvas        | PDF              | `<img>` referencing CV URL                    | Chart block previews live via Chart.js; the tag renders like any other HTML chart             |
| Flow / batch  | any of the above | PNG via pure-Apex rasterizer                  | `DocGenChartImageController.prepareChartImagesServerSide` — no browser canvas, no callouts    |

#### 7.6.2.1 Charts on large datasets — client-side rendering (v3.55+)

The pure-Apex rasterizer runs inside a synchronous transaction, and both the chart data and
the rendered PNGs have to fit in a 6 MB Apex heap. On a record with thousands of child rows
that is not a limit you can tune around — a PowerPoint or Excel template over a few thousand
child records used to fail outright with _"too large for sync PowerPoint/Excel output"_.

For PowerPoint and Excel, Portwood now takes the same route it has always taken for Word:
**the browser does the work.** The runner pages the child records down in chunks, aggregates
each page into buckets as it arrives, and renders the finished chart with **Chart.js** on a
real `<canvas>` before embedding the PNG. Nothing large is ever held in Apex at once, so the
heap ceiling stops being the constraint — verified against 30,000 child records.

You do not opt in and you do not change your tags. Write `{Chart:...}` exactly as documented
above; the runner picks the path. What you should know:

- **It needs a browser.** Flow, batch and Apex entry points still use the server-side
  rasterizer, which is why the heap guidance in [§14.8](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#148-template--output-size-guidance)
  still applies to unattended generation.
- **Non-groupable fields are refused with a message.** A Long Text Area cannot be used in a
  SOQL `GROUP BY`, and attempting it throws an uncatchable platform exception — so Portwood
  checks the field first and tells you, rather than letting the transaction die. Group by a
  Text, Picklist, Number, Date or Checkbox field instead.
- **Charts still render on the Canvas artboard** while you design, using the same library.

**Cleanup.** Each generated chart produces a transient `docgen_chart_*` ContentVersion. The runner cleans them up after the document downloads/saves. A daily orphan reaper (`DocGenChartCleanupSchedulable`) sweeps stragglers (failures or browser-closed-mid-flow).

#### 7.6.3 LLM authoring prompt — copy this to generate a template

Paste the block below into Claude / GPT / Gemini with one substitution: `${MY_DATA_DESCRIPTION}` should describe your child relationship name, the dimension field you want bucketed, and (optionally) the cross-tab field plus its expected values. The LLM will produce a complete HTML template you can upload.

```text
You are writing a Portwood HTML template that renders 8 chart styles using Portwood's
{Chart:...} tag syntax. Portwood is a native Salesforce 2GP package; the template is a single
HTML file uploaded as a ContentVersion against a DocGen_Template__c with Type__c='HTML'.

Hard constraints (Flying Saucer PDF engine, CSS 2.1 + small CSS 3 subset):
- Use <table>/<tr>/<td> for layout OR <div> with display:table/table-row/table-cell.
- Do NOT use: flex, grid, gap, linear-gradient, calc(), CSS variables. Silently ignored.
- Do NOT use <svg> for charts — Flying Saucer drops it. {Chart:...} emits <img> by default.
- Wrap @page in a <style> at the top. Do not also set Page_Size__c / Page_Orientation__c /
  Custom_Margins__c on the template if the source HTML declares @page.

Chart tag syntax: {Chart:RELATIONSHIP:FIELD:STYLE:OPTS}
  - RELATIONSHIP: child relationship name on the parent record (e.g. Survey_Responses__r)
  - FIELD: field on the child to bucket by (e.g. Selected_Answer__c)
  - STYLE: bar, column, pie, donut, pivot, stacked, clustered, line, area
  - OPTS: key=value&key=value (any order). All optional unless noted.

Available modifiers:
  - title=...                — chart header text, becomes img alt text
  - width=N  height=N        — logical pixels (defaults: 500x ~by-style)
  - where=SOQL_FRAGMENT      — appended to chart's WHERE. Identifier-only.
  - groupBy=FIELD            — cross-tab dimension. REQUIRED for stacked/clustered/pivot;
                               optional for line/area (omit → single-series).
  - colSort=val1,val2,...    — author-controlled column order. Required when groupBy is used.
  - colors=#hex,#hex,...     — palette override, cycles by row/series index
  - split=DELIM              — multi-select picklist delimiter (sums to >100% by design)
  - scale=N                  — PNG supersample (default 1-2). 4 max.

Required output:
1. A single self-contained HTML file (<!DOCTYPE html>...</html>) with inline <style>.
2. A title row with {Name} of the parent record.
3. Eight H2 sections — one per chart style. Each section:
   - H2 heading numbered and named (e.g. "5. Stacked (cross-tab)")
   - A one-line description of when to use this style
   - The {Chart:...} tag itself, wrapped in <div class="chart">
   - <h2 class="page-break"> on sections 2-8 so each chart gets its own page
4. A footer line acknowledging "Portwood Chart Engine — pure-Apex PNG rasterization".

Data shape — ${MY_DATA_DESCRIPTION}
(Example: "Survey__c parent. Child relationship Survey_Responses__r. Bucket by Selected_Answer__c.
Cross-tab dimension Location__c with values 8000 Marina, 3260 Bayshore.")

Use the bucket field for bar/column/pie/donut single-dimension styles. Use the cross-tab field
in groupBy for stacked/clustered/line/area/pivot. ColSort must match the cross-tab values.

Return the complete HTML file, ready to upload as a Portwood HTML template. No commentary.
```

#### 7.6.4 Reference templates

A ready-to-upload showcase ships in `docs/`:

- **`docs/ChartEngineShowcase.html`** — all 8 chart styles against the Commute Survey Demo (Selected_Answer**c bucketed by Location**c). Upload as `Type=HTML`, set `Base_Object_API__c=Survey__c`, set `Query_Config__c=Survey_Questions__r` (omit `Survey_Responses__r` — see §7.6.5 for why).
- **`docs/ChartEngineShowcase.docx`** — same template, Word format. Same chart tags, drops directly into the Word body as plain text.
- **`docs/SurveyChartExample.html`** — per-question single-dimension chart pattern (one chart per question via outer `{#Survey_Questions__r}` loop).
- **`docs/CommuteSurveyExample.html`** — full composition of all five chart modifiers using the `<div>` table-row layout.

The showcase HTML is short enough to read end-to-end. Highly recommended starting point if you're authoring a template from scratch.

#### 7.6.5 Resolution paths — `Query_Config__c` setup

How you configure `Query_Config__c` determines whether your charts work at 30K rows, 300K rows, or fail. The engine picks one of four resolution paths automatically:

1. **In-memory** — the child collection is already loaded into the data map (small relationship, eagerly queried), no `where=` / `groupBy=` used. Aggregation runs in Apex. Fastest path, zero extra SOQL.
2. **SOQL fallback (recommended for >2000 rows)** — the relationship is **NOT** in `Query_Config__c`, OR `where=` / `groupBy=` is present. The engine issues one `GROUP BY` aggregate. **Constant cost regardless of row count.**
3. **Parent-level** — chart sits outside any loop (header/summary). Same in-memory / SOQL behavior as above.
4. **Giant-query parent** — chart targets a relationship in giant-query templates (>2000 rows under the "giant" child). Same modifiers, same shape, server-side aggregation.

**Author's rule of thumb — applies to the chart's target relationship specifically:**

> ✅ **DON'T pre-load the relationship the chart aggregates.** Leave it out of `Query_Config__c` (or omit it from any nested subquery). The chart aggregates it server-side at constant cost.
>
> ✅ **DO pre-load the relationship the chart's parent loop iterates.** If the chart sits inside `{#Survey_Questions__r}`, the **Questions** subquery is still required — but it must NOT include a nested `(SELECT … FROM Survey_Responses__r)` underneath it.
>
> ❌ **DON'T pre-load the chart's target AND also chart against it at >2000 rows** — that triggers the giant-query path looking for a traditional loop body that isn't there.

The engine throws an actionable error pointing you to the fix when this misconfiguration is detected.

**Worked example — Survey with 30K responses, per-question chart inside a Question loop:**

```
Name, (SELECT Id, Question_Text__c, Display_Order__c FROM Survey_Questions__r ORDER BY Display_Order__c ASC)
```

- `Name` loads onto the Survey for the title bar.
- The `Survey_Questions__r` subquery loads each Question's Id, prompt, and order — needed because the template iterates `{#Survey_Questions__r}`.
- **`Id` in the question subquery is required** — the chart's SOQL fallback uses each question's Id as the parent record to scope its `GROUP BY` aggregate.
- **No nested `(SELECT … FROM Survey_Responses__r)`** — that's what keeps responses out of Apex heap and lets the chart's server-side aggregate handle them at constant cost.

The per-question chart tag inside the loop runs against each question's Id automatically. CPU stays under 500ms and SOQL queries stay under 10 regardless of whether the survey has 425 responses or 30,000.

**Subquery syntax note (V1 Query Config):** the V1 flat-string format uses standard SOQL-style subqueries — `(SELECT field1, field2 FROM RelationshipName)`. Bare `RelationshipName(field1,field2)` does NOT parse and silently drops the relationship.

#### 7.6.6 Security — FLS, sharing, and SOQL injection

Charts run with **`AccessLevel.USER_MODE`** — Salesforce enforces object permissions, field-level security, sharing rules, and record-level access at the database layer. A user without read access to the child object or grouped field sees empty buckets (catch with `{:else}`), never a leaked aggregate.

The chart resolver **validates every dynamic identifier** (relationship, child object, group field, lookup field, `groupBy` column) against `Schema.SObjectType.fields.getMap()` and `Schema.SObjectType.fields.ChildRelationship` before interpolation, and **sanitizes `where=` fragments** through the same keyword blocklist that protects Query Builder. SOQL injection is structurally impossible — identifiers are checked, values are bound.

#### 7.6.7 Governor budget

Portwood caps chart aggregates at **50 SOQL queries per transaction** (static budget inside `DocGenChartBucketResolver`). When the budget is exhausted, remaining charts render a single sentinel bucket labeled `"Chart limit reached"` — they never silently render as empty. Re-author the template to consolidate charts (or use a pivot instead of N single-dimension charts) if you hit the ceiling.

Per-chart CPU budget is tracked too — the rasterizer auto-tunes `scale=` defaults so an 8-chart document fits comfortably in the 10-second synchronous Apex limit.

#### 7.6.8 Hand-authored `{#ChartBucket:...}` loops

When you want a custom layout the `{Chart:...}` engine doesn't ship (e.g., a chart inside a Word table cell, or a sparkline next to a text column), drop down to the underlying section tag. The aggregation is identical — same modifiers, same body fields, same SOQL fallback at scale.

**Basic syntax:**

```html
{#ChartBucket:Survey_Responses__r:Selected_Answer__c}
<tr>
    <td>{key_label}</td>
    <td><div style="background:{color};width:{percent}%;height:14px;"></div></td>
    <td>{count} ({percent}%)</td>
</tr>
{/ChartBucket}
```

Buckets sort **descending by count**, alpha by key for ties. Null/blank values collapse into a single bucket labeled `"Not Specified"`.

**Body fields:**

| Tag             | Type    | What it returns                                                                  |
| --------------- | ------- | -------------------------------------------------------------------------------- |
| `{key}`         | String  | Raw group value (HTML-escaped)                                                   |
| `{key_label}`   | String  | Picklist label if available, else `{key}`; `"Not Specified"` for blanks          |
| `{count}`       | Integer | Records in this bucket                                                           |
| `{percent}`     | Decimal | Percent of total, 1 decimal place (use directly as `width:{percent}%`)           |
| `{percent_int}` | Integer | Rounded integer percent                                                          |
| `{max_percent}` | Decimal | Percent normalized so the largest bucket = 100 (for "longest bar = full" charts) |
| `{index}`       | Integer | 1-based bucket index                                                             |
| `{color}`       | String  | Cycled palette color, `#hex` form (override with `colors=` modifier)             |
| `{color_hex}`   | String  | Same color without the leading `#` — for Word `w:shd w:fill` attributes          |

Empty bucket lists render the body zero times. Add `{:else}No responses yet.` before the closing `{/ChartBucket}` for a fallback (`{:else}` splits the branch — it has no closing tag of its own).

**Modifiers** (pass as a third colon segment using `key=value&key=value`):

| Modifier   | Example                                              | What it does                                                                                                                             |
| ---------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `colors=`  | `colors=#1e40af,#b91c1c,#16a34a`                     | Override the default 8-color palette; cycles by row index.                                                                               |
| `where=`   | `where=Mode__c='Drive Alone' AND Reasons__c != null` | SOQL fragment appended to the chart's WHERE. Forces server-side aggregation.                                                             |
| `split=;`  | `split=;`                                            | Treat the field as multi-select (semicolon-separated).                                                                                   |
| `groupBy=` | `groupBy=Location__c`                                | Cross-tab pivot. Each bucket exposes a `cols` sub-list — iterate with `{#cols}{key}={count} ({percent}%){/cols}`. Total column appended. |
| `colSort=` | `colSort=8000 Marina,3260 Bayshore`                  | (Pairs with `groupBy=`.) Column ordering.                                                                                                |

**Pivot tables (`groupBy=`).** The body becomes a row containing another loop, `{#cols}`. Each col is one value of the `groupBy` field plus a final `Total` column:

```html
<div class="row">
    <div class="cell">{key_label}</div>
    {#cols}
    <div class="cell">{count} ({percent}%)</div>
    {/cols}
</div>
```

Inside `{#cols}` you get the standard bucket fields (`{key}` / `{key_label}` / `{count}` / `{percent}` / `{percent_int}` / `{color}` / `{color_hex}` / `{index}`) plus two pivot-only fields:

- `{percent_of_row}` — Decimal — this cell's count as a percent of its row's total.
- `{percent_of_row_int}` — Integer — same, rounded.

Use these when you want each row's segments to sum to 100% (stacked-bar composition) rather than each cell's value as a percent of the overall total.

**Layout gotcha for pivot bodies:** Portwood's HTML container auto-expansion reacts to nested loops by duplicating the nearest open `<tr>`. If you put `{#cols}` directly inside `<tr>`, every column gets a whole row. **Use `<div>` + `display:table-row` + `display:table-cell` for pivot bodies, not `<tr>`/`<td>`.** See `docs/CommuteSurveyExample.html` for the canonical pattern.

#### 7.6.9 CSS 2.1 reminders (PDF output)

Because Flying Saucer renders PDFs as CSS 2.1:

- ✅ `<table>` + `<tr>` + `<td>` for non-pivot charts
- ✅ `<div>` with `display: table` / `table-row` / `table-cell` for pivot charts
- ✅ Solid `background:#hex;` for bar fills (`{color}` returns `#hex` strings)
- ❌ `flex`, `grid`, `gap`, `linear-gradient(...)`, `calc(...)` — silently ignored, layout collapses
- ❌ CSS variables — `var(--brand)` is dropped

For DOCX output, an HTML-authored chart template still renders the same way; Word treats the chart `<div>` blocks as styled boxes.

#### 7.6.10 Word templates — supported as of v1.92

The `{Chart:...}` PNG-via-CV pipeline (shipped this release) made Word a **peer of HTML** for chart output. All 9 styles render correctly in `.docx` output. The legacy "Word doesn't do pivot/stacked/clustered" caveat is **no longer in effect**.

What's supported in Word today:

- ✅ All 9 styles via `{Chart:...}` tags
- ✅ All five modifiers (`colors=`, `where=`, `split=`, `groupBy=`, `colSort=`)
- ✅ Outer record loops driving page-per-iteration layout (page-breaks via `<w:pageBreakBefore/>`)
- ✅ Hand-authored `{#ChartBucket:...}` simple-bar pattern (legacy)

What's still Word-specific:

- Hand-authored cross-tab `{#ChartBucket}` with `{#cols}` inside `<w:tr>` — **still hits the row auto-expansion limitation.** Use `{Chart:...:stacked}` or `{Chart:...:clustered}` instead, which generate PNGs server-side and embed them via `<w:drawing>`.

Reference Word template: `docs/ChartEngineShowcase.docx` (all 8 chart styles, one per page). Open in Word to see how the `{Chart:...}` tags drop in as plain paragraph text. The engine handles every conversion downstream.

### 7.7 Images

**Option 1 — record-attached (easiest).** `{%Image:N}` renders the Nth oldest image attached to the current record. No ContentVersion ID field, no query-builder setup — drag a photo onto the record in Files and the tag picks it up. Filters to PNG/JPG/GIF/BMP/TIFF/SVG automatically (non-image attachments are skipped).

```
{%Image:1}                First image attached to the record, natural size
{%Image:1:200}            Max 200px in either dimension (preserves aspect)
{%Image:1:200x200}        Explicit 200px × 200px
{%Image:1:400x}           400px wide, auto height
{%Image:1:x150}           Auto width, 150px tall
{%Image:2}, {%Image:3}    Second, third, … attached image
```

Inside a `{#Relationship}` loop, `{%Image:N}` scopes to the iterating record's images — ideal for inspection reports, real estate listings, product catalogs. Out-of-range indexes render empty silently.

**Option 2 — image field (advanced).** When you need to pick a specific image that isn't the Nth attachment, store the ContentVersion ID (starts with `068`) in a text field and reference it:

```
{%ImageField}                   Embed an image from a rich text field or Files
{%LogoImage:200x100}            Width × height in pixels (see §7.7.2 for sizing in PDF)
```

Handles multiple sources automatically:

- Rich text HTML `<img src="data:...">` — decoded and embedded
- Raw base64 strings (100+ chars) — decoded and embedded
- ContentVersion IDs (18-char, starts with `068`) — looked up and fetched
- Salesforce file URLs (`/sfc/servlet.shepherd/...`) — resolved to blob
- HTTPS URLs — embedded as URL references for PDF rendering

**PDF path (special behavior).** For ContentVersion IDs, the PDF pipeline skips blob loading entirely — it uses relative Salesforce URLs (`/sfc/servlet.shepherd/version/download/<cvId>`) and `Blob.toPdf()` fetches them natively via the VF rendering engine. This is what enables unlimited images in PDFs without heap pressure.

**Image size limits.** PDFs with attached images are limited to roughly **30MB of total image content** for reliable Save-to-Record. Above that threshold, the save operation will error out (Salesforce platform limits on the ContentVersion insert path). If you need to include more images than this threshold allows, use **Download** instead of Save-to-Record — downloads work at a higher ceiling because they don't go through the same save pipeline. A typical inspection report with 20–30 phone photos fits within the 30MB ceiling; 50+ high-resolution photos may need to be downloaded and attached manually.

#### 7.7.1 Shared assets (`{%asset:<key>}`)

Use a **shared asset** when the same image — a logo, a footer band, a letterhead — appears in many templates and you want to update it in one place. Instead of pasting the same image (or its file ID) into every template, you reference the asset by a short, stable key. When you upload a new version of the asset, **every template that uses its tag picks up the new image automatically** — no template edits.

**Set one up** from the **Command Hub → Assets** tab: give the asset a friendly name (e.g. "Primary Footer"), choose its **tag key** (a short, human-readable handle such as `footer`, suggested from the name and checked for availability as you type), upload an image, and copy its merge tag. The key is **permanent** — renaming the asset later never changes the key, so templates keep working — and it is case-insensitive (`{%asset:Footer}` and `{%asset:footer}` are the same asset).

**Finding assets in a growing library (v3.30+).** The Assets tab shows a **thumbnail preview** of each asset's current image, and a **search box** filters the list live by name, tag key, merge tag, or category. Assets can carry an optional free-text **Category** ("Logos", "Footers", "Backgrounds" — any label you like, set when creating the asset or later via the row's **Edit** action); once at least one asset is categorized, a **category dropdown** appears next to the search box, including an _Uncategorized_ bucket. Categories are purely organizational — they never affect how the merge tag resolves.

```
{%asset:footer}            Latest version of the asset whose key is "footer"
{%asset:companylogo}       (any key you chose when creating the asset)
{%asset:companylogo:200x100}   Fixed 200×100 px
{%asset:companylogo:600x}      Fixed 600 px wide, height auto (keeps aspect)
{%asset:companylogo:x80}       Fixed 80 px tall, width auto
```

> **Assets in email templates (v3.32+):** the same `{%asset:<key>}` tag works inside **signature email templates** (Command Hub → Email Templates) — there it resolves to the asset's **public image URL** instead of embedding the image, so you write and size your own markup: `<img src="{%asset:footer-banner}" style="height:40px"/>`. This is the easiest way to host email images in Salesforce Files: reference any asset in your email HTML, and replacing the asset's image later updates every email automatically. Size suffixes are ignored in emails (use CSS); saving or previewing the template publishes the referenced assets so recipients' email clients can load them. See §10.14.

A size token must contain an `x` (the width × height separator); a bare number with no `x` is ignored. **Pixels (`px`, or a bare number) and percentages (`50%x`) are the supported units** — see **§7.7.2** for exactly what works in HTML → PDF (and the named-unit / max-width limits to be aware of).

- Resolves to the asset's **latest** uploaded version every time a document is generated, so an updated logo flows through to all referencing templates at once.
- Works across **Word, HTML, PDF, and PowerPoint** output, in the document body and in headers/footers — including very large datasets.
- **Cross-user by design:** an asset one administrator creates renders correctly in documents other users generate.
- **Deactivate** an asset (rather than deleting it) to retire it without losing history. A tag that points at a deactivated or unknown key renders a small `[missing asset: <key>]` placeholder so you notice it in review — it never breaks document generation.

**What the tag produces.** The tag resolves to the asset's current image and then flows through Portwood's normal image pipeline, so it behaves like an inline image native to each format. You place the tag **where you want the image to appear** — you do not wrap it in your own `<img>` or pass it to a `src`; the tag _is_ the image.

| Output                          | What `{%asset:key}` becomes                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **HTML / PDF (HTML template)**  | An `<img src="/sfc/servlet.shepherd/version/download/…">` element. The relative URL is fetched at render — exactly what the PDF engine (Flying Saucer) needs; no absolute URLs or data URIs required. A size token on the tag (`:300x`, `:200x100`, `:50%x`) is honored precisely; with no token the image renders at its natural size (capped to `max-width:100%`). See **§7.7.2** for the supported units and limits. |
| **Word (`.docx`)**              | The image bytes are **embedded** directly in the document. The `.docx` is self-contained and shows the image offline.                                                                                                                                                                                                                                                                                                   |
| **PDF (Word template)**         | Referenced by relative URL via the zero-heap path, so large images don't exhaust heap on big jobs.                                                                                                                                                                                                                                                                                                                      |
| **PowerPoint (`.pptx`)**        | Embedded as a picture shape on the slide.                                                                                                                                                                                                                                                                                                                                                                               |
| **Excel (`.xlsx`)**             | Image assets are **not** rendered in Excel output in v1 — the tag is removed cleanly (no error).                                                                                                                                                                                                                                                                                                                        |
| **Large datasets (>2000 rows)** | Tags in headers, footers, and grand-summary areas resolve the same way (the high-volume rendering path emits the same `<img>`).                                                                                                                                                                                                                                                                                         |

**Permissions:** administrators (Portwood Admin) create and manage assets; standard Portwood users get read-only access, which is all that is needed to generate documents that reference them.

> **v1 scope:** shared assets are **images** only. Text/HTML snippet assets and pinning a template to a specific asset version are planned follow-ups.

#### 7.7.2 Sizing images in HTML → PDF

The size token on any image tag — `{%Image:N:…}`, `{%ImageField:…}`, `{%asset:key:…}` — controls the rendered size in **HTML-template → PDF** output. (As of **v3.26** these are honored precisely; earlier versions could collapse every size of the same image to one.) The rules below are specific to the PDF engine (Flying Saucer); Word/DOCX output is more flexible because Word does its own layout.

**Supported units: pixels and percent only.**

| Token         | Result                                                                                         |
| ------------- | ---------------------------------------------------------------------------------------------- |
| `:300x100`    | 300 px wide × 100 px tall (exact — may stretch off-aspect)                                     |
| `:300x`       | 300 px wide, height **auto** (keeps aspect)                                                    |
| `:x100`       | 100 px tall, width **auto** (keeps aspect)                                                     |
| `:50%x`       | 50% of the page content width, height auto                                                     |
| `:300` (bare) | `{%Image:N}` only → 300 px wide; on `{%Field}`/`{%asset}` a bare number with no `x` is ignored |

A blank side means **auto** (aspect-preserving): `{%LogoImage:100x}` is the same as 100 px wide with auto height. Pixels map to physical size at **96 DPI** (so `:96x` ≈ 1 inch wide, `:288x` ≈ 3 inches).

**Named units are not parsed.** `in`, `pt`, `cm`, `mm`, `pc` (e.g. `:3inx`, `:x25mm`) are silently ignored and the image falls back to natural size. Convert to pixels at 96 DPI:

| 1 in  | 1 cm    | 1 mm    | 1 pt    | 1 pc  |
| ----- | ------- | ------- | ------- | ----- |
| 96 px | 37.8 px | 3.78 px | 1.33 px | 16 px |

So `:3inx` → `:288x`, `:x25mm` → `:x95`.

**`max-width` / `max-height` are _not_ honored in PDF.** Flying Saucer applies only an explicit `width`/`height` to these images — a CSS `max-width`, `max-height`, or a "max size" token is ignored and the image renders at its natural size. There is no "cap large, leave small alone" sizing in PDF.

- **Fitting a row of mismatched logos** (partner firms upload very different dimensions): give them all a **uniform width**, `{%Firm__r.Logo__c:200x}`. Each renders 200 px wide with proportional height — small logos scale up, large scale down, none distorted. (Avoid a fixed `:200x80` box for logos — it stretches them off-aspect.)

**Hand-authored `<img>` tags (advanced).** If you write your own `<img src="/sfc/servlet.shepherd/version/download/068…">` instead of a `{%}` tag, you control the CSS directly, but two caveats apply:

1. Only `width`/`height` take effect — `max-width` does not (same engine limit as above).
2. The renderer computes one rendered size **per image URL** and reuses it. If you reference the **same** file at two different sizes, both come out the same. Add a throwaway query parameter to make each distinct (`…/068…?n=1`, `…/068…?n=2`). Portwood's `{%}` tags do this automatically, so prefer the tag unless you specifically need raw markup. (A grid of _different_ logos — different files — isn't affected.)

### 7.8 Barcodes & QR codes

```
{*OrderNumber}                  Code 128 barcode (default)
{*TrackingId:code128}           Explicit type
{*SKU:code128:300x80}           300×80 px
{*ProductCode:qr}               QR code
{*URL:qr:200}                   200px QR code
```

Barcodes render in Word **and** HTML templates (HTML support added in v3.15) across PDF and DOCX output. Types supported: `code128`, `qr` — **only** those two. A typo'd or unsupported type (e.g. `{*SKU:code39}`) renders nothing, silently; leaving the type off defaults to Code 128.

QR codes are generated natively in Salesforce with Level Q error correction and support values up to 600 characters. For printed or mailed documents, short URLs or tokens under 120 characters are recommended for 1 inch square QR codes.

### 7.9 Signatures

See [§10](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#10-e-signatures-v3) for the full signature feature. Tag syntax:

```
{@Signature_Buyer}                  v2 — typed full signature (default)
{@Signature_Buyer:1:Full}           v3 — role=Buyer, order=1, type=Full signature
{@Signature_Buyer:1:Initials}       v3 — initials
{@Signature_Buyer:1:Date}           v3 — auto-filled signed date
{@Signature_Buyer:1:DatePick}       v3 — user-chosen date
{@Signature_Loan_Officer:2:Full}    Role names with underscores for multi-word
{@Signature_Buyer:1:Full:inline}    v3 — compact in-place mark, no stamp card (tight layouts)
```

- **Role**: any string (Buyer, Seller, Witness, Loan_Officer, etc.). Underscores become spaces in the UI.
- **Order**: sequence number per-role (optional, defaults to 1). Used for sequential signing and multi-placement per signer.
- **Type**: `Full` | `Initials` | `Date` | `DatePick` (optional, defaults to `Full`).
- **Style** (optional): add `:inline` as a final suffix (e.g. `{@Signature_Buyer:1:Full:inline}`, `{@Signature_Buyer:1:Date:inline}`) to render a **compact in-place mark** instead of the stamp card. See [§10.7.2](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#1072-stamp-card-vs-inline--how-a-signature-renders).

Pre-signing, tags are preserved in the output (not replaced). Post-signing, each tag position carries the signer's mark as a **stamp card** — drawn ink or typed name in a signature font, with a "Signed by X · date" caption (see §10.10). Date tags stamp the signed date as text.

#### Signature loop block — `{#Signatures}` (variable signer count)

Role tags above pin each signer to a **fixed spot** — perfect when you know the parties (Buyer + Seller). But when the **number of signers varies** (a quote signed by one person today, three next week), you'd otherwise need a separate template per count, and any unused role tag leaks as literal text.

The `{#Signatures}` loop block solves this: author **one** signature layout and it repeats **once per signer**, for any count, wherever you place it in the document.

```
{#Signatures}
  ______________________________
  {Name}
  Electronically signed on {SignedDate}
  {Role} · {Email}
{/Signatures}
```

Per-row fields available inside the block:

| Field              | Value                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| `{Name}`           | The name the signer typed at signing (their e-signature); the invited name if none was captured |
| `{RegisteredName}` | The name the signer was invited under                                                           |
| `{Role}`           | The signer's role (defaults to `Signer`)                                                        |
| `{Email}`          | The signer's email                                                                              |
| `{SignedDate}`     | The date they signed (blank before signing)                                                     |
| `{Status}`         | `Pending` before signing, `Signed` after                                                        |

**Styling is yours.** The block is plain template content, so style `{Name}` however you like — a cursive web font for a handwritten look, a bordered box, a two-column table of signers, etc. (HTML templates have full CSS control within the Flying Saucer CSS 2.1 subset; Word templates can style the line too.)

Notes:

- **Backwards-compatible and additive.** Role tags (`{@Signature_Role}`) are unchanged and continue to work exactly as before — use them when you want signatures in fixed, scattered positions. A template **without** a `{#Signatures}` block renders identically to previous releases. You can even combine both in one template.
- **Where it applies.** The loop is populated by the snapshot/PDF-viewer signing flow (the flow that re-renders the document from a send-time data snapshot and attaches the completed PDF + certificate to the record). Before signing, the block previews the invited signers with a `Pending` status; on completion it shows each signer's typed signature and signed date.
- **Typed-name signatures** today (drawn-signature images are a planned future enhancement; the loop already supports per-row image fields for when that lands).

### 7.10 Rich text fields

When a field value contains HTML (`<p>`, `<div>`, `<br>`, `<b>`, `<i>`, `<u>`, `<strong>`, `<em>`, `<span>`, `<img>`, `<a>`), Portwood preserves the formatting in the output — paragraphs, line breaks, bold/italic/underline, hyperlinks, and embedded images all carry through. Works in **Word templates** (DOCX or PDF output) and **HTML templates** (PDF output). PowerPoint strips HTML to plain text.

**Inline images in rich text** (the kind you paste directly into a Rich Text Area field) render across all three target formats — Word→PDF, Word→DOCX, and HTML→PDF — when you generate from the runner on a record page. Behind the scenes Portwood handles three flavors of image source automatically:

- **Lightning inline images** (`/servlet/rtaImage?...&refid=…`) — refids that resolve to a `ContentVersion` (068/069 prefix) are rewritten to relative `/sfc/servlet.shepherd/…` URLs. `0EM` Lightning ContentReference refids aren't queryable, so they keep their absolute `*.file.force.com` URL — works in authenticated server-side rendering, but not in environments that lack reach to the file subdomain.
- **Inline data URIs** (`<img src="data:image/...">`) — DOCX and Word→PDF embed them; HTML→PDF drops them (Flying Saucer's `Blob.toPdf` can't decode data URIs).
- **Hosted Salesforce file URLs** (`/sfc/servlet.shepherd/...`) — pass through to all targets.

A few caveats:

- The **Generate Sample** button in the template builder doesn't render inline rich-text images — they show as broken placeholders. Test the real output via the runner instead.
- For pixel-perfect images, use the `{%Image:N}` tag with an attached File rather than inline rich text — DOCX image quality is slightly lossy when sourced from rich-text inline images.
- Inline-image rotation isn't preserved. Rotate the source before pasting.
- **Pre-size images before pasting.** Lightning's rich text editor doesn't write `width=`/`height=`/`style=` to the HTML it stores — even when you drag-resize the image in the editor, the displayed size never makes it into the saved markup. (In Chrome, drag-resize is disabled outright; Firefox lets you drag but the resize still doesn't persist.) Portwood falls back to a 4-inch default for DOCX output and to natural pixel dimensions for PDF output, so a phone photo pasted at 4000×3000 will render correctly in DOCX but bleed off the page in PDF. The reliable fix is to **resize the image to your intended dimensions in an editor BEFORE pasting** — once it's in the rich text field, the size is locked to whatever the source pixels were. For pixel-precise sizing across both formats, prefer `{%Image:N}` with `:WxH` (§7.7).

Plain multiline (long text, textarea) fields work too — newlines in the field value render as proper line breaks in the output across all three targets. No manual `<br>` needed.

### 7.11 Watermarks / page backgrounds (PDF output)

Two ways to add a full-page watermark or background image to your PDF output:

**Option A: Upload via the template builder (recommended).** In the template editor, click the **Watermark / Background** tab and upload a pre-sized image. This bypasses Word's Watermark dialog entirely and gives you exact pixel-level control over the output. A **Watermark strength** control (Light 15% / Medium 30% / Strong 50% / Original) fades the image — the opacity is baked into the stored PNG because Flying Saucer has no CSS opacity, and Portwood keeps the unfaded original so changing the strength after upload re-fades from it rather than compounding. The new setting applies immediately and survives a page reload (v3.57+).

**Option B: Insert via Word's Design → Watermark dialog.** Word's built-in watermark works too, with these constraints:

- **Scale must be set to 100%.** Word's "Auto", "50%", etc. scale settings are ignored by the PDF renderer — only the source image's pixel dimensions matter.
- **Washout must be OFF.** Leave the Washout checkbox unchecked. To get a faded look, pre-fade the image in an editor (~15–20% opacity over white) BEFORE inserting in Word.
- **No rotation.** Word's 315° diagonal default isn't honored. If you need a rotated watermark, save the image pre-rotated as a PNG.

Both options use the same rendering pipeline — `@page { background-image: url(...) }` extending edge-to-edge across the full page bleed.

**Pre-resize your watermark image to the page dimensions at 96 DPI** (the resolution Flying Saucer renders at — NOT the standard 72 DPI you might assume from PDF specs):

| Page size            | Pixels at 96 DPI  |
| -------------------- | ----------------- |
| Letter (8.5 × 11 in) | **816 × 1056 px** |
| A4 (8.27 × 11.69 in) | **794 × 1123 px** |
| Legal (8.5 × 14 in)  | **816 × 1344 px** |

Other limitations (apply to both options):

- **Text watermarks** ("DRAFT", "CONFIDENTIAL" via Word's text watermark option) are not supported. Use a picture watermark with the text rendered into a PNG.
- **DOCX output preserves whatever Word would render natively** — these constraints only apply to PDF output.

### 7.12 Built-in date/time tags

Two special merge tags resolve to the current date/time without needing a formula field. They accept the same format suffixes as any date field:

```
{Today}                         2026-04-20 00:00:00 (bare tag carries a midnight time — add a format suffix for a clean date)
{Today:MM/dd/yyyy}              04/20/2026
{Today:MMMM d, yyyy}            April 20, 2026
{Today:date}                    Running user's locale default
{Today:date:de_DE}              20.04.2026 (German)
{Now}                           2026-04-20 14:30:00 (current DateTime)
{Now:yyyy-MM-dd HH:mm}          2026-04-20 14:30
{Now:date:ja_JP}                2026/04/20 (Now formatted as Japanese date)
```

Case-insensitive for the keyword itself (`{today}` works). Works in sync, giant-query, bulk, and signature-stamped documents. All format suffixes from §7.2 apply.

### 7.13 Running user tags (Prepared by:)

`{RunningUser.X}` resolves against the **executing user's** record (whoever clicks Generate, runs the Flow, or owns the bulk job). No configuration — works on every template, every record, every output format.

```
Prepared by: {RunningUser.Name}
Email:       {RunningUser.Email}
Title:       {RunningUser.Title} · {RunningUser.Department}
Phone:       {RunningUser.Phone}
```

**Allowlist** — these are the only User fields exposed (other field names resolve to empty by design, so signed templates can't be edited to leak arbitrary User columns):

| Group     | Fields                                                              |
| --------- | ------------------------------------------------------------------- |
| Identity  | `Id`, `Name`, `FirstName`, `LastName`, `Email`, `Username`, `Alias` |
| Title/org | `Title`, `Department`, `CompanyName`, `EmployeeNumber`              |
| Contact   | `Phone`, `MobilePhone`, `Extension`, `Fax`                          |
| Address   | `Street`, `City`, `State`, `PostalCode`, `Country`                  |
| Locale    | `TimeZoneSidKey`, `LocaleSidKey`, `LanguageLocaleKey`               |

Case-insensitive for the namespace (`{runninguser.name}` works). Format suffixes from §7.2 apply: `{RunningUser.Phone}`, `{RunningUser.Name:!}` (no formatter needed for strings — most useful for date-typed extensions).

Works in sync generation, bulk runs, giant-query PDFs (headers/footers/title blocks), Flow-triggered docs, and HTML templates. The User row is queried **once per transaction** and cached, so a 60K-row PDF with `{RunningUser.Name}` in the header costs one extra SOQL total.

### 7.14 Checkmarks & symbols (PDF-safe)

Salesforce's PDF engine (Flying Saucer) only ships with four fonts (Helvetica, Times, Courier, Arial Unicode MS) and does not render arbitrary Wingdings or Symbol glyphs. Approved custom static TrueType faces are supported through **Assets → Custom Fonts**. Most "decorative" Word symbols (Wingdings checkboxes, custom dingbats) silently render as a blank box.

Portwood handles this for you in two ways:

1. **Word checkbox glyphs** (Insert → Symbol → Wingdings 0xFE / 0xA8, or Word content-control checkboxes) are auto-translated to their Unicode equivalents at PDF render time.
2. **Unicode symbols** typed directly in Word, Google Docs, Notion, or any HTML template are auto-wrapped in an Arial Unicode MS span so they render instead of dropping to tofu.

#### Copy-paste symbol palette

These all render reliably in PDF and DOCX. Highlight + copy any of them into your template:

**Checkboxes**
| Symbol | Name | Codepoint |
|---|---|---|
| ☐ | Empty checkbox | U+2610 |
| ☑ | Checked checkbox | U+2611 |
| ☒ | Crossed checkbox | U+2612 |

**Checks & crosses**
| Symbol | Name | Codepoint |
|---|---|---|
| ✓ | Check mark | U+2713 |
| ✔ | Heavy check mark | U+2714 |
| ✗ | Ballot X | U+2717 |
| ✘ | Heavy ballot X | U+2718 |

**Bullets & arrows**
| Symbol | Name | Codepoint |
|---|---|---|
| • | Bullet | U+2022 |
| ▪ | Black square | U+25AA |
| ▶ | Right-pointing triangle | U+25B6 |
| ► | Right-pointing pointer | U+25BA |
| → | Right arrow | U+2192 |
| ← | Left arrow | U+2190 |
| ↑ | Up arrow | U+2191 |
| ↓ | Down arrow | U+2193 |
| ⇒ | Heavy right arrow | U+21D2 |

**Stars & rating**
| Symbol | Name | Codepoint |
|---|---|---|
| ★ | Filled star | U+2605 |
| ☆ | Empty star | U+2606 |
| ♥ | Heart | U+2665 |
| ♦ | Diamond | U+2666 |

**Punctuation & misc**
| Symbol | Name | Codepoint |
|---|---|---|
| § | Section | U+00A7 |
| ¶ | Pilcrow | U+00B6 |
| † | Dagger | U+2020 |
| ‡ | Double dagger | U+2021 |
| … | Ellipsis | U+2026 |
| — | Em dash | U+2014 |
| – | En dash | U+2013 |
| © | Copyright | U+00A9 |
| ® | Registered | U+00AE |
| ™ | Trademark | U+2122 |
| ° | Degree | U+00B0 |
| ± | Plus-minus | U+00B1 |
| × | Multiplication | U+00D7 |
| ÷ | Division | U+00F7 |

#### Conditional checkbox pattern

Combine the checkbox glyphs with `{Field:checkbox}`, or use `{#IF}` with `{:else}` to render dynamic checked/unchecked state from a Salesforce checkbox field:

```
Approved: {#IF IsApproved}☑{:else}☐{/IF}
```

Or in tabular form for surveys / inspection forms (the inverse section `{^Field}` works too):

| Item             | Status                                                              |
| ---------------- | ------------------------------------------------------------------- |
| Pre-flight check | {#IF Preflight_Complete\_\_c}☑{:else}☐{/IF}                         |
| Safety briefing  | {#IF Safety_Done\_\_c}☑{/IF}{^Safety_Done\_\_c}☐{/Safety_Done\_\_c} |

> There is no `{#IFNOT}` tag — use `{:else}` inside an `{#IF}`, or the inverse section `{^Field}…{/Field}` (§7.4).

#### What does NOT work

- **Wingdings / Webdings glyphs** other than checkboxes — Flying Saucer can't render them at all. Portwood translates the common checkbox/check codepoints (Wingdings F0A8, F0FE, F0FD, F0FB, F0FC, F0A2; Wingdings 2 F050–F053, F0A3, F0A4); anything else falls back to a neutral □ placeholder.
- **Emoji** (😀 🎉 etc.) — out of Arial Unicode MS coverage, render as tofu in PDF. Use the Unicode symbols above instead.
- **Unapproved or unsupported fonts** — use an approved static TrueType face for PDF, or native DOCX output where the recipient has the font installed. See [custom fonts](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#custom-fonts).

### 7.15 Classic Approvals related list — `{#Approvals}` (v1.92+)

Render the host record's Salesforce **Classic Approvals** process history (submission, every approval/rejection step) directly in a generated document. Common use cases: Purchase Orders showing every approver up the chain in the final PDF, NDAs stamped with each signatory's role + timestamp, change-management forms with the approval audit trail rendered alongside the form data.

**Opt-in via Query_Config\_\_c.** Add the standalone word `Approvals` somewhere in the template's Query_Config**c (case-insensitive, word-boundary — `MyApprovalsList**c`doesn't activate it). When Portwood sees the token, it queries`ProcessInstance`+`ProcessInstanceStep`for the host record and exposes the flattened step list as a child collection at the`Approvals` key.

Example Query_Config\_\_c entry:

```
Name, Status__c, Amount__c, Approvals
```

Example template body:

```
{#Approvals}
{ActorName} ({ActorTitle}) — {StepStatus} — {CreatedDate:MM/dd/yyyy h:mm a}
Comments: {Comments}

{/Approvals}
```

**Fields available inside the loop:**

| Field               | Source                                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------ |
| `ActorName`         | `Step.Actor.Name` — who actually took the action                                                       |
| `ActorTitle`        | `Step.Actor.Title` — title on the User who acted                                                       |
| `ActorEmail`        | `Step.Actor.Email`                                                                                     |
| `OriginalActorName` | `Step.OriginalActor.Name` — useful when an approval was reassigned (delegated to)                      |
| `StepStatus`        | `Started`, `Approved`, `Rejected`, `Removed`, `NoResponse` — see Salesforce docs for the full list     |
| `Comments`          | Approver's comments (empty string when omitted)                                                        |
| `CreatedDate`       | When the step occurred — works with the standard `{CreatedDate:MM/dd/yyyy}` format specifiers (§7.2)   |
| `ProcessStatus`     | The parent `ProcessInstance.Status` — the overall outcome of the approval process this step belongs to |
| `SubmittedByName`   | Who originally submitted for approval (constant within one ProcessInstance)                            |
| `SubmittedByTitle`  | Submitter's User.Title                                                                                 |

**Sorting.** Steps are sorted earliest-first within each ProcessInstance, and ProcessInstances are sorted earliest-first. So a record that was submitted, rejected, then resubmitted and approved produces the steps in chronological order across both submissions.

**What's not included (yet).** Only steps that have been _acted on_ appear — pending approval items (`ProcessInstanceWorkitem`) are not in the list. If you need "still awaiting approver X", that's a separate query. Flow-based approval orchestration is a different object model and out of scope; this tag covers the Classic Approvals process only.

**Cost.** One extra SOQL query per generation when the token is present. Templates that don't reference `Approvals` in Query_Config\_\_c skip the query entirely — no overhead.

### 7.16 Approved PDF font tags

Use `{%font:asset-key:revision}` only inside a quoted inline `style` attribute, as a complete style declaration. Copy the real tag from the approved face in **Assets → Custom Fonts**; the revision pins the exact face instead of choosing a mutable latest font.

```html
<!-- Illustrative key/revision only: replace with the tag copied from your approved face. -->
<p style="{%font:brand-body:0123456789abcdef};font-size:12pt;color:#193b57;">Prepared for {Name}</p>
```

Use one font tag per element. Do not write `font-family:{%font:…}` or combine it with another font-family/weight/style override; the tag supplies those declarations. You can add font size, color, and other non-font-face styling. The face must have passed native PDF review; a missing, ambiguous, or unapproved revision can fail validation. Test retired/deleted font dependencies before changing them.

For page furniture, use [CSS page-counter spans](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#running-headers-footers) rather than putting a font tag and literal page-number tokens in the same header/footer. This registry controls native PDF rendering, not a recipient's Office font installation. See [Upload and approve a custom font](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#custom-fonts).

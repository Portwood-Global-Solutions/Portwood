A loop repeats content for each record. Start with a two-row example, then add nesting or grouping once the simple version works.

**Before you start:** Choose the fields and relationships in [Choose information](#choose-data). For an orientation and the format checklist, open [Find the right merge tag](#merge-tags).

#### Loops

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

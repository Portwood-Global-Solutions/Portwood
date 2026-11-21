---
name: html-template-authoring
description: Author or repair a Portwood HTML template that renders correctly through Blob.toPdf (Flying Saucer). Use when writing a new template, converting a design to a template, or fixing one whose PDF output doesn't match the source — collapsed layout, missing images, wrong fonts, broken charts.
---

# Authoring HTML templates for Portwood

**HTML is the recommended source format.** It skips the DOCX→HTML parse and lands more
reliably in the renderer. Steer new authors here, and chart authors here without
exception.

## The renderer is CSS 2.1

`Blob.toPdf` is Flying Saucer: **CSS 2.1 plus a small CSS 3 subset**. Unsupported
properties are _silently ignored_ — the page still renders, but layout collapses to
default block flow. Nothing warns you.

### Never use

- `display: flex`, `display: grid`, `gap`
- `linear-gradient(...)` and friends
- `calc(...)`
- CSS custom properties (`var(--x)`)
- most CSS 3 layout

### Use instead

- `<table>`-based layout for anything multi-column
- solid background colors
- absolute lengths (`pt`, `in`) and percentages
- `display: table-cell` / `table-row` on `<div>` where you need cell behavior without a
  real table

### The `tbody` trap

```css
table > tbody > tr > td { ... }   /* silently matches NOTHING */
```

The parse tree has no implied `<tbody>`. Use `td` attribute selectors or class-only
selectors:

```css
td.total { ... }
```

## Images

**URLs must be relative.** Absolute `https://…` URLs and `data:` URIs both render
broken — this is a hard constraint of the renderer, not a bug to work around.

If the same image appears at two different sizes, the renderer caches **one layout size
per URL**. Vary the URL to force a re-layout (the engine appends a size key for this
reason).

## Fonts and symbols

The base font families resolve to the base-14 PDF fonts (Helvetica / Times / Courier,
WinAnsi). **Anything outside Latin-1 renders as nothing** — not a box, not a fallback,
absent. Checkmarks, arrows, CJK, Greek, Cyrillic all disappear.

`'Arial Unicode MS'` is the one family that draws them, embedding as a subsetted CID
font. The trade-off is real and worth knowing:

|                      | Symbols / CJK | Bold                                                   |
| -------------------- | ------------- | ------------------------------------------------------ |
| `'Arial Unicode MS'` | ✅            | ❌ — no bold face; `font-weight: bold` renders regular |
| every other family   | ❌            | ✅                                                     |

So a symbol-heavy document gives up bold. Build hierarchy from **size, colour and fill
bands** instead — reversed white-on-dark headers, tinted totals rows, a solid band
behind the key number.

Embedding costs roughly 1.5KB → 70KB per page that uses it, and only for the glyphs
used.

## `@page` conflicts

The engine builds a `<style>` from the template's `Page_Size__c`, `Page_Orientation__c`
and `Custom_Margins__c` fields. If your source HTML also declares `@page`, the engine
**defers to your source** — you do not need to clear the template's page fields.

## Charts

The HTML chart expander uses a prepared PNG when the caller supplies one. Without PNG preparation, use bar, stacked, clustered or pivot for PDF. Cross-tabs need a second field in `groupBy=`. Inline SVG is browser-only. Word and PowerPoint can embed prepared PNGs. Excel does not embed chart-tag images.

Use the [3.64 authoring context](../../../docs/knowledgebase/llm-context.md) for the complete tag and workflow reference. A shared HTML clause uses `{%snippet:key}`. Fields inside the clause merge against the record where the tag appears. Inside a selected child loop, `{Name}` reads that child’s name. The snippet editor previews formatting; generate a PDF with the template’s sample record to verify the values. For signing, keep the wording in the snippet and put each signing placement directly in the main template body. The sender scans the main template before expanding snippets. A translated Salesforce Custom Label uses `{!$Label.Name}`. Use an approved face’s copied `{%font:api-name}` declaration inside an inline style and include the real asset key and query fields in the authoring brief.

### The pivot layout gotcha

HTML container auto-expansion looks for the nearest open `<tr>` when processing nested
`{#…}` loops. Putting `{#cols}` directly inside a `<tr>` makes **each column duplicate
the whole row**.

```html
<!-- WRONG — every column repeats the entire row -->
<tr>
    {#cols}
    <td>{key}</td>
    {/cols}
</tr>

<!-- RIGHT — div + table-row, CSS 2.1 safe -->
<div class="row" style="display: table-row">
    {#cols}
    <div style="display: table-cell">{key}</div>
    {/cols}
</div>
```

### Reference templates

| File                             | What it shows                                                               |
| -------------------------------- | --------------------------------------------------------------------------- |
| `docs/SurveyChartExample.html`   | Canonical chart template — single-dimension per question + cross-tab spread |
| `docs/CommuteSurveyExample.html` | Pivot + filter + multi-select + colSort composed together                   |
| `docs/ChartEngineShowcase.html`  | The full style gallery                                                      |

## Large tables

For giant-query templates, repeating headers on every PDF page come from Flying
Saucer's `-fs-table-paginate: paginate` plus `thead { display: table-header-group; }`.
Be aware this **mis-paginates some real-world templates dramatically** — verify page
count on a full render before relying on it.

## Before you ship a template

- Grep your own CSS: `grep -nE "flex|grid|gap:|gradient|calc\(|var\(--" template.html`
- Confirm every `<img src>` is relative
- If it has symbols, confirm the font is `'Arial Unicode MS'` and you haven't relied on bold
- Render it and count the pages

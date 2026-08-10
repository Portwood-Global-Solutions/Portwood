---
name: triage-report
description: Decide whether a Portwood bug report is a real code defect or a template-authoring problem, before any code is written. Use when a user reports "the PDF looks wrong", a merge tag didn't resolve, an image is missing, a chart is distorted, or output doesn't match the template. Most reports are template issues.
---

# Triaging a Portwood report

**Most reports are template issues, not code defects.** Work through this before
calling anything a bug. A report that turns out to be an authoring problem gets
answered as guidance and closed with the `template-help` label — it does not become
engineering work.

## Step 1 — Reproduce it

Do not skip to a diagnosis from the description. Get the template, the record, and
the output format. If you can't reproduce, ask for the template body and the
generated file before anything else.

The single most useful question to ask a reporter: **"Is the template HTML or DOCX?"**
It splits the decision tree in half.

## Step 2 — Rule out the template

These account for the majority of "it looks wrong" reports.

### CSS 3 in an HTML template

The PDF engine is `Blob.toPdf` → Flying Saucer, which is **CSS 2.1** plus a small
CSS 3 subset. These are **silently ignored** — the page renders, but layout collapses
to default block flow:

- `display: flex`, `display: grid`, `gap`
- `linear-gradient(...)` and other gradient functions
- `calc(...)`
- CSS custom properties / variables
- most CSS 3 layout features

Grep the template body first:

```bash
grep -nE "display:\s*(flex|grid)|gap:|linear-gradient|calc\(|var\(--" template.html
```

Any hit → template issue. The fix is `<table>`-based layout and solid colors.

### The `tbody` selector trap

`table > tbody > tr > td` silently matches nothing, because the parser's tree doesn't
have the implied `<tbody>` the browser inserts. Use `td` attributes or class-only
selectors instead. A stylesheet that "does nothing" usually has one of these.

### A chart style the output format can't render

Charts work in **Word, PowerPoint, Excel, PDF and HTML** — but not every _style_ works
in every format, and the mismatch is silent. Check the style against the format before
calling it a bug:

| Style                                    | Word / PPTX / XLSX |  HTML → PDF  |    HTML in a browser     |
| ---------------------------------------- | :----------------: | :----------: | :----------------------: |
| `bar`                                    |       ✅ PNG       |  ✅ CSS-bar  |            ✅            |
| `pivot`                                  |         ❌         | ✅ CSS table |            ✅            |
| `clustered`, `stacked`                   |       ✅ PNG       | ✅ CSS table |            ✅            |
| `column`, `pie`, `donut`, `line`, `area` |       ✅ PNG       | ❌ needs SVG | ✅ with `htmlRender=svg` |

Two rules explain the whole table:

- **Word / PowerPoint / Excel** get a rasterized PNG from `DocGenChartRasterizer`. Its
  `KNOWN_STYLES` are `bar, column, pie, donut, stacked, clustered, line, area` —
  **`pivot` is not among them**, because a cross-tab is a table, not a chart shape.
- **HTML → PDF** renders CSS-bar tables. `htmlRender=svg` produces inline `<svg>`, and
  **Flying Saucer drops inline SVG from `Blob.toPdf`** — it renders in a browser and
  vanishes in the PDF. So `column`/`pie`/`donut`/`line`/`area` need a non-PDF HTML
  target, or a different style.

"My pie chart is blank in the PDF" is the classic report, and it's a format/style
mismatch, not a defect.

Reference templates in `docs/`: `SurveyChartExample.html` is canonical,
`CommuteSurveyExample.html` composes pivot + filter + multi-select + colSort,
`SurveyChartExample.docx` is the Word-authored variant.

### Images that never appear

Image URLs for `Blob.toPdf` must be **relative**. Absolute URLs and `data:` URIs both
render broken. If the template has `https://...` or `data:image/...` in an `<img src>`,
that's the answer.

### Fields that "don't exist"

`No such column` on a field that plainly exists in the org almost always means the
permission set was not assigned, or was assigned before the deploy. Assign
`DocGen_Admin` **after** deploying, then retry.

### A `{#ChartBucket}` pivot duplicating whole rows

Placing `{#cols}` directly inside a `<tr>` makes each column duplicate the entire row —
the HTML container auto-expansion looks for the nearest open `<tr>`. Use
`<div class="row">` + `display: table-row`. Canonical pattern in
`docs/CommuteSurveyExample.html`.

## Step 3 — If it survives, it's a bug: record it

Do **not** fix it. File the issue. The issue is the deliverable — it is the work queue
that community contributors pick from, so the write-up carries the weight a direct fix
used to.

A good Portwood issue has:

- **Exact repro** — template shape, record shape, output format, what you expected.
- **`file:line` citations** into the actual code.
- **The mechanism proven, not asserted.** Run the code and paste the real output. A
  one-liner that demonstrates the failure beats a paragraph describing it.
- **Ranked fix options**, with a recommendation and why.
- **An explicit scope note** — which code paths reach this, and which don't.

Label it: `bug`, a `priority:*`, a `severity:*` if output is silently wrong, plus the
area label (`designer`, `pdf`, `docx`, `bulk-generation`, `flow-action`). Add
`good first issue` when the fix is well-bounded and you've named the option to take —
those are what a new contributor can actually land.

See issues #282 and #295 for the reference shape.

## Step 4 — Is it a showstopper?

Only **P0** breaks the batching pattern and gets fixed immediately.

**The P0 test:** would a customer hit this and not know their output is wrong? If yes,
it's P0 regardless of how rare. Silent corruption beats loud crashes. Data loss and
"package unusable for a whole customer segment" also qualify.

Everything else waits for a designated fix session. See `TRIAGE.md` for the full
rubric.

## The four merge-tag resolution paths

If the report _is_ a merge-tag bug, find out which path it took before diagnosing —
a fix in one path does not reach the others. See the `fix-merge-tag` skill.

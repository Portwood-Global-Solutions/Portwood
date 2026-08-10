---
name: canvas-designer
description: Work on Portwood's Canvas designer (docGenCanvas LWC and canvasModel.js). Use when changing the artboard, the box model, the HTML serializer or importer, or when a Canvas template renders differently from what the canvas showed.
---

# Working on the Canvas designer

`force-app/main/default/lwc/docGenCanvas/` — a Canva-style artboard that produces
HTML templates. ~9,900 lines of client code; `canvasModel.js` is the scene graph and
**the only place that knows how it becomes HTML**.

Canvas templates render through the HTML path (`DocGenService.isHtmlBacked`), so output
is always PDF. The Apex side is two lines — there is no `DocGenCanvasService`.

## The architecture, and why it is that way

**The model is the truth. The DOM is a disposable projection.**

The older designer treated the rendered DOM as the document, reading it back with
`innerHTML` and re-parsing. Under Lightning Web Security's per-namespace sandbox that
repeatedly broke: `ChildNode.replaceWith` is missing on proxied nodes, and
`cloneNode(true)` silently omits browser-inserted nodes. Canvas never parses anything
back out of the live tree, so there is no tree to be distorted. `contenteditable`
survives only _inside_ a single text box, where the browser's restructuring can't escape.

**Rules that follow from this — do not break them:**

- Never read the canvas back via `cloneNode` or `replaceWith` on the live tree.
- Never reconstruct model state from rendered DOM.
- Boxes are plain objects with **inch** coordinates. Pixels appear only at render time
  (inches × 96 × zoom), so changing zoom can never drift the document.

## Key functions in `canvasModel.js`

| Function                           | What it does                                                  |
| ---------------------------------- | ------------------------------------------------------------- |
| `serialize(doc, geo)`              | Model → HTML. Pinned boxes first, then flow boxes in y order. |
| `deserialize(html)`                | HTML → model, for reopening a saved document                  |
| `htmlToCanvas(html, measure)`      | The importer — arbitrary HTML → boxes                         |
| `buildQueryConfig(doc)`            | Derives a V1 Query Config from the tags actually placed       |
| `collectUsedFields(doc)`           | Merge-tag discovery, including conditions and totals          |
| `snapBox` / `buildAnchorGroups`    | Alignment guides, and box linking with cycle detection        |
| `sanitizeInline` / `collapseMarks` | Rich-text handling and brace repair                           |

### Two behaviors worth understanding before you change anything

**`flowMarginTop` emits the GAP from the previous flow box, not the box's `y`.** That
one function is the entire "a table grows and pushes everything below it down"
behavior. Emitting absolute `y` puts a box authored at y=5in five inches _below_ the
table, and the error compounds with each additional flow box.

**`buildQueryConfig` emits V1 flat format on purpose**, not V3 — V1 is what a human can
read and correct in the Query Configuration tab. It is a _suggestion the author
accepts_, never a silent overwrite.

## Test before you push — no org needed

The serializer is deliberately written to run without a DOM (`typeof document ===
'undefined'` guards), so it can be checked in plain Node:

```bash
node scripts/qa/canvas-serializer-check.mjs
node scripts/qa/canvas-anchor-check.mjs
node scripts/qa/canvas-export-roundtrip-check.mjs
node scripts/qa/canvas-import-fidelity.mjs
node scripts/qa/canvas-import-placement-check.mjs
node scripts/qa/canvas-inline-sanitize-check.mjs
node scripts/qa/canvas-chart-box-check.mjs
```

**Run these first on any `canvasModel.js` change.** They are the fastest feedback loop
in the repo. If you add a serializer rule, add a check here — a serializer that only
runs in a browser cannot be verified before it ships.

## Traps

### Serializer fixes do not reach saved documents

A stored body keeps its old markup until it is re-saved. A fix to `serialize` changes
what _new_ saves produce; it does nothing for documents already in the org. Plan
migrations accordingly, and don't treat "still broken after the fix" as a failed fix
until you've re-saved.

### The `Canvas` picklist value is frozen forever

It shipped in a managed package (v3.54.0). The value and everything keyed to it can
never be renamed or removed.

### Bold vs symbols is an either/or

`'Arial Unicode MS'` is the only family that draws symbols/CJK, and it has **no bold
face** — `canRenderBold()` exists to disable the Bold control for it so the canvas
doesn't promise a weight the PDF can't deliver. Every other family bolds fine.

### `box.html` vs `box.text`

`textToHtml` prefers `box.html` and falls back to `box.text`. The `text` path runs
through `expandMarks`, where `__` is the underline mark — which collides with `__c` and
`__r` in Salesforce API names. For programmatic authoring, set `box.html` (escaped,
`<br />` for newlines) and treat `text` as the legacy fallback. See issues #282 and #295.

### LWS blocks some browser APIs

`createObjectURL` for `text/html` is blocked — the HTML export uses a `data:` URI
instead. Expect similar surprises with any browser API that hands out a URL or a live
node reference.

## Reproducing namespace bugs

LWS distortion **cannot be reproduced in a no-namespace scratch org**. If you're
touching DOM handling, the bug class is only visible in a namespaced package install or
a namespaced scratch org.

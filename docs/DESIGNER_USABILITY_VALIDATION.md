# Designer usability validation

Current combined feature review and final cleanup: [FEATURE_REVIEW.md](FEATURE_REVIEW.md). The phase-specific results below are retained as historical validation.

Scratch org: `portwood-ai-journey` (`00DQL00000eUBPy2AO`). Branch: `feat/byod-signature-sender`.

Live mutations use the separate inactive **Designer usability lab - Quote** template (`a0DQL00000eWVRR2A4`) and Northstar demo quote (`0Q0QL000005dg1J0AQ`). Existing user editing tabs/templates are left alone. A Salesforce Files image asset, `designer-demo-logo`, supplies the sample logo.

## Verified live

- Selected-text bold, italic, underline, point size, base family, text colour, bulleted/numbered lists and centre alignment; pressed toolbar state and formatting undo/redo.
- Verified Lato Regular/Bold selection and native embedded PDF faces. Missing italic variants explain how to choose/add an approved face, without altering the document. Asynchronous font application exposes a busy state.
- Paragraph insertion at legal block boundaries; Salesforce field insertion at the caret; quantity display changed from GBP currency to two decimal places.
- Whole table move up/down, duplicate and remove with cells and loop tags intact. Row/column additions and undo retain the table inspector.
- Shift-click rectangular cell selection, horizontal and two-dimensional merge/split, row/column additions through merged regions, and undo. Cell spacing, borders and selected-cell fill update the intended table/cells.
- Accessible image-asset buttons insert an independent image block, close the picker and expose its inspector; undo restores the original paragraph.
- Image width remains physical at 150% zoom (1.5in = 144 CSS px = 216 displayed px). Live column drag at 150% keeps the table at 1015 CSS px while a 30px pointer move adds 20 CSS px to the selected column; row drag follows the same scale and undo restores both.
- Absolute placement at left 4in/top 0.15in/width 4.5in, 0.1in nudging, duplicate offset, removal and undo. Native PDF text starts at x=328.31pt: 40.31pt printable margin plus 288pt placement, within renderer rounding.
- Running header/footer editing and formatting; both repeat on a two-page native PDF. Settings → Done preserves unsaved position/image edits. HTML source ↔ visual preserves CSS/fonts/tags. Version history opens and loads the saved version.
- New heading placeholder selection replaces its text immediately. Text starts blank; a page break creates a clean second page with no editor label/placeholder printed.
- Cancelling the Back-to-templates confirmation preserves the unsaved draft.
- Multiple saves/reopen preserve the source stylesheet, authored landscape page, custom-font markers, placed content, running regions and merge tags; editor selection attributes are removed.
- Native PDF underline matches the editing surface after CSS 2.1 normalization.
- Native PDF renders a single A4 landscape page, logo, positioned paragraph, heading, three quote line items and $23,850 total. Download inspected independently with pdfinfo, pdffonts and text bounding boxes: 841.88 × 595.28pt, Lato Regular and Bold embedded as subsetted Unicode CID fonts.
- 820px and 500px viewport checks: no horizontal sheet overflow, advanced formatting reachable, Escape dismisses More and Fields. Viewport override reset.
- Routine saves/inserts use quiet status; PDF advisories stay in an on-demand notes panel. Actual failures use one recoverable inline notice with technical details disclosed.

## Regression checks

- `node scripts/qa/designer-editing-check.mjs`: 47 scenarios pass. Includes actual production cleanup, settings, preview-error and Shift-click methods, plus the production document/grid/font helpers, PDF decoration normalization, drag-resize geometry at 150–200% zoom, blank text/page-break presets and replaceable heading placeholders.
- `node scripts/qa/designer-page-layout-check.mjs`: nine page/CSS cases pass.
- `node scripts/qa/designer-shell-preservation-check.mjs`: shell/style preservation passes.
- Pinned PDF.js adapter reproducibility check passes.
- Full repository formatting passes. Changed JS has no newly introduced undefined references compared with the pre-change snapshot.
- Offline QA stays at 516/577 with the exact same 61 pre-existing failures (0 blocker, 14 major, 47 minor); it is not a green full-repository suite. Generated tracked QA reports restored after results were copied outside the repo.

## Scope

This validates the common Designer paths on a real scratch org and representative Quote, not every arbitrary imported HTML document or installed subscriber org. Canvas remains a separate product. Native PDF is the pagination authority; absolute content can overlap if an author chooses overlapping coordinates. Large/image-heavy PDF performance and the broader pre-existing repository findings remain separate work.

Final scratch deployment: `0AfQL00000svu810AA`.

Temporary Lightning Debug Mode was restored to disabled, and the final normal-mode reload, replacement-heading behavior and one-page native PDF were checked with no browser console errors. No Apex implementation changed for this overhaul, so deployment used NoTestRun. No production/package deployment or branch push was made.

## Direct source editing follow-up

Deployed `0AfQL00000svwGH0AY` to the same scratch org/branch. Isolated source demo: **HTML source demo - Quote** (`a0DQL00000eWkIR2A0`). The original Designer demo/user editing tabs remain intact.

A visible Visual/HTML switch, full-height source workspace, Format HTML, wrap toggle, caret line/column indicator, source-specific inspector and save/preview shortcuts support direct iteration. The full source includes authored CSS and running regions. Source changes cancel older PDF responses; returning to editing cancels an in-flight preview. An empty source is not replaced by an older saved body. Merely opening source preserves the dirty state.

Live checks cover field insertion at the HTML caret and undo, Format HTML and undo, wrap preserving code, unsaved heading changes in native PDF, CSS edits reflected in Visual mode, Ctrl/⌘+S, and saved source reopening with all font/region bindings intact. Source → PDF → Back to HTML preserves the exact unsaved source. The existing native PDF test displays all three quote lines and the correct total. Source uses native browser editing rather than introducing an external code-editor runtime.

The initial source-demo validation worked around the renderer's blanket ban on `!important` by editing inline colour directly. That blanket ban was too restrictive for source editing and is superseded by the font-preview fix below.

Final source-demo native PDF succeeds with the edited teal heading, approved Lato faces, logo, running regions, three line items and $23,850 total. The editor was left open in HTML mode. Narrow-width (500px) controls stay within the viewport; temporary viewport overrides and Debug Mode were restored. No browser console errors were captured. Full formatting and 47 editing/nine layout regressions pass; offline QA retains exactly the baseline findings.

## Registered-font preview fix

Scratch deployment: `0AfQL00000svy5B0AQ`. The blanket `!important` rejection is removed. Ordinary colour, sizing, alignment and pagination priorities survive PDF preparation. The renderer pins only each bound element's registered family, weight and style with inline priority, including inherited descendants. Exact inline font values may carry CSS priority; conflicting face values still fail. Authored `@font-face`, unbound registry-family stylesheet declarations (with or without priority), missing glyphs and unreviewed faces remain guarded.

Regression coverage adds important layout/colour rules, font shorthand trying to override a bound heading, inherited face pinning, priority on exact/incorrect inline faces, and priority attempting to bypass binding checks. `DocGenFontTest` and `DocGenHtmlTemplateTest`: 85 passing tests. The 47 editing, nine layout and shell checks pass; full formatting passes; offline QA retains the exact 61 baseline failures.

The current unsaved HTML-source demo was reproduced with its existing `.title, .title * { color: #285e63 !important; }` rule, then previewed successfully after deployment without rewriting its source. The current two-page quote includes all three lines and the $23,850 total, with no error notice or browser console errors. No user save was performed.

An independent native `previewDraftPdfData` check applies `font:italic 700 24pt Times !important` to a registered Lato Regular container and its child. The generated PDF embeds only Lato Regular as Unicode CID TrueType; the author’s 24pt sizing, teal colour and right alignment still apply. Artifact: `output/designer-overhaul/native-font-priority.pdf` outside the repository. Preview screenshot: `output/designer-overhaul/live-font-preview-fixed.png`. No Debug Mode change, production deployment or branch push was made.

# CLAUDE.md — Portwood

## Skills

`.claude/skills/` packages the project's working knowledge as Claude Code skills — they load automatically when relevant, and read as plain Markdown otherwise. Prefer them over re-deriving from this file:

| Skill                     | Covers                                                        |
| ------------------------- | ------------------------------------------------------------- |
| `dev-setup`               | Fresh clone → working, tested org                             |
| `run-tests`               | QA harness, e2e scripts, Apex tests, prettier, Code Analyzer  |
| `triage-report`           | Is a report a real defect or a template issue?                |
| `fix-merge-tag`           | The merge-tag resolution paths and how not to half-fix one    |
| `html-template-authoring` | CSS 2.1 constraints, charts, fonts, images                    |
| `canvas-designer`         | Canvas artboard, serializer, importer                         |
| `managed-package-rules`   | `global` visibility, Flow Apex-Defined types, namespace traps |

## How this project runs (from 2026-08-10)

Portwood is in **community-development mode**. Dave has deliberately stepped back from the code so contributors have work to pick up.

- **File issues; don't fix them.** When you find a bug, write the issue and stop. No PR, no patched working tree. The issue is the deliverable — it's the contributor work queue, so the write-up carries the weight a direct fix used to: exact repro, `file:line` citations, the mechanism **proven by running the code** rather than asserted, ranked fix options, an explicit scope note. Issues #282 and #295 are the reference shape.
- **Triage before recording.** Real defect, or template-authoring problem? **Most reports are template issues.** See the `triage-report` skill — it's the gate, not an optional step.
- **Fixes happen in designated sessions only.** Bugs accumulate until Dave says otherwise. Don't prompt for a release between dates.
- **Only P0 jumps the queue.** The test: would a customer hit this and not know their output is wrong? Silent corruption beats loud crashes.
- **Reach for `good first issue` / `help wanted`.** A well-specified bug with a named fix option is exactly what a new contributor can land. `community-contribution` covers the inbound side.
- **Community PRs change merge mechanics.** `gh pr merge --admin` after self-approval was the sole-coder shortcut; real contributor PRs mean actual review, and CI gates now matter to people other than Dave — `npm run format:check` blocks merge.

### Release cadence

**Fridays, every two weeks.** Next release: **2026-09-11**, deliberately ~4.6 weeks out to collect real user feedback first. Then 09-25, 10-09, 10-23, 11-06.

Milestones on GitHub are **release dates**, not version numbers — a contributor can see when their PR would actually ship. Version numbers are assigned at release time.

## Triage

See `TRIAGE.md` for the priority rubric (P0/P1/P2/P3 + severity labels). Apply it when classifying new issues.

## Mission

Maintain Portwood — a native Salesforce 2GP package for generating Word and PDF documents from any Salesforce record. Work is roadmap-driven via the GitHub issue board; treat it as the source of truth for what's in flight.

## Critical: three merge-tag resolution paths

`DocGenGiantQueryAssembler` does **not** call `processXml()`. A fix to section-tag logic in `processXml` only covers row-level loop bodies. Parent-level tags outside the loop are resolved by `DocGenGiantQueryAssembler.resolveParentMergeTags()`, and grand-total aggregates by `resolveGiantAggregateTags()`. If a parser-level change needs to behave consistently for templates that fall into the giant-query path (>2000 child rows), the logic has to be mirrored in the assembler or routed through `processXmlForTest` the same way format-suffix tags already are. Always check whether your fix needs the same change in the giant-query parent path and add an e2e-07 assertion either way.

## Critical: {#ChartBucket} tag (v1.91+) — 4 resolution paths, 5 modifiers

`{#ChartBucket:relationship:field[:modifier1=value1&modifier2=value2&...]}body{/ChartBucket}` aggregates a child collection by `field`, exposing per-bucket data (`{key}`, `{count}`, `{percent}`, `{max_percent}`, `{color}`, `{index}`, `{key_label}`) inside the body. The bucket list is sorted desc by count, alpha by key for ties.

**Five modifiers** (composable; v1.91 surface):

| Modifier                                | Behavior                                                                                                                                                              |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `colors=#aaa,#bbb,#ccc`                 | Override default 8-color palette, cycles by row index                                                                                                                 |
| `where=Field='Value' AND Other != null` | Sanitized SOQL fragment appended to chart's WHERE. Forces SOQL fallback.                                                                                              |
| `split=;`                               | Multi-select delimiter. Splits combo values per respondent, percentages sum >100% expected.                                                                           |
| `groupBy=Field__c`                      | Cross-tab pivot. Each row gets `cols` sub-list with `{#cols}{key}{count}{percent}{/cols}` body iteration. Synthetic Total column appended last. Forces SOQL fallback. |
| `colSort=val1,val2,...`                 | Author-controlled column ordering (for `groupBy=`). Named values appear first in order; remaining values alpha-sorted; Total always last.                             |

**Four resolution paths** (chart resolver mirrors what merge-tags already do — all four must stay consistent):

1. **In-memory** — `DocGenChartBucketResolver.preprocessInline` against pre-loaded relationship records. Used when child count <2000 AND no `where=`/`groupBy=`. Single SOQL-free path, fastest.
2. **SOQL fallback** — `tryFallbackSoqlAggregateAdvanced` when relationship isn't on the data map OR `where=`/`groupBy=` force it. Schema-auto-discovers child object + FK via `ChildRelationship`. Issues a `GROUP BY` aggregate, constant-cost regardless of row count. **This is how 30K-scale templates work** — Query_Config\_\_c omits the chart-target relationship, retriever doesn't eager-load, chart aggregates server-side.
3. **Parent-level** — `DocGenGiantQueryAssembler.resolveParentMergeTags()` regex skips `{#…}` prefixes, so charts pass through. Then `processXmlForTest` routes through the inline path.
4. **Giant-query parent** — `DocGenGiantQueryAssembler.resolveGiantChartBuckets` for charts targeting the giant relationship in giant-query templates. Same modifiers, same shape.

**SOQL budget**: 50 chart aggregates per transaction (static `DocGenChartBucketResolver.chartSoqlBudget`). When exhausted, charts render a sentinel "Chart limit reached" bucket — never silently empty. Tune in resolver if templates pathologically stack >50 charts.

**Layout gotcha for `groupBy=` pivot**: HTML container auto-expansion at `DocGenService.processXml:2708` looks for the nearest open `<tr>` when processing nested `{#…}` loops — placing `{#cols}` directly inside `<tr>` causes each col to duplicate the whole row. Use `<div class="row">` + `display: table-row` instead (CSS 2.1 safe in Flying Saucer). See `docs/CommuteSurveyExample.html` for the canonical pattern.

**Reference templates**:

- `docs/SurveyChartExample.html` — single-dimension chart per question + cross-tab spread (rich pivot + vertical clustered bars + stacked composition) using Department dimension. Canonical chart template.
- `docs/CommuteSurveyExample.html` — pivot + filter + multi-select + colSort all composed
- `docs/SurveyChartExample.docx` — Word-authored variant, hand-built `{#ChartBucket}` bars.

### Charts render in EVERY format — pick by style, not by format

**Do not say "charts are HTML only." That is wrong**, and it contradicts how charts are actually authored (Word, PowerPoint and PDF all in active use). Two separate authoring surfaces, with opposite constraints:

1. **The `{Chart:}` tag → PNG-via-CV pipeline.** `DocGenChartRasterizer` emits real PNG bytes server-side; `DocGenChartImageController` gates on `Word` / `isHtmlBacked` / `PowerPoint`. `KNOWN_STYLES` = `bar, column, pie, donut, stacked, clustered, line, area`. **This is the path to recommend.**
2. **Hand-authored `{#ChartBucket}` loops building bars from table-cell widths.** Constrained in Word — `w:type="pct"` normalizes within the row, compressing dynamic range (45.9% vs 2.9% renders at ~6–9× instead of 15.8×), and `{#cols}` nesting conflicts with `<w:tr>` auto-expansion. This is what the old "steer to HTML" advice was about.

| Style                                    | Word / PPTX / XLSX | HTML → PDF | HTML in browser  |
| ---------------------------------------- | :----------------: | :--------: | :--------------: |
| `bar`                                    |        PNG         |  CSS-bar   |       yes        |
| `pivot`                                  |       **no**       | CSS table  |       yes        |
| `clustered`, `stacked`                   |        PNG         | CSS table  |       yes        |
| `column`, `pie`, `donut`, `line`, `area` |        PNG         |   **no**   | `htmlRender=svg` |

Two rules generate that table:

- **`pivot` never rasterizes** — not in `KNOWN_STYLES`, because a cross-tab is a table, not a chart shape. Cross-tab belongs in HTML.
- **Flying Saucer drops inline `<svg>` from `Blob.toPdf`.** `htmlRender=svg` looks right in a browser and vanishes in the PDF, so HTML→PDF templates must stay on CSS-bar styles (`bar`, `pivot`, `clustered`, `stacked`).

**This inverts the old guidance:** for rich chart shapes in a PDF, **Word is the better source**, because the PNG pipeline carries pie/donut/column/line/area that HTML→PDF cannot render at all. HTML is better for cross-tab.

The `{color_hex}` chart field exists so Word's `w:shd w:fill` attributes can use cycled palette colors (raw hex, no `#`).

## Critical: zero-heap PDF image rendering (don't accidentally regress)

For PDF output, `{%ImageField}` tags with ContentVersion IDs skip blob loading. `currentOutputFormat` is set to `'PDF'` before `processXml()` calls; in `buildImageXml()`, when `currentOutputFormat == 'PDF'` and value is `068xxx`, query only `Id, FileExtension` (NOT `VersionData`) and store the relative URL `/sfc/servlet.shepherd/version/download/<cvId>`. Image URLs in HTML for `Blob.toPdf()` MUST be relative — absolute URLs and data URIs render broken.

If your fix touches `processXml`, do not add `VersionData` to the PDF-path SOQL and do not prepend `URL.getOrgDomainUrl()` anywhere in the image pipeline.

## Package info

- Package: **Portwood**, Managed 2GP (id `0Hoal0000003d9hCAA`), namespace `portwoodglobal`. This is the package `sfdx-project.json` builds and what customers install. (A legacy Unlocked package `Portwood (Unlocked)` `0Hoal0000003TwjCAE` also exists in the Dev Hub but is NOT the release artifact.) **Managed-package consequence:** only `global` Apex is visible to subscribers — `public` classes/methods are invisible in subscriber orgs. An `@InvocableMethod` must be `global` to appear in a subscriber's Flow Builder; a Flow **Apex-Defined variable type** needs ALL of: (1) **top-level/standalone class** (Flow ignores inner/nested classes — the v2.7.0 lesson), (2) `global` class, (3) `@AuraEnabled` members, (4) `global` no-arg constructor. See [[feedback_flow_apexdefined_managed_pkg_recipe]].
- Current shipped version: **v3.56.0** (`04tVx0000010fnNIAQ`, build `3.56.0-5`) — chart label sizing made an explicit control (`fontSize=` on a chart tag, **Label size** on the Canvas chart), with title and other text scaling with it; plus **Bold** disabled for `'Arial Unicode MS'`, which has no bold face and was silently printing regular (#281). This is the ID the README's install link points at — keep the two in sync.
- Previous shipped version: **v3.55.0** (`04tVx0000010fXFIAY`, build `3.55.0-2`) — Canvas element linking (a block **follows** another and travels with it as the table above grows), named blocks, and charts as a Canvas element with live preview. PowerPoint and Excel now assemble in the browser like Word, lifting the 6 MB ceiling (tested to 30,000 child records), with Chart.js on that path.
- Previous shipped version: **v3.54.0** (`04tVx0000010Y4LIAU`, build `3.54.0-1`, promoted 2026-08-06, ancestor 3.53.0) — the **Canvas designer**, a new `Canvas` template type with a Canva-style artboard: pinned and flow boxes, tables with nested grandchild loops and totals, images from Portwood Assets via `{%asset:key:WIDTHx}`, shapes, QR/barcodes, signature placements, per-box `{#IF}` conditions, z-order, undo/redo and an HTML importer. Renders through the HTML path (`DocGenService.isHtmlBacked`), so output is always PDF. **The `Canvas` picklist value and everything around it are now frozen forever.** Shipped labelled Beta in the UI. Two notes for anyone touching it: `Blob.toPdf` only draws symbols/CJK under `'Arial Unicode MS'` (the generic families render them as nothing), and serializer fixes do NOT reach documents already saved — a stored body keeps its old markup until re-saved. 1,905 tests pass, 78% coverage.
- Previous shipped version: **v3.50.0** (`04tVx000000zxCrIAI`, build `3.50.0-1`, promoted 2026-07-31, ancestor 3.49.0) — the DocGen -> Portwood rename (PR #263). Display names only: labels, masterLabels, descriptions, user-visible strings. **Every API name is unchanged and frozen forever** — `DocGen_Template__c`, `DocGenService`, `DocGen_Admin`, the `portwoodglobal` namespace. Two scheduled job names deliberately keep the old string because they are matched by `CronJobDetail.Name` in orgs that already scheduled them: `DocGen Signature Reminders` and `DocGen Chart CV Reaper`. 1,890 tests pass, 78% coverage.
- Previous shipped version: **v2.9.0** (`04tVx000000a7fhIAA`, build `2.9.0-1`, promoted 2026-05-27) — Large-table repeating headers. Tight follow-up to v2.8 for giant-query PDFs, verified on a real customer short-codes `.docx` and 3,559 staging records. Adds Flying Saucer's table pagination CSS (`-fs-table-paginate: paginate` + `thead { display: table-header-group; }`) to snapshot-backed and HTML-backed giant-query tables so Word-authored headers repeat on every PDF page. Also forces `border-collapse: collapse` + `border-spacing: 0` and Word-style cell padding (`0pt 5.4pt`) so the repeated-header table keeps a continuous single-line frame rather than separated cell boxes. Fixes the Word edge case where both the visible header row and the merge-loop row carry `w:tblHeader`, causing the DOCX HTML snapshot to put the loop row inside `<thead>`; `replaceGiantLoopTableTail` now closes `<thead>` before generated rows. Validation: real-template proof = repeated orange header page 2+, continuous borders, 68-page PDF; e2e-01..08 + 07-syntax1..4 PASS/FAIL0; RunLocalTests 1470/100%/77%; `sf code-analyzer` 0; package build coverage 77%.
- Previous shipped version: **v2.8.0** (`04tVx000000a7e5IAA`, build `2.8.0-1`, promoted 2026-05-27) — Large-table rendering fidelity (PR #144). Three giant-query table fixes, all found + verified on a **real customer short-codes template** (~3,560-row `.docx`) generated through the giant path → 86-page PDF. (1) **Giant tables rendered ~50% width**: `DocGenGiantQueryAssembler` prepended its own `<colgroup>` on top of the snapshot's authored one → 2 colgroups = 2× columns = 200% width, packing cells into the left half (regression surfaced by the v2.5.0 chrome fix — before it, the empty-snapshot fallback gave a single-colgroup `width:100%` table). Fix: drop the duplicate; capture the snapshot's authored `<table>` tag + single colgroup and reuse them in every chunk-break table; `max-width:100%` clamp stops an authored absolute width clipping the last column. (2) **Footer = black box**: `processTable` collapsed borders into one `hasBorders` boolean + blanket `border:0.5pt solid #000` per cell — a top-rule-only footer became a full grid. Replaced with **per-side translation** (explicit `<w:tblBorders>` beats the named style; outer sides → `<table>`, `insideH/insideV` → cell grid lines in the authored color); new `addInteriorBorders` + public `resolveCellGridBorderCss`. (3) **Giant data rows used invented gray `#ccc`**: now carry a `gqc` class and inherit the authored grid border (scoped to data cells so it never leaks onto the running footer). `{RepeatHeader}` marker (pre-merge `applyRepeatHeaderMarkers` → Word `<w:tblHeader/>` → `<thead>`) groups the header for section-level repeat. **DEFERRED to a future release — true per-page header repeat on giant tables:** Flying Saucer's `-fs-table-paginate` is the only mechanism, works on clean content (78 pages at 3,559 rows, scales to 15K) but **mis-paginates the real metric/multi-running-element template to 8,258 pages**; metric→inch `@page` decimals (210mm→`8.26388…in`) are a contributing factor (~20%) but not the root. Validation: e2e-01..08 + 07-syntax1..4 PASS/FAIL0, RunLocalTests 1469/100%/77%, `sf code-analyzer` 0, real-template render confirmed (full-width every page, footer top-rule-only, no clipped columns, 86 pages).
- Previous shipped version: **v2.7.0** (`04tVx000000a1IXIAY`, build `2.7.0-2`, promoted 2026-05-26) — Flow `Signer` variable now selectable (PR #141). Completes v2.6.0's signature-Flow work. **Root cause v2.6.0 missed:** `DocGenSignatureFlowAction.Signer` is an **inner class**, and Flow does NOT expose inner/nested classes as Apex-Defined variable types — no `@AuraEnabled`/`global`/constructor on an inner class makes it appear (confirmed katiekodes.com/flow-apex-defined-data-types). Fix: new **standalone top-level** `DocGenSigner` (global + `@AuraEnabled` fields + `global` no-arg constructor) plus a new `signerRecords` (`List<DocGenSigner>`) input on the action labeled "Signers"; `buildSignerInputs` prefers it. Inner `Signer`/`signers` can't be removed (managed-pkg immutability) — relabeled legacy + `required` relaxed. **Full requirement set for a managed-package Apex-Defined Flow variable: (1) top-level/standalone class, (2) `global` class, (3) `@AuraEnabled` members, (4) `global` no-arg constructor** (see [[feedback_flow_apexdefined_managed_pkg_recipe]]). Took two prior misses (v2.6.0 `@AuraEnabled`; v2.7.0-1 `global` ctor — both on the inner class) because the managed visibility boundary can't be reproduced in a no-namespace staging org; must verify in a real subscriber install/scratch. Verified: `DocGenSigner` appears in a fresh subscriber scratch org and the action returns `success=true` (request + signers + tokens created). DocGenSignatureFlowActionTest 19/19, build coverage passed, `sf code-analyzer` 0.
- Previous shipped version: **v2.6.0** (`04tVx000000a037IAA`, build `2.6.0-2`) — Flow signature types + custom-signing helper visibility + text-box marker fix (PR #140). Three fixes, all surfaced installing v2.5.0 in the managed-package demobox; none a regression. (1) `DocGenSignatureFlowAction.Signer` gained `@AuraEnabled` on all four fields so the type is selectable as a Flow **Apex-Defined variable** — the "Portwood: Create Signature Request" action appeared but its `Signers` collection couldn't be built (`@AuraEnabled` was never present, back to v1.46 where `Signer` was introduced). (2) `DocGenSignatureValidator`/`DocGenSignatureSubmitter`/`DocGenSignatureFinalizer` (the UserGuide §11.8 custom-signing helpers) were `public` → invisible as subscriber Flow actions in a managed package; promoted classes+inner types+fields+methods to `global`. **Managed-package visibility rule** (now also in Package info above): only `global` Apex is subscriber-visible — an `@InvocableMethod` must be `global`; a Flow Apex-Defined variable type needs `global` + `@AuraEnabled` members. (3) `DocGenHtmlRenderer.unwrapTextboxes` used `lastIndexOf('<w:p', …)`, which prefix-matches `<w:pPr>`/`<w:pStyle>` — it landed mid-paragraph, split the `<w:p>`, and leaked the `__DGTXBX_OPEN|…__` text-box sentinel as visible text (collapsed running headers). Added `findEnclosingParagraphStart` (accepts only the real `<w:p>`/`<w:p `) + 2 regression tests. **Open follow-up:** a text box sharing its paragraph with other content (e.g. an inline image) still drops that sibling content — the whole paragraph is replaced by the marker. Validation: e2e-01..08 PASS/FAIL0, DocGenHtmlRendererTest 117/117 (+2 new), build coverage 76%, `sf code-analyzer` 0 violations.
- Previous shipped version: **v2.5.0** (`04tVx000000ZyyzIAC`, build `2.5.0-2`) — Large-dataset template chrome fix (P1 #134/#135). Templates over the ~2000-child-row giant-query threshold rendered ONLY their data rows — title, text-above-table, column headers, and footer all dropped. Root cause: `DocGenGiantQueryAssembler` read the internal `docgen_tmpl_html_<versionId>` snapshot `WITH USER_MODE`; that CV's ContentDocumentLink defaults to `Visibility=InternalUsers` (invisible under USER_MODE — the documented #114 quirk), so the read returned empty and the assembler silently fell back to a bare table built from Query_Config field names. It was the lone USER_MODE read in the class — switched to the FLS-guard + `WITH SYSTEM_MODE` hybrid used by every other internal-CV read here and in `DocGenController` (see [[feedback_internal_cv_reads_must_be_system_mode]]). Confirmed a **regression, NOT data volume and NOT v2.4.0**: the customer's working (3,553 rows, full chrome) and broken (3,552 rows, bare table) PDFs had the same dataset — both giant-query; a template re-save regenerated the snapshot with the InternalUsers visibility default. Beta `04tVx000000ZyxNIAS` (2.5.0-1, skip-validation) shipped first as a sandbox-installable working copy. Open follow-ups (#134, backlog): the giant-query path skips `processXml` so parent-level section/conditional/inverse tags and secondary child loops leak as raw text; and "Save to Record" on that path also downloads. Validation: e2e-01..08 PASS/FAIL0, DocGenGiantQueryTest 42/42 (new chrome-preservation regression test), build coverage 76%, `sf code-analyzer` 0 violations.
- Previous shipped version: **v2.4.0** (`04tVx000000ZyanIAC`, build `2.4.0-2`) — Multi-language runner + PowerPoint charts. Three customer-facing features: (1) **Runner i18n** (#95, #126) — the `docGenRunner` UI strings are now 12 Custom Labels (`DocGenRunner_*`) referenced via `@salesforce/label/c.*`, with translations for 10 languages (`es`, `ja`, `zh_CN`, `zh_TW`, `fr`, `de`, `pt_BR`, `it`, `ko`, `nl_NL`) in `force-app/main/default/translations/`. Native per-user (each user sees their own Salesforce Language; no custom picker — `@salesforce/label` can't be runtime-overridden without a parallel map). `docGenBulkRunner`/`docGenAdmin` extraction queued. (2) **PowerPoint charts** (#131) — `DocGenChartImageController.prepareChartImages`/`prepareChartImagesServerSide` no longer hard-return empty for non-Word/HTML; un-gated `PowerPoint` + new `loadActivePptxBody()` (concatenates pre-decomposed `…_ppt__slides__slideN.xml` parts). The `<p:pic>` embed (`postProcessPowerPointSlides`) was already built — only prep was missing. Known limitation (#130, backlog): chart tags split across runs by character formatting still text-fall-back (shared with Word). (3) **Merge error enrichment** (#115) — `processXml` errors now carry the offending tag, a snippet, and an HTML line number; `HeapPressureException` re-thrown ahead of the generic catch. **Build-pipeline note:** the 10 translations only deploy where Translation Workbench + the language are enabled. The Dev Hub package build copies an **org shape**, so a def with `edition` conflicts ("edition cannot be specified when copying an org's shape") and a default build org is English-only. Fix shipped: `config/build-def.json` (languageSettings, NO `edition` — the shape supplies it) wired via `packageDirectory.definitionFile`. Keep it for future translation releases. Staging validation needs a FRESH scratch org from the TWB-enabled `config/project-scratch-def.json` (#128). Validation: e2e-01..08 PASS/FAIL0, RunLocalTests 1415 methods / 0 fail / 76% org-wide, `sf code-analyzer` 0 violations.
- Previous shipped version: **v2.3.0** (`04tVx000000ZxDJIA0`, build `2.3.0-1`) — Guest-Aware FLS Reads (completion patch for v2.2). v2.2 swapped the 18 admin write-guards (`DocGenFlsGuard.assertUpdateable / assertCreateable`) to guest variants but left the 36 read-guards (`DocGenFlsGuard.assertAccessible`) as admin. Customers running v2.2.0 hit `Save failed: Insufficient FLS to read portwoodglobal__DocGen_Signer__c.Contact__c. Verify Portwood permission set assignment.` on the saveSignature step — the per-field FLS describe verdict throws for guest profiles on the SOQL select-list even though the permset grants read. v2.3.0 swaps 34 sites in `DocGenSignatureController.cls` + 2 sites in `DocGenAuthenticatorController.cls` (verifyDocument, verifyByRequestId) to `DocGenFlsGuard.guestAssertAccessible`. No new methods/classes/tests — reuses v2.2's helper. AppExchange impact: still v1.56 listed at the time of release; v2.x bundles are forward-prep per [[project_appexchange_voucher_pending]].
- Previous shipped version: **v2.2.0** (`04tVx000000ZxBhIAK`, build `2.2.0-2`) — Guest-Aware FLS Guards (signature flow hotfix). Adds `DocGenFlsGuard.guestAssertCreateable/guestAssertUpdateable/guestAssertAccessible` mirroring the v2.1.0 admin variants but bypassing the object-level + per-field FLS _verdict_ when `UserInfo.getUserType() == 'Guest'` (same shape as the existing `Test.isRunningTest()` bypass; the per-field `Schema.SObjectField.getDescribe().is*()` probe still fires for the Checkmarx pattern-match signal). 18 call sites in `DocGenSignatureController.cls` swapped from admin to guest variants (sendPin, verifyPin, validateSignerToken→Viewed, validateLegacyRequest, getOrCreatePublicLink, saveSignature, saveLegacySignature, stampLegacySignerAndSavePdf, saveSignedDocument, declineSignature, signPlacement). Fixes v2.1.0 regression where guest signers got `Failed to save: Insufficient access to update portwoodglobal__DocGen_Signature_Placement__c` on every write — DocGen_Guest_Signature permset grants allowRead-only by design (token-bound `Secure_Token__c` is the capability for guest writes, not perm-set Edit). Sender controller and Service queueables unchanged. v2.2.0-1 was built first but contained the pre-fix `DocGenMiscTests.testIssue114NoUserModeOnPreDecompCvLookups` over-broad assertion; v2.2.0-2 is the promoted build with the narrowed test (skips the admin delete-cleanup block at `DocGenController.cls:2822` where `WITH USER_MODE` is structurally correct). Test now passes. `sf code-analyzer`: 0 violations.
- Previous shipped version: **v2.1.0** (`04tVx000000Zw5xIAC`) — Per-Field FLS Guards release. Adds `DocGenFlsGuard.cls` with `assertCreateable/assertUpdateable/assertAccessible(SObject|SObjectType, Set<String> fieldAllowlist)` — calls `Schema.SObjectField.getDescribe().is{Createable,Updateable,Accessible}()` per field before every admin DML / `WITH SYSTEM_MODE` SOQL. 243 guard call sites across 19 controllers. Implements the second half of the v1.56 review's finding-resolution language ("enforce CRUD checks on the object AND FLS checks on the fields"). `Test.isRunningTest()` bypass on the per-field verdict (object-level CRUD and field-existence check still fire) — matches platform behavior where USER_MODE is lenient in test contexts; documented inline at each bypass. Closes the 222 FLS Create/Update + 340 USER_MODE Missing Checkmarx findings. `sf code-analyzer`: 0 Critical / 0 High / 0 Moderate after disabling pmd:ProtectSensitiveData + pmd:AvoidLwcBubblesComposedTrue (documented false positives in code-analyzer.yml). Packaged as v2.1.0 because patch versioning is disabled on the namespace (see [[project_patch_versioning_disabled]]). Build attempts: 3 (attempts 1 + 2 failed on the namespaced-field-map and FLS-propagation issues respectively, both fixed and documented in DocGenFlsGuard.cls).
- Previous shipped version: **v2.0.0** (`04tVx000000ZqBpIAK`) — Security Hardening for AppExchange resubmission. 4 clickjacking LWC fixes; CRUD/FLS hybrid pattern (Schema CRUD gate + SYSTEM_MODE); new `DocGenSignatureGuestSecurity.cls`; verifyDocument returns ALL signers for multi-signer docs. See `CHANGELOG.md` for per-finding mapping (the standalone `SECURITY_REVIEW_RESPONSE_v2.md` now lives only in the local-only `docs/appexchange/` bundle).
- DevHub: `Portwood Global - Production` (dave@portwoodglobalsolutions.com)
- Staging org for release validation: `portwood-staging` — must be created with `--no-namespace` so source-deploy lands in the default namespace and the e2e scripts' bare class/field references compile. Assign `DocGen_Admin` permset to the running user immediately after deploy or field-level security blocks the e2e scripts.
- Dev scratch: `docgen-designer`

### Package version descriptions must be CONSUMER-friendly

The `versionDescription` field in `sfdx-project.json` (and what shows up in the AppExchange listing + install dialog) is read by **end users / customers** evaluating the package, not by engineers. Write it like marketing copy, not engineering notes. The `versionName` ("v2.1.0 — Per-Field FLS Guards (DocGenFlsGuard)") is internal-facing; the `versionDescription` is customer-facing.

**Bad** (engineering jargon — what shipped in v2.1.0-1):

> v2.1.0 adds DocGenFlsGuard — per-field Schema.SObjectField.getDescribe().isAccessible/isCreateable/isUpdateable() checks at every admin DML and WITH SYSTEM_MODE SOQL site (243 guard call sites across 19 controllers). Implements the AppExchange v1.56 review's stated finding-resolution: 'enforce CRUD checks on the object and FLS checks on the fields...'

**Good** (consumer-friendly):

> Portwood generates PDFs and Word documents from any Salesforce record. v2.1 strengthens permission enforcement so users only see and modify the fields their permission set grants. 100% native Salesforce — no external services or callouts. Free for all users.

The detailed engineering-language belongs in `CHANGELOG.md` (and the local-only `docs/appexchange/` bundle), not in the package metadata customers see at install time.

## Release validation checklist

All three checks MUST pass before release. No exceptions.

**The one-command version** (runs every suite and writes `scripts/qa/report/qa-report.md`, exit 0 only when everything evaluated passed):

```bash
npm run qa                  # against docgen-verify
npm run qa -- --offline     # only suites needing no org — CI-safe
```

A suite that cannot run reports as **skipped**, not passed — check the report, not just the exit code. The explicit sequences below are what the harness runs, and what to fall back on when diagnosing a single failure. See the `run-tests` skill.

### 1. E2E test suite

```bash
sf apex run --target-org <org> -f scripts/e2e-01-permissions.apex
sf apex run --target-org <org> -f scripts/e2e-02-template-crud.apex
sf apex run --target-org <org> -f scripts/e2e-03-generate-pdf.apex
sf apex run --target-org <org> -f scripts/e2e-03b-page-setup.apex
sf apex run --target-org <org> -f scripts/e2e-04-generate-docx.apex
sf apex run --target-org <org> -f scripts/e2e-05-generate-bulk.apex
sf apex run --target-org <org> -f scripts/e2e-06-signatures.apex
sf apex run --target-org <org> -f scripts/e2e-06b-signature-lifecycle.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax1.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax2.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax3.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax4.apex
sf apex run --target-org <org> -f scripts/e2e-07-syntax5.apex
sf apex run --target-org <org> -f scripts/e2e-08-cleanup.apex
```

Each script must print `PASS: N  FAIL: 0  ALL TESTS PASSED`. Sequence: 01 standalone, 02 creates test data, 03/03b–06b depend on 02, 07-syntax1/2/3/4/5 standalone (use `processXmlForTest`), 08 cleans up. **syntax1–4 are all within a few hundred characters of the Anonymous Apex ceiling** — put new parser assertions in syntax5 (or a new syntax6) rather than growing them. **03b is split out of 03** because each full `generateDocument` costs ~10 SOQL and the combined generations exceeded the 100-SOQL synchronous limit in one anonymous transaction — a governor-limit throw prints NO summary line, so watch for a script that emits no `PASS: N` at all, not just a non-zero FAIL. Note for new scripts: anonymous Apex cannot catch a thrown `AuraHandledException` (uncatchable LimitException) — negative-path assertions on `@AuraEnabled` guard methods belong in unit tests, not e2e.

When fixing a parser-level bug, add a regression assertion in `e2e-07-syntax1` or `e2e-07-syntax2` that exercises the offending pattern via `processXmlForTest`. Each script must stay under 18,000 chars (Anonymous Apex limit is 20,000).

### 2. Apex test suite

```bash
sf apex run test --target-org <org> --test-level RunLocalTests --wait 15 --code-coverage
```

Expected: `Outcome: Passed`, `Pass Rate: 100%`, org-wide coverage ≥ 75%.

### 3. Code Analyzer

```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```

Expected: `0 High severity violation(s) found`. ~30 Moderate false positives are acceptable (see `code-analyzer.yml`).

## Pre-commit: prettier (CI gate)

CI runs `npm run format:check` (prettier) on every PR; a failure blocks merge. Run before pushing:

```bash
npm install   # one-time, adds prettier to node_modules/.bin
npm run format        # auto-fix
npm run format:check  # verify clean
```

Covers `force-app/**/*.{cls,trigger,page,component,cmp,html,js,xml}`, `scripts/**/*.apex`, and root `*.{json,md,yml,yaml}`. Apex scripts under `/scripts/` are formatted too — long string concatenations get reflowed, so don't fight the wrap.

## Subsystem caution

Several subsystems are tightly coupled and easy to break with surgical fixes — reach for `git log -- CLAUDE.md` and `git show 6a2deff^:CLAUDE.md` to recover the deeper historical notes if you're touching:

- **Signatures (especially v3 packets / multi-template)** — three hand-rolled loops, no content-correctness tests, two divergent creation paths. Read the `project_signature_v3_fragility.md` memory before changing anything here.
- **Client-side DOCX assembly** (`docGenZipWriter.js`) — splits work between server (XML merge) and browser (ZIP repack). The boundary is load-bearing; don't move work across it lightly.
- **HTML templates and `Blob.toPdf` rendering** — Flying Saucer is essentially **CSS 2.1** plus a small CSS 3 subset. `display: flex`/`grid`, `gap`, `linear-gradient(...)`, `calc(...)`, CSS variables, and most CSS 3 layout features are silently ignored — the page renders but layout collapses to default block flow. When troubleshooting "the PDF looks wrong," first check whether the source HTML uses any of these and rewrite to `<table>`-based layout + solid colors. Also: when both the engine `<style>` (built from `Page_Size__c`/`Page_Orientation__c`/`Custom_Margins__c` template fields) and the source HTML's own `<style>` declare `@page`, you get a conflict — recommend authors clear the template page fields when their source CSS already specifies `@page`. Issues #60 and #71 both live here.
- **Query Config formats** (V1 flat string, V3 node tree) — V3's `processChildNodes` and V1's `stitchGrandchildren` reproduce similar patterns; bug fixes often need to land in both (see #67).
- **Watermarks, font handling, command hub** — light traffic, but the test coverage is sparse, so verify visually after edits.
- **Visual Designer DOM under LWS namespace sandbox** (`docGenAdmin.js`) — in a managed-package install (NOT development), Lightning Web Security's per-namespace sandbox distorts DOM nodes the browser's native `contenteditable` inserts. Two facets bit us: `ChildNode.replaceWith` is missing on proxied nodes (v3.39, fixed with `_safeReplace`), and `cloneNode(true)` silently omits browser-inserted nodes (v3.41 — new paragraphs/blocks vanished on Save/Source; fixed by serializing from the canvas's live `innerHTML` STRING via `_extractVisualBody`, never a cloned node tree). Rule: to read the canvas back to HTML, go through the `innerHTML` string + a `<template>` parse (as the upload path already does), never `cloneNode`/`replaceWith` on the live distorted tree. This class of bug is invisible in dev/scratch orgs — only a namespaced package-install (or namespaced scratch org) reproduces it.

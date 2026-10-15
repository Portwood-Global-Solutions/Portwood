# Drawing Approval — Sign Against Existing Record PDFs — Plan

> **Branch:** `feat/drawing-pdf-merge` (off `main` @ v3.57.0, `62183ca`) for the plan; M1 is built on `feat/412-drawing-approval` (stacked on #423's `fix/413-signing-page-device-resolution`).
> **Status:** M1 BUILT on the fork (2026-10-01), ahead of the maintainer's decisions, and opened as draft PR #440. The maintainer answered §8 on #412 (2026-10-07); §6.2 maps each answer to the build, which now follows them. Successor to closed PR #197 (`exp/document-markup`, closed as dormant 2026-08-10).
> **Related:** #405 (template-defined supplemental PDFs — same concept, generation only), #407 (guided page fails open to the server re-render), #413 (signing page renders below screen resolution; no zoom), #373 / #404 (sender UI work in flight).
> **How to use this doc:** decisions in §4 are _proposed_ until the RFC is agreed. Work milestones in order; tick boxes and leave a one-line note on anything that changes.

---

## 1. Use case

A record carries one or more **existing PDFs** — engineering drawings (A1 and A3, landscape, AutoCAD / SOLIDWORKS / Adobe exports). We want to send them to an **external customer via the normal emailed signing link** so the customer can **approve (sign) or decline (with reason)**. A later milestone (M2) lets the customer **redline** the drawings.

Two shapes, both required (measured on a real issue set, §5.2):

- **Many single-sheet files per approval.** Document control on CDE-managed projects (high-rise, rail) forbids multi-page PDFs, so one approval can cover **dozens** of ~1 MB single-sheet files (sample: 14 × A1).
- **Large multi-page files.** Elsewhere a drawing set is one PDF — samples up to **~16 MB** and **14 × A1** pages in one file.

Constraints from the use case:

- Signers are **guests** on the Portwood Site — every byte they see or return goes through token-gated Apex.
- The send must work from **Flow** as well as the Signature Sender LWC (the process will be automated).
- The approval must identify **exactly which drawing revision** was approved.

## 2. What exists today (v3.57.0)

| Capability                                 | State                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sign a bare, pre-existing PDF              | **Removed in v3.18, deliberately.** `createRequestFromContentVersion` throws (`DocGenSignatureSenderController.cls:882-895`); `DocGenSignaturePdfFlowAction` ignores `contentVersionId`. This plan does **not** revive it — a signature-tagged template is always required.                                                                                                       |
| Generate a template + append record PDFs   | **Runner only**, "Combine with existing PDFs on this record" (`docGenRunner.js` `_generateMergedPdf` ~`:1291-1320`). Template always first; download or save; not Flow; not signing.                                                                                                                                                                                              |
| Include record PDFs in a signature request | **Not possible.** Every send path renders the signing document from a template (`createGuidedPdfSignatureRequest`, `DocGenSignatureSenderController.cls:1449`; viewing PDF `Blob.toPdf` at `:1606`, stored as `Source_Document_Id__c` at `:1619`).                                                                                                                                |
| Signature placement                        | Text anchors — `@@SIG-n@@` sentinels found in the PDF.js text layer on **any page** (`DocGenSignaturePdf.page` `locateAnchors` `:1125`, `hitToPdfRect` `:1203`). Placements store no page number. **Extra pages don't break placement.**                                                                                                                                          |
| Finalize (normal path)                     | Client-side pdf-lib composite onto the stored source bytes (`compositeAndFinalize` `:2150`) → `saveCompositedSignedPdf` (`DocGenSignatureController.cls:2692`) stores it as-is. Final hash = SHA-256 of the uploaded bytes.                                                                                                                                                       |
| Finalize (fallback)                        | If the signer has no session marks or the source didn't load, the page calls `saveSignature` (`DocGenSignaturePdf.page` ~`:3173`) → `TemplateSignaturePdfQueueable` **re-renders from the template** (`DocGenSignatureService.cls:1486`, `:1791`). Anything not from the template is dropped. See #407.                                                                           |
| Decline                                    | `declineSignature` (`DocGenSignatureController.cls:1826`) — reason text, status Declined, **no document produced**. Can be hidden org-wide (`Signature_Hide_Decline__c`) or per template (`Hide_Signer_Decline__c`); enforced server-side (#367).                                                                                                                                 |
| Signer form fields                         | text / number / date / checkbox / picklist, written back to the record at completion (`DocGenFieldWritebackService`). Future vehicle for richer outcomes (e.g. "approved as noted").                                                                                                                                                                                              |
| Guest file access                          | Guests can't use `/sfc/servlet.shepherd/` URLs (`DocGenSignatureController.cls:2199`); files reach the page as base64 through token-gated remote actions. The legacy path creates a view-only `ContentDistribution` preview (`getOrCreatePublicLink`, `:844`). No `@RestResource` exists in the package.                                                                          |
| PDF libraries                              | `pdflib` static resource (pdf-lib 1.17.1) — already loaded by the signing page (`DocGenSignaturePdf.page:23`). `pdfjs4` (PDF.js 4.7.76) for rendering. The Runner's `docGenPdfMerger.js` is a regex byte-scanner (no object streams, no inherited `/Rotate`/`/CropBox`) — **not suitable for CAD/scanner PDFs**. `DocGenPdfMerger.cls` is Portwood-output-only by its own header. |

## 3. Constraints that shape the design

### 3.1 Size — the dominant constraint

**Measured** (§5.1, §5.2) as an anonymous guest on the Site. Existing endpoints first, then two candidate transports (throwaway spike code, not in this branch):

| Path                                                                | Works up to                          | Fails at | Binding limit                                                     |
| ------------------------------------------------------------------- | ------------------------------------ | -------- | ----------------------------------------------------------------- |
| Existing download `getSourcePdfBase64` (one remote action)          | **5.5 MB** / file                    | 5.75 MB  | VF remoting **response** cap — "exceeded maximum of 15 MB"        |
| Existing upload `saveCompositedSignedPdf` (one remote action)       | **2.95 MB** / call                   | 3.0 MB   | VF remoting **request** cap (~4 MiB of base64) — "Input too long" |
| Candidate T2 — chunked remote-action download (4 MB aligned slices) | **15.85 MB** tested (4 calls, 5.1 s) | —        | none hit; each call re-loads + re-encodes the whole file          |
| Candidate T3 — guest `@RestResource`, raw binary GET                | **15.85 MB** tested (1 call, 1.3 s)  | —        | none hit                                                          |
| Candidate T3 — guest `@RestResource`, raw binary POST               | **16 MB** tested (1 call, 4.0 s)     | —        | none hit                                                          |

**Apex heap is not enforced on these paths in practice.** Documented synchronous heap is 6 MB; measured `Limits.getHeapSize()` reached **38.8 MB** in synchronous Apex (15.85 MB `VersionData` + base64) and **21–42 MB per call** in guest chunked downloads, with no exception. The existing `getSourcePdfBase64` already relies on this for any source above ~2.5 MB. T3 has the smallest footprint (GET ≈ 1× file; POST body not counted — ~7.5 KB). This is undocumented platform behaviour — see Q8.

Consequences:

- **Real drawings exceed the existing single-call download** (6.7, 13 and 16 MB samples) — M1 needs T2 or T3.
- **Upload stays the tight direction for remote actions** (2.95 MB). A single combined signed PDF is not viable over remoting — this drives D1. T3 removes the upload limit, which is what M2 needs.
- `ContentDistribution` download URLs are **CORS-blocked** from the Site page (opaque response), so public links are not a transport for page script.

### 3.2 Other constraints

- **No browser at send time for Flow.** Apex can't merge third-party PDFs, so any combining happens in the **signer's** browser — or not at all (D2).
- **Heavy drawings.** A 14 × A1 AutoCAD file with ~9,200 embedded image tiles takes pdf-lib 2.5 s to load and 8.7 s to copy on a desktop, and PDF.js ~9.5 s **per page** to render (§5.3). Merging dozens of drawings in a phone browser is not viable; rendering needs placeholders and a bounded number of live pages.
- **Legibility.** The signing viewer draws pages at fit-to-width in CSS pixels, ignoring `devicePixelRatio`, with no zoom (#413). At fit-to-width an A1 sheet gets 0.4–1.2 px/mm and an A3 sheet 0.8–2.5 px/mm — drawing text is unreadable. **Zoom that re-renders is an M1 requirement**, not a nice-to-have: a signer can't approve what they can't read.
- **Fallback re-render** (§2) silently loses non-template pages; the page currently fails open (#407).
- **Integrity:** nothing hashes the viewing PDF at send today. An approval must bind the exact drawing revisions.
- **Decline can be hidden** (#367) — an approval request without Decline is only half a sign-off.
- **Managed package rules** (`.claude/skills/managed-package-rules`): new Flow inputs must be `global`; API names are forever; guest `SYSTEM_MODE` reads must be token-keyed; verify in a namespaced org.

## 4. Proposed design decisions (pending RFC)

| #   | Decision                      | Proposal                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| --- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Signed output                 | **Approval record**: the template pages + signatures + certificate, where the certificate **lists every attached document** (title, version, SHA-256). The drawings stay on the record untouched. The upload stays small regardless of drawing count or size. A combined "approved pack" is not proposed.                                                                                                                                                                                             |
| D2  | Display                       | **No merge.** The signing page shows the template and each drawing as **separate documents in sequence** with an index ("Drawing 3 of 14"); each drawing is fetched and rendered **when opened**, pages rendered lazily. **Zoom re-renders** the visible page at `zoom × devicePixelRatio` (builds on the #413 fix); at high zoom only the visible region is rendered (canvas caps, e.g. iOS ~16.7 MP). Signatures are stamped onto the template bytes as today. pdf-lib merging is not needed in M1. |
| D3  | Transport                     | **Per file, token + index.** Recommended: **T3** — one token-gated guest `@RestResource` (raw binary GET now, POST in M2); one call per drawing, smallest heap. Fallback if a guest REST surface is unacceptable: **T2** chunked remote actions (download only). Send-time caps: per attachment (proposed 20 MB) and per request (proposed 100 files) — to agree.                                                                                                                                     |
| D4  | Identity of what was approved | Pin each attachment by **ContentVersion Id** (`VersionData` is immutable per version) + **SHA-256** computed server-side. Browser re-checks the hash on fetch (defence in depth — the measured browser hash matched the server's).                                                                                                                                                                                                                                                                    |
| D5  | Entry points                  | Signature Sender LWC **and** the Flow action "Portwood: Create Signature Request" take the same thing: an ordered list of file Ids + position (before/after template).                                                                                                                                                                                                                                                                                                                                |
| D6  | Failure mode                  | **Fail closed.** If any attachment can't be fetched or verified, signing is blocked with an actionable message. Both certificate builders (client and server) list the attachments, so even the fallback path produces a record that binds them.                                                                                                                                                                                                                                                      |
| D7  | Scope                         | Single-template requests only in M1. No markup, no packets, no generation-only supplemental PDFs (that's #405 — share the data model and naming with it).                                                                                                                                                                                                                                                                                                                                             |

### 4.1 Data model (proposed — naming to agree with #405)

New child object, working name `DocGen_Signature_Attachment__c` (master-detail → `DocGen_Signature_Request__c`):

| Field                    | Type      | Notes                                 |
| ------------------------ | --------- | ------------------------------------- |
| `Content_Version_Id__c`  | Text(18)  | Pinned version                        |
| `Content_Document_Id__c` | Text(18)  | For display / linking                 |
| `Title__c`               | Text(255) | Snapshot of file title at send        |
| `Version_Number__c`      | Text(20)  | Snapshot of `VersionNumber`           |
| `File_Size__c`           | Number    | Bytes                                 |
| `Sha256__c`              | Text(64)  | Server-computed                       |
| `Position__c`            | Picklist  | `Before` / `After` the template pages |
| `Sort_Order__c`          | Number    |                                       |

A child object (rather than a JSON field on the request) gives FLS, queryability, per-attachment status, dozens of rows without a field-length ceiling, and room for M2 (per-drawing markup output) without reshaping.

### 4.2 Flow of a request

1. **Send** (LWC or Flow) → `createGuidedPdfSignatureRequest` (options/overload TBD) validates each file in `USER_MODE`: sender can read it, it's a PDF, it's **linked to the related record**, size ≤ cap, count ≤ cap. Resolves ContentDocument → latest ContentVersion and pins it, computes SHA-256, inserts attachment rows. Everything else (template render, placements, signers, emails, expiry, verification) is unchanged — single-phase send, no Draft orphans.
2. **Signer opens the link** → init response includes an attachment **manifest** (index, title, version, size, position, sha256 — no record Ids). The page loads the template viewing PDF (existing) and shows the drawing index; each drawing is fetched by **token + index** when opened (server resolves the CV from the request — never client-supplied), hash-checked, and rendered page by page. Anchors are located on the template pages as today.
3. **Approve** → `compositeAndFinalize` stamps onto the template bytes; `addCertificatePage` lists the attachments (multi-page when there are dozens); `saveCompositedSignedPdf` stores the approval record on the related record (unchanged).
4. **Decline** → existing `declineSignature` with reason (unchanged).

## 5. M0 — Spike

Goal: replace estimates with measurements and de-risk real drawings.

- [x] **Samples:** a real issue set — 19 files, 0.5–15.85 MB, A1 + A3, AutoCAD / SOLIDWORKS / Adobe PDF Library. None encrypted, rotated or using object streams; all load in pdf-lib (§5.2). _Still wanted: a scanned drawing._
- [x] **Transport ceilings** — existing endpoints (§5.1), T2 and T3 (§5.2).
- [x] **Merge-for-display:** measured too heavy for large sets (§3.2) → replaced by the per-drawing viewer (D2).
- [x] **Viewer:** PDF.js from the signing page on the real sets, desktop and phone widths, DPR 1 and 3 (§5.3) → zoom-with-re-render required; render cost is content-bound. _Still wanted: timings on a real mid-range phone (the measurements are from a 22-core desktop)._
- [ ] Sender-side SHA-256 at send for a request with many / large files (sync vs a Queueable per file). A single 15.85 MB SHA-256 in synchronous Apex succeeded (§5.2).

### 5.1 M0 results — existing endpoints (2026-09-23)

**Method.** Scratch org built by `scripts/qa/setup-org.sh` conventions (`--no-namespace`; a `portwoodglobal`-namespaced org needs the project Dev Hub — remoting and heap limits are namespace-independent), full `force-app` deploy, a classic Salesforce Site serving `DocGenSignaturePdf` with `DocGen_Guest_Signature` on its guest user. Test files: valid PDFs padded with random (incompressible) bytes to exact sizes, plus a real 4.69 MB drawing, attached to an Account. One `DocGen_Signature_Request__c` + `DocGen_Signer__c` per file with `Source_Document_Id__c` = that file. From an anonymous browser session on the Site, the real `getSourcePdfBase64` and `saveCompositedSignedPdf` were invoked via `Visualforce.remoting.Manager.invokeAction` (`buffer:false`, 120 s timeout).

| File size (MB)     | Download `getSourcePdfBase64` | Upload `saveCompositedSignedPdf` |
| ------------------ | ----------------------------- | -------------------------------- |
| 1                  | OK — 412 ms                   | OK — 3,309 ms                    |
| 2                  | OK — 517 ms                   | OK — 2,515 ms                    |
| 2.5                | OK — 612 ms                   | OK — 2,067 ms                    |
| 2.75 / 2.85 / 2.95 | —                             | OK — 1,862 / 1,654 / 1,615 ms    |
| 3                  | OK — 762 ms                   | **fail**                         |
| 3.5 / 4            | OK — 718 / 718 ms             | **fail**                         |
| 4.69 (real CAD)    | OK — 921 ms                   | —                                |
| 5                  | OK — 923 ms                   | **fail**                         |
| 5.25 / 5.5         | OK — 1,777 / 1,030 ms         | **fail** (5.5)                   |
| 5.75 / 6           | **fail**                      | **fail** (6)                     |
| 7 / 8              | —                             | **fail**                         |

- Download failures: `Remoting response size exceeded maximum of 15 MB.`
- Upload failures: `Input too long. [1, 149]` — rejected by the platform before Apex runs (signer/request left untouched). 2.95 MB = 4,124,400 base64 chars passed; 3.0 MB = 4,194,304 chars failed.
- Every successful upload was verified server-side: a full-size file on the related record and the request `Signed`.

### 5.2 M0 results — real drawings and candidate transports (2026-09-23)

**Real issue set** (analysed with the package's `pdflib` resource in Node):

| Shape                                   | Files | Size                      | Notes                                                                                                                    |
| --------------------------------------- | ----- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| CDE single-sheet set, A1, Adobe PDF Lib | 14    | 0.58–0.93 MB (11.3 total) | One approval covers all 14. Trivial per file.                                                                            |
| Multi-page AutoCAD, 14 × A1             | 1     | 12.95 MB                  | ~9,200 embedded image tiles + 6 MB of vector content; pdf-lib load 2.5 s, copy 8.7 s.                                    |
| Single-sheet AutoCAD, A3                | 1     | 6.74 MB                   | Dense vector linework (6 MB of content streams).                                                                         |
| Multi-page SOLIDWORKS, 5 × A3           | 1     | 15.85 MB                  | Two lossless ~4,300 × 3,500 renders = 15 MB — an export-setting issue (shaded views), being reviewed by the design team. |
| Others (AutoCAD / SOLIDWORKS, A3)       | 3     | 0.51–1.80 MB              | —                                                                                                                        |

**Transports** — throwaway spike classes deployed to the scratch org only (key-gated, not in this branch), called from an anonymous session on the Site:

| File     | T2 chunked remote action (4 MB slices) | T3 guest REST GET (binary) |
| -------- | -------------------------------------- | -------------------------- |
| 6.74 MB  | 2 calls, 1.7 s, heap 21 MB/call        | 1 call, 0.5 s, heap 7 MB   |
| 12.95 MB | 4 calls, 4.6 s, heap 36 MB/call        | 1 call, 0.8 s, heap 13 MB  |
| 15.85 MB | 4 calls, 5.1 s, heap 42 MB/call        | 1 call, 1.3 s, heap 16 MB  |

- T3 POST (raw binary upload): 3 / 5 / 8 / 12 / 16 MB all stored **byte-exact** on the related record; 1.4–4.0 s; heap ~7.5 KB.
- Integrity: browser-computed SHA-256 of every reassembled / downloaded file matched the server's SHA-256 of the original.
- Synchronous Apex: loading 15.85 MB `VersionData`, SHA-256 and base64 reached 38.8 MB heap with no exception.
- A `ContentDistribution` `ContentDownloadUrl` fetched from the Site page: `TypeError: Failed to fetch` (CORS); `no-cors` gives an opaque response.

### 5.3 M0 results — viewer (2026-09-23)

**Method.** The signing page's own PDF.js build (`pdfjs4`, loaded from the page's `MODULE_URL`) on the Site, files fetched via the T3 spike endpoint, each page rendered with the page's `fitScale` rule (`min(1.6, (containerWidth − 28) / pageWidth)`, floor 320 px) at the stated device-pixel ratio. `intent: 'print'` was used because the hidden Browser pane pauses `requestAnimationFrame` (display-intent renders stall while hidden). Hardware: a 22-core desktop — phones will be slower.

| Set                     | View / DPR  | Canvas width | px per mm | First page | All pages | Slowest page | Canvas memory if all kept |
| ----------------------- | ----------- | ------------ | --------- | ---------- | --------- | ------------ | ------------------------- |
| A3 CAD, 6 pp, 4.69 MB   | desktop / 1 | 798          | 1.9       | 1.2 s      | 2.7 s     | 1.1 s        | 10 MB                     |
| A1 CAD, 14 pp, 12.95 MB | desktop / 1 | 798          | 0.9       | 9.3 s      | 24.8 s    | 9.2 s        | 24 MB                     |
| CDE set, 14 × A1 single | desktop / 1 | 798          | 0.9       | 1.3 s      | 18.4 s    | 1.4 s        | 24 MB                     |
| A3 CAD, 6 pp            | phone / 1   | 347          | 0.8       | 1.5 s      | 3.1 s     | 1.4 s        | 2 MB                      |
| A1 CAD, 14 pp           | phone / 1   | 347          | 0.4       | 10.7 s     | 30.2 s    | 10.6 s       | 5 MB                      |
| CDE set, 14 × A1 single | phone / 1   | 347          | 0.4       | 1.3 s      | 17.5 s    | 1.2 s        | 5 MB                      |
| A3 CAD, 6 pp            | phone / 3   | 1041         | 2.5       | 1.2 s      | 2.7 s     | 1.1 s        | 18 MB                     |
| A1 CAD, 14 pp           | phone / 3   | 1041         | 1.2       | 9.7 s      | 27.2 s    | 9.5 s        | 41 MB                     |
| CDE set, 14 × A1 single | phone / 3   | 1041         | 1.2       | 1.4 s      | 15.8 s    | 1.3 s        | 41 MB                     |

- **Render time is content-bound, not pixel-bound:** tripling DPR (9× pixels) did not slow any set. Sharp rendering costs memory, not time.
- **Real signing page, phone emulation (Pixel 8, DPR 2):** page-1 canvas backing 320 × 226 in a 320 × 226 CSS box = 640 × 452 physical px → 0.5 backing px per physical px (#413).
- Rough legibility target for 2.5 mm drawing text: ≥ 5 px/mm → an A1 page ≈ 4,200 px wide ≈ 12.5 MP (~50 MB RGBA) — so deep zoom must render the visible region only.

## 6. M1 — Attach record PDFs to a signature request (one PR, after RFC agreement)

### Backend

- [x] `DocGen_Signature_Attachment__c` + fields, plus `DocGen_Signer_Attachment__c` (per-signer review row: `Fetched_At__c`, `Viewed_At__c`; the M2 markup hangs off it). Permission sets: Admin full, User create/read, **guest no object access** (class access to the REST endpoint only).
- [x] Send: new `@AuraEnabled createGuidedPdfSignatureRequestV2(GuidedPdfSendOptions)` beside the unchanged 11-arg canonical (an options object, per the maintainer's Q4 answer; replaces the 13-arg `…WithAttachments` first built). Both, and the Flow action, run `sendGuidedPdfRequest(options)`. Validation per §4.2 runs **before** the merge and any DML. Limits per org in Signature Settings: 20 MB / 100 files / 200 MB total by default. A send with attachments is refused while Decline is hidden. SHA-256 **on first serve**, not at send (see §6.1).
- [x] Flow: `attachedDocumentIds` + `attachedDocumentPosition` on `DocGenSignatureFlowAction.Request`. Attachment errors are `DocGenException`, so the action returns `success=false` instead of faulting the interview. _Namespaced-org check still to do._
- [x] Guest: `attachmentCount` on init; the manifest comes from a separate PIN-gated `getAttachmentManifest`, so titles never show before verification. T3 `DocGenSignatureAttachmentRest` (`GET /signature-attachment?index=N`, token in an `X-Portwood-Token` header, never the URL), with the same gates as the signing endpoints plus pinned-version checks. `no-store` and `nosniff` headers.
- [x] ~~Server-path certificate lists attachments~~. **Changed:** the server re-render fallbacks (`saveSignature`, `savePdfSignature`, legacy request-token stamp) **refuse** requests with attachments, so only the client composite (which draws the register) can finalize them. Fail closed instead of a second register builder.
- [x] Fail-closed coordination with #407: #407 shipped in v3.58. The new gates sit after its placement gate in each finalize method.

### Signing page (`DocGenSignaturePdf.page`)

- [x] Multi-document viewer: a document switcher (prev / list / next) with ticks, and a separate attachment pane. Each drawing is fetched on open with a progress bar, SHA-256 checked in the browser against the server's header, and rendered page by page; switching away frees its canvases and PDF.js document. The signing document keeps its own page set, so anchors and stamping are untouched.
- [x] **Attachment pane runs on PDF.js's viewer component** (`pdf_viewer.js` from the same `pdfjs-dist@4.7.76` legacy build; added 2026-10-02). It replaces a hand-rolled renderer, and gives:
    - lazy rendering of the pages in view, with a bounded canvas cache;
    - device-resolution output, capped at 16.7 MP;
    - `updateScale` zoom around a point, with a CSS preview and then a sharp redraw.

    Portwood adds the input layer PDF.js leaves to the app:
    - mouse drag-to-pan;
    - Ctrl/⌘+wheel and trackpad pinch (continuous; wheel notches step 1.25×);
    - two-finger touch pinch, with `touch-action: pan-x pan-y` so the page itself doesn't zoom;
    -   - / − / Fit buttons.

    Verified on the dev box: zoom stays anchored under the pointer (≤ 0.1% drift once zoomed); a 14-page A1 set renders only the pages in view; jumping to page 9 draws 9–10 without 3–8. Text layer, forms, scripting, annotation editors and external links are off. The signing document stays on Portwood's own renderer, because its anchors and stamping depend on it. _Visible-region (tiled) rendering at deep zoom is still not available in PDF.js 4.7; pages stay capped at 16.7 MP._

- [x] Loading placeholder with download progress.
- [x] Approve needs every attachment opened **and** the signer's review confirmation (Q9): a tick box at the final step, recorded by `confirmAttachmentsReviewed` only once every attachment was opened (`DocGen_Signer__c.Attachments_Reviewed_At__c`). Enforced in the page and in `saveCompositedSignedPdf`.
- [x] Decline always shows on an attachment request, and `declineSignature` accepts it, even if Decline is hidden after sending (sends are refused while it's hidden).
- [x] Register: a separate **Attached Documents** page (paginates, "continued") before the Certificate of Completion. It lists title, version, size, position, SHA-256 and opened-by name and time, then each signer's review confirmation, with a line saying it records the confirmation, not that every page was read.
- [x] Fail closed: a failed manifest blocks the page; a failed attachment shows the error with **Try again**, and without it there's no approval.

### Sender LWC (`docGenSignatureSender`)

- [x] Record-PDF picker (`getAttachableRecordPdfs`: USER*MODE, size, oversize flagged), **Select all**, Before/After. Order is the picker's (by title). \_Manual reordering not built.* Single-template sends only.
- [x] **Opt-in per template** (added 2026-10-05, in line with #373's "config belongs on the template"): `DocGen_Template__c.Attached_Documents__c` = Off (default) / Optional / Required. Off hides the picker, so current users see no change. The server enforces it for the Sender and Flow alike: Off refuses attachments, Required refuses none, Required can't go in a packet. It's in the Command Hub template editor and template export/import.
- [x] Decline hidden on the template/org: the send is refused (Q6), the template editor warns when Attached Documents is on, and Signature Settings notes it under Hide Decline Button.
- [x] Sender preview lists the attached documents in signing order, with **View files** opening them in Salesforce's file viewer (2026-10-05).
- [ ] **Follow-up:** one combined preview (template + attached documents merged into one PDF). This needs pdf-lib in the LWC, chunked downloads of each file, and a size cap with a fallback. Apex can't merge PDFs, and the Runner's byte-level merger isn't safe for CAD. Drafted as a separate issue.
- [ ] Exclude Portwood's own signed copies from the picker. There's no reliable marker on a signed file (only a configurable title), so this isn't built; the opt-in confines the picker to approval templates.

### Tests & gates

- [x] Apex `DocGenSignatureAttachmentsTest` (29): review confirmation (early refusal, required to approve, idempotent, on the register, PIN-gated); Decline-hidden refusal and Decline kept after send; limits from settings with defaults, and their save validation; pinning and review rows; version pin and dedupe; every refusal (not PDF, not linked, bad Id, wrong type, bad position, count, size; nothing created); no-attachment parity; picker; Flow success and error; manifest public-safe and PIN-gated; serve (raw bytes, headers, hash stored, out of range, tampered hash, changed checksum); token, PIN, expiry and terminal gates; REST errors; approve gate, idempotent views, never-delivered refusal, register content; fallbacks refused and decline still works; cross-request scoping.
- [x] Content-correctness, end to end on the dev box: signed PDFs downloaded and parsed. Register entries and SHA-256s match the server records; 14 entries paginate.
- [x] Adversarial guest-security review (2026-10-01): **0 Critical / 0 High.** Four Mediums fixed on the branch:
    - **M1:** a failed Flow send now rolls back (savepoint), and attachment rows are written before any signer is invited.
    - **M2:** the register on `getSignatureCertificate` is only returned behind the same PIN/expiry/status gate.
    - **M3:** the page refuses to finish an attachment request when the register data is missing or short.
    - **M4:** `serve` re-checks the pinned version belongs to the pinned document, is still linked to the related record, and has a matching, non-blank checksum.

    Lows fixed:
    - distinct-file gate count;
    - request-field FLS guard;
    - a Cancelled signer is treated as closed;
    - the request-token Flow submit path refuses attachment requests;
    - `Vary` / `Content-Disposition` headers and error logging on the REST class;
    - DocGen_User can create the new rows but not edit them.

    Still open:
    - per-token rate limiting of the REST GET (L5);
    - optional HMAC over the pinned pointer;
    - a server-held copy of the register (the per-signer rows are the durable evidence today);
    - a versioned REST path (`/v1/`) — a maintainer call.

    Pre-existing issues the review noted, outside #412's scope:
    - the finalize endpoints don't refuse Declined or Cancelled requests;
    - `getSourcePdfBase64` and `getSignatureCertificate` have no PIN check;
    - sequential order isn't enforced server-side.

- [ ] `npm run qa`; namespaced pre-flight org; Code Analyzer. _`RunLocalTests` on the dev box: see §6.1._
- [x] UserGuide §10.3.1 + CHANGELOG entry.

### 6.1 M1 build notes (2026-10-01)

**Provisional answers to §8**, chosen to keep options open:

| Q   | Built as                                                                                            | Easy to change?                                             |
| --- | --------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | Approval record + register page (D1)                                                                | Yes (client only)                                           |
| 2   | T3 guest REST GET. First `@RestResource` in the package                                             | Moderate: T2 would replace one fetch function and one class |
| 3   | Two child objects. Names are frozen once released, so agree before merge. Could be shared with #405 | **Only before release**                                     |
| 4   | New method name (`…WithAttachments`); `@AuraEnabled` can't be overloaded                            | Yes                                                         |
| 5   | Attachments must be linked to the related record                                                    | Yes                                                         |
| 6   | Not built (no warning when Decline is hidden)                                                       | Yes                                                         |
| 7   | #407 landed first (v3.58)                                                                           | —                                                           |
| 8   | Caps above the documented heap (20 MB). The 16.6 MB sample served fine                              | Yes (`@TestVisible` caps)                                   |
| 9   | 20 MB / 100 files; must open every attachment                                                       | Yes                                                         |

**SHA-256 timing.** Hashing at send would read every file's `VersionData` in the sender's transaction: up to 100 × 20 MB. At send the row pins the ContentVersion Id plus the platform `Checksum`. The first serve computes SHA-256 and stores it; every later serve must match both. Versions are immutable, so this is belt and braces. The register's hash is the one the signer's browser verified.

**"Opened" means delivered and rendered.** `serve` stamps the signer's `Fetched_At__c`; `markAttachmentViewed` is refused until then and is called once page 1 renders. A signer scripting the endpoints can still mark a file opened without looking at it. That's the same limit as scrolling a contract, and the register records it as such.

**Measured on the dev box** (desktop Chrome, guest Site, files from §5.2): REST fetch of 13.6 MB took 2.6 s. A 16.6 MB, 5-page SOLIDWORKS set was fetched, hashed and had page 1 drawn and recorded in 4.6 s. A 0.95 MB single-sheet A1 took under 3 s. These are upper bounds: the test tab was hidden, so Chrome throttled its timers.

**Real phones (2026-10-02):** Pixel 10 (Chrome) and iPhone (Safari) both render, pan and pinch-zoom the drawings, after a fix for a phone-only layout bug: the drawing box collapsed to 0 px once the PDF.js viewer went in.

**Known gaps:** a namespaced-org check (Flow input visibility, `/services/apexrest/portwoodglobal/…` path); manual reordering in the picker. Visible-region rendering at deep zoom belongs in #424.

### 6.2 Maintainer answers (#412, 2026-10-07)

| Answer                                                                                         | Build                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Keep the approval document as the signed record; bind attachments by hash                      | As built (D1).                                                                                                                                                                                                                                                                                                              |
| A combined signed PDF only as an option for small packages                                     | Not built; out of scope for M1 (§9).                                                                                                                                                                                                                                                                                        |
| Show PDFs as separate reviewed documents, not one merged viewer                                | As built (D2).                                                                                                                                                                                                                                                                                                              |
| Register: name, version, size, order, SHA-256                                                  | As built, plus position and who opened each when.                                                                                                                                                                                                                                                                           |
| Secure Apex REST endpoint; validate token, status, expiry and file access                      | As built (T3).                                                                                                                                                                                                                                                                                                              |
| Only files linked to the same related record                                                   | As built, checked at send and again on every serve.                                                                                                                                                                                                                                                                         |
| Child records per attachment, not JSON                                                         | As built (two child objects).                                                                                                                                                                                                                                                                                               |
| Share naming and validation with #405, keep the data models separate                           | Separate objects. Naming and the PDF validation in `DocGenSignatureAttachments.resolveForSend` are there for #405 to reuse.                                                                                                                                                                                                 |
| Options DTO / versioned API instead of another overload                                        | **Changed:** `createGuidedPdfSignatureRequestV2(GuidedPdfSendOptions)`; the 13-arg method is gone.                                                                                                                                                                                                                          |
| Limits configurable per org: ~20 MB per PDF, 100 files, 100–200 MB total, optional page limits | **Changed:** three settings with defaults 20 MB / 100 / 200 MB. Ceilings 50 MB per file (each is served whole in one REST response; measured to 16 MB) and 200 files. No page limit: page count isn't known at send without parsing each PDF, and the viewer only draws the pages in view, so size, not pages, drives load. |
| Require opening each PDF and a review confirmation; don't claim every page was read            | **Changed:** the final-step tick box and `Attachments_Reviewed_At__c`; the register wording says it records the confirmation only.                                                                                                                                                                                          |
| Block attachment requests when Decline is hidden                                               | **Changed:** refused at send; Decline stays on for requests already sent.                                                                                                                                                                                                                                                   |
| #407 first                                                                                     | Shipped in v3.58.                                                                                                                                                                                                                                                                                                           |

## 7. Guardrails so M1 doesn't box in M2 (markup / redline)

1. **pdf-lib only** for flattening markup (M2) — never the regex merger. M2 needs `/Rotate`/`/CropBox` handling and vector drawing. M1 itself does not merge. _Revisit for M2:_ the attachment pane now runs PDF.js's viewer component, whose annotation editors (ink, free text, highlight, stamp) produce vector PDF annotations and `saveDocument()` writes them into the file. Decide whether M2's marked-up copy keeps them as editable annotations or flattens them with pdf-lib.
2. **Per-drawing identity is first-class.** M2 marks are keyed to _(attachment, source page)_ in unrotated page space — the D2 viewer already works per drawing.
3. **One transport both ways.** M2 returns a marked-up copy **per drawing** (up to ~16 MB). Remote actions cap uploads at 2.95 MB; T3 POST measured to 16 MB. Choosing T3 in M1 means M2 adds a POST on the same resource; choosing T2 means M2 still needs an upload design.
4. **Vector markup, not raster.** Raster overlays at A1/A3 resolution inflate files (the limit #197 hit).
5. **Pinned CV + SHA-256** lets a marked-up return prove which revision was marked.
6. **Decline produces no document today.** M2's "decline with markup" needs one — don't bake in "decline = no output".
7. `hitToPdfRect` ignores `/Rotate` and `/CropBox` — harmless for M1 (anchors are on template pages), must be fixed for M2.
8. Markup must not write audit rows shaped like signer audits — the certificate maps audits by `Signer__c` and completion back-fills every audit row's hash.

## 8. Open questions for the maintainer

_Answered on #412, 2026-10-07: see §6.2._

1. **Output (D1):** approval record binding attachments by hash — OK?
2. **Transport (D3) — needed in M1:** a token-gated guest `@RestResource` (T3, recommended — one call per file, also solves M2 uploads) or chunked remote actions (T2, no new surface type, download only)?
3. **Data model:** child object vs JSON field; one model shared with #405's supplemental PDFs? API naming (frozen forever).
4. **API shape:** options DTO for `createGuidedPdfSignatureRequest` vs another overload?
5. **Linkage rule:** require attachments to be linked to the related record (proposed: yes)?
6. **Decline:** block or warn when Decline is hidden on an attachment-bearing request?
7. **#407:** land fail-closed separately first, or as part of M1?
8. **Heap:** both T2 and the existing `getSourcePdfBase64` exceed the documented 6 MB heap on large files without error (§3.1). Comfortable relying on that, or should caps be set to the documented limit?
9. **Caps and review rule:** per-attachment and per-request caps (proposed 20 MB / 100 files)? Require the signer to open every drawing before Approve?

## 9. Out of scope for M1

Markup/redline (M2, separate PR + design); richer outcomes such as "approved as noted" (possible later via a signer picklist form field); packets with attachments; combined-pack output; generation-only supplemental PDFs for Runner/Flow (#405).

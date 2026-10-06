# Third-Party Notices

Portwood runs 100% on the Salesforce platform — no external services, no
callouts, and document data never leaves the org. It does, however, **vendor** a
small number of open-source **client-side** JavaScript libraries as pinned static
resources. They execute entirely in the user's browser, make no network calls, and
are shipped inside the managed package (not pulled from npm at install time).

This file is the component disclosure (SBOM) for those libraries. Keep it current
when versions change, and disclose it in AppExchange security materials.

| Component | Version                   | License            | Purpose                                                                                                                                                                                                                    | Source                             |
| --------- | ------------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| PDF.js    | 4.7.76 (legacy ESM build) | Apache License 2.0 | Renders the document + text layer in the guided signing viewer so sign-spots can be located. Its viewer component (`pdf_viewer.js`, `.css`, `images/`) shows attached documents (#412): lazy page rendering, zoom and pan. | https://github.com/mozilla/pdf.js  |
| pdf-lib   | 1.17.1 (UMD build)        | MIT                | Composites drawn/typed signatures onto the signed PDF in the browser at the located sign-spots.                                                                                                                            | https://github.com/Hopding/pdf-lib |

## Security notes

- **PDF.js** is pinned to **4.7.76**, which is past the 4.2.67 fix for CVE-2024-4367
  (arbitrary JS via a crafted PDF's font path). As defense-in-depth, the viewer also
  calls `getDocument({ ..., isEvalSupported: false })`. No known-vulnerable version
  ships in the package (verified by `sf code-analyzer` retire-js: 0 High).
- The v4 build is ESM-only; the files are stored with a `.js` extension so Salesforce
  serves them with a JavaScript MIME type, and the viewer dynamic-imports the module.
  `pdf_viewer.js` is the unmodified `legacy/web/pdf_viewer.mjs` from the same
  `pdfjs-dist@4.7.76` package (its source-map comment removed); the core and worker are
  byte-identical to that package's `legacy/build` files. Attached documents are shown
  with JavaScript, form fields, the annotation editors and external links disabled.
- These libraries make **no network requests** and have **no external runtime
  dependency** — they operate only on PDF bytes already in the browser.

## Licenses

- **Apache License 2.0** (PDF.js): https://www.apache.org/licenses/LICENSE-2.0
- **MIT License** (pdf-lib): https://opensource.org/licenses/MIT

Full upstream license text is retained in each project's repository linked above.

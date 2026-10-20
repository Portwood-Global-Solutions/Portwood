# Third-Party Notices

Portwood runs 100% on the Salesforce platform — no external services, no
callouts, and document data never leaves the org. It does, however, **vendor** a
small number of open-source **client-side** JavaScript libraries as pinned static
resources. They execute entirely in the user's browser, make no network calls, and
are shipped inside the managed package (not pulled from npm at install time).

This file is the component disclosure (SBOM) for those libraries. Keep it current
when versions change, and disclose it in AppExchange security materials.

| Component | Version                   | License            | Purpose                                                                                         | Source                             |
| --------- | ------------------------- | ------------------ | ----------------------------------------------------------------------------------------------- | ---------------------------------- |
| PDF.js    | 4.7.76 (legacy ESM build) | Apache License 2.0 | Renders the document + text layer in the guided signing viewer so sign-spots can be located.    | https://github.com/mozilla/pdf.js  |
| pdf-lib   | 1.17.1 (UMD build)        | MIT                | Composites drawn/typed signatures onto the signed PDF in the browser at the located sign-spots. | https://github.com/Hopding/pdf-lib |

## Security notes

- **PDF.js** is pinned to **4.7.76**, which is past the 4.2.67 fix for CVE-2024-4367
  (arbitrary JS via a crafted PDF's font path). As defense-in-depth, the viewer also
  calls `getDocument({ ..., isEvalSupported: false })`. No known-vulnerable version
  ships in the package (verified by `sf code-analyzer` retire-js: 0 High).
- The v4 build is ESM-only; the files are stored with a `.js` extension so Salesforce
  serves them with a JavaScript MIME type, and the viewer dynamic-imports the module.
- The Designer also ships a classic-script adapter of these same pinned bytes in
  `DocGenPdfPreview`. It removes the final ESM export and wraps the webpack locals
  for classic script loading; license comments remain intact. A first-party viewer
  page uses the adapter and its local worker handler inside a Salesforce resource
  iframe, avoiding Lightning Web Security's image-decoding overhead. The parent
  supplies permission-checked PDF bytes through an origin/source/session-checked
  message channel. Rebuild or verify the pinned adapter with
  `node scripts/build-designer-pdf-viewer.mjs [--check]`.
- These libraries make **no network requests** and have **no external runtime
  dependency** — they operate only on PDF bytes already in the browser.

## Licenses

- **Apache License 2.0** (PDF.js): https://www.apache.org/licenses/LICENSE-2.0
- **MIT License** (pdf-lib): https://opensource.org/licenses/MIT

Full upstream license text is retained in each project's repository linked above.

## Developer font fixtures

The optional demo tooling in `scripts/fonts/fixtures/` contains unmodified static TrueType
faces from Amiri, Barlow, Barlow Condensed, Crimson Text, DM Mono, DM Serif Display,
Lato, Parisienne and Poppins. Each face retains its original copyright and SIL Open Font
License text in the adjacent `LICENSE.txt`. Immutable source revisions and file paths for
the additional collection are recorded in `scripts/fonts/designer-manifest.json`.

These full font files are developer fixtures outside managed-package source. The setup
tool uploads them to Salesforce Files only in an explicitly selected development org.
`DocGenFontTestData` contains renamed, reduced Parisienne and Barlow test fixtures with
their original notices retained in the Apex source.

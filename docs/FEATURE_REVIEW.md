# Feature review: document authoring, font assets and PDF signatures

Branch: `feat/byod-signature-sender`, based on current `main`. This is a review branch; package versions and install links are unchanged.

## Review guide

| Area           | Main entry points                                                                                               | Result                                                                                                          |
| -------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Designer       | `docGenAdmin`, `docGenDesignerWorkspace`, `docGenDesignerModel`, `docGenPageLayout`, `docGenDesignerPdfPreview` | Contextual editing, inserts/fields, table operations, placement, source editing and unsaved native PDF preview. |
| Font assets    | `DocGenFontController`, `DocGenFontInspector`, `DocGenFontService`, `docGenFontAssets`, `docGenFontLoader`      | Licensed, immutable Salesforce File revisions; native review; shared Designer/Canvas/HTML use.                  |
| PDF signatures | `docGenSignatureSender`, `DocGenSignaturePreparationController`, `DocGenSignaturePrepare`, signature guards     | Record-page PDF preparation, recipients, coordinate fields, private drafts and sequential signing.              |
| First document | `docGenGettingStarted`, `DocGenGettingStartedController`, `DocGenStarterExamples`                               | Quote when available, Opportunity proposal and Account summary with optional fictional demo seed scripts.       |
| Agentforce     | `docGenAiConversation`, `DocGenAiQueryPlanner`, `DocGenAiReferenceController`, `agentforce-ext`                 | Business conversation, schema-grounded query plans and PDF/DOCX reference-based editable HTML.                  |

## Try the fonts

The `portwood-ai-journey` scratch org now has **nine families and 16 verified faces**. Fourteen faces were added to the existing Lato Regular/Bold pair. Every current specimen was downloaded, checked for matching embedded Unicode CID TrueType fonts and live glyph text, and visually reviewed before the new faces were approved.

Families: Amiri, Barlow, Barlow Condensed, Crimson Text, DM Mono, DM Serif Display, Lato, Parisienne and Poppins. Regular/bold/italic coverage varies by family; the picker offers only available verified faces.

1. Open Portwood → My templates → Your templates.
2. Choose **Design** for **Designer Fonts - Test Collection**. It is a separate inactive demo, with the fictional Northstar account as its sample record.
3. Click a word or select text, then use **Font family → More fonts…**. The source remains available through **HTML**.
4. Preview the document to compare browser and native PDF output. The collection is two Letter pages and embeds all 16 custom faces. Its fixed Arabic line uses prepared visual-order copy; it does not add dynamic Arabic shaping.

Repeat on another development org:

```bash
node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS --manifest scripts/fonts/designer-manifest.json
# Review each specimen and approve it in Assets → Fonts.
node scripts/fonts/setup-demo.mjs --target-org YOUR_SCRATCH_ALIAS --create-designer-template
```

The seed tool preserves existing revisions/templates and never approves fonts automatically. Choose an Account sample record in the new org. Full licensed TTF fixtures stay outside managed-package source; the org uses Salesforce Files rather than font Static Resources.

## Validation

- **640 selected Apex tests passed**, with zero test or compilation failures. This used 18 classes covering signatures, font assets, HTML/Canvas persistence, AI authoring and starters.
- After the cleanup's explicit read guards, **28 additional Getting Started/Signature Preparation tests passed** on the deployed source.
- **18 focused Node check scripts passed**. The final Designer check has **48 scenarios**, including literal text remaining text when duplicating repeat groups; nine page-layout cases and the shell-preservation check also pass.
- Changed merge-tag e2e: `e2e-07-syntax6.apex` passes **9/9**. Pinned PDF.js adapter reproduction, repository formatting, extra extension/tool formatting and `git diff --check` pass.
- Native font collection: **200,598 bytes, two Letter pages, 16 matching embedded faces, 93 SOQL queries, approximately 1.05 seconds Apex CPU** in the backend generation check. The live Designer preview also renders both pages, including the prepared Arabic sample.
- Offline QA stays at **516/577** with the exact same **61 baseline failures** (0 blocker, 14 major, 47 minor). Generated reports were copied outside the repo and restored; this is not a fully green repository QA run.
- Security/AppExchange full scan identified eight findings. Explicit read guards now protect private draft request fields and starter-resource reads. Scoped annotations document read-only editor serialization and intended inert-template parsing under LWS. Final targeted rescans clear all eight reported findings, including the extension. The full scan also reported 106 SFGE internal entry-point errors, so graph-analysis coverage is incomplete.

Scratch source deployment: `0AfQL00000sw3L00AI` (127 components, NoTestRun), followed by `0AfQL00000sw78V0AQ` for the final model serialization/comment layout. The 640-test validation attempt `0AfQL00000sw0N70AI` ran all selected tests successfully but rolled back because RunSpecifiedTests requires 75% coverage on every deployed class. It did **not** pass the deployment coverage gate:

| Class                           | Selected-suite coverage |
| ------------------------------- | ----------------------: |
| DocGenAiReferenceController     |                 69.481% |
| DocGenSignatureSenderController |                 72.202% |
| DocGenEinsteinProvider          |                 45.690% |
| DocGenController                |                 23.914% |
| DocGenGiantQueryAssembler       |                 50.461% |
| DocGenService                   |                 36.867% |

This is not a release-qualified package. Full release coverage, a namespaced/subscriber install check and remaining graph-analysis gaps need validation before packaging/merging for release. No new managed package, promotion or production deployment was performed.

## Cleanup and review limits

The previous standalone Designer prototype is archived outside the repository under the local output folder. Generated bytecode and QA output are excluded; source, useful examples, licenses and repeatable checks remain. Font QA tooling resolves the installed CLI, requires an explicitly authorized development org Id and no longer pins one developer's Homebrew path. Credentials/auth URLs were checked before staging. Existing user templates and editing tabs were preserved.

PDF signing is PDF-first with the current 2 MiB preparation budget; reference-file authoring accepts PDF/DOCX through Agentforce. Direct drag/drop of a document onto the Designer canvas is still separate work. Font support is not universal: static TTF only, up to 9 MiB and 16 faces per document, with glyph/embedding validation; supplementary Unicode, complex-script shaping and colour palettes retain the documented limitations. See UserGuide §14.2 and `scripts/fonts/STRESS_VALIDATION.txt`.

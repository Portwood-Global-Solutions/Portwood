# Contributing to Portwood

Thanks for your interest in contributing! Portwood is a community-driven Salesforce document generation tool, and contributions of all kinds are welcome — bug fixes, features, documentation, template examples, and testing.

## Quick start

```bash
git clone <your fork>
cd DocGen
npm install          # prettier + the QA harness
npm run org:new      # creates and fully configures the `docgen-verify` scratch org
npm run qa           # runs every suite and writes a report
```

That's clone to green tests. If anything fails, the answer is very likely in [`.claude/skills/dev-setup/SKILL.md`](.claude/skills/dev-setup/SKILL.md).

**One manual step the script can't do:** Setup → Release Updates → "Use the Visualforce PDF Rendering Service for `Blob.toPdf()` Invocations" → **Enable**. Without it, PDF output is wrong in ways that look like template bugs.

No org yet? `npm run qa -- --offline` runs every suite that doesn't need one.

## Read the skills first

`.claude/skills/` packages the things that make this codebase hard to change and aren't visible from the code. If you use Claude Code they load automatically; otherwise read them as plain Markdown. See [`.claude/skills/README.md`](.claude/skills/README.md).

| Skill                     | Read it when                                                                      |
| ------------------------- | --------------------------------------------------------------------------------- |
| `dev-setup`               | Going from a fresh clone to a working, tested org                                 |
| `run-tests`               | Verifying a change                                                                |
| `triage-report`           | A bug report arrives and you need to know if it's a real defect                   |
| `fix-merge-tag`           | Changing tag parsing, loops, conditionals, aggregates or charts                   |
| `html-template-authoring` | Writing a template, or a PDF doesn't match its source                             |
| `canvas-designer`         | Touching the Canvas artboard, serializer or importer                              |
| `managed-package-rules`   | Adding subscriber-visible Apex, a Flow action, or debugging install-only failures |

**The two facts that save the most time:**

1. **Most "the PDF looks wrong" reports are template issues, not bugs.** The renderer is CSS 2.1 and silently ignores `flex`, `grid`, `gap`, `calc()` and CSS variables.
2. **A merge-tag fix in one resolution path does not reach the other three.**

## How this project runs

Portwood releases **every two weeks, on a Friday**. Bugs are collected, triaged, and fixed in batches rather than one at a time — going slow is deliberate, and it's what creates room for contributors to pick work up.

- **Bug reports are always welcome**, and they don't wait for a release. File them as they happen.
- **A report gets triaged before it becomes work** — real defect, or template-authoring problem? Most are the latter, and get answered as guidance under the `template-help` label.
- **Only P0 jumps the queue.** The test: would a customer hit this and not know their output is wrong? Silent corruption beats loud crashes.
- **Issues labelled `good first issue`** are well-specified and have a named fix approach. They're the best place to start.

See [`TRIAGE.md`](TRIAGE.md) for the full priority rubric.

## Reporting bugs

[Open a bug report](https://github.com/Portwood-Global-Solutions/Portwood/issues/new?template=bug_report.md). Include your package version, Salesforce edition, output format (PDF/DOCX/PPTX/XLSX), whether the template is HTML or DOCX, and steps to reproduce. Attach the template body if you can — it's the single most useful thing.

## Suggesting features

[Open a feature request](https://github.com/Portwood-Global-Solutions/Portwood/issues/new?template=feature_request.md) or start a [Discussion](https://github.com/Portwood-Global-Solutions/Portwood/discussions) to talk through the idea first.

## Submitting code

1. **Check existing issues** — is someone already working on this?
2. **Open an issue first** for non-trivial changes so we can align on approach
3. **Fork** and branch from `main`
4. **Make your change** — follow the guidelines below
5. **Run the tests** (see below)
6. **Open a PR** against `main` with a clear description

### Before you push

```bash
npm run qa -- --offline    # fastest signal, no org needed
npm run format:check       # CI merge gate — a failure blocks the PR
```

If you touched `canvasModel.js`, also run the pure-Node serializer checks:

```bash
node scripts/qa/canvas-serializer-check.mjs
node scripts/qa/canvas-anchor-check.mjs
```

If you have an org configured, run the full `npm run qa`. Scope Apex test runs to the classes you changed — **never run a bare `sf apex run test`**, which triggers an org-wide run that locks `ContentFolder`:

```bash
sf apex run test --target-org docgen-verify --tests DocGenServiceTest --wait 15
```

Code Analyzer, before a release-bound change:

```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```

0 High severity required. ~30 Moderate false positives are expected and documented in `code-analyzer.yml`.

### Code guidelines

- **Read `CLAUDE.md`** before touching the merge engine or PDF pipeline. It documents constraints that are easy to regress — relative image URLs, zero-heap PDF rendering, no `VersionData` in PDF-path queries.
- **Add a test for new behavior.** E2E assertions for parser changes (via `processXmlForTest`), Apex tests for new methods. Note the e2e scripts have an 18,000-character ceiling — put new parser assertions in `e2e-07-syntax5` or a new `syntax6`.
- **No external runtime dependencies.** Portwood runs 100% on-platform — no external services, APIs, or callouts, and document data never leaves the org. Client-side libraries (PDF.js, pdf-lib) are **vendored as pinned static resources**, not pulled from npm at build time. If you add or update one, keep it patched, retain its license/NOTICE, and disclose it in the AppExchange security materials.
- **E-signatures are native + first-party.** The signature workflow ships in the package — no third-party signing or document-generation provider.
- **Use `WITH USER_MODE`** or `Security.stripInaccessible()` for all SOQL/DML in user-facing code. Internal ContentVersion reads are the documented exception — see the `managed-package-rules` skill.
- **Namespace awareness:** source code does not use namespace prefixes; the platform resolves `portwoodglobal__` at compile time. But **JS is different** — SObject keys come back namespace-prefixed in a subscriber org, so `row.Field__c` is `undefined` in a shipped package.

### What makes a good PR

- **Small and focused.** One bug fix or one feature.
- **Tests included.**
- **Clear description.** What changed, why, and how you tested it.
- **No unrelated changes.** Don't refactor surrounding code or add comments to files you didn't change.

## Architecture overview

Apex:

| Class                       | What it does                                                                         |
| --------------------------- | ------------------------------------------------------------------------------------ |
| `DocGenService`             | Core merge engine — template parsing, tag replacement, image handling, PDF rendering |
| `DocGenController`          | LWC controller — template CRUD, generation endpoints                                 |
| `DocGenHtmlRenderer`        | Converts DOCX XML to HTML for `Blob.toPdf()`                                         |
| `DocGenDataRetriever`       | Multi-level SOQL with V1/V3/V4 query config routing                                  |
| `DocGenGiantQueryAssembler` | The >2000-child-row path. **Does not call `processXml()`** — see `fix-merge-tag`     |
| `DocGenChartBucketResolver` | `{#ChartBucket}` aggregation across four resolution paths                            |
| `DocGenBatch`               | Batch Apex for bulk generation                                                       |
| `BarcodeGenerator`          | Pure Apex Code 128 + QR generation                                                   |

Lightning Web Components:

| Component               | What it does                                                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `docGenRunner`          | Main record-page component — template selection, generation. Contains the `docGenPdfMerger` and `docGenZipWriter` modules. |
| `docGenAdmin`           | Template manager — create, edit, version, query builder                                                                    |
| `docGenCanvas`          | The Canvas designer — artboard, box model, HTML serializer (`canvasModel.js`)                                              |
| `docGenColumnBuilder`   | Visual query builder with tree visualization                                                                               |
| `docGenSignatureSender` | Signature request composition and placement                                                                                |

`docGenPdfMerger.js` (client-side PDF merge) and `docGenZipWriter.js` (client-side DOCX/XLSX assembly) are **modules inside** the `docGenRunner` and `docGenAdmin` bundles, not standalone components.

## Community

- **Issues:** bug reports, feature requests, questions
- **Discussions:** ideas, show-and-tell, template sharing
- **Community Hub:** [portwood.dev/community](https://portwood.dev/community)

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).

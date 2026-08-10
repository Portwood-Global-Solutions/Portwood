---
name: run-tests
description: Run Portwood's test suites — the one-command QA harness, the anonymous-Apex e2e scripts, Apex unit tests, prettier, and Code Analyzer. Use before opening a PR, when verifying a fix, or when a test fails and you need to know whether it's your change or the harness.
---

# Running Portwood's tests

## The one command

```bash
npm run qa
```

Runs every suite against the `docgen-verify` org and writes one report. **Exit code
is `0` only when every evaluated check passed**, so it drops straight into CI.

```bash
npm run qa -- --org myorg           # a different org
npm run qa -- --offline             # only suites needing no org — CI-safe, fast
npm run qa -- --fast                # skip the slow suites
npm run qa -- --suite merge-tags,metadata-audit
npm run qa -- --headed              # watch the browser suites run
npm run qa -- --list                # what suites exist
```

Output lands in `scripts/qa/report/`:

- `qa-report.md` — headline numbers, coverage by area, and an ordered **what to fix** list
- `qa-report.json` — the same data, for tracking over time

**Start with `npm run qa -- --offline`.** It needs no org at all, so it's the fastest
way to know whether you broke something, and it's what a contributor without a
configured org can still run.

### Suites

`apex-e2e`, `apex-unit`, `flow-actions`, `merge-tags`, `metadata-audit`,
`output-formats`, `pdf-content`, `record-pages`, `template-integrity`, `ui-admin`,
`ui-designer`, `ui-runner`.

A suite that cannot run returns "skipped" rather than throwing — the report says so out
loud instead of quietly reporting 100%. **A skipped suite is not a passing suite**;
check the report rather than just the exit code when you care about coverage.

### Adding a suite

Drop a file in `scripts/qa/suites/` exporting `run({ org, headed, base })` that returns
`suiteResult(...)` from `lib/report.mjs`, then register it in `SUITES` in
`scripts/qa/run-all.mjs`. Suites must never throw.

## The pure-Node checks

`scripts/qa/canvas-*.mjs` and friends run serializer and layout logic **with no browser
and no org** — that's why the serializer is written to survive `typeof document ===
'undefined'`. They're the fastest feedback loop in the repo:

```bash
node scripts/qa/canvas-serializer-check.mjs
node scripts/qa/canvas-anchor-check.mjs
node scripts/qa/canvas-export-roundtrip-check.mjs
node scripts/qa/canvas-import-fidelity.mjs
node scripts/qa/canvas-inline-sanitize-check.mjs
```

If you change `canvasModel.js`, run these before anything else.

## The anonymous-Apex e2e suite

Each script prints `PASS: N  FAIL: 0  ALL TESTS PASSED`.

```bash
sf apex run --target-org docgen-verify -f scripts/e2e-01-permissions.apex
sf apex run --target-org docgen-verify -f scripts/e2e-02-template-crud.apex
sf apex run --target-org docgen-verify -f scripts/e2e-03-generate-pdf.apex
sf apex run --target-org docgen-verify -f scripts/e2e-03b-page-setup.apex
sf apex run --target-org docgen-verify -f scripts/e2e-04-generate-docx.apex
sf apex run --target-org docgen-verify -f scripts/e2e-05-generate-bulk.apex
sf apex run --target-org docgen-verify -f scripts/e2e-06-signatures.apex
sf apex run --target-org docgen-verify -f scripts/e2e-06b-signature-lifecycle.apex
sf apex run --target-org docgen-verify -f scripts/e2e-07-syntax1.apex
sf apex run --target-org docgen-verify -f scripts/e2e-07-syntax2.apex
sf apex run --target-org docgen-verify -f scripts/e2e-07-syntax3.apex
sf apex run --target-org docgen-verify -f scripts/e2e-07-syntax4.apex
sf apex run --target-org docgen-verify -f scripts/e2e-07-syntax5.apex
sf apex run --target-org docgen-verify -f scripts/e2e-08-cleanup.apex
```

Sequence matters: `01` standalone, `02` creates test data, `03`–`06b` depend on `02`,
`07-syntax*` standalone, `08` cleans up.

### Reading a failure correctly

**A governor-limit throw prints NO summary line at all.** Watch for a script that emits
no `PASS: N`, not just a non-zero `FAIL`. That's why `03b` is split out of `03` — each
full `generateDocument` costs ~10 SOQL, and the combined run blew the 100-SOQL
synchronous limit.

### Constraints when adding assertions

- Each script must stay under **18,000 characters** (the Anonymous Apex ceiling is
  20,000). `syntax1`–`syntax4` are already within a few hundred characters of it — put
  new parser assertions in `syntax5` or a new `syntax6`.
- **Anonymous Apex cannot catch a thrown `AuraHandledException`** (uncatchable
  `LimitException`). Negative-path assertions on `@AuraEnabled` guard methods belong in
  unit tests, not e2e.
- **`@TestVisible private` members are unreachable from anonymous Apex.** Prettier
  passing does not mean the script compiles — actually run it.

When you fix a parser-level bug, add a regression assertion exercising the pattern via
`processXmlForTest`.

## Apex unit tests

Scoped, for a fix:

```bash
sf apex run test --target-org docgen-verify --tests DocGenServiceTest --wait 15
```

**Never run a bare `sf apex run test`** — it triggers an org-wide run that locks
`ContentFolder`. Always pass `--tests` or `--class-names`.

Full local run (what release validation uses):

```bash
sf apex run test --target-org docgen-verify --test-level RunLocalTests --wait 15 --code-coverage
```

Expected: `Outcome: Passed`, `Pass Rate: 100%`, org-wide coverage ≥ 75%.

## Prettier — a CI merge gate

`npm run format:check` blocks merge. Run before pushing:

```bash
npm run format        # auto-fix
npm run format:check  # verify clean
```

Covers `force-app/**/*.{cls,trigger,page,component,cmp,html,js,xml}`, `scripts/**/*.apex`,
and root `*.{json,md,yml,yaml}`. Apex scripts get reflowed — don't fight the wrap.

## Code Analyzer

```bash
sf code-analyzer run --workspace "force-app/" --rule-selector "Security" --rule-selector "AppExchange" --view table
```

Expected: `0 High severity violation(s) found`. ~30 Moderate false positives are
acceptable and documented in `code-analyzer.yml`.

## What to run before opening a PR

1. `npm run qa -- --offline` — fastest signal, no org needed
2. The `canvas-*.mjs` checks if you touched `canvasModel.js`
3. Scoped Apex tests for classes you changed
4. `npm run format:check`
5. `npm run qa` in full if you have an org configured

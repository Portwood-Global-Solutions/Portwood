---
name: dev-setup
description: Get from a fresh clone of Portwood to a working, fully-tested Salesforce org. Use when setting up a development environment, creating a scratch org, onboarding to the project, or when org setup fails with permission or "No such column" errors.
---

# Setting up a Portwood dev environment

Two commands. If either fails, the causes are almost always in the gotchas below.

## Prerequisites

- Salesforce CLI (`sf`)
- A DevHub org (a Developer Edition org works)
- Node 18+ and `npm install` run once, for prettier and the QA harness

## Stand up an org

```bash
npm install          # once — prettier + QA harness deps
npm run org:new      # creates the `docgen-verify` scratch org and configures it end to end
```

To use an org you already have:

```bash
npm run org:setup -- my-existing-org
```

`scripts/qa/setup-org.sh` is **idempotent** — safe to re-run against a live org. It
takes an org from nothing to fully testable:

1. Creates the scratch org **`--no-namespace`**, so the e2e scripts' bare class and
   field references compile.
2. Deploys `force-app`.
3. Assigns `DocGen_Admin` and `DocGen_User` — **after** the deploy.
4. Deploys the QA-only host page, so `docGenRunner` and `docGenSignatureSender` are
   actually placed on a record page. The package ships no FlexiPage on purpose; without
   this there is nowhere for a browser test to reach them.
5. Sets org defaults that stop testing stalling on infrastructure — above all
   `Signature_Skip_Email_Verification__c`, and reminders OFF.
6. Seeds the Account and the `Verify — Designer` template the smoke suite opens.

## One manual step the script cannot do

**Setup → Release Updates → "Use the Visualforce PDF Rendering Service for
`Blob.toPdf()` Invocations" → Enable.**

Without it, PDF output is wrong in ways that look like template bugs.

## Verify it worked

```bash
npm run qa                  # every suite, against docgen-verify
```

Exit code is `0` only when every evaluated check passed. See the `run-tests` skill for
the full set of options.

## Gotchas that cost the most time

### "No such column" on a field that plainly exists

The permission set was not assigned, or was assigned **before** the deploy. Anonymous
Apex enforces FLS, so a missing permset makes deployed fields look like corrupted
metadata. Assign `DocGen_Admin` after deploying, then retry. This is the single most
common false alarm.

### The org must be `--no-namespace`

Source-deploy has to land in the default namespace or the e2e scripts' bare class and
field references won't compile. `setup-org.sh` already does this; if you create an org
by hand, pass `--no-namespace`.

### Namespace bugs are invisible in a dev org

Lightning Web Security's per-namespace sandbox distorts DOM nodes, and
`getPopulatedFieldsAsMap` / raw SObject keys come back namespace-prefixed in a
subscriber org. Neither reproduces in a no-namespace scratch org. If you're touching
LWC DOM handling or reading SObject fields in JS, that class of bug can only be caught
in a namespaced package install.

### Don't run a bare `sf apex run test`

It triggers an org-wide run that locks `ContentFolder` and takes far longer than you
want. Always scope it:

```bash
sf apex run test --target-org docgen-verify --tests DocGenServiceTest --wait 15
```

## Where things live

| Path                              | What                                                                         |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `force-app/main/default/classes/` | Apex — the merge engine, controllers, services                               |
| `force-app/main/default/lwc/`     | Lightning Web Components — designer, runner, canvas                          |
| `scripts/e2e-*.apex`              | Anonymous-Apex end-to-end suite                                              |
| `scripts/qa/`                     | The one-command QA harness and its suites                                    |
| `docs/`                           | Reference templates (`SurveyChartExample.html` is canonical for charts)      |
| `TRIAGE.md`                       | Priority rubric                                                              |
| `CLAUDE.md`                       | Critical engine constraints — read before touching the merge or PDF pipeline |

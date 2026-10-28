# DocGen QA report

**Org** `pr496-scratch` · **Run** 2026-10-28T08:25:46.784Z · **Duration** 57s

## Headline

|                       |        |
| --------------------- | ------ |
| Checks evaluated      | 19     |
| Passed                | 0 (0%) |
| Failed                | 19     |
| Skipped (not counted) | 0      |
| Blockers              | 14     |
| Major                 | 4      |
| Minor                 | 1      |

## Coverage by area

| Suite      | Area            | Passed | Failed | Skipped | Rate |
| ---------- | --------------- | -----: | -----: | ------: | ---: |
| `apex-e2e` | Apex end-to-end |      0 |     19 |       0 |   0% |

## What to fix

Ordered by severity. The detail column is written to say WHERE to look.

| Severity    | Suite      | Check                                                 | Evidence                    |
| ----------- | ---------- | ----------------------------------------------------- | --------------------------- |
| **blocker** | `apex-e2e` | Permissions: e2e-01-permissions.apex                  | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Template CRUD: e2e-02-template-crud.apex              | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | PDF generation: e2e-03-generate-pdf.apex              | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | DOCX generation: e2e-04-generate-docx.apex            | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Signatures: e2e-06-signatures.apex                    | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Signature redemption: e2e-06c-signing.apex            | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | PIN gate + decline: e2e-06d-pin-and-decline.apex      | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax1.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax2.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax3.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax4.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax5.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Merge-tag syntax: e2e-07-syntax6.apex                 | CLI failed: spawn sf ENOENT |
| **blocker** | `apex-e2e` | Custom fonts: e2e-10-custom-fonts.apex                | CLI failed: spawn sf ENOENT |
| **major**   | `apex-e2e` | Page setup: e2e-03b-page-setup.apex                   | CLI failed: spawn sf ENOENT |
| **major**   | `apex-e2e` | Bulk generation: e2e-05-generate-bulk.apex            | CLI failed: spawn sf ENOENT |
| **major**   | `apex-e2e` | Signature lifecycle: e2e-06b-signature-lifecycle.apex | CLI failed: spawn sf ENOENT |
| **major**   | `apex-e2e` | Images: e2e-09-images.apex                            | CLI failed: spawn sf ENOENT |
| **minor**   | `apex-e2e` | Cleanup: e2e-08-cleanup.apex                          | CLI failed: spawn sf ENOENT |

## Every check

### apex-e2e — Apex end-to-end

- ❌ Permissions: e2e-01-permissions.apex — CLI failed: spawn sf ENOENT
- ❌ Template CRUD: e2e-02-template-crud.apex — CLI failed: spawn sf ENOENT
- ❌ PDF generation: e2e-03-generate-pdf.apex — CLI failed: spawn sf ENOENT
- ❌ Page setup: e2e-03b-page-setup.apex — CLI failed: spawn sf ENOENT
- ❌ DOCX generation: e2e-04-generate-docx.apex — CLI failed: spawn sf ENOENT
- ❌ Bulk generation: e2e-05-generate-bulk.apex — CLI failed: spawn sf ENOENT
- ❌ Signatures: e2e-06-signatures.apex — CLI failed: spawn sf ENOENT
- ❌ Signature lifecycle: e2e-06b-signature-lifecycle.apex — CLI failed: spawn sf ENOENT
- ❌ Signature redemption: e2e-06c-signing.apex — CLI failed: spawn sf ENOENT
- ❌ PIN gate + decline: e2e-06d-pin-and-decline.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax1.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax2.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax3.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax4.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax5.apex — CLI failed: spawn sf ENOENT
- ❌ Merge-tag syntax: e2e-07-syntax6.apex — CLI failed: spawn sf ENOENT
- ❌ Images: e2e-09-images.apex — CLI failed: spawn sf ENOENT
- ❌ Custom fonts: e2e-10-custom-fonts.apex — CLI failed: spawn sf ENOENT
- ❌ Cleanup: e2e-08-cleanup.apex — CLI failed: spawn sf ENOENT

# Knowledgebase verification — Portwood 3.60.0

Reviewed on October 24, 2026 against source commit `8fd56843` and released managed package `04tVx000001BOsrIAG` (3.60.0.1). The Dev Hub's released-version query confirmed it was the newest promoted version at review time.

## Environment

- Newly created Developer scratch org, no namespace, no ancestor/source deployment.
- Managed package installed successfully with Admins Only installation.
- Portwood Admin and Button Manager assigned to the scratch administrator.
- Fictional records seeded by `scripts/knowledgebase/seed.apex`.
- Three HTML examples seeded by `scripts/knowledgebase/seed-templates.mjs`.
- Scratch-only Account page fixture with the packaged Runner and Signature Sender.

## Verified by using the installed UI

| Workflow                  | Observed result                                                                                                               |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Open Portwood             | Current existing-file and blank-Canvas choices; no retired starter gallery                                                    |
| First Canvas lesson       | Created Account template, chose Northstar Bikes, entered Name/Phone tags, saved and previewed                                 |
| First PDF                 | Extracted text contained Account brief, Northstar Bikes, and 317-555-0142; rendered page visually inspected                   |
| Complete Account Brief    | Contact rows and Opportunity rows rendered; total was $40,000.00                                                              |
| Save & Download           | Downloaded PDF and a corresponding File on the Account                                                                        |
| Bulk Individual Files     | Filter matched 3 Accounts; completed with 3 successes and 0 errors                                                            |
| Bulk Print-Ready Packet   | Completed with 3 successes and 0 errors; output PDF had 3 pages and all three Account names                                   |
| Uploaded-PDF signing      | Uploaded a real generated PDF; added fictional recipient; placed Signature and Date signed fields                             |
| Internal signing delivery | Created Salesforce-login preview links with email delivery suppressed and no PIN                                              |
| Guided signing            | Typed the fictional signer's name, completed date and consent, submitted successfully                                         |
| Completed request         | Request displayed Signed; related record had the completed PDF                                                                |
| Signed output             | Extracted text included the signer and a Certificate of Completion; sensitive certificate data kept out of public screenshots |
| Admin screens             | Inspected Signature Settings checklist, Assets, Custom Fonts, brand editor, and Email Templates                               |

## Advanced recipe and subscriber API checks

- Created an active Salesforce Site, enabled all four public signing Visualforce pages, assigned Portwood Guest Signature to that Site Guest User, and saved the Site base URL through Portwood settings.
- Called `DocGenSignatureFlowAction.generate()` from subscriber Apex with standalone `DocGenSigner`, invitations suppressed and no email verification. A clean, unauthenticated browser loaded the signing shell, both required placements, and the real PDF canvas. The public test stopped before submission; the earlier internal preview test completed the full signing/save path.
- Called `DocGenFlowAction.generateDocument()` from subscriber Apex and confirmed success and a File Id.
- Deployed and executed `KBAccountProvider` with both required interface methods; seven field paths and the two seeded Contacts were returned.
- Deployed and ran `KBGenerateAccountBrief`; its Queueable completed with zero errors and generated the Account File through the installed global service.
- Rendered 90 synthetic Contact rows through `generatePdfBlobFromData`. Baseline semantic table headers did not repeat after page one. Adding `-fs-table-paginate:paginate` produced four pages, all 90 rows once, and headers on every page. Visually reviewed page two.
- Verified CSS-counter footer spans preserved both lines with Page 1 of 4 through Page 4 of 4. Source review confirmed literal page-number tags use the text-margin path that flattens rich HTML.
- Generated a native one-page PDF; `DocGenPdfMerger.mergePdfs` with two copies and odd-page padding reported four pages.
- `DocGenEmailTemplateService.render` returned the expected subject/body without sending an email.
- The repeatable `verify-advanced.mjs` lab passed its four-page, 90-row, every-page header/footer assertions.
- Exported declarations are generated for 19 core global types and the optional Agentforce provider; nested DTO members and interface methods are included.

## Review boundaries

The task articles also reference the current source implementations. The review method in each article distinguishes source review from workflows also inspected in the org.

The fresh org has a configured Salesforce signing Site but no verified production email sender. Public document access was checked in a clean guest browser. Public completion, PIN delivery, reminders, domain mail authentication, and actual invitation/completion email delivery were not claimed as end-to-end delivery tests. Experience Cloud setup was source-reviewed; a separate Experience site was not provisioned. No external email was sent.

AI provider provisioning, font-license approval and arbitrary font specimens, every Office/PDF-form variant, every Flow transaction context, and large-data stress limits were not exhaustively exercised. Their instructions retain the applicable prerequisites, maturity labels, and need to test the actual output path.

The temporary PDFs and browser state remain outside the public guide. Public screenshot provenance is in `screenshots.json`.

## Reader and build checks

- Guide build and freshness checks passed for 73 articles, 11 topics, and 23 referenced screenshots.
- Both static and Visualforce entry pages match the shared reader sources.
- Browser integration checks passed for all 73 article routes and all 297 legacy aliases.
- Search, image zoom and restored focus, local learning-path progress, full Markdown view,
  390/768/1024px overflow checks, phone navigation, print visibility, HTML sanitization,
  and catalog failure/retry passed.
- Website guardrails passed, and the Visualforce page parsed as well-formed XML.

These checks validate the local reader and source/capture artifacts. They are not a production website deployment or a public-email delivery test.

## Prepublication legacy audit

All 225 substantive headings in the pre-overhaul guide have mapped destinations in `legacy-coverage.json`. The review added four searchable developer articles and corrected the ambiguities listed in `LEGACY-AUDIT.md`. The 73-article reader and all 297 legacy routes passed the same browser suite with the current production static header/footer shell. The public site uses Namecheap; Salesforce-only deployment would not publish it.

## Published table correction

The merge-tag directory contained an unescaped pipe in the inline-code example `{?poNumber|N/A}`. That produced a four-column delimiter under a three-column header, so the directory rendered as paragraph text. The source now escapes the literal pipe, and the generated catalog/Markdown have been rebuilt.

Build validation now checks table column counts in every article and retained reference. Browser validation checks all 55 article tables for actual HTML table output, expected header columns, expected data-row counts, and the complete signer-input fallback tag. The previous route/image checks did not establish table structure; these assertions cover that missing check.

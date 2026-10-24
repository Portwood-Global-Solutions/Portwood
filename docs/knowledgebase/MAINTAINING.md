# Maintaining the Portwood knowledgebase

The knowledgebase has one set of article sources and generated outputs. Edit the sources; regenerate the outputs. The website reads the catalog, and GitHub readers can read the complete guide.

```text
docs/knowledgebase/articles/*.md ─┐
docs/knowledgebase/guide.json ────┼─ npm run guide:build ─┬─ UserGuide.md
sfdx-project.json package alias ─┘                      └─ docs/knowledgebase/catalog.json
```

## Where to make a change

| Change                                                      | Edit                                                                                |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Words, steps, examples, screenshots in a lesson             | `docs/knowledgebase/articles/<slug>.md`                                             |
| Article title, topic, order, related lessons, review record | `docs/knowledgebase/guide.json`                                                     |
| Current released package                                    | `release.packageAlias` in `guide.json`; the ID is resolved from `sfdx-project.json` |
| Learning paths                                              | `learningPaths` in `guide.json`                                                     |
| Homepage document image                                     | `home` in `guide.json`                                                              |
| Screenshot bytes                                            | `docs/images/userguide/v<version>/`                                                 |
| Screenshot provenance                                       | `docs/knowledgebase/screenshots.json`                                               |
| Detailed developer material                                 | `docs/reference/`                                                                   |
| Site layout and behavior                                    | The separate website repository's `guide-reader/`                                   |

Do not hand-edit `UserGuide.md`, `catalog.json`, or `apex-surface.json`. A check fails when they differ from a fresh build.

## Everyday editing

```bash
npm ci
# Edit an article and its review record.
npm run guide:build
npm run guide:check
```

An article contains its body only. Its title comes from `guide.json`. Use H4 (`####`) for sections so the generated guide can place each article under its topic. Keep paths to local images relative to the repository root, such as `docs/images/userguide/v3.60/create-template.png`.

Link to another lesson with its stable slug, for example `[Make a table that grows](#repeating-tables)`. Use a full GitHub URL for a developer reference or a downloadable example. The builder validates local article links, source dependencies, image existence, provenance, and generated-output freshness.

## Writing a lesson

Start with a real task a reader wants to finish. Use the exact labels in the current UI.

1. Say what the reader will make or change.
2. State needed access, setup, or sample data before the first step.
3. Use a short numbered list. Each step should contain one clear action.
4. Put a screenshot beside the step or decision it explains.
5. Give a visible success check: “You are done when…”
6. Include the few likely problems and the next relevant lessons.

Explain a term before relying on it. Keep beginner lessons focused on actions. Put detailed tag families, Apex contracts, and layout recipes in their dedicated advanced topics; keep downloadable extended references in `docs/reference/`. A user should not need to understand an implementation to generate a document.

Every `guide.json` article has:

- A permanent `slug`. Renaming the title does not change the link.
- A topic, short summary, audience, and approximate reading time.
- `sources`: the actual code files or directories that can change these instructions.
- `related`: stable slugs for the next useful lessons.
- `review.version` and `review.date`.
- `review.method`: `org-and-source` when checked in a subscriber org as well as source, or `source` when reviewed from the implementation only.

The method records the kind of review, not a claim that every format, license, browser, and possible record was tested. Put exact test scope and exclusions in the release verification notes.

## Legacy coverage ledger

`legacy-coverage.json` records every substantive pre-overhaul heading, its GitHub and website anchor forms, and its current destination. The build checks all of them. When moving an article, keep or deliberately update this mapping; see `LEGACY-AUDIT.md` for corrections made during migration.

## Exported Apex inventory

`apex-surface.mjs` reads global declarations from core and optional Agentforce source. The builder expands `{{apexSurface}}` into the searchable inventory article and writes `apex-surface.json`. A changed global signature makes `guide:check` fail until regenerated. This is a declaration inventory, not a compiler or a compatibility guarantee: review behavior and legacy restrictions, and compile the subscriber examples against the new released package.

## Each release

1. Confirm the latest **promoted/released** managed package in the Dev Hub. A GitHub “Latest” label or the numerically newest beta alias is not proof of a production release.
2. Set `release.packageAlias` to that released alias. Use `{{version}}` and `{{packageId}}` in article text; do not paste another installation ID into a lesson.
3. List affected lessons:

    ```bash
    npm run guide:affected -- <previous-release-ref> <new-release-ref>
    ```

4. Read the changelog for capabilities with no existing source mapping. Add or retire lessons as needed. The dependency report is a starting point; it cannot infer a new feature's teaching needs.
5. Review the affected instructions against source and an installed subscriber org. Update their review records only after the check.
6. Recapture screenshots when a screen, label, or relevant behavior changed. Reuse unchanged screenshots with their original provenance; do not pretend every image was recaptured.
7. Check the retained developer references too. Fix contradictions rather than copying an obsolete claim into a new article.
8. Regenerate, validate, preview, and run the reader checks.
9. Record exactly what was tested and what still depends on external setup.

Older reviewed versions may remain on unaffected lessons. That is deliberate and visible. Do not bulk-replace every review version to make the guide appear newly verified.

## Recreate the documentation org

The 3.60 review used a **blank, unnamespaced subscriber scratch org with the released package installed**, not a source push of `force-app`.

Use your project's authorized Dev Hub and a unique scratch-org alias:

```bash
sf org create scratch --target-dev-hub <hub> \
  --definition-file config/project-scratch-def.json \
  --alias <kb-org> --duration-days 30 --no-namespace --no-ancestors

sf package install --package <released-04t-id> --target-org <kb-org> \
  --security-type AdminsOnly --no-prompt --wait 20

sf org assign permset --target-org <kb-org> \
  --name portwoodglobal__DocGen_Admin \
  --name portwoodglobal__DocGen_Button_Manager

sf apex run --target-org <kb-org> --file scripts/knowledgebase/seed.apex
node scripts/knowledgebase/seed-templates.mjs <kb-org>
sf project deploy start --target-org <kb-org> \
  --metadata-dir scripts/knowledgebase/fixtures --wait 5
```

The fixture gives Accounts a record page with the packaged Runner and Signature Sender. It changes the Account page assignment in that scratch org. It is outside the package directory and must not be deployed to customer orgs as an installation shortcut.

The template seeder refuses non-scratch URLs. The Apex data file is intended only for this disposable org. Example seeds do not send email. They create fictional Accounts, Contacts, Opportunities, and HTML templates; they are independent of customers' data and the larger demo schema.

Create the first Canvas template through the UI using the lesson. Verify PDF rendering in that org, and handle the Salesforce release update if it is offered or required.

## Recheck advanced recipes and subscriber code

After the base examples are seeded, deploy only the subscriber examples to the disposable scratch org and run the pagination lab:

```bash
sf project deploy start --target-org <kb-org> \
  --source-dir docs/knowledgebase/examples/apex --wait 5
node scripts/knowledgebase/verify-advanced.mjs <kb-org>
```

The lab creates/versions its own `KB_Repeating_Header_Lab` template, renders 90 synthetic rows through the installed global service, downloads the PDF into ignored `.tmp/advanced-verification`, and checks every row, header, and two-line page counter. It requires Poppler (`pdftotext`) and makes no email sends. It refuses a non-scratch URL. Inspect the PDF visually too. Four pages is an intentional current-layout regression assertion: investigate a changed result before accepting it for a later release.

Execute `KBAccountProvider.getData()` and `getFieldNames()` with the seeded Account; enqueue `KBGenerateAccountBrief` and check its AsyncApexJob and the Account File. Recheck the PDF merger using two native one-page outputs (four pages with padding), and render an email without sending. Check current action DTOs and token restrictions separately.

## Capture screenshots

1. Use fictional data and the released subscriber package.
2. Use a consistent desktop viewport. Keep the relevant label and action in frame.
3. Crop by choosing the browser/element screenshot area; do not fabricate UI or replace a label in an image.
4. Capture before/after states where they teach something different.
5. Exclude browser addresses, signing tokens, credentials, real customer data, and certificate IP/device details.
6. Add the image's release, capture date, description, and environment to `screenshots.json`.
7. Use descriptive alt text in the article. The reader reuses it as the enlarged image's caption.
8. Inspect the PNG at normal size and in the mobile reader.

Keep screenshot provenance when an unchanged image remains useful in a later release. Use a new version folder for recaptures so a reviewer can see which bytes changed.

## Preview both repositories together

The website is a separate Git checkout. Build its reader, then run the content repository's local preview:

```bash
node <website-checkout>/guide-reader/build.mjs
npm run guide:build
node scripts/knowledgebase/preview.mjs --website <website-checkout> --port 4173
# Open http://127.0.0.1:4173/guide
```

The preview serves local content and images. It does not require publishing either branch to GitHub. It also leaves Salesforce and the live site untouched.

Run browser checks with:

```bash
node scripts/knowledgebase/check-reader.mjs --website <website-checkout>
```

The browser check uses Playwright from this repository. Install its Chromium browser if your machine does not have Chrome or a Playwright Chromium available. It checks navigation, all article routes, search, old links, mobile overflow, image zoom, learning paths, raw Markdown, load failures, and HTML sanitization.

## Links and publication order

The article slugs are the current public links. The imported legacy anchors preserve links from the old guide, including the different GitHub/site hyphen rules. Keep aliases when moving or renaming a lesson. Add a deliberate destination when retiring one.

Publish the content changes, including `catalog.json` and images, before switching the live website to the new reader. The new reader fetches the catalog from the content repository's main branch. Keep its schema compatible, or coordinate a reader update when changing the schema.

The root `UserGuide.md` remains readable on GitHub and usable by the previous Markdown renderer during the transition. Old anchors in the generated Markdown are explicit HTML anchors.

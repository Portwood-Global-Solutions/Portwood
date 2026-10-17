Portwood first-document journey
==============================
Goal: a new customer reaches a native Salesforce PDF within five minutes of completing package installation and permission assignment.

Product path
1. Install Portwood. Assign Portwood Admin to template authors and Portwood User to document users. The app checks authoring access and gives the assignment path when missing; it never grants permissions itself.
2. Open Portwood > Get started (the default hub destination).
3. Choose Quote PDF or Account summary. If standard Salesforce Quotes or QuoteLineItems are unavailable to the current user, the sales card falls back to Opportunity proposal. The app does not enable Quotes or grant access.
4. Keep Try sample data for a complete first PDF, or select a Salesforce record. Click Render my PDF.
5. The native file viewer opens. Close it to see clear next actions: choose a real record, customize the template, add branding, or put Portwood Runner on a record page.
6. In the designer, Preview with sample data uses the same fictional data until the author chooses a real sample record. Draft preview does not publish edits.
7. Add Portwood Runner through Lightning App Builder, save and activate the page, and assign Portwood User to the team. Signature requests remain record-page actions; the hub contains Signature settings only.

The starter examples (two offered at a time)
- Quote PDF: shown first when Quote and QuoteLineItem are queryable and readable. Account context, QuoteNumber, status, expiration, products, quantities, sales prices, decimal line discounts, native Subtotal/TotalPrice, saved tax/shipping, and native GrandTotal. Uses standard Salesforce Quotes; CPQ custom quote objects are separate templates.
- Opportunity proposal: Account and Owner context, OpportunityLineItems with Product2.Name, quantity, unit price, line total, and an aggregate proposal total.
- Account summary: Account and Owner details, open opportunities, open cases, contacts, pipeline total, and collection counts. Closed deals and cases are filtered out in the data query. Empty collections explain what is missing.
- Both use built-in PDF fonts. Custom fonts and logos are optional after the first success.
- Fictional data is supplied to the actual merge/PDF engine. No sample CRM records, products, price books, Cases, or contacts are inserted by onboarding.
- Each creator gets one reusable starter per example. Reopening an example never replaces an edited template. A unique API key makes double-click retries safe. Each generated PDF goes to that user's private Salesforce Files. No ContentDistribution is created for documents.

Visual direction
Navy #183452 for headings and document structure; teal #206b72 for actions and selection; pale teal #edf5f5 for selected data and totals; blue-gray #526475 for supporting text; light slate #f3f6f9 for secondary surfaces; #d8e1ea for borders.
Use the Salesforce/system sans family in the UI and built-in Helvetica in starter PDFs. Use size, spacing, and a single teal rule to establish hierarchy. Actions sit above the page illustrations, visible on a laptop. The three-step indicator describes real progress. Every back action names its destination.

Fonts
- Search includes name, file name, asset key, weight, and style across all loaded faces. Status filters and 24-face pages keep the DOM bounded.
- The list and specimen scroll independently. Search, status, and pagination stay outside the list scroller.
- Compatibility guidance precedes upload and is available from the catalog: static TrueType only, 9 MB / 20,000 glyph budgets, license requirements, separate faces for styles, variable/CFF/web/collection rejections, shaping limits, supplementary Unicode, and monochrome color fonts.
- Approval always requires a native PDF specimen review. Browser appearance is not evidence that text will print.
- Current catalog API returns at most 200 faces. A notice appears at that boundary; filters describe only the loaded catalog. Server pagination beyond 200 remains a scalability follow-up.

Source and rebuilding
scripts/onboarding/build-examples.py is the authoring source for the packaged DocGenStarterExamples JSON resource and docs/examples/StarterQuote.html + StarterAccount.html + StarterOpportunity.html.
Run python3 scripts/onboarding/build-examples.py, then format the example HTML with Prettier. The resource is packaged template markup and fictional data; font bytes continue to live in Salesforce Files.
Table loop open/close tags must remain inside the first/last cells of the same row. Bare text directly inside tbody is foster-parented by browser parsing and breaks visual-editor round trips.
Empty relationship wrappers contain records: [], so inverse guards use Relationship.records.

Validation
node scripts/qa/onboarding-starters-check.mjs
sf apex run test --target-org SCRATCH_ALIAS --tests DocGenGettingStartedTest --result-format json --wait 1
npm run qa -- --offline
npm run format:check
git diff --check

A fresh subscriber-package install and permission assignment have not yet been timed. Source-deployed scratch testing is evidence for the in-app flow, not an install-time guarantee. Existing offline metadata-audit failures are baseline debt, not introduced by this feature.

Scratch demo fixture
scripts/onboarding/seed-demo.apex is a separate developer-only fixture, never called by the app. It is hard-scoped to scratch org 00DRu00000aiv7VMAQ and idempotent by an exact fictional-account marker. It creates Northstar Manufacturing - Journey Demo, two open opportunities, a closed deal, three priced line items, two open cases, a closed case, and two contacts so the real-record path can be demonstrated.
Current fixture: Account 001Ru000028jUI6IAM; Opportunity 006Ru00000XyLLBIA3.
Read-only asset users receive preview/copy actions and admin guidance instead of unavailable upload/edit/delete controls. New image permissions are described on the server; font administration still uses Manage Portwood Fonts.

Quote demo fixture
Quotes were initially disabled in portwood-proposal. Enabled the Quote setting only in that development org for validation; no package-wide Quote requirement or customer-setting change was added.
scripts/onboarding/seed-quote-demo.apex reuses the existing Northstar opportunity and its three priced products. It is scratch-scoped, idempotent and never synchronizes the quote to its opportunity. Quote 0Q0Ru000005Mb2sKAC has $24,500 subtotal, $23,100 after the implementation line discount, $600 tax, $150 shipping and $23,850 grand total.

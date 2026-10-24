# Legacy guide audit and publication review

Reviewed October 24, 2026 against the pre-overhaul `UserGuide.md` at `8fd56843` and the 3.60.0 source.

The initial rewrite needed four developer-facing additions: signer-input tags/writeback, exact per-email token lists and custom widgets, asynchronous job polling, and in-site query-configuration examples. Those now have their own searchable articles. The legacy references remain available as downloadable Markdown.

## Clarifications made before publication

- Current Create Signature Request and the deprecated signature action both use the guided signing pipeline. The deprecated action's ignored ContentVersion input is not a product-wide ban on uploaded-PDF signing.
- Validation accepts modern signer tokens; the legacy submitter/finalizer do not. Validation success does not make a modern token compatible with legacy submission.
- Subscriber Apex queries the job record rather than calling the package-internal Bulk controller.
- Persisted job states include Processing, Stitching and Merging; automation must not compare them with friendly UI labels such as Running.
- Screen Flows need an actual screen/refresh boundary. Wait availability depends on Flow type; a record trigger does not grant a generic Wait element.
- Writeback is single-signer, happens after the signed file is saved, and can fail/log independently from signing success.
- Email tokens are supplied per email type. A sample preview does not establish a token's runtime availability for every notification.
- The filename fallback in the core service is the source data Name, not a universal template-name guarantee.
- The obsolete “custom PDF fonts not implemented” section is deliberately replaced by the approved static TrueType workflow and pinned font tags.
- Both the legacy website's collapsed-dash anchors and GitHub's non-collapsed-dash anchors have explicit destinations. The migration ledger records every substantive legacy heading; the old table of contents remains structural navigation in the generated Markdown.

## Repeat the check

`legacy-coverage.json` records the source commit, original heading, both anchor forms and the destination article. `guide:check` validates every destination and migrated alias. Use it alongside the source-dependency report and release verification notes; a heading map alone cannot prove that an instruction is accurate or a runtime path was tested.

The public-email delivery limitations in `VERIFICATION-3.60.md` remain explicit. They do not prevent publication of the instructions; they prevent claiming a delivery test that did not happen.

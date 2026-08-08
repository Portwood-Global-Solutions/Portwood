# Known issues

What the QA suite reports that is **real and unfixed**, as distinct from suite staleness
or org setup. Each entry is reproducible and written down so a run that reports it is not
mistaken for a regression.

Reviewed 2026-08-08 for v3.55.0.

## Fixed in v3.55.0

Kept here briefly so an older report reading "known issue" is not confusing.

- **A `<style>` block inside `<body>` had its CSS eaten.** Every `{...}` pair is merge-tag
  syntax, so each declaration resolved to nothing and left its selector printed on the
  page. Customer-reported. Now stripped before the merge, with the stylesheet hoisted
  into `<head>` so nothing is lost. See UserGuide §15.2.
- **`DocGen_Template_Version__c.Type__c` defaulted to Word** — **on new installs only.**
  A version created without an explicit type retyped its template through
  `activateVersion`. The picklist default is removed and `activateVersion` now ignores a
  blank type.

    **Salesforce does not push a removed picklist default to existing subscriber orgs.**
    Measured on two upgraded orgs: a fresh 3.55 install describes the field with no
    default, while orgs upgraded from 3.53 and 3.48 still report `Word`. So an existing
    customer keeps the old behaviour until an admin clears it by hand — Setup → Object
    Manager → Portwood Template Version → Type → edit the Word value → untick Default.

    All of Portwood's own creation paths set the type explicitly, so this only bites code
    that creates versions without one: scripts, data loads, integrations.

- **`Validate Signature Token` faulted a bulk Flow.** It queries per token, so past
  roughly fifty requests the transaction died on `Too many SOQL queries: 101` and lost
  every result. It now validates as many as the allowance affords and returns the rest
  marked "not attempted". The underlying per-token querying remains — see #4 below.

## Not a defect — corrected

**Bulk generation and a template's Record Filter.** An earlier version of this file, and
the QA check it came from, claimed the batch ignored `Record_Filter__c` and produced
documents for excluded records. That is not true. `DocGenBatch.andTemplateFilter` ANDs
the filter onto the job's WHERE clause and parenthesises both sides. Measured:

| Job condition             | Composed query                                             |
| ------------------------- | ---------------------------------------------------------- |
| _(none)_                  | `(Industry = 'Agriculture')`                               |
| `Industry = 'Technology'` | `(Industry = 'Technology') AND (Industry = 'Agriculture')` |
| `A OR B`                  | `(A OR B) AND (Industry = 'Agriculture')`                  |

The check now asserts that composition instead. What remains is a usability point, not a
correctness one: a template whose filter excludes every selected record produces an empty
job with no explanation. A count preview on the bulk picker would close it.

## 1. A new Type picklist value can be missing after an upgrade

`Canvas` arrived in v3.54 and does not always reach an org that already had Portwood
installed. Measured on two orgs upgraded to v3.56 — from v3.48 and from v3.53 — both
offer Word, PowerPoint, Excel, HTML and PDF; neither offers `Canvas`. The same org
installed fresh has all six. Not inactive, absent, on both `DocGen_Template__c.Type__c`
and `DocGen_Template_Version__c.Type__c`.

**Consequence:** an upgrading customer cannot create a Canvas template, which puts the
Canvas designer and everything built on it out of reach — while a fresh install is fine.
Creating one by API fails with `INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`.

Documented in UserGuide §15.12, with the check surfaced in the release note so it is read
before someone goes looking for the designer rather than after.

Two things not yet established, and both change the remedy:

- **Whether an admin can add the value by hand.** Both fields are restricted picklists
  owned by the package, and Salesforce normally forbids a subscriber adding to those. If
  it is forbidden here, documentation alone cannot fix it and the answer is code — a
  post-install step, or an unrestricted picklist.
- **Whether it reproduces outside a scratch org.** All three orgs measured are scratch
  orgs, which are not a faithful model of subscriber upgrade behaviour. A real
  Developer or Enterprise org upgrading is the test that settles it.

Worth resolving before the next release rather than carrying.

## 2. The runner offers templates it cannot generate

`getTemplatesForObjectInternal` filters on `Is_Active__c` and audience, but not on the
template having a body. The template appears in the picker and fails only after Generate,
with "No template file found (active or attached)".

**Attempted for v3.55 and backed out**, for two reasons worth recording so the next
attempt starts ahead rather than repeating them.

_It cannot filter on the active version alone._ `DocGenTemplateManager` falls back to an
attached file when the version's `Content_Version_Id__c` is null, so a version-only test
hides templates that generate perfectly well from an attachment.

_And matching the generator exactly is not safe either._ `DocGenPdfPreparedBodyQueueable`
sets `Content_Version_Id__c` **asynchronously**. Between saving a PDF template and that
job finishing, the version has no body — so an exact filter makes a freshly-saved template
disappear from the picker and come back on its own. A template that vanishes with no
explanation is a worse bug than one that errors when you pick it.

Ten tests in `DocGenControllerTests` also failed, all of them building bodyless templates
as fixtures for audience, sort and record-filter assertions. They are not wrong to — the
picker's contract today is "matches this object and this audience", and adding "and can
generate" is a contract change, not a filter tweak.

A workable fix needs to tolerate the async window — a grace period on
`LastModifiedDate`, or the queueable marking the version — plus the fixture work. Worth
doing, not worth guessing at.

## 3. Signature actions fault the Flow on invalid input

`Create Signature Request` throws for a null Template Id, a null Related Record Id, an
empty Signers collection, or a signer with no email. `Finalize Signature Image` throws on
a malformed token. On those paths the `Success` and `Error Message` outputs are never
reached.

**Deliberate, and left alone on purpose.** `DocGenSignatureFlowActionTest` has eight tests
pinning the throwing behaviour, so it is a contract rather than an oversight — and the
change would be the more dangerous direction. A Flow that faults today is loud; one that
quietly continues with `success = false`, in an interview whose author never wired those
outputs, is not.

Documented instead: UserGuide §11.11 now spells out which errors arrive by which route and
tells authors to wire a fault connector. Revisit as a deliberate contract change in a
major release, not as a patch.

## 4. `Validate Signature Token` is still not truly bulkified

The limit no longer faults the interview (see Fixed, above), but the action still issues
per-token queries and so cannot validate a large batch in one transaction.

The real fix is a bulk `validateTokens(Set<String>)`. That means restructuring guest-facing
token security — the capability assert, the multi-signer path and the legacy fallback all
key off a single token — and it deserves the review guest access warrants rather than
being folded into a release.

`flow-actions` separately reports SOQL and DML inside the per-request loop of
`DocGenFlowAction.generateDocument`; the same reasoning applies, and the same fix would
cover it.

## 5. A template created outside the designer opens to an empty canvas

The Designer loads a template body from a ContentVersion titled
`docgen_html_body_<templateId>`. It does **not** fall back to the active version's
`Content_Version_Id__c`.

**Consequence:** a template whose body was written any other way — the API, a script, a
data load — generates perfectly but opens to a blank designer with nothing to say why.
Re-saving once through the Template Manager UI writes the CV the designer expects.

`scripts/qa/suites/template-integrity.mjs` checks this directly and will report any
template created by script. That is the check working: the same thing happens to a
customer who builds templates through the API. The durable fix is the fallback.

## 6. 149 fields have no description or help text

`metadata-audit` reports one row per field. Real, worth doing, and mechanical — an admin
looking at the field in Setup has nothing to tell them what it does.

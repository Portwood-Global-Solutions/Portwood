# Dynamic signature Brands demo

Current work is on `feat/byod-signature-sender` / PR #465. Both demo orgs are
throwaway scratch orgs with Salesforce Sites, not published Experience Builder
Networks. Public tokens, captured responses and diagnostic logs remain local in
`output/` and must not be committed.

## Chrome investigation and fresh-org comparison

The original `portwood-proposal` warning remains unresolved. Its reported
`DocGenSignaturePdf` endpoint returned HTTP 200 without an off-platform redirect.
Tests were performed one at a time with normal Chrome security:

1. Removed the pre-existing `api.ipify.org` browser lookup from both signing pages.
   The user's reported link subsequently loaded normally, but a fresh branded
   PDF request on the same Site was still blocked. Removal alone was insufficient.
2. Temporarily replaced dynamic branding with static Portwood presentation. The
   same PDF URL still showed **Dangerous site**. The full implementation was restored.
3. Temporarily served a plain Visualforce diagnostic page at that exact endpoint,
   with no package controller, document, forms, images or package scripts. Salesforce
   still injects its own platform scripts. Fresh Chrome navigation remained blocked.
   The full signing page was restored.
4. Created `portwood-signing-clean`, deployed the same Salesforce-only source and
   configured a new native Site. Fictional Harbor Works HTML and prepared-PDF
   requests both open and reload normally in regular Chrome. The PDF renders its
   document and signing controls with normal site information and no captured
   console warnings/errors. Dynamic branding remains enabled.

The comparison supports a persistent classification associated with the original
Site or URL; it does not identify the original trigger, clear existing warnings,
or guarantee future Safe Browsing classification. Moving a demo is a diagnostic,
not remediation of an already flagged customer link. No warning was bypassed,
no live agreement was signed, no email was sent and no Google review was submitted.
The prepared review was left unsubmitted at the user's request.

## Salesforce-only resources and signature IP capture

The IP lookup predates this work: the HTML page added it in `f0b4067`, and the PDF
page inherited it in `eb42bec`. It has now been removed. Signing IP capture remains
required; removing the lookup alone exposed a native-context gap in live testing:
Visualforce page requests provide IP headers, while VF remoting supplies no headers.

Both pages now capture the native request observation during read-only initial rendering.
A server HMAC binds the IP and two-hour validity window to the signer token. Audit
writes verify that observation when a current request IP is unavailable. The
random org-specific key lives in a protected custom setting and is never rendered
or exposed by a remote method. Generic document-query gateways explicitly reject this private settings object. Installation/upgrade and authorized admin setup initialize the private key. Source-deployed QA orgs initialize it through setup as well. Guest rendering never writes settings, marks a signer Viewed, publishes a document or changes signing status. Completed/rejected links do not expose an IP observation. No additional browser endpoint or
external service is used. Plain guest-supplied IP strings are not accepted as
observations. A stale or modified proof requires reloading the page.

Salesforce's platform IP header takes priority over forwarding headers. Native
Site checks include deliberately supplied forwarding/platform headers. Other
custom-domain/CDN configurations still require integration validation; forwarding
headers are best-effort fallbacks, and an unavailable platform address must never
be represented as a verified public address.

`DocGenAssetPolicy` rejects automatic off-platform images, fonts, stylesheets and
embedded content in Brand/configuration, email, template/merged HTML, rich text,
Office resource relationships and native PDF-rendering paths. Native Salesforce
asset URLs, inline images/fonts, local vector charts and manual hyperlinks remain supported. Live
previews filter resource URLs before attaching content. Older unsafe configuration
falls back or fails clearly instead of loading its resources. The guide no longer
automatically redirects outside Salesforce. Existing customer content with remote
images must move those images into Salesforce Assets/Files.

Validation: **1,275/1,275 Apex regression tests** passed after correcting the seven
failures from the initial 2,317-test full run. Local checks pass: **34** resource
policy assertions, **24** provider/page initialization assertions and **92**
completed-link assertions. Fresh-org initial-response/theme checks pass **84** assertions
across both endpoints, including server-rendered theme values and script-safe
public presentation. Final scoped checks pass **407/407 Apex tests**, including an audit write from a verified observation, read-only guest rendering, installation/setup initialization, private-key query rejection and the corrected versioning fixture. Four live native observations verify across requests; supplied forwarding/platform headers do not replace the baseline address. A native public File image also loads in the real guest PDF page. Both orgs have the same review build. The fresh-org full run passed **2,326/2,327 tests**. Its one failure was a versioning fixture that left the factory's empty revision active alongside V2; the fixture now deactivates that revision before the test, and the final scoped rerun passes with the original assertions unchanged.

The metadata audit retains **51 existing findings**. Security/AppExchange analysis is not a clean release signoff: the broad scan has existing DOM/vendor/output findings and Graph Engine internal errors. Final targeted PMD reports four VF output warnings on encoded support links and script-safe presentation JSON. The new IP controller/helper has no remaining URL-parameter or GET-action findings. Managed-package/subscriber security validation remains a release gate.

Both signing pages identify Portwood DocGen as the service provider outside the
customizable content. Branding is present in the initial HTML; remoting does not
swap the theme after load. Advanced content is sanitized before reveal. The live
Salesforce branding set remains dynamic on the next page load.

## Completed-link reload behavior

`DocGenSignaturePdf` and `DocGenSignature` now retain the current Brand/theme
after signing, while the token remains unexpired. The initial response renders
**Signature Complete**, or **Signature Recorded** while other recipients are
pending. The signing validation result remains `isValid=false`; only the public
presentation and completion state are returned. It contains no signer identity,
document URL, record identifier or form data, and the confirmation performs no
Viewed update or document publication. Cancelled, declined, draft and expired
completed requests do not receive this presentation.

The completed page skips token remoting, document loading, verification and IP
capture. It also handles completion in another tab between render and validation
by switching to the confirmation instead of showing an error. This changes the
post-signing experience without re-enabling signing or changing its write gates.

Validation: **448 Apex tests** passed, including actual sequential prepared-PDF
completion, guest confirmation and rejection of unavailable links; **92 page
script assertions** cover both pages' initial confirmation and concurrent-tab
completion. **59 live HTTP/DOM checks** cover synthetic completed/waiting fixtures
on both endpoints and the existing signed Cedar PDF request. Synthetic fixtures
set test statuses only; no new document was signed and no email was sent. Their
links and captures are local in `output/signing-completion/`.

Regular Chrome loaded the synthetic completed **DocGenSignaturePdf** page with
its branding and **Signature Complete** message on initial navigation and reload,
with normal site information and no captured console warnings/errors. The
previously flagged, unsigned Harbor Works **DocGenSignaturePdf** URL was also
rechecked after deployment and still shows **Dangerous site**. No warning was
bypassed. These results do not establish the cause of, or clearance from, Safe
Browsing's classification.

Open **Portwood → Brands** and search for **Cedar Community - live theme**. The
library shows a signing-page thumbnail. Select the Brand to edit its identity,
page settings, and previews. Under **Signing pages → Live Salesforce theme**, the
Brand references **Cedar Community — live theme demo**.

The association reads the current Salesforce `BrandingSetProperty` values when a
valid signer opens either signing page. It does not copy a palette into the Brand.
The demo changes the Salesforce theme from blue to green after creating both
requests; the same guest links then show green without resaving the Brand or
requests. Reload an already-open page to see a theme change.

Uploaded PDFs now have a **Signing Brand** selector in **Review and send**. A
request's explicit Brand takes priority over its template Brand. Blank uses the
template or organization defaults. Inactive Brands cannot be newly assigned.

The fixture creates a fictional Account, a template-based HTML request, and an
uploaded-PDF request. It uses **Create public signing links**, sends no email, and
leaves both links available for review. Links and screenshots are local artifacts
in `output/brand-live-demo/`; tokens are not committed to the repository.

## Reproduce

After deploying the changed source to the authorized Proposal scratch org:

```sh
node scripts/brands/demo.mjs portwood-proposal
node scripts/qa/brand-library-browser-check.mjs portwood-proposal
node scripts/qa/preparation-brand-browser-check.mjs portwood-proposal
node scripts/qa/signing-first-paint-check.mjs
node scripts/qa/signing-first-paint-security-check.mjs portwood-proposal
node scripts/qa/signing-completion-check.mjs
```

The first command creates new fictional requests. To repeat the color-change
checks against the existing local links, add `--reuse` to that command.

## Supported theme presentation and boundaries

Salesforce documents BrandingSet properties including `ActionColor`,
`CompanyLogo`, and `PrimaryFont` in its
[BrandingSet metadata reference](https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_brandingset.htm).
The implementation projects supported action/header/page colors, a Salesforce-hosted
logo, and a safe font-family list. It supports site-relative `/sfsites/`,
`/file-asset/`, and `/resource/` images using the configured signing-site base.
Missing or invalid values fall back to the Brand. Custom font files and arbitrary
Experience Builder CSS are not imported. Document styling remains independent.

Choose the branding set for the intended site once. The association follows
changes to that set; it does not discover the active site or audience from a
standalone signing URL. Switching a site to a different branding set requires
selecting that set on the Brand.

The Proposal scratch org has an active Salesforce Site but no Experience Cloud
Network. The demo verifies actual anonymous guest pages and a real Salesforce
branding set. Validation against a published Experience Builder site remains an
integration check for an Experience Cloud-enabled org.

## Verification

- **438/438 Apex tests passed** across Brand resolution/configuration, HTML/PDF
  signing, preparation, verification, and sender regressions.
- **11 live anonymous checks passed**, including theme changes on both existing
  links, mobile page width, and rejection of an invalid token.
- **8 native Brand library checks passed**: search, theme/default selection,
  preview colors, save/reopen, and the component constrained to phone width.
- **4 native PDF Brand selector checks passed**: restored selection, valid
  recipient markup, clearing to organization defaults, and restoring the Brand
  through save/reload.
- **92 local browser assertions passed** across the actual HTML/PDF signing-page
  sources. Existing image-linking/save-readiness regression checks passed.
- The new request Brand field passes layout, administrator permissions, and help
  checks. The metadata audit retains its existing **51 findings** elsewhere.

# Dynamic signature Brands demo

Deployed to `portwood-proposal` on October 18, 2026, on `feat/byod-signature-sender`.

**Latest independent retest: the warning is not fixed.** A new fictional Harbor
Works Account, Brand, Salesforce branding set, inactive HTML template, and two
unsigned requests were created on the existing Proposal scratch org/Site. The
new HTML signing link loads normally in regular Chrome, including after reload.
The new PDF signing link shows **Dangerous site** on first navigation and reload;
its Details say **recently found phishing**. No warning was bypassed, no document
was signed, no email was sent, and no Google review was submitted.

Both initial HTTP responses contain the correct Harbor Works branding before
JavaScript. Changing only the new theme's action color from orange to teal
updates both responses at the same URLs; the Brand modification timestamp stays
unchanged. The HTML page also displays the new color after reload, loads its
document/signing controls, and reports no captured console warnings or errors.
**56 HTTP/DOM assertions passed** across the initial and updated theme. These
functional checks do not establish Safe Browsing clearance. Local fixture links,
response captures and results are in `output/brand-independent-check/`.

The earlier fresh Cedar PDF did open normally in Chrome, but this independent
retest shows that result was not consistent across new requests. The original
demo URL also remains unresolved. The earlier signed request was preserved.
Do not bypass an interstitial. Earlier Cedar links are in
`output/brand-live-demo/links.json`.

The hostname matches Salesforce's `SiteDetail.SecureUrl`. On October 18, an HTTP
inspection found no redirect away from that host; the four served vendor/Brand
script resources matched the checked-in files. Google's public hostname report
returned **No available data**, while Chrome's interstitial explicitly said
**recently found phishing**. These observations do not identify the cause or prove
the detection is a false positive. The original URL's warning is unresolved;
clearing it may require Google's review. See
[Google's Security Issues guidance](https://support.google.com/webmasters/answer/9044101).

A correction is now deployed: both signing pages identify Portwood DocGen as the
service provider and state its relationship to the customer Brand. This remains
visible outside the customizable HTML, including invalid-link states. The default
page title also identifies Portwood. This addresses the third-party labeling gap
in [Google's published guidance](https://developers.google.com/search/docs/monitor-debug/security/social-engineering);
it does not establish that this gap caused the detection or clear the warning.
All **14 provider identity DOM checks** pass, and the deployed guest response
contains the identification. A Google Safe Browsing re-evaluation request is
prepared in Chrome. Submission and Google's classification decision are separate
from deployment. The current Google account has no verified Search Console
property available for this Site.

Both signing pages now resolve the current Brand and linked Salesforce theme on
the server. Their initial HTML contains the title, identity, text, image URLs and
validated CSS variables. The getter shares the existing token, expiry, request
status and prepared-PDF signing-order gates, but performs no Viewed updates or
public document-link creation. Only the public branding projection is embedded;
signer names, emails, tokens, document data and internal theme associations are
not included. Invalid, expired and cancelled tokens receive a neutral page.
Recognized, unexpired completed links retain public branding and render a
read-only confirmation, as described below.

The remoting callback no longer applies branding. Advanced author HTML remains
in script-safe JSON and is sanitized synchronously before its section becomes
visible; Standard presentation is the fallback if initialization fails. The
Portwood provider identity remains visible throughout. The live theme still
updates on the next page load: changing its action color changed the initial
HTML at the same signing URL without resaving the Brand.

Current validation: **448/448 Apex tests**, **30 live initial HTML/DOM checks**,
**34 live escaping/Advanced initialization checks**, and **22 provider identity
and page-initialization checks** passed. Chrome previously loaded the fresh Cedar
PDF and its signing controls without script errors; the independent Harbor Works
PDF now warns, as described above. The Google review has **not been submitted**,
as requested.

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
The implementation projects supported action/header/page colors, a public HTTPS
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

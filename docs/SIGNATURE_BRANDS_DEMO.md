# Dynamic signature Brands demo

Deployed to `portwood-proposal` on October 18, 2026, on `feat/byod-signature-sender`.

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

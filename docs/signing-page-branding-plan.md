# Signing page branding

## Outcome

The Brand selected on a Portwood Template controls the identity of both its
signature emails and its public signing pages. Admins configure a brand once in
Command Hub → Brands and preview the signing experience before saving.

## Implementation plan

1. Extend `DocGen_Brand__c` and the existing admin DTO with optional signing-page
   action, header, and background colors; heading; welcome text; footer;
   completion message; and support URL. Reuse the company name and public logo.
2. Resolve the active brand from the token-bound request on successful token
   validation. Return a public presentation DTO only. Fall back through the
   existing org identity settings to built-in defaults. Resolve linked logo
   assets through the same read-only public-link resolver used by email.
3. Share one CSS/JavaScript resource across HTML/guided and PDF signing. Keep the
   brand header and footer visible during verification, document review,
   signing, processing, completion, waiting, and subsequent errors. Do not
   expose branding for an unknown, expired, or otherwise rejected token.
4. Expand the Brands editor with signing-page controls and a live preview. Save
   through the existing admin/FLS gates. Add permission metadata for new fields.
5. Verify persistence, fallback behavior, inactive brands, guest resolution,
   token scoping, hostile values, responsive rendering, and both signing pages.
   Deploy and test in the existing `portwood-proposal` scratch org.

## Presentation design

Use the customer's logo and company name as the visual anchor. Keep the document
and signing controls on their existing white surfaces, with left-aligned copy.
Default to the Salesforce Sans/system stack already shipped by the signing pages;
the expanded editor also offers serif and humanist page typography.
Default tokens: action `#0176D3`, header `#FFFFFF`, background `#F3F2F2`, body
`#181818`, muted `#706E6B`, border `#DDDBDA`. Admin choices replace the first
three; foreground colors are calculated for contrast. Keep focus indicators
visible and respect reduced motion. Brand styles never enter document content
or change the signature's ink, audit attribution, consent, or verification.

```text
Company logo / name                         (brand header)
Page heading and welcome text

Existing verification / document / signing surface

Page footer                                  Get help
```

The existing Salesforce controls remain familiar to admins. The signing preview
uses the actual page tokens and copy, with a completion preview, rather than an
unrelated marketing layout.

## Decisions and boundaries

- Blank page action color inherits the email brand color; blank identity fields
  inherit org defaults. Page copy has built-in defaults. Page footer inherits
  the shared brand/org footer unless explicitly set.
- Settings resolve live, like existing email brands and decline settings, so
  updates also reach pending requests. Signed documents remain unchanged.
- Standard copy remains plain text. Advanced mode adds HTML sections and
  controlled CSS through the shared renderer described below.
- This extends the Portwood pages hosted by Salesforce Sites or Experience
  Cloud. The existing site's URL/domain and routing continue to apply. Separate
  site-wide brand mappings, custom domains, font uploads, and a drag-and-drop page builder are
  future work if customers need them.
- Requests without a branded template (including direct file sends) use the
  existing org identity defaults, matching outbound email behavior.

## Standard and Advanced modes

Extend the same Brand editor with an optional, versioned
`Signing_Page_Config__c` JSON configuration. Older records and callers keep the
existing Standard presentation. Admin CRUD and guest reads continue through the
existing permission and token gates. Only validated presentation settings are
projected to a signer; asset keys and unknown configuration keys stay internal.

Standard controls include a page-specific logo, logo height/alignment, banner
and alternative text, background image, system/serif/humanist typography,
content width, and spacing. Every image supports a public HTTPS URL or a linked
Shared Asset. The background has a color overlay to preserve text contrast.
The logo/banner carry the customer's identity; document surfaces stay quiet.

Advanced mode adds header, welcome, footer, and completion HTML plus controlled
CSS. Empty or rejected sections use their Standard fallback. A starter layout
and escaped placeholders make HTML authoring practical without copying company
details into each section. Switching modes preserves the saved HTML.

HTML is sanitized using a pinned, bundled DOMPurify build. Sections allow
ordinary content, links, tables, and images; executable elements, forms, and
event handlers are removed. Image/link URLs must be absolute HTTPS. CSS is
parsed by the browser, limited to presentation/layout properties, and scoped
inside each custom content container. It cannot position content over signing
controls or select the document. Standard controls and Advanced sections use
the same rendering resource for the editor preview and public pages.

Validation adds hostile HTML/CSS, safe image resolution, mode switching,
backward-compatible saves, cleared/invalid configurations, layout isolation,
mobile sizing, live editor persistence, and anonymous signing page checks in
the AI scratch org.

## Validation

Run targeted Apex tests for the DTO/controller/resolver and signing regressions;
browser-check shared rendering with real page markup, malicious values, mobile
viewports, and unchanged document styling; run formatter and metadata checks.
Record the actual results with the implementation handoff.

## Using the feature

Open **Command Hub → Brands**, create or edit a brand, and fill in its shared
identity and **Signing pages** settings. The editor shows email and page previews,
including the completion message. Choose that brand in the template's
**Signature brand** picker. Its requests use the same identity in emails and
both signing pages. Clearing a page color or footer restores inheritance.

Use **Images** to select a page-specific logo, banner, or background from Shared
Assets or public HTTPS URLs. **Layout and typography** controls the page font,
spacing, and maximum content width. The document retains its own typography.

Choose **Advanced** in **Page design mode** to edit the four HTML sections and
their CSS. **Use starter layout** supplies escaped field placeholders and a
responsive starting point. Custom sections replace the corresponding Standard
sections; blank or rejected content uses the Standard fallback. Switching to
Standard preserves the saved HTML and CSS for later use. CSS applies within
custom sections. Image assets are published by the admin picker, and Save waits
for those public URLs to be ready.

## Verification results (October 17, 2026)

- Deployed to the existing `portwood-proposal` scratch org.
- All 423 targeted Apex checks passed across branding, email rendering, HTML,
  PDF, guided signing, and signature preparation.
- All 40 local browser assertions passed using the actual HTML/PDF page source
  and shared resource, covering mobile sizing, contrast, hostile values,
  document-style isolation, and invalid tokens.
- The live Salesforce editor updated its preview and preserved all entered
  settings after save/reopen. This caught and fixed the existing identity
  inputs' missing Lightning `change` handlers.
- Both public Salesforce Site URLs rendered the saved brand for an anonymous
  signer on desktop and mobile. Temporary test requests were removed; the
  **Cedar Community — signing page demo** brand remains available for review.
- All 52 Brand metadata checks passed. Compared with the branch's original
  metadata audit, there are no new failures; the Brand layout fixes 10 existing
  findings. The 51 remaining repository findings concern other metadata.

Run the page browser checks with `node scripts/qa/signing-branding-check.mjs`.
Screenshots are generated under `output/signing-branding/`.

## Expanded mode verification

- Deployed the Standard/Advanced editor and shared renderer to
  `portwood-ai-journey` and `portwood-proposal`.
- All 428 targeted Apex regression checks passed in the AI org. The final
  configuration/branding follow-up passed all 13 checks in each scratch org,
  including the Site-enabled org's guest context.
- All 92 browser assertions passed across the actual HTML/PDF page sources,
  including images, typography, scoped CSS, hostile HTML/CSS, escaped fields,
  mode switching, fallbacks, and mobile sizing. The image-linking check passed
  save-readiness and stale-response cases.
- The live AI editor saved and reopened images, layout, and HTML/CSS, and
  preserved the source through a saved Standard → Advanced mode switch.
- Both public signing pages rendered Advanced sections, responsive CSS, banners,
  and an Asset image without a Salesforce login. The temporary signing fixtures
  were removed. The AI org has no public Site, so this check used the existing
  `portwood-proposal` Site.
- All 55 Brand metadata checks passed; no new repository audit failures.
- **Community signing — Advanced demo** is saved in the AI org for review.

Additional local check: `node scripts/qa/brand-image-linking-check.mjs`.

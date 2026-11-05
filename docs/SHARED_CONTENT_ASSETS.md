# Reusable terms and HTML snippets

This review branch adds **Assets → Terms & snippets**. Save a section once and include its full formatted content in HTML and Canvas documents with a stable tag:

```html
<div>{%snippet:standard-terms}</div>
```

## Customer journey

1. Open **Portwood → Assets → Terms & snippets → New shared content**.
2. Name the section, choose an optional category, and write it. **HTML source** supports exact inline formatting and tables. The tag key is permanent once saved; the name can change.
3. Save and **Copy tag**. In Designer use **Insert → Shared content**, or paste the tag on its own line in an HTML template. The keyboard insert menu also lists active sections.
4. Preview a PDF with a sample record. The Designer keeps the reference as an atomic chip; the PDF includes the entire section.

Use categories such as Terms & Conditions, Payment instructions, Disclaimers, or Closing sections. These share the same HTML snippet asset type.

## Shared content behavior

- A tag uses the **latest active revision**. Updating the asset changes future generated documents without editing each template. Previously generated files remain unchanged.
- **Revision history** opens older HTML. **Restore as new revision**, followed by Save, publishes a new revision and retains the intervening history.
- Saves check the latest version under an asset record lock. A stale editor cannot overwrite someone else's revision; its unsaved HTML stays in the editor.
- Inactive or missing snippets stop generation with the key and recovery instructions. They are never silently omitted.
- Save rejects circular/missing references before publishing active content. Nested snippets expand before record merging.
- Record fields and loops use the current context: `{Name}` outside a loop uses the root record; inside a loop it uses that row. **Include every referenced field/relationship in the template's query.** Adding a snippet does not change the query automatically. The AI authoring prompt describes this contract and available snippets.

## Formatting and scope

Snippets are HTML **body fragments**, using inline styles. Paragraphs, headings, lists, tables, text alignment, links, `dir`/`lang`, page breaks and keep-together formatting are supported. Use `page-break-inside:avoid` for a compact section or row; oversized sections still need to flow across pages.

Image and registered-font assets work within the fragment:

```html
<div style="page-break-inside:avoid">
    <h2>Payment details</h2>
    <p>Prepared for {Account.Name}</p>
    <p style="{%font:your-approved-font:revision-prefix};font-size:10pt">Standard wording</p>
    <img src="{%asset:company-logo:144x}" alt="Company logo" />
    {%snippet:payment-instructions}
</div>
```

Copy real font/image tags from Assets. Registered fonts retain their existing approval, glyph and script requirements. The visual text editor handles common formatting; use HTML source to retain exact CSS and font directives. The browser preview shows unmerged content; native PDF preview verifies the actual output.

This first version supports **HTML and Canvas document templates**, including their HTML running headers/footers and the giant-query PDF pipeline. Word-source templates receive a clear error. Email templates continue using image assets; private HTML snippets are not published as email logos or expanded in email bodies.

Scripts, event handlers, embedded documents, external stylesheets, authored style blocks, data-URI images, CSS URL loading and executable CSS are rejected with an actionable message. Validation preserves legal wording rather than silently stripping content. Use a full template for document-wide styles and page settings.

Heap guards allow 250,000 characters per snippet, 100 distinct snippets, eight nesting levels, and 1,000,000 characters of expanded content per expansion. File metadata bounds a bulk read before loading private HTML bytes. These are text-processing safeguards; font files keep their separate upload rules.

## Storage and permissions

`DocGen_Asset__c.Asset_Type__c = HTMLSnippet` identifies these assets. The existing immutable `Asset_Key__c` supplies the key; `Category__c` groups them. Each asset has a Salesforce File with successive ContentVersions and **private-on-records** sharing. There are no snippet Static Resources or public ContentDistributions.

The authoring/merge gateways enforce asset sharing and CRUD/FLS. A private inner file reader retrieves only the backing revisions of those authorized assets, allowing another Portwood reader to generate documents and another authorized editor to publish a revision. Readers cannot publish. Image upload, image deletion and public email-logo endpoints reject non-image assets.

## Working scratch sample

In `portwood-ai-journey`, open **My templates → Your templates → Shared Content - Quote Demo → Design**. The inactive sample uses the fictional Northstar Quote and its three line items. It includes:

- `{%snippet:demo-standard-terms}`: formatted terms, merging `{Account.Name}` and `{QuoteNumber}`.
- `{%snippet:demo-closing-note}`: a reusable closing paragraph in the verified Poppins Italic face.

Source examples: [Quote HTML](examples/SharedTermsQuote.html), [terms fragment](examples/SharedTermsSnippet.html). Both corresponding assets are editable in Assets. Revision history includes a 30-day → 45-day → restored 30-day demonstration. Local proof PDFs show the unchanged template using the new revision while the earlier PDF retains its original wording.

## Verification

- `DocGenSnippetTest`: normal HTML rendering, dynamic fields, row context, headers/footers, giant parent/extraction, nesting, private-file readers/editors, revision restoration/conflicts, missing/inactive content, cycles, malformed tags, unsafe HTML and expansion bounds.
- `scripts/e2e-07-syntax7.apex`: standalone normal/giant extraction and latest-revision regression; fixture writes roll back.
- `node scripts/qa/shared-content-check.mjs`: actual Assets component state, save failure recovery, history restoration and reader/busy restrictions.
- `node scripts/qa/designer-editing-check.mjs`: shared insertion and saved-tag preservation, plus the existing Designer editing cases.
- Native standard and explicitly launched batch Quote PDF proofs include merged terms, all three line items, correct Salesforce totals and embedded Poppins Italic. Chunk-boundary tests verify balanced tbody/tfoot wrappers; font/glyph preparation happens after row injection. The batch proof uses three lines, not a new high-volume benchmark.
- Final scoped validation: 212 Apex tests passed; 180 merge-tag checks passed with four existing scope skips; syntax6 9/9 and syntax7 3/3; 50 Designer and five Assets authoring Node scenarios. New snippet controller/service coverage is 95%/96%.

See [FEATURE_REVIEW.md](FEATURE_REVIEW.md) for combined branch validation and remaining managed-package release gates.

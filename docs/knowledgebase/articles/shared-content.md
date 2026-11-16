Shared content lets you author a frequently reused section once and insert it into HTML or Canvas templates with a stable merge tag.

#### Create shared content

1. Open **Portwood > Assets > Terms & snippets**.
2. Select **New shared content**.
3. Enter a name, optional category, and permanent asset key.
4. Use **Write** for common formatting, **HTML source** for exact inline styles and tables, or **Preview** to review the rendered section.
5. Save the content and choose **Copy tag**.

The copied tag looks like this:

    {%snippet:terms-and-conditions}

Insert the tag where the complete section should appear. In HTML or Canvas authoring, use the shared-content insertion control when available. Keep the tag on its own line when the surrounding layout needs a separate paragraph.

#### Revisions and activation

A shared-content asset uses the latest active revision. Changing only **Active for document generation** updates the asset status without creating another content revision. Editing the name, category, or HTML content creates a new revision when you choose **Save new version**.

Use **Revision history** to inspect an earlier version. **Restore as new revision** copies that version into a new revision while retaining the intervening history. Inactive or missing content is reported during generation instead of being silently omitted.

#### Formatting and fonts

Use HTML body fragments with paragraphs, headings, lists, tables, links, alignment, page breaks, and inline styles. The editor keeps the content inside its frame when switching between Write, HTML source, and Preview. Pasted text keeps its meaningful spacing and paragraph breaks.

Approved custom font tags can be used inside the fragment. PDF preview and generated PDF output use the approved embedded font. Native Word, Excel, and PowerPoint output carries the font family and formatting; recipients need the font installed in their Office application for the same typeface to display.

Images and other reusable assets can be referenced with their normal asset tags. Copy the real image or font tag from Assets rather than typing an unapproved key.

#### Supported templates and output

Shared content is designed for HTML and Canvas templates and is also expanded in supported native Office merge paths. Test the actual output format when the fragment contains complex tables, lists, images, or custom fonts.

PowerPoint templates produce native PPTX files. PDF is not an available output choice for PowerPoint templates; use Word, HTML, or Canvas when the finished document must be PDF.

#### Limits and safety

Snippets are body fragments, not full HTML documents. Scripts, event handlers, external stylesheets, executable CSS, data-URI images, and unsafe URLs are rejected. Add document-wide styles and page settings to the template.

Record fields and loops inside a snippet use the current merge context. Include every referenced field and relationship in the template query; creating a snippet does not add fields to a template query automatically.

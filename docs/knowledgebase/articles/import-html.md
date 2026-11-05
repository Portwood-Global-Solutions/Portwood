Use a Google Docs export or an HTML file as a PDF template.

#### From Google Docs

1. Make a copy of your document.
2. Replace example values with tags, such as `{Name}` and `{Phone}` for an Account template.
3. Choose **File → Download → Web Page (.html, zipped)**.
4. In Portwood, choose **Create New → Bring an Existing Template**.
5. Choose the base object, **Type = HTML**, and PDF output.
6. Include the fields used in the document.
7. Upload the ZIP, keeping the HTML and images together.
8. Finish creation and click **Save as New Version** if prompted.
9. Generate a PDF with your sample record and check the whole document.

Portwood extracts the HTML and images from the export. You do not need to upload each exported picture separately.

#### From another HTML source

Upload a `.html`, `.htm`, or HTML ZIP file through the same path. A ZIP should contain the document and the images it references.

Keep a copy of the authoring file. When you re-export from Google Docs, upload the new file as a new version of the existing template.

#### Edit in Portwood

Use the template's **Design** action to open the HTML designer. Its toolbar and panels let you format text, insert tags and tables, choose images, edit the query, and set headers and footers.

Use **Save as New Version** to activate edits. **Download Sample** or **PDF Preview** helps you check the rendered result.

#### Return to the Designer Beta library

When an HTML template is open in the legacy designer, click **Back to Library** to return to the **Designer (Beta)** template picker. This lets you choose another HTML or Canvas template without going back to the main **Your Templates** table.

If the designer has unsaved changes, Portwood opens an **Unsaved changes** confirmation. Choose **OK** to discard the changes and return to the Designer Beta picker. Close or cancel the dialog to keep editing. Use **Save as New Version** before leaving when you want the changes to become the active template version.

#### Why the PDF can look different

Salesforce's PDF renderer supports a smaller set of layout features than a web browser. Plain paragraphs, tables, fixed widths, and common fonts are reliable starting points. Modern web layouts using flexbox or grid can change or disappear.

Always check a generated PDF before sending it. For advanced styling and a reusable authoring prompt, see the [HTML and Word layout reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/template-layout.md).

Use the symptom that matches your output, then regenerate the same test record.

#### A value is blank or a tag still appears

1. Open the source record and check its value.
2. Confirm the field is selected in the template's **Data/Query** configuration.
3. Copy the tag from the field chooser instead of retyping it. Field spelling and relationship paths matter.
4. For a table, check that opening and closing loop names match and both belong in the data row.
5. Save the document as a new version and confirm that version is active.
6. Test with the affected user's field and record access.

An unknown or unavailable field can resolve to blank. A missing closing brace or section can fail generation. Plain prose wrapped in `{braces}` can be treated as a tag too.

#### My uploaded changes do not appear

Upload the replacement file and click **Save as New Version**. A details-only save does not activate a staged file. In Canvas, use **Save**. Reopen the active version and regenerate.

#### The PDF shows raw CSS

Ask the administrator to check the **Blob.toPdf() Visualforce PDF Rendering Service** release update. Also confirm the package version: an older bug could strip CSS declarations from a style block in the body; that was fixed in v3.55.

For a current package, save and test a small copy of the affected template and include the actual output in the support investigation.

#### A picture is missing

Check whether it is a shared asset, a template image, or an image inside a Salesforce rich-text field. Verify the source exists, the running user can access it, and the template was saved after upload.

Test rich-text images through the actual record runner as well as the authoring preview; the paths can differ. For important fixed artwork, use a shared asset or a sized image tag rather than relying on an oversized pasted photograph.

#### Text runs through a table border

First check for long strings with no spaces, such as URLs, identifiers, or codes. The PDF renderer does not honor every browser word-wrap rule.

Give the value more width, put it on a separate full-width row, or use a display-specific field with sensible break points. Do not insert visible spaces or hyphens into a value someone must copy exactly. For authored static HTML, `<wbr />` can mark intentional break points.

For Word tables that should align, use consistent fixed widths and avoid mixing incompatible AutoFit settings. See the [layout reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/template-layout.md).

#### The document is too large

Compress source images, limit unnecessary related rows, and test the appropriate runner or background path. For bulk, reduce Batch Size to 1 and consider Individual Files. A background route still has Salesforce limits; it is not unlimited.

If you see a heap, timeout, or upload error, keep its exact text. Use [file and format limits](#limits) and job history to choose the next attempt.

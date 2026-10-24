Turn a Word document you already maintain into a reusable template.

**Before you start:** Save a copy as `.docx`. Keep your original. Choose the Salesforce object you will generate from.

#### 1. Add tags in Word

Replace example values with field tags:

```text
Customer: {Name}
Phone: {Phone}
Prepared on: {Today:MMMM d, yyyy}
```

These first two tags assume an **Account** template. For an Opportunity, the customer name is usually `{Account.Name}`.

Use ordinary text, headings, and tables. Keep a tag together and type it exactly, including braces. Save the `.docx`.

#### 2. Bring the file into Portwood

1. Open **My Templates → Create New → Bring an Existing Template**.
2. Enter a name and choose the **Base Object**.
3. Set **Type** to **Word**.
4. Choose the default **Output Format**: PDF or Word.
5. Select a sample record if one is available.
6. Continue to the data step and include the fields used by your tags.
7. Upload your `.docx` on the document step and finish the wizard.
8. Use **Save as New Version** if the editor shows the upload as staged.

#### 3. Check the generated file

Generate a sample using a record with real values. If your default is PDF, check the PDF rather than relying on Word's preview.

**You are done when:** The generated document has the expected values, page breaks, tables, and images.

#### Make later changes

Edit the original Word file, save it, then open the template's **Edit** action. Upload the replacement and click **Save as New Version**.

For PDF output, simple tables and common fonts are easiest to maintain. Use fixed column widths when columns must line up. Avoid building a layout from spaces, floating shapes, or text boxes. If a table looks different, see [Fix a layout or output problem](#troubleshooting).

Files larger than **10 MB** are rejected by the template uploader. Compress large pictures in Word before uploading.

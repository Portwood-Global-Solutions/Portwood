Use Excel or PowerPoint when the recipient needs a spreadsheet or slide deck. Both formats are currently **Alpha**.

#### Make an Excel template

1. Make a copy of your workbook.
2. Put a field tag in a cell, such as `{Name}`.
3. For a related-record table, put the opening and closing loop tags in the same worksheet row:

| Cell | Content                  |
| ---- | ------------------------ |
| A2   | `{#Contacts}{FirstName}` |
| B2   | `{LastName}`             |
| C2   | `{Email}{/Contacts}`     |

4. Save as `.xlsx` or `.xlsm`.
5. Create an **Excel** template, select its fields and related list, and upload the file.
6. Save the version and generate the workbook.
7. Open it in Excel. Check formulas, shifted rows, formatting, and any macros.

Use one repeating region per row. With several Contacts, the example row expands down; rows below it move down. With no Contacts, the repeating row is removed.

Image tags, shared-asset images, chart-tag images, and rich-text formatting are not supported like they are in Word/PDF output. Choose Word or HTML when those are essential.

Macro-enabled templates retain `.xlsm` output. Microsoft Excel may block macros in downloaded files according to the recipient's security policy. Test the intended delivery process with your administrator.

#### Make a PowerPoint template

1. Add field tags to a copy of a `.pptx` deck.
2. Create a **PowerPoint** template and choose the base object and data.
3. Upload, save the version, and generate a sample.
4. Open the result in PowerPoint and inspect every slide.

Basic fields, parent lookups, formats, and supported loops can be used. Complex slide layouts need testing.

#### Choose the right output

Excel templates produce Excel files; PowerPoint templates produce PowerPoint files. These templates cannot produce a combined PDF in bulk generation. Choose **Individual Files** for bulk Office output.

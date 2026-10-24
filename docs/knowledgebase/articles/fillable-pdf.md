Fill the fields of an existing PDF form using Salesforce information. This feature is **in testing**.

An existing PDF form is different from a PDF you merely want someone to sign. For signing, use [Send an uploaded PDF for signature](#sign-uploaded-pdf).

#### Map a form

1. Create a template with **Type = PDF** and choose its base object.
2. Include the Salesforce fields you want to use.
3. Upload the fillable PDF.
4. Open **Fillable Fields** after the scan completes.
5. Give hard-to-read form fields a friendly **Label**, such as **Mailing address**.
6. For each field, choose its **Data Path** from the template's selected data.
7. For a checkbox or radio button, check the PDF's **Checked Value** and map an appropriate value.
8. Click **Save as New Version**.
9. Generate a sample and inspect every mapped field.

#### Change a mapping later

Edit labels or mappings under **Fillable Fields** and use **Save Mapping**. If you replace the PDF, save it as a new version so its body and mapping are prepared together.

#### Know what to test

Portwood reads actual PDF form fields; it does not recognize a printed blank line as a field. Standard AcroForm PDFs are the intended format. XFA-only, encrypted, or unusual forms may need a different source file.

Generated fields normally remain editable. Do not assume the result has been flattened into a permanent printed page.

Bulk generation supports these templates as **Individual Files**. Combined-PDF modes are not supported for fillable PDF templates.

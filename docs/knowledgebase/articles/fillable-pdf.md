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

Generated fields remain editable unless you turn on flattening.

Bulk generation supports these templates as **Individual Files**. Combined-PDF modes are not supported for fillable PDF templates.

#### Flatten the generated PDF

By default, a generated PDF keeps its form fields, so anyone who downloads it can change the Salesforce values. Turn on flattening when the values must stay as Salesforce wrote them.

1. For a new template, click **Bring an Existing Template**, set **Type** to **PDF**, and check **Flatten PDF on generation**.
2. For an existing template, open **Edit**, go to **Settings** → **Output & Page Setup**, turn on **Flatten PDF on generation**, and click **Save as New Version**.
3. Generate a sample and open the PDF.

You are done when the values appear on the page and you cannot click into or change any field.

Flattening applies everywhere the template generates: download, preview, save to record, bulk, Flow, and signature documents. The option appears only when **Type** is **PDF**. It is off by default, so existing templates are unchanged until you turn it on.

#### What a flattened PDF looks like

Portwood draws each filled value as plain text where its field was, then removes the form. The field's own border and background color are not drawn for fields Portwood fills. Anything drawn into the PDF's page design stays, including boxes or lines placed behind a field.

If you want only the values with no boxes, draw the boxes as part of each form field — its border and background settings — rather than as shapes on the page. The boxes then show while the PDF is fillable and disappear when it is flattened.

#### Fix flattening problems

- **Generation stops with a message about compressed object streams.** The PDF stores its pages in a compressed form that Portwood cannot rewrite. Upload the same PDF again as a new version, then generate again. Or turn off **Flatten PDF on generation** for this template.
- **The option is missing.** Check that **Type** is **PDF**. If it still does not appear, you lack edit access to the **Flatten PDF on Generation** field. The **DocGen_Admin** permission set includes it; an admin using a custom permission set must grant access to that field.
- **A value is missing.** Check that the field is mapped under **Fillable Fields** and that the record has a value. Unmapped fields keep their original appearance.

Try the [unfilled service acceptance form](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/acceptance-form.pdf) with the Account **Name** field. Compare your result with the [flattened sample](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/flattened-acceptance.pdf). Both display in a PDF reader. Only the source contains an editable Name widget.

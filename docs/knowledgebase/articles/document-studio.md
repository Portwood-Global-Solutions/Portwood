Start with a file someone actually needs. Open one of these finished PDFs, try its links or scan its equipment labels, then take the HTML and data into your own org.

| Build this | Try this in the finished file | Make it your own |
| --- | --- | --- |
| [Commercial proposal](https://portwood.dev/demos/studio/field-quote.pdf) | Click **Harbor reserve** on the cover. Find the battery options, then jump back to the contents. | [Nested pricing tables](#cpq-quote) · [Contents, links and watermarks](#print-navigation) |
| [Renewal decision brief](https://portwood.dev/demos/studio/renewal-brief.pdf) | Read the recommendation, then find the team whose adoption is bringing the account below target. | [Design a brief that changes with the data](#renewal-decision) |
| [Field-service sheet](https://portwood.dev/demos/studio/service-sheet.pdf) | Scan either equipment card. Its QR code contains the asset identifier printed directly below it. | [Make a scannable service sheet](#service-sheet) |

A signer can also move from a Salesforce Screen Flow to a document prepared in the background. [Build the event-driven signing handoff](#event-signing-journey).

[Watch the studio chapters](https://portwood.dev/demos/portwood-3.64-demo.html?chapter=give-the-buyer-a-contents-page) to follow a buyer into the quote, a technician to the work order, and a signer through the Flow.

#### Generate your first studio sample

[Download the design studio files](https://portwood.dev/demos/studio/document-studio.zip) and unzip the folder. Each finished PDF comes with a matching HTML template and JSON sample. For your first run, choose the three files with the same name.

**Use the included practice Flow.** From the unzipped `document-studio/sandbox-flow` directory, an administrator can deploy the draft with `sf project deploy start --source-dir force-app --target-org YOUR_SANDBOX`. In Portwood, choose **New Template → Bring an Existing Template → JSON Data (from Flow) → HTML**, upload the design you want, and activate it. Use the API name in the table. You can start with just one design.

| Upload this template | Give it this API name |
| --- | --- |
| `field-quote.html` | `Guide364_Studio_field_quote` |
| `renewal-brief.html` | `Guide364_Studio_renewal_brief` |
| `service-sheet.html` | `Guide364_Studio_service_sheet` |

In Flow Builder, open **Guide · Try a document design**, then **Debug**, with rollback off. Choose your design, select **Generate PDF**, and open the resulting Salesforce File. The Flow already has the fictional sample data. To try different figures, edit the corresponding plain-text JSON resource in a copy of the Flow.

#### Use a practice Flow you already have

1. Upload and activate the HTML as above. Copy its template **API Name**.
2. Open a practice Screen Flow in Salesforce **Flow Builder**. Add a **Text** variable named `sampleJson`. For a one-off test, give it the contents of the JSON sample as its default value. A **Long Text Area** on a screen is another way to paste the sample at run time.
3. Add **Portwood: Generate Document**. Set **Template API Name** to your template, **JSON Data** to the text resource, **Output Format Override** to **PDF** and **Save to Record** to **False**. Run **Debug** with rollback mode off so Salesforce keeps the new File.
4. Check **Success**. When it is true, copy the returned **Content Document ID** and open the File in Salesforce Files. In Lightning Experience you can open `/lightning/r/ContentDocument/<Content Document ID>/view` on your org’s domain. When it is false, inspect **Error Message** before retrying. [Generate documents from Flow](#flow-generate)

For real orders, build the same data shape from the records the current user can read, or use an Apex data provider. The sample keys are a contract between the data and the HTML. They are not fields you need to add to Salesforce. [Choose a data source](#custom-data)

#### Brief your AI like a designer

Give the assistant your data shape, the sample HTML, and a change you can recognize in the finished document. For the proposal, try this request.

> Adapt the proposal for a purchasing manager. Keep the quoted net prices, currency and section IDs. Give optional services their own panel, keep one-time charges separate from monthly charges, and make the contents links follow their sections even when pricing spills onto another page. Return one HTML file and tell me which three things to check in the PDF.

For a renewal brief, describe what should happen when usage is missing. For a work order, specify the actual identifier a technician should scan. Open the generated file and try that task before you save the new template version. [Download the AI authoring reference](https://portwood.dev/demos/studio/portwood-authoring-context.md)

#### Give readers a text edition

Each sample also has an HTML reading copy with a document language, headings, labeled prices or usage figures, and the equipment identifiers in text. These are filled examples you can open in a browser or use with a screen reader. [Read the proposal](https://portwood.dev/demos/studio/field-quote-reading.html) · [Read the renewal brief](https://portwood.dev/demos/studio/renewal-brief-reading.html) · [Read the work order](https://portwood.dev/demos/studio/service-sheet-reading.html)

The three generated PDFs contain selectable text and lack PDF structure tags and document-language metadata. If your customer requires a tagged PDF, check the exported file’s tags, language, reading order, link names and table headers with your accessibility tools, and test the file with their assistive technology. Share the text edition alongside the visual copy.

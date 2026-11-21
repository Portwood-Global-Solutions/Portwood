# Use a design in your Salesforce sandbox

| Start here | What to look for |
| --- | --- |
| `field-quote.pdf` | Jump from the contents to a priced bundle. Check the draft mark, monthly price and separate optional service. |
| `renewal-brief.pdf` | See why an account owner should book an adoption review and which team needs attention. |
| `service-sheet.pdf` | Scan a QR code and compare the result with the printed equipment identifier. |

Open a `-reading.html` file for a filled text edition with headings and labeled tables. The HTML file without `-reading` is the Portwood template. Its matching JSON file contains fictional data for one run.

## Run the included practice Flow

From `sandbox-flow`, a Salesforce administrator can deploy the draft with `sf project deploy start --source-dir force-app --target-org YOUR_SANDBOX`. Upload and activate at least one HTML template using **JSON Data (from Flow)**. Use `Guide364_Studio_field_quote`, `Guide364_Studio_renewal_brief` or `Guide364_Studio_service_sheet` for its API name, matching the filename. In Flow Builder, open **Guide · Try a document design**, choose **Debug** with rollback off, select that design, then choose **Generate PDF**. Open the returned Salesforce File. The sample data is included in the Flow’s plain-text resources.

## Run from your own Flow

1. In **Portwood → New Template → Bring an Existing Template**, choose **JSON Data (from Flow)** and **HTML**. Upload the template HTML, save and activate it. Copy its **API Name**.
2. In a practice Screen Flow, collect the JSON file’s contents in a **Long Text Area** or a Text resource. Pass that value to **Portwood: Generate Document → JSON Data** along with **Template API Name**. Choose **PDF** for **Output Format Override** and leave **Save to Record** off for the first run.
3. Run with rollback off. On **Success**, open the returned **Content Document ID** in Salesforce Files. On a failure, inspect the action’s **Error Message**. Compare your output with the included PDF or text edition.
4. To attach a final quote, pass its real Salesforce **Record ID** and turn **Save to Record** on. Set `IsDraft` to `false` for the approved copy. In Signature Sender on the quote, choose **Salesforce file** and select that exact revision before placing signing fields.

The quote uses prepared CPQ-style data. Your org supplies priced lines grouped by their real parent and keeps recurring fees, options and one-time amounts distinct. For the renewal brief, keep `HasUsage` and `AtTarget` consistent with the figures. A work-order QR contains an offline identifier. Test its printed size on the intended stock.

[Open the Design Studio guide](https://portwood.dev/guide#document-studio)

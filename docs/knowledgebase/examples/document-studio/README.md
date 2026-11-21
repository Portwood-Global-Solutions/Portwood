# Use a design in your Salesforce sandbox

| Start here          | What to look for                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------- |
| `field-quote.pdf`   | Jump from the contents to a priced bundle. Check the draft mark, monthly price and separate optional service. |
| `renewal-brief.pdf` | See why an account owner should book an adoption review and which team needs attention.                       |
| `service-sheet.pdf` | Scan a QR code and compare the result with the printed equipment identifier.                                  |

Open a `-reading.html` file for a filled text edition with headings and labeled tables. The HTML file without `-reading` is the Portwood template. Its matching JSON file contains fictional data for one run.

## Generate a sample using Salesforce screens

[Follow the illustrated Design Studio walkthrough](https://portwood.dev/guide#document-studio). If your administrator has already supplied **Guide · Try a document design**, choose a design, select **Generate PDF**, and open the resulting Salesforce File.

1. In **Portwood → My Templates → New Template**, choose **Bring an Existing Template**. Select **JSON Data (from Flow)**, **HTML** and **PDF**. Copy the template’s API name. Select **Next → Create Template**. Under **Upload New Version**, select **Choose File**, pick the matching HTML, and select **Save as New Version**.
2. In a practice Screen Flow, create a plain-text **Text Template** resource containing the matching JSON file. Give it to the Portwood **Generate Document** action using **JSON Data**. Set **Template API Name**, **Output Format Override = PDF** and **Save to Record = False**.
3. Run **Debug** with rollback off. On **Success**, open the resulting File from **Files → Owned by Me**. If the action returns a failure, inspect its **Error Message**. Compare the output with the included PDF or reading copy.
4. To attach a final quote, pass its real Salesforce **Record ID** and turn **Save to Record** on. Set `IsDraft` to `false` for the approved copy. In Signature Sender on the quote, choose **Salesforce file** and select that exact revision before placing signing fields.

## Install the optional three-design practice Flow

In the `sandbox-flow` directory, an administrator can deploy the included draft with `sf project deploy start --source-dir force-app --target-org YOUR_SANDBOX`. Supply at least one active HTML template. Use `Guide364_Studio_field_quote`, `Guide364_Studio_renewal_brief` or `Guide364_Studio_service_sheet` for its API name, matching the filename. In **Setup → Flows** open **Guide · Try a document design**, select **Debug**, choose the matching design, then select **Generate PDF**. The three plain-text resources already hold the corresponding JSON.

The quote uses prepared CPQ-style data. Your org supplies priced lines grouped by their real parent and keeps recurring fees, options and one-time amounts distinct. For the renewal brief, keep `HasUsage` and `AtTarget` consistent with the figures. A work-order QR contains an offline identifier. Test its printed size on the intended stock.

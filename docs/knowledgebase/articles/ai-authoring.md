Use AI to help draft or revise an HTML template, then check the result in Portwood.

The downloadable reference includes three complete HTML designs, their sample data, and the working Screen Flow and event subscriber. Start by giving your assistant one design and the change you want to see in its PDF. [Open the design studio](#document-studio)

The current creation wizard offers an existing file or a blank Canvas. AI help is available in the HTML designer; it is not a separate starter-gallery path.

#### Use an external assistant

1. Open an HTML template in **Design**.
2. Choose **Copy AI Prompt** in the designer toolbar.
3. Review the prompt before copying it to the assistant your organization allows. The prompt can describe your fields and template.
4. Describe the document and changes you want.
5. Bring the returned HTML back into the designer or upload it as a replacement HTML file.
6. Review any fidelity findings and generate a real sample PDF.
7. Click **Save as New Version** when the result is ready.

Portwood's PDF engine cannot reproduce every web layout an assistant can invent. Ask for a simple document using tables, standard fonts, and supported PDF styling.

#### Use Generate with Agentforce

Your administrator can install the separate **Portwood Agentforce Extension** in an org with the required Einstein/Prompt Builder features. Once configured, **Generate with Agentforce** can draft or revise the HTML from inside Portwood.

The extension is optional. A normal Portwood install does not require AI features, and installing only the core package does not create them.

For extension installation, permissions, provider setup, and troubleshooting, see [Agentforce setup](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/AGENTFORCE_SETUP.md).

#### Check what AI made

Check field names, opening and closing tags, page size, images, long text, and page breaks. A clean browser preview is only the first check; the generated PDF is the one your reader receives.

#### Give your assistant the right fields and examples

Download the [Portwood authoring and automation context](https://portwood.dev/demos/studio/portwood-authoring-context.md) and attach it to your assistant along with **Copy AI Prompt** from the actual template. The download combines tag syntax, CSS, complete example HTML, Flow contracts and signing recipes. The copied prompt supplies your template's data shape. Add the approved snippet keys, font tags, signer roles, output format and generation entry point you intend to use.

Try this request: “Build a two-page service review. Use the Account and Opportunities fields in my query. Keep the totals together, use our approved handoff snippet, and give me the body and footer separately. Then show how to pass the single signer's returned URL to a Screen Flow.” Check the PDF with zero rows and again with enough rows to cross a page. Test the Flow separately with an authorized practice signer.

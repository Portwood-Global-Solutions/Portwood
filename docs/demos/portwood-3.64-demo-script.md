# From account to acceptance
Portwood product walkthrough. The voiceover is synthesized from this script. Sandbox outputs and current UI are labeled in the film. Earlier guide captures illustrate established workflows.

## 0:00  The finished packet

**On screen**  page 1 of 4 → portfolio overview → acceptance page

Alder Works needs three things before a service engagement can start. A schedule that finance can check, an acceptance form with the right account on it, and a signature the service team can find later. This is the actual schedule. We generated it in Salesforce from fifty-four fictional service lines. Let’s work backwards from the file, then follow it forward to acceptance.

## 0:22  Start with one field

**On screen**  Account letter → Account HTML → PDF

Here’s the smallest version of the job. The template says “Welcome,” followed by Name in braces. Select Account as the source, choose Name in the query, and upload the HTML. The generated page now says “Welcome, Alder Works.” If you can get that one heading right, you’ve proved the connection between the record, the query, and the template.

## 0:43  Choose a starting point

**On screen**  New template → Choose a source

In the template library, choose Bring an Existing Template when the team already maintains a file. Word works well for flowing text. HTML gives you control over print layout. Canvas gives you a page you can arrange visually. Excel and PowerPoint keep their native formats. Filling a PDF form is a different route again. Start with the file the recipient actually needs.

## 1:06  Design and bind

**On screen**  Canvas first document → Choose data

On Canvas, position the elements, choose fields and preview with a sample record. You can link elements, group them into named blocks, and reuse a design. For a growing schedule, I prefer a table. On the Account, select the related Opportunities and the fields for each row. Keep a stable sort order so line fourteen stays line fourteen when someone checks the printed copy.

## 1:29  Build the schedule

**On screen**  One row in the HTML template → optional decimals → fixed-decimal total

Look at the first and last cells of this row. The first opens the Opportunities loop. The last closes it. Portwood repeats the whole row, and Row Number counts each entry. Outside the table, a sum gives us the combined estimate. We used optional decimals for the lines. One hundred stays one hundred, and one hundred point one keeps its tenth. The total always prints two decimal places.

## 1:53  Print across pages

**On screen**  continuation header → last row and total → running footer

Here’s where a short preview can fool you. On page two, the column headings need to repeat, and a row near the bottom needs to stay readable. The stylesheet uses a real table header and the renderer’s table pagination setting. The footer has a second line for page numbering. On the third page, the last line is fifty-four. The total is five thousand four hundred dollars and thirty-five cents.

## 2:17  Use richer layouts

**On screen**  KPI band and stage chart → Paged-media stylesheet → per-stage subtotals

For a denser executive report, set widths on the columns and give each cell its own padding. Use solid fills for section bands and put full-page artwork in the background setting. A browser can draw a gradient, rounded corners, or an inline vector graphic that disappears in the final PDF. For a branded shape, use a sized image asset. For charts, use a prepared image on a supported path, or a CSS bar or pivot table.

## 2:43  Manage shared language

**On screen**  Snippet editor → Snippet preview → expanded shared clause

The service coordinator owns this handoff clause. In Assets, open Terms and Snippets. HTML source shows the fragment; Preview shows the wording. The template holds just the snippet key. When we generate the schedule, the clause picks up the account name. A later approved revision updates future documents. The files already sent to clients keep the wording they had.

## 3:07  Keep a brand portable

**On screen**  Assets and fonts → Copy keys from the target org → Custom fonts

For a logo, copy the image tag and give it a print size. Deactivate or reactivate the asset with the same key. For a typeface, copy the approved font tag into an inline style. A stable font name can travel to another org with the same approved face. And when a title needs translated wording, use a Salesforce Custom Label. It resolves in the language of the person running generation.

## 3:31  Give AI the actual schema

**On screen**  Context for the assistant → final PDF check

If I ask an assistant for a service review without telling it the data shape, it can produce a beautiful field that doesn’t exist. The designer’s Copy AI Prompt supplies the selected fields. Attach the authoring reference for recipes, font and snippet rules, chart limits, and Flow contracts. In an org with the Agentforce extension, you can also ask for a revision in the designer. Generate a PDF to check the answer.

## 3:56  Fill and flatten

**On screen**  Source PDF · one editable AcroForm field (Input-1) → zero AcroForm fields

Here is a real AcroForm. On the source PDF the account name is an editable field. Our template maps Name and turns on Flatten PDF on generation. This is the sandbox output. Alder Works is still visible, and the PDF has zero form fields. If a client needs to keep typing in the form, leave flattening off. An older compressed form may need a fresh upload before it can flatten.

## 4:21  Deliver one file

**On screen**  Record runner → Record page actions

From a record, the runner can download a file, save it to Files, or do both when configured. A document button can preview the exact file it then downloads. An email button walks through template, preview, and recipients. Choose None to clear the suggested record email and enter a recipient manually. The subject is plain text. Check the recipients before sending.

## 4:44  Run a batch

**On screen**  3.64 sandbox · choose a template (bulk-start) → Step 2 · record filter → Bulk completed

For a batch, start with a filter you can inspect. Record Type developer name and standard lookup fields such as Owner Email work alongside custom relationships. Check a sample before choosing individual files or a combined PDF. A submitted job has an ID. The team checks the completed count, errors, and actual files before treating that batch as delivered.

## 5:07  Combine existing Files

**On screen**  Merge PDFs · action inputs → Sandbox duplex packet · page 1 (Packet-1) → Sandbox duplex packet · page 3 (Packet-3)

We already have a letter and a flattened form. Merge PDFs takes the exact Salesforce file versions in order. We turned on duplex padding. In the actual output, the letter is on page one, the form is on page three, and pages two and four are blank. The action also returns both file IDs. For a larger packet, check the input byte budget before sending it through Flow.

## 5:31  Prepare a signature request

**On screen**  Signature source → Signature fields → Signature review

You can send a template, or upload an existing PDF and place fields on it. A signature, initials, a signed date and a date the signer picks are different fields. Assign them to the right person. The active template picker follows the record’s object. For an automated request, build the signer collection with a name, email and matching role. Save the resulting request ID so you can follow the same agreement throughout.

## 5:56  Sign in the interview

**On screen**  Screen Flow → 3.64 sandbox · embedded signing (sign-flow) → 3.64 sandbox · guided signature field (capture-signature)

When the signer is already signed in, put Portwood Sign in Flow on the screen. For one person, pass the returned Signer URLs collection. The component uses its first link. Review the document, complete the fields, then confirm consent. The Flow can branch on Signed, Declined, and Request complete. One person finishing a parallel request is a different milestone from everybody finishing.

## 6:20  Navigate to the signing site

**On screen**  Signing-site handoff → 3.64 sandbox · signing-site link (site-handoff) → 3.64 sandbox · request remains pending (site-pending)

Some journeys call for the signing site itself. The example Flow extracts one signer’s URL and passes it to Open a Page. The handoff screen also offers a link if the browser does not open the page. Now imagine the signer simply closes that tab. Nothing has been signed. Check signing status reads the saved request again, and keeps the interview pending until the outcome changes.

## 6:44  React to an approval

**On screen**  Approval subscriber → Screen interview and event subscriber

An approval can come from another process entirely. Publish a business event after the approval commits. A platform-event-triggered Flow reads the approval key, checks the business record, and creates the signature request. A unique tracking key lets a repeat delivery find the first request. If an interactive screen started the work, give it a receipt to check. The background subscriber prepares the request. Navigation happens in the user’s browser.

## 7:11  Know when to act

**On screen**  Portwood Signature PDF event → Fulfillment check

Portwood’s own signature PDF event carries a request ID and can identify the signer who caused it. That matters when the second person signs before the first. The event can arrive before the final file exists, and some signing paths finish without it. For fulfillment, check the saved request for Signed and the protected signed file ID. Use that request ID to keep your downstream action from running twice.

## 7:36  Follow the signer journey

**On screen**  Signer document → Signer enter signature → Signer complete

On the signing page a person can type or draw, unless the org or template requires typed signatures and initials. The page redraws at higher resolution when zoomed. Korean and other non-Latin names and dates are supported in the signed file and certificate. The certificate can include a clickable verification link. An authenticated embedded signer uses the same signing service; a guest or a prepared uploaded PDF uses the signing site.

## 8:05  Manage invitations

**On screen**  Typed policy → Brand editor → Email templates

A sender can resend an eligible open request or revoke the outstanding unsigned links. If you revoke, check email status separately from request status. A notice needs the configured sender address. Brands and email templates control the communication, including the revoked notice. A Portwood User can send requests. For embedded signing, an internal non-admin may also need the Portal Signer permission set.

## 8:31  Move between releases

**On screen**  Sandbox-to-sandbox migration → Before applying

When you switch back to an older template version, check the body, query, title and page setup together. HTML versions keep their own body files. Background workbook generation handles sheets in compressed passes and preserves macros. To move configuration, start the migration command with a dry run between two nonproduction orgs. Review conflicts and mappings, then approve staged fonts in the destination. The command’s environment check belongs to the CLI.

## 9:01  Keep Office files editable

**On screen**  Generated XLSX · Account worksheet (Sheets-1) → Generated XLSX · Handoff worksheet (Sheets-2) → Generated PPTX · account cover (Slides-1)

Finance asked for a workbook, and the account team asked for a slide. These came from the same sandbox account. On the workbook, both the Account tab and the Handoff tab contain the merged account name. On the PowerPoint slide, it appears inside the original layout. Use individual files for Office output in bulk. A macro-enabled workbook keeps its macro format. For a PDF deliverable, start with a template that supports PDF.

## 9:28  When a control is missing

**On screen**  Check the installation → If the problem persists

If a button you saw here is missing, start with two questions. Which version of Portwood is installed, and has the org been upgraded? Your Salesforce administrator can find the answer in Setup, under Installed Packages. If you are current, try the same record as the person who needs the button. Check their permission set, the record page, and whether the template is active. Those details give support a much better starting point than a screenshot of an empty list.

## 9:54  Give the buyer a contents page

**On screen**  Generated quote · buyer’s contents page → Destination · Harbor configuration and return link → Expanded quote · terms now begin on page seven

Imagine you are the buyer. You have four pages in front of you and one question about the Harbor configuration. Click Harbor on the cover and you land on the right bundle. Back to contents takes you home. Now add forty-two lines to the quote. The commercial terms move from page four to page seven, and the contents number moves with them. The draft stamp follows every page until the quote is ready to issue.

## 10:18  Price the bundle once

**On screen**  Generated quote · Atlas component schedule → Generated quote · Harbor options → Generated quote · commercial terms

Here are two field stations on the same order. Read down the Atlas table: the enclosure and accessories add up to six thousand five hundred forty dollars. Harbor has its own components. Its optional inspection stays outside the committed amount. Up front, the buyer sees ten thousand six hundred seventy dollars once and one hundred twenty a month. That is the same deal the sales team priced. The document gives each number a place where the buyer can check it.

## 10:44  Let the data change the brief

**On screen**  Generated brief · adoption review → Higher adoption · same template → Missing usage · same template

Would you walk into this renewal meeting ready to ask for a signature? At seventy-two percent adoption, the brief recommends booking an adoption review. The team bars make it easy to see where to start. Give the same design eighty-four percent adoption and the headline changes to preparing renewal terms. Take the reading away and it asks for usage data. When you brief an AI assistant, spell out that third case. An unknown reading and a zero call for different conversations.

## 11:14  Put the work order in the field

**On screen**  Generated work order · equipment checklist → Generated work order · second unit and receipt

At the equipment cabinet, a technician needs the right unit, the right checks, and somewhere to write. Each card has its own checklist and a QR label. Scan the pump label and you get the pump’s identifier, even offline. The identifier is printed underneath for a person who cannot scan it. The tear-off receipt goes back to the office. Try the sheet on the printer your team takes into the field.

## 11:38  Follow the event into signing

**On screen**  Preparing the agreement → Flow Builder routes the private URL to a new tab → The signing site asks for email verification → A signer can reopen the same agreement from the status screen

Back in Salesforce, I choose Prepare agreement. The screen sends the event, and the background Flow prepares my agreement. When I open the signing page, this sandbox asks me to verify the email on my Salesforce user. Let’s say I close that tab to look something up. Back in the Flow, I check the status. It still needs my signature. I select Reopen my signing page and Check again. There’s my agreement. I can pick up where I left off.

## 12:04  Close the loop

**On screen**  Generated in the Portfolio 1 → Generated in the Review 4 → Try it with your own document

We started with one field and finished with something a service team can use. The schedule adds up, the form keeps the account name, and the workflow has a place to check for the signed agreement. The guide includes the HTML, footer, example Flow, and the PDFs you’ve seen here. Bring one of your own documents, one ordinary record and one difficult record. Those three things make a very good next demo.

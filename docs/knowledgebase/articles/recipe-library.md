Build a client service packet in stages. The first exercise needs one Account and permission to create an HTML template. For the later exercises, use a sandbox where you can manage templates, run a Screen Flow and inspect its records. Use fictional records and signers for practice.

[Explore finished quotes, renewal briefs and scannable work orders in the design studio.](#document-studio)

| Start with | Build this | Check your result |
| --- | --- | --- |
| One Account | [A one-field welcome letter](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/account-letter.html) | The PDF heading contains the Account name. |
| Related Opportunities | [A paginated service schedule](#css-print-lab) | The column labels repeat and the final line appears once. |
| Shared language | [A versioned handoff clause](#shared-content) | Two templates using the same key pick up the new active text. |
| A fillable PDF | [A fixed acceptance form](#fillable-pdf) | The account name is visible and the flattened output has no editable widget. |
| Two existing Salesforce Files | [An ordered PDF packet](#merge-pdfs-flow) | Both source documents appear in order in a new File. |
| A signed-in customer | [Acceptance inside a Screen Flow](#flow-signatures) | The Flow advances after the component confirms the outcome. |
| A signer using the signing site | [A navigation link in a Screen Flow](#signing-site-handoff) | The intended signer opens the site and the interview can check the request again. |
| Approval or signing activity in another process | [An event-driven signature workflow](#signing-events) | One approval produces one request and a completed agreement produces one downstream action. |

#### Generate the one-field letter

1. Download the letter above using GitHub's **Download raw file**. In Portwood, choose **New Template → Bring an Existing Template**. Choose **Salesforce Record (SOQL)**, **Account**, and **HTML**.
2. Select **Name** in the data picker and upload the HTML body. Save the template and select an Account you can read.
3. Generate the PDF. A record named **Alder Works** should produce **Welcome, Alder Works**. Try a second account before moving on.

The whole binding is `<h1>Welcome, {Name}</h1>`. HTML controls how the heading looks. The query supplies the value. Adding a field in just one of those places leaves part of the job unfinished.

For smaller pieces to copy into your own design, including barcodes, headers, totals and signature lines, use the [HTML recipe collection](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/html-recipes.md). For a document with your own fields, start from the [AI authoring workflow](#ai-authoring).

Compare your result with the [finished welcome letter](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/account-letter.pdf). To practice merging, pair it with the [flattened service acceptance PDF](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/flattened-acceptance.pdf).

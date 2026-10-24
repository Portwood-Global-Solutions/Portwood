Start with a working example, then change one thing at a time.

These files use standard Salesforce fields. The fictional examples use Northstar Bikes, its Contacts, and its Opportunities.

#### Account brief

**Makes:** A customer summary with Contact rows, Opportunity rows, and a total.

**Base object:** Account. **Type:** HTML. **Output:** PDF.

[Open the Account Brief template](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/account-brief.html). Use GitHub's download control to save the HTML file, then [import it](#import-html).

Include these fields:

- Account: Name, Industry, Phone, BillingCity, BillingState, AnnualRevenue.
- Contacts: FirstName, LastName, Title, Email.
- Opportunities: Name, StageName, Amount.

Sort Contacts by LastName and Opportunities by Name. Generate with an Account that has both lists.

![A generated Northstar Bikes Account Brief with Contact rows, Opportunity rows, and a 40,000 dollar total](docs/images/userguide/v3.60/account-brief-result.png)

**Try next:** Remove one optional value, add another Contact, change a heading, then regenerate. The corresponding values and row count should change without redesigning the table.

#### Opportunity summary

**Makes:** A one-page deal summary with a parent Account, formatted amount/date, and a conditional closing message.

**Base object:** Opportunity. **Type:** HTML. **Output:** PDF.

[Open the Opportunity Summary template](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/opportunity-summary.html).

Include Name, Account.Name, Amount, StageName, CloseDate, and IsWon. Generate once for a won Opportunity and once for an open one; the final message should change.

#### Signing practice

**Makes:** A fictional practice document with a Customer signature and signing date.

**Base object:** Account. **Type:** HTML. **Data:** Name.

[Open the Signing Practice template](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/signing-practice.html). Use the signer role **Customer** to match its tags.

Use it in a test org before sending real agreements. It demonstrates signature placement; it is not a business contract.

#### More advanced examples

The repository's [demo template library](https://github.com/Portwood-Global-Solutions/Portwood/tree/main/DEMO%20TEMPLATES) includes additional layouts. Read each example's field and object requirements before importing it; some require the demo schema or a developer-supplied provider.

#### Advanced layout lab

Use [Repeat table headers](#repeat-table-headers) for the 90-row, four-page HTML lab and [rich page footers](#running-headers-footers) for its two-line Page X of Y footer. The downloadable body/footer and scratch-only verification script make the recipe repeatable for later releases. For subscriber code, use the [custom provider](#apex-data-provider) and [Queueable generation example](#apex-generation).

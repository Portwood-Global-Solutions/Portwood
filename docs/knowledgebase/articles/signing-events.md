Use this recipe when an approval happens in one process and someone signs later, possibly in another session. Imagine a sales manager approves a service agreement. The customer should receive one request, and the service team should start work only after the signed file is ready.

#### Set up the handoff

| When this happens | Have Salesforce do this | What you can check |
| --- | --- | --- |
| The manager approves the agreement | Save the approved record and publish an **Agreement Approved** platform event. This is an event your administrator creates. | The approval has a stable reference that survives a retry. |
| The event arrives | Start a **Platform Event–Triggered Flow**. Find the approved record and signer, then call **Portwood: Create Signature Request**. | The tracking record contains one Portwood request ID. |
| The customer is ready | Deliver their invitation, or let their signed-in Screen Flow open the signing site. | The intended customer sees the right agreement. |
| Everyone finishes | Check the request is **Signed** and the signed File exists. Use that request ID to start fulfillment once. | The service team can open the completed agreement from the record. |

A background Flow has no browser to navigate. If a person is waiting in a Screen Flow, give the interview a receipt it can check. A **Check again** button can read that receipt after the background work finishes. [Open the signing site from a Screen Flow](#signing-site-handoff)

#### Test it before turning it on

Use a practice approval and a controlled signer. Deliver the same approval twice and confirm you still have one request. With parallel signing, have the second person sign first. The first signature should leave fulfillment pending. After everyone signs, open the completed File and check fulfillment ran once.

The [Flow Builder worksheet](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/signature-event-recipe.md) gives your admin the event fields, unique-key handling, request and signer lookups, and the conditions for final file delivery.

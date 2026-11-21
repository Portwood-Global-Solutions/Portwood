# Build the event subscriber for a signing workflow

For a signed-in employee or portal member signing an agreement, arrange a Portwood site license. Public signing links run under the signing site’s licensed guest user. [Choose signing licenses](https://portwood.dev/guide#user-licenses)

Use a business event to start an agreement, then let the rest of the process continue when the signed file exists. A platform-event-triggered Flow runs in its own transaction and has no screen. Keep the customer's navigation in the [Screen Flow handoff](../../UserGuide.md#signing-site-handoff).

#### Start a request from an approval event

1. In your own org, define **Agreement Approved** (`Agreement_Approved__e`) with **Publish After Commit** and Text fields `Approval_Key__c` and `Opportunity_Id__c`. These are example names for metadata you create. Publish the event from the approval transaction after recording who approved which agreement version.
2. Create a **Platform Event–Triggered Flow** on that event. Read `$Record.Approval_Key__c` and `$Record.Opportunity_Id__c`. Get the approved Opportunity, confirm its approved version still matches the key, and resolve the intended signer from the approved record. The subscriber needs document, signer and business-record access in its running context.
3. To keep a replay from sending another invitation, create a tracking record with a **unique** approval-key field. Use a value identifying the approval and document version. An ordinary Get-then-Create check allows two simultaneous subscribers through. On a duplicate-key fault, load the existing row. Reuse its request ID, or route an unfinished attempt for reconciliation.
4. Call **Portwood: Create Signature Request** once for the claimed work. Pass the template API name, related record and signer collection. Store the returned request ID and email status on the tracking record. Route both unsuccessful results and faults to a recoverable state. On retry, check for an existing request before creating another.
5. Use Portwood's branded invitation for an unattended send, or start a separate, authorized interactive workflow for the signer. Keep signer URLs out of event payloads. An event subscriber cannot navigate a browser. [Salesforce platform-event Flow behavior](https://developer.salesforce.com/docs/platform/platform-events/guide/platform-events-subscribe-flow.html)

#### Follow activity from the Portwood signing site

On the package paths that publish it, **Portwood Signature PDF** (`portwoodglobal__DocGen_Signature_PDF__e`) is an after-commit signal used by Portwood's own subscriber. To inspect those signals, create a second **Platform Event–Triggered Flow**, select this existing event, and use the fields below. Subscribe to events produced by signing. Publishing this internal event yourself can invoke package PDF and notification work.

| Event field in a subscriber org         | What to do with it                                                                                                                                                                                       |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `$Record.portwoodglobal__Request_Id__c` | Get the Portwood Signature Request by ID. Use its current status and related record.                                                                                                                     |
| `$Record.portwoodglobal__Signer_Id__c`  | When populated, get that signer and verify its request matches. In parallel signing this identifies the actor even if people signed out of order. An empty value supports request-level processing only. |

A notification can arrive between signers, on a decline, or before final file generation finishes. The package also has paths that complete the PDF without this event. For a business milestone that must cover every signing path, use an after-save record-triggered Flow on **Portwood Signature Request**. Check for **Signed** and a populated **Protected Signed Content Document Id** when the subsequent action needs the final File. Run when the record first meets both conditions. Read the File with the appropriate access. Use the request ID as a unique completion key when delivering to another system.

#### Prove the two boundaries

In a sandbox, publish the same fictional approval twice. Expect one tracking record and one request. Sign the second invitation first on a parallel two-person test, then decline or complete the other in separate tests. Check that the first signature never starts fulfillment, a decline takes the stopped path, and the completed case links the signed File once. For an uploaded PDF, also exercise finalization without relying on receipt of the package event.

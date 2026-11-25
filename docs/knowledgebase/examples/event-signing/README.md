# Request an agreement and open it from a Screen Flow

This subscriber project lets one signed-in person prepare and open a practice agreement. The screen publishes a platform event. A second Flow creates the Portwood request and writes the result to a private receipt. The same screen interview reads that receipt and uses Salesforce’s standard **Open a Page** action to open the signer’s URL. A third Flow clears that URL after the handoff window.

[See the signer’s screens](https://portwood.dev/guide#event-signing-journey) or [build it step by step in Salesforce Setup](https://portwood.dev/guide#signing-handoff-setup).

This sample starts with a signed-in user. Authenticated signing for employees or portal members requires a Portwood site license. A public signing page also needs its guest user configured. [Plan licenses and request a quote](https://portwood.dev/guide#user-licenses).

## Install this optional project in a sandbox

1. Use a sandbox with Portwood installed and a configured Salesforce Site or Experience Cloud signing page. The signer and Flow execution users need the Portwood permissions and record access appropriate to their roles. The source uses Salesforce Flow API 68 and the managed `portwoodglobal` namespace.
2. From this project’s directory, deploy the sample objects, permission set and three **Draft** Flows. Substitute your sandbox alias in the command.
   ```bash
   sf project deploy start --source-dir force-app --target-org YOUR_SANDBOX
   ```
3. In Portwood, create an **HTML** template using **Salesforce Record (SOQL)**. Choose **Guide Signing Receipt** as the base object and select its **Name** field (the receipt number). Upload `acceptance.html`, give the template the exact API name `Guide_Event_Acceptance`, and save and activate it. The template puts the **Customer** signing tags directly in the body. This sample signs the receipt-backed agreement. To sign an already-generated quote PDF, use Portwood’s uploaded-PDF preparation route.
4. Assign **Guide Signing Handoff** to your test signer. Grant **Run Flows** and access to **Guide · Request and open an agreement** if your org restricts flow access. Keep the receipt object private. Limit users with administrative, hierarchy or sharing-rule access to its signer-link field. The included permission set gives users read access to receipts and permission to publish this event. The background Flow writes receipts.
5. In Flow Builder, activate **Guide · Clear expired signing link**, **Guide · Prepare the agreement**, then **Guide · Request and open an agreement**. Use a supported Lightning host, for example the standard Flow component on a Lightning app page. Test with the person who will actually use the interview. Configure the org’s **Default Workflow User** if Salesforce prompts for one when you activate the scheduled cleanup.
6. Choose **Prepare agreement**, then **Open signing page**. If preparation is still pending, choose **Check again** in the same interview. The site link is for the publishing user only. After returning, use **Check signing status**. If the signer closed the signing tab, **Reopen my signing page → Check again** rechecks the private receipt and opens the same request. After signing, the Flow can report that the final file is still being saved. The finished path requires both the signed status and the protected signed File ID.

## Follow the fields

| Element | Mapping |
| --- | --- |
| Publish | Create `Guide_Sign_Requested__e` with `Receipt_Key__c = $Flow.InterviewGuid`. The event uses **Publish After Commit**. The next Screen commits the publication. |
| Claim | Create a private `Guide_Sign_Receipt__c` with unique `Receipt_Key__c`, `Stage__c = Preparing` and `OwnerId = $Record.CreatedById`. Existing keys exit the subscriber. The database’s unique constraint also prevents a concurrent duplicate from creating a second request. A concurrent duplicate-key fault can appear in failed Flow interviews. |
| Identify the signer | Read the publishing User’s name and email. Set the **DocGenSigner** role to **Customer**. Pass that one signer to **Portwood: Create Signature Request** with **Single** signing order, **Send Branded Emails = False** and one day of validity. The verification policy comes from the template and org. |
| Store the outcome | On success store `Request_Id__c`, the single returned URL, its handoff expiry and **Ready**. Mark a failed or unsuccessful request **Failed** so the interview can show a recoverable explanation. Investigate that receipt before initiating another submission. |
| Read the result | Filter by the interview key **and** signed-in owner. **Open a Page** receives `pageType = WebPage` and `webPageUrl = Receipt.Signer_URL__c`. The handoff screen also has a link. Rechecking reads the existing receipt. |
| Clear the link | A scheduled path clears `Signer_URL__c` approximately one day after the receipt becomes ready. The interview separately checks `Link_Expires_At__c` before opening it. Keep platform-event payloads, analytics, recordings and logs free of signing URLs. |
| Confirm completion | Read `portwoodglobal__DocGen_Signature_Request__c` using the stored request ID. Read the protected File through Salesforce’s normal access rules. |

The retry key covers one interview. For repeat approvals across interviews, use a unique business key tied to the approved proposal and version. A business process with multiple signers also needs per-signer authorization for each handoff. The separate approval-event recipe in the guide covers those changes.

[Open a Page action](https://help.salesforce.com/s/articleView?id=platform.flow_ref_elements_actions_open_a_page.htm&language=en_US&type=5) · [Platform-event-triggered Flows](https://developer.salesforce.com/docs/platform/platform-events/guide/platform-events-subscribe-flow.html)

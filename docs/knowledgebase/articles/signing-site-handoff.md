Give the person in a Screen Flow a **Review and sign** link to the configured Salesforce Site or Experience Cloud signing page. Keep the interview available so the person can return and check progress. For a signed-in user who should stay on the same screen throughout, use [Sign inside the Flow](#flow-signatures).

#### Create the request in the interview

1. Start with an authenticated user authorized to act for the selected record and signer. Resolve the signer from that verified relationship. Keep one signer's URL in this interview.
2. Configure **Portwood: Create Signature Request** with the template API name, related record ID, a one-person **DocGenSigner** collection and **Signing Order = Single**. Set **Send Branded Emails = False** when this screen supplies the initial invitation. Let the template's verification policy apply.
3. Store **Signature Request Id**, **Signer URLs**, **Success**, **Email Status** and **Error Message**. Connect the fault path and handle an unsuccessful result before showing a navigation control.
4. Add a **Loop** over **Signer URLs**. Inside it, assign the current item to a Text variable called `signerUrl`. This example accepts exactly one signer. With several recipients, use the URL matching the authorized person's position in the original signer collection. Giving everyone the first URL gives them the first person's signing capability.

#### Build the handoff screen

Add **Display Text** to a Screen. Enter **Review and sign**, select those words in the rich-text editor and set their link destination to the `signerUrl` resource. The underlying display text looks like this:

```html
<a href="{!signerUrl}" target="_blank">Review and sign</a>
```

This is **Flow screen markup**. Portwood HTML templates use a different merge language. Use the complete URL returned by the action so the site path, namespace and signer credential travel together. Keep it out of record notes, events, analytics and screen recordings.

Label the screen's Next button **Check signing status**. After the screen, use **Get Records** on **Portwood Signature Request** using the saved request ID. A **Decision** routes **Signed** to confirmation, **Declined** or **Cancelled** to a stopped path, and **Sent** or **In Progress** to a status screen with a route back to Get Records. Returning to the tab or clicking the link does not establish completion. For a file-dependent next step, also wait for the verified output file. [Signing events](#signing-events)

#### Try both paths

Open the link, inspect the document, then close its tab without signing. **Check signing status** should keep the interview pending. Repeat with a controlled signer, complete consent, then check again. Test an expired or revoked link as well. Returning to the status screen should reuse the same request.

For an invited guest, deliver that person's signing link through the configured invitation. A public-facing Flow must establish who may initiate a request and who may see each link before exposing any signer credential.

#### Use the Open a Page navigation action

When your Screen Flow host supports Lightning local actions, place **Open a Page** after the screen where the intended signer chooses to continue. Set **Page Type** to **Web Page** and use the single returned URL as the web page URL. In Flow metadata the action is `flowruntime:openAPage` with inputs `pageType = WebPage` and `webPageUrl = {!signerUrl}`. Route a navigation fault to the link screen. Treat successful navigation as **opened**. Use the saved request and File for the signed outcome. Debug in the Lightning or Experience Cloud host where the Flow will run, since tab behavior depends on that container.

When an event subscriber prepares the request for the screen, the publisher and subscriber finish in separate transactions. Give the interview a receipt ID before publishing. On **Check again**, get that receipt with the signed-in person's access. Route pending preparation back to a screen, a preparation fault to a recoverable explanation, and a ready receipt to the navigation action. Keep the request ID on the receipt. If the two transactions must exchange a signer URL, restrict that value to its intended signer and the handoff process, clear it when its purpose ends, and keep it out of event payloads and debug transcripts. [Build the event subscriber](#signing-events)

The [downloadable Screen Flow](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/acceptance/flows/Guide364_Service_Acceptance.flow-meta.xml) is a subscriber example for API 68. Deploy it as a draft in a sandbox with Portwood 3.64, then debug with input Text variables `recordId` and `templateApiName`. Use an authorized test record and a signable template with a **Customer** role. It uses the logged-in user's name and email and suppresses the initial invitation. Leave the site checkbox clear for embedded signing or select it to exercise **Open a Page**. Before exposing a copy to other users, have its launcher resolve the allowed record and template and enforce your signer eligibility rule.

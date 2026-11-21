A signed-in person is completing a Screen Flow. They choose **Prepare agreement**, Salesforce prepares the request in the background, and **Open signing page** takes them to their own Portwood signing page. Back in the interview, they can check whether the signed File is ready.

[Download the working Flow project](https://portwood.dev/demos/studio/event-signing.zip) · [Read the setup and field map](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/event-signing/README.md)

#### Follow one request across the two Flows

| Where | What happens | What to look for |
| --- | --- | --- |
| The person’s Screen Flow | **Create Records** publishes **Guide Sign Requested** with the interview’s receipt key. The next Screen ends that transaction. | The person sees **Preparing your agreement**. The event carries the key only. |
| The event-triggered Flow | The subscriber claims a private receipt with that unique key, resolves the publishing user and calls **Portwood: Create Signature Request**. | One receipt holds the Portwood request ID and the intended signer’s returned link. A replay reuses the existing work. |
| The original interview | **Get Records** reads the receipt by interview key and signed-in owner. A ready receipt takes the **Open a Page** action. | The browser opens the signing page. If the event is still being processed, **Check again** reads the same receipt. |
| After the handoff | The interview re-reads the saved Portwood request. | **Signed** and a populated protected File ID lead to **Signed file ready**. Closing the browser tab leaves the request pending. |

#### Choose the page you want to open

In the Screen Flow, choose **Action → Open a Page**. For the **signer**, choose **External Web Page**, set **URL** to the single signer URL from the receipt, and choose **New Browser Tab**. Keep the **Review and sign** link on the following screen for a person whose browser blocks the tab. The downloaded sample uses `flowruntime:openAPage`. Salesforce offers this action in Flow API 67 and later. [Salesforce Open a Page](https://help.salesforce.com/s/articleView?id=platform.flow_ref_elements_actions_open_a_page.htm&language=en_US&type=5)

For an **internal coordinator** who needs the Salesforce record, select **Salesforce Record Page** in the same action. Set **Record ID** to the saved signature request ID, **Object Name** to `portwoodglobal__DocGen_Signature_Request__c`, and **View Mode** to **View**. That destination shows the request to someone with record access. To collect a signature, use the signer’s own web page.

#### Set up your own signing journey

The sample is for a single signed-in person signing their own agreement. It includes a small record-backed template, a private receipt, a **Publish After Commit** event and a cleanup Flow for the temporary signer link. The subscriber uses the publishing Salesforce user’s identity. The event contains no name, email or signing credential. The **Signing Order** is **Single**, and **Send Branded Emails** is off because the interview handles delivery. The template and org’s signer verification policy still applies.

For an approval on an Opportunity, resolve the authorized signer from the approved record and use an approval-and-document-version key to recognize repeat business submissions. The example’s interview key protects retries of one interview. A newly started interview is a new submission. [Start from an approval event](#signing-events)

For several signers, give each person only their own link. If the person wants to sign directly on the Flow screen, use [Portwood: Sign in Flow](#flow-signatures).

In our sandbox the standard action opened the site’s **Verify your email** screen. Returning without signing left the request pending. Replaying the same event produced one receipt and one request. If the site fails to open, check the signer’s **Guide Signing Handoff** permission set and use **Review and sign** on the handoff screen. [Watch the event-to-signing chapter](https://portwood.dev/demos/portwood-3.64-demo.html?chapter=follow-the-event-into-signing)

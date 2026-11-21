To let someone wait for a signing link in a Salesforce screen, give the screen and the background Flow a private place to meet. In this example a **Guide Signing Receipt** remembers which request belongs to the person. A **Guide Sign Requested** event tells the background Flow to start preparing it. Set these up once in a sandbox.

This example starts with a signed-in person. For a portal or employee signing rollout, arrange a **Portwood site license**. It also covers the guest user if the Flow opens a public signing page. [Check signing licenses and request a quote](#user-licenses)

#### 1. Make the receipt in Object Manager

1. Open **Setup → Object Manager → Create → Custom Object**. Enter **Guide Signing Receipt** for the label and **Guide Signing Receipts** for the plural. Use `Guide_Sign_Receipt` for **Object Name** to match this example. For the record name, use **Receipt number**, choose **Auto Number** and enter `HANDOFF-{00000}` as the display format. Save.
2. In **Fields & Relationships**, select **New** for each row below. Use these field names if you want to match the pictured example. Salesforce adds the `__c` suffix.

| Field label | Field name | Type and setting |
| --- | --- | --- |
| Receipt key | `Receipt_Key` | Text, 100 characters. Select **Unique** and treat uppercase and lowercase as duplicates. |
| Preparation status | `Stage` | Text, 24 characters. The Flow uses **Preparing**, **Ready** and **Failed**. |
| Signature request ID | `Request_Id` | Text, 18 characters. Holds the Portwood request ID. |
| Private signing URL | `Signer_URL` | Long Text Area, 4,096 characters. Holds this signer’s personal link temporarily. |
| Handoff link expires | `Link_Expires_At` | Date/Time. The screen checks this before opening the link. |

![In Object Manager, the receipt fields include the private signing URL and a unique receipt key.](docs/images/userguide/v3.64/receipt-setup.png)

3. In **Setup → Sharing Settings**, set the receipt object’s default access to **Private**. In a permission set, give participants **Read** on the receipt and the fields above. The background Flow creates and updates receipts. Restrict access to the signing URL when you review role hierarchy, sharing rules and administrative access. Open **Manage Assignments → Add Assignment** on the permission set and assign it to the people who run this screen. Give the person **Run Flows** and access to the screen Flow if your org restricts individual Flows.

#### 2. Create the platform event

1. In Setup’s **Quick Find**, enter **Platform Events**. Open it and select **New Platform Event**. Set the label to **Guide Sign Requested** and use `Guide_Sign_Requested` for the object name.
2. Set **Publish Behavior** to **Publish After Commit** and save. Under **Custom Fields & Relationships**, choose **New → Text**. Use **Receipt key**, field name `Receipt_Key`, length **100**. The event carries only this key.

![The platform event definition shows Guide Sign Requested and Publish After Commit.](docs/images/userguide/v3.64/event-definition.png)

3. In the participant’s permission set, grant **Read** and **Create** on this event, and **Read** and **Edit** on its **Receipt key** field. Give the Flow’s execution user access to the records, template and Portwood action it uses. Test as a person who will actually sign.

#### 3. Give Portwood an agreement to prepare

In **Portwood → My Templates → New Template**, choose **Bring an Existing Template**, **Salesforce Record (SOQL)** and **HTML**. Select **Guide Signing Receipt** as the base object and add **Name** to the selected fields. Set **API Name** to `Guide_Event_Acceptance` and **Output Format** to **PDF**. Select **Next → Create Template**. Under **Upload New Version**, select **Choose File** and upload the [practice agreement HTML](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/event-signing/acceptance.html), or use your own HTML agreement. Select **Save as New Version** and confirm the template is active.

Put the **Customer** signature field directly in the main template body. Confirm your org’s signing site works with a practice request. [Prepare a signable template](#sign-template) · [Set up external signing](#setup-signatures)

Now [build the background Flow that prepares an agreement](#signing-events). If your team already has an approval event and a private tracking record, map their fields to the same roles when you follow that walkthrough.

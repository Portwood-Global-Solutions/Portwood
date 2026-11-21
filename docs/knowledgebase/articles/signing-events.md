Build the background half of a signing experience. When someone chooses **Prepare agreement** on the screen, this Flow creates one Portwood request and puts their personal signing link on their private receipt. Start with the [receipt, event and signable template](#signing-handoff-setup).

#### 1. Start a Flow when the request arrives

In **Setup → Flows**, select **New Flow**. In **New Automation**, choose **Platform Event—Triggered Flow**. In **Choose Platform Event**, search for and select **Guide Sign Requested**. If you return to the canvas, select **Start → Edit** to see the chosen event.

![Choose Platform Event—Triggered Flow for the background work. Screen Flow is the separate choice for the person’s interview.](docs/images/userguide/v3.64/flow-type-choice.png)

![Choose Platform Event is set to Guide Sign Requested.](docs/images/userguide/v3.64/trigger-event.png)

Under **Start**, select **+ → Get Records**. Find the first **Guide Signing Receipt** where **Receipt key** equals **Triggering Guide Sign Requested → Receipt key**. Add a **Decision**. When a receipt already exists, end that path. On the other path, use **Create Records** to create a receipt with the event’s key, **Preparation status = Preparing** and **Owner ID = the event’s Created By ID**. Keep the new record’s ID. The unique key also prevents two simultaneous deliveries from creating two receipts.

#### 2. Tell Portwood who is signing

Use **Get Records** to find the **User** whose **Id** equals the event’s **Created By ID**. In **Manager → New Resource → Variable**, create a variable named `Person`, choose **Apex-Defined**, and select the packaged **DocGenSigner** class. Create a second variable named `People` with the same type and select **Allow multiple values (collection)**.

Add an **Assignment**. Set `Person.name` to the User’s **Full Name**, `Person.email` to the User’s **Email**, and `Person.role` to **Customer**, matching the template. In the last row select `People`, change the operator to **Add**, and select `Person`.

![The Assignment sets the signer’s name, email and Customer role, then adds Person to the People collection.](docs/images/userguide/v3.64/assign-signer.png)

#### 3. Create the signature request

Select **+** and search for **Create Signature Request**. Choose the Portwood action. For **Related Record Id**, select the receipt you just created. Enter these inputs for a person who will open the site from the same interview.

| In the action          | Choose this value                                                                               |
| ---------------------- | ----------------------------------------------------------------------------------------------- |
| Signers                | `People`                                                                                        |
| Signing Order          | `Single`                                                                                        |
| Template API Name      | `Guide_Event_Acceptance`                                                                        |
| Send Branded Emails    | `False`. The screen supplies the initial invitation.                                            |
| Link Expiration (Days) | `1` for this practice agreement. Leave the signer verification policy to your template and org. |

![The signing action uses People, Single, and the API name of the active agreement template.](docs/images/userguide/v3.64/signer-inputs.png)

#### 4. Put the result on the receipt

Use a **Decision** to check the action’s **Success** output. On success, use a **Loop** over **Signer URLs**. This example has one signer. Inside the loop, assign the current item to a Text variable named `SignerLink`. After the loop, confirm the link is populated.

Use **Update Records** on the receipt you just created. Set **Signature request ID** to the action’s **Signature Request Id**, **Private signing URL** to `SignerLink`, **Preparation status** to `Ready`, and **Handoff link expires** to a Date/Time formula containing `NOW() + 1`. On an action fault, unsuccessful result, or missing link, update the receipt to **Failed** and keep any returned request ID for investigation.

![The receipt update saves the expiry, Portwood request ID, private signer link and Ready status.](docs/images/userguide/v3.64/receipt-fields.png)

To clear the temporary URL, add a separate record-triggered Flow on the receipt. Run it after save when a receipt first meets **Preparation status = Ready**. Under **Start → Add Scheduled Paths**, use **1 Day After** the record-triggering event. On that path, use **Update Records** to clear **Private signing URL** on the triggering receipt. The practice agreement and the local expiry both use one day. The screen also checks expiry immediately before navigation. Save both Flows. If Salesforce asks for a **Default Workflow User** when you activate the scheduled cleanup, set it in **Setup → Process Automation Settings**. Activate the cleanup and background Flows in your sandbox. Next, [build the screen that opens the signing site](#signing-site-handoff).

#### If a manager’s approval starts the process

Use the approved agreement and version as the unique key. Find the authorized customer on the approved record. The publishing user in this case is the manager, while the invitation belongs to the customer. For multiple signers, route each person’s own link to them.

Test one approval twice and check that it produces one request. In a parallel two-person test, let the second person sign first. Fulfillment should still be waiting.

#### Tell the service team when the signed file is ready

1. Create a **Record-Triggered Flow** on **Portwood Signature Request**. In **Start**, select **A record is created or updated** and **Actions and Related Records**.
2. Under **All Conditions Are Met**, set **Status** to **Signed** and **Protected Signed Content Document Id → Is Null** to **False**. For updates, choose **Only when a record is updated to meet the condition requirements**. A signer can finish before the protected File is ready.
3. On that path, create the team’s follow-up task on the related business record, or pass the signed File ID to your delivery step. If another system can retry delivery, use the request ID as its unique reference. Try opening the finished File as someone on the receiving team.

For a separate notification each time a person signs, a **Platform Event–Triggered Flow** can listen to **Portwood Signature PDF** where the package emits it. Look up the request and the event’s signer. Use the request’s final status and File for fulfillment across signing methods. [Approval and fulfillment field map](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/signature-event-recipe.md)

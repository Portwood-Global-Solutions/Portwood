Give a signed-in person a button that opens their own Portwood signing page. They can return to the same Flow to check the signed file. This walkthrough uses the [background Flow that prepares the agreement](#signing-events). [See the screens as a signer](#event-signing-journey)

For a members-only portal or employee signing experience, authenticated signing requires a **Portwood site license**. If the button opens a public signing page, configure that site’s guest user as well. [Plan signing access and request a quote](#user-licenses)

#### 1. Put a Prepare agreement button on the screen

In **Setup → Flows → New Flow**, select **Screen Flow**. Under **Start**, select **+ → Screen**. Drag **Display Text** onto it and enter a short explanation of the agreement. In the screen’s footer settings, give the **Next** button the label **Prepare agreement**.

Below that screen, add **Create Records**. Choose **Manually** for setting field values and select the **Guide Sign Requested** object. Add **Receipt key** and choose **Running Flow Interview → InterviewGuid** as its value. This identifies this interview if the person checks back several times.

![Create Records publishes Guide Sign Requested with Receipt key set to the running Flow’s InterviewGuid.](docs/images/userguide/v3.64/publish-event.png)

Add a second **Screen** immediately after it. Enter **The request is being prepared** and label its Next button **Open signing page**. Reaching this screen commits the platform event so the background Flow can start. Label the Flow and save a draft. In **Auto-Layout**, your first few steps should read from top to bottom like this.

![The screen, the event and the second screen are separate steps before Read my receipt.](docs/images/userguide/v3.64/screen-path.png)

#### 2. Find the right person’s link

After the second screen add **Get Records** on **Guide Signing Receipt**. Set **Condition Requirements** to **All Conditions Are Met (AND)**. Match **Receipt key** to **Running Flow Interview → InterviewGuid** and **Owner ID** to **Running User → Id**. Store the first matching record. In the pictured example this element is labeled **Read my receipt**.

![Get Records looks for both the interview’s receipt key and the signed-in user’s owner ID.](docs/images/userguide/v3.64/read-receipt.png)

Add a **Decision**. A receipt is ready when **Preparation status = Ready**, its **Private signing URL** has a value and **Handoff link expires** is in the future. For an empty result or a receipt still preparing, show a **Check again** screen and connect it back to **Get Records**. For a failed or expired receipt, show a message and a contact for help.

#### 3. Open the signing site with Salesforce’s standard action

On the ready branch select **+**. In **Search Elements** type **Open a Page** and choose the navigation action. You can also open the **Action** picker and search there.

![Searching the plus menu for Open a Page brings up the navigation action.](docs/images/userguide/v3.64/find-navigation.png)

Give it the label **Open the signing page**. In **Page Type**, select **External Web Page**. For **URL**, use the resource picker to select **Guide Signing Receipt from Read my receipt → Private signing URL**. For **Where to Open the Page**, select **New Browser Tab**. Salesforce provides this action in Flow API 67 and later. [Salesforce Open a Page action](https://help.salesforce.com/s/articleView?id=platform.flow_ref_elements_actions_open_a_page.htm&language=en_US&type=5)

![The three navigation settings show External Web Page, the receipt’s private signing URL, and New Browser Tab.](docs/images/userguide/v3.64/open-signing-page.png)

If the URL picker says the field is unavailable, check the **Read** permission on **Private signing URL** for the person using Flow Builder, reopen the Flow and reselect the field.

If this Screen Flow creates the request directly, pass its single **Signer URLs** item as the URL. Scope the link to the intended signer. For an internal coordinator who needs the staff view, choose **Salesforce Record Page**, the saved signature request ID, the Portwood Signature Request object and **View**. Signing takes place at the person’s private web link.

#### 4. Let the person return and check the file

After the action add a **Screen** with **Display Text**. Type **review and sign your agreement**, select those words, and use the link control to insert the same signer URL resource. Connect the action’s fault path to this screen as well. A person whose browser blocks the new tab can still choose the link. Set the Next button label to **Check signing status**.

Then **Get Records** on **Portwood Signature Request** using the saved **Signature request ID**. On a **Decision**, show success when **Status = Signed** and **Protected Signed Content Document Id** is populated. Give **Signed** requests that are still saving their file a separate screen with **Check again**. For a declined or cancelled request, or one past its signing expiry, show a stopped screen. Send an unreadable request to your help screen.

On the **still needs a signature** screen, add a **Checkbox** labeled **Reopen my signing page** and a **Check again** footer button. Add a Decision after that screen. When the box is checked, connect it back to **Read my receipt** so the Flow checks this person’s ownership, link and expiry before opening the same agreement. Otherwise connect it to the request-status lookup. Both paths reuse the initial request.

#### 5. Give your team a place to open the Flow

1. In **Flow Builder**, save the Screen Flow with a recognizable label such as **Guide · Request and open an agreement**. Activate the cleanup and background Flows first, then activate the Screen Flow. An active Screen Flow appears in the Lightning page’s Flow picker.
2. For a dedicated page, open **Setup → Lightning App Builder → New → App Page**. Select **Next**, label the page **Service agreements**, choose **Next → One Region → Done**. To use an existing record page instead, open a record and choose the gear menu’s **Edit Page**.
3. Under **Components**, search for **Flow**. Drag the standard **Flow** component into the page region. Select it on the canvas and use the **Flow** dropdown in the properties panel to pick your Screen Flow.

![In Lightning App Builder, the Components pane is on the left, the Flow sits on the page in the middle, and its settings are on the right.](docs/images/userguide/v3.64/host-palette.png)

![The Flow dropdown has Guide · Request and open an agreement selected.](docs/images/userguide/v3.64/host-selected.png)

4. Select **Save → Activate**, or **Activation** on an already-saved page. For an app page, choose which users can see its tab and add it to your team’s Lightning app under **Lightning Experience**. For a record page, select the app, record type and profile assignment your signers use. [Salesforce app page activation](https://help.salesforce.com/s/articleView?id=platform.lightning_page_getting_into_salesforce1.htm&language=en_US&type=5)
5. As a practice signer, open the assigned app, select **Service agreements**, and choose **Prepare agreement**. If you used a record page, open that record in the assigned app. Open the signing page, close that tab before signing, then check the status and try **Reopen my signing page**. You should get the same agreement. [See the signer’s screens](#event-signing-journey)

If everyone should stay on the same page throughout, [place the signing component inside the Flow](#flow-signatures). Admins can also [download the optional working project](https://portwood.dev/demos/studio/event-signing.zip).

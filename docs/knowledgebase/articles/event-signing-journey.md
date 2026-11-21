If your team uses a Salesforce screen to collect an agreement, you can prepare it, open your signing page, and return to the same screen to check the result. This example follows one person signing their own service agreement.

Setting this up for your team? [Check licensing for signed-in signers](#user-licenses), then [build the signing experience in Salesforce](#signing-handoff-setup).

#### 1. Prepare your agreement

Open the signing Flow your team put on the record or app page. Check that you’re signed in as the person who should sign, then select **Prepare agreement**.

![Choose Prepare agreement to request the document for the person who is signed in.](docs/images/userguide/v3.64/sign-prepare.png)

#### 2. Open the signing page

Select **Open signing page**. Salesforce is preparing your document in the background. If the screen says preparation is still running, select **Check again**. Stay in this interview so it keeps checking the same request.

![The preparation screen has an Open signing page button in the footer.](docs/images/userguide/v3.64/sign-preparing.png)

When the agreement is ready, the signing site opens in a new tab. If your browser stays on the Flow, select **review and sign your agreement** to open it yourself. Keep the original tab open.

![The original Flow offers a review-and-sign link and a Check signing status button.](docs/images/userguide/v3.64/sign-return.png)

#### 3. Verify your email and sign

If the site asks you to verify your email, enter the email address on your Salesforce user and select **Send Verification Code**. Enter the code from that inbox. In this example the Flow gives you your signing link directly. The verification code is the email to look for. Your team’s signing settings determine whether this step appears.

![The signer enters their email address and selects Send Verification Code.](docs/images/userguide/v3.64/sign-verify.png)

Read the agreement and select **SIGN HERE**. Type or draw your signature as the signing page allows. Choose **Save & Next** to move through the fields. When you have reviewed the completed agreement, read the consent statement and select **Finish & Submit** if you agree.

![The signing dialog lets you review your mark and move to the next field.](docs/images/userguide/v3.60/signer-enter-signature.png)

![The Complete Signing dialog asks for consent before Finish & Submit.](docs/images/userguide/v3.60/signer-consent.png)

Your organization may also ask for initials or a date. [See how to sign a document](#signer-experience)

#### 4. Check whether the signed file is ready

Return to the original Salesforce tab and select **Check signing status**. If you left the signing page before submitting, the screen below is the expected result. Finish in the signing tab. If you closed it, select **Reopen my signing page**, then **Check again**. You return to the same agreement.

If the Flow says the agreement is **signed** and the file is being saved, give it a moment and select **Check again**. Once Portwood saves the final file, the Flow confirms it is ready. [Find the signed PDF and certificate](#manage-signatures)

![Reopen my signing page and Check again take the signer back to the same unsigned agreement.](docs/images/userguide/v3.64/sign-pending.png)

#### Set this up for your team

Start with the [signing receipt and event](#signing-handoff-setup). Then [build the Flow that prepares the request](#signing-events) and [add the navigation button to your screen](#signing-site-handoff). Each walkthrough shows the Salesforce controls to select.

If your buyer must sign a particular approved quote PDF, open **Signature Sender → Salesforce file** on the quote and select that revision. This example creates a new agreement from a template. [Send the approved quote for signature](#cpq-quote)

The practice version is available for admins who want to inspect the finished Flows in their own sandbox. [Download the optional sample](https://portwood.dev/demos/studio/event-signing.zip) · [Watch the signing handoff](https://portwood.dev/demos/portwood-3.64-demo.html?chapter=follow-the-event-into-signing)

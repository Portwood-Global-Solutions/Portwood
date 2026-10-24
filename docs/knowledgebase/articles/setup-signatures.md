Set up the public signing page and email sender before inviting external recipients.

**Before you start:** You are a Salesforce administrator with authority to configure a Salesforce Site or Experience Cloud site and the organization's email settings.

#### 1. Open the checklist

Go to **Portwood → Signatures**. The **Setup Status** checklist shows what is configured and what still needs attention.

![Signature Settings in a fresh org shows the missing site, email sender, and guest permission assignment](docs/images/userguide/v3.60/signature-settings.png)

#### 2. Configure the signing site

Follow the complete [Salesforce Site walkthrough](#site-salesforce), or use [an existing Experience Cloud site](#site-experience-cloud). The steps below are the overview.

1. Create or choose the active Salesforce Site or supported Experience Cloud site.
2. Add the packaged signing Visualforce pages to the site's enabled pages, including **DocGenSignature**, **DocGenSignaturePdf**, **DocGenVerify**, and **DocGenSign**.
3. In Portwood's **Signature Site URL**, enter the site's base URL.
4. For an Experience Cloud site, remove a trailing **`/s`** from the URL.

Use the base site address, not an individual signing page or someone's signing token.

#### 3. Give the site's guest user access

For a classic Salesforce Site:

1. Open **Setup → Sites → your site**.
2. Click **Public Access Settings**.
3. Open **View Users**, then the site's guest user.
4. Under **Permission Set Assignments**, assign **Portwood Guest Signature**.

For Experience Cloud, find that site's guest user through its administration/profile controls and assign the same packaged set.

Experience Cloud also needs **Administration → Preferences → Let guest users view asset files, library files, and CMS content available to the site**. Without it, the public PDF preview can say **Document unavailable**.

#### 4. Configure the sender

Use [Configure signing email and verification](#site-email) for the sender, deliverability, and test checklist.

1. In Salesforce Setup, create and verify the intended **Organization-Wide Email Address**.
2. Make it available to the profiles required by the signing workflow; the guest completion path needs an eligible sender.
3. Complete your sending-domain authentication and Salesforce email-deliverability setup.
4. Return to **Portwood → Signatures** and select the address under **Send Emails From**.
5. Save and **Re-check Setup**.

PIN emails need a working sender even if you distribute signing links yourself. Check the request's **Email Status** when an email fails to arrive.

#### 5. Set the defaults

Choose expiration, reminders, email verification, email pre-fill, and whether Decline is available. Verification settings can be inherited or overridden on templates and individual sends; check what the actual send will use.

#### 6. Test the public path

Create a test request for an inbox you control. Open the public link in a private browser window that is not signed into Salesforce. Verify the code email, document preview, signing, completion, and saved file.

**You are done when:** An external test signer can complete the full path and the request shows the expected delivery and completion state. A green setup checklist is useful, but it does not replace this test.

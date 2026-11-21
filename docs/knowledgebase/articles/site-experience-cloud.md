Use this route when your organization wants signing served through an Experience Cloud site. The standalone [Salesforce Site walkthrough](#site-salesforce) is the simpler starting point when you do not need a wider portal.

**Before you start:** Your administrator owns an active Experience Cloud site, its domain, and its guest-access policy. Experience templates and administrative screens vary; follow Salesforce's [Create an Experience Cloud Site](https://help.salesforce.com/s/articleView?id=networks_creating.htm&language=en_US&type=5) for the site's initial creation and publication.

#### Decide how customers will sign

| What happens in your community or portal                                            | What you need                                                                                                                                                                                                                  |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| A customer opens a private invitation link without logging in to the portal         | With per-user licensing, assign a Portwood license to this site’s Salesforce guest user. Public recipients need no individual seat. Assign **Portwood Guest Signature** to the guest user.                                     |
| A customer or partner logs in and signs as a member, including inside a Screen Flow | **Authenticated signing requires a Portwood site license.** Give the member Salesforce access to this site, its signing page and the specific Screen Flow. For the embedded signing screen, assign **Portwood Portal Signer**. |
| The portal offers both routes                                                       | The org’s site license covers the members and the guest user. Configure the guest and member permissions for their respective signing routes.                                                                                  |

For a members-only experience, arrange the site license and test the Flow as a customer or partner. [Request an enterprise site-license quote](https://calendar.app.google/HJLhcSFRFDoqxXEM9) · [Add the signing screen to a Flow](#flow-signatures)

The steps below configure **public signing links** on an Experience Cloud site.

#### 1. Open the site's administration

In **Setup → Digital Experiences → All Sites**, open the site's **Workspaces** and administration controls. Confirm that the site is active/published and that the external domain works while signed out.

#### 2. Enable the packaged public pages

Find this site's guest profile/public access settings. In its **Enabled Visualforce Page Access**, enable the packaged pages `DocGenSignature`, `DocGenSignaturePdf`, `DocGenVerify`, and `DocGenSign` in the `portwoodglobal` namespace.

On the guest profile, open **Assigned Users** or **View Users**, then select the site’s guest user. For per-user licensing, confirm **Portwood** under **Managed Packages** on that record. Assign **Portwood Guest Signature** under **Permission Set Assignments**. [Find and license the right user](#user-licenses)

#### 3. Allow the public document preview

In the site's **Administration → Preferences**, enable:

**Let guest users view asset files, library files, and CMS content available to the site**.

Without this, the signing shell can load while the PDF says **Document unavailable**. This preference is not a reason to make unrelated Salesforce Files public; verify the actual signing document's token-controlled preview.

#### 4. Enter the correct base address

In **Portwood → Signatures → Signature Site URL**, use the site's base address with its site path, but remove a trailing `/s`.

| Browser's portal address                  | Portwood base setting                   |
| ----------------------------------------- | --------------------------------------- |
| `https://example.my.site.com/customers/s` | `https://example.my.site.com/customers` |

Do not append a Visualforce page or signer token. Save and **Re-check Setup**.

#### 5. Test outside your admin session

Use a practice request and a private browser. Confirm the generated link, PDF preview, signing, and saved output. Then test verification and completion delivery using [Configure signing email](#site-email).

If a link opens **Invalid Page**, first check the `/s` suffix, enabled Visualforce pages, active site, and base path. If the page loads but the PDF is unavailable, check the guest content preference and packaged guest permission set.

This route was reviewed against the current signing URL logic and existing configuration guidance. The fresh-org hands-on setup used Salesforce Sites; it did not provision every Experience template.

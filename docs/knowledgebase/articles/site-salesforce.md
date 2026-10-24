A Salesforce Site gives external recipients a public doorway to the signing experience. They use their unique signing link; they do not need a Salesforce login.

**Before you start:** Install Portwood and use a Salesforce administrator account. This walkthrough uses **Salesforce Sites**. If your organization already uses Experience Cloud, follow [the Experience Cloud route](#site-experience-cloud) instead.

#### 1. Open Sites

1. Open the gear menu and choose **Setup**.
2. Type **Sites** in Quick Find.
3. Open **Sites** under **Sites and Domains**.
4. If this org has no Salesforce Sites domain, register the intended available domain using Salesforce's on-screen process. Domain selection belongs to your organization's site plan; check it before registering.
5. Click **New**.

In the fresh scratch org, Salesforce had already provisioned a Sites domain. A new production org can show a domain-registration step first. Salesforce describes these controls in [Manage Salesforce Sites](https://help.salesforce.com/s/articleView?id=platform.sites_managing_sites.htm&language=en_US&type=5).

#### 2. Name and activate the site

| Field                      | Example or choice                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------------ |
| Site Label                 | Portwood Signing                                                                                       |
| Site Name                  | Portwood_Signing; check the generated value                                                            |
| Site Contact               | The internal user responsible for this site                                                            |
| Default Record Owner       | An appropriate active internal user                                                                    |
| Default Web Address        | A short unused path such as `sign`                                                                     |
| Active                     | Selected                                                                                               |
| Active Site Home Page      | Use the lookup to choose `portwoodglobal.DocGenSignature`, or your organization's neutral landing page |
| Clickjack Protection Level | Leave the recommended same-origin protection for this standalone signing site                          |

Use the home-page lookup rather than guessing its API spelling. Managed pages appear with the namespace, and typed lookup values can fail to resolve. The home page does not replace the complete signing URL generated for each request.

Save. On **Site Details**, copy the HTTPS domain plus the site's path from **Custom URLs**. For example:

```text
https://your-domain.my.salesforce-sites.com/sign
```

Your domain will differ. The example is a base address, not a signing link.

![A newly created Salesforce Site shows its active state, home page, and Custom URLs](docs/images/userguide/v3.60/site-details.png)

#### 3. Enable the packaged public pages

1. On Site Details, find **Site Visualforce Pages** and click **Edit**.
2. Move these pages into **Enabled Visualforce Pages**:
    - `portwoodglobal.DocGenSignature`
    - `portwoodglobal.DocGenSignaturePdf`
    - `portwoodglobal.DocGenVerify`
    - `portwoodglobal.DocGenSign`
3. Save.

The home page may already be enabled. `DocGenSignaturePrepare` is the authenticated preparation UI used by your internal senders; it is not one of the public pages to add for this setup.

![The enabled-page list includes all four packaged public signing pages](docs/images/userguide/v3.60/site-enabled-pages.png)

Salesforce documents the available/enabled list in [Assign Visualforce Pages to a Site](https://help.salesforce.com/s/articleView?id=platform.sites_site_pages.htm&language=en_US&type=5).

#### 4. Give this site's guest user the packaged permission set

Each site has its own guest user. Assigning a permission set to yourself or a different site's guest will not complete this step.

1. Return to Site Details and click **Public Access Settings**.
2. On the guest profile, click **View Users**.
3. Open the user named for this site, such as **Portwood Signing Site Guest User**.
4. In **Permission Set Assignments**, click **Edit Assignments**.
5. Move **Portwood Guest Signature** to **Enabled Permission Sets** and save.

![Portwood Guest Signature is selected for this site's guest user](docs/images/userguide/v3.60/site-guest-permission.png)

Use the packaged permission set as the starting point. Do not grant a guest the Admin permission set or broad Account/Contact access to make signing work. The signing pipeline uses the specific request/link and packaged access controls.

#### 5. Tell Portwood where the site lives

1. Open the **Portwood** app and its **Signatures** workspace.
2. Paste the base address into **Signature Site URL**, including your site's path such as `/sign`.
3. Save the setting and click **Re-check Setup**.
4. Follow [Configure signing email](#site-email) for the sender and verification delivery.

Do not include `/apex/…`, a token, or a single recipient's signing link in the base setting.

#### 6. Prove the public path

Create a practice request and open its generated signing link in a private browser window signed out of Salesforce. Check document preview, required fields, consent, submission, request status, and the saved completed file. Once email is configured, repeat with verification enabled and an inbox you control.

![The practice document and its signature/date fields load in a clean public guest browser](docs/images/userguide/v3.60/site-public-preview.png)

**You are done when:** The intended public signer can finish the full request. A green setup checklist is a configuration check, not a substitute for this test.

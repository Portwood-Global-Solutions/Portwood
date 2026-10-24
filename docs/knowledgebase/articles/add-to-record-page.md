Add the Generate and signing tools where your team works.

**Before you start:** You are a Salesforce administrator who can edit and activate Lightning record pages.

#### Add the document runner

1. Open an example record of the right type, such as an Account.
2. Open Salesforce's **Setup** gear and choose **Edit Page**.
3. In Lightning App Builder's component list, search for **Portwood Runner**.
4. Drag it into a region on the page.
5. Select it and choose which destinations to offer: **Download**, **Save to Record**, and **Save & Download**.
6. Leave the extra packet and PDF-combining options on if your team needs them.
7. Click **Save**, then **Activate**. Assign the page to the intended app, profiles, or record types.
8. Return to the record and refresh it.

**You are done when:** The intended user sees Portwood Runner on that record, can choose a matching template, and can generate a file.

#### Add the signing tool

Follow the same steps, searching for **Portwood Signature Sender**. Place it on the record page where requests should be stored.

#### Make the page simpler

If a team only needs to save documents, turn off the other destinations. The runner hides the destination selector when only one option remains.

Make sure the page also gives users a way to open the record's **Files**. A successful save can be hard to find if the Files related list is absent.

#### If the component does not appear

Check the page's activation assignments, component visibility rules, and the user's Portwood permission set. Editing a page for one app does not necessarily change the page users see in another app.

On mobile, the runner saves to the record. Packet and PDF-combining workflows require desktop download support.

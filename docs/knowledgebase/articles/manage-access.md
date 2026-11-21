Start with the person’s job. Confirm [who needs a Portwood license](#user-licenses), then give them the permissions for the work they do.

| What the person does                                 | Permission set to assign                                                                                             |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Builds templates or configures Portwood              | **Portwood Admin**                                                                                                   |
| Generates documents or sends signature requests      | **Portwood User**                                                                                                    |
| Serves public signing links as the site’s guest user | **Portwood Guest Signature**, on that site's licensed guest user                                                     |
| Signs inside a Screen Flow using a portal login      | **Portwood Portal Signer**, with a Portwood site license and Salesforce access to the portal, page and specific Flow |
| Signs inside a Screen Flow as an internal non-admin  | **Portwood User** plus **Portwood Portal Signer** for the embedded component, with a Portwood site license           |
| Configures document and email buttons                | **Portwood Button Manager** plus the required Salesforce metadata permission                                         |

In **Setup → Permission Sets**, open the set, choose **Manage Assignments → Add Assignments**, and select the intended users. Public guests can sign through their invitation. The old **Portwood Guest Runner (deprecated)** permission set grants no access. Document generation from a portal record requires a signed-in user with access to the generator. [Set up external signing](#setup-signatures)

#### A user cannot open Portwood

Check **Installed Packages → Portwood** for license coverage. On the user’s record, check their permission set, Salesforce user license and access to the app or page. Refresh the session after an access change.

#### A user can open Portwood but sees no template

Check the record's object, template Active setting, active version, audience settings, and record filter. [Template organization](#organize-templates) explains these controls.

The packaged User permission set includes template View All. Manual template sharing is not normally required with current versions. Custom permission sets without that grant may behave differently.

#### A user sees the template but data is missing

Check access to the source record, related records, and selected fields. Template visibility is separate from permission to read the information merged into it.

#### You added your own fields to Portwood objects

Manage field access through an appropriate subscriber permission set. Decide which administrators, internal users, and guest paths need each field. Test each affected role. Managed permission sets are package-owned; add your own grants rather than assuming a new subscriber field is automatically covered.

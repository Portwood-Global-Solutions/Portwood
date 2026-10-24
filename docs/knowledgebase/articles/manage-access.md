Give each person enough access for their job and test the experience as that person.

| Person                                                     | Usually needs                                                     |
| ---------------------------------------------------------- | ----------------------------------------------------------------- |
| Template builder / administrator                           | **Portwood Admin**                                                |
| Internal user making documents or sending signing requests | **Portwood User**                                                 |
| Signing site's guest user                                  | **Portwood Guest Signature**                                      |
| Administrator configuring document/email buttons           | **Portwood Button Manager** plus the platform metadata permission |

You can find these sets in Salesforce **Setup → Permission Sets**. Open the set, choose **Manage Assignments → Add Assignments**, and select the intended users.

Portwood Quick Action and Guest Runner are additional specialized sets. Do not assign every set to every user; use the set appropriate to the entry point and supported Salesforce license.

#### A user cannot open Portwood

Check the permission assignment, user license, app visibility, and whether the page or action is available in the user's app/profile. Refresh the session after an access change.

#### A user can open Portwood but sees no template

Check the record's object, template Active setting, active version, audience settings, and record filter. [Template organization](#organize-templates) explains these controls.

The packaged User permission set includes template View All. Manual template sharing is not normally required with current versions. Custom permission sets without that grant may behave differently.

#### A user sees the template but data is missing

Check access to the source record, related records, and selected fields. Template visibility is separate from permission to read the information merged into it.

#### You added your own fields to Portwood objects

Manage field access through an appropriate subscriber permission set. Decide which administrators, internal users, and guest paths need each field. Test each affected role. Managed permission sets are package-owned; add your own grants rather than assuming a new subscriber field is automatically covered.

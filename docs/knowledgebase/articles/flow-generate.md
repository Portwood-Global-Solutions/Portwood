Let a Salesforce Flow make a document when a business event happens.

**Before you start:** You know Flow Builder and have a tested template. Give the template a stable **API Name**, such as `Opportunity_Summary`, and confirm the Flow's running context can access the required data.

#### Example: make a summary when a deal is won

1. Create an after-save, record-triggered Flow on **Opportunity**.
2. Set entry conditions so it runs when the record **first changes to Closed Won**, rather than on every later edit to a won deal.
3. Put document work on an appropriate asynchronous path when required by the rendering method and your transaction design.
4. Add an **Action** and search for **Generate Document** from Portwood.
5. Set the inputs:

| Input                      | Example                                                     |
| -------------------------- | ----------------------------------------------------------- |
| **Template API Name**      | `Opportunity_Summary` — use your template's actual API Name |
| **Record ID**              | `{!$Record.Id}`                                             |
| **Save to Record**         | `True`                                                      |
| **Document Title**         | An optional title you build from the record                 |
| **Output Format Override** | Leave blank for the template's default                      |

6. Store **Success**, **Error Message**, **Content Document ID**, and **Content Version ID** outputs.
7. Add a Decision: continue only when **Success = True**.
8. Connect the action's fault path to your Flow's error handling too.
9. Debug with a test Opportunity, then activate after checking the saved document.

**You are done when:** One qualifying change creates the intended file, and an unrelated later edit does not create another copy.

#### Email the generated file

Use the returned **Content Version ID** with the supported attachment input of Salesforce's Send Email action. Verify the attachment ID type expected by that action. Preview and test with an inbox you control before enabling customer delivery.

**Save to Record = False** avoids linking the file to the source record; the Generate Document action still creates a standalone Salesforce File. It is not a storage-free PDF action.

#### When the data can be large

**Generate Document (Auto Giant Query)** can choose a background path for supported large Word datasets. It takes a **Template ID** and **Record ID**. Check **Is Giant Query**: if true, follow **Job ID** and wait for completion; otherwise use the returned file IDs.

That action's background route requires a supported V3 query and is Word-only. For other large formats, use the runner or a suitable bulk workflow. A successful job submission does not mean its file is ready yet.

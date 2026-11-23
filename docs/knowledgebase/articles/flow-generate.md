Let a Salesforce Flow make a document when a business event happens.

**Before you start:** You know Flow Builder and have a tested template. Give the template a stable **API Name**, such as `Opportunity_Summary`, and confirm the Flow's running context can access the required data.

If your data comes from a JSON file or another Flow, [build the illustrated Generate PDF button](#document-studio).

#### Make a summary when a deal is won

1. Create an after-save, record-triggered Flow on **Opportunity**.
2. Set entry conditions so it runs when the record **first changes to Closed Won**, rather than on every later edit to a won deal.
3. Put document work on an appropriate asynchronous path when required by the rendering method and your transaction design.
4. Select **+** and search for **Generate Document**. Choose the Portwood action whose description starts **Generates a document (PDF, DOCX, PPTX, XLSX)**. Give the action a label.

![The Add to Flow search can return several Generate Document actions. Open the Portwood action for the supported document formats.](docs/images/userguide/v3.64/find-generate.png)

5. For a record-triggered summary, set these inputs.

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

#### Keep one file and add a new version each time

By default, every run creates a new file. To keep one file and add a new version to it instead, fill in **Save as New Version Of** with the existing file's **Content Document ID**. It starts with `069`; a Content Version ID, starting with `068`, also works.

1. Leave **Save as New Version Of** blank on the first run, so the action creates the file.
2. Store the returned **Content Document ID** somewhere the next run can read it, such as a text field on the record.
3. On later runs, set **Save as New Version Of** to that stored ID. It takes an ID, not `True`.
4. Keep the Decision on **Success** from the recipe above. A wrong ID returns **Success = False** with an **Error Message**; it does not stop the Flow.

| Error Message says                               | What to check                                                                   |
| ------------------------------------------------ | ------------------------------------------------------------------------------- |
| `is not a valid file ID`                         | The input holds something other than an ID, such as `True` or a file name       |
| `is a … ID, not a file ID`                       | The input holds a record ID, such as the Account's, instead of the file's       |
| `no file found with ID`                          | The file was deleted, or the running user cannot see it                         |
| `you don't have permission to add a new version` | The running user can view the file but is not its owner or a Collaborator on it |

The action returns the same **Content Document ID** and the **Content Version ID** of the version it just made. The record's Files list shows one entry with the newest version. Open the file and select **View File Details** to see earlier versions under **Version History**. With **Save to Record = True**, the action also attaches the file to the record if it is not attached yet. Each new version takes the generated **Document Title**.

**You are done when:** Two runs leave one file on the record, and its Version History lists two versions.

#### Email the generated file

Use the returned **Content Version ID** with the supported attachment input of Salesforce's Send Email action. Verify the attachment ID type expected by that action. Preview and test with an inbox you control before enabling customer delivery.

**Save to Record = False** avoids linking the file to the source record; the Generate Document action still creates a standalone Salesforce File. It is not a storage-free PDF action.

#### When the data can be large

**Generate Document (Auto Giant Query)** can choose a background path for supported large Word datasets. It takes a **Template ID** and **Record ID**. Check **Is Giant Query**: if true, follow **Job ID** and wait for completion; otherwise use the returned file IDs.

That action's background route requires a supported V3 query and is Word-only. For other large formats, use the runner or a suitable bulk workflow. A successful job submission does not mean its file is ready yet.

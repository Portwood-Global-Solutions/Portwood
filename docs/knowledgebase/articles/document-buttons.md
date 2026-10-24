Give people a short action such as **Generate Quote**, **Preview Brief**, or **Email Document** on a record.

**Before you start:** A Salesforce administrator needs **Portwood Button Manager** plus the relevant platform metadata permission, such as **Customize Application**. Portwood Admin alone does not expose the Buttons and Send Email management tabs.

#### Create a document button

1. Open **Portwood → Buttons → New Button**.
2. Choose the object and template.
3. Choose the label, active setting, optional record types, title, and save-to-record behavior.
4. Choose **Delivery mode**:

| Mode                   | The user gets                       |
| ---------------------- | ----------------------------------- |
| **Download**           | A downloaded file                   |
| **Preview**            | Salesforce's file preview           |
| **Preview & Download** | A preview, then an offered download |

5. Save. Configuration can take a few seconds to appear because it is saved as metadata.

#### Put the action on the page

1. In Salesforce Setup, open **Object Manager → your object → Buttons, Links, and Actions**.
2. Create an action with **Action Type = Lightning Web Component**.
3. Select the packaged **docGenButton** component.
4. Add the action to the intended record page's actions or the page layout's Salesforce Mobile and Lightning Experience Actions.
5. Test as a user who will use it.

Creating a configuration does not place the action on the page. Both parts are required.

For a headless preview action, use **docGenPreviewButton** and an active configuration with Preview delivery. Preview creates a Salesforce File even when the file is not linked to the record.

#### Create an email button

1. Open **Portwood → Send Email → New Send Email Button**.
2. Configure its object, optional default template, label, and audience.
3. Place a record action using **docGenSendEmailButton**.
4. Test its three steps: **Template → Preview → Recipients & message**.

Sending generates the document, saves it to the record, and sends an attachment to the selected addresses. Review the preview and recipients before sending. An email-delivery failure is shown to the user; finding a generated file alone does not prove the email was sent.

For very large related lists, use Portwood Runner or an appropriate background Flow action. The one-click document action uses a synchronous generation path.

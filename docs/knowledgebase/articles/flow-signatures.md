Create a signing request automatically when a record is ready for approval or acceptance.

**Before you start:** Test the template, signature roles, public signing path, and email sender manually. This article is for a Flow builder.

#### 1. Prepare the signer resources

Create a single **Apex-Defined** variable using the packaged **DocGenSigner** class and a collection variable of the same type.

In **Manager → New Resource → Variable**, name the first variable `Person` and the collection `People`. On the canvas, select **+ → Assignment** and fill in the signer’s fields.

| Field         | Example                                             |
| ------------- | --------------------------------------------------- |
| **name**      | Your Contact's full name                            |
| **email**     | Your Contact's email                                |
| **role**      | `Customer`, matching `{@Signature_Customer:1:Full}` |
| **contactId** | The Contact ID, when available                      |

In the final assignment row select **People → Add → Person**. Repeat for additional people. This example gets the signer from a User. For a Contact, choose that Contact’s name and email instead.

![The final Assignment row adds the populated signer to the People collection.](docs/images/userguide/v3.64/assign-signer.png)

#### 2. Create the request

Select **+**, search for **Create Signature Request**, and choose the Portwood action. Set its inputs.

| Input                                    | What to supply                                     |
| ---------------------------------------- | -------------------------------------------------- |
| **Template API Name** or **Template Id** | The tested template                                |
| **Related Record Id**                    | The record where the signed file belongs           |
| **Signers**                              | Your DocGenSigner collection                       |
| **Signing Order**                        | `Single`, `Parallel`, or `Sequential`              |
| **Send Branded Emails**                  | Leave on when Portwood should send the invitations |

Set expiration, message, and verification overrides only when your process needs them.

Store **Signature Request Id**, **Signer URLs**, **Email Status**, **Success**, and **Error Message**. Connect the **fault path**: invalid signature inputs can fault the interview before outputs are returned.

#### 3. Let the request finish the document

Follow the request's status. Once everyone signs, the signing workflow creates the completed PDF and certificate. Do not add a separate Generate Document action expecting it to supply the signed version; that can create an extra unsigned file.

#### Sign inside the Flow screen

Use the **Portwood: Sign in Flow** screen component when the signer is already signed in to Salesforce or to your Experience Cloud site and should sign without leaving the Flow. Guests are refused; send guests the emailed signing link instead.

1. Add **Portwood: Create Signature Request** as described above. Set **Send Branded Emails** to `False` when the person signs right away in the Flow.
2. Add a **Screen** element. From the **Custom** components, drag **Portwood: Sign in Flow** onto it.
3. Set **Signer URLs (collection)** to the action's **Signer URLs** output. The component signs for the first link, so use this for a single-signer request. For several signers, loop over **Signer URLs** and set **Signer URL** to the current item instead.
4. After the screen, add a **Decision** on the component's outputs.

| Output               | Meaning                                             |
| -------------------- | --------------------------------------------------- |
| **Signed**           | True once this signer's signature is recorded       |
| **Declined**         | True if the signer declined; the Flow continues     |
| **Request complete** | True when every signer on the request has signed    |
| **Signer status**    | The signer's status, such as `Signed` or `Declined` |
| **Error message**    | Why signing could not proceed, if it could not      |

![The signer selects SIGN HERE directly on the service acceptance document inside the Flow.](docs/images/userguide/v3.64/embedded-sign.png)

The signer clicks **SIGN HERE** on the document, draws or types their signature in the dialog that opens over the document, and chooses **Save & Next** to move to the next field. After the last field, they tick the consent box in **Complete Signing** and choose **Finish & Submit**. The Flow moves to the next screen as soon as the signature is recorded. Turn on **Wait for the user to select Next after signing** to let the signer select **Next** themselves.

Assign **Portwood Portal Signer** to the intended Experience Cloud members. For a non-admin internal signer using the packaged Portwood User permission set, also assign **Portwood Portal Signer** to grant access to the Flow signing controller. Check the screen as the actual signer profile.

The signature is saved the same way as on the signing page, with the same audit record, document hash, Certificate of Completion, and completion emails. You are done when your test Flow reaches the screen after signing and the signed PDF appears on the related record.

If the screen says the document can't be signed here, the request is a prepared uploaded PDF or the document is too large; use the returned signing link for those requests.

#### In-session signing

A screen Flow can direct a signer to their returned signing URL. This keeps signing inside Portwood's audited signing surface. On a sequential request, signer URLs are returned in signer order; capture the first URL with a loop/assignment if the first person signs immediately.

The **Send Branded Emails = False** input suppresses the initial invitations. On sequential requests it does not suppress every later signer's automatic invitation. Choose one deliberate delivery approach to avoid duplicate invitations.

Legacy custom-signature actions do not accept modern v3 signer tokens. Use the returned Portwood signing link for current requests; see the [automation reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/automation.md) for compatibility and advanced options.

Use [Collect signer answers](#signer-inputs) for `{?key}` fields, optional certificate entries, and single-signer record writeback.

For a signing-site link that keeps the interview open, follow [Open the signing site from a Screen Flow](#signing-site-handoff). To start a request from approval or act on completion, see [Platform event recipes](#signing-events).

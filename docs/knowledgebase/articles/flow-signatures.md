Create a signing request automatically when a record is ready for approval or acceptance.

**Before you start:** Test the template, signature roles, public signing path, and email sender manually. This article is for a Flow builder.

#### 1. Prepare the signer resources

Create a single **Apex-Defined** variable using the packaged **DocGenSigner** class and a collection variable of the same type.

Assign the single signer's fields:

| Field         | Example                                             |
| ------------- | --------------------------------------------------- |
| **name**      | Your Contact's full name                            |
| **email**     | Your Contact's email                                |
| **role**      | `Customer`, matching `{@Signature_Customer:1:Full}` |
| **contactId** | The Contact ID, when available                      |

Add the populated signer to the collection. Repeat for additional people.

#### 2. Create the request

Add **Portwood: Create Signature Request** and set:

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

#### In-session signing

A screen Flow can direct a signer to their returned signing URL. This keeps signing inside Portwood's audited signing surface. On a sequential request, signer URLs are returned in signer order; capture the first URL with a loop/assignment if the first person signs immediately.

The **Send Branded Emails = False** input suppresses the initial invitations. On sequential requests it does not suppress every later signer's automatic invitation. Choose one deliberate delivery approach to avoid duplicate invitations.

Legacy custom-signature actions do not accept modern v3 signer tokens. Use the returned Portwood signing link for current requests; see the [automation reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/automation.md) for compatibility and advanced options.

Use [Collect signer answers](#signer-inputs) for `{?key}` fields, optional certificate entries, and single-signer record writeback.

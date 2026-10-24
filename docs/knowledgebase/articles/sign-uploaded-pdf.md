Send a finished PDF for signature without rebuilding it as a template.

**Before you start:** Open the Salesforce record where the signed file belongs. The page needs **Portwood Signature Sender**. For external recipients, your administrator must [set up external signing](#setup-signatures).

#### 1. Choose the document

1. Click **New signature request**.
2. Choose **Upload PDF** for a file on your computer, or **Salesforce file** for a PDF on this record.
3. Select the PDF and continue.

![The signature sender offers Upload PDF, Salesforce file, and Portwood template](docs/images/userguide/v3.60/signature-source.png)

Use an unlocked, unsigned PDF of no more than **2 MB** and **50 pages**. Portwood keeps an original snapshot; choosing an existing Salesforce File does not replace that file.

#### 2. Add the people

Enter each recipient's name and email, or choose a Contact. Add them in the order they should sign.

Uploaded PDFs use **sequential** signing: the second person waits for the first, and so on. You can add up to **10 recipients**.

#### 3. Place the fields

1. In **Assign fields to**, select the recipient.
2. Choose **Signature**, then click the PDF where that person's signature belongs.
3. Add **Initials**, **Date signed**, or **Date picker** fields if needed.
4. Repeat for every recipient.
5. Use the page controls to inspect every PDF page.

Drag a field to move it. Select it to change **Width** and **Height**, move it with arrow keys, or remove it. Every recipient needs at least one Signature field. Keep all fields inside their pages; the request supports up to **100 fields**.

**Date signed** fills automatically. **Date picker** asks the signer to choose a date.

![PDF preparation shows fields assigned to Jordan Rivera and placed on the document](docs/images/userguide/v3.60/signature-fields.png)

#### 4. Review the request

Click **Review request**. Check the document, assigned people, positions, title, optional Signing Brand, expiration, and email-verification preference.

Choose delivery:

| Delivery                          | What happens                                                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Preview signing in Salesforce** | Creates an actual practice request whose signing links require Salesforce login; invitation, reminder, and completion emails are suppressed |
| **Create public signing links**   | Creates external signing links through your configured public site                                                                          |
| **Email invitations**             | Sends invitations through your configured site and sender, in signing order                                                                 |

The internal preview is useful for learning in a test org. Completing it still creates a signed file on the record.

![The review step checks document title, brand, expiration, verification, and preview-only delivery](docs/images/userguide/v3.60/signature-review.png)

#### 5. Create or send it

Click **Create preview links**, **Create signing links**, or **Send request** for the selected delivery. Find it under **Recent requests** and follow its progress.

**You are done when:** Everyone has signed and the completed PDF appears on the related record. Keep the original, signed PDF, and audit history together.

#### Leave and come back

Use **Save draft** before leaving preparation. On this record, open **Continue preparing → Resume**. Drafts belong to their creator and this record. Once sent, the original and placements are locked; prepare a new request if they need to change.

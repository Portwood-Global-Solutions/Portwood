Generate a document from Salesforce information and send it for signature.

**Before you start:** The template is active, includes signature positions, and generates the expected PDF. External delivery needs the [signing-site and email setup](#setup-signatures).

#### Prepare the template once

In Canvas, add a **Signature** block and configure the role and type. In Word or HTML, reserve space and use a signature tag:

```text
Customer signature
{@Signature_Customer:1:Full}

Date signed
{@Signature_Customer:1:Date}
```

The role **Customer** must match the signer's role in the request. Keep each signature on its own line or in its own table cell with room around it.

Use `Initials` for initials and `DatePick` for a date the signer chooses. Use `:inline` as a final suffix when you intentionally want a compact mark instead of the default signature card.

#### Send a request

1. Open the Salesforce record and find **Portwood Signature Sender**.
2. Click **New signature request → Portwood template**.
3. Choose the template, or several compatible templates for a packet.
4. Add each signer from Contacts or enter their name and email.
5. Match each person's **Role** to the template's signature role.
6. Choose the signing order.
7. Check expiration, verification, optional message, and other send settings.
8. Review and send.

| Order          | Use it when…                                      |
| -------------- | ------------------------------------------------- |
| **Single**     | Exactly one person signs                          |
| **Parallel**   | Everyone can receive an invitation at once        |
| **Sequential** | One person must finish before the next is invited |

These choices apply to template requests. The uploaded-PDF preparation path uses sequential signing.

#### Send several documents together

A signature packet gives the signer one session for the selected templates. Review the complete packet, including every role and signing spot. Completion produces a combined signed PDF with its completion certificate.

#### Check the first request

In a test org, verify the signer sees the correct values and only their own signing fields. After completion, open the signed PDF and check its marks and certificate.

A normal **Generate** action produces an unsigned document. Completing a signing request is what produces the signed document and signing audit history.

Use [Signer Inputs](#signer-inputs) when the signer must supply values in addition to their signature.

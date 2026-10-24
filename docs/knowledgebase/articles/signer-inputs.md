Ask a signer for a PO number, selected date, acknowledgement, or other information while they sign. These are signer inputs, separate from the Salesforce fields merged when the request is created.

#### Configure an input

1. Open the template editor and choose **Signer Inputs**.
2. Click **Add Field**.
3. Set the **Label** and **Type**: text, number, date, checkbox, or picklist. Supply choices for a picklist.
4. Choose **Required** if the signer must answer.
5. Copy the generated **Merge Tag**. Its stable key uses letters, numbers, and underscores.
6. Choose **On Certificate** if the answer should appear on the completion certificate.
7. To update Salesforce after signing, select a suitable **Mapped Field** on the related record and enable **Write Back**.
8. Save the intended version and test a practice signing request.

#### Place the answer

```text
{?poNumber}
{?poNumber|N/A}
```

The second form supplies a fallback when no answer is available. Use the key copied from the editor; typing a new key into the document does not create an input. Reserve its own line or table cell for the value so it has room to render without overprinting a static label.

The signer fills these fields during signing. Answers can appear in the finished document and, when configured, on the certificate. This feature is separate from mapping an uploaded PDF's AcroForm fields or manually placing signature spots in the uploaded-PDF preparation screen.

#### Understand writeback

Writeback runs after the completed signed PDF is saved. It updates only fields explicitly mapped and enabled in the template configuration. The guest does not receive general permission to edit the related Account, Opportunity, or other base record.

**Writeback supports single-signer requests.** With several signers, answers are captured and attributed on the certificate, but record writeback is skipped because there is no unambiguous single answer for a shared field. Do not design a multi-signer packet expecting the last answer to overwrite Salesforce.

Field access, supported value conversion, and validation rules still apply. A failed record update is logged; it does not undo a completed signing request. Check the related record and **Portwood Signature Audits** for writeback failures rather than treating a Signed status as proof of a successful field update.

#### Retry a failed update

Correct the mapped field, permissions, or validation issue first. The global **Write Back Signer Form Fields** action accepts only the completed request Id and re-derives the allowed fields from its configuration. It does not accept arbitrary field/value instructions from the guest.

```apex
portwoodglobal.DocGenFieldWritebackService.WritebackRequest retry =
    new portwoodglobal.DocGenFieldWritebackService.WritebackRequest();
retry.requestId = completedRequestId;
portwoodglobal.DocGenFieldWritebackService.writeBackFields(
    new List<portwoodglobal.DocGenFieldWritebackService.WritebackRequest>{retry});
```

The action returns no success DTO and logs failures instead of throwing them back into signing. Verify the target value and audit after a retry. Test an optional blank answer, required answer, invalid value, inaccessible field, validation-rule failure, and multi-signer request before enabling this in a business process.

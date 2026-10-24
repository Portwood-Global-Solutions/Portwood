The global action classes can be called by subscriber Apex as well as Flow. Build their published request types and inspect the returned result for every input.

#### Action directory

| Class and entry point                                                 | Use                                                            | Result to follow                                      |
| --------------------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| `DocGenFlowAction.generateDocument(List<Request>)`                    | Normal document generation, optional JSON data and save target | Success/error, ContentDocumentId and ContentVersionId |
| `DocGenGiantQueryFlowAction.generateDocument(List<Request>)`          | Automatic small/giant path selection                           | Immediate File or jobId plus isGiantQuery             |
| `DocGenBulkFlowAction.generateBulkDocuments(List<Request>)`           | Many parent records                                            | jobId and success/error                               |
| `DocGenSignatureFlowAction.generate(List<Request>)`                   | Create a current signing request                               | Request Id, ordered signer links and success/error    |
| `DocGenFieldWritebackService.writeBackFields(List<WritebackRequest>)` | Retry completed-request signer-field writeback                 | Inspect resulting record fields/errors                |

See the generated [global declarations](#apex-surface) for every published DTO field, and the task articles for the meaning of the Flow inputs.

#### Generate through a request object

```apex
portwoodglobal.DocGenFlowAction.Request input = new portwoodglobal.DocGenFlowAction.Request();
input.templateApiName = 'KB_Account_Brief';
input.recordId = accountId;
input.saveToRecord = true;
List<portwoodglobal.DocGenFlowAction.Response> results =
    portwoodglobal.DocGenFlowAction.generateDocument(
        new List<portwoodglobal.DocGenFlowAction.Request>{input});
if (!results[0].success) {
    System.debug(LoggingLevel.ERROR, results[0].errorMessage);
}
```

Run rendering in a supported fresh transaction. A list input is a contract shape, not permission to render an unlimited number of PDFs in one transaction.

The Generate Document request above was compiled and executed against the installed subscriber package; it returned success and a File Id.

#### Build current signers

```apex
portwoodglobal.DocGenSigner signer = new portwoodglobal.DocGenSigner();
signer.name = 'Jordan Rivera';
signer.email = 'jordan@example.com'; // replace with an intended recipient you control for testing
signer.role = 'Customer'; // matches {@Signature_Customer} in the practice template
portwoodglobal.DocGenSignatureFlowAction.Request input =
    new portwoodglobal.DocGenSignatureFlowAction.Request();
input.templateApiName = 'KB_Signing_Practice';
input.relatedRecordId = accountId;
input.signerRecords = new List<portwoodglobal.DocGenSigner>{signer};
input.signingOrder = 'Single';
input.sendEmails = false;
input.requireEmailVerification = false; // deliberate no-code test; choose your real policy
List<portwoodglobal.DocGenSignatureFlowAction.Result> results =
    portwoodglobal.DocGenSignatureFlowAction.generate(
        new List<portwoodglobal.DocGenSignatureFlowAction.Request>{input});
// Check success/errorMessage before consuming signatureRequestId or signerUrls.
```

Configure the public [signing site](#setup-signatures) first. Setting `sendEmails=false` suppresses invitation delivery; it is not the internal authenticated-preview mode and does not remove the need for email infrastructure if verification is enabled. Signing URLs are credentials: deliver them only to their intended recipients.

The signing request shape was also compiled and executed in the subscriber org with invitations and verification disabled. Its link loaded the PDF and both placements in a clean guest browser. That test did not submit the public request or exercise email delivery.

#### Avoid legacy-token traps

`DocGenSignaturePdfFlowAction.send` is deprecated; use Create Signature Request for new integrations. `DocGenSignatureValidator` can validate both modern signer tokens and legacy request tokens. `DocGenSignatureSubmitter` and `DocGenSignatureFinalizer` only submit/finalize the legacy request-token workflow; successful validation does not make those actions compatible with a modern token. Do not use the submitter/finalizer to inject a captured signature into a current v3 signer token; that is unsupported.

Use `DocGenSigner` for the signer collection. The older nested Signer type and parallel legacy lists remain published for compatibility, but the standalone type is the usable choice for new Flow authoring.

`DocGenSignaturePreparationController` also has global methods for the authenticated uploaded-PDF preparation UI: context, PDF selection/upload, draft load/save/send. They enforce record/draft ownership and expected revisions. This UI-oriented JSON/revision workflow is more coupled than the service/action APIs; use the packaged sender unless you intentionally own that full preparation experience.

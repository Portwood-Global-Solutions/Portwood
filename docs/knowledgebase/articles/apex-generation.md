Use `portwoodglobal.DocGenService` from subscriber Apex. Start with the method that matches the result your process needs.

#### Choose the method

| Result you need                           | Global method                                                                 | Result                                                     |
| ----------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------- |
| A File on the source record               | `generateDocument(templateId, recordId)`                                      | `ContentDocumentId`                                        |
| An explicit compatible output type        | `generateDocument(templateId, recordId, outputFormatOverride)`                | `ContentDocumentId`                                        |
| A saved File with a chosen title          | `generateDocument(templateId, recordId, outputFormatOverride, documentTitle)` | `ContentDocumentId`                                        |
| A different attachment target             | Add `attachmentRecordId` as the fifth argument                                | `ContentDocumentId`; null target creates a standalone File |
| PDF bytes without a saved File            | `generatePdfBlob(templateId, recordId)`                                       | Map with `blob` and `title`                                |
| A saved File from an already prepared map | `generateDocumentFromData(templateId, recordId, data)`                        | `ContentDocumentId`                                        |
| PDF bytes from a prepared map             | `generatePdfBlobFromData(templateId, data)`                                   | Map with `blob` and `title`                                |
| Prepared data with record context         | `generatePdfBlobFromData(templateId, recordId, data)`                         | Map with `blob` and `title`                                |
| Prepared data, output type, and File save | `generateAndSaveFromData(templateId, recordId, data, outputFormatOverride)`   | `ContentDocumentId`                                        |

`generateAndSaveFromData` also accepts a fifth `documentTitle` and a sixth `fileAttachmentTarget`. The second argument remains required. Passing a null sixth argument creates a standalone File; use a Blob method if you want no File at all.

#### Generate after the business transaction

A trigger or Flow can change records and then queue the document work. The worker gets a fresh transaction. Rendering is subject to platform transaction rules; do not paste a synchronous PDF call directly into a trigger and assume it is supported there.

The downloadable [KBGenerateAccountBrief class](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/apex/KBGenerateAccountBrief.cls) was deployed and executed in the fresh subscriber org. It looks up the template by its stable API Name and calls the global generation service from a Queueable implementing `Database.AllowsCallouts`.

```apex
// Run in your process after deciding this Account needs a document.
System.enqueueJob(new KBGenerateAccountBrief(accountId));
```

The example uses `KB_Account_Brief`, the [worked example](#example-library). Replace that stable key with your own template API Name. For a real deployment, add job outcome reporting, retries with duplicate protection, access checks appropriate to the caller, and tests for the business trigger.

#### Return bytes to another process

```apex
Map<String, Object> result = portwoodglobal.DocGenService.generatePdfBlob(templateId, accountId);
Blob pdf = (Blob) result.get('blob');
String title = (String) result.get('title');
// Your code can attach the bytes to an email or pass them to another system.
// This Portwood method does not itself send an email or create a File.
```

Read all inputs before rendering; keep preceding DML out of the render transaction. Test the exact document, image, and chart path you will use. Large outputs still consume Apex heap even when you do not save a File.

#### Handle access and failures deliberately

The standard retrieval path uses user-mode queries. A prepared map skips the source-record retrieval; template, file, font, and other supporting queries can still consume SOQL budget. Prepared maps and custom providers bypass that retrieval, so caller code must enforce access on the data it supplies. `with sharing` alone does not enforce field access.

Catch `portwoodglobal.DocGenException` for Portwood validation failures, and handle other platform/transaction failures in your job framework. Log safe identifiers and the failure reason; do not write entire documents, signing URLs, or sensitive merged values into logs.

The package's `DocGenController` and `DocGenBulkController` are internal UI controllers, not exported subscriber APIs. `@AuraEnabled` does not make a public controller global. Call the exported service/actions or your own authorized wrapper.

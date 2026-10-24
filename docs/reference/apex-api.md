# Apex and Flow API reference

This advanced reference accompanies the [task-based knowledgebase](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md). Retained from the existing guide and reviewed against the 3.60.0 source. Use the task articles for current installation and user workflows.

Call Portwood from an appropriate Apex or Flow transaction. Rendering can have transaction constraints; verify the actual entry point and use an asynchronous boundary when required. **`DocGenService` is the `global`, subscriber-callable API** — prefix as `portwoodglobal.DocGenService` from your own code. The controller classes referenced later in this chapter (`DocGenController`, `DocGenBulkController`) are the package's own UI endpoints and are **not callable from subscriber code** — they're documented for reference; automate through `DocGenService` or the Flow actions instead.

> The signatures below describe the current exported entry points. Verify the installed version and the source contract when adding an integration.

### 12.1 `DocGenService` — synchronous generation

Primary entry point from Apex. Call from a supported rendering transaction. From a trigger or a transaction that has already performed DML, enqueue work into a fresh transaction rather than rendering synchronously. All methods listed below are `global` in the managed namespace `portwoodglobal` — call them directly from subscriber Apex.

| Method                                                                                                                   | Returns                                | Purpose                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `generateDocument(Id templateId, Id recordId)`                                                                           | `Id` (ContentDocumentId)               | Generates, saves as File on the record, returns the new ContentDocumentId. Uses the template's default output format.                                                                                                                    |
| `generateDocument(Id templateId, Id recordId, String outputFormatOverride)`                                              | `Id`                                   | Same, but `'PDF'` / `'Word'` / `'Excel'` / `'PowerPoint'` / `'HTML'` override. Throws on lock or incompatible combination.                                                                                                               |
| `generatePdfBlob(Id templateId, Id recordId)`                                                                            | `Map<String,Object>` (`blob`, `title`) | Renders a PDF in-memory without saving. Use when you want to email / attach elsewhere / POST to another system.                                                                                                                          |
| `generateDocumentFromData(Id templateId, Id recordId, Map<String,Object> preloadedRecordData)`                           | `Id`                                   | Same as `generateDocument` but skips the per-record data query and uses the supplied map instead. For custom bulk loops or callers that already have the data in hand.                                                                   |
| `generatePdfBlobFromData(Id templateId, Map<String,Object> dataMap)`                                                     | `Map<String,Object>` (`blob`, `title`) | Renders a PDF straight from a caller-built data map — no source-record retrieval, no recordId required. Lets you assemble external API responses, computed totals, or cross-object aggregations and merge them directly into a template. |
| `generateAndSaveFromData(Id templateId, Id attachmentRecordId, Map<String,Object> dataMap, String outputFormatOverride)` | `Id` (ContentDocumentId)               | Same as `generatePdfBlobFromData`, but also saves the file as a ContentVersion linked to `attachmentRecordId`. One-shot "build wrapper → render → attach".                                                                               |

```apex
// Example: render in a fresh supported worker transaction after approval
Id contentDocId = portwoodglobal.DocGenService.generateDocument(
    'a0zXXXXXXXXXXXXX',   // template ID
    accountId,            // record ID
    'PDF'                 // force PDF regardless of template setting
);

// Example: invoice generation referencing a Custom Label for the template Id
Id invoicePdf = portwoodglobal.DocGenService.generateDocument(
    System.Label.Invoice_Document_Template_Id,
    invRecordId
);

// Example: render a PDF in-memory and email it without ever creating a File
Map<String, Object> result = portwoodglobal.DocGenService.generatePdfBlob(templateId, oppId);
Blob pdf = (Blob) result.get('blob');
String title = (String) result.get('title');
// ...attach to a Messaging.SingleEmailMessage, POST to an external system, etc.
```

> **Catching exceptions.** All API methods throw `portwoodglobal.DocGenException` on validation failures (locked output format, missing template, PowerPoint→PDF, null `dataMap`, etc.). Subscriber code can catch by name: `catch (portwoodglobal.DocGenException e) { ... }`.

> **Sharing & FLS.** The standard data retriever executes its Salesforce queries in user mode, enforcing the running user's record and field access. The `…FromData` overloads accept a caller-supplied data map and bypass that retrieval boundary: caller code is responsible for enforcing access on the values it supplies. A custom provider must also enforce its own access rules.

### 12.2 `DocGenController` — LWC / Aura endpoints

These are package-internal UI endpoints, listed to explain the bundled components. Their `@AuraEnabled` annotation does not make a non-global controller a subscriber Apex/LWC API. Use the global service or Flow actions for subscriber integrations.

| Method                                                                                    | Returns                                                                        | Purpose                                                                                                                            |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| `generatePdf(Id templateId, Id recordId, Boolean saveToRecord)`                           | `Map<String,Object>` (`base64`, `contentDocumentId`, `title`)                  | LWC-friendly PDF generation. `saveToRecord=true` attaches, `false` returns base64 only.                                            |
| `generatePdfAsync(Id templateId, Id recordId)`                                            | `Id` (AsyncApexJob Id)                                                         | Enqueues a Queueable for large PDFs (>~15 MB) that exceed the sync Aura timeout. Client polls.                                     |
| `generateDocumentGiantQuery(Id templateId, Id recordId)`                                  | `Map<String,Object>` (`isGiantQuery`, `jobId` OR `docId` + `contentVersionId`) | Auto-routes: small child counts go sync, >2000 rows spawn a batched Giant Query job.                                               |
| `saveTemplate(Map<String,Object> fields, Boolean createVersion, String contentVersionId)` | `Map<String,Object>`                                                           | Programmatic template save. Fields: Id, Name, Type**c, Base_Object_API**c, Query_Config**c, Header_Html**c, Footer_Html\_\_c, etc. |
| `getAllTemplates()`                                                                       | `List<DocGen_Template__c>`                                                     | Every template in the org (cacheable).                                                                                             |
| `getTemplatesForObject(String objectApiName)`                                             | `List<DocGen_Template__c>`                                                     | Audience-filtered list. Applies `Required_Permission_Sets__c` and static `Record_Filter__c`.                                       |
| `getTemplatesForObjectAndRecord(String objectApiName, String recordId)`                   | `List<DocGen_Template__c>`                                                     | Above plus per-record filter evaluation (`Specific_Record_Ids__c`, runtime `Record_Filter__c`).                                    |
| `saveHtmlTemplateImage(Id templateId, String fileName, String base64Content)`             | `Map<String,Object>` (`contentVersionId`, `url`)                               | Stores an inline image from an HTML template upload. Called from the LWC during client-side unzip.                                 |
| `saveHtmlTemplateBody(Id templateId, String fileName, String htmlContent)`                | `Map<String,Object>` (`contentVersionId`, `contentDocumentId`)                 | Stores the rewritten HTML body after image extraction.                                                                             |

### 12.3 `DocGenBulkController` — bulk generation

| Method                                                                                                                | Returns                                                 | Purpose                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `submitJob(Id templateId, String condition, String jobLabel, Boolean mergePdf, Integer batchSize, Boolean mergeOnly)` | `Id` (DocGen_Job\_\_c Id)                               | Launches a bulk batch. `condition` is a SOQL WHERE on the template's base object. `mergePdf` produces a combined PDF; `mergeOnly` skips per-record files. |
| `analyzeJob(Id templateId, Integer recordCount, Integer batchSize, Boolean mergePdf)`                                 | `JobAnalysis` (SOQL / DML / heap / record-count checks) | Pre-flight estimator. Run before `submitJob` to warn about governor-limit risks.                                                                          |
| `getBulkTemplates()`                                                                                                  | `List<DocGen_Template__c>`                              | Audience-filtered template list for the bulk UI.                                                                                                          |
| `getJobStatus(Id jobId)`                                                                                              | `DocGen_Job__c`                                         | Current status, success count, error count, total records, merged-PDF CV Id.                                                                              |
| `validateFilter(String objectName, String condition)`                                                                 | `Integer` (matching count)                              | Validates a WHERE clause and returns the count. Use to preview scope.                                                                                     |

### 12.4 Flow invocable actions (full signatures)

Usable from Flow Builder and from Apex via `Invocable.Action.createCustomAction(...)`:

| Action                                                                               | Class                          | Input                                                                                                                                                                                                                                                                                                                         | Output                                                                                                            |
| ------------------------------------------------------------------------------------ | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Generate Document                                                                    | `DocGenFlowAction`             | `templateId` or `templateApiName`, `recordId`, `saveToRecord`, `documentTitle`, `outputFormatOverride`, `jsonData`                                                                                                                                                                                                            | `contentDocumentId`, `contentVersionId`, `success`, `errorMessage`                                                |
| Generate Bulk Documents                                                              | `DocGenBulkFlowAction`         | `templateId`, `queryCondition`, `recordIds`, `jobLabel`, `combinedPdfOnly`, `keepIndividualFiles`, `batchSize`                                                                                                                                                                                                                | `jobId`, `success`, `errorMessage`                                                                                |
| Generate Document (Auto Giant Query)                                                 | `DocGenGiantQueryFlowAction`   | `templateId`, `recordId`, `saveToRecord`                                                                                                                                                                                                                                                                                      | `contentDocumentId` + `contentVersionId` (small) OR `jobId` (giant), `isGiantQuery`, `success`, `errorMessage`    |
| Create Signature Request                                                             | `DocGenSignatureFlowAction`    | `templateId` or `templateApiName`, `relatedRecordId`, `signerRecords` (List<DocGenSigner>: `name`, `email`, `role`, `contactId`), `signingOrder`, `emailMessage`, `emailSubject`, `sendEmails` ("Send Branded Emails"), `requireEmailVerification`, `prefillSignerEmail`, `expirationDays` ("Link Expiration (Days)", v3.31+) | `success`, `signatureRequestId`, `signerUrls`, `signerNames`, `signerEmails`, `signerRoles`, `errorMessage`       |
| Send Existing Document for Signature (**deprecated** — use Create Signature Request) | `DocGenSignaturePdfFlowAction` | `templateId` (required; `contentVersionId` deprecated/ignored as of v3.18), `relatedRecordId`, `signerRecords` (List<DocGenSigner>: `name`, `email`, `role`, `contactId`), `signingOrder`, `documentTitleFormat`                                                                                                              | `success`, `signatureRequestId`, `signerUrls`, `signerNames`, `signerEmails`, `signerRoles`, `errorMessage`       |
| Write Back Signer Form Fields                                                        | `DocGenFieldWritebackService`  | `requestId` (Signature Request Id)                                                                                                                                                                                                                                                                                            | — (re-runs the automatic §11.7.1 signer-input writeback for a completed request; use for retries or custom flows) |
| Validate Signature Token (custom signing UI)                                         | `DocGenSignatureValidator`     | `token`                                                                                                                                                                                                                                                                                                                       | `isValid`, `errorMessage`, `signerName`, `documentTitle`, `documentUrl`                                           |
| Submit Signed Signature (**legacy requests only**)                                   | `DocGenSignatureSubmitter`     | `token`, `signatureData` (base64)                                                                                                                                                                                                                                                                                             | `isSuccess`, `errorMessage`                                                                                       |
| Finalize Signature Image (**legacy requests only**)                                  | `DocGenSignatureFinalizer`     | `token`, `base64Image`                                                                                                                                                                                                                                                                                                        | — (void)                                                                                                          |

> The old `signers` (List<Signer>) input on Create Signature Request is a deprecated inner type that Flow can't populate — always use **`signerRecords` (List<DocGenSigner>)**.

> **Submit Signed Signature / Finalize Signature Image resolve only a _request-level_ token** _(clarified 2026-07-30)_ — they cannot submit a signature for a signer on a request created by **Create Signature Request** or **Send Existing Document for Signature**. Passing a v3 signer token is a silent no-op. See [§11.9.1](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#1191-compatibility--which-tokens-these-actions-accept).

### 12.5 `DocGenDataProvider` interface — custom data source

Implement this interface to supply custom data from external APIs, computed fields, or cross-object aggregations. Choose the **Apex Class (Data Provider)** source when creating or editing the template and name your provider class. The V4 query configuration is described in the query reference.

```apex
global interface DocGenDataProvider {
    Map<String, Object> getData(Id recordId);
    List<String> getFieldNames();
}
```

Return a map whose keys match the merge tags in your template. Nested maps → parent-lookup tags (`{Owner.Name}`), lists of maps → child loops (`{#Contacts}`).

Example:

```apex
/** Subscriber-side example. Deploy to your org after installing Portwood. */
global with sharing class KBAccountProvider implements portwoodglobal.DocGenDataProvider {
    global Map<String, Object> getData(Id recordId) {
        Account account = [
            SELECT Name, Industry, Phone
            FROM Account
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        List<Object> contacts = new List<Object>();
        for (Contact contact : [
            SELECT Name, Email, Title
            FROM Contact
            WHERE AccountId = :recordId
            WITH USER_MODE
            ORDER BY Name
            LIMIT 100
        ]) {
            contacts.add(
                new Map<String, Object>{ 'Name' => contact.Name, 'Email' => contact.Email, 'Title' => contact.Title }
            );
        }
        return new Map<String, Object>{
            'Name' => account.Name,
            'Industry' => account.Industry,
            'Phone' => account.Phone,
            'ContactCount' => contacts.size(),
            'Contacts' => new Map<String, Object>{ 'records' => contacts }
        };
    }
    global List<String> getFieldNames() {
        return new List<String>{
            'Name',
            'Industry',
            'Phone',
            'ContactCount',
            'Contacts.Name',
            'Contacts.Email',
            'Contacts.Title'
        };
    }
}
```

### 12.6 Namespace prefix

The package installs in the `portwoodglobal` namespace. From subscriber code:

- **Apex**: prefix — `portwoodglobal.DocGenService.generateDocument(...)`
- **LWC**: call your own Apex wrapper around an exported global service or use the packaged components; package-internal controllers are not a supported subscriber API.
- **Flow**: actions appear in the palette with the package namespace label
- **Merge tags in templates**: use each field's exact API name and relationship path, including its namespace when the field has one. Copy tags from the query builder.

---

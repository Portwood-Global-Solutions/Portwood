# Advanced automation and signing compatibility

This advanced reference accompanies the [task-based knowledgebase](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md). Retained from the existing guide and reviewed against the 3.60.0 source. Use the task articles for current installation and user workflows.

### 11.7 Recipe — Send a document for signature on the PDF viewer page

> **Deprecated (v3.21+).** "Portwood: Send Existing Document for Signature" still works — it now routes to the same guided PDF signing as everything else — but new Flows should use **Portwood: Create Signature Request** (§11.6), which covers this scenario with more options (email message/subject, verification settings, Template API Name). This recipe stays for existing Flows.

Use **Portwood: Send Existing Document for Signature** (`DocGenSignaturePdfFlowAction`) when you want the signer to review the **real, fully rendered PDF in the browser** (rather than the typed-name placement page) and have the completed document land back on the record. Pass a **Template Id**: Portwood snapshots the record's merge data at send-time and, on completion, re-renders the document from that snapshot (immune to later record edits), appends a signing-certificate page, and attaches the signed PDF to the related record's Files. This supports the [`{#Signatures}` loop block](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#signature-loop-block--signatures-variable-signer-count) — one signature layout that repeats per signer. The template must have a **Base Object** and **Query Config** set.

> **Deprecated action input:** This old Flow action ignores its `Content Version Id` input and requires a Template Id. This does not describe the whole signing product: the current uploaded-PDF preparation UI supports existing PDFs with manually placed fields. See [Send an uploaded PDF](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#sign-uploaded-pdf).

**Trigger:** any Flow (record-triggered, screen, or scheduled). Build the `signers` collection exactly as in [§11.6](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#116-recipe--send-a-contract-for-signature-on-opportunity-approval) (an Apex-Defined `DocGenSigner` collection — `name` + `email` required; `role`, `contactId` optional).

**Step — Portwood: Send Existing Document for Signature.**

| Input                 | Value                                                        |
| --------------------- | ------------------------------------------------------------ |
| Template Id           | `{!$Label.AgreementTemplateId}` _(required)_                 |
| Related Record ID     | `{!$Record.Id}`                                              |
| Signers               | `{!signers}`                                                 |
| Signing Order         | `Parallel` or `Sequential`                                   |
| Document Title Format | _(optional — overrides the title shown on the signing page)_ |

**Outputs:** `success`, `signatureRequestId`, `signerUrls` (per-signer links, valid until the request's expiration — the org default or the **Link Expiration (Days)** input, in signer order), `signerNames` / `signerEmails` / `signerRoles`, and `errorMessage` when `success` is `false`.

**Result:** each signer gets a link to the **PDF-viewer signing page**, reviews the real PDF, and signs through a guided modal. Once everyone signs, the re-rendered document + certificate page is attached to the related record automatically.

> **For new Flows:** use Create Signature Request. Both actions route into the current guided PDF signing pipeline; the older action is retained for existing integrations, not as the way to choose a different signing surface.

#### 11.7.1 Signer form fields — collect input during signing, write it back

On the guided PDF signing path you can ask each signer for extra information **before they sign** — e.g. a PO number, a quantity, an acknowledgement checkbox — and have those answers flow into the finished document, the certificate, and (optionally) back onto the Salesforce record.

**Configure the fields on the template.** In the Template Builder, add one or more **Form Fields**. Each field has:

| Property                | Meaning                                                                                  |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| **Key**                 | A stable id (`[A-Za-z0-9_]+`) you reference in the document with `{?key}`.               |
| **Label**               | What the signer sees on the "Your Information" step.                                     |
| **Type**                | `text`, `number`, `date`, `checkbox`, or `picklist` (picklist uses the field's choices). |
| **Required**            | Signer can't continue until it's filled.                                                 |
| **Writeback field**     | _(optional)_ A field on the related record to write the answer to on completion.         |
| **List on certificate** | _(optional)_ Show the answer on the Certificate of Completion.                           |

**Place the value in the document.** Put a `{?key}` tag wherever the answer should appear — e.g. `{?poNumber}`. An optional fallback is supported: `{?poNumber|N/A}`. Like signature tags, give a `{?key}` tag its **own table cell or line** — placed mid-line (e.g. `PO: {?poNumber}`) the value can overprint the label.

**What happens on completion:**

- The signer fills the fields on a **"Your Information"** step, then signs (typed or drawn).
- The values **render in the signed document** at each `{?key}` position.
- Fields flagged **List on certificate** appear on the Certificate of Completion (per signer).
- For a **single-signer** request, mapped answers **write back to the related record** in one update.

> **Multi-signer / packet limitation.** When a request has more than one signer, form-field answers are captured and listed on the certificate but are **not** written back to the record yet (the fields are shared across signers, so there's no single value to write). Per-field signer ownership — assigning each field to a specific signer so multi-signer writeback is unambiguous — is planned. Single-signer writeback works today.

### 11.8 Recipe — Pass pre-built JSON data instead of querying

The **Generate Document** action accepts an optional **JSON Data** input. When present, Portwood skips its own SOQL retrieval and uses the supplied JSON directly. Use cases:

- External API response that you've already fetched and parsed
- Cross-object data your query config can't express
- Computed values that aren't on any record

```text
{
  "Name": "Acme Corp",
  "Amount": 50000,
  "Items": {
    "records": [
      { "Product": "Widget", "Qty": 2, "Price": 100 },
      { "Product": "Gadget", "Qty": 1, "Price": 250 }
    ]
  }
}
```

Wire this to a Flow Text Variable populated upstream — typically by an Apex action that calls an external API and returns a JSON string. The merge tags in your template (`{Name}`, `{Amount:currency}`, `{#Items}…{/Items}`) resolve against the JSON instead of a Salesforce record.

### 11.9 Recipe — Custom signing UI (advanced, legacy requests only)

> **Corrected 2026-07-30 (guide revision, no package change).** Earlier revisions of this section did not state which kind of signature request these three actions work with. The submit/finalize actions work **only** against a **legacy single-signer** request — one whose signing token lives on the request record itself. Those submit/finalize actions **cannot** submit a signature into a request created by **Portwood: Create Signature Request** ([§11.6](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#116-recipe--send-a-contract-for-signature-on-opportunity-approval)) or **Send Existing Document for Signature** ([§11.7](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#117-recipe--send-a-document-for-signature-on-the-pdf-viewer-page)) — the current v3 multi-signer path, and what almost every Flow built since v3.0 uses. If you want to capture a signature inside your own portal or screen Flow, use [§11.6.1](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#1161-sign-in-session--capture-the-signature-in-your-own-portal-or-screen-flow) instead: it is the supported route, and it is the only one that produces an audit trail and a Certificate of Completion.

Three helper actions exist for orgs that want to build their own signing experience instead of using the bundled Visualforce pages — for example, an embedded signature pad inside an existing customer portal. **These require package v2.6.0 or later** (earlier versions shipped them but they weren't exposed to subscriber Flows). In Flow Builder, search "Portwood" and pick the action by its label:

- **Validate Signature Token** (`DocGenSignatureValidator`) — validates a secure token from the signing URL and returns signer name, document title, and a preview URL. Call this when your custom page first loads.
- **Submit Signed Signature** (`DocGenSignatureSubmitter`) — accepts the secure token plus the base64-encoded signature and submits it. A lighter-weight alternative to Finalize.
- **Finalize Signature Image** (`DocGenSignatureFinalizer`) — accepts a base64-encoded PNG of the captured signature, stamps it onto the document, enqueues the PDF rendition, and writes the audit record. Call this when the user clicks "Sign and Submit".

#### 11.9.1 Compatibility — which tokens these actions accept

| Token you pass                                                  | Validate Signature Token    | Submit Signed Signature / Finalize Signature Image                                                                                 |
| --------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| A **signer** token from the `signerUrls` output of a v3 request | ✅ returns `isValid = true` | ❌ **silently does nothing** — no error, no exception, no signature. The Flow reports success and nothing happens.                 |
| The **request's own** `Secure_Token__c` on a v3 request         | ✅ returns `isValid = true` | ❌ falls into the legacy typed-name path with no per-signer placements → an error on the audit record and no document is produced. |
| A **legacy single-signer** request token                        | ✅                          | ✅ works as documented                                                                                                             |

**Why.** On a v3 request each signer's signing token lives on the **Portwood Signer** child record, and the request's own `Secure_Token__c` is the **certificate verification** token printed on the Certificate of Completion — not a signing token. Validate Signature Token resolves both shapes; Submit and Finalize resolve only the request-level token. That asymmetry is exactly why a Flow can validate cleanly and then produce nothing.

#### 11.9.2 Not supported — injecting a captured signature image into a v3 signer

There is **no** action that takes a base64 signature you captured yourself and records it as a v3 signer's signature. Audit data (timestamp, IP address, consent hash, document hash, certificate entry) is only created for a mark drawn or typed through Portwood's own signing surface — see [§10.9](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#109-audit-trail).

If you have already captured a signature image and only need it to **appear** in the document, that works — but it is a picture, not a signed signature:

1. Use an appropriate Apex/upload step to create a **ContentVersion** (`Title`, `PathOnClient` = `signature.png`, binary `VersionData` decoded from base64). Do not assume a Flow Text variable can be assigned directly to the Blob field.
2. Store the returned `068…` Id in a text field on the record.
3. Reference it in the template with `{%Your_Field__c}` ([§7.7](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#77-images)).

That image renders wherever you place it, has **no** audit record, and does **not** appear on the Certificate of Completion. Use it for a pre-printed mark (e.g. an authorized signatory reproduced on many documents); do not use it where the signature has to be legally defensible.

#### 11.9.3 Legacy custom-screen Flow

For a legacy single-signer request:

1. Pass `?token=…` into the screen Flow URL.
2. **Action: Validate Signature Token** with `{!token}` — receive name/title/preview.
3. Display the preview. Capture the signature in a Lightning component, base64-encode the PNG.
4. **Action: Finalize Signature Image** with `{!token}` and `{!base64Png}` — done.

Most customers don't need this. Use the bundled signing pages ([§11.6.1](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#1161-sign-in-session--capture-the-signature-in-your-own-portal-or-screen-flow) for the in-session variant) unless you have a specific reason to embed.

### 11.10 Polling an async job from a screen Flow

Bulk and Giant Query actions return a `jobId`. Read `portwoodglobal__DocGen_Job__c` through Get Records or an authorized user-mode query. The [asynchronous-job walkthrough](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/UserGuide.md#async-jobs) lists the actual stored states, result fields, partial-success handling, and screen refresh loop.

Screen Flows do not support Wait elements. Use a Screen/Refresh loop for an interactive check, or a supported asynchronous automation pattern for unattended completion. Do not add a tight polling loop in one transaction. `DocGenBulkController.getJobStatus` is a package-internal endpoint and cannot be called by subscriber Apex.

### 11.11 Error handling

The generation and current signature-creation actions return:

- `success` (Boolean) — `false` if generation failed
- `errorMessage` (String) — user-readable explanation when `success = false`

Always add a Decision element after the action that branches on `success`. The most common failures:

- **Template Id is wrong.** Prefer the **Template API Name** input (v3.28+): set the API Name field on the template and pass that literal — it's identical in every environment, so nothing breaks on deploy. On older versions, store template Ids in Custom Labels (`Setup → Custom Labels`) and reference them as `{!$Label.YourLabelName}`.
- **Record Id is null.** A scheduled trigger fired but the criteria returned nothing. Add an entry condition.
- **Locked output format conflicts with the requested override.** Either unlock the template or stop overriding the format in the Flow.
- **Heap limit exceeded** on a sync action. Switch to **Generate Document (Auto Giant Query)** so the engine routes to async automatically.

**Two kinds of error, and they arrive by different routes.** A Decision on `success`
catches only one of them, so signature Flows need both:

| What went wrong                                                                                               | How you find out                                | What to wire                        |
| ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------- |
| **Runtime failure** — template deleted, DML rejected, limit hit                                               | `success = false` with `errorMessage`           | A Decision element after the action |
| **Invalid input** — no Template Id, no Related Record Id, an empty Signers collection, a signer with no email | The action **throws**, and the interview faults | A **fault connector** on the action |

The signature actions validate their inputs strictly and stop the interview rather than
returning `success = false`. That is deliberate: a missing Template Id is an authoring
mistake, and failing loudly at build time beats a Flow that quietly continues down its
success path having created nothing. It does mean `success` and `errorMessage` are not
reached on those paths — drag the fault connector, or those mistakes look like silence.

**Bulk batches.** Flow can hand invocable actions collections of requests, and
**Validate Signature Token** queries per token. Past roughly fifty it runs out of the
transaction's SOQL allowance; rather than faulting and losing the whole batch, it
validates as many as it can afford and returns the rest with `Is Valid = false` and an
Error Message saying they were not attempted. Check `Is Valid` per row, and validate in
smaller batches if you are processing many at once.

---

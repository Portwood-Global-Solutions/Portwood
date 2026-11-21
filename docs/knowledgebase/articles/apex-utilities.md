These global helpers support specific jobs. Read the input limits before putting one into your process.

#### Merge PDF files in order

```apex
Blob packet = portwoodglobal.DocGenPdfMerger.mergePdfs(
    new List<Blob>{firstPdf, secondPdf}, true);
Integer pages = portwoodglobal.DocGenPdfMerger.pageCount(packet);
```

`mergePdfCvs(List<Id>, Boolean)` accepts ContentVersion Ids and loads parts incrementally. Passing `true` adds a blank page after every odd-length part, including the last part. Two one-page parts therefore produce four pages. The blank pages carry no page number; the content pages retain numbering baked into their original render.

The native merger handles standard uploaded PDFs, including supported compressed object and cross-reference streams. Ordinary AcroForm values are kept under separate field names for each source. Encrypted, signed, XFA and scripted forms are rejected. Catch `DocGenPdfMerger.DocGenPdfMergeException` for unsupported inputs. For exact file-version inputs and a saved File output, use [Merge PDFs in Flow](#merge-pdfs-flow).

To check duplex padding, merge two one-page PDFs. The result should have four pages, with the two originals on pages one and three.

#### Render a branded email without sending it

```apex
Map<String, String> tokens = new Map<String, String>{
    'SignerName' => 'Jordan Rivera', 'DocumentTitle' => 'Practice document',
    'SignatureUrl' => 'https://example.com/practice'
};
portwoodglobal.DocGenEmailTemplateService.RenderedEmail email =
    portwoodglobal.DocGenEmailTemplateService.render(
        portwoodglobal.DocGenEmailTemplateService.TYPE_REQUEST, tokens);
String subject = email.subject;
String html = email.htmlBody;
String plainText = email.plainBody;
```

Overloads add `messageOverride`, then `brandId`. `renderSubject(String, Map<String,String>)` resolves subject tokens. Rendering does not send an email, create a request, or authorize a signing URL. Use the appropriate email type/token contract and a real request's URL when building an actual notification.

The rendered subject and body were checked in the fresh org. No email was sent by this rendering test.

#### Schedule transient chart/PDF-part cleanup

```apex
System.schedule('Portwood transient cleanup', '0 0 * * * ?',
    new portwoodglobal.DocGenChartCvReaper());
```

Inspect Scheduled Jobs first so you do not add duplicate schedules. `reap()` is also exported and returns the number cleaned. The current helper targets old, orphan transient `chart_`/`pdfpart_` files, with age/job-state checks and a bounded batch. It is not a general Salesforce Files retention policy.

`DocGenEmailTemplateInstall` is the package install handler; `seedDefaults()` is an exported setup utility. Normal document generation does not require calling the install handler yourself.

#### Add native AI authoring

`DocGenAiProvider` requires `isAvailable()`, `getName()`, and `generateHtml(String)`. The optional Agentforce extension exports `DocGenEinsteinProvider`. Use [Agentforce setup](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/AGENTFORCE_SETUP.md) for entitlement and configuration. The native provider contract uses Einstein/ConnectApi and explicitly excludes HTTP-callout providers. Return a complete HTML document and handle unavailable configuration through `isAvailable()`.

These global helpers support specific jobs. Read the input limits before putting one into your process.

#### Merge Portwood-native PDFs

```apex
Blob packet = portwoodglobal.DocGenPdfMerger.mergePdfs(
    new List<Blob>{firstPdf, secondPdf}, true);
Integer pages = portwoodglobal.DocGenPdfMerger.pageCount(packet);
```

`mergePdfCvs(List<Id>, Boolean)` accepts ContentVersion Ids and loads parts incrementally. Passing `true` adds a blank page after every odd-length part, including the last part. Two one-page parts therefore produce four pages. The blank pages carry no page number; the content pages retain numbering baked into their original render.

This is a specialized server merger for Portwood's Flying Saucer/iText PDF 1.4 output with classic cross-reference tables and the expected page structure. It is not a general library for arbitrary uploaded product sheets, encrypted PDFs, object streams, or every PDF producer. Catch `DocGenPdfMerger.DocGenPdfMergeException` and use a compatible workflow for unsupported inputs. The packaged browser-side packet workflow is separate.

The 3.60.0 subscriber check generated a one-page Account Brief, merged two copies with padding, and confirmed the resulting four-page count.

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

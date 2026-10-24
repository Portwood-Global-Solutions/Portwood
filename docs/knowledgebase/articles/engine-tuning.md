Start with the smallest document that proves the business result. Add data, graphics, and styling in stages so you can tell which change creates a problem.

#### Pick the path for the job

| Job                                                  | Starting point                                               |
| ---------------------------------------------------- | ------------------------------------------------------------ |
| One normal record, interactive download              | Record-page Runner                                           |
| Many parent records                                  | Bulk Generation or Generate Bulk Documents Flow action       |
| One parent with a very large child list              | Auto Giant Query / the supported giant-query path            |
| Computed or external data already prepared           | JSON data or `DocGenDataProvider`; own the access checks     |
| A PDF Blob for another process, without a saved File | Global `DocGenService.generatePdfBlob…`                      |
| A packet of Portwood-native PDF parts in Apex        | Global `DocGenPdfMerger`, within its supported PDF structure |

Giant-query generation is asynchronous once it crosses the engine's large-relationship threshold. Follow the returned job rather than expecting an immediate File Id. It is different from bulk generation across many parent records.

#### Make the data smaller before making the heap larger

Select only used fields, filter relationships, order them deliberately, and set justified limits. Avoid huge rich-text fields and full-resolution images when the document prints a small thumbnail. A query limit changes the document's data and totals; disclose intended truncation to the reader rather than quietly hiding rows.

Use standard retrieval when it fits. When you supply JSON or an Apex map, Portwood cannot know whether your code was allowed to retrieve each value; enforce sharing, object access, and field access in the caller/provider.

#### Work with transaction boundaries

Do not assume a rendering API can run synchronously from a trigger or after arbitrary DML. Queue the document work into a fresh transaction and test the exact Flow/Apex entry point. Bulk rendering, chart preparation, file saves, and merging all consume resources. A method accepting a list does not promise unlimited work in one transaction.

Keep durable job outcomes and retries in your own process. Avoid retrying after an uncertain success without checking for the existing File/request; duplicate retries can create duplicate documents or invitations.

#### Use the PDF engine's strengths

Use tables for aligned print layouts, fixed units for controlled dimensions, simple borders, and a supported font. The renderer follows a CSS 2.1/paged model; browser flex/grid layouts, shadows, rounded corners, and JavaScript are not a reliable PDF design foundation. Use a pre-rendered image when a visual effect cannot be represented by the print engine.

For precise Word conversion, fix table widths and AutoFit rather than repeatedly changing the PDF's margins. The [layout reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/template-layout.md) includes the width traps and a constrained HTML-authoring prompt.

#### Diagnose one variable at a time

1. Confirm the template, active version, record, output type, and running user.
2. Reduce to one field and one related row.
3. Add the original query selection, then loops and totals.
4. Add images, then charts, then page furniture.
5. Reintroduce the failing data volume last.
6. Compare preview, record Runner, and the actual automation path; they can prepare assets differently.

For a release, keep small, empty, long-text, many-row, multi-page, and representative image cases. Inspect the final files, not only the designer preview. A screenshot captures a symptom; the template version, query, data shape, and execution path make it reproducible.

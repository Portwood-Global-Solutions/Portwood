# Guide verification for Portwood 3.64

The guide follows the managed source at tag `v3.64.0` (commit `6ac4a9b6d426`). The installed subscriber build used for checks was 3.64.0.1, package version ID `04tVx000001FBU1IAO`. The optional Agentforce extension was installed at 1.1.0.1. Article review metadata distinguishes source review from sandbox observations.

## What we exercised in the sandbox

| Workflow | What we checked |
| --- | --- |
| Generate a first letter | The HTML contained one Account field. The downloaded PDF displayed the fixture account's name. |
| Print a long service schedule | An Account with 54 related rows produced a four-page PDF. On page four, the active handoff snippet merged its internal `{Name}` into “Alder Works.” We checked printed page numbers, optional decimal formatting and the final total of 5,400.35. A second PDF generated directly from the sandbox Account record, through `generatePdfBlob(templateId, recordId)`, printed the same clause with “Alder Works - Guide Lab.” The managed `fieldsAndRowContext` test also passed for a parent name and two different Contact names from the same snippet. |
| Group and chart a portfolio | Six engagements produced three groups. The two-page PDF included the bar chart and subtotals of 11,000, 19,900 and 11,000, matching the overall 41,900. |
| Fill and flatten a form | The input contained one editable widget. The generated PDF contained its filled account name and zero editable widgets. |
| Merge existing Files | Two one-page sources passed to the managed Flow action produced one duplex packet with content on pages one and three and blank backs on pages two and four. |
| Keep Office files editable | The sandbox generated a native two-worksheet workbook and a PowerPoint file. We opened their rendered output for the walkthrough. |
| Sign inside a Screen Flow | We used an authenticated practice interview and its own signer to open the embedded signing component and its signature-entry dialog. |
| Navigate to the signing site | The second branch opened the signing page for the intended practice signer. The Flow's fallback link worked and its status recheck correctly returned Pending. |
| React to an approval event | An existing equivalent subscriber received the same synthetic approval event twice in sequence. The tracking record advanced to Ready to sign and identified one request after both deliveries. Concurrent deliveries and downstream fulfillment were source-reviewed. |

The downloadable Flow was deployed as a draft. The recording used a temporary active variant limited to the fictional fixture. The sandbox definition was returned to an inactive state and the downloadable draft redeployed after filming. The session stopped before making a legally binding mark. Outbound signing email, a full guest completion, the cross-org migration round trip and an external model generation were outside the live checks.

## Automated checks

- The 11 browser checks exercised all 81 articles, legacy routes, screenshots, search, raw Markdown, mobile layout, learning paths, printing and recovery from loading errors. Both website entry pages were rebuilt from the shared reader. The local reader's 33 distinct guide downloads responded.
- Both create and revise prompts were generated using the real query parser, a sample Account and its Opportunities. Both included the current snippet, font, label, grouping, print and signing guidance. The revision preserved its input template. The prompts are a proposed package-source update. The downloadable assistant context can be used with the existing installed package.
- The managed sandbox test run passed 62 of 64 tests across the Flow signer, PDF merge, form filling and shared snippets. Both failures were in shared snippets. `secondEditorCanVersionPrivateFile` and `userCanReadButCannotPublish` both reported insufficient read access to the managed asset object. The underlying cause remains open. Saving and rendering the clause succeeded as the author used in the demonstration. The two failures leave second-editor and read-only behavior unverified in this org.
- Local signing checks passed 107 signer-core assertions, 58 typed-signature assertions and the Korean signed-PDF check. Shared-content authoring checks and three migration CLI test suites also passed.
- The 25-chapter walkthrough runs 10 minutes 18 seconds. We decoded its full video and audio streams and checked actual playback, chapter seeking and English captions in Chrome. It combines sandbox recordings, generated files, earlier guide captures and a synthesized voiceover. The script identifies what appears on screen.

PDF.js 4.7.76, Apache-2.0. Derived from the existing ../pdfjs4 resources.
Original license comments retained. See THIRD-PARTY-NOTICES.md.
Only modification: remove the final ESM export clause and wrap in an IIFE.
This exposes the existing globalThis.pdfjsLib/pdfjsWorker namespaces to Lightning loadScript.
viewer.html, viewer.js and viewer.css are first-party files. They display the generated
PDF in a same-origin Salesforce resource iframe so image decoding avoids LWS overhead.
Only the parent frame can supply bytes; both endpoints validate origin, source window
and a per-viewer session. The Apex permission-checked File reader remains in the LWC.
The local worker handler uses PDF.js's standard main-thread loopback port.
No external runtime requests. isEvalSupported is disabled by the caller.

PDF.js 4.7.76, Apache-2.0. Derived from the existing ../pdfjs4 resources.
Original license comments retained. See THIRD-PARTY-NOTICES.md.
Only modification: remove the final ESM export clause and wrap in an IIFE.
This exposes the existing globalThis.pdfjsLib/pdfjsWorker namespaces to Lightning loadScript.
The worker handler is loaded locally for main-thread rendering under Lightning Web Security.
No external runtime requests. isEvalSupported is disabled by the caller.

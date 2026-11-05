# Native PDF merge capacity probe

This is a disposable **scratch-org-only** harness, outside `force-app` and excluded
from package deployment by `.forceignore`. It measures the existing invocable in
a synchronous Apex REST transaction and in a real Queueable transaction. The
`engine` cases call `DocGenPdfMerger.mergePdfCvs` directly, bypassing the action's
100-version and aggregate-byte guards. They do not change those guards.

`PdfMergeStress.Job` attaches a Finalizer so that uncatchable CPU/heap failures
are recorded in a separate transaction. Normal responses record the runtime
heap/CPU limits, CPU consumed by merging and saving, SOQL count, input bytes,
and output ContentVersion ID. `heapBefore`/`heapAfter` are current heap readings,
**not peak heap**. Client wall time includes Queueable scheduling and PDF checks.
CPU includes saving the merged File; the result-log insert is outside that metric.

The fixtures include 100 distinct one-page text PDFs, incompressible grayscale
images, long documents, compressed object/xref streams, ordinary forms, exact
byte-boundary packets, and highly compressed thousands-of-pages documents.
Repeated IDs count toward both packet length and total input bytes. Count probes
above 100 cycle those 100 source versions; image probes include both repeated and
distinct IDs. These are controlled workloads, not universal PDF capacity claims.

For every successful merge, the Python runner downloads the result and checks
page count, page order, extracted text, decoded image SHA-256 values, and qpdf
syntax through pikepdf. Duplex cases verify inserted blank pages. This download is
test verification; the server-side merger itself makes no external callouts.

## Run

1. Use a dedicated authenticated scratch org with `DocGenPdfDocument`,
   `DocGenPdfMerger`, and `DocGenPdfMergeFlowAction` already deployed. Copy the
   harness `.cls` and `.cls-meta.xml` into a temporary Salesforce DX project's
   `force-app/main/default/classes` directory, and deploy that temporary project
   to the scratch org. Do not add this REST endpoint to the managed package.
2. Create a Python virtual environment with `pypdf`, `pikepdf`, `reportlab`, and
   `Pillow`. The test run used `.tmp/pdf-venv` with pypdf 6.21.0, pikepdf 10.17.0,
   ReportLab 5.0.1, and Pillow 12.3.0.
3. Save an explicit CLI authentication export for that scratch org to
   `.tmp/pdf-merge/stress/auth.json`, with mode `0600`. The JSON `result` must
   include `instanceUrl`, `accessToken`, `expirationDate`, and `devHubId`.
   Keep this file private and gitignored. Never copy it into results or reports.
4. From the repository root, run:

    ```sh
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py generate
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py baseline
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py engine
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py fine
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py extreme
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py complex
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py shape
    .tmp/pdf-venv/bin/python scripts/qa/pdf-merge-stress/stress.py summarize
    ```

Results and PDFs are cached under `.tmp/pdf-merge/stress/`. Remove a case's result
JSON to rerun it; each new execution gets a unique server-side label so an older
Queueable result cannot satisfy a new poll. A new org requires fresh source IDs:
remove `sources.json` and the old case results before generating fixtures.
If polling is interrupted after a Queueable completes, use `--recover` to read
its existing server result instead of launching the same expensive case again.
Remove the private authentication export when finished; `summarize` works offline.

The action does not automatically enqueue work. A Screen Flow calling it directly
uses synchronous limits. The Queueable here explicitly supplies the asynchronous
execution context.

See [the October 16 results](RESULTS-2026-10-16.md) for measured successes and
failures. The sanitized JSON and CSV beside that report contain all case metrics.

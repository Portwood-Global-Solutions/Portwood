# Portwood bulk PDF benchmark and runbook

Generate one private Salesforce PDF per Account, then download one PDF containing the whole job in order. The reference use case is a nonprofit producing annual contribution statements from Accounts, Opportunities, and Opportunity Line Items. This directory contains the synthetic fixture, the scratch Batch Apex runner, the private File export, the browser merge, and the verification scripts.

Start with the [sample statement](evidence/sample-statement.pdf), the [recorded results](evidence/100000-results.json), and the [product implementation specification](IMPLEMENTATION.md). The [authenticated downloader reference](download-reference/) contains the ready notification, Download page, bounded range reader, and resume experiments.

## Recorded 100,000-Account run

Portwood 3.61.0-1 queried 100,000 Accounts, 200,000 Opportunities, and 400,000 line items. Each Account had two Opportunities and each Opportunity had two line items. The installed package filled the HTML template and called `Blob.toPdf()` for each statement. A scratch-only Batch Apex class saved each PDF as a standalone private Salesforce File. Chrome merged the checksum-verified exports over localhost. The finished PDF had 100,000 pages and matched every source page in order. A separate semantic check confirmed the donor, gift, and line-item details.

| Measured stage | Wall time |
| --- | ---: |
| Start provisioning through final verification | 22 min 28 sec |
| First Batch Apex submission through last completion | 13 min 5 sec |
| First export through last export, overlapping generation | 6 min 52 sec |
| Chrome merge and save | 23.6 sec |

The 100,000 source PDFs totalled 284,164,681 bytes. The merged file was 250,490,191 bytes (239 MiB). Each of eight Developer scratch orgs held 12,500 Accounts and had 16 MB free out of its 50 MB File storage allocation at the post-export check. Five batch jobs ran per org, with a scope of up to 40 Accounts. All 40 jobs finished without errors and recorded zero Apex callouts. File inserts accounted for about 89% of the summed transaction stage time. The full wall time reflects parallel scratch orgs and a localhost browser replay. Single-org throughput and authenticated Lightning download latency are separate measurements.

## Prerequisites

- Work from this directory, which contains its own Salesforce DX project. Use Node.js 22 or newer, npm, Bash, jq, Python 3.11 or newer, Salesforce CLI, and an installed Google Chrome. Install Poppler so `pdfunite`, `pdftotext`, and `pdftoppm` are on your path.
- Authenticate a Dev Hub permitted to create Developer scratch orgs. The full run requires eight scratch slots and the ability to install the managed Portwood package. Use an authenticated alias for `PORTWOOD_DEV_HUB`. The reference package version is 3.61.0-1, subscriber package version ID `04tVx000001BaZ3IAK`.
- Reserve about 1 GB of local disk for individual files, the merged PDF, browser working data, and verification artifacts. Use synthetic data and scratch orgs. The harness appends `-01` through `-08` to the configured scratch alias prefix as needed.
- Run `npm ci` for the pinned PDF and Chrome automation dependencies. The fixture assets are served only on loopback. Salesforce CLI authentication stays in the shell process.

## Run the benchmark

Run the four stages in the same shell. Start with a 100-Account smoke run using a distinct scratch alias prefix. Substitute your authenticated Dev Hub alias.

A fresh scratch smoke verified all 100 statements, 200 Opportunities, and 400 line items with zero Apex callouts. The browser output matched the source pages in order.

```bash
cd experiments/portwood-bulk-pdf-benchmark
npm ci
export PORTWOOD_DEV_HUB='your-dev-hub-alias'
export PORTWOOD_ACCOUNT_COUNT=100
export PORTWOOD_ORG_COUNT=1
export PORTWOOD_BATCH_SHARDS=1
export PORTWOOD_ORG_PREFIX='portwood-pdf-smoke'
export PORTWOOD_RUN_KEY='PWCEDAR-100'
bash tmp/portwood-account-packets-100k/provision.sh
bash tmp/portwood-account-packets-100k/seed-all.sh
bash tmp/portwood-account-packets-100k/run-all.sh
bash tmp/portwood-account-packets-100k/finish.sh
```

For the measured configuration, set the scale and use a fresh prefix, then run the same four commands.

```bash
export PORTWOOD_ACCOUNT_COUNT=100000
export PORTWOOD_ORG_COUNT=8
export PORTWOOD_BATCH_SHARDS=5
export PORTWOOD_ORG_PREFIX='portwood-pdf-benchmark-100k'
export PORTWOOD_RUN_KEY='PWCEDAR-100000'
bash tmp/portwood-account-packets-100k/provision.sh
bash tmp/portwood-account-packets-100k/seed-all.sh
bash tmp/portwood-account-packets-100k/run-all.sh
bash tmp/portwood-account-packets-100k/finish.sh
```

Keep the same environment values throughout one run. `PORTWOOD_PACKAGE_ID` defaults to the reference package and can select a compatible installed build for a comparison. The measured configuration used 40 Accounts per Batch Apex scope and 12 export workers per org. The number of orgs sets the storage and job parallelism as well as the shape of the timing comparison.

| Stage | What to look for |
| --- | --- |
| Provision | Scratch aliases are created, managed Portwood is installed, the admin and user permission sets are assigned, the experiment class is deployed, and the template ID is saved. |
| Seed | An inclusive ordinal range is created and queried back in each org. The manifest records exact Account, Opportunity, and line-item IDs and confirms two gifts per Account and two items per gift. |
| Generate and export | A private submission receipt records Batch Apex job IDs. The audit checks every ordinal and exact ContentVersion, privacy, checksum, zero recorded Apex callouts, and absence of batch errors. Exports land as six-digit PDFs in one local folder. |
| Merge and verify | Chrome reads the ordered loopback manifest, appends the source pages into a browser-managed file, and downloads the merged PDF. Poppler verifies source-to-output text and sampled pixels. The semantic verifier checks the fixture fields on every page. |

Look under `runs/<run-key>/output/` for the merged PDF and `runs/<run-key>/artifacts/` for timings, SHA-256, and verification. Keep the run folder until you've collected the evidence. The [published results](evidence/100000-results.json) report the exact byte counts and checksums from the reference run. The original 239 MiB output is reproduced from the harness rather than checked into Git.

### Resume and diagnose

- Preserve the run key, scratch aliases, ordinal ranges, and run folder. The seeder checks existing fixture records before inserting. The generation step discovers its existing submission receipt and resumes monitoring. The exporter reuses local PDFs whose bytes match Salesforce's checksum. Invoke `run-all.sh` with the numeric org index, for example `bash tmp/portwood-account-packets-100k/run-all.sh 3`, to resume one org, then run `finish.sh`.
- If a batch reports errors, inspect its status and the org's Apex Jobs page before progressing. The benchmark requires a complete set of Files. After addressing the cause, use a new run key and fresh scratch aliases to reproduce the full timing. The [product proposal](IMPLEMENTATION.md) specifies per-ordinal retries for a partially completed customer job.
- If storage is exhausted, inspect `sf limits api display --target-org <scratch-alias>` and repeat with fewer Accounts per org or fresh scratch orgs. Record and File storage are separate and the storage counters update asynchronously. [Salesforce storage allocations](https://help.salesforce.com/s/articleView?id=limits.htm&language=en_US&type=5)
- A scratch org expires automatically. When a run is complete and its evidence is saved, you can remove your own disposable scratch org with `sf org delete scratch --target-org <scratch-alias>`. Salesforce Files and synthetic records in that scratch org expire with it.

## Source map

| Piece | Entry point |
| --- | --- |
| Synthetic data and HTML receipt | [Seeder](scripts/bench/seed-portwood-account-packets.mjs), [template](scripts/bench/portwood-account-contribution-statement.html) |
| Create the template and render the private Files | [Template builder](tmp/portwood-live-receipt-timing/prepare-account-template.py), [Batch Apex](tmp/portwood-live-receipt-timing/bulk-source/main/default/classes/PortwoodAccountReceiptBatch.cls), [submission and audit](tmp/portwood-live-receipt-timing/orchestrate-account-batches.mjs) |
| Authenticated export and checksum verification | [File exporter](tmp/portwood-live-receipt-timing/export-account-packets.mjs), [Salesforce transport](scripts/lib/salesforce-pdf-transport.mjs) |
| Browser merge | [Browser runner](scripts/bench/portwood-pdf-merge-stress.mjs), [worker](scripts/bench/portwood-pdf-merge-browser.worker.mjs), [streaming writer](scripts/lib/portwood-browser-pdf-merge.mjs) |
| Verify the statement fields | [Semantic verifier](tmp/portwood-live-receipt-timing/verify-account-packets.py) |

# Giant Query PDF limits

This report measures the server-side path for HTML-backed PDFs with multiple tables and direct V3 child queries. A template with one table still uses the original Giant Query path. [PR #543](https://github.com/Portwood-Global-Solutions/Portwood/pull/543)

## How to read the results

Source records are unique records read from Salesforce. Printed rows count each placement in the PDF. A repeated table can print the same records again from one cursor. Each end-to-end pass requires a Salesforce File with every expected row in the authored section and sort order. Both failed cases below staged every row and reported an Apex heap exception during final assembly.

The PDF tests use synthetic data in a scratch org. The CLI creates the fixture, starts the real Portwood Runner's Apex methods, and streams the completed file for local text validation. Salesforce performs data retrieval, row rendering, assembly, and file publication.

## Measured sizes

These results were measured on November 15, 2026 in a Developer scratch org seeded with 100,000 synthetic Contacts. Both compact and rich tests render three cells per row. The rich fixture adds inline styles and a two-sentence note that wraps.

| Fixture                            | Source records | Printed rows | Staged HTML bytes | PDF pages | PDF bytes | Observed time | Result                            |
| ---------------------------------- | -------------: | -----------: | ----------------: | --------: | --------: | ------------: | --------------------------------- |
| Compact, two distinct queries      |         10,000 |       10,000 |           587,786 |       132 |   318,067 |        1m 16s | All rows verified                 |
| Compact, two distinct queries      |         25,000 |       25,000 |         1,477,788 |       330 |   685,527 |        3m 33s | All rows verified                 |
| Compact, two distinct queries      |         50,000 |       50,000 |         2,977,788 |       660 | 1,302,618 |        6m 44s | All rows verified                 |
| Compact, two distinct queries      |        100,000 |      100,000 |         5,977,788 |     1,321 | 2,539,329 |       12m 57s | All rows verified                 |
| Compact, one query used four times |         50,000 |      200,000 |        11,955,576 |         — |         — |       18m 16s | Apex heap failure joining HTML    |
| Wrapped text, two distinct queries |         10,000 |       10,000 |         3,497,786 |       346 |   649,117 |        1m 22s | All rows verified                 |
| Wrapped text, two distinct queries |         25,000 |       25,000 |         8,752,788 |       946 | 1,603,397 |         3m 4s | All rows verified                 |
| Wrapped text, one query used twice |         25,000 |       50,000 |        17,527,788 |         — |         — |        5m 20s | Apex heap failure during assembly |

The largest verified compact run published one 100,000-row PDF. The 200,000-row compact run staged all 4,000 fragments and then failed while joining the complete HTML, before `Blob.toPdf()`. Apex reported `Apex heap size too large: 26985858`.

The 50,000-row wrapped-text job staged all 1,000 fragments and failed in the final Queueable with `Apex heap size too large: 35080015`. The 25,000-row run passed with the same row layout. These exceptions report heap used at failure. Salesforce publishes the heap allowance separately.

Staged bytes sum the `ContentVersion.ContentSize` of the row fragments. They exclude template chrome and the extra markup used to split tables for pagination. Observed time runs from requesting the job until the CLI sees a terminal status. Several cases ran concurrently in the scratch org, so the timings reflect that queue load.

## Where jobs run out of capacity

- **Retrieval and row rendering.** Portwood fetches 50 source records at a time and processes up to 16 pages per Queueable transaction. Between pages it checks heap and CPU and can yield earlier. Salesforce allows up to 50 million records per cursor and applies daily org allowances when a cursor opens. [Apex Cursors](https://developer.salesforce.com/docs/platform/apex-dev/references/apex-dev/apex-cursors.html)
- **Final assembly.** One Queueable loads the staged fragments, joins the entire HTML, checks assets and fonts, renders it with one `Blob.toPdf()` call, and saves the PDF. Salesforce documents a 25 MB asynchronous Apex heap and 60 seconds of Apex CPU per transaction. Its Visualforce PDF renderer also documents a pre-render response under 15 MB, a 60 MB generated PDF limit, and 30 MB of images. Heap, CPU, or renderer complexity can fail first. [Apex governor limits](https://developer.salesforce.com/docs/platform/apex-dev/references/apex-dev/apex-gov-limits.html) · [PDF renderer limits](https://developer.salesforce.com/docs/platform/salesforce-pages-developers-guide/guide/pages-output-pdf-considerations.html)
- **Fragment cleanup.** Each physical table produces one temporary Salesforce File per 50 printed rows, rounded up per table. Successful assembly attempts to delete those Files in the final transaction. The transaction shares a 10,000-DML-row budget with publication and asset linking. Failed assembly can leave fragments in the org. [Apex governor limits](https://developer.salesforce.com/docs/platform/apex-dev/references/apex-dev/apex-gov-limits.html)
- **Download.** This benchmark verifies Salesforce Files publication and streaming retrieval. The Runner's automatic browser download separately requests a Base64 copy through synchronous Apex.

The Runner uses a heap estimate to decide when to start Giant Query. The estimate describes routing. The 2,000-row split in each long HTML table helps the renderer paginate. The PDF is still rendered in one call. A repeat header can appear twice on the page containing the split.

## Reproduce the measurement

Use a scratch org with the PR source deployed, an authenticated Salesforce CLI, Node.js, and Poppler (`pdfinfo` and `pdftotext`). Create a synthetic Account in that org and generate a CSV of its Contacts. Put its ID in `GQ540_ACCOUNT_ID`.

```sh
export GQ540_ORG="your-scratch-org-alias"
export GQ540_ACCOUNT_ID="your-synthetic-account-id"
export GQ540_RUN_DIR="$(mktemp -d)"

python3 - <<'PY'
import csv
import os

account = os.environ["GQ540_ACCOUNT_ID"]
with open(os.path.join(os.environ["GQ540_RUN_DIR"], "contacts.csv"), "w", newline="") as file:
    writer = csv.writer(file, lineterminator="\n")
    writer.writerow(["AccountId", "LastName", "FirstName", "Department"])
    for group in "AB":
        for index in range(1, 50_001):
            writer.writerow([account, f"{group}{index:06}", f"Tie{(index-1) % 13:02}", f"Scale {group}"])
PY

sf data import bulk --target-org "$GQ540_ORG" --sobject Contact \
  --file "$GQ540_RUN_DIR/contacts.csv" --line-ending LF --wait 15

node scripts/qa/giant-query-540-scale.mjs \
  --org "$GQ540_ORG" --account "$GQ540_ACCOUNT_ID" \
  --rows 10000 --rows 25000 --rows 50000 --rows 100000 \
  --output-dir "$GQ540_RUN_DIR/compact"
```

The compact template uses two filtered Contact queries with three short cells per row. `--shape rich` adds styled cells and wrapped text. `--placements 2` repeats the same query in two tables. When using repeated placements, `--rows` gives the total printed rows across those tables. For the wrapped-text assembly failure, use `--shape rich --placements 2 --rows 50000`. For the compact assembly failure, use `--placements 4 --rows 200000`. Keep row shape and placement count fixed when comparing sizes.

Open `matrix.json` for the outcome of each run. Each case directory contains `result.json` with the scout counts, job status, staged row count, failure stage and message, timing, and PDF verification fields. Successful cases also save `output.pdf`. A published file passes verification only when the extracted content contains the exact expected row sequence and values in every table.

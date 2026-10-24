Make one document per record without opening every record yourself.

**Before you start:** Check one document first. Use an active template and a filter that selects only the intended records.

#### Try a small run

1. Open **Portwood → Bulk Generation**.
2. Select the template.
3. Choose a saved filter or enter a **SOQL Condition**. For the fictional Accounts in this guide:

    ```sql
    Name IN ('Northstar Bikes', 'Willow and Pine', 'Bluebird Studio')
    ```

4. Click **Validate Filter** and check how many records match.
5. Select a **Sample Record** and click **Preview Sample PDF** when available.
6. Choose the output mode.
7. Give the job a useful name. Leave **Batch Size = 1** for your first run, especially with images or charts.
8. Click **Run Bulk Generation**.
9. Review the job and its files when processing finishes.

The condition is the filter only. Do not include `SELECT` or the word `WHERE` in that field.

![The bulk runner has validated the three fictional Accounts and is set to Individual Files](docs/images/userguide/v3.60/bulk-ready.png)

#### Choose the right output

| Mode                      | Use it when…                                     |
| ------------------------- | ------------------------------------------------ |
| **Individual Files**      | Each record needs its own file                   |
| **Print-Ready Packet**    | You want one PDF covering the selected records   |
| **Combined + Individual** | You need the individual files and a combined PDF |

Word, HTML, and supported Canvas PDF workflows can be used for PDF documents. Native Excel and PowerPoint output and fillable PDF forms require **Individual Files**. Follow any compatibility message shown for the selected template.

#### Put the documents in order

Choose **Sort By** and **Direction** before running. This controls processing and the order in the combined PDF. The order of records in a manually prepared list is not a substitute for sorting the job.

#### Print double-sided

For Print-Ready Packet or Combined + Individual, turn on **Duplex Padding** when each document should start on the front of a sheet. Portwood adds a blank page after odd-length documents in the combined packet. Individual files are left unpadded.

Duplex packets have a size estimate based on the sample record. Large images or embedded fonts can reduce how many documents fit in one packet. Split large runs or choose Individual Files when the estimate or job asks for it.

#### Save a filter for next time

Use the bulk runner's save-filter control. Give it a name your team understands, such as **Current customer statements**. Next time, select it instead of typing a condition.

**You are done when:** The success/failure counts match what you expected and a sample of the finished files is correct.

Review [Read job status and recover failures](#job-history) before rerunning a partially successful job.

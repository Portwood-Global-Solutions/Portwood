Make one document per record without opening every record yourself.

**Before you start:** Check one document first. Use an active template and a filter that selects only the intended records.

#### Try a small run

1. Open **Portwood → Bulk Generation**.
2. Select the template.
3. Choose **SOQL filter** and enter a condition or load a saved filter. For the fictional Accounts in this guide:

    ```sql
    Name IN ('Northstar Bikes', 'Willow and Pine', 'Bluebird Studio')
    ```

4. Click **Validate Filter** and check how many records match.
5. Select a **Sample Record** and click **Preview Sample PDF** when available.
6. Choose the output mode.
7. Give the job a useful name. Leave **Batch Size = 1** for your first run, especially with images or charts.
8. Click **Run Bulk Generation**.
9. Review the job and its files when processing finishes.

To use a saved report, choose **Salesforce report**, search by name, and select a tabular report containing the template object's record ID column. Click **Preview Report Records** to see the number of distinct eligible records after the template filter. If Salesforce truncates the report, you can narrow its filters or confirm generation from the first 2,000 rows. Choose **Merge PDFs in Browser** to stream those records into one PDF.

Enter the condition that follows the main query's `WHERE`. For an Account template, this example selects households with a Contact in California.

```sql
RecordType.DeveloperName = 'HH_Account'
AND Id IN (SELECT AccountId FROM Contact WHERE MailingState = 'CA')
```

Use your org's record type developer name. Salesforce supports up to two top-level `IN` or `NOT IN` subqueries joined by `AND`. The count also applies the selected template's saved Record Filter.

Filters can traverse supported standard lookups as well as custom relationships. For example, use `RecordType.DeveloperName = 'Partner_Account'`, `Owner.Email = 'owner@example.com'`, or a custom `Account__r.Region__c = 'West'` condition when those fields are available on the selected object. The same relationship rule applies to child-record filters. If the object has no Record Types, or a Record Type value is malformed, the validation message explains the issue. Keep the filter to conditions the builder allows; unknown fields and disallowed SOQL keywords remain rejected.

![The bulk runner has validated the three fictional Accounts and is set to Individual Files](docs/images/userguide/v3.60/bulk-ready.png)

#### Choose the right output

| Mode                      | Use it when…                                           |
| ------------------------- | ------------------------------------------------------ |
| **Individual Files**      | Each record needs its own file                         |
| **Print-Ready Packet**    | You want one PDF covering the selected records         |
| **Combined + Individual** | You need the individual files and a combined PDF       |
| **Merge PDFs in Browser** | You want one download from a large set of private PDFs |

Word, HTML, and supported Canvas PDF workflows can be used for PDF documents. Native Excel and PowerPoint output and fillable PDF forms require **Individual Files**. Follow any compatibility message shown for the selected template.

#### Download a large merged PDF

1. Select a PDF template and choose **Merge PDFs in Browser**.
2. Start the run. Portwood makes a private PDF for each selected record in the background.
3. Open the completed job from its notification or Recent Jobs, then choose **Download merged PDF**.
4. Keep the browser open while it assembles and saves the PDF. If the connection drops or the page closes, reopen the same job in the same browser profile to resume.

Use a current desktop browser that supports browser-managed file storage. The mode supports up to 100,000 source records and up to 1 MiB per generated PDF. Each source PDF uses Salesforce File storage. The browser needs space for the merged PDF on the device. If some statements fail, review the job and choose **Retry missing PDFs** when available before downloading.

#### Put the documents in order

Choose **Sort By** and **Direction** before running. This controls processing and the order in the combined PDF. The order of records in a manually prepared list is not a substitute for sorting the job.

#### Print double-sided

For Print-Ready Packet, Combined + Individual, or Merge PDFs in Browser, turn on **Duplex Padding** when each document should start on the front of a sheet. Portwood adds a blank page after odd-length documents in the combined packet. Individual files are left unpadded.

Server-side duplex packets have a size estimate based on the sample record. Large images or embedded fonts can reduce how many documents fit in one packet. Split large runs or choose Individual Files when the estimate or job asks for it.

#### Save a filter for next time

Use the bulk runner's save-filter control. Give it a name your team understands, such as **Current customer statements**. Next time, select it instead of typing a condition.

**You are done when:** The success/failure counts match what you expected and a sample of the finished files is correct.

Review [Read job status and recover failures](#job-history) before rerunning a partially successful job.

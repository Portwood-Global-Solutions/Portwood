Schedule a document run instead of starting it by hand.

**Before you start:** Test the template and filter in [Bulk Generation](#bulk-generation). A Salesforce administrator should design the schedule and Flow error handling.

#### Configure the action

1. Create the automation that should launch the run, such as one scheduled Flow.
2. Add **Generate Bulk Documents** from Portwood.
3. Set **Template API Name** or **Template ID**.
4. Supply a **WHERE Condition** or a **Record IDs** collection.
5. Set the job label, output options, batch size, and sort order.

Example inputs for the downloadable Account Brief template:

| Input                          | Example                                          |
| ------------------------------ | ------------------------------------------------ |
| **Template API Name**          | `KB_Account_Brief`                               |
| **WHERE Condition**            | `Name IN ('Northstar Bikes', 'Willow and Pine')` |
| **Sort Order**                 | `Name ASC`                                       |
| **Job Label**                  | `Practice account briefs`                        |
| **Combined PDF Only**          | `False`                                          |
| **Also Keep Individual Files** | `True`                                           |
| **Batch Size**                 | `1`                                              |

Use your own filter for real work. **Sort Order** contains field names and direction, without the words `ORDER BY`.

#### Avoid launching the same run repeatedly

If a scheduled Flow starts once per matching record, adding a bulk action that already queries all records can launch the entire run many times. Design one launch per intended batch, or pass the intended record IDs with a deliberate batching strategy.

#### Follow the result

Store **Success**, **Error Message**, and **Job ID**. Add a Decision for an unsuccessful response and a fault connector for an unexpected action failure.

The action submits background work and returns. Follow the job in Portwood job history; do not email a completion notice just because submission returned successfully.

When producing a combined PDF for double-sided printing, the action's **Duplex Padding** input applies the same behavior as the bulk UI.

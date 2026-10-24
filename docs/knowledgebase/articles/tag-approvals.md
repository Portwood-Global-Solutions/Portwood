Use this built-in relationship for classic Salesforce approval history. Check the output against a record with an actual approval submission.

**Before you start:** Choose the fields and relationships in [Choose information](#choose-data). For an orientation and the format checklist, open [Find the right merge tag](#merge-tags).

#### Classic Approvals related list — `{#Approvals}` (v1.92+)

Render the host record's Salesforce **Classic Approvals** process history (submission, every approval/rejection step) directly in a generated document. Common use cases: Purchase Orders showing every approver up the chain in the final PDF, NDAs stamped with each signatory's role + timestamp, change-management forms with the approval audit trail rendered alongside the form data.

**Opt-in via Query_Config\_\_c.** Add the standalone word `Approvals` somewhere in the template's Query_Config**c (case-insensitive, word-boundary — `MyApprovalsList**c`doesn't activate it). When Portwood sees the token, it queries`ProcessInstance`+`ProcessInstanceStep`for the host record and exposes the flattened step list as a child collection at the`Approvals` key.

Example Query_Config\_\_c entry:

```
Name, Status__c, Amount__c, Approvals
```

Example template body:

```
{#Approvals}
{ActorName} ({ActorTitle}) — {StepStatus} — {CreatedDate:MM/dd/yyyy h:mm a}
Comments: {Comments}

{/Approvals}
```

**Fields available inside the loop:**

| Field               | Source                                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------ |
| `ActorName`         | `Step.Actor.Name` — who actually took the action                                                       |
| `ActorTitle`        | `Step.Actor.Title` — title on the User who acted                                                       |
| `ActorEmail`        | `Step.Actor.Email`                                                                                     |
| `OriginalActorName` | `Step.OriginalActor.Name` — useful when an approval was reassigned (delegated to)                      |
| `StepStatus`        | `Started`, `Approved`, `Rejected`, `Removed`, `NoResponse` — see Salesforce docs for the full list     |
| `Comments`          | Approver's comments (empty string when omitted)                                                        |
| `CreatedDate`       | When the step occurred — works with the standard `{CreatedDate:MM/dd/yyyy}` format specifiers (§7.2)   |
| `ProcessStatus`     | The parent `ProcessInstance.Status` — the overall outcome of the approval process this step belongs to |
| `SubmittedByName`   | Who originally submitted for approval (constant within one ProcessInstance)                            |
| `SubmittedByTitle`  | Submitter's User.Title                                                                                 |

**Sorting.** Steps are sorted earliest-first within each ProcessInstance, and ProcessInstances are sorted earliest-first. So a record that was submitted, rejected, then resubmitted and approved produces the steps in chronological order across both submissions.

**What's not included (yet).** Only steps that have been _acted on_ appear — pending approval items (`ProcessInstanceWorkitem`) are not in the list. If you need "still awaiting approver X", that's a separate query. Flow-based approval orchestration is a different object model and out of scope; this tag covers the Classic Approvals process only.

**Cost.** One extra SOQL query per generation when the token is present. Templates that don't reference `Approvals` in Query_Config\_\_c skip the query entirely — no overhead.

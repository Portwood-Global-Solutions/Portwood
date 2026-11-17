V1, V2, and V3 describe Salesforce record queries. V4 binds a custom provider or the special Flow JSON source. Use the visual V3 builder for new record-query templates unless a specific integration needs a different format.

#### V1 — Legacy flat string

Plain field/subquery selection string. Use V3 when you need a richer tree or explicit child configuration.

```
Name, Industry, (SELECT FirstName, LastName FROM Contacts)
```

Detected when the config does NOT start with `{`.

#### V2 — JSON flat (junction support)

Adds junction-object support for many-to-many (e.g., Account ↔ Contact via AccountContactRelation).

```json
{
    "v": 2,
    "baseObject": "Opportunity",
    "baseFields": ["Name"],
    "parentFields": ["Account.Name"],
    "children": [{ "rel": "OpportunityLineItems", "fields": ["Name"] }],
    "junctions": [
        {
            "junctionRel": "OpportunityContactRoles",
            "targetObject": "Contact",
            "targetIdField": "ContactId",
            "targetFields": ["FirstName"]
        }
    ]
}
```

#### V3 — Query tree (multi-object, any depth)

Preferred. Tree of nodes — each node is one SOQL query, stitched into the parent's data map via `lookupField`.

```json
{
    "v": 3,
    "root": "Account",
    "nodes": [
        {
            "id": "n0",
            "object": "Account",
            "fields": ["Name"],
            "parentFields": ["Owner.Name"],
            "parentNode": null,
            "lookupField": null,
            "relationshipName": null
        },
        {
            "id": "n1",
            "object": "Contact",
            "fields": ["FirstName"],
            "parentFields": [],
            "parentNode": "n0",
            "lookupField": "AccountId",
            "relationshipName": "Contacts"
        },
        {
            "id": "n2",
            "object": "Opportunity",
            "fields": ["Name", "Amount"],
            "parentFields": [],
            "parentNode": "n0",
            "lookupField": "AccountId",
            "relationshipName": "Opportunities"
        },
        {
            "id": "n3",
            "object": "OpportunityLineItem",
            "fields": ["Quantity"],
            "parentFields": ["Product2.Name"],
            "parentNode": "n2",
            "lookupField": "OpportunityId",
            "relationshipName": "OpportunityLineItems"
        }
    ]
}
```

#### Using the visual builder

The visual query builder walks your schema like a tree: start from the base object, tick fields (blue pills), climb into **+ parent lookup**, and expand **+ related list** child sections — each child with its own Tag name, Filter (WHERE), Sort by, and Limit. It writes a V3 config. As of v3.37 the same builder appears everywhere a query gets built: **Edit Template → Query Configuration**, the **designer's Query panel**, and the **Generate-with-AI** step.

**Multi-hop parent traversal (v1.97+).** On any object's `parentFields` panel, expand a lookup and the builder now recurses into the parent's lookup tree — for example, on an Opportunity tab, expand `Account` → `Parent` → `Owner` → pick `Name`, and the resulting merge tag is `{Account.Parent.Owner.Name}`. The recursion is capped at 5 hops to keep schema-load latency bounded. Each hop loads its target object's fields lazily on expand. Use this when the data you need lives more than one lookup away from the base object and you don't want to compose `parentFields` paths by hand.

For direct JSON editing or V1 legacy configs, toggle **Manual Query** mode and the older `docGenQueryBuilder` appears.

#### Per-child filters, order by, limit

Each V3 child node supports:

- `fields`: scalar fields to SELECT
- `parentFields`: dotted lookup fields (e.g., `Product2.Name`)
- `where`: optional `WHERE` clause (sanitized for SOQL injection)
- `orderBy`: optional `ORDER BY` (sanitized)
- `limit`: optional `LIMIT`

- `parentKeyField`: optional lookup on the parent record to use as the join key
- `single`: optional. Set to `true` to merge the first matching record as one object

Giant Query can select ordinary child collections for background processing. It skips lookup joins and single-record nodes when choosing the large collection.

#### Joining through a parent's lookup (`parentKeyField`, `single`)

A child node normally fetches the records whose `lookupField` points at its parent record. Sometimes the records you need point at something the parent _looks up to_ instead. A document on a custom `Project__c` with an `Opportunity__c` lookup may need that Opportunity's contact roles: they point at the Opportunity, not the project, and no subquery can reach them.

`parentKeyField` names a lookup field on the parent node's object. The node then matches its `lookupField` against that lookup's value instead of the parent's Id:

```json
{
    "id": "n1",
    "object": "OpportunityContactRole",
    "parentNode": "n0",
    "relationshipName": "OpportunityContactRoles",
    "alias": "Architect",
    "lookupField": "OpportunityId",
    "parentKeyField": "Opportunity__c",
    "single": true,
    "fields": ["Role"],
    "parentFields": ["Contact.Name", "Contact.Email"],
    "where": "Role = 'Architect'",
    "orderBy": "CreatedDate",
    "limit": "1"
}
```

- `parentKeyField` must be a lookup (reference) field on the parent node's object. Anything else stops generation with a clear error. You don't need to add it to the parent's `fields`; Portwood selects it.
- When the parent's lookup is blank, the node merges empty: tags render blank and loops render no rows.
- `single: true` merges the first matching record as one object, so its fields read like a lookup, with no loop: `{Architect.Contact.Name}`. With no match the tags render blank. Use `where` to narrow the matches, and `orderBy` to choose which record comes first. Portwood uses the record ID as a tiebreaker and as the default sort.
- `single` matters most in Excel, where a loop that is its row's only tag repeats the row per record and removes it when there are none. Single tags never add or remove rows.
- In bulk generation, records that share one lookup value (two projects on one Opportunity) each get the same related records, from one query.
- `parentKeyField` and `single` nodes are skipped when choosing a Giant Query collection.
- The visual builder can't edit these nodes, because the parent's schema doesn't list the relationship. It keeps them exactly as configured, names them in a note above the tree, and writes them back unchanged when you save. Edit them in **Manual Query** mode.

#### Apex Data Provider (V4 — class-backed templates)

When the data you need to render isn't an SObject — external API responses, computed totals, cross-object aggregations, anything SOQL can't reach — implement the `portwoodglobal.DocGenDataProvider` interface in your org and bind a template to that class. The merge engine calls your class at render time and uses whatever Map you return.

##### Step 1 — write the provider class in your org

```apex
/** Subscriber-side example. Deploy to your org after installing Portwood. */
global with sharing class KBAccountProvider implements portwoodglobal.DocGenDataProvider {
    global Map<String, Object> getData(Id recordId) {
        Account account = [
            SELECT Name, Industry, Phone
            FROM Account
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
        List<Object> contacts = new List<Object>();
        for (Contact contact : [
            SELECT Name, Email, Title
            FROM Contact
            WHERE AccountId = :recordId
            WITH USER_MODE
            ORDER BY Name
            LIMIT 100
        ]) {
            contacts.add(
                new Map<String, Object>{ 'Name' => contact.Name, 'Email' => contact.Email, 'Title' => contact.Title }
            );
        }
        return new Map<String, Object>{
            'Name' => account.Name,
            'Industry' => account.Industry,
            'Phone' => account.Phone,
            'ContactCount' => contacts.size(),
            'Contacts' => new Map<String, Object>{ 'records' => contacts }
        };
    }
    global List<String> getFieldNames() {
        return new List<String>{
            'Name',
            'Industry',
            'Phone',
            'ContactCount',
            'Contacts.Name',
            'Contacts.Email',
            'Contacts.Title'
        };
    }
}
```

The sample deliberately returns at most 100 Contacts; its count reflects those returned rows. For a minimal deployed-and-executed example, use [KBAccountProvider](#apex-data-provider).

Two methods are required, both `global`. `getData` returns a `Map<String, Object>`; `getFieldNames` returns the list of merge tags shown in the wizard.

The interface lives in the managed package — reference it with the full namespace: `portwoodglobal.DocGenDataProvider`.

##### Step 2 — bind a template to the class

In the Portwood app → New Template:

1. **Step 1 — Data Source**: pick **Apex Class (Data Provider)** instead of Salesforce Record.
2. **Data Provider Class**: search for your class name (e.g., `KBAccountProvider`). The picker filters to classes implementing `portwoodglobal.DocGenDataProvider`. Select yours.
3. The wizard validates the class, calls `getFieldNames()`, and displays the available merge tags.
4. **Step 2** lands directly on the connected-provider view. Compose your template body using the merge tags as you would for any other template.
5. **Step 3** — review and save.

Behind the scenes the template's `Query_Config__c` becomes `{"v":4,"provider":"KBAccountProvider"}`. You can also flip an existing SOQL-backed template to v4 from the **Edit modal → Query Configuration → Use Apex data provider** link.

##### Step 3 — generate

Same as any template. The Portwood app's Generate button, the **Generate Document** Flow action, the Apex `DocGenService.generateDocument()` API — all of them detect the v4 binding automatically and call your class.

```apex
// From Apex — exactly the same call shape as a SOQL-backed template
Id contentDocId = portwoodglobal.DocGenService.generateDocument(templateId, accountId, null);
```

##### Common patterns

- **External callout**: do the callout in `getData`, parse the response, return the parsed Map. Bear in mind callouts subject to governor limits and DML-before-callout rules.
- **Cross-object aggregations**: query whatever you need, build aggregates in Apex, expose them as merge tags.
- **Custom Metadata-driven**: read Custom Metadata Type records to resolve the data shape dynamically.
- **Standalone (no recordId)**: ignore the `recordId` parameter and return data assembled from elsewhere. Useful for "render a report for the current user" templates.

If you don't want template-side binding at all — the data is already in a Flow variable or an Apex wrapper — use **runtime data injection** instead: the **Generate Document** Flow action accepts a `JSON Data` invocable variable, and `DocGenService.generatePdfBlobFromData(templateId, dataMap)` accepts an Apex Map directly. Same merge engine, same tags, no class to write.

##### 6.6.1 JSON Data (from Flow) — template authoring mode

When a template will _only_ ever receive its data from a Flow via `DocGenFlowAction.jsonData`, pick **JSON Data (from Flow)** as the Data Source in Step 1. The wizard then skips the Base Object picker, the SOQL query builder, and the Apex Provider class picker — there's nothing to configure between naming the template and uploading the document.

Behind the scenes the template stores `Base_Object_API__c = 'FlowJsonData'` (a sentinel value) and `Query_Config__c = {"v":4,"source":"flowJsonData"}`. The sentinel keeps the template invisible to the standard record-page Generate-Document launcher (whose query is `WHERE Base_Object_API__c = :objectApiName`) — JSON Data templates are intentionally Flow-only. To invoke one, pass `jsonData` into the **Generate Document** Flow action; the merge engine resolves `{Field}`, `{Parent.Field}`, and `{#Items}…{/Items}` against your JSON shape just like any other template.

---

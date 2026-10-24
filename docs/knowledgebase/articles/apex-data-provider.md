A provider prepares the dataset before Portwood merges it. Use one for calculated values, deliberately shaped reports, or data that the visual query builder cannot express.

#### 1. Implement both required methods

```apex
global interface DocGenDataProvider {
    Map<String, Object> getData(Id recordId);
    List<String> getFieldNames();
}
```

Your class implements `portwoodglobal.DocGenDataProvider`; expose both methods as global. `getData()` supplies values and `getFieldNames()` supplies the authoring field list. The old one-method example was incomplete.

Use the complete [KBAccountProvider class](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/apex/KBAccountProvider.cls) and its [metadata file](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/examples/apex/KBAccountProvider.cls-meta.xml). It uses `with sharing` and `WITH USER_MODE`, selects standard Account/Contact fields, limits the Contact query to 100, and implements both methods. The ContactCount is the count of those returned rows, not a claim to count unlimited Contacts.

#### 2. Understand the data shape

```apex
Map<String, Object> data = new Map<String, Object>{
    'Name' => 'Northstar Bikes',
    'Owner' => new Map<String, Object>{'Name' => 'Practice Owner'},
    'Contacts' => new Map<String, Object>{
        'records' => new List<Object>{
            new Map<String, Object>{'Name' => 'Avery Chen', 'Email' => 'avery@example.com'}
        }
    }
};
```

| Data                              | Template                                |
| --------------------------------- | --------------------------------------- |
| Root scalar                       | `{Name}`                                |
| Nested map                        | `{Owner.Name}`                          |
| Relationship wrapper with records | `{#Contacts}{Name}: {Email}{/Contacts}` |

Inside the loop, `Name` is the Contact's key. Include parent paths and list field paths in `getFieldNames()` so an author can discover them. Keep shape and casing stable as your provider evolves.

#### 3. Bind the template

Choose **Apex Class (Data Provider)** as its data source and enter `KBAccountProvider`, or set the equivalent Query Config:

```json
{ "v": 4, "provider": "KBAccountProvider" }
```

Save and activate a version, select a valid sample Account, and preview. The provider example was deployed and executed against the installed 3.60.0 package. It returned Northstar Bikes and two Contacts; its field list exposed the expected paths.

#### 4. Test your own boundary cases

Test an inaccessible record/field, no related rows, null values, many rows, and the intended Flow/bulk path. Keep data selection separate from layout so a template change does not silently widen access. A provider is responsible for sharing, object/field permissions, and any external integration policy.

#### Use a map without a provider

If your calling process already has the data, use `generatePdfBlobFromData` or `generateAndSaveFromData`. The same root/map/records shape applies. You do not need to insert temporary Salesforce records just to merge calculated values.

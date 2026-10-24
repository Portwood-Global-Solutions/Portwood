Use information your Flow or developer has prepared instead of querying a normal Salesforce record.

Most templates should start with the visual field chooser. Use a custom-data path when the document needs calculated structures, API results, or a deliberately prepared dataset.

#### Pass JSON from a Flow

Create a template using **Data Source = JSON Data (from Flow)** and provide sample data for authoring. In **Generate Document**, set **JSON Data** to the text your Flow prepares.

A small example:

```json
{
    "Name": "Northstar Bikes",
    "Total": 240,
    "Items": {
        "records": [{ "Description": "Workshop", "Quantity": 2, "Price": 120 }]
    }
}
```

The template can use `{Name}`, `{Total:currency}`, and a repeating `{#Items}…{/Items}` section.

Supplying JSON bypasses the normal data query. Portwood does not create those Salesforce records for you. If the result should attach to a record, provide its **Record ID** and **Save to Record = True** as well.

#### Use an Apex data provider

A developer can implement **DocGenDataProvider** and bind the template to that class. The provider returns the values and lists the document needs.

Your developer is responsible for the provider's data access, filtering, errors, and any external integrations. The core document-generation path does not automatically make a provider's callouts or data handling safe or storage-free.

The [query and provider reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/query-config.md) includes the interface, configuration, examples, and execution constraints.

#### Test the shape, not just one example

Try empty lists, missing optional values, many rows, long text, and errors from the source system. Keep authoring sample data representative and free of sensitive customer information.

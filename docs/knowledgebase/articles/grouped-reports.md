Use one dataset and `{#GroupBy}` when the categories can change. Use deliberately filtered query aliases when each section has a different data-selection rule.

#### One table per stage

Select Opportunities with `Name`, `StageName`, and `Amount`. Sort by `StageName` if you want groups in stage order. This HTML wraps a complete table in the group and keeps the row loop inside its cells:

```html
<div>{#GroupBy Opportunities by StageName}</div>
<h2>{GroupName}</h2>
<table style="width:100%;border-collapse:collapse;">
    <thead>
        <tr>
            <th>Opportunity</th>
            <th>Amount</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td>{#Opportunities}{Name}</td>
            <td>{Amount:currency}{/Opportunities}</td>
        </tr>
    </tbody>
</table>
<p>Stage total: {SUM:Opportunities.Amount:currency}</p>
<div>{/GroupBy}</div>
<p>All stages: {SUM:Opportunities.Amount:currency}</p>
```

Inside the group, the Opportunities relationship contains that group's members. Outside it, the total sees the whole available relationship. `{RowNumber}` restarts within each group's row loop.

#### A different alias is not a filter

Renaming `{#QuoteLineItems}` to `{#Purchase}` does not select purchase items. `Purchase` must exist in Query Config or the supplied data. Either configure two filtered aliases, use a prepared provider, or keep the real relationship and apply conditions to its rows. A conditional display does not automatically change an aggregate over the unfiltered relationship.

#### Keep table HTML valid

Do not place naked loop/IF text directly between `<table>`, `<tbody>`, and `<tr>`. Browsers can move that text outside the table before Portwood processes it. Keep row-loop markers in cells, and place group markers outside complete tables. After switching between visual editing and HTML, inspect the saved markup and preview again.

#### Respect scope

Within a Contact loop, `{Name}` means the Contact's Name. To print the root Account's Name, use a uniquely named root block such as `{~AccountHeading}{Name}{/AccountHeading}`. Root-scope blocks are unsupported inside giant-query loops; use a prepared layout/data structure for that case.

Test zero, one, and several groups, blank category values, and long labels. Compare group totals with a trusted Salesforce report before sharing the document.

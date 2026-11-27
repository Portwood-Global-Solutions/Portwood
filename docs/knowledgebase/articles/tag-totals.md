Summarize the records that are actually available to the template. Filtering a query changes the input to the total.

**Before you start:** Choose the fields and relationships in [Choose information](#choose-data). For an orientation and the format checklist, open [Find the right merge tag](#merge-tags).

#### Aggregates

Grand totals across a child relationship. Works in sync and giant-query paths.

```
{COUNT:OpportunityLineItems}                          1000
{COUNT:OpportunityLineItems:number}                   1,000
{SUM:OpportunityLineItems.TotalPrice}                 50000
{SUM:OpportunityLineItems.TotalPrice:currency}        $50,000.00
{SUM:Lines.Amount:currency:EUR:de_DE}                 50.000,00 €
{AVG:OrderItems.UnitPrice:currency}                   $127.50
{MIN:Quotes.Amount:currency}                          $100.00
{MAX:Deals.Amount:currency:GBP}                       £999,999.00
{SUM:Lines.Amount:currency:auto=CustomerCurrency__c}  uses the parent record's currency
```

All five functions support any format suffix (`currency`, `number`, `percent`, custom patterns), including `currency:auto` (see [Auto-detecting the currency from the record](#auto-detecting-the-currency-from-the-record)).

In standard and bulk generation, a footer can summarize the rows of a nested loop. For an Account template with Opportunities and Opportunity Line Items, put the service-date filter in the line-item query. Place the following tags after both closing loops to summarize all matching line items on that account.

| Tag | Result |
| --- | --- |
| `{SUM:Opportunities.OpportunityLineItems.TotalPrice:currency}` | Total price of the matching lines |
| `{AVG:Opportunities.OpportunityLineItems.TotalPrice:currency}` | Average price per matching line with a numeric price |
| `{MIN:Opportunities.OpportunityLineItems.TotalPrice}` | Lowest numeric line price |
| `{MAX:Opportunities.OpportunityLineItems.TotalPrice}` | Highest numeric line price |
| `{COUNT:Opportunities.OpportunityLineItems}` | Number of matching lines, including lines with blank prices |
| `{COUNT:Opportunities.OpportunityLineItems.TotalPrice}` | Number of matching lines with a numeric price |

The separate Giant Query batch calculates aggregates on direct fields of its streamed relationship.

**Aggregate fields don't need to be rendered columns** — you can aggregate `UnitPrice` even if your loop table only shows `Product2.Name` and `Quantity`. The resolver validates field names against the child object's schema.

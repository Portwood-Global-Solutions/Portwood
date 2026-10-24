Keep dates, amounts, labels, and numbers easy to read.

#### Start with a field tag

`{Amount}` prints the field's value. A format after a colon changes how that value looks:

| What you want                     | Tag                        |
| --------------------------------- | -------------------------- |
| A readable date                   | `{CloseDate:MMMM d, yyyy}` |
| A short date                      | `{CloseDate:MM/dd/yyyy}`   |
| A date in the user's locale       | `{CloseDate:date}`         |
| A US dollar amount                | `{Amount:currency}`        |
| Euros                             | `{Amount:currency:EUR}`    |
| Number with separators            | `{Quantity:number}`        |
| Two decimal places                | `{Quantity:#,##0.00}`      |
| Picklist label seen in Salesforce | `{StageName:label}`        |
| Checkbox as `[X]` or `[ ]`        | `{IsClosed:checkbox}`      |
| Today's date                      | `{Today:MMMM d, yyyy}`     |
| Name of the person generating     | `{RunningUser.Name}`       |

These examples assume the fields exist on the relevant record or loop row. Add ordinary fields to the template's selected data. `Today`, `Now`, and the allowed `RunningUser` fields are built in.

#### Match the reader's country

Add an explicit locale when the document must use a particular convention:

```text
{CloseDate:date:en_GB}
{Amount:currency:EUR:de_DE}
```

Use `MM` for the month in a date pattern; lowercase `mm` means minutes. `yyyy` is the calendar year.

#### Work with more than one currency

In a multi-currency org, `{Amount:currency:auto}` follows the record's currency. A fixed `:EUR` chooses euro formatting; it does not by itself convert an amount.

When you need conversion, use the supported `:convert` suffix and verify your org's currency rates. For example:

```text
{Amount:currency:EUR:convert}
```

Totals across mixed currencies need particular care. Portwood rejects conflicting currencies unless conversion is requested. Conversion uses current static Salesforce currency rates, not dated Advanced Currency Management rates.

See the [merge tag reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/merge-tags.md) for all supported patterns, currencies, locales, and conversion rules.

Make a list that grows automatically: Contacts on an Account, products on an Opportunity, or rows from another related list.

**Before you start:** Add the related list and its fields in [Choose the information in a document](#choose-data).

#### In Canvas

1. Choose the **Table** tool and place a table on the page.
2. In its properties, choose the related list you want to repeat.
3. Set the columns and headings.
4. Give the table a name, such as **Contacts**.
5. Select a sample record that has several related records.
6. Turn on **Show sample data** to check the table, then generate a real **Preview**.

If text or totals should sit below the table, set that block to **Follows** this table. Leaving it at a fixed position can let the growing table run into it.

#### In Word

Create a table with a heading row and one example data row. Put the opening tag in the data row's first cell and the closing tag in its last cell:

| Name                                | Title     | Email                |
| ----------------------------------- | --------- | -------------------- |
| `{#Contacts}{FirstName} {LastName}` | `{Title}` | `{Email}{/Contacts}` |

Keep both loop tags in the **same row**. Portwood copies that row once per Contact. The column headings stay outside the loop.

Inside the loop, `{FirstName}` means the current Contact's first name. Outside it, a tag refers to the base record.

#### In HTML

Use a real table heading and one repeating body row:

```html
<table style="width:100%;border-collapse:collapse">
    <thead>
        <tr>
            <th>Name</th>
            <th>Email</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td>{#Contacts}{FirstName} {LastName}</td>
            <td>{Email}{/Contacts}</td>
        </tr>
    </tbody>
</table>
```

#### Add numbers or a total

Inside the repeating row, `{RowNumber}` prints 1, 2, 3, and so on.

Outside the loop, `{COUNT:Contacts}` prints the number of Contacts. A numeric example is `{SUM:OpportunityLineItems.TotalPrice:currency}` for a selected line-item relationship.

#### Check three cases

Preview a record with **no rows**, **a few rows**, and **enough rows for another page**. Empty loops print nothing. Use an inverse section if you want a message instead:

```text
{^Contacts}No contacts are listed yet.{/Contacts}
```

Set sorting on the related list if the row order matters. Do not rely on the order you happen to see in an early preview.

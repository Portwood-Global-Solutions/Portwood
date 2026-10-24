Help people find the right template and keep unfinished ones out of their way.

#### Use clear names and categories

In a template's settings, set **Category** to a useful group such as **Quotes**, **Customer letters**, or **Certificates**.

Set **Default** for the template most people should choose on that object. Use **Sort Order** to arrange templates; lower numbers appear earlier.

Give variants names that explain the result, such as **Quote - PDF** and **Quote - Editable Word**.

#### Hide a work in progress

Turn **Active** off. The template stays editable in My Templates but disappears from generation pickers. Turn it back on after checking the finished output.

#### Offer a template only when it applies

In **Visibility & Sort**, use:

| Setting                      | Example                                                       |
| ---------------------------- | ------------------------------------------------------------- |
| **Required Permission Sets** | Offer a template to people with the sales-team permission set |
| **Specific Record Ids**      | Offer it only on selected test records                        |
| **Record Filter**            | Offer it only when `StageName = 'Closed Won'`                 |

List permission-set API names exactly. When several permission sets are listed, having at least one matches that setting. When you combine different visibility settings, they must all match.

#### Understand visibility and data access

The packaged **Portwood User** permission set gives read access to all template records. The visibility settings control the template choices users are offered; they do not hide the existence of those template records from someone with View All.

Merged record and field access still matters. If template definitions themselves must be private, ask your administrator to design a custom permission set and sharing approach without the packaged template View All grant.

**You are done when:** A test user sees the intended choices on the intended record, and does not see unfinished or inapplicable ones in the picker.

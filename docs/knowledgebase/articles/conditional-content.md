Show a paragraph only when it applies, such as a discount note, an approval message, or a section that has related records.

#### In Canvas

Select a block and enter its condition under **Show only when**. For example, an Opportunity block can use:

```text
Amount > 10000
```

The whole block disappears when the condition is false. Preview one record that matches and one that does not.

Use a **variant group** for alternative blocks that should use the same flow position. Give the alternatives the same group name and conditions that do not overlap.

#### In Word or HTML

Put a conditional section around the words:

```text
{#IF Amount > 10000}
This proposal requires manager approval.
{/IF}
```

Use an alternative with `{:else}`:

```text
{#IF StageName = 'Closed Won'}
Thank you for your business.
{:else}
We look forward to working with you.
{/IF}
```

Use the field's exact API name. For an Opportunity stage, that is **StageName**. Text comparisons are case-sensitive; copy the stored value exactly.

#### Show a section only when rows exist

```text
{#IF Contacts.totalSize != 0}
Your contacts
{#Contacts}{FirstName} {LastName}
{/Contacts}
{/IF}
```

Include Contacts in the selected data. `.totalSize` lets you check whether the list is empty.

#### Combine conditions

Use `AND`, `OR`, `NOT`, and parentheses when needed:

```text
{#IF Amount > 10000 AND IsClosed = false}
Manager review is needed before this deal closes.
{/IF}
```

**You are done when:** A matching record shows the section, a nonmatching record hides it, and the surrounding page still looks right.

Every opening section needs the correct closing tag. Copy a working pair before editing a more complicated condition.

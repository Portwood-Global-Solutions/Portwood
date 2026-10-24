Give generated files useful names so people can find them later.

#### Set the default name

Open the template's settings and fill in **Document Title Format**. For an Account template, try:

```text
Account Brief - {Name} - {Today:yyyy-MM-dd}
```

For an Opportunity template, try:

```text
Quote - {Account.Name} - {Name}
```

Generate a sample and check the resulting filename. Set a title format when the name matters. The core merge service falls back to the source data’s `Name` when no format resolves; surrounding UI/signing paths can apply their own defaults. A blank format is not a promise of one identical filename across every entry point.

#### What you can include

- Fields from the record, such as `{Name}`.
- Parent fields, such as `{Account.Name}`.
- The date, such as `{Today:yyyy-MM-dd}`.
- Allowed running-user fields, such as `{RunningUser.Name}`.

Title fields are resolved separately, so they do not need to be selected only to support the filename. Body fields still need to be included in the template's data selection.

#### Why a particular file has a different title

A title explicitly passed by a Flow action or button configuration takes precedence over the template's default. Check those settings if changing the template does not change an automation's filename.

Saved versions can also retain their rendering settings. Save and test the intended active version after changing a title format.

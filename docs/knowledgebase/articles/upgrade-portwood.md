Keep templates and workflows working when you install a new release.

**Before you start:** Read the [changelog](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/CHANGELOG.md), note your installed version in **Setup → Installed Packages**, and test in a sandbox.

#### Before upgrading

1. Export important templates and keep their authoring files.
2. Record the template API Names used by buttons and Flows.
3. Choose a small set of representative documents: simple, long, image-heavy, bulk, and signed.
4. Check that Portwood permission sets are assigned only to supported users.
5. Install the new release in the test environment and run those examples.

#### Check picklists in an older installation

Salesforce may not add newer managed-package picklist values during an upgrade.

If a type is missing, open **Setup → Object Manager → Portwood Template → Fields & Relationships → Type**. Confirm these values exist and are active:

```text
Word
PowerPoint
Excel
HTML
PDF
Canvas
```

Add a missing value with its exact spelling and check record-type availability. Repeat on **Portwood Template Version**. Both objects matter. Fresh installs receive the current values; upgraded older orgs can need this repair.

If your automation uses **Signing Order = Single**, also confirm **Single** exists on Portwood Signature Request's Signing Order picklist.

If scripts create versions without setting Type, check whether **Word** is still an old picklist default on Portwood Template Version. Set Type explicitly in automation; remove a stale default deliberately if needed.

#### After upgrading

- Generate and inspect the representative documents.
- Open and save a test copy in each designer you use.
- Check button and Flow entry points as their intended users.
- Run a small bulk job and inspect its files.
- Test public signing and email delivery with a controlled recipient.
- Confirm custom fonts, shared images, and brand behavior.

Do not change the active production template just to test a new design. Use a clone and switch it on after review.

#### Update this knowledgebase

Documentation maintainers should follow the [release maintenance workflow](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/MAINTAINING.md). The guide is built from task articles so a release can update only the affected lessons and screenshots.

Start with [Find the right merge tag](#merge-tags), [Apex generation](#apex-generation), [custom providers](#apex-data-provider), or [all global declarations](#apex-surface). For layout recipes, use [repeating table headers](#repeat-table-headers) and [rich page footers](#running-headers-footers). These articles are searchable here in the guide.

Use these references when your task needs precise syntax or custom code. The beginner lessons remain the best place to learn the normal workflows.

| Reference                                                                                                                             | What you will find                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| [Merge tag reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/merge-tags.md)                   | Field formats, nested loops, grouping, conditions, totals, charts, images, barcodes, signatures, running-user fields, and Classic Approvals |
| [Query and data-provider reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/query-config.md)   | Legacy query formats, V3 trees, parent/child paths, V4 providers, JSON data                                                                 |
| [HTML and Word layout reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/template-layout.md)   | PDF styling support, HTML authoring prompt, headers/footers, Word widths and AutoFit                                                        |
| [Apex and Flow API reference](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/apex-api.md)             | Service methods, invocable signatures, namespace usage                                                                                      |
| [Advanced automation and compatibility](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/reference/automation.md) | Legacy signing actions, signer-input writeback, JSON examples, asynchronous job polling, error handling                                     |
| [Documentation maintenance](https://github.com/Portwood-Global-Solutions/Portwood/blob/main/docs/knowledgebase/MAINTAINING.md)        | Article sources, generated outputs, release review, screenshots, validation                                                                 |

#### Use the managed-package namespace

In Apex outside the package, exported class references use the `portwoodglobal` namespace. Salesforce object and field API names use `portwoodglobal__`.

Prefer a template's stable API Name where an action supports it. Record IDs are specific to an org. Some actions still require a Template ID; check that action's inputs rather than assuming all actions accept the same key.

#### Treat output paths separately

Interactive generation has a browser available. Flow, batch, and Apex generation run on the server and have different memory and rendering constraints. Test the entry point your users or automation will actually use.

The guide's reviews identify their source dependencies for maintainers. When source and a historical example disagree, check the current method contract and verify the behavior in a subscriber test org before shipping an integration.

For exact query JSON, use [Query configuration formats](#query-config). For jobs, use [asynchronous completion](#async-jobs). For signer-supplied values, use [Signer Inputs](#signer-inputs) and the [email-token directory](#email-tokens).

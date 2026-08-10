---
name: fix-merge-tag
description: Fix a Portwood merge-tag or parser bug correctly across all of its resolution paths. Use when changing tag parsing, section/loop tags, conditionals, aggregates, or chart buckets — a fix in one path silently does not reach the others.
---

# Fixing a merge-tag bug

**The trap:** there is more than one place that resolves tags, and they do not share
code. A fix landed in one path leaves the others broken, and the failure is silent —
the tag just prints raw or evaluates wrong for templates that happen to take a
different route.

Before writing a fix, work out which path(s) the reported template takes.

## The three merge-tag resolution paths

`DocGenGiantQueryAssembler` does **not** call `processXml()`. So:

| Path                               | Resolved by                                             | Reached when                             |
| ---------------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| Row-level loop bodies              | `DocGenService.processXml()`                            | normal templates                         |
| Parent-level tags outside the loop | `DocGenGiantQueryAssembler.resolveParentMergeTags()`    | giant-query templates (>2000 child rows) |
| Grand-total aggregates             | `DocGenGiantQueryAssembler.resolveGiantAggregateTags()` | giant-query templates                    |

A section-tag fix in `processXml` covers **only** row-level loop bodies. If the change
needs to behave consistently for giant-query templates, mirror it in the assembler or
route it through `processXmlForTest` the same way format-suffix tags already do.

**Always** check whether your fix needs the same change in the giant-query parent path,
and add an `e2e-07` assertion either way — including one that proves it doesn't need it.

## The four `{#ChartBucket}` resolution paths

`{#ChartBucket:relationship:field[:mod=val&...]}body{/ChartBucket}` has its own set,
and all four must stay consistent:

1. **In-memory** — `DocGenChartBucketResolver.preprocessInline` against pre-loaded
   relationship records. Used when child count <2000 **and** no `where=`/`groupBy=`.
   SOQL-free, fastest.
2. **SOQL fallback** — `tryFallbackSoqlAggregateAdvanced`, when the relationship isn't
   on the data map or `where=`/`groupBy=` force it. Schema-auto-discovers child object
   and FK via `ChildRelationship`, issues a `GROUP BY` aggregate at constant cost.
   **This is how 30K-scale templates work.**
3. **Parent-level** — `resolveParentMergeTags()`'s regex skips `{#…}` prefixes so charts
   pass through, then `processXmlForTest` routes to the inline path.
4. **Giant-query parent** — `resolveGiantChartBuckets` for charts targeting the giant
   relationship. Same modifiers, same shape.

**SOQL budget:** 50 chart aggregates per transaction
(`DocGenChartBucketResolver.chartSoqlBudget`). When exhausted, charts render a sentinel
"Chart limit reached" bucket — never silently empty.

### The five modifiers

Composable, and all four paths must honour each:

| Modifier                        | Behavior                                                                |
| ------------------------------- | ----------------------------------------------------------------------- |
| `colors=#aaa,#bbb`              | Override the default 8-color palette, cycling by row index              |
| `where=Field='X' AND Y != null` | Sanitized SOQL fragment appended to the WHERE. Forces SOQL fallback.    |
| `split=;`                       | Multi-select delimiter; percentages summing >100% is expected           |
| `groupBy=Field__c`              | Cross-tab pivot; each row gets a `cols` sub-list. Forces SOQL fallback. |
| `colSort=v1,v2`                 | Column ordering for `groupBy=`; named first, rest alpha, Total last     |

## Query Config formats

V1 (flat string) and V3 (node tree) reproduce similar patterns in different code —
V3's `processChildNodes` and V1's `stitchGrandchildren`. **A fix often needs to land in
both.**

## Constraints you must not regress

### Zero-heap PDF image rendering

For PDF output, `{%ImageField}` tags with ContentVersion IDs skip blob loading.
`currentOutputFormat` is set to `'PDF'` before `processXml()` calls; in
`buildImageXml()`, when the format is `'PDF'` and the value is a `068` ID, query **only**
`Id, FileExtension` — never `VersionData` — and store the relative URL
`/sfc/servlet.shepherd/version/download/<cvId>`.

If your fix touches `processXml`:

- **Do not** add `VersionData` to the PDF-path SOQL.
- **Do not** prepend `URL.getOrgDomainUrl()` anywhere in the image pipeline.

Image URLs for `Blob.toPdf` **must be relative**. Absolute URLs and `data:` URIs render
broken.

### Exception ordering

`processXml`'s try/catch must rethrow `HeapPressureException` ahead of the generic
catch. Order: `HeapPressureException` → `DocGen*` → generic.

## Verifying the fix

1. Add a regression assertion in `e2e-07-syntax5` (or a new `syntax6`) exercising the
   pattern via `processXmlForTest`. `syntax1`–`syntax4` are near the 18,000-char ceiling.
2. Add an `e2e-07` assertion for the giant-query parent path — even if the answer is
   "unchanged", the assertion is what stops the next person breaking it.
3. `npm run qa -- --suite merge-tags`
4. Scoped Apex tests, then `npm run format:check`.

See the `run-tests` skill for the constraints on writing e2e assertions.

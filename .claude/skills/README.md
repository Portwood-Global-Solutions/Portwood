# Portwood skills

Project knowledge packaged as [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills).
If you use Claude Code in this repo they load automatically when relevant; if you don't,
read them as plain Markdown — each one is a self-contained guide.

They exist because most of what makes Portwood hard to change is not visible in the
code: the renderer silently ignores half of CSS, tags resolve through four different
paths that don't share code, and a whole class of bug only appears in a real
managed-package install. These write that down.

| Skill                                                         | Read it when                                                                      |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [`dev-setup`](dev-setup/SKILL.md)                             | Going from a fresh clone to a working, tested org                                 |
| [`run-tests`](run-tests/SKILL.md)                             | Verifying a change — QA harness, e2e scripts, prettier, Code Analyzer             |
| [`triage-report`](triage-report/SKILL.md)                     | A bug report arrives and you need to know if it's a real defect                   |
| [`fix-merge-tag`](fix-merge-tag/SKILL.md)                     | Changing tag parsing, loops, conditionals, aggregates or charts                   |
| [`html-template-authoring`](html-template-authoring/SKILL.md) | Writing a template, or a PDF doesn't match its source                             |
| [`canvas-designer`](canvas-designer/SKILL.md)                 | Touching the Canvas artboard, serializer or importer                              |
| [`managed-package-rules`](managed-package-rules/SKILL.md)     | Adding subscriber-visible Apex, a Flow action, or debugging install-only failures |

## Start here

New contributor: **`dev-setup`** → **`run-tests`**. That's clone to green tests.

Picking up an issue: **`triage-report`** first — it tells you whether the report is a
code defect at all. Then the skill for the area you're changing.

## The two highest-value facts

If you read nothing else:

1. **Most "the PDF looks wrong" reports are template issues, not bugs.** The renderer is
   CSS 2.1 and silently ignores `flex`, `grid`, `gap`, `calc()` and CSS variables. Check
   the template before you check the code.
2. **A merge-tag fix in one resolution path does not reach the other three.** Find out
   which path the failing template takes before you write anything.

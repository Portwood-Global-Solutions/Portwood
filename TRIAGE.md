# Triage rubric

How we prioritize issues and enhancement requests on this repo. Reporters are welcome to suggest a priority in their issue body, but maintainers make the call when applying labels.

## Priority

| Label         | Use when…                                                                                                                           | Examples                                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `priority:P0` | Output is silently wrong, data loss, or the package is unusable for an entire customer segment. Ship in the next dot release.       | #69 (`{#IF Field = "literal"}` silently false), #68 (`{:else}` misappropriated across nested IFs)                              |
| `priority:P1` | Visible regression or significant bug, but a workaround exists OR impact is scoped to one feature. Plan into the next 1–2 releases. | #67 (ProcessInstance grandchild stitcher), #71 (rich-text PDF image sizing), #60 (HTML/CSS rendering), #72 (guest DOCX images) |
| `priority:P2` | Planned enhancement on the roadmap. Specced and actionable.                                                                         | #31 (partials), #66 (Classic Approvals related list)                                                                           |
| `priority:P3` | Backlog. Idea has merit but needs more scoping, or impact is low. Revisit when capacity allows.                                     | #55 (drag-and-drop builder)                                                                                                    |

**The P0 test:** would a customer hit this and not know their output is wrong? If yes, it's P0 regardless of how rare. Silent corruption beats loud crashes.

## Severity (orthogonal to priority)

| Label                         | Meaning                                                                                                                                      |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `severity:silent-corruption`  | Output looks fine but is wrong. No error surfaced. Highest user impact because customers can't detect it. Frequently combined with P0 or P1. |
| `severity:visible-regression` | Quality issue is visible to the user (broken layout, missing image, malformed output). Customer can see it and report it.                    |

A bug should usually carry one severity label. Enhancements don't need a severity.

## Is it even a bug?

Before applying any of the above: **most reports are template-authoring problems, not code defects.** The renderer is CSS 2.1 and silently ignores `flex`, `grid`, `gap`, `calc()` and CSS variables; image URLs must be relative; and a chart style that doesn't survive the chosen output format fails silently (`pivot` never rasterizes for Word/PPTX; SVG-rendered styles are dropped from `Blob.toPdf`). Reproduce and rule the template out first.

A report that turns out to be an authoring problem gets answered as guidance and closed with `template-help`. It does not become engineering work. See `.claude/skills/triage-report/SKILL.md` for the full checklist.

## Milestones — release dates, not version numbers

Portwood releases **every two weeks, on a Friday**. Milestones are the release date, so a contributor can see when their PR would actually ship. Version numbers are assigned at release time, not in advance.

- **The next date** (currently `2026-09-11`) — what's shipping next. Bug-fix-only when possible. P0s land here unconditionally.
- **The date after** — P1 bugs and small enhancements.
- **Later dates** — larger features with completed specs.
- **Backlog** — P3 items, anything needing more scoping, parking lot.

When a release ships we close its date milestone and add the next Friday two weeks out. Closed version-numbered milestones (`v1.x`, `v3.4x`) are retained for historical record and are not used for new work.

## Other useful labels

- `good first issue` — well-specified, bounded, with a named fix approach. The best entry point for a new contributor; apply it whenever a bug qualifies.
- `help wanted` — we'd particularly welcome someone picking this up.
- `community-contribution` — reporter included a verified fix or substantial RCA. Fast wins; surface them in triage.
- `bug`, `enhancement` — the type. Set automatically by issue templates.
- `pdf`, `docx`, `designer`, `flow-action`, `bulk-generation`, `install-upgrade`, `template-help` — subsystem tags for filtering.

## Filter recipes

```
is:open label:priority:P0                  # fire-now list
is:open milestone:2026-09-11               # what's shipping next
is:open label:severity:silent-corruption   # quality-of-fix watchlist
is:open label:"good first issue"           # newcomer entry points
is:open label:community-contribution       # reporter-fix-attached
is:open no:milestone                       # untriaged
```

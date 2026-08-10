---
name: managed-package-rules
description: Constraints that only bite in a real managed-package install of Portwood — global visibility, Flow Apex-Defined types, namespace-prefixed keys, USER_MODE on internal reads, immutable API names. Use when adding Apex a subscriber must see, building a Flow action, or debugging something that works in a scratch org but fails in a package install.
---

# Managed-package constraints

Portwood ships as **Managed 2GP**, namespace `portwoodglobal`. A large class of bugs
exists only in a real subscriber install and **cannot be reproduced in a no-namespace
scratch org**. If something works in dev and fails in an install, start here.

## Only `global` Apex is visible to subscribers

`public` classes and methods are **invisible** in a subscriber org.

- An `@InvocableMethod` must be `global` to appear in a subscriber's Flow Builder.
- Helper classes a subscriber is meant to call must be `global`, along with their inner
  types, fields and methods.

## Flow Apex-Defined variable types — all four are required

For a type to be selectable as a Flow Apex-Defined variable in a subscriber org:

1. **Top-level / standalone class.** Flow ignores inner and nested classes entirely.
2. **`global`** class.
3. **`@AuraEnabled`** members.
4. **`global` no-arg constructor.**

Missing any one produces the same symptom: the action appears, but its variable type
can't be selected. This cost three separate releases to get right, each time because
only one of the four was missing. **Verify in a real subscriber install or a namespaced
scratch org** — a no-namespace staging org cannot show you the failure.

## API names are frozen forever

Everything shipped is immutable: `DocGen_Template__c`, `DocGenService`, `DocGen_Admin`,
the `portwoodglobal` namespace, the `Canvas` picklist value. Display names (labels,
descriptions, user-visible strings) can change; API names cannot.

Two scheduled job names deliberately keep their old strings because they're matched by
`CronJobDetail.Name` in orgs that already scheduled them: `DocGen Signature Reminders`
and `DocGen Chart CV Reaper`.

2GP also cannot drop Apex classes without the "Remove Metadata Components" DevHub
feature — the workaround is inert stubs.

## Namespace-prefixed keys break JS

In a subscriber org, SObject field keys come back **namespace-prefixed**:

- `row.Field__c` is `undefined` in a shipped package — it's `row.portwoodglobal__Field__c`.
  Use `@salesforce/schema` imports or a normalizing mapper in LWC.
- `getPopulatedFieldsAsMap()` keys are prefixed too. Prefer direct field access.

Neither reproduces in a no-namespace org. A namespaced build is the real gate.

## `WITH USER_MODE` on internal reads

Portwood's internal ContentVersions (`docgen_tmpl_html_*`, `docgen_tmpl_xml_*`) have
`ContentDocumentLink.Visibility = InternalUsers`, which is **invisible under
`USER_MODE`** — the read silently returns empty and the caller falls back to something
degraded. Use the FLS-guard + `WITH SYSTEM_MODE` hybrid for these.

The same applies to a **newly packaged field**: the build's test user has no permission
set, so `WITH USER_MODE` fails the package build with "No such column" on a field that
plainly exists. Use `SYSTEM_MODE` plus an FLS guard for internal config reads.

## Guest-context rules

- Guest profiles need the **guest** FLS-guard variants, not the admin ones — the
  per-field verdict throws for guests even when the permission set grants access.
- `@AuraEnabled(cacheable=true)` serves stale empty results to guests. Never cache
  context-sensitive Apex.
- Every guest-reachable `SYSTEM_MODE` query must be **token-keyed**, never keyed by a
  guessable Id — that shape has already produced one IDOR.
- A guest LWC silently fails to render if the guest can't see the `recordId`. Check
  sharing before debugging the component.

## No external callouts

Portwood is 100% native — no external services, APIs, or callouts, and document data
never leaves the org. Client-side libraries are **vendored as pinned static resources**,
not pulled from npm at build time. If you add or update one: keep it patched, retain its
license/NOTICE, and disclose it.

Extension points exist precisely so the non-native hop can live outside the package —
see `DocGenAiProvider` and `DocGenDataProvider`, both resolved by `Type.forName` with a
namespace fallback.

## Testing the things a scratch org can't show you

A namespaced pre-flight org catches build traps in minutes rather than after a 20–40
minute package build: deploy plus `RunLocalTests`, **without** assigning the permission
set, so you see exactly what the build's test user sees.

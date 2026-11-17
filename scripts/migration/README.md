# Portwood configuration migration CLI

This first phase inventories a source org and builds a read-only comparison against a target org. It supports a source deployment or an installed Portwood managed package. It requires Node.js and the Salesforce CLI, with the two orgs authenticated separately. The CLI uses the running user's field permissions and sharing.

```sh
umask 077
node scripts/migration/portwood.mjs inventory --org source-sandbox > source-inventory.json
node scripts/migration/portwood.mjs plan --source source-inventory.json --target destination-sandbox > migration-plan.json
```

The inventory covers templates, shared assets, snippets, fonts, brands, email templates, and selected org settings. Snippets are inventoried under their shared asset keys and identified separately in the plan. Keep the JSON private. It includes configuration names, Salesforce IDs, and organization-specific settings.

The dry run reports candidate creations, conflicting or ambiguous keys, missing keys, unsupported objects, dependency gaps, and manual mappings. It compares templates and fonts by API name, assets and snippets by asset key, brands by name, and email templates by type and brand. A match means the identity collides and needs review. The planner has not verified that those records have the same contents.

## Implementation plan

1. Inventory and dry run (this phase). Identify configuration surfaces and fail on incomplete query results. Surface conflicting identities, unavailable metadata, and source IDs that need new Salesforce mappings.
2. Add a supported transfer service with the same Portwood permissions as the UI. Existing template bundle export/import methods are Aura actions inside the package. Reuse their exact active template versions, protected File handling, and ID remapping through a supported callable interface. Include file checksums and explicit inclusion of linked configuration dependencies.
3. Import assets and snippets before fonts, then import brands and email templates before dependent templates. Use stable keys and record exact source-to-target mappings. Refuse ambiguous matches. Enable explicit reuse for matching checksums and require an explicit update policy for differences.
4. Apply organization-specific mappings for verified sender addresses, signing sites, record allowlists, sample records, permission sets, and provider classes. Validate target schema and references before applying changes. Keep historical signatures, audit rows, and output documents outside configuration migration.
5. Verify round trips in installed-package orgs. Check branded sends, snippet and asset binding, font selection, and generated document output. Rerun the import and check that it does not duplicate configuration.

This phase does not transfer document bodies or Salesforce Files, update target records, copy managed settings, or discover references embedded inside template bodies. Continue using the existing template bundle workflow for individual template transfers. See issue [#532](https://github.com/Portwood-Global-Solutions/Portwood/issues/532).

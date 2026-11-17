# Portwood configuration migration CLI

Install the draft plugin from this checkout with Node.js 20 or later and an authenticated Salesforce CLI.

```sh
npm ci --prefix scripts/migration
sf plugins link scripts/migration
sf portwood migrate --source-org source-sandbox --target-org destination-sandbox --dry-run
sf portwood migrate --source-org source-sandbox --target-org destination-sandbox --mappings mappings.json
```

Deploy the Portwood source with the migration API in both orgs. Give each CLI user the appropriate Portwood object and File access plus the **Portwood Configuration Migration** permission set. Font imports also require **Manage Portwood Fonts**. This draft applies writes only between sandbox and scratch orgs.

Dry run compares stable keys and lists conflicts, missing identities, and settings that need mapping. Apply preflights source resources before writing, then transfers shared image assets, fonts, snippets, brands, email templates, templates, and selected signing settings. It remaps brand relationships to the destination. Each resource is written in one Salesforce transaction. A failure stops further writes and reports what was already applied. Re-run against the same orgs after addressing the reported issue. The CLI compares the existing destination payload before reusing it. Conflicts stop by default. Use `--conflict skip` only when you intend to leave a differing destination resource in place.

Use `--only templates` or repeat the option to select particular resource types. When limiting the scope, create or map dependencies before transferring templates and email templates.

## Mappings

Supply a JSON file for settings and resources that refer to org-specific values. Use the resource key shown in the dry run, preserving its case. For example:

```json
{
    "templates": {
        "Account_Quote": {
            "testRecordId": null,
            "specificRecordIds": "001000000000001AAA",
            "requiredPermissionSets": "Portwood_Quote_User",
            "recordFilter": "Type = 'Customer'"
        }
    },
    "brands": {
        "Retail": {
            "owaId": "0D2000000000001CAA",
            "logoUrl": null
        }
    },
    "fonts": {
        "quote-sans-regular": {
            "hostingRightsConfirmed": true
        }
    },
    "settings": {
        "replace": true,
        "signingSiteUrl": "https://example.my.salesforce-sites.com",
        "owaId": "0D2000000000001CAA",
        "logoUrl": null
    }
}
```

Values shown are examples. Use destination Salesforce IDs and URLs. A template can supply an explicit `brandId` if its source brand is outside the migration scope. A branded email template can also specify `brandId` under `emailTemplates`. Template record and audience restrictions require explicit mappings when they were configured at the source.

New fonts retain their exact source bytes and license identity, but enter the target registry as **Staged**. An approved source face needs its target specimen reviewed and approved through Portwood Assets. The migration reports that approval and defers new templates until it has been completed. Rerun after approval. A new source-configured AI provider or prompt is outside the signing-settings transfer. Set `settings.leaveAiUnchanged` to acknowledge that the target AI configuration stays in place.

## Current bounds

- The service transfers active/published files and configuration. Version history, generated documents, historical signature requests and audit evidence stay in the source org.
- Template bundles are limited to a 1.5 MB JSON request. Shared images and individual font files are limited to 950 KB; large files need a separate streaming transport.
- Templates reuse the package's existing bundle reader and writer. Embedded asset and font dependencies in Office files still need review, especially when using `--only templates`. Reuse comparisons for template bundles with inline Salesforce File references remain conservative and report a conflict.
- Settings transfer covers signing defaults and branding, not Salesforce site provisioning, sender verification, permission-set deployment, provider code, or per-user settings. Apply settings only in an org you intend to reconfigure.
- Managed-package installation and namespace handling require subscriber validation before release.

For manifest files or inventory-only verification, the standalone tools run without the plugin:

```sh
umask 077
node scripts/migration/portwood.mjs inventory --org source-sandbox > source-inventory.json
node scripts/migration/portwood.mjs plan --source source-inventory.json --target destination-sandbox > migration-plan.json
```

Keep the inventory and mapping files private. They contain Salesforce IDs and org-specific settings. See [#532](https://github.com/Portwood-Global-Solutions/Portwood/issues/532).

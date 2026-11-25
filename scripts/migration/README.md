# Portwood configuration migration CLI

Install the draft Salesforce CLI plugin from this checkout using Node.js 20 or later. Run these commands from the repository root, using two authenticated disposable scratch orgs as `source-scratch` and `destination-scratch`. Deploy the same migration API revision in both.

```sh
sf project deploy start --source-dir force-app --target-org source-scratch --wait 10
sf project deploy start --source-dir force-app --target-org destination-scratch --wait 10
sf org assign permset --name DocGen_Admin --name DocGen_Migration --target-org source-scratch
sf org assign permset --name DocGen_Admin --name DocGen_Migration --target-org destination-scratch
npm ci --prefix scripts/migration
sf plugins link scripts/migration
sf portwood migrate --source-org source-scratch --target-org destination-scratch --dry-run
sf portwood migrate --source-org source-scratch --target-org destination-scratch --mappings mappings.json
```

For users with custom permissions, assign **Portwood Configuration Migration** alongside the required configuration and File access. Font imports also require **Manage Portwood Fonts**, which is included in `DocGen_Admin`. This draft command applies writes only between sandbox and scratch orgs. The check is in the command; the Apex REST API itself accepts writes in any org from a user with the `Migrate_DocGen_Configuration` custom permission, within that user's own access. Note that installing the package also grants that custom permission to profiles (System Administrator for an admins-only install, most profiles for an all-users install).

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
- Native template bodies (DOCX, XLSX, XLSM, PPTX, PDF) and shared images transfer from Salesforce Files up to 10,000,000 bytes per file. Static TTF font sources transfer up to 9,000,000 bytes per file and use Portwood's asynchronous inspection. The transfer verifies the byte count and Salesforce checksum before attaching the destination File.
- Files download into a private temporary directory, then upload using Salesforce's binary Files endpoint. The CLI removes temporary local copies and attempts to discard private destination staging Files if a write fails. If cleanup fails or a font job is still running, the report includes the staging File ID or job ID. Retain that report and check the job before retrying.
- HTML and Canvas bodies, bundled inline Salesforce Files, and template metadata still use the existing bundle path, with a 1.5 MB JSON request cap. Embedded asset and font dependencies in Office files need review, especially with `--only templates`. Reuse comparisons for template bundles with inline Salesforce File references remain conservative and report a conflict.
- Settings transfer covers signing defaults and branding, not Salesforce site provisioning, sender verification, permission-set deployment, provider code, or per-user settings. Apply settings only in an org you intend to reconfigure.
- Managed-package installation and namespace handling require subscriber validation before release.

For manifest files or inventory-only verification, the standalone tools run without the plugin:

```sh
umask 077
node scripts/migration/portwood.mjs inventory --org source-sandbox > source-inventory.json
node scripts/migration/portwood.mjs plan --source source-inventory.json --target destination-sandbox > migration-plan.json
```

Keep the inventory and mapping files private. They contain Salesforce IDs and org-specific settings. See [#532](https://github.com/Portwood-Global-Solutions/Portwood/issues/532).

## Measured scratch-org transfer

The native transfer was tested between independent scratch orgs with these fixtures. Direct File downloads from both orgs matched in byte count and SHA-256 for each fixture.

| File                 | Exact source bytes | Destination check                              |
| -------------------- | -----------------: | ---------------------------------------------- |
| Shared PNG           |          2,434,357 | Attached to the migrated image asset           |
| Native Word template |          2,472,100 | Active template produced a 2,489,527-byte DOCX |
| Licensed static TTF  |          2,054,744 | Staged under the original font revision key    |

The configured maximums above are caps rather than measured end-to-end capacity guarantees. Salesforce file permissions, host settings, and parsing limits still govern what an org can import.

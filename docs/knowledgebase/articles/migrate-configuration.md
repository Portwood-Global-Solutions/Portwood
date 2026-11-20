Copy your Portwood setup — templates, brands, fonts, snippets, shared images, email templates, and signing settings — from one org to another with a single command. Use it to rebuild a sandbox or scratch org, or to keep two non-production orgs in step. To move one template by hand instead, see [Move a template between orgs](#move-templates).

This is a draft tool. It writes only between sandboxes and scratch orgs; it refuses a production org.

#### Before you start

You need:

- **Node.js 20 or later** and the **Salesforce CLI** (`sf`) on your computer. Windows PowerShell, Command Prompt, Git Bash, macOS, and Linux are supported.
- A checkout of the Portwood repository. The command lives in `scripts/migration`.
- The same Portwood version in both orgs.
- Both orgs logged in to the CLI under an alias, for example `source-org` and `target-org`.
- **Portwood Admin** and **Portwood Configuration Migration** assigned to your user in both orgs. Font imports also need **Manage Portwood Fonts**, which Portwood Admin includes.

```sh
sf org assign permset --name DocGen_Admin --name DocGen_Migration --target-org source-org
sf org assign permset --name DocGen_Admin --name DocGen_Migration --target-org target-org
```

#### Install the command

Run these once, from the repository root (the folder that contains `sfdx-project.json`):

```sh
npm ci --prefix scripts/migration
sf plugins link scripts/migration
```

Check it worked with `sf portwood migrate --help`. If `sf plugins link` reports **plugin is invalid**, you are in the wrong folder — move to the repository root and try again.

#### Preview the move with a dry run

```sh
sf portwood migrate --source-org source-org --target-org target-org --dry-run
```

A dry run reads both orgs and writes nothing. It prints a report with one line per item and a **status**:

| Status                        | What it means                                                                |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `create`                      | The item is new and will be copied.                                          |
| `conflict`                    | The destination already has an item with the same key but different content. |
| `missing-key`                 | The item has no API name or key, so it cannot be matched. Give it one first. |
| `ambiguous-key`               | More than one item shares the key. Rename one so each key is unique.         |
| `manual-mapping`              | A setting refers to something specific to the org. Map it before applying.   |
| `target-resource-unavailable` | The destination's Portwood version does not have this kind of item.          |

Each item also lists warnings, such as record IDs that need mapping.

#### Map values that belong to one org

Record IDs, sender addresses, and site URLs differ between orgs. Put the destination's values in a JSON file, keyed by the item's key from the dry run (keep its case):

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
        "Retail": { "owaId": "0D2000000000001CAA", "logoUrl": null }
    },
    "fonts": {
        "quote-sans-regular": { "hostingRightsConfirmed": true }
    },
    "settings": {
        "replace": true,
        "signingSiteUrl": "https://example.my.salesforce-sites.com",
        "owaId": "0D2000000000001CAA",
        "logoUrl": null
    }
}
```

The values above are examples. Use IDs and URLs from the destination org. Keep mapping files and reports private; they contain Salesforce IDs.

#### Apply the move

```sh
sf portwood migrate --source-org source-org --target-org target-org --mappings mappings.json
```

1. The command checks every source item before writing anything.
2. It copies shared images, fonts, snippets, brands, email templates, templates, and signing settings, in that order, and points each template at the matching destination brand.
3. Each item is written in its own transaction. If one fails, the command stops and reports what it already copied.
4. Fix the reported problem and run the same command again. Items that already match are reused, not duplicated.

Useful options:

- `--only templates` copies one kind of item. Repeat it for several kinds (`templates`, `snippets`, `assets`, `brands`, `emailTemplates`, `settings`, `fonts`). Copy or map what a template depends on first.
- `--conflict skip` leaves a differing destination item in place instead of stopping. The default, `stop`, halts at the first conflict.

#### Approve migrated fonts

New fonts arrive in the destination as **Staged**, with their original file and license details. Open **Portwood Assets** in the destination, review and approve each font, then run the command again. Templates that use a font wait until it is approved.

#### What is not copied

- Version history, generated documents, past signature requests, and audit evidence stay in the source org.
- Salesforce site setup, sender verification, permission-set assignments, custom provider code, and per-user settings.
- A new AI provider or prompt. Set `settings.leaveAiUnchanged` to keep the destination's AI setup.

Files over 10,000,000 bytes (fonts over 9,000,000 bytes) are not copied. HTML and Canvas templates travel in a bundle limited to about 1.5 MB.

#### If something goes wrong

- **Salesforce CLI request failed** — run `sf org list` and confirm both aliases are connected. The message now includes the underlying reason.
- **The command takes several minutes** — the dry run starts the Salesforce CLI once per object it reads, so allow a few minutes per org, especially on Windows.
- **It refuses to write** — one of the orgs is production. Use a sandbox or scratch org.
- **A font job is still running or a temporary file was left behind** — the report lists its job or File ID. Keep the report and check that item before running again.

**You are done when:** The dry run shows no unexpected conflicts, the apply finishes without errors, and a migrated template generates correctly from a record in the destination org.

#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
hub=${PORTWOOD_DEV_HUB:?Export PORTWOOD_DEV_HUB with an authenticated Salesforce Dev Hub alias.}
[[ $# -le 1 ]] || { echo 'Usage: provision.sh [scratch-alias]' >&2; exit 2; }
[[ -s "$run_dir/run-start.epoch" ]] || date +%s > "$run_dir/run-start.epoch"
python3 "$bench/prepare-account-template.py" "$run_dir/account-create-template.apex"

package_is_installed() {
    sf package installed list --target-org "$1" --json |
        jq -e --arg version "$package_id" '.status == 0 and any(.result[]; .SubscriberPackageVersionId == $version)' >/dev/null
}

provision_org() {
    local alias="$1" shard begin expected
    shard="$run_dir/$alias"
    mkdir -p "$shard"
    begin=$(date +%s)
    if [[ ! -s "$shard/org-create.json" ]]; then
        if ! sf org create scratch --target-dev-hub "$hub" --definition-file "$lab/scratch-def.json" \
            --alias "$alias" --duration-days 3 --wait 12 --json |
            jq -ce 'select(.status == 0 and (.result.orgId | startswith("00D"))) | {status, result: {orgId: .result.orgId}}' > "$shard/org-create.partial"; then
            rm -f "$shard/org-create.partial"
            printf 'Scratch creation failed for %s. Check Dev Hub quota and alias before retrying.\n' "$alias" >&2
            return 1
        fi
        mv "$shard/org-create.partial" "$shard/org-create.json"
        date +%s > "$shard/org-ready.epoch"
    fi
    expected=$(jq -er '.result.orgId' "$shard/org-create.json")
    sf org display --target-org "$alias" --json |
        jq -e --arg expected "$expected" '
        .status == 0 and
        ((.result.id // .result.orgId)[0:15] == $expected[0:15]) and
        (.result.instanceUrl | test("^https://[^/]+\\.scratch\\.my\\.salesforce\\.com/?$"))
    ' >/dev/null
    if [[ -s "$shard/setup-ready.epoch" ]]; then
        printf '%s setup already ready\n' "$alias"
        return
    fi
    if [[ ! -s "$shard/package-ready.epoch" ]]; then
        if ! package_is_installed "$alias"; then
            sf package install --target-org "$alias" --package "$package_id" --security-type AdminsOnly \
                --no-prompt --wait 16 --publish-wait 3 --json > "$shard/package-install.json" || true
            if ! package_is_installed "$alias"; then
                printf '%s package installation is not confirmed. See %s/package-install.json.\n' "$alias" "$shard" >&2
                return 1
            fi
        fi
        date +%s > "$shard/package-ready.epoch"
    fi
    if [[ ! -s "$shard/permissions-ready.epoch" ]]; then
        sf org assign permset --target-org "$alias" --name portwoodglobal__DocGen_Admin \
            --name portwoodglobal__DocGen_User --json | jq -e '.status == 0' >/dev/null
        date +%s > "$shard/permissions-ready.epoch"
    fi
    if [[ ! -s "$shard/deploy-ready.epoch" ]]; then
        sf project deploy start --target-org "$alias" --source-dir "$bench/bulk-source/main/default/classes" \
            --wait 8 --json | jq -e '.status == 0 and .result.success == true' >/dev/null
        date +%s > "$shard/deploy-ready.epoch"
    fi
    if [[ ! -s "$shard/template.id" ]]; then
        sf apex run --target-org "$alias" --file "$run_dir/account-create-template.apex" --json |
            jq -er 'select(.status == 0) | .result.logs | capture("USER_DEBUG[^\\n]*PW_ACCOUNT_TEMPLATE=(?<id>[A-Za-z0-9]+)").id' \
            > "$shard/template.partial"
        mv "$shard/template.partial" "$shard/template.id"
    fi
    date +%s > "$shard/setup-ready.epoch"
    printf '%s setup ready after %s s\n' "$alias" "$(( $(date +%s) - begin ))"
}

pids=()
for (( index=1; index<=org_count; index++ )); do
    alias=$(org_alias "$index")
    if [[ $# -eq 0 || "$1" == "$alias" ]]; then
        provision_org "$alias" &
        pids+=("$!")
    fi
done
[[ ${#pids[@]} -gt 0 ]] || { echo 'The alias is outside the configured scratch pool.' >&2; exit 2; }
wait_for_all "${pids[@]}"

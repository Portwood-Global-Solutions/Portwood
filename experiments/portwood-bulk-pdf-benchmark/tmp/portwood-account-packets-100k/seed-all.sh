#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
[[ -s "$run_dir/seed-start.epoch" ]] || date +%s > "$run_dir/seed-start.epoch"
pids=()
for (( index=1; index<=org_count; index++ )); do
    alias=$(org_alias "$index")
    shard="$run_dir/$alias"
    [[ -s "$shard/org-ready.epoch" ]] || { printf 'Provision %s first.\n' "$alias" >&2; exit 1; }
done
for (( index=1; index<=org_count; index++ )); do
    alias=$(org_alias "$index")
    shard="$run_dir/$alias"
    set_org_range "$index"
    (
        org=$(jq -er '.result.orgId' "$shard/org-create.json")
        node scripts/bench/seed-portwood-account-packets.mjs --range "$first" "$last" "$shard/manifest.json" --target-org "$alias" --org-id "$org"
        jq -e --argjson first "$first" --argjson last "$last" --argjson count "$count" \
            '.firstOrdinal == $first and .lastOrdinal == $last and .accountCount == $count and
            .opportunityCount == ($count * 2) and .opportunityLineItemCount == ($count * 4)' "$shard/manifest.json" >/dev/null
        [[ -s "$shard/seed-ready.epoch" ]] || date +%s > "$shard/seed-ready.epoch"
        printf '%s seeded and verified\n' "$alias"
    ) > "$shard/seed.log" 2>&1 &
    pids+=("$!")
done
wait_for_all "${pids[@]}"

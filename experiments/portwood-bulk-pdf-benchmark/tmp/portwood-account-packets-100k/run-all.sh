#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
tool="$bench/orchestrate-account-batches.mjs"
mkdir -p "$run_dir/pdfs"

run_org() {
    local index="$1" alias shard org template first last count phase attempt
    alias=$(org_alias "$index")
    shard="$run_dir/$alias"
    set_org_range "$index"
    org=$(jq -er '.result.orgId' "$shard/org-create.json")
    template=$(cat "$shard/template.id")
    jq -e --arg org "$org" --argjson first "$first" --argjson last "$last" \
        '.orgId[0:15] == $org[0:15] and .firstOrdinal == $first and .lastOrdinal == $last' "$shard/manifest.json" >/dev/null
    local args=(--org "$alias" --org-id "$org" --template-id "$template" --run-key "$run_key" --first "$first" --last "$last"
        --shards "$batch_shards" --scope "$batch_scope" --state-dir "$shard" --poll-seconds 22 --wait-minutes 60)
    [[ -s "$shard/generation-start.epoch" ]] || date +%s > "$shard/generation-start.epoch"
    for phase in submit wait audit; do
        attempt=0
        until node "$tool" "$phase" "${args[@]}" >> "$shard/$phase.log" 2>&1; do
            attempt=$(( attempt + 1 ))
            [[ "$attempt" -lt 3 ]] || return 1
            sleep 7
        done
    done
    [[ -s "$shard/generation-verified.epoch" ]] || date +%s > "$shard/generation-verified.epoch"
    if [[ ! -s "$shard/export-ready.epoch" || ! -s "$shard/export.json" ]]; then
        [[ -s "$shard/export-start.epoch" ]] || date +%s > "$shard/export-start.epoch"
        node "$bench/export-account-packets.mjs" "PW-ACCOUNT-RECEIPT-$run_key" "$count" "$run_dir/pdfs" \
            --target-org "$alias" --org-id "$org" --first "$first" --workers "$export_workers" --stats "$shard/export.json"
        date +%s > "$shard/export-ready.epoch"
    fi
    sf limits api display --target-org "$alias" --json |
        jq -ce 'select(.status == 0) | [.result[] | select(.name == "DataStorageMB" or .name == "FileStorageMB")] | select(length == 2)' \
        > "$shard/storage-after.partial"
    mv "$shard/storage-after.partial" "$shard/storage-after.json"
}

if [[ $# -eq 0 ]]; then
    for (( index=1; index<=org_count; index++ )); do
        set -- "$@" "$index"
    done
fi
seen=()
for index in "$@"; do
    require_integer 'Org index' "$index" 1 "$org_count"
    [[ -z "${seen[$index]:-}" ]] || { printf 'Duplicate org index %s.\n' "$index" >&2; exit 2; }
    seen[$index]=true
    alias=$(org_alias "$index")
    shard="$run_dir/$alias"
    [[ -s "$shard/setup-ready.epoch" && -s "$shard/seed-ready.epoch" ]] || {
        printf 'Provision and seed %s first.\n' "$alias" >&2
        exit 1
    }
done
pids=()
for index in "$@"; do
    alias=$(org_alias "$index")
    run_org "$index" >> "$run_dir/$alias/workflow.log" 2>&1 &
    pids+=("$!")
done
wait_for_all "${pids[@]}"

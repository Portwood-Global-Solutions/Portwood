#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
manifest_args=()
for (( index=1; index<=org_count; index++ )); do
    alias=$(org_alias "$index")
    shard="$run_dir/$alias"
    [[ -s "$shard/export-ready.epoch" && -s "$shard/storage-after.json" ]] || {
        printf 'Finish the Salesforce export for %s first.\n' "$alias" >&2
        exit 1
    }
    manifest_args+=(--manifest "$shard/manifest.json")
done
date +%s > "$run_dir/browser-start.epoch"
output_dir="$run_dir/output"
artifacts_dir="$run_dir/artifacts"
node scripts/bench/portwood-pdf-merge-stress.mjs "$account_count" --input-dir "$run_dir/pdfs" \
    --uninterrupted --receipt-id-prefix PW-BENCH-100K-2025 --output-dir "$output_dir" --artifacts-dir "$artifacts_dir"
raw="$output_dir/portwood-salesforce-receipts-$account_count-uninterrupted.pdf"
merged="$output_dir/portwood-cedar-waters-account-statements-$account_count.pdf"
python3 "$bench/verify-account-packets.py" "$raw" "${manifest_args[@]}" --report "$run_dir/verified-content.json"
ln -f "$raw" "$merged"
python3 "$lab/report.py" "$run_dir" "$run_key" "$account_count" "$org_count" "$batch_shards" "$alias_prefix"
date +%s > "$run_dir/finished.epoch"

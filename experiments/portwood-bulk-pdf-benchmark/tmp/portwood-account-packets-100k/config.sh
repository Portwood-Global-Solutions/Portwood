#!/bin/bash
# Loaded by each workflow stage. Run scripts from the source kit root.
lab=tmp/portwood-account-packets-100k
bench=tmp/portwood-live-receipt-timing
[[ -f "$lab/scratch-def.json" ]] || { echo 'Run from the benchmark kit root.' >&2; exit 2; }
account_count=${PORTWOOD_ACCOUNT_COUNT:-100000}
org_count=${PORTWOOD_ORG_COUNT:-8}
batch_shards=${PORTWOOD_BATCH_SHARDS:-5}
batch_scope=${PORTWOOD_BATCH_SCOPE:-40}
export_workers=${PORTWOOD_EXPORT_WORKERS:-12}
run_key=${PORTWOOD_RUN_KEY:-PWCEDAR-$account_count}
alias_prefix=${PORTWOOD_ORG_PREFIX:-portwood-packets-$account_count}
package_id=${PORTWOOD_PACKAGE_ID:-04tVx000001BaZ3IAK}

require_integer() {
    local name="$1" value="$2" lower="$3" upper="$4"
    if ! [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]] || (( value < lower || value > upper )); then
        printf '%s must be between %s and %s.\n' "$name" "$lower" "$upper" >&2
        exit 2
    fi
}

require_integer PORTWOOD_ACCOUNT_COUNT "$account_count" 2 100000
require_integer PORTWOOD_ORG_COUNT "$org_count" 1 8
require_integer PORTWOOD_BATCH_SHARDS "$batch_shards" 1 5
require_integer PORTWOOD_BATCH_SCOPE "$batch_scope" 1 40
require_integer PORTWOOD_EXPORT_WORKERS "$export_workers" 1 24
if (( account_count / org_count < batch_shards || (account_count + org_count - 1) / org_count > 12500 )); then
    echo 'Each scratch org must have at least one Account per batch job and at most 12,500 Accounts.' >&2
    exit 2
fi
[[ "$run_key" =~ ^[A-Za-z0-9-]{1,48}$ ]] || { echo 'Invalid PORTWOOD_RUN_KEY.' >&2; exit 2; }
[[ "$alias_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9-]{1,42}$ ]] || { echo 'Invalid PORTWOOD_ORG_PREFIX.' >&2; exit 2; }
[[ "$package_id" =~ ^04t[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$ ]] || { echo 'Invalid PORTWOOD_PACKAGE_ID.' >&2; exit 2; }
run_dir="runs/$run_key"
mkdir -p "$run_dir"
benchmark_settings="$account_count $org_count $batch_shards $batch_scope $alias_prefix $package_id"
if [[ -s "$run_dir/settings" ]]; then
    [[ $(cat "$run_dir/settings") == "$benchmark_settings" ]] || {
        echo 'Existing run uses other settings. Use the original settings or choose a new PORTWOOD_RUN_KEY.' >&2
        exit 2
    }
else
    printf '%s\n' "$benchmark_settings" > "$run_dir/settings"
fi
export SF_DISABLE_TELEMETRY=true

org_alias() {
    printf '%s-%02d' "$alias_prefix" "$1"
}

set_org_range() {
    first=$(( ( $1 - 1 ) * account_count / org_count + 1 ))
    last=$(( $1 * account_count / org_count ))
    count=$(( last - first + 1 ))
}

wait_for_all() {
    local status=0 pid
    for pid in "$@"; do
        wait "$pid" || status=1
    done
    return "$status"
}

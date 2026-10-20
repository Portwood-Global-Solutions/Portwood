#!/usr/bin/env bash
#
# Portwood — functional smoke test for a REAL package install, driven entirely over
# the REST API.
#
#   ./scripts/edition-smoke-test.sh --target-org portwood-pe
#
# WHY THIS EXISTS AND NOT scripts/e2e-*.apex:
#
#   Professional and Group Edition orgs return
#       INVALID_OPERATION: Apex compilation not enabled for this organization
#   for ANY anonymous Apex. Every e2e-*.apex script is therefore unrunnable on the
#   low-tier SKUs — not failing, structurally impossible. (They are also unrunnable
#   against any install, since they call `public` subscriber-invisible classes
#   unprefixed. See scripts/setup-permission-test-org.sh.)
#
#   What IS reachable in a subscriber org on any edition: the REST Actions API over
#   the package's `global` @InvocableMethod surface. This script builds a template
#   from scratch with plain record DML and then renders it through
#   portwoodglobal__DocGenFlowAction — the same entry point a customer's Flow uses.
#
# It proves the install is functional end to end: object + field metadata landed,
# the permission set grants what the merge engine needs, ContentVersion plumbing
# works, the merge engine resolves tags, and Blob.toPdf produces a real PDF.

set -euo pipefail

ORG="portwood-pe"
KEEP="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-org|-o) ORG="$2"; shift 2 ;;
        --keep)          KEEP="true"; shift ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

PASS=0
FAIL=0
check() {
    if [[ "$2" == "true" ]]; then
        echo "  PASS: $1"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $1 — $3"; FAIL=$((FAIL + 1))
    fi
}

# A freshly created scratch org has no cached instanceApiVersion, so fall back to
# the org's own list of supported versions rather than hardcoding one.
api_version="$(sf org display --target-org "$ORG" --json \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r.get("instanceApiVersion") or r.get("apiVersion") or "")')"
if [[ -z "$api_version" ]]; then
    api_version="$(sf api request rest "/services/data/" --target-org "$ORG" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["version"])')"
fi
edition="$(sf data query --target-org "$ORG" -q 'SELECT OrganizationType FROM Organization LIMIT 1' --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["records"][0]["OrganizationType"])')"

echo "==> Org: $ORG  |  Edition: $edition  |  API v$api_version"

echo "==> 1. Seeding an Account to merge from"
account_id="$(sf data create record --target-org "$ORG" -s Account \
    -v "Name='Portwood Smoke Co' Industry=Technology" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
check "Account created" "true"

echo "==> 2. Uploading the HTML template body as a ContentVersion"
tmp_dir="$(mktemp -d -t portwood-smoke-XXXXXX)"
[[ "$KEEP" == "true" ]] || trap 'rm -rf "$tmp_dir"' EXIT

# Deliberately plain CSS 2.1 — Flying Saucer silently ignores flex/grid/calc/vars.
cat > "$tmp_dir/body.html" <<'HTML'
<html>
  <head>
    <style>
      body { font-family: Arial, sans-serif; font-size: 11pt; }
      h1 { font-size: 18pt; color: #1a4d7a; }
      table { border-collapse: collapse; width: 100%; }
      td { border: 1px solid #999; padding: 4pt 6pt; }
    </style>
  </head>
  <body>
    <h1>Portwood Edition Smoke Test</h1>
    <table>
      <tr><td>Account</td><td>{Name}</td></tr>
      <tr><td>Industry</td><td>{Industry}</td></tr>
      <tr><td>Record Id</td><td>{Id}</td></tr>
    </table>
  </body>
</html>
HTML

cv_body="$(python3 -c 'import base64,sys; print(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$tmp_dir/body.html")"
cat > "$tmp_dir/cv.json" <<JSON
{"Title":"portwood_smoke_body","PathOnClient":"portwood_smoke_body.html","VersionData":"${cv_body}"}
JSON

cv_id="$(sf api request rest "/services/data/v${api_version}/sobjects/ContentVersion" \
    --target-org "$ORG" --method POST --body "@$tmp_dir/cv.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
check "Template body ContentVersion created" "true"

echo "==> 3. Creating the template + active version"
template_id="$(sf data create record --target-org "$ORG" -s portwoodglobal__DocGen_Template__c \
    -v "Name='Portwood Edition Smoke' portwoodglobal__Base_Object_API__c=Account portwoodglobal__Query_Config__c='Id,Name,Industry' portwoodglobal__Type__c=HTML portwoodglobal__Output_Format__c=PDF portwoodglobal__Is_Active__c=true" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"

version_id="$(sf data create record --target-org "$ORG" -s portwoodglobal__DocGen_Template_Version__c \
    -v "portwoodglobal__Template__c=$template_id portwoodglobal__Content_Version_Id__c=$cv_id portwoodglobal__Base_Object_API__c=Account portwoodglobal__Query_Config__c='Id,Name,Industry' portwoodglobal__Type__c=HTML portwoodglobal__Output_Format__c=PDF portwoodglobal__Is_Active__c=true" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["id"])')"
check "Template + version records created" "true"

echo "==> 4. Generating a PDF through portwoodglobal__DocGenFlowAction (REST Actions API)"
cat > "$tmp_dir/action.json" <<JSON
{"inputs":[{"templateId":"${template_id}","recordId":"${account_id}","saveToRecord":true,"documentTitle":"Portwood Edition Smoke Output"}]}
JSON

# Keep CLI warnings on stderr out of the JSON consumed by the assertions.
if ! sf api request rest \
    "/services/data/v${api_version}/actions/custom/apex/portwoodglobal__DocGenFlowAction" \
    --target-org "$ORG" --method POST --body "@$tmp_dir/action.json" \
    > "$tmp_dir/action-out.json" 2> "$tmp_dir/action-stderr.log"; then
    cat "$tmp_dir/action-stderr.log" >&2
fi

gen_cv_id="$(python3 - "$tmp_dir/action-out.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if isinstance(d, list) and d and d[0].get("isSuccess") and (d[0].get("outputValues") or {}).get("success"):
    print(d[0]["outputValues"].get("contentVersionId") or "")
PY
)"

if [[ -z "$gen_cv_id" ]]; then
    check "Invocable action returned a generated document" "false" "see $tmp_dir/action-out.json"
    echo "  --- action response ---"
    head -30 "$tmp_dir/action-out.json"
else
    check "Invocable action returned a generated document" "true"

    # A PDF that renders is a PDF that starts with %PDF and is not a stub. Pull the
    # bytes back rather than trusting the Id: a merge failure can still produce a file.
    size="$(sf data query --target-org "$ORG" \
        -q "SELECT ContentSize, FileType, Title FROM ContentVersion WHERE Id='$gen_cv_id'" --json \
        | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]["records"][0]; print(r["ContentSize"], r["FileType"], r["Title"])')"
    echo "  generated: $size"

    if ! sf api request rest "/services/data/v${api_version}/sobjects/ContentVersion/${gen_cv_id}/VersionData" \
        --target-org "$ORG" --stream-to-file "$tmp_dir/out.pdf" > "$tmp_dir/download.log" 2>&1; then
        cat "$tmp_dir/download.log" >&2
    fi

    head_bytes="$(head -c 5 "$tmp_dir/out.pdf" 2>/dev/null || echo "")"
    [[ "$head_bytes" == "%PDF-" ]] \
        && check "Downloaded file is a real PDF (%PDF- header)" "true" \
        || check "Downloaded file is a real PDF (%PDF- header)" "false" "got '$head_bytes'"

    byte_count="$(wc -c < "$tmp_dir/out.pdf" | tr -d ' ')"
    [[ "$byte_count" -gt 1000 ]] \
        && check "PDF has real content ($byte_count bytes)" "true" \
        || check "PDF has real content" "false" "only $byte_count bytes"

    # Merge-tag proof: the account name must appear in the PDF's text. Compressed
    # streams mean a raw grep can miss it, so fall back to pdftotext when present.
    if command -v pdftotext >/dev/null 2>&1; then
        pdftotext "$tmp_dir/out.pdf" "$tmp_dir/out.txt" 2>/dev/null || true
        grep -q "Portwood Smoke Co" "$tmp_dir/out.txt" 2>/dev/null \
            && check "Merge tag {Name} resolved in rendered PDF" "true" \
            || check "Merge tag {Name} resolved in rendered PDF" "false" "'Portwood Smoke Co' not in extracted text"
        grep -q "{Name}" "$tmp_dir/out.txt" 2>/dev/null \
            && check "No unresolved merge tags leaked" "false" "literal {Name} found in output" \
            || check "No unresolved merge tags leaked" "true"
    else
        echo "  SKIP: merge-tag text assertions (pdftotext not installed — brew install poppler)"
    fi
fi

echo "==> 5. Cleaning up"
if [[ "$KEEP" == "true" ]]; then
    echo "  (--keep) left behind: account=$account_id template=$template_id"
    echo "  artifacts in $tmp_dir"
else
    sf data delete record --target-org "$ORG" -s portwoodglobal__DocGen_Template__c -i "$template_id" >/dev/null 2>&1 || true
    sf data delete record --target-org "$ORG" -s Account -i "$account_id" >/dev/null 2>&1 || true
    echo "  removed smoke records"
fi

echo
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    echo "ALL TESTS PASSED — package is functional on $edition"
else
    echo "SMOKE TEST FAILED on $edition"
    exit 1
fi

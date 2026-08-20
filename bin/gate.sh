#!/bin/sh
# Required gate for autolaunch-contracts.
#
# This is the sole required entrypoint. It is offline: it performs no download, no package or
# registry lookup, and no git fetch. Dependencies and the Solidity compiler are materialized
# before the gate, never by it; anything missing or drifted fails closed here.
#
# A failure of this gate is a stop-report. Never relax a pinned identity, threshold, or
# configuration value to make it pass.
set -eu

cd "$(dirname "$0")/.."

FOUNDRY_OFFLINE=true
FOUNDRY_PROFILE=default
GIT_TERMINAL_PROMPT=0
export FOUNDRY_OFFLINE FOUNDRY_PROFILE GIT_TERMINAL_PROMPT

TAB=$(printf '\t')

closure_file=requirements/dependency-closure.txt
toolchain_lock=requirements/toolchain.lock
authority_lock=requirements/authority.lock
ledger_file=requirements/ledger.toml
fixture_file=test/fixtures/base-bindings.json
manifest_file=contracts/chain-contracts.yaml
bindings_source=src/bindings/BaseBindings.sol
dispositions_file=docs/security/slither-dispositions.md
threat_model_file=docs/security/threat-model.md

generated=reports/generated
mkdir -p "$generated"

receipt="$generated/dependency-receipt.txt"
required_paths="$generated/required-paths.txt"
status_paths="$generated/submodule-status-paths.txt"
spec_bindings="$generated/spec-bindings.txt"
submodule_status="$generated/submodule-status.txt"
test_report="$generated/forge-test.json"
test_stderr="$generated/forge-test.stderr.log"
slither_json="$generated/slither.json"
slither_checklist="$generated/slither-checklist.md"
expected_literals="$generated/expected-literals.txt"
found_literals="$generated/found-literals.txt"
config_json="$generated/forge-config.json"

: >"$receipt"

fail() {
    printf 'GATE FAIL: %s\n' "$*" >&2
    exit 1
}

expect() {
    [ "$2" = "$3" ] || fail "$1: expected [$2], found [$3]"
}

record() {
    printf '%s verified: %s\n' "$1" "$2" >>"$receipt"
}

section() {
    printf '\n=== %s ===\n' "$*"
}

lock_value() {
    lock_result=$(awk -v key="$2" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 3 }' "$1") ||
        fail "missing key [$2] in $1"
    [ -n "$lock_result" ] || fail "empty value for key [$2] in $1"
    printf '%s\n' "$lock_result"
}

sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    else
        fail "no SHA-256 utility is available"
    fi
}

# Hexadecimal literals of an exact character length: 42 for an address, 66 for a bytes32.
hex_literals() {
    grep -oE '0x[0-9a-fA-F]+' "$1" | awk -v want="$2" 'length($0) == want' | sort -u
}

closure_rows() {
    awk -v role="$1" '
        /^[[:space:]]*#/ { next }
        NF == 0 { next }
        $1 == role {
            detail = ""
            for (field = 5; field <= NF; field++) {
                detail = detail (detail == "" ? "" : " ") $field
            }
            printf "%s\t%s\t%s\t%s\n", $2, $3, $4, detail
        }
    ' "$closure_file"
}

# Split a closure path into the parent repository that owns it and the path inside that parent.
split_path() {
    split_parent=${1%/lib/*}
    if [ "$split_parent" = "$1" ]; then
        split_parent=.
        split_child=$1
    else
        split_child=${1#"$split_parent"/}
    fi
}

submodule_head() {
    git -C "$1" rev-parse HEAD 2>/dev/null || fail "cannot read HEAD of $1; its material is absent"
}

require_clean_submodule() {
    [ -z "$(git -C "$1" status --porcelain)" ] || fail "submodule tree is dirty: $1"
}

materialize() {
    split_path "$1"
    git -C "$split_parent" submodule update --init --no-fetch -- "$split_child" >/dev/null 2>&1 ||
        fail "required submodule is not materialized offline: $1 (materialize the pinned closure before the gate)"
}

# ---------------------------------------------------------------------------
section "Tool and build configuration identity (DEP-010, DEP-011, DEP-014)"
# ---------------------------------------------------------------------------

for required_file in "$closure_file" "$toolchain_lock" "$authority_lock" "$ledger_file" \
    "$fixture_file" "$manifest_file" "$bindings_source" "$dispositions_file" \
    "$threat_model_file" bin/check-requirements.py SPEC.md .gitmodules; do
    [ -f "$required_file" ] || fail "required repository file is missing: $required_file"
done

command -v forge >/dev/null 2>&1 || fail "forge is not on PATH"
command -v slither >/dev/null 2>&1 || fail "slither is not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not on PATH"

forge_version=$(forge --version | awk '/^forge Version:/ { print $3; exit }')
forge_commit=$(forge --version | awk '/^Commit SHA:/ { print $3; exit }')
slither_version=$(slither --version 2>&1 | tail -n 1 | tr -d '[:space:]')
python_version=$(python3 --version 2>&1 | awk '{ print $2 }')

expect "forge version" "$(lock_value "$toolchain_lock" forge_version)" "$forge_version"
expect "forge commit" "$(lock_value "$toolchain_lock" forge_commit_sha)" "$forge_commit"
expect "slither version" "$(lock_value "$toolchain_lock" slither_version)" "$slither_version"
expect "ledger-check interpreter" "$(lock_value "$toolchain_lock" ledger_python_version)" "$python_version"
record DEP-010 "forge $forge_version ($forge_commit); slither $slither_version; python $python_version"

forge config --json >"$config_json"
grep -qE '"offline":[[:space:]]*true' "$config_json" || fail "the effective Foundry configuration is not offline"
grep -qE '"ffi":[[:space:]]*false' "$config_json" || fail "the effective Foundry configuration enables FFI"
record DEP-014 "the effective Foundry configuration is offline with FFI disabled"

expect "SPEC.md digest" "$(lock_value "$authority_lock" spec_sha256)" "$(sha256_of SPEC.md)"
record DEP-011 "SPEC.md matches the frozen authority digest"

# ---------------------------------------------------------------------------
section "Pinned dependency closure (DEP-001 through DEP-008)"
# ---------------------------------------------------------------------------

: >"$required_paths"
for role in pin derived mirror; do
    closure_rows "$role" | cut -f1 >>"$required_paths"
done
[ -s "$required_paths" ] || fail "the dependency closure declares no required path"

closure_rows pin | while IFS="$TAB" read -r path source requirement detail; do
    expect "pin row $path takes its expectation from SPEC.md" SPEC.md "$source"
    materialize "$path"
    expected=$(sed -n 's/^- '"$detail"': `\([0-9a-f]\{40\}\)`$/\1/p' SPEC.md)
    [ -n "$expected" ] || fail "SPEC.md pins no commit under the bullet label [$detail]"
    expect "founder pin $path" "$expected" "$(submodule_head "$path")"
    require_clean_submodule "$path"
    record "$requirement" "$path pinned at the SPEC.md literal for [$detail] ($expected)"
done

closure_rows derived | while IFS="$TAB" read -r path source requirement detail; do
    materialize "$path"
    child=${path#"$source"/}
    expected=$(git -C "$source" rev-parse "HEAD:$child" 2>/dev/null) ||
        fail "$source records no gitlink at $child"
    expect "derived pin $path" "$expected" "$(submodule_head "$path")"
    require_clean_submodule "$path"
    record "$requirement" "$child at $expected, derived from the pinned tree of $source ($detail)"
done

closure_rows mirror | while IFS="$TAB" read -r path source requirement detail; do
    materialize "$path"
    expected=$(submodule_head "$source")
    expect "mirrored pin $path" "$expected" "$(submodule_head "$path")"
    require_clean_submodule "$path"
    record "$requirement" "$path follows $source at $expected ($detail)"
done

closure_rows crosscheck | while IFS="$TAB" read -r path source requirement detail; do
    split_path "$source"
    expected=$(git -C "$split_parent" rev-parse "HEAD:$split_child" 2>/dev/null) ||
        fail "$split_parent records no gitlink at $split_child"
    expect "crosscheck $path against $source" "$expected" "$(submodule_head "$path")"
    record "$requirement" "$path at $expected equals the gitlink $split_parent records ($detail)"
done

closure_rows distinct | while IFS="$TAB" read -r path source requirement detail; do
    left=$(submodule_head "$path")
    right=$(submodule_head "$source")
    [ "$left" != "$right" ] || fail "$path and $source must stay distinct commits, both are $left"
    record "$requirement" "$path ($left) is distinct from $source ($right) ($detail)"
done

git submodule status --recursive >"$submodule_status" 2>&1 ||
    fail "unable to inspect the recursive submodule tree"
awk '{ print $2 }' "$submodule_status" | sort -u >"$status_paths"

while IFS= read -r status_line; do
    [ -n "$status_line" ] || continue
    status_prefix=$(printf '%s' "$status_line" | cut -c1)
    status_path=$(printf '%s' "$status_line" | awk '{ print $2 }')
    case "$status_prefix" in
        ' ') ;;
        '-')
            ! grep -Fxq "$status_path" "$required_paths" ||
                fail "required submodule is not initialized: $status_path"
            ;;
        *) fail "submodule disagrees with the gitlink its parent records: $status_line" ;;
    esac
done <"$submodule_status"

while read -r required_path; do
    [ -n "$required_path" ] || continue
    grep -Fxq "$required_path" "$status_paths" ||
        fail "required submodule has no recursive status entry: $required_path"
done <"$required_paths"

git config --file .gitmodules --get-regexp '\.path$' | awk '{ print $2 }' |
    while read -r declared_path; do
        grep -Fxq "$declared_path" "$required_paths" ||
            fail ".gitmodules declares a root submodule the closure does not require: $declared_path"
    done
record DEP-008 "every required submodule is initialized, clean, and agrees with its parent gitlink"

# ---------------------------------------------------------------------------
section "Frozen binding literals (DEP-012, DEP-013)"
# ---------------------------------------------------------------------------

sed -n 's/^| \(.*\) | `\(0x[0-9a-fA-F]\{40\}\)` |$/\1;\2/p' SPEC.md |
    awk -F';' '{ key = tolower($1); gsub(/ /, "_", key); printf "%s;%s\n", key, $2 }' >"$spec_bindings"
[ -s "$spec_bindings" ] || fail "SPEC.md declares no binding table rows"

while IFS=';' read -r key address; do
    grep -F "\"$key\": \"$address\"" "$fixture_file" >/dev/null ||
        fail "$fixture_file does not bind $key to the SPEC.md address $address"
done <"$spec_bindings"

# Set equality below proves each remaining file carries every SPEC.md literal and no other.
cut -d';' -f2 "$spec_bindings" | sort -u >"$expected_literals"
for compared_file in "$fixture_file" "$manifest_file" "$bindings_source"; do
    hex_literals "$compared_file" 42 >"$found_literals"
    diff "$expected_literals" "$found_literals" >/dev/null ||
        fail "$compared_file carries an address literal SPEC.md does not, or is missing one"
done

spec_code_hash=$(sed -n 's/^.*runtime code hash `\(0x[0-9a-f]\{64\}\)`.*$/\1/p' SPEC.md)
[ -n "$spec_code_hash" ] || fail "SPEC.md declares no CCA runtime code hash"

printf '%s\n' "$spec_code_hash" >"$expected_literals"
for compared_file in "$fixture_file" "$manifest_file" "$bindings_source"; do
    hex_literals "$compared_file" 66 >"$found_literals"
    diff "$expected_literals" "$found_literals" >/dev/null ||
        fail "$compared_file carries a 32-byte literal that is not the SPEC.md CCA runtime code hash"
done
record DEP-012 "the manifest, fixture, and binding source carry exactly the SPEC.md binding set"

admitted_signature=$(sed -n 's/.*"cca_factory_protocol_fee_controller_signature": "\([^"]*\)".*/\1/p' "$fixture_file")
[ -n "$admitted_signature" ] || fail "$fixture_file declares no CCA admission signature"
grep -F "$admitted_signature" "$manifest_file" >/dev/null ||
    fail "$manifest_file does not declare the admitted signature $admitted_signature"

admitted_function=${admitted_signature%%(*}
pinned_cca=$(closure_rows pin | awk -F"$TAB" '$4 == "CCA v2.1" { print $1; exit }')
[ -n "$pinned_cca" ] || fail "the dependency closure declares no CCA v2.1 pin"
implementation_files=$(grep -rlE "^[[:space:]]*function $admitted_function\(" \
    "$pinned_cca/src" --include='*.sol' 2>/dev/null | grep -v '/interfaces/' || true)
[ -n "$implementation_files" ] ||
    fail "$admitted_signature is defined by no pinned CCA implementation source, only by an interface"
record DEP-013 "$admitted_signature is defined by pinned implementation source $(printf '%s' "$implementation_files" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
section "Formatting"
# ---------------------------------------------------------------------------

forge fmt --check

# ---------------------------------------------------------------------------
section "Build and compiled build identity (DEP-009)"
# ---------------------------------------------------------------------------

forge build --sizes

artifact_setting() {
    find out -name '*.json' -not -path 'out/build-info/*' -exec grep -oh "$1" {} + | sort -u
}

expect "compiler recorded in every artifact" \
    "\"version\":\"$(lock_value "$toolchain_lock" solc_identity)\"" \
    "$(artifact_setting '"version":"0\.8\.[0-9]*+commit\.[0-9a-f]*"')"
expect "artifact optimizer runs" \
    "\"runs\":$(lock_value "$toolchain_lock" solc_optimizer_runs)" \
    "$(artifact_setting '"runs":[0-9]*')"
expect "artifact via-IR" \
    "\"viaIR\":$(lock_value "$toolchain_lock" solc_via_ir)" \
    "$(artifact_setting '"viaIR":[a-z]*')"
expect "artifact EVM version" \
    "\"evmVersion\":\"$(lock_value "$toolchain_lock" solc_evm_version)\"" \
    "$(artifact_setting '"evmVersion":"[a-z]*"')"
expect "artifact bytecode hash" \
    "\"bytecodeHash\":\"$(lock_value "$toolchain_lock" solc_bytecode_hash)\"" \
    "$(artifact_setting '"bytecodeHash":"[a-z]*"')"
expect "artifact CBOR metadata" \
    "\"appendCBOR\":$(lock_value "$toolchain_lock" solc_append_cbor)" \
    "$(artifact_setting '"appendCBOR":[a-z]*')"
record DEP-009 "every artifact records $(lock_value "$toolchain_lock" solc_identity), optimizer $(lock_value "$toolchain_lock" solc_optimizer_runs), via-IR, $(lock_value "$toolchain_lock" solc_evm_version), metadata disabled"

# ---------------------------------------------------------------------------
section "Source-enumerated test execution and requirement reconciliation"
# ---------------------------------------------------------------------------

test_status=0
forge test --json >"$test_report" 2>"$test_stderr" || test_status=$?
cat "$test_stderr"

python3 bin/check-requirements.py \
    --ledger "$ledger_file" \
    --test-dir test \
    --test-report "$test_report" \
    --dependency-receipt "$receipt"

[ "$test_status" -eq 0 ] || fail "forge test exited $test_status"

# ---------------------------------------------------------------------------
section "Static analysis"
# ---------------------------------------------------------------------------

hidden_triage=$(find . -name '*slither.db.json' -not -path './lib/*' -not -path './out/*' || true)
[ -z "$hidden_triage" ] || fail "hidden Slither triage database present: $hidden_triage"

for suppressed_file in $(grep -rl 'slither-disable' src test 2>/dev/null || true); do
    grep -F "$suppressed_file" "$dispositions_file" >/dev/null ||
        fail "inline Slither suppression in $suppressed_file is not accounted for in $dispositions_file"
done

# Slither refuses to overwrite an existing report, so a stale artifact would silently survive.
rm -f "$slither_json" "$slither_checklist"
slither . --fail-medium --json "$slither_json" --checklist >"$slither_checklist"
[ -s "$slither_json" ] || fail "Slither produced no JSON evidence"
cat "$slither_checklist"

# ---------------------------------------------------------------------------
section "Gate report"
# ---------------------------------------------------------------------------

printf 'required submodule paths: %s\n' "$(wc -l <"$required_paths" | tr -d ' ')"
sort -u "$required_paths"
printf '\ndependency receipt:\n'
cat "$receipt"
printf '\nGATE PASS\n'

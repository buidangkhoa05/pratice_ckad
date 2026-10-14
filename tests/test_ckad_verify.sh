#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DRILLS="$(make_drill_tree "$TMP")"
stub_setup

fixture_script() { printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$1"; chmod +x "$1"; }
fixture_script "$DRILLS/1-design-build/01-sidecar/verify.sh" 0
fixture_script "$DRILLS/1-design-build/02-init-job/verify.sh" 1
mkdir -p "$DRILLS/1-design-build/01-sidecar/.solution"
printf 'kind: Pod\nmetadata:\n  name: logger\n' \
  > "$DRILLS/1-design-build/01-sidecar/.solution/pod.yaml"

ckad() {
  CKAD_ROOT="$CKAD_TEST_ROOT" DRILLS_ROOT="$DRILLS" \
  CKAD_STATE="$TMP/.ckad-state" SCRATCH_ROOT="$TMP/scratch" NO_COLOR=1 \
  bash "$CKAD_TEST_ROOT/bin/ckad" "$@" 2>&1
}

# --- solution is gated on a verify attempt ---
out="$(ckad solution 1.1)"; rc=$?
expect_rc "$rc" 1 "solution refuses before any verify attempt"
expect_contains "$out" "verify" "refusal tells you to verify first"
if printf '%s' "$out" | grep -q "kind: Pod"; then
  expect_eq "leaked" "withheld" "refusal does not print the solution"
else
  expect_eq "withheld" "withheld" "refusal does not print the solution"
fi

# --- verify passing ---
out="$(ckad verify 1.1)"; rc=$?
expect_rc "$rc" 0 "verify exits 0 when the drill's verify.sh passes"
expect_contains "$(cat "$TMP/.ckad-state")" "1.1 1 1" "a passing verify is recorded"

# --- verify failing ---
out="$(ckad verify 1.2)"; rc=$?
expect_rc "$rc" 1 "verify exits 1 when the drill's verify.sh fails"
expect_contains "$(cat "$TMP/.ckad-state")" "1.2 1 0" "a failing verify is recorded as not passed"

# --- solution after an attempt ---
out="$(ckad solution 1.1)"; rc=$?
expect_rc "$rc" 0 "solution succeeds after a verify attempt"
expect_contains "$out" "kind: Pod" "solution prints the reference manifest"

# --- a drill with no verify.sh is a repo bug, not a user failure ---
out="$(ckad verify 3.1)"; rc=$?
expect_rc "$rc" 1 "verify fails loudly when the drill has no verify.sh"
expect_contains "$out" "verify.sh" "missing verify.sh is named in the error"

# --- reset ---
stub_reset
mkdir -p "$TMP/scratch/1.1"; date +%s > "$TMP/scratch/1.1/.started"
ckad reset 1.1 >/dev/null
expect_contains "$(stub_calls)" "delete namespace ckad-1-1" "reset deletes the drill namespace"
expect_eq "$(test -f "$TMP/scratch/1.1/.started" && echo yes || echo no)" "no" "reset clears the timer"

# --- score ---
out="$(ckad score)"
expect_contains "$out" "25" "score shows domain 4's exam weight"
expect_contains "$out" "1/2" "score shows passed over total for domain 1"

harness_finish

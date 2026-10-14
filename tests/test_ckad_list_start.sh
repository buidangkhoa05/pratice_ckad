#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DRILLS="$(make_drill_tree "$TMP")"
stub_setup

fixture_script() { # <path> <exit-code>
  printf '#!/usr/bin/env bash\nexit %s\n' "$2" > "$1"
  chmod +x "$1"
}
fixture_script "$DRILLS/1-design-build/01-sidecar/verify.sh" 0

ckad() { # run the CLI with every path redirected into the fixture
  CKAD_ROOT="$CKAD_TEST_ROOT" \
  DRILLS_ROOT="$DRILLS" \
  CKAD_STATE="$TMP/.ckad-state" \
  SCRATCH_ROOT="$TMP/scratch" \
  NO_COLOR=1 \
  bash "$CKAD_TEST_ROOT/bin/ckad" "$@" 2>&1
}

# --- list ---
out="$(ckad list)"
expect_contains "$out" "1.1" "list shows drill 1.1"
expect_contains "$out" "Sidecar sharing an emptyDir" "list shows the drill title"
expect_contains "$out" "8 min" "list shows the target time"
expect_contains "$out" "3.1" "list shows drills from other domains"

out="$(ckad list 1)"
expect_contains "$out" "1.2" "list <domain> shows that domain"
if printf '%s' "$out" | grep -q "3.1"; then
  expect_eq "leaked" "filtered" "list <domain> excludes other domains"
else
  expect_eq "filtered" "filtered" "list <domain> excludes other domains"
fi

# --- unknown and malformed ids ---
ckad start 9.9 >/dev/null 2>&1
expect_rc "$?" 1 "start fails on an unknown id"
expect_contains "$(ckad start 9.9)" "1.1" "start on an unknown id lists the valid ids"
ckad start banana >/dev/null 2>&1
expect_rc "$?" 1 "start fails on a malformed id"

# --- start ---
# First kubectl call (get namespace) fails, so start must fall through to
# create; the second (create namespace) succeeds.
stub_reset; stub_rc_seq "1 0"
out="$(ckad start 1.1)"; rc=$?
expect_rc "$rc" 0 "start succeeds"
expect_contains "$out" "Sidecar sharing an emptyDir" "start prints the task"
expect_contains "$(stub_calls)" "create namespace ckad-1-1" "start creates the drill namespace"
expect_eq "$(test -f "$TMP/scratch/1.1/.started" && echo yes)" "yes" "start records a start timestamp"
expect_eq "$(test -d "$TMP/scratch/1.1" && echo yes)" "yes" "start creates a scratch directory"

# --- an existing namespace is reused rather than recreated ---
stub_reset; stub_rc 0
ckad start 1.1 >/dev/null
if printf '%s' "$(stub_calls)" | grep -q "create namespace"; then
  expect_eq "recreated" "reused" "start reuses an existing namespace"
else
  expect_eq "reused" "reused" "start reuses an existing namespace"
fi

# --- start runs setup.sh when present, with NS exported ---
stub_reset
printf '#!/usr/bin/env bash\nprintf "%%s" "$NS" > "%s/setup-ran"\n' "$TMP" \
  > "$DRILLS/3-observability/01-broken-probe/setup.sh"
chmod +x "$DRILLS/3-observability/01-broken-probe/setup.sh"
ckad start 3.1 >/dev/null
expect_eq "$(cat "$TMP/setup-ran" 2>/dev/null)" "ckad-3-1" "start runs setup.sh with NS set to the drill namespace"

harness_finish

# Sourced by every tests/test_*.sh. Owns expectations and stub wiring.
set -uo pipefail

CKAD_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_EXPECT_PASS=0
_EXPECT_FAIL=0

expect_eq() { # <actual> <expected> <desc>
  if [[ "$1" == "$2" ]]; then
    _EXPECT_PASS=$(( _EXPECT_PASS + 1 )); printf '  ok   %s\n' "$3"
  else
    _EXPECT_FAIL=$(( _EXPECT_FAIL + 1 ))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$3" "$2" "$1"
  fi
}

expect_contains() { # <haystack> <needle> <desc>
  if printf '%s' "$1" | grep -qF -- "$2"; then
    _EXPECT_PASS=$(( _EXPECT_PASS + 1 )); printf '  ok   %s\n' "$3"
  else
    _EXPECT_FAIL=$(( _EXPECT_FAIL + 1 ))
    printf '  FAIL %s\n       missing: [%s]\n       in:      [%s]\n' "$3" "$2" "$1"
  fi
}

expect_rc() { # <actual_rc> <expected_rc> <desc>
  expect_eq "$1" "$2" "$3 (exit code)"
}

harness_finish() {
  printf '  --- %d passed, %d failed\n' "$_EXPECT_PASS" "$_EXPECT_FAIL"
  (( _EXPECT_FAIL == 0 ))
}

# --- stub kubectl wiring ---------------------------------------------------
stub_setup() {
  STUB_DIR="$(mktemp -d)"
  cp "$CKAD_TEST_ROOT/tests/stubs/kubectl" "$STUB_DIR/kubectl"
  chmod +x "$STUB_DIR/kubectl"
  STUB_LOG="$STUB_DIR/log"; : > "$STUB_LOG"
  STUB_COUNT="$STUB_DIR/count"; printf '0' > "$STUB_COUNT"
  PATH="$STUB_DIR:$PATH"
  export PATH STUB_LOG STUB_COUNT
  unset STUB_OUT STUB_RC STUB_RC_SEQ
  trap 'rm -rf "$STUB_DIR"' EXIT
}

stub_out()    { export STUB_OUT="$1"; }
stub_rc()     { export STUB_RC="$1"; }
stub_rc_seq() { export STUB_RC_SEQ="$1"; printf '0' > "$STUB_COUNT"; }
stub_calls()  { cat "$STUB_LOG"; }
stub_reset()  { : > "$STUB_LOG"; printf '0' > "$STUB_COUNT"; unset STUB_OUT STUB_RC STUB_RC_SEQ; }

# --- fixture drill tree ----------------------------------------------------
# Builds a minimal drills/ tree: domains 1 and 3, two drills in domain 1 and
# one in domain 3. Echoes the drills root.
make_drill_tree() { # <parent-dir>
  local root="$1/drills"
  mkdir -p "$root/1-design-build/01-sidecar" \
           "$root/1-design-build/02-init-job" \
           "$root/3-observability/01-broken-probe"

  cat > "$root/1-design-build/01-sidecar/task.md" <<'EOF'
# Sidecar sharing an emptyDir

**Target time:** 8 min

Do the thing.
EOF
  cat > "$root/1-design-build/02-init-job/task.md" <<'EOF'
# Init container ordering and a failing Job

**Target time:** 12 min
EOF
  cat > "$root/3-observability/01-broken-probe/task.md" <<'EOF'
# Diagnose a failing readiness probe

**Target time:** 10 min
EOF
  printf '%s\n' "$root"
}

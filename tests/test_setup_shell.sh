#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SCRIPT="$CKAD_TEST_ROOT/bin/setup-shell.sh"

# Sourcing must not exit the calling shell even with a fake HOME and no cluster.
out="$(HOME="$TMP" bash -c "source '$SCRIPT' >/dev/null 2>&1; echo STILL_ALIVE")"
expect_contains "$out" "STILL_ALIVE" "sourcing setup-shell.sh does not exit the shell"

# The exported dry-run and force shorthands are what they claim to be.
out="$(HOME="$TMP" bash -c "source '$SCRIPT' >/dev/null 2>&1; echo \"\$do\"")"
expect_eq "$out" "--dry-run=client -o yaml" "\$do expands to the dry-run flags"
out="$(HOME="$TMP" bash -c "source '$SCRIPT' >/dev/null 2>&1; echo \"\$now\"")"
expect_eq "$out" "--force --grace-period=0" "\$now expands to the force-delete flags"

# Aliases are defined.
out="$(HOME="$TMP" bash -ic "source '$SCRIPT' >/dev/null 2>&1; alias k; alias kgp" 2>&1)"
expect_contains "$out" "kubectl" "alias k points at kubectl"
expect_contains "$out" "get pods" "alias kgp gets pods"

# The vimrc block is written once and only once.
HOME="$TMP" bash -c "source '$SCRIPT' >/dev/null 2>&1"
expect_contains "$(cat "$TMP/.vimrc")" "shiftwidth=2" "vimrc gains the YAML indent settings"
HOME="$TMP" bash -c "source '$SCRIPT' >/dev/null 2>&1"
expect_eq "$(grep -c 'ckad-practice' "$TMP/.vimrc")" "1" "re-sourcing does not duplicate the vimrc block"

harness_finish

#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DRILLS_ROOT="$(make_drill_tree "$TMP")"
export CKAD_STATE="$TMP/.ckad-state"
source "$CKAD_TEST_ROOT/lib/drills.sh"
source "$CKAD_TEST_ROOT/lib/state.sh"

expect_eq "$(state_get 1.1)" "0 0 0" "unknown drill defaults to 0 0 0"
expect_eq "$(state_attempts 1.1)" "0" "unknown drill has no attempts"
state_passed 1.1; expect_rc "$?" 1 "unknown drill has not passed"

state_record 1.1 0 95
expect_eq "$(state_get 1.1)" "1 0 0" "a failed attempt increments attempts and records no time"
state_passed 1.1; expect_rc "$?" 1 "a failed attempt does not mark the drill passed"

state_record 1.1 1 120
expect_eq "$(state_get 1.1)" "2 1 120" "a passing attempt records the time"
state_passed 1.1; expect_rc "$?" 0 "a passing attempt marks the drill passed"

state_record 1.1 1 90
expect_eq "$(state_get 1.1)" "3 1 90" "a faster pass replaces the best time"

state_record 1.1 1 200
expect_eq "$(state_get 1.1)" "4 1 90" "a slower pass keeps the best time"

state_record 1.1 0 10
expect_eq "$(state_get 1.1)" "5 1 90" "a later failure keeps passed and best time"

state_record 1.2 1 60
expect_eq "$(state_domain_counts 1)" "2 2" "domain counts reflect two passed of two drills"
expect_eq "$(state_domain_counts 3)" "0 1" "an untouched domain counts zero passed"

expect_eq "${CKAD_WEIGHTS[4]}" "25" "domain 4 carries the heaviest exam weight"

# Records must survive a fresh source of the library.
unset CKAD_WEIGHTS
source "$CKAD_TEST_ROOT/lib/state.sh"
expect_eq "$(state_get 1.2)" "1 1 60" "state persists across a reload"

harness_finish

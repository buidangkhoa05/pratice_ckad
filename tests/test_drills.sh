#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DRILLS_ROOT="$(make_drill_tree "$TMP")"
source "$CKAD_TEST_ROOT/lib/drills.sh"

expect_eq "$(drill_domains | wc -l | tr -d ' ')" "2" "drill_domains finds both domain directories"
expect_contains "$(drill_domains)" "1-design-build" "drill_domains lists domain 1"

expect_eq "$(drill_ids | tr '\n' ' ')" "1.1 1.2 3.1 " "drill_ids lists ids in order"

expect_eq "$(drill_path 1.2)" "$DRILLS_ROOT/1-design-build/02-init-job" "drill_path maps 1.2 to the padded directory"
expect_eq "$(drill_path 3.1)" "$DRILLS_ROOT/3-observability/01-broken-probe" "drill_path maps across domains"

drill_path 9.9 >/dev/null 2>&1
expect_rc "$?" 1 "drill_path returns 1 for an unknown id"

drill_path banana >/dev/null 2>&1
expect_rc "$?" 2 "drill_path returns 2 for a malformed id"

expect_eq "$(drill_ns 3.2)" "ckad-3-2" "drill_ns builds the namespace name"
expect_eq "$(drill_domain_of 4.7)" "4" "drill_domain_of extracts the domain"

expect_eq "$(drill_title "$(drill_path 1.1)")" "Sidecar sharing an emptyDir" "drill_title reads the task.md H1"
expect_eq "$(drill_target "$(drill_path 1.1)")" "8 min" "drill_target reads the target time"

# A drill whose task.md omits the target time must not break listing.
mkdir -p "$DRILLS_ROOT/3-observability/02-no-meta"
printf '# Bare drill\n' > "$DRILLS_ROOT/3-observability/02-no-meta/task.md"
expect_eq "$(drill_target "$DRILLS_ROOT/3-observability/02-no-meta")" "-" "missing target time reads as -"

harness_finish

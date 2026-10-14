#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"
LIB="$CKAD_TEST_ROOT/lib"

# finish exits non-zero when nothing was asserted
out="$(bash -c "source '$LIB/report.sh'; finish" 2>&1)"; rc=$?
expect_rc "$rc" 1 "finish fails when no assertions ran"
expect_contains "$out" "FAIL" "zero-assertion run reports FAIL"

# all passing
out="$(NO_COLOR=1 bash -c "source '$LIB/report.sh'; report_pass 'thing one'; report_pass 'thing two'; finish" 2>&1)"; rc=$?
expect_rc "$rc" 0 "finish succeeds when every assertion passed"
expect_contains "$out" "thing one" "passing assertion is named in output"
expect_contains "$out" "2/2" "summary counts passing assertions"

# one failure
out="$(NO_COLOR=1 bash -c "source '$LIB/report.sh'; report_pass 'ok bit'; report_fail 'bad bit' 'two' 'five'; finish" 2>&1)"; rc=$?
expect_rc "$rc" 1 "finish fails when any assertion failed"
expect_contains "$out" "bad bit" "failing assertion is named"
expect_contains "$out" "two" "failure shows the expected value"
expect_contains "$out" "five" "failure shows the actual value"
expect_contains "$out" "1/2" "summary counts only passes"

# report_fail must not abort the caller
out="$(NO_COLOR=1 bash -c "source '$LIB/report.sh'; report_fail 'first'; report_fail 'second'; finish" 2>&1)"
expect_contains "$out" "second" "report_fail does not stop later assertions"

harness_finish

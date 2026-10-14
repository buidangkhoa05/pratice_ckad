#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

expect_eq "abc" "abc" "expect_eq matches equal strings"
expect_contains "hello world" "lo wo" "expect_contains finds a substring"

stub_setup
stub_out "stubbed output"
out="$(kubectl get pods)"; rc=$?
expect_eq "$out" "stubbed output" "stub kubectl prints STUB_OUT"
expect_rc "$rc" 0 "stub kubectl defaults to success"
expect_contains "$(stub_calls)" "get pods" "stub kubectl logs its argv"

stub_reset
stub_rc 1
kubectl get nope >/dev/null 2>&1; rc=$?
expect_rc "$rc" 1 "stub kubectl honors STUB_RC"

stub_reset
stub_rc_seq "1 1 0"
kubectl a >/dev/null 2>&1; r1=$?
kubectl b >/dev/null 2>&1; r2=$?
kubectl c >/dev/null 2>&1; r3=$?
kubectl d >/dev/null 2>&1; r4=$?
expect_eq "$r1$r2$r3$r4" "1100" "STUB_RC_SEQ consumes per call, last value repeats"

harness_finish

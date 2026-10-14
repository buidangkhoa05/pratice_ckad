#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"
LIB="$CKAD_TEST_ROOT/lib"

run_verify() { NO_COLOR=1 bash -c "source '$LIB/assert.sh'; $1" 2>&1; }

stub_setup

# --- namespace guard ---
stub_rc 1   # every kubectl call fails, including the namespace lookup
out="$(run_verify "ns ckad-9-9; assert_exists deployment/a; assert_exists deployment/b; finish")"
rc=$?
expect_rc "$rc" 1 "missing namespace fails the run"
expect_contains "$out" "ckad-9-9" "missing namespace is named"
# 0 passed of 1 total: the guard reported once, not once per assertion (0/2).
expect_contains "$out" "0/1" "missing namespace reports one failure, not one per assertion"
expect_contains "$out" "ckad start 9.9" "missing namespace suggests a pasteable command"

# --- assert_exists ---
stub_reset; stub_rc 0
out="$(run_verify "ns ckad-1-1; assert_exists pod/logger; finish")"; rc=$?
expect_rc "$rc" 0 "assert_exists passes when kubectl get succeeds"
expect_contains "$out" "pod/logger" "assert_exists names the resource"
expect_contains "$(stub_calls)" "-n ckad-1-1 get pod/logger" "assert_exists scopes kubectl to the namespace"

# --- assert_absent ---
stub_reset; stub_rc_seq "0 1"   # namespace present, then resource lookup fails
out="$(run_verify "ns ckad-1-1; assert_absent pod/gone; finish")"; rc=$?
expect_rc "$rc" 0 "assert_absent passes when the resource is not found"

stub_reset; stub_rc 0           # namespace present, resource also present
out="$(run_verify "ns ckad-1-1; assert_absent pod/here; finish")"; rc=$?
expect_rc "$rc" 1 "assert_absent fails when the resource exists"

# --- assert_jsonpath ---
stub_reset; stub_out "2"
out="$(run_verify "ns ckad-2-1; assert_jsonpath deploy/api '{.spec.replicas}' 2; finish")"; rc=$?
expect_rc "$rc" 0 "assert_jsonpath passes on an equal value"
expect_contains "$(stub_calls)" "jsonpath={.spec.replicas}" "assert_jsonpath passes the path to kubectl"

stub_reset; stub_out "3"
out="$(run_verify "ns ckad-2-1; assert_jsonpath deploy/api '{.spec.replicas}' 2; finish")"; rc=$?
expect_rc "$rc" 1 "assert_jsonpath fails on a different value"
expect_contains "$out" "3" "assert_jsonpath shows the actual value"

stub_reset; stub_out ""
out="$(run_verify "ns ckad-2-1; assert_jsonpath deploy/api '{.spec.replicas}' 2; finish")"; rc=$?
expect_rc "$rc" 1 "assert_jsonpath fails on an empty result"
expect_contains "$out" "<empty>" "empty jsonpath result is shown as <empty> rather than blank"

harness_finish

#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"
LIB="$CKAD_TEST_ROOT/lib"

run_verify() { NO_COLOR=1 bash -c "source '$LIB/assert.sh'; $1" 2>&1; }

stub_setup

# --- assert_pod_ready counts only Ready=True lines ---
stub_reset; stub_out "True
True"
out="$(run_verify "ns ckad-1-1; assert_pod_ready -l app=web --count 2; finish")"; rc=$?
expect_rc "$rc" 0 "assert_pod_ready passes when the Ready count matches"

stub_reset; stub_out "True
False"
out="$(run_verify "ns ckad-1-1; assert_pod_ready -l app=web --count 2; finish")"; rc=$?
expect_rc "$rc" 1 "assert_pod_ready fails when a pod is not Ready"
expect_contains "$out" "1 Ready" "assert_pod_ready reports how many were Ready"

stub_reset; stub_out "True"
out="$(run_verify "ns ckad-1-1; assert_pod_ready --pod logger; finish")"; rc=$?
expect_rc "$rc" 0 "assert_pod_ready accepts --pod for an unlabelled pod"
expect_contains "$(stub_calls)" "logger" "assert_pod_ready queries the named pod"

# --- assert_logs ---
stub_reset; stub_out "2026-01-01 app-heartbeat"
out="$(run_verify "ns ckad-1-1; assert_logs --pod logger -c sidecar --contains app-heartbeat; finish")"; rc=$?
expect_rc "$rc" 0 "assert_logs passes when the string is present"
expect_contains "$(stub_calls)" "-c sidecar" "assert_logs targets the named container"

stub_reset; stub_out "nothing useful"
out="$(run_verify "ns ckad-1-1; assert_logs --pod logger --contains app-heartbeat; finish")"; rc=$?
expect_rc "$rc" 1 "assert_logs fails when the string is missing"

# --- assert_exec ---
stub_reset; stub_out "mode=production"
out="$(run_verify "ns ckad-4-1; assert_exec --pod cfg --contains mode=production -- cat /etc/app/app.properties; finish")"; rc=$?
expect_rc "$rc" 0 "assert_exec passes when output contains the string"
expect_contains "$(stub_calls)" "cat /etc/app/app.properties" "assert_exec passes the command through"

# Absolute Unix paths must reach the container intact. Git Bash rewrites them
# into Windows paths unless MSYS2_ARG_CONV_EXCL is set for the exec call.
stub_reset; stub_out "mode=production"
out="$(run_verify "ns ckad-4-1; assert_exec --pod cfg -- cat /etc/app/app.properties; finish")"
expect_contains "$(stub_calls)" "cat /etc/app/app.properties" \
  "assert_exec does not let MSYS rewrite an absolute path argument"

stub_reset; stub_out "web-abc123"
out="$(run_verify "ns ckad-4-1; assert_exec -l app=cfg -- printenv DB_PASS; finish")"; rc=$?
expect_contains "$(stub_calls)" "exec web-abc123" "assert_exec resolves a selector to a pod name (kubectl exec rejects -l)"

stub_reset; stub_rc_seq "0 1"   # namespace ok, exec fails
out="$(run_verify "ns ckad-5-2; assert_exec --pod client --expect-fail -- wget -T2 api; finish")"; rc=$?
expect_rc "$rc" 0 "assert_exec --expect-fail passes when the command fails"

stub_reset; stub_rc 0
out="$(run_verify "ns ckad-5-2; assert_exec --pod client --expect-fail -- wget -T2 api; finish")"; rc=$?
expect_rc "$rc" 1 "assert_exec --expect-fail fails when the command succeeds"

# --- retry_until ---
# The namespace check consumes call 0; the first attempt then fails and the
# final attempt passes.
stub_reset; stub_out "True"; stub_rc_seq "0 1 1 0"
out="$(run_verify "ns ckad-2-1; RETRY_SLEEP=0 retry_until 10 assert_pod_ready --pod api; finish")"; rc=$?
expect_rc "$rc" 0 "retry_until eventually passes"
expect_contains "$out" "1/1" "retry_until reports one assertion, not one per attempt"

stub_reset; stub_out "False"; stub_rc 0
out="$(run_verify "ns ckad-2-1; RETRY_SLEEP=0 retry_until 2 assert_pod_ready --pod api; finish")"; rc=$?
expect_rc "$rc" 1 "retry_until gives up and reports the failure once"
expect_contains "$out" "0/1" "retry_until timeout reports a single failure"

# CKAD_RETRY_MAX caps the wait so selftest's empty-namespace phase is quick.
stub_reset; stub_out "False"; stub_rc 0
start=$SECONDS
run_verify "ns ckad-2-1; CKAD_RETRY_MAX=1 RETRY_SLEEP=1 retry_until 300 assert_pod_ready --pod api; finish" >/dev/null
elapsed=$(( SECONDS - start ))
if (( elapsed < 10 )); then
  expect_eq "capped" "capped" "CKAD_RETRY_MAX caps a long retry budget"
else
  expect_eq "waited ${elapsed}s" "capped" "CKAD_RETRY_MAX caps a long retry budget"
fi

harness_finish

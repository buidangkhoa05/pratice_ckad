# CKAD Practice Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local CKAD drill repository where each exercise is self-grading against a real multi-node Kubernetes cluster.

**Architecture:** A `bin/ckad` bash CLI discovers drills on the filesystem, runs each drill's `setup.sh`/`verify.sh` in a drill-private namespace, and records results in a flat state file. Verification logic lives in `lib/assert.sh`, a library of assertion primitives that read live cluster state only. Unit tests run with no cluster by putting a stub `kubectl` on `PATH`; drill correctness is validated by `bin/selftest.sh` against a live `kind` cluster.

**Tech Stack:** bash 5.2 (Git Bash), kubectl, kind 0.33.0, Calico CNI, ingress-nginx, metrics-server.

## Global Constraints

- **Shell:** bash via Git Bash. Every script starts `#!/usr/bin/env bash`.
- **Line endings:** `.gitattributes` must contain `*.sh text eol=lf`. CRLF makes every shebang fail under Git Bash with a misleading `bad interpreter` error.
- **No `jq`.** It is not installed and is not a prerequisite. State is a flat space-separated file, not JSON. This is a deliberate deviation from the spec's `.ckad-state.json`; nothing but `bin/ckad` reads it, and escaping JSON correctly in pure bash is a liability for zero gain.
- **No `helm` or standalone `kustomize` prerequisite.** Drill 2.2 uses `kubectl apply -k`, which is built into kubectl. This deviates from the spec's prerequisite list, which over-specified.
- **Scripts never use `set -e`.** Assertions must keep running after a failure so one verify pass reports every unmet requirement. Use `set -uo pipefail` only.
- **Assertions read live cluster state, never the user's YAML files.** Solving a drill imperatively with `kubectl create` must pass identically to an applied manifest.
- **Namespace per drill:** `ckad-<domain>-<drill>` (drill `3.2` → `ckad-3-2`).
- **Drill id format:** `<domain>.<drill>`, e.g. `3.2`. Directory names are `drills/<domain>-<slug>/<nn>-<slug>/` with `nn` zero-padded.
- **Pinned images only** (no `:latest`): `nginx:1.27-alpine`, `nginxinc/nginx-unprivileged:1.27-alpine`, `busybox:1.36`, `curlimages/curl:8.10.1`.
- **Curriculum weights** for `ckad score`: domain 1 = 20, 2 = 20, 3 = 15, 4 = 25, 5 = 20.
- **Env overrides for testability:** `CKAD_ROOT`, `DRILLS_ROOT`, `CKAD_STATE`, `SCRATCH_ROOT` override their defaults everywhere. Unit tests depend on this.
- **CNI is Calico, not kindnet.** `kind`'s default CNI does not enforce NetworkPolicy, which would make drill 5.2 silently pass with a policy that blocks nothing. `kind-config.yaml` sets `disableDefaultCNI: true` and `bootstrap.sh` installs Calico. This is an addition to the spec, which did not name a CNI.

## File Structure

| File | Responsibility |
|---|---|
| `.gitattributes` | Force LF on `*.sh` |
| `.gitignore` | `scratch/`, `.ckad-state`, `*.local.yaml` |
| `README.md` | Quickstart, prerequisites, exam-day cheatsheet |
| `lib/report.sh` | Output formatting, pass/fail counters, `finish` exit code. No kubectl knowledge. |
| `lib/assert.sh` | Assertion primitives. Sources `report.sh`. The only file drills source. |
| `lib/drills.sh` | Drill discovery: id ↔ path, listing, title/target-time parsing, namespace naming. No kubectl knowledge. |
| `lib/state.sh` | Read/write the flat results file; per-domain scoring. |
| `bin/ckad` | CLI dispatch. Sources `drills.sh` and `state.sh`. |
| `bin/setup-shell.sh` | Sourced per session: aliases, `$do`/`$now`, completion, vim YAML config |
| `bin/selftest.sh` | Validates drills: solution makes verify pass, empty namespace makes it fail |
| `cluster/kind-config.yaml` | 1 control-plane + 2 labelled workers, 80/443 port maps, default CNI disabled |
| `cluster/bootstrap.sh` | Idempotent cluster creation + Calico, ingress-nginx, metrics-server |
| `tests/run.sh` | Test runner: executes every `tests/test_*.sh`, aggregates exit codes |
| `tests/harness.sh` | `expect_*` helpers, stub `PATH` setup, fixture drill tree builder |
| `tests/stubs/kubectl` | Fake kubectl driven by env vars; logs its argv for call assertions |
| `tests/test_*.sh` | One file per lib unit |
| `drills/<domain>/<nn>-<slug>/` | `task.md`, optional `setup.sh`, `verify.sh`, `.solution/` |

`lib/` is split four ways because each piece has a different dependency: `report.sh` depends on nothing, `drills.sh` and `state.sh` depend on the filesystem, and only `assert.sh` depends on a cluster. That split is what makes unit tests possible without a cluster.

---

### Task 1: Repo skeleton and test harness

Nothing else can be tested until a test runner exists. This task's deliverable is a runner that proves itself green on a fixture test.

**Files:**
- Create: `.gitattributes`, `.gitignore`, `tests/run.sh`, `tests/harness.sh`, `tests/stubs/kubectl`, `tests/test_harness.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `expect_eq <actual> <expected> <desc>`, `expect_contains <haystack> <needle> <desc>`, `expect_rc <actual_rc> <expected_rc> <desc>`, `harness_finish` (exits 0 iff all expectations passed), `stub_setup` (puts stub kubectl on PATH, sets `$STUB_LOG`/`$STUB_COUNT`), `stub_out <text>`, `stub_rc <code>`, `stub_rc_seq "<codes>"`, `stub_calls` (echoes logged kubectl argv lines), `CKAD_TEST_ROOT` (repo root).

- [ ] **Step 1: Create `.gitattributes` and `.gitignore`**

`.gitattributes`:
```
*.sh text eol=lf
*.yaml text eol=lf
bin/ckad text eol=lf
tests/stubs/kubectl text eol=lf
```

`.gitignore`:
```
scratch/
.ckad-state
*.local.yaml
kubeconfig
```

- [ ] **Step 2: Write the stub kubectl**

`tests/stubs/kubectl`:
```bash
#!/usr/bin/env bash
# Fake kubectl for unit tests. Behavior is driven entirely by env vars:
#   STUB_OUT     text printed on stdout for every call
#   STUB_RC      exit code for every call (default 0)
#   STUB_RC_SEQ  space-separated exit codes consumed one per call; the last
#                value repeats once exhausted. Used to test retry_until.
#   STUB_LOG     file this appends its full argv to, one line per call
#   STUB_COUNT   file holding the call counter for STUB_RC_SEQ
[[ -n "${STUB_LOG:-}" ]] && printf '%s\n' "$*" >> "$STUB_LOG"

n=0
if [[ -n "${STUB_COUNT:-}" ]]; then
  n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
  printf '%s' "$(( n + 1 ))" > "$STUB_COUNT"
fi

[[ -n "${STUB_OUT:-}" ]] && printf '%s\n' "$STUB_OUT"

if [[ -n "${STUB_RC_SEQ:-}" ]]; then
  read -r -a codes <<< "$STUB_RC_SEQ"
  idx=$n
  (( idx >= ${#codes[@]} )) && idx=$(( ${#codes[@]} - 1 ))
  exit "${codes[$idx]}"
fi

exit "${STUB_RC:-0}"
```

- [ ] **Step 3: Write the harness**

`tests/harness.sh`:
```bash
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
```

- [ ] **Step 4: Write the runner**

`tests/run.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failed=0
for f in "$ROOT"/tests/test_*.sh; do
  printf '\n== %s ==\n' "$(basename "$f")"
  bash "$f" || failed=1
done
printf '\n'
if (( failed == 0 )); then printf 'ALL TESTS PASSED\n'; exit 0; fi
printf 'TEST FAILURES\n'; exit 1
```

- [ ] **Step 5: Write the harness's own test**

`tests/test_harness.sh`:
```bash
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
```

- [ ] **Step 6: Run the tests**

Run: `bash tests/run.sh`
Expected: PASS — `test_harness.sh` reports `8 passed, 0 failed`, runner prints `ALL TESTS PASSED`.

If the shebang fails with `bad interpreter`, `.gitattributes` was added after the files were committed; run `git add --renormalize .`.

- [ ] **Step 7: Commit**

```bash
git add .gitattributes .gitignore tests
git commit -m "test: add bash test harness with stub kubectl"
```

---

### Task 2: `lib/report.sh` — output and exit code

**Files:**
- Create: `lib/report.sh`
- Test: `tests/test_report.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `report_pass <desc>`, `report_fail <desc> [expected] [actual]`, `finish` (prints summary, **exits** 0 iff at least one assertion ran and none failed), counters `REPORT_PASS` / `REPORT_FAIL`.

`finish` exits rather than returns so a drill's `verify.sh` cannot accidentally swallow the result. A verify script with zero assertions must FAIL — that catches an empty or mis-sourced script that would otherwise look green.

- [ ] **Step 1: Write the failing test**

`tests/test_report.sh`:
```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_report.sh`
Expected: FAIL — every expectation fails because `lib/report.sh` does not exist.

- [ ] **Step 3: Implement `lib/report.sh`**

```bash
# lib/report.sh — output formatting and pass/fail accounting.
# Sourced by lib/assert.sh. Knows nothing about kubectl.

REPORT_PASS=0
REPORT_FAIL=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _C_OK=$'\033[32m'; _C_BAD=$'\033[31m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_BAD=''; _C_DIM=''; _C_OFF=''
fi

report_pass() { # <desc>
  REPORT_PASS=$(( REPORT_PASS + 1 ))
  printf '%s*%s %s\n' "$_C_OK" "$_C_OFF" "$1"
}

report_fail() { # <desc> [expected] [actual]
  REPORT_FAIL=$(( REPORT_FAIL + 1 ))
  printf '%sx%s %s\n' "$_C_BAD" "$_C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '  %sexpected:%s %s\n' "$_C_DIM" "$_C_OFF" "$2"
  [[ -n "${3:-}" ]] && printf '  %sactual:  %s %s\n' "$_C_DIM" "$_C_OFF" "$3"
  return 0
}

finish() {
  local total=$(( REPORT_PASS + REPORT_FAIL ))
  printf '\n'
  if (( REPORT_FAIL == 0 && total > 0 )); then
    printf '%sPASS%s  %d/%d requirements met\n' "$_C_OK" "$_C_OFF" "$REPORT_PASS" "$total"
    exit 0
  fi
  if (( total == 0 )); then
    printf '%sFAIL%s  no assertions ran - verify.sh is empty or failed to source lib/assert.sh\n' \
      "$_C_BAD" "$_C_OFF"
    exit 1
  fi
  printf '%sFAIL%s  %d/%d requirements met\n' "$_C_BAD" "$_C_OFF" "$REPORT_PASS" "$total"
  exit 1
}
```

Replace the `*` and `x` glyphs with `✓` and `✗` only after confirming your terminal renders them; Git Bash on Windows with a non-UTF-8 code page will mangle them, and a mangled pass marker is worse than an ASCII one.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_report.sh`
Expected: PASS — `13 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/report.sh tests/test_report.sh
git commit -m "feat: add report.sh pass/fail accounting for verify scripts"
```

---

### Task 3: `lib/assert.sh` — namespace guard and static assertions

**Files:**
- Create: `lib/assert.sh`
- Test: `tests/test_assert_static.sh`

**Interfaces:**
- Consumes: `report_pass`, `report_fail`, `finish`, `REPORT_PASS`, `REPORT_FAIL` from Task 2.
- Produces: `ns <namespace>`, `_k <args...>` (kubectl scoped to the drill namespace), `_ns_ok` (guard), `assert_exists <resource>`, `assert_absent <resource>`, `assert_jsonpath <resource> <jsonpath> <expected>`, globals `ASSERT_NS` and `_NS_CHECKED`.

The namespace guard is why `_NS_CHECKED` is tri-state: `0` unchecked, `1` confirmed present, `2` confirmed missing and already reported. Without it, a drill the user never started reports twelve confusing failures instead of one actionable line.

- [ ] **Step 1: Write the failing test**

`tests/test_assert_static.sh`:
```bash
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
expect_contains "$out" "1/1" "missing namespace reports one failure, not one per assertion"
expect_contains "$out" "ckad start" "missing namespace suggests the fix"

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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_assert_static.sh`
Expected: FAIL — `lib/assert.sh` does not exist, so every `run_verify` produces a sourcing error.

- [ ] **Step 3: Implement `lib/assert.sh`**

```bash
# lib/assert.sh - assertion primitives for drill verify scripts.
#
# Usage inside drills/<domain>/<nn>-<slug>/verify.sh:
#
#   #!/usr/bin/env bash
#   source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
#   ns ckad-3-2
#   assert_exists deployment/web
#   finish
#
# Every assertion reads live cluster state. None read the user's YAML files,
# so solving a drill imperatively passes exactly as an applied manifest does.
# Note the absence of `set -e`: assertions must keep running after a failure
# so one pass reports every unmet requirement.

set -uo pipefail

_ASSERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ASSERT_DIR/report.sh"

ASSERT_NS=""
_NS_CHECKED=0   # 0 unchecked, 1 present, 2 missing and already reported

ns() { ASSERT_NS="$1"; }

# kubectl scoped to the drill namespace. Leading underscore so it cannot
# collide with the user's own `k` alias from bin/setup-shell.sh.
_k() { kubectl -n "$ASSERT_NS" "$@"; }

# Guard called first by every assertion. Reports a missing namespace once.
_ns_ok() {
  (( _NS_CHECKED == 1 )) && return 0
  (( _NS_CHECKED == 2 )) && return 1
  if [[ -z "$ASSERT_NS" ]]; then
    report_fail "namespace declared" "ns <name> before any assertion" "none set"
    _NS_CHECKED=2; return 1
  fi
  if kubectl get namespace "$ASSERT_NS" >/dev/null 2>&1; then
    _NS_CHECKED=1; return 0
  fi
  report_fail "namespace $ASSERT_NS exists" \
              "namespace present" \
              "not found - run: ckad start ${ASSERT_NS#ckad-}"
  _NS_CHECKED=2; return 1
}

assert_exists() { # <resource>
  local res="$1"
  _ns_ok || return 1
  if _k get "$res" >/dev/null 2>&1; then
    report_pass "$res exists"
  else
    report_fail "$res exists" "present in $ASSERT_NS" "not found"
  fi
}

assert_absent() { # <resource>
  local res="$1"
  _ns_ok || return 1
  if _k get "$res" >/dev/null 2>&1; then
    report_fail "$res is absent" "not present in $ASSERT_NS" "still exists"
  else
    report_pass "$res is absent"
  fi
}

assert_jsonpath() { # <resource> <jsonpath> <expected>
  local res="$1" path="$2" want="$3" got
  _ns_ok || return 1
  local desc="$res $path = $want"
  if ! got="$(_k get "$res" -o jsonpath="$path" 2>&1)"; then
    report_fail "$desc" "$want" "kubectl error: $got"
    return 1
  fi
  if [[ "$got" == "$want" ]]; then
    report_pass "$desc"
  else
    report_fail "$desc" "$want" "${got:-<empty>}"
  fi
}
```

Two notes for whoever writes drills against this:

- `kubectl` renders an empty JSON object as `map[]` in jsonpath output. Asserting that a volume is an `emptyDir` therefore expects the literal string `map[]`, not `{}`.
- Dots inside annotation keys need escaping: `'{.metadata.annotations.deployment\.kubernetes\.io/revision}'`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_assert_static.sh`
Expected: PASS — `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add lib/assert.sh tests/test_assert_static.sh
git commit -m "feat: add assert.sh namespace guard and static assertions"
```

---

### Task 4: `lib/assert.sh` — runtime assertions and `retry_until`

**Files:**
- Modify: `lib/assert.sh` (append)
- Test: `tests/test_assert_runtime.sh`

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: `assert_pod_ready [-l <sel> | --pod <name>] [--count <n>]`, `assert_logs [-l <sel> | --pod <name>] [-c <container>] --contains <str>`, `assert_exec [-l <sel> | --pod <name>] [-c <container>] [--contains <str>] [--expect-fail] -- <cmd...>`, `assert_http <url> [--status <n>]`, `retry_until <seconds> <assertion> [args...]`, `RETRY_SLEEP`.

`retry_until` runs the assertion in-process rather than in a subshell so the counters mutate correctly. It saves and restores them around the silent attempts, then runs the assertion once more for real. That costs one extra kubectl call and keeps retry noise out of the drill's output.

- [ ] **Step 1: Write the failing test**

`tests/test_assert_runtime.sh`:
```bash
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
expect_contains "$out" "1/1" "retry_until timeout reports a single failure"

harness_finish
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_assert_runtime.sh`
Expected: FAIL — `assert_pod_ready: command not found` for every case.

- [ ] **Step 3: Append the runtime assertions to `lib/assert.sh`**

```bash
# --- runtime assertions ----------------------------------------------------
# These query observed state (Ready conditions, logs, in-container commands,
# in-cluster HTTP) rather than spec fields.

RETRY_SLEEP="${RETRY_SLEEP:-2}"

# Resolves [-l sel | --pod name] into kubectl target args.
# Sets _TARGET_ARGS (array) and _TARGET_DESC. Returns 1 if neither was given.
_resolve_target() { # <sel> <pod>
  local sel="$1" pod="$2"
  _TARGET_ARGS=(); _TARGET_DESC=""
  if [[ -n "$pod" ]]; then
    _TARGET_ARGS=("$pod"); _TARGET_DESC="pod/$pod"; return 0
  fi
  if [[ -n "$sel" ]]; then
    _TARGET_ARGS=(-l "$sel"); _TARGET_DESC="pods matching $sel"; return 0
  fi
  return 1
}

assert_pod_ready() { # [-l <sel> | --pod <name>] [--count <n>]
  local sel="" pod="" count=1 got ready
  while (( $# )); do
    case "$1" in
      -l|--selector) sel="$2"; shift 2 ;;
      --pod)         pod="$2"; shift 2 ;;
      --count)       count="$2"; shift 2 ;;
      *) report_fail "assert_pod_ready usage" "[-l sel | --pod name] [--count n]" "unexpected: $1"; return 1 ;;
    esac
  done
  _ns_ok || return 1
  _resolve_target "$sel" "$pod" || {
    report_fail "assert_pod_ready usage" "-l sel or --pod name" "neither given"; return 1; }
  local desc="$count of $_TARGET_DESC Ready"
  local jp='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}'
  [[ -n "$pod" ]] && jp='{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}'
  if ! got="$(_k get pods "${_TARGET_ARGS[@]}" -o jsonpath="$jp" 2>&1)"; then
    report_fail "$desc" "$count Ready" "kubectl error: $got"; return 1
  fi
  ready="$(printf '%s\n' "$got" | grep -c '^True$')"
  if (( ready == count )); then
    report_pass "$desc"
  else
    report_fail "$desc" "$count Ready" "$ready Ready"
  fi
}

assert_logs() { # [-l <sel> | --pod <name>] [-c <container>] --contains <str>
  local sel="" pod="" container="" want="" out
  while (( $# )); do
    case "$1" in
      -l|--selector)  sel="$2"; shift 2 ;;
      --pod)          pod="$2"; shift 2 ;;
      -c|--container) container="$2"; shift 2 ;;
      --contains)     want="$2"; shift 2 ;;
      *) report_fail "assert_logs usage" "[-l sel | --pod name] [-c container] --contains str" "unexpected: $1"; return 1 ;;
    esac
  done
  _ns_ok || return 1
  _resolve_target "$sel" "$pod" || {
    report_fail "assert_logs usage" "-l sel or --pod name" "neither given"; return 1; }
  local -a cargs=(); [[ -n "$container" ]] && cargs=(-c "$container")
  local desc="logs of $_TARGET_DESC contain \"$want\""
  if ! out="$(_k logs "${_TARGET_ARGS[@]}" "${cargs[@]}" --tail=-1 2>&1)"; then
    report_fail "$desc" "log line containing \"$want\"" "kubectl error: $out"; return 1
  fi
  if printf '%s' "$out" | grep -qF -- "$want"; then
    report_pass "$desc"
  else
    report_fail "$desc" "log line containing \"$want\"" "${out:-<no log output>}"
  fi
}

assert_exec() { # [-l sel | --pod name] [-c container] [--contains str] [--expect-fail] -- <cmd...>
  local sel="" pod="" container="" want="" expect_fail=0 out rc
  while (( $# )); do
    case "$1" in
      -l|--selector)  sel="$2"; shift 2 ;;
      --pod)          pod="$2"; shift 2 ;;
      -c|--container) container="$2"; shift 2 ;;
      --contains)     want="$2"; shift 2 ;;
      --expect-fail)  expect_fail=1; shift ;;
      --)             shift; break ;;
      *) report_fail "assert_exec usage" "... -- <command>" "unexpected: $1"; return 1 ;;
    esac
  done
  _ns_ok || return 1

  # kubectl exec takes a pod name and does NOT accept -l, unlike kubectl logs.
  # A selector therefore has to be resolved to a concrete pod first.
  local target_pod="$pod"
  if [[ -z "$target_pod" && -n "$sel" ]]; then
    target_pod="$(_k get pods -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [[ -n "$target_pod" ]] || {
      report_fail "selector $sel matches a pod" "at least one pod" "none found"; return 1; }
  fi
  [[ -n "$target_pod" ]] || {
    report_fail "assert_exec usage" "-l sel or --pod name" "neither given"; return 1; }

  local -a cargs=(); [[ -n "$container" ]] && cargs=(-c "$container")
  local desc
  if (( expect_fail )); then desc="in pod/$target_pod: [$*] fails"
  elif [[ -n "$want" ]]; then desc="in pod/$target_pod: [$*] outputs \"$want\""
  else desc="in pod/$target_pod: [$*] succeeds"; fi

  out="$(_k exec "$target_pod" "${cargs[@]}" -- "$@" 2>&1)"; rc=$?

  if (( expect_fail )); then
    if (( rc != 0 )); then report_pass "$desc"
    else report_fail "$desc" "non-zero exit" "exit 0, output: ${out:-<none>}"; fi
    return 0
  fi
  if (( rc != 0 )); then
    report_fail "$desc" "exit 0" "exit $rc: ${out:-<none>}"; return 1
  fi
  if [[ -n "$want" ]] && ! printf '%s' "$out" | grep -qF -- "$want"; then
    report_fail "$desc" "output containing \"$want\"" "${out:-<none>}"; return 1
  fi
  report_pass "$desc"
}

# Curls a URL from a throwaway in-cluster pod. Running curl from the host
# cannot reach a ClusterIP and is not governed by a NetworkPolicy, so this is
# the only truthful way to test Services and policies.
assert_http() { # <url> [--status <n>]
  local url="$1"; shift
  local want_status=200 got
  while (( $# )); do
    case "$1" in
      --status) want_status="$2"; shift 2 ;;
      *) report_fail "assert_http usage" "<url> [--status n]" "unexpected: $1"; return 1 ;;
    esac
  done
  _ns_ok || return 1
  local desc="GET $url returns $want_status"
  got="$(_k run "probe-$RANDOM" --rm -i --restart=Never --quiet \
            --image=curlimages/curl:8.10.1 --command -- \
            curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null \
          | tr -d '[:space:]')"
  if [[ "$got" == "$want_status" ]]; then
    report_pass "$desc"
  else
    report_fail "$desc" "$want_status" "${got:-no response}"
  fi
}

# Retries an assertion silently until it passes or the timeout expires, then
# runs it once more for real so the output shows a single result.
retry_until() { # <seconds> <assertion> [args...]
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  local saved_pass=$REPORT_PASS saved_fail=$REPORT_FAIL
  while (( SECONDS < deadline )); do
    REPORT_PASS=0; REPORT_FAIL=0
    "$@" >/dev/null 2>&1
    if (( REPORT_FAIL == 0 && REPORT_PASS > 0 )); then break; fi
    (( RETRY_SLEEP > 0 )) && sleep "$RETRY_SLEEP"
  done
  REPORT_PASS=$saved_pass; REPORT_FAIL=$saved_fail
  "$@"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_assert_runtime.sh`
Expected: PASS — `15 passed, 0 failed`.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run.sh`
Expected: PASS — `ALL TESTS PASSED`, four test files green.

- [ ] **Step 6: Commit**

```bash
git add lib/assert.sh tests/test_assert_runtime.sh
git commit -m "feat: add runtime assertions and retry_until to assert.sh"
```

---

### Task 5: `lib/drills.sh` — drill discovery

**Files:**
- Create: `lib/drills.sh`
- Modify: `tests/harness.sh` (append the fixture tree builder)
- Test: `tests/test_drills.sh`

**Interfaces:**
- Consumes: nothing (no kubectl, no report).
- Produces: `DRILLS_ROOT`, `drill_domains` (one domain directory path per line), `drill_ids` (every id, ordered), `drill_path <id>` (echoes path; returns 1 if unknown, 2 if the id is malformed), `drill_ns <id>`, `drill_domain_of <id>`, `drill_title <path>`, `drill_target <path>`.
- Produces in harness: `make_drill_tree <dir>` — builds a two-domain fixture tree and echoes the root.

Keeping this file free of kubectl is what lets `ckad list` and `ckad score` be unit-tested with no cluster at all.

- [ ] **Step 1: Append the fixture builder to `tests/harness.sh`**

```bash
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
```

- [ ] **Step 2: Write the failing test**

`tests/test_drills.sh`:
```bash
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
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `bash tests/test_drills.sh`
Expected: FAIL — `lib/drills.sh` does not exist; sourcing it aborts the script.

- [ ] **Step 4: Implement `lib/drills.sh`**

```bash
# lib/drills.sh - drill discovery and metadata.
# Pure filesystem logic: no kubectl, no reporting. That is what lets
# `ckad list` and `ckad score` be unit-tested without a cluster.

_DRILLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKAD_ROOT="${CKAD_ROOT:-$(cd "$_DRILLS_LIB_DIR/.." && pwd)}"
DRILLS_ROOT="${DRILLS_ROOT:-$CKAD_ROOT/drills}"

# Domain directories, sorted, one per line.
drill_domains() {
  local d
  for d in "$DRILLS_ROOT"/[0-9]-*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
}

# Every drill id, ordered by domain then drill number.
drill_ids() {
  local dom drl dnum nnum
  while IFS= read -r dom; do
    dnum="$(basename "$dom")"; dnum="${dnum%%-*}"
    for drl in "$dom"/[0-9][0-9]-*; do
      [[ -d "$drl" ]] || continue
      nnum="$(basename "$drl")"; nnum="${nnum%%-*}"
      printf '%s.%s\n' "$dnum" "$((10#$nnum))"
    done
  done < <(drill_domains)
}

# Echoes the drill directory. Returns 2 if the id is malformed, 1 if unknown.
drill_path() { # <id>
  local id="$1" d n dom drl
  [[ "$id" =~ ^([0-9]+)\.([0-9]+)$ ]] || return 2
  d="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  dom="$(compgen -G "$DRILLS_ROOT/${d}-*" 2>/dev/null | head -1)" || return 1
  [[ -n "$dom" ]] || return 1
  drl="$(compgen -G "$dom/$(printf '%02d' "$n")-*" 2>/dev/null | head -1)" || return 1
  [[ -n "$drl" ]] || return 1
  printf '%s\n' "$drl"
}

drill_ns()        { printf 'ckad-%s\n' "${1//./-}"; }   # 3.2 -> ckad-3-2
drill_domain_of() { printf '%s\n' "${1%%.*}"; }

# First markdown H1 in task.md.
drill_title() { # <drill-path>
  local t="$1/task.md"
  [[ -f "$t" ]] || { printf '(no task.md)\n'; return 0; }
  sed -n 's/^# \(.*\)$/\1/p' "$t" | head -1
}

# The "**Target time:** 8 min" line, or "-" when absent.
drill_target() { # <drill-path>
  local t="$1/task.md" v
  [[ -f "$t" ]] || { printf -- '-\n'; return 0; }
  v="$(sed -n 's/^\*\*Target time:\*\* *\(.*\)$/\1/p' "$t" | head -1)"
  printf '%s\n' "${v:--}"
}
```

`$((10#$nnum))` strips the zero padding in base 10 — without the `10#`, bash reads `08` as an invalid octal literal and the loop dies on the eighth drill in a domain.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test_drills.sh`
Expected: PASS — `12 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add lib/drills.sh tests/harness.sh tests/test_drills.sh
git commit -m "feat: add drill discovery and metadata parsing"
```

---

### Task 6: `lib/state.sh` — results and scoring

**Files:**
- Create: `lib/state.sh`
- Test: `tests/test_state.sh`

**Interfaces:**
- Consumes: `drill_ids`, `drill_domain_of` from Task 5.
- Produces: `CKAD_STATE`, `state_get <id>` (echoes `<attempts> <passed> <best_time>`, defaulting to `0 0 0`), `state_record <id> <passed 0|1> <elapsed_seconds>`, `state_attempts <id>`, `state_passed <id>` (rc 0 if ever passed), `state_domain_counts <domain>` (echoes `<passed> <total>`), `CKAD_WEIGHTS` (associative array of domain → exam weight).

File format, one line per attempted drill: `<id> <attempts> <passed:0|1> <best_time_seconds>`. Space-separated rather than JSON because `jq` is not installed and nothing outside `bin/ckad` reads this file.

`best_time` only updates on a passing attempt — a fast failure is not a record.

- [ ] **Step 1: Write the failing test**

`tests/test_state.sh`:
```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_state.sh`
Expected: FAIL — `lib/state.sh` does not exist.

- [ ] **Step 3: Implement `lib/state.sh`**

```bash
# lib/state.sh - drill results and exam-weighted scoring.
#
# Format, one line per attempted drill:
#   <id> <attempts> <passed:0|1> <best_time_seconds>
#
# Space-separated rather than JSON: jq is not installed, and nothing outside
# bin/ckad reads this file.

_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKAD_ROOT="${CKAD_ROOT:-$(cd "$_STATE_LIB_DIR/.." && pwd)}"
CKAD_STATE="${CKAD_STATE:-$CKAD_ROOT/.ckad-state}"

declare -A CKAD_WEIGHTS=( [1]=20 [2]=20 [3]=15 [4]=25 [5]=20 )

# Echoes "<attempts> <passed> <best_time>"; "0 0 0" when the drill is unknown.
state_get() { # <id>
  local id="$1" line
  if [[ -f "$CKAD_STATE" ]]; then
    line="$(grep -E "^${id//./\\.} " "$CKAD_STATE" | head -1)"
    if [[ -n "$line" ]]; then
      printf '%s\n' "${line#* }"
      return 0
    fi
  fi
  printf '0 0 0\n'
}

state_attempts() { # <id>
  local f; read -r f _ _ <<< "$(state_get "$1")"; printf '%s\n' "$f"
}

# Returns 0 if the drill has ever passed.
state_passed() { # <id>
  local _a p _b; read -r _a p _b <<< "$(state_get "$1")"
  [[ "$p" == "1" ]]
}

state_record() { # <id> <passed 0|1> <elapsed_seconds>
  local id="$1" passed="$2" elapsed="$3"
  local attempts prev_passed best
  read -r attempts prev_passed best <<< "$(state_get "$id")"
  attempts=$(( attempts + 1 ))
  (( passed == 1 )) && prev_passed=1
  if (( passed == 1 )); then
    if (( best == 0 )) || (( elapsed < best )); then best="$elapsed"; fi
  fi
  touch "$CKAD_STATE"
  local tmp="$CKAD_STATE.tmp"
  grep -vE "^${id//./\\.} " "$CKAD_STATE" > "$tmp" 2>/dev/null || :
  printf '%s %s %s %s\n' "$id" "$attempts" "$prev_passed" "$best" >> "$tmp"
  sort -V "$tmp" -o "$CKAD_STATE"
  rm -f "$tmp"
}

# Echoes "<passed> <total>" for one domain.
state_domain_counts() { # <domain>
  local dom="$1" id passed=0 total=0
  while IFS= read -r id; do
    [[ "$(drill_domain_of "$id")" == "$dom" ]] || continue
    total=$(( total + 1 ))
    state_passed "$id" && passed=$(( passed + 1 ))
  done < <(drill_ids)
  printf '%s %s\n' "$passed" "$total"
}
```

`sort -V` keeps `1.10` after `1.9` in the file; a plain lexical sort would not.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_state.sh`
Expected: PASS — `14 passed, 0 failed`.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run.sh`
Expected: PASS — `ALL TESTS PASSED`, six test files green.

- [ ] **Step 6: Commit**

```bash
git add lib/state.sh tests/test_state.sh
git commit -m "feat: add drill results tracking and weighted scoring"
```

---

### Task 7: `bin/ckad` — dispatch, `list`, `start`

**Files:**
- Create: `bin/ckad`
- Test: `tests/test_ckad_list_start.sh`

**Interfaces:**
- Consumes: all of `lib/drills.sh` (Task 5) and `lib/state.sh` (Task 6).
- Produces: the `ckad` executable with `list` and `start`; internal helpers `_resolve <id>` (echoes the drill path or dies listing valid ids), `_die <msg>`, `SCRATCH_ROOT` (defaults to `$CKAD_ROOT/scratch`, overridable for tests — add it to the env-override list in Global Constraints).
- Produces in the test file: `fixture_script <path> <exit-code>` — writes an executable stub `verify.sh`/`setup.sh`.

`start` creates the namespace itself rather than leaving it to `setup.sh`, so a drill without a `setup.sh` still gets an isolated namespace. Namespace creation is idempotent so re-running `start` after a crash is safe.

- [ ] **Step 1: Write the failing test**

`tests/test_ckad_list_start.sh`:
```bash
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
stub_reset
out="$(ckad start 1.1)"; rc=$?
expect_rc "$rc" 0 "start succeeds"
expect_contains "$out" "Sidecar sharing an emptyDir" "start prints the task"
expect_contains "$(stub_calls)" "create namespace ckad-1-1" "start creates the drill namespace"
expect_eq "$(test -f "$TMP/scratch/1.1/.started" && echo yes)" "yes" "start records a start timestamp"
expect_eq "$(test -d "$TMP/scratch/1.1" && echo yes)" "yes" "start creates a scratch directory"

# --- start runs setup.sh when present, with NS exported ---
stub_reset
printf '#!/usr/bin/env bash\nprintf "%%s" "$NS" > "%s/setup-ran"\n' "$TMP" \
  > "$DRILLS/3-observability/01-broken-probe/setup.sh"
chmod +x "$DRILLS/3-observability/01-broken-probe/setup.sh"
ckad start 3.1 >/dev/null
expect_eq "$(cat "$TMP/setup-ran" 2>/dev/null)" "ckad-3-1" "start runs setup.sh with NS set to the drill namespace"

harness_finish
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_ckad_list_start.sh`
Expected: FAIL — `bin/ckad` does not exist, so every invocation reports no such file.

- [ ] **Step 3: Implement `bin/ckad`**

```bash
#!/usr/bin/env bash
# ckad - drive CKAD practice drills.
#
#   ckad list [domain]   ckad start <id>     ckad verify <id>
#   ckad solution <id>   ckad reset [<id>|--all]   ckad score

set -uo pipefail

CKAD_ROOT="${CKAD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CKAD_ROOT
source "$CKAD_ROOT/lib/drills.sh"
source "$CKAD_ROOT/lib/state.sh"
SCRATCH_ROOT="${SCRATCH_ROOT:-$CKAD_ROOT/scratch}"

_die() { printf 'ckad: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: ckad <command> [args]

  list [domain]        list drills, newest result per drill
  start <id>           print the task, create its namespace, start the timer
  verify <id>          check your work against the live cluster
  solution <id>        show the reference answer (requires one verify attempt)
  reset [<id>|--all]   delete the drill namespace, or rebuild the cluster
  score                per-domain pass rate, weighted like the exam

ids look like 3.2 (domain 3, drill 2)
EOF
}

# Echoes the drill path, or dies listing the valid ids.
_resolve() { # <id>
  local p rc
  p="$(drill_path "$1")"; rc=$?
  if (( rc != 0 )); then
    printf 'ckad: no drill %s\n\nvalid ids:\n' "$1" >&2
    drill_ids | sed 's/^/  /' >&2
    exit 1
  fi
  printf '%s\n' "$p"
}

cmd_list() { # [domain]
  local filter="${1:-}" id path last attempts passed best
  printf '%-6s %-44s %-8s %s\n' "ID" "TITLE" "TARGET" "LAST"
  while IFS= read -r id; do
    [[ -n "$filter" && "$(drill_domain_of "$id")" != "$filter" ]] && continue
    path="$(drill_path "$id")" || continue
    read -r attempts passed best <<< "$(state_get "$id")"
    if (( attempts == 0 )); then last="-"
    elif (( passed == 1 )); then last="pass (${best}s, ${attempts} tries)"
    else last="fail (${attempts} tries)"; fi
    printf '%-6s %-44s %-8s %s\n' \
      "$id" "$(drill_title "$path")" "$(drill_target "$path")" "$last"
  done < <(drill_ids)
}

cmd_start() { # <id>
  local id="$1" path ns
  path="$(_resolve "$id")"
  ns="$(drill_ns "$id")"

  kubectl get namespace "$ns" >/dev/null 2>&1 \
    || kubectl create namespace "$ns" >/dev/null \
    || _die "could not create namespace $ns - is the cluster running? try: cluster/bootstrap.sh"

  if [[ -x "$path/setup.sh" ]]; then
    printf 'seeding cluster state...\n'
    NS="$ns" bash "$path/setup.sh" || _die "setup.sh failed for $id"
  fi

  mkdir -p "$SCRATCH_ROOT/$id"
  date +%s > "$SCRATCH_ROOT/$id/.started"

  printf '\n'
  cat "$path/task.md"
  cat <<EOF

---
namespace: $ns
work in:   $SCRATCH_ROOT/$id
check:     ckad verify $id
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list)     cmd_list "${1:-}" ;;
    start)    [[ $# -ge 1 ]] || _die "start needs a drill id"; cmd_start "$1" ;;
    ""|-h|--help|help) usage ;;
    *)        _die "unknown command: $cmd (try: ckad help)" ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Make it executable and run the test**

```bash
chmod +x bin/ckad
bash tests/test_ckad_list_start.sh
```
Expected: PASS — `14 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/ckad tests/test_ckad_list_start.sh
git commit -m "feat: add ckad CLI with list and start"
```

---

### Task 8: `bin/ckad` — `verify`, `solution`, `reset`, `score`

**Files:**
- Modify: `bin/ckad` (add four command functions and their `case` arms)
- Test: `tests/test_ckad_verify.sh`

**Interfaces:**
- Consumes: `_resolve`, `_die`, `SCRATCH_ROOT` from Task 7; `state_record`, `state_attempts`, `state_domain_counts`, `CKAD_WEIGHTS` from Task 6.
- Produces: `cmd_verify`, `cmd_solution`, `cmd_reset`, `cmd_score`.

`verify` exports `CKAD_ROOT` before running `verify.sh` so the drill's `source` line resolves whether it is run through the CLI or directly. The gate on `solution` is the whole point of recording attempts: reading the answer first feels like progress and teaches nothing.

- [ ] **Step 1: Write the failing test**

`tests/test_ckad_verify.sh`:
```bash
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
ckad reset 1.1 >/dev/null
expect_contains "$(stub_calls)" "delete namespace ckad-1-1" "reset deletes the drill namespace"
expect_eq "$(test -f "$TMP/scratch/1.1/.started" && echo yes || echo no)" "no" "reset clears the timer"

# --- score ---
out="$(ckad score)"
expect_contains "$out" "25" "score shows domain 4's exam weight"
expect_contains "$out" "1/2" "score shows passed over total for domain 1"

harness_finish
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_ckad_verify.sh`
Expected: FAIL — `ckad: unknown command: verify` for every case.

- [ ] **Step 3: Add the four commands to `bin/ckad`**

Insert these functions after `cmd_start`:

```bash
cmd_verify() { # <id>
  local id="$1" path ns started elapsed=0 rc
  path="$(_resolve "$id")"
  ns="$(drill_ns "$id")"
  [[ -f "$path/verify.sh" ]] \
    || _die "drill $id has no verify.sh - the repo is broken, not your answer"

  started="$SCRATCH_ROOT/$id/.started"
  [[ -f "$started" ]] && elapsed=$(( $(date +%s) - $(cat "$started") ))

  CKAD_ROOT="$CKAD_ROOT" NS="$ns" bash "$path/verify.sh"
  rc=$?

  (( rc == 0 )) && state_record "$id" 1 "$elapsed" || state_record "$id" 0 "$elapsed"
  if (( elapsed > 0 )); then
    printf 'elapsed: %dm%02ds   target: %s\n' \
      $(( elapsed / 60 )) $(( elapsed % 60 )) "$(drill_target "$path")"
  fi
  (( rc == 0 )) || printf 'stuck? ckad solution %s\n' "$id"
  return $rc
}

cmd_solution() { # <id>
  local id="$1" path f
  path="$(_resolve "$id")"
  if (( $(state_attempts "$id") == 0 )); then
    _die "try it first - run 'ckad verify $id' at least once before reading the answer"
  fi
  [[ -d "$path/.solution" ]] || _die "drill $id has no .solution directory"
  for f in "$path/.solution"/*; do
    [[ -f "$f" ]] || continue
    printf '\n===== %s =====\n' "$(basename "$f")"
    cat "$f"
  done
}

cmd_reset() { # [<id>|--all]
  local target="${1:---all}"
  if [[ "$target" == "--all" ]]; then
    printf 'recreating the whole cluster...\n'
    exec bash "$CKAD_ROOT/cluster/bootstrap.sh" --recreate
  fi
  local id="$target" ns
  _resolve "$id" >/dev/null
  ns="$(drill_ns "$id")"
  printf 'deleting namespace %s...\n' "$ns"
  kubectl delete namespace "$ns" --ignore-not-found >/dev/null
  rm -f "$SCRATCH_ROOT/$id/.started"
  printf 'reset. your YAML in %s/%s was left alone.\n' "$SCRATCH_ROOT" "$id"
}

cmd_score() {
  local dom passed total weight earned=0 possible=0
  printf '%-8s %-7s %-8s %s\n' "DOMAIN" "WEIGHT" "PASSED" "EARNED"
  for dom in 1 2 3 4 5; do
    read -r passed total <<< "$(state_domain_counts "$dom")"
    weight="${CKAD_WEIGHTS[$dom]}"
    local got=0
    (( total > 0 )) && got=$(( passed * weight / total ))
    earned=$(( earned + got )); possible=$(( possible + weight ))
    printf '%-8s %-7s %-8s %s\n' "$dom" "$weight%" "$passed/$total" "$got"
  done
  printf '%-8s %-7s %-8s %s\n' "total" "$possible%" "" "$earned"
  printf '\nCKAD needs 66. This is drill coverage, not a score prediction.\n'
}
```

Then extend the `case` block in `main`:

```bash
    verify)   [[ $# -ge 1 ]] || _die "verify needs a drill id"; cmd_verify "$1" ;;
    solution) [[ $# -ge 1 ]] || _die "solution needs a drill id"; cmd_solution "$1" ;;
    reset)    cmd_reset "${1:-}" ;;
    score)    cmd_score ;;
```

The last line of `cmd_score` matters: a weighted drill-coverage number looks exactly like a predicted exam score, and it is not one. Say so where it is printed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_ckad_verify.sh`
Expected: PASS — `14 passed, 0 failed`.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run.sh`
Expected: PASS — `ALL TESTS PASSED`, eight test files green.

- [ ] **Step 6: Commit**

```bash
git add bin/ckad tests/test_ckad_verify.sh
git commit -m "feat: add ckad verify, solution, reset and score"
```

---

### Task 9: Cluster bootstrap

This is the first task that needs Docker Desktop running and internet access. It has no unit test — its test is a working cluster.

**Files:**
- Create: `cluster/kind-config.yaml`, `cluster/bootstrap.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a kind cluster named `ckad` with kube-context `kind-ckad`, Calico, ingress-nginx, metrics-server. `bootstrap.sh [--recreate]` is called by `ckad reset --all` (Task 8).

No `image:` pin in the kind config: kind 0.33.0 ships a matching default node image, and a hand-pinned tag that disagrees with the installed kind is a confusing failure. The README records whatever `kubectl version` reports after bootstrap.

- [ ] **Step 1: Install the prerequisite**

```bash
winget install Kubernetes.kind
```
Then start Docker Desktop and confirm: `docker info >/dev/null && echo docker ok`

- [ ] **Step 2: Write `cluster/kind-config.yaml`**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
# Default CNI is off because kindnet does not enforce NetworkPolicy; Calico is
# installed by bootstrap.sh. Without this, drill 5.2 would pass with a policy
# that blocks nothing.
networking:
  disableDefaultCNI: true
  podSubnet: "192.168.0.0/16"
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
    labels:
      disk: ssd
  - role: worker
    labels:
      zone: a
```

The worker labels exist so nodeSelector and affinity drills have something real to select on, and `ingress-ready=true` is what the ingress-nginx kind manifest schedules against.

- [ ] **Step 3: Write `cluster/bootstrap.sh`**

```bash
#!/usr/bin/env bash
# Creates the ckad practice cluster. Idempotent: re-running is a no-op unless
# --recreate is passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER=ckad
RECREATE=0
[[ "${1:-}" == "--recreate" ]] && RECREATE=1

die() { printf '\nbootstrap: %s\n' "$1" >&2; exit 1; }
step() { printf '\n==> %s\n' "$1"; }

# --- preflight: every failure names its own fix -----------------------------
step "preflight"
command -v kubectl >/dev/null || die "kubectl not found on PATH"
command -v kind    >/dev/null || die "kind not found - run: winget install Kubernetes.kind"
docker info >/dev/null 2>&1 \
  || die "cannot reach the Docker daemon - start Docker Desktop and wait for it to say Running"

mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
if (( mem_bytes > 0 && mem_bytes < 4000000000 )); then
  printf 'warning: Docker reports %s GiB of memory. Three nodes plus Calico\n' \
    "$(( mem_bytes / 1073741824 ))"
  printf '         needs about 4 GiB; raise it in Docker Desktop > Settings > Resources.\n'
fi
printf 'ok\n'

# --- cluster ----------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  if (( RECREATE )); then
    step "deleting existing cluster"
    kind delete cluster --name "$CLUSTER"
  else
    printf '\ncluster %s already exists. Use --recreate to rebuild it.\n' "$CLUSTER"
    kubectl config use-context "kind-$CLUSTER" >/dev/null
    exit 0
  fi
fi

step "creating cluster (1 control-plane, 2 workers)"
kind create cluster --name "$CLUSTER" --config "$HERE/kind-config.yaml" \
  || die "kind create failed - see the output above"

# --- CNI --------------------------------------------------------------------
step "installing Calico (NetworkPolicy enforcement)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml \
  || die "Calico apply failed - check internet access"
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s \
  || die "Calico did not become ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s \
  || die "nodes did not become Ready after Calico"

# --- ingress ----------------------------------------------------------------
step "installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml \
  || die "ingress-nginx apply failed"
# Waiting on the admission webhook is not optional: without it the first
# Ingress you apply is rejected for reasons unrelated to your YAML.
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=300s \
  || die "ingress-nginx controller did not become ready"

# --- metrics ----------------------------------------------------------------
step "installing metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml \
  || die "metrics-server apply failed"
# kind's kubelet serving certs are self-signed, so metrics-server must be told
# to skip verification or `kubectl top` and every HPA drill silently report
# nothing forever.
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  || die "could not patch metrics-server"
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s \
  || die "metrics-server did not become ready"

step "done"
kubectl get nodes -o wide
cat <<'EOF'

next:
  source bin/setup-shell.sh    # aliases and $do/$now
  ckad list                    # pick a drill
EOF
```

- [ ] **Step 4: Run it**

Run: `bash cluster/bootstrap.sh`
Expected: three nodes `Ready`, roughly 3-5 minutes on a first run while images pull.

- [ ] **Step 5: Verify the things that silently fail**

```bash
kubectl get nodes --show-labels | grep -c 'disk=ssd\|zone=a'   # expect 2
kubectl top nodes                                              # expect numbers, not an error
kubectl -n ingress-nginx get svc ingress-nginx-controller      # expect it to exist
```
If `kubectl top nodes` reports metrics not available, wait 30 seconds and retry — metrics-server needs one scrape interval before it answers.

- [ ] **Step 6: Confirm idempotency**

Run: `bash cluster/bootstrap.sh`
Expected: prints `cluster ckad already exists. Use --recreate to rebuild it.` and exits 0 without touching anything.

- [ ] **Step 7: Commit**

```bash
git add cluster
git commit -m "feat: add kind cluster bootstrap with Calico, ingress and metrics"
```

---

### Task 10: `bin/setup-shell.sh` — exam-day shell

**Files:**
- Create: `bin/setup-shell.sh`
- Test: `tests/test_setup_shell.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: aliases `k`, `kg`, `kgp`, `kgd`, `kdp`, `kdel`, `kn`, `kns`; exports `do`, `now`, `yd`, `KUBE_EDITOR`; function `kn` for namespace switching; appends a YAML block to `~/.vimrc` only when absent.

This is sourced, not executed, so it must not call `exit` and must not use `set -e` — either one would kill the user's interactive shell on a trivial error.

- [ ] **Step 1: Write the failing test**

`tests/test_setup_shell.sh`:
```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_setup_shell.sh`
Expected: FAIL — `bin/setup-shell.sh` does not exist.

- [ ] **Step 3: Implement `bin/setup-shell.sh`**

```bash
# bin/setup-shell.sh - source this at the start of every practice session:
#
#   source bin/setup-shell.sh
#
# Practicing with these shortcuts is part of the training. Typing
# `kubectl get pods --all-namespaces` by hand is how people run out of time.
#
# Deliberately no `set -e` and no `exit`: this is sourced into an interactive
# shell, and either one would close the user's terminal on a trivial error.

alias k='kubectl'
alias kg='kubectl get'
alias kgp='kubectl get pods'
alias kgd='kubectl get deploy'
alias kdp='kubectl describe pod'
alias kdel='kubectl delete'
alias kns='kubectl config set-context --current --namespace'

# Switch namespace: kn ckad-3-2   (no argument prints the current one)
kn() {
  if [[ -z "${1:-}" ]]; then
    kubectl config view --minify -o jsonpath='{..namespace}'; printf '\n'
  else
    kubectl config set-context --current --namespace="$1" >/dev/null \
      && printf 'namespace: %s\n' "$1"
  fi
}

# Generate a manifest without creating anything:  k run web --image=nginx $do
export do='--dry-run=client -o yaml'
# Delete without waiting:                         k delete pod web $now
export now='--force --grace-period=0'
# Shorthand for inspecting live objects:          k get deploy web $yd
export yd='-o yaml'

export KUBE_EDITOR='vim'

# Completion, including for the `k` alias.
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion bash) 2>/dev/null
  complete -o default -F __start_kubectl k 2>/dev/null
fi

# YAML-friendly vim, appended once. Editing YAML with default tabs loses more
# exam time than any missing alias.
if [[ -n "${HOME:-}" ]] && ! grep -q 'ckad-practice' "$HOME/.vimrc" 2>/dev/null; then
  cat >> "$HOME/.vimrc" <<'VIMEOF'
" ckad-practice: YAML editing defaults
set tabstop=2 shiftwidth=2 expandtab number
autocmd FileType yaml setlocal indentkeys-=0#
VIMEOF
  printf 'added YAML settings to %s/.vimrc\n' "$HOME"
fi

printf 'shell ready: k, kgp, kn, $do, $now, $yd\n'
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_setup_shell.sh`
Expected: PASS — `7 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/setup-shell.sh tests/test_setup_shell.sh
git commit -m "feat: add exam-day shell setup"
```

---

### Task 11: `bin/selftest.sh` — validate the drills

Every drill task from here on uses this as its test, so it must exist and be proven first. It is proven against a fixture drill tree, not against the real drills — there are none yet.

**Files:**
- Create: `bin/selftest.sh`
- Test: `tests/test_selftest.sh`

**Interfaces:**
- Consumes: `drill_ids`, `drill_path`, `drill_ns` (Task 5).
- Produces: `bin/selftest.sh [<id>…]` — with no arguments it checks every drill; exits 0 only if all pass.

For each drill it asserts two things:

1. Applying `.solution/` makes `verify.sh` exit 0 — catches a verify script stricter than its own reference answer.
2. With the namespace deleted, `verify.sh` exits non-zero — catches a verify script that passes against nothing, which is the defect that quietly wastes the most practice time.

The second check is why this script is worth writing. A verify script with a typo'd jsonpath often passes everything, and you would only discover it by solving the drill wrong and being told you were right.

- [ ] **Step 1: Write the failing test**

`tests/test_selftest.sh`:
```bash
#!/usr/bin/env bash
source "$(dirname "$0")/harness.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DRILLS="$(make_drill_tree "$TMP")"
stub_setup

# A drill whose verify.sh passes only when a marker file exists. The marker
# stands in for cluster state: "apply the solution" creates it, "delete the
# namespace" removes it.
GOOD="$DRILLS/1-design-build/01-sidecar"
mkdir -p "$GOOD/.solution"
printf 'kind: ConfigMap\n' > "$GOOD/.solution/cm.yaml"
cat > "$GOOD/verify.sh" <<EOF
#!/usr/bin/env bash
[[ -f "$TMP/applied" ]] && exit 0
exit 1
EOF
chmod +x "$GOOD/verify.sh"

# A broken drill: verify.sh always passes, even against an empty namespace.
BAD="$DRILLS/1-design-build/02-init-job"
mkdir -p "$BAD/.solution"
printf 'kind: ConfigMap\n' > "$BAD/.solution/cm.yaml"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BAD/verify.sh"
chmod +x "$BAD/verify.sh"

# Stub kubectl so `apply` creates the marker and `delete namespace` removes it.
cat > "$STUB_DIR/kubectl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
case "\$*" in
  *"apply"*)            touch "$TMP/applied" ;;
  *"delete namespace"*) rm -f "$TMP/applied" ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/kubectl"

selftest() {
  CKAD_ROOT="$CKAD_TEST_ROOT" DRILLS_ROOT="$DRILLS" NO_COLOR=1 \
  bash "$CKAD_TEST_ROOT/bin/selftest.sh" "$@" 2>&1
}

out="$(selftest 1.1)"; rc=$?
expect_rc "$rc" 0 "a well-formed drill passes selftest"
expect_contains "$out" "1.1" "selftest names the drill it checked"

out="$(selftest 1.2)"; rc=$?
expect_rc "$rc" 1 "a verify.sh that passes on an empty namespace is caught"
expect_contains "$out" "empty namespace" "the failure explains that it passed against nothing"

out="$(selftest)"; rc=$?
expect_rc "$rc" 1 "running all drills fails when any drill is broken"

# A drill with no .solution is a repo bug and must be reported, not skipped.
out="$(selftest 3.1)"; rc=$?
expect_rc "$rc" 1 "a drill with no .solution fails selftest"
expect_contains "$out" "solution" "the missing .solution is named"

harness_finish
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash tests/test_selftest.sh`
Expected: FAIL — `bin/selftest.sh` does not exist.

- [ ] **Step 3: Implement `bin/selftest.sh`**

```bash
#!/usr/bin/env bash
# selftest - validate the drills themselves against a live cluster.
#
#   bin/selftest.sh          # every drill
#   bin/selftest.sh 3.2 4.1  # named drills
#
# Per drill:
#   1. apply .solution/ -> verify.sh must exit 0
#   2. delete namespace -> verify.sh must exit non-zero
#
# Check 2 is the valuable one. A verify script with a typo'd jsonpath usually
# passes everything, and you would otherwise discover that only by solving a
# drill wrong and being congratulated for it.

set -uo pipefail

CKAD_ROOT="${CKAD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export CKAD_ROOT
source "$CKAD_ROOT/lib/drills.sh"

FAILED=0

check_drill() { # <id>
  local id="$1" path ns rc
  path="$(drill_path "$id")" || { printf 'x %s: no such drill\n' "$id"; FAILED=1; return; }
  ns="$(drill_ns "$id")"

  if [[ ! -f "$path/verify.sh" ]]; then
    printf 'x %s: no verify.sh\n' "$id"; FAILED=1; return
  fi
  if [[ ! -d "$path/.solution" ]] || ! compgen -G "$path/.solution/*.yaml" >/dev/null; then
    printf 'x %s: no .solution/*.yaml to apply\n' "$id"; FAILED=1; return
  fi

  printf '\n--- %s ---\n' "$id"

  # Start from nothing.
  kubectl delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create namespace "$ns" >/dev/null 2>&1

  # Phase 1: the reference solution must satisfy the drill's own verify script.
  [[ -x "$path/setup.sh" ]] && NS="$ns" bash "$path/setup.sh" >/dev/null 2>&1
  kubectl -n "$ns" apply -f "$path/.solution/" >/dev/null 2>&1
  bash "$path/verify.sh" >/dev/null 2>&1; rc=$?
  if (( rc == 0 )); then
    printf '  ok   solution satisfies verify.sh\n'
  else
    printf '  FAIL solution does NOT satisfy verify.sh (exit %d)\n' "$rc"
    printf '       verify.sh is stricter than its own answer. Full output:\n'
    bash "$path/verify.sh" 2>&1 | sed 's/^/       /'
    FAILED=1
  fi

  # Phase 2: with nothing applied, verify.sh must fail.
  kubectl delete namespace "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create namespace "$ns" >/dev/null 2>&1
  bash "$path/verify.sh" >/dev/null 2>&1; rc=$?
  if (( rc != 0 )); then
    printf '  ok   verify.sh fails on an empty namespace\n'
  else
    printf '  FAIL verify.sh PASSES on an empty namespace - it checks nothing\n'
    FAILED=1
  fi

  kubectl delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1
}

targets=("$@")
if (( ${#targets[@]} == 0 )); then
  mapfile -t targets < <(drill_ids)
fi

for id in "${targets[@]}"; do
  check_drill "$id"
done

printf '\n'
if (( FAILED == 0 )); then printf 'SELFTEST PASSED (%d drills)\n' "${#targets[@]}"; exit 0; fi
printf 'SELFTEST FAILED\n'; exit 1
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x bin/selftest.sh
bash tests/test_selftest.sh
```
Expected: PASS — `7 passed, 0 failed`.

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run.sh`
Expected: PASS — `ALL TESTS PASSED`, ten test files green.

- [ ] **Step 6: Commit**

```bash
git add bin/selftest.sh tests/test_selftest.sh
git commit -m "feat: add selftest to validate drills against a live cluster"
```

---

### Task 12: Domain 1 drills — Design & Build (20%)

From here on, each drill task writes `verify.sh` before `.solution/`, which is the TDD cycle in drill form: the verify script is the test, the solution is the implementation, and `bin/selftest.sh` runs both directions.

**Files:**
- Create: `drills/1-design-build/01-sidecar/{task.md,verify.sh,.solution/pod.yaml}`
- Create: `drills/1-design-build/02-init-job/{task.md,verify.sh,.solution/pod.yaml,.solution/job.yaml}`

**Interfaces:**
- Consumes: `lib/assert.sh` (Tasks 3-4), `bin/selftest.sh` (Task 11), a running cluster (Task 9).
- Produces: drill ids `1.1` and `1.2`.

Solution manifests deliberately omit `metadata.namespace`. Both `selftest` and the user apply them with `-n`, and a hardcoded namespace would break the moment a drill is copied to a new id.

- [ ] **Step 1: Write `drills/1-design-build/01-sidecar/task.md`**

```markdown
# Sidecar sharing an emptyDir

**Target time:** 8 min
**Namespace:** `ckad-1-1`

A legacy app writes its log to a file instead of stdout, so `kubectl logs`
shows nothing. Fix that with a sidecar, without modifying the app's image.

Create a Pod named `logger` with:

1. A container named `app`, image `busybox:1.36`, that appends a line
   containing `app-heartbeat` to `/var/log/app.log` every 2 seconds, forever.
2. A container named `sidecar`, image `busybox:1.36`, that streams that same
   file to stdout so `kubectl logs logger -c sidecar` shows the lines.
3. A volume named `logs` of type `emptyDir`, mounted at `/var/log` in **both**
   containers.
4. The Pod must reach Ready.

Hints: `k run logger --image=busybox:1.36 $do -- sh -c 'sleep 1' > pod.yaml`
gives you a skeleton to edit. The sidecar must tolerate the file not existing
yet — `tail -f` on a missing file exits immediately.
```

- [ ] **Step 2: Write the test — `drills/1-design-build/01-sidecar/verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-1-1

assert_exists pod/logger

# Container names, checked individually so manifest order does not matter.
assert_jsonpath pod/logger '{.spec.containers[?(@.name=="app")].name}' 'app'
assert_jsonpath pod/logger '{.spec.containers[?(@.name=="sidecar")].name}' 'sidecar'

# kubectl renders an empty JSON object as map[] in jsonpath output, so that is
# what an `emptyDir: {}` volume compares against.
assert_jsonpath pod/logger '{.spec.volumes[?(@.name=="logs")].emptyDir}' 'map[]'

assert_jsonpath pod/logger \
  '{.spec.containers[?(@.name=="app")].volumeMounts[?(@.name=="logs")].mountPath}' '/var/log'
assert_jsonpath pod/logger \
  '{.spec.containers[?(@.name=="sidecar")].volumeMounts[?(@.name=="logs")].mountPath}' '/var/log'

retry_until 90 assert_pod_ready --pod logger
retry_until 60 assert_logs --pod logger -c sidecar --contains 'app-heartbeat'

finish
```

- [ ] **Step 3: Confirm the drill fails before the solution exists**

```bash
chmod +x drills/1-design-build/01-sidecar/verify.sh
mkdir -p drills/1-design-build/01-sidecar/.solution
bash bin/selftest.sh 1.1
```
Expected: FAIL — `no .solution/*.yaml to apply`. This proves selftest is actually looking at this drill.

- [ ] **Step 4: Write `.solution/pod.yaml`**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: logger
spec:
  volumes:
    - name: logs
      emptyDir: {}
  containers:
    - name: app
      image: busybox:1.36
      command:
        - sh
        - -c
        - while true; do echo "$(date) app-heartbeat" >> /var/log/app.log; sleep 2; done
      volumeMounts:
        - name: logs
          mountPath: /var/log
    - name: sidecar
      image: busybox:1.36
      # touch first: tail -f on a file that does not exist yet exits at once,
      # and the app container may not have created it when the sidecar starts.
      command:
        - sh
        - -c
        - touch /var/log/app.log; tail -f /var/log/app.log
      volumeMounts:
        - name: logs
          mountPath: /var/log
```

- [ ] **Step 5: Run selftest for 1.1**

Run: `bash bin/selftest.sh 1.1`
Expected: PASS — both `solution satisfies verify.sh` and `verify.sh fails on an empty namespace`.

- [ ] **Step 6: Write `drills/1-design-build/02-init-job/task.md`**

```markdown
# Init container ordering and a Job that gives up

**Target time:** 12 min
**Namespace:** `ckad-1-2`

Two independent pieces.

**A.** Create a Pod named `web`:

1. An init container named `seed`, image `busybox:1.36`, that writes an
   `index.html` containing the word `seeded` into a shared volume.
2. A container named `web`, image `nginx:1.27-alpine`, serving that file from
   `/usr/share/nginx/html`.
3. A volume named `content` of type `emptyDir`, mounted in both.
4. The Pod must reach Ready, and
   `k exec web -- cat /usr/share/nginx/html/index.html` must print `seeded`.

**B.** Create a Job named `migrate` that is *expected to fail*:

1. One container, image `busybox:1.36`, running a command that exits non-zero.
2. `restartPolicy: Never`.
3. `backoffLimit: 2`.
4. Leave it alone until the Job reports exactly **3** failed Pods.

Part B is about knowing what `backoffLimit` counts. Predict the number of
Pods before you look.
```

- [ ] **Step 7: Write `drills/1-design-build/02-init-job/verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-1-2

# --- A: init container seeds content for the main container ---
assert_exists pod/web
assert_jsonpath pod/web '{.spec.initContainers[?(@.name=="seed")].name}' 'seed'
assert_jsonpath pod/web '{.spec.volumes[?(@.name=="content")].emptyDir}' 'map[]'
assert_jsonpath pod/web \
  '{.spec.containers[?(@.name=="web")].volumeMounts[?(@.name=="content")].mountPath}' \
  '/usr/share/nginx/html'
retry_until 120 assert_pod_ready --pod web
assert_exec --pod web -c web --contains 'seeded' -- cat /usr/share/nginx/html/index.html

# --- B: backoffLimit 2 means 1 attempt plus 2 retries = 3 failed pods ---
assert_exists job/migrate
assert_jsonpath job/migrate '{.spec.backoffLimit}' '2'
assert_jsonpath job/migrate '{.spec.template.spec.restartPolicy}' 'Never'
retry_until 240 assert_jsonpath job/migrate '{.status.failed}' '3'

finish
```

- [ ] **Step 8: Confirm it fails, then write the solution**

Run: `chmod +x drills/1-design-build/02-init-job/verify.sh && bash bin/selftest.sh 1.2`
Expected: FAIL — no `.solution`.

`.solution/pod.yaml`:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  volumes:
    - name: content
      emptyDir: {}
  initContainers:
    - name: seed
      image: busybox:1.36
      command: ["sh", "-c", "echo '<h1>seeded</h1>' > /work/index.html"]
      volumeMounts:
        - name: content
          mountPath: /work
  containers:
    - name: web
      image: nginx:1.27-alpine
      volumeMounts:
        - name: content
          mountPath: /usr/share/nginx/html
```

`.solution/job.yaml`:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: migrate
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: migrate
          image: busybox:1.36
          command: ["sh", "-c", "echo migrating; exit 1"]
```

- [ ] **Step 9: Run selftest for 1.2**

Run: `bash bin/selftest.sh 1.2`
Expected: PASS. Allow up to four minutes — the Job must exhaust its backoff, and the retries are spaced by Kubernetes' exponential delay.

- [ ] **Step 10: Commit**

```bash
git add drills/1-design-build
git commit -m "feat: add domain 1 drills - sidecar and init/job"
```

---

### Task 13: Selftest support for imperative solutions, then domain 2 drills (20%)

Rollouts and kustomize overlays cannot be expressed as a single `kubectl apply -f`: a rollback only exists after a sequence of commands. Selftest needs to support that before domain 2 can be written.

**Files:**
- Modify: `bin/selftest.sh` (honor `.solution/apply.sh`)
- Modify: `tests/test_selftest.sh` (cover it)
- Create: `drills/2-deployment/01-rollout-undo/{task.md,verify.sh,.solution/deployment.yaml,.solution/apply.sh}`
- Create: `drills/2-deployment/02-kustomize-overlay/{task.md,verify.sh,.solution/apply.sh,.solution/base/*,.solution/overlays/prod/*}`

**Interfaces:**
- Consumes: Task 11's `check_drill`.
- Produces: drill ids `2.1` and `2.2`; the `.solution/apply.sh` convention — when present, selftest runs it with `NS` exported instead of applying `*.yaml`, and the `*.yaml` requirement is waived.

- [ ] **Step 1: Add the failing test to `tests/test_selftest.sh`**

Append before `harness_finish`:

```bash
# --- .solution/apply.sh replaces the plain apply ---
SEQ="$DRILLS/3-observability/01-broken-probe"
mkdir -p "$SEQ/.solution"
printf '#!/usr/bin/env bash\ntouch "%s/applied"\nprintf "%%s" "$NS" > "%s/apply-ns"\n' \
  "$TMP" "$TMP" > "$SEQ/.solution/apply.sh"
chmod +x "$SEQ/.solution/apply.sh"
cat > "$SEQ/verify.sh" <<EOF
#!/usr/bin/env bash
[[ -f "$TMP/applied" ]] && exit 0
exit 1
EOF
chmod +x "$SEQ/verify.sh"

out="$(selftest 3.1)"; rc=$?
expect_rc "$rc" 0 "a drill with .solution/apply.sh and no yaml passes selftest"
expect_eq "$(cat "$TMP/apply-ns" 2>/dev/null)" "ckad-3-1" "apply.sh runs with NS set to the drill namespace"
```

Note this replaces the earlier `selftest 3.1` expectation in that file — 3.1 now has a `.solution`, so delete the two "a drill with no .solution fails selftest" expectations and keep coverage of that case by pointing it at a drill that still lacks one. Add this instead:

```bash
mkdir -p "$DRILLS/3-observability/02-no-sol"
printf '# No solution\n' > "$DRILLS/3-observability/02-no-sol/task.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DRILLS/3-observability/02-no-sol/verify.sh"
chmod +x "$DRILLS/3-observability/02-no-sol/verify.sh"
out="$(selftest 3.2)"; rc=$?
expect_rc "$rc" 1 "a drill with no .solution fails selftest"
expect_contains "$out" "solution" "the missing .solution is named"
```

- [ ] **Step 2: Run it to confirm the new expectations fail**

Run: `bash tests/test_selftest.sh`
Expected: FAIL — `3.1` fails because selftest still demands `.solution/*.yaml`.

- [ ] **Step 3: Teach `bin/selftest.sh` about `apply.sh`**

Replace the solution-presence check in `check_drill`:

```bash
  local apply_script="$path/.solution/apply.sh"
  if [[ ! -d "$path/.solution" ]] \
     || { [[ ! -x "$apply_script" ]] && ! compgen -G "$path/.solution/*.yaml" >/dev/null; }; then
    printf 'x %s: no .solution/*.yaml and no .solution/apply.sh\n' "$id"; FAILED=1; return
  fi
```

And replace the single apply line with:

```bash
  # Drills whose answer is a sequence of commands (a rollback, a kustomize
  # build) ship .solution/apply.sh instead of plain manifests.
  if [[ -x "$apply_script" ]]; then
    NS="$ns" bash "$apply_script" >/dev/null 2>&1
  else
    kubectl -n "$ns" apply -f "$path/.solution/" >/dev/null 2>&1
  fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_selftest.sh`
Expected: PASS — `9 passed, 0 failed`.

- [ ] **Step 5: Write `drills/2-deployment/01-rollout-undo/task.md`**

```markdown
# Rollout, then undo it

**Target time:** 10 min
**Namespace:** `ckad-2-1`

Create a Deployment named `api`:

1. 4 replicas, label `app=api` on the Pods, one container named `api`,
   image `nginx:1.27-alpine`.
2. A `RollingUpdate` strategy with `maxSurge: 1` and `maxUnavailable: 0`
   — the Service must never lose capacity during an update.
3. Roll it out, then update the image to `nginx:1.28-alpine` and record the
   reason in the `kubernetes.io/change-cause` annotation.
4. Then roll back to the original image using revision 1.
5. End state: 4 Ready Pods on `nginx:1.27-alpine`, and the Deployment is on
   revision **3**.

Why 3: creating, updating, and undoing each produce a revision. `k rollout
history deploy/api` shows them. Do not reach 1.27 by editing the image back
by hand — use `rollout undo`, and note that it creates a new revision rather
than deleting one.
```

- [ ] **Step 6: Write `drills/2-deployment/01-rollout-undo/verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-2-1

assert_exists deployment/api
assert_jsonpath deployment/api '{.spec.replicas}' '4'
assert_jsonpath deployment/api '{.spec.strategy.type}' 'RollingUpdate'
assert_jsonpath deployment/api '{.spec.strategy.rollingUpdate.maxSurge}' '1'
assert_jsonpath deployment/api '{.spec.strategy.rollingUpdate.maxUnavailable}' '0'

# Back on the original image...
assert_jsonpath deployment/api '{.spec.template.spec.containers[0].image}' 'nginx:1.27-alpine'
# ...but via a third revision, which is what proves a rollback rather than an
# edit. Dots inside the annotation key must be escaped in jsonpath.
assert_jsonpath deployment/api \
  '{.metadata.annotations.deployment\.kubernetes\.io/revision}' '3'

retry_until 180 assert_pod_ready -l app=api --count 4

finish
```

- [ ] **Step 7: Confirm it fails, then write the solution**

Run: `chmod +x drills/2-deployment/01-rollout-undo/verify.sh && bash bin/selftest.sh 2.1`
Expected: FAIL — no `.solution`.

`.solution/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 4
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
```

`.solution/apply.sh`:
```bash
#!/usr/bin/env bash
# The end state of this drill is a rollback, which only exists after a
# sequence of commands. NS is exported by selftest and by ckad.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

kubectl -n "$NS" apply -f "$HERE/deployment.yaml"
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 1

kubectl -n "$NS" set image deployment/api api=nginx:1.28-alpine
kubectl -n "$NS" annotate deployment/api \
  kubernetes.io/change-cause="upgrade to nginx 1.28" --overwrite
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 2

kubectl -n "$NS" rollout undo deployment/api --to-revision=1
kubectl -n "$NS" rollout status deployment/api --timeout=180s   # revision 3
```

- [ ] **Step 8: Run selftest for 2.1**

```bash
chmod +x drills/2-deployment/01-rollout-undo/.solution/apply.sh
bash bin/selftest.sh 2.1
```
Expected: PASS. Two to three minutes — three sequential rollouts of four Pods.

- [ ] **Step 9: Write `drills/2-deployment/02-kustomize-overlay/task.md`**

```markdown
# A kustomize overlay for production

**Target time:** 12 min
**Namespace:** `ckad-2-2`

Build a kustomize base and one overlay. No Helm, and no standalone
`kustomize` binary — `kubectl apply -k` has it built in.

**Base** (`base/`): a Deployment named `site`, 1 replica, container `site`,
image `nginx:1.27-alpine`, Pod label `app=site`.

**Overlay** (`overlays/prod/`) referencing that base and changing only:

1. replicas to 3
2. image to `nginx:1.28-alpine`
3. a label `env=prod` applied to the Deployment *and* its Pods

Apply the overlay with `k apply -k overlays/prod`. The base must remain
deployable on its own — if your base only works through the overlay, the
split is wrong.

End state: Deployment `site` with 3 Ready Pods on `nginx:1.28-alpine`,
carrying `env=prod`.
```

- [ ] **Step 10: Write `drills/2-deployment/02-kustomize-overlay/verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-2-2

assert_exists deployment/site
assert_jsonpath deployment/site '{.spec.replicas}' '3'
assert_jsonpath deployment/site '{.spec.template.spec.containers[0].image}' 'nginx:1.28-alpine'
assert_jsonpath deployment/site '{.metadata.labels.env}' 'prod'
# The label must reach the Pods too, not just the Deployment - that is the
# difference between `labels` with includeTemplates and a stray metadata edit.
retry_until 180 assert_pod_ready -l env=prod --count 3

finish
```

- [ ] **Step 11: Confirm it fails, then write the solution**

Run: `chmod +x drills/2-deployment/02-kustomize-overlay/verify.sh && bash bin/selftest.sh 2.2`
Expected: FAIL — no `.solution`.

`.solution/base/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: site
spec:
  replicas: 1
  selector:
    matchLabels:
      app: site
  template:
    metadata:
      labels:
        app: site
    spec:
      containers:
        - name: site
          image: nginx:1.27-alpine
```

`.solution/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
```

`.solution/overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
replicas:
  - name: site
    count: 3
images:
  - name: nginx
    newTag: 1.28-alpine
labels:
  - pairs:
      env: prod
    includeTemplates: true
```

`.solution/apply.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
kubectl -n "$NS" apply -k "$HERE/overlays/prod"
kubectl -n "$NS" rollout status deployment/site --timeout=180s
```

`includeTemplates: true` is what pushes `env=prod` onto the Pod template; the
older `commonLabels` did this implicitly and also wrote into the selector,
which is immutable and breaks on the second apply.

- [ ] **Step 12: Run selftest for 2.2 and the full suite**

```bash
chmod +x drills/2-deployment/02-kustomize-overlay/.solution/apply.sh
bash bin/selftest.sh 2.2
bash tests/run.sh
```
Expected: both PASS.

- [ ] **Step 13: Commit**

```bash
git add bin/selftest.sh tests/test_selftest.sh drills/2-deployment
git commit -m "feat: add domain 2 drills and selftest support for imperative solutions"
```

---

### Task 14: Domain 3 drills — Observability (15%)

**Files:**
- Create: `drills/3-observability/01-broken-probe/{task.md,setup.sh,verify.sh,.solution/deployment.yaml,.solution/configmap.yaml}`
- Create: `drills/3-observability/02-slow-start/{task.md,verify.sh,.solution/deployment.yaml}`

**Interfaces:**
- Consumes: `lib/assert.sh`, `bin/selftest.sh` with `apply.sh` support (Task 13).
- Produces: drill ids `3.1` and `3.2`.

3.1 is the first drill with a `setup.sh`: it seeds a deliberately broken Deployment, and the task is to diagnose it. Selftest runs `setup.sh` in phase 1 only, so phase 2 still sees an empty namespace and the verify script must still fail there.

- [ ] **Step 1: Write `drills/3-observability/01-broken-probe/task.md`**

```markdown
# Diagnose a readiness probe that never passes

**Target time:** 10 min
**Namespace:** `ckad-3-1`

A Deployment named `broken` has been deployed for you. Its Pods are Running
but never Ready, so the Service in front of it has no endpoints.

1. Find out why. Do not change the image, the replica count, or the
   container port the app actually listens on.
2. Fix it so both Pods reach Ready.
3. Record what was wrong: create a ConfigMap named `diagnosis` with a key
   `cause` whose value is exactly `readiness-probe-port`.

Start with `k describe pod` and read the Events, then compare what the probe
asks for against what the container exposes. `k get events --sort-by=.lastTimestamp`
is worth the muscle memory.
```

- [ ] **Step 2: Write `setup.sh` — the deliberately broken state**

```bash
#!/usr/bin/env bash
# Seeds a Deployment whose readiness probe targets a port nothing listens on.
# NS is exported by ckad start and by selftest.
set -euo pipefail

kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken
  template:
    metadata:
      labels:
        app: broken
    spec:
      containers:
        - name: broken
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 8081
            periodSeconds: 5
EOF

kubectl -n "$NS" expose deployment broken --port=80 --name=broken >/dev/null
```

- [ ] **Step 3: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-3-1

assert_exists deployment/broken
# The image must not have been swapped out to dodge the problem.
assert_jsonpath deployment/broken '{.spec.template.spec.containers[0].image}' 'nginx:1.27-alpine'
assert_jsonpath deployment/broken '{.spec.replicas}' '2'
assert_jsonpath deployment/broken \
  '{.spec.template.spec.containers[0].readinessProbe.httpGet.port}' '80'

retry_until 180 assert_pod_ready -l app=broken --count 2

# The symptom this drill is really about: a Service with no ready endpoints
# cannot route. readyReplicas is the order-independent way to assert it -
# comparing endpoint IPs positionally is flaky, since Pod ordering is not
# guaranteed.
assert_exists endpoints/broken
retry_until 60 assert_jsonpath deployment/broken '{.status.readyReplicas}' '2'

assert_exists configmap/diagnosis
assert_jsonpath configmap/diagnosis '{.data.cause}' 'readiness-probe-port'

finish
```

- [ ] **Step 4: Confirm it fails, then write the solution**

```bash
chmod +x drills/3-observability/01-broken-probe/{setup.sh,verify.sh}
bash bin/selftest.sh 3.1
```
Expected: FAIL — no `.solution`.

`.solution/deployment.yaml` — the same Deployment with the probe pointed at the port nginx actually serves:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken
  template:
    metadata:
      labels:
        app: broken
    spec:
      containers:
        - name: broken
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 5
```

`.solution/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: diagnosis
data:
  cause: readiness-probe-port
```

- [ ] **Step 5: Run selftest for 3.1**

Run: `bash bin/selftest.sh 3.1`
Expected: PASS. Phase 1 applies the fix over the broken Deployment; phase 2 sees an empty namespace and the verify script fails as it must.

- [ ] **Step 6: Write `drills/3-observability/02-slow-start/task.md`**

```markdown
# Three probes for a slow-starting app

**Target time:** 12 min
**Namespace:** `ckad-3-2`

Create a Deployment named `web`: 2 replicas, Pod label `app=web`, one
container named `web`, image `nginx:1.27-alpine`, overridden to take about 20
seconds before it serves anything:

    command: ["sh", "-c", "sleep 20; nginx -g 'daemon off;'"]

Give it all three probes, all `httpGet` on path `/` port `80`:

1. A `startupProbe` with `periodSeconds: 3` and `failureThreshold: 10`.
2. A `readinessProbe` with `periodSeconds: 5`.
3. A `livenessProbe` with `periodSeconds: 10`.

Both Pods must reach Ready.

The point: with a startupProbe, the liveness probe does not run until startup
succeeds, so a slow boot no longer gets the container killed. Try it without
the startupProbe and watch the restart count climb — that is the failure this
drill exists to make memorable.
```

- [ ] **Step 7: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-3-2

C='{.spec.template.spec.containers[0]}'

assert_exists deployment/web
assert_jsonpath deployment/web '{.spec.replicas}' '2'

assert_jsonpath deployment/web "$C.startupProbe.httpGet.path"      '/'
assert_jsonpath deployment/web "$C.startupProbe.httpGet.port"      '80'
assert_jsonpath deployment/web "$C.startupProbe.periodSeconds"     '3'
assert_jsonpath deployment/web "$C.startupProbe.failureThreshold"  '10'

assert_jsonpath deployment/web "$C.readinessProbe.httpGet.port"    '80'
assert_jsonpath deployment/web "$C.readinessProbe.periodSeconds"   '5'

assert_jsonpath deployment/web "$C.livenessProbe.httpGet.port"     '80'
assert_jsonpath deployment/web "$C.livenessProbe.periodSeconds"    '10'

retry_until 180 assert_pod_ready -l app=web --count 2

# A restart here means the liveness probe fired during startup, which is
# exactly what the startupProbe is supposed to prevent.
assert_jsonpath deployment/web '{.status.readyReplicas}' '2'

finish
```

- [ ] **Step 8: Confirm it fails, then write `.solution/deployment.yaml`**

Run: `chmod +x drills/3-observability/02-slow-start/verify.sh && bash bin/selftest.sh 3.2`
Expected: FAIL — no `.solution`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          command: ["sh", "-c", "sleep 20; nginx -g 'daemon off;'"]
          ports:
            - containerPort: 80
          startupProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 3
            failureThreshold: 10
          readinessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            periodSeconds: 10
```

`failureThreshold: 10` with `periodSeconds: 3` allows 30 seconds of startup, which covers the 20-second sleep with margin. Tightening it to 5 is how you get a CrashLoopBackOff that looks like an application bug.

- [ ] **Step 9: Run selftest for 3.2**

Run: `bash bin/selftest.sh 3.2`
Expected: PASS — roughly 60 seconds, since each Pod sleeps 20 seconds before serving.

- [ ] **Step 10: Commit**

```bash
git add drills/3-observability
git commit -m "feat: add domain 3 drills - probe diagnosis and startup probes"
```

---

### Task 15: Domain 4 drills — Application Environment, Config & Security (25%)

The heaviest domain on the exam.

**Files:**
- Create: `drills/4-app-environment/01-config-secret/{task.md,verify.sh,.solution/{configmap.yaml,secret.yaml,deployment.yaml}}`
- Create: `drills/4-app-environment/02-nonroot-limits/{task.md,verify.sh,.solution/deployment.yaml}`

**Interfaces:**
- Consumes: `lib/assert.sh`, `bin/selftest.sh`.
- Produces: drill ids `4.1` and `4.2`.

- [ ] **Step 1: Write `drills/4-app-environment/01-config-secret/task.md`**

```markdown
# ConfigMap as a volume, Secret as environment variables

**Target time:** 12 min
**Namespace:** `ckad-4-1`

Both ways of injecting configuration, in one Pod.

1. A ConfigMap named `app-config` with one key `app.properties` whose content
   includes the line `mode=production`.
2. A Secret named `app-secret` with keys `DB_USER=appuser` and
   `DB_PASS=s3cr3t`.
3. A Deployment named `cfg`, 1 replica, Pod label `app=cfg`, one container
   named `cfg`, image `busybox:1.36`, command `sleep 3600`, where:
   - `app-config` is mounted as a volume named `config` at `/etc/app`, so
     `/etc/app/app.properties` exists inside the container;
   - every key of `app-secret` arrives as an environment variable, injected
     with `envFrom` rather than listed one at a time.

Check your work from inside the container:
`k exec deploy/cfg -- cat /etc/app/app.properties` and
`k exec deploy/cfg -- printenv DB_PASS`.

Generate the Secret with `k create secret generic` — writing base64 by hand
is a waste of exam time and an easy place to typo.
```

- [ ] **Step 2: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-4-1

T='{.spec.template.spec}'

assert_exists configmap/app-config
assert_exists secret/app-secret
# Secret values are base64 in the API; s3cr3t encodes to czNjcjN0.
assert_jsonpath secret/app-secret '{.data.DB_PASS}' 'czNjcjN0'
assert_jsonpath secret/app-secret '{.data.DB_USER}' 'YXBwdXNlcg=='

assert_exists deployment/cfg
assert_jsonpath deployment/cfg "$T.volumes[?(@.name==\"config\")].configMap.name" 'app-config'
assert_jsonpath deployment/cfg \
  "$T.containers[0].volumeMounts[?(@.name==\"config\")].mountPath" '/etc/app'
# envFrom, not a hand-listed env block.
assert_jsonpath deployment/cfg "$T.containers[0].envFrom[0].secretRef.name" 'app-secret'

retry_until 120 assert_pod_ready -l app=cfg --count 1

# The checks that matter: the file and the variable as the process sees them.
assert_exec -l app=cfg --contains 'mode=production' -- cat /etc/app/app.properties
assert_exec -l app=cfg --contains 's3cr3t'          -- printenv DB_PASS
assert_exec -l app=cfg --contains 'appuser'         -- printenv DB_USER

finish
```

- [ ] **Step 3: Confirm it fails, then write the solution**

Run: `chmod +x drills/4-app-environment/01-config-secret/verify.sh && bash bin/selftest.sh 4.1`
Expected: FAIL — no `.solution`.

`.solution/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  app.properties: |
    mode=production
    log.level=info
```

`.solution/secret.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
stringData:
  DB_USER: appuser
  DB_PASS: s3cr3t
```

`stringData` lets the API server do the base64 encoding. The equivalent imperative command is
`k create secret generic app-secret --from-literal=DB_USER=appuser --from-literal=DB_PASS=s3cr3t`.

`.solution/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cfg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cfg
  template:
    metadata:
      labels:
        app: cfg
    spec:
      volumes:
        - name: config
          configMap:
            name: app-config
      containers:
        - name: cfg
          image: busybox:1.36
          command: ["sleep", "3600"]
          envFrom:
            - secretRef:
                name: app-secret
          volumeMounts:
            - name: config
              mountPath: /etc/app
```

- [ ] **Step 4: Run selftest for 4.1**

Run: `bash bin/selftest.sh 4.1`
Expected: PASS.

- [ ] **Step 5: Write `drills/4-app-environment/02-nonroot-limits/task.md`**

```markdown
# Run as non-root, and say what you need

**Target time:** 12 min
**Namespace:** `ckad-4-2`

Create a Deployment named `secure`, 1 replica, Pod label `app=secure`, one
container named `secure`, that satisfies a hardened-cluster policy:

1. Pod-level `securityContext`: `runAsNonRoot: true`, `runAsUser: 101`.
2. Container-level `securityContext`: `allowPrivilegeEscalation: false`, and
   all capabilities dropped (`drop: ["ALL"]`).
3. Resource `requests` of `cpu: 100m` / `memory: 64Mi` and `limits` of
   `cpu: 200m` / `memory: 128Mi`.
4. The Pod must reach Ready.

Start from `nginx:1.27-alpine` and watch it fail: that image's entrypoint
binds port 80, which is privileged, and writes to paths only root can write.
Part of this task is recognising that the fix is a different image, not a
looser policy — use `nginxinc/nginx-unprivileged:1.27-alpine`, which listens
on 8080 as uid 101.

That substitution is the real lesson. "Make it run as non-root" usually means
"get an image built to run as non-root", not "add a securityContext and hope".
```

- [ ] **Step 6: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-4-2

T='{.spec.template.spec}'

assert_exists deployment/secure
assert_jsonpath deployment/secure "$T.securityContext.runAsNonRoot" 'true'
assert_jsonpath deployment/secure "$T.securityContext.runAsUser"    '101'

assert_jsonpath deployment/secure \
  "$T.containers[0].securityContext.allowPrivilegeEscalation" 'false'
assert_jsonpath deployment/secure \
  "$T.containers[0].securityContext.capabilities.drop[0]" 'ALL'

assert_jsonpath deployment/secure "$T.containers[0].resources.requests.cpu"    '100m'
assert_jsonpath deployment/secure "$T.containers[0].resources.requests.memory" '64Mi'
assert_jsonpath deployment/secure "$T.containers[0].resources.limits.cpu"      '200m'
assert_jsonpath deployment/secure "$T.containers[0].resources.limits.memory"   '128Mi'

retry_until 150 assert_pod_ready -l app=secure --count 1

# Ready is not enough on its own - prove the process is not root.
assert_exec -l app=secure --contains '101' -- id -u

finish
```

Note what this verify script does *not* assert: the image name. A different
non-root-capable image that satisfies every requirement should pass. Pinning
the image here would grade the answer instead of the outcome.

- [ ] **Step 7: Confirm it fails, then write `.solution/deployment.yaml`**

Run: `chmod +x drills/4-app-environment/02-nonroot-limits/verify.sh && bash bin/selftest.sh 4.2`
Expected: FAIL — no `.solution`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure
  template:
    metadata:
      labels:
        app: secure
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
      containers:
          # nginx:1.27-alpine cannot satisfy runAsNonRoot: its entrypoint
          # binds port 80 and writes to root-owned paths. The unprivileged
          # build listens on 8080 as uid 101.
        - name: secure
          image: nginxinc/nginx-unprivileged:1.27-alpine
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

- [ ] **Step 8: Run selftest for 4.2 and the full unit suite**

```bash
bash bin/selftest.sh 4.2
bash tests/run.sh
```
Expected: both PASS.

- [ ] **Step 9: Commit**

```bash
git add drills/4-app-environment
git commit -m "feat: add domain 4 drills - config injection and non-root security"
```

---

### Task 16: Domain 5 drills — Services & Networking (20%)

**Files:**
- Create: `drills/5-services-networking/01-ingress-routing/{task.md,verify.sh,.solution/{blue.yaml,green.yaml,ingress.yaml}}`
- Create: `drills/5-services-networking/02-network-policy/{task.md,setup.sh,verify.sh,.solution/{deny.yaml,allow.yaml}}`

**Interfaces:**
- Consumes: `lib/assert.sh` including `assert_http` and `assert_exec --expect-fail`; ingress-nginx and Calico from Task 9.
- Produces: drill ids `5.1` and `5.2`.

5.2 is the drill that justifies installing Calico. Under kind's default CNI these policies would be accepted by the API server and enforced by nothing, so the behavioural assertions would pass whatever the user wrote.

- [ ] **Step 1: Write `drills/5-services-networking/01-ingress-routing/task.md`**

```markdown
# Path-based Ingress in front of two Services

**Target time:** 14 min
**Namespace:** `ckad-5-1`

1. Two Deployments, `blue` and `green`: 1 replica each, image
   `nginx:1.27-alpine`, Pod labels `app=blue` and `app=green`.
2. A ClusterIP Service for each, named `blue` and `green`, port 80 to
   container port 80.
3. An Ingress named `routes`, ingress class `nginx`, with no host, routing:
   - `/blue`  (pathType `Prefix`) to Service `blue` port 80
   - `/green` (pathType `Prefix`) to Service `green` port 80

Both paths must return HTTP 200 through the ingress controller.

The trap: nginx has no `/blue` directory, so a naive Ingress gives you a 404
from the backend rather than from the controller. You need the
`nginx.ingress.kubernetes.io/rewrite-target: /` annotation so the path is
stripped before the request reaches the Service. Diagnosing 404-from-backend
versus 404-from-controller is the skill here.

Check a Service directly without leaving the cluster:
`k run tmp --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -s http://blue`
```

- [ ] **Step 2: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-5-1

CTRL='http://ingress-nginx-controller.ingress-nginx.svc.cluster.local'

for color in blue green; do
  assert_exists "deployment/$color"
  assert_exists "service/$color"
  assert_jsonpath "service/$color" '{.spec.type}'          'ClusterIP'
  assert_jsonpath "service/$color" '{.spec.ports[0].port}' '80'
  retry_until 150 assert_pod_ready -l "app=$color" --count 1
done

# Services reachable on their own, before involving the Ingress.
retry_until 60 assert_http http://blue  --status 200
retry_until 60 assert_http http://green --status 200

assert_exists ingress/routes
assert_jsonpath ingress/routes '{.spec.ingressClassName}' 'nginx'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/blue")].backend.service.name}'  'blue'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/green")].backend.service.name}' 'green'
assert_jsonpath ingress/routes \
  '{.spec.rules[0].http.paths[?(@.path=="/blue")].pathType}' 'Prefix'

# The assertions that actually prove routing works end to end.
retry_until 120 assert_http "$CTRL/blue"  --status 200
retry_until 120 assert_http "$CTRL/green" --status 200

finish
```

- [ ] **Step 3: Confirm it fails, then write the solution**

Run: `chmod +x drills/5-services-networking/01-ingress-routing/verify.sh && bash bin/selftest.sh 5.1`
Expected: FAIL — no `.solution`.

`.solution/blue.yaml` (and `.solution/green.yaml`, identical with `blue` replaced by `green`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blue
spec:
  replicas: 1
  selector:
    matchLabels:
      app: blue
  template:
    metadata:
      labels:
        app: blue
    spec:
      containers:
        - name: blue
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: blue
spec:
  type: ClusterIP
  selector:
    app: blue
  ports:
    - port: 80
      targetPort: 80
```

`.solution/ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: routes
  annotations:
    # Without this, nginx receives a request for /blue, has no such path, and
    # answers 404 - a backend 404, not a routing failure.
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /blue
            pathType: Prefix
            backend:
              service:
                name: blue
                port:
                  number: 80
          - path: /green
            pathType: Prefix
            backend:
              service:
                name: green
                port:
                  number: 80
```

- [ ] **Step 4: Run selftest for 5.1**

Run: `bash bin/selftest.sh 5.1`
Expected: PASS. The first run pulls `curlimages/curl`, so allow extra time.

- [ ] **Step 5: Write `drills/5-services-networking/02-network-policy/task.md`**

```markdown
# Default-deny, then open one door

**Target time:** 14 min
**Namespace:** `ckad-5-2`

Already deployed for you: a Deployment `api` with Service `api` on port 80,
and two client Pods — `client-allowed` (label `role=frontend`) and
`client-denied` (label `role=batch`). Right now both can reach `api`.

Create two NetworkPolicies:

1. `default-deny` — denies **all** ingress to every Pod in the namespace.
   Its `podSelector` must be empty, and `policyTypes` must list `Ingress`.
2. `allow-frontend` — allows ingress to Pods labelled `app=api`, from Pods
   labelled `role=frontend`, on TCP port 80.

End state: `client-allowed` can reach `http://api`, `client-denied` cannot.

Test from inside:
`k exec client-allowed -- wget -q -T3 -O- http://api`
`k exec client-denied  -- wget -q -T3 -O- http://api`   # must time out

An empty `podSelector: {}` selects every Pod in the namespace — that is what
makes policy 1 a default. Policies are additive and there is no deny rule:
you open traffic back up by adding an allow, never by editing the deny.
```

- [ ] **Step 6: Write `setup.sh`**

```bash
#!/usr/bin/env bash
# Seeds an api Deployment plus two differently-labelled clients, with no
# NetworkPolicy in place, so both clients can reach the api to begin with.
set -euo pipefail

kubectl -n "$NS" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client-allowed
  labels:
    role: frontend
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-denied
  labels:
    role: batch
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF

kubectl -n "$NS" wait --for=condition=Ready pod/client-allowed pod/client-denied --timeout=120s >/dev/null
kubectl -n "$NS" rollout status deployment/api --timeout=120s >/dev/null
```

- [ ] **Step 7: Write `verify.sh`**

```bash
#!/usr/bin/env bash
source "${CKAD_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}/lib/assert.sh"
ns ckad-5-2

assert_exists networkpolicy/default-deny
# An empty podSelector renders as map[] and is what makes this policy a default.
assert_jsonpath networkpolicy/default-deny '{.spec.podSelector}'    'map[]'
assert_jsonpath networkpolicy/default-deny '{.spec.policyTypes[0]}' 'Ingress'

assert_exists networkpolicy/allow-frontend
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.podSelector.matchLabels.app}' 'api'
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.ingress[0].from[0].podSelector.matchLabels.role}' 'frontend'
assert_jsonpath networkpolicy/allow-frontend \
  '{.spec.ingress[0].ports[0].port}' '80'

retry_until 120 assert_pod_ready -l app=api --count 1

# Behaviour, not just spec fields. These two assertions are the drill: a
# policy that parses but enforces nothing fails here.
retry_until 90 assert_exec --pod client-allowed --contains 'Welcome to nginx' \
  -- wget -q -T3 -O- http://api
assert_exec --pod client-denied --expect-fail \
  -- wget -q -T3 -O- http://api

finish
```

- [ ] **Step 8: Confirm it fails, then write the solution**

```bash
chmod +x drills/5-services-networking/02-network-policy/{setup.sh,verify.sh}
bash bin/selftest.sh 5.2
```
Expected: FAIL — no `.solution`.

`.solution/deny.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  # An empty selector means every Pod in the namespace.
  podSelector: {}
  policyTypes:
    - Ingress
```

`.solution/allow.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend
      ports:
        - protocol: TCP
          port: 80
```

- [ ] **Step 9: Run selftest for 5.2, then every drill**

```bash
bash bin/selftest.sh 5.2
bash bin/selftest.sh          # all ten
bash tests/run.sh
```
Expected: `SELFTEST PASSED (10 drills)` and `ALL TESTS PASSED`. The full selftest takes roughly 10-15 minutes — drill 1.2 waits out a Job backoff and several drills roll out multiple replicas.

If 5.2 fails only on the `client-denied` assertion, Calico is not enforcing. Check `kubectl -n kube-system get ds calico-node` and confirm `kind-config.yaml` has `disableDefaultCNI: true` — a cluster built before that line was added keeps kindnet.

- [ ] **Step 10: Commit**

```bash
git add drills/5-services-networking
git commit -m "feat: add domain 5 drills - ingress routing and network policy"
```

---

### Task 17: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything. This is the entry point for a reader who has forgotten how the repo works.

- [ ] **Step 1: Capture the real cluster version**

Run: `kubectl version -o json | grep -A2 serverVersion`
Use the actual `gitVersion` in the README rather than guessing a version.

- [ ] **Step 2: Write `README.md`**

```markdown
# CKAD practice

Self-grading Kubernetes drills, grouped by the CKAD curriculum domains and run
against a local three-node kind cluster.

## One-time setup

    winget install Kubernetes.kind      # kubectl and docker are already present
    # start Docker Desktop, wait for "Running"
    bash cluster/bootstrap.sh           # ~4 min: cluster, Calico, ingress, metrics

Cluster: 1 control-plane + 2 workers (labelled `disk=ssd` and `zone=a` for
nodeSelector practice), Kubernetes <paste gitVersion from Step 1>.

## Every session

    source bin/setup-shell.sh    # k, kgp, kn, $do, $now, $yd
    ckad list                    # what is there, and how you did last time

Add `bin/` to your PATH, or call it as `bash bin/ckad`.

## The loop

    ckad start 3.2      # prints the task, creates ckad-3-2, starts the timer
    # ... work in scratch/3.2/ ...
    ckad verify 3.2     # per-requirement pass/fail against the live cluster
    ckad solution 3.2   # only after one verify attempt
    ckad reset 3.2      # wipe the namespace and try again
    ckad score          # which domain to grind next

Assertions read the live cluster, never your files — solving a drill
imperatively with `kubectl create` passes exactly like an applied manifest.

## Drills

| Domain | Weight | Drills |
|---|---|---|
| 1 Design & Build | 20% | sidecar + emptyDir, init container + Job backoff |
| 2 Deployment | 20% | rollout and undo, kustomize overlay |
| 3 Observability | 15% | diagnose a broken probe, startup/readiness/liveness |
| 4 App Environment | 25% | ConfigMap volume + Secret env, non-root + limits |
| 5 Services & Networking | 20% | path-based Ingress, default-deny NetworkPolicy |

## Exam-day shorthands

| What | How |
|---|---|
| Generate YAML, create nothing | `k run web --image=nginx:1.27-alpine $do > p.yaml` |
| Deployment skeleton | `k create deploy api --image=nginx:1.27-alpine $do` |
| Delete immediately | `k delete pod web $now` |
| Switch namespace | `kn ckad-3-2` |
| Why is it not Ready | `k describe pod <p>` then `k get events --sort-by=.lastTimestamp` |
| Previous container's logs | `k logs <p> --previous` |
| One field, scriptably | `k get deploy api -o jsonpath='{.spec.replicas}'` |
| Explain a field | `k explain deploy.spec.strategy --recursive` |

`k explain` works offline and is faster than the docs site. Practice it.

## Adding a drill

    drills/<domain>/<nn>-<slug>/
      task.md       # H1 title, "**Target time:** N min", numbered requirements
      setup.sh      # optional; seeds state, $NS is exported
      verify.sh     # source lib/assert.sh, ns <namespace>, assert, finish
      .solution/    # *.yaml, or apply.sh for command sequences

Then: `bash bin/selftest.sh <id>` — it checks that your solution satisfies
your verify script, and that the verify script fails on an empty namespace.
The second check is the one that catches a drill that silently grades nothing.

## Repo tests

    bash tests/run.sh        # unit tests, no cluster needed (stub kubectl)
    bash bin/selftest.sh     # all drills, needs the cluster, ~15 min
```

- [ ] **Step 3: Verify the README's own instructions**

Follow the "Every session" and "The loop" sections literally from a fresh shell on a drill you have not done. Anything that does not work as written is a README bug — fix it now, while you still remember the real commands.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add README with setup, drill loop and exam shorthands"
```

---

## Plan Self-Review

**Spec coverage.** Every spec section maps to a task: repo layout → Tasks 1-11 collectively; `kind-config.yaml` and `bootstrap.sh` → Task 9; `ckad` CLI commands → Tasks 7-8 (all six commands present); `lib/assert.sh` primitives → Tasks 3-4 (all eight plus `retry_until`); namespace isolation → Task 7 `cmd_start` and Task 8 `cmd_reset`; gated solutions → Task 8; state file → Task 6; `setup-shell.sh` → Task 10; `selftest.sh` → Task 11; the ten drills → Tasks 12-16; error-handling requirements → Task 9 preflight, Task 7 `_resolve`, Task 3 `_ns_ok`, Task 4 `retry_until` bounds.

**Deviations from the spec**, all recorded in Global Constraints: flat state file instead of `.ckad-state.json` (no `jq`); `helm` and standalone `kustomize` dropped as prerequisites (`kubectl apply -k` suffices); Calico added as the CNI (kindnet does not enforce NetworkPolicy, which would make drill 5.2 fraudulent); `.gitattributes` added; `.solution/apply.sh` convention added in Task 13 for drills whose answer is a command sequence.

**Type and name consistency.** `_resolve_target` is used by `assert_pod_ready` and `assert_logs`; `assert_exec` deliberately does not use it, because `kubectl exec` rejects `-l` and needs a resolved pod name. `NS` is the exported variable name in `setup.sh`, `apply.sh`, `cmd_start`, `cmd_verify`, and `selftest.sh`. `CKAD_ROOT`, `DRILLS_ROOT`, `CKAD_STATE`, and `SCRATCH_ROOT` are honored by every component that reads a path.

**Known timing costs.** Task 9 bootstrap is 3-5 minutes; drill 1.2 selftest waits out a Job backoff (up to 4 minutes); the full `bin/selftest.sh` run is 10-15 minutes. These are inherent to testing against a real cluster, not signs of a problem.

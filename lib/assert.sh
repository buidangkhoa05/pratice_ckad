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
  # ckad-3-2 -> 3.2: strip the prefix, then turn the dash back into the dot
  # the CLI expects, so the hint is a command the user can actually paste.
  local id="${ASSERT_NS#ckad-}"
  report_fail "namespace $ASSERT_NS exists" \
              "namespace present" \
              "not found - run: ckad start ${id//-/.}"
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

  # MSYS2_ARG_CONV_EXCL is not optional on Git Bash. Without it, MSYS rewrites
  # any argument that looks like an absolute Unix path into a Windows path
  # before kubectl sees it, so `cat /usr/share/nginx/html/index.html` arrives
  # in the container as `cat C:/Program Files/Git/usr/share/...`. Scoped to
  # this call because selftest's `kubectl apply -f <host path>` still needs
  # the conversion.
  out="$(MSYS2_ARG_CONV_EXCL='*' _k exec "$target_pod" "${cargs[@]}" -- "$@" 2>&1)"; rc=$?

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

  # Run detached, wait for the pod to finish, then read its logs. The obvious
  # `kubectl run --rm -i` does not work here: --quiet suppresses the container
  # output entirely, and without it the attach races the container so the
  # status code is lost and only "pod deleted" comes back.
  local pod="probe-$RANDOM" phase="" i
  _k run "$pod" --restart=Never --image=curlimages/curl:8.10.1 --command -- \
      curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" >/dev/null 2>&1

  for (( i = 0; i < 30; i++ )); do
    phase="$(_k get "pod/$pod" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done

  # curl without -f exits 0 for any response, so a 404 still lands in the
  # logs; a connection failure exits non-zero and logs 000.
  got="$(_k logs "pod/$pod" 2>/dev/null | tr -d '[:space:]')"
  _k delete "pod/$pod" --ignore-not-found --wait=false >/dev/null 2>&1

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
  # CKAD_RETRY_MAX caps every wait. selftest sets it low for the
  # empty-namespace phase, where nothing will ever become ready and waiting
  # the full budget of every assertion costs minutes per drill.
  if [[ -n "${CKAD_RETRY_MAX:-}" ]] && (( timeout > CKAD_RETRY_MAX )); then
    timeout="$CKAD_RETRY_MAX"
  fi
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

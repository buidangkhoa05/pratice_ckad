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

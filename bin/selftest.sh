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

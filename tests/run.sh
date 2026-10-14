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

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
  printf '%s✓%s %s\n' "$_C_OK" "$_C_OFF" "$1"
}

report_fail() { # <desc> [expected] [actual]
  REPORT_FAIL=$(( REPORT_FAIL + 1 ))
  printf '%s✗%s %s\n' "$_C_BAD" "$_C_OFF" "$1"
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

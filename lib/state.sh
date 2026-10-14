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

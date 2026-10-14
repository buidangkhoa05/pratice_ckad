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

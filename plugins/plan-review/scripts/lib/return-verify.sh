# lib/return-verify.sh — shared helpers for the return-verify gate
# (return-verify-mark.sh / return-verify-clear.sh / return-verify-gate.sh).
#
# The gate requires the main session to run at least one read-only
# verification (Bash/Read/Grep/Glob) after every sub-agent SubagentStop
# before it is allowed to dispatch another Agent/Task call. This file only
# provides the shared directory/TTL/armed-check primitives; each script owns
# its own read/write of the `.return-verify-<session_id>` state file.
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.

# rv_marker_dir — prints the marker directory (shared with main-edit-gate.sh
# and dispatch-check.sh; same env var, same default).
rv_marker_dir() {
  printf '%s' "${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
}

# rv_ttl_min — prints the return-verify-gate TTL in minutes. A non-numeric or
# empty override falls back to the documented default (same guard as
# main-edit-gate.sh's MAIN_EDIT_GATE_TTL_MIN handling).
rv_ttl_min() {
  local ttl="${RETURN_VERIFY_TTL_MIN:-180}"
  case "$ttl" in
    ''|*[!0-9]*) ttl=180 ;;
  esac
  printf '%s' "$ttl"
}

# rv_gate_armed <session_id> — returns 0 when the main-edit-gate marker for
# this session exists, is not older than MAIN_EDIT_GATE_TTL_MIN minutes, and
# has valid JSON with agent_rows >= 1; returns 1 otherwise. Mirrors
# main-edit-gate.sh's own armed-check (lines 45-63) but never deletes the
# marker and never writes any output — this is a pure read-only predicate
# shared by all three return-verify scripts.
rv_gate_armed() {
  local session_id="$1"
  local marker_dir marker_file ttl_min
  marker_dir="$(rv_marker_dir)"
  marker_file="$marker_dir/.main-edit-gate-${session_id}"
  ttl_min="${MAIN_EDIT_GATE_TTL_MIN:-180}"
  case "$ttl_min" in
    ''|*[!0-9]*) ttl_min=180 ;;
  esac

  [ -f "$marker_file" ] || return 1

  local file_mtime now ttl_sec
  file_mtime=$(stat -f %m "$marker_file" 2>/dev/null || stat -c %Y "$marker_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  ttl_sec=$(( ttl_min * 60 ))
  if (( now - file_mtime > ttl_sec )); then
    return 1
  fi

  local agent_rows
  agent_rows=$(jq -r '.agent_rows // 0' "$marker_file" 2>/dev/null || echo 0)
  case "$agent_rows" in
    ''|*[!0-9]*) agent_rows=0 ;;
  esac
  [ "$agent_rows" -ge 1 ] || return 1

  return 0
}

# rv_cleanup_stale — deletes .return-verify-* state files older than
# rv_ttl_min minutes. Fail-silent (matches every other stale-cleanup call
# site in this plugin).
rv_cleanup_stale() {
  local marker_dir ttl_min
  marker_dir="$(rv_marker_dir)"
  ttl_min="$(rv_ttl_min)"
  find "$marker_dir" -maxdepth 1 -name '.return-verify-*' -mmin "+${ttl_min}" -delete 2>/dev/null || true
}

#!/bin/bash
# SubagentStop hook — return-verify-gate bookkeeping (mark phase).
#
# Whenever a sub-agent finishes while the main-edit-gate is armed for its
# parent session, this hook appends that agent to the
# `.return-verify-<session_id>` pending list. return-verify-gate.sh then
# denies the next Agent/Task dispatch until return-verify-clear.sh observes
# the main session running at least one read-only tool call
# (Bash/Read/Grep/Glob).
#
# Unlike main-edit-gate.sh, this hook does NOT skip on a non-empty agent_id/
# agent_type — SubagentStop's session_id is the PARENT session, and
# agent_id/agent_type identify the sub-agent that just stopped, which is
# exactly the event being recorded.
#
# Environment variables:
#   RETURN_VERIFY_GATE_DISABLED=1  — kill switch, bypass entirely
#   REVIEW_COUNTER_DIR             — marker directory (default: /tmp/claude-reviews)
#   RETURN_VERIFY_TTL_MIN          — pending-state TTL in minutes (default: 180)
#   MAIN_EDIT_GATE_TTL_MIN         — main-edit-gate marker TTL in minutes (default: 180)
set -euo pipefail

INPUT=$(cat)

[ "${RETURN_VERIFY_GATE_DISABLED:-0}" != "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

RV_LIB="$(dirname "$0")/lib/return-verify.sh"
[ -s "$RV_LIB" ] || exit 0
if ! . "$RV_LIB"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$SESSION_ID" ] || exit 0

rv_gate_armed "$SESSION_ID" || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)

MARKER_DIR="$(rv_marker_dir)"
mkdir -p "$MARKER_DIR" 2>/dev/null || true
STATE_FILE="$MARKER_DIR/.return-verify-${SESSION_ID}"

EXISTING="[]"
if [ -f "$STATE_FILE" ]; then
  EXISTING_PENDING=$(jq -r '.pending // [] | tojson' "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$EXISTING_PENDING" ]; then
    EXISTING="$EXISTING_PENDING"
  fi
fi
# Guard against a corrupt/non-array pending field (e.g. hand-edited state) —
# treat anything that doesn't parse as a JSON array as an empty backlog.
printf '%s' "$EXISTING" | jq -e 'type == "array"' >/dev/null 2>&1 || EXISTING="[]"

NOW=$(date +%s)
NEW_STATE=$(jq -n \
  --argjson pending "$EXISTING" \
  --arg agent_id "$AGENT_ID" \
  --arg agent_type "$AGENT_TYPE" \
  --argjson stopped_at "$NOW" \
  --argjson updated_at "$NOW" \
  '{pending: ($pending + [{agent_id: $agent_id, agent_type: $agent_type, stopped_at: $stopped_at}]), updated_at: $updated_at}' \
  2>/dev/null) || exit 0
[ -n "$NEW_STATE" ] || exit 0

TEMP_FILE=$(mktemp "$MARKER_DIR/.return-verify-${SESSION_ID}.XXXXXX" 2>/dev/null || true)
[ -n "$TEMP_FILE" ] || exit 0
printf '%s' "$NEW_STATE" > "$TEMP_FILE" 2>/dev/null || { rm -f "$TEMP_FILE" 2>/dev/null || true; exit 0; }
mv -f "$TEMP_FILE" "$STATE_FILE" 2>/dev/null || rm -f "$TEMP_FILE" 2>/dev/null || true

exit 0

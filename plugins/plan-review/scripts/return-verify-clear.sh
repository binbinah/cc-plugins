#!/bin/bash
# PostToolUse:Bash/Read/Grep/Glob hook — return-verify-gate bookkeeping
# (clear phase).
#
# Whenever the MAIN session (not a sub-agent) runs a read-only tool call,
# this hook deletes the `.return-verify-<session_id>` pending-verification
# state, satisfying the return-verify-gate for the next Agent/Task dispatch.
# PostToolUse never makes a permission decision, so this hook always exits 0
# with no stdout.
#
# Environment variables:
#   RETURN_VERIFY_GATE_DISABLED=1  — kill switch, bypass entirely
#   REVIEW_COUNTER_DIR             — marker directory (default: /tmp/claude-reviews)
set -euo pipefail

INPUT=$(cat)

[ "${RETURN_VERIFY_GATE_DISABLED:-0}" != "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$SESSION_ID" ] || exit 0

# Sub-agents' own tool calls carry a distinct identity — they don't count as
# the main session's verification.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)
[ -z "$AGENT_ID" ] || exit 0
[ -z "$AGENT_TYPE" ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL_NAME" in
  Bash|Read|Grep|Glob) ;;
  *) exit 0 ;;
esac

MARKER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
rm -f "$MARKER_DIR/.return-verify-${SESSION_ID}" 2>/dev/null || true

exit 0

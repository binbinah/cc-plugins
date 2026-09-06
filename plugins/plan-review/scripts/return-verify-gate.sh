#!/bin/bash
# PreToolUse:Agent/Task hook — return-verify gate.
#
# While the main-edit-gate is armed for this session, every SubagentStop
# recorded by return-verify-mark.sh must be followed by at least one
# read-only tool call from the MAIN session (Bash/Read/Grep/Glob — cleared by
# return-verify-clear.sh) before the main session may dispatch another
# Agent/Task call. This enforces "verify what came back before sending the
# next agent" — it does not track step order, count, or which specific agent
# must be verified.
#
# Fail open on missing jq, missing session_id, sub-agent calls, a missing/
# corrupt/empty/stale pending state, or an expired/missing main-edit-gate
# marker (see rv_gate_armed in lib/return-verify.sh).
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

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL_NAME" in
  Agent|Task) ;;
  *) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$SESSION_ID" ] || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)
[ -z "$AGENT_ID" ] || exit 0
[ -z "$AGENT_TYPE" ] || exit 0

rv_cleanup_stale

MARKER_DIR="$(rv_marker_dir)"
TTL_MIN="$(rv_ttl_min)"
STATE_FILE="$MARKER_DIR/.return-verify-${SESSION_ID}"

[ -f "$STATE_FILE" ] || exit 0

file_mtime=$(stat -f %m "$STATE_FILE" 2>/dev/null || stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
ttl_sec=$(( TTL_MIN * 60 ))
if (( now - file_mtime > ttl_sec )); then
  rm -f "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

if ! rv_gate_armed "$SESSION_ID"; then
  rm -f "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

PENDING_COUNT=$(jq -r '.pending // [] | length' "$STATE_FILE" 2>/dev/null || echo 0)
case "$PENDING_COUNT" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$PENDING_COUNT" -ge 1 ] || exit 0

PENDING_LIST=$(jq -r '
  [.pending[] | (.agent_type // "unknown") + "/" + ((.agent_id // "")[0:8])] | join("、")
' "$STATE_FILE" 2>/dev/null || true)
[ -n "$PENDING_LIST" ] || PENDING_LIST="unknown"

MSG=$(printf '回传核验门禁（return-verify-gate）：有 %s 个子代理已回传但主会话尚未做任何只读核验（%s），先跑至少一条只读命令取证（git diff --stat、wc -l、测试报告汇总、rg 关键符号或 Read 关键文件），再派下一步。确需关闭：设置 RETURN_VERIFY_GATE_DISABLED=1；标记在 %s 分钟后自动失效。' \
  "$PENDING_COUNT" "$PENDING_LIST" "$TTL_MIN")
DENY_JSON=$(printf '%s' "$MSG" | jq -Rs .)
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${DENY_JSON}}}
EOF
exit 0

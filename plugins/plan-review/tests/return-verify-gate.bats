#!/usr/bin/env bats
# BDD tests for the return-verify gate (return-verify-mark.sh,
# return-verify-clear.sh, return-verify-gate.sh).
#
# Once main-edit-gate.sh is armed for a session, every SubagentStop is
# recorded into `.return-verify-<session_id>` (mark). A main-session
# Bash/Read/Grep/Glob call clears it (clear). While pending entries remain,
# return-verify-gate.sh denies the next Agent/Task dispatch (gate). All three
# fail open on missing jq, missing session_id, sub-agent identity, and a
# missing/stale/corrupt state.

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

STATE_FILE() {
  printf '%s' "${REVIEW_COUNTER_DIR}/.return-verify-${1:-test-session}"
}

# =============================================================================
# mark (SubagentStop)
# =============================================================================

@test "mark: unarmed main-edit-gate does not write state" {
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$(STATE_FILE)" ]
}

@test "mark: armed gate writes pending with correct agent_id" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ "$HOOK_EXIT" -eq 0 ]
  [ -f "$(STATE_FILE)" ]
  local aid
  aid=$(jq -r '.pending[0].agent_id' "$(STATE_FILE)")
  [ "$aid" = "a1" ]
}

@test "mark: connective two stops accumulate pending length 2" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  INPUT=$(build_hook_input session_id=test-session agent_id=a2 agent_type=Explore)
  run_return_verify_mark
  local len
  len=$(jq -r '.pending | length' "$(STATE_FILE)")
  [ "$len" = "2" ]
}

@test "mark: RETURN_VERIFY_GATE_DISABLED=1 does not write" {
  create_main_edit_gate_marker "test-session" 2
  export RETURN_VERIFY_GATE_DISABLED=1
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ ! -f "$(STATE_FILE)" ]
}

@test "mark: missing session_id does not write" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_hook_input agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$(STATE_FILE)" ]
}

@test "mark: main-edit-gate agent_rows=0 does not write" {
  create_main_edit_gate_marker "test-session" 0
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ ! -f "$(STATE_FILE)" ]
}

@test "mark: stdout is always empty" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_hook_input session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_mark
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# clear (PostToolUse: Bash/Read/Grep/Glob)
# =============================================================================

@test "clear: main-session Bash call deletes state file" {
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Bash session_id=test-session)
  run_return_verify_clear
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$(STATE_FILE)" ]
}

@test "clear: main-session Read call deletes state file" {
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Read session_id=test-session)
  run_return_verify_clear
  [ ! -f "$(STATE_FILE)" ]
}

@test "clear: sub-agent Bash call (agent_id set) does not delete" {
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Bash session_id=test-session agent_id=a1 agent_type=general-purpose)
  run_return_verify_clear
  [ -f "$(STATE_FILE)" ]
}

@test "clear: main-session Edit call does not delete" {
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Edit session_id=test-session)
  run_return_verify_clear
  [ -f "$(STATE_FILE)" ]
}

@test "clear: state file already absent exits 0 with no output" {
  INPUT=$(build_hook_input tool_name=Bash session_id=test-session)
  run_return_verify_clear
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# gate (PreToolUse: Agent/Task)
# =============================================================================

@test "gate: pending state denies with return-verify-gate and agent_type in reason" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"return-verify-gate"* ]]
  [[ "$reason" == *"general-purpose"* ]]
}

@test "gate: after clear (no state file) allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: non-empty agent_id bypasses (nested dispatch), allows" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session agent_id=a9 agent_type=general-purpose)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: RETURN_VERIFY_GATE_DISABLED=1 allows" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1
  export RETURN_VERIFY_GATE_DISABLED=1
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: Task tool call also denies" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Task session_id=test-session)
  run_return_verify_gate
  assert_deny_json
}

@test "gate: invalid JSON state file allows" {
  create_main_edit_gate_marker "test-session" 2
  printf 'not json at all' > "$(STATE_FILE)"
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: empty pending array allows" {
  create_main_edit_gate_marker "test-session" 2
  jq -n '{pending: [], updated_at: 0}' > "$(STATE_FILE)"
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

@test "gate: state file mtime past TTL allows and deletes the file" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1
  export RETURN_VERIFY_TTL_MIN=1
  touch -t 202001010000 "$(STATE_FILE)"
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$(STATE_FILE)" ]
}

@test "gate: missing main-edit-gate marker allows and deletes stale return-verify state" {
  create_return_verify_marker "test-session" 1
  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  run_return_verify_gate
  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
  [ ! -f "$(STATE_FILE)" ]
}

@test "gate: no jq on PATH allows" {
  create_main_edit_gate_marker "test-session" 2
  create_return_verify_marker "test-session" 1

  local restricted_bin="${TEST_TEMP_DIR}/restricted_bin_gate"
  mkdir -p "$restricted_bin"
  for cmd in bash cat grep head tr printf mkdir rm find xargs ls echo mktemp chmod sed stat date; do
    local cmd_path
    cmd_path=$(command -v "$cmd" 2>/dev/null) || continue
    ln -sf "$cmd_path" "${restricted_bin}/${cmd}"
  done

  INPUT=$(build_hook_input tool_name=Agent session_id=test-session)
  local orig_path="$PATH"
  export PATH="$restricted_bin"
  run_return_verify_gate
  export PATH="$orig_path"

  [ "$HOOK_EXIT" -eq 0 ]
  [ -z "$HOOK_STDOUT" ]
}

# =============================================================================
# hooks.json registration
# =============================================================================

@test "hooks.json: three return-verify scripts are registered on the right events" {
  local hooks_json="${BATS_TEST_DIRNAME}/../hooks/hooks.json"

  # SubagentStop → return-verify-mark.sh
  run jq -e '.hooks.SubagentStop[].hooks[] | select(.command | contains("return-verify-mark.sh"))' "$hooks_json"
  [ "$status" -eq 0 ]

  # PostToolUse → return-verify-clear.sh on all four matchers
  for m in Bash Read Grep Glob; do
    run jq -e --arg m "$m" '.hooks.PostToolUse[] | select(.matcher == $m) | .hooks[] | select(.command | contains("return-verify-clear.sh"))' "$hooks_json"
    [ "$status" -eq 0 ]
  done

  # PreToolUse Agent/Task → return-verify-gate.sh present and ordered after dispatch-check.sh
  for m in Agent Task; do
    run jq -e --arg m "$m" '
      [.hooks.PreToolUse[] | select(.matcher == $m)][0].hooks
      | (map(.command) | index("bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-check.sh")) as $d
      | (map(.command) | index("bash ${CLAUDE_PLUGIN_ROOT}/scripts/return-verify-gate.sh")) as $r
      | ($d != null and $r != null and $d < $r)
    ' "$hooks_json"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

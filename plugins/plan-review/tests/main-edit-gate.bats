#!/usr/bin/env bats
# BDD tests for the main-session edit gate (main-edit-gate.sh).
#
# Once plan-review.sh APPROVEs a plan whose Dispatch Manifest carries at
# least one agent-location row, it writes a `.main-edit-gate-<session>`
# marker. While that marker is live, Edit/Write/MultiEdit/NotebookEdit and a
# best-effort family of Bash write commands are denied for paths under cwd
# (except .md files and anything under .claude/). Missing jq, missing
# session_id, sub-agent calls, and a missing/stale/corrupt marker all fail
# open.

setup() {
  load 'test_helper/common-setup'
  common_setup
  unset MAIN_EDIT_GATE_DISABLED
  unset MAIN_EDIT_GATE_TTL_MIN

  PROJ="${TEST_TEMP_DIR}/proj"
  mkdir -p "${PROJ}/src" "${PROJ}/.claude"
}

teardown() {
  common_teardown
}

# assert_gate_deny — assert_deny_json plus the main-edit-gate attribution
# every deny reason must carry.
assert_gate_deny() {
  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"main-edit-gate"* ]] || {
    echo "Expected reason to contain 'main-edit-gate', got: $reason"
    return 1
  }
}

# assert_gate_deny_unknown — assert_gate_deny plus confirms the reason marks
# the target as statically undecidable (the "unknown" verdict branch), not
# merely any deny.
assert_gate_deny_unknown() {
  assert_gate_deny
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"无法静态判定"* ]] || {
    echo "Expected reason to contain '无法静态判定', got: $reason"
    return 1
  }
}

# =============================================================================
# Marker lifecycle / bypass conditions
# =============================================================================

@test "gate: no marker allows Edit inside project" {
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: armed marker denies Edit on project source" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: .md file is always allowed" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.md")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: path under .claude/ is always allowed" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/.claude/x.json")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: path outside cwd is allowed" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="/tmp/outside/A.java")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: non-empty agent_id bypasses the gate" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java" agent_id=a1)
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: non-empty agent_type bypasses the gate" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java" agent_type=general-purpose)
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: expired marker allows and deletes itself" {
  create_main_edit_gate_marker "test-session" 2
  touch -t 202001010000 "${REVIEW_COUNTER_DIR}/.main-edit-gate-test-session"
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_allowed
  [ ! -f "${REVIEW_COUNTER_DIR}/.main-edit-gate-test-session" ]
}

@test "gate: non-numeric MAIN_EDIT_GATE_TTL_MIN falls back to the default and still denies" {
  create_main_edit_gate_marker "test-session" 2
  export MAIN_EDIT_GATE_TTL_MIN=abc
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: marker file with invalid JSON content allows" {
  printf 'not json at all' > "${REVIEW_COUNTER_DIR}/.main-edit-gate-test-session"
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: MAIN_EDIT_GATE_DISABLED=1 bypasses entirely" {
  create_main_edit_gate_marker "test-session" 2
  export MAIN_EDIT_GATE_DISABLED=1
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: agent_rows=0 allows" {
  create_main_edit_gate_marker "test-session" 0
  INPUT=$(build_edit_input cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: NotebookEdit on project notebook denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=NotebookEdit cwd="$PROJ" notebook_path="${PROJ}/nb.ipynb")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: MultiEdit on project source denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=MultiEdit cwd="$PROJ" file_path="${PROJ}/src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

# =============================================================================
# Bash: known write-file command families
# =============================================================================

@test "gate: bash sed -i on project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command="sed -i 's/x/y/' src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash BSD sed -i '' on file outside cwd allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command="sed -i '' 's/x/y/' /tmp/f")
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash heredoc redirect to project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cat > src/A.java <<EOF')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash quoted redirect target inside cwd denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x > "src/B.java"')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash redirect outside cwd allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x > /tmp/y')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash redirect to /dev/null allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd 2>/dev/null')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash fd-numbered redirect into project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd 2> src/err.log')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash fd-numbered append redirect outside cwd allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd 2>> /tmp/err.log')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash >| force-overwrite redirect into project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x >| src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash &> combined stdout+stderr redirect into project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x &> src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash &>> combined append redirect outside cwd allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x &>> /tmp/log')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash stderr-to-stdout fd-dup alone allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd 2>&1')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash stdout-to-fd2 fd-dup allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd >&2')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash fd-dup piped to tee outside cwd allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cmd 2>&1 | tee /tmp/log')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash tee with multiple project targets denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='tee src/a.txt src/b.txt')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash tee -a mixing outside and inside targets denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='tee -a /tmp/x src/c.txt')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash redirect target with shell variable is unknown, denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo x > "$PWD/src/A.java"')
  run_main_edit_gate
  assert_gate_deny_unknown
}

@test "gate: bash tee target with shell variable is unknown, denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='tee "$TARGET"')
  run_main_edit_gate
  assert_gate_deny_unknown
}

@test "gate: bash redirect target with command substitution is unknown, denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo > $(mktemp)')
  run_main_edit_gate
  assert_gate_deny_unknown
}

@test "gate: bash combined command denies if any segment writes into cwd" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo > /tmp/x && echo >> src/d.txt')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash semicolon-separated non-redirect write command denies (cp)" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='true ; cp /tmp/x src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash &&-separated non-redirect write command denies (sed -i)" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command="true && sed -i 's/x/y/' src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash pipe-separated non-redirect write command denies (install)" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='true | install -m 644 /tmp/x src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash redirect under expanded ~/.claude/ allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='echo > ~/.claude/x')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash cp into project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cp /tmp/x src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash mv out of the project allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='mv src/A.java /tmp/')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash cp --target-directory=src denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cp --target-directory=src /tmp/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash install -t src denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='install -t src /tmp/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash ln --target-directory src denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='ln --target-directory src /tmp/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash cp with unrecognized valued long option is unknown, denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='cp --backup=numbered /tmp/x /tmp/y')
  run_main_edit_gate
  assert_gate_deny_unknown
}

@test "gate: bash install with short option and project target denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='install -m 644 /tmp/x src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash dd of= into project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='dd if=/dev/zero of=src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash perl -pi -e in-place on project file denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command="perl -pi -e 's/a/b/' src/A.java")
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash git apply denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='git apply /tmp/p.diff')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash git checkout -- <path> denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='git checkout -- src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash git restore <path> denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='git restore src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash git stash pop denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='git stash pop')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash patch denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='patch < /tmp/p.diff')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash git status is read-only, allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='git status')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash plain search command allows" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='rg -n foo src/')
  run_main_edit_gate
  assert_gate_allowed
}

@test "gate: bash rsync into project denies" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command='rsync /tmp/x src/')
  run_main_edit_gate
  assert_gate_deny
}

# =============================================================================
# Bash: multi-line command.  A newline is a segment separator like &&/;/|, so
# a Bash tool_input.command spanning several physical lines is judged one
# line at a time.
# =============================================================================

@test "gate: bash multi-line command denies when a later line runs sed -i on a project file" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command=$'echo hello\nsed -i \'s/x/y/\' src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash multi-line command denies when a later line copies into a project file" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command=$'echo hello\ncp /tmp/x src/A.java')
  run_main_edit_gate
  assert_gate_deny
}

@test "gate: bash heredoc body line that looks like a write command denies (conservative, by design)" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(build_edit_input tool_name=Bash cwd="$PROJ" command=$'cat > /tmp/out <<EOF\ncp /tmp/x src/A.java\nEOF')
  run_main_edit_gate
  assert_gate_deny
}

# =============================================================================
# Robustness: unusual characters in the target must still yield parseable JSON
# =============================================================================

@test "gate: file_path with an embedded double quote still yields valid deny JSON" {
  create_main_edit_gate_marker "test-session" 2
  INPUT=$(jq -n --arg tn "Edit" --arg sid "test-session" --arg cwd "$PROJ" \
    --arg fp "${PROJ}/src/a\"b.java" \
    '{tool_name: $tn, session_id: $sid, cwd: $cwd, tool_input: {file_path: $fp}}')
  run_main_edit_gate
  assert_gate_deny
}

#!/usr/bin/env bats
# BDD tests for lib/preflight-extra.sh (C1-C4 writing-discipline pre-flight),
# wired into plan-review.sh right after the Dispatch Manifest pre-flight
# blocks (INVALID/MISSING/HOARDING) and before context collection.
#
# All "pass" cases run with REVIEW_DRY_RUN=1 so the flow reaches the engine
# stage without a real engine call — the synthetic verdict is always
# APPROVE, which itself emits an ack-deny (see assert_ack_approve_json) so
# these still assert via that helper, not assert_allowed.
#
# Dependencies: bats-core, jq

setup() {
  load 'test_helper/common-setup'
  common_setup
}

teardown() {
  common_teardown
}

# =============================================================================
# C1 — rollback
# =============================================================================

@test "C1: DML trigger without a rollback section → deny with PLAN DISCIPLINE and C1" {
  local plan="## 计划
本次涉及一次 DML 变更，修改若干行数据。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"PLAN DISCIPLINE"* ]]
  [[ "$reason" == *"C1"* ]]
}

@test "C1: DML trigger with a rollback section (list items) → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
本次涉及一次 DML 变更，修改若干行数据。

## 回滚
- 执行反向 SQL 恢复受影响的数据行
- 校验回滚后的数据一致性"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C1: no trigger keywords → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
这是一次纯文档措辞调整，不涉及任何环境变更。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C1: empty rollback heading section → deny" {
  local plan="## 计划
本次要发布到生产环境。

## 回滚

## 下一节
其他内容"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C1"* ]]
}

@test "C1: not-applicable with reason → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
本次要发布到生产环境。

## 回滚
不适用，原因：本次只改动只读展示文案，无数据变更。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

# =============================================================================
# C2 — concurrency & failure compensation
# =============================================================================

C2_FULL_SECTION='## 并发与失败补偿
- 原子性：整表更新使用行级锁包裹，保证操作原子执行
- 部分失败补偿：写入失败时自动回滚已写入的部分记录
- 幂等键：使用请求 ID 作为幂等键防止重复处理
- 缓存失效：更新成功后立即清理相关缓存条目
- 重入与超时：设置超时时间并允许安全重入执行'

@test "C2: lock/transaction trigger without the section → deny with PLAN DISCIPLINE and C2" {
  local plan="## 计划
本次改动涉及分布式锁与事务边界调整。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"PLAN DISCIPLINE"* ]]
  [[ "$reason" == *"C2"* ]]
}

@test "C2: all 5 labeled items present → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

${C2_FULL_SECTION}"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C2: no trigger keywords → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
一次纯前端样式调整。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C2: missing the cache-invalidation item → deny and reason names it" {
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

## 并发与失败补偿
- 原子性：整表更新使用行级锁包裹，保证操作原子执行
- 部分失败补偿：写入失败时自动回滚已写入的部分记录
- 幂等键：使用请求 ID 作为幂等键防止重复处理
- 重入与超时：设置超时时间并允许安全重入执行"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"缓存失效"* ]]
}

@test "C2: keywords stacked on one line (not 5 independent items) → deny" {
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

## 并发与失败补偿
- 原子、补偿、幂等、无缓存、超时均已考虑"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C2"* ]]
}

@test "C2: an item writes not-applicable without reason → deny" {
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

## 并发与失败补偿
- 原子性：整表更新使用行级锁包裹，保证操作原子执行
- 部分失败补偿：写入失败时自动回滚已写入的部分记录
- 幂等键：不适用
- 缓存失效：更新成功后立即清理相关缓存条目
- 重入与超时：设置超时时间并允许安全重入执行"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"不适用缺原因"* ]]
}

@test "C2: item body is 3 Han characters (9 bytes, below the 12-byte floor) → deny content-too-short" {
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

## 并发与失败补偿
- 原子性：三个字
- 部分失败补偿：写入失败时自动回滚已写入的部分记录
- 幂等键：使用请求 ID 作为幂等键防止重复处理
- 缓存失效：更新成功后立即清理相关缓存条目
- 重入与超时：设置超时时间并允许安全重入执行"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"原子性：正文过短"* ]]
}

@test "C2: item body is 4 Han characters (12 bytes, at the floor) → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 计划
本次改动涉及分布式锁与幂等处理。

## 并发与失败补偿
- 原子性：四个字词
- 部分失败补偿：写入失败时自动回滚已写入的部分记录
- 幂等键：使用请求 ID 作为幂等键防止重复处理
- 缓存失效：更新成功后立即清理相关缓存条目
- 重入与超时：设置超时时间并允许安全重入执行"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

# =============================================================================
# C3 — non-mock verification
# =============================================================================

@test "C3: mock mentioned without any real-environment verification → deny with PLAN DISCIPLINE and C3" {
  local plan="## 验证
使用 mockito 编写单元测试覆盖核心分支。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"PLAN DISCIPLINE"* ]]
  [[ "$reason" == *"C3"* ]]
}

@test "C3: mock plus an integration-test mention → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 验证
先用 mock 跑单测，再补一轮集成测试跑通真实数据库路径。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C3: no mock mentioned → approve" {
  export REVIEW_DRY_RUN=1
  local plan="## 验证
跑一轮集成测试。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

# =============================================================================
# C4 — main-row work nature (v2 manifest only)
# =============================================================================

c4_plan() {
  local main_row="$1"
  printf '%s\n' "## 计划
使用 Task( 派发部分工作。

## Dispatch Manifest
| step | location | subagent_type | model_source | model | depends_on | parallel_with |
|------|----------|---------------|--------------|-------|------------|---------------|
${main_row}
| 2 | agent | general-purpose | preset | - | 1 | - |"
}

@test "C4: main row step has no label → deny, main-edit reason names the rule" {
  local plan
  plan=$(c4_plan '| 1 | main | - | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C4"* ]]
  [[ "$reason" == *"须写『编号 标签』"* ]]
}

@test "C4: main row label hits an execution/data-fetch verb → deny, reason quotes the label" {
  local plan
  plan=$(c4_plan '| 1 通读全部 diff 并跑测试 | main | - | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C4"* ]]
  [[ "$reason" == *"通读全部 diff 并跑测试"* ]]
}

@test "C4: legit main row (number + label, no execution verb) → approve" {
  export REVIEW_DRY_RUN=1
  local plan
  plan=$(c4_plan '| 1 plan 定稿与批准 | main | - | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "C4: label with quotes and a backslash → deny, valid JSON, reason contains the label" {
  local plan
  plan=$(c4_plan '| 1 编写含"引号"与\反斜杠的代码 | main | - | - | - | - | - |')
  INPUT=$(build_input "plan=$plan")
  run_hook

  echo "$HOOK_STDOUT" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C4"* ]]
  [[ "$reason" == *'编写含"引号"与\反斜杠的代码'* ]]
}

# =============================================================================
# Aggregation, kill switch, counter semantics
# =============================================================================

@test "aggregate: two independent failures (C1 + C3) are both reported in one deny" {
  local plan="## 计划
本次要发布到生产环境。

## 验证
使用 mockito 编写单元测试。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  local reason
  reason=$(echo "$HOOK_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  [[ "$reason" == *"C1"* ]]
  [[ "$reason" == *"C3"* ]]
}

@test "kill switch: PREFLIGHT_EXTRA_DISABLED=1 skips all four checks" {
  export REVIEW_DRY_RUN=1
  export PREFLIGHT_EXTRA_DISABLED=1
  local plan="## 计划
本次要发布到生产环境。

## 验证
使用 mockito 编写单元测试。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_ack_approve_json
}

@test "counter: pre-flight deny increments TOTAL_ROUNDS, leaves ATTEMPT frozen" {
  set_counter_value 2 test-session 5
  local plan="## 计划
本次涉及一次 DML 变更。"
  INPUT=$(build_input "plan=$plan")
  run_hook

  assert_deny_json
  [ "$(get_counter_value)" -eq 2 ]
  [ "$(get_total_rounds)" -eq 6 ]
}

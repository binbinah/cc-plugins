# lib/preflight-extra.sh — Writing-discipline local pre-flight (C1-C4).
#
# Sourced by plan-review.sh, AFTER lib/manifest.sh (C4 reuses
# manifest_table_rows/has_manifest/parse_manifest_to_json). Runs entirely
# offline, no engine call, no network — the whole point is to catch the
# four most common "writing discipline" review findings (missing rollback,
# missing concurrency/failure-compensation checklist, mock-only verification,
# vague main-row work items) in well under a second, before the ~60s-per-
# round engine consultation ever starts.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no &>>.
# Matching is grep -qiE throughout (avoid \b — BSD grep has no word-boundary
# escape; "independent word" triggers use `(^|[^a-zA-Z0-9_])word([^a-zA-Z0-9_]|$)`).
#
# Public entry point:
#   preflight_extra_check <plan>
#     Runs C1..C4. On any failure, returns 1 and sets:
#       PREFLIGHT_EXTRA_ERROR — multi-line message, one paragraph per failed
#                               check (code, reason, how to fix).
#       PREFLIGHT_EXTRA_CODES — space-separated failed codes, e.g. "C1 C3"
#                               (log_decision only ever logs this, never the
#                               human-readable reason text — labels quoted in
#                               PREFLIGHT_EXTRA_ERROR must not leak into logs).
#     Returns 0 (both globals reset to empty) when all checks pass.

# _preflight_extra_fail <code> <reason> <fix>
# Appends one failure paragraph to PREFLIGHT_EXTRA_ERROR and the code to
# PREFLIGHT_EXTRA_CODES. Internal helper, not part of the public contract.
_preflight_extra_fail() {
  local code="$1" reason="$2" fix="$3"
  if [ -n "$PREFLIGHT_EXTRA_ERROR" ]; then
    PREFLIGHT_EXTRA_ERROR="${PREFLIGHT_EXTRA_ERROR}
"
  fi
  PREFLIGHT_EXTRA_ERROR="${PREFLIGHT_EXTRA_ERROR}${code}：${reason}
如何修：${fix}"
  if [ -n "$PREFLIGHT_EXTRA_CODES" ]; then
    PREFLIGHT_EXTRA_CODES="${PREFLIGHT_EXTRA_CODES} ${code}"
  else
    PREFLIGHT_EXTRA_CODES="${code}"
  fi
}

# _preflight_section_body <plan> <heading-keyword-regex-lowercase>
# Emits the body of the FIRST section whose heading (`^#{1,6} ...`) matches
# the given keyword regex (matched case-insensitively via tolower()): every
# line from the line after that heading up to (not including) the next
# `^#{1,6} ` heading line, or end of file. A bold-label line (`**foo**`) is
# never treated as a heading. Emits nothing if no such heading exists, or if
# the section between it and the next heading is empty — callers must treat
# an empty result as "check fails", which naturally covers both "no such
# heading" and "empty section" (spec: 空节不算).
_preflight_section_body() {
  local plan="$1" kw="$2"
  awk -v kw="$kw" '
    BEGIN { found = 0; in_sec = 0 }
    {
      line = $0
      low = tolower(line)
      if (in_sec) {
        if (line ~ /^#{1,6}[ \t]/) { in_sec = 0 } else { print line }
        next
      }
      if (!found && line ~ /^#{1,6}[ \t]/ && low ~ kw) {
        found = 1
        in_sec = 1
      }
    }
  ' <<<"$plan"
}

# --- C1: rollback ------------------------------------------------------
_preflight_c1() {
  local plan="$1"
  local trigger='生产|(^|[^a-zA-Z0-9_])prod([^a-zA-Z0-9_]|$)|DML|dml-apply|发布|上线|Apollo|SCM|配置中心|ALTER TABLE|migration|schema'
  printf '%s' "$plan" | grep -qiE "$trigger" || return 0

  local body
  body=$(_preflight_section_body "$plan" '回滚|回退|rollback')

  if [ -n "$body" ]; then
    if printf '%s' "$body" | grep -qiE '不适用' && printf '%s' "$body" | grep -qiE '原因'; then
      return 0
    fi
    if printf '%s' "$body" | grep -qiE '^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]'; then
      return 0
    fi
    if printf '%s' "$body" | grep -qiE '```'; then
      return 0
    fi
  fi

  _preflight_extra_fail "C1" \
"plan 触发了生产变更类关键词（生产/prod/DML/dml-apply/发布/上线/Apollo/SCM/配置中心/ALTER TABLE/migration/schema），
但没有一个标题含『回滚/回退/rollback』且正文非空、满足回滚要求的小节（空标题不算）。" \
"新增一个标题（如『## 回滚』），正文写明回滚步骤（列表/编号项，或围栏代码块）；确实不适用时写『不适用，原因：...』。"
  return 1
}

# --- C2: concurrency & failure compensation ----------------------------
_preflight_c2() {
  local plan="$1"
  local trigger='锁|租约|lease|NSQ|补偿|幂等|@Transactional|事务|外部系统|状态机|state ?='
  printf '%s' "$plan" | grep -qiE "$trigger" || return 0

  local body
  body=$(_preflight_section_body "$plan" '并发|竞态|失败补偿|一致性|concurrency|幂等')

  if [ -z "$body" ]; then
    _preflight_extra_fail "C2" \
"plan 触发了并发/失败补偿类关键词（锁/租约/lease/NSQ/补偿/幂等/@Transactional/事务/外部系统/状态机/state=），
但没有一个标题含『并发/竞态/失败补偿/一致性/concurrency/幂等』且正文非空的小节（空标题不算）。" \
"新增该标题，正文按 5 个固定标签逐项列出：原子性、部分失败补偿、幂等键、缓存失效、重入与超时。"
    return 1
  fi

  local label bad_details="" bad_count=0
  for label in 原子性 部分失败补偿 幂等键 缓存失效 重入与超时; do
    local pattern line status
    pattern="^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*\**${label}\**[:：]"
    line=$(printf '%s\n' "$body" | grep -E "$pattern" | head -1)
    status=""
    if [ -z "$line" ]; then
      status="缺失"
    else
      local content trimmed trimmed_bytes
      content=$(printf '%s' "$line" | sed -E 's/^[^:：]*[:：]//')
      trimmed=$(printf '%s' "$content" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      # Byte length, not bash's char-count ${#var} — that expansion follows
      # the process's current LC_CTYPE, so the same content can count as 4
      # (UTF-8 locale, per-character) or 12 (C/POSIX locale, per-byte)
      # depending on what locale this hook happens to run under, making the
      # threshold below drift with the environment. Force LC_ALL=C inside an
      # isolated subshell (does not leak into the rest of this script) so
      # wc -c always counts raw bytes, deterministically. Threshold: 12
      # bytes == 4 Han characters (3 bytes each in UTF-8) or 12 ASCII chars.
      trimmed_bytes=$(export LC_ALL=C; printf '%s' "$trimmed" | wc -c | tr -d ' ')
      if printf '%s' "$line" | grep -qiE '不适用'; then
        if ! printf '%s' "$line" | grep -qiE '原因'; then
          status="不适用缺原因"
        elif [ "$trimmed_bytes" -lt 12 ]; then
          status="正文过短"
        fi
      elif [ "$trimmed_bytes" -lt 12 ]; then
        status="正文过短"
      fi
    fi
    if [ -n "$status" ]; then
      bad_count=$((bad_count + 1))
      bad_details="${bad_details}
- ${label}：${status}"
    fi
  done

  if [ "$bad_count" -gt 0 ]; then
    _preflight_extra_fail "C2" \
"并发与失败补偿小节的 5 个固定标签逐项校验未通过：${bad_details}" \
"5 个标签（原子性、部分失败补偿、幂等键、缓存失效、重入与超时）须各自独立成一个列表项，
格式『- 标签：正文』，正文去空白后至少 12 字节（约 4 个汉字或 12 个 ASCII 字符）；同一行堆叠多个标签不算数；
写『不适用』的项必须同时写明『原因』。"
    return 1
  fi
  return 0
}

# --- C3: non-mock verification ------------------------------------------
_preflight_c3() {
  local plan="$1"
  printf '%s' "$plan" | grep -qiE 'mock|mockito' || return 0
  printf '%s' "$plan" | grep -qiE '集成测试|integration|数据库|SELECT|mvn test|pre 环境|pre 实测|curl|端到端|e2e|bats|真实环境|实机' && return 0

  _preflight_extra_fail "C3" \
"plan 提到了 mock/mockito，但验证判据里没有任何非 mock 的真实环境或数据库层验证。" \
"补一项集成测试/数据库校验/pre 实测/curl/端到端/bats/实机验证，不能只靠 mock 单测收口。"
  return 1
}

# --- C4: main-row work-nature (v2 manifest only) -------------------------
_preflight_c4() {
  local plan="$1"
  has_manifest "$plan" || return 0

  # Precondition (guaranteed by the caller's invocation order — plan-review.sh
  # runs the INVALID/MISSING/HOARDING pre-flight blocks before ever calling
  # preflight_extra_check): validate_manifest_v2 already passed for $plan.
  # parse_manifest_to_json re-validates internally; on the (should-not-happen)
  # chance it fails here, skip C4 rather than fail on a structural issue that
  # is not this check's concern.
  local json
  json=$(parse_manifest_to_json "$plan" "preflight-c4") || return 0

  local step bad_details="" bad_count=0
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    if ! printf '%s' "$step" | grep -qE '^[0-9]+([.][0-9]+)?[[:space:]]+.+'; then
      bad_count=$((bad_count + 1))
      bad_details="${bad_details}
- main 行 step『${step}』须写『编号 标签』"
      continue
    fi
    if printf '%s' "$step" | grep -qiE '编译|构建|跑测试|执行测试|测试执行|取证|读 ?diff|截图|采集|抓取|回归|实现|编写|编码|改代码|检索|通读|逐行'; then
      bad_count=$((bad_count + 1))
      bad_details="${bad_details}
- step『${step}』是执行 / 取数活，改为 agent 行"
    fi
  done < <(printf '%s' "$json" | jq -r '.steps[] | select(.location=="main") | .id')

  if [ "$bad_count" -gt 0 ]; then
    _preflight_extra_fail "C4" \
"Dispatch Manifest 中 location=main 的行工作性质不合规：${bad_details}" \
"main 行 step 单元格须写『编号 标签』（如『1 plan 定稿与批准』）；
标签不得是执行/取数类动词（编译/构建/跑测试/执行测试/测试执行/取证/读diff/截图/采集/抓取/回归/实现/编写/编码/改代码/检索/通读/逐行），
这类工作须改成 agent 行派发出去。"
    return 1
  fi
  return 0
}

# preflight_extra_check <plan>
preflight_extra_check() {
  local plan="$1"
  PREFLIGHT_EXTRA_ERROR=""
  PREFLIGHT_EXTRA_CODES=""
  local rc=0

  _preflight_c1 "$plan" || rc=1
  _preflight_c2 "$plan" || rc=1
  _preflight_c3 "$plan" || rc=1
  _preflight_c4 "$plan" || rc=1

  [ "$rc" -eq 0 ]
}

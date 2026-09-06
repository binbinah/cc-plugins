#!/bin/bash
# PreToolUse:Edit/Write/MultiEdit/NotebookEdit/Bash hook — main-session edit gate.
#
# Once plan-review.sh APPROVEs a plan whose Dispatch Manifest carries at least
# one agent-location row, it writes a marker file for the session. While that
# marker is live, this hook blocks the main session from editing project
# source directly: Edit/Write/MultiEdit/NotebookEdit on a path under cwd (and
# not under .md / .claude/) deny, and Bash denies for a best-effort family of
# known write-file commands (redirection, tee, sed/perl in-place, cp/mv/
# install/rsync/ln, dd, truncate, git worktree write-back, patch). Anything
# else — including writes performed inside a script interpreter (python3,
# node, bash script.sh) or forwarded via xargs — is out of coverage by design;
# this is not a sandbox. Sub-agent calls (input carrying a non-empty agent_id
# or agent_type) are never gated. Fail open on missing jq, missing session_id,
# missing/corrupt/stale marker, or agent_rows < 1.
#
# Environment variables:
#   MAIN_EDIT_GATE_DISABLED=1  — kill switch, bypass entirely
#   REVIEW_COUNTER_DIR         — marker directory (default: /tmp/claude-reviews)
#   MAIN_EDIT_GATE_TTL_MIN     — marker TTL in minutes (default: 180)
set -euo pipefail

INPUT=$(cat)

[ "${MAIN_EDIT_GATE_DISABLED:-0}" != "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
[ -n "$SESSION_ID" ] || exit 0

# Sub-agent calls carry a distinct identity; never gate them.
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null || true)
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || true)
[ -z "$AGENT_ID" ] || exit 0
[ -z "$AGENT_TYPE" ] || exit 0

MARKER_DIR="${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}"
TTL_MIN="${MAIN_EDIT_GATE_TTL_MIN:-180}"
# A non-numeric override must not silently collapse the TTL to 0 (which
# would make `(( now - file_mtime > ttl_sec ))` treat every marker as
# already expired) — fall back to the documented default instead.
case "$TTL_MIN" in
  ''|*[!0-9]*) TTL_MIN=180 ;;
esac
MARKER_FILE="$MARKER_DIR/.main-edit-gate-${SESSION_ID}"

find "$MARKER_DIR" -maxdepth 1 -name '.main-edit-gate-*' -mmin "+${TTL_MIN}" -delete 2>/dev/null || true

[ -f "$MARKER_FILE" ] || exit 0

file_mtime=$(stat -f %m "$MARKER_FILE" 2>/dev/null || stat -c %Y "$MARKER_FILE" 2>/dev/null || echo 0)
now=$(date +%s)
ttl_sec=$(( TTL_MIN * 60 ))
if (( now - file_mtime > ttl_sec )); then
  rm -f "$MARKER_FILE" 2>/dev/null || true
  exit 0
fi

AGENT_ROWS=$(jq -r '.agent_rows // 0' "$MARKER_FILE" 2>/dev/null || echo 0)
case "$AGENT_ROWS" in
  ''|*[!0-9]*) AGENT_ROWS=0 ;;
esac
[ "$AGENT_ROWS" -ge 1 ] || exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)

# --- Path normalization -----------------------------------------------------

# normalize_path <path> — collapses "." and ".." segments without requiring
# the path to exist. Pure string manipulation (bash 3.2 compatible arrays,
# no realpath/readlink dependency).
normalize_path() {
  local path="$1"
  local leading=""
  case "$path" in
    /*) leading="/" ;;
  esac
  local old_ifs="$IFS"
  IFS='/'
  local -a parts
  read -ra parts <<< "$path"
  IFS="$old_ifs"
  local -a stack=()
  local n=0
  local seg
  for seg in "${parts[@]}"; do
    case "$seg" in
      ""|".") continue ;;
      "..")
        if [ "$n" -gt 0 ]; then
          unset "stack[$((n-1))]"
          n=$((n-1))
        elif [ -z "$leading" ]; then
          stack[$n]=".."
          n=$((n+1))
        fi
        ;;
      *)
        stack[$n]="$seg"
        n=$((n+1))
        ;;
    esac
  done
  local out="$leading"
  local i
  for ((i=0; i<n; i++)); do
    if [ "$i" -gt 0 ]; then
      out="${out}/${stack[$i]}"
    else
      out="${out}${stack[$i]}"
    fi
  done
  [ -n "$out" ] || out="."
  printf '%s' "$out"
}

# strip_quotes <s> — removes one matching pair of surrounding quote
# characters (a literal " or ' still attached because tokenize()/split
# points are quote-unaware whitespace splits, not a real shell parser).
strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

# target_verdict <raw> — prints allow|deny|unknown for a raw path/command
# operand. See module header for the decision order.
target_verdict() {
  local s
  s="$(strip_quotes "$1")"

  # unresolved variable / command substitution: cannot statically judge
  case "$s" in
    *'$'*|*'`'*) printf 'unknown'; return ;;
  esac

  case "$s" in
    "~/"*) s="${HOME}/${s#\~/}" ;;
    "~") s="$HOME" ;;
  esac

  case "$s" in
    /*) : ;;
    *) s="${CWD%/}/$s" ;;
  esac

  s="$(normalize_path "$s")"

  local cwd_norm
  cwd_norm="$(normalize_path "$CWD")"
  cwd_norm="${cwd_norm%/}"

  case "$s" in
    "$cwd_norm"/*) : ;;
    *) printf 'allow'; return ;;
  esac

  local base="${s##*/}"
  case "$base" in
    *.md) printf 'allow'; return ;;
  esac

  case "$s" in
    */.claude/*) printf 'allow'; return ;;
  esac

  printf 'deny'
}

# --- Bash command-line heuristics -------------------------------------------

# split_commands <command> — splits on &&, ||, ;, | (not lone &, so fd-dup
# forms like "2>&1" survive intact) and on bare newlines (LF, and CRLF is
# consumed as a unit so a trailing CR never lingers) into global array
# SPLIT_CMDS. A multi-line Bash tool_input.command is therefore judged one
# physical line at a time — including any line that happens to sit inside a
# heredoc body, which is a known, accepted over-approximation: a heredoc
# body line that merely looks like a write command (e.g. "cp /tmp/x
# src/A.java" between "<<EOF" and "EOF") denies even though it is literal
# text, not an executed command. The literal ">|" (noclobber-override
# redirect) operator is protected with a placeholder before the generic "|"
# split runs, and restored per-segment afterward, so its embedded "|" is
# never mistaken for a pipe separator.
split_commands() {
  local cmd="$1"
  local marker=$'\x1e'   # ASCII RS; 0x01 collides with bash's internal CTLESC and silently corrupts unquoted array splitting
  local noclobber=$'\x1d' # ASCII GS; stand-in for ">|" while "|" is split on
  cmd="${cmd//>|/$noclobber}"
  cmd="${cmd//$'\r\n'/$marker}"
  cmd="${cmd//$'\n'/$marker}"
  cmd="${cmd//||/$marker}"
  cmd="${cmd//&&/$marker}"
  cmd="${cmd//;/$marker}"
  cmd="${cmd//|/$marker}"
  local old_ifs="$IFS"
  IFS="$marker"
  set -f
  SPLIT_CMDS=($cmd)
  set +f
  IFS="$old_ifs"
  local i
  for i in "${!SPLIT_CMDS[@]}"; do
    SPLIT_CMDS[$i]="${SPLIT_CMDS[$i]//$noclobber/>|}"
  done
}

# tokenize <text> — naive whitespace split (no quote-awareness beyond what
# target_verdict itself strips) into global array WORDS. Globbing disabled so
# stray "*"/"?" in a command string is never expanded against real files.
tokenize() {
  local s="$1"
  local old_ifs="$IFS"
  IFS=$' \t'
  set -f
  WORDS=($s)
  set +f
  IFS="$old_ifs"
}

# mask_quoted_operators <command> — prints the command with every shell
# metacharacter that sits INSIDE a single- or double-quoted span (`>`, `<`,
# `|`, `;`, `&`) replaced by `_`. Quote characters themselves, and every
# character outside a quoted span, are preserved verbatim, so a quoted
# redirect *target* (`> "src/A.java"`) still reaches target_verdict intact
# while a quoted *pattern* (`rg "Map<String, X>" f`) no longer reads as a
# redirect. Outside quotes a backslash escapes the next character; inside
# double quotes only `\\` and `\"` are escapes; single quotes take no
# escapes at all. An unterminated quote masks through end-of-string, which
# fails open — the same direction as every other parse limit in this hook.
mask_quoted_operators() {
  local s="$1"
  local n=${#s}
  local out=""
  local i c q=""
  for ((i=0; i<n; i++)); do
    c="${s:i:1}"
    if [ -z "$q" ]; then
      case "$c" in
        \\) out="${out}${c}"; i=$((i+1)); [ "$i" -lt "$n" ] && out="${out}${s:i:1}" ;;
        \"|\') q="$c"; out="${out}${c}" ;;
        *) out="${out}${c}" ;;
      esac
    elif [ "$q" = '"' ]; then
      case "$c" in
        \\)
          out="${out}${c}"
          i=$((i+1))
          if [ "$i" -lt "$n" ]; then
            c="${s:i:1}"
            case "$c" in
              '>'|'<'|'|'|';'|'&') out="${out}_" ;;
              *) out="${out}${c}" ;;
            esac
          fi
          ;;
        \") q=""; out="${out}${c}" ;;
        '>'|'<'|'|'|';'|'&') out="${out}_" ;;
        *) out="${out}${c}" ;;
      esac
    else
      case "$c" in
        \') q=""; out="${out}${c}" ;;
        '>'|'<'|'|'|';'|'&') out="${out}_" ;;
        *) out="${out}${c}" ;;
      esac
    fi
  done
  printf '%s' "$out"
}

# Globals used to report the outcome of evaluate_subcmd.
SUBCMD_VERDICT="allow"
SUBCMD_TARGET=""

# check_redirects <text> — scans for `>`, `>>`, `>|`, `&>`, `&>>` targets,
# including fd-numbered forms like `2>`/`2>>`; skips /dev/null. A fd-dup
# target such as `&1`/`&2` (as in `2>&1` or `>&2`) can never reach the skip
# check below: the target character class excludes `&` outright, so the
# whole match attempt fails to find a target there in the first place — it
# is unmatched, not filtered post-capture. Stops at the first non-allow
# target it finds.
check_redirects() {
  local s="$1"
  local remaining="$s"
  local re='(&>>|&>|>\||>>|>)[[:space:]]*([^[:space:]&|;]+)'
  local guard=0
  while [ "$guard" -lt 20 ] && [[ "$remaining" =~ $re ]]; do
    guard=$((guard+1))
    local target="${BASH_REMATCH[2]}"
    local matched="${BASH_REMATCH[0]}"
    remaining="${remaining/"$matched"/}"
    case "$target" in
      /dev/null) continue ;;
    esac
    local v
    v=$(target_verdict "$target")
    if [ "$v" != "allow" ]; then
      SUBCMD_VERDICT="$v"
      SUBCMD_TARGET="$target"
      return 0
    fi
  done
}

# check_tee — all non-"-" args to `tee` are candidate targets (multiple
# targets supported).
check_tee() {
  local n=${#WORDS[@]}
  local idx=1
  while [ "$idx" -lt "$n" ]; do
    local w="${WORDS[$idx]}"
    case "$w" in
      -*) : ;;
      *)
        local v
        v=$(target_verdict "$w")
        if [ "$v" != "allow" ]; then
          SUBCMD_VERDICT="$v"; SUBCMD_TARGET="$w"
          return 0
        fi
        ;;
    esac
    idx=$((idx+1))
  done
}

# check_inplace_rewrite <cmd0> — sed -i/--in-place, perl -i/-pi/-ni. Without
# -e, the first non-"-" arg is the embedded script and is dropped; with -e,
# every non-"-" arg is treated as a file (conservative: ambiguous role, so
# lean toward denying rather than missing a real target). BSD `-i ''` — the
# empty string immediately after -i — is the backup-suffix argument, not a
# file, and is consumed without becoming a candidate.
check_inplace_rewrite() {
  local cmd0="$1"
  local n=${#WORDS[@]}
  local has_dash_i=0 has_dash_e=0
  local i
  case "$cmd0" in
    sed)
      for ((i=1; i<n; i++)); do
        case "${WORDS[$i]}" in
          -i|-i.*|--in-place|--in-place=*) has_dash_i=1 ;;
          -e|--expression) has_dash_e=1 ;;
        esac
      done
      ;;
    perl)
      for ((i=1; i<n; i++)); do
        case "${WORDS[$i]}" in
          -i|-pi|-ni|-i.*) has_dash_i=1 ;;
          -e) has_dash_e=1 ;;
        esac
      done
      ;;
  esac
  [ "$has_dash_i" -eq 1 ] || return 0

  local -a files=()
  local idx=1
  while [ "$idx" -lt "$n" ]; do
    local w="${WORDS[$idx]}"
    case "$w" in
      -i)
        local nxt=$((idx+1))
        if [ "$nxt" -lt "$n" ]; then
          local nxt_stripped
          nxt_stripped="$(strip_quotes "${WORDS[$nxt]}")"
          [ -n "$nxt_stripped" ] || idx=$nxt
        fi
        ;;
      -*) : ;;
      *) files+=("$w") ;;
    esac
    idx=$((idx+1))
  done

  if [ "$has_dash_e" -eq 0 ] && [ "${#files[@]}" -gt 0 ]; then
    files=("${files[@]:1}")
  fi

  local f v
  for f in "${files[@]}"; do
    v=$(target_verdict "$f")
    if [ "$v" != "allow" ]; then
      SUBCMD_VERDICT="$v"; SUBCMD_TARGET="$f"
      return 0
    fi
  done
}

# check_copy_family <cmd0> — cp/mv/install/rsync/ln. -t <dir>/-t<dir>/
# --target-directory <dir>/--target-directory=<dir> wins as the target;
# otherwise the last non-"-" arg is the target. Any other valued long option
# (--foo=bar) makes the positional-argument count impossible to trust
# statically, so it denies as unknown.
check_copy_family() {
  local n=${#WORDS[@]}
  local target="" long_opt_unknown=0 last_nondash=""
  local idx=1
  while [ "$idx" -lt "$n" ]; do
    local w="${WORDS[$idx]}"
    case "$w" in
      --target-directory=*)
        target="${w#--target-directory=}"
        ;;
      --target-directory)
        idx=$((idx+1))
        [ "$idx" -lt "$n" ] && target="${WORDS[$idx]}"
        ;;
      -t?*)
        target="${w#-t}"
        ;;
      -t)
        idx=$((idx+1))
        [ "$idx" -lt "$n" ] && target="${WORDS[$idx]}"
        ;;
      --*=*)
        long_opt_unknown=1
        ;;
      -*)
        : ;;
      *)
        last_nondash="$w"
        ;;
    esac
    idx=$((idx+1))
  done

  if [ -z "$target" ]; then
    if [ "$long_opt_unknown" -eq 1 ]; then
      SUBCMD_VERDICT="unknown"
      SUBCMD_TARGET="${WORDS[*]}"
      return 0
    fi
    target="$last_nondash"
  fi

  [ -n "$target" ] || return 0
  local v
  v=$(target_verdict "$target")
  if [ "$v" != "allow" ]; then
    SUBCMD_VERDICT="$v"; SUBCMD_TARGET="$target"
  fi
}

# check_dd — target is the value of of=.
check_dd() {
  local n=${#WORDS[@]}
  local idx=1
  while [ "$idx" -lt "$n" ]; do
    case "${WORDS[$idx]}" in
      of=*)
        local target="${WORDS[$idx]#of=}"
        local v
        v=$(target_verdict "$target")
        if [ "$v" != "allow" ]; then
          SUBCMD_VERDICT="$v"; SUBCMD_TARGET="$target"
          return 0
        fi
        ;;
    esac
    idx=$((idx+1))
  done
}

# check_truncate — every non-"-" arg is a candidate target.
check_truncate() {
  local n=${#WORDS[@]}
  local idx=1
  while [ "$idx" -lt "$n" ]; do
    local w="${WORDS[$idx]}"
    case "$w" in
      -*) : ;;
      *)
        local v
        v=$(target_verdict "$w")
        if [ "$v" != "allow" ]; then
          SUBCMD_VERDICT="$v"; SUBCMD_TARGET="$w"
          return 0
        fi
        ;;
    esac
    idx=$((idx+1))
  done
}

# check_git — git apply / git checkout -- <path> / git restore <path> /
# git stash pop write back into the working tree; while the gate is active
# they deny outright (the target is effectively cwd itself).
check_git() {
  local n=${#WORDS[@]}
  [ "$n" -ge 2 ] || return 0
  local sub="${WORDS[1]}"
  case "$sub" in
    apply)
      SUBCMD_VERDICT="deny"; SUBCMD_TARGET="git apply"
      ;;
    checkout)
      local i
      for ((i=2; i<n; i++)); do
        if [ "${WORDS[$i]}" = "--" ]; then
          SUBCMD_VERDICT="deny"; SUBCMD_TARGET="git checkout --"
          return 0
        fi
      done
      ;;
    restore)
      SUBCMD_VERDICT="deny"; SUBCMD_TARGET="git restore"
      ;;
    stash)
      if [ "$n" -ge 3 ] && [ "${WORDS[2]}" = "pop" ]; then
        SUBCMD_VERDICT="deny"; SUBCMD_TARGET="git stash pop"
      fi
      ;;
  esac
}

# evaluate_subcmd <text> — sets SUBCMD_VERDICT/SUBCMD_TARGET for one
# &&/||/;/|-delimited command segment.
evaluate_subcmd() {
  local sub="$1"
  SUBCMD_VERDICT="allow"
  SUBCMD_TARGET=""

  local trimmed="$sub"
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [ -n "$trimmed" ] || return 0

  check_redirects "$trimmed"
  [ "$SUBCMD_VERDICT" = "allow" ] || return 0

  tokenize "$trimmed"
  local n=${#WORDS[@]}
  [ "$n" -gt 0 ] || return 0
  local cmd0="${WORDS[0]##*/}"

  case "$cmd0" in
    tee) check_tee ;;
    sed|perl) check_inplace_rewrite "$cmd0" ;;
    cp|mv|install|rsync|ln) check_copy_family ;;
    dd) check_dd ;;
    truncate) check_truncate ;;
    git) check_git ;;
    patch)
      SUBCMD_VERDICT="deny"; SUBCMD_TARGET="patch"
      ;;
  esac
}

# --- Deny message ------------------------------------------------------------

build_deny_message() {
  local kind="$1" target="$2" rows="$3"
  local paren
  if [ "$kind" = "unknown" ]; then
    paren="目标含变量或命令替换，无法静态判定：${target}"
  else
    paren="目标：${target}"
  fi
  printf '执行期门禁（main-edit-gate）：本会话已批准含 %s 个派发行的 Dispatch Manifest，主会话不直接修改项目源码（%s）。请按 Manifest 派 general-purpose 子代理执行；`.md` 与 `.claude/` 下文件不受限。确需关闭：设置 MAIN_EDIT_GATE_DISABLED=1；标记在 %s 分钟后自动失效。' \
    "$rows" "$paren" "$TTL_MIN"
}

emit_deny() {
  local kind="$1" target="$2"
  local msg
  msg=$(build_deny_message "$kind" "$target" "$AGENT_ROWS")
  local deny_json
  deny_json=$(printf '%s' "$msg" | jq -Rs .)
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":${deny_json}}}
EOF
  exit 0
}

# --- Dispatch by tool --------------------------------------------------------

if [ "$TOOL_NAME" = "NotebookEdit" ]; then
  RAW_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // ""' 2>/dev/null || true)
  [ -n "$RAW_PATH" ] || exit 0
  VERDICT=$(target_verdict "$RAW_PATH")
  case "$VERDICT" in
    allow) exit 0 ;;
    unknown) emit_deny "unknown" "$RAW_PATH" ;;
    *) emit_deny "deny" "$RAW_PATH" ;;
  esac
fi

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "MultiEdit" ]; then
  RAW_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || true)
  [ -n "$RAW_PATH" ] || exit 0
  VERDICT=$(target_verdict "$RAW_PATH")
  case "$VERDICT" in
    allow) exit 0 ;;
    unknown) emit_deny "unknown" "$RAW_PATH" ;;
    *) emit_deny "deny" "$RAW_PATH" ;;
  esac
fi

# TOOL_NAME = Bash
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
[ -n "$COMMAND" ] || exit 0

# Quoted spans are opaque to the redirect / separator heuristics below: a
# `>` inside an rg pattern (Java generics, HTML, arrows in log text) must
# not be read as a redirect, and a `|` or `;` inside a pattern must not
# split the command. Masking keeps quoted redirect targets intact.
COMMAND="$(mask_quoted_operators "$COMMAND")"

split_commands "$COMMAND"
for SUB in "${SPLIT_CMDS[@]}"; do
  evaluate_subcmd "$SUB"
  if [ "$SUBCMD_VERDICT" != "allow" ]; then
    emit_deny "$SUBCMD_VERDICT" "$SUBCMD_TARGET"
  fi
done

exit 0

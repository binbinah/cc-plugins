# plan-review

Adversarial red-team review of implementation plans via cross-model consultation.

When Claude calls `ExitPlanMode`, this plugin intercepts the call and sends the plan to a review engine (Gemini, Claude, or Codex) for adversarial scrutiny. The reviewer can APPROVE, raise CONCERNS, or REJECT. On non-approval, feedback is returned to Claude for revision or rebuttal. After max rounds without consensus, the plan passes through for user arbitration.

## Installation

```bash
# From marketplace
claude plugin add plan-review@WooDragon-cc-plugins

# Development mode
claude --plugin-dir ~/.claude/dev-plugins/plan-review
```

## Architecture

```
scripts/
  plan-review.sh              Orchestrator (PreToolUse hook): guards → counters → dual safety
                               valves → pre-check → prompt assembly → retry driver → verdict
                               branching. Plan-specific policy only (plan extraction, ack-round
                               counters, verdict routing, manifest parsing).
  second-opinion.sh           Generic second-opinion driver — a plain CLI any caller invokes
                               directly to get a second opinion on any artifact, built on the
                               same engine state machine. Does no verdict parsing; stdout is the
                               engine's raw review text, verbatim. See "Second Opinion Entry
                               Point" below.
  lib/
    common.sh                 Logging helpers, backfill_engine_err, allow_with_reason, plan_hash,
                               clamp_head_bytes/clamp_tail_bytes (UTF-8-safe byte-budget truncation)
    consult.sh                Engine consultation state machine (run_consultation()): timeout
                               resolution, degrade checks, the retry loop (capacity/timeout/empty-
                               response handling), and the REST fallback. Shared by both
                               plan-review.sh (hook) and second-opinion.sh (driver) — extracted so
                               the engine infrastructure is callable outside the hook context.
    plan-source.sh            Transcript triple-gated lookup + extraction chain +
                               RESOLVE_REASON tri-state messaging
    verdict.sh                Verdict extraction + APPROVE/CONCERNS/REJECT feedback rendering
    manifest.sh               Dispatch Manifest detection + MANIFEST_EXAMPLE + JSON serialization
    engines/
      agy.sh                   engine_probe/invoke/extract for the default gemini (agy CLI) engine
      claude.sh                engine_probe/invoke/extract for REVIEW_ENGINE=claude
      codex.sh                 engine_probe/invoke/extract for REVIEW_ENGINE=codex, plus an
                                engine_err_filter privacy-redaction hook
      rest.sh                  REST SSE fallback (see "Engine interface" below)
  assets/
    review-common.md          Generic review-engine instructions shared by every caller (ground
                               truth on version identifiers, Review Discipline, Finding Quality
                               Gate, Severity Definitions, Verdict Rules, Output Format). Does not
                               assume the artifact under review is a plan.
    review-plan.md            Plan-specific layer (framing, Scope Boundary, the 8 Review
                               Criteria, output length cap). Concatenated ahead of
                               review-common.md when plan-review.sh assembles the hook's system
                               prompt — this is the only consumer that concatenates the two.
  dispatch-check.sh           Layer 2 hook — Manifest v2 Agent/Task signature-set enforcement
  precompact-review.sh        PreCompact hook — plan recovery across compaction
```

### Engine interface

Each review engine implements three hooks that the orchestrator calls uniformly:

- **`engine_probe`** — called once, outside the retry loop: check the CLI is present, resolve
  model variables, and prepare any one-off temp resources. Returns non-zero if unusable.
- **`engine_invoke`** — called once per retry round: run the CLI, write raw output to
  `$ENGINE_OUT`, set `engine_exit`.
- **`engine_extract`** — read `$ENGINE_OUT` and set `REVIEW` to the review text. Verdict parsing
  happens later, in `lib/verdict.sh` — engines never see it.

Adding a new engine means adding one `lib/engines/<name>.sh` file that implements these three
functions, then adding one line to the orchestrator's engine whitelist `case` in `plan-review.sh`
— no other file needs to change.

`rest.sh` is the exception: it is a fallback channel, not a fourth first-class engine. It only
activates after the CLI retry budget is exhausted, and it always runs alongside whichever engine
was already sourced in the same process — so its functions use a `rest_` prefix instead of
implementing the three-hook interface, to avoid colliding with the active engine's own function
names.

## Environment Variables

### `plan-review.sh` (ExitPlanMode adversarial review)

| Variable | Default | Description |
|----------|---------|-------------|
| `REVIEW_ENGINE` | `gemini` | Review engine: `gemini` (default, routed through the local `agy` CLI), `claude` (`claude -p` subprocess), or `codex` (`codex exec` subprocess) |
| `AGY_MODEL` | `Gemini 3.1 Pro (High)` | Model id passed to the `agy` CLI when `REVIEW_ENGINE=gemini` |
| `CLAUDE_MODEL` | `opus` | Claude model when `REVIEW_ENGINE=claude` |
| `CODEX_BIN` | _(empty)_ | Path to the `codex` binary. Default: `codex` as resolved on `PATH`. Set this when codex is not on `PATH` |
| `CODEX_MODEL` | _(empty)_ | Model id passed to `codex exec` when `REVIEW_ENGINE=codex`. Empty means inherit whatever `~/.codex/config.toml` specifies |
| `GEMINI_MODEL` | `gemini-3.1-pro-preview` | Model id used only by the REST fallback payload (not the `agy` CLI path) |
| `REVIEW_DISABLED` | `0` | Set `1` to bypass entirely |
| `REVIEW_DRY_RUN` | `0` | Set `1` to skip engine call (synthetic APPROVE) |
| `REVIEW_MAX_ROUNDS` | `3` | Max non-Critical consultation rounds (CONCERNS accumulation) before escalation |
| `REVIEW_MAX_TOTAL_ROUNDS` | `20` | Absolute global ceiling (including REJECT rounds); hard-blocks once reached |
| `REVIEW_REPO_ACCESS` | `0` | codex engine only. Set `1` to run the reviewer with `-C <project cwd>` (still `-s read-only`) instead of an empty temp dir, letting it ground findings — and verify the plan author's factual rebuttals — against real code. Trade-offs: repo content becomes readable by the engine's provider, and rounds get slower |
| `REVIEW_ENGINE_TIMEOUT` | `595` | Engine call timeout in seconds (requires `timeout`/`gtimeout` on `PATH`) |
| `REVIEW_API_URL` | _(empty)_ | REST API fallback base URL (OpenAI-compatible), used when the CLI path fails |
| `REVIEW_API_KEY` | _(empty)_ | REST API fallback bearer token |
| `REVIEW_REST_TIMEOUT` | `115` | REST fallback curl timeout in seconds (clamped to `remaining-3` by the budget logic) |
| `REVIEW_REST_STALL_TIMEOUT` | `90` | REST SSE stream stall watchdog (`curl --speed-time`), tuned to tolerate legitimate reasoning-model TTFT |
| `REVIEW_HOOK_BUDGET` | `595` | Total hook time budget in seconds (600s hook timeout minus 5s margin); governs the retry loop and REST timeout clamping |
| `REVIEW_CAPACITY_DELAY` | `25` | Wait time after detecting `MODEL_CAPACITY_EXHAUSTED` (skipped — breaks immediately to REST — when REST is configured) |
| `REVIEW_ENGINE_DEGRADE_TTL` | `600` | TTL in seconds for the Gemini degrade state; subsequent hooks within the TTL skip the CLI and go straight to REST. Shortened from 3600 in v1.2.0 — agy 429 probing is cheap (~26s median) and multi-round session reuse lowers 429 frequency, so a shorter cooldown recovers agy faster without thrashing |
| `PREFLIGHT_EXTRA_DISABLED` | `0` | Set `1` to skip the C1–C4 [plan discipline pre-flight](#plan-discipline-pre-flight-v180) checks (kill switch) |

Legacy variables (`GEMINI_REVIEW_OFF`, `GEMINI_DRY_RUN`, `GEMINI_MAX_REVIEWS`) are supported via fallback mapping.

### `second-opinion.sh` (generic second-opinion driver)

The driver reuses the same engine variables above (`REVIEW_ENGINE`, `AGY_MODEL`, `CLAUDE_MODEL`,
`CODEX_BIN`, `CODEX_MODEL`, `GEMINI_MODEL`, `REVIEW_API_URL`, `REVIEW_API_KEY`,
`REVIEW_REST_TIMEOUT`, `REVIEW_REST_STALL_TIMEOUT`, `REVIEW_HOOK_BUDGET`,
`REVIEW_CAPACITY_DELAY`, `REVIEW_ENGINE_DEGRADE_TTL`) and shares `REVIEW_COUNTER_DIR` (and
therefore `DEGRADE_FILE`) with `plan-review.sh` — a Gemini capacity degrade tripped by one is
honored by the other. It does **not** provide its own `--timeout` flag; time budget is inherited
purely from env (`REVIEW_ENGINE_TIMEOUT` / `REVIEW_HOOK_BUDGET`). It also does **not** read
`REVIEW_DISABLED` or `REVIEW_DRY_RUN` — see [Second Opinion Entry Point](#second-opinion-entry-point-second-opinionsh)
for why. `REVIEW_LOG_DIR` (default `~/.claude/logs`) controls where its own `second-opinion.log`
is written, separate from `plan-review.log`.

### `dispatch-check.sh` (Layer 2 — Agent/Task dispatch enforcement)

| Variable | Default | Description |
|----------|---------|-------------|
| `DISPATCH_CHECK_DISABLED` | `0` | Set `1` to disable the Layer 2 Manifest v2 signature check (kill switch) |

### `main-edit-gate.sh` (execution-time main-session edit gate)

| Variable | Default | Description |
|----------|---------|-------------|
| `MAIN_EDIT_GATE_DISABLED` | `0` | Set `1` to disable the [main-session edit gate](#main-session-edit-gate-v180) (kill switch) |

### `return-verify-mark.sh` / `return-verify-clear.sh` / `return-verify-gate.sh` (return-verify gate)

| Variable | Default | Description |
|----------|---------|-------------|
| `RETURN_VERIFY_GATE_DISABLED` | `0` | Set `1` to disable the [return-verify gate](#return-verify-gate-v190) (kill switch) |
| `RETURN_VERIFY_TTL_MIN` | `180` | Minutes before the pending-verification state expires; a non-numeric or empty override falls back to `180` |
| `MAIN_EDIT_GATE_TTL_MIN` | `180` | Minutes before an armed gate marker expires; on expiry the marker is treated as pass-through and deleted |

### Dispatch Manifest v2

A plan with dispatch keywords must include a Dispatch Manifest with at least one
`agent` or `pi` row. A plan without dispatch keywords, including Tier0 work, remains
Manifest-free. `plan-review.sh` stores only the approved v2 signature set. The
fixed columns are `step | location | subagent_type | model_source | model |
depends_on | parallel_with`.

- `main` rows use `-` for `subagent_type`, `model_source`, and `model`.
- `agent` + `preset` rows require `subagent_type` and require the tool call to
  omit `model`.
- `agent` + `runtime` rows require both `subagent_type` and `model`; the hook
  matches both values exactly.
- `pi` rows (`location=pi`) are executed by the local pi worker via `run_pi.sh`
  instead of the Agent tool; `subagent_type` must be `explore` or `implement`,
  and `model_source` / `model` must both be `-`.

The hook permits repeated matching calls. It does not implement a step cursor,
call count, execution order, or global model ownership policy. State with no
schema marker is treated as temporary Manifest v1 compatibility state: the hook
emits a migration prompt and skips enforcement. Corrupt, stale, or invalid state
fails open.

## Plan discipline pre-flight (v1.8.0)

Runs locally, after the three existing pre-flight checks (INVALID DISPATCH
MANIFEST, MISSING DISPATCH MANIFEST, DISPATCH HOARDING) and before any engine
call. It adds four writing-discipline checks (C1–C4) that previously consumed
whole review rounds — the check itself runs in well under a second. A failure
does **not** count as a consultation round: it only increments `TOTAL_ROUNDS`
(the global ceiling tracked by `REVIEW_MAX_TOTAL_ROUNDS`), leaving `ATTEMPT`
(the CONCERNS/REJECT escalation counter) frozen. On failure the hook denies
with the heading `## Red Team Pre-flight — PLAN DISCIPLINE`, in the same deny
JSON shape as the other pre-flight checks.

Set `PREFLIGHT_EXTRA_DISABLED=1` to skip all four checks (kill switch).

| # | Trigger (plan text matches any of) | Pass condition | Rejection message |
|---|---|---|---|
| **C1 Rollback** | `生产`, `prod` (word-boundary), `DML`, `dml-apply`, `发布`, `上线`, `Apollo`, `SCM`, `配置中心`, `ALTER TABLE`, `migration`, `schema` | A Markdown heading (`^#{1,6} `) containing `回滚`, `回退`, or `rollback` exists, and that section's body (up to the next heading) satisfies either: contains `不适用` **and** `原因`; or has at least one list/numbered item (`^[[:space:]]*([-*]\|[0-9]+[.)])[[:space:]]`) or one fenced code block | Must write rollback steps (a list or commands); if not applicable, write `不适用，原因：…`; an empty section does not count |
| **C2 Concurrency & failure compensation** | `锁`, `租约`, `lease`, `NSQ`, `补偿`, `幂等`, `@Transactional`, `事务`, `外部系统`, `状态机`, `state ?=` | A heading containing `并发`, `竞态`, `失败补偿`, `一致性`, `concurrency`, or `幂等` exists, and that section's body contains **5 distinct list items**, each starting with one of 5 fixed labels (item regex `^[[:space:]]*([-*]\|[0-9]+[.)])[[:space:]]*\**(原子性\|部分失败补偿\|幂等键\|缓存失效\|重入与超时)\**[:：]`), with at least 12 bytes remaining after the label once whitespace is trimmed, measured under a forced `LC_ALL=C` byte count (≈ 4 Han characters or 12 ASCII characters, so the threshold does not drift with the hook's locale); an item containing `不适用` must also contain `原因`. Stacking multiple keywords on one line does not count as multiple items | Lists all 5 fixed labels with their status (missing / body too short / `不适用` without `原因`) |
| **C3 Non-mock verification** | `mock`, `mockito` | The plan also contains any of: `集成测试`, `integration`, `数据库`, `SELECT`, `mvn test`, `pre 环境`, `pre 实测`, `curl`, `端到端`, `e2e`, `bats`, `真实环境`, `实机` | Verification cannot rely on mock unit tests alone; at least one real-environment or database-level check is required |
| **C4 Main-row work nature** | Only when `has_manifest` and `validate_manifest_v2` already passed; iterates `manifest_table_rows` with `location=main` | The `step` cell must be "number + space + label" (regex `^[0-9]+([.][0-9]+)?[[:space:]]+.+`); the label must not match `编译`, `构建`, `跑测试`, `执行测试`, `测试执行`, `取证`, `读 ?diff`, `截图`, `采集`, `抓取`, `回归`, `实现`, `编写`, `编码`, `改代码`, `检索`, `通读`, `逐行` | Missing label: "main-row step must be written as '编号 标签'"; keyword matched: "step N's label '\<label\>' is execution/data-fetch work — move it to an agent row" |

For C1/C2 the "section body" is extracted with `awk`: from the line after the
matched heading up to the next `^#{1,6} ` line, or end of file. A bold-label
form is no longer accepted as a section marker.

## Main-session edit gate (v1.8.0)

When `plan-review.sh` APPROVEs a plan whose Dispatch Manifest contains at
least one `agent` or `pi` row, it atomically writes a marker file
`${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}/.main-edit-gate-<session_id>`
(JSON: `plan_hash`, `created_at`, `agent_rows`). A separate hook,
`scripts/main-edit-gate.sh`, is registered on PreToolUse for `Edit`, `Write`,
`MultiEdit`, `NotebookEdit`, and `Bash`: while the marker is live, the main
session may not edit project source directly — the Manifest already assigned
that work to a dispatched agent. Dispatched sub-agents are unaffected: they
carry their own `session_id`, and the hook input's `agent_id`/`agent_type`
identifies them.

**Pass-through conditions** (any one is enough to allow the call through,
with no output):

- `MAIN_EDIT_GATE_DISABLED=1` (kill switch)
- `jq` is not available
- the hook input has no `session_id`
- the hook input has a non-empty `agent_id` or `agent_type`
- the marker file for this session does not exist
- the marker is older than `MAIN_EDIT_GATE_TTL_MIN` minutes (default `180`;
  a non-numeric or empty `MAIN_EDIT_GATE_TTL_MIN` falls back to `180`); the
  stale marker is deleted as a side effect
- the marker file's content is not valid JSON, or its `agent_rows` is `< 1`
  — both fail open (allowed through)

**Path rule** (`Edit`/`Write`/`MultiEdit` read `.tool_input.file_path`,
`NotebookEdit` reads `.tool_input.notebook_path`; relative paths are resolved
against `.cwd`):

- a path outside `cwd` → allowed
- a path whose basename ends in `.md` → allowed
- a path containing `/.claude/` → allowed
- anything else → denied

**Bash coverage** — while the gate is active, `main-edit-gate.sh` splits the
command on `&&`, `;`, `|`, `||`, and bare newlines (`\n`, `\r\n`) — a
multi-line command is judged one physical line at a time — and inspects each
piece for a *known write-file command family*, then applies the same path
rule above to every extracted target. Splitting on newlines is a deliberate
trade-off: a heredoc body line that merely *looks like* a write command (for
example a code sample being written into a file via `Edit`/`Write`, quoted
inside a `cat <<EOF` block) is conservatively denied along with real
commands, since the hook cannot distinguish heredoc payload from executable
text without a real shell parser.

- quoted spans are opaque (v1.8.1): a `>`, `<`, `|`, `;` or `&` inside a
  single- or double-quoted string is neither a redirect nor a separator, so
  `rg -n "Map<String, X> foo" src/A.java` is read-only; a quoted redirect
  *target* (`> "src/A.java"`) is still judged, and an unterminated quote
  fails open
- redirection (`>`, `>>`, `>|`, `&>`, `&>>`), skipping `/dev/null`; a pure
  fd-duplication form (`2>&1`, `>&2`) is not treated as a write target, but
  an fd-numbered redirect to a path (e.g. `2> path`) is judged like any
  other redirection
- `tee` (including multiple targets)
- in-place rewrites: `sed -i`/`--in-place`, `perl -i`/`-pi`/`-ni`
- copy/move/install: `cp`, `mv`, `install`, `rsync`, `ln` — including
  `-t <dir>`/`-t<dir>`/`--target-directory[=]<dir>`; any other value-taking
  long option that isn't a recognized boolean is treated as **not statically
  determinable** and denied
- `dd of=...`, `truncate`
- git working-tree writes and `patch`: `git apply`, `git checkout --
  <path>`, `git restore <path>`, `git stash pop`, `patch` — the target is
  treated as `cwd` itself, so these are denied outright whenever the gate is
  active
- a target containing `$`, `` ` ``, or `$(` (a shell variable or command
  substitution) is **not statically determinable** and is denied

**Explicitly not covered** — this is a known-write-command-family gate, not a
sandbox: writes performed from inside an interpreter (`python3`/`node`/`bash
script.sh` writing files internally) and write commands forwarded through
`xargs` are not inspected.

Denial uses the same JSON shape as `dispatch-check.sh`, with the message
built via `printf '%s' "$MSG" | jq -Rs .`. To lift the gate immediately, set
`MAIN_EDIT_GATE_DISABLED=1`; otherwise it expires automatically after
`MAIN_EDIT_GATE_TTL_MIN` minutes.

## Return-verify gate (v1.9.0)

Once `main-edit-gate.sh` is armed, delegating work to agents is not enough on
its own — the main session must actually look at what a dispatched agent
produced before sending the next one. This gate enforces that: after a
plan is approved and dispatched, every sub-agent return must be followed by
at least one main-session read-only tool call before another `Agent`/`Task`
call is allowed through.

Three cooperating scripts, one shared state file per session
(`${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}/.return-verify-<session_id>`,
JSON: `{"pending": [{"agent_id", "agent_type", "stopped_at"}, ...],
"updated_at"}`), written atomically via a `mktemp` temp file in the same
directory followed by `mv`:

- **`return-verify-mark.sh`** (`SubagentStop`, all matchers) — appends the
  sub-agent that just stopped to `pending`. Unlike `main-edit-gate.sh`, this
  hook does **not** skip on a non-empty `agent_id`/`agent_type`: `SubagentStop`
  fires with the *parent* session's `session_id`, and `agent_id`/`agent_type`
  identify the sub-agent whose return is being recorded — that is the event
  worth marking, not one to filter out.
- **`return-verify-clear.sh`** (`PostToolUse` on `Bash`, `Read`, `Grep`,
  `Glob`) — deletes the state file whenever the *main* session (empty
  `agent_id`/`agent_type`) runs one of those tools. `PostToolUse` never makes
  a permission decision, so this hook always exits 0 with no output.
- **`return-verify-gate.sh`** (`PreToolUse` on `Agent`/`Task`, registered
  after `dispatch-check.sh`) — denies the call when `pending` is non-empty
  for this session.

**Pass-through conditions** (any one is enough to allow the call through,
with no output):

- `RETURN_VERIFY_GATE_DISABLED=1` (kill switch)
- `jq` is not available
- the hook input has no `session_id`
- the hook input has a non-empty `agent_id` or `agent_type` (a sub-agent's
  own nested dispatch is not gated)
- the state file for this session does not exist
- the state file's content is not valid JSON, or `pending` is empty
- the state file is older than `RETURN_VERIFY_TTL_MIN` minutes (default
  `180`; non-numeric/empty falls back to `180`) — the stale file is deleted
  as a side effect
- `main-edit-gate.sh`'s own marker for this session is missing, stale, or
  has `agent_rows < 1` (shared `rv_gate_armed` predicate in
  `scripts/lib/return-verify.sh`) — the return-verify gate is only live
  while the main-edit-gate itself is armed; a plan-approval-less or expired
  session clears any stale pending state as a side effect

Denial uses the same JSON shape as `main-edit-gate.sh`/`dispatch-check.sh`.
The reason names each pending agent as `<agent_type>/<agent_id first 8
chars>`, joined with `、`, and points at running a read-only command (`git
diff --stat`, `wc -l`, a test-report summary, `rg` for a key symbol, or
`Read` on a key file) before dispatching the next step.

`scripts/plan-review.sh` clears `.return-verify-<session_id>` whenever it
re-arms `main-edit-gate.sh` on a fresh APPROVE (a new approval invalidates
any pending state left over from the prior round's dispatches), and its
stale-cleanup pass also sweeps `.return-verify-*` files past
`RETURN_VERIFY_TTL_MIN`.

## Consultation Flow

```
ExitPlanMode → hook intercepts → engine reviews
  ├─ APPROVE → ack-deny: present review + re-call ExitPlanMode → allow (user's native go/no-go)
  ├─ CONCERNS/REJECT → deny + feedback → Claude revises → re-submit
  └─ max rounds reached → allow through (user decides)
```

An engine APPROVE is **not** authorization to start work — it only clears the plan
for the user's native ExitPlanMode decision. The ack-deny message instructs Claude to
present the review and re-call ExitPlanMode (unchanged); only the user's native approval
on that second call permits execution.

## Review Criteria

Eight criteria — authoritative text is split across two files (see [Architecture](#architecture)):

- `scripts/assets/review-common.md` — the generic layer: version-identifier ground truth, Review
  Discipline, Finding Quality Gate, Severity Definitions, Verdict Rules, Output Format. Shared by
  every caller of the engine infrastructure, including `second-opinion.sh`; it never assumes the
  reviewed artifact is a plan.
- `scripts/assets/review-plan.md` — the plan-specific layer: framing, Scope Boundary, the 8
  criteria below, and the output length cap. Only `plan-review.sh` uses this file, concatenating
  it ahead of `review-common.md` when assembling the hook's system prompt.

| # | Criterion | Focus |
|---|-----------|-------|
| 1 | **Correctness** | Does the plan actually solve the stated problem? |
| 2 | **Completeness** | Missing steps, edge cases, error handling? |
| 3 | **Simplicity** | Is there a simpler approach? Unnecessary complexity? |
| 4 | **Safety** | Security risks, data loss, backwards-compatibility breaks? |
| 5 | **Testability** | Test strategy presence; test pyramid completeness; e2e selector cascade (evidence-gated); deletion completeness for exported symbols |
| 6 | **Architecture fit** | Consistent with project patterns? |
| 7 | **Dispatch Economy** | Main decision work, preset registered agents, runtime built-ins, and mechanical work delegation rules |
| 8 | **Reuse over reinvention** | Using existing dependencies before building custom? |

Criterion #5 (Testability) is evidence-gated: e2e selector audits only trigger if the plan or project context reveals e2e coverage (Playwright, Cypress, `*.spec.ts`, `e2e/` directory).

## Engine Isolation (Claude)

When `REVIEW_ENGINE=claude`, the script spawns `claude -p` with triple isolation:

1. **`PLAN_REVIEW_RUNNING=1`** — recursive guard; subprocess bails immediately if set
2. **`--setting-sources local`** — loads only `settings.local.json`, no project/user hooks
3. **`--tools ""`** — no tool calls = no PreToolUse events = no hook re-entry

`unset CLAUDECODE` and `unset CLAUDE_CODE_ENTRYPOINT` prevent the subprocess from inheriting parent's internal state. This is implementation-dependent but necessary: user authenticates via OAuth (`claude login`), no `ANTHROPIC_API_KEY` available, making `claude -p` the only viable invocation path.

## Engine Isolation (Codex)

When `REVIEW_ENGINE=codex`, the script spawns `codex exec` with a parallel set of isolation flags:

1. **`-s read-only`** — sandbox policy; the reviewer process cannot write to disk
2. **`-C <fresh empty temp dir>`** — the working root is a throwaway empty directory, not the user's project. This relocates the working root; on its own it does not stop a tool from reaching paths outside that directory (see the tool-surface caveat below). With `REVIEW_REPO_ACCESS=1` the working root becomes the project cwd instead (sandbox stays read-only) — an explicit opt-in trading isolation for grounded review
3. **`--ephemeral`** — no session files persisted to disk
4. **`--skip-git-repo-check`** — required because the isolated temp dir is not a git repo

The prompt is fed via stdin (no `ARG_MAX` limit, unlike the agy path which needs a 256KB guard), and the final message is captured via `-o <file>`.

**Tool-surface caveat**: the four flags above constrain the file scope the reviewer sees; they do not disable codex's agent tool surface. Whether MCP servers or web search remain available to the reviewer follows the user's own `~/.codex/config.toml`. This differs from the `claude` engine, where `--tools ""` removes the tool surface outright. The plugin leaves codex's tool configuration to the user rather than overriding it — silently rewriting a user's engine config is the worse trade. Users who require a text-only reviewer should disable those tools in their codex configuration.

**stderr handling**: `codex exec` echoes the entire prompt to stderr. Because of this, codex's stderr is deliberately **not** appended to the plan-review log (unlike the other engines) — doing so would duplicate the full prompt into the log file. On a failed call, only a filtered diagnostic is written to the log: the banner plus trailing `warning:`/`ERROR:` lines, with any line matching the prompt stripped out, truncated to 500 chars.

## Session Reuse (agy, v1.2.0)

When `REVIEW_ENGINE=gemini` (agy CLI), a multi-round consultation reuses one agy server-side conversation instead of resending the full static prompt every round:

- **First round** builds a fresh conversation and captures the `conversation_id` agy assigns (via `--output-format json`).
- **Subsequent rounds** resume it with `--conversation <id>`, sending only the volatile tail (current plan + round framing). The static prefix (system instructions + project/global context) already lives in agy's session history, so the provider serves it from prompt cache.

This lowers 429 frequency and quota consumption on multi-round negotiations. The conversation reference is session-scoped and torn down when the review cycle ends (approve / escalate / no-plan / global valve), on any non-zero agy exit (capacity, timeout, resume-rejected, network), when a response cannot be parsed, or when the plan changes after an approval. Extraction/reuse failures fall through to a plain agy call or REST — never a new blocking path.

**agy invocation contract**: since v1.2.0 the agy CLI is always called with `--output-format json`, and the review body is text-sliced out of the (not-well-formed) JSON `response` field. This depends on agy's envelope carrying `conversation_id` and `response` keys. If a future agy build changes that envelope shape, extraction fails closed (empty review → retry / REST fallback), so a shape change degrades gracefully rather than mis-parsing — but it does mean the agy path is coupled to this envelope. The `claude` engine path and the REST fallback are unchanged. With no env config, the review decision logic behaves as before; the observable deltas are the JSON invocation, multi-round session reuse, and the shorter degrade cooldown (600s).

## Round Memory (v1.5.0)

`--conversation` session reuse (above) is an agy-only, token-cost optimization — it is not the source of truth for cross-round memory. Every other engine has none of its own: `claude` runs with `--no-session-persistence`, `codex` runs `--ephemeral`, and the REST fallback has no session concept at all. Round memory therefore lives in the orchestrator itself, not in any one engine.

Each `CONCERNS`/`REJECT` round's verdict and review body is appended to a per-session thread file (byte-budgeted via `clamp_head_bytes`). On the next round, the orchestrator injects that accumulated thread as a `## Prior Review Thread` section (byte-budgeted via `clamp_tail_bytes`, keeping the most recent rounds) whenever no engine already has live native memory of its own for this round — covering `claude`, `codex`, REST, and agy itself once its `--conversation` handle is lost (extraction failure, CLI error, or first round). The injection is evaluated at two points: prompt composition, and again immediately before the REST fallback fires — a resume-round agy CLI failure clears the conversation handle *after* composition already judged native memory available, so the second check is what keeps REST from receiving a prompt with no history at all.

The `## Consultation Context` block (present whenever a plan is past its first round) carries delta review rules alongside the round-number framing: re-verify prior Critical findings against the current plan, treat a new non-Critical finding on unchanged text as a forfeited relitigation, focus new findings on changed text, and hold rebuttals to a symmetric evidence burden (an unverifiable factual claim does not clear a finding). These rules apply identically to every engine, including agy's own session-resume rounds, which carry a duplicate of this text since they bypass the shared prompt file entirely.

The thread's lifetime mirrors the review cycle: cleared whenever a cycle ends — approval, either safety valve, no-plan fail-closed, or an orphan exit (engine not found / not attempted — dropped to avoid leaking one plan's findings into an unrelated later plan under the same session id). The one exception is a plan revised after approval (plan hash no longer matches the approved marker): that is not a cycle end — the counter keeps counting — so the thread survives with an appended revision marker instead of being cleared, since prior findings on this same plan are exactly the highest-value context to carry into the re-review. Only the `--conversation` handle is dropped there, since it embeds the full old plan text server-side.

No new environment variables — the byte budgets are fixed defaults in `lib/common.sh` (`HISTORY_ROUND_BYTES=9000` per recorded round, `HISTORY_INJECT_BYTES=48000` on injection), sized so a full-length CJK review (`review-plan.md` caps output at 3000 characters, ~9KB in Chinese) survives a single round uncut and roughly 5 rounds of thread history survive injection. Once a plan's accumulated thread exceeds the injection budget, `clamp_tail_bytes` keeps the most recent rounds and silently drops the oldest ones first. These match the raised `CLAUDE.md` ingestion limits below (`GLOBAL_MD_BYTES=8000`, `PROJECT_MD_BYTES=24000`).

## Second Opinion Entry Point (second-opinion.sh)

`second-opinion.sh` is a generic, out-of-hook driver built on the same engine infrastructure
(agy + Gemini 3.1 Pro + REST fallback + session reuse) that `plan-review.sh` uses. Unlike the
hook, it is a plain CLI: any caller invokes it directly to get a second opinion on any artifact —
not just an implementation plan — and gets back raw review text, not a verdict decision.

### Interface

```
second-opinion.sh --system-prompt-file <path> [--system-prompt-file <path2> ...]
                  [--prompt-file <path>] [--session <label>]
```

- `--system-prompt-file` — **required, repeatable**. Concatenated in command-line order to form
  the system instructions sent to the engine. Missing entirely, pointing at a nonexistent path, or
  an empty file is **fail loud**: nonzero exit, empty stdout. There is no fallback rubric — unlike
  the hook, this driver never silently substitutes the plan-review criteria for a caller that
  forgot to pass one.
- Artifact body — `--prompt-file <path>` or stdin. **stdin is the only path available to callers
  that are forbidden from writing files** (e.g. redteam-style callers operating under a
  read-only mandate). If both are given, `--prompt-file` wins; stdin is a fallback for
  file-write-averse callers, not a second source merged with an explicit file.
- stdout carries **only** the review body — no JSON wrapper, no log lines. stderr carries all
  diagnostics. Exit 0 means a result was obtained; nonzero means every engine was exhausted, or a
  fail-loud precondition was violated.

**Fail loud, not fail open.** `plan-review.sh` fails open (allows the tool call through) on every
engine failure, because the cost of a false block is high and the hook has a native human
approval step downstream regardless. This driver has no such downstream backstop — a caller
treats whatever comes out of stdout as the review. A synthesized "looks like a review" response
here would be actively misleading, so every failure path is fail-closed: nonzero exit, empty
stdout, diagnostic on stderr.

**Does not read `REVIEW_DISABLED` / `REVIEW_DRY_RUN`.** Those two variables encode "turn off the
ExitPlanMode gate" semantics for the hook. An explicit, direct invocation of this driver is not
that gate — it must not be silently reshaped by env state that was set for a different call site.

**Shares `DEGRADE_FILE`** with `plan-review.sh` (same `REVIEW_COUNTER_DIR`) so a Gemini
capacity-exhaustion degrade tripped by one caller is honored by the other. **Does no verdict
parsing** — the driver is a transport layer only; `<verdict>` tags, if present in the engine's
response, are returned as-is inside the raw text.

### Session continuation (`--session <label>`)

`--session <label>` takes an opaque label, not a file path. The actual session-file path is
derived by the driver:

```
${REVIEW_COUNTER_DIR:-/tmp/claude-reviews}/.so-<hash(label + assembled system-prompt bytes)[:16]>
```

The hash folds in the **assembled system-prompt bytes**, not just the label, via `plan_hash()`
(`lib/common.sh`, reused verbatim — sha256sum → shasum -a 256 → cksum fallback, so this stays
portable across Linux and macOS). This is deliberate: it means a rubric edit invalidates the old
session automatically. A caller does not need to remember "I changed the prompt, so I must also
throw away the old `--session` value" — that is a rule a path-based scheme would require the
caller to enforce themselves, and forgetting it means resuming a stale session under a changed
rubric, silently mixing old and new review criteria.

Real evidence from testing: with the same `--session` label, changing one byte of the system
prompt changed the derived key from `9f2d2375...` to `bf96267a...`, and the engine returned to a
genuinely fresh first round (no reference to "the previous round") instead of resuming the old
one.

Omitting `--session` gives a single-round, stateless call backed by a throwaway temp file — no
session persists past that one invocation.

Multi-round memory under `--session` is **not unconditional**. It lives entirely in agy's
server-side `--conversation` session, which only accumulates while the agy CLI path keeps
succeeding. If the agy CLI fails on a given round and the REST fallback produces the review
instead, that round's output never reaches agy's session history — the driver detects this and
deletes the session file (`CONV_FILE`) rather than leave a conversation handle with a silent gap
in it. The **next** round under the same `--session` label therefore starts over as a fresh first
round, with no memory of anything before the REST fallback fired. Callers relying on continuity
across rounds should treat "agy CLI succeeded every round so far" as the precondition for that
continuity, not the `--session` flag alone.

### Path discovery

The officially recommended path is:

```
~/.claude/plugins/marketplaces/cc-plugins/plugins/plan-review/scripts/second-opinion.sh
```

This is the version-less, CC-maintained git checkout — the one under `marketplaces/`, not
`cache/`. **This has a real cost, and it is intentional to state it plainly rather than let
callers discover it by surprise**: `marketplaces/` tracks the marketplace `HEAD`, but the hook
actually loads assets from `plugins/cache/<version>/`. The two drift apart across a push — a
caller invoking the `marketplaces/` path picks up a change immediately on push; the hook only
picks it up after the next plugin reinstall. The same asset can therefore be two different
versions depending on which of the two consumers is looking at it.

**Do not glob `find ~/.claude/plugins -path '.../second-opinion.sh'` and take the first hit.**
Tested against the structurally identical `pr-review` plugin, that glob returned three hits
(`marketplaces/` + two different `cache/<version>/` directories); `head -1` picking the "right"
one is an accident of filesystem traversal order, not a guarantee. `plan-review`'s own `cache/`
directory currently has four different versions sitting side by side.

### Time budget

The driver does **not** provide its own `--timeout` flag — time budget is purely inherited from
env (`REVIEW_ENGINE_TIMEOUT` / `REVIEW_HOOK_BUDGET`). To override, set those env vars inline on
the invocation. Worst-case measured latency was ~415s (agy self-terminates at its own
`--print-timeout` 5-minute mark, the retry guard breaks out because the remaining time budget is
insufficient for another attempt, and REST fallback then gets its own 115s). Callers wrapping the
driver in a `timeout` command should budget **at least 480s**.

### Known limitation: no usage/log traceability

The driver does not set `SESSION_ID`, so its calls produce **no** `agy-conversation` /
`agy-usage` log lines — the driver's diagnostics go to stderr only (`second-opinion.log`), by
design, but the practical effect is that a driver invocation **cannot be traced from
`plan-review.log`**. If you need to quantify the driver's own token consumption, that requires
adding a separate extraction mechanism — not currently in scope.

### Example

```bash
SO=~/.claude/plugins/marketplaces/cc-plugins/plugins/plan-review/scripts/second-opinion.sh
"$SO" --system-prompt-file <your-own-rubric>.md \
      --system-prompt-file <plugin>/scripts/assets/review-common.md \
      --session my-review-t7 <<'EOF'
<artifact under review>
EOF
```

Order matters: your own rubric goes first, `review-common.md` goes last. The plugin's own
`review-plan.md` follows the same rule (see [Review Criteria](#review-criteria) above) because it
opens with framing language ("You are a senior software architect performing...") that must lead
the assembled prompt; `review-common.md` is the shared review discipline and output-format layer,
so it belongs at the end regardless of what precedes it.

## Fault Tolerance

- **jq missing** → allow (can't parse input)
- **Engine CLI missing** → allow + stderr warning
- **Engine call fails** → allow + stderr warning
- **Empty response** → allow
- **Malformed verdict** → fail-closed as CONCERNS
- **Log directory unwritable** → logs to `/dev/null`, core logic unaffected

## Privacy Notice

This plugin sends the following data to the configured review engine — the Gemini API, the Anthropic API, or, when `REVIEW_ENGINE=codex`, whichever provider the user's `~/.codex/config.toml` selects:

- **Global CLAUDE.md** — first 8KB of `~/.claude/CLAUDE.md`
- **Project CLAUDE.md** — first 24KB of `$CWD/CLAUDE.md`
- **Recent conversation** — last 3 user messages from the session transcript
- **Plan content** — the full implementation plan under review
- **Prior review thread** (v1.5.0, multi-round only) — up to the most recent 24KB of accumulated verdicts and review findings from earlier rounds on the same plan (see [Round Memory](#round-memory-v150)), sent to whichever provider handles the CURRENT round — not necessarily the same provider that produced the earlier findings if `REVIEW_ENGINE` changed mid-session
- **Repository contents** — only with `REVIEW_REPO_ACCESS=1` (codex): the reviewer runs read-only inside the project working directory and may read any file in it

This context is necessary for meaningful adversarial review. If your CLAUDE.md or conversations contain sensitive information (internal hostnames, credentials, business logic), be aware that this data will be sent to the external API — and, on multi-round reviews, may be echoed back into the thread and re-sent on subsequent rounds.

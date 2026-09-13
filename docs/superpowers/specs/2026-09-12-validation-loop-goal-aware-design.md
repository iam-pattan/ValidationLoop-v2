# ValidationLoop v1.5.0 — Goal-Aware Validation

**Status:** Approved design, pending implementation plan
**Date:** 2026-09-12
**Supersedes:** none (extends v1.4.0 — on-demand `/validate`)
**Spec author:** brainstorming session with user

---

## 1. Problem & Goal

ValidationLoop v1.4 scores changed files against a generic 5-dimension rubric
(truthfulness 30 / validation 25 / authenticity 20 / derivations 15 / assumptions 10)
with **no knowledge of what the user asked for**. A task that produces flawless,
well-cited code solving the *wrong problem* — or silently dropping a requirement —
scores just as high as on-target work. That is the blind spot this version closes.

Two additions, both driven off a single new artifact (the per-session goal log):

1. **Goal-aware judging** — the `/validate` judge receives the session's submitted
   prompts (the "goals") alongside the file list, scores a new **alignment**
   dimension (advisory-only), and emits a structured **deviations** list.
2. **Live-session goal anchoring** — the same goal log is re-injected into the
   running session every turn via `UserPromptSubmit` `additionalContext`, so the
   main model keeps its objective even after context compaction summarizes away
   the original prompt.

### Design decisions (locked during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Goal unit | Auto-capture every prompt + smart merge | Handles multi-task sessions; no friction |
| Distill cost | Deferred to `/validate` | Zero added latency to prompt-submit |
| Deviation form | Alignment score + deviations list, **advisory-only** | Surfaces specifics without disturbing the calibrated gate |
| Judge flow | Fused single call (judge distills + scores together) | One fewer script; interpretation is inspectable via the advisory block |
| Live-session injection | Heuristic-trimmed raw extract via `additionalContext` | Pure shell, zero latency, consistent with deferred distill |

### Acknowledged limitation

In `block` mode, a task that solves the *wrong problem* with flawless, well-cited
code will still PASS (≥85 on the 5 dims) and will not be forced to rework —
alignment is advisory-only. This is the direct consequence of advisory-only and is
accepted for v1.5; alignment can be promoted to a weighted dimension in a later
version once its behavior is calibrated, without redesigning the capture/inject
plumbing.

---

## 2. Architecture & Data Flow

```
You type a prompt
        |
        v
UserPromptSubmit hook -- goal-capture.sh --+-> append user_input to
        |                                  |   /tmp/claude/glm-qc/<session>.goals
        |                                  |   (pure shell, zero-latency, no model call;
        |                                  |    same TOCTOU hardening as glm-qc-mark.sh;
        |                                  |    skips slash-command prompts)
        |                                  |
        |                                  +-> emit additionalContext = trimmed running-goal
        |                                      extract -> main session sees its accumulated
        |                                      objective THIS turn (compaction-resistant anchor)
        v
  ... you work, files tracked as today (glm-qc-mark.sh -> <session>.files) ...
        |
        v
You run /validate -- validate.sh -> glm-qc.sh (UNCHANGED entry point)
        |
        v
glm-qc.sh reads BOTH <session>.files AND <session>.goals
        |
        +- if goals empty -> current v1.4 behavior (5-dim, no alignment) -- graceful fallback
        |
        +- if goals present -> judge prompt includes:
             * the file list (as today)
             * the raw goal log (the prompts you submitted this session)
             * instructions to ALSO emit alignment (0-100, cited) + deviations[]
        |
        v
GLM/Kimi judge returns extended JSON:
  {dimensions:{<5 dims as today>}, alignment:{score,cite,evidence},
   deviations:[{claimed_goal, delivered, severity, evidence}], top_issues, unverified_claims}
        |
        v
glm-qc-score.py (extended):
  * score_one() OVER 5 DIMS -- UNCHANGED -> same weighted overall -> same PASS/REVIEW/REWORK
  * NEW: extract alignment + deviations, append as a separate ADVISORY block in .summary
  * .verdict and the numeric gate are IDENTICAL to v1.4 -- calibration preserved
        |
        v
Output: existing verdict block + a new "GOAL ALIGNMENT" advisory section
        (alignment score, each deviation with severity + evidence)
```

### Key invariants

- The 5-dimension weighted score and the PASS/REVIEW/REWORK verdict are
  **byte-for-byte unchanged** from v1.4 when no goal is captured, and
  **numerically unchanged** even when one is (alignment is reported, not added to
  the weighted total).
- Zero added latency to prompt-submit (capture is pure shell append; the
  `additionalContext` extract is a bounded shell read).
- No new model call per `/validate` — the judge does distill+score in one fused
  call (the only added cost is a slightly longer judge prompt).
- The goal log lives on disk in `/tmp`, **not in conversation context** — so
  context compaction does NOT affect it. No `PreCompact` hook needed.

---

## 3. Components

| File | Status | What it does |
|---|---|---|
| `scripts/goal-capture.sh` | **NEW** | `UserPromptSubmit` hook. Pure shell, zero-latency. Appends each `user_input` to `/tmp/claude/glm-qc/<session>.goals`; emits `additionalContext` with a trimmed extract of *prior* goals back into the live turn. Skips slash commands; treats `/clear` as a goal-log reset. Same TOCTOU hardening as `glm-qc-mark.sh`. |
| `hooks/hooks.json` | **MODIFIED** | Add a `UserPromptSubmit` block (timeout 10s). Existing `PostToolUse` block untouched. |
| `scripts/glm-qc.sh` | **MODIFIED** | After reading `<session>.files`, also read `<session>.goals`. If goals present → extended judge prompt (goal log + alignment/deviations instructions + extended schema). If absent → **exact current 5-dim prompt, unchanged**. `run_judge`, tie-breaker, fallback chain untouched. |
| `scripts/glm-qc-score.py` | **MODIFIED** | `score_one()` over 5 dims **unchanged** (alignment NOT in WEIGHTS). NEW: extract `alignment` + `deviations`, append a "GOAL ALIGNMENT" advisory block to `.summary`. `.overall`/`.verdict` byte-identical to v1.4. Log gains `alignment` + `deviations_count` for calibration. |
| `scripts/validate.sh` | unchanged | Still recovers session id, hands off to `glm-qc.sh`. |
| `scripts/glm-qc-mark.sh` | unchanged | File tracking unchanged. |
| `README.md`, `SETUP-GUIDE.md` | **UPDATED** | v1.5.0: document pre-hook, goal log, alignment advisory, live-session injection. |

---

## 4. Core Logic

### 4.1 The capture hook — `goal-capture.sh`

`UserPromptSubmit` fires on every prompt and provides `user_input`, `session_id`
on stdin. The hook:

1. Reads stdin JSON, extracts `session_id` (same sanitization as `mark.sh`) and
   `user_input`.
2. **Slash-command handling:** if `user_input` starts with `/`:
   - If it is `/clear` → **reset** `.goals` to empty (fresh objective for
     post-clear work) and exit 0 with no `additionalContext`.
   - Otherwise (any other slash command) → exit 0 silently: no append, no
     injection. Keeps the goal log clean and avoids injecting stale context into a
     command turn.
3. **Append:** write `user_input` (one logical line, newlines escaped) to
   `/tmp/claude/glm-qc/<session>.goals` via the same `secure_dir`/`secure_file`
   TOCTOU-safe helpers used in `mark.sh`.
4. **Inject:** build a bounded extract of *prior* goals (everything already in
   `.goals` *before* this prompt) and emit it as `additionalContext` so the live
   session sees its accumulated objective this turn. Emit the
   `hookSpecificOutput` JSON shape:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "<trimmed goal extract>"
  }
}
```

5. **Never block.** Any failure (disk, jq, permissions) → exit 0 with no JSON.
   A capture hook failure must not break the session.

#### The `additionalContext` extract (heuristic-trimmed, pure shell)

- **Primary objective:** the first substantial prompt in `.goals` (first line ≥8
  words containing a verb/action keyword, else the first line).
- **Recent refinements:** the last 2–3 prompts already in `.goals`, excluding
  trivial follow-ups (<8 words and no action keyword).
- **Cap:** ~1500 chars total. Truncate the middle if over.
- **Framing prefix** so the model knows what this is:

```
[Goal anchor — your accumulated task objective for this session, re-injected each
turn so it survives context compaction. Treat as the north star, not a new request.]
Primary objective: <first substantial prompt>
Recent refinements:
  - <prompt n-2>
  - <prompt n-1>
```

### 4.2 The judge prompt extension — `glm-qc.sh`

When `<session>.goals` is present and non-trivial (≥10 chars, ≥1 line), build the
extended prompt; otherwise build the **exact v1.4 prompt** (string-identical — this
is test 8). The extended prompt adds, after the existing rubric:

```
The user's submitted goals for this session were:
<<<GOALS>>>
{goal log, bounded to last ~20 prompts}
<<<END GOALS>>>

ALSO score "alignment" 0-100: did the work accomplish what was ASKED in the goals?
  Cite both the goal line AND the file:line that addresses (or fails to address) it.
ALSO emit "deviations": where delivered work diverges from stated goals —
  each as {claimed_goal, delivered, severity (high|med|low), evidence (file:line)}.
  Empty list if the work is aligned.

OUTPUT ONLY a JSON object matching:
{"dimensions":{<5 dims as today>},
 "alignment":{"score":0-100,"cite":"goal:line + file:line","evidence":"short"},
 "deviations":[{"claimed_goal":"...","delivered":"...","severity":"high|med|low","evidence":"file:line"}],
 "top_issues":["..."],"unverified_claims":["..."]}

Rules: give a real citation for EVERY score; when you cannot verify something, score
it LOW, not high. CRITICAL: alignment measures GOAL-COVERAGE, NOT code quality (that
is the other 5 dimensions) — keep them orthogonal. Do not double-count: bad code is
already penalized under truthfulness/validation; alignment is only about whether the
work did what was asked.
```

The last paragraph is load-bearing: without it the judge double-counts (bad code →
low truthfulness → low alignment), collapsing the new dimension into the existing
ones and making alignment redundant.

`run_judge`, the model fallback chain, the REVIEW-band tie-breaker, and the
`QC_RUNNING` recursion guard are all **untouched**.

### 4.3 The scorer extension — `glm-qc-score.py`

- `WEIGHTS` and `score_one()` **unchanged**. Alignment is NOT in `WEIGHTS`; the
  5-dim weighted `overall` is computed exactly as in v1.4.
- After the existing per-judge scoring, extract:
  - `alignment` — same uncited-cap guardrail as the 5 dims: a score ≥70 with no
    `cite` is capped at 65. A missing `alignment` field is noted
    (`alignment: no score`) but does **not** penalize the 5-dim score.
  - `deviations` — defensive parse: missing `severity` → `unknown`; missing
    `evidence` → `(uncited)` noted; absent/empty → "no deviations reported."
    Never fatal.
- Append to `.summary` a new advisory block:

```
GOAL ALIGNMENT (advisory — not in the weighted score):
  alignment  72  (cite)
  deviations:
    [high] Asked for EU-only heatmap; delivered global — file:line
    [med]  Asked to exclude test merchants; not filtered — file:line
```

(If no goals were captured, this block is omitted entirely — the summary is
byte-identical to v1.4.)

- `.log` (the calibration line appended to `~/.claude/qc-scores.jsonl`) gains:
  - per-judge `alignment` score
  - `deviations_count`
  - top-level `goals_captured: bool`

  This lets future calibration compare alignment trends against the base score
  without affecting either.

**The invariant (test 6):** a run with goals captured produces the *same*
`.overall` and `.verdict` as a run without — alignment is purely additive to the
report. The v1.4 calibration baseline stays valid.

---

## 5. Error Handling & Edge Cases

| Scenario | Behavior |
|---|---|
| No goals captured (older/resumed sessions) | `glm-qc.sh` finds no `.goals` → runs the exact v1.4 5-dim prompt, no alignment block. Graceful fallback. |
| Goals file empty/corrupt | Same as no goals. Length/sanity check: `<10` chars or no parseable lines → skip alignment. |
| Capture hook fails (disk, perms, jq missing) | Hook exits 0, no JSON. Never blocks the turn. `/validate` later falls back to 5-dim. |
| Judge doesn't emit `alignment` | Scorer notes `alignment: no score` (transparent), does not penalize the 5-dim score. Missing alignment never lowers the verdict. |
| Judge emits malformed `deviations` | Defensive parse — missing fields filled with `unknown`/`(uncited)`. Never fatal. Absent → "no deviations reported." |
| Slash command prompt (`/validate`, `/clear`, etc.) | `/clear` → reset `.goals` to empty. Other slash commands → skip append and skip injection. |
| `/clear` mid-session | `.goals` reset to empty (the hook handles this). Fresh objective for post-clear work. |
| Compaction | Goals on disk, not in context → compaction cannot lose them. `additionalContext` re-injection each turn is the anchor. No `PreCompact` hook needed. |
| `--resume` / `--continue` | New prompts fire `UserPromptSubmit`, appending to the session's `.goals`. Prior-session goals gone (different session id / `/tmp` lifecycle) — acceptable: resumed work re-states its goal via the first new prompt. |
| Very long goal log (many prompts) | `additionalContext` extract capped ~1500 chars (first substantial + last 2-3, deduped). Judge receives the full log bounded to last ~20 prompts. |
| Trivial follow-up ("ok", "thanks", "go") | Still appended (completeness) but excluded from the extract's "recent refinements" (<8 words and no action keyword). |
| Recursion / re-entrancy | `goal-capture.sh` is pure shell, no model call → no recursion possible. `QC_RUNNING` guard on the judge unchanged. |
| Privacy | Goal log on disk in `/tmp` (mode 600, owner-only, TOCTOU-hardened — same as `.files`). Goal text sent to the judge through the same gateway as file contents today — no new data egress path. |

---

## 6. Testing Strategy

No test framework exists for this repo. Testing is **direct script invocation +
fixture files** (consistent with the workspace reality and how the v1.2 fixes were
validated). A runner script `scripts/test-v1.5.sh` executes the deterministic tests
(no model calls) and reports pass/fail; the end-to-end smoke test is manual.

| # | Test | How | Deterministic? |
|---|---|---|---|
| 1 | Capture hook writes goals | Pipe fake `UserPromptSubmit` JSON to `goal-capture.sh` → assert `.goals` contains the line + stdout has `additionalContext` JSON. | yes |
| 2 | Capture hook skips slash commands | Pipe `user_input:"/validate"` → assert `.goals` unchanged AND no `additionalContext`. | yes |
| 3 | `/clear` resets goals | Pipe `user_input:"/clear"` after goals exist → assert `.goals` empty. | yes |
| 4 | Extract bounded | Append 30 fake prompts → assert `additionalContext` ≤1500 chars, contains first + last 2-3 only. | yes |
| 5 | Scorer: goals present, alignment emitted | Feed `glm-qc-score.py` a fixture with `alignment` + 2 deviations → assert summary has GOAL ALIGNMENT block, `.overall` = 5-dim weighted value, `.verdict` from 5 dims only. | yes |
| 6 | Scorer: advisory-only invariant (regression) | v1.4 fixture (no alignment) through extended scorer → assert `.overall` and `.verdict` identical to v1.4 output. | yes |
| 7 | Scorer: missing/uncited alignment | Fixture with `alignment:{score:90}` (no cite) → assert capped to 65, 5-dim score unaffected. | yes |
| 8 | Judge prompt: goals vs no-goals path | Diff the prompt `glm-qc.sh` builds with `.goals` present vs absent → assert no-goals = exact v1.4 string; goals path adds `<<<GOALS>>>` + alignment instructions. | yes |
| 9 | End-to-end smoke | Capture 3 prompts → write a fixture file → run `validate.sh` with `QC_MODEL` = session default → assert verdict + GOAL ALIGNMENT block. | manual (model call) |

---

## 7. Versioning & Rollout

- Plugin version bumped to **1.5.0** in `plugin.json` and the marketplace manifest.
- The `UserPromptSubmit` hook is added to `hooks/hooks.json` — the existing
  `PostToolUse` block is untouched, so file tracking behavior is unchanged.
- No `settings.json` changes required by the user — the hook is registered by the
  plugin on reinstall/restart, same as the existing PostToolUse hook.
- No new env vars required; the existing `QC_*` vars govern the judge as today.
- `README.md` and `SETUP-GUIDE.md` get a v1.5.0 changelog entry and a new "Goal
  capture & live-session anchoring" section.

---

## 8. Out of Scope (future work)

- **Promoting alignment to a weighted dimension** — deferred until its behavior is
  calibrated against the `qc-scores.jsonl` log. The plumbing (capture, inject,
  extract) supports it; only `WEIGHTS` + `score_one()` would change later.
- **`PreCompact` hook** — not needed (goals on disk survive compaction). Reserved
  if a future requirement asks to re-inject goals *into the compacted context
  itself* rather than per-turn.
- **Goal-log inspection command** (e.g. `/goals`) — a convenience command to view
  the current session's captured goals. Nice-to-have, not required for v1.5.
- **Cross-session goal persistence** — goals are per-session by design; resuming
  re-states the goal via the first new prompt.

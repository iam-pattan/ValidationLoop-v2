# ValidationLoop (Claude Code plugin)

An **on-demand second-model validation** layer for Claude Code. When you run
`/validate` (after reviewing a task's work and deciding it should be QC'd), an
*independent* model validates the session's changed files against a rubric and
surfaces a confidence score. If the score is borderline, a second model is pulled
in as a tie-breaker and the two are averaged. Think "four-eyes principle," but
you decide when the second pair of eyes looks.

> Two independent models must agree before you rely on the result.

**Works out of the box with your session's default model — zero config.** For the
real value (a genuinely independent review), point `QC_MODEL` / `QC_MODEL2` at a
*different model family* your gateway serves. See [Configuration](#configuration).

**v1.5.0 adds goal awareness.** A `UserPromptSubmit` hook captures each prompt
you submit into a per-session goal log. That log does two things: (1) it is
re-injected into the live session every turn as `additionalContext` — a
compaction-resistant "north star" so your objective survives context compaction;
(2) at `/validate` time the judge reads it and scores an **advisory**
`alignment` dimension (did the work do what was asked?) plus a structured
`deviations` list. The 5-dimension weighted score and PASS/REVIEW/REWORK verdict
are **unchanged** — alignment is reported, not folded into the gate.

---

## What you get

| Piece | What it does |
|---|---|
| `qc-reviewer` subagent | On-demand independent validator — ask Claude to *"use the qc-reviewer agent to review this."* |
| UserPromptSubmit hook | Captures each submitted prompt into a per-session goal log (`scripts/goal-capture.sh`). Also re-injects a trimmed goal extract into the live turn as `additionalContext` — a compaction-resistant objective anchor. Runs automatically on every prompt; zero added latency (pure shell). |
| PostToolUse hook | Records which files changed this session (`scripts/glm-qc-mark.sh`). Runs automatically on every edit. |
| `/validate` command | Runs the second-model QC over this session's changed files — **only when you ask for it** (`scripts/validate.sh` → `scripts/glm-qc.sh`). If a goal log exists, the judge also scores `alignment` + emits `deviations` (advisory). |
| Scorer | Computes the weighted confidence score and the PASS/REVIEW/REWORK verdict (`scripts/glm-qc-score.py`); appends a GOAL ALIGNMENT advisory block when goals were captured. |

### The confidence score (0–100)

Five dimensions, **analytics-weighted** by default:

| Dimension | Weight | Meaning |
|---|---|---|
| Truthfulness | 30% | Claims correct & verifiable against the code/output |
| Validation | 25% | Actually tested / reconciled; edge cases handled |
| Authenticity | 20% | Grounded in real artifacts — nothing fabricated |
| Derivations | 15% | Logic / math / SQL sound and reproducible |
| Assumptions | 10% | Assumptions explicit & reasonable, not silently baked in |

Bands → action: **≥85 PASS** (silent) · **65–84 REVIEW** (advisory note) · **<65 REWORK** (blocks in enforcing mode).

Guardrails on the validating model itself: every score needs a `file:line`
citation (an uncited high score is capped at 65); uncertainty must score *low*;
weights and thresholds are enforced by code, not the model; unparseable output
becomes REVIEW, never a silent PASS. Every score is logged to
`<config-dir>/qc-scores.jsonl` for calibration over time.

---

## Requirements

- **Claude Code** with plugins enabled.
- **`jq`** and **`python3`** on your PATH (the hooks call them).

Check:
```sh
command -v jq && command -v python3 && echo "deps OK"
```

No API key, no specific model gateway, and no specific model required. Out of the
box, the judge runs on your session's default model (whatever you have configured).
To get the cross-family benefit, your gateway should expose at least one model
from a *different family* than the one doing the work, under an Anthropic-compatible
ID — set `QC_MODEL` / `QC_MODEL2` to that ID (see [Configuration](#configuration)).

---

## Install

ValidationLoop is a standard Claude Code plugin marketplace. Register it from this
repo and install:

```
claude plugin marketplace add https://github.com/iam-pattan/ValidationLoopPlugin
claude plugin install validation-loop@validation-loop-marketplace
```

Then restart Claude Code. It clones the repo, enables the plugin, and registers
the `UserPromptSubmit` + `PostToolUse` hooks and the `/validate` command
automatically. No manual hook editing.

**Alternative — declarative `settings.json`** (locked-down setups, or config over
CLI):

```json
{
  "extraKnownMarketplaces": {
    "validation-loop-marketplace": {
      "source": {
        "source": "git",
        "url": "https://github.com/iam-pattan/ValidationLoopPlugin.git"
      }
    }
  },
  "enabledPlugins": {
    "validation-loop@validation-loop-marketplace": true
  }
}
```

Restart Claude Code after pasting.

**Local tryout (no GitHub):** clone/copy this repo and point a directory source
at the repo root:

```
/plugin marketplace add /path/to/ValidationLoopPlugin
/plugin install validation-loop@validation-loop-marketplace
```

### Optional: gateway model discovery

If your gateway exposes custom (non-standard) model IDs that you want to use as
the cross-family validator, enable gateway model discovery so those IDs resolve in
the main session (not just inside the judge subprocess, which forces it on
already). Set it in both places:

`~/.zshrc` (or `~/.bashrc`):
```sh
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
```

`~/.claude/settings.json` (merge into the `env` block):
```json
{ "env": { "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1" } }
```

---

## Configuration

All optional, via the `env` block in your `~/.claude/settings.json` (or your
shell). The plugin ships working defaults — it runs on your session's default
model with no configuration at all. Override to point at cross-family models for
the real second-opinion benefit:

| Variable | Default | Purpose |
|---|---|---|
| `QC_MODE` | `advisory` | `advisory` = never blocks (prints a note). `block` = REWORK verdicts block until fixed. |
| `QC_MODEL` | *(empty = session default)* | Preferred primary validating model ID. **Set to a different-family model for the real second-opinion benefit.** |
| `QC_MODEL2` | *(empty = session default)* | Second / tie-breaker model ID (used on REVIEW-band results, and as the next fallback). |
| `QC_FALLBACK_MODEL` | *(empty = session default)* | Extra fallback used when the named models don't resolve on your gateway. After this, the hook falls back once more to your session's default model. |

> **Out of the box, all three model vars are empty**, meaning the judge runs on
> your session's own default model. That makes the plugin work immediately on any
> setup, but it is the *same model* (or same family) doing the work and the review.
> To get the actual value of this tool, point `QC_MODEL` and `QC_MODEL2` at a
> **different model family** your gateway serves (e.g. a GLM, Qwen, Llama, or
> Gemini-class model exposed under an Anthropic-compatible ID). The fallback
> staying on the session default is fine — it's the last resort, not the primary.

Example `settings.json` env block pointing at different-family primaries:

```json
{
  "env": {
    "QC_MODEL": "your-gateway-glm-model-id",
    "QC_MODEL2": "your-gateway-qwen-model-id"
  }
}
```

Other tweaks:
- **Change dimension weights / thresholds:** edit `scripts/glm-qc-score.py`
  (`WEIGHTS`, `PASS_MIN`, `REVIEW_MIN`) in the installed plugin. Weights must sum
  to 1.0.
- **Single validator only (no tie-breaker):** point `QC_MODEL2` at the same model
  as `QC_MODEL`.
- **On-demand `qc-reviewer` subagent:** its model is whatever your session runs by
  default (it has no `model:` frontmatter, so it inherits the session default). To
  run it on a specific model, add a `model:` line to `agents/qc-reviewer.md`
  frontmatter.

---

## How it triggers

1. **You submit a prompt.** The UserPromptSubmit hook (`goal-capture.sh`)
   appends it to a per-session goal log and re-injects a trimmed extract of your
   *prior* goals as `additionalContext` — so the running session keeps its
   objective across context compaction. Slash commands are not goals (`/clear`
   resets the log; other `/` commands are ignored). Zero added latency.
2. Claude completes a task and edits/creates files. Each changed file is recorded
   automatically (PostToolUse tracking hook). This never runs a model — it just
   appends a path to a per-session list.
3. **When you run `/validate`**, the validator reads both the changed-file list
   *and* the goal log, runs the validating model(s), scores the work, and:
   - emits the 5-dimension weighted score → **PASS / REVIEW / REWORK**;
   - if goals were captured, appends a **GOAL ALIGNMENT** advisory block:
     an `alignment` score (0–100, cited) + a `deviations` list (where delivered
     work diverges from the stated goals, each with severity + evidence).
   - **advisory:** shows the score + findings as a non-blocking note;
   - **block:** on a REWORK verdict, blocks and feeds the findings back so Claude fixes them.
4. If you never run `/validate`, no model ever runs — goals and changed files are
   simply tracked and discarded with the session. Pure Q&A turns (no file changes)
   leave nothing to validate.

Cost: each `/validate` run makes 1 (or 2, on borderline) headless model calls
(~15–60s). Recursion (`QC_RUNNING`) and one-pass (`stop_hook_active`) guards
prevent infinite loops.

---

## Privacy / data note

The **contents of changed files are sent to the validating model** through your
configured `ANTHROPIC_BASE_URL`. Only use models and a gateway approved for your
data's sensitivity. Nothing leaves your configured endpoint — the judge is a
headless `claude -p` call against the same endpoint your session uses.

The changed-file *paths* and goal-log *text* (not file contents) are temporarily
written to `/tmp/claude/glm-qc/<session>.*` (mode 600, owner-only, TOCTOU-hardened)
and deleted at the end of each validation run. The calibration log at
`~/.claude/qc-scores.jsonl` stores only scores and verdicts, not file contents.

---

## Tests

A deterministic test suite (no model calls) lives at `scripts/test-v1.5.sh`:

```sh
sh plugins/validation-loop/scripts/test-v1.5.sh
```

It covers the capture hook, the advisory alignment block, the no-goals regression
invariant, and the randomized-delimiter / byte-bound / whitespace-gate fixes.

---

## Uninstall

```
/plugin uninstall validation-loop@validation-loop-marketplace
```

The calibration log at `<config-dir>/qc-scores.jsonl` is left in place — delete it
manually if you want.

## Version

1.5.0 — **goal-aware validation.** A new `UserPromptSubmit` hook
(`scripts/goal-capture.sh`) captures each submitted prompt into a per-session
goal log and re-injects a trimmed extract as `additionalContext` each turn — a
compaction-resistant objective anchor for the live session. At `/validate` time,
`glm-qc.sh` reads the goal log and, when present, extends the judge prompt to
also score an `alignment` dimension (did the work do what was asked?) and emit a
structured `deviations` list. `glm-qc-score.py` appends a **GOAL ALIGNMENT**
advisory block to the report. **The 5-dimension weighted score and the
PASS/REVIEW/REWORK verdict are unchanged** — alignment is advisory-only, so the
calibration baseline stays valid. When no goal log exists, behavior is
byte-identical to the base prompt. `/clear` resets the goal log; other slash
commands are not captured. New `scripts/test-v1.5.sh` covers the capture hook, the
advisory block, and the no-goals regression invariant. `hooks/hooks.json` adds the
`UserPromptSubmit` block; the `PostToolUse` block is untouched.

1.4.0 — **on-demand validation via `/validate`.** The every-task Stop hook is
removed; changed files are still tracked automatically (PostToolUse), but the
second-model judge now runs only when you type `/validate`. No more surprise
end-of-task spins or advisory nitpick clutter on routine edits.

1.3.0 — **zero-setup, error-resilient validation.** The judge subprocess forces
`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` and walks a model fallback chain,
using the first model that responds. Validation is skipped only if the entire
model layer is unreachable — never because a preferred model is missing.

1.2.0 — renamed to **ValidationLoop**. Fixes two bugs: `glm-qc-score.py` crashed
with `ZeroDivisionError` when invoked with zero judge files, and its JSON
extractor gave up on the first unbalanced `{` instead of continuing to scan.

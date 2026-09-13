# ValidationLoop — Setup Guide

A self-contained guide to **ValidationLoop**: an **on-demand second-model
validation** layer for Claude Code. When you run `/validate` after a task that
changed files, an *independent* model validates the work against a weighted
rubric and surfaces a confidence score. On a borderline score, a second model is
pulled in as a tie-breaker and the two are averaged.

> Two independent models must agree before you rely on the result.

> **v1.5.0 — goal awareness.** A `UserPromptSubmit` hook captures each prompt
> into a per-session goal log and re-injects a trimmed extract each turn
> (compaction-resistant objective anchor). At `/validate` time, if a goal log
> exists, the judge also scores an advisory `alignment` dimension + a
> `deviations` list. The 5-dimension weighted score and PASS/REVIEW/REWORK
> verdict are **unchanged** — alignment is advisory-only.

This document covers the methodology, the install steps, and the configuration.

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [The methodology](#2-the-methodology)
3. [Prerequisites](#3-prerequisites)
4. [Install](#4-install)
5. [Configuration reference](#5-configuration-reference)
6. [How a validation run works](#6-how-a-validation-run-works)
7. [Privacy & data note](#7-privacy--data-note)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. What it does

| Piece | What it does |
|---|---|
| `qc-reviewer` subagent | On-demand independent validator — ask Claude to *"use the qc-reviewer agent to review this."* |
| UserPromptSubmit hook | Captures each submitted prompt into a per-session goal log (`goal-capture.sh`). Also re-injects a trimmed extract as `additionalContext` each turn. |
| PostToolUse hook | Records which files changed this session (`glm-qc-mark.sh`). |
| `/validate` command | Runs the second-model QC over this session's changed files, on demand (`validate.sh` → `glm-qc.sh`). |
| Scorer | Computes the weighted confidence score and the PASS/REVIEW/REWORK verdict (`glm-qc-score.py`). |

**Actions by final verdict:**
- **PASS (≥85)** — allow finish silently.
- **REVIEW (65–84)** — surface an advisory note (never blocks).
- **REWORK (<65)** — block in enforcing mode; advisory otherwise.

Pure Q&A turns (no file changes) are skipped entirely — validation only fires on
tasks that actually edit or create files.

---

## 2. The methodology

### The rubric (0–100, weighted)

Five dimensions, weighted to reflect what matters for analytical/engineering work:

| Dimension | Weight | Meaning |
|---|---|---|
| Truthfulness | 30% | Claims correct & verifiable against the code/output |
| Validation | 25% | Actually tested / reconciled; edge cases handled |
| Authenticity | 20% | Grounded in real artifacts — nothing fabricated |
| Derivations | 15% | Logic / math / SQL sound and reproducible |
| Assumptions | 10% | Assumptions explicit & reasonable, not silently baked in |

Weights and thresholds are **enforced by code, not the model** — the validating
model produces per-dimension scores and citations; the scorer computes the
weighted total and the verdict. This prevents the model from rubber-stamping its
own output.

### Guardrails on the validating model itself

- **Every score needs a `file:line` citation.** A score ≥70 with no citation is
  capped at 65. No rubber-stamps.
- **Uncertainty must score low, not high.**
- **Missing dimension → penalized**, not assumed good (conservative 40).
- **Unparseable judge output → REVIEW**, never a silent PASS.
- **Ensemble disagreement is flagged.** When two judges differ by >20 points, the
  report marks it low-confidence regardless of the average.

### The model fallback chain (why validation is never silently skipped)

The judge tries models in order and uses the **first that produces output**:

```
QC_MODEL  →  QC_MODEL2  →  QC_FALLBACK_MODEL  →  session default
```

Out of the box the first three are empty, so the judge runs on your **session's
default model**. Validation is skipped **only if the entire model layer is
unreachable** — never because a named model is missing. The report labels
whichever model actually ran, so a fallback is *visible, not silent*.

### Why a *different* model family?

The whole point is a genuinely independent review. If the validating model is the
same family as the one that did the work, it shares the same blind spots. That's
why the defaults use the session model (so it works zero-config) but the docs push
you to set `QC_MODEL` / `QC_MODEL2` to a **different-family** model your gateway
exposes.

---

## 3. Prerequisites

- **Claude Code** with plugins enabled.
- **`jq`** and **`python3`** on your PATH (the hooks call them).

Check:
```sh
command -v jq && command -v python3 && echo "deps OK"
```

No API key and no specific gateway required — the judge reuses the `claude -p`
subprocess against your configured `ANTHROPIC_BASE_URL`, with whatever model your
session uses by default.

---

## 4. Install

```
claude plugin marketplace add https://github.com/iam-pattan/ValidationLoopPlugin
claude plugin install validation-loop@validation-loop-marketplace
```

Then restart Claude Code. It clones the repo, enables the plugin, and registers
the `UserPromptSubmit` + `PostToolUse` hooks and the `/validate` command
automatically.

**Verify it's loaded:**
```
/plugin list
```
You should see `validation-loop@validation-loop-marketplace` enabled.

**Test it:** make Claude edit a file, then run `/validate`. You should see a
`=== ValidationLoop ===` block with a confidence score and per-dimension
breakdown. If you submitted prompts first, you'll also see a GOAL ALIGNMENT
advisory block. A pure Q&A turn (no file edits) should produce nothing — the hook
skips it.

---

## 5. Configuration reference

All optional. The plugin ships working defaults (session default model); override
to point at your gateway's models. Set these in the `env` block of
`~/.claude/settings.json` or your shell.

| Variable | Default | Purpose |
|---|---|---|
| `QC_MODE` | `advisory` | `advisory` = never blocks. `block` = REWORK verdicts block until fixed. |
| `QC_MODEL` | *(empty = session default)* | Preferred primary validating model ID. **Set to a different-family model for the real second-opinion benefit.** |
| `QC_MODEL2` | *(empty = session default)* | Second / tie-breaker model ID (used on REVIEW-band results, and as the next fallback). |
| `QC_FALLBACK_MODEL` | *(empty = session default)* | Extra fallback. After this, the hook falls back once more to your session's default model. |

> **Out of the box, all three model vars are empty** — the judge runs on your
> session's own default model. To get the actual value, point `QC_MODEL` and
> `QC_MODEL2` at a **different model family** your gateway serves (e.g. a GLM,
> Qwen, Llama, or Gemini-class model exposed under an Anthropic-compatible ID).

Other tweaks:
- **Change dimension weights / thresholds:** edit `scripts/glm-qc-score.py`
  (`WEIGHTS`, `PASS_MIN`, `REVIEW_MIN`) in the installed plugin. Weights must sum
  to 1.0.
- **Single validator only (no tie-breaker):** point `QC_MODEL2` at the same model
  as `QC_MODEL`.

Example `settings.json` env block pointing at different-family primaries:

```json
{
  "env": {
    "QC_MODEL": "your-gateway-glm-model-id",
    "QC_MODEL2": "your-gateway-qwen-model-id"
  }
}
```

---

## 6. How a validation run works

```
You submit a prompt
        |
        v
UserPromptSubmit -- goal-capture.sh appends to /tmp/.../<session>.goals
                  + re-injects a trimmed extract as additionalContext
        |
        v
Claude edits files during a task
        |
        v
PostToolUse(Write|Edit|MultiEdit) -- glm-qc-mark.sh appends path to <session>.files
        |
        v
You run /validate -- validate.sh -> glm-qc.sh:
  1. Read & dedupe the changed-file list; drop paths that no longer exist.
  2. Read the goal log; if present and non-trivial, build the goal-aware prompt.
  3. run_judge(): try QC_MODEL -> QC_MODEL2 -> QC_FALLBACK_MODEL -> session default.
     First model that returns non-empty output wins.
  4. score.py: extract JSON, apply weights + guardrails, compute verdict.
  5. If REVIEW: run a SECOND judge (different model), re-score as an average.
  6. Emit result:
       PASS   -> silent (log only)
       REVIEW -> advisory note (non-blocking)
       REWORK -> block (if QC_MODE=block) or advisory
  7. Append a compact log line to ~/.claude/qc-scores.jsonl for calibration.
```

Cost: each `/validate` run makes 1 (or 2, on borderline) headless model calls,
typically 15–60s. Recursion (`QC_RUNNING`) and one-pass (`stop_hook_active`)
guards prevent infinite loops.

---

## 7. Privacy & data note

The **contents of changed files are sent to the validating model** through your
configured `ANTHROPIC_BASE_URL`. Only use models and a gateway approved for your
data's sensitivity. Nothing leaves your configured endpoint.

The changed-file *paths* and goal-log *text* (not file contents) are temporarily
written to `/tmp/claude/glm-qc/<session>.*` (mode 600, owner-only) and deleted at
the end of each validation run. The calibration log at
`~/.claude/qc-scores.jsonl` stores only scores and verdicts, not file contents.

---

## 8. Troubleshooting

**No validation output after editing files.**
- Confirm the plugin is enabled: `/plugin list`.
- Confirm `jq` and `python3` are on PATH: `command -v jq python3`.

**Validation always silently no-ops (no score, no error).**
- Every model in the chain returned empty. If you set `QC_MODEL` / `QC_MODEL2` to
  IDs your gateway doesn't serve, clear them (back to session default) or set them
  to IDs that resolve. Test a model ID directly:
  `claude -p "hi" --model <id>`.

**`/model` picker or the subagent doesn't show custom model IDs.**
- Enable gateway model discovery in **both** `~/.zshrc` and `settings.json` (see
  the README's "Optional: gateway model discovery" section), then restart.

**Judge output is always "unparseable."**
- The model is returning prose instead of JSON. `extract_json` handles fences and
  scans past stray braces, but if the model never emits a balanced `{...}`, it
  can't recover. Try a more instruction-following model for `QC_MODEL`.

**REWORK verdict blocks but you disagree.**
- Switch to advisory mode: set `QC_MODE=advisory` (the default). The verdict is
  still surfaced as a note; it just won't block.

**Want to see what the judges actually returned?**
- Temporarily comment out the `rm -f "$GLM_RAW"` / `rm -f "$KIMI_RAW"` lines in
  `glm-qc.sh` and inspect `/tmp/claude/glm-qc/<session>.glm.raw` after a run.
  Re-enable the cleanup when done.

**Calibration log growing unbounded.**
- `~/.claude/qc-scores.jsonl` is append-only. Rotate or truncate it periodically:
  `tail -1000 ~/.claude/qc-scores.jsonl > /tmp/qc.tmp && mv /tmp/qc.tmp ~/.claude/qc-scores.jsonl`

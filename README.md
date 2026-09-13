# ValidationLoopPlugin

> **ValidationLoop** — an on-demand second-model validation layer for [Claude Code](https://claude.com/claude-code). When you run `/validate`, an *independent* model validates your session's changed files against a weighted rubric and surfaces a PASS / REVIEW / REWORK confidence score. On a borderline score, a second model is added as a tie-breaker and the two are averaged.

**Works out of the box with your session's default model — zero config, no API key, no specific gateway.** For a genuine cross-family second opinion, point `QC_MODEL` / `QC_MODEL2` at a different-family model your gateway serves.

## What's in this repo

```
ValidationLoopPlugin/
├── .claude-plugin/
│   └── marketplace.json                 # marketplace manifest (root)
├── plugins/
│   └── validation-loop/                 # the plugin
│       ├── .claude-plugin/plugin.json
│       ├── agents/qc-reviewer.md        # on-demand independent validator subagent
│       ├── commands/validate.md         # the /validate slash command
│       ├── hooks/hooks.json             # UserPromptSubmit (goal capture) + PostToolUse (file tracking)
│       └── scripts/
│           ├── goal-capture.sh          # UserPromptSubmit hook — captures goals, re-injects as additionalContext
│           ├── glm-qc-mark.sh           # PostToolUse hook — records changed files
│           ├── validate.sh              # /validate entry point
│           ├── glm-qc.sh                # runs the judge, scores, surfaces verdict
│           ├── glm-qc-score.py          # weighted rubric scorer + verdict
│           └── test-v1.5.sh             # deterministic test suite
├── docs/superpowers/specs/              # design spec
├── SETUP-GUIDE.md
└── LICENSE
```

## Quick install

```
claude plugin marketplace add https://github.com/iam-pattan/ValidationLoopPlugin
claude plugin install validation-loop@validation-loop-marketplace
```

Restart Claude Code. Then: type a task prompt, do some file work, run `/validate`.

Full details: **[SETUP-GUIDE.md](SETUP-GUIDE.md)** and **[plugins/validation-loop/README.md](plugins/validation-loop/README.md)**.

## v1.5.0 — goal awareness

A `UserPromptSubmit` hook captures each prompt into a per-session goal log. That log:
1. is **re-injected into the live session every turn** as `additionalContext` — a compaction-resistant "north star" so your objective survives context compaction;
2. is read by the `/validate` judge, which scores an **advisory** `alignment` dimension (did the work do what was asked?) and emits a structured `deviations` list.

The 5-dimension weighted score and PASS/REVIEW/REWORK verdict are **unchanged** — alignment is reported, not folded into the gate. See the [design spec](docs/superpowers/specs/2026-09-12-validation-loop-goal-aware-design.md).

## License

MIT

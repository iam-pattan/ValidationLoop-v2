---
description: Run the ValidationLoop second-model QC review on the files changed this session — on demand, only when you've reviewed the work and approve it.
---

# /validate

Run ValidationLoop's scored second-model QC over the files changed during this session.

Unlike an always-on Stop hook, `/validate` runs only when you ask for it — so you
can review the work first and decide when (or whether) the independent reviewer
should score it.

```
sh ${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh
```

## What it does

1. Recovers this session's id (from `CLAUDE_CODE_SESSION_ID`, falling back to the most recent marker file).
2. Reads the list of files you changed this session (tracked by the PostToolUse marker hook, which still runs automatically).
3. Reads the per-session goal log (captured by the UserPromptSubmit hook). If goals exist, the judge also scores `alignment` and emits a `deviations` list.
4. Spawns an independent judge (a second model added as a tie-breaker on a borderline REVIEW verdict) to score the work on five dimensions, prints the verdict and summary.

## Notes

- If you haven't changed any files this session, it exits with "nothing to validate."
- Mode follows `QC_MODE` (currently `advisory`): a low score surfaces an advisory note rather than blocking. Flip to `block` if you want rework forced.
- Out of the box the judge runs on your session's default model. For a cross-family second opinion, set `QC_MODEL` / `QC_MODEL2` to different-family model IDs your gateway serves.
- The judge spins up a headless `claude -p` subprocess, so expect ~15–40s.

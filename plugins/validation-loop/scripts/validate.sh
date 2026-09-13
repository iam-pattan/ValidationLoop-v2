#!/bin/sh
# validate.sh — on-demand entry point for ValidationLoop.
#
# Invoked by the /validate slash command. Unlike a Stop hook, a slash command
# gets no hook JSON on stdin, so the session id is recovered from the env var
# Claude Code exports into every Bash subprocess (CLAUDE_CODE_SESSION_ID). That
# id is the same one glm-qc-mark.sh recorded changed files under, so the judge
# reviews exactly this session's work.
#
# Behavior is identical to the former Stop hook: if no files changed this
# session, it exits silently; otherwise it hands off to glm-qc.sh, which runs
# the independent judge and emits a verdict under the current QC_MODE.
#
# To use: type /validate when you have reviewed the work and want it QC'd.

SID="${CLAUDE_CODE_SESSION_ID:-}"

# Fall back to the freshest marker file if the env var is absent (e.g. run by
# hand from a shell outside Claude Code). Keeps the command usable for ad-hoc
# validation of the most recently active session.
if [ -z "$SID" ]; then
  DIR="$(cd -P /tmp 2>/dev/null && pwd)/claude/glm-qc"
  SID=$(ls -t "$DIR"/*.files 2>/dev/null | head -1 | sed -E 's#.*/##; s#\.files$##')
fi
[ -n "$SID" ] || { echo "ValidationLoop: no active session id and no marker files found — nothing to validate." >&2; exit 0; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Hand the script the same shape of stdin a Stop hook would have provided, so
# glm-qc.sh runs unchanged (it reads session_id and stop_hook_active from it).
printf '{"session_id":"%s","stop_hook_active":false}' "$SID" | sh "$HERE/glm-qc.sh"

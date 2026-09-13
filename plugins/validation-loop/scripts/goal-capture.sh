#!/bin/sh
# goal-capture.sh (v1.5) — UserPromptSubmit hook for ValidationLoop.
#
# Two jobs, both pure-shell / zero-model-call so prompt-submit stays snappy:
#   1. APPEND this prompt to the per-session goal log at
#      /tmp/claude/glm-qc/<session>.goals — the /validate judge reads this later
#      to score goal alignment + flag deviations from the ask.
#   2. EMIT additionalContext carrying a trimmed extract of the PRIOR goals back
#      into the live turn — a compaction-resistant "north star" so the running
#      session keeps its objective even after context compaction summarizes away
#      the original prompt.
#
# Slash commands are not goals: /clear resets the goal log (fresh objective for
# post-clear work); any other slash command is ignored (no append, no injection).
# Any failure exits 0 with no JSON — a capture hook must never break the session.
#
# Mirrors the TOCTOU-safe /tmp hardening of glm-qc-mark.sh: the goal log lives
# alongside the changed-file list under the same owner-only, no-symlink regime.

IN=$(cat)
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null)
case "$SID" in
  *[!A-Za-z0-9_-]*|'') SID=nosession ;;
esac
UI=$(printf '%s' "$IN" | jq -r '.user_input // empty' 2>/dev/null)
[ -n "$UI" ] || exit 0
# Detect slash commands even with leading whitespace (a user may type "  /clear").
UI_TRIM=$(printf '%s' "$UI" | sed -E 's/^[[:space:]]+//')

# --- symlink/TOCTOU-safe helpers (identical to glm-qc-mark.sh) ---
secure_dir() {
  path="$1"; rel="$2"
  IFS='/'; set -- $rel; IFS=' '
  for part in "$@"; do
    [ -z "$part" ] && continue
    path="$path/$part"
    [ -L "$path" ] && return 1
    if [ -e "$path" ]; then
      [ -d "$path" ] || return 1
    else
      ( umask 077; mkdir "$path" ) 2>/dev/null || return 1
    fi
  done
  owner=$(stat -f '%u' "$path" 2>/dev/null || stat -c '%u' "$path" 2>/dev/null)
  [ "$owner" = "$(id -u)" ] || return 1
  chmod 700 "$path" 2>/dev/null
  return 0
}
secure_file() {
  [ -L "$1" ] && return 1
  if [ -e "$1" ]; then
    [ -f "$1" ] || return 1
    owner=$(stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null)
    [ "$owner" = "$(id -u)" ] || return 1
  else
    ( umask 077; : > "$1" ) 2>/dev/null || return 1
  fi
  return 0
}

TMPBASE=$(cd -P /tmp 2>/dev/null && pwd) || TMPBASE=/tmp
DIR="$TMPBASE/claude/glm-qc"
secure_dir "$TMPBASE" "claude/glm-qc" || exit 0
GOALS="${DIR}/${SID}.goals"

# --- slash-command handling: not goals (check the trimmed form) ---
case "$UI_TRIM" in
  /*)
    case "$UI_TRIM" in
      /clear|"/clear "*)
        # Reset the goal log so post-clear work gets a fresh objective — without
        # this, a stale pre-clear goal would mis-anchor both the live session
        # and the judge.
        secure_file "$GOALS" && : > "$GOALS" 2>/dev/null
        ;;
    esac
    exit 0
    ;;
esac

# --- build the prior-goals extract BEFORE appending the current prompt ---
# (the current prompt is already reaching the model as user_input; injecting it
#  again as a "recent refinement" would be redundant. Anchoring matters from
#  turn 2 onward, when prior goals may scroll out of context.)
EXTRACT=""
if [ -s "$GOALS" ]; then
  EXTRACT=$(python3 - "$GOALS" <<'PY'
import sys, re
path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = [l.rstrip("\n") for l in fh if l.strip()]
except OSError:
    sys.exit(0)
if not lines:
    sys.exit(0)
ACTIONS = re.compile(
    r"\b(fix|add|build|create|update|refactor|implement|analyz|investigat|"
    r"write|run|check|validat|debug|improv|configur|deploy|generat|extract|"
    r"find|review|optim|migrat|remov|chang|modif|test|handl|support|enabl|"
    r"disabl|extend|set\s+up|figure\s+out|look\s+into|dig\s+into)\b", re.I)
def nontrivial(s):
    return len(s.split()) >= 8 or bool(ACTIONS.search(s))
primary = next((l for l in lines if nontrivial(l)), lines[0])
primary_idx = lines.index(primary)
# Recent refinements: last up-to-3 non-trivial lines, excluding the primary
# (so a single-goal session doesn't echo its objective back as a "refinement").
recent = [l for i, l in enumerate(lines) if i != primary_idx and nontrivial(l)][-3:]
out = ["[Goal anchor — your accumulated task objective for this session, "
       "re-injected each turn so it survives context compaction. Treat as the "
       "north star, not a new request.]",
       "Primary objective: " + primary]
if recent:
    out.append("Recent refinements:")
    for r in recent:
        out.append("  - " + r)
text = "\n".join(out)
MAX = 1500
if len(text) > MAX:
    text = text[:MAX - 3] + "..."
print(text)
PY
)
fi

# --- append the current prompt (newlines collapsed to one logical line) ---
secure_file "$GOALS" || exit 0
ESC=$(printf '%s' "$UI" | tr '\n\r' '  ')
printf '%s\n' "$ESC" >> "$GOALS"

# --- emit additionalContext (only when there were prior goals to anchor on) ---
if [ -n "$EXTRACT" ]; then
  printf '%s' "$EXTRACT" | jq -Rs '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:.}}'
fi
exit 0

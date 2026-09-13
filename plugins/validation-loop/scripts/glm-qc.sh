#!/bin/sh
# glm-qc.sh (v1.5, plugin) — validate entry. When the main Claude session finishes
# a task and files changed, an independent judge scores the work against a rubric
# and emits an analytics-weighted confidence score. On a borderline (REVIEW)
# verdict a second, different model is added as a tie-breaker and averaged.
#
# GOAL-AWARE (v1.5): if a per-session goal log was captured by the UserPromptSubmit
# hook (goal-capture.sh -> <session>.goals), the judge prompt is EXTENDED to also
# score an "alignment" dimension (advisory-only) and emit a "deviations" list. The
# 5-dimension weighted score and the PASS/REVIEW/REWORK verdict are UNCHANGED —
# alignment is reported, not folded into the gate. When no goal log exists, the
# base prompt runs.
#
# GENERIC MODEL DEFAULTS: out of the box the judge runs on your session's own
# default model (zero config). For a genuine cross-family second opinion, set
# QC_MODEL / QC_MODEL2 to different-family model IDs your gateway serves. The
# hook walks a fallback chain and uses the first model that responds, so it is
# never silently skipped unless the entire model layer is unreachable.
#
# Actions by final verdict:
#   PASS   (>=85) -> allow finish silently
#   REVIEW (65-84)-> surface an advisory note (never blocks)
#   REWORK (<65)  -> block in QC_MODE=block; advisory otherwise
#
# Modes (env QC_MODE): block | advisory (default advisory).
# Guards: QC_RUNNING (no recursion), stop_hook_active (one pass/task).

[ -n "$QC_RUNNING" ] && exit 0

IN=$(cat)
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null)
case "$SID" in
  *[!A-Za-z0-9_-]*|'') SID=nosession ;;
esac
ACTIVE=$(printf '%s' "$IN" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$ACTIVE" = "true" ] && exit 0

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCORER="$HERE/glm-qc-score.py"
LOG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/qc-scores.jsonl"

# --- symlink/TOCTOU-safe helpers for the shared, world-writable /tmp dir ---
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
verify_file() {
  [ -L "$1" ] && return 1
  [ -f "$1" ] || return 1
  owner=$(stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null)
  [ "$owner" = "$(id -u)" ]
}
secure_file() {
  [ -L "$1" ] && return 1
  if [ -e "$1" ]; then
    verify_file "$1" || return 1
  else
    ( umask 077; : > "$1" ) 2>/dev/null || return 1
  fi
  return 0
}

TMPBASE=$(cd -P /tmp 2>/dev/null && pwd) || TMPBASE=/tmp
DIR="$TMPBASE/claude/glm-qc"
secure_dir "$TMPBASE" "claude/glm-qc" || exit 0
PENDING="${DIR}/${SID}.files"
verify_file "$PENDING" || exit 0

FILES=$(sort -u "$PENDING" | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)
rm -f "$PENDING"
[ -z "$FILES" ] && exit 0
LIST=$(printf '%s' "$FILES" | tr '\n' ' ')
MODE="${QC_MODE:-advisory}"
# GENERIC DEFAULTS: empty means "use the session's default model" (zero-config).
# For a cross-family second opinion, set QC_MODEL/QC_MODEL2 to different-family
# IDs your gateway serves (e.g. a GLM, Qwen, Llama, or Gemini model exposed under
# an Anthropic-compatible ID). The fallback chain always ends at the session
# default, so validation is never skipped because a named model is missing.
DEFAULT_SENTINEL="__session_default__"
MODEL1="${QC_MODEL:-}"
MODEL2="${QC_MODEL2:-}"
FALLBACK="${QC_FALLBACK_MODEL:-}"

# --- v1.5: load the per-session goal log (captured by goal-capture.sh) ---
GOALS_FILE="${DIR}/${SID}.goals"
GOALS=""
if [ -f "$GOALS_FILE" ] && verify_file "$GOALS_FILE"; then
  GOALS=$(cat "$GOALS_FILE" 2>/dev/null)
fi
# Trivial/empty guard: must be >=10 bytes, >=1 line, AND contain non-whitespace.
GOAL_AWARE=0
if [ -n "$GOALS" ]; then
  GLEN=$(printf '%s' "$GOALS" | wc -c | tr -d ' ')
  GLINES=$(printf '%s' "$GOALS" | grep -c '.' || true)
  if [ "$GLEN" -ge 10 ] && [ "$GLINES" -ge 1 ] \
     && printf '%s' "$GOALS" | grep -q '[^[:space:]]'; then
    GOAL_AWARE=1
  fi
fi
if [ "$GOAL_AWARE" = "1" ]; then
  GOALS_BOUNDED=$(printf '%s\n' "$GOALS" | tail -20 | head -c 8000)
else
  GOALS_BOUNDED=""
fi

# Per-invocation randomized delimiters for the goal block (defends against a goal
# line containing a guessed closing marker injecting text into the judge prompt).
DELIM_OPEN="GOALS_$(ls -i "$GOALS_FILE" 2>/dev/null | awk '{print $1}')_$$"
DELIM_CLOSE="END_${DELIM_OPEN}"

# Map a raw model id (or the session-default sentinel) to a human label.
label_of() {
  case "$1" in
    "$DEFAULT_SENTINEL") printf 'session default' ;;
    "")                  printf 'session default' ;;
    *)                   printf '%s' "$1" ;;
  esac
}

# --- base prompt: runs when no goals captured ---
SCHEMA='{"dimensions":{"authenticity":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"truthfulness":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"derivations":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"assumptions":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"validation":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"}},"top_issues":["..."],"unverified_claims":["..."]}'
DEFS='authenticity=grounded in real artifacts, no fabricated files/tables/columns/numbers; truthfulness=claims correct and verifiable against the actual code/output; derivations=logic/math/SQL reasoning sound and reproducible from inputs; assumptions=explicit and reasonable, not silently baked in; validation=actually tested/reconciled, edge cases handled.'
prompt_for() {
  printf 'You are an independent QC reviewer on %s, reviewing work produced by a DIFFERENT AI. Read each changed file yourself; trust no summary. Score five dimensions 0-100 and OUTPUT ONLY a JSON object (no markdown fences, no prose) exactly matching this shape: %s\nRules: give a real file:line citation for EVERY score; when you cannot verify something, score it LOW, not high. Definitions: %s\nFiles: %s' "$1" "$SCHEMA" "$DEFS" "$2"
}

# --- v1.5 goal-aware prompt: adds the goal log + alignment + deviations ---
SCHEMA_GOAL='{"dimensions":{"authenticity":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"truthfulness":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"derivations":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"assumptions":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"},"validation":{"score":<0-100>,"cite":"<file:line>","evidence":"<short>"}},"alignment":{"score":<0-100>,"cite":"<goal line + file:line>","evidence":"<short>"},"deviations":[{"claimed_goal":"<short>","delivered":"<short>","severity":"high|med|low","evidence":"<file:line>"}],"top_issues":["..."],"unverified_claims":["..."]}'
prompt_for_goal_aware() {
  # $1 = label, $2 = file list, $3 = bounded goal log, $4 = open delim, $5 = close delim
  printf 'You are an independent QC reviewer on %s, reviewing work produced by a DIFFERENT AI. Read each changed file yourself; trust no summary.\n\nThe user'"'"'s submitted goals for this session were:\n<<<%s>>>\n%s\n<<<%s>>>\n\nScore five dimensions 0-100 and OUTPUT ONLY a JSON object (no markdown fences, no prose) exactly matching this shape: %s\nRules: give a real file:line citation for EVERY score; when you cannot verify something, score it LOW, not high. Definitions: %s\n\nALSO score "alignment" 0-100: did the work accomplish what was ASKED in the goals? Cite both the goal line AND the file:line that addresses (or fails to address) it.\nALSO emit "deviations": where delivered work diverges from stated goals — each as {claimed_goal, delivered, severity (high|med|low), evidence (file:line)}. Empty list if aligned.\n\nCRITICAL: alignment measures GOAL-COVERAGE, NOT code quality (that is the other 5 dimensions) — keep them orthogonal. Do not double-count: bad code is already penalized under truthfulness/validation; alignment is only about whether the work did what was asked.\n\nFiles: %s' "$1" "$4" "$3" "$5" "$SCHEMA_GOAL" "$DEFS" "$2"
}

# run_judge: try each candidate model in order until one produces non-empty
# output. CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 is forced on the judge
# subprocess so custom gateway model ids resolve with NO user setup; QC_RUNNING=1
# prevents the judge's own hook from recursing. Empty model id or the sentinel
# both mean "session default". Echoes the id that produced output; non-zero if none.
# $1=outfile  $2..=candidate model ids (empty/sentinel = session default)
run_judge() {
  out="$1"; shift
  for m in "$@"; do
    lbl=$(label_of "$m")
    if [ "$GOAL_AWARE" = "1" ]; then
      prompt=$(prompt_for_goal_aware "$lbl" "$LIST" "$GOALS_BOUNDED" "$DELIM_OPEN" "$DELIM_CLOSE")
    else
      prompt=$(prompt_for "$lbl" "$LIST")
    fi
    if [ -z "$m" ] || [ "$m" = "$DEFAULT_SENTINEL" ]; then
      QC_RUNNING=1 CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 \
        claude -p "$prompt" 2>/dev/null \
        | tr -d '\000-\010\013\014\016-\037\177' > "$out" || true
    else
      QC_RUNNING=1 CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 \
        claude -p "$prompt" --model "$m" 2>/dev/null \
        | tr -d '\000-\010\013\014\016-\037\177' > "$out" || true
    fi
    if [ -s "$out" ]; then
      printf '%s' "$m"
      return 0
    fi
  done
  return 1
}

# Build the candidate chain: named models first (if any), then the session
# default as the final fallback so validation is never silently skipped.
set --
[ -n "$MODEL1" ] && set -- "$@" "$MODEL1"
[ -n "$MODEL2" ] && set -- "$@" "$MODEL2"
[ -n "$FALLBACK" ] && set -- "$@" "$FALLBACK"
set -- "$@" "$DEFAULT_SENTINEL"

# Primary judge: first model in the chain that yields output wins.
GLM_RAW="${DIR}/${SID}.glm.raw"
secure_file "$GLM_RAW" || exit 0
PRIMARY_MODEL=$(run_judge "$GLM_RAW" "$@")
[ -s "$GLM_RAW" ] || exit 0

export QC_GOAL_AWARE="$GOAL_AWARE"
RESULT=$(QC_JUDGE_LABELS="$(label_of "$PRIMARY_MODEL")" python3 "$SCORER" "$GLM_RAW" 2>/dev/null)
VERDICT=$(printf '%s' "$RESULT" | jq -r '.verdict // "REVIEW"' 2>/dev/null)

# Tie-breaker: on a borderline (REVIEW) verdict, add a SECOND, different model.
if [ "$VERDICT" = "REVIEW" ]; then
  KIMI_RAW="${DIR}/${SID}.kimi.raw"
  if secure_file "$KIMI_RAW"; then
    set --
    for cand in "$MODEL2" "$FALLBACK" "$DEFAULT_SENTINEL"; do
      { [ -n "$cand" ] && [ "$cand" = "$PRIMARY_MODEL" ]; } && continue
      set -- "$@" "$cand"
    done
    TIE_MODEL=""
    [ "$#" -gt 0 ] && TIE_MODEL=$(run_judge "$KIMI_RAW" "$@")
    if [ -s "$KIMI_RAW" ]; then
      RESULT=$(QC_JUDGE_LABELS="$(label_of "$PRIMARY_MODEL"),$(label_of "$TIE_MODEL")" \
               python3 "$SCORER" "$GLM_RAW" "$KIMI_RAW" 2>/dev/null)
      VERDICT=$(printf '%s' "$RESULT" | jq -r '.verdict // "REVIEW"' 2>/dev/null)
    fi
  fi
  rm -f "$KIMI_RAW"
fi
rm -f "$GLM_RAW"
[ -z "$RESULT" ] && exit 0

SUMMARY=$(printf '%s' "$RESULT" | jq -r '.summary // "QC score unavailable"' 2>/dev/null)

# Calibration log (best-effort; never fatal).
secure_file "$LOG" && printf '%s\n' "$RESULT" | jq -c '.log' >> "$LOG" 2>/dev/null || true

emit_advisory() {
  printf '%s\n%s\n' "=== ValidationLoop ===" "$SUMMARY" >&2
  jq -n --arg r "$SUMMARY" '{suppressOutput:true, systemMessage:("ValidationLoop (advisory — not blocking):\n\n" + $r)}'
  exit 0
}

case "$VERDICT" in
  PASS)
    printf '%s\n' "=== ValidationLoop: PASS ===" "$SUMMARY" >&2
    exit 0 ;;
  REWORK)
    if [ "$MODE" = "block" ]; then
      jq -n --arg r "$SUMMARY" '{decision:"block", reason:("ValidationLoop scored this task low (REWORK). Verify each dimension against the code; fix real issues and note false positives, then finish.\n\n" + $r)}'
      exit 0
    fi
    emit_advisory ;;
  *)  # REVIEW
    emit_advisory ;;
esac

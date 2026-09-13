#!/bin/sh
# glm-qc-mark.sh — PostToolUse(Write|Edit|MultiEdit) hook.
# Records each file changed this session into a per-session marker so the
# Stop hook (glm-qc.sh) knows what to QC. Runs alongside any other
# PostToolUse hooks; never blocks or errors the tool call.
IN=$(cat)
F=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"' 2>/dev/null)
case "$SID" in
  *[!A-Za-z0-9_-]*|'') SID=nosession ;;
esac
[ -n "$F" ] || exit 0

# --- symlink/TOCTOU-safe helpers for the shared, world-writable /tmp dir ---
# secure_dir: given a trusted, already-resolved base (e.g. the OS's real
# /tmp), walks each component of the untrusted relative subpath, refusing to
# follow/create through a symlink, and requires the leaf dir to be owned by
# us. (Base itself is not symlink-checked: on macOS /tmp -> /private/tmp is
# a legitimate root-owned OS symlink, not attacker-controlled.)
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
# secure_file: existing file must be a regular file we own, not a symlink;
# create it (mode 600) if absent. Safe to reuse across appends.
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
PENDING="${DIR}/${SID}.files"
secure_file "$PENDING" || exit 0
printf '%s\n' "$F" >> "$PENDING"
exit 0

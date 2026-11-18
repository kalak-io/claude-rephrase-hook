#!/usr/bin/env bash
# Installer for the rephrase-prompt hook. For each agent CLI on PATH (claude,
# codex, agy), copies the hook into its hooks dir and registers it as the
# prompt hook of that CLI. Idempotent: re-running replaces the entry, never
# duplicates it. REPHRASE_PROVIDER=claude|codex|agy makes every harness
# rewrite with that provider (default: each harness uses its own CLI).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/rephrase-prompt.sh"
SRC2="$HERE/translate-output.sh"
DEST2="${HOME}/.claude/hooks/translate-output.sh"
SETTINGS="${HOME}/.claude/settings.json"

command -v jq >/dev/null || { echo "error: jq is required (installer + hook need it)"; exit 1; }
[ -f "$SRC" ] || { echo "error: $SRC not found"; exit 1; }
"$SRC" --selftest >/dev/null || { echo "error: selftest failed, aborting"; exit 1; }

# $1 JSON file, $2 jq filter, rest = jq args. Creates the file if missing,
# keeps a .bak, and writes through a symlink (dotfiles often link these files).
edit_json() {
  local file=$1 filter=$2 tmp; shift 2
  mkdir -p "$(dirname "$file")"
  [ -s "$file" ] || echo '{}' > "$file"
  cp "$file" "$file.bak"
  tmp=$(mktemp)
  jq "$@" "$filter" "$file" > "$tmp" && cat "$tmp" > "$file" && rm -f "$tmp"
}

# Claude Code / Codex layout: .hooks.<event>[]. Drops any entry whose command
# contains $dest, then appends $entry.
# shellcheck disable=SC2016  # $ev, $dest, $entry are jq variables
REGISTER='
  .hooks[$ev] //= []
  | .hooks[$ev] |= map(select(any((.hooks // [])[]?; (.command // "") | contains($dest)) | not))
  | .hooks[$ev] += [{hooks: [$entry]}]'
# agy keys hooks.json by hook name, not by event: set ours, keep the rest.
# shellcheck disable=SC2016
REGISTER_AGY='.["rephrase-prompt"] = {PreInvocation: [$entry]}'

installed=0
for h in claude codex agy; do
  command -v "$h" >/dev/null || continue
  dest="${HOME}/.$h/hooks/rephrase-prompt.sh"
  [ "$h" = agy ] && dest="${HOME}/.gemini/config/hooks/rephrase-prompt.sh"
  cmd="$dest ${REPHRASE_PROVIDER:-$h}"
  mkdir -p "$(dirname "$dest")"
  install -m 0755 "$SRC" "$dest"
  entry=$(jq -n --arg c "$cmd" '{type:"command",command:$c,timeout:60}')
  case $h in
    claude) edit_json "$SETTINGS" "$REGISTER" --arg ev UserPromptSubmit --arg dest "$dest" --argjson entry "$entry" ;;
    codex)  edit_json "${HOME}/.codex/hooks.json" "$REGISTER" --arg ev UserPromptSubmit --arg dest "$dest" --argjson entry "$entry"
            grep -qE '^hooks *= *true' "${HOME}/.codex/config.toml" 2>/dev/null \
              || echo "note: Codex runs hooks only with 'hooks = true' under [features] in ~/.codex/config.toml"
            echo "note: Codex asks you to trust the new hook on its next start" ;;
    agy)    edit_json "${HOME}/.gemini/config/hooks.json" "$REGISTER_AGY" --argjson entry "$entry" ;;
  esac
  echo "installed → $dest ($h, rewrites with ${REPHRASE_PROVIDER:-$h})"
  installed=1
done
[ "$installed" = 1 ] || { echo "error: none of claude, codex, agy is on PATH"; exit 1; }

# --- optional: output-translation hook (MessageDisplay, Claude Code only) -
# Off by default. Enable interactively (y) or non-interactively with INSTALL_TRANSLATE=1.
want_translate=0
if ! command -v claude >/dev/null; then
  :
elif [ "${INSTALL_TRANSLATE:-0}" = "1" ]; then
  want_translate=1
elif [ -t 0 ]; then
  read -rp "Also install the output-translation hook (read replies in your language)? [y/N] " yn
  case "$yn" in [yY]|[yY][eE][sS]) want_translate=1 ;; esac
fi

if [ "$want_translate" = 1 ]; then
  lang="${TRANSLATE_LANG:-}"
  if [ -z "$lang" ] && [ -t 0 ]; then
    read -rp "Translation language? [French] " lang
  fi
  lang="${lang:-French}"

  [ -f "$SRC2" ] || { echo "error: $SRC2 not found"; exit 1; }
  install -m 0755 "$SRC2" "$DEST2"
  "$DEST2" --selftest >/dev/null || { echo "error: translate selftest failed, aborting"; exit 1; }

  edit_json "$SETTINGS" "$REGISTER" --arg ev MessageDisplay --arg dest "$DEST2" \
    --argjson entry "$(jq -n --arg c "$DEST2 $lang" '{type:"command",command:$c,timeout:10}')"

  echo "installed → $DEST2 (language: $lang)"
  echo "done. New sessions rephrase prompts ≥60 chars and show replies in $lang."
else
  echo "done. New sessions rephrase prompts ≥60 chars."
fi

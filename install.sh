#!/usr/bin/env bash
# Installer for the Claude rephrase-prompt hook.
# Copies the hook into ~/.claude/hooks/ and registers it as a global
# UserPromptSubmit hook in ~/.claude/settings.json. Idempotent: re-running
# will not duplicate the settings entry.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/rephrase-prompt.sh"
DEST="${HOME}/.claude/hooks/rephrase-prompt.sh"
SRC2="$HERE/translate-output.sh"
DEST2="${HOME}/.claude/hooks/translate-output.sh"
SETTINGS="${HOME}/.claude/settings.json"

# --- deps ----------------------------------------------------------------
command -v jq >/dev/null   || { echo "error: jq is required (installer + hook need it)"; exit 1; }
command -v claude >/dev/null || echo "warning: 'claude' CLI not on PATH — hook will no-op until it is (fails open)"

[ -f "$SRC" ] || { echo "error: $SRC not found"; exit 1; }

# --- install the hook ----------------------------------------------------
mkdir -p "$(dirname "$DEST")"
install -m 0755 "$SRC" "$DEST"
"$DEST" --selftest >/dev/null || { echo "error: selftest failed, aborting"; exit 1; }

# --- register in settings.json (idempotent) ------------------------------
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"

tmp=$(mktemp)
jq --arg cmd "$DEST" '
  .hooks.UserPromptSubmit //= []
  | if any(.hooks.UserPromptSubmit[]?; (.hooks // [])[]?.command == $cmd)
    then .
    else .hooks.UserPromptSubmit += [{hooks: [{type: "command", command: $cmd, timeout: 60}]}]
    end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "installed → $DEST"
echo "registered in $SETTINGS (backup: $SETTINGS.bak)"

# --- optional: output-translation hook (MessageDisplay) ------------------
# Off by default. Enable interactively (y) or non-interactively with INSTALL_TRANSLATE=1.
want_translate=0
if [ "${INSTALL_TRANSLATE:-0}" = "1" ]; then
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

  tmp=$(mktemp)
  jq --arg dest "$DEST2" --arg cmd "$DEST2 $lang" '
    .hooks.MessageDisplay //= []
    | .hooks.MessageDisplay |= map(select(((.hooks // [])[]?.command // "") | startswith($dest) | not))
    | .hooks.MessageDisplay += [{hooks: [{type: "command", command: $cmd, timeout: 10}]}]
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

  echo "installed → $DEST2 (language: $lang)"
  echo "done. New sessions rephrase prompts ≥60 chars and show replies in $lang."
else
  echo "done. New Claude Code sessions will rephrase prompts ≥60 chars."
fi

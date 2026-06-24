#!/usr/bin/env bash
# Installer for the Claude rephrase-prompt hook.
# Copies the hook into ~/.claude/hooks/ and registers it as a global
# UserPromptSubmit hook in ~/.claude/settings.json. Idempotent: re-running
# will not duplicate the settings entry.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/rephrase-prompt.sh"
DEST="${HOME}/.claude/hooks/rephrase-prompt.sh"
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
echo "done. New Claude Code sessions will rephrase prompts ≥60 chars."

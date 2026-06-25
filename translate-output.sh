#!/usr/bin/env bash
# MessageDisplay hook — translate Claude's on-screen prose into your language
# while the interaction stays English. Display-only: the transcript and what
# Claude sees keep the original text. Reuses Claude Code auth via `claude -p`
# (no API key). Fails open: any error/empty result => exit 0, original renders.
set -uo pipefail

# --- knobs ---------------------------------------------------------------
# Args come from the hook command in settings.json: "<script> <LANG> [MODEL]".
if [ "${1:-}" = "--selftest" ]; then SELFTEST=1; shift; else SELFTEST=0; fi
LANG_NAME="${1:-French}"   # target language; first command arg
MODEL="${2:-haiku}"        # tier alias by default (auto-tracks current Haiku)
# -------------------------------------------------------------------------

proceed() {                # return 0 = translate, 1 = skip. Pure, no claude call.
  [ "${TRANSLATE_OUTPUT:-1}" = "0" ]    && return 1   # kill switch
  [ -n "${TRANSLATE_HOOK_ACTIVE:-}" ]   && return 1   # recursion guard (self)
  [ -n "${REPHRASE_HOOK_ACTIVE:-}" ]    && return 1   # recursion guard (sibling hook)
  [ -z "${1// /}" ]                     && return 1   # empty / blank delta
  return 0
}

# Self-check (no claude call): asserts the gating decisions.
if [ "$SELFTEST" = 1 ]; then
  proceed ""        && { echo "FAIL empty";          exit 1; }
  proceed "   "     && { echo "FAIL blank";          exit 1; }
  ( export TRANSLATE_HOOK_ACTIVE=1; proceed "hi there" ) && { echo "FAIL self-guard";    exit 1; }
  ( export REPHRASE_HOOK_ACTIVE=1;  proceed "hi there" ) && { echo "FAIL sibling-guard"; exit 1; }
  ( export TRANSLATE_OUTPUT=0;      proceed "hi there" ) && { echo "FAIL killswitch";    exit 1; }
  proceed "Here is the plan." || { echo "FAIL go"; exit 1; }
  echo "selftest OK"; exit 0
fi

delta=$(cat | jq -r '.delta // empty')
proceed "$delta" || exit 0

instruction="Translate the following text to ${LANG_NAME}. Preserve all Markdown structure, code blocks, inline code, identifiers, file paths, URLs and numbers verbatim — translate only natural-language prose. Do not answer or add anything. Output ONLY the translation."

out=$(printf '%s\n\n---\n%s' "$instruction" "$delta" \
  | REPHRASE_HOOK_ACTIVE=1 TRANSLATE_HOOK_ACTIVE=1 claude -p --model "$MODEL" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' 2>/dev/null)  # no MCP

[ -z "${out// /}" ] && exit 0   # fail open → original English renders

jq -n --arg c "$out" \
  '{hookSpecificOutput:{hookEventName:"MessageDisplay",displayContent:$c}}'

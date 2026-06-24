#!/usr/bin/env bash
# UserPromptSubmit hook — rewrite the user's prompt into clear English and inject
# it as additionalContext (non-native-speaker aid). Reuses Claude Code auth via
# `claude -p` (no API key). Fails open: any error/empty rewrite => exit 0, no
# context, never blocks the prompt.
set -uo pipefail

# --- knobs ---------------------------------------------------------------
MODEL="claude-haiku-4-5-20251001"   # pinned; matches the rest of the setup
MIN_CHARS=60                        # ponytail: skip short prompts; tune freely
# -------------------------------------------------------------------------

should_rephrase() {                 # return 0 = rephrase, 1 = skip
  local p=$1
  [ -z "$p" ] && return 1
  case "$p" in /*|!*) return 1 ;; esac      # slash-command / bash passthrough
  [ "${#p}" -lt "$MIN_CHARS" ] && return 1  # short / confirmations
  return 0
}

# Self-check (no claude call): asserts the gating decisions.
if [ "${1:-}" = "--selftest" ]; then
  should_rephrase ""        && { echo "FAIL empty";  exit 1; }
  should_rephrase "/loop x" && { echo "FAIL slash";  exit 1; }
  should_rephrase "!ls"     && { echo "FAIL bang";   exit 1; }
  should_rephrase "yes go"  && { echo "FAIL short";  exit 1; }
  should_rephrase "Please refactor the auth middleware so token expiry is strict" \
                            || { echo "FAIL long";   exit 1; }
  echo "selftest OK"; exit 0
fi

# Recursion guard: nested `claude -p` inherits this var; its own copy of this
# hook sees it and exits immediately.
[ -n "${REPHRASE_HOOK_ACTIVE:-}" ] && exit 0

prompt=$(cat | jq -r '.prompt // empty')
should_rephrase "$prompt" || exit 0

instruction='Rewrite the following user message into clear, idiomatic, professional English. Preserve the exact technical intent and every identifier, path, and code snippet verbatim. Do not answer it and do not add anything. Output ONLY the rewrite.'

rewrite=$(printf '%s\n\n---\n%s' "$instruction" "$prompt" \
  | REPHRASE_HOOK_ACTIVE=1 claude -p --model "$MODEL" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' 2>/dev/null)  # no MCP

[ -z "${rewrite// /}" ] && exit 0   # fail open

ctx="The user is not a native English speaker. Below is their submitted prompt
rewritten in clear English with identical intent. Use it to interpret the
request; if it conflicts with the original, prefer the original wording.

$rewrite"

jq -n --arg c "$ctx" --arg r "$rewrite" \
  '{systemMessage:("✎ rephrased → " + $r),
    hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'

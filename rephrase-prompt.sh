#!/usr/bin/env bash
# Prompt hook for Claude Code (UserPromptSubmit), Codex (UserPromptSubmit) and
# Antigravity CLI `agy` (PreInvocation): rewrite the user's prompt into clear
# English and inject it as context (non-native-speaker aid). The rewrite runs on
# the lightest model of a provider CLI (claude, codex or agy), with that
# CLI's own auth (no API key). Fails open: any error/empty rewrite => exit 0,
# no context, never blocks the prompt.
#
# Usage: rephrase-prompt.sh [PROVIDER] [MODEL]
#   PROVIDER  claude | codex | agy. Default: the harness that runs the hook.
#   MODEL     override the provider's default light model.
set -uo pipefail

# --- knobs ---------------------------------------------------------------
PROVIDER="${1:-}"
MODEL="${2:-}"
MIN_CHARS=60                        # ponytail: skip short prompts; tune freely
# -------------------------------------------------------------------------

should_rephrase() {                 # return 0 = rephrase, 1 = skip
  local p=$1
  [ -z "$p" ] && return 1
  case "$p" in /*|!*) return 1 ;; esac      # slash-command / bash passthrough
  [ "${#p}" -lt "$MIN_CHARS" ] && return 1  # short / confirmations
  case "$p" in                              # pasted text, harness markup, unattended runs
    "<pasted_content"*|"UNATTENDED SESSION"*|"<command-"*|"<bash-"*) return 1 ;;
  esac
  return 0
}

hook_enabled() {                    # return 0 = run, 1 = off. Pure, reads the environment only.
  [ "${REPHRASE_PROMPT:-1}" = "0" ] && return 1   # kill switch
  [ -n "${CREW_SEAT:-}" ] && return 1             # a crew agent seat: crew writes its prompts, no human types
  return 0
}

default_model() {
  case "$1" in
    claude) echo haiku ;;        # tier alias, auto-tracks current Haiku
    codex)  echo gpt-6-luna ;;   # ponytail: Codex has no tier alias, bump when Luna is retired
    agy)    echo gemini-3.8-flash-low ;;  # ponytail: pinned, `agy models` lists the current ones
  esac
}

# Harness from the hook payload: agy sends hookEventName PreInvocation, Codex
# sends a turn_id, Claude Code neither.
detect_provider() {
  jq -r 'if .hookEventName == "PreInvocation" then "agy"
         elif has("turn_id") then "codex" else "claude" end' <<<"$1" 2>/dev/null
}

rewrite_with() {                    # $1 provider, $2 model, stdin = request
  case "$1" in
    claude) claude -p --model "$2" --strict-mcp-config --mcp-config '{"mcpServers":{}}' ;;
    codex)  codex exec --ignore-user-config --ephemeral --skip-git-repo-check \
              -s read-only -m "$2" -c model_reasoning_effort=low - ;;
    agy)    agy --model "$2" --disable-slash-commands -p "$(cat)" ;;  # prompt as the -p argument: agy then skips stdin
  esac
}

# Self-check (no model call): asserts the gating decisions.
if [ "${1:-}" = "--selftest" ]; then
  should_rephrase ""        && { echo "FAIL empty";  exit 1; }
  should_rephrase "/loop x" && { echo "FAIL slash";  exit 1; }
  should_rephrase "!ls"     && { echo "FAIL bang";   exit 1; }
  should_rephrase "yes go"  && { echo "FAIL short";  exit 1; }
  should_rephrase "Please refactor the auth middleware so token expiry is strict" \
                            || { echo "FAIL long";   exit 1; }
  should_rephrase "<pasted_content id=\"x\"> a long pasted block that is not the user's own words" \
                            && { echo "FAIL pasted"; exit 1; }
  should_rephrase "UNATTENDED SESSION: no human is watching this tab, run the queued item" \
                            && { echo "FAIL unattended"; exit 1; }
  [ "$(detect_provider '{"hookEventName":"PreInvocation","lastUserInput":"x"}')" = agy ] || { echo "FAIL detect agy"; exit 1; }
  [ "$(detect_provider '{"hook_event_name":"UserPromptSubmit","turn_id":"t","prompt":"x"}')" = codex ] || { echo "FAIL detect codex"; exit 1; }
  [ "$(detect_provider '{"hook_event_name":"UserPromptSubmit","prompt":"x"}')" = claude ] || { echo "FAIL detect claude"; exit 1; }
  ( unset CREW_SEAT REPHRASE_PROMPT; hook_enabled ) || { echo "FAIL enabled"; exit 1; }
  ( CREW_SEAT=build1 hook_enabled ) && { echo "FAIL crew seat"; exit 1; }
  ( REPHRASE_PROMPT=0 hook_enabled ) && { echo "FAIL kill switch"; exit 1; }
  echo "selftest OK"; exit 0
fi

# Recursion guard: the nested CLI call inherits this var; its own copy of this
# hook sees it and exits immediately.
[ -n "${REPHRASE_HOOK_ACTIVE:-}" ] && exit 0
hook_enabled || exit 0

payload=$(cat)
event=$(jq -r '.hook_event_name // .hookEventName // "UserPromptSubmit"' <<<"$payload" 2>/dev/null)
# agy fires PreInvocation before every model call of a turn: rewrite only on
# the first one (invocationNum 0), when the user's input is new.
[ "$event" = PreInvocation ] && [ "$(jq -r '.invocationNum // 0' <<<"$payload")" != 0 ] && exit 0
prompt=$(jq -r '.prompt // .lastUserInput // empty' <<<"$payload" 2>/dev/null)
should_rephrase "$prompt" || exit 0

PROVIDER="${PROVIDER:-$(detect_provider "$payload")}"
MODEL="${MODEL:-$(default_model "$PROVIDER")}"
[ -n "$MODEL" ] || exit 0           # unknown provider: fail open

instruction='Rewrite the following user message into clear, idiomatic, professional English. Preserve the exact technical intent and every identifier, path, and code snippet verbatim. Do not answer it and do not add anything. Output ONLY the rewrite.'

rewrite=$(printf '%s\n\n---\n%s' "$instruction" "$prompt" \
  | REPHRASE_HOOK_ACTIVE=1 rewrite_with "$PROVIDER" "$MODEL" 2>/dev/null)  # no MCP

[ -z "${rewrite// /}" ] && exit 0   # fail open

ctx="The user is not a native English speaker. Below is their submitted prompt
rewritten in clear English with identical intent. Use it to interpret the
request; if it conflicts with the original, prefer the original wording.

$rewrite"

if [ "$event" = PreInvocation ]; then     # agy contract: inject a system step
  jq -n --arg c "$ctx" '{injectSteps:[{systemMessage:{systemMessage:$c}}]}'
  exit 0
fi
jq -n --arg c "$ctx" --arg r "$rewrite" --arg e "$event" \
  '{systemMessage:("✎ rephrased → " + $r),
    hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'

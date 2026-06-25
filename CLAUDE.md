# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this repo is

Two standalone [Claude Code](https://docs.claude.com/en/docs/claude-code) hooks
for non-native English speakers, plus a copy-based installer. No build, no test
framework — just bash + `jq` + the authenticated `claude` CLI.

- **`rephrase-prompt.sh`** — `UserPromptSubmit` hook. Rewrites your prompt into
  idiomatic English and injects it as `additionalContext` (never answers it).
  Skips empty / slash-command / bash-passthrough / `<MIN_CHARS` prompts.
- **`translate-output.sh`** — `MessageDisplay` hook (**optional, opt-in**).
  Translates Claude's on-screen prose into your language (`$1`, default French)
  while the transcript/code/commits stay English. Display-only.
- **`install.sh`** — copies both into `~/.claude/hooks/` and registers them in
  `~/.claude/settings.json` (idempotent, backs up to `.bak`). The translation
  hook is gated behind an opt-in prompt.

## Design conventions (follow these)

These are deliberate and were chosen on purpose — preserve them:

- **Config via command args, not env vars.** Tunables that belong in
  `settings.json` are positional args on the hook command
  (`translate-output.sh French sonnet`), read as `${1:-default}` / `${2:-...}`.
  Env vars are only for runtime toggles (`TRANSLATE_OUTPUT=0` kill switch,
  `INSTALL_TRANSLATE=1` for non-interactive install).
- **No rigid model pins.** Default to the tier alias `haiku` (auto-tracks the
  current model), not a dated snapshot. Both hooks already do this.
- **Optional features are opt-in** in the installer, never forced on.
- **Fail open, always `exit 0`.** Any error / missing dep / empty result → the
  hook produces no output and never blocks or breaks the session.
- **Recursion guard.** Each hook's nested `claude -p` call exports
  `REPHRASE_HOOK_ACTIVE=1` / `TRANSLATE_HOOK_ACTIVE=1`; both hooks bail if either
  is set, so the sub-call can't re-trigger them.
- **No MCP in sub-calls:** `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`.

## Verify

No test suite. Each script self-tests its gating logic with **no `claude` call**:

```sh
./rephrase-prompt.sh --selftest    # → selftest OK
./translate-output.sh --selftest   # → selftest OK
```

For a real end-to-end check, pipe a hook-shaped JSON payload to the script
(`{"prompt":"..."}` or `{"delta":"...","final":true}`) — this spends a Haiku
call. Test the installer against a sandbox `HOME=$(mktemp -d)` so it never
touches the real `~/.claude/settings.json`.

## Gotchas

- `MessageDisplay` fires **per streamed batch** in the interactive terminal and
  blocks each batch on the hook — translation makes streaming chunkier/slower
  and costs tokens per reply. That's why it's off by default.
- Editing a hook script doesn't redeploy it — `install.sh` *copies* into
  `~/.claude/hooks/`. Re-run `./install.sh` (or edit the copy) after changes.
- Keep `rephrase-prompt.sh` unchanged when adding hooks — the new hook's guard
  already covers its subprocess.

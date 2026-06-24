# claude-rephrase-hook

A [Claude Code](https://docs.claude.com/en/docs/claude-code) `UserPromptSubmit`
hook that rewrites your prompt into clear, idiomatic English before Claude reads
it — a writing aid for non-native English speakers.

It does **not** answer your prompt or change what you asked for. It rewrites the
wording into clean English, preserving every identifier, path, and code snippet
verbatim, and injects that as extra context. Claude is told to prefer your
original wording if the two ever conflict.

```
you type:   "can u make the auth midleware to check token expiry strict pls"
Claude sees: "Please make the auth middleware enforce strict token-expiry checks."
```

## How it works

On each prompt, the hook decides whether to rewrite, then (if so) asks Claude
Haiku for a clean rewrite and injects it as `additionalContext`.

- **Skips** (passes through untouched): empty prompts, slash-commands (`/…`),
  bash passthrough (`!…`), and anything under **60 characters** (confirmations,
  short replies). Tunable via `MIN_CHARS` at the top of the script.
- **Model:** pinned to `claude-haiku-4-5-20251001` (`MODEL` knob at the top of
  the script — bump it when the model retires).
- **No API key:** reuses your Claude Code auth via `claude -p`.
- **No MCP:** the sub-call runs with MCP disabled for speed and privacy.
- **Recursion-guarded:** the nested `claude -p` call won't re-trigger the hook.
- **Fails open:** any error, missing dependency, or empty rewrite → the hook
  exits cleanly and your original prompt goes through unchanged. It can never
  block or break a prompt.

### Cost & latency

Every qualifying prompt (≥60 chars) spawns one background Haiku call before your
real prompt runs. That adds a small amount of latency and token spend per
prompt. Haiku is cheap and fast, but it is not free — raise `MIN_CHARS` or
remove the hook if you don't want it.

## Requirements

- `bash`
- [`jq`](https://jqlang.github.io/jq/)
- the [`claude`](https://docs.claude.com/en/docs/claude-code) CLI, installed and
  authenticated

## Install

```sh
git clone https://github.com/kalak-io/claude-rephrase-hook.git
cd claude-rephrase-hook
./install.sh
```

`install.sh` copies the hook to `~/.claude/hooks/rephrase-prompt.sh` and
registers it as a global `UserPromptSubmit` hook in `~/.claude/settings.json`
(backing up to `settings.json.bak` first). It's idempotent — re-running won't
create duplicate entries. New Claude Code sessions pick it up automatically.

### Manual install

If you'd rather not run the script: copy `rephrase-prompt.sh` somewhere on disk,
`chmod +x` it, and add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/rephrase-prompt.sh", "timeout": 60 }
        ]
      }
    ]
  }
}
```

## Verify

```sh
./rephrase-prompt.sh --selftest
# → selftest OK
```

This checks the gating logic (empty / slash / bang / short are skipped, a normal
sentence is rephrased) without making any `claude` call.

## Uninstall

Remove the `UserPromptSubmit` entry from `~/.claude/settings.json` and delete
`~/.claude/hooks/rephrase-prompt.sh`.

## License

MIT — see [LICENSE](LICENSE).

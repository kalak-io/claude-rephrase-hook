# claude-rephrase-hook

A prompt hook for [Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex) and the Antigravity CLI (`agy`) that
rewrites your prompt into clear, idiomatic English before the agent reads it. It is a writing
aid for non-native English speakers.

It does **not** answer your prompt or change what you asked for. It rewrites the
wording into clean English, preserving every identifier, path, and code snippet
verbatim, and injects that as extra context. Claude is told to prefer your
original wording if the two ever conflict.

```
you type:   "can u make the auth midleware to check token expiry strict pls"
Claude sees: "Please make the auth middleware enforce strict token-expiry checks."
```

## How it works

On each prompt, the hook decides whether to rewrite. If so, it asks the lightest
model of a provider CLI for a clean rewrite and injects it as
`additionalContext`. It runs as `UserPromptSubmit` in Claude Code and Codex, and
as `PreInvocation` in `agy`. `agy` fires
`PreInvocation` before every model call of a turn, so the hook rewrites only on
the first one (`invocationNum` 0) and injects the rewrite as a system step.

- **Skips** (passes through untouched): empty prompts, slash-commands (`/…`),
  bash passthrough (`!…`), and anything under **60 characters** (confirmations,
  short replies). Tunable via `MIN_CHARS` at the top of the script. It also
  skips pasted content (`<pasted_content`), Claude Code command and bash
  markup (`<command-`, `<bash-`) and prompts that start with
  `UNATTENDED SESSION` (automated runs).
- **Provider:** the first argument of the hook command, `claude`, `codex` or
  `agy`. Without it, the hook uses the CLI of the harness that runs it (`agy`
  sends `PreInvocation`, Codex sends a `turn_id`, else Claude Code).
- **Model:** the lightest model of the provider, overridable with a second
  argument (`rephrase-prompt.sh codex gpt-6-luna`):

  | Provider | Default model | Call |
  |---|---|---|
  | `claude` | `haiku` (tier alias) | `claude -p` |
  | `codex` | `gpt-6-luna` (pinned, no tier alias exists) | `codex exec --ignore-user-config` |
  | `agy` | `gemini-3.8-flash-low` (pinned, see `agy models`) | `agy -p` |
- **No API key:** each CLI uses its own login.
- **No MCP:** the sub-call runs with MCP disabled for speed and privacy.
- **Recursion-guarded:** the nested CLI call does not re-trigger the hook.
- **Fails open:** any error, missing dependency, or empty rewrite → the hook
  exits cleanly and your original prompt goes through unchanged. It can never
  block or break a prompt.

### Cost & latency

Every qualifying prompt (≥60 chars) spawns one CLI call before your real prompt
runs. A run measured on this repo took about 5 s with `claude`, 7.5 s with
`codex` and 9 s with `agy`. Raise `MIN_CHARS` or remove the hook if the delay is too long.

## Output translation (optional, Claude Code only)

The mirror image, for reading rather than writing. An optional `MessageDisplay`
hook (`translate-output.sh`) translates Claude's on-screen prose into your
language while **the interaction stays English**:

```
Claude writes (transcript, code, commits): "Here is the plan. Run `git status`."
you read on screen (French):                "Voici le plan. Exécutez `git status`."
```

- **Display-only.** It replaces only what's rendered in your terminal. The
  transcript, code, commit messages, and what Claude sees next turn keep the
  original English — `--verbose` shows the untranslated text.
- **Prose only.** Code blocks, inline code, identifiers, paths, URLs and numbers
  are preserved verbatim; only natural language is translated.
- **Language is a command arg.** Chosen at install (default French); it lives as
  the hook command in `~/.claude/settings.json` (`translate-output.sh French`).
  Change it by editing that arg or re-running `./install.sh`.
- **Model:** the `haiku` tier alias by default (no dated pin to retire);
  override with an optional 2nd arg (`translate-output.sh French sonnet`).
- **Recursion-guarded** and **fails open**, same as the rephrase hook — any
  error or timeout shows the original English.
- **Kill switch:** set `TRANSLATE_OUTPUT=0` to disable without uninstalling.

**Cost & latency — read this before enabling.** In the interactive terminal
`MessageDisplay` fires once per batch of completed lines *as the reply streams*,
and Claude Code holds each batch until the hook returns (10s timeout). So every
streamed batch incurs a Haiku round-trip before it renders — streaming feels
chunkier/slower and every reply spends translation tokens. Tool-call-only turns
don't trigger it. This is why it's **off by default**.

## Requirements

- `bash`
- [`jq`](https://jqlang.github.io/jq/)
- at least one of `claude`, `codex` or `agy`, installed and authenticated
  (no API key: each CLI uses its own login).
  Codex runs hooks only with `hooks = true` under `[features]` in
  `~/.codex/config.toml`.

## Install

```sh
git clone https://github.com/kalak-io/claude-rephrase-hook.git
cd claude-rephrase-hook
./install.sh
```

For each CLI on your PATH, `install.sh` copies the hook into its hooks directory
and registers it (backing up the file to `.bak` first):

| CLI | Hook file | Registered in | Event |
|---|---|---|---|
| `claude` | `~/.claude/hooks/rephrase-prompt.sh` | `~/.claude/settings.json` | `UserPromptSubmit` |
| `codex` | `~/.codex/hooks/rephrase-prompt.sh` | `~/.codex/hooks.json` | `UserPromptSubmit` |
| `agy` | `~/.gemini/config/hooks/rephrase-prompt.sh` | `~/.gemini/config/hooks.json` (key `rephrase-prompt`) | `PreInvocation` |

Each harness rewrites with its own CLI. To use one provider everywhere, run
`REPHRASE_PROVIDER=claude ./install.sh`. Re-running replaces the entry, it does
not duplicate it. Codex asks you to trust the new hook on its next start.

It then **asks** whether to also install the optional output-translation hook
(default No) and, if yes, which language. To install it non-interactively:
`INSTALL_TRANSLATE=1 TRANSLATE_LANG=French ./install.sh`.

### Manual install

If you'd rather not run the script: copy `rephrase-prompt.sh` somewhere on disk,
`chmod +x` it, and add this to `~/.claude/settings.json` (same shape in
`~/.codex/hooks.json`, see `install.sh` for the `agy` shape):

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
./rephrase-prompt.sh --selftest    # → selftest OK
./translate-output.sh --selftest   # → selftest OK (if you installed it)
```

This checks the gating logic (empty / slash / bang / short are skipped, a normal
sentence is rephrased, the provider is detected from each harness payload; for the translator: blank deltas, guards and the kill
switch skip) without making any model call.

## Uninstall

Remove the `rephrase-prompt.sh` entries from the files in the install table
(and, if present, the `MessageDisplay` entry in `~/.claude/settings.json`), then
delete the hook files.

## License

MIT — see [LICENSE](LICENSE).

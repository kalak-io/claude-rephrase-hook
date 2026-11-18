# prompt-rephraser

A prompt hook for coding agents that rewrites your prompt into clear, idiomatic
English before the agent reads it. It is a writing aid for people who are not
fluent in English, and it works in [Claude Code](https://docs.claude.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex) and the Antigravity CLI (`agy`).

The hook does not answer your prompt or change what you asked for. It rewrites
the wording, keeps every identifier, path and code snippet verbatim, and gives
the rewrite to the agent as extra context. The agent is told to prefer your
original wording if the two disagree.

```
you type:        "can u make the auth midleware to check token expiry strict pls"
the agent reads: "Please make the auth middleware enforce strict token-expiry checks."
```

The rewrite runs on the lightest model of an agent CLI that you already use.
Each CLI uses its own login, so you need no API key.

## Supported agents

| Agent | Hook event | Default rewrite model | Rewrite call |
|---|---|---|---|
| Claude Code | `UserPromptSubmit` | `haiku` (tier alias) | `claude -p` |
| Codex | `UserPromptSubmit` | `gpt-6-luna` (pinned, Codex has no tier alias) | `codex exec --ignore-user-config` |
| Antigravity CLI | `PreInvocation` | `gemini-3.8-flash-low` (pinned, see `agy models`) | `agy -p` |

`agy` fires `PreInvocation` before every model call of a turn. The hook rewrites
only on the first call (`invocationNum` 0) and injects the rewrite as a system
step.

## How it works

On each prompt, the hook decides whether to rewrite. If so, it asks a provider
CLI for a clean rewrite and injects the result into the agent's context.

- **Skips:** the hook passes these prompts through untouched:
  - Empty prompts, slash commands (`/…`) and bash passthrough (`!…`).
  - Prompts under 60 characters, such as confirmations. `MIN_CHARS` at the top
    of the script sets the limit.
  - Pasted content (`<pasted_content`), harness markup (`<command-`, `<bash-`)
    and unattended runs (`UNATTENDED SESSION`).
- **Language:** the hook rewrites every prompt over the limit, English ones too.
- **Provider:** the first argument of the hook command picks the CLI that
  rewrites: `claude`, `codex` or `agy`. Without it, the hook uses the CLI of the
  agent that runs it. It detects that agent from the payload: `agy` sends
  `PreInvocation`, Codex sends a `turn_id`, and Claude Code sends neither.
- **Model:** a second argument replaces the default model, for example
  `rephrase-prompt.sh codex gpt-6-luna`.
- **No MCP:** the rewrite call runs without MCP servers for `claude` and
  `codex`. `agy` has no flag for this, so its call loads your `agy` config.
- **Recursion guard:** the nested CLI call does not trigger the hook again.
- **Fails open:** if any step fails, the hook exits with no output and your
  prompt goes through unchanged. It never blocks a prompt.

### Cost and latency

Each prompt over the limit starts one CLI call before the agent runs. One
measured run took about 5 s with `claude`, 7.5 s with `codex` and 9 s with
`agy`. If the delay is too long, raise `MIN_CHARS` or remove the hook.

## Requirements

- `bash` and [`jq`](https://jqlang.github.io/jq/).
- At least one of `claude`, `codex` or `agy`, installed and logged in.
- For Codex, `hooks = true` under `[features]` in `~/.codex/config.toml`.

## Install

```sh
git clone https://github.com/kalak-io/prompt-rephraser.git
cd prompt-rephraser
./install.sh
```

For each CLI on your PATH, `install.sh` copies the hook into the hooks directory
of that CLI and registers it. It backs up each config file to `.bak` first:

| CLI | Hook file | Registered in |
|---|---|---|
| `claude` | `~/.claude/hooks/rephrase-prompt.sh` | `~/.claude/settings.json` |
| `codex` | `~/.codex/hooks/rephrase-prompt.sh` | `~/.codex/hooks.json` |
| `agy` | `~/.gemini/config/hooks/rephrase-prompt.sh` | `~/.gemini/config/hooks.json`, key `rephrase-prompt` |

Each agent rewrites with its own CLI by default. To use one provider for every
agent, run `REPHRASE_PROVIDER=claude ./install.sh`. If you run the installer
again, it replaces its own entry and keeps your other hooks. It also writes
through a symlinked config file. Codex asks you to trust the new hook on its
next start.

The script copies the hook. After you change `rephrase-prompt.sh`, run
`./install.sh` again.

### Manual install

Copy `rephrase-prompt.sh` to a folder, make it executable, and register it.
Claude Code and Codex use the same shape, in `~/.claude/settings.json` and
`~/.codex/hooks.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "/path/to/rephrase-prompt.sh claude", "timeout": 60 }
        ]
      }
    ]
  }
}
```

`agy` keys `~/.gemini/config/hooks.json` by hook name:

```json
{
  "rephrase-prompt": {
    "PreInvocation": [
      { "type": "command", "command": "/path/to/rephrase-prompt.sh agy", "timeout": 60 }
    ]
  }
}
```

## Output translation (optional, Claude Code only)

`translate-output.sh` does the reverse, for reading. It is a Claude Code
`MessageDisplay` hook that translates the agent's on-screen prose into your
language, while the conversation itself stays in English:

```
the agent writes (transcript, code, commits): "Here is the plan. Run `git status`."
you read on screen (French):                  "Voici le plan. Exécutez `git status`."
```

Codex and `agy` have no equivalent event, so this hook is for Claude Code only.

- **Display only:** the hook changes only what your terminal shows. The
  transcript, the code, the commit messages and the next turn keep the English
  text. `--verbose` shows the original.
- **Prose only:** code blocks, inline code, identifiers, paths, URLs and numbers
  stay verbatim.
- **Arguments:** the first argument is the language (default French), the
  second is the model (default `haiku`), for example
  `translate-output.sh French sonnet`.
- **Kill switch:** set `TRANSLATE_OUTPUT=0` to turn it off without uninstalling.
- Like the rephrase hook, it has a recursion guard and fails open.

Read this before you turn it on. `MessageDisplay` fires once per batch of lines
while the reply streams, and Claude Code waits for the hook before it shows each
batch (10 s timeout). Every batch therefore costs one model call, and streaming
feels slower. That is why the installer asks first, with No as the default. To
install it without the question, run
`INSTALL_TRANSLATE=1 TRANSLATE_LANG=French ./install.sh`.

## Verify

```sh
./rephrase-prompt.sh --selftest    # → selftest OK
./translate-output.sh --selftest   # → selftest OK
```

The self-tests check which prompts the hook skips and which agent it detects
from each payload. They make no model call.

## Uninstall

Remove the `rephrase-prompt.sh` entries from the files in the install table,
and the `MessageDisplay` entry in `~/.claude/settings.json` if you installed the
translation. Then delete the hook files.

## License

MIT, see [LICENSE](LICENSE).

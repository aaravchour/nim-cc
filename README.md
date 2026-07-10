# nim-cc — use Claude Code with NVIDIA NIM, toggled on/off

A tiny shell wrapper that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) through [NVIDIA NIM](https://build.nvidia.com) (OpenAI-compatible) via [claude-code-router](https://github.com/musistudio/claude-code-router), with a clean toggle back to normal Anthropic mode.

```
nim          # Claude Code on NVIDIA NIM   (NIM mode ON)
nim off      # Claude Code normally          (NIM mode OFF)
```

Claude Code speaks the **Anthropic** API format, but NVIDIA NIM speaks **OpenAI** format — so the two can't talk directly. `nim-cc` uses `claude-code-router` (`ccr`) as a local translation proxy and wires everything up for you: config, API key, gateway, and env vars.

- **Self-contained** — env vars are only set for the `claude` process it spawns; nothing is exported to your shell or persisted globally. `nim off` inherits your shell untouched, so it works whether your "normal" setup is Anthropic, Ollama, or anything else.
- **Non-destructive** — `nim init` backs up any existing `~/.claude-code-router/config.json`.
- **Key stays private** — stored in `~/.claude-code-router/nim.env` (chmod 600), referenced as `$NVIDIA_API_KEY` in the config.
- **Multiple providers** — NIM by default, but you can add OpenRouter, Groq, DeepSeek, OpenAI, or a local Ollama/LM Studio with `nim provider add` and switch between them with one command.
- **Self-diagnosis** — `nim doctor` checks the whole chain (ccr, config, key, gateway, live provider ping) and tells you exactly what to fix.

## Quick start

```bash
# 1. install the router (one time)  — must be the v1.x CLI, NOT the desktop app
npm install -g @musistudio/claude-code-router@1.0.73

# 2. install nim-cc
curl -fsSL https://raw.githubusercontent.com/aaravchour/nim-cc/main/install.sh | bash

# 3. set your NVIDIA API key (get one at https://build.nvidia.com → API Keys)
nim key

# 4. run
nim          # Claude Code on NIM
nim off      # Claude Code normally
nim doctor   # diagnose the whole chain anytime
```

`install.sh` copies `nim` to `~/.local/bin/nim` (on your `$PATH` if you use the standard setup). To install manually instead:

```bash
curl -fsSL -o ~/.local/bin/nim https://raw.githubusercontent.com/aaravchour/nim-cc/main/nim
chmod +x ~/.local/bin/nim
```

## Selecting models

The easy way to pick a model — no JSON editing:

```bash
nim models          # numbered menu of the models in your config → pick one → becomes default
nim models --all    # fetch the LIVE list of every model NVIDIA NIM offers → pick → set as default
nim use deepseek-ai/deepseek-r1     # set default directly (auto-adds it to your list)
nim add mistralai/mixtral-8x22b-instruct-v0.1   # add a model without changing the default
nim ls              # list configured models (* = current default)
```

- `nim models` and `nim models --all` use a numbered menu by default, and **auto-upgrade to [fzf](https://github.com/junegunn/fzf) fuzzy search** if you have it installed (great for the long `--all` list).
- `nim models --all` calls NVIDIA's live `/v1/models` endpoint with your key, so you only see models your account can actually use.
- Picking a model reloads the router immediately — the next `nim` session uses it.
- Inside a running Claude Code session you can also switch on the fly: `/model nvidia,deepseek-ai/deepseek-r1`.

> The model commands need `jq` (`brew install jq`). The rest of `nim` works without it.

## Commands

| Command | What it does |
|---|---|
| `nim` / `nim on` / `nim enable` | Run Claude Code routed through your active provider (forwards extra args to `claude`) |
| `nim off` | Run Claude Code with your normal setup — inherits your shell env untouched (works for Anthropic, Ollama, etc.) |
| `nim <args...>` | Same as `nim`, but forwards args to claude (e.g. `nim --resume`, `nim "fix this")` |
| `nim models` | Numbered menu of your models → set as default (uses fzf if installed) |
| `nim models --all` | Pick from the **live** list of every model the active provider offers → set as default |
| `nim use <model>` | Set default model directly (auto-adds it to your list) |
| `nim add <model>` | Add a model to your list without changing the default |
| `nim ls` | List configured models for the active provider (`*` = current default) |
| `nim provider` | List configured providers (active marked with `*`) |
| `nim provider add [name]` | Add a provider — presets: `nvidia openrouter groq deepseek openai ollama lmstudio` |
| `nim provider use <name>` | Switch the active provider |
| `nim provider rm <name>` | Remove a provider |
| `nim route` | Show how requests are routed (`default` / `background` / `think` / `longContext`) |
| `nim route set <kind> <model>` | Set a route, e.g. `nim route set think deepseek-ai/deepseek-v4-pro` |
| `nim key [KEYVAR]` | Set an API key (default: the active provider's key; stored in `~/.claude-code-router/nim.env`, chmod 600) |
| `nim doctor` | Diagnose the whole chain — ccr, config, key, gateway, and a live end-to-end ping |
| `nim status` | Show install state, active provider, key, default model, endpoint |
| `nim config` | Edit the router config in `$EDITOR`, then reloads the router |
| `nim restart` | Reload the router after editing config/key |
| `nim init` | (Re)write the default NIM config (backs up any existing one) |
| `nim update` | Update `nim` to the latest version from GitHub |
| `nim uninstall` | Remove the `nim` wrapper and its config files |
| `nim help` | Show help |

## Default routing

`nim init` writes `~/.claude-code-router/config.json`:

| Route | Model |
|---|---|
| `default` | `meta/llama-3.3-70b-instruct` |
| `background` | `meta/llama-3.1-70b-instruct` |
| `think` | `deepseek-ai/deepseek-v4-pro` |
| `longContext` (≥60k tokens) | `meta/llama-3.3-70b-instruct` |

All on `https://integrate.api.nvidia.com/v1/chat/completions`. Edit with `nim config`, or use `nim route set` / `nim use`. (Models are fetched from NVIDIA's live `/v1/models` list; NVIDIA retires/renames model IDs over time, so `nim models --all` always shows what your account can actually use.)

## Multiple providers

NIM is the default, but you can route Claude Code through any OpenAI-compatible endpoint. Presets are built in:

```bash
nim provider add openrouter     # add OpenRouter (prompts for endpoint/key/model)
nim key OPENROUTER_API_KEY       # set that provider's key
nim provider use openrouter      # switch the active provider
nim models --all                 # pick a model from OpenRouter's live list
```

Provider presets: `nvidia`, `openrouter`, `groq`, `deepseek`, `openai`, `ollama` (local), `lmstudio` (local). For a custom endpoint, `nim provider add` and type a name that isn't a preset — it'll prompt for the URL and key variable. Local providers (`ollama`, `lmstudio`) need no key.

`~/.claude-code-router/nim.env` can hold multiple keys (one per line, `KEYVAR=value`); `nim` exports all of them when it starts the gateway.

## Files

- `~/nim-cc` → installed to `~/.local/bin/nim`
- `~/.claude-code-router/config.json` — router config (providers + routes)
- `~/.claude-code-router/nim.env` — your API keys (chmod 600), one `KEYVAR=value` per line

## Self-hosted NIM

Pointed at NVIDIA's hosted cloud by default. For a self-hosted NIM deployment, run `nim config` and change `api_base_url` to your endpoint (e.g. `http://localhost:8000/v1/chat/completions`) and update the `models` list.

## Caveats

- **Tool use / agentic loops**: `ccr` translates Anthropic's tool format to OpenAI function-calling. Most NIM models support it, but smaller models can be less reliable than Claude for long agent sessions.
- **Install the npm v1.x CLI package**, not the CCR *desktop* app — the desktop app (v2/v3) uses a SQLite config and has no `ccr code`/`ccr activate`. Pin it: `npm install -g @musistudio/claude-code-router@1.0.73`. `nim doctor` and `nim status` detect a wrong version and tell you how to fix it.
- **The gateway only gets your key if it's started with the key in its environment.** `nim on` always `load_env`s your keys and `ccr restart`s before launching, so this is handled automatically. If you manually started `ccr` without the key, you'll see a `401` from the provider — run `nim restart` (or just `nim`, which restarts for you).
- **`~/.claude/settings.json` model pins** (e.g. `"model": "opus[1m]"`) are fine — `ccr` routes any requested Claude model name to your configured default, so the pin resolves to your NIM model transparently.
- **NVIDIA rate limits / transient 503** ("ResourceExhausted") apply on the NIM side regardless of your Claude plan; just retry.

## License

MIT — see [LICENSE](LICENSE).
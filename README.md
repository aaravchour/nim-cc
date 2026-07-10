# nim-cc — use Claude Code with NVIDIA NIM, toggled on/off

A tiny shell wrapper that runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) through [NVIDIA NIM](https://build.nvidia.com) (OpenAI-compatible) via [claude-code-router](https://github.com/musistudio/claude-code-router), with a clean toggle back to normal Anthropic mode.

```
nim          # Claude Code on NVIDIA NIM   (NIM mode ON)
nim off      # Claude Code normally          (NIM mode OFF)
```

Claude Code speaks the **Anthropic** API format, but NVIDIA NIM speaks **OpenAI** format — so the two can't talk directly. `nim-cc` uses `claude-code-router` (`ccr`) as a local translation proxy and wires everything up for you: config, API key, gateway, and env vars.

- **Self-contained** — env vars are only set for the `claude` process it spawns; nothing is exported to your shell or persisted globally.
- **Non-destructive** — `nim init` backs up any existing `~/.claude-code-router/config.json`.
- **Key stays private** — stored in `~/.claude-code-router/nim.env` (chmod 600), referenced as `$NVIDIA_API_KEY` in the config.

## Quick start

```bash
# 1. install the router (one time)
npm install -g @musistudio/claude-code-router

# 2. install nim-cc
curl -fsSL https://raw.githubusercontent.com/aaravchour/nim-cc/main/install.sh | bash

# 3. set your NVIDIA API key (get one at https://build.nvidia.com → API Keys)
nim key

# 4. run
nim          # Claude Code on NIM
nim off      # Claude Code normally
nim status   # check state anytime
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
| `nim` | Run Claude Code routed through NVIDIA NIM (forwards extra args to `claude`) |
| `nim off` | Run Claude Code direct to Anthropic — unsets router env so a global proxy can't leak in |
| `nim models` | Numbered menu of your models → set as default (uses fzf if installed) |
| `nim models --all` | Pick from the **live** list of every NIM model → set as default |
| `nim use <model>` | Set default model directly (auto-adds it to your list) |
| `nim add <model>` | Add a model to your list without changing the default |
| `nim ls` | List configured models (`*` = current default) |
| `nim key` | Set your `nvapi-...` key (stored in `~/.claude-code-router/nim.env`, chmod 600) |
| `nim config` | Edit the router config (models / routes) in `$EDITOR`, then reloads the router |
| `nim status` | Show install state, key, default model, endpoint |
| `nim restart` | Reload the router after editing config/key |
| `nim init` | (Re)write the default NIM config (backs up any existing one) |
| `nim help` | Show help |

## Default routing

`nim init` writes `~/.claude-code-router/config.json`:

| Route | Model |
|---|---|
| `default` | `nvidia/llama-3.1-nemotron-70b-instruct` |
| `background` | `meta/llama-3.3-70b-instruct` |
| `think` | `deepseek-ai/deepseek-r1` |
| `longContext` (≥60k tokens) | `deepseek-ai/deepseek-r1` |

All on `https://integrate.api.nvidia.com/v1/chat/completions`. Edit with `nim config`.

## Files

- `~/nim-cc` → installed to `~/.local/bin/nim`
- `~/.claude-code-router/config.json` — router config (NIM provider + routes)
- `~/.claude-code-router/nim.env` — your `NVIDIA_API_KEY` (chmod 600)

## Self-hosted NIM

Pointed at NVIDIA's hosted cloud by default. For a self-hosted NIM deployment, run `nim config` and change `api_base_url` to your endpoint (e.g. `http://localhost:8000/v1/chat/completions`) and update the `models` list.

## Caveats

- **Tool use / agentic loops**: `ccr` translates Anthropic's tool format to OpenAI function-calling. Most NIM models support it, but smaller models can be less reliable than Claude for long agent sessions.
- **Install the npm package**, not the CCR *desktop* app — the desktop app uses a SQLite config and different CLI; this script targets `@musistudio/claude-code-router` (the `ccr` CLI with `config.json`).
- **NVIDIA rate limits** apply on the NIM side regardless of your Claude plan.

## License

MIT — see [LICENSE](LICENSE).
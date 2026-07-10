#!/usr/bin/env bash
# nim — run Claude Code through NVIDIA NIM (OpenAI-compatible) via claude-code-router.
#
# Usage:
#   nim            Run Claude Code routed through NVIDIA NIM  (NIM mode ON)
#   nim off        Run Claude Code normally, direct to Anthropic  (NIM mode OFF)
#   nim <args...>  Same as `nim`, but forwards args to claude (e.g. nim --resume, nim "fix this")
#   nim key        Set your NVIDIA API key (nvapi-...)  — stored in ~/.claude-code-router/nim.env
#   nim config     Edit the router config (models / routes) in $EDITOR
#   nim models     Interactively pick a model (ccr model)
#   nim status     Show install state, key, default model, endpoint
#   nim restart    Reload the router after editing config/key
#   nim init       (Re)write the default NIM config (backs up any existing one)
#   nim help       Show this help
#
# Setup (one time):
#   1. npm install -g @musistudio/claude-code-router     # the `ccr` proxy
#   2. nim key                                            # paste your nvapi-... key
#   3. nim                                                # run Claude Code on NIM
#   Get a key at https://build.nvidia.com  (account → API Keys).

set -euo pipefail

CCR_DIR="${HOME}/.claude-code-router"
CONFIG="${CCR_DIR}/config.json"
ENV_FILE="${CCR_DIR}/nim.env"                       # holds NVIDIA_API_KEY (chmod 600)
NIM_BASE_URL="https://integrate.api.nvidia.com/v1/chat/completions"

# --- pretty output ---------------------------------------------------------
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36mℹ\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- config management ------------------------------------------------------
write_default_config() {
  mkdir -p "$CCR_DIR"
  if [[ -f "$CONFIG" ]]; then
    cp "$CONFIG" "${CONFIG}.bak.$(date +%s)" 2>/dev/null || true
    info "Backed up existing config to ${CONFIG}.bak.*"
  fi
  cat > "$CONFIG" <<JSON
{
  "LOG": true,
  "API_TIMEOUT_MS": 600000,
  "Providers": [
    {
      "name": "nvidia",
      "api_base_url": "${NIM_BASE_URL}",
      "api_key": "\$NVIDIA_API_KEY",
      "models": [
        "nvidia/llama-3.1-nemotron-70b-instruct",
        "meta/llama-3.3-70b-instruct",
        "deepseek-ai/deepseek-r1",
        "meta/llama-3.1-405b-instruct"
      ]
    }
  ],
  "Router": {
    "default":       "nvidia,nvidia/llama-3.1-nemotron-70b-instruct",
    "background":    "nvidia,meta/llama-3.3-70b-instruct",
    "think":         "nvidia,deepseek-ai/deepseek-r1",
    "longContext":   "nvidia,deepseek-ai/deepseek-r1",
    "longContextThreshold": 60000
  }
}
JSON
  ok "NIM config written to $CONFIG"
}

ensure_config() {
  if [[ ! -f "$CONFIG" ]]; then
    info "No router config found — writing default NIM config."
    write_default_config
  fi
}

# --- key / env --------------------------------------------------------------
ensure_key() {
  if [[ ! -f "$ENV_FILE" ]] || ! grep -q 'NVIDIA_API_KEY=.' "$ENV_FILE" 2>/dev/null; then
    err "NVIDIA API key not set. Run: nim key"
    return 1
  fi
}

load_env() {
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  export NVIDIA_API_KEY
}

# --- commands ---------------------------------------------------------------
cmd_on() {
  have ccr    || { err "claude-code-router not found. Install: npm install -g @musistudio/claude-code-router"; return 1; }
  have claude || { err "claude not found. Install Claude Code first."; return 1; }
  ensure_config
  ensure_key
  load_env
  ccr start >/dev/null 2>&1 || true          # start gateway if not running (idempotent)
  info "NIM mode ON — routing Claude Code through NVIDIA NIM"
  exec ccr code "$@"                          # ccr code sets ANTHROPIC_BASE_URL + launches claude
}

cmd_off() {
  have claude || { err "claude not found."; return 1; }
  info "NIM mode OFF — using Claude Code directly (Anthropic)"
  # unset any router env so a globally-configured proxy doesn't leak into "off" mode
  exec env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY claude "$@"
}

cmd_key() {
  mkdir -p "$CCR_DIR"
  printf 'Enter your NVIDIA API key (nvapi-...): '
  read -rs KEY
  echo
  [[ -n "$KEY" ]] || { err "No key entered."; return 1; }
  printf 'NVIDIA_API_KEY=%s\n' "$KEY" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Key saved to $ENV_FILE (chmod 600)"
  if have ccr; then
    load_env
    ccr restart >/dev/null 2>&1 && ok "Router reloaded with new key." || true
  fi
  info "Get a key at https://build.nvidia.com  (account → API Keys)"
}

cmd_config() {
  ensure_config
  "${EDITOR:-vi}" "$CONFIG"
  if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
}

cmd_models() {
  have ccr || { err "ccr not found."; return 1; }
  load_env
  ccr start >/dev/null 2>&1 || true
  ccr model
}

cmd_restart() {
  have ccr || { err "ccr not found."; return 1; }
  load_env
  ccr restart
  ok "Router reloaded."
}

cmd_status() {
  printf 'nim — NVIDIA NIM bridge for Claude Code\n\n'
  printf 'ccr installed:     '; have ccr    && ok 'yes' || err 'no  (npm install -g @musistudio/claude-code-router)'
  printf 'claude installed:  '; have claude && ok 'yes' || err 'no'
  printf 'config:            '; [[ -f "$CONFIG" ]]   && ok "$CONFIG" || err 'missing  (run: nim init)'
  printf 'api key:           '; [[ -f "$ENV_FILE" ]] && grep -q 'NVIDIA_API_KEY=.' "$ENV_FILE" 2>/dev/null && ok 'set' || err 'missing  (run: nim key)'
  if [[ -f "$CONFIG" ]]; then
    DEF=$(grep -o '"default"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" | head -1 | sed 's/.*:.*"\([^"]*\)"$/\1/')
    [[ -n "$DEF" ]] && printf 'default model:     %s\n' "$DEF"
  fi
  printf 'endpoint:          %s\n' "$NIM_BASE_URL"
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# --- dispatch ----------------------------------------------------------------
main() {
  case "${1:-}" in
    off)      shift; cmd_off "$@" ;;
    key)      cmd_key ;;
    config)   cmd_config ;;
    models)   cmd_models ;;
    status)   cmd_status ;;
    restart)  cmd_restart ;;
    init)     write_default_config ;;
    help|-h|--help) usage ;;
    *)        cmd_on "$@" ;;   # bare `nim` OR `nim <args>` → claude on NIM
  esac
}

main "$@"
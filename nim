#!/usr/bin/env bash
# nim — run Claude Code through NVIDIA NIM (OpenAI-compatible) via claude-code-router.
#
# Usage:
#   nim                 Run Claude Code routed through NVIDIA NIM  (NIM mode ON)
#   nim off             Run Claude Code normally, direct to Anthropic  (NIM mode OFF)
#   nim <args...>       Same as `nim`, but forwards args to claude (e.g. nim --resume, nim "fix this")
#   nim models          Pick a model from your config (numbered menu) → set as default
#   nim models --all    Pick from the LIVE list of every model NVIDIA NIM offers
#   nim use <model>     Set default model directly, e.g. nim use deepseek-ai/deepseek-r1
#   nim add <model>     Add a model to your list (without making it default)
#   nim ls              List configured models (* = current default)
#   nim key             Set your NVIDIA API key (nvapi-...)  — stored in ~/.claude-code-router/nim.env
#   nim config          Edit the router config (models / routes) in $EDITOR
#   nim status          Show install state, key, default model, endpoint
#   nim restart         Reload the router after editing config/key
#   nim init            (Re)write the default NIM config (backs up any existing one)
#   nim help            Show this help
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
NIM_MODELS_URL="https://integrate.api.nvidia.com/v1/models"

# --- pretty output ---------------------------------------------------------
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36mℹ\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
require_jq() { have jq || { err "jq is required for this. Install: brew install jq"; return 1; }; }

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

# --- model helpers ----------------------------------------------------------
current_default_model() {
  [[ -f "$CONFIG" ]] || return 0
  jq -r '.Router.default // ""' "$CONFIG" 2>/dev/null | sed 's/^nvidia,//'
}

set_default_model() {
  # $1 = model id (provider-prefixed, e.g. deepseek-ai/deepseek-r1)
  local model="$1"
  require_jq || return 1
  ensure_config
  jq --arg m "$model" '
      (.Providers[] | select(.name=="nvidia")).models |= ((. // []) | . + [$m] | unique)
    | .Router.default = "nvidia,\($m)"
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  ok "Default model set to: nvidia,$model"
  if have ccr; then load_env; ccr restart >/dev/null 2>&1 && ok "Router reloaded." || true; fi
}

# Interactive picker. Reads candidate model IDs from stdin, prints chosen one.
# Uses fzf if available (fuzzy search), else a numbered menu.
# $1 = current default id (for the "<- current" marker)
pick_model() {
  local current="${1:-}" items=() line
  while IFS= read -r line; do [[ -n "$line" ]] && items+=("$line"); done

  if (( ${#items[@]} == 0 )); then
    err "No models to show."; return 1
  fi

  if have fzf; then
    printf '%s\n' "${items[@]}" \
      | fzf --prompt="Select model (default) > " --reverse --height=40% --tac --no-sort
  else
    echo "Select a model to use as default:" >&2
    local i mark
    for i in "${!items[@]}"; do
      mark=""
      [[ "${items[$i]}" == "$current" ]] && mark="   <- current"
      printf '  [%d] %s%s\n' "$((i+1))" "${items[$i]}" "$mark" >&2
    done
    printf 'Enter number (or q to quit): ' >&2
    local n
    read -r n </dev/tty || true
    [[ "$n" == "q" || "$n" == "Q" ]] && return 0
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#items[@]} )); then
      printf '%s\n' "${items[$((n-1))]}"
    fi
  fi
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

cmd_models() {
  require_jq || return 1
  ensure_key || return 1
  load_env
  local all=0
  [[ "${1:-}" == "-a" || "${1:-}" == "--all" ]] && all=1

  local current; current=$(current_default_model)
  local chosen

  if (( all )); then
    info "Fetching live model list from NVIDIA NIM..."
    local resp
    resp=$(curl -fsS -H "Authorization: Bearer ${NVIDIA_API_KEY}" "${NIM_MODELS_URL}") \
      || { err "Failed to fetch models from NIM (check your key / network)."; return 1; }
    chosen=$(printf '%s\n' "$resp" \
      | jq -r '(.data // []) | .[].id // empty' 2>/dev/null | sort -u \
      | pick_model "$current") || { info "No change."; return 0; }
  else
    ensure_config
    chosen=$(jq -r '(.Providers[] | select(.name=="nvidia").models) // [] | .[]' "$CONFIG" 2>/dev/null \
      | pick_model "$current") || { info "No change."; return 0; }
  fi

  if [[ -z "$chosen" ]]; then
    info "No model selected; nothing changed."
    return 0
  fi
  set_default_model "$chosen"
}

cmd_use() {
  local model="${1:-}"
  [[ -n "$model" ]] || { err "Usage: nim use <model>   (e.g. nim use deepseek-ai/deepseek-r1)"; return 1; }
  require_jq || return 1
  load_env
  set_default_model "$model"
}

cmd_add() {
  local model="${1:-}"
  [[ -n "$model" ]] || { err "Usage: nim add <model>   (e.g. nim add mistralai/mixtral-8x22b-instruct-v0.1)"; return 1; }
  require_jq || return 1
  ensure_config
  jq --arg m "$model" \
    '(.Providers[] | select(.name=="nvidia")).models |= ((. // []) | . + [$m] | unique)' \
    "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  ok "Added model: $model"
  info "Make it default with: nim use \"$model\"  (or pick with: nim models)"
}

cmd_ls() {
  require_jq || return 1
  ensure_config
  local current; current=$(current_default_model)
  echo "Configured NIM models (* = current default):"
  local m
  while IFS= read -r m; do
    if [[ "$m" == "$current" ]]; then printf '  * %s\n' "$m"
    else printf '    %s\n' "$m"; fi
  done < <(jq -r '(.Providers[] | select(.name=="nvidia").models) // [] | .[]' "$CONFIG" 2>/dev/null)
  [[ -n "$current" ]] && printf '\nCurrent default: nvidia,%s\n' "$current"
}

cmd_key() {
  mkdir -p "$CCR_DIR"
  printf 'Enter your NVIDIA API key (nvapi-...): '
  local KEY
  read -rs KEY </dev/tty || read -rs KEY
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
  printf 'jq installed:      '; have jq     && ok 'yes' || err 'no  (brew install jq — needed for nim models/use/add/ls)'
  printf 'config:            '; [[ -f "$CONFIG" ]]   && ok "$CONFIG" || err 'missing  (run: nim init)'
  printf 'api key:           '; [[ -f "$ENV_FILE" ]] && grep -q 'NVIDIA_API_KEY=.' "$ENV_FILE" 2>/dev/null && ok 'set' || err 'missing  (run: nim key)'
  if [[ -f "$CONFIG" ]]; then
    local def; def=$(current_default_model)
    [[ -n "$def" ]] && printf 'default model:     nvidia,%s\n' "$def"
  fi
  printf 'endpoint:          %s\n' "$NIM_BASE_URL"
  printf 'live models:       %s\n' "$NIM_MODELS_URL"
}

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

# --- dispatch ----------------------------------------------------------------
main() {
  case "${1:-}" in
    off)        shift; cmd_off "$@" ;;
    models)     shift; cmd_models "$@" ;;
    use)        shift; cmd_use "$@" ;;
    add)        shift; cmd_add "$@" ;;
    ls|list)    cmd_ls ;;
    key)        cmd_key ;;
    config)     cmd_config ;;
    status)     cmd_status ;;
    restart)    cmd_restart ;;
    init)       write_default_config ;;
    help|-h|--help) usage ;;
    *)          cmd_on "$@" ;;   # bare `nim` OR `nim <args>` → claude on NIM
  esac
}

main "$@"
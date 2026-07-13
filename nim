#!/usr/bin/env bash
# nim — run Claude Code through NVIDIA NIM (or any OpenAI-compatible API) via claude-code-router.
#
# Usage:
#   nim                 Run Claude Code routed through your active provider  (ON)
#   nim off             Run Claude Code with your normal setup, not nim  (OFF)
#   nim <args...>       Same as `nim`, forwards args to claude (e.g. nim --resume, nim "fix this")
#   nim on | enable     Same as bare `nim` (explicit ON)
#
#   nim models          Pick a model from your active provider (numbered menu) → default
#   nim models --all    Pick from the LIVE list of models the active provider offers → default
#   nim use <model>     Set default model directly, e.g. nim use deepseek-ai/deepseek-v4-pro
#   nim add <model>     Add a model to your list (without making it default)
#   nim ls              List configured models for the active provider (* = current default)
#
#   nim provider        List configured providers (active marked with *)
#   nim provider add    Add a provider (name + endpoint + key, guided)
#   nim provider use <name>     Switch the active provider (keeps first model if present)
#   nim provider rm <name>      Remove a provider
#   nim route           Show how requests are routed (default / background / think / longContext)
#   nim route set <kind> <model>   e.g. nim route set think deepseek-ai/deepseek-v4-pro
#
#   nim ping           Ping the active default model directly (bypasses ccr) — catches a broken model
#   nim doctor          Diagnose the whole chain (ccr, config, key, gateway, provider, live ping)
#   nim status          Show install state, active provider, key, default model, endpoint
#   nim key [KEYVAR]    Set an API key (default: active provider's key, stored in nim.env, chmod 600)
#   nim config          Edit the router config in $EDITOR, then reloads the router
#   nim restart         Reload the router (after editing config/key)
#   nim init            (Re)write the default NIM config (backs up any existing one)
#   nim update          Update nim to the latest version on GitHub
#   nim uninstall        Remove the nim wrapper and config files (keeps nothing)
#   nim help            Show this help
#
# Setup (one time):
#   1. npm install -g @musistudio/claude-code-router     # the `ccr` proxy (needs v1.x CLI)
#   2. nim key                                            # paste your nvapi-... key
#   3. nim                                                # run Claude Code on NIM
#   Get a key at https://build.nvidia.com  (account → API Keys).

set -euo pipefail

CCR_DIR="${HOME}/.claude-code-router"
CONFIG="${CCR_DIR}/config.json"
ENV_FILE="${CCR_DIR}/nim.env"                       # holds provider API keys (chmod 600)

# --- pretty output ---------------------------------------------------------
err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36mℹ\033[0m %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
require_jq() { have jq || { err "jq is required for this. Install: brew install jq"; return 1; }; }

ccr_major_version() {
  # The v1.x CLI has no --version flag (it prints usage), but supports `ccr activate`.
  # The desktop/v2/v3 editions print a semver and lack `ccr activate`.
  have ccr || { echo 0; return; }
  if ccr activate 2>/dev/null | grep -q 'ANTHROPIC_BASE_URL'; then
    echo 1
  else
    ccr --version 2>/dev/null | grep -Eo '[0-9]+' | head -1 || echo 0
  fi
}
require_ccr_1x() {
  have ccr || { err "claude-code-router not found. Install: npm install -g @musistudio/claude-code-router"; return 1; }
  local v; v=$(ccr_major_version)
  if [[ "$v" != 1 ]]; then
    err "ccr is v${v:-?} (desktop/SQLite edition) — this script needs the v1.x CLI."
    err "Fix: npm install -g @musistudio/claude-code-router@1.0.73"
    return 1
  fi
}

# --- provider presets ------------------------------------------------------
# returns "url|keyvar|label" or fails
provider_preset() {
  case "$1" in
    nvidia)     printf 'https://integrate.api.nvidia.com/v1/chat/completions|NVIDIA_API_KEY|NVIDIA NIM' ;;
    openrouter) printf 'https://openrouter.ai/api/v1/chat/completions|OPENROUTER_API_KEY|OpenRouter' ;;
    groq)       printf 'https://api.groq.com/openai/v1/chat/completions|GROQ_API_KEY|Groq' ;;
    deepseek)   printf 'https://api.deepseek.com/chat/completions|DEEPSEEK_API_KEY|DeepSeek' ;;
    openai)     printf 'https://api.openai.com/v1/chat/completions|OPENAI_API_KEY|OpenAI' ;;
    ollama)     printf 'http://localhost:11434/v1/chat/completions|-|Ollama (local)' ;;
    lmstudio)   printf 'http://localhost:1234/v1/chat/completions|-|LM Studio (local)' ;;
    *) return 1 ;;
  esac
}

# --- config management ------------------------------------------------------
ensure_plugins() {
  local plugin_dir="${CCR_DIR}/plugins"
  mkdir -p "$plugin_dir"
  cat > "${plugin_dir}/strip-reasoning.js" <<'JS'
class StripReasoning {
  name = "strip-reasoning";
  async transformRequestIn(e) {
    if (e && typeof e === 'object') {
      delete e.reasoning;
      delete e.disable_reasoning;
    }
    return e;
  }
  async transformResponseOut(e) {
    return e;
  }
}

module.exports = StripReasoning;
JS
}

migrate_config() {
  require_jq || return 0
  [[ -f "$CONFIG" ]] || return 0
  ensure_plugins
  local plugin_path="${CCR_DIR}/plugins/strip-reasoning.js"
  jq --arg path "$plugin_path" '
    .transformers = (
      (.transformers // [])
      | if any(.path == $path) then . else . + [{"path": $path}] end
    )
    | .Providers |= map(
        if .name == "nvidia" then
          .transformer = (
            (.transformer // {})
            | .use = (
                (.use // [])
                | if index("strip-reasoning") then . else . + ["strip-reasoning"] end
              )
          )
        else . end
      )
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

write_default_config() {
  mkdir -p "$CCR_DIR"
  ensure_plugins
  if [[ -f "$CONFIG" ]]; then
    cp "$CONFIG" "${CONFIG}.bak.$(date +%s)" 2>/dev/null || true
    info "Backed up existing config to ${CONFIG}.bak.*"
  fi
  cat > "$CONFIG" <<JSON
{
  "LOG": true,
  "API_TIMEOUT_MS": 600000,
  "transformers": [
    {
      "path": "${CCR_DIR}/plugins/strip-reasoning.js"
    }
  ],
  "Providers": [
    {
      "name": "nvidia",
      "api_base_url": "https://integrate.api.nvidia.com/v1/chat/completions",
      "api_key": "\$NVIDIA_API_KEY",
      "models": [
        "deepseek-ai/deepseek-v4-pro",
        "deepseek-ai/deepseek-v4-flash",
        "google/gemma-4-31b-it",
        "meta/llama-3.3-70b-instruct",
        "meta/llama-3.1-70b-instruct"
      ],
      "transformer": {
        "use": [
          "strip-reasoning"
        ]
      }
    }
  ],
  "Router": {
    "default":            "nvidia,deepseek-ai/deepseek-v4-pro",
    "background":         "nvidia,meta/llama-3.1-70b-instruct",
    "think":              "nvidia,deepseek-ai/deepseek-v4-pro",
    "longContext":        "nvidia,deepseek-ai/deepseek-v4-pro",
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
  else
    migrate_config
  fi
}

# --- key / env --------------------------------------------------------------
# $1 = keyvar (e.g. NVIDIA_API_KEY); prints value from nim.env, or empty
key_for_keyvar() {
  local kv="${1:-}"
  [[ -n "$kv" && "$kv" != "null" && "$kv" != "-" ]] || return 0
  grep -o "^${kv}=.*" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

# exports ALL keys defined in nim.env into this process env (so ccr gateway can use them)
load_env() {
  [[ -f "$ENV_FILE" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# --- active provider helpers ------------------------------------------------
active_provider()  { [[ -f "$CONFIG" ]] && jq -r '.Router.default // ""' "$CONFIG" 2>/dev/null | cut -d, -f1 || true; }
active_provider_url() {
  local n; n=$(active_provider)
  [[ -n "$n" ]] && jq -r --arg n "$n" '.Providers[]|select(.name==$n)|.api_base_url // ""' "$CONFIG" 2>/dev/null || true
}
active_provider_keyvar() {
  local n; n=$(active_provider)
  [[ -n "$n" ]] && jq -r --arg n "$n" '.Providers[]|select(.name==$n)|.api_key // ""' "$CONFIG" 2>/dev/null | sed 's#^\$##' || true
}
active_needs_key() {
  local kv; kv=$(active_provider_keyvar)
  [[ -n "$kv" && "$kv" != "null" && "$kv" != "-" ]]
}
ensure_active_key() {
  if active_needs_key; then
    local kv; kv=$(active_provider_keyvar)
    if [[ -z "$(key_for_keyvar "$kv")" ]]; then
      err "Key '$kv' (for active provider) is not set. Run: nim key $kv"
      return 1
    fi
  fi
}

# --- model helpers ----------------------------------------------------------
current_default_model() {
  [[ -f "$CONFIG" ]] || return 0
  jq -r '.Router.default // ""' "$CONFIG" 2>/dev/null | sed 's#^[^,]*,##'
}

# set default route to provider,model ; adds model to that provider's list
set_default_model() {
  local provider="$1" model="$2"
  require_jq || return 1
  ensure_config
  jq --arg p "$provider" --arg m "$model" '
      (.Providers[] | select(.name==$p)).models |= ((. // []) | . + [$m] | unique)
    | .Router.default = ($p + "," + $m)
    | .Router.think = ($p + "," + $m)
    | .Router.longContext = ($p + "," + $m)
  ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  ok "Default model set to: $provider,$model"
  if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
}

# Ping a provider's model directly (bypasses ccr) with a tiny completion request.
# Args: provider model. Prints a one-line classification. Returns: 0 healthy,
# 2 transient (429/503), 1 broken (empty 200 / 401 / 403 / 404 / timeout / other).
# Catches a flaky default model BEFORE it surfaces as cryptic ccr 500s mid-task.
ping_model() {
  local provider="${1:-}" model="${2:-}" keep=0
  [[ -n "$provider" && -n "$model" ]] || return 1
  local url kv key content code rc=1
  url=$(jq -r --arg n "$provider" '.Providers[]|select(.name==$n)|.api_base_url // ""' "$CONFIG" 2>/dev/null)
  [[ -n "$url" ]] || { printf 'no endpoint configured for %s\n' "$provider"; return 1; }

  local -a auth=()
  kv=$(jq -r --arg n "$provider" '.Providers[]|select(.name==$n)|.api_key // ""' "$CONFIG" 2>/dev/null | sed 's#^\$##')
  if [[ -n "$kv" && "$kv" != "null" && "$kv" != "-" ]]; then
    key=$(key_for_keyvar "$kv")
    [[ -n "$key" ]] || { printf "key '%s' not set (run: nim key %s)\n" "$kv" "$kv"; return 1; }
    auth=(-H "Authorization: Bearer $key")
  fi

  local body; body=$(mktemp -t nim_ping.XXXXXX 2>/dev/null || printf '/tmp/nim_ping.%s' "$$")
  code=$(curl -sS -m 30 -o "$body" -w "%{http_code}" \
    "${auth[@]}" -H "Content-Type: application/json" \
    "$url" -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":5,\"stream\":false}" 2>/dev/null) || code=000

  case "$code" in
    000) printf 'timeout / unreachable (endpoint %s)\n' "$url" ;;
    200)
      content=$(jq -r '.choices[0].message.content // empty' "$body" 2>/dev/null || true)
      if [[ -n "$content" && "$content" != "null" ]]; then
        rc=0; printf 'ok — model replied\n'
      else
        printf 'empty response (HTTP 200 but no completion content) — model is likely broken. Switch: nim use <other-model> | nim models --all\n'
      fi ;;
    429) rc=2; printf 'HTTP 429 rate-limited (transient — model works but throttled now)\n' ;;
    503) rc=2; printf 'HTTP 503 provider capacity (transient)\n' ;;
    401) printf 'HTTP 401 unauthorized — bad/missing key (run: nim key %s)\n' "$kv" ;;
    403) printf 'HTTP 403 forbidden — key lacks access to %s,%s\n' "$provider" "$model" ;;
    404) printf "HTTP 404 — model '%s' not found on '%s'. Switch: nim models --all\n" "$model" "$provider" ;;
    *)   keep=1; printf 'HTTP %s — unexpected (body kept at %s)\n' "$code" "$body"; rc=2 ;;
  esac
  [[ "$keep" -eq 1 ]] || rm -f "$body" 2>/dev/null
  return "$rc"
}

# Interactive picker. Reads candidate model IDs from stdin, prints chosen one.
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
  require_ccr_1x || return 1
  have claude || { err "claude not found. Install Claude Code first."; return 1; }
  ensure_config
  ensure_active_key || return 1
  load_env                                 # export keys into THIS process (gateway inherits them)
  ccr restart >/dev/null 2>&1 || ccr start >/dev/null 2>&1 || true   # restart so gateway has fresh keys
  # ccr activate forces ANTHROPIC_BASE_URL -> :3456, overriding any inherited setup (e.g. Ollama)
  eval "$(ccr activate)"
  # drop Claude Code tier->model overrides (e.g. glm-5.2:cloud) so ccr routes by its Router config
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
  info "NIM mode ON — Claude Code → ccr (:3456) → $(active_provider) [$(current_default_model)]"
  exec claude "$@"
}

cmd_off() {
  have claude || { err "claude not found."; return 1; }
  info "NIM mode OFF — using your normal Claude Code setup"
  # inherit shell env unchanged: for you that's Ollama; for others, real Anthropic. nim sets no globals.
  exec claude "$@"
}

cmd_models() {
  require_jq || return 1
  ensure_active_key || return 1
  load_env
  local all=0
  [[ "${1:-}" == "-a" || "${1:-}" == "--all" ]] && all=1

  local provider; provider=$(active_provider)
  [[ -n "$provider" ]] || { err "No active provider in config. Run: nim init"; return 1; }
  local current; current=$(current_default_model)
  local chosen url kv key

  if (( all )); then
    url=$(active_provider_url)
    if active_needs_key; then kv=$(active_provider_keyvar); key=$(key_for_keyvar "$kv"); fi
    info "Fetching live model list from ${url}..."
    local resp auth=()
    [[ -n "${key:-}" ]] && auth=(-H "Authorization: Bearer ${key}")
    resp=$(curl -fsS "${auth[@]}" "${url%/chat/completions}/models" 2>/dev/null) \
      || { err "Failed to fetch models (check key / network / endpoint)."; return 1; }
    chosen=$(printf '%s\n' "$resp" \
      | jq -r '(.data // []) | .[].id // empty' 2>/dev/null | sort -u \
      | pick_model "$current") || { info "No change."; return 0; }
  else
    ensure_config
    chosen=$(jq -r --arg p "$provider" '(.Providers[]|select(.name==$p).models) // [] | .[]' "$CONFIG" 2>/dev/null \
      | pick_model "$current") || { info "No change."; return 0; }
  fi

  if [[ -z "$chosen" ]]; then
    info "No model selected; nothing changed."
    return 0
  fi
  set_default_model "$provider" "$chosen"
}

cmd_use() {
  local model="${1:-}"
  [[ -n "$model" ]] || { err "Usage: nim use <model>   (e.g. nim use deepseek-ai/deepseek-v4-pro)"; return 1; }
  require_jq || return 1
  local provider; provider=$(active_provider)
  [[ -n "$provider" ]] || { err "No active provider. Run: nim init"; return 1; }
  load_env
  set_default_model "$provider" "$model"
}

cmd_add() {
  local model="${1:-}"
  [[ -n "$model" ]] || { err "Usage: nim add <model>   (e.g. nim add mistralai/mixtral-8x22b-instruct-v0.1)"; return 1; }
  require_jq || return 1
  ensure_config
  local provider; provider=$(active_provider)
  [[ -n "$provider" ]] || { err "No active provider. Run: nim init"; return 1; }
  jq --arg p "$provider" --arg m "$model" \
    '(.Providers[]|select(.name==$p)).models |= ((. // []) | . + [$m] | unique)' \
    "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  ok "Added model: $model  (provider: $provider)"
  info "Make it default with: nim use \"$model\"  (or pick with: nim models)"
}

cmd_ls() {
  require_jq || return 1
  ensure_config
  local provider; provider=$(active_provider)
  [[ -n "$provider" ]] || { err "No active provider."; return 1; }
  local current; current=$(current_default_model)
  echo "Configured models for provider '$provider' (* = current default):"
  local m
  while IFS= read -r m; do
    if [[ "$m" == "$current" ]]; then printf '  * %s\n' "$m"
    else printf '    %s\n' "$m"; fi
  done < <(jq -r --arg p "$provider" '(.Providers[]|select(.name==$p).models) // [] | .[]' "$CONFIG" 2>/dev/null)
  [[ -n "$current" ]] && printf '\nCurrent default: %s,%s\n' "$provider" "$current"
}

cmd_provider() {
  require_jq || return 1
  ensure_config
  local sub="${1:-}"
  case "$sub" in
    "")
      local active; active=$(active_provider)
      echo "Configured providers (* = active):"
      local n url kv
      while IFS=$'\t' read -r n url kv; do
        local mark=""
        [[ "$n" == "$active" ]] && mark="*"
        printf '  %s %-12s  %s  key:%s\n' "$mark" "$n" "$url" "${kv:--}"
      done < <(jq -r '.Providers[] | [.name, .api_base_url, (.api_key // "-")] | @tsv' "$CONFIG" 2>/dev/null)
      echo
      info "active: ${active}  model: $(current_default_model)"
      echo "Add: nim provider add | Switch: nim provider use <name> | Remove: nim provider rm <name>"
      ;;
    add)
      shift
      local name="${1:-}"
      if [[ -z "$name" ]]; then
        echo "Provider presets:" >&2
        echo "  nvidia openrouter groq deepseek openai ollama lmstudio" >&2
        printf 'Provider name (preset or custom): ' >&2
        read -r name </dev/tty || true
      fi
      [[ -n "$name" ]] || { err "No provider name given."; return 1; }
      local preset url kv label
      if preset=$(provider_preset "$name"); then
        url=$(printf '%s' "$preset" | cut -d'|' -f1)
        kv=$(printf '%s' "$preset" | cut -d'|' -f2)
        label=$(printf '%s' "$preset" | cut -d'|' -f3)
        info "Using preset: $label"
      else
        printf 'Endpoint URL (OpenAI-compatible, chat/completions): ' >&2
        read -r url </dev/tty || true
        printf 'Key env var name (e.g. MYAPI_KEY), or - for none: ' >&2
        read -r kv </dev/tty || true
        [[ -z "$kv" ]] && kv="-"
      fi
      local keyval="\$${kv}"
      [[ "$kv" == "-" ]] && keyval="-"
      local model=""
      printf 'First model id for this provider (or blank to skip): ' >&2
      read -r model </dev/tty || true
      local models='[]'
      [[ -n "$model" ]] && models=$(printf '%s' "$model" | jq -R . | jq -s .)
      jq --arg n "$name" --arg u "$url" --argjson m "$models" \
        --arg k "$keyval" \
        '.Providers += [{"name":$n,"api_base_url":$u,"api_key":$k,"models":$m}]' \
        "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
      ok "Provider '$name' added."
      if [[ "$kv" != "-" ]]; then
        if [[ -z "$(key_for_keyvar "$kv")" ]]; then
          info "Set its key now: nim key $kv"
        fi
      fi
      info "Activate with: nim provider use $name"
      if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
      ;;
    use)
      shift
      local name="${1:-}"
      [[ -n "$name" ]] || { err "Usage: nim provider use <name>"; return 1; }
      local exists
      exists=$(jq -r --arg n "$name" '.Providers[]|select(.name==$n)|.name // empty' "$CONFIG" 2>/dev/null)
      [[ -n "$exists" ]] || { err "No provider named '$name'. Run: nim provider add"; return 1; }
      local model
      model=$(jq -r --arg n "$name" '(.Providers[]|select(.name==$n).models) // [] | .[0] // empty' "$CONFIG" 2>/dev/null)
      if [[ -z "$model" ]]; then
        jq --arg n "$name" '.Router.default = ($n + ",")' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        ok "Active provider set to: $name  (no model yet — set one with: nim use <model>)"
        if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
      else
        set_default_model "$name" "$model"
        ok "Active provider set to: $name  (default model: $model)"
      fi
      ;;
    rm)
      shift
      local name="${1:-}"
      [[ -n "$name" ]] || { err "Usage: nim provider rm <name>"; return 1; }
      [[ "$name" == "nvidia" ]] && { err "Won't remove the built-in 'nvidia' provider."; return 1; }
      jq --arg n "$name" '.Providers |= map(select(.name != $n))' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
      local active; active=$(active_provider)
      if [[ "$active" == "$name" ]]; then
        local new; new=$(jq -r '.Providers[0].name // empty' "$CONFIG" 2>/dev/null)
        if [[ -n "$new" ]]; then
          local m0; m0=$(jq -r '.Providers[0].models[0] // empty' "$CONFIG" 2>/dev/null)
          [[ -n "$m0" ]] && set_default_model "$new" "$m0" || jq '.Router.default = "'"$new"',"' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        fi
      fi
      ok "Removed provider '$name'."
      if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
      ;;
    *) err "Unknown provider subcommand: '$sub'. Try: add | use <name> | rm <name>"; return 1 ;;
  esac
}

cmd_route() {
  require_jq || return 1
  ensure_config
  local sub="${1:-}"
  case "$sub" in
    "")
      echo "Routing table:"
      local k v
      while IFS=$'\t' read -r k v; do
        printf '  %-16s %s\n' "$k" "$v"
      done < <(jq -r '.Router | to_entries[] | [.key, (.value|tostring)] | @tsv' "$CONFIG" 2>/dev/null)
      echo
      info "Set with: nim route set <default|background|think|longContext> <model>"
      ;;
    set)
      shift
      local kind="${1:-}" model="${2:-}"
      [[ -n "$kind" && -n "$model" ]] || { err "Usage: nim route set <kind> <model>  (e.g. nim route set think deepseek-ai/deepseek-v4-pro)"; return 1; }
      case "$kind" in
        default|background|think|longContext|longContextThreshold) ;;
        *) err "Unknown route kind '$kind'. Use: default|background|think|longContext|longContextThreshold"; return 1 ;;
      esac
      local provider; provider=$(active_provider)
      if [[ "$kind" == "longContextThreshold" ]]; then
        [[ "$model" =~ ^[0-9]+$ ]] || { err "longContextThreshold must be a number (tokens)."; return 1; }
        jq --arg t "$model" '.Router.longContextThreshold = ($t|tonumber)' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        ok "longContextThreshold set to $model"
      else
        jq --arg k "$kind" --arg v "${provider},${model}" '.Router[$k] = $v' \
          "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
        ok "$kind route set to ${provider},${model}"
      fi
      if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
      ;;
    *) err "Usage: nim route  |  nim route set <kind> <model>"; return 1 ;;
  esac
}

cmd_ping() {
  require_jq || return 1
  ensure_config
  load_env
  local provider model
  provider=$(active_provider)
  model=$(current_default_model)
  [[ -n "$provider" && -n "$model" ]] || { err "No active default model set. Run: nim use <model>"; return 1; }
  info "Pinging $provider,$model directly (bypasses ccr)..."
  local rc=0 msg
  msg=$(ping_model "$provider" "$model") || rc=$?
  case "$rc" in
    0) ok "$provider,$model: $msg" ;;
    2) info "$provider,$model: $msg" ;;
    *) err "$provider,$model: $msg"; return 1 ;;
  esac
}

cmd_doctor() {
  require_jq || return 1
  echo "=== nim doctor ==="
  local pass=0 fail=0
  have ccr    && { ok "ccr installed";         pass=$((pass+1)); } || { err "ccr missing (npm install -g @musistudio/claude-code-router)"; fail=$((fail+1)); }
  have claude && { ok "claude installed";      pass=$((pass+1)); } || { err "claude missing"; fail=$((fail+1)); }
  have jq     && { ok "jq installed";          pass=$((pass+1)); } || { err "jq missing (brew install jq)"; fail=$((fail+1)); }
  [[ -f "$CONFIG" ]] && { ok "config present ($CONFIG)"; pass=$((pass+1)); } || { err "config missing (run: nim init)"; fail=$((fail+1)); }

  if [[ -f "$CONFIG" ]]; then
    [[ -f "${CCR_DIR}/plugins/strip-reasoning.js" ]] \
      && { ok "strip-reasoning plugin present"; pass=$((pass+1)); } \
      || { err "strip-reasoning plugin missing (run: nim restart)"; fail=$((fail+1)); }

    local v; v=$(ccr_major_version)
    if [[ "$v" == 1 ]]; then ok "ccr is v1.x CLI (compatible)"; pass=$((pass+1));
    else err "ccr is v${v:-?} (needs v1.x CLI: npm install -g @musistudio/claude-code-router@1.0.73)"; fail=$((fail+1)); fi

    local provider; provider=$(active_provider)
    local def; def=$(jq -r '.Router.default // ""' "$CONFIG" 2>/dev/null)
    if [[ -n "$provider" && -n "$def" && "$def" == *,* ]]; then ok "active provider: $provider  default: $(current_default_model)"; pass=$((pass+1));
    else err "Router.default not set properly ('$def'). Run: nim use <model>"; fail=$((fail+1)); fi

    if active_needs_key; then
      local kv; kv=$(active_provider_keyvar)
      if [[ -n "$(key_for_keyvar "$kv")" ]]; then ok "provider key '$kv' is set in nim.env"; pass=$((pass+1));
      else err "provider key '$kv' not set (run: nim key $kv)"; fail=$((fail+1)); fi
    else
      ok "active provider needs no key"; pass=$((pass+1));
    fi

    # Direct provider ping of the active default model (bypasses ccr).
    # Catches a broken/flaky default model (empty 200, 404, 401) before it
    # surfaces as cryptic ccr 500s mid-task — e.g. a model returning {}.
    local dmodel; dmodel=$(current_default_model)
    if [[ -n "$provider" && -n "$dmodel" ]]; then
      load_env
      local pmsg prc
      info "pinging default model $provider,$dmodel directly (bypasses ccr)..."
      prc=0; pmsg=$(ping_model "$provider" "$dmodel") || prc=$?
      case "$prc" in
        0) ok "default model $provider,$dmodel: $pmsg"; pass=$((pass+1)) ;;
        2) info "default model $provider,$dmodel: $pmsg" ;;
        *) err "$provider,$dmodel: $pmsg"; fail=$((fail+1)) ;;
      esac
    fi
  fi

  if have ccr && [[ -f "$CONFIG" ]]; then
    info "restarting gateway with current keys loaded (matches a real 'nim' run)..."
    load_env
    ccr restart >/dev/null 2>&1 || true
    sleep 1
    local code
    code=$(curl -s -m 40 -o /tmp/nim_doctor.json -w "%{http_code}" -X POST http://127.0.0.1:3456/v1/messages \
      -H "Content-Type: application/json" -H "x-api-key: test" -H "anthropic-version: 2023-06-01" \
      -d '{"model":"claude-opus-4-8[1m]","max_tokens":5,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null) || code=000
    case "$code" in
      200) ok "end-to-end gateway -> provider: HTTP 200 ✓"; pass=$((pass+1)); rm -f /tmp/nim_doctor.json ;;
      429|503) info "reached provider but got HTTP $code (transient provider capacity — retry later)"; rm -f /tmp/nim_doctor.json ;;
      401) err "end-to-end HTTP 401 from provider — gateway lacks the key. Run: nim key, then nim restart"; fail=$((fail+1)); rm -f /tmp/nim_doctor.json ;;
      404) err "end-to-end HTTP 404 — model not available for your account. Switch: nim models --all"; fail=$((fail+1)); rm -f /tmp/nim_doctor.json ;;
      000) err "no response from gateway on :3456 (is ccr running? run: nim restart) — or the upstream provider timed out (run: nim ping)"; fail=$((fail+1)); ;;
      500) err "end-to-end HTTP 500 — provider returned an empty/bad response (flaky model?). Run: nim ping"; fail=$((fail+1)); rm -f /tmp/nim_doctor.json ;;
      *)    err "end-to-end HTTP $code — see /tmp/nim_doctor.json"; fail=$((fail+1)); rm -f /tmp/nim_doctor.json ;;
    esac
  fi

  echo
  echo "Result: ${pass} ok, ${fail} problem(s)"
  [[ "$fail" -eq 0 ]] && ok "All checks passed — 'nim' should work." || { err "Fix the above, then: nim doctor"; return 1; }
}

cmd_key() {
  mkdir -p "$CCR_DIR"
  local kv="${1:-}"
  if [[ -z "$kv" ]]; then
    kv=$(active_provider_keyvar 2>/dev/null)
    [[ -z "$kv" || "$kv" == "null" || "$kv" == "-" ]] && kv="NVIDIA_API_KEY"
  fi
  local label
  label=$(active_provider 2>/dev/null) || label="provider"
  printf 'API key for %s (stored as %s in %s): ' "$label" "$kv" "$ENV_FILE"
  local KEY
  read -rs KEY </dev/tty || read -rs KEY
  echo
  [[ -n "$KEY" ]] || { err "No key entered."; return 1; }
  if grep -q "^${kv}=" "$ENV_FILE" 2>/dev/null; then
    { grep -v "^${kv}=" "$ENV_FILE" 2>/dev/null; printf '%s=%s\n' "$kv" "$KEY"; } > "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$kv" "$KEY" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  ok "Saved $kv in $ENV_FILE (chmod 600)"
  if have ccr; then load_env; ccr restart >/dev/null 2>&1 && ok "Router reloaded with new key." || true; fi
  info "Get a key at https://build.nvidia.com  (account → API Keys)"
}

cmd_config() {
  ensure_config
  "${EDITOR:-vi}" "$CONFIG"
  if have ccr; then load_env; ccr restart >/dev/null 2>&1 || true; fi
}

cmd_restart() {
  require_ccr_1x || return 1
  load_env
  ccr restart
  ok "Router reloaded."
}

cmd_status() {
  printf 'nim — bridge for Claude Code → OpenAI-compatible providers (default: NVIDIA NIM)\n\n'
  printf 'ccr installed:     '; have ccr    && ok 'yes' || err 'no  (npm install -g @musistudio/claude-code-router@1.0.73)'
  printf 'ccr version:       '; have ccr    && echo "    v$(ccr_major_version).x" || echo '    —'
  printf 'claude installed:  '; have claude && ok 'yes' || err 'no'
  printf 'jq installed:       '; have jq    && ok 'yes' || err 'no  (brew install jq — needed for model/provider/route/doctor)'
  printf 'config:            '; [[ -f "$CONFIG" ]] && ok "$CONFIG" || err 'missing  (run: nim init)'
  if [[ -f "$CONFIG" ]]; then
    local p; p=$(active_provider)
    [[ -n "$p" ]] && printf 'active provider:   %s\n' "$p"
    printf 'endpoint:          %s\n' "$(active_provider_url)"
    if active_needs_key; then
      local kv; kv=$(active_provider_keyvar)
      printf 'api key (%s):   ' "$kv"
      [[ -n "$(key_for_keyvar "$kv")" ]] && ok 'set' || err 'missing  (run: nim key)'
    fi
    local def; def=$(current_default_model)
    [[ -n "$def" ]] && printf 'default model:     %s,%s\n' "$p" "$def"
  fi
}

cmd_update() {
  local url="https://raw.githubusercontent.com/aaravchour/nim-cc/main/nim"
  local dest="$0"
  have curl || { err "curl required."; return 1; }
  info "Updating $dest from $url ..."
  curl -fsSL "$url" -o "${dest}.new" || { err "Download failed."; return 1; }
  head -1 "${dest}.new" | grep -q '^#!/' || { err "Downloaded file does not look like a script."; rm -f "${dest}.new"; return 1; }
  mv "${dest}.new" "$dest"
  chmod +x "$dest"
  ok "Updated. Run: nim help"
}

cmd_uninstall() {
  info "This will remove:"
  printf '  %s\n' "$0"
  printf '  %s\n' "$CONFIG"
  printf '  %s\n' "$ENV_FILE"
  printf 'Remove them? [y/N] '
  local yn; read -r yn </dev/tty || true
  [[ "$yn" == "y" || "$yn" == "Y" ]] || { info "Aborted."; return 0; }
  rm -f "$0" "$CONFIG" "$ENV_FILE" 2>/dev/null
  rmdir "$CCR_DIR" 2>/dev/null || true
  if have ccr; then ccr stop >/dev/null 2>&1 || true; info "ccr still installed (npm uninstall -g @musistudio/claude-code-router to remove)."; fi
  ok "nim uninstalled."
}

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 && !/^#/ {exit}' "$0"
}

# --- dispatch ----------------------------------------------------------------
main() {
  case "${1:-}" in
    on|enable)        shift; cmd_on "$@" ;;
    off)             shift; cmd_off "$@" ;;
    models)          shift; cmd_models "$@" ;;
    use)             shift; cmd_use "$@" ;;
    add)             shift; cmd_add "$@" ;;
    ls|list)         cmd_ls ;;
    provider)        shift; cmd_provider "$@" ;;
    route)           shift; cmd_route "$@" ;;
    ping)            shift; cmd_ping "$@" ;;
    doctor)          shift; cmd_doctor "$@" ;;
    key)             shift; cmd_key "$@" ;;
    config)          cmd_config ;;
    status)          cmd_status ;;
    restart)         shift; cmd_restart "$@" ;;
    init)            write_default_config ;;
    update)          cmd_update ;;
    uninstall)       cmd_uninstall ;;
    help|-h|--help)  usage ;;
    *)               cmd_on "$@" ;;   # bare `nim` OR `nim <args>` → claude on NIM
  esac
}

main "$@"
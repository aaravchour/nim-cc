#!/usr/bin/env bash
# install.sh — install nim-cc (the `nim` wrapper for Claude Code + NVIDIA NIM)
# Installs `nim` to ~/.local/bin/nim. Safe to re-run.
set -euo pipefail

DEST_DIR="${HOME}/.local/bin"
DEST="${DEST_DIR}/nim"
SRC_URL="https://raw.githubusercontent.com/aaravchour/nim-cc/main/nim"

err()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
info() { printf '\033[36mℹ\033[0m %s\n' "$*"; }

# allow installing from a local clone instead of downloading
if [[ -f "$(dirname "$0")/nim" ]] && ! [[ "$0" == *curl* ]]; then
  mkdir -p "$DEST_DIR"
  cp "$(dirname "$0")/nim" "$DEST"
else
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is required to download nim."; exit 1
  fi
  mkdir -p "$DEST_DIR"
  info "Downloading nim -> $DEST"
  curl -fsSL -o "$DEST" "$SRC_URL" || { err "Download failed."; exit 1; }
fi
chmod +x "$DEST"
ok "Installed nim -> $DEST"

# make sure DEST_DIR is on PATH
case ":${PATH}:" in
  *":${DEST_DIR}:"*) : ;;  # already on PATH
  *)
    info "$DEST_DIR is not on your PATH."
    info "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
    printf '    export PATH="%s:$PATH"\n' "$DEST_DIR"
    info "Then restart your terminal (or: source ~/.zshrc)."
    ;;
esac

cat <<EOF

Next steps:
  1. Install the router (one time):  npm install -g @musistudio/claude-code-router
  2. Set your NVIDIA key:            nim key   (get one at https://build.nvidia.com)
  3. Run:                            nim

EOF
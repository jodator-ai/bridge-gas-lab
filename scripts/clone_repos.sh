#!/usr/bin/env bash
# clone_repos.sh — clone all required public repositories
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOS_DIR="$ROOT/repos"
mkdir -p "$REPOS_DIR"

log() { echo "[clone_repos] $*"; }

clone_or_update() {
  local url="$1"
  local dir="$2"
  local depth="${3:-1}"

  if [ -d "$dir/.git" ]; then
    log "Already cloned: $dir — skipping"
  else
    log "Cloning $url -> $dir (depth=$depth)..."
    git clone --depth="$depth" "$url" "$dir"
    log "Done: $dir"
  fi
}

log "=== Cloning public repositories ==="

# Required
clone_or_update \
  "https://github.com/matter-labs/zksync-os-server" \
  "$REPOS_DIR/zksync-os-server"

clone_or_update \
  "https://github.com/matter-labs/zksync-contracts" \
  "$REPOS_DIR/zksync-contracts"

# foundry-zksync — only clone if install_deps.sh hasn't done it yet
clone_or_update \
  "https://github.com/matter-labs/foundry-zksync" \
  "$REPOS_DIR/foundry-zksync"

# Optional reference only
clone_or_update \
  "https://github.com/matter-labs/zksync-js" \
  "$REPOS_DIR/zksync-js"

log "=== Clone complete ==="
log ""
log "Repository layout:"
ls -1 "$REPOS_DIR"

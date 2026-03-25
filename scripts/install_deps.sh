#!/usr/bin/env bash
# install_deps.sh — install all tooling required by the lab
# Assumes: Linux x86_64, bash, curl, apt-get or equivalent
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$ROOT/results/raw/install_deps.log"
mkdir -p "$ROOT/results/raw"

log() { echo "[install_deps] $*" | tee -a "$LOG"; }

log "=== Lab dependency installer ==="
log "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Rust ──────────────────────────────────────────────────────────────────────
if command -v cargo &>/dev/null; then
  log "Rust already installed: $(rustc --version)"
else
  log "Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
  log "Rust installed: $(rustc --version)"
fi

# ── jq ────────────────────────────────────────────────────────────────────────
if command -v jq &>/dev/null; then
  log "jq already installed: $(jq --version)"
else
  log "Installing jq..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
  elif command -v brew &>/dev/null; then
    brew install jq
  else
    log "ERROR: cannot install jq — no known package manager found"
    exit 1
  fi
  log "jq installed: $(jq --version)"
fi

# ── git ───────────────────────────────────────────────────────────────────────
if command -v git &>/dev/null; then
  log "git already installed: $(git --version)"
else
  log "Installing git..."
  sudo apt-get update -qq && sudo apt-get install -y -qq git
fi

# ── foundry-zksync ────────────────────────────────────────────────────────────
if command -v cast &>/dev/null && cast --version 2>&1 | grep -q 'zksync\|ZkSync\|forge'; then
  log "foundry-zksync already installed: $(cast --version)"
elif command -v cast &>/dev/null; then
  log "WARNING: cast found but may not be foundry-zksync build: $(cast --version)"
  log "Proceeding — re-install via foundry-zksync if ZKsync features are missing"
else
  log "Installing foundry-zksync..."
  FOUNDRY_ZKSYNC_DIR="$ROOT/repos/foundry-zksync"
  if [ -d "$FOUNDRY_ZKSYNC_DIR" ]; then
    log "foundry-zksync repo already cloned at $FOUNDRY_ZKSYNC_DIR"
  else
    git clone --depth=1 https://github.com/matter-labs/foundry-zksync "$FOUNDRY_ZKSYNC_DIR"
  fi

  # Try the installer script first
  if [ -f "$FOUNDRY_ZKSYNC_DIR/install-foundry-zksync" ]; then
    log "Running foundry-zksync installer script..."
    bash "$FOUNDRY_ZKSYNC_DIR/install-foundry-zksync"
  else
    log "Building foundry-zksync from source (this may take several minutes)..."
    cd "$FOUNDRY_ZKSYNC_DIR"
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env" 2>/dev/null || true
    cargo build --release --bin forge --bin cast --bin anvil 2>&1 | tail -5
    BIN_DIR="$FOUNDRY_ZKSYNC_DIR/target/release"
    if [ -f "$BIN_DIR/cast" ]; then
      log "Linking binaries to ~/.local/bin"
      mkdir -p "$HOME/.local/bin"
      ln -sf "$BIN_DIR/cast" "$HOME/.local/bin/cast"
      ln -sf "$BIN_DIR/forge" "$HOME/.local/bin/forge"
      ln -sf "$BIN_DIR/anvil" "$HOME/.local/bin/anvil"
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi
  log "foundry-zksync installed: $(cast --version 2>/dev/null || echo 'check PATH')"
fi

# ── bc (for arithmetic in scripts) ────────────────────────────────────────────
if ! command -v bc &>/dev/null; then
  log "Installing bc..."
  sudo apt-get update -qq && sudo apt-get install -y -qq bc 2>/dev/null || true
fi

# ── python3 (for ceiling math) ────────────────────────────────────────────────
if command -v python3 &>/dev/null; then
  log "python3 available: $(python3 --version)"
fi

log "=== Dependency installation complete ==="
log ""
log "PATH additions needed (add to ~/.bashrc if not already present):"
log "  export PATH=\"\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH\""

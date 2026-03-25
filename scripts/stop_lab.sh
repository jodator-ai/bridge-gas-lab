#!/usr/bin/env bash
# stop_lab.sh — stop Anvil and zksync-os-server
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDS_DIR="$ROOT/.pids"

log() { echo "[stop_lab] $*"; }

kill_pid_file() {
  local pidfile="$1"
  local name="$2"
  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping $name (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        log "Force-killing $name..."
        kill -9 "$pid" 2>/dev/null || true
      fi
    else
      log "$name (PID $pid) already stopped"
    fi
    rm -f "$pidfile"
  fi
}

kill_pid_file "$PIDS_DIR/anvil.pid" "Anvil"
kill_pid_file "$PIDS_DIR/l2server.pid" "zksync-os-server"

# Also kill any stray anvil/zksync processes on the lab ports
for port in 8545 3050; do
  pid=$(lsof -ti :"$port" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    log "Killing stray process on port $port (PID $pid)..."
    kill -9 "$pid" 2>/dev/null || true
  fi
done

log "Lab stopped."

#!/bin/bash
#===============================================================================
# launch-with-secrets.sh — Wrapper that injects secrets via 1Password CLI
#
# Usage (from LaunchAgent plist):
#   /path/to/launch-with-secrets.sh <command> [args...]
#
# Behavior:
#   1. Tries: op run --env-file ~/.openclaw/.op-env -- "$@"
#   2. Falls back to: source ~/.openclaw/.env && exec "$@"
#===============================================================================

set -u
set -o pipefail

OP_ENV_FILE="${HOME}/.openclaw/.op-env"
FALLBACK_ENV_FILE="${HOME}/.openclaw/.env"
LOG_FILE="${HOME}/.openclaw/logs/launch-with-secrets.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null
}

# Attempt 1: 1Password CLI injection
if command -v op &>/dev/null && [ -f "$OP_ENV_FILE" ]; then
  log "Attempting 1Password secret injection via op run"
  exec op run --env-file="$OP_ENV_FILE" -- "$@"
  # exec replaces the process; if we get here, op failed
  log "op run exec failed (exit $?), falling through to .env fallback"
fi

# Attempt 2: Direct .env file sourcing
if [ -f "$FALLBACK_ENV_FILE" ]; then
  log "Falling back to direct .env sourcing from $FALLBACK_ENV_FILE"
  set -a
  # shellcheck source=/dev/null
  source "$FALLBACK_ENV_FILE"
  set +a
  exec "$@"
fi

# Neither method available
log "ERROR: No secret injection method available. Tried:"
log "  1. op run --env-file=$OP_ENV_FILE"
log "  2. source $FALLBACK_ENV_FILE"
log "Launching without secrets (will likely fail)..."
exec "$@"

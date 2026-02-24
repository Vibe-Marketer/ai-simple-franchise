#!/bin/bash
#===============================================================================
# OpenClaw AI Employee — Franchise Installer v1.1.0
# Complete 20-step Mac setup for the full OpenClaw AI employee stack.
#
# Usage:
#   ./install.sh <client-name>
#   ./install.sh <client-name> --dry-run
#   ./install.sh <client-name> --secrets-file ~/secrets.txt
#
# Examples:
#   ./install.sh acme-corp
#   ./install.sh test-vm --dry-run
#
# Supports: Apple Silicon (arm64) + Intel (x86_64)
# Idempotent: safe to run multiple times.
#===============================================================================

set -u
set -o pipefail

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------
VERSION="1.1.0"
ARCH="$(uname -m)"
DATE="$(date +%Y-%m-%d)"
INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.openclaw/logs"
LOG_FILE="$LOG_DIR/install-${DATE}.log"
DRY_RUN=false
SKIP_DOCKER=false
CLIENT_NAME="default"
SECRETS_FILE=""
TOTAL_STEPS=20
CURRENT_STEP=0
FAILURES=()
SKIPPED=()
SUCCESSES=()

# API keys (populated from secrets file or interactive prompts)
ANTHROPIC_API_KEY=""
OPENROUTER_API_KEY=""
COMPOSIO_API_KEY=""

# Paths
OPENCLAW_DIR="$HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
NODE_TARGET="24.13.0"
NODE_MAJOR="24"
NEO4J_PASSWORD="openclaw-graph-2026"

# Colors
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  B='\033[0;34m'  C='\033[0;36m'  NC='\033[0m'

#-------------------------------------------------------------------------------
# Parse args
#-------------------------------------------------------------------------------
# First arg (non-flag) is the client name
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)          DRY_RUN=true; shift ;;
    --skip-docker)      SKIP_DOCKER=true; shift ;;
    --secrets-file)
      if [ -z "${2:-}" ]; then echo "Error: --secrets-file requires a path"; exit 1; fi
      SECRETS_FILE="$2"; shift 2 ;;
    --client-name)
      # Legacy flag — still works
      if [ -z "${2:-}" ]; then echo "Error: --client-name requires a value"; exit 1; fi
      CLIENT_NAME="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 <client-name> [--dry-run] [--skip-docker] [--secrets-file FILE]"
      echo ""
      echo "Examples:"
      echo "  $0 acme-corp                         # Full install"
      echo "  $0 test-vm --dry-run                  # Preview only"
      echo "  $0 acme-corp --secrets-file keys.txt  # Keys from file"
      exit 0 ;;
    -*)
      echo "Unknown option: $1"
      echo "Usage: $0 <client-name> [--dry-run] [--skip-docker]"
      exit 1 ;;
    *)
      # Positional arg = client name
      CLIENT_NAME="$1"; shift ;;
  esac
done

# Client name is required (unless dry-run with default)
if [ "$CLIENT_NAME" = "default" ] && ! $DRY_RUN; then
  echo ""
  echo "Usage: $0 <client-name>"
  echo ""
  echo "  Example: $0 acme-corp"
  echo ""
  exit 1
fi

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${C}  [$CURRENT_STEP/$TOTAL_STEPS]${NC} $1"
  echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  log "STEP $CURRENT_STEP/$TOTAL_STEPS: $1"
}

ok()   { echo -e "  ${G}✓${NC} $1"; log "OK: $1"; SUCCESSES+=("$1"); }
fail() { echo -e "  ${R}✗${NC} $1"; log "FAIL: $1"; FAILURES+=("$1"); }
warn() { echo -e "  ${Y}⚠${NC} $1"; log "WARN: $1"; }
skip() { echo -e "  ${Y}⚠${NC} $1 (skipped — already installed)"; log "SKIP: $1"; SKIPPED+=("$1"); }
dry()  { echo -e "  ${Y}[DRY-RUN]${NC} Would: $1"; log "DRY: $1"; }
info() { echo -e "  ${C}→${NC} $1"; log "INFO: $1"; }

cmd_exists() { command -v "$1" &>/dev/null; }
app_installed() { [ -d "/Applications/$1.app" ] || [ -d "$HOME/Applications/$1.app" ]; }

brew_path() {
  if [ "$ARCH" = "arm64" ]; then echo "/opt/homebrew/bin/brew"
  else echo "/usr/local/bin/brew"; fi
}

ensure_brew_in_path() {
  local bp; bp="$(brew_path)"
  if [ -f "$bp" ] && ! cmd_exists brew; then
    eval "$("$bp" shellenv)"
  fi
}

install_brew_pkg() {
  local pkg="$1" label="$2"
  if brew list "$pkg" &>/dev/null 2>&1; then
    skip "$label"
    return 0
  fi
  if $DRY_RUN; then dry "brew install $pkg"; SUCCESSES+=("$label (dry)"); return 0; fi
  if brew install "$pkg" >> "$LOG_FILE" 2>&1; then
    ok "$label"
  else
    fail "$label (brew install $pkg)"
  fi
}

install_npm_global() {
  local pkg="$1" label="$2" cmd="${3:-$1}"
  if cmd_exists "$cmd"; then
    skip "$label"
    return 0
  fi
  if $DRY_RUN; then dry "npm install -g $pkg"; SUCCESSES+=("$label (dry)"); return 0; fi
  if npm install -g "$pkg" >> "$LOG_FILE" 2>&1; then
    ok "$label"
  else
    fail "$label (npm install -g $pkg)"
  fi
}

# Template processor: replace {{PLACEHOLDER}} tokens via sed
process_template() {
  local src="$1" dest="$2"
  if [ ! -f "$src" ]; then
    fail "Template not found: $src"
    return 1
  fi
  local content
  content="$(cat "$src")"
  content="$(echo "$content" | sed \
    -e "s|{{CLIENT_NAME}}|${CLIENT_NAME}|g" \
    -e "s|{{HOME}}|${HOME}|g" \
    -e "s|{{OPENCLAW_DIR}}|${OPENCLAW_DIR}|g" \
    -e "s|{{WORKSPACE_DIR}}|${WORKSPACE_DIR}|g" \
    -e "s|{{ANTHROPIC_API_KEY}}|${ANTHROPIC_API_KEY}|g" \
    -e "s|{{OPENROUTER_API_KEY}}|${OPENROUTER_API_KEY}|g" \
    -e "s|{{COMPOSIO_API_KEY}}|${COMPOSIO_API_KEY}|g" \
    -e "s|{{NEO4J_PASSWORD}}|${NEO4J_PASSWORD}|g" \
    -e "s|{{DATE}}|${DATE}|g" \
    -e "s|{{NODE_TARGET}}|${NODE_TARGET}|g" \
  )"
  echo "$content" > "$dest"
}

#-------------------------------------------------------------------------------
# Load secrets
#-------------------------------------------------------------------------------
load_secrets() {
  if [ -n "$SECRETS_FILE" ]; then
    if [ ! -f "$SECRETS_FILE" ]; then
      echo -e "${R}Error: secrets file not found: ${SECRETS_FILE}${NC}"
      exit 1
    fi
    log "Loading secrets from $SECRETS_FILE"
    while IFS='=' read -r key value; do
      # Skip blank lines and comments
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      # Trim whitespace
      key="$(echo "$key" | xargs)"
      value="$(echo "$value" | xargs)"
      case "$key" in
        ANTHROPIC_API_KEY)  ANTHROPIC_API_KEY="$value" ;;
        OPENROUTER_API_KEY) OPENROUTER_API_KEY="$value" ;;
        COMPOSIO_API_KEY)   COMPOSIO_API_KEY="$value" ;;
      esac
    done < "$SECRETS_FILE"
    # Validate required keys present (Anthropic is optional — Max plan)
    local missing=()
    [ -z "$OPENROUTER_API_KEY" ] && missing+=("OPENROUTER_API_KEY")
    [ -z "$COMPOSIO_API_KEY" ]   && missing+=("COMPOSIO_API_KEY")
    if [ ${#missing[@]} -gt 0 ]; then
      echo -e "${R}Error: secrets file missing keys: ${missing[*]}${NC}"
      exit 1
    fi
    [ -z "$ANTHROPIC_API_KEY" ] && ANTHROPIC_API_KEY="MAX_PLAN"
  elif ! $DRY_RUN; then
    echo ""
    echo -e "${C}  Enter API keys (paste each one and press Enter):${NC}"
    echo ""
    read -r -p "  OpenRouter API key (sk-or-...): " OPENROUTER_API_KEY
    if [ -z "$OPENROUTER_API_KEY" ]; then echo -e "${R}Error: OpenRouter key is required${NC}"; exit 1; fi
    read -r -p "  Composio API key (ak_...): " COMPOSIO_API_KEY
    if [ -z "$COMPOSIO_API_KEY" ]; then echo -e "${R}Error: Composio key is required${NC}"; exit 1; fi
    echo ""
    read -r -p "  Anthropic API key (press Enter to skip if using Max plan): " ANTHROPIC_API_KEY
    if [ -z "$ANTHROPIC_API_KEY" ]; then
      ANTHROPIC_API_KEY="MAX_PLAN"
      echo -e "  ${C}→${NC} Using Anthropic Max plan (no API key needed)"
    fi
    echo ""
  else
    # Dry run — use placeholders
    ANTHROPIC_API_KEY="sk-ant-PLACEHOLDER"
    OPENROUTER_API_KEY="sk-or-v1-PLACEHOLDER"
    COMPOSIO_API_KEY="ak_PLACEHOLDER"
  fi
}

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${G}║       OpenClaw AI Employee — Franchise Installer v${VERSION}     ║${NC}"
echo -e "${G}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Architecture:   ${C}${ARCH}${NC}"
echo -e "  macOS:          ${C}$(sw_vers -productVersion 2>/dev/null || echo 'unknown')${NC}"
echo -e "  Date:           ${C}${DATE}${NC}"
echo -e "  Client:         ${C}${CLIENT_NAME}${NC}"
echo -e "  Installer dir:  ${C}${INSTALLER_DIR}${NC}"
echo -e "  Log:            ${C}${LOG_FILE}${NC}"
$DRY_RUN && echo -e "  Mode:           ${Y}DRY RUN${NC}"
$SKIP_DOCKER && echo -e "  Docker:         ${Y}SKIPPED${NC}"
echo ""
log "=== Installer v${VERSION} started | arch=$ARCH | client=$CLIENT_NAME | dry=$DRY_RUN ==="

# Load API secrets before any steps
load_secrets

#===============================================================================
# STEP 1: macOS system settings (pre-flight)
#===============================================================================
step "macOS system settings (pre-flight)"

# --- Check SIP status ---
sip_status="$(csrutil status 2>/dev/null || echo 'unknown')"
if echo "$sip_status" | grep -q "enabled"; then
  warn "System Integrity Protection (SIP) is ENABLED"
  info "Some advanced operations may be restricted with SIP on."
  info "To disable (optional, requires Recovery Mode):"
  info "  1. Restart Mac → hold Power button until 'Loading startup options' appears"
  info "  2. Select Options → click Continue"
  info "  3. Open Terminal from Utilities menu"
  info "  4. Run: csrutil disable"
  info "  5. Restart"
elif echo "$sip_status" | grep -q "disabled"; then
  ok "SIP is disabled"
else
  warn "Could not determine SIP status"
fi

# --- sudo-guarded system settings ---
if $DRY_RUN; then
  dry "Enable Remote Login (SSH): sudo systemsetup -setremotelogin on"
  dry "Enable Screen Sharing: sudo launchctl load -w com.apple.screensharing.plist"
  dry "Set power management: sudo pmset -a sleep 0 displaysleep 0 disksleep 0"
  dry "Enable Wake on LAN: sudo pmset -a womp 1"
  dry "Auto-restart after power failure: sudo pmset -a autorestart 1"
  SUCCESSES+=("macOS system settings (dry)")
else
  if sudo -n true 2>/dev/null; then
    # Enable Remote Login (SSH)
    sudo systemsetup -setremotelogin on 2>/dev/null \
      && ok "Remote Login (SSH) enabled" \
      || warn "Could not enable Remote Login — enable manually in System Settings > General > Sharing"

    # Enable Screen Sharing
    sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null \
      && ok "Screen Sharing enabled" \
      || warn "Could not enable Screen Sharing — enable manually in System Settings > General > Sharing"

    # Power management — prevent sleep
    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 2>/dev/null \
      && ok "Power management: sleep disabled" \
      || warn "Could not set power management — run manually: sudo pmset -a sleep 0 displaysleep 0 disksleep 0"

    # Wake on LAN
    sudo pmset -a womp 1 2>/dev/null \
      && ok "Wake on LAN enabled" \
      || warn "Could not enable Wake on LAN"

    # Auto-restart after power failure
    sudo pmset -a autorestart 1 2>/dev/null \
      && ok "Auto-restart after power failure enabled" \
      || warn "Could not enable auto-restart after power failure"
  else
    warn "sudo requires a password — skipping system settings"
    info "Run these commands manually with sudo:"
    info "  sudo systemsetup -setremotelogin on"
    info "  sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist"
    info "  sudo pmset -a sleep 0 displaysleep 0 disksleep 0"
    info "  sudo pmset -a womp 1"
    info "  sudo pmset -a autorestart 1"
  fi
fi

# --- Deploy SSH key (allows GitHub Actions to push updates via Tailscale) ---
DEPLOY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIxINTvk1fYxIeH6nk2lYidHqJ8u6PRgjZKif3wAYDqq franchise-deploy@github-actions"

mkdir -p "$HOME/.ssh" 2>/dev/null
chmod 700 "$HOME/.ssh" 2>/dev/null
touch "$HOME/.ssh/authorized_keys" 2>/dev/null
chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null

if grep -qF "franchise-deploy@github-actions" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  skip "Deploy SSH key"
else
  if $DRY_RUN; then
    dry "Add franchise deploy SSH key to ~/.ssh/authorized_keys"
  else
    echo "$DEPLOY_PUBKEY" >> "$HOME/.ssh/authorized_keys" \
      && ok "Deploy SSH key added to authorized_keys" \
      || fail "Deploy SSH key"
  fi
fi

#===============================================================================
# STEP 2: Homebrew + brew bundle
#===============================================================================
step "Homebrew + brew bundle"

# Xcode Command Line Tools — required for Homebrew and git
if xcode-select -p &>/dev/null; then
  skip "Xcode Command Line Tools"
else
  if $DRY_RUN; then
    dry "Install Xcode Command Line Tools"
  else
    info "Installing Xcode Command Line Tools (this may take a few minutes)..."
    xcode-select --install 2>/dev/null
    # Wait for installation to complete
    until xcode-select -p &>/dev/null; do
      sleep 5
    done
    ok "Xcode Command Line Tools"
  fi
fi

if cmd_exists brew; then
  skip "Homebrew"
  ensure_brew_in_path
else
  if $DRY_RUN; then dry "Install Homebrew"; else
    info "Installing Homebrew (this may take a minute)..."
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      >> "$LOG_FILE" 2>&1 \
      && { ensure_brew_in_path; ok "Homebrew"; } \
      || fail "Homebrew"
  fi
fi

# Install all brew packages from Brewfile
if cmd_exists brew; then
  if [ -f "$INSTALLER_DIR/Brewfile" ]; then
    if $DRY_RUN; then
      dry "brew bundle --file=$INSTALLER_DIR/Brewfile"
      SUCCESSES+=("Brew bundle (dry)")
    else
      info "Running brew bundle (this may take a while on a fresh machine)..."
      if brew bundle --file="$INSTALLER_DIR/Brewfile" >> "$LOG_FILE" 2>&1; then
        ok "Brew bundle — all packages installed"
      else
        warn "Brew bundle completed with some failures — check log"
        info "You can retry individual packages: brew bundle --file=$INSTALLER_DIR/Brewfile"
      fi
    fi
  else
    warn "Brewfile not found at $INSTALLER_DIR/Brewfile — installing essentials only"
    install_brew_pkg "git" "git"
    install_brew_pkg "jq" "jq"
    install_brew_pkg "curl" "curl"
    install_brew_pkg "sqlite3" "sqlite3"
  fi
else
  warn "Homebrew not available — skipping brew packages"
fi

#===============================================================================
# STEP 3: NVM + Node.js v24.13.0
#===============================================================================
step "NVM + Node.js v${NODE_TARGET}"

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

if [ -s "$NVM_DIR/nvm.sh" ]; then
  skip "nvm"
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
else
  if $DRY_RUN; then dry "Install nvm"; else
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh 2>/dev/null \
      | bash >> "$LOG_FILE" 2>&1 \
      && { . "$NVM_DIR/nvm.sh"; ok "nvm"; } \
      || fail "nvm"
  fi
fi

# Node.js — pin exact version
if cmd_exists node && [ "$(node -v 2>/dev/null)" = "v${NODE_TARGET}" ]; then
  skip "Node.js v${NODE_TARGET}"
else
  if $DRY_RUN; then dry "nvm install $NODE_TARGET && nvm alias default $NODE_TARGET"; else
    if type nvm &>/dev/null; then
      nvm install "$NODE_TARGET" >> "$LOG_FILE" 2>&1 \
        && nvm use "$NODE_TARGET" >> "$LOG_FILE" 2>&1 \
        && nvm alias default "$NODE_TARGET" >> "$LOG_FILE" 2>&1 \
        && ok "Node.js v${NODE_TARGET}" \
        || fail "Node.js v${NODE_TARGET}"
    else
      fail "Node.js (nvm not available)"
    fi
  fi
fi

#===============================================================================
# STEP 4: Global npm packages (openclaw, clawhub)
#===============================================================================
step "Global npm packages"

install_npm_global "openclaw" "OpenClaw CLI" "openclaw"
install_npm_global "clawhub" "ClawHub CLI" "clawhub"
install_npm_global "mcporter" "MCPorter CLI" "mcporter"
install_npm_global "@anthropic-ai/claude-code" "Claude Code" "claude"
install_npm_global "opencode-ai" "OpenCode" "opencode"
install_npm_global "@steipete/oracle" "Oracle CLI" "oracle"
install_npm_global "vercel" "Vercel CLI" "vercel"

#===============================================================================
# STEP 5: Python packages (pipx)
#===============================================================================
step "Python packages (pipx)"

# Ensure pipx is available (installed via Brewfile)
if ! cmd_exists pipx; then
  if cmd_exists brew; then
    brew install pipx >> "$LOG_FILE" 2>&1 && ok "pipx installed" || fail "pipx"
  else
    warn "pipx not available — skipping Python packages"
  fi
fi

if cmd_exists pipx; then
  pipx ensurepath >> "$LOG_FILE" 2>&1

  # MLX Whisper — Apple Silicon optimized speech-to-text
  if pipx list 2>/dev/null | grep -q "mlx.whisper\|mlx-whisper"; then
    skip "mlx-whisper"
  else
    if $DRY_RUN; then
      dry "pipx install mlx-whisper"
      SUCCESSES+=("mlx-whisper (dry)")
    else
      if [ "$ARCH" = "arm64" ]; then
        pipx install mlx-whisper >> "$LOG_FILE" 2>&1 \
          && ok "mlx-whisper (Apple Silicon)" \
          || warn "mlx-whisper install failed — may need: pipx install mlx-whisper"
      else
        warn "mlx-whisper requires Apple Silicon (arm64) — skipping on $ARCH"
        info "Using openai-whisper (CPU) instead"
      fi
    fi
  fi
else
  warn "pipx not available — Python packages skipped"
  info "Install manually: pipx install mlx-whisper"
fi

#===============================================================================
# STEP 6: 1Password CLI setup
#===============================================================================
step "1Password CLI setup"

if cmd_exists op; then
  skip "1Password CLI (op)"
else
  if $DRY_RUN; then
    dry "brew install --cask 1password-cli"
    SUCCESSES+=("1Password CLI (dry)")
  else
    if cmd_exists brew; then
      brew install --cask 1password-cli >> "$LOG_FILE" 2>&1 \
        && ok "1Password CLI (op)" \
        || fail "1Password CLI (brew install --cask 1password-cli)"
    else
      fail "1Password CLI (Homebrew not available)"
    fi
  fi
fi

# Check if op is signed in (don't try to auth — Andrew will do that manually)
if cmd_exists op; then
  if op account list &>/dev/null 2>&1; then
    ok "1Password CLI signed in"

    # Create vault for this client if it doesn't exist
    VAULT_NAME="openclaw-${CLIENT_NAME}"
    if op vault get "$VAULT_NAME" &>/dev/null 2>&1; then
      skip "1Password vault: $VAULT_NAME"
    else
      if $DRY_RUN; then
        dry "op vault create '$VAULT_NAME'"
      else
        op vault create "$VAULT_NAME" >> "$LOG_FILE" 2>&1 \
          && ok "1Password vault: $VAULT_NAME" \
          || fail "1Password vault creation"
      fi
    fi

    # Store API keys and tokens as vault items
    if ! $DRY_RUN && op vault get "$VAULT_NAME" &>/dev/null 2>&1; then
      store_op_item() {
        local item_name="$1" field_name="$2" field_value="$3"
        if [ -z "$field_value" ] || [ "$field_value" = "sk-ant-PLACEHOLDER" ] || [ "$field_value" = "sk-or-v1-PLACEHOLDER" ] || [ "$field_value" = "ak_PLACEHOLDER" ]; then
          return 0
        fi
        if op item get "$item_name" --vault "$VAULT_NAME" &>/dev/null 2>&1; then
          skip "1Password item: $item_name"
        else
          op item create --category=login --title="$item_name" --vault="$VAULT_NAME" \
            "${field_name}=${field_value}" >> "$LOG_FILE" 2>&1 \
            && ok "1Password item: $item_name" \
            || warn "Failed to create 1Password item: $item_name"
        fi
      }
      store_op_item "anthropic" "credential" "$ANTHROPIC_API_KEY"
      store_op_item "openrouter" "credential" "$OPENROUTER_API_KEY"
      store_op_item "composio" "credential" "$COMPOSIO_API_KEY"
      unset -f store_op_item
    elif $DRY_RUN; then
      dry "Store API keys in 1Password vault '$VAULT_NAME'"
    fi
  else
    warn "1Password CLI not signed in — skipping vault setup"
    info "Sign in manually:  op signin"
    info "Then re-run installer or create vault manually:"
    info "  op vault create 'openclaw-${CLIENT_NAME}'"
  fi
fi

# Generate .op-env secrets reference file from template
OP_ENV_TMPL="$INSTALLER_DIR/config/op-env.template"
OP_ENV_DEST="$OPENCLAW_DIR/.op-env"

if [ -f "$OP_ENV_DEST" ]; then
  skip ".op-env secrets reference"
else
  if [ -f "$OP_ENV_TMPL" ]; then
    if $DRY_RUN; then
      dry "Generate .op-env from template"
    else
      process_template "$OP_ENV_TMPL" "$OP_ENV_DEST" \
        && ok ".op-env secrets reference generated" \
        || fail ".op-env template processing"
    fi
  else
    warn ".op-env template not found at $OP_ENV_TMPL"
  fi
fi

# Install launch-with-secrets.sh wrapper
LAUNCH_WRAPPER_SRC="$INSTALLER_DIR/scripts/launch-with-secrets.sh"
LAUNCH_WRAPPER_DEST="$OPENCLAW_DIR/scripts/launch-with-secrets.sh"

mkdir -p "$OPENCLAW_DIR/scripts" 2>/dev/null

if [ -f "$LAUNCH_WRAPPER_DEST" ]; then
  skip "launch-with-secrets.sh wrapper"
else
  if [ -f "$LAUNCH_WRAPPER_SRC" ]; then
    if $DRY_RUN; then
      dry "Install launch-with-secrets.sh wrapper"
    else
      cp "$LAUNCH_WRAPPER_SRC" "$LAUNCH_WRAPPER_DEST" 2>>"$LOG_FILE" \
        && chmod +x "$LAUNCH_WRAPPER_DEST" \
        && ok "launch-with-secrets.sh wrapper installed" \
        || fail "launch-with-secrets.sh wrapper"
    fi
  else
    fail "launch-with-secrets.sh not found at $LAUNCH_WRAPPER_SRC"
  fi
fi

#===============================================================================
# STEP 7: Tailscale + Cloudflare Tunnel
#===============================================================================
step "Tailscale + Cloudflare Tunnel"

# --- Tailscale ---
if app_installed "Tailscale" || cmd_exists tailscale; then
  skip "Tailscale"
else
  if $DRY_RUN; then
    dry "brew install --cask tailscale"
    SUCCESSES+=("Tailscale (dry)")
  else
    if cmd_exists brew; then
      brew install --cask tailscale >> "$LOG_FILE" 2>&1 \
        && ok "Tailscale installed" \
        || fail "Tailscale (brew install --cask tailscale)"
    else
      fail "Tailscale (Homebrew not available)"
    fi
  fi
fi

info "Tailscale authentication (manual):"
info "  open -a Tailscale"
info "  tailscale up --hostname=${CLIENT_NAME}"

# --- Cloudflared ---
if cmd_exists cloudflared; then
  skip "cloudflared"
else
  if $DRY_RUN; then
    dry "brew install cloudflared"
    SUCCESSES+=("cloudflared (dry)")
  else
    if cmd_exists brew; then
      brew install cloudflared >> "$LOG_FILE" 2>&1 \
        && ok "cloudflared installed" \
        || fail "cloudflared (brew install cloudflared)"
    else
      fail "cloudflared (Homebrew not available)"
    fi
  fi
fi

# Generate cloudflared config from template (requires TUNNEL_ID and TUNNEL_DOMAIN)
CLOUDFLARED_TMPL="$INSTALLER_DIR/config/cloudflared.yml.template"
CLOUDFLARED_DEST="$HOME/.cloudflared/config.yml"

if [ -f "$CLOUDFLARED_DEST" ]; then
  skip "cloudflared config.yml"
else
  mkdir -p "$HOME/.cloudflared" 2>/dev/null
  if [ -f "$CLOUDFLARED_TMPL" ]; then
    info "Cloudflare tunnel config template available at:"
    info "  $CLOUDFLARED_TMPL"
    info ""
    info "To configure, create a tunnel and then generate the config:"
    info "  cloudflared tunnel login"
    info "  cloudflared tunnel create ${CLIENT_NAME}"
    info "  # Then copy the tunnel ID and update the config:"
    info "  TUNNEL_ID=<your-tunnel-id> TUNNEL_DOMAIN=<your-domain>"
    info "  sed -e 's/{{TUNNEL_ID}}/'\$TUNNEL_ID'/g' \\"
    info "      -e 's/{{CLIENT_NAME}}/${CLIENT_NAME}/g' \\"
    info "      -e 's|{{HOME}}|${HOME}|g' \\"
    info "      -e 's/{{TUNNEL_DOMAIN}}/'\$TUNNEL_DOMAIN'/g' \\"
    info "      '$CLOUDFLARED_TMPL' > '$CLOUDFLARED_DEST'"
    warn "cloudflared config.yml — requires manual tunnel setup (see above)"
    SKIPPED+=("cloudflared config (manual setup required)")
  else
    warn "cloudflared config template not found at $CLOUDFLARED_TMPL"
  fi
fi

# Install cloudflared LaunchAgent plist
CF_PLIST_SRC="$INSTALLER_DIR/launchagents/com.cloudflare.cloudflared.plist"
CF_PLIST_DEST="$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist"

if [ -f "$CF_PLIST_DEST" ]; then
  skip "com.cloudflare.cloudflared.plist"
else
  if [ -f "$CF_PLIST_SRC" ]; then
    if $DRY_RUN; then
      dry "Install com.cloudflare.cloudflared.plist"
    else
      mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null
      process_template "$CF_PLIST_SRC" "$CF_PLIST_DEST" \
        && ok "com.cloudflare.cloudflared.plist" \
        || fail "com.cloudflare.cloudflared.plist"
    fi
  else
    warn "cloudflared plist template not found at $CF_PLIST_SRC"
  fi
fi

info "After tunnel setup, load the LaunchAgent:"
info "  launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist"

#===============================================================================
# STEP 8: Docker Desktop + start daemon
#===============================================================================
step "Docker Desktop"

if $SKIP_DOCKER; then
  warn "Docker Desktop — skipped by --skip-docker flag"
  SKIPPED+=("Docker Desktop")
else
  if app_installed "Docker"; then
    skip "Docker Desktop"
  else
    if $DRY_RUN; then dry "brew install --cask docker"; SUCCESSES+=("Docker Desktop (dry)"); else
      if cmd_exists brew; then
        brew install --cask docker >> "$LOG_FILE" 2>&1 \
          && ok "Docker Desktop" \
          || fail "Docker Desktop (brew install --cask docker)"
      else
        fail "Docker Desktop (Homebrew not available)"
      fi
    fi
  fi

  # Start Docker daemon if not running
  if ! $DRY_RUN && ! docker info &>/dev/null 2>&1; then
    if app_installed "Docker"; then
      info "Starting Docker Desktop (may take up to 60s)..."
      open -a Docker
      local_timeout=30
      for i in $(seq 1 $local_timeout); do
        docker info &>/dev/null 2>&1 && break
        sleep 2
      done
      if docker info &>/dev/null 2>&1; then
        ok "Docker daemon running"
      else
        warn "Docker started but daemon not ready yet — Neo4j step may fail"
      fi
    fi
  elif ! $DRY_RUN; then
    ok "Docker daemon already running"
  fi
fi

#===============================================================================
# STEP 9: Neo4j container (empty graph, password auth)
#===============================================================================
step "Neo4j container"

if $SKIP_DOCKER; then
  warn "Neo4j — skipped (Docker skipped)"
  SKIPPED+=("Neo4j")
elif ! docker info &>/dev/null 2>&1; then
  warn "Neo4j — Docker not running, skipping"
  SKIPPED+=("Neo4j (Docker not running)")
else
  if docker ps -a --format '{{.Names}}' | grep -q '^neo4j$'; then
    skip "Neo4j container"
    # Ensure it is running
    if ! docker ps --format '{{.Names}}' | grep -q '^neo4j$'; then
      if $DRY_RUN; then dry "docker start neo4j"; else
        docker start neo4j >> "$LOG_FILE" 2>&1 \
          && ok "Neo4j container started" \
          || fail "Neo4j container start"
      fi
    fi
  else
    if $DRY_RUN; then dry "docker run neo4j:community (password auth)"; SUCCESSES+=("Neo4j (dry)"); else
      mkdir -p "$OPENCLAW_DIR/neo4j/data" "$OPENCLAW_DIR/neo4j/logs"
      docker run -d \
        --name neo4j \
        --restart unless-stopped \
        -p 7474:7474 -p 7687:7687 \
        -e NEO4J_AUTH="neo4j/${NEO4J_PASSWORD}" \
        -v "$OPENCLAW_DIR/neo4j/data:/data" \
        -v "$OPENCLAW_DIR/neo4j/logs:/logs" \
        neo4j:community >> "$LOG_FILE" 2>&1 \
        && ok "Neo4j container (password: ${NEO4J_PASSWORD})" \
        || fail "Neo4j container"
    fi
  fi
fi

#===============================================================================
# STEP 10: Create ~/.openclaw directory structure
#===============================================================================
step "Create ~/.openclaw directory structure"

DIRS=(
  "$OPENCLAW_DIR"
  "$OPENCLAW_DIR/workspace"
  "$OPENCLAW_DIR/workspace-bizdev"
  "$OPENCLAW_DIR/workspace-content"
  "$OPENCLAW_DIR/workspace-dev"
  "$OPENCLAW_DIR/workspace-outreach"
  "$OPENCLAW_DIR/workspace-quick"
  "$OPENCLAW_DIR/logs"
  "$OPENCLAW_DIR/memory"
  "$OPENCLAW_DIR/extensions"
  "$OPENCLAW_DIR/skills"
  "$OPENCLAW_DIR/neo4j/data"
  "$OPENCLAW_DIR/neo4j/logs"
  "$OPENCLAW_DIR/agents"
  "$OPENCLAW_DIR/cron"
  "$OPENCLAW_DIR/crons"
  "$OPENCLAW_DIR/scripts"
)

if $DRY_RUN; then
  dry "Create ${#DIRS[@]} directories under $OPENCLAW_DIR"
  SUCCESSES+=("Directory structure (dry)")
else
  local_ok=true
  for d in "${DIRS[@]}"; do
    mkdir -p "$d" 2>>"$LOG_FILE" || local_ok=false
  done
  if $local_ok; then
    ok "Directory structure (${#DIRS[@]} directories)"
  else
    fail "Some directories could not be created"
  fi
fi

#===============================================================================
# STEP 11: Install openclaw-mem0 extension
#===============================================================================
step "Install openclaw-mem0 extension"

MEM0_EXT_DIR="$OPENCLAW_DIR/extensions/openclaw-mem0"

if [ -d "$MEM0_EXT_DIR/node_modules" ] && [ -f "$MEM0_EXT_DIR/package.json" ]; then
  skip "openclaw-mem0 extension"
else
  if $DRY_RUN; then
    dry "Install openclaw-mem0 extension from installer package"
    SUCCESSES+=("openclaw-mem0 (dry)")
  else
    # Copy extension base from installer package if available
    if [ -d "$INSTALLER_DIR/extensions/openclaw-mem0" ] && [ -n "$(ls -A "$INSTALLER_DIR/extensions/openclaw-mem0" 2>/dev/null)" ]; then
      mkdir -p "$MEM0_EXT_DIR"
      cp -R "$INSTALLER_DIR/extensions/openclaw-mem0/"* "$MEM0_EXT_DIR/" 2>>"$LOG_FILE"
      info "Copied openclaw-mem0 from installer package"
    else
      # Fall back to npm install
      mkdir -p "$MEM0_EXT_DIR"
      info "Installing openclaw-mem0 via npm..."
    fi

    # Run npm install in the extension directory
    if [ -f "$MEM0_EXT_DIR/package.json" ]; then
      (cd "$MEM0_EXT_DIR" && npm install >> "$LOG_FILE" 2>&1) \
        && ok "openclaw-mem0 npm install" \
        || fail "openclaw-mem0 npm install"
    else
      fail "openclaw-mem0 — no package.json found (provide extension in $INSTALLER_DIR/extensions/openclaw-mem0/)"
    fi
  fi
fi

# Apply mem0 SDK patches
info "Applying mem0ai SDK patches..."
MEM0_DIST="$MEM0_EXT_DIR/node_modules/mem0ai/dist/oss"
if [ -d "$MEM0_DIST" ]; then
  PATCH_DIR="$INSTALLER_DIR/patches"
  if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/mem0-*.patch &>/dev/null 2>&1; then
    if $DRY_RUN; then
      dry "Apply mem0 SDK patches from $PATCH_DIR"
    else
      local_patch_ok=true
      for pf in "$PATCH_DIR"/mem0-*.patch; do
        patch -d "$MEM0_EXT_DIR" -p1 < "$pf" >> "$LOG_FILE" 2>&1 || local_patch_ok=false
      done
      if $local_patch_ok; then
        ok "mem0ai SDK patches applied"
      else
        warn "Some mem0 patches failed — check log. Manual patching may be required."
        info "See: ~/Desktop/rag-reality/06-OPENCLAW-MEM0-INSTALLATION-GUIDE.md"
      fi
    fi
  else
    warn "No mem0 patch files found in $PATCH_DIR/"
    info "Patches must be applied manually. Required patches:"
    info "  1. Add 'Return your response as json.' to _retrieveNodesFromData prompt"
    info "  2. Same for DELETE_RELATIONS_SYSTEM_PROMPT"
    info "  3. OpenAILLM.generateResponse — only pass response_format when tools NOT provided"
    info "  4. OpenAIEmbedder — accept baseURL config, pass dimensions parameter"
    info "  5. ConfigManager.mergeConfig — preserve baseURL in embedder config"
    info "Patch both: index.js (CJS) and index.mjs (ESM) in node_modules/mem0ai/dist/oss/"
  fi
else
  if [ -d "$MEM0_EXT_DIR" ]; then
    warn "mem0ai dist/oss not found — patches skipped (run npm install first)"
  fi
fi

#===============================================================================
# STEP 12: Install openclaw-composio extension
#===============================================================================
step "Install openclaw-composio extension"

COMPOSIO_EXT_DIR="$OPENCLAW_DIR/extensions/openclaw-composio"

if [ -d "$COMPOSIO_EXT_DIR/node_modules" ] && [ -f "$COMPOSIO_EXT_DIR/package.json" ]; then
  skip "openclaw-composio extension"
else
  if $DRY_RUN; then
    dry "Copy openclaw-composio from installer package"
    SUCCESSES+=("openclaw-composio (dry)")
  else
    if [ -d "$INSTALLER_DIR/extensions/openclaw-composio" ] && [ -n "$(ls -A "$INSTALLER_DIR/extensions/openclaw-composio" 2>/dev/null)" ]; then
      mkdir -p "$COMPOSIO_EXT_DIR"
      cp -R "$INSTALLER_DIR/extensions/openclaw-composio/"* "$COMPOSIO_EXT_DIR/" 2>>"$LOG_FILE"
      info "Copied openclaw-composio from installer package"
      # npm install if package.json present
      if [ -f "$COMPOSIO_EXT_DIR/package.json" ]; then
        (cd "$COMPOSIO_EXT_DIR" && npm install >> "$LOG_FILE" 2>&1) \
          && ok "openclaw-composio installed" \
          || fail "openclaw-composio npm install"
      else
        ok "openclaw-composio copied (no package.json — pre-built)"
      fi
    else
      # Copy from the running system as a fallback reference
      warn "No openclaw-composio found in installer package at $INSTALLER_DIR/extensions/openclaw-composio/"
      info "Populate $INSTALLER_DIR/extensions/openclaw-composio/ with the extension files before running."
      fail "openclaw-composio extension — source files missing"
    fi
  fi
fi

# Create composio entity-map config directory
mkdir -p "$COMPOSIO_EXT_DIR/config" 2>/dev/null
if [ ! -f "$COMPOSIO_EXT_DIR/config/entity-map.json" ]; then
  if $DRY_RUN; then
    dry "Create entity-map.json for $CLIENT_NAME"
  else
    cat > "$COMPOSIO_EXT_DIR/config/entity-map.json" << ENTITYMAP
{
  "default": "${CLIENT_NAME}",
  "channels": {},
  "users": {}
}
ENTITYMAP
    ok "entity-map.json created (default entity: $CLIENT_NAME)"
  fi
else
  skip "entity-map.json"
fi

#===============================================================================
# STEP 13: Apply OpenClaw BUSINESS.md injection patches
#===============================================================================
step "OpenClaw BUSINESS.md injection patches"

warn "BUSINESS.md injection requires patching OpenClaw dist files."
info "This patch adds BUSINESS.md to loadWorkspaceBootstrapFiles() in agent-scope-*.js"
info ""
info "Location: \$(dirname \$(which openclaw))/../lib/node_modules/openclaw/dist/agent-scope-*.js"
info ""
info "Manual steps:"
info "  1. Find the dist files:  ls \$(npm root -g)/openclaw/dist/agent-scope-*.js"
info "  2. In each file, locate the loadWorkspaceBootstrapFiles() function"
info "  3. Find the entries array containing 'BOOTSTRAP.md'"
info "  4. Add 'BUSINESS.md' as the next entry after 'BOOTSTRAP.md'"
info ""
info "Alternatively, if patch files are provided:"

PATCH_DIR="$INSTALLER_DIR/patches"
if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/business-md-*.patch &>/dev/null 2>&1; then
  OPENCLAW_DIST=""
  if cmd_exists openclaw; then
    OPENCLAW_DIST="$(dirname "$(dirname "$(which openclaw)")")/lib/node_modules/openclaw/dist"
    # Fallback: try nvm path
    if [ ! -d "$OPENCLAW_DIST" ]; then
      OPENCLAW_DIST="$HOME/.nvm/versions/node/v${NODE_TARGET}/lib/node_modules/openclaw/dist"
    fi
  fi
  if [ -d "$OPENCLAW_DIST" ]; then
    if $DRY_RUN; then
      dry "Apply BUSINESS.md patches to $OPENCLAW_DIST"
    else
      local_patch_ok=true
      for pf in "$PATCH_DIR"/business-md-*.patch; do
        patch -d "$OPENCLAW_DIST/.." -p1 < "$pf" >> "$LOG_FILE" 2>&1 || local_patch_ok=false
      done
      if $local_patch_ok; then
        ok "BUSINESS.md injection patches applied"
      else
        warn "Some BUSINESS.md patches failed — apply manually (see instructions above)"
      fi
    fi
  else
    warn "OpenClaw dist directory not found — install openclaw first, then re-run this step"
  fi
else
  warn "No BUSINESS.md patch files found in $PATCH_DIR/"
  info "This step must be completed manually after installation."
  SKIPPED+=("BUSINESS.md patches (manual)")
fi

#===============================================================================
# STEP 14: Process templates — workspace files, openclaw.json, .env
#===============================================================================
step "Process templates and workspace files"

TMPL_DIR="$INSTALLER_DIR/workspace"

# --- 14a. Copy core workspace identity files ---
WORKSPACE_FILES=("AGENTS.md" "TOOLS.md" "HEARTBEAT.md" "BOOTSTRAP.md" "BUSINESS.md" "IDENTITY.md" "USER.md" "SOUL.md")

for wf in "${WORKSPACE_FILES[@]}"; do
  src_template="$TMPL_DIR/${wf}.template"
  src_plain="$TMPL_DIR/${wf}"
  dest="$WORKSPACE_DIR/${wf}"

  if [ -f "$dest" ]; then
    skip "workspace/$wf"
    continue
  fi

  if [ -f "$src_template" ]; then
    if $DRY_RUN; then
      dry "Process template $wf.template -> workspace/$wf"
    else
      process_template "$src_template" "$dest" \
        && ok "workspace/$wf (from template)" \
        || fail "workspace/$wf template processing"
    fi
  elif [ -f "$src_plain" ]; then
    if $DRY_RUN; then
      dry "Copy $wf -> workspace/$wf"
    else
      cp "$src_plain" "$dest" 2>>"$LOG_FILE" \
        && ok "workspace/$wf (copied)" \
        || fail "workspace/$wf copy"
    fi
  else
    warn "workspace/$wf — no source found in $TMPL_DIR/"
  fi
done

# --- 14b. Create symlinks for specialist workspaces ---
SPECIALIST_WORKSPACES=("workspace-bizdev" "workspace-content" "workspace-dev" "workspace-outreach" "workspace-quick")
SYMLINK_FILES=("IDENTITY.md" "SOUL.md" "TOOLS.md" "USER.md" "BUSINESS.md")

for sw in "${SPECIALIST_WORKSPACES[@]}"; do
  sw_dir="$OPENCLAW_DIR/$sw"
  mkdir -p "$sw_dir" 2>/dev/null

  for sf in "${SYMLINK_FILES[@]}"; do
    target="$WORKSPACE_DIR/$sf"
    link="$sw_dir/$sf"
    if [ -L "$link" ] || [ -f "$link" ]; then
      # Already exists (symlink or file)
      continue
    fi
    if [ -f "$target" ]; then
      if $DRY_RUN; then
        dry "Symlink $sw/$sf -> workspace/$sf"
      else
        ln -s "$target" "$link" 2>>"$LOG_FILE"
      fi
    fi
  done

  # Each specialist workspace has its own AGENTS.md (not symlinked)
  agents_src="$INSTALLER_DIR/workspaces/$sw/AGENTS.md"
  agents_dest="$sw_dir/AGENTS.md"
  if [ ! -f "$agents_dest" ] && [ -f "$agents_src" ]; then
    if $DRY_RUN; then
      dry "Copy $sw/AGENTS.md"
    else
      cp "$agents_src" "$agents_dest" 2>>"$LOG_FILE"
    fi
  fi
done

if $DRY_RUN; then
  dry "Create symlinks for specialist workspaces"
  SUCCESSES+=("Specialist workspace symlinks (dry)")
else
  ok "Specialist workspace symlinks created"
fi

# --- 14c. Generate openclaw.json from template ---
OPENCLAW_JSON="$OPENCLAW_DIR/openclaw.json"
OPENCLAW_JSON_TMPL="$INSTALLER_DIR/config/openclaw.json.template"

if [ -f "$OPENCLAW_JSON" ]; then
  skip "openclaw.json"
else
  if [ -f "$OPENCLAW_JSON_TMPL" ]; then
    if $DRY_RUN; then
      dry "Generate openclaw.json from template"
    else
      process_template "$OPENCLAW_JSON_TMPL" "$OPENCLAW_JSON" \
        && ok "openclaw.json generated" \
        || fail "openclaw.json template processing"
    fi
  else
    warn "openclaw.json template not found at $OPENCLAW_JSON_TMPL"
    info "You will need to create openclaw.json manually or run 'openclaw init'"
    # Attempt openclaw init as fallback
    if cmd_exists openclaw; then
      if $DRY_RUN; then dry "openclaw init"; else
        openclaw init >> "$LOG_FILE" 2>&1 \
          && ok "openclaw.json (via openclaw init)" \
          || warn "openclaw init returned non-zero (may already be initialized)"
      fi
    fi
  fi
fi

# --- 14d. Create .env from template ---
ENV_FILE="$OPENCLAW_DIR/.env"
ENV_TMPL="$INSTALLER_DIR/config/env.template"

if [ -f "$ENV_FILE" ]; then
  skip ".env"
else
  if [ -f "$ENV_TMPL" ]; then
    if $DRY_RUN; then
      dry "Generate .env from template"
    else
      process_template "$ENV_TMPL" "$ENV_FILE" \
        && { chmod 600 "$ENV_FILE"; ok ".env generated (mode 600)"; } \
        || fail ".env template processing"
    fi
  else
    # Create a minimal .env with the provided keys
    if $DRY_RUN; then
      dry "Create minimal .env with provided keys"
    else
      cat > "$ENV_FILE" << ENVEOF
# OpenClaw AI Employee — Environment
# Generated: ${DATE}
# Client: ${CLIENT_NAME}

# Anthropic
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# OpenRouter (for mem0 embeddings + LLM)
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}

# Composio (tool integrations)
COMPOSIO_API_KEY=${COMPOSIO_API_KEY}

# Neo4j
NEO4J_URL=bolt://localhost:7687
NEO4J_USERNAME=neo4j
NEO4J_PASSWORD=${NEO4J_PASSWORD}
ENVEOF
      chmod 600 "$ENV_FILE"
      ok ".env created (mode 600)"
    fi
  fi
fi

# Also create workspace/.env if missing
WS_ENV="$WORKSPACE_DIR/.env"
if [ ! -f "$WS_ENV" ]; then
  if $DRY_RUN; then
    dry "Create workspace/.env"
  else
    cat > "$WS_ENV" << WSENVEOF
COMPOSIO_API_KEY=${COMPOSIO_API_KEY}
WSENVEOF
    chmod 600 "$WS_ENV"
    ok "workspace/.env created"
  fi
else
  skip "workspace/.env"
fi

#===============================================================================
# STEP 15: Install skills
#===============================================================================
step "Install skills"

# Global skills (installed to ~/.openclaw/skills/)
GLOBAL_SKILLS=("autonomous-brain" "calendly" "wacli")

for skill_name in "${GLOBAL_SKILLS[@]}"; do
  skill_src="$INSTALLER_DIR/skills/$skill_name"
  skill_dest="$OPENCLAW_DIR/skills/$skill_name"

  if [ -d "$skill_dest" ] && [ -n "$(ls -A "$skill_dest" 2>/dev/null)" ]; then
    skip "skill: $skill_name (global)"
    continue
  fi

  if [ -d "$skill_src" ] && [ -n "$(ls -A "$skill_src" 2>/dev/null)" ]; then
    if $DRY_RUN; then
      dry "Install skill $skill_name to ~/.openclaw/skills/"
    else
      mkdir -p "$skill_dest"
      cp -R "$skill_src/"* "$skill_dest/" 2>>"$LOG_FILE" \
        && ok "skill: $skill_name (global)" \
        || fail "skill: $skill_name copy"
    fi
  else
    warn "skill: $skill_name — source not found at $skill_src/"
  fi
done

# Workspace skills (installed to workspace/skills/)
WS_SKILLS=("dev-gsd" "sales-outreach" "viral-content")

for skill_name in "${WS_SKILLS[@]}"; do
  skill_src="$INSTALLER_DIR/skills/$skill_name"
  skill_dest="$WORKSPACE_DIR/skills/$skill_name"

  if [ -d "$skill_dest" ] && [ -n "$(ls -A "$skill_dest" 2>/dev/null)" ]; then
    skip "skill: $skill_name (workspace)"
    continue
  fi

  if [ -d "$skill_src" ] && [ -n "$(ls -A "$skill_src" 2>/dev/null)" ]; then
    if $DRY_RUN; then
      dry "Install skill $skill_name to workspace/skills/"
    else
      mkdir -p "$skill_dest"
      cp -R "$skill_src/"* "$skill_dest/" 2>>"$LOG_FILE" \
        && ok "skill: $skill_name (workspace)" \
        || fail "skill: $skill_name copy"
    fi
  else
    warn "skill: $skill_name — source not found at $skill_src/"
  fi
done

#===============================================================================
# STEP 16: Install cron jobs
#===============================================================================
step "Install cron jobs"

CRON_SRC="$INSTALLER_DIR/config/cron-jobs.template.json"
CRON_DEST="$OPENCLAW_DIR/cron/jobs.json"

if [ -f "$CRON_DEST" ]; then
  skip "cron jobs.json"
else
  if [ -f "$CRON_SRC" ]; then
    if $DRY_RUN; then
      dry "Process cron-jobs.template.json → ~/.openclaw/cron/jobs.json"
      SUCCESSES+=("Cron jobs (dry)")
    else
      mkdir -p "$OPENCLAW_DIR/cron" 2>/dev/null
      # Process template placeholders in cron jobs
      local_cron_content="$(cat "$CRON_SRC")"
      local_cron_content="$(echo "$local_cron_content" | sed \
        -e "s|{{HOME}}|${HOME}|g" \
        -e "s|{{OWNER_PHONE}}||g" \
        -e "s|{{USER_NAME}}|${CLIENT_NAME}|g" \
        -e "s|{{TWITTER_HANDLE}}||g" \
        -e "s|{{EMAIL_ADDRESS}}||g" \
        -e "s|{{WHATSAPP_GROUP_ID}}||g" \
        -e "s|{{COMMUNITY_CALL_LINK}}||g" \
      )"
      echo "$local_cron_content" > "$CRON_DEST" \
        && ok "cron jobs.json installed (placeholders need updating)" \
        || fail "cron jobs.json"
      info "Update placeholders in $CRON_DEST:"
      info "  OWNER_PHONE, TWITTER_HANDLE, EMAIL_ADDRESS, etc."
    fi
  else
    warn "Cron jobs template not found at $CRON_SRC"
  fi
fi

#===============================================================================
# STEP 17: Install utility scripts
#===============================================================================
step "Install utility scripts"

SCRIPTS_DEST="$OPENCLAW_DIR/scripts"
mkdir -p "$SCRIPTS_DEST" 2>/dev/null

UTIL_SCRIPTS=("backup.sh" "restore.sh" "update-check.sh" "update.sh")

for script_name in "${UTIL_SCRIPTS[@]}"; do
  script_src="$INSTALLER_DIR/scripts/$script_name"
  script_dest="$SCRIPTS_DEST/$script_name"

  if [ -f "$script_dest" ]; then
    skip "script: $script_name"
    continue
  fi

  if [ -f "$script_src" ]; then
    if $DRY_RUN; then
      dry "Install $script_name to ~/.openclaw/scripts/"
    else
      cp "$script_src" "$script_dest" 2>>"$LOG_FILE" \
        && chmod +x "$script_dest" \
        && ok "script: $script_name" \
        || fail "script: $script_name copy"
    fi
  else
    warn "script: $script_name — not found at $script_src"
  fi
done

# Also install the workspace scripts directory
if [ -d "$INSTALLER_DIR/workspace/scripts" ]; then
  mkdir -p "$WORKSPACE_DIR/scripts" 2>/dev/null
  for ws_script in "$INSTALLER_DIR/workspace/scripts/"*; do
    [ -f "$ws_script" ] || continue
    ws_script_name="$(basename "$ws_script")"
    ws_script_dest="$WORKSPACE_DIR/scripts/$ws_script_name"
    if [ -f "$ws_script_dest" ]; then
      skip "workspace script: $ws_script_name"
    else
      if $DRY_RUN; then
        dry "Install workspace/scripts/$ws_script_name"
      else
        cp "$ws_script" "$ws_script_dest" 2>>"$LOG_FILE" \
          && chmod +x "$ws_script_dest" \
          && ok "workspace script: $ws_script_name" \
          || fail "workspace script: $ws_script_name"
      fi
    fi
  done
fi

#===============================================================================
# STEP 18: Install LaunchAgents
#===============================================================================
step "Install LaunchAgents"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null

# Resolve paths for plists
NODE_BIN=""
OPENCLAW_INDEX=""
if [ -s "$NVM_DIR/nvm.sh" ]; then
  NODE_BIN="$HOME/.nvm/versions/node/v${NODE_TARGET}/bin/node"
  OPENCLAW_INDEX="$HOME/.nvm/versions/node/v${NODE_TARGET}/lib/node_modules/openclaw/dist/index.js"
fi
# Fallback to homebrew node
if [ -z "$NODE_BIN" ] || [ ! -f "$NODE_BIN" ]; then
  if [ "$ARCH" = "arm64" ]; then
    NODE_BIN="/opt/homebrew/bin/node"
  else
    NODE_BIN="/usr/local/bin/node"
  fi
fi
# Fallback for openclaw index.js
if [ -z "$OPENCLAW_INDEX" ] || [ ! -f "$OPENCLAW_INDEX" ]; then
  # Try to find it
  local_openclaw_bin="$(which openclaw 2>/dev/null || echo '')"
  if [ -n "$local_openclaw_bin" ]; then
    # Resolve: openclaw bin -> ../../lib/node_modules/openclaw/dist/index.js
    local_openclaw_root="$(dirname "$(dirname "$local_openclaw_bin")")/lib/node_modules/openclaw"
    if [ -f "$local_openclaw_root/dist/index.js" ]; then
      OPENCLAW_INDEX="$local_openclaw_root/dist/index.js"
    fi
  fi
fi

# --- ai.openclaw.node.plist ---
NODE_PLIST="$LAUNCH_AGENTS_DIR/ai.openclaw.node.plist"
if [ -f "$INSTALLER_DIR/launchagents/ai.openclaw.node.plist" ]; then
  # Use provided plist template
  if [ -f "$NODE_PLIST" ]; then
    skip "ai.openclaw.node.plist"
  else
    if $DRY_RUN; then
      dry "Install ai.openclaw.node.plist"
    else
      process_template "$INSTALLER_DIR/launchagents/ai.openclaw.node.plist" "$NODE_PLIST" \
        && ok "ai.openclaw.node.plist" \
        || fail "ai.openclaw.node.plist"
    fi
  fi
elif [ -f "$NODE_PLIST" ]; then
  skip "ai.openclaw.node.plist"
else
  if $DRY_RUN; then
    dry "Create ai.openclaw.node.plist"
    SUCCESSES+=("ai.openclaw.node.plist (dry)")
  else
    cat > "$NODE_PLIST" << NODEPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>ai.openclaw.node</string>
    <key>Comment</key>
    <string>OpenClaw Node Host — ${CLIENT_NAME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProgramArguments</key>
    <array>
      <string>${HOME}/.openclaw/scripts/launch-with-secrets.sh</string>
      <string>${NODE_BIN}</string>
      <string>${OPENCLAW_INDEX}</string>
      <string>node</string>
      <string>run</string>
      <string>--host</string>
      <string>127.0.0.1</string>
      <string>--port</string>
      <string>18789</string>
    </array>
    <key>StandardOutPath</key>
    <string>${HOME}/.openclaw/logs/node.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.openclaw/logs/node.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
      <key>OPENCLAW_LAUNCHD_LABEL</key>
      <string>ai.openclaw.node</string>
      <key>OPENCLAW_SERVICE_MARKER</key>
      <string>openclaw</string>
      <key>OPENCLAW_SERVICE_KIND</key>
      <string>node</string>
    </dict>
  </dict>
</plist>
NODEPLIST
    ok "ai.openclaw.node.plist created"
  fi
fi

# --- ai.openclaw.gateway.plist ---
GW_PLIST="$LAUNCH_AGENTS_DIR/ai.openclaw.gateway.plist"
if [ -f "$INSTALLER_DIR/launchagents/ai.openclaw.gateway.plist" ]; then
  if [ -f "$GW_PLIST" ]; then
    skip "ai.openclaw.gateway.plist"
  else
    if $DRY_RUN; then
      dry "Install ai.openclaw.gateway.plist"
    else
      process_template "$INSTALLER_DIR/launchagents/ai.openclaw.gateway.plist" "$GW_PLIST" \
        && ok "ai.openclaw.gateway.plist" \
        || fail "ai.openclaw.gateway.plist"
    fi
  fi
elif [ -f "$GW_PLIST" ]; then
  skip "ai.openclaw.gateway.plist"
else
  if $DRY_RUN; then
    dry "Create ai.openclaw.gateway.plist"
    SUCCESSES+=("ai.openclaw.gateway.plist (dry)")
  else
    cat > "$GW_PLIST" << GWPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>ai.openclaw.gateway</string>
    <key>Comment</key>
    <string>OpenClaw Gateway — ${CLIENT_NAME}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProgramArguments</key>
    <array>
      <string>${HOME}/.openclaw/scripts/launch-with-secrets.sh</string>
      <string>${NODE_BIN}</string>
      <string>${OPENCLAW_INDEX}</string>
      <string>gateway</string>
      <string>--port</string>
      <string>18789</string>
    </array>
    <key>StandardOutPath</key>
    <string>${HOME}/.openclaw/logs/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.openclaw/logs/gateway.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
      <key>OPENCLAW_GATEWAY_PORT</key>
      <string>18789</string>
      <key>OPENCLAW_LAUNCHD_LABEL</key>
      <string>ai.openclaw.gateway</string>
      <key>OPENCLAW_SERVICE_MARKER</key>
      <string>openclaw</string>
      <key>OPENCLAW_SERVICE_KIND</key>
      <string>gateway</string>
    </dict>
  </dict>
</plist>
GWPLIST
    ok "ai.openclaw.gateway.plist created"
  fi
fi

# Load the agents (but don't fail the whole install if they don't start)
if ! $DRY_RUN; then
  info "LaunchAgents will start on next login, or load now with:"
  info "  launchctl load $NODE_PLIST"
  info "  launchctl load $GW_PLIST"
  if [ -f "$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist" ]; then
    info "  launchctl load $HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
  fi
fi

#===============================================================================
# STEP 19: Create Composio entity + display Connect Link instructions
#===============================================================================
step "Composio entity for client"

if [ -z "$COMPOSIO_API_KEY" ] || [ "$COMPOSIO_API_KEY" = "ak_PLACEHOLDER" ]; then
  warn "Composio API key not set — skipping entity creation"
  SKIPPED+=("Composio entity")
else
  if $DRY_RUN; then
    dry "Create Composio entity for '$CLIENT_NAME'"
    SUCCESSES+=("Composio entity (dry)")
  else
    info "Composio entity ID: $CLIENT_NAME"
    info ""
    info "To connect integrations, run the Composio connect-link flow:"
    info ""
    info "  1. Set your Composio API key:"
    info "     export COMPOSIO_API_KEY='${COMPOSIO_API_KEY}'"
    info ""
    info "  2. Create entity and get connect links (via the openclaw-composio extension):"
    info "     cd $COMPOSIO_EXT_DIR"
    info "     npx ts-node connect-links.ts --entity '$CLIENT_NAME'"
    info ""
    info "  3. Or use the Composio CLI directly:"
    info "     pip install composio-core  # if not installed"
    info "     composio add gmail --entity-id '$CLIENT_NAME'"
    info "     composio add googlecalendar --entity-id '$CLIENT_NAME'"
    info "     composio add slack --entity-id '$CLIENT_NAME'"
    info "     composio add notion --entity-id '$CLIENT_NAME'"
    info "     composio add github --entity-id '$CLIENT_NAME'"
    info ""
    info "  The agent will use these connections for tool calls."
    ok "Composio entity instructions displayed"
  fi
fi

#===============================================================================
# STEP 20: Health check
#===============================================================================
step "Health check"

HEALTHCHECK="$INSTALLER_DIR/healthcheck.sh"

if [ -f "$HEALTHCHECK" ] && [ -x "$HEALTHCHECK" ]; then
  if $DRY_RUN; then
    dry "Run $HEALTHCHECK"
    SUCCESSES+=("Health check (dry)")
  else
    info "Running health check..."
    echo ""
    if bash "$HEALTHCHECK" 2>>"$LOG_FILE"; then
      ok "Health check passed"
    else
      warn "Health check reported issues — review output above"
    fi
  fi
else
  # Inline health check
  info "Running inline health check..."
  local_checks_passed=0
  local_checks_failed=0

  check_health() {
    local label="$1" result="$2"
    if [ "$result" = "ok" ]; then
      echo -e "  ${G}✓${NC} $label"
      local_checks_passed=$((local_checks_passed + 1))
    else
      echo -e "  ${R}✗${NC} $label — $result"
      local_checks_failed=$((local_checks_failed + 1))
    fi
  }

  # Check Homebrew
  if cmd_exists brew; then check_health "Homebrew" "ok"
  else check_health "Homebrew" "not found"; fi

  # Check Node.js
  if cmd_exists node; then
    local_node_ver="$(node -v 2>/dev/null)"
    if [ "$local_node_ver" = "v${NODE_TARGET}" ]; then
      check_health "Node.js $local_node_ver" "ok"
    else
      check_health "Node.js" "found $local_node_ver, expected v${NODE_TARGET}"
    fi
  else check_health "Node.js" "not found"; fi

  # Check npm
  if cmd_exists npm; then check_health "npm $(npm -v 2>/dev/null)" "ok"
  else check_health "npm" "not found"; fi

  # Check OpenClaw CLI
  if cmd_exists openclaw; then check_health "OpenClaw CLI" "ok"
  else check_health "OpenClaw CLI" "not found"; fi

  # Check ClawHub CLI
  if cmd_exists clawhub; then check_health "ClawHub CLI" "ok"
  else check_health "ClawHub CLI" "not found"; fi

  # Check 1Password CLI
  if cmd_exists op; then check_health "1Password CLI (op)" "ok"
  else check_health "1Password CLI (op)" "not found"; fi

  # Check .op-env secrets reference
  if [ -f "$OPENCLAW_DIR/.op-env" ]; then check_health "~/.openclaw/.op-env" "ok"
  else check_health "~/.openclaw/.op-env" "missing"; fi

  # Check launch-with-secrets.sh wrapper
  if [ -x "$OPENCLAW_DIR/scripts/launch-with-secrets.sh" ]; then check_health "launch-with-secrets.sh" "ok"
  else check_health "launch-with-secrets.sh" "missing or not executable"; fi

  # Check Tailscale
  if app_installed "Tailscale" || cmd_exists tailscale; then check_health "Tailscale" "ok"
  else check_health "Tailscale" "not found"; fi

  # Check cloudflared
  if cmd_exists cloudflared; then check_health "cloudflared" "ok"
  else check_health "cloudflared" "not found"; fi

  # Check Docker
  if ! $SKIP_DOCKER; then
    if docker info &>/dev/null 2>&1; then check_health "Docker daemon" "ok"
    else check_health "Docker daemon" "not running"; fi

    # Check Neo4j container
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^neo4j$'; then
      check_health "Neo4j container" "ok"
    else
      check_health "Neo4j container" "not running"
    fi
  fi

  # Check directory structure
  if [ -d "$WORKSPACE_DIR" ]; then check_health "~/.openclaw/workspace" "ok"
  else check_health "~/.openclaw/workspace" "missing"; fi

  # Check .env
  if [ -f "$OPENCLAW_DIR/.env" ]; then check_health "~/.openclaw/.env" "ok"
  else check_health "~/.openclaw/.env" "missing"; fi

  # Check openclaw.json
  if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then check_health "openclaw.json" "ok"
  else check_health "openclaw.json" "missing"; fi

  # Check extensions
  if [ -d "$MEM0_EXT_DIR/node_modules" ]; then check_health "openclaw-mem0 extension" "ok"
  else check_health "openclaw-mem0 extension" "not installed"; fi

  if [ -f "$COMPOSIO_EXT_DIR/package.json" ]; then check_health "openclaw-composio extension" "ok"
  else check_health "openclaw-composio extension" "not installed"; fi

  # Check LaunchAgents
  if [ -f "$LAUNCH_AGENTS_DIR/ai.openclaw.node.plist" ]; then check_health "LaunchAgent: node" "ok"
  else check_health "LaunchAgent: node" "missing"; fi

  if [ -f "$LAUNCH_AGENTS_DIR/ai.openclaw.gateway.plist" ]; then check_health "LaunchAgent: gateway" "ok"
  else check_health "LaunchAgent: gateway" "missing"; fi

  if [ -f "$LAUNCH_AGENTS_DIR/com.cloudflare.cloudflared.plist" ]; then check_health "LaunchAgent: cloudflared" "ok"
  else check_health "LaunchAgent: cloudflared" "missing"; fi

  echo ""
  info "Health: $local_checks_passed passed, $local_checks_failed failed"

  if [ $local_checks_failed -eq 0 ]; then
    ok "All health checks passed"
  else
    warn "Some health checks failed ($local_checks_failed)"
  fi
fi

#===============================================================================
# Summary
#===============================================================================
echo ""
echo -e "${G}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${G}║                    Installation Summary                     ║${NC}"
echo -e "${G}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Client:     ${C}${CLIENT_NAME}${NC}"
echo -e "  Installer:  ${C}${INSTALLER_DIR}${NC}"
echo ""

echo -e "  ${G}Succeeded: ${#SUCCESSES[@]}${NC}"
for s in "${SUCCESSES[@]+"${SUCCESSES[@]}"}"; do
  [ -n "$s" ] && echo -e "    ${G}✓${NC} $s"
done

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo -e "  ${Y}Skipped:   ${#SKIPPED[@]}${NC}"
  for s in "${SKIPPED[@]}"; do echo -e "    ${Y}⚠${NC} $s"; done
fi

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo -e "  ${R}Failed:    ${#FAILURES[@]}${NC}"
  for f in "${FAILURES[@]}"; do echo -e "    ${R}✗${NC} $f"; done
  echo ""
  echo -e "  ${Y}Check log: ${LOG_FILE}${NC}"
fi

echo ""

if [ ${#FAILURES[@]} -eq 0 ]; then
  echo -e "${G}  Installation complete. Next steps:${NC}"
  echo ""
  echo -e "  1. Load LaunchAgents:  ${C}launchctl load ~/Library/LaunchAgents/ai.openclaw.node.plist${NC}"
  echo -e "                         ${C}launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist${NC}"
  echo -e "                         ${C}launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist${NC}"
  echo -e "  2. Connect Composio:   ${C}composio add gmail --entity-id '${CLIENT_NAME}'${NC}"
  echo -e "  3. Tailscale auth:     ${C}open -a Tailscale && tailscale up --hostname=${CLIENT_NAME}${NC}"
  echo -e "  4. Cloudflare tunnel:  ${C}cloudflared tunnel login && cloudflared tunnel create ${CLIENT_NAME}${NC}"
  echo -e "  5. Apply BUSINESS.md:  See Step 13 output above (manual patch)"
  echo -e "  6. Start the agent:    ${C}openclaw start${NC}"
  echo ""
fi

log "=== Summary: ${#SUCCESSES[@]} ok, ${#SKIPPED[@]} skipped, ${#FAILURES[@]} failed ==="
exit ${#FAILURES[@]}

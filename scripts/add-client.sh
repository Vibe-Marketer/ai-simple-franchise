#!/bin/bash
#===============================================================================
# Add a client to the franchise registry (config/clients.json)
# Run from the ai-simple-franchise repo root.
#
# Usage:
#   ./scripts/add-client.sh
#   ./scripts/add-client.sh --name acme-corp --hostname acme-corp --user admin
#===============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CLIENTS_FILE="$REPO_DIR/config/clients.json"

# Colors
G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' R='\033[0;31m' NC='\033[0m'

# Parse args
CLIENT_NAME=""
HOSTNAME=""
SSH_USER=""
TAILSCALE_IP=""
NO_PUSH=false

while [ $# -gt 0 ]; do
  case "$1" in
    --name)       CLIENT_NAME="$2"; shift 2 ;;
    --hostname)   HOSTNAME="$2"; shift 2 ;;
    --user)       SSH_USER="$2"; shift 2 ;;
    --ip)         TAILSCALE_IP="$2"; shift 2 ;;
    --no-push)    NO_PUSH=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--name NAME] [--hostname HOST] [--user USER] [--ip TAILSCALE_IP] [--no-push]"
      echo ""
      echo "If options are not provided, you'll be prompted interactively."
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Verify clients.json exists
if [ ! -f "$CLIENTS_FILE" ]; then
  echo -e "${R}Error: $CLIENTS_FILE not found${NC}"
  echo "Run this from the ai-simple-franchise repo root."
  exit 1
fi

echo ""
echo -e "${G}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${G}║            Add Client to Franchise Registry             ║${NC}"
echo -e "${G}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Interactive prompts for missing values
if [ -z "$CLIENT_NAME" ]; then
  read -r -p "  Client name (e.g. acme-corp): " CLIENT_NAME
  if [ -z "$CLIENT_NAME" ]; then
    echo -e "${R}Error: Client name is required${NC}"
    exit 1
  fi
fi

# Sanitize: lowercase, hyphens only
CLIENT_NAME="$(echo "$CLIENT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')"

# Check for duplicates
if jq -e ".clients[] | select(.name == \"$CLIENT_NAME\")" "$CLIENTS_FILE" &>/dev/null; then
  echo -e "${Y}Client '$CLIENT_NAME' already exists in registry${NC}"
  jq ".clients[] | select(.name == \"$CLIENT_NAME\")" "$CLIENTS_FILE"
  exit 0
fi

if [ -z "$HOSTNAME" ]; then
  read -r -p "  Tailscale hostname [${CLIENT_NAME}]: " HOSTNAME
  HOSTNAME="${HOSTNAME:-$CLIENT_NAME}"
fi

if [ -z "$TAILSCALE_IP" ]; then
  read -r -p "  Tailscale IP (leave blank for MagicDNS): " TAILSCALE_IP
fi

if [ -z "$SSH_USER" ]; then
  read -r -p "  SSH username [admin]: " SSH_USER
  SSH_USER="${SSH_USER:-admin}"
fi

# Show what we're adding
echo ""
echo -e "  ${C}Adding client:${NC}"
echo -e "    Name:          ${C}${CLIENT_NAME}${NC}"
echo -e "    Hostname:      ${C}${HOSTNAME}${NC}"
echo -e "    Tailscale IP:  ${C}${TAILSCALE_IP:-"(MagicDNS)"}${NC}"
echo -e "    SSH user:      ${C}${SSH_USER}${NC}"
echo -e "    Installer:     ${C}~/ai-simple-franchise${NC}"
echo ""

read -r -p "  Confirm? [Y/n]: " confirm
confirm="${confirm:-Y}"
if [[ ! "$confirm" =~ ^[Yy] ]]; then
  echo "  Cancelled."
  exit 0
fi

# Add to clients.json using jq
TEMP_FILE="$(mktemp)"
jq ".clients += [{
  \"name\": \"$CLIENT_NAME\",
  \"hostname\": \"$HOSTNAME\",
  \"tailscale_ip\": \"$TAILSCALE_IP\",
  \"ssh_user\": \"$SSH_USER\",
  \"installer_path\": \"~/ai-simple-franchise\",
  \"enabled\": true
}]" "$CLIENTS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$CLIENTS_FILE"

echo ""
echo -e "  ${G}✓${NC} Client '$CLIENT_NAME' added to registry"

# Show current registry
CLIENT_COUNT=$(jq '.clients | length' "$CLIENTS_FILE")
echo -e "  ${C}→${NC} Total clients: $CLIENT_COUNT"
echo ""

# Commit and push
if ! $NO_PUSH; then
  echo -e "  ${C}Committing and pushing to GitHub...${NC}"
  cd "$REPO_DIR" || exit 1
  git add config/clients.json
  git commit -m "Add client: $CLIENT_NAME" --quiet
  if git push origin main --quiet 2>&1; then
    echo -e "  ${G}✓${NC} Pushed to GitHub"
  else
    echo -e "  ${Y}⚠${NC} Push failed — commit is local, push manually: git push origin main"
  fi
fi

echo ""
echo -e "${G}  Done. Next steps:${NC}"
echo ""
echo -e "  1. Install on client machine:"
echo -e "     ${C}ssh ${SSH_USER}@${HOSTNAME}${NC}"
echo -e "     ${C}git clone https://github.com/Vibe-Marketer/ai-simple-franchise.git${NC}"
echo -e "     ${C}cd ai-simple-franchise && ./install.sh --client-name ${CLIENT_NAME}${NC}"
echo ""
echo -e "  2. Or deploy updates to this client:"
echo -e "     ${C}GitHub Actions → Deploy to Clients → target: ${CLIENT_NAME}${NC}"
echo ""

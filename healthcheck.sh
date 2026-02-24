#!/bin/bash
#===============================================================================
# OpenClaw Franchise Health Check
# Verifies all components of the franchise installation are working.
#===============================================================================

set -o pipefail

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  C='\033[0;36m'  NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  shift
  if "$@" &>/dev/null; then
    echo -e "  ${G}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${R}✗${NC} $label"
    FAIL=$((FAIL + 1))
  fi
}

check_warn() {
  local label="$1"
  shift
  if "$@" &>/dev/null; then
    echo -e "  ${G}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${Y}⚠${NC} $label (optional)"
    WARN=$((WARN + 1))
  fi
}

echo ""
echo -e "${C}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${C}║              OpenClaw Franchise Health Check                ║${NC}"
echo -e "${C}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- System ---
echo -e "${C}System${NC}"
check "Node.js installed" node -v
check "Node.js v24+" bash -c 'node -v | grep -q "^v2[4-9]"'
check "npm available" npm -v
check "OpenClaw CLI installed" command -v openclaw

# --- Docker + Neo4j ---
echo ""
echo -e "${C}Docker + Neo4j${NC}"
check "Docker running" docker info
check "Neo4j container exists" docker ps -a --format '{{.Names}}' | grep -q '^neo4j$'
check "Neo4j container running" docker ps --format '{{.Names}}' | grep -q '^neo4j$'
check_warn "Neo4j bolt port reachable" bash -c 'echo "" | nc -w2 localhost 7687'

# --- OpenClaw Config ---
echo ""
echo -e "${C}OpenClaw Configuration${NC}"
check "openclaw.json exists" test -f "$HOME/.openclaw/openclaw.json"
check ".env exists" test -f "$HOME/.openclaw/.env"
check "Main workspace exists" test -d "$HOME/.openclaw/workspace"
check "AGENTS.md exists" test -f "$HOME/.openclaw/workspace/AGENTS.md"
check "TOOLS.md exists" test -f "$HOME/.openclaw/workspace/TOOLS.md"
check "HEARTBEAT.md exists" test -f "$HOME/.openclaw/workspace/HEARTBEAT.md"
check "IDENTITY.md exists" test -f "$HOME/.openclaw/workspace/IDENTITY.md"
check "USER.md exists" test -f "$HOME/.openclaw/workspace/USER.md"
check "SOUL.md exists" test -f "$HOME/.openclaw/workspace/SOUL.md"
check "BUSINESS.md exists" test -f "$HOME/.openclaw/workspace/BUSINESS.md"

# --- Specialist Workspaces ---
echo ""
echo -e "${C}Specialist Workspaces${NC}"
for ws in bizdev content dev outreach quick; do
  check "workspace-$ws exists" test -d "$HOME/.openclaw/workspace-$ws"
  check "workspace-$ws/AGENTS.md" test -f "$HOME/.openclaw/workspace-$ws/AGENTS.md"
done

# --- Extensions ---
echo ""
echo -e "${C}Extensions${NC}"
check "openclaw-mem0 installed" test -d "$HOME/.openclaw/extensions/openclaw-mem0"
check "openclaw-mem0 node_modules" test -d "$HOME/.openclaw/extensions/openclaw-mem0/node_modules"
check "openclaw-composio installed" test -d "$HOME/.openclaw/extensions/openclaw-composio"
check "openclaw-composio node_modules" test -d "$HOME/.openclaw/extensions/openclaw-composio/node_modules"

# --- Mem0 ---
echo ""
echo -e "${C}Memory System (Mem0 v2)${NC}"
check "Vectors DB exists" test -f "$HOME/.openclaw/memory/mem0-vectors.db"
check_warn "Vectors DB has data" bash -c 'test $(stat -f%z "$HOME/.openclaw/memory/mem0-vectors.db" 2>/dev/null || echo 0) -gt 1000'
check "History DB exists" test -f "$HOME/.openclaw/memory/mem0-history.db"

# --- Skills ---
echo ""
echo -e "${C}Skills${NC}"
for skill in autonomous-brain calendly wacli; do
  check_warn "Skill: $skill" test -d "$HOME/.openclaw/skills/$skill"
done
for skill in dev-gsd sales-outreach viral-content; do
  check_warn "Skill: $skill" test -d "$HOME/.openclaw/workspace/skills/$skill"
done

# --- LaunchAgents ---
echo ""
echo -e "${C}LaunchAgents${NC}"
check "Node plist exists" test -f "$HOME/Library/LaunchAgents/ai.openclaw.node.plist"
check "Gateway plist exists" test -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
check_warn "Node LaunchAgent loaded" launchctl list | grep -q ai.openclaw.node
check_warn "Gateway LaunchAgent loaded" launchctl list | grep -q ai.openclaw.gateway

# --- API Keys ---
echo ""
echo -e "${C}API Keys (presence only)${NC}"
check_warn "ANTHROPIC_API_KEY or Max plan" bash -c 'grep -q "^ANTHROPIC_API_KEY=." "$HOME/.openclaw/.env" || grep -q "anthropic:.*token" "$HOME/.openclaw/openclaw.json"'
check "OPENROUTER_API_KEY set" bash -c 'grep -q "^OPENROUTER_API_KEY=." "$HOME/.openclaw/.env"'
check "COMPOSIO_API_KEY set" bash -c 'grep -q "^COMPOSIO_API_KEY=." "$HOME/.openclaw/.env"'

# --- Composio Plugin ---
echo ""
echo -e "${C}Composio Integration${NC}"
check "Entity map exists" test -f "$HOME/.openclaw/extensions/openclaw-composio/config/entity-map.json"
check_warn "Composio API reachable" bash -c 'curl -sf -o /dev/null -w "%{http_code}" https://backend.composio.dev/api/v1/apps | grep -q "200\|401"'

# --- Summary ---
echo ""
echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  ${G}Passed: $PASS${NC}  ${R}Failed: $FAIL${NC}  ${Y}Warnings: $WARN${NC}  Total: $TOTAL"

if [ $FAIL -eq 0 ]; then
  echo -e "\n  ${G}System is healthy.${NC}"
  exit 0
elif [ $FAIL -le 3 ]; then
  echo -e "\n  ${Y}System has minor issues.${NC}"
  exit 1
else
  echo -e "\n  ${R}System needs attention.${NC}"
  exit 2
fi

#!/bin/bash
#===============================================================================
# Apply OpenClaw BUSINESS.md Injection Patch
#
# Adds BUSINESS.md to the list of workspace files that get injected every turn.
# This patch modifies OpenClaw's compiled dist files.
#
# IMPORTANT: This patch will be lost on OpenClaw update.
# After updating OpenClaw, re-run this script.
#===============================================================================

set -euo pipefail

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  NC='\033[0m'

# Find the OpenClaw dist directory
OPENCLAW_BIN="$(which openclaw 2>/dev/null || echo '')"
if [ -z "$OPENCLAW_BIN" ]; then
  echo -e "${R}✗${NC} OpenClaw not found in PATH"
  exit 1
fi

# Resolve symlinks to find the actual install location
OPENCLAW_REAL="$(readlink -f "$OPENCLAW_BIN" 2>/dev/null || realpath "$OPENCLAW_BIN" 2>/dev/null || echo "$OPENCLAW_BIN")"
OPENCLAW_DIR="$(dirname "$OPENCLAW_REAL")/../lib/node_modules/openclaw/dist"

if [ ! -d "$OPENCLAW_DIR" ]; then
  # Try nvm-style path
  OPENCLAW_DIR="$(dirname "$OPENCLAW_BIN")/../lib/node_modules/openclaw/dist"
fi

if [ ! -d "$OPENCLAW_DIR" ]; then
  echo -e "${R}✗${NC} OpenClaw dist directory not found"
  echo "  Looked in: $OPENCLAW_DIR"
  echo "  OpenClaw binary: $OPENCLAW_BIN"
  exit 1
fi

echo ""
echo "OpenClaw dist directory: $OPENCLAW_DIR"
echo ""

# Find agent-scope files that contain loadWorkspaceBootstrapFiles
PATCHED=0
FAILED=0

for file in "$OPENCLAW_DIR"/agent-scope-*.js; do
  [ -f "$file" ] || continue
  BASENAME="$(basename "$file")"

  if grep -q 'BUSINESS.md' "$file" 2>/dev/null; then
    echo -e "  ${Y}⚠${NC} $BASENAME — BUSINESS.md already present"
    PATCHED=$((PATCHED + 1))
    continue
  fi

  if ! grep -q 'BOOTSTRAP.md' "$file" 2>/dev/null; then
    echo -e "  ${Y}⚠${NC} $BASENAME — no BOOTSTRAP.md reference (skipping)"
    continue
  fi

  # Backup
  [ ! -f "${file}.orig" ] && cp "$file" "${file}.orig"

  # Add BUSINESS.md after BOOTSTRAP.md in the entries array
  if python3 -c "
import re
with open('$file', 'r') as f:
    content = f.read()
# Find BOOTSTRAP.md entry and add BUSINESS.md after it
content = content.replace(
    'BOOTSTRAP.md',
    'BOOTSTRAP.md\",\"BUSINESS.md',
    1
)
with open('$file', 'w') as f:
    f.write(content)
" 2>/dev/null; then
    if grep -q 'BUSINESS.md' "$file" 2>/dev/null; then
      echo -e "  ${G}✓${NC} $BASENAME — patched"
      PATCHED=$((PATCHED + 1))
    else
      echo -e "  ${R}✗${NC} $BASENAME — patch failed"
      FAILED=$((FAILED + 1))
    fi
  else
    echo -e "  ${R}✗${NC} $BASENAME — python patch failed"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "Results: $PATCHED patched/verified, $FAILED failed"
[ $FAILED -eq 0 ] && exit 0 || exit 1
